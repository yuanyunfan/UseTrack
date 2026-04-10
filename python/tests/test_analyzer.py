"""Tests for UseTrack analyzer — ActivityClassifier and MetricsCalculator."""

import pytest

from usetrack.analyzer import ActivityClassifier, MetricsCalculator

# ============================================================
# ActivityClassifier tests
# ============================================================


class TestActivityClassifier:
    """Tests for rule-based activity classification."""

    def setup_method(self) -> None:
        self.classifier = ActivityClassifier()

    # --- App name matching ---

    @pytest.mark.parametrize(
        ("app_name", "expected"),
        [
            ("Cursor", "deep_work"),
            ("Visual Studio Code", "deep_work"),
            ("Xcode", "deep_work"),
            ("Terminal", "deep_work"),
            ("iTerm2", "deep_work"),
            ("Warp", "deep_work"),
            ("Obsidian", "deep_work"),
            ("Notion", "deep_work"),
        ],
    )
    def test_deep_work_apps(self, app_name: str, expected: str) -> None:
        assert self.classifier.classify(app_name) == expected

    @pytest.mark.parametrize(
        ("app_name", "expected"),
        [
            ("Slack", "communication"),
            ("Microsoft Teams", "communication"),
            ("zoom.us", "communication"),
            ("Mail", "communication"),
            ("Microsoft Outlook", "communication"),
        ],
    )
    def test_communication_apps(self, app_name: str, expected: str) -> None:
        assert self.classifier.classify(app_name) == expected

    @pytest.mark.parametrize(
        ("app_name", "expected"),
        [
            ("Safari", "browsing"),
            ("Google Chrome", "browsing"),
            ("Arc", "browsing"),
            ("Firefox", "browsing"),
        ],
    )
    def test_browsing_apps(self, app_name: str, expected: str) -> None:
        assert self.classifier.classify(app_name) == expected

    @pytest.mark.parametrize(
        ("app_name", "expected"),
        [
            ("Spotify", "entertainment"),
            ("Music", "entertainment"),
        ],
    )
    def test_entertainment_apps(self, app_name: str, expected: str) -> None:
        assert self.classifier.classify(app_name) == expected

    @pytest.mark.parametrize(
        ("app_name", "expected"),
        [
            ("Finder", "system"),
            ("System Settings", "system"),
            ("Activity Monitor", "system"),
            ("1Password", "system"),
        ],
    )
    def test_system_apps(self, app_name: str, expected: str) -> None:
        assert self.classifier.classify(app_name) == expected

    def test_unknown_app_returns_other(self) -> None:
        assert self.classifier.classify("SomeRandomApp") == "other"

    # --- URL domain matching (overrides app category) ---

    @pytest.mark.parametrize(
        ("url", "expected"),
        [
            ("https://github.com/yuanyunfan/repo", "learning"),
            ("https://stackoverflow.com/questions/12345", "learning"),
            ("https://docs.python.org/3/library/asyncio.html", "learning"),
            ("https://developer.apple.com/documentation/swiftui", "learning"),
            ("https://arxiv.org/abs/2301.00001", "learning"),
            ("https://docs.rs/tokio/latest", "learning"),
            ("https://learn.microsoft.com/en-us/azure/", "learning"),
        ],
    )
    def test_url_learning_overrides_browsing(self, url: str, expected: str) -> None:
        # Chrome defaults to "browsing", but URL should override to "learning"
        result = self.classifier.classify("Google Chrome", url=url)
        assert result == expected

    @pytest.mark.parametrize(
        ("url", "expected"),
        [
            ("https://twitter.com/home", "entertainment"),
            ("https://x.com/elonmusk", "entertainment"),
            ("https://www.youtube.com/watch?v=abc", "entertainment"),
            ("https://www.reddit.com/r/python", "entertainment"),
            ("https://www.bilibili.com/video/BV123", "entertainment"),
            ("https://www.instagram.com/", "entertainment"),
            ("https://weibo.com/u/12345", "entertainment"),
            ("https://www.tiktok.com/@user", "entertainment"),
        ],
    )
    def test_url_entertainment_overrides_browsing(self, url: str, expected: str) -> None:
        result = self.classifier.classify("Safari", url=url)
        assert result == expected

    @pytest.mark.parametrize(
        ("url", "expected"),
        [
            ("https://mail.google.com/mail/u/0/", "communication"),
            ("https://outlook.live.com/mail/", "communication"),
            ("https://app.slack.com/client/T123/C456", "communication"),
        ],
    )
    def test_url_communication_overrides_browsing(self, url: str, expected: str) -> None:
        result = self.classifier.classify("Google Chrome", url=url)
        assert result == expected

    def test_url_takes_priority_over_app(self) -> None:
        """URL domain match should override app name match."""
        # Chrome is "browsing" by default, but github.com -> "learning"
        assert self.classifier.classify("Google Chrome", url="https://github.com") == "learning"
        # Even for a non-browser app with URL (edge case)
        assert self.classifier.classify("SomeApp", url="https://twitter.com") == "entertainment"

    def test_unknown_url_falls_back_to_app(self) -> None:
        """Unknown URL domain should fall back to app name match."""
        result = self.classifier.classify(
            "Google Chrome", url="https://some-random-site.com/page"
        )
        assert result == "browsing"

    # --- Window title heuristics ---

    @pytest.mark.parametrize(
        ("title", "expected"),
        [
            ("How to use asyncio — Stack Overflow", "learning"),
            ("yuanyunfan/usetrack: GitHub", "learning"),
            ("Python Documentation — asyncio", "learning"),
            ("API Reference — FastMCP", "learning"),
        ],
    )
    def test_window_title_learning_heuristics(self, title: str, expected: str) -> None:
        # No URL, so falls through to window title heuristics
        result = self.classifier.classify("Google Chrome", window_title=title)
        assert result == expected

    @pytest.mark.parametrize(
        ("title", "expected"),
        [
            ("Twitter / X", "entertainment"),
            ("YouTube - Funny video", "entertainment"),
            ("reddit - The front page", "entertainment"),
            ("哔哩哔哩 bilibili 热门视频", "entertainment"),
        ],
    )
    def test_window_title_entertainment_heuristics(self, title: str, expected: str) -> None:
        result = self.classifier.classify("Safari", window_title=title)
        assert result == expected

    def test_window_title_only_for_browsers(self) -> None:
        """Window title heuristics should only apply to browser apps."""
        # Cursor is deep_work, title heuristics should not apply
        result = self.classifier.classify("Cursor", window_title="stackoverflow.com")
        assert result == "deep_work"

    def test_window_title_not_used_when_url_matches(self) -> None:
        """URL match takes priority over window title heuristics."""
        result = self.classifier.classify(
            "Google Chrome",
            url="https://github.com/repo",
            window_title="YouTube - Video",
        )
        assert result == "learning"  # URL wins

    # --- Database rules override ---

    def test_db_rules_override_defaults(self) -> None:
        """Database rules should override default app rules."""
        classifier = ActivityClassifier(db_rules={"Cursor": "entertainment"})
        assert classifier.classify("Cursor") == "entertainment"

    def test_db_rules_add_new_apps(self) -> None:
        """Database rules can add new app mappings."""
        classifier = ActivityClassifier(db_rules={"MyCustomApp": "deep_work"})
        assert classifier.classify("MyCustomApp") == "deep_work"

    def test_db_rules_none_uses_defaults(self) -> None:
        """None db_rules should use defaults only."""
        classifier = ActivityClassifier(db_rules=None)
        assert classifier.classify("Cursor") == "deep_work"


# ============================================================
# _extract_domain tests
# ============================================================


class TestExtractDomain:
    """Tests for URL domain extraction."""

    @pytest.mark.parametrize(
        ("url", "expected"),
        [
            ("https://github.com/user/repo", "github.com"),
            ("http://docs.python.org/3/library/", "docs.python.org"),
            ("https://www.youtube.com/watch?v=abc", "www.youtube.com"),
            ("github.com/user/repo", "github.com"),
            ("HTTPS://GitHub.COM/user/repo", "github.com"),
            ("https://mail.google.com/mail/u/0/", "mail.google.com"),
            ("ftp://files.example.com/data", "files.example.com"),
        ],
    )
    def test_extract_domain(self, url: str, expected: str) -> None:
        assert ActivityClassifier._extract_domain(url) == expected

    def test_extract_domain_no_path(self) -> None:
        assert ActivityClassifier._extract_domain("https://example.com") == "example.com"

    def test_extract_domain_no_protocol(self) -> None:
        assert ActivityClassifier._extract_domain("example.com") == "example.com"

    def test_extract_domain_with_port(self) -> None:
        assert ActivityClassifier._extract_domain("http://localhost:8080/api") == "localhost:8080"


# ============================================================
# MetricsCalculator.detect_deep_work_sessions tests
# ============================================================


class TestDetectDeepWorkSessions:
    """Tests for deep work session detection."""

    def setup_method(self) -> None:
        # MetricsCalculator needs a db, but detect_deep_work_sessions is pure
        # We pass None since we don't call async db methods
        self.calc = MetricsCalculator(db=None)  # type: ignore[arg-type]

    def test_single_long_session(self) -> None:
        """A single continuous deep work session >= 25 min should be detected."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 900,
                "ts": "2026-04-10T09:00:00",
            },
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 900,
                "ts": "2026-04-10T09:15:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 1
        assert sessions[0]["app"] == "Cursor"
        assert sessions[0]["duration_min"] == 30.0

    def test_session_too_short(self) -> None:
        """Sessions shorter than 25 min should not be detected."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 600,
                "ts": "2026-04-10T09:00:00",
            },
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 600,
                "ts": "2026-04-10T09:10:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 0

    def test_multiple_sessions_different_apps(self) -> None:
        """Different deep_work apps should create separate sessions."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 1800,
                "ts": "2026-04-10T09:00:00",
            },
            {
                "app_name": "Xcode",
                "category": "deep_work",
                "duration_s": 1800,
                "ts": "2026-04-10T09:30:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 2
        assert sessions[0]["app"] == "Cursor"
        assert sessions[1]["app"] == "Xcode"

    def test_non_deep_work_breaks_session(self) -> None:
        """Non-deep-work events should break a session."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 1200,
                "ts": "2026-04-10T09:00:00",
            },
            {
                "app_name": "Slack",
                "category": "communication",
                "duration_s": 60,
                "ts": "2026-04-10T09:20:00",
            },
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 1200,
                "ts": "2026-04-10T09:21:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        # Each Cursor segment is only 20 min, below 25 min threshold
        assert len(sessions) == 0

    def test_empty_events(self) -> None:
        """Empty event list should return no sessions."""
        assert self.calc.detect_deep_work_sessions([]) == []

    def test_no_deep_work_events(self) -> None:
        """Events without deep_work category should return no sessions."""
        events = [
            {
                "app_name": "Slack",
                "category": "communication",
                "duration_s": 3600,
                "ts": "2026-04-10T09:00:00",
            },
        ]
        assert self.calc.detect_deep_work_sessions(events) == []

    def test_events_without_duration(self) -> None:
        """Events with no duration_s should not contribute to sessions."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": None,
                "ts": "2026-04-10T09:00:00",
            },
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 1800,
                "ts": "2026-04-10T09:30:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 1
        assert sessions[0]["duration_min"] == 30.0

    def test_session_timestamps(self) -> None:
        """Session should track start and end timestamps correctly."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 900,
                "ts": "2026-04-10T09:00:00",
            },
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 900,
                "ts": "2026-04-10T09:15:00",
            },
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 900,
                "ts": "2026-04-10T09:30:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 1
        assert sessions[0]["start"] == "2026-04-10T09:00:00"
        assert sessions[0]["end"] == "2026-04-10T09:30:00"
        assert sessions[0]["duration_min"] == 45.0

    def test_last_session_captured(self) -> None:
        """The last session in the event list should be captured if long enough."""
        events = [
            {
                "app_name": "Slack",
                "category": "communication",
                "duration_s": 60,
                "ts": "2026-04-10T08:00:00",
            },
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 1800,
                "ts": "2026-04-10T09:00:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 1
        assert sessions[0]["app"] == "Cursor"

    def test_exactly_25_min_threshold(self) -> None:
        """Exactly 25 min (1500s) should be included."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 1500,
                "ts": "2026-04-10T09:00:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 1
        assert sessions[0]["duration_min"] == 25.0

    def test_just_below_25_min_threshold(self) -> None:
        """Just below 25 min (1499s) should NOT be included."""
        events = [
            {
                "app_name": "Cursor",
                "category": "deep_work",
                "duration_s": 1499,
                "ts": "2026-04-10T09:00:00",
            },
        ]
        sessions = self.calc.detect_deep_work_sessions(events)
        assert len(sessions) == 0
