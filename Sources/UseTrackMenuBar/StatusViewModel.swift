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
                let (startTs, endTs) = Self.todayRange()

                // Deep work minutes (用范围查询利用 idx_activity_ts 索引)
                let dwQuery = """
                    SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1)
                    FROM activity_stream
                    WHERE ts >= ? AND ts < ? AND category = 'deep_work'
                """
                let dwMin = try db.scalar(dwQuery, [startTs, endTs]) as? Double ?? 0

                // Total active minutes
                let totalQuery = """
                    SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1)
                    FROM activity_stream
                    WHERE ts >= ? AND ts < ? AND activity NOT IN ('idle_start', 'idle_end')
                """
                let totalMin = try db.scalar(totalQuery, [startTs, endTs]) as? Double ?? 0

                // Context switches
                let switchQuery = """
                    SELECT COUNT(*)
                    FROM activity_stream
                    WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
                """
                let switches = try db.scalar(switchQuery, [startTs, endTs]) as? Int64 ?? 0

                // Current app (latest app_switch)
                let currentQuery = """
                    SELECT app_name FROM activity_stream
                    WHERE ts >= ? AND ts < ? AND activity = 'app_switch' AND app_name IS NOT NULL
                    ORDER BY ts DESC LIMIT 1
                """
                var currentAppName = "—"
                for row in try db.prepare(currentQuery, [startTs, endTs]) {
                    currentAppName = row[0] as? String ?? "—"
                }

                // Top 5 apps
                let topQuery = """
                    SELECT app_name, ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as minutes,
                           COALESCE(category, 'other') as category
                    FROM activity_stream
                    WHERE ts >= ? AND ts < ? AND activity = 'app_switch' AND app_name IS NOT NULL
                    GROUP BY app_name ORDER BY minutes DESC LIMIT 5
                """
                var apps: [(String, Double, String)] = []
                for row in try db.prepare(topQuery, [startTs, endTs]) {
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
        // 使用 Shortcuts 自动化切换 macOS Focus (Do Not Disturb)
        // 需要用户先在 Shortcuts.app 创建名为 "UseTrack Focus On" 的快捷指令
        let script = """
        tell application "Shortcuts Events"
            run the shortcut named "UseTrack Focus On"
        end tell
        """
        runAppleScript(script, label: "Enable Focus")
    }

    private func disableFocusMode() {
        // 使用 Shortcuts 关闭 Focus
        // 需要用户先在 Shortcuts.app 创建名为 "UseTrack Focus Off" 的快捷指令
        let script = """
        tell application "Shortcuts Events"
            run the shortcut named "UseTrack Focus Off"
        end tell
        """
        runAppleScript(script, label: "Disable Focus")
    }

    private func runAppleScript(_ source: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: source)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            if let error = error {
                let errorNum = error[NSAppleScript.errorNumber] as? Int ?? 0
                // -1728: Shortcut not found — 用户需要先创建
                if errorNum == -1728 {
                    print("[FocusMode] Shortcut not found. Create 'UseTrack Focus On/Off' in Shortcuts.app")
                } else {
                    print("[FocusMode] \(label) error: \(error)")
                }
            } else {
                print("[FocusMode] \(label) — success")
            }
        }
    }

    // MARK: - Helpers

    /// 返回今天的 ISO8601 时间范围 (startOfDay, startOfNextDay)，用于范围查询利用索引
    static func todayRange() -> (String, String) {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let startOfNextDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return (formatter.string(from: startOfDay), formatter.string(from: startOfNextDay))
    }

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
