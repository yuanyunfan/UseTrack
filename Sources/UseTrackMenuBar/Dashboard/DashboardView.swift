// UseTrack — macOS Activity Tracker
// DashboardView: Dashboard 主视图 + 导航结构
//
// 使用 HStack + List 手动实现侧边栏布局，避免 NavigationSplitView 的自动折叠行为。

import SwiftUI

// MARK: - Dashboard Pages

enum DashboardPage: String, CaseIterable, Identifiable {
    case today = "Today"
    case timeline = "Timeline"
    case trends = "Trends"
    case heatmap = "Heatmap"
    case aiSessions = "AI Sessions"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today: return "chart.bar.fill"
        case .timeline: return "calendar.day.timeline.left"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .heatmap: return "square.grid.3x3.fill"
        case .aiSessions: return "brain.head.profile"
        case .settings: return "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .today: return "今日概览"
        case .timeline: return "时间线"
        case .trends: return "趋势"
        case .heatmap: return "热力图"
        case .aiSessions: return "AI Sessions"
        case .settings: return "设置"
        }
    }
}

// MARK: - Dashboard View

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var selectedPage: DashboardPage = .today

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — fixed width, always visible
            VStack(alignment: .leading, spacing: 0) {
                Text("导航")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                List(DashboardPage.allCases, selection: $selectedPage) { page in
                    Label(page.label, systemImage: page.icon)
                        .tag(page)
                }
                .listStyle(.sidebar)

                Divider()

                // Bottom info
                VStack(alignment: .leading, spacing: 2) {
                    Text("UseTrack v0.1.0")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("DB: \(dbSizeString())")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(width: 180)
            .background(.ultraThinMaterial)

            Divider()

            // Detail — fills remaining space
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selectedPage)  // 切 tab 时强制重建 view，确保 onAppear 触发
        }
        .onChange(of: selectedPage) { page in
            refreshPage(page)
        }
    }

    private func refreshPage(_ page: DashboardPage) {
        switch page {
        case .today:     viewModel.loadToday()
        case .timeline:  viewModel.loadTimeline(for: Date())
        case .trends:    viewModel.loadTrends()
        case .heatmap:   viewModel.loadHeatmap()
        case .aiSessions: viewModel.loadAISessions()
        case .settings:  viewModel.loadSettings()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPage {
        case .today:
            TodayView(viewModel: viewModel)
        case .timeline:
            TimelineView(viewModel: viewModel)
        case .trends:
            TrendsView(viewModel: viewModel)
        case .heatmap:
            HeatmapView(viewModel: viewModel)
        case .aiSessions:
            AISessionsView(viewModel: viewModel)
        case .settings:
            SettingsView(viewModel: viewModel)
        }
    }

    private func dbSizeString() -> String {
        let path = NSString(string: "~/.usetrack/usetrack.db").expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return "N/A" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
