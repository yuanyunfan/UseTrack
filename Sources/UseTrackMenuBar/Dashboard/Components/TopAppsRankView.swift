// UseTrack — Dashboard
// TopAppsRankView: Top Apps 排行列表

import SwiftUI

struct AppUsage: Identifiable {
    let id = UUID()
    let rank: Int
    let appName: String
    let category: String
    let minutes: Double
}

struct TopAppsRankView: View {
    let apps: [AppUsage]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Top Apps").font(.headline)

            ForEach(apps) { app in
                HStack {
                    Text("\(app.rank)")
                        .font(.caption).bold()
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    Circle()
                        .fill(CategoryData.color(for: app.category))
                        .frame(width: 8, height: 8)
                    Text(app.appName)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Text(formatMinutes(app.minutes))
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            if apps.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .cornerRadius(12)
    }

    private func formatMinutes(_ min: Double) -> String {
        let h = Int(min) / 60
        let m = Int(min) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
