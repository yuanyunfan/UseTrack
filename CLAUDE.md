# CLAUDE.md — UseTrack

## Project Overview

UseTrack 是一个 macOS 本地化的个人电脑使用监控系统。Swift 后台守护进程采集 App 切换、窗口标题、浏览器 URL、输入活跃度等数据，存入 SQLite；Python MCP Server 暴露数据给 Claude 等 LLM 做效率分析；AI 自动生成每日 Obsidian 效率报告。

核心架构：Swift 采集器（LaunchAgent）→ SQLite → Python MCP Server → Claude/LLM

## Tech Stack

- **Swift 5.10+** — 后台采集守护进程 + Menu Bar UI（SwiftUI/AppKit）
- **Python 3.12+** — MCP Server (FastMCP) + AI 分析 + 报告生成
- **SQLite 3** — 共享数据库（Swift 写入，Python 读取）
- **uv** — Python 包管理
- **Swift Package Manager** — Swift 依赖管理
- **pytest + pytest-asyncio** — Python 测试
- **XCTest** — Swift 测试

## Commands

```bash
# Swift (采集器)
swift build                    # Build collector
swift test                     # Run Swift tests
swift run UseTrackCollector    # Run collector locally

# Python (MCP Server + AI)
uv sync                       # Install Python dependencies
uv run pytest                  # Run Python tests
uv run usetrack-mcp            # Start MCP server
uv run usetrack-report         # Generate daily report

# 项目初始化
./init.sh                      # Full environment init
```

## Session Workflow (MANDATORY)

> **IMPORTANT**: 以下步骤是强制性的。每次 session 必须执行，不可跳过。

### Session 开始时 — 必须立即执行：
1. **读取 `claude-progress.txt`** — 了解上次进度、当前状态、已知问题
2. **读取 `feature_list.json`** — 确认下一个 `"passes": false` 的 feature
3. **简要汇报给用户**: "上次进度: XXX，本次计划做: YYY"

### 每完成一个 feature 时：
4. **更新 `feature_list.json`** — passes 改为 true
5. **更新 phase status** — 如该 phase 所有 feature 都 passes，status 改为 "done"
6. **更新 summary** — 重新计算 done/remaining/progress_pct

### Session 结束前 — 必须执行：
7. **更新 `claude-progress.txt`** — 记录完成内容、下一步、遇到的问题
8. **更新 `CHANGELOG.md`** — 如有显著功能完成

## Testing

- **Swift**: `XCTest` — `Tests/UseTrackCollectorTests/`，文件名 `*Tests.swift`
- **Python**: `pytest` + `pytest-asyncio` — `tests/`，文件名 `test_*.py`
- 覆盖率目标：核心逻辑 80%+

## Project Structure

```
UseTrack/
├── Package.swift                  # Swift package manifest
├── Sources/
│   ├── UseTrackCollector/         # Swift 后台采集守护进程
│   │   ├── UseTrackCollector.swift # Entry point (@main + ArgumentParser)
│   │   ├── Watchers/
│   │   │   ├── AppWatcher.swift   # NSWorkspace App 切换监听
│   │   │   ├── WindowWatcher.swift # CGWindowList 窗口标题轮询
│   │   │   ├── AFKWatcher.swift   # CGEventSource 空闲检测
│   │   │   ├── InputWatcher.swift # 击键/点击/滚动频率统计
│   │   │   ├── GitWatcher.swift   # Git 仓库 commit 扫描
│   │   │   └── ObsidianWatcher.swift # Obsidian vault 字数监听
│   │   ├── Models/
│   │   │   ├── ActivityEvent.swift
│   │   │   ├── AttentionState.swift
│   │   │   └── WindowSnapshot.swift
│   │   ├── Storage/
│   │   │   └── DatabaseManager.swift # SQLite 写入层 (线程安全)
│   │   └── Attention/
│   │       ├── AttentionScorer.swift  # 多信号融合注意力评分
│   │       ├── ScreenDetector.swift   # 多屏窗口位置检测
│   │       └── MouseTracker.swift     # 鼠标追踪 (线程安全)
│   └── UseTrackMenuBar/           # SwiftUI Menu Bar App
│       ├── main.swift             # AppKit + NSPopover 入口
│       ├── StatusViewModel.swift  # 数据查询 + 状态管理
│       └── StatusView.swift       # SwiftUI 界面
├── Tests/
│   └── UseTrackCollectorTests/
├── python/                        # Python 子项目
│   ├── pyproject.toml
│   ├── src/usetrack/
│   │   ├── mcp_server.py          # FastMCP Server (7 tools)
│   │   ├── db.py                  # SQLite 异步读取层
│   │   ├── analyzer.py            # 活动分类 + 指标计算
│   │   ├── reporter.py            # Obsidian 报告生成 + 干扰分析
│   │   └── models.py              # Pydantic 数据模型
│   └── tests/                     # 161 个 Python 测试
├── browser-extension/             # Chrome Extension (Manifest V3)
│   ├── manifest.json
│   └── background.js              # URL 追踪 + Native Messaging
├── db/schema.sql                  # SQLite schema (6 表 + FTS5 + 3 视图)
├── config/
│   ├── com.usetrack.collector.plist # LaunchAgent 配置
│   └── install.sh                 # 安装/卸载脚本
└── init.sh                        # 环境初始化
```

## Architecture Decisions

| 决策 | 选择 | 原因 |
|------|------|------|
| 采集层语言 | Swift | macOS API 原生调用，零 FFI 开销，LaunchAgent 官方推荐 |
| MCP/AI 层语言 | Python | FastMCP SDK 成熟，AI 生态最好（langchain/openai/anthropic） |
| 进程间通信 | SQLite 共享数据库 | 最简单可靠，无需 IPC/RPC，Swift 写 + Python 读 |
| 注意力归因 | 多信号融合评分 | 键盘焦点+鼠标位置+点击/滚动+时间衰减，区分 active/reference/passive |
| 隐私策略 | L2 摘要模式 | 仅发送结构化统计给云端 LLM，不发原始窗口标题/URL |
| 数据库 Schema | 单表时间序列 | activity_stream 单表 + JSON meta 字段，灵活且查询简单 |

## Conventions

- **Swift**: Swift API Design Guidelines, 4 spaces indent, `camelCase`
- **Python**: ruff format + ruff check, 4 spaces indent, `snake_case`
- **数据库**: `snake_case` 表名和列名
- **Git**: Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`)
- **分支**: `main` + feature branches (`feat/xxx`, `fix/xxx`)

## Git Quality Gates

Pre-commit hook 检查链（fail-fast）：
1. `swift build` — 编译检查
2. `swift test` — Swift 测试
3. `ruff check python/` — Python lint
4. `uv run pytest python/tests/` — Python 测试

**禁止使用 `--no-verify` 绕过 hook。**

## Retrospective

> 每次遇到重大踩坑或架构教训时追加。格式: **[日期] 问题**: 根因 → 修复 → 教训

- **[2026-04-10] Watcher 被 ARC 释放**: `run()` 中的局部变量在 `RunLoop.run()` 期间被回收，NotificationCenter observer 全部失效 → 改为全局 `keepAlive` 数组持有强引用 → **长驻进程中引用的对象必须确保生命周期**
- **[2026-04-10] 线程安全竞态**: InputWatcher/MouseTracker 的 event monitor 线程与 Timer 线程并发读写共享状态 → 加 `DispatchQueue` 串行化 → **macOS 全局事件监听回调在非主线程执行**
- **[2026-04-10] `date(ts)` 阻止索引**: SQLite 的 `date()` 函数调用使 `idx_activity_ts` 索引失效 → 改为 `ts >= ? AND ts < ?` 范围查询 → **SQLite 函数调用在 WHERE 中会导致全表扫描**
- **[2026-04-10] GROUP BY 非聚合列陷阱**: `GROUP BY app_name` 时 `category` 返回任意值 → 改为 `GROUP BY app_name, category` → **SQLite 的 GROUP BY 对非聚合列行为未定义**
