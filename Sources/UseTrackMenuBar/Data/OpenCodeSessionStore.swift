// UseTrack — macOS Activity Tracker
// OpenCodeSessionStore: 解析 OpenCode SQLite 会话数据
//
// 数据源: ~/.local/share/opencode/opencode.db
// - session 表: id, title, directory, time_created, time_updated
// - message 表: id, session_id, time_created, data (JSON)
//   data.tokens: { input, output, cache.read, cache.write, total }

import Foundation
import SQLite

class OpenCodeSessionStore {
    private let dbPath: String

    init() {
        self.dbPath = NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath
    }

    // MARK: - Internal types

    private struct SessionAcc {
        var title: String = ""
        var directory: String = ""
        var model: String = ""
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var turns: Int = 0
        var userMessages: Int = 0
        var toolCalls: Int = 0
        var minTime: Double = .greatestFiniteMagnitude
        var maxTime: Double = 0

        var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens }

        var timeRange: String {
            guard minTime < .greatestFiniteMagnitude else { return "" }
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            let s = fmt.string(from: Date(timeIntervalSince1970: minTime / 1000))
            let e = fmt.string(from: Date(timeIntervalSince1970: maxTime / 1000))
            return "\(s)~\(e)"
        }

        mutating func addTime(_ ms: Double) {
            minTime = min(minTime, ms)
            maxTime = max(maxTime, ms)
        }
    }

    // MARK: - Core scan

    private func scanSessions(from startDate: String, to endDate: String) -> [String: SessionAcc] {
        guard let db = try? Connection(dbPath, readonly: true) else { return [:] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        guard let startD = fmt.date(from: startDate),
              let endD = fmt.date(from: endDate) else { return [:] }
        let startMs = Int64(startD.timeIntervalSince1970 * 1000)
        let endMs = Int64(endD.timeIntervalSince1970 * 1000)

        // Load session metadata
        var sessionMeta: [String: (title: String, dir: String)] = [:]
        if let rows = try? db.prepare("SELECT id, title, directory FROM session") {
            for row in rows {
                if let id = row[0] as? String {
                    sessionMeta[id] = (title: row[1] as? String ?? "", dir: row[2] as? String ?? "")
                }
            }
        }

        var sessions: [String: SessionAcc] = [:]

        guard let rows = try? db.prepare(
            "SELECT session_id, data FROM message WHERE time_created >= ? AND time_created < ?",
            startMs, endMs
        ) else { return [:] }

        for row in rows {
            guard let sid = row[0] as? String,
                  let dataStr = row[1] as? String,
                  let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let role = json["role"] as? String ?? ""
            let timeDict = json["time"] as? [String: Any]
            let created = timeDict?["created"] as? Double ?? 0

            var s = sessions[sid] ?? SessionAcc()
            if let meta = sessionMeta[sid] {
                s.title = meta.title
                s.directory = meta.dir
            }
            s.addTime(created)

            if role == "user" {
                s.userMessages += 1
            } else if role == "assistant" {
                if let tokens = json["tokens"] as? [String: Any] {
                    let input = (tokens["input"] as? NSNumber)?.int64Value ?? 0
                    let output = (tokens["output"] as? NSNumber)?.int64Value ?? 0
                    let cache = tokens["cache"] as? [String: Any]
                    let cacheRead = (cache?["read"] as? NSNumber)?.int64Value ?? 0

                    if input > 0 || output > 0 || cacheRead > 0 {
                        s.inputTokens += input
                        s.outputTokens += output
                        s.cacheReadTokens += cacheRead
                        s.turns += 1
                    }
                }
                if let model = json["modelID"] as? String, !model.isEmpty {
                    s.model = model
                }
                if json["finish"] as? String == "tool-calls" {
                    s.toolCalls += 1
                }
            }

            sessions[sid] = s
        }

        return sessions
    }

    // MARK: - Public API

    func getTodayKPI(for dateStr: String) -> AISessionKPI {
        let sessions = scanSessions(from: dateStr, to: nextDate(dateStr))

        var totalInput: Int64 = 0, totalOutput: Int64 = 0, totalCache: Int64 = 0
        var toolCalls = 0, userMsgs = 0, validSessions = 0
        var projects = Set<String>()
        var projectTokens: [String: Int64] = [:]

        for (_, s) in sessions {
            guard s.totalTokens > 0 || s.userMessages > 0 else { continue }
            validSessions += 1
            let proj = projectName(s.directory)
            projects.insert(proj)
            totalInput += s.inputTokens
            totalOutput += s.outputTokens
            totalCache += s.cacheReadTokens
            toolCalls += s.toolCalls
            userMsgs += s.userMessages
            projectTokens[proj, default: 0] += s.totalTokens
        }

        return AISessionKPI(
            sessions: validSessions,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput, totalCacheReadTokens: totalCache,
            toolCalls: toolCalls, activeProjects: projects.count,
            userMessages: userMsgs, assistantMessages: sessions.values.reduce(0) { $0 + $1.turns },
            topProjects: projectTokens.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
        )
    }

    func getDailyTrends(days: Int) -> [AISessionDailyTrend] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!

        let sessions = scanSessions(from: fmtDate(start), to: fmtDate(end))

        var daily: [String: (input: Int64, output: Int64, cache: Int64, sessions: Int, tools: Int)] = [:]
        for i in 0..<days {
            daily[fmtDate(cal.date(byAdding: .day, value: i, to: start)!)] = (0, 0, 0, 0, 0)
        }

        for (_, s) in sessions {
            guard s.totalTokens > 0, s.minTime < .greatestFiniteMagnitude else { continue }
            let day = fmtDate(Date(timeIntervalSince1970: s.minTime / 1000))
            guard var entry = daily[day] else { continue }
            entry.input += s.inputTokens
            entry.output += s.outputTokens
            entry.cache += s.cacheReadTokens
            entry.sessions += 1
            entry.tools += s.toolCalls
            daily[day] = entry
        }

        return daily.keys.sorted().map { day in
            let d = daily[day]!
            return AISessionDailyTrend(
                date: day, inputTokensK: Double(d.input) / 1000.0,
                outputTokensK: Double(d.output) / 1000.0,
                cacheReadTokensK: Double(d.cache) / 1000.0,
                sessions: d.sessions, toolCalls: d.tools
            )
        }
    }

    func getSessionDetails(for dateStr: String) -> [AISessionDetail] {
        let sessions = scanSessions(from: dateStr, to: nextDate(dateStr))

        return sessions.compactMap { sid, s in
            guard s.totalTokens > 0 else { return nil }
            return AISessionDetail(
                sessionId: sid, project: projectName(s.directory),
                topic: s.title, timeRange: s.timeRange,
                inputTokens: s.inputTokens, outputTokens: s.outputTokens,
                cacheReadTokens: s.cacheReadTokens, totalTokens: s.totalTokens,
                turns: s.turns, toolCalls: s.toolCalls,
                model: s.model, source: "OpenCode"
            )
        }.sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - Helpers

    private func projectName(_ dir: String) -> String {
        let home = NSHomeDirectory()
        if dir == home { return "~(home)" }
        if dir.hasPrefix(home + "/") {
            let rel = String(dir.dropFirst(home.count + 1))
            for p in ["ProjectRepo/", "Documents/", "Desktop/", "Downloads/"] {
                if rel.hasPrefix(p) { return String(rel.dropFirst(p.count)) }
            }
            return rel
        }
        return dir.split(separator: "/").last.map(String.init) ?? dir
    }

    private func fmtDate(_ date: Date) -> String {
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
