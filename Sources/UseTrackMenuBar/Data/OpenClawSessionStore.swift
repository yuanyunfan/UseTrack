// UseTrack — macOS Activity Tracker
// OpenClawSessionStore: 解析 OpenClaw JSONL 会话数据
//
// 数据源: ~/.openclaw/agents/*/sessions/*.jsonl
// JSONL 格式: type=session (header), type=message (with usage)
// usage: { input, output, cacheRead, cacheWrite, totalTokens }

import Foundation

class OpenClawSessionStore {
    private let basePath: String

    init() {
        self.basePath = NSString(string: "~/.openclaw/agents").expandingTildeInPath
    }

    private struct SessionAcc {
        var model: String = ""
        var topic: String = ""
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var turns: Int = 0
        var userMessages: Int = 0
        var toolCalls: Int = 0
        var timestamps: [String] = []

        var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens }

        var timeRange: String {
            guard let first = timestamps.min(), let last = timestamps.max() else { return "" }
            return "\(toLocalTime(first))~\(toLocalTime(last))"
        }

        private func toLocalTime(_ iso: String) -> String {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
            if let d = f1.date(from: iso) { return timeFmt.string(from: d) }
            if let d = f2.date(from: iso) { return timeFmt.string(from: d) }
            return String(iso.prefix(5))
        }
    }

    // MARK: - Core scan

    private func scanSessions(from startDate: String, to endDate: String) -> [String: SessionAcc] {
        let fm = FileManager.default
        guard let agents = try? fm.contentsOfDirectory(atPath: basePath) else { return [:] }

        var sessions: [String: SessionAcc] = [:]

        for agent in agents {
            let sessionsDir = (basePath as NSString).appendingPathComponent("\(agent)/sessions")
            guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = (sessionsDir as NSString).appendingPathComponent(file)
                guard let data = fm.contents(atPath: filePath),
                      let content = String(data: data, encoding: .utf8) else { continue }

                let sessionId = String(file.dropLast(6)) // remove .jsonl
                var acc = SessionAcc()
                var hasMatchingDate = false

                content.enumerateLines { line, _ in
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }

                    let type = json["type"] as? String ?? ""

                    if type == "message" {
                        guard let ts = json["timestamp"] as? String,
                              let day = ClaudeSessionStore.localDateFromISO(ts),
                              day >= startDate && day < endDate else { return }

                        hasMatchingDate = true
                        acc.timestamps.append(ts)

                        guard let msg = json["message"] as? [String: Any] else { return }
                        let role = msg["role"] as? String ?? ""

                        if role == "user" {
                            acc.userMessages += 1
                            if acc.topic.isEmpty, let content = msg["content"] as? [[String: Any]] {
                                for item in content {
                                    if item["type"] as? String == "text",
                                       let text = item["text"] as? String, !text.isEmpty {
                                        acc.topic = String(text.prefix(80))
                                        break
                                    }
                                }
                            }
                        } else if role == "assistant" {
                            if let usage = msg["usage"] as? [String: Any] {
                                let input = (usage["input"] as? NSNumber)?.int64Value ?? 0
                                let output = (usage["output"] as? NSNumber)?.int64Value ?? 0
                                let cacheRead = (usage["cacheRead"] as? NSNumber)?.int64Value ?? 0

                                if input > 0 || output > 0 || cacheRead > 0 {
                                    acc.inputTokens += input
                                    acc.outputTokens += output
                                    acc.cacheReadTokens += cacheRead
                                    acc.turns += 1
                                }
                            }
                            if let model = msg["model"] as? String, !model.isEmpty {
                                acc.model = model
                            }
                            if let content = msg["content"] as? [[String: Any]] {
                                for item in content {
                                    if item["type"] as? String == "toolCall" {
                                        acc.toolCalls += 1
                                    }
                                }
                            }
                        }
                    }
                }

                if hasMatchingDate && (acc.totalTokens > 0 || acc.userMessages > 0) {
                    sessions[sessionId] = acc
                }
            }
        }
        return sessions
    }

    // MARK: - Public API

    func getTodayKPI(for dateStr: String) -> AISessionKPI {
        let sessions = scanSessions(from: dateStr, to: nextDate(dateStr))

        var totalInput: Int64 = 0, totalOutput: Int64 = 0, totalCache: Int64 = 0
        var toolCalls = 0, userMsgs = 0, validSessions = 0

        for (_, s) in sessions {
            guard s.totalTokens > 0 || s.userMessages > 0 else { continue }
            validSessions += 1
            totalInput += s.inputTokens
            totalOutput += s.outputTokens
            totalCache += s.cacheReadTokens
            toolCalls += s.toolCalls
            userMsgs += s.userMessages
        }

        return AISessionKPI(
            sessions: validSessions,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput, totalCacheReadTokens: totalCache,
            toolCalls: toolCalls, activeProjects: 0,
            userMessages: userMsgs, assistantMessages: sessions.values.reduce(0) { $0 + $1.turns },
            topProjects: []
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
            guard s.totalTokens > 0, let firstTs = s.timestamps.min(),
                  let day = ClaudeSessionStore.localDateFromISO(firstTs),
                  daily[day] != nil else { continue }
            var entry = daily[day]!
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
                sessionId: sid, project: "OpenClaw",
                topic: s.topic, timeRange: s.timeRange,
                inputTokens: s.inputTokens, outputTokens: s.outputTokens,
                cacheReadTokens: s.cacheReadTokens, totalTokens: s.totalTokens,
                turns: s.turns, toolCalls: s.toolCalls,
                model: s.model, source: "OpenClaw"
            )
        }.sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - Helpers

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
