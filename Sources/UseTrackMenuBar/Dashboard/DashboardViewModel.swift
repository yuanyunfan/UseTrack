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

    // MARK: - AI Sessions Page

    private let claudeStore = ClaudeSessionStore()
    private let openCodeStore = OpenCodeSessionStore()
    private let hermesStore = HermesSessionStore()
    private let openClawStore = OpenClawSessionStore()
    @Published var aiKPI = AISessionKPI(
        sessions: 0, totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
        toolCalls: 0, activeProjects: 0, userMessages: 0, assistantMessages: 0, topProjects: []
    )
    @Published var aiSessionsChartJSON: String = "{}"
    @Published var aiSessionDetails: [AISessionDetail] = []

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
                // Today's dayOfWeek: 0=Mon...6=Sun
                let weekday = Calendar.current.component(.weekday, from: Date()) // 1=Sun...7=Sat
                let todayDow = (weekday + 5) % 7 // Convert to 0=Mon...6=Sun
                let json = "{\"data\":[\(dataArray.joined(separator: ","))],\"max\":\(maxCount),\"todayDow\":\(todayDow)}"

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

    // MARK: - AI Sessions

    // MARK: - KPI Aggregation Helpers

    private func mergeKPIs(_ kpis: [AISessionKPI]) -> AISessionKPI {
        var sessions = 0, toolCalls = 0, activeProjects = 0, userMsgs = 0, assistantMsgs = 0
        var totalInput: Int64 = 0, totalOutput: Int64 = 0, totalCache: Int64 = 0
        var allProjects: [String] = []

        for k in kpis {
            sessions += k.sessions
            totalInput += k.totalInputTokens
            totalOutput += k.totalOutputTokens
            totalCache += k.totalCacheReadTokens
            toolCalls += k.toolCalls
            activeProjects += k.activeProjects
            userMsgs += k.userMessages
            assistantMsgs += k.assistantMessages
            allProjects.append(contentsOf: k.topProjects)
        }

        return AISessionKPI(
            sessions: sessions,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput, totalCacheReadTokens: totalCache,
            toolCalls: toolCalls, activeProjects: activeProjects,
            userMessages: userMsgs, assistantMessages: assistantMsgs,
            topProjects: Array(allProjects.prefix(3))
        )
    }

    private func mergeTrends(_ trendArrays: [[AISessionDailyTrend]]) -> [AISessionDailyTrend] {
        var byDate: [String: AISessionDailyTrend] = [:]

        for trends in trendArrays {
            for t in trends {
                if let existing = byDate[t.date] {
                    byDate[t.date] = AISessionDailyTrend(
                        date: t.date,
                        inputTokensK: existing.inputTokensK + t.inputTokensK,
                        outputTokensK: existing.outputTokensK + t.outputTokensK,
                        cacheReadTokensK: existing.cacheReadTokensK + t.cacheReadTokensK,
                        sessions: existing.sessions + t.sessions,
                        toolCalls: existing.toolCalls + t.toolCalls
                    )
                } else {
                    byDate[t.date] = t
                }
            }
        }

        return byDate.values.sorted { $0.date < $1.date }
    }

    func loadAISessions(days: Int = 7) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let todayStr = dateFormatter.string(from: Date())

            // Gather from all sources
            let claudeKPI = self.claudeStore.getTodayKPI(for: todayStr)
            let openCodeKPI = self.openCodeStore.getTodayKPI(for: todayStr)
            let hermesKPI = self.hermesStore.getTodayKPI(for: todayStr)
            let openClawKPI = self.openClawStore.getTodayKPI(for: todayStr)
            let kpi = self.mergeKPIs([claudeKPI, openCodeKPI, hermesKPI, openClawKPI])

            let trends: [AISessionDailyTrend]
            if days == 1 {
                trends = self.mergeTrends([
                    self.claudeStore.getHourlyTrends(),
                    self.openCodeStore.getHourlyTrends(),
                    self.hermesStore.getHourlyTrends(),
                    self.openClawStore.getHourlyTrends()
                ])
            } else {
                trends = self.mergeTrends([
                    self.claudeStore.getDailyTrends(days: days),
                    self.openCodeStore.getDailyTrends(days: days),
                    self.hermesStore.getDailyTrends(days: days),
                    self.openClawStore.getDailyTrends(days: days)
                ])
            }

            let projects = self.claudeStore.getProjectUsage(days: days)
            let tools = self.claudeStore.getToolUsage(days: days)

            var details = self.claudeStore.getSessionDetails(for: todayStr)
            details.append(contentsOf: self.openCodeStore.getSessionDetails(for: todayStr))
            details.append(contentsOf: self.hermesStore.getSessionDetails(for: todayStr))
            details.append(contentsOf: self.openClawStore.getSessionDetails(for: todayStr))
            details.sort { $0.totalTokens > $1.totalTokens }

            // Build chart JSON
            let trendsJSON = trends.map {
                "{\"date\":\"\($0.date)\",\"inputK\":\($0.inputTokensK),\"outputK\":\($0.outputTokensK),\"cacheK\":\($0.cacheReadTokensK),\"sessions\":\($0.sessions),\"tools\":\($0.toolCalls)}"
            }.joined(separator: ",")

            let projectsJSON = projects.prefix(10).map {
                let name = $0.project.replacingOccurrences(of: "\"", with: "\\\"")
                return "{\"name\":\"\(name)\",\"tokensK\":\($0.tokensK)}"
            }.joined(separator: ",")

            let toolsJSON = tools.prefix(10).map {
                let name = $0.tool.replacingOccurrences(of: "\"", with: "\\\"")
                return "{\"name\":\"\(name)\",\"count\":\($0.count)}"
            }.joined(separator: ",")

            let chartJSON = "{\"trends\":[\(trendsJSON)],\"projects\":[\(projectsJSON)],\"tools\":[\(toolsJSON)]}"

            DispatchQueue.main.async {
                self.aiKPI = kpi
                self.aiSessionsChartJSON = chartJSON
                self.aiSessionDetails = details
                self.lastError = nil
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
