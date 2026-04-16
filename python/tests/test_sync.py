"""Tests for UseTrack multi-machine sync: config, export, and merged queries."""

from datetime import date, timedelta
from pathlib import Path

import aiosqlite

from usetrack.sync import MergedDB, export_today, load_sync_config

SCHEMA_PATH = Path(__file__).resolve().parents[2] / "db" / "schema.sql"


# --- Fixtures ---


async def _create_test_db(tmp_path: Path, name: str = "test.db", day_offset: int = 0) -> Path:
    """Create a test DB with sample data."""
    db_path = tmp_path / name
    async with aiosqlite.connect(db_path) as db:
        schema = SCHEMA_PATH.read_text()
        await db.executescript(schema)

        d = (date.today() - timedelta(days=day_offset)).isoformat()

        activities = [
            (f"{d}T09:00:00", "app_switch", "Cursor", "main.py", 1800, "deep_work"),
            (f"{d}T09:30:00", "app_switch", "Slack", "General", 60, "communication"),
            (f"{d}T09:31:00", "app_switch", "Cursor", "utils.py", 2700, "deep_work"),
        ]
        for ts, activity, app, title, dur, cat in activities:
            await db.execute(
                """INSERT INTO activity_stream
                   (ts, activity, app_name, window_title, duration_s, category)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (ts, activity, app, title, dur, cat),
            )

        await db.execute(
            "INSERT INTO output_metrics (date, metric_type, value) VALUES (?, ?, ?)",
            (d, "git_commits", 5),
        )
        await db.commit()
    return db_path


# --- Config tests ---


class TestSyncConfig:
    def test_load_missing_config(self, tmp_path: Path, monkeypatch):
        """No config file → returns None."""
        monkeypatch.setattr("usetrack.sync.SYNC_CONFIG_PATH", tmp_path / "nonexistent.toml")
        assert load_sync_config() is None

    def test_load_disabled_config(self, tmp_path: Path, monkeypatch):
        """enabled = false → returns None."""
        cfg = tmp_path / "sync.toml"
        cfg.write_text('[sync]\nmachine_id = "test"\nsync_dir = "/tmp/sync"\nenabled = false\n')
        monkeypatch.setattr("usetrack.sync.SYNC_CONFIG_PATH", cfg)
        assert load_sync_config() is None

    def test_load_valid_config(self, tmp_path: Path, monkeypatch):
        """Valid config → returns dict with all fields."""
        cfg = tmp_path / "sync.toml"
        cfg.write_text(
            '[sync]\nmachine_id = "personal"\n'
            'sync_dir = "/tmp/UseTrack"\nenabled = true\n'
            "export_interval_min = 15\n"
        )
        monkeypatch.setattr("usetrack.sync.SYNC_CONFIG_PATH", cfg)
        result = load_sync_config()
        assert result is not None
        assert result["machine_id"] == "personal"
        assert result["sync_dir"] == Path("/tmp/UseTrack")
        assert result["export_interval_min"] == 15

    def test_load_config_missing_fields(self, tmp_path: Path, monkeypatch):
        """Missing machine_id → returns None."""
        cfg = tmp_path / "sync.toml"
        cfg.write_text('[sync]\nsync_dir = "/tmp/sync"\nenabled = true\n')
        monkeypatch.setattr("usetrack.sync.SYNC_CONFIG_PATH", cfg)
        assert load_sync_config() is None


# --- Export tests ---


class TestExport:
    async def test_export_creates_db(self, tmp_path: Path):
        """Export creates a .db file with today's data."""
        source = await _create_test_db(tmp_path, "source.db")
        sync_dir = tmp_path / "sync"

        out = export_today(
            source_db=source,
            sync_dir=sync_dir,
            machine_id="test_machine",
            target_date=date.today(),
        )

        assert out.exists()
        assert out.name == f"{date.today().isoformat()}.db"
        assert out.parent.name == "test_machine"

        # Verify data was exported
        import sqlite3

        conn = sqlite3.connect(str(out))
        count = conn.execute("SELECT COUNT(*) FROM activity_stream").fetchone()[0]
        assert count == 3  # 3 activities inserted
        metrics = conn.execute("SELECT COUNT(*) FROM output_metrics").fetchone()[0]
        assert metrics == 1
        conn.close()

    async def test_export_only_target_date(self, tmp_path: Path):
        """Export only includes data for the target date, not other days."""
        source = await _create_test_db(tmp_path, "source.db")
        # Add yesterday's data too
        async with aiosqlite.connect(source) as db:
            yesterday = (date.today() - timedelta(days=1)).isoformat()
            await db.execute(
                """INSERT INTO activity_stream
                   (ts, activity, app_name, window_title, duration_s, category)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (f"{yesterday}T10:00:00", "app_switch", "Chrome", "Old", 300, "browsing"),
            )
            await db.commit()

        sync_dir = tmp_path / "sync"
        out = export_today(
            source_db=source,
            sync_dir=sync_dir,
            machine_id="m1",
            target_date=date.today(),
        )

        import sqlite3

        conn = sqlite3.connect(str(out))
        count = conn.execute("SELECT COUNT(*) FROM activity_stream").fetchone()[0]
        assert count == 3  # Only today's data
        conn.close()

    async def test_export_atomic_replace(self, tmp_path: Path):
        """Running export twice overwrites cleanly."""
        source = await _create_test_db(tmp_path, "source.db")
        sync_dir = tmp_path / "sync"

        out1 = export_today(
            source_db=source, sync_dir=sync_dir, machine_id="m1", target_date=date.today()
        )
        out2 = export_today(
            source_db=source, sync_dir=sync_dir, machine_id="m1", target_date=date.today()
        )
        assert out1 == out2
        assert out1.exists()
        # No .tmp file left
        assert not (out1.parent / f"{date.today().isoformat()}.db.tmp").exists()


# --- MergedDB tests ---


class TestMergedDB:
    async def _setup_merged(self, tmp_path: Path) -> tuple[MergedDB, Path]:
        """Create local DB + remote DB, return MergedDB instance."""
        local_db = await _create_test_db(tmp_path, "local.db")
        sync_dir = tmp_path / "sync"

        # Create a "remote" machine's exported DB
        remote_dir = sync_dir / "work"
        remote_dir.mkdir(parents=True)
        remote_path = remote_dir / f"{date.today().isoformat()}.db"

        async with aiosqlite.connect(remote_path) as db:
            await db.executescript("""
                CREATE TABLE activity_stream (
                    id INTEGER PRIMARY KEY, ts DATETIME NOT NULL,
                    activity TEXT NOT NULL, app_name TEXT, window_title TEXT,
                    duration_s REAL, meta JSON, category TEXT
                );
                CREATE TABLE output_metrics (
                    id INTEGER PRIMARY KEY, date DATE NOT NULL,
                    metric_type TEXT NOT NULL, value REAL NOT NULL, details JSON
                );
            """)
            d = date.today().isoformat()
            await db.execute(
                """INSERT INTO activity_stream
                   (ts, activity, app_name, window_title, duration_s, category)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (f"{d}T10:00:00", "app_switch", "PyCharm", "project.py", 3600, "deep_work"),
            )
            await db.execute(
                """INSERT INTO activity_stream
                   (ts, activity, app_name, window_title, duration_s, category)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (f"{d}T11:00:00", "app_switch", "Slack", "Team", 120, "communication"),
            )
            await db.execute(
                "INSERT INTO output_metrics (date, metric_type, value) VALUES (?, ?, ?)",
                (d, "git_commits", 3),
            )
            await db.commit()

        merged = MergedDB(db_path=local_db, sync_dir=sync_dir, machine_id="personal")
        await merged.connect()
        return merged, sync_dir

    async def test_activity_summary_merged(self, tmp_path: Path):
        """Activity summary combines local + remote data."""
        merged, _ = await self._setup_merged(tmp_path)
        try:
            result = await merged.get_activity_summary("today")
            # Local: 1800+60+2700 = 4560s = 76min events, Remote: 3600+120 = 3720s = 62min
            # Total should be > local-only
            assert result["total_active_min"] > 70  # local alone is 76
            assert result["total_events"] >= 5  # 3 local + 2 remote
        finally:
            await merged.close()

    async def test_focus_metrics_merged(self, tmp_path: Path):
        """Focus metrics combine deep work from both machines."""
        merged, _ = await self._setup_merged(tmp_path)
        try:
            result = await merged.get_focus_metrics("today")
            # Local deep_work: 1800+2700 = 4500s = 75min
            # Remote deep_work: 3600s = 60min
            # Merged should be ~135min
            assert result["deep_work_min"] >= 130
        finally:
            await merged.close()

    async def test_output_metrics_merged(self, tmp_path: Path):
        """Output metrics sum across machines."""
        merged, _ = await self._setup_merged(tmp_path)
        try:
            result = await merged.get_output_metrics("today")
            # Local: 5 commits, Remote: 3 commits
            assert result.get("git_commits", 0) == 8
        finally:
            await merged.close()

    async def test_trends_merged(self, tmp_path: Path):
        """Trends merge daily values across machines."""
        merged, _ = await self._setup_merged(tmp_path)
        try:
            result = await merged.get_trends("active_time", days=1)
            # Should have today's combined data
            assert len(result["data"]) >= 1
            today_val = result["data"][0]["value"]
            # Local: 76min, Remote: 62min → ~138min
            assert today_val > 100
        finally:
            await merged.close()

    async def test_no_remote_dbs_fallback(self, tmp_path: Path):
        """Without remote DBs, MergedDB behaves like UseTrackDB."""
        local_db = await _create_test_db(tmp_path, "local.db")
        merged = MergedDB(
            db_path=local_db, sync_dir=tmp_path / "empty_sync", machine_id="personal"
        )
        await merged.connect()
        try:
            result = await merged.get_activity_summary("today")
            assert result["total_events"] == 3
        finally:
            await merged.close()

    async def test_skips_own_machine(self, tmp_path: Path):
        """MergedDB skips its own machine_id directory."""
        local_db = await _create_test_db(tmp_path, "local.db")
        sync_dir = tmp_path / "sync"
        # Create a DB under own machine_id — should be skipped
        own_dir = sync_dir / "personal"
        own_dir.mkdir(parents=True)
        async with aiosqlite.connect(own_dir / f"{date.today().isoformat()}.db") as db:
            await db.executescript("""
                CREATE TABLE activity_stream (
                    id INTEGER PRIMARY KEY, ts DATETIME NOT NULL,
                    activity TEXT NOT NULL, app_name TEXT, window_title TEXT,
                    duration_s REAL, meta JSON, category TEXT
                );
            """)
            d = date.today().isoformat()
            await db.execute(
                """INSERT INTO activity_stream
                   (ts, activity, app_name, window_title, duration_s, category)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (f"{d}T12:00:00", "app_switch", "Xcode", "xxx", 9999, "deep_work"),
            )
            await db.commit()

        merged = MergedDB(db_path=local_db, sync_dir=sync_dir, machine_id="personal")
        await merged.connect()
        try:
            result = await merged.get_activity_summary("today")
            # Should NOT include the 9999s from own machine's sync dir
            assert result["total_active_min"] < 200  # 76min local only
        finally:
            await merged.close()
