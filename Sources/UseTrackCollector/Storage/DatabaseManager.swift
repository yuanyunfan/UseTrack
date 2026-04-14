// UseTrack — macOS Activity Tracker
// DatabaseManager: Swift 端 SQLite 写入层
//
// 职责:
// - 管理 SQLite 数据库连接（WAL 模式）
// - 自动创建表结构（与 db/schema.sql 一致）
// - 提供 activity_stream / window_snapshot / output_metrics 的写入方法
// - 缓存 sensitive_apps 和 app_rules 到内存
// - 数据保留策略清理

import Foundation
import SQLite

class DatabaseManager {
    /// 数据库文件路径
    let dbPath: String

    /// SQLite 连接
    private let db: Connection

    /// Serial queue to protect all DB writes from concurrent access
    private let dbQueue = DispatchQueue(label: "com.usetrack.database")

    /// 敏感 App 黑名单缓存（内存中）
    private var sensitiveApps: Set<String> = []

    /// App 分类规则缓存: appName -> category
    private var appRulesCache: [String: String] = [:]

    // MARK: - ISO 8601 日期格式化

    private static let iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.iso8601Formatter.string(from: date)
    }

    // MARK: - Initialization

    /// 初始化数据库连接并创建表结构
    /// - Parameter dbPath: 数据库文件路径，默认 ~/.usetrack/usetrack.db
    init(dbPath: String = "~/.usetrack/usetrack.db") throws {
        // 展开 ~ 路径
        let expandedPath = NSString(string: dbPath).expandingTildeInPath
        self.dbPath = expandedPath

        // 确保目录存在
        let directory = (expandedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // 打开数据库连接
        self.db = try Connection(expandedPath)

        // 配置 PRAGMA
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA busy_timeout=5000")
        try db.execute("PRAGMA foreign_keys=ON")

        // 创建表结构
        try createTables()

        // 加载缓存
        try loadSensitiveApps()
        try loadAppRules()
    }

    // MARK: - Schema Creation

    private func createTables() throws {
        // activity_stream
        try db.execute("""
            CREATE TABLE IF NOT EXISTS activity_stream (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                ts           DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')),
                activity     TEXT NOT NULL,
                app_name     TEXT,
                window_title TEXT,
                duration_s   REAL,
                meta         JSON,
                category     TEXT,
                CHECK(activity IN ('app_switch', 'url_visit', 'idle', 'typing', 'focus', 'idle_start', 'idle_end'))
            )
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_activity_ts ON activity_stream(ts)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_activity_type ON activity_stream(activity, ts)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_activity_category ON activity_stream(category, ts)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_activity_app ON activity_stream(app_name, ts)")

        // FTS5 虚拟表
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS activity_fts USING fts5(
                window_title,
                content=activity_stream,
                content_rowid=id
            )
        """)

        // FTS 同步触发器
        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS activity_fts_insert AFTER INSERT ON activity_stream BEGIN
                INSERT INTO activity_fts(rowid, window_title) VALUES (new.id, new.window_title);
            END
        """)

        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS activity_fts_delete AFTER DELETE ON activity_stream BEGIN
                INSERT INTO activity_fts(activity_fts, rowid, window_title) VALUES ('delete', old.id, old.window_title);
            END
        """)

        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS activity_fts_update AFTER UPDATE OF window_title ON activity_stream BEGIN
                INSERT INTO activity_fts(activity_fts, rowid, window_title) VALUES ('delete', old.id, old.window_title);
                INSERT INTO activity_fts(rowid, window_title) VALUES (new.id, new.window_title);
            END
        """)

        // window_snapshot
        try db.execute("""
            CREATE TABLE IF NOT EXISTS window_snapshot (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                ts           DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')),
                screen_index INTEGER NOT NULL,
                app_name     TEXT NOT NULL,
                window_title TEXT,
                attention    TEXT NOT NULL,
                score        REAL NOT NULL,
                bounds       JSON,
                CHECK(attention IN ('active_focus', 'active_reference', 'passive_visible', 'stale'))
            )
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_snapshot_ts ON window_snapshot(ts)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_snapshot_attention ON window_snapshot(attention, ts)")

        // output_metrics
        try db.execute("""
            CREATE TABLE IF NOT EXISTS output_metrics (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                date         DATE NOT NULL,
                metric_type  TEXT NOT NULL,
                value        REAL NOT NULL,
                details      JSON,
                UNIQUE(date, metric_type)
            )
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_output_date ON output_metrics(date)")

        // daily_summary
        try db.execute("""
            CREATE TABLE IF NOT EXISTS daily_summary (
                date              DATE PRIMARY KEY,
                total_active_min   REAL,
                deep_work_min      REAL,
                context_switches   INTEGER,
                ping_pong_switches INTEGER,
                productivity_ratio REAL,
                top_apps           JSON,
                top_urls           JSON,
                energy_curve       JSON,
                ai_summary         TEXT,
                ai_suggestions     JSON,
                created_at         DATETIME DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'))
            )
        """)

        // app_rules
        try db.execute("""
            CREATE TABLE IF NOT EXISTS app_rules (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern      TEXT NOT NULL UNIQUE,
                category     TEXT NOT NULL,
                is_regex     BOOLEAN DEFAULT 0,
                created_at   DATETIME DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'))
            )
        """)

        // 默认分类规则
        let defaultRules: [(String, String)] = [
            ("Cursor", "deep_work"),
            ("Visual Studio Code", "deep_work"),
            ("Xcode", "deep_work"),
            ("Terminal", "deep_work"),
            ("iTerm2", "deep_work"),
            ("Warp", "deep_work"),
            ("Slack", "communication"),
            ("Microsoft Teams", "communication"),
            ("zoom.us", "communication"),
            ("Mail", "communication"),
            ("Microsoft Outlook", "communication"),
            ("Safari", "browsing"),
            ("Google Chrome", "browsing"),
            ("Arc", "browsing"),
            ("Firefox", "browsing"),
            ("Obsidian", "deep_work"),
            ("Notion", "deep_work"),
            ("Finder", "system"),
            ("System Preferences", "system"),
            ("System Settings", "system"),
            ("Activity Monitor", "system"),
            ("1Password", "system"),
            ("Spotify", "entertainment"),
            ("Music", "entertainment"),
            ("Preview", "system"),
        ]

        let insertRule = try db.prepare(
            "INSERT OR IGNORE INTO app_rules (pattern, category) VALUES (?, ?)"
        )
        for (pattern, category) in defaultRules {
            try insertRule.run(pattern, category)
        }

        // sensitive_apps
        try db.execute("""
            CREATE TABLE IF NOT EXISTS sensitive_apps (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                app_name     TEXT NOT NULL UNIQUE,
                reason       TEXT
            )
        """)

        let defaultSensitive: [(String, String)] = [
            ("1Password", "Password manager"),
            ("Keychain Access", "System credentials"),
            ("Disk Utility", "System tool"),
        ]

        let insertSensitive = try db.prepare(
            "INSERT OR IGNORE INTO sensitive_apps (app_name, reason) VALUES (?, ?)"
        )
        for (appName, reason) in defaultSensitive {
            try insertSensitive.run(appName, reason)
        }

        // Views — 使用 substr(ts,1,10) 替代 date(ts) 避免索引失效
        try db.execute("""
            CREATE VIEW IF NOT EXISTS v_daily_app_usage AS
            SELECT
                substr(ts, 1, 10) AS date,
                app_name,
                category,
                COUNT(*) AS event_count,
                ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) AS total_minutes
            FROM activity_stream
            WHERE activity = 'app_switch'
            GROUP BY substr(ts, 1, 10), app_name, category
            ORDER BY date DESC, total_minutes DESC
        """)

        try db.execute("""
            CREATE VIEW IF NOT EXISTS v_hourly_heatmap AS
            SELECT
                substr(ts, 1, 10) AS date,
                CAST(strftime('%H', ts) AS INTEGER) AS hour,
                COUNT(*) AS events,
                ROUND(SUM(CASE WHEN category = 'deep_work' THEN COALESCE(duration_s, 0) ELSE 0 END) / 60.0, 1) AS deep_work_min,
                COUNT(DISTINCT app_name) AS unique_apps
            FROM activity_stream
            GROUP BY substr(ts, 1, 10), strftime('%H', ts)
            ORDER BY date DESC, hour
        """)

        try db.execute("""
            CREATE VIEW IF NOT EXISTS v_context_switches AS
            SELECT
                substr(ts, 1, 10) AS date,
                CAST(strftime('%H', ts) AS INTEGER) AS hour,
                COUNT(*) AS switches
            FROM activity_stream
            WHERE activity = 'app_switch'
            GROUP BY substr(ts, 1, 10), strftime('%H', ts)
            ORDER BY date DESC, hour
        """)
    }

    // MARK: - Cache Loading

    private func loadSensitiveApps() throws {
        sensitiveApps = []
        let stmt = try db.prepare("SELECT app_name FROM sensitive_apps")
        for row in stmt {
            if let appName = row[0] as? String {
                sensitiveApps.insert(appName)
            }
        }
    }

    private func loadAppRules() throws {
        appRulesCache = [:]
        let stmt = try db.prepare("SELECT pattern, category FROM app_rules WHERE is_regex = 0")
        for row in stmt {
            if let pattern = row[0] as? String, let category = row[1] as? String {
                appRulesCache[pattern] = category
            }
        }
    }

    // MARK: - Activity Stream

    /// 插入一条活动事件
    /// - Returns: 新插入行的 row ID
    @discardableResult
    func insertActivity(_ event: ActivityEvent) throws -> Int64 {
        return try dbQueue.sync {
            // 序列化 meta 字段
            var metaJSON: String? = nil
            if let meta = event.meta {
                let data = try JSONSerialization.data(withJSONObject: meta)
                metaJSON = String(data: data, encoding: .utf8)
            }

            let ts = formatDate(event.timestamp)

            try db.run(
                """
                INSERT INTO activity_stream (ts, activity, app_name, window_title, duration_s, meta, category)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                ts,
                event.activity,
                event.appName,
                event.windowTitle,
                event.durationSeconds,
                metaJSON,
                event.category
            )

            return db.lastInsertRowid
        }
    }

    /// 更新最近一条活动事件的持续时间（当下一个事件到达时回填）
    func updateLastActivityDuration(durationSeconds: Double) throws {
        try dbQueue.sync {
            try db.run(
                """
                UPDATE activity_stream
                SET duration_s = ?
                WHERE id = (SELECT MAX(id) FROM activity_stream)
                """,
                durationSeconds
            )
        }
    }

    // MARK: - Window Snapshot

    /// 批量插入窗口快照（每分钟一次，记录所有可见窗口的注意力状态）
    func insertWindowSnapshots(_ snapshots: [WindowSnapshot]) throws {
        guard !snapshots.isEmpty else { return }

        try dbQueue.sync {
            try db.transaction {
            let stmt = try db.prepare(
                """
                INSERT INTO window_snapshot (ts, screen_index, app_name, window_title, attention, score, bounds)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )

            for snapshot in snapshots {
                let ts = formatDate(snapshot.timestamp)

                // 将 AttentionState 枚举转为数据库中的 snake_case 格式
                let attentionValue: String
                switch snapshot.attention {
                case .activeFocus:
                    attentionValue = "active_focus"
                case .activeReference:
                    attentionValue = "active_reference"
                case .passiveVisible:
                    attentionValue = "passive_visible"
                case .stale:
                    attentionValue = "stale"
                }

                // 序列化 bounds 为 JSON
                let boundsJSON = """
                    {"x":\(snapshot.bounds.origin.x),"y":\(snapshot.bounds.origin.y),"w":\(snapshot.bounds.size.width),"h":\(snapshot.bounds.size.height)}
                    """

                try stmt.run(
                    ts,
                    snapshot.screenIndex,
                    snapshot.appName,
                    snapshot.windowTitle,
                    attentionValue,
                    snapshot.score,
                    boundsJSON
                )
            }
            }
        }
    }

    // MARK: - Output Metrics

    /// 插入产出指标（每日聚合数据，UPSERT 语义：覆盖）
    func insertOutputMetric(date: String, metricType: String, value: Double, details: String? = nil) throws {
        try dbQueue.sync {
            try db.run(
                """
                INSERT INTO output_metrics (date, metric_type, value, details)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(date, metric_type) DO UPDATE SET value = excluded.value, details = excluded.details
                """,
                date,
                metricType,
                value,
                details
            )
        }
    }

    /// 累加产出指标（用于增量更新场景，如多仓库 git 指标）
    /// ON CONFLICT 时将 value 累加到已有值，而非覆盖
    func addOutputMetric(date: String, metricType: String, delta: Double, details: String? = nil) throws {
        try dbQueue.sync {
            try db.run(
                """
                INSERT INTO output_metrics (date, metric_type, value, details)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(date, metric_type) DO UPDATE SET value = value + excluded.value, details = excluded.details
                """,
                date,
                metricType,
                delta,
                details
            )
        }
    }

    // MARK: - Lookup (Cached)

    /// 检查是否是敏感 App（使用内存缓存）
    func isSensitiveApp(appName: String) -> Bool {
        sensitiveApps.contains(appName)
    }

    /// 获取 App 的分类（使用内存缓存）
    /// 获取 App 的分类（缓存 + DB fallback，确保 Dashboard 修改后立即生效）
    func getCategoryForApp(appName: String) -> String? {
        return dbQueue.sync {
            // Check cache first
            if let cached = appRulesCache[appName] {
                return cached
            }
            // Not in cache — query DB (may have been added by Dashboard)
            do {
                for row in try db.prepare(
                    "SELECT category FROM app_rules WHERE pattern = ? AND is_regex = 0 LIMIT 1",
                    [appName]
                ) {
                    if let category = row[0] as? String {
                        appRulesCache[appName] = category  // Update cache
                        return category
                    }
                }
            } catch {
                // Ignore query errors
            }
            return nil
        }
    }

    // MARK: - Data Retention

    /// 清理过期数据
    /// - Parameters:
    ///   - activityDays: activity_stream 保留天数（默认 90 天）
    ///   - snapshotDays: window_snapshot 保留天数（默认 30 天）
    func cleanupOldData(activityDays: Int = 90, snapshotDays: Int = 30) throws {
        try dbQueue.sync {
            try db.run(
                "DELETE FROM activity_stream WHERE ts < datetime('now', ?)",
                "-\(activityDays) days"
            )
            try db.run(
                "DELETE FROM window_snapshot WHERE ts < datetime('now', ?)",
                "-\(snapshotDays) days"
            )
        }
    }
}
