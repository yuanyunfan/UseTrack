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
    private let syncConfig: SyncConfig?

    struct SyncConfig {
        let machineId: String
        let syncDir: String
    }

    init(dbPath: String = NSString(string: "~/.usetrack/usetrack.db").expandingTildeInPath) {
        self.dbPath = dbPath
        self.syncConfig = Self.loadSyncConfig()
    }

    private func connect() throws -> Connection {
        return try Connection(dbPath, readonly: true)
    }

    /// Read-write connection for settings mutations
    private func connectReadWrite() throws -> Connection {
        return try Connection(dbPath)
    }

    // MARK: - Sync Support

    /// Load sync config from ~/.usetrack/sync.toml
    private static func loadSyncConfig() -> SyncConfig? {
        let path = NSString(string: "~/.usetrack/sync.toml").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }

        // Simple TOML parser for our known keys
        var enabled = false
        var machineId: String?
        var syncDir: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("enabled") && trimmed.contains("true") { enabled = true }
            if let val = Self.parseTOMLString(trimmed, key: "machine_id") { machineId = val }
            if let val = Self.parseTOMLString(trimmed, key: "sync_dir") {
                syncDir = NSString(string: val).expandingTildeInPath
            }
        }
        guard enabled, let mid = machineId, let sd = syncDir else { return nil }
        return SyncConfig(machineId: mid, syncDir: sd)
    }

    private static func parseTOMLString(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        guard let eqIdx = line.firstIndex(of: "=") else { return nil }
        var val = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if val.hasPrefix("\"") && val.hasSuffix("\"") {
            val = String(val.dropFirst().dropLast())
        }
        return val.isEmpty ? nil : val
    }

    /// Find remote .db files from other machines for a given date range
    private func findRemoteDbs(startDate: String, endDate: String) -> [String] {
        guard let config = syncConfig else {

            return []
        }
        let fm = FileManager.default
        let syncDir = config.syncDir
        guard let machineDirs = try? fm.contentsOfDirectory(atPath: syncDir) else {

            return []
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        guard let startD = fmt.date(from: startDate),
              let endD = fmt.date(from: endDate) else { return [] }

        var result: [String] = []
        let cal = Calendar.current

        for machineDir in machineDirs {
            if machineDir == config.machineId { continue }  // Skip own machine
            if machineDir.hasPrefix(".") { continue }

            let machinePath = (syncDir as NSString).appendingPathComponent(machineDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: machinePath, isDirectory: &isDir), isDir.boolValue else { continue }

            var d = startD
            while d <= endD {
                let dateStr = fmt.string(from: d)
                let dbFile = (machinePath as NSString).appendingPathComponent("\(dateStr).db")
                if fm.fileExists(atPath: dbFile) {
                    result.append(dbFile)
                }
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
        }
        return result
    }

    /// Query a remote db and return scalar Double
    private func queryRemoteScalar(_ dbPath: String, sql: String, params: [Binding?]) -> Double {
        guard let db = try? Connection(dbPath, readonly: true) else { return 0 }
        return (try? db.scalar(sql, params) as? Double) ?? 0
    }

    /// Query a remote db and return scalar Int64
    private func queryRemoteScalarInt(_ dbPath: String, sql: String, params: [Binding?]) -> Int64 {
        guard let db = try? Connection(dbPath, readonly: true) else { return 0 }
        return (try? db.scalar(sql, params) as? Int64) ?? 0
    }

    /// Query a remote db and return rows as [[Binding?]]
    private func queryRemoteRows(_ dbPath: String, sql: String, params: [Binding?]) -> [[Binding?]] {
        guard let db = try? Connection(dbPath, readonly: true) else { return [] }
        guard let stmt = try? db.prepare(sql, params) else { return [] }
        return stmt.map { Array($0) }
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
        var dwMin = try db.scalar(dwQuery, [range.start, range.end]) as? Double ?? 0

        // Total active minutes
        let totalQuery = """
            SELECT ROUND(SUM(MIN(COALESCE(duration_s, 0), 3600)) / 60.0, 1)
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity NOT IN ('idle_start', 'idle_end')
        """
        var activeMin = try db.scalar(totalQuery, [range.start, range.end]) as? Double ?? 0

        // Context switches
        let switchQuery = """
            SELECT COUNT(*)
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
        """
        var switches = try db.scalar(switchQuery, [range.start, range.end]) as? Int64 ?? 0

        // Ping-pong switches (< 5 seconds)
        let ppQuery = """
            SELECT COUNT(*)
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
              AND duration_s IS NOT NULL AND duration_s < 5
        """
        var pingPong = try db.scalar(ppQuery, [range.start, range.end]) as? Int64 ?? 0

        // Merge remote data
        let dateStr = dateString(for: date)
        for remotePath in findRemoteDbs(startDate: dateStr, endDate: dateStr) {
            dwMin += queryRemoteScalar(remotePath, sql: dwQuery, params: [range.start, range.end])
            activeMin += queryRemoteScalar(remotePath, sql: totalQuery, params: [range.start, range.end])
            switches += queryRemoteScalarInt(remotePath, sql: switchQuery, params: [range.start, range.end])
            pingPong += queryRemoteScalarInt(remotePath, sql: ppQuery, params: [range.start, range.end])
        }

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
                // Seconds until next hour boundary (precise, accounts for sub-seconds)
                let nextHour = cal.nextDate(after: cursor, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .strict, direction: .forward) ?? cursor.addingTimeInterval(3600)
                let secsUntilNextHour = nextHour.timeIntervalSince(cursor)
                let chunk = min(remaining, secsUntilNextHour)

                activeBySlot[slot, default: 0] += chunk
                if isDeepWork {
                    dwBySlot[slot, default: 0] += chunk
                }

                remaining -= chunk
                cursor = cursor.addingTimeInterval(chunk)
            }
        }

        // Merge remote energy curve data
        let dateStr = dateString(for: date)
        let prevDateStr = dateString(for: date.addingTimeInterval(-86400))
        for remotePath in findRemoteDbs(startDate: prevDateStr, endDate: dateStr) {
            let remoteRows = queryRemoteRows(remotePath, sql: query, params: [startTs, endTs])
            for row in remoteRows {
                guard let tsStr = row[0] as? String else { continue }
                let duration = (row[1] as? Double) ?? 0
                let category = (row[2] as? String) ?? ""
                guard let startDate = formatter.date(from: tsStr) ?? formatterFrac.date(from: String(tsStr.prefix(23))) else { continue }

                let isDeepWork = (category == "deep_work")
                var remaining = duration
                var cursor = startDate
                while remaining > 0 {
                    let slot = slotFormatter.string(from: cursor)
                    let nextHour = cal.nextDate(after: cursor, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .strict, direction: .forward) ?? cursor.addingTimeInterval(3600)
                    let secsUntilNextHour = nextHour.timeIntervalSince(cursor)
                    let chunk = min(remaining, secsUntilNextHour)
                    activeBySlot[slot, default: 0] += chunk
                    if isDeepWork { dwBySlot[slot, default: 0] += chunk }
                    remaining -= chunk
                    cursor = cursor.addingTimeInterval(chunk)
                }
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

        var catMap: [String: Double] = [:]
        for row in try db.prepare(query, [range.start, range.end]) {
            let cat = row[0] as? String ?? "other"
            let min = row[1] as? Double ?? 0
            catMap[cat, default: 0] += min
        }

        // Merge remote
        let dateStr = dateString(for: date)
        for remotePath in findRemoteDbs(startDate: dateStr, endDate: dateStr) {
            for row in queryRemoteRows(remotePath, sql: query, params: [range.start, range.end]) {
                let cat = (row[0] as? String) ?? "other"
                let min = (row[1] as? Double) ?? 0
                catMap[cat, default: 0] += min
            }
        }

        return catMap.map { (category: $0.key, minutes: $0.value) }
            .sorted { $0.minutes > $1.minutes }
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
        """

        // Use map for merging: (appName, category) → minutes
        var appMap: [String: (category: String, minutes: Double)] = [:]
        for row in try db.prepare(query, [range.start, range.end]) {
            let name = row[0] as? String ?? ""
            let cat = row[1] as? String ?? "other"
            let min = row[2] as? Double ?? 0
            appMap[name, default: (category: cat, minutes: 0)].minutes += min
        }

        // Merge remote
        let dateStr = dateString(for: date)
        for remotePath in findRemoteDbs(startDate: dateStr, endDate: dateStr) {
            for row in queryRemoteRows(remotePath, sql: query, params: [range.start, range.end]) {
                let name = (row[0] as? String) ?? ""
                let cat = (row[1] as? String) ?? "other"
                let min = (row[2] as? Double) ?? 0
                appMap[name, default: (category: cat, minutes: 0)].minutes += min
            }
        }

        return appMap.map { (appName: $0.key, category: $0.value.category, minutes: $0.value.minutes) }
            .sorted { $0.minutes > $1.minutes }
            .prefix(limit)
            .map { $0 }
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
            if let event = Self.parseTimelineRow(row, isoFmt: isoFmt, isoFmtNoFrac: isoFmtNoFrac, outputFmt: outputFmt) {
                result.append(event)
            }
        }

        // Merge remote timeline events
        let dateStr = dateString(for: date)
        for remotePath in findRemoteDbs(startDate: dateStr, endDate: dateStr) {
            for row in queryRemoteRows(remotePath, sql: query, params: [range.start, range.end]) {
                if let event = Self.parseTimelineRow(row, isoFmt: isoFmt, isoFmtNoFrac: isoFmtNoFrac, outputFmt: outputFmt) {
                    result.append(event)
                }
            }
        }

        return result.sorted { $0.start < $1.start }
    }

    private static func parseTimelineRow(_ row: [Binding?], isoFmt: ISO8601DateFormatter, isoFmtNoFrac: ISO8601DateFormatter, outputFmt: DateFormatter) -> TimelineEvent? {
        let app = (row[0] as? String) ?? ""
        let tsStr = (row[1] as? String) ?? ""
        let durationS = (row[2] as? Double) ?? 0
        let category = (row[3] as? String) ?? "other"

        guard let startDate = isoFmt.date(from: tsStr) ?? isoFmtNoFrac.date(from: tsStr) ?? parseFlexibleDate(tsStr) else {
            return nil
        }
        let endDate = startDate.addingTimeInterval(durationS)
        let durationMin = durationS / 60.0

        return TimelineEvent(
            app: app,
            start: outputFmt.string(from: startDate),
            end: outputFmt.string(from: endDate),
            category: category,
            durationMin: Double(round(durationMin * 10) / 10)
        )
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

        var dateMap: [String: Double] = [:]
        for row in try db.prepare(query, params) {
            let d = row[0] as? String ?? ""
            let v: Double
            if let dv = row[1] as? Double {
                v = dv
            } else if let iv = row[1] as? Int64 {
                v = Double(iv)
            } else {
                v = 0
            }
            dateMap[d, default: 0] += v
        }

        // Merge remote trends
        let startDateStr = dateString(for: startDate)
        let endDateStr = dateString(for: today)
        for remotePath in findRemoteDbs(startDate: startDateStr, endDate: endDateStr) {
            for row in queryRemoteRows(remotePath, sql: query, params: params) {
                let d = (row[0] as? String) ?? ""
                let v: Double
                if let dv = row[1] as? Double { v = dv }
                else if let iv = row[1] as? Int64 { v = Double(iv) }
                else { v = 0 }
                dateMap[d, default: 0] += v
            }
        }

        return dateMap.sorted { $0.key < $1.key }
            .map { (date: $0.key, value: $0.value) }
    }

    // MARK: - Weekly Heatmap

    func getWeeklyHeatmap() throws -> [(dayOfWeek: Int, hour: Int, count: Int)] {
        let db = try connect()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Last 7 days
        let startDate = cal.date(byAdding: .day, value: -6, to: today)!
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

        var heatMap: [String: Int] = [:]  // "dow-hour" → count
        for row in try db.prepare(query, [startTs, endTs]) {
            let dow = (row[0] as? Int64).map { Int($0) } ?? 0
            let hour = (row[1] as? Int64).map { Int($0) } ?? 0
            let count = (row[2] as? Int64).map { Int($0) } ?? 0
            heatMap["\(dow)-\(hour)", default: 0] += count
        }

        // Merge remote heatmap
        let startDateStr = dateString(for: startDate)
        let endDateStr = dateString(for: today)
        for remotePath in findRemoteDbs(startDate: startDateStr, endDate: endDateStr) {
            for row in queryRemoteRows(remotePath, sql: query, params: [startTs, endTs]) {
                let dow = (row[0] as? Int64).map { Int($0) } ?? 0
                let hour = (row[1] as? Int64).map { Int($0) } ?? 0
                let count = (row[2] as? Int64).map { Int($0) } ?? 0
                heatMap["\(dow)-\(hour)", default: 0] += count
            }
        }

        return heatMap.map { key, count in
            let parts = key.split(separator: "-").map { Int($0) ?? 0 }
            return (dayOfWeek: parts[0], hour: parts[1], count: count)
        }.sorted { ($0.dayOfWeek, $0.hour) < ($1.dayOfWeek, $1.hour) }
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

    // MARK: - AI Sessions (从 ai_sessions / ai_tool_calls 表查询)

    /// 把本地日期的"今天"转换为 UTC ISO 时间窗口 [startUTC, endUTC)，用于过滤 ai_sessions.started_at（UTC ISO 字符串）
    private func dayWindowUTC(for date: Date, daysBack: Int = 0) -> (start: String, end: String) {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: date)
        let startOfWindow = cal.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
        let endOfWindow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? date
        return (Self.isoOutFmt.string(from: startOfWindow), Self.isoOutFmt.string(from: endOfWindow))
    }

    private static let isoOutFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoInFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoInFmtNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let timeOnlyFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func parseISO(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return Self.isoInFmt.date(from: s) ?? Self.isoInFmtNoFrac.date(from: s)
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "claude":   return "Claude Code"
        case "opencode": return "OpenCode"
        case "hermes":   return "Hermes"
        case "openclaw": return "OpenClaw"
        case "codex":    return "Codex"
        default:         return source
        }
    }

    /// "今日"（实际是本地日期 date 当天）的 KPI 聚合
    func getAISessionKPI(for date: Date) throws -> AISessionKPI {
        let db = try connect()
        let (startUTC, endUTC) = dayWindowUTC(for: date)

        // Token 总量 + 项目分布从 ai_token_events 聚合（按消息时间精确归日，跨日 session 不双计）
        var totalIn: Int64 = 0, totalOut: Int64 = 0, totalCache: Int64 = 0
        var projects = Set<String>()
        var projectTokens: [String: Int64] = [:]
        var sessionsByKey = Set<String>()  // (source, session_id) 集合

        for row in try db.prepare("""
            SELECT input_tokens, output_tokens, cache_read_tokens,
                   COALESCE(project, '(unknown)'), source, session_id
            FROM ai_token_events
            WHERE ts_utc >= ? AND ts_utc < ?
            """, startUTC, endUTC) {
            let inT = (row[0] as? Int64) ?? 0
            let outT = (row[1] as? Int64) ?? 0
            let cacheT = (row[2] as? Int64) ?? 0
            let proj = (row[3] as? String) ?? "(unknown)"
            let src = (row[4] as? String) ?? ""
            let sid = (row[5] as? String) ?? ""

            totalIn += inT; totalOut += outT; totalCache += cacheT
            projects.insert(proj)
            projectTokens[proj, default: 0] += (inT + outT + cacheT)
            sessionsByKey.insert("\(src):\(sid)")
        }

        // 消息/工具数从 ai_sessions 取（仅对今天有 token event 的 session 计入）
        var userMsgs = 0, assistantMsgs = 0, toolCalls = 0
        if !sessionsByKey.isEmpty {
            for row in try db.prepare("""
                SELECT source, session_id, user_messages, assistant_turns, tool_calls
                FROM ai_sessions
                WHERE started_at >= ? AND started_at < ?
                """, startUTC, endUTC) {
                let src = (row[0] as? String) ?? ""
                let sid = (row[1] as? String) ?? ""
                guard sessionsByKey.contains("\(src):\(sid)") else { continue }
                userMsgs += Int((row[2] as? Int64) ?? 0)
                assistantMsgs += Int((row[3] as? Int64) ?? 0)
                toolCalls += Int((row[4] as? Int64) ?? 0)
            }
        }

        let topProjects = projectTokens.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
        return AISessionKPI(
            sessions: sessionsByKey.count,
            totalInputTokens: totalIn, totalOutputTokens: totalOut, totalCacheReadTokens: totalCache,
            toolCalls: toolCalls, activeProjects: projects.count,
            userMessages: userMsgs, assistantMessages: assistantMsgs,
            topProjects: topProjects
        )
    }

    /// 按日聚合的趋势（最近 days 天）
    func getAIDailyTrends(for date: Date, days: Int) throws -> [AISessionDailyTrend] {
        let db = try connect()
        let (startUTC, endUTC) = dayWindowUTC(for: date, daysBack: days - 1)

        var byDate: [String: (input: Int64, output: Int64, cache: Int64, sessions: Set<String>)] = [:]
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"; dayFmt.timeZone = .current

        for row in try db.prepare("""
            SELECT ts_utc, input_tokens, output_tokens, cache_read_tokens, source, session_id
            FROM ai_token_events
            WHERE ts_utc >= ? AND ts_utc < ?
            """, startUTC, endUTC) {
            guard let ts = row[0] as? String, let d = parseISO(ts) else { continue }
            let key = dayFmt.string(from: d)
            var b = byDate[key] ?? (0, 0, 0, Set<String>())
            b.input += (row[1] as? Int64) ?? 0
            b.output += (row[2] as? Int64) ?? 0
            b.cache += (row[3] as? Int64) ?? 0
            b.sessions.insert("\((row[4] as? String) ?? ""):\((row[5] as? String) ?? "")")
            byDate[key] = b
        }

        let cal = Calendar.current
        let startDay = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: date)!)
        var trends: [AISessionDailyTrend] = []
        for i in 0..<days {
            let d = cal.date(byAdding: .day, value: i, to: startDay)!
            let key = dayFmt.string(from: d)
            let b = byDate[key] ?? (0, 0, 0, Set<String>())
            trends.append(AISessionDailyTrend(
                date: key,
                inputTokensK: Double(b.input) / 1000.0,
                outputTokensK: Double(b.output) / 1000.0,
                cacheReadTokensK: Double(b.cache) / 1000.0,
                sessions: b.sessions.count, toolCalls: 0
            ))
        }
        return trends
    }

    /// 1 天视图的小时级趋势（本地时间 0~23 时）
    func getAIHourlyTrends(for date: Date) throws -> [AISessionDailyTrend] {
        let db = try connect()
        let (startUTC, endUTC) = dayWindowUTC(for: date)

        var byHour: [Int: (input: Int64, output: Int64, cache: Int64, sessions: Set<String>)] = [:]
        let hourFmt = DateFormatter(); hourFmt.dateFormat = "H"; hourFmt.timeZone = .current

        for row in try db.prepare("""
            SELECT ts_utc, input_tokens, output_tokens, cache_read_tokens, source, session_id
            FROM ai_token_events
            WHERE ts_utc >= ? AND ts_utc < ?
            """, startUTC, endUTC) {
            guard let ts = row[0] as? String, let d = parseISO(ts), let hour = Int(hourFmt.string(from: d)) else { continue }
            var b = byHour[hour] ?? (0, 0, 0, Set<String>())
            b.input += (row[1] as? Int64) ?? 0
            b.output += (row[2] as? Int64) ?? 0
            b.cache += (row[3] as? Int64) ?? 0
            b.sessions.insert("\((row[4] as? String) ?? ""):\((row[5] as? String) ?? "")")
            byHour[hour] = b
        }

        var trends: [AISessionDailyTrend] = []
        for h in 0..<24 {
            let b = byHour[h] ?? (0, 0, 0, Set<String>())
            trends.append(AISessionDailyTrend(
                date: String(format: "%02d:00", h),
                inputTokensK: Double(b.input) / 1000.0,
                outputTokensK: Double(b.output) / 1000.0,
                cacheReadTokensK: Double(b.cache) / 1000.0,
                sessions: b.sessions.count, toolCalls: 0
            ))
        }
        return trends
    }

    /// Top 项目（按 token 总量排序，取最近 days 天）
    func getAIProjectUsage(for date: Date, days: Int) throws -> [AIProjectUsage] {
        let db = try connect()
        let (startUTC, endUTC) = dayWindowUTC(for: date, daysBack: days - 1)
        var byProj: [String: (tokens: Int64, sessions: Set<String>)] = [:]
        for row in try db.prepare("""
            SELECT COALESCE(project, '(unknown)') AS proj,
                   input_tokens + output_tokens + cache_read_tokens AS tokens,
                   source, session_id
            FROM ai_token_events
            WHERE ts_utc >= ? AND ts_utc < ?
            """, startUTC, endUTC) {
            let proj = (row[0] as? String) ?? "(unknown)"
            let tokens = (row[1] as? Int64) ?? 0
            let key = "\((row[2] as? String) ?? ""):\((row[3] as? String) ?? "")"
            var b = byProj[proj] ?? (0, Set<String>())
            b.tokens += tokens
            b.sessions.insert(key)
            byProj[proj] = b
        }
        return byProj
            .map { AIProjectUsage(project: $0.key, tokensK: Double($0.value.tokens) / 1000.0, sessions: $0.value.sessions.count) }
            .sorted { $0.tokensK > $1.tokensK }
    }

    /// 按 AI 工具来源（claude/codex/...）汇总 token，用于"AI 工具占比"饼图
    func getAISourceUsage(for date: Date, days: Int) throws -> [(source: String, totalTokens: Int64, sessions: Int)] {
        let db = try connect()
        let (startUTC, endUTC) = dayWindowUTC(for: date, daysBack: days - 1)
        var bySource: [String: (tokens: Int64, sessions: Set<String>)] = [:]
        for row in try db.prepare("""
            SELECT source,
                   input_tokens + output_tokens + cache_read_tokens AS tokens,
                   session_id
            FROM ai_token_events
            WHERE ts_utc >= ? AND ts_utc < ?
            """, startUTC, endUTC) {
            let src = (row[0] as? String) ?? ""
            let tokens = (row[1] as? Int64) ?? 0
            let sid = (row[2] as? String) ?? ""
            var b = bySource[src] ?? (0, Set<String>())
            b.tokens += tokens
            b.sessions.insert(sid)
            bySource[src] = b
        }
        return bySource
            .map { (sourceLabel($0.key), $0.value.tokens, $0.value.sessions.count) }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Top 工具（按调用次数）— 仅统计当日有 token event 的 session 的工具调用
    func getAIToolUsage(for date: Date, days: Int) throws -> [AIToolUsage] {
        let db = try connect()
        let (startUTC, endUTC) = dayWindowUTC(for: date, daysBack: days - 1)
        var results: [AIToolUsage] = []
        for row in try db.prepare("""
            SELECT t.tool_name, SUM(t.call_count) AS cnt
            FROM ai_tool_calls t
            WHERE EXISTS (
                SELECT 1 FROM ai_token_events e
                WHERE e.source = t.source AND e.session_id = t.session_id
                  AND e.ts_utc >= ? AND e.ts_utc < ?
            )
            GROUP BY t.tool_name
            ORDER BY cnt DESC
            """, startUTC, endUTC) {
            let tool = (row[0] as? String) ?? "?"
            let cnt = Int((row[1] as? Int64) ?? 0)
            results.append(AIToolUsage(tool: tool, count: cnt))
        }
        return results
    }

    /// 当日 session 详情列表（按当日 token 总量降序）
    func getAISessionDetails(for date: Date) throws -> [AISessionDetail] {
        let db = try connect()
        let (startUTC, endUTC) = dayWindowUTC(for: date)
        var results: [AISessionDetail] = []
        for row in try db.prepare("""
            SELECT s.session_id, s.source, COALESCE(s.project, '(unknown)'),
                   COALESCE(s.topic, ''), s.started_at, s.ended_at,
                   SUM(e.input_tokens) AS inp,
                   SUM(e.output_tokens) AS out,
                   SUM(e.cache_read_tokens) AS cache,
                   s.assistant_turns, s.tool_calls, COALESCE(s.model_primary, '')
            FROM ai_token_events e
            JOIN ai_sessions s ON s.source = e.source AND s.session_id = e.session_id
            WHERE e.ts_utc >= ? AND e.ts_utc < ?
            GROUP BY s.source, s.session_id
            ORDER BY (inp + out + cache) DESC
            LIMIT 200
            """, startUTC, endUTC) {
            let sid = (row[0] as? String) ?? ""
            let src = (row[1] as? String) ?? ""
            let proj = (row[2] as? String) ?? "(unknown)"
            let topic = (row[3] as? String) ?? ""
            let startedAt = parseISO(row[4] as? String)
            let endedAt = parseISO(row[5] as? String)
            let inT = (row[6] as? Int64) ?? 0
            let outT = (row[7] as? Int64) ?? 0
            let cacheT = (row[8] as? Int64) ?? 0
            let turns = Int((row[9] as? Int64) ?? 0)
            let toolCalls = Int((row[10] as? Int64) ?? 0)
            let model = (row[11] as? String) ?? ""

            let timeRange: String
            if let s = startedAt, let e = endedAt {
                timeRange = "\(Self.timeOnlyFmt.string(from: s))~\(Self.timeOnlyFmt.string(from: e))"
            } else if let s = startedAt {
                timeRange = Self.timeOnlyFmt.string(from: s)
            } else {
                timeRange = ""
            }

            results.append(AISessionDetail(
                sessionId: sid, project: proj, topic: topic, timeRange: timeRange,
                inputTokens: inT, outputTokens: outT, cacheReadTokens: cacheT,
                totalTokens: inT + outT + cacheT,
                turns: turns, toolCalls: toolCalls, model: model,
                source: sourceLabel(src)
            ))
        }
        return results
    }
}
