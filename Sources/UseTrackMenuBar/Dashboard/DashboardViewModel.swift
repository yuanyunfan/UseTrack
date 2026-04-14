// UseTrack — macOS Activity Tracker
// DashboardViewModel: Dashboard 全局 ViewModel
//
// 管理 Dashboard 所有页面的数据状态，异步从 DashboardDataStore 加载。

import Foundation
import SwiftUI

class DashboardViewModel: ObservableObject {
    private let store = DashboardDataStore()

    // MARK: - Today Page

    @Published var todayMetrics = TodayMetrics(
        deepWorkMin: 0, activeMin: 0, contextSwitches: 0,
        pingPongSwitches: 0, productivityRatio: 0
    )
    @Published var energyCurve: [HourlyEnergy] = []
    @Published var categories: [CategoryData] = []
    @Published var topApps: [AppUsage] = []

    // MARK: - Timeline Page

    @Published var timelineJSON: String = "[]"

    // MARK: - Trends Page

    @Published var deepWorkTrend: [TrendPoint] = []
    @Published var switchesTrend: [TrendPoint] = []
    @Published var activeTimeTrend: [TrendPoint] = []
    @Published var productivityTrend: [TrendPoint] = []

    // MARK: - Heatmap Page

    @Published var heatmapJSON: String = "{\"data\":[], \"max\":0}"

    // MARK: - Settings Page

    @Published var appRules: [AppRule] = []
    @Published var dbSizeBytes: Int64 = 0

    // MARK: - State

    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    // MARK: - Refresh All

    func refresh() {
        loadToday()
    }

    // MARK: - Today

    func loadToday() {
        let date = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let metrics = try self.store.getTodayMetrics(for: date)
                let energy = try self.store.getEnergyCurve(for: date)
                let cats = try self.store.getCategoryBreakdown(for: date)
                let apps = try self.store.getTopApps(for: date, limit: 10)

                // Convert tuples to model types
                let energyModels = energy.map {
                    HourlyEnergy(hour: $0.hour, activeMin: $0.activeMin, deepWorkMin: $0.deepWorkMin)
                }
                let catModels = cats.map {
                    CategoryData(
                        category: $0.category,
                        minutes: $0.minutes,
                        color: CategoryData.color(for: $0.category)
                    )
                }
                let appModels = apps.enumerated().map { (idx, app) in
                    AppUsage(rank: idx + 1, appName: app.appName, category: app.category, minutes: app.minutes)
                }

                DispatchQueue.main.async {
                    self.todayMetrics = metrics
                    self.energyCurve = energyModels
                    self.categories = catModels
                    self.topApps = appModels
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Failed to load today data: \(error.localizedDescription)"
                }
                print("[Dashboard] loadToday error: \(error)")
            }
        }
    }

    // MARK: - Timeline

    func loadTimeline(for date: Date) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let events = try self.store.getTimelineEvents(for: date)
                let dictArray: [[String: Any]] = events.map { e in
                    [
                        "app": e.app,
                        "start": e.start,
                        "end": e.end,
                        "category": e.category,
                        "duration_min": e.durationMin
                    ]
                }
                let jsonData = try JSONSerialization.data(withJSONObject: dictArray, options: [])
                let json = String(data: jsonData, encoding: .utf8) ?? "[]"

                DispatchQueue.main.async {
                    self.timelineJSON = json
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Failed to load timeline: \(error.localizedDescription)"
                }
                print("[Dashboard] loadTimeline error: \(error)")
            }
        }
    }

    // MARK: - Trends

    func loadTrends(days: Int = 14) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let dw = try self.store.getTrends(metric: "deep_work", days: days)
                let sw = try self.store.getTrends(metric: "context_switches", days: days)
                let at = try self.store.getTrends(metric: "active_time", days: days)
                let pr = try self.store.getTrends(metric: "productivity", days: days)

                // Convert tuples to TrendPoint
                let dwPoints = dw.map { TrendPoint(date: $0.date, value: $0.value) }
                let swPoints = sw.map { TrendPoint(date: $0.date, value: $0.value) }
                let atPoints = at.map { TrendPoint(date: $0.date, value: $0.value) }
                let prPoints = pr.map { TrendPoint(date: $0.date, value: $0.value) }

                DispatchQueue.main.async {
                    self.deepWorkTrend = dwPoints
                    self.switchesTrend = swPoints
                    self.activeTimeTrend = atPoints
                    self.productivityTrend = prPoints
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Failed to load trends: \(error.localizedDescription)"
                }
                print("[Dashboard] loadTrends error: \(error)")
            }
        }
    }

    // MARK: - Heatmap

    func loadHeatmap() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try self.store.getWeeklyHeatmap()
                let maxCount = data.map { $0.count }.max() ?? 0
                let dataArray = data.map { "[\($0.dayOfWeek),\($0.hour),\($0.count)]" }
                let json = "{\"data\":[\(dataArray.joined(separator: ","))],\"max\":\(maxCount)}"

                DispatchQueue.main.async {
                    self.heatmapJSON = json
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Failed to load heatmap: \(error.localizedDescription)"
                }
                print("[Dashboard] loadHeatmap error: \(error)")
            }
        }
    }

    // MARK: - Settings

    func loadSettings() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let rules = try self.store.getAppRules()
                let size = try self.store.getDatabaseSize()

                DispatchQueue.main.async {
                    self.appRules = rules
                    self.dbSizeBytes = size
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Failed to load settings: \(error.localizedDescription)"
                }
                print("[Dashboard] loadSettings error: \(error)")
            }
        }
    }

    func addAppRule(pattern: String, category: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.store.addAppRule(pattern: pattern, category: category)
                self.loadSettings()
                self.loadToday()  // Refresh dashboard after category change
            } catch {
                print("[Dashboard] addAppRule error: \(error)")
            }
        }
    }

    /// Change category for an app (from Top Apps dot click) — creates/updates rule + backfills history
    func changeAppCategory(appName: String, category: String) {
        addAppRule(pattern: appName, category: category)
    }

    func deleteAppRule(id: Int64) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.store.deleteAppRule(id: id)
                self.loadSettings()
            } catch {
                print("[Dashboard] deleteAppRule error: \(error)")
            }
        }
    }

    func updateAppRuleCategory(id: Int64, category: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.store.updateAppRuleCategory(id: id, category: category)
                self.loadSettings()
                self.loadToday()  // Refresh dashboard after category change
            } catch {
                print("[Dashboard] updateAppRuleCategory error: \(error)")
            }
        }
    }

    // MARK: - Formatting Helpers

    func formatMinutes(_ min: Double) -> String {
        let h = Int(min) / 60
        let m = Int(min) % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}
