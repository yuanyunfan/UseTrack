// UseTrack — Dashboard
// TodayView: 今日概览页面

import SwiftUI

struct TodayView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 4 个指标卡片
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    MetricCardView(title: "深度工作",
                                   value: viewModel.formatMinutes(viewModel.todayMetrics.deepWorkMin),
                                   icon: "brain.head.profile", color: .green, trend: nil)
                    MetricCardView(title: "活跃时间",
                                   value: viewModel.formatMinutes(viewModel.todayMetrics.activeMin),
                                   icon: "clock", color: .blue, trend: nil)
                    MetricCardView(title: "上下文切换",
                                   value: "\(viewModel.todayMetrics.contextSwitches)",
                                   icon: "arrow.triangle.swap",
                                   color: viewModel.todayMetrics.contextSwitches > 100 ? .red : .orange,
                                   trend: nil)
                    MetricCardView(title: "生产力比",
                                   value: "\(Int(viewModel.todayMetrics.productivityRatio * 100))%",
                                   icon: "chart.bar.fill",
                                   color: viewModel.todayMetrics.productivityRatio > 0.5 ? .green : .orange,
                                   trend: nil)
                }

                // 能量柱图
                EnergyBarChart(data: viewModel.energyCurve)

                // 底部两列
                HStack(alignment: .top, spacing: 16) {
                    CategoryPieChart(data: viewModel.categories)
                    TopAppsRankView(apps: viewModel.topApps) { appName, newCategory in
                        viewModel.changeAppCategory(appName: appName, category: newCategory)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("今日概览")
    }
}
