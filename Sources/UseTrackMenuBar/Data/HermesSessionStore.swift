// UseTrack — macOS Activity Tracker
// HermesSessionStore: 解析 Hermes Agent SQLite 会话数据
//
// 数据源: ~/.hermes/state.db (+ ~/.hermes/profiles/*/state.db)
// sessions 表已有聚合好的 token 统计

import Foundation
import SQLite

class HermesSessionStore {
    // MARK: - Scan Cache (NSLock 保护：4 个 Store 的 scan 在并行队列里跑，
    // 同时 invalidateCache 可能被新一轮 loadAISessions 调用 → Dictionary 并发读写崩溃)
    private var scanCache: [String: [Row]] = [:]
    private let cacheLock = NSLock()

    private func cachedScan(from start: String, to end: String) -> [Row] {
        let key = "\(start)|\(end)"
        cacheLock.lock()
        if let result = scanCache[key] {
            cacheLock.unlock()
            return result
        }
        cacheLock.unlock()
        let result = scanSessions(from: start, to: end)
        cacheLock.lock()
        scanCache[key] = result
        cacheLock.unlock()
        return result
    }

    func invalidateCache() {
        cacheLock.lock()
        scanCache.removeAll()
        cacheLock.unlock()
    }
    private var dbPaths: [String] {
        var paths = [NSString(string: "~/.hermes/state.db").expandingTildeInPath]
        let profilesDir = NSString(string: "~/.hermes/profiles").expandingTildeInPath
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
            for p in profiles {
                let dbPath = (profilesDir as NSString).appendingPathComponent("\(p)/state.db")
                if FileManager.default.fileExists(atPath: dbPath) {
                    paths.append(dbPath)
                }
            }
        }
        return paths
    }

    private struct Row {
        let id: String
        let source: String
        let model: String
        let startedAt: Double
        let endedAt: Double?
        let messageCount: Int
        let toolCallCount: Int
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
    }

    // MARK: - Core scan

    private func scanSessions(from startDate: String, to endDate: String) -> [Row] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        guard let startD = fmt.date(from: startDate),
              let endD = fmt.date(from: endDate) else { return [] }
        let startTs = startD.timeIntervalSince1970
        let endTs = endD.timeIntervalSince1970

        var results: [Row] = []

        for dbPath in dbPaths {
            guard let db = try? Connection(dbPath, readonly: true) else { continue }
            guard let rows = try? db.prepare(
                """
                SELECT id, source, model, started_at, ended_at,
                       message_count, tool_call_count,
                       input_tokens, output_tokens, cache_read_tokens
                FROM sessions WHERE started_at >= ? AND started_at < ?
                """, startTs, endTs
            ) else { continue }

            for row in rows {
                let input = (row[7] as? Int64) ?? 0
                let output = (row[8] as? Int64) ?? 0
                let cache = (row[9] as? Int64) ?? 0
                guard input > 0 || output > 0 || cache > 0 else { continue }

                results.append(Row(
                    id: row[0] as? String ?? "",
                    source: row[1] as? String ?? "",
                    model: row[2] as? String ?? "",
                    startedAt: row[3] as? Double ?? 0,
                    endedAt: row[4] as? Double,
                    messageCount: Int(row[5] as? Int64 ?? 0),
                    toolCallCount: Int(row[6] as? Int64 ?? 0),
                    inputTokens: input, outputTokens: output, cacheReadTokens: cache
                ))
            }
        }
        return results
    }

    // MARK: - Public API

    func getTodayKPI(for dateStr: String) -> AISessionKPI {
        let rows = cachedScan(from: dateStr, to: nextDate(dateStr))

        var totalInput: Int64 = 0, totalOutput: Int64 = 0, totalCache: Int64 = 0
        var toolCalls = 0, userMsgs = 0
        var sources = Set<String>()

        for r in rows {
            totalInput += r.inputTokens
            totalOutput += r.outputTokens
            totalCache += r.cacheReadTokens
            toolCalls += r.toolCallCount
            userMsgs += r.messageCount
            sources.insert(r.source)
        }

        return AISessionKPI(
            sessions: rows.count,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput, totalCacheReadTokens: totalCache,
            toolCalls: toolCalls, activeProjects: sources.count,
            userMessages: userMsgs, assistantMessages: 0,
            topProjects: Array(sources.prefix(3))
        )
    }

    func getDailyTrends(days: Int) -> [AISessionDailyTrend] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!

        let rows = cachedScan(from: fmtDate(start), to: fmtDate(end))

        var daily: [String: (input: Int64, output: Int64, cache: Int64, sessions: Int, tools: Int)] = [:]
        for i in 0..<days {
            daily[fmtDate(cal.date(byAdding: .day, value: i, to: start)!)] = (0, 0, 0, 0, 0)
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = .current

        for r in rows {
            let day = dateFmt.string(from: Date(timeIntervalSince1970: r.startedAt))
            guard var entry = daily[day] else { continue }
            entry.input += r.inputTokens
            entry.output += r.outputTokens
            entry.cache += r.cacheReadTokens
            entry.sessions += 1
            entry.tools += r.toolCallCount
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

    func getHourlyTrends() -> [AISessionDailyTrend] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayStr = fmtDate(today)
        let tomorrowStr = fmtDate(cal.date(byAdding: .day, value: 1, to: today)!)

        let rows = cachedScan(from: todayStr, to: tomorrowStr)

        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "HH"
        hourFmt.timeZone = .current

        var hourly: [String: (input: Int64, output: Int64, cache: Int64, sessions: Int, tools: Int)] = [:]
        for h in 0..<24 {
            hourly[String(format: "%02d:00", h)] = (0, 0, 0, 0, 0)
        }

        for r in rows {
            let hour = hourFmt.string(from: Date(timeIntervalSince1970: r.startedAt)) + ":00"
            guard var entry = hourly[hour] else { continue }
            entry.input += r.inputTokens
            entry.output += r.outputTokens
            entry.cache += r.cacheReadTokens
            entry.sessions += 1
            entry.tools += r.toolCallCount
            hourly[hour] = entry
        }

        return hourly.keys.sorted().map { hour in
            let d = hourly[hour]!
            return AISessionDailyTrend(
                date: hour, inputTokensK: Double(d.input) / 1000.0,
                outputTokensK: Double(d.output) / 1000.0,
                cacheReadTokensK: Double(d.cache) / 1000.0,
                sessions: d.sessions, toolCalls: d.tools
            )
        }
    }

    func getSessionDetails(for dateStr: String) -> [AISessionDetail] {
        let rows = cachedScan(from: dateStr, to: nextDate(dateStr))
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        return rows.map { r in
            let startTime = timeFmt.string(from: Date(timeIntervalSince1970: r.startedAt))
            let endTime = r.endedAt.map { timeFmt.string(from: Date(timeIntervalSince1970: $0)) } ?? startTime
            let total = r.inputTokens + r.outputTokens + r.cacheReadTokens

            return AISessionDetail(
                sessionId: r.id, project: r.source,
                topic: "", timeRange: "\(startTime)~\(endTime)",
                inputTokens: r.inputTokens, outputTokens: r.outputTokens,
                cacheReadTokens: r.cacheReadTokens, totalTokens: total,
                turns: r.messageCount, toolCalls: r.toolCallCount,
                model: r.model, source: "Hermes"
            )
        }.sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - Helpers

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func fmtDate(_ date: Date) -> String {
        Self.dateFmt.string(from: date)
    }

    private func nextDate(_ dateStr: String) -> String {
        guard let d = Self.dateFmt.date(from: dateStr) else { return dateStr }
        return Self.dateFmt.string(from: Calendar.current.date(byAdding: .day, value: 1, to: d)!)
    }
}
