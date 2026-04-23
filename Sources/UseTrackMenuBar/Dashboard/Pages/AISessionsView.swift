// UseTrack — Dashboard
// AISessionsView: Claude Code AI Session 分析页面
//
// 三个区域:
// ① 顶部 KPI 卡片 (Sessions / Token / Tool 调用 / 活跃项目)
// ② 中部 ECharts 图表 (Token 趋势 + Session 趋势 + 项目排行 + 工具分布)
// ③ 底部 Session 列表 (按 total token 排序, 含 topic)

import SwiftUI

struct AISessionsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var selectedDays = 7

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                kpiCards

                Picker("时间范围", selection: $selectedDays) {
                    Text("1 天").tag(1)
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                .onChange(of: selectedDays) { _ in
                    viewModel.loadAISessions(days: selectedDays)
                }

                EChartsWebView(htmlFileName: "ai-sessions", data: viewModel.aiSessionsChartJSON)
                    .frame(height: 500)
                    .background(.quaternary.opacity(0.3))
                    .cornerRadius(12)

                sessionList
            }
            .padding()
        }
        .navigationTitle("AI Sessions")
        .onAppear { viewModel.loadAISessions(days: selectedDays) }
    }

    // MARK: - KPI Cards

    @ViewBuilder
    private var kpiCards: some View {
        let kpi = viewModel.aiKPI
        let totalTokens = kpi.totalInputTokens + kpi.totalOutputTokens + kpi.totalCacheReadTokens
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
            MetricCardView(
                title: "Sessions",
                value: "\(kpi.sessions)",
                icon: "bubble.left.and.bubble.right",
                color: .blue,
                trend: nil
            )
            MetricCardView(
                title: "Total Token",
                value: formatTokens(totalTokens),
                icon: "number.circle",
                color: .green,
                trend: nil
            )
            MetricCardView(
                title: "Tool 调用",
                value: "\(kpi.toolCalls)",
                icon: "wrench.and.screwdriver",
                color: .orange,
                trend: nil
            )
            MetricCardView(
                title: "活跃项目",
                value: "\(kpi.activeProjects)",
                icon: "folder",
                color: .purple,
                trend: nil
            )
        }
    }

    // MARK: - Session List

    @ViewBuilder
    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日 Sessions").font(.headline)

            if viewModel.aiSessionDetails.isEmpty {
                Text("暂无 Session 数据")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("时间").frame(width: 100, alignment: .leading)
                    Text("项目").frame(width: 110, alignment: .leading)
                    Text("Topic").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input").frame(width: 70, alignment: .trailing)
                    Text("Output").frame(width: 60, alignment: .trailing)
                    Text("Cache").frame(width: 70, alignment: .trailing)
                    Text("Total").frame(width: 70, alignment: .trailing)
                    Text("Turns").frame(width: 45, alignment: .trailing)
                    Text("模型").frame(width: 55, alignment: .trailing)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)

                Divider()

                ForEach(Array(viewModel.aiSessionDetails.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 0) {
                        Text(s.timeRange)
                            .frame(width: 100, alignment: .leading)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)

                        Text(s.project)
                            .frame(width: 110, alignment: .leading)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Text(s.topic)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Text(formatTokens(s.inputTokens))
                            .frame(width: 70, alignment: .trailing)
                            .font(.caption.monospacedDigit())

                        Text(formatTokens(s.outputTokens))
                            .frame(width: 60, alignment: .trailing)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)

                        Text(formatTokens(s.cacheReadTokens))
                            .frame(width: 70, alignment: .trailing)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)

                        Text(formatTokens(s.totalTokens))
                            .frame(width: 70, alignment: .trailing)
                            .font(.caption.monospacedDigit().weight(.semibold))

                        Text("\(s.turns)")
                            .frame(width: 45, alignment: .trailing)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)

                        Text(s.model)
                            .frame(width: 55, alignment: .trailing)
                            .font(.caption2)
                            .foregroundColor(modelColor(s.model))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }

                // Total row
                let totals = viewModel.aiSessionDetails
                Divider()
                HStack(spacing: 0) {
                    Text("合计").frame(width: 100, alignment: .leading).font(.caption.weight(.semibold))
                    Text("\(totals.count) sessions").frame(width: 110, alignment: .leading).font(.caption)
                    Spacer()
                    Text(formatTokens(totals.reduce(0) { $0 + $1.inputTokens }))
                        .frame(width: 70, alignment: .trailing)
                    Text(formatTokens(totals.reduce(0) { $0 + $1.outputTokens }))
                        .frame(width: 60, alignment: .trailing)
                    Text(formatTokens(totals.reduce(0) { $0 + $1.cacheReadTokens }))
                        .frame(width: 70, alignment: .trailing)
                    Text(formatTokens(totals.reduce(0) { $0 + $1.totalTokens }))
                        .frame(width: 70, alignment: .trailing).font(.caption.weight(.bold))
                    Text("\(totals.reduce(0) { $0 + $1.turns })")
                        .frame(width: 45, alignment: .trailing)
                    Text("").frame(width: 55)
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func formatTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    private func modelColor(_ model: String) -> Color {
        switch model {
        case "opus": return .purple
        case "sonnet": return .blue
        case "haiku": return .green
        default: return .secondary
        }
    }
}
