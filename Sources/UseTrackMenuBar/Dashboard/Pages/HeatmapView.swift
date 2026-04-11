// UseTrack — Dashboard
// HeatmapView: 活动热力图页面（ECharts 渲染）

import SwiftUI

struct HeatmapView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack {
            Text("过去 7 天活动热力图").font(.headline).padding()
            EChartsWebView(htmlFileName: "heatmap", data: viewModel.heatmapJSON)
        }
        .navigationTitle("活动热力图")
        .onAppear { viewModel.loadHeatmap() }
    }
}
