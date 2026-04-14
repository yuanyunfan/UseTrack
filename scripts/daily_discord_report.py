#!/usr/bin/env python3
"""UseTrack Daily Report — send to Discord via Webhook."""

import asyncio
import json
import os
import sys
import urllib.request
from datetime import date, datetime
from pathlib import Path

# Add project to path
sys.path.insert(0, str(Path(__file__).parent / "python" / "src"))

from usetrack.db import UseTrackDB

WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
DB_PATH = Path.home() / ".usetrack" / "usetrack.db"

CATEGORY_EMOJI = {
    "deep_work": "🟢",
    "communication": "🔵",
    "learning": "🟡",
    "browsing": "🟠",
    "entertainment": "🔴",
    "system": "⚪",
}


def format_minutes(mins: float) -> str:
    if not mins:
        return "0m"
    h, m = int(mins // 60), int(mins % 60)
    return f"{h}h {m}m" if h > 0 else f"{m}m"


def trend_arrow(current: float, average: float, lower_is_better: bool = False) -> str:
    if not average:
        return ""
    diff = (current - average) / average * 100
    if abs(diff) < 5:
        return "→"
    if lower_is_better:
        return "↓ 好" if diff < 0 else "↑"
    return "↑" if diff > 0 else "↓"


def energy_bar(ratio: float) -> str:
    filled = int(ratio * 10)
    return "█" * filled + "░" * (10 - filled)


async def gather_data():
    db = UseTrackDB(db_path=DB_PATH)
    await db.connect()

    summary, focus, distraction, output, dw_trend, switch_trend = await asyncio.gather(
        db.get_activity_summary("today"),
        db.get_focus_metrics("today"),
        db.get_distraction_patterns("today"),
        db.get_output_metrics("today"),
        db.get_trends("deep_work", 7),
        db.get_trends("context_switches", 7),
    )

    await db.close()
    return summary, focus, distraction, output, dw_trend, switch_trend


def build_discord_payload(summary, focus, distraction, output, dw_trend, switch_trend):
    today_str = date.today().isoformat()
    total_min = focus.get("total_active_min", 0) or 0
    dw_min = focus.get("deep_work_min", 0) or 0
    switches = focus.get("context_switches", 0) or 0
    ping_pong = focus.get("ping_pong_switches", 0) or 0
    ratio = focus.get("productivity_ratio", 0) or 0

    # 7-day averages
    dw_vals = [d["value"] for d in dw_trend.get("data", []) if d.get("value")]
    sw_vals = [d["value"] for d in switch_trend.get("data", []) if d.get("value")]
    avg_dw = round(sum(dw_vals) / len(dw_vals), 1) if dw_vals else 0
    avg_sw = round(sum(sw_vals) / len(sw_vals)) if sw_vals else 0

    # Color based on productivity
    if ratio >= 0.5:
        color = 0x2ECC71  # green
    elif ratio >= 0.3:
        color = 0xF39C12  # orange
    else:
        color = 0xE74C3C  # red

    # Top apps field
    top_apps_lines = []
    for app in summary.get("top_apps", [])[:6]:
        cat = app.get("category") or "other"
        emoji = CATEGORY_EMOJI.get(cat, "⚪")
        top_apps_lines.append(f"{emoji} **{app['app_name']}** — {app['minutes']}m ({cat})")
    top_apps_text = "\n".join(top_apps_lines) if top_apps_lines else "暂无数据"

    # Energy curve field
    curve = focus.get("energy_curve", {})
    energy_lines = []
    for h in range(8, 23):
        key = str(h).zfill(2)
        r = curve.get(key)
        if r is not None:
            bar = energy_bar(r)
            label = " 深度" if r >= 0.7 else ""
            energy_lines.append(f"`{key}:00` {bar}{label}")
    energy_text = "\n".join(energy_lines) if energy_lines else "暂无数据"

    # Output field
    output_lines = []
    for key, label in [
        ("git_commits", "Git Commits"),
        ("git_lines_added", "代码新增"),
        ("git_lines_removed", "代码删除"),
        ("obsidian_words", "笔记字数"),
    ]:
        val = output.get(key)
        if val:
            output_lines.append(f"**{label}**: {int(val)}")
    output_text = " | ".join(output_lines) if output_lines else "暂无数据"

    # Distraction field
    dist_min = distraction.get("distraction_time_min", 0) or 0
    dist_lines = []
    if dist_min > 0:
        dist_lines.append(f"娱乐/浏览: **{int(dist_min)}分钟**")
    for t in distraction.get("top_transitions", [])[:3]:
        dist_lines.append(f"切换链: {t['from_app']} → {t['to_app']} ({t['count']}次)")
    dist_text = "\n".join(dist_lines) if dist_lines else "✅ 无明显干扰"

    # Suggestions
    suggestions = []
    if dw_min >= 180:
        suggestions.append("✅ 深度工作超 3h，表现出色！")
    elif dw_min < 60:
        suggestions.append("⚠️ 深度工作不足 1h，需改善")
    if switches > 120:
        suggestions.append("⚠️ 切换过频繁，建议关闭通知")
    if ping_pong > 5:
        suggestions.append(f"⚠️ {ping_pong}次乒乓切换")
    if dist_min > 60:
        suggestions.append(f"💡 非生产性浏览{int(dist_min)}min")
    if not suggestions:
        suggestions.append("📊 数据正常，继续保持")
    suggestions_text = "\n".join(suggestions)

    payload = {
        "embeds": [
            {
                "title": f"📊 每日效率报告 — {today_str}",
                "color": color,
                "fields": [
                    {
                        "name": "⏱️ 关键指标",
                        "value": (
                            f"**活跃时长**: {format_minutes(total_min)}\n"
                            f"**深度工作**: {format_minutes(dw_min)} {trend_arrow(dw_min, avg_dw)}\n"
                            f"**生产力比**: {int(ratio * 100)}%\n"
                            f"**上下文切换**: {switches}次 {trend_arrow(avg_sw, switches, True)}\n"
                            f"**乒乓切换**: {ping_pong}次"
                        ),
                        "inline": True,
                    },
                    {
                        "name": "📱 Top Apps",
                        "value": top_apps_text,
                        "inline": True,
                    },
                    {
                        "name": "⚡ 能量曲线",
                        "value": energy_text,
                        "inline": False,
                    },
                    {
                        "name": "📦 产出",
                        "value": output_text,
                        "inline": False,
                    },
                    {
                        "name": "🔍 干扰分析",
                        "value": dist_text,
                        "inline": True,
                    },
                    {
                        "name": "💡 AI 洞察",
                        "value": suggestions_text,
                        "inline": True,
                    },
                ],
                "footer": {
                    "text": "UseTrack · 自动生成",
                },
                "timestamp": datetime.now().astimezone().isoformat(),
            }
        ]
    }
    return payload


def send_to_discord(payload: dict):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        WEBHOOK_URL,
        data=data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "UseTrack/0.1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"✅ Discord 发送成功 (HTTP {resp.status})")
            return True
    except urllib.error.HTTPError as e:
        # Discord returns 204 No Content on success, urllib treats it as error
        if e.code == 204:
            print("✅ Discord 发送成功 (HTTP 204)")
            return True
        print(f"❌ Discord 发送失败: HTTP {e.code} - {e.read().decode()}")
        return False
    except Exception as e:
        print(f"❌ Discord 发送失败: {e}")
        return False


async def main():
    if not WEBHOOK_URL:
        print("❌ 环境变量 DISCORD_WEBHOOK_URL 未设置")
        print("   请设置: export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'")
        sys.exit(1)

    if not DB_PATH.exists():
        print(f"❌ 数据库不存在: {DB_PATH}")
        print("   请先启动 UseTrack Collector")
        sys.exit(1)

    print(f"📊 正在生成 {date.today()} 的效率报告...")
    summary, focus, distraction, output, dw_trend, switch_trend = await gather_data()
    payload = build_discord_payload(summary, focus, distraction, output, dw_trend, switch_trend)
    send_to_discord(payload)


if __name__ == "__main__":
    asyncio.run(main())
