"""UseTrack database layer — async SQLite read operations."""

import sqlite3
from datetime import date, timedelta
from pathlib import Path

import aiosqlite

DEFAULT_DB_PATH = Path.home() / ".usetrack" / "usetrack.db"


class UseTrackDB:
    """Async SQLite reader for UseTrack activity data."""

    def __init__(self, db_path: Path = DEFAULT_DB_PATH):
        self.db_path = db_path
        self._db: aiosqlite.Connection | None = None

    async def connect(self) -> None:
        """Open database connection. Raises FileNotFoundError if DB doesn't exist."""
        if not self.db_path.exists():
            raise FileNotFoundError(
                f"UseTrack database not found: {self.db_path}. "
                "Start the collector first: ~/bin/UseTrackCollector"
            )
        self._db = await aiosqlite.connect(self.db_path)
        self._db.row_factory = aiosqlite.Row

    async def close(self) -> None:
        """Close database connection."""
        if self._db:
            await self._db.close()

    async def __aenter__(self) -> "UseTrackDB":
        await self.connect()
        return self

    async def __aexit__(self, *args: object) -> None:
        await self.close()

    # --- Helper: parse period string ---

    def _parse_period(self, period: str) -> tuple[str, str]:
        """Convert period string to (start_ts, end_ts) ISO datetime strings.

        Returns half-open interval [start, end) suitable for ``ts >= ? AND ts < ?``.
        - start: first day at ``T00:00:00``
        - end: day *after* last day at ``T00:00:00`` (exclusive upper bound)

        Supported formats:
        - "today" / "yesterday" / "this_week" / "last_week" / "this_month"
        - "YYYY-MM-DD" (specific date)
        - "YYYY-MM-DD:YYYY-MM-DD" (date range, inclusive)

        Raises ValueError for invalid formats.
        """
        today = date.today()
        if period == "today":
            start_d, end_d = today, today
        elif period == "yesterday":
            d = today - timedelta(days=1)
            start_d, end_d = d, d
        elif period == "this_week":
            start_d = today - timedelta(days=today.weekday())  # Monday
            end_d = today
        elif period == "last_week":
            end_d = today - timedelta(days=today.weekday() + 1)
            start_d = end_d - timedelta(days=6)
        elif period == "this_month":
            start_d = today.replace(day=1)
            end_d = today
        elif ":" in period:
            parts = period.split(":")
            start_d = date.fromisoformat(parts[0])
            end_d = date.fromisoformat(parts[1])
        else:
            start_d = date.fromisoformat(period)
            end_d = start_d

        # Half-open: [start 00:00:00, end+1day 00:00:00)
        start_ts = f"{start_d.isoformat()}T00:00:00"
        end_ts = f"{(end_d + timedelta(days=1)).isoformat()}T00:00:00"
        return start_ts, end_ts

    # --- Query methods ---

    async def get_activity_summary(self, period: str = "today") -> dict:
        """Get aggregated activity summary for a period."""
        start, end = self._parse_period(period)

        # Total active time and event counts
        row = await self._fetchone(
            """
            SELECT
                COUNT(*) as total_events,
                ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as total_active_min,
                COUNT(DISTINCT app_name) as unique_apps
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity NOT IN ('idle_start', 'idle_end')
            """,
            (start, end),
        )

        # Top apps (group by app_name + category to avoid ambiguous category)
        top_apps = await self._fetchall(
            """
            SELECT app_name,
                   category,
                   COUNT(*) as events,
                   ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as minutes
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity = 'app_switch' AND app_name IS NOT NULL
            GROUP BY app_name, category
            ORDER BY minutes DESC
            LIMIT 10
            """,
            (start, end),
        )

        # Category breakdown
        categories = await self._fetchall(
            """
            SELECT category,
                   ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as minutes
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND category IS NOT NULL
            GROUP BY category
            ORDER BY minutes DESC
            """,
            (start, end),
        )

        return {
            "period": period,
            "start_date": start,
            "end_date": end,
            "total_events": row["total_events"] if row else 0,
            "total_active_min": row["total_active_min"] if row else 0,
            "unique_apps": row["unique_apps"] if row else 0,
            "top_apps": [dict(r) for r in top_apps],
            "categories": [dict(r) for r in categories],
        }

    async def query_activities(
        self,
        start: str,
        end: str,
        app_filter: str | None = None,
        category_filter: str | None = None,
        limit: int = 100,
    ) -> list[dict]:
        """Query raw activity events within a time range."""
        limit = max(1, min(limit, 10000))
        sql = """
            SELECT id, ts, activity, app_name, window_title, duration_s, meta, category
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
        """
        params: list = [start, end]

        if app_filter:
            # Escape LIKE special characters to prevent pattern injection
            escaped = app_filter.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            sql += " AND app_name LIKE ? ESCAPE '\\'"
            params.append(f"%{escaped}%")
        if category_filter:
            sql += " AND category = ?"
            params.append(category_filter)

        sql += " ORDER BY ts DESC LIMIT ?"
        params.append(limit)

        rows = await self._fetchall(sql, tuple(params))
        return [dict(r) for r in rows]

    async def get_focus_metrics(self, target_date: str = "today") -> dict:
        """Calculate focus/attention metrics for a date."""
        if target_date == "today":
            d = date.today()
        elif target_date == "yesterday":
            d = date.today() - timedelta(days=1)
        else:
            d = date.fromisoformat(target_date)

        # Half-open interval [day 00:00:00, next_day 00:00:00)
        start_ts = f"{d.isoformat()}T00:00:00"
        end_ts = f"{(d + timedelta(days=1)).isoformat()}T00:00:00"

        # Deep work: continuous single-app usage with deep_work category
        deep_work = await self._fetchone(
            """
            SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as deep_work_min
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND category = 'deep_work'
            """,
            (start_ts, end_ts),
        )

        # Context switches (app_switch events per day)
        switches = await self._fetchone(
            """
            SELECT COUNT(*) as total_switches
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
            """,
            (start_ts, end_ts),
        )

        # Ping-pong switches (rapid back-and-forth within 5 seconds)
        ping_pong = await self._fetchone(
            """
            SELECT COUNT(*) as ping_pong
            FROM activity_stream
            WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
              AND duration_s IS NOT NULL AND duration_s < 5
            """,
            (start_ts, end_ts),
        )

        # Total active time
        total = await self._fetchone(
            """
            SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as total_min
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity NOT IN ('idle_start', 'idle_end')
            """,
            (start_ts, end_ts),
        )

        total_min = total["total_min"] if total and total["total_min"] else 0
        dw_min = deep_work["deep_work_min"] if deep_work and deep_work["deep_work_min"] else 0

        # Energy curve: deep work ratio per hour
        energy = await self._fetchall(
            """
            SELECT
                CAST(strftime('%H', ts) AS INTEGER) as hour,
                ROUND(
                    SUM(CASE WHEN category = 'deep_work'
                        THEN COALESCE(duration_s, 0) ELSE 0 END)
                    / NULLIF(SUM(COALESCE(duration_s, 0)), 0),
                    2
                ) as deep_work_ratio
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND duration_s IS NOT NULL AND duration_s > 0
            GROUP BY strftime('%H', ts)
            ORDER BY hour
            """,
            (start_ts, end_ts),
        )

        return {
            "date": d.isoformat(),
            "deep_work_min": dw_min,
            "context_switches": switches["total_switches"] if switches else 0,
            "ping_pong_switches": ping_pong["ping_pong"] if ping_pong else 0,
            "total_active_min": total_min,
            "productivity_ratio": round(dw_min / total_min, 2) if total_min > 0 else 0,
            "energy_curve": {
                str(r["hour"]).zfill(2): r["deep_work_ratio"] or 0 for r in energy
            },
        }

    async def search_activity(self, keyword: str, limit: int = 50) -> list[dict]:
        """Full-text search across window titles using FTS5."""
        limit = max(1, min(limit, 10000))
        if not keyword or not keyword.strip():
            return []
        # Sanitize: wrap keyword in double quotes so FTS5 treats it as a literal
        # phrase, preventing use of operators (AND, OR, NOT, NEAR, *) to probe
        # database content. Escape any embedded double quotes per FTS5 rules.
        sanitized = '"' + keyword.strip().replace('"', '""') + '"'
        try:
            rows = await self._fetchall(
                """
                SELECT a.id, a.ts, a.activity, a.app_name, a.window_title,
                       a.duration_s, a.category
                FROM activity_fts f
                JOIN activity_stream a ON a.id = f.rowid
                WHERE activity_fts MATCH ?
                ORDER BY a.ts DESC
                LIMIT ?
                """,
                (sanitized, limit),
            )
            return [dict(r) for r in rows]
        except sqlite3.OperationalError:
            # FTS5 syntax error (e.g. bare operators like "OR AND NOT")
            return []

    async def get_output_metrics(self, period: str = "today") -> dict:
        """Get output metrics (notes, git, code) for a period."""
        start, end = self._parse_period(period)
        # output_metrics.date is a DATE column — extract date part from datetime range
        start_date = start[:10]
        end_date = end[:10]

        rows = await self._fetchall(
            """
            SELECT metric_type, SUM(value) as total
            FROM output_metrics
            WHERE date >= ? AND date < ?
            GROUP BY metric_type
            """,
            (start_date, end_date),
        )

        result: dict = {"period": period, "start_date": start, "end_date": end}
        for r in rows:
            result[r["metric_type"]] = r["total"]
        return result

    async def get_trends(self, metric: str, days: int = 7) -> dict:
        """Get trend data for a metric over N days."""
        end_d = date.today()
        start_d = end_d - timedelta(days=days - 1)
        # Half-open interval for activity_stream queries
        start_ts = f"{start_d.isoformat()}T00:00:00"
        end_ts = f"{(end_d + timedelta(days=1)).isoformat()}T00:00:00"

        if metric == "deep_work":
            rows = await self._fetchall(
                """
                SELECT date(ts) as date,
                       ROUND(SUM(CASE WHEN category = 'deep_work'
                           THEN COALESCE(duration_s, 0) ELSE 0 END) / 60.0, 1) as value
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                GROUP BY date(ts)
                ORDER BY date
                """,
                (start_ts, end_ts),
            )
        elif metric == "context_switches":
            rows = await self._fetchall(
                """
                SELECT date(ts) as date, COUNT(*) as value
                FROM activity_stream
                WHERE ts >= ? AND ts < ? AND activity = 'app_switch'
                GROUP BY date(ts)
                ORDER BY date
                """,
                (start_ts, end_ts),
            )
        elif metric == "active_time":
            rows = await self._fetchall(
                """
                SELECT date(ts) as date,
                       ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as value
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                  AND activity NOT IN ('idle_start', 'idle_end')
                GROUP BY date(ts)
                ORDER BY date
                """,
                (start_ts, end_ts),
            )
        else:
            # Generic metric from output_metrics table (date column is DATE type)
            rows = await self._fetchall(
                """
                SELECT date, SUM(value) as value
                FROM output_metrics
                WHERE date >= ? AND date < ? AND metric_type = ?
                GROUP BY date
                ORDER BY date
                """,
                (start_d.isoformat(), (end_d + timedelta(days=1)).isoformat(), metric),
            )

        return {
            "metric": metric,
            "days": days,
            "data": [{"date": r["date"], "value": r["value"]} for r in rows],
        }

    async def get_distraction_patterns(self, period: str = "today") -> dict:
        """Analyze distraction patterns: frequent switch chains, social media time."""
        start, end = self._parse_period(period)

        # Short-duration app switches (< 15 seconds) — likely distractions
        short_switches = await self._fetchall(
            """
            SELECT app_name, COUNT(*) as count,
                   ROUND(AVG(duration_s), 1) as avg_duration_s
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND activity = 'app_switch' AND duration_s < 15 AND duration_s IS NOT NULL
            GROUP BY app_name
            HAVING count >= 3
            ORDER BY count DESC
            LIMIT 10
            """,
            (start, end),
        )

        # Entertainment/browsing time
        distraction_time = await self._fetchone(
            """
            SELECT ROUND(SUM(COALESCE(duration_s, 0)) / 60.0, 1) as minutes
            FROM activity_stream
            WHERE ts >= ? AND ts < ?
              AND category IN ('entertainment', 'browsing')
            """,
            (start, end),
        )

        # Most frequent app transition pairs (use window function for correct ordering)
        transitions = await self._fetchall(
            """
            WITH app_switches AS (
                SELECT app_name,
                       LEAD(app_name) OVER (ORDER BY ts) as next_app
                FROM activity_stream
                WHERE ts >= ? AND ts < ?
                  AND activity = 'app_switch'
                  AND app_name IS NOT NULL
            )
            SELECT app_name as from_app, next_app as to_app, COUNT(*) as count
            FROM app_switches
            WHERE next_app IS NOT NULL AND app_name != next_app
            GROUP BY app_name, next_app
            HAVING count >= 3
            ORDER BY count DESC
            LIMIT 10
            """,
            (start, end),
        )

        return {
            "period": period,
            "frequent_short_switches": [dict(r) for r in short_switches],
            "distraction_time_min": (
                distraction_time["minutes"]
                if distraction_time and distraction_time["minutes"]
                else 0
            ),
            "top_transitions": [dict(r) for r in transitions],
        }

    # --- Internal helpers ---

    async def _fetchone(self, sql: str, params: tuple = ()) -> dict | None:
        if self._db is None:
            raise RuntimeError("Database not connected. Call connect() first.")
        async with self._db.execute(sql, params) as cursor:
            row = await cursor.fetchone()
            return dict(row) if row else None

    async def _fetchall(self, sql: str, params: tuple = ()) -> list[dict]:
        if self._db is None:
            raise RuntimeError("Database not connected. Call connect() first.")
        async with self._db.execute(sql, params) as cursor:
            rows = await cursor.fetchall()
            return [dict(r) for r in rows]
