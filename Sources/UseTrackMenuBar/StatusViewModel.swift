// UseTrack — macOS Activity Tracker
// StatusViewModel: 从 SQLite 读取今日数据并计算指标

import Foundation
import SQLite

class StatusViewModel: ObservableObject {
    @Published var deepWorkMin: Double = 0
    @Published var totalActiveMin: Double = 0
    @Published var contextSwitches: Int = 0
    @Published var currentApp: String = "—"
    @Published var currentSessionMin: Double = 0
    @Published var productivityRatio: Double = 0
    @Published var isFocusMode: Bool = false
    @Published var topApps: [(name: String, minutes: Double, category: String)] = []

    private let dbPath: String

    init(dbPath: String = NSString(string: "~/.usetrack/usetrack.db").expandingTildeInPath) {
        self.dbPath = dbPath
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let db = try Connection(self.dbPath, readonly: true)
                let today = Self.todayString()

                // Deep work minutes
                let dwQuery = """
                    SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1)
                    FROM activity_stream
                    WHERE date(ts) = ? AND category = 'deep_work'
                """
                let dwMin = try db.scalar(dwQuery, [today]) as? Double ?? 0

                // Total active minutes
                let totalQuery = """
                    SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1)
                    FROM activity_stream
                    WHERE date(ts) = ? AND activity NOT IN ('idle_start', 'idle_end')
                """
                let totalMin = try db.scalar(totalQuery, [today]) as? Double ?? 0

                // Context switches
                let switchQuery = """
                    SELECT COUNT(*)
                    FROM activity_stream
                    WHERE date(ts) = ? AND activity = 'app_switch'
                """
                let switches = try db.scalar(switchQuery, [today]) as? Int64 ?? 0

                // Current app (latest app_switch)
                let currentQuery = """
                    SELECT app_name FROM activity_stream
                    WHERE date(ts) = ? AND activity = 'app_switch' AND app_name IS NOT NULL
                    ORDER BY ts DESC LIMIT 1
                """
                var currentAppName = "—"
                for row in try db.prepare(currentQuery, [today]) {
                    currentAppName = row[0] as? String ?? "—"
                }

                // Top 5 apps
                let topQuery = """
                    SELECT app_name, ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as minutes,
                           COALESCE(category, 'other') as category
                    FROM activity_stream
                    WHERE date(ts) = ? AND activity = 'app_switch' AND app_name IS NOT NULL
                    GROUP BY app_name ORDER BY minutes DESC LIMIT 5
                """
                var apps: [(String, Double, String)] = []
                for row in try db.prepare(topQuery, [today]) {
                    let name = row[0] as? String ?? ""
                    let min = row[1] as? Double ?? 0
                    let cat = row[2] as? String ?? "other"
                    apps.append((name, min, cat))
                }

                DispatchQueue.main.async {
                    self.deepWorkMin = dwMin
                    self.totalActiveMin = totalMin
                    self.contextSwitches = Int(switches)
                    self.currentApp = currentAppName
                    self.productivityRatio = totalMin > 0 ? dwMin / totalMin : 0
                    self.topApps = apps
                }
            } catch {
                print("[MenuBar] DB read error: \(error)")
            }
        }
    }

    // MARK: - Focus Mode

    func toggleFocusMode() {
        isFocusMode.toggle()
        if isFocusMode {
            enableFocusMode()
        } else {
            disableFocusMode()
        }
    }

    private func enableFocusMode() {
        // Placeholder: 真正的 DND 切换需要 Shortcuts 或 private API
        // 目前仅更新 UI 状态和日志
        print("[FocusMode] Enabled — notifications suppressed")
    }

    private func disableFocusMode() {
        print("[FocusMode] Disabled")
    }

    // MARK: - Helpers

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
