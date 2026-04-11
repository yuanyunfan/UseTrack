// UseTrack — Dashboard
// EnergyBarChart: 每小时的深度工作 vs 活跃时间柱状图

import SwiftUI
import Charts

struct HourlyEnergy: Identifiable {
    let id = UUID()
    let hour: Int
    let activeMin: Double
    let deepWorkMin: Double
}

struct EnergyBarChart: View {
    let data: [HourlyEnergy]

    var body: some View {
        VStack(alignment: .leading) {
            Text("能量曲线").font(.headline)

            Chart(data) { item in
                BarMark(
                    x: .value("时间", "\(String(format: "%02d", item.hour)):00"),
                    y: .value("活跃", item.activeMin)
                )
                .foregroundStyle(.blue.opacity(0.3))

                BarMark(
                    x: .value("时间", "\(String(format: "%02d", item.hour)):00"),
                    y: .value("深度工作", item.deepWorkMin)
                )
                .foregroundStyle(.green)
            }
            .chartYAxisLabel("分钟")
            .frame(height: 180)
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .cornerRadius(12)
    }
}
