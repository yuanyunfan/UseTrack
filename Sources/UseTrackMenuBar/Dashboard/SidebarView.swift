// UseTrack — macOS Activity Tracker
// SidebarView: Dashboard 侧边栏导航
//
// 展示页面列表 + 底部版本和数据库信息。

import SwiftUI

struct SidebarView: View {
    @Binding var selectedPage: DashboardPage
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        List(selection: $selectedPage) {
            Section("导航") {
                ForEach(DashboardPage.allCases) { page in
                    NavigationLink(value: page) {
                        Label(page.label, systemImage: page.icon)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                HStack {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("UseTrack v0.1.0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if viewModel.dbSizeBytes > 0 {
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("DB: \(viewModel.formatBytes(viewModel.dbSizeBytes))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear {
            // Load DB size for sidebar
            viewModel.loadSettings()
        }
    }
}
