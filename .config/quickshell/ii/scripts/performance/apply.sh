#!/usr/bin/env bash
# Regenerate ~/.config/hypr/custom/performance.lua from the shell config
# (~/.config/illogical-impulse/config.json -> performanceMode).
#
# This script is the ONLY writer of custom/performance.lua. The settings app and
# the right-sidebar button just set the config value and call this, so the UI
# never hand-writes Hyprland config -- the same contract scripts/keyboard/apply.sh
# uses for the keyboard layouts.
#
# Usage:
#   apply.sh                 write the file from the config, then reload Hyprland
#   apply.sh on|off          use this value, write, reload (the UI's path: the
#                            config write is debounced, so the value is handed
#                            over explicitly instead of being read back)
#   apply.sh on --no-reload  used at login, where Hyprland is already reading
#                            the file
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/config.json"
OUT="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/performance.lua"
RELOAD=1
VALUE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-reload) RELOAD=0 ;;
        on|true|1) VALUE=1 ;;
        off|false|0) VALUE=0 ;;
    esac
    shift || true
done

python3 - "$CONFIG" "$OUT" "$VALUE" <<'PY'
import json, os, sys

config_path, out_path, value = sys.argv[1], sys.argv[2], sys.argv[3]

on = None
if value != "":
    on = value == "1"
if on is None:
    try:
        with open(config_path) as f:
            on = bool(json.load(f).get("performanceMode", False))
    except (OSError, ValueError):
        on = False

HEAD = """-- ═══ Performance mode — GENERATED, do not edit by hand ═══════════════════
--
-- Rewritten by ~/.config/quickshell/ii/scripts/performance/apply.sh every time
-- you flip "Performance mode" (the settings app, or the right-sidebar button /
-- its top-bar icon). That script is the only writer, so there is one source of
-- truth: the shell config's `performanceMode`.
--
-- With it ON the interface keeps its look, its layout and every feature -- the
-- same theme, the same windows, the same gestures. Only the motion budget goes
-- away: the compositor's animations are switched off below, and the two things
-- custom/general.lua animates by hand (the fullscreen -> anchored glide and the
-- finger-following close-drag) cut straight to the end instead of issuing a
-- dispatch per frame. See custom/performance.lua (`performance`) for that half.

local M = {}

-- Read at RUN time by the gesture and keybind code (custom/general.lua), so
-- the same config works whether the flag is on or off -- and so the toggle
-- takes effect on the next gesture, not on the next login.
M.performance = false
function M.setPerformance(on)
    M.performance = on and true or false
end
"""

# Every leaf this configuration animates, EXCEPT workspace switching: the
# four workspace leaves are deliberately not in this list. Switching desktops
# is navigation, and killing it made Super+digit and the 4-finger swipe
# teleport (reported 2026-10-18). Power Mode already made this exact call for
# the same reason (see PowerMode.qml: "the desktop switch is the one that
# hurt, because it is navigation") -- boost keeps the same carve-out, so the
# mode still cuts windows, fades, layers, zoom and borders and only lets
# navigation slide.
#
# They are disabled ONE BY ONE on
# purpose: in this build `hl.config` is first-wins for nested tables while the
# config is being read (the base config sets animations.enabled = true first, so
# setting it again in a later file is silently ignored), whereas an
# `hl.animation` call for the same leaf is last-wins -- which is exactly how the
# custom files already re-tune windowsIn/Out. The master switch is pushed at
# runtime by the last lines of this script, as `true` in every state (a master
# `false` would override the carve-out above).
# Every leaf the configs actually name, taken from the configs themselves
# (`grep -rho 'leaf = "[a-zA-Z]*"' ~/.config/hypr`) so nothing is guessed, plus
# the generic `global`/`borderangle` leaves.
LEAVES = [
    "global", "border", "borderangle", "windows", "windowsIn", "windowsOut",
    "windowsMove", "fade", "fadeIn", "fadeOut", "layers", "layersIn",
    "layersOut", "fadeLayersIn", "fadeLayersOut",
    "zoomFactor",
]

# The flag lives in this module now (it used to hang off custom/popup.lua,
# whose popup-app support is retired). The ON branch flips it directly -- the
# module cannot require itself -- and every branch ends with the module's
# return.
if on:
    body = HEAD + """
M.setPerformance(true)
"""
    for leaf in LEAVES:
        body += 'hl.animation({ leaf = "%s", enabled = false, speed = 1 })\n' % leaf
else:
    body = HEAD + """
-- OFF right now: nothing to do -- the interface animates as configured in
-- custom/general.lua.
"""
body += "\nreturn M\n"

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    f.write(body)
print("performance mode: %s" % ("ON" if on else "OFF"))
PY

if [ "$RELOAD" -eq 1 ]; then
    hyprctl reload >/dev/null 2>&1 || true
fi

# The master switch, pushed in BOTH directions as `enabled = true`.
#
# It used to push `false` while the mode was on, and that master kill is
# absolute: it overrides every per-leaf setting, so the workspace carve-out
# above could not survive it -- desktop switches teleported again no matter
# what the LEAVES list said (reported 2026-10-18). The leaves themselves are
# what boost means now (they are last-wins and reload-surviving; see LEAVES),
# so the master stays ON in every state and simply re-asserts it on a flip.
if [ "$VALUE" != "" ]; then
    hyprctl eval "hl.config({ animations = { enabled = true } })" >/dev/null 2>&1 || true
fi

# The CPU clock policy (EPP) is power policy, not presentation: the decision
# goes to the one policy table (power-autoswitch's converge, which reads this
# same config key) instead of sysfs here, so the boost toggle and the Power
# Mode feed one rule and only one writer ever holds the root path. The value
# is passed as --boost= rather than left to be read from the config: the
# config write is debounced (the reason this script takes on|off explicitly),
# so a backgrounded converge reading the file would race it. Backgrounded so
# the UI's flip never waits on pkexec; converge is a no-op for anything
# already in force. Without this the toggle only moved animations and the
# machine's EPP kept whatever the profile last set (measured 2026-10-18).
if [ -x "$HOME/.local/bin/power-autoswitch" ]; then
    if [ -n "$VALUE" ]; then
        "$HOME/.local/bin/power-autoswitch" --converge "--boost=$VALUE" &
    else
        "$HOME/.local/bin/power-autoswitch" --converge &
    fi
fi
