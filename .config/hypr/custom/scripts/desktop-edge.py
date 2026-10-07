#!/usr/bin/env python3
"""Decide whether a horizontal desktop swipe would go anywhere.

Prints one word:

    bump   the swipe would land nowhere -- the desktop has no neighbour in
           that direction and Hyprland will not invent one
    ok     there is somewhere to go (or Hyprland will create it), so the
           real switch is about to happen and any error animation would be
           a lie

Called from the 4-finger left/right gestures in custom/general.lua. It is a
separate script, rather than logic inline in the gesture, for the same reason
field-move.py is: the gesture needs the ANSWER before it returns, so it can
stay silent on a swipe that will succeed, and that answer is JSON.

Usage:  desktop-edge.py left|right
"""

import json
import subprocess
import sys

# A special workspace is negative (sentinels, and Hyprland's own -99), and
# none of them are a neighbour you can swipe to.
def real_ids(workspaces):
    return sorted({w["id"] for w in workspaces if isinstance(w.get("id"), int) and w["id"] > 0})


def hyprctl_json(*args):
    try:
        out = subprocess.run(
            ["hyprctl", "-j", *args],
            capture_output=True,
            text=True,
            timeout=2,
        ).stdout
        return json.loads(out) if out.strip() else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def creates_its_own():
    """True when Hyprland makes a new desktop instead of hitting a wall.

    `workspace_swipe_create_new` is why the two edges are not symmetric on
    this setup: swiping right off the end of the strip CREATES a desktop, so
    that is a success and must not bump. Swiping left off the first desktop
    has no id below 1 to create, and that is the dead end this is for.
    """
    opt = hyprctl_json("getoption", "gestures:workspace_swipe_create_new")
    if not isinstance(opt, dict):
        return False
    return opt.get("bool") is True


def verdict(direction):
    monitors = hyprctl_json("monitors")
    if not isinstance(monitors, list) or not monitors:
        # Cannot know. Stay quiet: a bump on a swipe that was about to work
        # is worse than no bump on one that was not.
        return "ok"

    monitor = next((m for m in monitors if m.get("focused")), None)
    if monitor is None:
        return "ok"

    active = (monitor.get("activeWorkspace") or {}).get("id")
    ids = real_ids(monitor.get("workspaces") or [])
    if not isinstance(active, int) or active not in ids:
        return "ok"

    index = ids.index(active)
    if direction == "left":
        return "ok" if index > 0 else "bump"

    # Right: a neighbour, or room for Hyprland to make one.
    if index < len(ids) - 1 or creates_its_own():
        return "ok"
    return "bump"


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("left", "right"):
        print("ok")
        return
    print(verdict(sys.argv[1]))


if __name__ == "__main__":
    main()
