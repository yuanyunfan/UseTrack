"""Tests for UseTrack reporter — DailyReporter and DistractionAnalyzer."""

from __future__ import annotations

from usetrack.reporter import DailyReporter, DistractionAnalyzer

# ============================================================
# DailyReporter._format_duration
# ============================================================


class TestFormatDuration:
    def test_zero(self):
        assert DailyReporter._format_duration(0) == "0min"

    def test_none_like(self):
        assert DailyReporter._format_duration(0.0) == "0min"

    def test_minutes_only(self):
        assert DailyReporter._format_duration(45) == "45min"

    def test_hours_and_minutes(self):
        assert DailyReporter._format_duration(125) == "2h 5min"

    def test_exact_hour(self):
        assert DailyReporter._format_duration(60) == "1h 0min"

    def test_large_value(self):
        assert DailyReporter._format_duration(600) == "10h 0min"

    def test_fractional_minutes(self):
        # 90.7 -> 1h 30min (int truncation)
        assert DailyReporter._format_duration(90.7) == "1h 30min"


# ============================================================
# DailyReporter._trend_arrow
# ============================================================


class TestTrendArrow:
    def test_no_average(self):
        assert DailyReporter._trend_arrow(100, 0) == ""

    def test_stable(self):
        # Less than 5% diff -> →
        assert DailyReporter._trend_arrow(100, 98) == "\u2192"

    def test_increase(self):
        assert DailyReporter._trend_arrow(120, 100) == "\u2191"

    def test_decrease(self):
        assert DailyReporter._trend_arrow(80, 100) == "\u2193"

    def test_lower_is_better_decrease(self):
        # current < average with lower_is_better -> good
        result = DailyReporter._trend_arrow(80, 100, lower_is_better=True)
        assert "\u2193" in result
        assert "\u597d" in result

    def test_lower_is_better_increase(self):
        # current > average with lower_is_better -> bad (just up arrow)
        result = DailyReporter._trend_arrow(120, 100, lower_is_better=True)
        assert result == "\u2191"

    def test_exactly_5_percent(self):
        # Exactly 5% diff -> abs(5) < 5 is False, so treated as increase
        assert DailyReporter._trend_arrow(105, 100) == "\u2191"

    def test_just_over_5_percent(self):
        assert DailyReporter._trend_arrow(106, 100) == "\u2191"


# ============================================================
# DailyReporter._format_energy_curve
# ============================================================


class TestFormatEnergyCurve:
    def test_empty_curve(self):
        bars = DailyReporter._format_energy_curve({})
        # Should have entries for 8:00 - 22:00 = 15 hours
        assert len(bars) == 15
        # All should be empty bars
        for hour_str, bar in bars:
            assert "\u2591" * 12 in bar

    def test_full_deep_work(self):
        curve = {"10": 1.0}
        bars = DailyReporter._format_energy_curve(curve)
        # Find hour 10
        bar_10 = [b for h, b in bars if h == "10"][0]
        assert "\u2588" * 12 in bar_10
        assert "\u6df1\u5ea6\u5de5\u4f5c" in bar_10

    def test_mixed_work(self):
        curve = {"14": 0.5}
        bars = DailyReporter._format_energy_curve(curve)
        bar_14 = [b for h, b in bars if h == "14"][0]
        assert "\u6df7\u5408" in bar_14

    def test_low_ratio(self):
        curve = {"09": 0.1}
        bars = DailyReporter._format_energy_curve(curve)
        bar_09 = [b for h, b in bars if h == "09"][0]
        # ratio < 0.3 -> no label
        assert "\u6df1\u5ea6\u5de5\u4f5c" not in bar_09
        assert "\u6df7\u5408" not in bar_09

    def test_hour_range(self):
        bars = DailyReporter._format_energy_curve({})
        hours = [h for h, _ in bars]
        assert hours[0] == "08"
        assert hours[-1] == "22"

    def test_none_value_treated_as_zero(self):
        curve = {"11": None}
        bars = DailyReporter._format_energy_curve(curve)
        bar_11 = [b for h, b in bars if h == "11"][0]
        assert "\u2591" * 12 in bar_11


# ============================================================
# DailyReporter._generate_suggestions
# ============================================================


class TestGenerateSuggestions:
    def test_excellent_deep_work(self):
        suggestions = DailyReporter._generate_suggestions(200, 50, 2, {}, 400)
        assert any("\u2705" in s for s in suggestions)

    def test_low_deep_work(self):
        suggestions = DailyReporter._generate_suggestions(30, 50, 2, {}, 400)
        assert any("\u4e0d\u8db3 1 \u5c0f\u65f6" in s for s in suggestions)

    def test_high_context_switches(self):
        suggestions = DailyReporter._generate_suggestions(100, 150, 2, {}, 400)
        assert any("\u5207\u6362\u8fc7\u4e8e\u9891\u7e41" in s for s in suggestions)

    def test_ping_pong_warning(self):
        suggestions = DailyReporter._generate_suggestions(100, 50, 10, {}, 400)
        assert any("\u4e52\u4e53\u5207\u6362" in s for s in suggestions)

    def test_high_distraction(self):
        distraction = {"distraction_time_min": 90}
        suggestions = DailyReporter._generate_suggestions(100, 50, 2, distraction, 400)
        assert any("Focus Mode" in s for s in suggestions)

    def test_low_productivity_ratio(self):
        # deep_work / total < 0.3
        suggestions = DailyReporter._generate_suggestions(50, 50, 2, {}, 300)
        assert any("\u756a\u8304\u949f" in s for s in suggestions)

    def test_no_suggestions_for_normal(self):
        # Moderate values -> only the "excellent" or ratio-based checks
        suggestions = DailyReporter._generate_suggestions(120, 80, 3, {}, 300)
        # Should not have any warning/distraction suggestions
        assert not any("\u26a0\ufe0f \u4e0a\u4e0b\u6587\u5207\u6362" in s for s in suggestions)
        assert not any("\u4e52\u4e53\u5207\u6362" in s for s in suggestions)

    def test_zero_total_min(self):
        # Edge case: total_min = 0 -> no division error
        suggestions = DailyReporter._generate_suggestions(0, 0, 0, {}, 0)
        assert isinstance(suggestions, list)


# ============================================================
# DailyReporter._format_distraction
# ============================================================


class TestFormatDistraction:
    def test_empty_data(self):
        result = DailyReporter._format_distraction({})
        assert result is None

    def test_distraction_time(self):
        data = {"distraction_time_min": 45}
        result = DailyReporter._format_distraction(data)
        assert result is not None
        assert "45" in result
        assert "\u5a31\u4e50" in result

    def test_short_switches(self):
        data = {
            "frequent_short_switches": [
                {"app_name": "Slack", "count": 15},
                {"app_name": "Chrome", "count": 10},
            ]
        }
        result = DailyReporter._format_distraction(data)
        assert result is not None
        assert "Slack" in result
        assert "\u9891\u7e41\u77ed\u5207\u6362" in result

    def test_transitions(self):
        data = {
            "top_transitions": [
                {"from_app": "VSCode", "to_app": "Chrome"},
            ]
        }
        result = DailyReporter._format_distraction(data)
        assert result is not None
        assert "VSCode" in result
        assert "\u5207\u6362\u94fe" in result

    def test_zero_distraction_time(self):
        data = {"distraction_time_min": 0}
        result = DailyReporter._format_distraction(data)
        assert result is None

    def test_none_distraction_time(self):
        data = {"distraction_time_min": None}
        result = DailyReporter._format_distraction(data)
        assert result is None


# ============================================================
# DistractionAnalyzer._generate_distraction_tips
# ============================================================


class TestGenerateDistractionTips:
    def test_worst_app(self):
        tips = DistractionAnalyzer._generate_distraction_tips({}, "Twitter", [])
        assert len(tips) == 1
        assert "Twitter" in tips[0]
        assert "\u5e72\u6270\u6e90" in tips[0]

    def test_worst_hours(self):
        tips = DistractionAnalyzer._generate_distraction_tips({}, None, ["14", "15", "16"])
        assert len(tips) == 1
        assert "14:00" in tips[0]
        assert "\u4f4e\u6548\u65f6\u6bb5" in tips[0]

    def test_high_distraction_time(self):
        patterns = {"distraction_time_min": 45}
        tips = DistractionAnalyzer._generate_distraction_tips(patterns, None, [])
        assert len(tips) == 1
        assert "45" in tips[0]
        assert "\u9650\u989d" in tips[0]

    def test_low_distraction_time_no_tip(self):
        patterns = {"distraction_time_min": 20}
        tips = DistractionAnalyzer._generate_distraction_tips(patterns, None, [])
        assert len(tips) == 0

    def test_all_combined(self):
        patterns = {"distraction_time_min": 60}
        tips = DistractionAnalyzer._generate_distraction_tips(
            patterns, "Slack", ["09", "10"]
        )
        assert len(tips) == 3

    def test_empty_inputs(self):
        tips = DistractionAnalyzer._generate_distraction_tips({}, None, [])
        assert tips == []
