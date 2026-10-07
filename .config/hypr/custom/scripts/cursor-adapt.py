#!/usr/bin/env python3
"""Pick the Bibata variant that matches whatever is under the pointer.

WHY THIS EXISTS. Bibata ships every cursor as a solid body plus a contrasting
keyline (white body + black keyline, or black body + white keyline). The
keyline is there so the pointer never disappears -- but paying for it on every
surface is not free: a white arrow with a black rim looks heavier than the same
arrow solid, when all it has to do is trace a shape the eye already follows.

So: the pointer keeps the body colour darkMode gave it -- white on a dark
desktop, black on a light one -- and goes SOLID as the default. The rim comes
back only when the pointer is genuinely at risk of vanishing, which is when it
is over something the same colour as itself.

    body contrasts with what is under it   -> solid   (Ice-NoLine / Classic-NoLine)
    body is close to what is under it      -> rimmed  (Ice / Classic)

A NOTE ON WHAT THIS IS NOT, because the first version of this file got it wrong.
The obvious alternative is "look at the background and pick whichever of
white/black contrasts with it" -- and then the rim can never fire, because
choosing the contrasting body has already solved the visibility problem before
the rim is ever consulted. That version's rim branches were provably dead code:
the light branch demanded luma >= 140 AND luma < 64. The body colour therefore
has to be fixed by the theme, and the rim is the exception to it, not the other
way round.

WHY grim IS SAFE HERE. grim does NOT draw the cursor unless you pass -c, so
sampling the pixel directly under the pointer reads the BACKGROUND and not the
pointer itself. That is the whole reason this can work at all: sampling the
pointer would close a feedback loop where a white pointer on a white patch
makes the sample white, which keeps it white forever, and the loop can never
be escaped by moving the mouse anywhere.

HYSTERESIS. The rim has an asymmetric band so it cannot chatter. It switches ON
when the gap to the background has closed to NEAR_ON, and back OFF only once the
gap has reopened to NEAR_OFF, which is wider. Between the two nothing happens,
so parking the mouse on a mid-grey does not make the pointer oscillate. Two
consecutive agreeing samples are also required, which kills single-sample
flickers when a window animates under the pointer.

COST. One grim process per sample, but only when the pointer has actually
MOVED by MIN_MOVE px -- a stationary pointer costs one cheap `hyprctl cursorpos`
per tick and nothing else. Continuous movement is capped at one sample per
MIN_SAMPLE_INTERVAL.

Usage: cursor-adapt.py [--once] [--verbose]
"""

import os
import re
import subprocess
import sys
import time

# Where the shell/hyprland scripts keep their logs.
LOG = os.path.expanduser("~/.local/state/quickshell/cursor-adapt.log")

THEME_LUA = os.path.expanduser("~/.config/hypr/custom/theme.lua")

# Mode file, written by custom/theme.lua on every palette change.
MODE_FILE = os.path.expanduser("~/.local/state/quickshell/theme-mode")

# Gap (in luminance, 0-255) between the pointer's body and the background at
# which the rim switches on, and the wider gap at which it switches back off.
#
# These started at 64/84 and were far too generous. 64 means "anything from
# light grey upward", so the rim kept coming back over ordinary light UI --
# measured on the real desktop, it fired at luma 206 and 219, which are just
# pale panels, not white surfaces. The net effect was that the borderless
# cursor almost never actually looked borderless, which is the opposite of
# what it was built for.
#
# 30 means "within 30 of pure white" for the white pointer, i.e. genuinely a
# white or near-white surface -- which is the case the rim exists for. Below
# about 40 the rim stops firing on ordinary light-grey panels entirely.
NEAR_ON = 30
NEAR_OFF = 48

SOLID_WHITE = "Bibata-Modern-Ice-NoLine"
SOLID_BLACK = "Bibata-Modern-Classic-NoLine"
RIMMED_WHITE = "Bibata-Modern-Ice"
RIMMED_BLACK = "Bibata-Modern-Classic"

POLL = 0.06          # cursorpos tick
MIN_MOVE = 3         # px of movement before a background sample is worth it
MIN_SAMPLE_INTERVAL = 0.10
CONFIRM = 2          # consecutive agreeing samples before switching


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%.2f %s\n" % (time.time(), msg))
    except OSError:
        pass


def cursor_pos():
    """(x, y) of the pointer, or None."""
    try:
        out = subprocess.run(["hyprctl", "cursorpos"], capture_output=True,
                             text=True, timeout=3).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.match(r"^\s*(-?\d+)\s*,\s*(-?\d+)\s*$", out)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def sample_luma(x, y, size=3):
    """Mean luminance of a small patch at (x, y), or None.

    A patch rather than a single pixel: one pixel can land on a 1px border or a
    glyph stroke and give a wildly wrong reading. 3x3 is big enough to average
    that away and still local enough to track a button or a panel edge.
    """
    try:
        raw = subprocess.run(
            ["grim", "-t", "ppm", "-g", "%d,%d %dx%d" % (x, y, size, size), "-"],
            capture_output=True, timeout=4).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    # P6\n<w> <h>\n255\n<binary rgb>
    parts = raw.split(b"\n", 3)
    if len(parts) < 4 or not parts[0].startswith(b"P6"):
        return None
    body = parts[3]
    if not body:
        return None
    n = len(body) // 3
    if n == 0:
        return None
    total = 0
    for i in range(n):
        r, g, b = body[i * 3], body[i * 3 + 1], body[i * 3 + 2]
        total += 0.299 * r + 0.587 * g + 0.114 * b
    return total / n


def read_size(default=24):
    """Pull M.CURSOR_SIZE out of theme.lua so there is one source of truth."""
    try:
        src = open(THEME_LUA, encoding="utf-8").read()
    except OSError:
        return default
    m = re.search(r"^M\.CURSOR_SIZE\s*=\s*(\d+)", src, re.M)
    return int(m.group(1)) if m else default


def read_mode():
    """'dark' or 'light' -- the body colour the theme decided on."""
    try:
        with open(MODE_FILE, encoding="utf-8") as f:
            v = f.read().strip()
    except OSError:
        return "dark"
    return "light" if v == "light" else "dark"


def body_luma(mode):
    return 255 if mode == "dark" else 0


def themes_for(mode):
    """(solid, rimmed) for the given mode's body colour."""
    return ((SOLID_WHITE, RIMMED_WHITE) if mode == "dark"
            else (SOLID_BLACK, RIMMED_BLACK))


def choose(luma, mode, rimmed):
    """Background luminance -> (theme or None, label).

    None means "leave it alone", which is what the hysteresis band returns.
    """
    solid, rim = themes_for(mode)
    gap = abs(luma - body_luma(mode))
    if not rimmed:
        return (rim if gap <= NEAR_ON else solid), ("rim ON" if gap <= NEAR_ON else "solid")
    return (rim if gap < NEAR_OFF else solid), ("rim ON" if gap < NEAR_OFF else "solid OFF")


def setcursor(theme, size):
    try:
        subprocess.run(["hyprctl", "setcursor", theme, str(size)],
                       capture_output=True, timeout=5)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def main():
    verbose = "--verbose" in sys.argv
    once = "--once" in sys.argv
    size = read_size()
    mode = read_mode()
    solid, rim = themes_for(mode)
    current = solid
    rimmed = False
    last_sample_xy = None
    last_sample_at = 0.0
    candidate = None
    candidate_hits = 0

    log("started size=%d mode=%s current=%s" % (size, mode, current))

    while True:
        pos = cursor_pos()
        if pos is None:
            time.sleep(POLL)
            continue

        # darkMode may have flipped since the last tick. Re-seed from the solid
        # variant of the new body colour and drop the rim: a theme change is a
        # fresh decision, not a continuation of the old one.
        new_mode = read_mode()
        if new_mode != mode:
            mode = new_mode
            solid, rim = themes_for(mode)
            rimmed = False
            current = solid
            candidate, candidate_hits = None, 0
            setcursor(current, size)
            log("mode -> %s, reseeded to %s" % (mode, current))

        moved = (last_sample_xy is None
                 or abs(pos[0] - last_sample_xy[0]) >= MIN_MOVE
                 or abs(pos[1] - last_sample_xy[1]) >= MIN_MOVE)
        now = time.time()
        if moved and (now - last_sample_at) >= MIN_SAMPLE_INTERVAL:
            last_sample_at = now
            last_sample_xy = pos
            luma = sample_luma(pos[0], pos[1])
            if luma is not None:
                theme, label = choose(luma, mode, rimmed)
                if verbose:
                    log("pos=%s luma=%.0f %s -> %s" % (pos, luma, label, theme))
                if theme is None or theme == current:
                    candidate, candidate_hits = None, 0
                else:
                    if theme == candidate:
                        candidate_hits += 1
                    else:
                        candidate, candidate_hits = theme, 1
                    if candidate_hits >= CONFIRM:
                        if setcursor(candidate, size):
                            log("switch %s -> %s (luma=%.0f, %dx%d, %s)"
                                % (current, candidate, luma, pos[0], pos[1], label))
                            current = candidate
                            rimmed = (candidate == rim)
                        candidate, candidate_hits = None, 0
                if once:
                    return 0
        time.sleep(POLL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass