// UseTrack — Dashboard
// SettingsView: App 分类规则设置页面

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var newPattern = ""
    @State private var newCategory = "deep_work"

    static let categoryOptions = ["deep_work", "communication", "learning", "browsing", "entertainment", "system"]

    static let categoryEmoji: [String: String] = [
        "deep_work": "🟢",
        "communication": "🔵",
        "learning": "🟡",
        "browsing": "🟠",
        "entertainment": "🔴",
        "system": "⚪",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App 分类规则").font(.headline)

            // 规则列表
            List {
                ForEach(viewModel.appRules) { rule in
                    HStack {
                        Text(Self.categoryEmoji[rule.category] ?? "⚪")
                            .frame(width: 20)

                        Text(rule.pattern)
                            .font(.body)
                            .frame(minWidth: 120, alignment: .leading)

                        Spacer()

                        // Category picker (editable)
                        Picker("", selection: Binding(
                            get: { rule.category },
                            set: { newCat in
                                viewModel.updateAppRuleCategory(id: rule.id, category: newCat)
                            }
                        )) {
                            ForEach(Self.categoryOptions, id: \.self) { cat in
                                HStack {
                                    Text(Self.categoryEmoji[cat] ?? "⚪")
                                    Text(cat)
                                }
                                .tag(cat)
                            }
                        }
                        .frame(width: 160)

                        Button(role: .destructive) {
                            viewModel.deleteAppRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.7))
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

                Picker("", selection: $newCategory) {
                    ForEach(Self.categoryOptions, id: \.self) { cat in
                        HStack {
                            Text(Self.categoryEmoji[cat] ?? "⚪")
                            Text(cat)
                        }
                        .tag(cat)
                    }
                }
                .frame(width: 160)

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
