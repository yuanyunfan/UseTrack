// UseTrack — Dashboard
// SettingsView: App 分类规则设置页面

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var appearance = AppearanceManager.shared
    @State private var newPattern = ""
    @State private var newCategory = "deep_work"

    static let categoryOptions = ["deep_work", "communication", "learning", "browsing", "entertainment", "system"]

    static let categoryLabels: [String: String] = [
        "deep_work": "Deep Work",
        "communication": "Communication",
        "learning": "Learning",
        "browsing": "Browsing",
        "entertainment": "Entertainment",
        "system": "System",
    ]

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            // 外观设置
            Text("外观").font(.headline)

            HStack(spacing: 12) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button {
                        appearance.mode = mode
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: mode.icon)
                                .font(.title2)
                            Text(mode.label)
                                .font(.caption)
                        }
                        .frame(width: 80, height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(appearance.mode == mode
                                      ? Color.accentColor.opacity(0.15)
                                      : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(appearance.mode == mode
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)

            Divider()

            Text("App 分类规则").font(.headline)

            // 规则列表
            List {
                ForEach(viewModel.appRules) { rule in
                    HStack {
                        Circle()
                            .fill(CategoryData.color(for: rule.category))
                            .frame(width: 8, height: 8)

                        Text(rule.pattern)
                            .font(.body)
                            .frame(minWidth: 120, alignment: .leading)

                        Spacer()

                        // Category picker
                        Picker("", selection: Binding(
                            get: { rule.category },
                            set: { newCat in
                                viewModel.updateAppRuleCategory(id: rule.id, category: newCat)
                            }
                        )) {
                            ForEach(Self.categoryOptions, id: \.self) { cat in
                                Text(Self.categoryLabels[cat] ?? cat).tag(cat)
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
                        Text(Self.categoryLabels[cat] ?? cat).tag(cat)
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
        }
        .navigationTitle("设置")
        .onAppear { viewModel.loadSettings() }
    }
}
