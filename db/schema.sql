-- UseTrack Database Schema
-- SQLite 3
-- Swift collector writes, Python MCP server reads.

PRAGMA journal_mode=WAL;           -- Write-Ahead Logging for concurrent read/write
PRAGMA busy_timeout=5000;          -- 5s timeout for lock contention
PRAGMA foreign_keys=ON;

-- ============================================================
-- Core activity stream (single-table time series design)
-- ============================================================
CREATE TABLE IF NOT EXISTS activity_stream (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')),
    activity     TEXT NOT NULL,               -- app_switch / url_visit / idle / typing / focus
    app_name     TEXT,                        -- Application name (e.g., "Cursor", "Chrome")
    window_title TEXT,                        -- Window title (may contain sensitive info)
    duration_s   REAL,                        -- Duration in seconds (backfilled on next event)
    meta         JSON,                        -- Extended data: {url, project, file_path, keystrokes_per_min, screen_index, attention_state, attention_score, mouse_in_bounds_pct, focus_switches_to, concurrent_focus_app}
    category     TEXT,                        -- AI classification: deep_work / communication / learning / browsing / entertainment / system

    CHECK(activity IN ('app_switch', 'url_visit', 'idle', 'typing', 'focus', 'idle_start', 'idle_end'))
);

CREATE INDEX IF NOT EXISTS idx_activity_ts ON activity_stream(ts);
CREATE INDEX IF NOT EXISTS idx_activity_type ON activity_stream(activity, ts);
CREATE INDEX IF NOT EXISTS idx_activity_category ON activity_stream(category, ts);
CREATE INDEX IF NOT EXISTS idx_activity_app ON activity_stream(app_name, ts);

-- Full-text search on window titles
CREATE VIRTUAL TABLE IF NOT EXISTS activity_fts USING fts5(
    window_title,
    content=activity_stream,
    content_rowid=id
);

-- FTS triggers to keep index in sync
CREATE TRIGGER IF NOT EXISTS activity_fts_insert AFTER INSERT ON activity_stream BEGIN
    INSERT INTO activity_fts(rowid, window_title) VALUES (new.id, new.window_title);
END;

CREATE TRIGGER IF NOT EXISTS activity_fts_delete AFTER DELETE ON activity_stream BEGIN
    INSERT INTO activity_fts(activity_fts, rowid, window_title) VALUES ('delete', old.id, old.window_title);
END;

CREATE TRIGGER IF NOT EXISTS activity_fts_update AFTER UPDATE OF window_title ON activity_stream BEGIN
    INSERT INTO activity_fts(activity_fts, rowid, window_title) VALUES ('delete', old.id, old.window_title);
    INSERT INTO activity_fts(rowid, window_title) VALUES (new.id, new.window_title);
END;

-- ============================================================
-- Window snapshot (multi-monitor attention state, every minute)
-- ============================================================
CREATE TABLE IF NOT EXISTS window_snapshot (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime')),
    screen_index INTEGER NOT NULL,            -- Monitor number (0 = primary)
    app_name     TEXT NOT NULL,
    window_title TEXT,
    attention    TEXT NOT NULL,               -- active_focus / active_reference / passive_visible / stale
    score        REAL NOT NULL,              -- Attention score from multi-signal fusion
    bounds       JSON,                        -- {x, y, w, h} window position

    CHECK(attention IN ('active_focus', 'active_reference', 'passive_visible', 'stale'))
);

CREATE INDEX IF NOT EXISTS idx_snapshot_ts ON window_snapshot(ts);
CREATE INDEX IF NOT EXISTS idx_snapshot_attention ON window_snapshot(attention, ts);

-- ============================================================
-- Output metrics (daily aggregates of productive output)
-- ============================================================
CREATE TABLE IF NOT EXISTS output_metrics (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    date         DATE NOT NULL,
    metric_type  TEXT NOT NULL,               -- obsidian_words / git_commits / git_lines_added / git_lines_removed / code_time_min
    value        REAL NOT NULL,
    details      JSON,                        -- {files: [...], repos: [...], languages: {...}}

    UNIQUE(date, metric_type)
);

CREATE INDEX IF NOT EXISTS idx_output_date ON output_metrics(date);

-- ============================================================
-- Daily summary (AI-generated, one row per day)
-- ============================================================
CREATE TABLE IF NOT EXISTS daily_summary (
    date              DATE PRIMARY KEY,
    total_active_min   REAL,
    deep_work_min      REAL,
    context_switches   INTEGER,
    ping_pong_switches INTEGER,
    productivity_ratio REAL,                  -- (deep_work + learning) / total_active
    top_apps           JSON,                  -- [{app, minutes, category}]
    top_urls           JSON,                  -- [{domain, minutes}]
    energy_curve       JSON,                  -- {hour: deep_work_ratio}
    ai_summary         TEXT,                  -- AI-generated daily summary text
    ai_suggestions     JSON,                  -- ["suggestion1", "suggestion2", ...]
    created_at         DATETIME DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'))
);

-- ============================================================
-- App classification rules (user-configurable)
-- ============================================================
CREATE TABLE IF NOT EXISTS app_rules (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern      TEXT NOT NULL UNIQUE,        -- App name or regex pattern
    category     TEXT NOT NULL,               -- deep_work / communication / learning / browsing / entertainment / system
    is_regex     BOOLEAN DEFAULT 0,
    created_at   DATETIME DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now', 'localtime'))
);

-- Default classification rules
INSERT OR IGNORE INTO app_rules (pattern, category) VALUES
    ('Cursor', 'deep_work'),
    ('Visual Studio Code', 'deep_work'),
    ('Xcode', 'deep_work'),
    ('Terminal', 'deep_work'),
    ('iTerm2', 'deep_work'),
    ('Warp', 'deep_work'),
    ('Slack', 'communication'),
    ('Microsoft Teams', 'communication'),
    ('zoom.us', 'communication'),
    ('Mail', 'communication'),
    ('Microsoft Outlook', 'communication'),
    ('Safari', 'browsing'),
    ('Google Chrome', 'browsing'),
    ('Arc', 'browsing'),
    ('Firefox', 'browsing'),
    ('Obsidian', 'deep_work'),
    ('Notion', 'deep_work'),
    ('Finder', 'system'),
    ('System Preferences', 'system'),
    ('System Settings', 'system'),
    ('Activity Monitor', 'system'),
    ('1Password', 'system'),
    ('Spotify', 'entertainment'),
    ('Music', 'entertainment'),
    ('Preview', 'system'),
    ('Discord', 'communication'),
    ('WeChat', 'communication'),
    ('Telegram', 'communication'),
    ('Claude', 'deep_work'),
    ('Docker Desktop', 'deep_work'),
    ('Postman', 'deep_work'),
    ('TablePlus', 'deep_work'),
    ('DataGrip', 'deep_work'),
    ('PyCharm', 'deep_work'),
    ('IntelliJ IDEA', 'deep_work'),
    ('Notes', 'deep_work'),
    ('Calculator', 'system');

-- ============================================================
-- Sensitive app blacklist (skip data collection for these)
-- ============================================================
CREATE TABLE IF NOT EXISTS sensitive_apps (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    app_name     TEXT NOT NULL UNIQUE,
    reason       TEXT
);

INSERT OR IGNORE INTO sensitive_apps (app_name, reason) VALUES
    ('1Password', 'Password manager'),
    ('Keychain Access', 'System credentials'),
    ('Disk Utility', 'System tool');

-- ============================================================
-- Data retention: auto-cleanup old data
-- ============================================================
-- Run periodically: DELETE FROM activity_stream WHERE ts < datetime('now', '-90 days');
-- Run periodically: DELETE FROM window_snapshot WHERE ts < datetime('now', '-30 days');

-- ============================================================
-- Views for common queries
-- ============================================================

-- Daily app usage summary
CREATE VIEW IF NOT EXISTS v_daily_app_usage AS
SELECT
    date(ts) AS date,
    app_name,
    category,
    COUNT(*) AS event_count,
    ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) AS total_minutes
FROM activity_stream
WHERE activity = 'app_switch'
GROUP BY date(ts), app_name, category
ORDER BY date DESC, total_minutes DESC;

-- Hourly activity heatmap
CREATE VIEW IF NOT EXISTS v_hourly_heatmap AS
SELECT
    date(ts) AS date,
    CAST(strftime('%H', ts) AS INTEGER) AS hour,
    COUNT(*) AS events,
    ROUND(SUM(CASE WHEN category = 'deep_work' THEN COALESCE(duration_s, 0) ELSE 0 END) / 60.0, 1) AS deep_work_min,
    COUNT(DISTINCT app_name) AS unique_apps
FROM activity_stream
GROUP BY date(ts), strftime('%H', ts)
ORDER BY date DESC, hour;

-- Context switch frequency (per hour)
CREATE VIEW IF NOT EXISTS v_context_switches AS
SELECT
    date(ts) AS date,
    CAST(strftime('%H', ts) AS INTEGER) AS hour,
    COUNT(*) AS switches
FROM activity_stream
WHERE activity = 'app_switch'
GROUP BY date(ts), strftime('%H', ts)
ORDER BY date DESC, hour;
