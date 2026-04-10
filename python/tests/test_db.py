"""Tests for UseTrack database layer."""

from datetime import date, timedelta
from pathlib import Path

import aiosqlite
import pytest

from usetrack.db import UseTrackDB

# --- Fixtures ---

SCHEMA_PATH = Path(__file__).resolve().parents[2] / "db" / "schema.sql"


async def _create_test_db(tmp_path: Path) -> Path:
    """Create a test database with schema and sample data."""
    db_path = tmp_path / "test.db"
    async with aiosqlite.connect(db_path) as db:
        schema = SCHEMA_PATH.read_text()
        await db.executescript(schema)

        today = date.today().isoformat()
        yesterday = (date.today() - timedelta(days=1)).isoformat()

        # Insert sample activity data
        activities = [
            # Today: deep work in Cursor (30 min)
            (f"{today}T09:00:00", "app_switch", "Cursor", "main.py — Project", 1800, "deep_work"),
            # Today: quick Slack check (10 sec — ping-pong)
            (f"{today}T09:30:00", "app_switch", "Slack", "General — Slack", 3, "communication"),
            # Today: back to Cursor (45 min)
            (f"{today}T09:30:03", "app_switch", "Cursor", "utils.py — Project", 2700, "deep_work"),
            # Today: Chrome browsing (5 min)
            (f"{today}T10:15:03", "app_switch", "Chrome", "Google — Chrome", 300, "browsing"),
            # Today: quick Slack again (2 sec — ping-pong)
            (f"{today}T10:20:03", "app_switch", "Slack", "DM — Slack", 2, "communication"),
            # Today: back to Chrome (8 sec — short switch)
            (f"{today}T10:20:05", "app_switch", "Chrome", "Stack Overflow — Chrome", 8, "browsing"),
            # Today: Spotify (entertainment, 10 min)
            (f"{today}T10:20:13", "app_switch", "Spotify", "Now Playing", 600, "entertainment"),
            # Today: more short Slack switches for distraction pattern
            (f"{today}T10:30:13", "app_switch", "Slack", "Thread — Slack", 4, "communication"),
            (f"{today}T10:30:17", "app_switch", "Cursor", "db.py — UseTrack", 1200, "deep_work"),
            (f"{today}T10:50:17", "app_switch", "Slack", "Alert — Slack", 3, "communication"),
            # Yesterday: some activity
            (f"{yesterday}T14:00:00", "app_switch", "Cursor",
             "old.py — Project", 3600, "deep_work"),
            (f"{yesterday}T15:00:00", "app_switch", "Chrome",
             "Docs — Chrome", 600, "browsing"),
        ]

        for ts, activity, app, title, dur, cat in activities:
            await db.execute(
                """INSERT INTO activity_stream
                   (ts, activity, app_name, window_title, duration_s, category)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (ts, activity, app, title, dur, cat),
            )

        # Insert output metrics
        await db.execute(
            "INSERT INTO output_metrics (date, metric_type, value) VALUES (?, ?, ?)",
            (today, "git_commits", 5),
        )
        await db.execute(
            "INSERT INTO output_metrics (date, metric_type, value) VALUES (?, ?, ?)",
            (today, "obsidian_words", 1200),
        )
        await db.execute(
            "INSERT INTO output_metrics (date, metric_type, value) VALUES (?, ?, ?)",
            (yesterday, "git_commits", 3),
        )

        await db.commit()
    return db_path


@pytest.fixture
async def db(tmp_path: Path) -> UseTrackDB:
    """Provide a UseTrackDB connected to a test database."""
    db_path = await _create_test_db(tmp_path)
    udb = UseTrackDB(db_path=db_path)
    await udb.connect()
    yield udb
    await udb.close()


# --- _parse_period ---


class TestParsePeriod:
    def test_today(self):
        udb = UseTrackDB()
        start, end = udb._parse_period("today")
        today = date.today()
        assert start == f"{today.isoformat()}T00:00:00"
        assert end == f"{(today + timedelta(days=1)).isoformat()}T00:00:00"

    def test_yesterday(self):
        udb = UseTrackDB()
        start, end = udb._parse_period("yesterday")
        yesterday = date.today() - timedelta(days=1)
        assert start == f"{yesterday.isoformat()}T00:00:00"
        assert end == f"{date.today().isoformat()}T00:00:00"

    def test_this_week(self):
        udb = UseTrackDB()
        start, end = udb._parse_period("this_week")
        today = date.today()
        monday = today - timedelta(days=today.weekday())
        assert start == f"{monday.isoformat()}T00:00:00"
        assert end == f"{(today + timedelta(days=1)).isoformat()}T00:00:00"

    def test_last_week(self):
        udb = UseTrackDB()
        start, end = udb._parse_period("last_week")
        today = date.today()
        last_sunday = today - timedelta(days=today.weekday() + 1)
        last_monday = last_sunday - timedelta(days=6)
        assert start == f"{last_monday.isoformat()}T00:00:00"
        assert end == f"{(last_sunday + timedelta(days=1)).isoformat()}T00:00:00"

    def test_this_month(self):
        udb = UseTrackDB()
        start, end = udb._parse_period("this_month")
        today = date.today()
        assert start == f"{today.replace(day=1).isoformat()}T00:00:00"
        assert end == f"{(today + timedelta(days=1)).isoformat()}T00:00:00"

    def test_specific_date(self):
        udb = UseTrackDB()
        start, end = udb._parse_period("2026-04-01")
        assert start == "2026-04-01T00:00:00"
        assert end == "2026-04-02T00:00:00"

    def test_date_range(self):
        udb = UseTrackDB()
        start, end = udb._parse_period("2026-04-01:2026-04-07")
        assert start == "2026-04-01T00:00:00"
        assert end == "2026-04-08T00:00:00"


# --- context manager ---


class TestContextManager:
    async def test_async_context_manager(self, tmp_path: Path):
        db_path = await _create_test_db(tmp_path)
        async with UseTrackDB(db_path=db_path) as udb:
            assert udb._db is not None
            result = await udb.get_activity_summary("today")
            assert "total_events" in result
        # After exit, internal connection ref should indicate closed state
        assert udb._db is not None  # ref still exists
        # Verify it's actually closed by checking we can't execute
        with pytest.raises(Exception):
            await udb._db.execute("SELECT 1")


# --- get_activity_summary ---


class TestGetActivitySummary:
    async def test_today_summary(self, db: UseTrackDB):
        result = await db.get_activity_summary("today")
        assert result["period"] == "today"
        assert result["total_events"] > 0
        assert result["unique_apps"] > 0
        assert result["total_active_min"] > 0
        assert len(result["top_apps"]) > 0
        assert len(result["categories"]) > 0

    async def test_yesterday_summary(self, db: UseTrackDB):
        result = await db.get_activity_summary("yesterday")
        assert result["total_events"] > 0

    async def test_empty_period(self, db: UseTrackDB):
        result = await db.get_activity_summary("2020-01-01")
        assert result["total_events"] == 0
        assert result["top_apps"] == []

    async def test_top_apps_ordered_by_minutes(self, db: UseTrackDB):
        result = await db.get_activity_summary("today")
        apps = result["top_apps"]
        for i in range(len(apps) - 1):
            assert apps[i]["minutes"] >= apps[i + 1]["minutes"]

    async def test_category_breakdown(self, db: UseTrackDB):
        result = await db.get_activity_summary("today")
        cat_names = [c["category"] for c in result["categories"]]
        assert "deep_work" in cat_names


# --- query_activities ---


class TestQueryActivities:
    async def test_basic_query(self, db: UseTrackDB):
        today = date.today().isoformat()
        start = f"{today}T00:00:00"
        end = f"{today}T23:59:59"
        results = await db.query_activities(start, end)
        assert len(results) > 0
        assert "ts" in results[0]
        assert "app_name" in results[0]

    async def test_app_filter(self, db: UseTrackDB):
        today = date.today().isoformat()
        results = await db.query_activities(
            f"{today}T00:00:00", f"{today}T23:59:59", app_filter="Cursor"
        )
        for r in results:
            assert "Cursor" in r["app_name"]

    async def test_category_filter(self, db: UseTrackDB):
        today = date.today().isoformat()
        results = await db.query_activities(
            f"{today}T00:00:00", f"{today}T23:59:59", category_filter="deep_work"
        )
        for r in results:
            assert r["category"] == "deep_work"

    async def test_limit(self, db: UseTrackDB):
        today = date.today().isoformat()
        results = await db.query_activities(f"{today}T00:00:00", f"{today}T23:59:59", limit=2)
        assert len(results) <= 2

    async def test_ordered_desc(self, db: UseTrackDB):
        today = date.today().isoformat()
        results = await db.query_activities(f"{today}T00:00:00", f"{today}T23:59:59")
        for i in range(len(results) - 1):
            assert results[i]["ts"] >= results[i + 1]["ts"]


# --- get_focus_metrics ---


class TestGetFocusMetrics:
    async def test_today_metrics(self, db: UseTrackDB):
        result = await db.get_focus_metrics("today")
        assert result["date"] == date.today().isoformat()
        assert result["deep_work_min"] > 0
        assert result["context_switches"] > 0
        assert result["total_active_min"] > 0
        assert 0 <= result["productivity_ratio"] <= 1

    async def test_ping_pong_detected(self, db: UseTrackDB):
        result = await db.get_focus_metrics("today")
        # We inserted switches with duration_s < 5
        assert result["ping_pong_switches"] > 0

    async def test_energy_curve(self, db: UseTrackDB):
        result = await db.get_focus_metrics("today")
        assert isinstance(result["energy_curve"], dict)
        # All keys should be zero-padded hour strings
        for k in result["energy_curve"]:
            assert len(k) == 2
            assert 0 <= int(k) <= 23

    async def test_empty_date(self, db: UseTrackDB):
        result = await db.get_focus_metrics("2020-01-01")
        assert result["deep_work_min"] == 0
        assert result["productivity_ratio"] == 0

    async def test_yesterday(self, db: UseTrackDB):
        result = await db.get_focus_metrics("yesterday")
        assert result["date"] == (date.today() - timedelta(days=1)).isoformat()
        assert result["deep_work_min"] > 0


# --- search_activity ---


class TestSearchActivity:
    async def test_search_by_keyword(self, db: UseTrackDB):
        results = await db.search_activity("Project")
        assert len(results) > 0
        for r in results:
            assert "Project" in (r["window_title"] or "")

    async def test_search_no_results(self, db: UseTrackDB):
        results = await db.search_activity("nonexistent_keyword_xyz")
        assert results == []

    async def test_search_limit(self, db: UseTrackDB):
        results = await db.search_activity("Slack", limit=1)
        assert len(results) <= 1


# --- get_output_metrics ---


class TestGetOutputMetrics:
    async def test_today_metrics(self, db: UseTrackDB):
        result = await db.get_output_metrics("today")
        assert result["period"] == "today"
        assert result.get("git_commits") == 5
        assert result.get("obsidian_words") == 1200

    async def test_date_range(self, db: UseTrackDB):
        today = date.today().isoformat()
        yesterday = (date.today() - timedelta(days=1)).isoformat()
        result = await db.get_output_metrics(f"{yesterday}:{today}")
        assert result.get("git_commits") == 8  # 5 today + 3 yesterday

    async def test_empty_period(self, db: UseTrackDB):
        result = await db.get_output_metrics("2020-01-01")
        # Should not have any metric keys beyond period/start_date/end_date
        assert "git_commits" not in result


# --- get_trends ---


class TestGetTrends:
    async def test_deep_work_trend(self, db: UseTrackDB):
        result = await db.get_trends("deep_work", days=7)
        assert result["metric"] == "deep_work"
        assert result["days"] == 7
        assert isinstance(result["data"], list)
        # Should have data for today (at least)
        dates = [d["date"] for d in result["data"]]
        assert date.today().isoformat() in dates

    async def test_context_switches_trend(self, db: UseTrackDB):
        result = await db.get_trends("context_switches", days=7)
        assert len(result["data"]) > 0

    async def test_active_time_trend(self, db: UseTrackDB):
        result = await db.get_trends("active_time", days=7)
        assert len(result["data"]) > 0

    async def test_output_metric_trend(self, db: UseTrackDB):
        result = await db.get_trends("git_commits", days=7)
        assert len(result["data"]) > 0
        # Should include today's 5 commits
        today_data = [d for d in result["data"] if d["date"] == date.today().isoformat()]
        assert len(today_data) == 1
        assert today_data[0]["value"] == 5


# --- get_distraction_patterns ---


class TestGetDistractionPatterns:
    async def test_today_patterns(self, db: UseTrackDB):
        result = await db.get_distraction_patterns("today")
        assert "frequent_short_switches" in result
        assert "distraction_time_min" in result
        assert "top_transitions" in result

    async def test_distraction_time(self, db: UseTrackDB):
        result = await db.get_distraction_patterns("today")
        # We have browsing and entertainment data
        assert result["distraction_time_min"] > 0

    async def test_short_switches_detected(self, db: UseTrackDB):
        result = await db.get_distraction_patterns("today")
        # Slack has 4 switches with duration < 15s, Chrome has 1 (needs >= 3)
        short_apps = [s["app_name"] for s in result["frequent_short_switches"]]
        assert "Slack" in short_apps

    async def test_empty_period(self, db: UseTrackDB):
        result = await db.get_distraction_patterns("2020-01-01")
        assert result["frequent_short_switches"] == []
        assert result["distraction_time_min"] == 0


# --- _fetchone / _fetchall error handling ---


class TestHelpers:
    async def test_fetchone_without_connect(self):
        udb = UseTrackDB()
        with pytest.raises(AssertionError, match="not connected"):
            await udb._fetchone("SELECT 1")

    async def test_fetchall_without_connect(self):
        udb = UseTrackDB()
        with pytest.raises(AssertionError, match="not connected"):
            await udb._fetchall("SELECT 1")
