// UseTrack — macOS Activity Tracker
// ClaudeSessionStore: 解析 Claude Code 本地 JSONL 会话数据
//
// 对齐 analyze.py 的解析逻辑:
// - Token 计算: Input = input_tokens + cache_creation_input_tokens
// - 快速路径: 只解析包含 "usage" 的行（assistant 消息）
// - 用户消息: 提取第一条 user text 作为 session topic
// - isAllZero 过滤: 跳过所有 token 为 0 的行
// - 项目名: 对齐 analyze.py 的路径解析规则
// - 递归扫描: 包含 subagents/ 子目录下的 .jsonl

import Foundation

// MARK: - Data Models

struct AISessionKPI {
    let sessions: Int
    let totalInputTokens: Int64
    let totalOutputTokens: Int64
    let totalCacheReadTokens: Int64
    let toolCalls: Int
    let activeProjects: Int
    let userMessages: Int
    let assistantMessages: Int
    let topProjects: [String]
}

struct AISessionDailyTrend {
    let date: String
    let inputTokensK: Double
    let outputTokensK: Double
    let cacheReadTokensK: Double
    let sessions: Int
    let toolCalls: Int
}

struct AIProjectUsage {
    let project: String
    let tokensK: Double
    let sessions: Int
}

struct AIToolUsage {
    let tool: String
    let count: Int
}

struct AISessionDetail {
    let sessionId: String
    let project: String
    let topic: String       // 第一条用户消息摘要
    let timeRange: String   // "HH:mm~HH:mm"
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let totalTokens: Int64  // input + output + cache_read
    let turns: Int           // assistant 消息数（有 token 的）
    let toolCalls: Int
    let model: String
    let source: String      // "Claude Code", "OpenCode", "Hermes", "OpenClaw"

    init(sessionId: String, project: String, topic: String, timeRange: String,
         inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64, totalTokens: Int64,
         turns: Int, toolCalls: Int, model: String, source: String = "Claude Code") {
        self.sessionId = sessionId; self.project = project; self.topic = topic
        self.timeRange = timeRange; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens; self.turns = turns; self.toolCalls = toolCalls
        self.model = model; self.source = source
    }
}

// MARK: - Claude Session Store

class ClaudeSessionStore {
    private let basePath: String

    /// ISO8601 formatters for parsing timestamps
    private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFmtNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let localDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// Convert ISO timestamp (UTC) to local date string "yyyy-MM-dd"
    static func localDateFromISO(_ isoStr: String) -> String? {
        if let d = isoFmt.date(from: isoStr) { return localDateFmt.string(from: d) }
        if let d = isoFmtNoFrac.date(from: isoStr) { return localDateFmt.string(from: d) }
        return nil
    }

    init() {
        self.basePath = NSString(string: "~/.claude/projects").expandingTildeInPath
    }

    // MARK: - Core: scan a single date range, return per-session aggregated data

    /// Scan all JSONL files, aggregate by session. Aligned with analyze.py.
    private func scanSessions(from startDate: String, to endDate: String) -> [String: SessionAccumulator] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: basePath) else { return [:] }

        var sessions: [String: SessionAccumulator] = [:]

        for projDir in projectDirs {
            let projPath = (basePath as NSString).appendingPathComponent(projDir)

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let projectName = humanProjectName(projDir)

            // Recursively find all .jsonl files (includes subagents/)
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: projPath),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }

                let filePath = fileURL.path

                guard let data = fm.contents(atPath: filePath),
                      let content = String(data: data, encoding: .utf8) else { continue }

                content.enumerateLines { line, _ in
                    guard !line.isEmpty else { return }

                    // --- User message: extract topic ---
                    if line.contains("\"user\"") || line.contains("\"human\"") {
                        guard let json = Self.parseJSON(line) else { return }
                        let objType = json["type"] as? String ?? ""
                        guard objType == "user" || objType == "human" else { return }
                        guard let ts = json["timestamp"] as? String else { return }
                        guard let day = Self.localDateFromISO(ts) else { return }
                        guard day >= startDate && day < endDate else { return }

                        let sid = json["sessionId"] as? String ?? "unknown"
                        var s = sessions[sid] ?? SessionAccumulator(project: projectName)
                        s.project = projectName
                        s.userMessages += 1
                        s.addTime(ts)
                        if s.topic == nil {
                            s.topic = Self.extractUserText(json)
                        }
                        sessions[sid] = s
                        return
                    }

                    // --- Fast path: only parse lines with "usage" (analyze.py line 169) ---
                    guard line.contains("\"usage\"") else { return }

                    guard let json = Self.parseJSON(line) else { return }

                    let msg = json["message"] as? [String: Any] ?? [:]
                    let usage = (msg["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any])
                    guard let usage = usage else { return }

                    // Model required (analyze.py line 185)
                    let model = (msg["model"] as? String) ?? (json["model"] as? String) ?? ""
                    guard !model.isEmpty else { return }

                    guard let ts = json["timestamp"] as? String else { return }
                    guard let day = Self.localDateFromISO(ts) else { return }
                    guard day >= startDate && day < endDate else { return }

                    // Token extraction aligned with analyze.py normalizeClaudeUsage
                    let inputT = Self.num(usage["input_tokens"]) + Self.num(usage["cache_creation_input_tokens"])
                    let outputT = Self.num(usage["output_tokens"])
                    let cacheRead = Self.num(usage["cache_read_input_tokens"])

                    // isAllZero filter
                    guard inputT > 0 || outputT > 0 || cacheRead > 0 else { return }

                    let sid = json["sessionId"] as? String ?? "unknown"
                    var s = sessions[sid] ?? SessionAccumulator(project: projectName)
                    s.project = projectName
                    s.inputTokens += inputT
                    s.outputTokens += outputT
                    s.cacheReadTokens += cacheRead
                    s.turns += 1
                    s.addTime(ts)
                    if !model.isEmpty && !model.hasPrefix("<") { s.model = model }

                    // Tool calls
                    if let content = msg["content"] as? [[String: Any]] {
                        for item in content {
                            if item["type"] as? String == "tool_use" {
                                let name = item["name"] as? String ?? "unknown"
                                s.toolCounts[name, default: 0] += 1
                            }
                        }
                    }

                    sessions[sid] = s
                }
            }
        }

        return sessions
    }

    // MARK: - Public API

    func getTodayKPI(for dateStr: String) -> AISessionKPI {
        let sessions = scanSessions(from: dateStr, to: nextDate(dateStr))

        var totalInput: Int64 = 0, totalOutput: Int64 = 0, totalCache: Int64 = 0
        var toolCalls = 0, userMsgs = 0
        var projects = Set<String>()
        var projectTokens: [String: Int64] = [:]
        var validSessions = 0

        for (_, s) in sessions {
            let total = s.inputTokens + s.outputTokens + s.cacheReadTokens
            if total == 0 && s.userMessages == 0 { continue }
            validSessions += 1
            projects.insert(s.project)
            totalInput += s.inputTokens
            totalOutput += s.outputTokens
            totalCache += s.cacheReadTokens
            toolCalls += s.totalToolCalls
            userMsgs += s.userMessages
            projectTokens[s.project, default: 0] += total
        }

        let topProjects = projectTokens.sorted { $0.value > $1.value }.prefix(3).map { $0.key }

        return AISessionKPI(
            sessions: validSessions,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput, totalCacheReadTokens: totalCache,
            toolCalls: toolCalls, activeProjects: projects.count,
            userMessages: userMsgs, assistantMessages: sessions.values.reduce(0) { $0 + $1.turns },
            topProjects: topProjects
        )
    }

    func getDailyTrends(days: Int) -> [AISessionDailyTrend] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!

        let sessions = scanSessions(from: isoDateString(start), to: isoDateString(end))

        // Aggregate by day
        var daily: [String: (input: Int64, output: Int64, cache: Int64, sessions: Set<String>, tools: Int)] = [:]
        for i in 0..<days {
            let d = cal.date(byAdding: .day, value: i, to: start)!
            daily[isoDateString(d)] = (0, 0, 0, Set(), 0)
        }

        for (sid, s) in sessions {
            // Distribute to each day this session has timestamps
            for day in s.activeDays {
                guard day >= isoDateString(start) && day < isoDateString(end) else { continue }
                var entry = daily[day] ?? (0, 0, 0, Set(), 0)
                entry.sessions.insert(sid)
                // Attribute all tokens to the session's primary day (first timestamp)
                daily[day] = entry
            }
            // Attribute tokens to primary day
            if let primaryDay = s.activeDays.min() {
                var entry = daily[primaryDay] ?? (0, 0, 0, Set(), 0)
                entry.input += s.inputTokens
                entry.output += s.outputTokens
                entry.cache += s.cacheReadTokens
                entry.tools += s.totalToolCalls
                entry.sessions.insert(sid)
                daily[primaryDay] = entry
            }
        }

        return daily.keys.sorted().map { day in
            let d = daily[day]!
            return AISessionDailyTrend(
                date: day,
                inputTokensK: Double(d.input) / 1000.0,
                outputTokensK: Double(d.output) / 1000.0,
                cacheReadTokensK: Double(d.cache) / 1000.0,
                sessions: d.sessions.count,
                toolCalls: d.tools
            )
        }
    }

    func getProjectUsage(days: Int) -> [AIProjectUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!

        let sessions = scanSessions(from: isoDateString(start), to: isoDateString(end))

        var projectData: [String: (tokens: Int64, sessions: Set<String>)] = [:]
        for (sid, s) in sessions {
            let total = s.inputTokens + s.outputTokens + s.cacheReadTokens
            guard total > 0 else { continue }
            var entry = projectData[s.project] ?? (0, Set())
            entry.tokens += total
            entry.sessions.insert(sid)
            projectData[s.project] = entry
        }

        return projectData.map { key, val in
            AIProjectUsage(project: key, tokensK: Double(val.tokens) / 1000.0, sessions: val.sessions.count)
        }.sorted { $0.tokensK > $1.tokensK }
    }

    func getToolUsage(days: Int) -> [AIToolUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!

        let sessions = scanSessions(from: isoDateString(start), to: isoDateString(end))

        var tools: [String: Int] = [:]
        for (_, s) in sessions {
            for (name, count) in s.toolCounts {
                let simplified = simplifyToolName(name)
                tools[simplified, default: 0] += count
            }
        }

        return tools.map { AIToolUsage(tool: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    func getSessionDetails(for dateStr: String) -> [AISessionDetail] {
        let sessions = scanSessions(from: dateStr, to: nextDate(dateStr))

        return sessions.compactMap { sid, s in
            let total = s.inputTokens + s.outputTokens + s.cacheReadTokens
            guard total > 0 else { return nil }  // Skip zero-token sessions

            return AISessionDetail(
                sessionId: sid,
                project: s.project,
                topic: s.topic ?? "",
                timeRange: s.timeRange,
                inputTokens: s.inputTokens,
                outputTokens: s.outputTokens,
                cacheReadTokens: s.cacheReadTokens,
                totalTokens: total,
                turns: s.turns,
                toolCalls: s.totalToolCalls,
                model: simplifyModelName(s.model)
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }  // Sort by total tokens, biggest first
    }

    // MARK: - Helpers

    /// Convert directory name to project name (aligned with analyze.py)
    private func humanProjectName(_ dirName: String) -> String {
        if dirName == "-Users-yuan" { return "~(home)" }

        let prefix = "-Users-yuan-"
        guard dirName.hasPrefix(prefix) else {
            return dirName.split(separator: "-").last.map(String.init) ?? dirName
        }

        var remainder = String(dirName.dropFirst(prefix.count))
        let prefixesToStrip = ["ProjectRepo-", "Documents-", "Desktop-", "Downloads-"]
        for p in prefixesToStrip {
            if remainder.hasPrefix(p) {
                remainder = String(remainder.dropFirst(p.count))
                break
            }
        }
        return remainder
    }

    private func simplifyToolName(_ name: String) -> String {
        if name.starts(with: "mcp__") {
            let rest = name.dropFirst(5)
            if let idx = rest.firstIndex(of: "_") {
                return "MCP:\(rest[rest.startIndex..<idx])"
            }
        }
        return name
    }

    private func simplifyModelName(_ model: String) -> String {
        if model.contains("opus") { return "opus" }
        if model.contains("sonnet") { return "sonnet" }
        if model.contains("haiku") { return "haiku" }
        if model.isEmpty { return "" }
        return model
    }

    private static func parseJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func num(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        return 0
    }

    /// Extract first user text content (analyze.py _extract_user_text)
    private static func extractUserText(_ json: [String: Any]) -> String? {
        let msg = json["message"] as? [String: Any]
        let content = msg?["content"]

        if let list = content as? [[String: Any]] {
            for item in list {
                if item["type"] as? String == "text",
                   let text = item["text"] as? String, !text.isEmpty {
                    return String(text.prefix(80))
                }
            }
        } else if let text = content as? String, !text.isEmpty {
            return String(text.prefix(80))
        }

        // Fallback: try top-level "display" field from history
        if let display = json["display"] as? String, !display.isEmpty {
            return String(display.prefix(80))
        }
        return nil
    }

    private func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func nextDate(_ dateStr: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: dateStr) else { return dateStr }
        return f.string(from: Calendar.current.date(byAdding: .day, value: 1, to: d)!)
    }
}

// MARK: - Session Accumulator

private struct SessionAccumulator {
    var project: String
    var model: String = ""
    var topic: String? = nil
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var turns: Int = 0
    var userMessages: Int = 0
    var toolCounts: [String: Int] = [:]
    var timestamps: [String] = []  // ISO strings

    var totalToolCalls: Int { toolCounts.values.reduce(0, +) }

    var activeDays: Set<String> {
        Set(timestamps.compactMap { ClaudeSessionStore.localDateFromISO($0) })
    }

    var timeRange: String {
        guard let first = timestamps.min(), let last = timestamps.max() else { return "" }
        return "\(Self.toLocalTime(first))~\(Self.toLocalTime(last))"
    }

    mutating func addTime(_ ts: String) {
        timestamps.append(ts)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func toLocalTime(_ isoStr: String) -> String {
        if let d = isoFormatter.date(from: isoStr) {
            return timeFormatter.string(from: d)
        }
        if let d = isoFormatterNoFrac.date(from: isoStr) {
            return timeFormatter.string(from: d)
        }
        return String(isoStr.prefix(5))
    }
}
