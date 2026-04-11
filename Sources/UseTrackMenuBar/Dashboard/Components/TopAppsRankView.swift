// UseTrack — Dashboard
// TopAppsRankView: Top Apps 排行列表（点击圆点可修改分类）

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
    var onCategoryChange: ((String, String) -> Void)?  // (appName, newCategory)

    var body: some View {
        VStack(alignment: .leading) {
            Text("Top Apps").font(.headline)

            ForEach(apps) { app in
                AppRow(app: app, onCategoryChange: onCategoryChange)
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
}

/// Single app row with clickable category dot
struct AppRow: View {
    let app: AppUsage
    var onCategoryChange: ((String, String) -> Void)?
    @State private var showingPicker = false

    private static let categories = ["deep_work", "communication", "learning", "browsing", "entertainment", "system"]
    private static let categoryLabels: [String: String] = [
        "deep_work": "Deep Work",
        "communication": "Communication",
        "learning": "Learning",
        "browsing": "Browsing",
        "entertainment": "Entertainment",
        "system": "System",
    ]

    var body: some View {
        HStack {
            Text("\(app.rank)")
                .font(.caption).bold()
                .foregroundColor(.secondary)
                .frame(width: 20)

            // Clickable category dot
            Circle()
                .fill(CategoryData.color(for: app.category))
                .frame(width: 10, height: 10)
                .onTapGesture { showingPicker = true }
                .popover(isPresented: $showingPicker, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Self.categories, id: \.self) { cat in
                            Button {
                                onCategoryChange?(app.appName, cat)
                                showingPicker = false
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(CategoryData.color(for: cat))
                                        .frame(width: 8, height: 8)
                                    Text(Self.categoryLabels[cat] ?? cat)
                                        .font(.callout)
                                    if cat == app.category {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(8)
                    .frame(width: 160)
                }

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

    private func formatMinutes(_ min: Double) -> String {
        let h = Int(min) / 60
        let m = Int(min) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
