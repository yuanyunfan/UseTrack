#!/usr/bin/env python3
"""
修复历史 app_switch 事件中被 AFK / 锁屏 / 睡眠时段污染的 duration_s。

背景:
    旧版 AppWatcher 只在「下一次 app 切换」时回填 duration，没有在用户进入
    idle / locked / asleep 时截断 in-flight 的 app_switch。结果:
    切到 iTerm2 后睡觉 8 小时，第二天醒来切到下个 app 时，那条 iTerm2 的
    duration_s 会被算成 8h+。

修复策略:
    把 idle_end 事件 (ts, duration_s) 推回成 idle 区间 [ts - duration, ts]，
    然后从每条 app_switch 的 [start, start + duration] 区间里减去与所有 idle
    区间的重叠时长。

用法:
    python scripts/repair_app_durations.py            # dry-run, 只打印
    python scripts/repair_app_durations.py --apply    # 实际写回 DB
    python scripts/repair_app_durations.py --db /path/to/usetrack.db --apply
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path

DEFAULT_DB = Path.home() / ".usetrack" / "usetrack.db"


def parse_ts(ts: str) -> datetime:
    # 兼容 "2026-04-21T10:16:03.576" 和 "2026-04-21T10:16:03"
    if "." in ts:
        return datetime.strptime(ts[:23], "%Y-%m-%dT%H:%M:%S.%f")
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S")


def load_idle_intervals(con: sqlite3.Connection) -> list[tuple[datetime, datetime]]:
    rows = con.execute(
        "SELECT ts, duration_s FROM activity_stream "
        "WHERE activity = 'idle_end' AND duration_s IS NOT NULL AND duration_s > 0"
    ).fetchall()
    intervals = []
    for ts, dur in rows:
        end = parse_ts(ts)
        start = end - timedelta(seconds=dur)
        intervals.append((start, end))
    intervals.sort()
    return intervals


def overlap_seconds(
    seg_start: datetime,
    seg_end: datetime,
    intervals: list[tuple[datetime, datetime]],
) -> float:
    total = 0.0
    for i_start, i_end in intervals:
        if i_end <= seg_start:
            continue
        if i_start >= seg_end:
            break
        total += (min(seg_end, i_end) - max(seg_start, i_start)).total_seconds()
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--apply", action="store_true", help="实际写回 DB（默认 dry-run）")
    parser.add_argument("--min-saved", type=float, default=1.0,
                        help="只显示节省 >= N 秒的行（默认 1s）")
    args = parser.parse_args()

    if not args.db.exists():
        print(f"❌ DB 不存在: {args.db}", file=sys.stderr)
        return 1

    con = sqlite3.connect(args.db)
    intervals = load_idle_intervals(con)
    print(f"加载 {len(intervals)} 个 idle 区间")

    rows = con.execute(
        "SELECT id, ts, app_name, duration_s FROM activity_stream "
        "WHERE activity = 'app_switch' AND duration_s IS NOT NULL AND duration_s > 0"
    ).fetchall()
    print(f"扫描 {len(rows)} 条 app_switch...")

    updates: list[tuple[float, int]] = []
    saved_total = 0.0
    for row_id, ts, app, dur in rows:
        seg_start = parse_ts(ts)
        seg_end = seg_start + timedelta(seconds=dur)
        ovl = overlap_seconds(seg_start, seg_end, intervals)
        if ovl >= args.min_saved:
            new_dur = max(0.0, dur - ovl)
            saved_total += ovl
            updates.append((new_dur, row_id))
            print(f"  [{row_id}] {ts} {app[:24]:<24} {dur:>8.0f}s → {new_dur:>8.0f}s "
                  f"(-{ovl/60:.1f}m)")

    print(f"\n共 {len(updates)} 行可修复，节省虚假活跃时长 {saved_total/3600:.2f}h")

    if not args.apply:
        print("（dry-run，未写回。加 --apply 执行）")
        return 0

    if not updates:
        print("无需修复。")
        return 0

    confirm = input(f"确认写回 {args.db} ? [y/N] ").strip().lower()
    if confirm != "y":
        print("已取消。")
        return 0

    con.executemany(
        "UPDATE activity_stream SET duration_s = ? WHERE id = ?",
        updates,
    )
    con.commit()
    print(f"✓ 已更新 {len(updates)} 行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
