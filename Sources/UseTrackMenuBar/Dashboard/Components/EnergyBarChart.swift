// UseTrack — Dashboard
// EnergyBarChart: 最近24小时的深度工作 vs 其他活跃时间柱状图

import SwiftUI
import Charts

struct HourlyEnergy: Identifiable {
    let id = UUID()
    let hour: Int
    let activeMin: Double
    let deepWorkMin: Double

    /// Non-deep-work active time (activeMin - deepWorkMin)
    var otherMin: Double {
        max(activeMin - deepWorkMin, 0)
    }
}

/// Stacked bar data for Charts
struct EnergySegment: Identifiable {
    let id = UUID()
    let hour: String      // Display label like "08:00"
    let category: String  // "深度工作" or "其他活跃"
    let minutes: Double
}

struct EnergyBarChart: View {
    let data: [HourlyEnergy]

    /// Convert HourlyEnergy into stacked segments, preserving the order from data store
    private var segments: [EnergySegment] {
        data.flatMap { item -> [EnergySegment] in
            let hourLabel = "\(String(format: "%02d", item.hour)):00"
            return [
                EnergySegment(hour: hourLabel, category: "其他活跃", minutes: item.otherMin),
                EnergySegment(hour: hourLabel, category: "深度工作", minutes: item.deepWorkMin),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("能量曲线").font(.headline)

            Chart(segments) { seg in
                BarMark(
                    x: .value("时间", seg.hour),
                    y: .value("分钟", seg.minutes),
                    width: .ratio(0.8)
                )
                .foregroundStyle(by: .value("类型", seg.category))
            }
            .chartForegroundStyleScale([
                "深度工作": Color.green,
                "其他活跃": Color.blue.opacity(0.3),
            ])
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            // Show only the hour part "HH" to save space
                            Text(String(label.prefix(2)))
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .chartYAxisLabel("分钟")
            .chartYScale(domain: 0...60)
            .frame(height: 180)
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .cornerRadius(12)
    }
}
