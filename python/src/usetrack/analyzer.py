"""UseTrack AI analyzer — activity classification and productivity metrics."""

from __future__ import annotations

from datetime import date
from typing import TYPE_CHECKING

from usetrack.models import DailySummary, FocusMetrics

if TYPE_CHECKING:
    from usetrack.db import UseTrackDB


class ActivityClassifier:
    """Rule-based activity classifier.

    Classification priority:
    URL domain match > window title heuristics (browsers) > app name match > "other"
    """

    # Default app -> category mappings (supplement database app_rules)
    DEFAULT_RULES: dict[str, str] = {
        # deep_work
        "Cursor": "deep_work",
        "Visual Studio Code": "deep_work",
        "Xcode": "deep_work",
        "Terminal": "deep_work",
        "iTerm2": "deep_work",
        "Warp": "deep_work",
        "Obsidian": "deep_work",
        "Notion": "deep_work",
        # communication
        "Slack": "communication",
        "Microsoft Teams": "communication",
        "zoom.us": "communication",
        "Mail": "communication",
        "Microsoft Outlook": "communication",
        # browsing (will be refined by URL)
        "Safari": "browsing",
        "Google Chrome": "browsing",
        "Arc": "browsing",
        "Firefox": "browsing",
        # entertainment
        "Spotify": "entertainment",
        "Music": "entertainment",
        # system
        "Finder": "system",
        "System Settings": "system",
        "Activity Monitor": "system",
        "1Password": "system",
    }

    # URL domain -> category overrides for browsers
    URL_RULES: dict[str, str] = {
        # learning
        "docs.python.org": "learning",
        "developer.apple.com": "learning",
        "stackoverflow.com": "learning",
        "arxiv.org": "learning",
        "github.com": "learning",
        "docs.rs": "learning",
        "learn.microsoft.com": "learning",
        # entertainment
        "twitter.com": "entertainment",
        "x.com": "entertainment",
        "youtube.com": "entertainment",
        "reddit.com": "entertainment",
        "instagram.com": "entertainment",
        "facebook.com": "entertainment",
        "bilibili.com": "entertainment",
        "weibo.com": "entertainment",
        "douyin.com": "entertainment",
        "tiktok.com": "entertainment",
        # communication
        "mail.google.com": "communication",
        "outlook.live.com": "communication",
        "slack.com": "communication",
    }

    def __init__(self, db_rules: dict[str, str] | None = None):
        """Initialize with optional database rules (override defaults)."""
        self.rules = {**self.DEFAULT_RULES}
        if db_rules:
            self.rules.update(db_rules)

    def classify(
        self,
        app_name: str,
        url: str | None = None,
        window_title: str | None = None,
    ) -> str:
        """Classify an activity event.

        Priority: URL domain match > window title heuristics (browsers) > app name match > "other"
        """
        # 1. If URL is available (browser), check URL rules first
        if url:
            domain = self._extract_domain(url)
            for pattern, category in self.URL_RULES.items():
                if pattern in domain:
                    return category

        # 2. For browser apps: try window title heuristics before falling back to "browsing"
        _browsers = {"Google Chrome", "Safari", "Arc", "Firefox"}
        if window_title and app_name in _browsers:
            title_lower = window_title.lower()
            if any(
                kw in title_lower
                for kw in [
                    "stackoverflow", "stack overflow", "github",
                    "docs", "api", "documentation",
                ]
            ):
                return "learning"
            if any(
                kw in title_lower
                for kw in ["twitter", "youtube", "reddit", "bilibili"]
            ):
                return "entertainment"

        # 3. App name match (includes browser fallback to "browsing")
        if app_name in self.rules:
            return self.rules[app_name]

        return "other"

    @staticmethod
    def _extract_domain(url: str) -> str:
        """Extract domain from URL."""
        url = url.lower()
        if "://" in url:
            url = url.split("://", 1)[1]
        return url.split("/", 1)[0]


class MetricsCalculator:
    """Calculate productivity metrics from raw activity data."""

    def __init__(self, db: UseTrackDB):
        self.db = db

    async def calculate_focus_metrics(self, target_date: str = "today") -> FocusMetrics:
        """Calculate all focus metrics for a date."""
        raw = await self.db.get_focus_metrics(target_date)
        return FocusMetrics(
            date=date.fromisoformat(raw["date"]),
            deep_work_min=raw["deep_work_min"],
            context_switches=raw["context_switches"],
            ping_pong_switches=raw["ping_pong_switches"],
            productivity_ratio=raw["productivity_ratio"],
            energy_curve=raw["energy_curve"],
        )

    async def calculate_daily_summary(self, target_date: str = "today") -> DailySummary:
        """Calculate complete daily summary."""
        summary = await self.db.get_activity_summary(target_date)
        focus = await self.db.get_focus_metrics(target_date)

        return DailySummary(
            date=date.fromisoformat(focus["date"]),
            total_active_min=summary["total_active_min"],
            deep_work_min=focus["deep_work_min"],
            context_switches=focus["context_switches"],
            top_apps=summary["top_apps"],
            top_urls=[],  # Will be populated when URL tracking is added
            ai_summary=None,  # Will be generated by reporter
            ai_suggestions=None,
        )

    def detect_deep_work_sessions(self, events: list[dict]) -> list[dict]:
        """Detect continuous deep work sessions (>= 25 min same app, deep_work category).

        Returns list of sessions: [{app, start, end, duration_min}]
        """
        sessions: list[dict] = []
        current_session: dict | None = None

        for event in events:
            if event.get("category") == "deep_work" and event.get("duration_s"):
                if current_session and current_session["app"] == event["app_name"]:
                    # Extend current session
                    current_session["end"] = event["ts"]
                    current_session["duration_s"] += event["duration_s"]
                else:
                    # Save previous session if long enough
                    if current_session and current_session["duration_s"] >= 1500:  # 25 min
                        current_session["duration_min"] = round(
                            current_session["duration_s"] / 60, 1
                        )
                        sessions.append(current_session)
                    # Start new session
                    current_session = {
                        "app": event["app_name"],
                        "start": event["ts"],
                        "end": event["ts"],
                        "duration_s": event["duration_s"],
                    }
            else:
                # Non-deep-work event breaks the session
                if current_session and current_session["duration_s"] >= 1500:
                    current_session["duration_min"] = round(
                        current_session["duration_s"] / 60, 1
                    )
                    sessions.append(current_session)
                current_session = None

        # Don't forget the last session
        if current_session and current_session["duration_s"] >= 1500:
            current_session["duration_min"] = round(current_session["duration_s"] / 60, 1)
            sessions.append(current_session)

        return sessions
