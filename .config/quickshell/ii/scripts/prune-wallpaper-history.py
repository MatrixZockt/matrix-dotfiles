#!/usr/bin/env python3
"""Prune wallpaper-history.json: drop entries whose image file is gone.

A ghost entry can never render a preview (its thumbnail generation fails on
the missing source) and can never be applied again -- it sits in the
carousel as a permanent blank card. Runs at shell start from
WallpaperHistory.qml; prints what it did to stderr (visible in the shell log).
"""
import json
import os
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: prune-wallpaper-history.py <history.json>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path) as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print("[prune] no history yet:", path, file=sys.stderr)
        return 0
    except Exception as exc:
        print("[prune] unreadable history:", exc, file=sys.stderr)
        return 0
    if not isinstance(data, list):
        print("[prune] unexpected history format, leaving it alone", file=sys.stderr)
        return 0
    kept = [entry for entry in data
            if isinstance(entry, str) and os.path.isfile(entry)]
    if len(kept) != len(data):
        with open(path, "w") as fh:
            json.dump(kept, fh)
        print(f"[prune] wallpaper history: {len(data)} -> {len(kept)} "
              f"(dropped {len(data) - len(kept)} missing files)", file=sys.stderr)
    else:
        print(f"[prune] wallpaper history clean ({len(kept)} entries)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
