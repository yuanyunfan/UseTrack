// UseTrack — Dashboard
// MetricCardView: 单个指标卡片（图标 + 数值 + 标题 + 趋势箭头）

import SwiftUI

struct MetricCardView: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let trend: String?  // "↑ 15%", "↓ 8%", "→", nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title2)
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            if let trend = trend {
                Text(trend)
                    .font(.caption2)
                    .foregroundColor(trend.contains("↑") ? .green : trend.contains("↓") ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.5))
        .cornerRadius(12)
    }
}
