// UseTrack — macOS Activity Tracker
// AISessionWatcher: 扫描 4 个 AI 工具的会话数据，增量同步到 SQLite
//
// 数据源:
//   - claude   : ~/.claude/projects/<projDir>/**/*.jsonl
//   - opencode : ~/.local/share/opencode/opencode.db
//   - hermes   : ~/.hermes/state.db + ~/.hermes/profiles/*/state.db
//   - openclaw : ~/.openclaw/agents/<agent>/sessions/*.jsonl
//
// 增量策略:
//   - jsonl 文件: ai_session_files.mtime > 文件 mtime 时跳过
//   - SQLite 数据源: 用 DB 文件 mtime 做 cache key；变了才重扫整库
//
// 调度:
//   - start() 时触发一次（后台 queue），之后每 pollInterval 秒一次
//   - --backfill-ai 子命令调用 runOnce(reset:) 强制重扫

import Foundation
import SQLite

class AISessionWatcher {
    private let dbManager: DatabaseManager
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "com.usetrack.ai-session-watcher", qos: .utility)
    private var isScanning = false
    private let scanLock = NSLock()

    init(dbManager: DatabaseManager, pollInterval: TimeInterval = 300) {
        self.dbManager = dbManager
        self.pollInterval = pollInterval
    }

    func start() {
        // 启动后立刻跑一次，捕捉 collector 离线期间的新 session
        workQueue.async { [weak self] in self?.runOnce() }

        // 之后每 pollInterval 秒一次
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.workQueue.async { self?.runOnce() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 扫描全部 4 个数据源。reset=true 时清空既有数据从头来。
    func runOnce(reset: Bool = false) {
        scanLock.lock()
        if isScanning {
            scanLock.unlock()
            return
        }
        isScanning = true
        scanLock.unlock()
        defer {
            scanLock.lock()
            isScanning = false
            scanLock.unlock()
        }

        let started = Date()
        if reset {
            for source in ["claude", "opencode", "hermes", "openclaw", "codex"] {
                try? dbManager.resetAISource(source)
            }
        }

        let claudeCount = scanClaude()
        let openCodeCount = scanOpenCode()
        let hermesCount = scanHermes()
        let openClawCount = scanOpenClaw()
        let codexCount = scanCodex()

        let elapsed = Date().timeIntervalSince(started)
        print("[AISessionWatcher] scan complete in \(String(format: "%.1f", elapsed))s — claude:\(claudeCount) opencode:\(openCodeCount) hermes:\(hermesCount) openclaw:\(openClawCount) codex:\(codexCount)")
    }

    // MARK: - Claude (~/.claude/projects/**/*.jsonl)

    private func scanClaude() -> Int {
        let basePath = NSString(string: "~/.claude/projects").expandingTildeInPath
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: basePath) else { return 0 }

        var newOrChanged = 0

        for projDir in projectDirs {
            let projPath = (basePath as NSString).appendingPathComponent(projDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let projectName = humanProjectName(projDir)

            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: projPath),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                let filePath = fileURL.path

                let mtime = fileMTime(filePath) ?? 0
                if let prev = dbManager.getAISessionFileMTime(filePath: filePath), prev >= mtime {
                    continue  // 文件未变化，跳过
                }

                let sessions = parseClaudeFile(filePath, projectName: projectName)
                for rec in sessions {
                    try? dbManager.upsertAISession(rec)
                }
                try? dbManager.markAISessionFileScanned(
                    filePath: filePath, source: "claude",
                    mtime: mtime, sessionsFound: sessions.count
                )
                if !sessions.isEmpty { newOrChanged += sessions.count }
            }
        }
        return newOrChanged
    }

    private func parseClaudeFile(_ filePath: String, projectName: String) -> [DatabaseManager.AISessionRecord] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else { return [] }

        // 单文件可能含多个 sessionId（比如 subagents 共用），按 sid 聚合
        struct Acc {
            var input: Int64 = 0, output: Int64 = 0, cache: Int64 = 0
            var userMsgs = 0, turns = 0, toolCalls = 0
            var topic: String? = nil
            var model: String? = nil
            var firstTs: String? = nil
            var lastTs: String? = nil
            var tools: [String: Int] = [:]
        }
        var byId: [String: Acc] = [:]

        content.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }

            let sid = (json["sessionId"] as? String) ?? "unknown"
            var acc = byId[sid] ?? Acc()

            let objType = json["type"] as? String ?? ""
            let ts = json["timestamp"] as? String

            if let ts = ts {
                if acc.firstTs == nil || ts < acc.firstTs! { acc.firstTs = ts }
                if acc.lastTs == nil || ts > acc.lastTs! { acc.lastTs = ts }
            }

            if objType == "user" || objType == "human" {
                acc.userMsgs += 1
                if acc.topic == nil {
                    acc.topic = Self.extractUserText(json)
                }
            } else if objType == "assistant" || objType == "ai" {
                let msg = (json["message"] as? [String: Any]) ?? [:]
                if let usage = (msg["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) {
                    let inT = Self.num(usage["input_tokens"]) + Self.num(usage["cache_creation_input_tokens"])
                    let outT = Self.num(usage["output_tokens"])
                    let cacheR = Self.num(usage["cache_read_input_tokens"])
                    if inT > 0 || outT > 0 || cacheR > 0 {
                        acc.input += inT; acc.output += outT; acc.cache += cacheR; acc.turns += 1
                    }
                }
                if let m = (msg["model"] as? String) ?? (json["model"] as? String), !m.isEmpty {
                    acc.model = m
                }
                if let contents = msg["content"] as? [[String: Any]] {
                    for item in contents where item["type"] as? String == "tool_use" {
                        acc.toolCalls += 1
                        let name = (item["name"] as? String) ?? "unknown"
                        acc.tools[name, default: 0] += 1
                    }
                }
            }

            byId[sid] = acc
        }

        var results: [DatabaseManager.AISessionRecord] = []
        for (sid, a) in byId where (a.input + a.output + a.cache) > 0 || a.userMsgs > 0 {
            results.append(DatabaseManager.AISessionRecord(
                sessionId: sid, source: "claude", project: projectName,
                startedAt: a.firstTs, endedAt: a.lastTs,
                inputTokens: a.input, outputTokens: a.output, cacheReadTokens: a.cache,
                userMessages: a.userMsgs, assistantTurns: a.turns, toolCalls: a.toolCalls,
                modelPrimary: a.model, topic: a.topic, toolBreakdown: a.tools
            ))
        }
        return results
    }

    // MARK: - OpenCode (~/.local/share/opencode/opencode.db)

    private func scanOpenCode() -> Int {
        let dbPath = NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else { return 0 }

        let mtime = fileMTime(dbPath) ?? 0
        if let prev = dbManager.getAISessionFileMTime(filePath: dbPath), prev >= mtime {
            return 0
        }

        guard let conn = try? Connection(dbPath, readonly: true) else { return 0 }

        // 读 session 元数据
        var sessionMeta: [String: (title: String, dir: String)] = [:]
        if let rows = try? conn.prepare("SELECT id, title, directory FROM session") {
            for row in rows {
                if let id = row[0] as? String {
                    sessionMeta[id] = (row[1] as? String ?? "", row[2] as? String ?? "")
                }
            }
        }

        struct Acc {
            var input: Int64 = 0, output: Int64 = 0, cache: Int64 = 0
            var userMsgs = 0, turns = 0, toolCalls = 0
            var model: String? = nil
            var firstMs: Double = .greatestFiniteMagnitude
            var lastMs: Double = 0
        }
        var byId: [String: Acc] = [:]

        guard let rows = try? conn.prepare("SELECT session_id, data FROM message") else { return 0 }
        for row in rows {
            guard let sid = row[0] as? String,
                  let dataStr = row[1] as? String,
                  let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            var acc = byId[sid] ?? Acc()
            let role = json["role"] as? String ?? ""
            if let timeDict = json["time"] as? [String: Any], let created = timeDict["created"] as? Double {
                acc.firstMs = min(acc.firstMs, created)
                acc.lastMs = max(acc.lastMs, created)
            }

            if role == "user" {
                acc.userMsgs += 1
            } else if role == "assistant" {
                if let tokens = json["tokens"] as? [String: Any] {
                    let cacheObj = (tokens["cache"] as? [String: Any]) ?? [:]
                    let inputBase = (tokens["input"] as? NSNumber)?.int64Value ?? 0
                    let cacheWrite = (cacheObj["write"] as? NSNumber)?.int64Value ?? 0
                    let cacheRead = (cacheObj["read"] as? NSNumber)?.int64Value ?? 0
                    let output = (tokens["output"] as? NSNumber)?.int64Value ?? 0
                    // 对齐 pew normalizeOpenCodeTokens: input = tokens.input + tokens.cache.write
                    let input = inputBase + cacheWrite
                    if input > 0 || output > 0 || cacheRead > 0 {
                        acc.input += input; acc.output += output; acc.cache += cacheRead; acc.turns += 1
                    }
                }
                if let m = json["modelID"] as? String, !m.isEmpty { acc.model = m }
                if json["finish"] as? String == "tool-calls" { acc.toolCalls += 1 }
            }
            byId[sid] = acc
        }

        var count = 0
        for (sid, a) in byId where (a.input + a.output + a.cache) > 0 || a.userMsgs > 0 {
            let meta = sessionMeta[sid]
            let project = projectFromDirectory(meta?.dir ?? "")
            let firstTs = a.firstMs < .greatestFiniteMagnitude ? msToISO(a.firstMs) : nil
            let lastTs = a.lastMs > 0 ? msToISO(a.lastMs) : nil
            let topic = meta?.title.isEmpty == false ? meta?.title : nil
            try? dbManager.upsertAISession(.init(
                sessionId: sid, source: "opencode", project: project,
                startedAt: firstTs, endedAt: lastTs,
                inputTokens: a.input, outputTokens: a.output, cacheReadTokens: a.cache,
                userMessages: a.userMsgs, assistantTurns: a.turns, toolCalls: a.toolCalls,
                modelPrimary: a.model, topic: topic, toolBreakdown: [:]
            ))
            count += 1
        }
        try? dbManager.markAISessionFileScanned(filePath: dbPath, source: "opencode", mtime: mtime, sessionsFound: count)
        return count
    }

    // MARK: - Hermes (~/.hermes/state.db + profiles)

    private func scanHermes() -> Int {
        var dbPaths = [NSString(string: "~/.hermes/state.db").expandingTildeInPath]
        let profilesDir = NSString(string: "~/.hermes/profiles").expandingTildeInPath
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
            for p in profiles {
                let dbPath = (profilesDir as NSString).appendingPathComponent("\(p)/state.db")
                if FileManager.default.fileExists(atPath: dbPath) { dbPaths.append(dbPath) }
            }
        }

        var total = 0
        for dbPath in dbPaths {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            let mtime = fileMTime(dbPath) ?? 0
            if let prev = dbManager.getAISessionFileMTime(filePath: dbPath), prev >= mtime { continue }

            guard let conn = try? Connection(dbPath, readonly: true) else { continue }
            guard let rows = try? conn.prepare("""
                SELECT id, source, model, started_at, ended_at,
                       message_count, tool_call_count,
                       input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                       title
                FROM sessions
                """) else { continue }

            var count = 0
            for row in rows {
                let input = (row[7] as? Int64) ?? 0
                let output = (row[8] as? Int64) ?? 0
                let cacheRead = (row[9] as? Int64) ?? 0
                let cacheWrite = (row[10] as? Int64) ?? 0
                // 对齐 pew hermes parser: cachedInputTokens = cache_read + cache_write
                let cache = cacheRead + cacheWrite
                guard input > 0 || output > 0 || cache > 0 else { continue }

                let id = row[0] as? String ?? ""
                let triggerSource = row[1] as? String  // cron/discord/etc — 用作 project 维度区分自动化 vs 手动
                let model = row[2] as? String
                let started = row[3] as? Double ?? 0
                let ended = row[4] as? Double
                let title = row[11] as? String
                try? dbManager.upsertAISession(.init(
                    sessionId: id, source: "hermes", project: triggerSource ?? "(unknown)",
                    startedAt: started > 0 ? epochToISO(started) : nil,
                    endedAt: ended.map(epochToISO),
                    inputTokens: input, outputTokens: output, cacheReadTokens: cache,
                    userMessages: Int((row[5] as? Int64) ?? 0),
                    assistantTurns: 0,
                    toolCalls: Int((row[6] as? Int64) ?? 0),
                    modelPrimary: model, topic: title, toolBreakdown: [:]
                ))
                count += 1
            }
            try? dbManager.markAISessionFileScanned(filePath: dbPath, source: "hermes", mtime: mtime, sessionsFound: count)
            total += count
        }
        return total
    }

    // MARK: - OpenClaw (~/.openclaw/agents/<agent>/sessions/*.jsonl)

    private func scanOpenClaw() -> Int {
        let basePath = NSString(string: "~/.openclaw/agents").expandingTildeInPath
        let fm = FileManager.default
        guard let agents = try? fm.contentsOfDirectory(atPath: basePath) else { return 0 }

        var newOrChanged = 0
        for agent in agents {
            let sessionsDir = (basePath as NSString).appendingPathComponent("\(agent)/sessions")
            guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let filePath = (sessionsDir as NSString).appendingPathComponent(file)
                let mtime = fileMTime(filePath) ?? 0
                if let prev = dbManager.getAISessionFileMTime(filePath: filePath), prev >= mtime { continue }

                let sid = String(file.dropLast(6))
                if let rec = parseOpenClawFile(filePath, sessionId: sid, agent: agent) {
                    try? dbManager.upsertAISession(rec)
                    newOrChanged += 1
                    try? dbManager.markAISessionFileScanned(filePath: filePath, source: "openclaw", mtime: mtime, sessionsFound: 1)
                } else {
                    try? dbManager.markAISessionFileScanned(filePath: filePath, source: "openclaw", mtime: mtime, sessionsFound: 0)
                }
            }
        }
        return newOrChanged
    }

    private func parseOpenClawFile(_ filePath: String, sessionId: String, agent: String) -> DatabaseManager.AISessionRecord? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var input: Int64 = 0, output: Int64 = 0, cache: Int64 = 0
        var userMsgs = 0, turns = 0, toolCalls = 0
        var topic: String? = nil
        var model: String? = nil
        var firstTs: String? = nil, lastTs: String? = nil
        var tools: [String: Int] = [:]

        content.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "message" else { return }

            if let ts = json["timestamp"] as? String {
                if firstTs == nil || ts < firstTs! { firstTs = ts }
                if lastTs == nil || ts > lastTs! { lastTs = ts }
            }
            guard let msg = json["message"] as? [String: Any] else { return }
            let role = msg["role"] as? String ?? ""

            if role == "user" {
                userMsgs += 1
                if topic == nil, let contents = msg["content"] as? [[String: Any]] {
                    for item in contents where item["type"] as? String == "text" {
                        if let text = item["text"] as? String, !text.isEmpty {
                            topic = String(text.prefix(80)); break
                        }
                    }
                }
            } else if role == "assistant" {
                if let usage = msg["usage"] as? [String: Any] {
                    let uInput = (usage["input"] as? NSNumber)?.int64Value ?? 0
                    let uCacheRead = (usage["cacheRead"] as? NSNumber)?.int64Value ?? 0
                    let uCacheWrite = (usage["cacheWrite"] as? NSNumber)?.int64Value ?? 0
                    let outT = (usage["output"] as? NSNumber)?.int64Value ?? 0
                    // 对齐 pew openclaw parser: input = usage.input + usage.cacheRead + usage.cacheWrite
                    let inT = uInput + uCacheRead + uCacheWrite
                    if inT > 0 || outT > 0 || uCacheRead > 0 {
                        input += inT; output += outT; cache += uCacheRead; turns += 1
                    }
                }
                if let m = msg["model"] as? String, !m.isEmpty { model = m }
                if let contents = msg["content"] as? [[String: Any]] {
                    for item in contents where item["type"] as? String == "toolCall" {
                        toolCalls += 1
                        let name = (item["name"] as? String) ?? "unknown"
                        tools[name, default: 0] += 1
                    }
                }
            }
        }

        guard (input + output + cache) > 0 || userMsgs > 0 else { return nil }
        return DatabaseManager.AISessionRecord(
            sessionId: sessionId, source: "openclaw", project: agent,
            startedAt: firstTs, endedAt: lastTs,
            inputTokens: input, outputTokens: output, cacheReadTokens: cache,
            userMessages: userMsgs, assistantTurns: turns, toolCalls: toolCalls,
            modelPrimary: model, topic: topic, toolBreakdown: tools
        )
    }

    // MARK: - Codex (~/.codex/sessions/**/rollout-*.jsonl + Multica workspaces)
    // pew codex parser: cumulative diff on event_msg.payload.type == "token_count"
    //   inputTokens = total_token_usage.input_tokens (delta)
    //   cachedInputTokens = total_token_usage.cached_input_tokens (delta)
    //   outputTokens = total_token_usage.output_tokens (delta)

    private func scanCodex() -> Int {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        let sessionsDir = (codexHome as NSString).appendingPathComponent("sessions")

        var scanDirs = [sessionsDir]

        // Multica workspaces
        let multicaRoot = ProcessInfo.processInfo.environment["MULTICA_WORKSPACES"]
            ?? NSString(string: "~/multica_workspaces").expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: multicaRoot, isDirectory: &isDir), isDir.boolValue,
           let workspaces = try? fm.contentsOfDirectory(atPath: multicaRoot) {
            for ws in workspaces {
                let wsPath = (multicaRoot as NSString).appendingPathComponent(ws)
                guard let tasks = try? fm.contentsOfDirectory(atPath: wsPath) else { continue }
                for task in tasks {
                    let sessPath = (wsPath as NSString).appendingPathComponent("\(task)/codex-home/sessions")
                    if fm.fileExists(atPath: sessPath, isDirectory: &isDir), isDir.boolValue {
                        scanDirs.append(sessPath)
                    }
                }
            }
        }

        var newOrChanged = 0
        for scanDir in scanDirs {
            guard fm.fileExists(atPath: scanDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: scanDir),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") else { continue }
                let filePath = fileURL.path

                let mtime = fileMTime(filePath) ?? 0
                if let prev = dbManager.getAISessionFileMTime(filePath: filePath), prev >= mtime { continue }

                if let rec = parseCodexFile(filePath) {
                    try? dbManager.upsertAISession(rec)
                    newOrChanged += 1
                    try? dbManager.markAISessionFileScanned(filePath: filePath, source: "codex", mtime: mtime, sessionsFound: 1)
                } else {
                    try? dbManager.markAISessionFileScanned(filePath: filePath, source: "codex", mtime: mtime, sessionsFound: 0)
                }
            }
        }
        return newOrChanged
    }

    private func parseCodexFile(_ filePath: String) -> DatabaseManager.AISessionRecord? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var sessionId: String? = nil
        var projectCwd: String? = nil
        var lastModel: String? = nil
        var lastTotals: (input: Int64, cached: Int64, output: Int64)? = nil
        var totalInput: Int64 = 0, totalOutput: Int64 = 0, totalCached: Int64 = 0
        var deltaCount = 0
        var userMsgs = 0, assistantMsgs = 0
        var firstTs: String? = nil, lastTs: String? = nil

        content.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }

            let evtType = obj["type"] as? String ?? ""
            let payload = (obj["payload"] as? [String: Any]) ?? [:]
            if let ts = obj["timestamp"] as? String {
                if firstTs == nil || ts < firstTs! { firstTs = ts }
                if lastTs == nil || ts > lastTs! { lastTs = ts }
            }

            switch evtType {
            case "session_meta":
                if let id = payload["id"] as? String, !id.isEmpty { sessionId = id }
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty { projectCwd = cwd }
                if let m = payload["model"] as? String, !m.isEmpty { lastModel = m }

            case "turn_context":
                if let m = payload["model"] as? String, !m.isEmpty { lastModel = m }

            case "response_item":
                let role = payload["role"] as? String ?? ""
                if role == "user" { userMsgs += 1 }
                else if role == "assistant" { assistantMsgs += 1 }

            case "event_msg":
                guard payload["type"] as? String == "token_count" else { return }
                guard let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any] else { return }

                let curIn = max(0, Self.num(usage["input_tokens"]))
                let curCached = max(0, Self.num(usage["cached_input_tokens"]))
                let curOut = max(0, Self.num(usage["output_tokens"]))

                let delta: (input: Int64, cached: Int64, output: Int64)
                if let prev = lastTotals {
                    let dIn = curIn - prev.input
                    let dCached = curCached - prev.cached
                    let dOut = curOut - prev.output
                    if dIn < 0 || dCached < 0 || dOut < 0 {
                        // 计数器重置 → 用绝对值
                        delta = (curIn, curCached, curOut)
                    } else {
                        delta = (dIn, dCached, dOut)
                    }
                } else {
                    delta = (curIn, curCached, curOut)
                }
                lastTotals = (curIn, curCached, curOut)

                if delta.input == 0 && delta.cached == 0 && delta.output == 0 { return }

                totalInput += delta.input
                totalCached += delta.cached
                totalOutput += delta.output
                deltaCount += 1

            default:
                break
            }
        }

        guard deltaCount > 0 else { return nil }

        let project = projectCwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "(unknown)"
        let sid = sessionId ?? URL(fileURLWithPath: filePath).lastPathComponent

        return DatabaseManager.AISessionRecord(
            sessionId: sid, source: "codex", project: project,
            startedAt: firstTs, endedAt: lastTs,
            inputTokens: totalInput, outputTokens: totalOutput, cacheReadTokens: totalCached,
            userMessages: userMsgs, assistantTurns: assistantMsgs, toolCalls: 0,
            modelPrimary: lastModel, topic: nil, toolBreakdown: [:]
        )
    }

    // MARK: - Helpers

    private func fileMTime(_ path: String) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }

    private func humanProjectName(_ dirName: String) -> String {
        if dirName == "-Users-yuan" { return "~(home)" }
        let prefix = "-Users-yuan-"
        guard dirName.hasPrefix(prefix) else {
            return dirName.split(separator: "-").last.map(String.init) ?? dirName
        }
        var remainder = String(dirName.dropFirst(prefix.count))
        for p in ["ProjectRepo-", "Documents-", "Desktop-", "Downloads-"] {
            if remainder.hasPrefix(p) { remainder = String(remainder.dropFirst(p.count)); break }
        }
        // 对齐 analyze.py：workspace-fix-XXX → workspace/fix/XXX；workspace-XXX → workspace/XXX
        for kd in ["workspace-fix-", "workspace-"] {
            if let range = remainder.range(of: kd) {
                let basePart = String(remainder[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let subPart = String(remainder[range.upperBound...])
                let kdClean = String(kd.dropLast()).replacingOccurrences(of: "-", with: "/")
                remainder = subPart.isEmpty ? "\(basePart)/\(kdClean)" : "\(basePart)/\(kdClean)/\(subPart)"
                break
            }
        }
        return remainder
    }

    private func projectFromDirectory(_ dir: String) -> String {
        guard !dir.isEmpty else { return "(unknown)" }
        return URL(fileURLWithPath: dir).lastPathComponent
    }

    private func msToISO(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        return Self.isoOut.string(from: date)
    }
    private func epochToISO(_ s: Double) -> String {
        return Self.isoOut.string(from: Date(timeIntervalSince1970: s))
    }
    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func num(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        return 0
    }

    private static func extractUserText(_ json: [String: Any]) -> String? {
        let msg = json["message"] as? [String: Any]
        let content = msg?["content"]
        if let list = content as? [[String: Any]] {
            for item in list where item["type"] as? String == "text" {
                if let text = item["text"] as? String, !text.isEmpty {
                    return String(text.prefix(80))
                }
            }
        } else if let text = content as? String, !text.isEmpty {
            return String(text.prefix(80))
        }
        return nil
    }
}
