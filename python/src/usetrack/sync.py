"""UseTrack multi-machine sync — config, export, and merged query support."""

from __future__ import annotations

import logging
import sqlite3
from datetime import date, timedelta
from pathlib import Path

import aiosqlite

from usetrack.db import DEFAULT_DB_PATH, UseTrackDB

logger = logging.getLogger(__name__)

SYNC_CONFIG_PATH = Path.home() / ".usetrack" / "sync.toml"

# Tables to export (only these have time-series data worth syncing)
EXPORT_TABLES = ["activity_stream", "window_snapshot", "output_metrics"]


# --- Config ---


def load_sync_config() -> dict | None:
    """Load sync config from ~/.usetrack/sync.toml. Returns None if not found or disabled."""
    if not SYNC_CONFIG_PATH.exists():
        return None

    import tomllib

    with open(SYNC_CONFIG_PATH, "rb") as f:
        config = tomllib.load(f)

    sync = config.get("sync", {})
    if not sync.get("enabled", False):
        return None

    machine_id = sync.get("machine_id")
    sync_dir = sync.get("sync_dir")
    if not machine_id or not sync_dir:
        logger.warning("sync.toml missing machine_id or sync_dir, ignoring")
        return None

    return {
        "machine_id": machine_id,
        "sync_dir": Path(sync_dir).expanduser(),
        "enabled": True,
        "export_interval_min": sync.get("export_interval_min", 30),
    }


# --- Export ---


def export_today(
    source_db: Path = DEFAULT_DB_PATH,
    sync_dir: Path | None = None,
    machine_id: str | None = None,
    target_date: date | None = None,
) -> Path:
    """Export today's data from local DB to sync directory as a standalone .db file.

    Creates: {sync_dir}/{machine_id}/{YYYY-MM-DD}.db
    Uses atomic write: creates .tmp then renames.

    Returns the path to the exported .db file.
    """
    config = load_sync_config()
    if sync_dir is None:
        if config is None:
            raise RuntimeError("No sync config found and no sync_dir provided")
        sync_dir = config["sync_dir"]
    if machine_id is None:
        if config is None:
            raise RuntimeError("No sync config found and no machine_id provided")
        machine_id = config["machine_id"]

    d = target_date or date.today()
    start_ts = f"{d.isoformat()}T00:00:00"
    end_ts = f"{(d + timedelta(days=1)).isoformat()}T00:00:00"

    out_dir = sync_dir / machine_id
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{d.isoformat()}.db"
    tmp_path = out_dir / f"{d.isoformat()}.db.tmp"

    # Create export DB with schema subset, insert today's rows
    src = sqlite3.connect(str(source_db))
    try:
        dst = sqlite3.connect(str(tmp_path))
        try:
            dst.execute("PRAGMA journal_mode=WAL")
            # Create tables (minimal schema, no triggers/views/FTS)
            dst.executescript("""
                CREATE TABLE IF NOT EXISTS activity_stream (
                    id INTEGER PRIMARY KEY, ts DATETIME NOT NULL,
                    activity TEXT NOT NULL, app_name TEXT, window_title TEXT,
                    duration_s REAL, meta JSON, category TEXT
                );
                CREATE TABLE IF NOT EXISTS window_snapshot (
                    id INTEGER PRIMARY KEY, ts DATETIME NOT NULL,
                    screen_index INTEGER NOT NULL, app_name TEXT NOT NULL,
                    window_title TEXT, attention TEXT NOT NULL,
                    score REAL NOT NULL, bounds JSON
                );
                CREATE TABLE IF NOT EXISTS output_metrics (
                    id INTEGER PRIMARY KEY, date DATE NOT NULL,
                    metric_type TEXT NOT NULL, value REAL NOT NULL,
                    details JSON
                );
            """)

            # Copy activity_stream rows for the day
            rows = src.execute(
                "SELECT id, ts, activity, app_name, window_title, duration_s, meta, category "
                "FROM activity_stream WHERE ts >= ? AND ts < ?",
                (start_ts, end_ts),
            ).fetchall()
            if rows:
                dst.executemany(
                    "INSERT OR REPLACE INTO activity_stream VALUES (?,?,?,?,?,?,?,?)", rows
                )

            # Copy window_snapshot rows for the day
            rows = src.execute(
                "SELECT id, ts, screen_index, app_name, window_title, attention, score, bounds "
                "FROM window_snapshot WHERE ts >= ? AND ts < ?",
                (start_ts, end_ts),
            ).fetchall()
            if rows:
                dst.executemany(
                    "INSERT OR REPLACE INTO window_snapshot VALUES (?,?,?,?,?,?,?,?)", rows
                )

            # Copy output_metrics rows for the day (date column is DATE type)
            start_date = d.isoformat()
            end_date = (d + timedelta(days=1)).isoformat()
            rows = src.execute(
                "SELECT id, date, metric_type, value, details "
                "FROM output_metrics WHERE date >= ? AND date < ?",
                (start_date, end_date),
            ).fetchall()
            if rows:
                dst.executemany(
                    "INSERT OR REPLACE INTO output_metrics VALUES (?,?,?,?,?)", rows
                )

            dst.commit()
        finally:
            dst.close()
    finally:
        src.close()

    # Atomic rename
    tmp_path.replace(out_path)
    logger.info("Exported %s to %s", d.isoformat(), out_path)
    return out_path


# --- Merged DB ---


class MergedDB(UseTrackDB):
    """UseTrackDB subclass that merges local DB with remote sync DBs.

    For each query, runs against local DB first, then scans sync_dir for
    other machines' daily .db files matching the query date range.
    Results are merged in Python.
    """

    def __init__(
        self,
        db_path: Path = DEFAULT_DB_PATH,
        sync_dir: Path | None = None,
        machine_id: str | None = None,
    ):
        super().__init__(db_path)
        self.sync_dir = sync_dir
        self.machine_id = machine_id

    def _find_remote_dbs(self, start_date: str, end_date: str) -> list[Path]:
        """Find remote .db files matching the date range.

        start_date/end_date are ISO date strings (YYYY-MM-DD).
        Returns paths to .db files from OTHER machines only.
        """
        if not self.sync_dir or not self.sync_dir.exists():
            return []

        result = []
        try:
            start_d = date.fromisoformat(start_date)
            end_d = date.fromisoformat(end_date)
        except ValueError:
            return []

        for machine_dir in self.sync_dir.iterdir():
            if not machine_dir.is_dir():
                continue
            if machine_dir.name == self.machine_id:
                continue  # Skip own machine
            # Check each date in range
            d = start_d
            while d <= end_d:
                db_file = machine_dir / f"{d.isoformat()}.db"
                if db_file.exists():
                    result.append(db_file)
                d += timedelta(days=1)

        return result

    def _dates_from_period(self, period: str) -> tuple[str, str]:
        """Extract date range (YYYY-MM-DD, YYYY-MM-DD) from period string."""
        start_ts, end_ts = self._parse_period(period)
        return start_ts[:10], end_ts[:10]

    async def _query_remote_db(self, db_path: Path, sql: str, params: tuple) -> list[dict]:
        """Query a single remote .db file."""
        try:
            async with aiosqlite.connect(db_path) as db:
                db.row_factory = aiosqlite.Row
                async with db.execute(sql, params) as cursor:
                    rows = await cursor.fetchall()
                    return [dict(r) for r in rows]
        except Exception as e:
            logger.warning("Failed to query remote DB %s: %s", db_path, e)
            return []

    # --- Overridden query methods with merge logic ---

    async def get_activity_summary(self, period: str = "today") -> dict:
        """Get merged activity summary from local + remote DBs."""
        local = await super().get_activity_summary(period)
        start, end = self._parse_period(period)
        start_date, end_date = start[:10], end[:10]

        remote_dbs = self._find_remote_dbs(start_date, end_date)
        if not remote_dbs:
            return local

        # Query each remote DB for aggregates
        for db_path in remote_dbs:
            row = await self._query_remote_db(
                db_path,
                """SELECT COUNT(*) as total_events,
                   ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as total_active_min,
                   COUNT(DISTINCT app_name) as unique_apps
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                  AND activity NOT IN ('idle_start', 'idle_end')""",
                (start, end),
            )
            if row:
                r = row[0]
                local["total_events"] += r.get("total_events", 0) or 0
                local["total_active_min"] = round(
                    (local["total_active_min"] or 0) + (r.get("total_active_min", 0) or 0), 1
                )
                # unique_apps is approximate (may double-count across machines)
                local["unique_apps"] = max(local["unique_apps"], r.get("unique_apps", 0) or 0)

            # Merge top_apps
            remote_apps = await self._query_remote_db(
                db_path,
                """SELECT app_name, category, COUNT(*) as events,
                   ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as minutes
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                  AND activity = 'app_switch' AND app_name IS NOT NULL
                GROUP BY app_name, category
                ORDER BY minutes DESC LIMIT 10""",
                (start, end),
            )
            if remote_apps:
                # Merge into local top_apps by summing minutes for same app+category
                app_map: dict[tuple, dict] = {}
                for app in local["top_apps"]:
                    key = (app["app_name"], app["category"])
                    app_map[key] = dict(app)
                for app in remote_apps:
                    key = (app["app_name"], app["category"])
                    if key in app_map:
                        app_map[key]["events"] += app.get("events", 0) or 0
                        app_map[key]["minutes"] = round(
                            (app_map[key]["minutes"] or 0) + (app.get("minutes", 0) or 0), 1
                        )
                    else:
                        app_map[key] = dict(app)
                local["top_apps"] = sorted(
                    app_map.values(), key=lambda x: x.get("minutes", 0) or 0, reverse=True
                )[:10]

            # Merge categories
            remote_cats = await self._query_remote_db(
                db_path,
                """SELECT category,
                   ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as minutes
                FROM activity_stream
                WHERE ts >= ? AND ts < ? AND category IS NOT NULL
                GROUP BY category ORDER BY minutes DESC""",
                (start, end),
            )
            if remote_cats:
                cat_map: dict[str, float] = {}
                for c in local["categories"]:
                    cat_map[c["category"]] = c.get("minutes", 0) or 0
                for c in remote_cats:
                    cat_name = c["category"]
                    cat_map[cat_name] = round(
                        cat_map.get(cat_name, 0) + (c.get("minutes", 0) or 0), 1
                    )
                local["categories"] = sorted(
                    [{"category": k, "minutes": v} for k, v in cat_map.items()],
                    key=lambda x: x["minutes"],
                    reverse=True,
                )

        return local

    async def get_focus_metrics(self, target_date: str = "today") -> dict:
        """Get merged focus metrics."""
        local = await super().get_focus_metrics(target_date)

        if target_date == "today":
            d = date.today()
        elif target_date == "yesterday":
            d = date.today() - timedelta(days=1)
        else:
            d = date.fromisoformat(target_date)

        start_ts = f"{d.isoformat()}T00:00:00"
        end_ts = f"{(d + timedelta(days=1)).isoformat()}T00:00:00"

        remote_dbs = self._find_remote_dbs(d.isoformat(), d.isoformat())
        if not remote_dbs:
            return local

        for db_path in remote_dbs:
            # Deep work
            dw = await self._query_remote_db(
                db_path,
                """SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as deep_work_min
                FROM activity_stream WHERE ts >= ? AND ts < ? AND category = 'deep_work'""",
                (start_ts, end_ts),
            )
            if dw and dw[0].get("deep_work_min"):
                local["deep_work_min"] = round(
                    local["deep_work_min"] + dw[0]["deep_work_min"], 1
                )

            # Switches
            sw = await self._query_remote_db(
                db_path,
                """SELECT COUNT(*) as total_switches FROM activity_stream
                WHERE ts >= ? AND ts < ? AND activity = 'app_switch'""",
                (start_ts, end_ts),
            )
            if sw:
                local["context_switches"] += sw[0].get("total_switches", 0) or 0

            # Ping-pong
            pp = await self._query_remote_db(
                db_path,
                """SELECT COUNT(*) as ping_pong FROM activity_stream
                WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
                  AND duration_s IS NOT NULL AND duration_s < 5""",
                (start_ts, end_ts),
            )
            if pp:
                local["ping_pong_switches"] += pp[0].get("ping_pong", 0) or 0

            # Total active
            ta = await self._query_remote_db(
                db_path,
                """SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as total_min
                FROM activity_stream WHERE ts >= ? AND ts < ?
                  AND activity NOT IN ('idle_start', 'idle_end')""",
                (start_ts, end_ts),
            )
            if ta and ta[0].get("total_min"):
                local["total_active_min"] = round(
                    local["total_active_min"] + ta[0]["total_min"], 1
                )

        # Recalculate ratio
        if local["total_active_min"] > 0:
            local["productivity_ratio"] = round(
                local["deep_work_min"] / local["total_active_min"], 2
            )

        return local

    async def get_trends(self, metric: str, days: int = 7) -> dict:
        """Get merged trend data."""
        local = await super().get_trends(metric, days)

        end_d = date.today()
        start_d = end_d - timedelta(days=days - 1)
        start_ts = f"{start_d.isoformat()}T00:00:00"
        end_ts = f"{(end_d + timedelta(days=1)).isoformat()}T00:00:00"

        remote_dbs = self._find_remote_dbs(start_d.isoformat(), end_d.isoformat())
        if not remote_dbs:
            return local

        # Build date->value map from local
        date_map: dict[str, float] = {}
        for pt in local["data"]:
            date_map[pt["date"]] = pt["value"] or 0

        for db_path in remote_dbs:
            if metric == "deep_work":
                sql = """SELECT date(ts) as date,
                    ROUND(SUM(CASE WHEN category = 'deep_work'
                        THEN COALESCE(duration_s, 0) ELSE 0 END) / 60.0, 1) as value
                    FROM activity_stream WHERE ts >= ? AND ts < ?
                    GROUP BY date(ts) ORDER BY date"""
                params = (start_ts, end_ts)
            elif metric == "context_switches":
                sql = """SELECT date(ts) as date, COUNT(*) as value
                    FROM activity_stream WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
                    GROUP BY date(ts) ORDER BY date"""
                params = (start_ts, end_ts)
            elif metric == "active_time":
                sql = """SELECT date(ts) as date,
                    ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as value
                    FROM activity_stream WHERE ts >= ? AND ts < ?
                      AND activity NOT IN ('idle_start', 'idle_end')
                    GROUP BY date(ts) ORDER BY date"""
                params = (start_ts, end_ts)
            else:
                sql = """SELECT date, SUM(value) as value FROM output_metrics
                    WHERE date >= ? AND date < ? AND metric_type = ?
                    GROUP BY date ORDER BY date"""
                params = (
                    start_d.isoformat(),
                    (end_d + timedelta(days=1)).isoformat(),
                    metric,
                )

            remote_rows = await self._query_remote_db(db_path, sql, params)
            for r in remote_rows:
                d_str = r["date"]
                date_map[d_str] = round(date_map.get(d_str, 0) + (r["value"] or 0), 1)

        local["data"] = sorted(
            [{"date": k, "value": v} for k, v in date_map.items()],
            key=lambda x: x["date"],
        )
        return local

    async def get_output_metrics(self, period: str = "today") -> dict:
        """Get merged output metrics."""
        local = await super().get_output_metrics(period)
        start, end = self._parse_period(period)
        start_date, end_date = start[:10], end[:10]

        remote_dbs = self._find_remote_dbs(start_date, end_date)
        if not remote_dbs:
            return local

        for db_path in remote_dbs:
            rows = await self._query_remote_db(
                db_path,
                """SELECT metric_type, SUM(value) as total FROM output_metrics
                WHERE date >= ? AND date < ? GROUP BY metric_type""",
                (start_date, end_date),
            )
            for r in rows:
                mt = r["metric_type"]
                local[mt] = (local.get(mt) or 0) + (r["total"] or 0)

        return local
