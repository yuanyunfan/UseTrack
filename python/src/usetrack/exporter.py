"""UseTrack data exporter CLI — export today's data to sync directory."""

import argparse
import sys
from datetime import date

from usetrack.sync import export_today, load_sync_config


def main():
    parser = argparse.ArgumentParser(description="Export UseTrack data to sync directory")
    parser.add_argument(
        "--date",
        type=str,
        default=None,
        help="Date to export (YYYY-MM-DD, default: today)",
    )
    args = parser.parse_args()

    config = load_sync_config()
    if config is None:
        print("Error: sync not configured. Create ~/.usetrack/sync.toml with:")
        print()
        print('[sync]')
        print('machine_id = "personal"')
        print('sync_dir = "~/Nutstore Files/UseTrack"')
        print("enabled = true")
        sys.exit(1)

    target_date = date.fromisoformat(args.date) if args.date else date.today()

    try:
        out_path = export_today(
            sync_dir=config["sync_dir"],
            machine_id=config["machine_id"],
            target_date=target_date,
        )
        print(f"Exported {target_date} → {out_path}")
    except Exception as e:
        print(f"Export failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
