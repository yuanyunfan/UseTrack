"""Tests for UseTrack data models."""

from datetime import date, datetime

from usetrack.models import ActivityEvent, DailySummary, FocusMetrics


def test_activity_event_creation():
    event = ActivityEvent(
        timestamp=datetime.now(),
        activity="app_switch",
        app_name="Cursor",
        window_title="main.swift — UseTrack",
    )
    assert event.activity == "app_switch"
    assert event.app_name == "Cursor"
    assert event.id is None
    assert event.category is None


def test_daily_summary_creation():
    summary = DailySummary(
        date=date.today(),
        total_active_min=450.0,
        deep_work_min=180.0,
        context_switches=86,
        top_apps=[{"app": "Cursor", "minutes": 180}],
        top_urls=[{"domain": "github.com", "minutes": 30}],
    )
    assert summary.deep_work_min == 180.0
    assert len(summary.top_apps) == 1


def test_focus_metrics_creation():
    metrics = FocusMetrics(
        date=date.today(),
        deep_work_min=198.0,
        context_switches=86,
        ping_pong_switches=3,
        productivity_ratio=0.44,
        energy_curve={"09": 0.9, "10": 1.0, "11": 1.0, "12": 0.3},
    )
    assert metrics.productivity_ratio == 0.44
