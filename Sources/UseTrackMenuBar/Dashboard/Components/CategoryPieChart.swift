// UseTrack — Dashboard
// CategoryPieChart: 分类时间分布饼图 + 图例

import SwiftUI
import Charts

struct CategoryData: Identifiable {
    let id = UUID()
    let category: String
    let minutes: Double
    let color: Color

    static func color(for category: String) -> Color {
        switch category {
        case "deep_work": return .green
        case "communication": return .blue
        case "learning": return .yellow
        case "browsing": return .orange
        case "entertainment": return .red
        case "system": return .gray
        default: return .secondary
        }
    }

    static func emoji(for category: String) -> String {
        switch category {
        case "deep_work": return "🟢"
        case "communication": return "🔵"
        case "learning": return "🟡"
        case "browsing": return "🟠"
        case "entertainment": return "🔴"
        case "system": return "⚪"
        default: return "⚪"
        }
    }
}

struct CategoryPieChart: View {
    let data: [CategoryData]

    var body: some View {
        VStack(alignment: .leading) {
            Text("分类时间分布").font(.headline)

            if #available(macOS 14.0, *) {
                Chart(data) { item in
                    SectorMark(
                        angle: .value("时间", item.minutes),
                        innerRadius: .ratio(0.5),
                        angularInset: 1.5
                    )
                    .foregroundStyle(item.color)
                }
                .frame(height: 200)
            }

            // Legend (always show)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(data) { item in
                    HStack {
                        Circle().fill(item.color).frame(width: 8, height: 8)
                        Text(item.category).font(.caption)
                        Spacer()
                        Text("\(Int(item.minutes))m").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .cornerRadius(12)
    }
}
