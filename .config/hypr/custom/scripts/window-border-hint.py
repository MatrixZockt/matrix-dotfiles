#!/usr/bin/env python3
"""Black border feedback while the pointer rests on a window's resize edge.

What this does
--------------
The drag itself is Hyprland's: `resize_on_border` + `extend_border_grab_area`
in custom/general.lua mean a press inside the band around any window edge and
a drag resizes, anchored to the corner nearest the cursor (`smart_resizing`).
Hyprland also swaps in a resize cursor over that band by itself.

What Hyprland does not do is show anything *persistent* about the edge. This
adds the missing half: while the pointer is inside the grab band, the focused
window's border turns opaque black; the moment it leaves, the original colour
comes back. The black frame therefore appears exactly when the edge would
accept a drag, and disappears when it would not.

Two things about this Hyprland build, both established by testing, that shape
the implementation:

1. THERE IS NO `cursorpos` EVENT. socket2 does deliver `openwindow`,
   `activewindow`, `closewindow` and friends (verified), but pointer motion is
   never published on 0.56 -- the socket was read while the pointer was driven
   across the screen with ydotool and `hyprctl cursorpos` confirmed the
   position really had changed, and zero events arrived. So the pointer has to
   be polled. socket2 is still connected, for its geometry events only, so the
   window box is re-read when the window set changes rather than on every tick.

2. `setvar` IS GONE FROM hyprctl, and the raw request socket cannot answer most
   queries either -- on `.socket.sock`, `getoption` and `monitors` reply while
   `cursorpos`, `activewindow`, `clients` and `binds` all return "unknown
   request". There is no `setvar` subcommand in this build at all, so the
   obvious "swap the border colour at runtime" call simply does not exist.

   What DOES work is the config's own language: this desktop is configured in
   Lua, and `hyprctl eval "hl.config({...})"` applies a value live and
   immediately (verified: the border reads back as ff000000 the instant it
   runs). So the colour is pushed with `hl.config`, which is also the most
   honest form for this config -- it goes through the same API that sets every
   other value in custom/ and hyprland/.

That combination is why this is a small process and not a single cheap IPC
loop, and why the poll is rate-adaptive: FAST while the pointer is actually
moving (which is the only time a border can change), SLOW once it has been
still, so an untouched desktop costs almost nothing. The same
`hyprctl cursorpos` process-call pattern is what the edge-reveal sidebar
already uses in this config, so it is an established cost here.
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time

# Must match general:extend_border_grab_area in custom/general.lua. If the
# band changes there it must change here too: a black border on a strip the
# drag does not answer to is worse than no border at all.
GRAB = 10

# The resting colours are NOT defined here. They used to be, copied from
# hyprland/colors.lua, and pushed verbatim on the way out of the band -- which
# meant that on a light desktop the border snapped back to the old dark colour
# the moment the pointer left a window edge, while everything else stayed
# light. custom/theme.lua owns the resting colours now, for both modes, and
# `restore()` puts the current one back. One source of truth: the two can never
# disagree about what "resting" looks like.

# The draggable cue. Opaque black so it reads against the dark window edge and
# the lighter wallpaper showing through the gap alike.
HILIT = "rgba(000000ff)"

FAST = 0.08     # pointer moving -- ~12/s, responsive without being silly
SLOW = 0.45     # pointer idle  -- ~2/s
IDLE_AFTER = 1.2
GEO_MAX_AGE = 0.5


def hyprctl(*args, timeout=1.0):
    """One hyprctl call. Returns str ('' on any failure)."""
    try:
        p = subprocess.run(
            ["hyprctl", *args], capture_output=True, timeout=timeout
        )
    except (subprocess.TimeoutExpired, OSError):
        return ""
    if p.returncode != 0:
        return ""
    return p.stdout.decode(errors="replace")


def set_border(active, inactive):
    """Push both border colours through the config's own Lua API.

    Not `hyprctl setvar`: that subcommand does not exist on this build
    (it answers "unknown request"), and neither does any raw-socket route to
    it. `hyprctl eval` + `hl.config` is the supported live-config path here.
    """
    return hyprctl(
        "eval",
        "hl.config({ general = { col = {"
        f" active_border = '{active}',"
        f" inactive_border = '{inactive}'"
        " } } })",
    )


def restore_border():
    """Hand the border back to the theme that is actually in force.

    Not `set_border` with a remembered pair: the resting colours changed when
    the desktop gained a light mode, and a copy kept here would have gone stale
    the moment anyone picked a new palette. `custom/theme.lua` re-applies
    whichever mode it last applied, so this asks the owner rather than
    remembering an answer.
    """
    return hyprctl("eval", 'require("custom.theme").restore()')


def read_geometry():
    """(x, y, w, h) of the focused window, or None if there is nothing to size."""
    raw = hyprctl("activewindow", "-j")
    if not raw.startswith("{"):
        return None
    try:
        d = json.loads(raw)
    except ValueError:
        return None
    if d.get("fullscreen") in (1, True):
        return None
    at, size = d.get("at") or [0, 0], d.get("size") or [0, 0]
    w, h = int(size[0]), int(size[1])
    if w <= 0 or h <= 0:
        return None
    return int(at[0]), int(at[1]), w, h


def parse_pos(s):
    parts = s.split(",")
    if len(parts) < 2:
        return None
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return None


def on_edge(x, y, geo):
    gx, gy, gw, gh = geo
    # Corners are matched by both axes, which is correct: a corner is the
    # strongest resize target there is.
    vertical = (abs(x - gx) <= GRAB or abs(x - (gx + gw)) <= GRAB) and \
               gx - GRAB <= x <= gx + gw + GRAB
    horizontal = (abs(y - gy) <= GRAB or abs(y - (gy + gh)) <= GRAB) and \
                 gy - GRAB <= y <= gy + gh + GRAB
    return vertical or horizontal


def start_event_watcher():
    """Invalidate the cached window box when the window set changes."""
    dirty = threading.Event()
    dirty.set()
    his = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    path = (
        f"{os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000')}"
        f"/hypr/{his}/.socket2.sock"
    )

    def run():
        try:
            ev = socket_connect(path)
        except OSError:
            return
        interesting = (
            b"activewindow", b"openwindow", b"closewindow", b"movewindow",
            b"movewindowv2", b"resizewindow", b"fullscreen", b"workspace",
            b"focusedmon", b"changefloatingmode", b"activewindowv2",
        )
        buf = b""
        while True:
            try:
                chunk = ev.recv(4096)
            except (OSError, timeout_error):
                continue
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, _, buf = buf.partition(b"\n")
                if line.partition(b">>")[0] in interesting:
                    dirty.set()

    threading.Thread(target=run, daemon=True).start()
    return dirty


def socket_connect(path):
    import socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2.0)
    s.connect(path)
    return s


timeout_error = __import__("socket").timeout


def main():
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        print("border-hint: not running under Hyprland", file=sys.stderr)
        return 1

    dirty = start_event_watcher()

    geo = None
    geo_at = 0.0
    lit = False           # is the black border currently applied?
    last_pos = None
    idle_since = time.monotonic()

    def paint(want):
        nonlocal lit
        if want == lit:
            return
        lit = want
        if want:
            # Both colours, not just the active one: the pointer may be on a
            # window that is not quite focused during a focus race, and the cue
            # must follow the pointer rather than the focus.
            set_border(HILIT, HILIT)
        else:
            restore_border()

    # Any exit must put the border back. A KeyboardInterrupt-only handler is
    # not enough: this is killed by SIGTERM on reload (the autostart is
    # idempotent, so a reload restarts it) and a daemon that dies with the
    # black frame still applied would leave every window looking permanently
    # draggable with no way to clear it short of a re-login.
    def bail(*_):
        restore_border()
        sys.exit(0)

    signal.signal(signal.SIGTERM, bail)
    signal.signal(signal.SIGINT, bail)

    try:
        while True:
            pos = parse_pos(hyprctl("cursorpos"))
            if pos is None:
                # Query failed (compositor busy, or tearing down). Drop the
                # highlight rather than stranding a black frame on a window.
                geo, last_pos = None, None
                paint(False)
                time.sleep(SLOW)
                continue

            now = time.monotonic()
            if pos != last_pos:
                last_pos = pos
                idle_since = now
            idle = (now - idle_since) > IDLE_AFTER

            if not idle or geo is None:
                if dirty.is_set() or (now - geo_at) > GEO_MAX_AGE:
                    dirty.clear()
                    geo = read_geometry()
                    geo_at = now

            paint(geo is not None and on_edge(pos[0], pos[1], geo))

            # Once nothing is moving and the border is off, there is nothing to
            # recompute at all: back off hard until the pointer moves again.
            if idle and not lit:
                time.sleep(SLOW)
            else:
                time.sleep(FAST)
    except KeyboardInterrupt:
        restore_border()
        return 0


if __name__ == "__main__":
    sys.exit(main())
