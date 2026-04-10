# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

## [0.1.0] - 2026-04-10

### Added
- **Swift 采集器** — 6 个 Watcher（App/Window/AFK/Input/Git/Obsidian）+ SQLite 写入层
- **注意力归因引擎** — 多屏窗口检测 + 鼠标追踪 + 多信号融合评分（active_focus/active_reference/passive_visible/stale）
- **MCP Server** — FastMCP 7 个 tools（summary/query/focus/search/output/trends/distraction）
- **AI 分析引擎** — 规则+URL+标题启发式活动分类 + 深度工作会话检测 + 核心指标计算
- **Obsidian 报告生成器** — Jinja2 模板每日效率报告（指标表格+能量曲线+干扰分析+AI 建议）
- **干扰模式识别** — 频繁短切换检测 + 低效时段识别 + 干扰源定位
- **Chrome Extension** — Manifest V3 URL 追踪 + Native Messaging
- **Menu Bar UI** — AppKit + SwiftUI 实时状态面板 + 专注模式切换
- **LaunchAgent** — 自动启动 + 崩溃重启 + 安装/卸载脚本
- **SQLite Schema** — 6 张表 + FTS5 全文索引 + 3 个分析视图 + 41 条默认分类规则
- **AI Native Harness** — CLAUDE.md + 进度追踪 + Hooks + 自定义命令 + Git 质量门禁
- 161 个 Python 测试

### Fixed
- top_apps GROUP BY 非聚合列返回任意 category
- energy_curve 无 duration 事件产生异常 0 值
- transitions SQL 假设 ID 连续（改用 LEAD 窗口函数）
- search_activity FTS5 空字符串/非法语法崩溃
- DB 文件不存在时静默创建空库
- Watcher 局部变量被 ARC 释放导致监听失效
- InputWatcher/MouseTracker/DatabaseManager 线程安全竞态
- AppWatcher 启动时首个 App 不记录

### Optimized
- SQL 查询从 `date(ts)` 函数调用改为 `ts >= ? AND ts < ?` 范围查询，命中索引
- GitWatcher output_metrics 多仓库累加而非覆盖
- AttentionScorer lastInteraction 字典定期清理防止无限增长
- ObsidianWatcher 基于 modificationDate 增量检测，避免全量读取
- reporter generate_report 7 次查询改 asyncio.gather 并行
- GitWatcher/ObsidianWatcher 路径改为 CLI 可配置
- 启动时检测 Screen Recording 权限并提示
