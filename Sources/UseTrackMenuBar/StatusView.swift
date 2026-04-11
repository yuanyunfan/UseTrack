// UseTrack — macOS Activity Tracker
// StatusView: Menu Bar Popover 的 SwiftUI 界面

import SwiftUI

struct StatusView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("UseTrack")
                    .font(.headline)
                Spacer()
                // Focus mode toggle
                Toggle(isOn: Binding(
                    get: { viewModel.isFocusMode },
                    set: { _ in viewModel.toggleFocusMode() }
                )) {
                    Image(systemName: viewModel.isFocusMode ? "moon.fill" : "moon")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider()

            // Key metrics
            HStack(spacing: 16) {
                MetricCard(
                    title: "深度工作",
                    value: formatMinutes(viewModel.deepWorkMin),
                    icon: "brain.head.profile",
                    color: .green
                )
                MetricCard(
                    title: "活跃时长",
                    value: formatMinutes(viewModel.totalActiveMin),
                    icon: "clock",
                    color: .blue
                )
                MetricCard(
                    title: "切换",
                    value: "\(viewModel.contextSwitches)",
                    icon: "arrow.triangle.swap",
                    color: viewModel.contextSwitches > 100 ? .red : .orange
                )
            }

            // Productivity bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("生产力")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(viewModel.productivityRatio * 100))%")
                        .font(.caption.bold())
                }
                ProgressView(value: viewModel.productivityRatio)
                    .tint(viewModel.productivityRatio > 0.5 ? .green : .orange)
            }

            Divider()

            // Top apps
            Text("今日 Top Apps")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(Array(viewModel.topApps.enumerated()), id: \.offset) { _, app in
                HStack {
                    Circle()
                        .fill(categoryColor(app.category))
                        .frame(width: 8, height: 8)
                    Text(app.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(formatMinutes(app.minutes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Dashboard button
            Button {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            } label: {
                HStack {
                    Image(systemName: "chart.bar.fill")
                    Text("打开 Dashboard")
                }
            }
            .font(.caption)

            // Quit button
            Button("退出 UseTrack") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding()
        .frame(width: 300)
    }

    func formatMinutes(_ min: Double) -> String {
        let h = Int(min) / 60
        let m = Int(min) % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    func categoryColor(_ category: String) -> Color {
        switch category {
        case "deep_work": return .green
        case "communication": return .blue
        case "learning": return .yellow
        case "browsing": return .orange
        case "entertainment": return .red
        default: return .gray
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
            Text(value)
                .font(.system(.body, design: .rounded).bold())
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
