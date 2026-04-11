// UseTrack — Dashboard
// TrendLineChart: 趋势折线图（LineMark + AreaMark）

import SwiftUI
import Charts

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: String
    let value: Double
}

struct TrendLineChart: View {
    let title: String
    let data: [TrendPoint]
    let color: Color
    let unit: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)

            if data.isEmpty {
                Text("暂无数据").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(data) { point in
                    LineMark(
                        x: .value("日期", point.date),
                        y: .value(unit, point.value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("日期", point.date),
                        y: .value(unit, point.value)
                    )
                    .foregroundStyle(color.opacity(0.1))
                }
                .chartYAxisLabel(unit)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .cornerRadius(12)
    }
}
