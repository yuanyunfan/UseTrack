// UseTrack — macOS Activity Tracker
// DashboardDataStore: Dashboard 数据查询层
//
// 从 SQLite 只读读取数据，移植自 Python db.py。
// 关键规则：
// - 所有日期查询用 ts >= ? AND ts < ? 范围查询，不用 date(ts)
// - GROUP BY 必须包含所有非聚合列
// - 只读连接

import Foundation
import SQLite

// MARK: - Data Models

struct TodayMetrics {
    let deepWorkMin: Double
    let activeMin: Double
    let contextSwitches: Int
    let pingPongSwitches: Int
    let productivityRatio: Double
}

struct TimelineEvent {
    let app: String
    let start: String
    let end: String
    let category: String
    let durationMin: Double
}

struct AppRule: Identifiable {
    let id: Int64
    let pattern: String
    var category: String
}

// MARK: - DashboardDataStore

class DashboardDataStore {
    private let dbPath: String

    init(dbPath: String = NSString(string: "~/.usetrack/usetrack.db").expandingTildeInPath) {
        self.dbPath = dbPath
    }

    private func connect() throws -> Connection {
        return try Connection(dbPath, readonly: true)
    }

    /// Read-write connection for settings mutations
    private func connectReadWrite() throws -> Connection {
        return try Connection(dbPath)
    }

    // MARK: - Date Helpers

    /// Returns [startOfDay, startOfNextDay) as local datetime strings matching DB format
    private func dayRange(for date: Date) -> (start: String, end: String) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let startOfNextDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (fmt.string(from: startOfDay), fmt.string(from: startOfNextDay))
    }

    /// Returns ISO 8601 date-only string (YYYY-MM-DD)
    private func dateString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// Returns a local datetime string for a given date, matching DB timestamp format
    private func isoString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    // MARK: - Today Metrics

    func getTodayMetrics(for date: Date) throws -> TodayMetrics {
        let db = try connect()
        let range = dayRange(for: date)

        // Deep work minutes (cap each event at 60min to exclude idle-while-focused)
        let dwQuery = """
            SELECT ROUND(SUM(MIN(COALESCE(duration_s, 0), 3600)) / 60.0, 1)
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND category = 'deep_work'
        """
        let dwMin = try db.scalar(dwQuery, [range.start, range.end]) as? Double ?? 0

        // Total active minutes
        let totalQuery = """
            SELECT ROUND(SUM(MIN(COALESCE(duration_s, 0), 3600)) / 60.0, 1)
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity NOT IN ('idle_start', 'idle_end')
        """
        let activeMin = try db.scalar(totalQuery, [range.start, range.end]) as? Double ?? 0

        // Context switches
        let switchQuery = """
            SELECT COUNT(*)
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
        """
        let switches = try db.scalar(switchQuery, [range.start, range.end]) as? Int64 ?? 0

        // Ping-pong switches (< 5 seconds)
        let ppQuery = """
            SELECT COUNT(*)
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
              AND duration_s IS NOT NULL AND duration_s < 5
        """
        let pingPong = try db.scalar(ppQuery, [range.start, range.end]) as? Int64 ?? 0

        let ratio = activeMin > 0 ? dwMin / activeMin : 0

        return TodayMetrics(
            deepWorkMin: dwMin,
            activeMin: activeMin,
            contextSwitches: Int(switches),
            pingPongSwitches: Int(pingPong),
            productivityRatio: ratio
        )
    }

    // MARK: - Energy Curve (last 24 hours)

    /// Returns energy data for the last 24 hours (from current hour back 23 hours).
    /// Always returns exactly 24 entries, even for hours with no activity (filled with 0).
    func getEnergyCurve(for date: Date) throws -> [(hour: Int, activeMin: Double, deepWorkMin: Double)] {
        let db = try connect()
        let cal = Calendar.current

        // Compute the 24-hour window: from (currentHour - 23) to end of currentHour
        let currentHour = cal.dateComponents([.year, .month, .day, .hour], from: date)
        guard let endOfWindow = cal.date(from: currentHour)?.addingTimeInterval(3600) else {
            return []
        }
        let startOfWindow = endOfWindow.addingTimeInterval(-24 * 3600)

        let startTs = isoString(for: startOfWindow)
        let endTs = isoString(for: endOfWindow)

        // Fetch raw events with start time and duration
        let query = """
            SELECT ts, COALESCE(duration_s, 0), COALESCE(category, '')
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity NOT IN ('idle_start', 'idle_end')
              AND duration_s IS NOT NULL AND duration_s > 0
              AND app_name NOT IN ('loginwindow', 'ScreenSaverEngine')
            ORDER BY ts
        """

        // Accumulate per-hour buckets, keyed by "YYYY-MM-DD HH" to handle day boundaries
        var activeBySlot: [String: Double] = [:]
        var dwBySlot: [String: Double] = [:]

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Also handle fractional seconds: "2026-04-11T16:00:11.123"
        let formatterFrac = DateFormatter()
        formatterFrac.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatterFrac.locale = Locale(identifier: "en_US_POSIX")

        let slotFormatter = DateFormatter()
        slotFormatter.dateFormat = "yyyy-MM-dd HH"
        slotFormatter.locale = Locale(identifier: "en_US_POSIX")

        for row in try db.prepare(query, [startTs, endTs]) {
            guard let tsStr = row[0] as? String else { continue }
            let duration = row[1] as? Double ?? 0
            let category = row[2] as? String ?? ""

            guard let startDate = formatter.date(from: tsStr) ?? formatterFrac.date(from: String(tsStr.prefix(23))) else { continue }

            let isDeepWork = (category == "deep_work")

            // Split duration across hour boundaries
            var remaining = duration
            var cursor = startDate

            while remaining > 0 {
                let slot = slotFormatter.string(from: cursor)
                // Seconds until next hour boundary
                let minuteOfHour = cal.component(.minute, from: cursor)
                let secondOfHour = cal.component(.second, from: cursor)
                let secsUntilNextHour = Double((59 - minuteOfHour) * 60 + (60 - secondOfHour))
                let chunk = min(remaining, secsUntilNextHour)

                activeBySlot[slot, default: 0] += chunk
                if isDeepWork {
                    dwBySlot[slot, default: 0] += chunk
                }

                remaining -= chunk
                cursor = cursor.addingTimeInterval(chunk)
            }
        }

        // Build all 24 hour slots, including those with no activity
        var result: [(hour: Int, activeMin: Double, deepWorkMin: Double)] = []
        for i in 0..<24 {
            let slotDate = startOfWindow.addingTimeInterval(Double(i) * 3600)
            let slot = slotFormatter.string(from: slotDate)
            let hour = cal.component(.hour, from: slotDate)

            let activeSec = activeBySlot[slot] ?? 0
            let dwSec = dwBySlot[slot] ?? 0
            let activeMin = min(activeSec / 60.0, 60.0)
            let dwMin = min(dwSec / 60.0, activeMin)
            result.append((hour: hour, activeMin: round(activeMin * 10) / 10, deepWorkMin: round(dwMin * 10) / 10))
        }
        return result
    }

    // MARK: - Category Breakdown

    func getCategoryBreakdown(for date: Date) throws -> [(category: String, minutes: Double)] {
        let db = try connect()
        let range = dayRange(for: date)

        let query = """
            SELECT category,
                   ROUND(SUM(MIN(COALESCE(duration_s, 0), 3600)) / 60.0, 1) as minutes
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND category IS NOT NULL
            GROUP BY category
            ORDER BY minutes DESC
        """

        var result: [(category: String, minutes: Double)] = []
        for row in try db.prepare(query, [range.start, range.end]) {
            let cat = row[0] as? String ?? "other"
            let min = row[1] as? Double ?? 0
            result.append((category: cat, minutes: min))
        }
        return result
    }

    // MARK: - Top Apps

    func getTopApps(for date: Date, limit: Int = 10) throws -> [(appName: String, category: String, minutes: Double)] {
        let db = try connect()
        let range = dayRange(for: date)

        let query = """
            SELECT app_name,
                   COALESCE(category, 'other') as category,
                   ROUND(SUM(MIN(COALESCE(duration_s, 0), 3600)) / 60.0, 1) as minutes
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity = 'app_switch' AND app_name IS NOT NULL
            GROUP BY app_name, category
            ORDER BY minutes DESC
            LIMIT ?
        """

        var result: [(appName: String, category: String, minutes: Double)] = []
        for row in try db.prepare(query, [range.start, range.end, limit]) {
            let name = row[0] as? String ?? ""
            let cat = row[1] as? String ?? "other"
            let min = row[2] as? Double ?? 0
            result.append((appName: name, category: cat, minutes: min))
        }
        return result
    }

    // MARK: - Timeline Events (Gantt chart)

    func getTimelineEvents(for date: Date) throws -> [TimelineEvent] {
        let db = try connect()
        let range = dayRange(for: date)

        // Get app_switch events with duration, compute end time
        let query = """
            SELECT app_name, ts, duration_s,
                   COALESCE(category, 'other') as category
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity = 'app_switch'
              AND app_name IS NOT NULL
              AND duration_s IS NOT NULL AND duration_s > 0
            ORDER BY ts
        """

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFmt.timeZone = .current

        let isoFmtNoFrac = ISO8601DateFormatter()
        isoFmtNoFrac.formatOptions = [.withInternetDateTime]
        isoFmtNoFrac.timeZone = .current

        let outputFmt = DateFormatter()
        outputFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var result: [TimelineEvent] = []
        for row in try db.prepare(query, [range.start, range.end]) {
            let app = row[0] as? String ?? ""
            let tsStr = row[1] as? String ?? ""
            let durationS = row[2] as? Double ?? 0
            let category = row[3] as? String ?? "other"

            // Parse start time
            guard let startDate = isoFmt.date(from: tsStr) ?? isoFmtNoFrac.date(from: tsStr) ?? Self.parseFlexibleDate(tsStr) else {
                continue
            }

            let endDate = startDate.addingTimeInterval(durationS)
            let durationMin = durationS / 60.0

            result.append(TimelineEvent(
                app: app,
                start: outputFmt.string(from: startDate),
                end: outputFmt.string(from: endDate),
                category: category,
                durationMin: Double(round(durationMin * 10) / 10)
            ))
        }
        return result
    }

    /// Flexible date parser for SQLite datetime formats
    private static func parseFlexibleDate(_ str: String) -> Date? {
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss"
        ]
        for f in fmts {
            let formatter = DateFormatter()
            formatter.dateFormat = f
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let d = formatter.date(from: str) {
                return d
            }
        }
        return nil
    }

    // MARK: - N-day Trends

    func getTrends(metric: String, days: Int = 7) throws -> [(date: String, value: Double)] {
        let db = try connect()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let endDate = cal.date(byAdding: .day, value: 1, to: today)!

        let startTs = isoString(for: startDate)
        let endTs = isoString(for: endDate)

        let query: String
        var params: [Binding?] = [startTs, endTs]

        switch metric {
        case "deep_work":
            // substr(ts,1,10) 提取日期部分，比 date(ts) 更轻量且不阻止索引
            query = """
                SELECT substr(ts, 1, 10) as d,
                       ROUND(SUM(CASE WHEN category = 'deep_work'
                           THEN COALESCE(duration_s, 0) ELSE 0 END) / 60.0, 1) as value
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                GROUP BY substr(ts, 1, 10)
                ORDER BY d
            """
        case "context_switches":
            query = """
                SELECT substr(ts, 1, 10) as d, COUNT(*) as value
                FROM activity_stream
                WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
                GROUP BY substr(ts, 1, 10)
                ORDER BY d
            """
        case "active_time":
            query = """
                SELECT substr(ts, 1, 10) as d,
                       ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as value
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                  AND activity NOT IN ('idle_start', 'idle_end')
                GROUP BY substr(ts, 1, 10)
                ORDER BY d
            """
        case "productivity":
            query = """
                SELECT substr(ts, 1, 10) as d,
                       ROUND(
                           SUM(CASE WHEN category = 'deep_work'
                               THEN COALESCE(duration_s, 0) ELSE 0 END)
                           / NULLIF(SUM(CASE WHEN activity NOT IN ('idle_start', 'idle_end')
                               THEN COALESCE(duration_s, 0) ELSE 0 END), 0),
                           2
                       ) as value
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                GROUP BY substr(ts, 1, 10)
                ORDER BY d
            """
        default:
            // Generic metric from output_metrics
            query = """
                SELECT date, SUM(value) as value
                FROM output_metrics
                WHERE date >= ? AND date < ? AND metric_type = ?
                GROUP BY date
                ORDER BY date
            """
            params = [dateString(for: startDate), dateString(for: endDate), metric]
        }

        var result: [(date: String, value: Double)] = []
        for row in try db.prepare(query, params) {
            let d = row[0] as? String ?? ""
            let v = row[1] as? Double ?? 0
            result.append((date: d, value: v))
        }
        return result
    }

    // MARK: - Weekly Heatmap

    func getWeeklyHeatmap() throws -> [(dayOfWeek: Int, hour: Int, count: Int)] {
        let db = try connect()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Last 4 weeks
        let startDate = cal.date(byAdding: .weekOfYear, value: -4, to: today)!
        let endDate = cal.date(byAdding: .day, value: 1, to: today)!

        let startTs = isoString(for: startDate)
        let endTs = isoString(for: endDate)

        // strftime('%w') returns 0=Sunday ... 6=Saturday
        // We want 0=Monday ... 6=Sunday
        let query = """
            SELECT
                CASE CAST(strftime('%w', ts) AS INTEGER)
                    WHEN 0 THEN 6
                    ELSE CAST(strftime('%w', ts) AS INTEGER) - 1
                END as day_of_week,
                CAST(strftime('%H', ts) AS INTEGER) as hour,
                COUNT(*) as count
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity NOT IN ('idle_start', 'idle_end')
            GROUP BY day_of_week, hour
            ORDER BY day_of_week, hour
        """

        var result: [(dayOfWeek: Int, hour: Int, count: Int)] = []
        for row in try db.prepare(query, [startTs, endTs]) {
            let dow = (row[0] as? Int64).map { Int($0) } ?? 0
            let hour = (row[1] as? Int64).map { Int($0) } ?? 0
            let count = (row[2] as? Int64).map { Int($0) } ?? 0
            result.append((dayOfWeek: dow, hour: hour, count: count))
        }
        return result
    }

    // MARK: - App Rules CRUD

    func getAppRules() throws -> [AppRule] {
        let db = try connect()
        let query = "SELECT id, pattern, category FROM app_rules ORDER BY category, pattern"

        var result: [AppRule] = []
        for row in try db.prepare(query) {
            let id = (row[0] as? Int64) ?? 0
            let pattern = row[1] as? String ?? ""
            let category = row[2] as? String ?? "other"
            result.append(AppRule(id: id, pattern: pattern, category: category))
        }
        return result
    }

    func deleteAppRule(id: Int64) throws {
        let db = try connectReadWrite()
        let sql = "DELETE FROM app_rules WHERE id = ?"
        try db.run(sql, [id])
    }

    func updateAppRuleCategory(id: Int64, category: String) throws {
        let db = try connectReadWrite()
        // 1. Get the app name for this rule
        var pattern: String?
        for row in try db.prepare("SELECT pattern FROM app_rules WHERE id = ?", [id]) {
            pattern = row[0] as? String
        }
        // 2. Update the rule
        try db.run("UPDATE app_rules SET category = ? WHERE id = ?", [category, id])
        // 3. Backfill: update all historical events for this app
        if let appName = pattern {
            try db.run(
                "UPDATE activity_stream SET category = ? WHERE app_name = ?",
                [category, appName]
            )
        }
    }

    func addAppRule(pattern: String, category: String) throws {
        let db = try connectReadWrite()
        try db.run(
            "INSERT OR REPLACE INTO app_rules (pattern, category) VALUES (?, ?)",
            [pattern, category]
        )
        // Backfill: update all historical events for this app
        try db.run(
            "UPDATE activity_stream SET category = ? WHERE app_name = ?",
            [category, pattern]
        )
    }

    // MARK: - DB Info

    func getDatabaseSize() throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: dbPath)
        return attrs[.size] as? Int64 ?? 0
    }
}
