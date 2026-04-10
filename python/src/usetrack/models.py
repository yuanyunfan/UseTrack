"""UseTrack data models."""

from datetime import date, datetime

from pydantic import BaseModel


class ActivityEvent(BaseModel):
    id: int | None = None
    timestamp: datetime
    activity: str  # app_switch / url_visit / idle / typing / focus
    app_name: str | None = None
    window_title: str | None = None
    duration_s: float | None = None
    meta: dict | None = None
    category: str | None = None  # deep_work / communication / browsing / entertainment


class DailySummary(BaseModel):
    date: date
    total_active_min: float
    deep_work_min: float
    context_switches: int
    top_apps: list[dict]
    top_urls: list[dict]
    ai_summary: str | None = None
    ai_suggestions: list[str] | None = None


class FocusMetrics(BaseModel):
    date: date
    deep_work_min: float
    context_switches: int
    ping_pong_switches: int
    productivity_ratio: float
    energy_curve: dict[str, float]  # hour -> deep_work_ratio


class OutputMetrics(BaseModel):
    date: date
    obsidian_words: int = 0
    git_commits: int = 0
    git_lines_added: int = 0
    git_lines_removed: int = 0
    code_time_min: float = 0


class WindowSnapshot(BaseModel):
    timestamp: datetime
    screen_index: int
    app_name: str
    window_title: str
    attention: str  # active_focus / active_reference / passive_visible / stale
    score: float
    bounds: dict  # {x, y, w, h}
