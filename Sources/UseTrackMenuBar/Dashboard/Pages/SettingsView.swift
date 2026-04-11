// UseTrack — Dashboard
// SettingsView: App 分类规则设置页面

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var newPattern = ""
    @State private var newCategory = "deep_work"

    let categoryOptions = ["deep_work", "communication", "learning", "browsing", "entertainment", "system"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App 分类规则").font(.headline)

            // 规则列表
            List {
                ForEach(viewModel.appRules) { rule in
                    HStack {
                        Text(CategoryData.emoji(for: rule.category))
                        Text(rule.pattern).font(.body)
                        Spacer()
                        Text(rule.category).font(.caption).foregroundColor(.secondary)
                        Button(role: .destructive) {
                            viewModel.deleteAppRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 300)

            // 添加新规则
            HStack {
                TextField("App 名称", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                Picker("分类", selection: $newCategory) {
                    ForEach(categoryOptions, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                }
                .frame(width: 150)
                Button("添加") {
                    guard !newPattern.isEmpty else { return }
                    viewModel.addAppRule(pattern: newPattern, category: newCategory)
                    newPattern = ""
                }
            }
        }
        .padding()
        .navigationTitle("设置")
        .onAppear { viewModel.loadSettings() }
    }
}
