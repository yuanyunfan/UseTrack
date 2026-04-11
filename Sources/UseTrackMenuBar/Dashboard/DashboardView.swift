// UseTrack — macOS Activity Tracker
// DashboardView: Dashboard 主视图 + 导航结构
//
// 使用 NavigationSplitView 实现侧边栏 + 详情页布局。

import SwiftUI

// MARK: - Dashboard Pages

enum DashboardPage: String, CaseIterable, Identifiable {
    case today = "Today"
    case timeline = "Timeline"
    case trends = "Trends"
    case heatmap = "Heatmap"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today: return "chart.bar.fill"
        case .timeline: return "calendar.day.timeline.left"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .heatmap: return "square.grid.3x3.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .today: return "今日概览"
        case .timeline: return "时间线"
        case .trends: return "趋势"
        case .heatmap: return "热力图"
        case .settings: return "设置"
        }
    }
}

// MARK: - Dashboard View

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var selectedPage: DashboardPage = .today

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedPage: $selectedPage, viewModel: viewModel)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
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
        case .settings:
            SettingsView(viewModel: viewModel)
        }
    }
}
