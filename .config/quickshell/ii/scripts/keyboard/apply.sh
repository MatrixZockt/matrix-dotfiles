#!/usr/bin/env bash
# Regenerate ~/.config/hypr/custom/keyboard.lua from the layouts stored in the
# shell config (~/.config/illogical-impulse/config.json -> keyboard.layouts).
#
# This script is the ONLY writer of custom/keyboard.lua. The settings app just
# edits the config file and calls this, so there is a single source of truth and
# the UI never hand-writes Hyprland config.
#
# Usage:
#   apply.sh                      write the file and reload Hyprland
#   apply.sh --no-reload          write the file only (used at login, where
#                                 Hyprland is already reading the file)
#   apply.sh --layouts de,us      set the list first, then write and reload
#   apply.sh --layouts de,us --no-reload
#
# `--layouts` is how the settings app changes things: it hands over the new
# list and this script is the one thing that writes the config, so the UI never
# has to write JSON through a data binding.

set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/config.json"
OUT="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/keyboard.lua"
RELOAD=1
LAYOUTS_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-reload) RELOAD=0 ;;
        --layouts) shift; LAYOUTS_ARG="${1:-}" ;;
        --layouts=*) LAYOUTS_ARG="${1#--layouts=}" ;;
    esac
    shift || true
done

if [ -n "$LAYOUTS_ARG" ]; then
    python3 - "$CONFIG" "$LAYOUTS_ARG" <<'PY'
import json, os, re, sys

config_path, raw = sys.argv[1], sys.argv[2]

try:
    with open(config_path) as fh:
        cfg = json.load(fh)
except Exception:
    cfg = {}

layouts = []
for code in raw.split(","):
    code = code.strip().lower()
    if re.fullmatch(r"[a-z]{2,3}", code) and code not in layouts:
        layouts.append(code)

if layouts:
    keyboard = cfg.get("keyboard")
    if not isinstance(keyboard, dict):
        keyboard = {}
    keyboard["layouts"] = layouts
    keyboard.setdefault("options", "grp:alt_shift_toggle")
    cfg["keyboard"] = keyboard
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w") as fh:
        json.dump(cfg, fh, indent=2)
PY
fi

mkdir -p "$(dirname "$OUT")"

python3 - "$CONFIG" "$OUT" <<'PY'
import json
import re
import sys

config_path, out_path = sys.argv[1], sys.argv[2]

try:
    with open(config_path) as fh:
        cfg = json.load(fh)
except Exception:
    cfg = {}

keyboard = cfg.get("keyboard") or {}


def clean_layout(code):
    """Only accept real xkb layout codes, so a bad value can never reach
    Hyprland's config (or end up interpolated into the generated Lua)."""
    code = str(code).strip().lower()
    return code if re.fullmatch(r"[a-z]{2,3}", code) else None


layouts = []
for code in keyboard.get("layouts") or []:
    cleaned = clean_layout(code)
    if cleaned and cleaned not in layouts:
        layouts.append(cleaned)
if not layouts:
    layouts = ["us"]

# xkb option list. Defaults to Alt+Shift toggling between the layouts above.
options = str(keyboard.get("options", "grp:alt_shift_toggle")).strip()
if options and not re.fullmatch(r"[a-zA-Z0-9_:+.,-]*", options):
    options = "grp:alt_shift_toggle"

lines = [
    "-- GENERATED FILE -- do not edit by hand.",
    "--",
    "-- Written by scripts/keyboard/apply.sh from the keyboard.layouts list in the",
    "-- shell config. Manage the list in Settings > Keyboard (Super+I, then the",
    "-- Keyboard page) or in ~/.config/illogical-impulse/config.json; anything",
    "-- typed in here is overwritten the next time that list changes.",
    "",
    "hl.config({",
    "    input = {",
    '        kb_layout = "%s",' % ",".join(layouts),
]
if options:
    lines.append('        kb_options = "%s",' % options)
lines += ["    },", "})", ""]

body = "\n".join(lines)

try:
    current = open(out_path).read()
except OSError:
    current = None

if current != body:
    with open(out_path, "w") as fh:
        fh.write(body)

sys.stderr.write("keyboard: layouts=%s options=%s\n" % (
    ",".join(layouts), options or "(none)"))
PY

if [ "$RELOAD" = "1" ]; then
    # Not fatal: this also runs from contexts where Hyprland may be restarting.
    hyprctl reload >/dev/null 2>&1 || true
fi
