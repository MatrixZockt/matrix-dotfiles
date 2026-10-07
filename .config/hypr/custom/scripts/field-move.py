#!/usr/bin/env python3
"""field-move.py -- three-finger / keyboard navigation of the tiling field.

Semantics (REQUESTED 2026-09-29): a horizontal or vertical three-finger swipe
is a SWAP, not a relocation. Swiping towards a side means "I want to be looking
at what is over there". Only when there is genuinely nothing over there does
the swipe fall back to rearranging the desktop -- and then it is the NEIGHBOUR
that moves across, so the space the swipe was asking for gets filled instead of
being left empty. Focus does not follow the move in that case.

  left / right / up / down
      1. SWAP (the normal case). There is a window over there -> focus moves to
         it. The windows do not move; you simply end up looking at the other
         one. This is what a three-finger swipe means on every other desktop,
         and it is what was asked for.
      2. FALLBACK (nothing over there). The neighbour is moved across into the
         space the swipe would have opened, and focus STAYS where it is. So the
         half of the screen you swiped towards is never left empty: the other
         app slides over to fill it, and the window you were looking at grows
         into what it vacated.

The fallback is the "one app occupies a whole side" case. Two windows side by
side, the left one full height, swipe down: there is nothing below, so nothing
to swap with -- the right-hand window moves down into the lower-left and the
focused window keeps the upper-left. Same shape for every direction.

If there is no other window on the desktop at all there is nothing to swap
with and nothing to move across, so the window wiggles (the old "no field that
way" tell, kept as motion rather than a notification).

Usage: field-move.py <left|right|up|down>   (called by 3f gestures and the
CTRL+SUPER+arrow keybinds)
"""

import json
import subprocess
import sys
import time

GAP_TOL = 26      # logical px: edge-adjacency tolerance (gaps + rounding)
BUMP = 22         # wiggle amplitude, logical px
SPAN_EXCESS = 60  # how far past our column an edge must stick out to count as a spanner
SETTLE = 0.22     # seconds to wait for the compositor to re-lay-out


def hypr_json(args):
    out = subprocess.run(["hyprctl", "-j"] + args, capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        return json.loads(out.stdout)
    except ValueError:
        return None


def dispatch(expr):
    return subprocess.run(["hyprctl", "dispatch", expr],
                          capture_output=True, text=True)


def tiled_on(wsid):
    """Mapped, tiled windows on a workspace, in LOGICAL coords."""
    wins = []
    for c in hypr_json(["clients"]) or []:
        if not isinstance(c, dict):
            continue
        ws = c.get("workspace") or {}
        if ws.get("id") != wsid:
            continue
        if c.get("floating") or c.get("pinned") or not c.get("mapped"):
            continue
        if c.get("fullscreen"):
            continue
        at, size = c.get("at") or [0, 0], c.get("size") or [0, 0]
        if size[0] <= 0 or size[1] <= 0:
            continue
        wins.append({"address": c["address"], "x": at[0], "y": at[1],
                     "w": size[0], "h": size[1], "class": c.get("class") or ""})
    return wins


def monitor_logical(windows_client):
    """(width, height, center_x) of the client's monitor, in logical px."""
    for m in hypr_json(["monitors"]) or []:
        if isinstance(m, dict) and m.get("id") == windows_client.get("monitor"):
            scale = m.get("scale") or 1.0
            lw = round(m.get("width", 1920) / scale)
            lh = round(m.get("height", 1080) / scale)
            return lw, lh, lw // 2
    return 1600, 1000, 800  # sensible default for this machine


def x_overlap(a, b):
    lo = max(a["x"], b["x"])
    hi = min(a["x"] + a["w"], b["x"] + b["w"])
    return max(0, hi - lo)


def y_overlap(a, b):
    lo = max(a["y"], b["y"])
    hi = min(a["y"] + a["h"], b["y"] + b["h"])
    return max(0, hi - lo)


def find_along(w, wins, up):
    """The window directly above (up) / below (not up) w in its column:
    its near edge sits within GAP_TOL of w's far edge and the columns
    overlap by >= 40% of w's width. Returns the best-overlap candidate."""
    best, best_ov = None, 0
    for o in wins:
        if o["address"] == w["address"]:
            continue
        if up:
            edge_ok = abs((o["y"] + o["h"]) - w["y"]) <= GAP_TOL
        else:
            edge_ok = abs(o["y"] - (w["y"] + w["h"])) <= GAP_TOL
        if not edge_ok:
            continue
        ov = x_overlap(o, w)
        if ov >= 0.4 * w["w"] and ov > best_ov:
            best, best_ov = o, ov
    return best


def spans_beyond(o, w):
    """True when o covers w's column AND sticks out well past it -- the
    'browser spanning the top over a half-width terminal' shape."""
    covers = o["x"] <= w["x"] + GAP_TOL and \
        (o["x"] + o["w"]) >= (w["x"] + w["w"]) - GAP_TOL
    sticks = o["x"] < w["x"] - SPAN_EXCESS or \
        (o["x"] + o["w"]) > (w["x"] + w["w"]) + SPAN_EXCESS
    return covers and sticks


def box_of(address):
    for c in hypr_json(["clients"]) or []:
        if isinstance(c, dict) and c.get("address") == address:
            at, size = c.get("at") or [0, 0], c.get("size") or [0, 0]
            return (at[0], at[1], size[0], size[1])
    return None


def neighbor_in_direction(w, wins, direction):
    """The window a swipe towards `direction` should swap focus with: the
    NEAREST one whose centre lies on that side of ours and which shares our
    column (up/down) or our row (left/right) closely enough to read as being
    "over there" rather than somewhere unrelated.

    Direction names are the swipes: left/right/up/down.
    """
    wcx, wcy = w["x"] + w["w"] / 2, w["y"] + w["h"] / 2
    best, best_d = None, None
    for o in wins:
        if o["address"] == w["address"]:
            continue
        ocx, ocy = o["x"] + o["w"] / 2, o["y"] + o["h"] / 2
        if direction == "left":
            if ocx >= wcx - GAP_TOL:
                continue
            cross = y_overlap(o, w)
            along = wcx - ocx
        elif direction == "right":
            if ocx <= wcx + GAP_TOL:
                continue
            cross = y_overlap(o, w)
            along = ocx - wcx
        elif direction == "up":
            if ocy >= wcy - GAP_TOL:
                continue
            cross = x_overlap(o, w)
            along = wcy - ocy
        else:  # down
            if ocy <= wcy + GAP_TOL:
                continue
            cross = x_overlap(o, w)
            along = ocy - wcy
        # It has to actually share the row/column we are looking along, or it
        # is not "over there" -- it is just some other window.
        need = (w["h"] if direction in ("left", "right") else w["w"]) * 0.4
        if cross < need:
            continue
        d = along
        if best_d is None or d < best_d:
            best, best_d = o, d
    return best


def wiggle(win, direction, floating):
    """The 'cannot go that way' tell: two quick bumps of the window's own
    edge toward the swiped direction, then back. Tiled windows bump via
    resize (tree untouched); floats via pixel move and back."""
    addr = win["address"]
    dx = BUMP if direction == "right" else -BUMP if direction == "left" else 0
    dy = BUMP if direction == "down" else -BUMP if direction == "up" else 0
    try:
        if floating:
            ox, oy = win["x"], win["y"]
            for sign in (1, -1, 1, -1):
                dispatch('hl.dsp.window.move({ window = "address:%s", x = %d, y = %d })'
                         % (addr, ox + dx * sign, oy + dy * sign))
                time.sleep(0.1)
            dispatch('hl.dsp.window.move({ window = "address:%s", x = %d, y = %d })'
                     % (addr, ox, oy))
        else:
            w0, h0 = win["w"], win["h"]
            dw = abs(dx)
            dh = abs(dy)
            for sign in (1, -1, 1, -1):
                dispatch('hl.dsp.window.resize({ window = "address:%s", x = %d, y = %d })'
                         % (addr, w0 + dw * sign, h0 + dh * sign))
                time.sleep(0.1)
            dispatch('hl.dsp.window.resize({ window = "address:%s", x = %d, y = %d })'
                     % (addr, w0, h0))
    except Exception:
        pass


def focus_address(address):
    """Focus a window by address. The window dispatchers on this build act on
    the FOCUSED window, so focusing is how a swap is expressed: the two
    windows do not move at all, only which one you are looking at does."""
    dispatch('hl.dsp.focus({ window = "address:%s" })' % address)


def move_address(address, direction):
    d = {"left": "l", "right": "r", "up": "u", "down": "d"}[direction]
    dispatch('hl.dsp.window.move({ window = "address:%s", direction = "%s" })'
             % (address, d))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args or args[0] not in ("left", "right", "up", "down"):
        print(__doc__)
        return 2
    direction = args[0]

    act = hypr_json(["activewindow"])
    if not act:
        return 0  # nothing focused: nothing to swap with, nothing to move
    ws = (act.get("workspace") or {}).get("id")
    if ws is None or (isinstance(ws, int) and ws < 0):
        return 0

    focused = {"address": act["address"], "x": (act.get("at") or [0, 0])[0],
               "y": (act.get("at") or [0, 0])[1],
               "w": (act.get("size") or [0, 0])[0],
               "h": (act.get("size") or [0, 0])[1]}

    # Floating windows do not participate in the field; a swipe on one is a
    # refusal wiggle (the float layer has no fields).
    if act.get("floating"):
        wiggle(focused, direction, floating=True)
        return 0

    wins = tiled_on(ws)
    if len(wins) <= 1:
        # Nothing to swap with AND nothing to move across: there is only one
        # app, so the swipe cannot mean anything. Wiggle rather than do
        # nothing, which is indistinguishable from a broken gesture.
        wiggle(focused, direction, floating=False)
        return 0

    # ── 1. SWAP: is there a window over there? ──────────────────────────
    target = neighbor_in_direction(focused, wins, direction)
    if target is not None:
        focus_address(target["address"])
        return 0

    # ── 2. FALLBACK: nothing over there -- move the NEIGHBOUR across ─────
    #
    # Focus stays exactly where it is. What moves is the window that was
    # ALREADY on the far side of us, dragged into the space this swipe was
    # asking about, so that space ends up occupied instead of empty.
    #
    # "The neighbour" is the one whose centre is on the SAME side as us but
    # furthest along our own axis -- i.e. the window sitting next to us in the
    # direction perpendicular to the swipe. Left/right swipes look for a
    # window in our column (above or below); up/down swipes look for one in
    # our row (beside us).
    across = perpendicular_neighbor(focused, wins, direction)
    if across is None:
        wiggle(focused, direction, floating=False)
        return 0

    before = box_of(across["address"])
    move_address(across["address"], direction)
    time.sleep(SETTLE)
    if box_of(across["address"]) == before:
        # The compositor would not move it (it is extended that way already,
        # or the tree refused) -- fall back to the old tell.
        wiggle(focused, direction, floating=False)
        return 0

    # Focus deliberately NOT followed: the window you were looking at is
    # still the window you are looking at, and it has simply grown into the
    # space the neighbour vacated. That is what "move the other desktop app
    # so it would fill the empty space" asks for.
    focus_address(focused["address"])
    return 0


def perpendicular_neighbor(w, wins, direction):
    """The window to drag across in the fallback: the one next to us, i.e. the
    one sharing our column for a left/right swipe (the one above or below) or
    our row for an up/down swipe (the one beside us). Nearest by edge gap."""
    best, best_gap = None, None
    for o in wins:
        if o["address"] == w["address"]:
            continue
        if direction in ("left", "right"):
            # Same column: their vertical ranges must overlap us.
            ov = y_overlap(o, w)
            if ov < 0.4 * w["h"]:
                continue
            if o["y"] + o["h"] <= w["y"] + GAP_TOL:
                gap = w["y"] - (o["y"] + o["h"])
            elif o["y"] >= w["y"] + w["h"] - GAP_TOL:
                gap = o["y"] - (w["y"] + w["h"])
            else:
                gap = 0
        else:
            # Same row: their horizontal ranges must overlap us.
            ov = x_overlap(o, w)
            if ov < 0.4 * w["w"]:
                continue
            if o["x"] + o["w"] <= w["x"] + GAP_TOL:
                gap = w["x"] - (o["x"] + o["w"])
            elif o["x"] >= w["x"] + w["w"] - GAP_TOL:
                gap = o["x"] - (w["x"] + w["w"])
            else:
                gap = 0
        if best_gap is None or gap < best_gap:
            best, best_gap = o, gap
    return best


if __name__ == "__main__":
    sys.exit(main())
