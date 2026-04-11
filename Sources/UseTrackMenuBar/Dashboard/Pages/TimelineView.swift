// UseTrack — Dashboard
// TimelineView: 时间线页面（ECharts 渲染）

import SwiftUI

struct TimelineView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var selectedDate = Date()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("时间线").font(.headline)
                Spacer()
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .frame(width: 150)
                    .onChange(of: selectedDate) { _ in
                        viewModel.loadTimeline(for: selectedDate)
                    }
            }
            .padding(.horizontal)

            EChartsWebView(htmlFileName: "timeline", data: viewModel.timelineJSON)
        }
        .padding(.top)
        .navigationTitle("时间线")
        .onAppear { viewModel.loadTimeline(for: selectedDate) }
    }
}
