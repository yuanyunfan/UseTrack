// UseTrack — Dashboard
// TrendsView: 趋势分析页面

import SwiftUI

struct TrendsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var selectedDays = 7

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("时间范围", selection: $selectedDays) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                .onChange(of: selectedDays) { _ in
                    viewModel.loadTrends(days: selectedDays)
                }

                TrendLineChart(title: "深度工作", data: viewModel.deepWorkTrend,
                               color: .green, unit: "分钟")
                    .frame(height: 200)

                HStack(spacing: 16) {
                    TrendLineChart(title: "上下文切换", data: viewModel.switchesTrend,
                                   color: .orange, unit: "次")
                        .frame(height: 180)

                    TrendLineChart(title: "生产力比", data: viewModel.productivityTrend,
                                   color: .blue, unit: "%")
                        .frame(height: 180)
                }
            }
            .padding()
        }
        .navigationTitle("趋势分析")
        .onAppear { viewModel.loadTrends(days: selectedDays) }
    }
}
