#!/usr/bin/env bash
# ── Window controls ──────────────────────────────────────────────────────────
# A "buttons on the window" menu for the focused window: close, minimize,
# maximize, fullscreen, float, pin, center, force-kill.
#
# Why a menu and not real buttons in the title bar: Hyprland never draws window
# decorations (no title bar, no buttons) - that is a deliberate design decision of
# the compositor, and adding real buttons needs a compositor plugin (hyprbars).
# This menu gives the same actions from inside any application.
#
# Reach it with:  SUPER + Escape
#            or:  SUPER + scroll-down (while the pointer is inside a window)
set -u

# Name of the window the actions will apply to, shown in the menu prompt.
title=$(hyprctl -j activewindow 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
name = data.get("title") or data.get("class") or "active window"
print(name[:38])
' 2>/dev/null)

# Hyprland 0.56 dropped the legacy verbs (hyprctl dispatch killactive); every
# dispatch goes through the Lua dispatchers: hl.dsp.window.close() and friends.
dispatch() { hyprctl dispatch "$1" >/dev/null 2>&1; }

choice=$(printf '%s\n' \
    'Close window' \
    'Minimize (hide)' \
    'Show minimized windows' \
    'Maximize / restore' \
    'Fullscreen' \
    'Float / tile' \
    'Pin on all workspaces' \
    'Center on screen' \
    'Force kill (frozen app)' \
    | fuzzel --dmenu --prompt="Window: ${title}  ") || exit 0

case "$choice" in
    'Close window')            dispatch 'hl.dsp.window.close()' ;;
    'Minimize (hide)')         dispatch 'hl.dsp.window.move({ workspace = "special:minimized", follow = false })' ;;
    'Show minimized windows')  dispatch 'hl.dsp.workspace.toggle_special("minimized")' ;;
    'Maximize / restore')      dispatch 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })' ;;
    'Fullscreen')              dispatch 'hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })' ;;
    'Float / tile')            dispatch 'hl.dsp.window.float({ action = "toggle" })' ;;
    'Pin on all workspaces')   dispatch 'hl.dsp.window.pin()' ;;
    'Center on screen')        dispatch 'hl.dsp.window.center()' ;;
    'Force kill (frozen app)') dispatch 'hl.dsp.window.kill()' ;;
esac
