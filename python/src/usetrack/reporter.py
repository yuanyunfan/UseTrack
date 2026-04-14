"""UseTrack reporter — generate daily Obsidian efficiency reports."""

from __future__ import annotations

import asyncio
import os
from datetime import date, datetime, timedelta
from pathlib import Path

from jinja2 import Template

from usetrack.db import UseTrackDB

OBSIDIAN_VAULT = Path.home() / "Documents" / "NotionSync"
DAILY_NOTES_DIR = OBSIDIAN_VAULT / "00-Inbox"

# Jinja2 template for daily report
REPORT_TEMPLATE = Template(
    """\
## :bar_chart: 效率报告 — {{ date }}

### 关键指标
| 指标 | 今日 | 7日均值 | 趋势 |
|------|------|--------|------|
| 活跃时长 | {{ total_active }} | {{ avg_active }} | {{ trend_active }} |
| 深度工作 | {{ deep_work }} | {{ avg_deep_work }} | {{ trend_deep_work }} |
| 生产力比 | {{ productivity_pct }}% | {{ avg_productivity_pct }}% | {{ trend_productivity }} |
| 上下文切换 | {{ context_switches }} 次 | {{ avg_switches }} 次 | {{ trend_switches }} |
| 乒乓切换 | {{ ping_pong }} 次 | {{ avg_ping_pong }} 次 | {{ trend_ping_pong }} |

### 时间分配
{% for app in top_apps %}- {{ app.icon }} {{ app.app_name }}: {{ app.minutes }}min ({{ app.category }})
{% endfor %}

### 能量曲线
{% for hour, bar in energy_bars %}{{ hour }}:00 {{ bar }}
{% endfor %}

{% if output_metrics %}### 产出
{% for key, value in output_metrics.items() %}- {{ key }}: {{ value }}
{% endfor %}{% endif %}

{% if distraction_summary %}### 干扰分析
{{ distraction_summary }}
{% endif %}

{% if suggestions %}### AI 洞察
{% for s in suggestions %}{{ loop.index }}. {{ s }}
{% endfor %}{% endif %}

{% if ai_summary %}### 深度分析 (Claude)
{{ ai_summary }}
{% endif %}

---
*由 UseTrack 自动生成 · {{ generated_at }}*
"""
)

CATEGORY_ICONS: dict[str, str] = {
    "deep_work": ":green_circle:",
    "communication": ":blue_circle:",
    "learning": ":yellow_circle:",
    "browsing": ":orange_circle:",
    "entertainment": ":red_circle:",
    "system": ":white_circle:",
    "other": ":white_circle:",
}


class DailyReporter:
    """Generate daily efficiency reports as Obsidian markdown."""

    def __init__(
        self,
        db: UseTrackDB,
        output_dir: Path = DAILY_NOTES_DIR,
        use_ai: bool = True,
    ):
        self.db = db
        self.output_dir = output_dir
        self.use_ai = use_ai and bool(os.environ.get("ANTHROPIC_API_KEY"))

    async def generate_report(self, target_date: str = "today") -> str:
        """Generate a complete daily report as markdown string."""
        # Gather all data in parallel (7 independent DB queries)
        summary, focus, distraction, output, dw_trend, switch_trend, active_trend = (
            await asyncio.gather(
                self.db.get_activity_summary(target_date),
                self.db.get_focus_metrics(target_date),
                self.db.get_distraction_patterns(target_date),
                self.db.get_output_metrics(target_date),
                self.db.get_trends("deep_work", 7),
                self.db.get_trends("context_switches", 7),
                self.db.get_trends("active_time", 7),
            )
        )

        # Calculate averages
        dw_values = [d["value"] for d in dw_trend["data"] if d["value"]]
        switch_values = [d["value"] for d in switch_trend["data"] if d["value"]]
        active_values = [d["value"] for d in active_trend["data"] if d["value"]]

        avg_dw = round(sum(dw_values) / len(dw_values), 1) if dw_values else 0
        avg_switches = round(sum(switch_values) / len(switch_values)) if switch_values else 0
        avg_active = round(sum(active_values) / len(active_values), 1) if active_values else 0

        # Format values
        total_active_min = summary.get("total_active_min", 0) or 0
        deep_work_min = focus.get("deep_work_min", 0) or 0
        productivity_ratio = focus.get("productivity_ratio", 0) or 0
        context_switches = focus.get("context_switches", 0) or 0
        ping_pong = focus.get("ping_pong_switches", 0) or 0

        # Top apps with icons
        top_apps = []
        for app in summary.get("top_apps", []):
            cat = app.get("category", "other") or "other"
            top_apps.append(
                {
                    "icon": CATEGORY_ICONS.get(cat, ":white_circle:"),
                    "app_name": app["app_name"],
                    "minutes": app["minutes"],
                    "category": cat,
                }
            )

        # Energy curve bars
        energy_bars = self._format_energy_curve(focus.get("energy_curve", {}))

        # Distraction summary
        distraction_summary = self._format_distraction(distraction)

        # Output metrics formatting
        output_formatted: dict[str, object] = {}
        for key in ["obsidian_words", "git_commits", "git_lines_added", "code_time_min"]:
            if key in output and output[key]:
                label = key.replace("_", " ").title()
                output_formatted[label] = output[key]

        # Suggestions based on data (rule engine)
        suggestions = self._generate_suggestions(
            deep_work_min, context_switches, ping_pong, distraction, total_active_min
        )

        # AI summary (if available, appends deeper analysis)
        ai_summary = await self.generate_ai_summary(
            {
                "total_active_min": total_active_min,
                "deep_work_min": deep_work_min,
                "productivity_ratio": productivity_ratio,
                "context_switches": context_switches,
                "ping_pong": ping_pong,
                "top_apps": summary.get("top_apps", []),
                "energy_curve": focus.get("energy_curve", {}),
                "distraction_time_min": distraction.get("distraction_time_min", 0),
                "output_metrics": output_formatted,
            }
        )

        # Render template
        report_date = focus.get("date", date.today().isoformat())
        return REPORT_TEMPLATE.render(
            date=report_date,
            total_active=self._format_duration(total_active_min),
            avg_active=self._format_duration(avg_active),
            trend_active=self._trend_arrow(total_active_min, avg_active),
            deep_work=self._format_duration(deep_work_min),
            avg_deep_work=self._format_duration(avg_dw),
            trend_deep_work=self._trend_arrow(deep_work_min, avg_dw),
            productivity_pct=round(productivity_ratio * 100),
            avg_productivity_pct=round((avg_dw / avg_active * 100) if avg_active > 0 else 0),
            trend_productivity=self._trend_arrow(
                productivity_ratio, avg_dw / avg_active if avg_active > 0 else 0
            ),
            context_switches=context_switches,
            avg_switches=avg_switches,
            trend_switches=self._trend_arrow(
                context_switches, avg_switches, lower_is_better=True
            ),
            ping_pong=ping_pong,
            avg_ping_pong=0,
            trend_ping_pong="",
            top_apps=top_apps,
            energy_bars=energy_bars,
            output_metrics=output_formatted if output_formatted else None,
            distraction_summary=distraction_summary,
            suggestions=suggestions if suggestions else None,
            ai_summary=ai_summary,
            generated_at=datetime.now().strftime("%Y-%m-%d %H:%M"),
        )

    async def write_report(self, target_date: str = "today") -> Path:
        """Generate report and write to Obsidian vault."""
        report = await self.generate_report(target_date)

        # Determine filename date
        if target_date == "today":
            d = date.today()
        elif target_date == "yesterday":
            d = date.today() - timedelta(days=1)
        else:
            d = date.fromisoformat(target_date)

        filename = f"{d.strftime('%Y%m%d')}-效率报告.md"
        filepath = self.output_dir / filename

        # Check for existing file — append instead of overwrite
        if filepath.exists():
            existing = filepath.read_text()
            if "效率报告" in existing:
                # Replace the report section
                filepath.write_text(report)
            else:
                # Append to existing daily note
                with open(filepath, "a") as f:
                    f.write("\n\n" + report)
        else:
            self.output_dir.mkdir(parents=True, exist_ok=True)
            filepath.write_text(report)

        return filepath

    # --- Formatting helpers ---

    @staticmethod
    def _format_duration(minutes: float) -> str:
        """Format minutes as Xh Ymin."""
        if not minutes:
            return "0min"
        h = int(minutes // 60)
        m = int(minutes % 60)
        if h > 0:
            return f"{h}h {m}min"
        return f"{m}min"

    @staticmethod
    def _trend_arrow(
        current: float, average: float, lower_is_better: bool = False
    ) -> str:
        """Generate trend arrow based on current vs average comparison."""
        if not average:
            return ""
        diff_pct = (current - average) / average * 100 if average else 0
        if abs(diff_pct) < 5:
            return "\u2192"
        if lower_is_better:
            return "\u2193 (\u597d)" if diff_pct < 0 else "\u2191"
        return "\u2191" if diff_pct > 0 else "\u2193"

    @staticmethod
    def _format_energy_curve(curve: dict) -> list[tuple[str, str]]:
        """Format energy curve as ASCII bars."""
        bars = []
        for hour in range(8, 23):  # 8:00 - 22:00
            key = str(hour).zfill(2)
            ratio = curve.get(key, 0) or 0
            bar_len = int(ratio * 12)
            bar = "\u2588" * bar_len + "\u2591" * (12 - bar_len)
            label = "\u6df1\u5ea6\u5de5\u4f5c" if ratio >= 0.7 else "\u6df7\u5408" if ratio >= 0.3 else ""
            bars.append((key, f"{bar} {label}"))
        return bars

    @staticmethod
    def _format_distraction(distraction: dict) -> str | None:
        """Format distraction patterns as readable text."""
        parts: list[str] = []

        dist_min = distraction.get("distraction_time_min", 0) or 0
        if dist_min > 0:
            parts.append(f"\u5a31\u4e50/\u6d4f\u89c8\u603b\u8ba1 {dist_min:.0f} \u5206\u949f")

        short_switches = distraction.get("frequent_short_switches", [])
        if short_switches:
            apps = ", ".join(
                f"{s['app_name']}({s['count']}\u6b21)" for s in short_switches[:3]
            )
            parts.append(f"\u9891\u7e41\u77ed\u5207\u6362: {apps}")

        transitions = distraction.get("top_transitions", [])
        if transitions:
            chains = " \u2192 ".join(
                f"{t['from_app']}\u2194{t['to_app']}" for t in transitions[:3]
            )
            parts.append(f"\u5e38\u89c1\u5207\u6362\u94fe: {chains}")

        return "\n".join(f"- {p}" for p in parts) if parts else None

    @staticmethod
    def _generate_suggestions(
        deep_work_min: float,
        switches: int,
        ping_pong: int,
        distraction: dict,
        total_min: float,
    ) -> list[str]:
        """Generate actionable suggestions based on data."""
        suggestions: list[str] = []

        if deep_work_min >= 180:
            suggestions.append("\u2705 \u6df1\u5ea6\u5de5\u4f5c\u8d85\u8fc7 3 \u5c0f\u65f6\uff0c\u8868\u73b0\u51fa\u8272\uff01")
        elif deep_work_min < 60:
            suggestions.append(
                "\u26a0\ufe0f \u6df1\u5ea6\u5de5\u4f5c\u4e0d\u8db3 1 \u5c0f\u65f6\uff0c\u8003\u8651\u5b89\u6392\u4e00\u4e2a 2 \u5c0f\u65f6\u7684\u4e0d\u95f4\u65ad\u7f16\u7801\u65f6\u6bb5"
            )

        if switches > 120:
            suggestions.append("\u26a0\ufe0f \u4e0a\u4e0b\u6587\u5207\u6362\u8fc7\u4e8e\u9891\u7e41\uff0c\u5efa\u8bae\u5173\u95ed\u975e\u5fc5\u8981\u901a\u77e5")

        if ping_pong > 5:
            suggestions.append(
                f"\u26a0\ufe0f \u68c0\u6d4b\u5230 {ping_pong} \u6b21\u4e52\u4e53\u5207\u6362\uff0c\u8fd9\u662f\u6ce8\u610f\u529b\u788e\u7247\u5316\u7684\u4fe1\u53f7"
            )

        dist_min = distraction.get("distraction_time_min", 0) or 0
        if dist_min > 60:
            suggestions.append(
                f"\U0001f4a1 \u5a31\u4e50/\u6d4f\u89c8\u65f6\u95f4 {dist_min:.0f} \u5206\u949f\uff0c\u8003\u8651\u7528 Focus Mode \u9650\u5236"
            )

        if total_min and deep_work_min / total_min < 0.3:
            suggestions.append(
                "\U0001f4a1 \u751f\u4ea7\u529b\u6bd4\u4f4e\u4e8e 30%\uff0c\u5c1d\u8bd5\u4f7f\u7528\u756a\u8304\u949f\u5de5\u4f5c\u6cd5"
            )

        return suggestions

    async def generate_ai_summary(self, data: dict) -> str | None:
        """Use Anthropic API to generate a deeper AI analysis of the day's data.

        Returns None if AI is not available or if the API call fails.
        data should contain: total_active_min, deep_work_min, context_switches,
        ping_pong, top_apps, energy_curve, distraction, output_metrics.
        """
        if not self.use_ai:
            return None

        try:
            import anthropic

            client = anthropic.Anthropic()

            # 构建数据摘要（只发送结构化统计，不发原始标题/URL — L2 隐私模式）
            prompt = f"""分析以下个人电脑使用数据，给出 3-5 条具体的效率改进建议。
要求：用中文回复，简洁直接，每条建议一句话，重点关注"可执行的行动"。

## 今日数据
- 活跃时长: {data.get('total_active_min', 0):.0f} 分钟
- 深度工作: {data.get('deep_work_min', 0):.0f} 分钟
- 生产力比: {data.get('productivity_ratio', 0):.0%}
- 上下文切换: {data.get('context_switches', 0)} 次
- 乒乓切换: {data.get('ping_pong', 0)} 次

## Top Apps (按使用时长)
"""
            for app in data.get("top_apps", [])[:8]:
                prompt += f"- {app.get('app_name', '?')}: {app.get('minutes', 0)}min ({app.get('category', 'other')})\n"

            # 能量曲线
            curve = data.get("energy_curve", {})
            if curve:
                prompt += "\n## 能量曲线 (每小时深度工作占比)\n"
                for h in range(8, 23):
                    key = str(h).zfill(2)
                    ratio = curve.get(key, 0) or 0
                    prompt += f"- {key}:00: {ratio:.0%}\n"

            # 干扰数据
            dist_min = data.get("distraction_time_min", 0) or 0
            if dist_min > 0:
                prompt += f"\n## 干扰\n- 非生产性浏览/娱乐: {dist_min:.0f} 分钟\n"

            # 产出
            output = data.get("output_metrics", {})
            if output:
                prompt += "\n## 产出\n"
                for k, v in output.items():
                    if v:
                        prompt += f"- {k}: {v}\n"

            message = client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=500,
                messages=[{"role": "user", "content": prompt}],
            )

            return message.content[0].text

        except ImportError:
            return None
        except Exception as e:
            print(f"[Reporter] AI summary error: {e}")
            return None


class DistractionAnalyzer:
    """Higher-level distraction pattern analysis."""

    def __init__(self, db: UseTrackDB):
        self.db = db

    async def analyze(self, period: str = "today") -> dict:
        """Full distraction analysis with actionable insights."""
        patterns = await self.db.get_distraction_patterns(period)
        focus_period = "today" if period == "this_week" else period
        focus = await self.db.get_focus_metrics(focus_period)

        # Identify worst distraction source
        short_switches = patterns.get("frequent_short_switches", [])
        worst_app = short_switches[0]["app_name"] if short_switches else None

        # Identify worst time period (from energy curve)
        energy = focus.get("energy_curve", {})
        worst_hours = [h for h, r in energy.items() if r is not None and r < 0.2]

        return {
            **patterns,
            "worst_distraction_app": worst_app,
            "low_productivity_hours": worst_hours,
            "suggestions": self._generate_distraction_tips(
                patterns, worst_app, worst_hours
            ),
        }

    @staticmethod
    def _generate_distraction_tips(
        patterns: dict, worst_app: str | None, worst_hours: list
    ) -> list[str]:
        """Generate distraction-specific actionable tips."""
        tips: list[str] = []
        if worst_app:
            tips.append(
                f"\U0001f534 {worst_app} \u662f\u4f60\u6700\u5927\u7684\u5e72\u6270\u6e90\uff0c\u8003\u8651\u5728\u6df1\u5ea6\u5de5\u4f5c\u65f6\u6bb5\u5c4f\u853d\u5b83"
            )
        if worst_hours:
            hours_str = ", ".join(f"{h}:00" for h in worst_hours[:3])
            tips.append(
                f"\u23f0 {hours_str} \u662f\u4f60\u7684\u4f4e\u6548\u65f6\u6bb5\uff0c\u907f\u514d\u5728\u6b64\u5b89\u6392\u91cd\u8981\u5de5\u4f5c"
            )
        dist_min = patterns.get("distraction_time_min", 0) or 0
        if dist_min > 30:
            tips.append(
                f"\U0001f4f1 \u4eca\u65e5\u975e\u751f\u4ea7\u6027\u6d4f\u89c8 {dist_min:.0f} \u5206\u949f\uff0c\u8bbe\u7f6e\u6bcf\u65e5\u9650\u989d"
            )
        return tips


def main() -> None:
    """CLI entry point for report generation."""

    async def _run() -> None:
        db = UseTrackDB()
        await db.connect()
        try:
            reporter = DailyReporter(db)
            filepath = await reporter.write_report("today")
            print(f"Report generated: {filepath}")
        finally:
            await db.close()

    asyncio.run(_run())


if __name__ == "__main__":
    main()
