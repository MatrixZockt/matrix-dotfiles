#!/usr/bin/env bash
# Keybind customisation.
#
# This shell's binds are written in Lua, and Hyprland reports every one of them to
# `hyprctl binds` with dispatcher `__lua` -- the action is a Lua closure, not a
# string that could be re-created. So a key combo cannot simply be "re-bound" from
# the outside: there is nothing to re-bind it *to*.
#
# What can be done reliably, and is what this provides, is an override layer on top
# of the real config:
#
#   * switch a shortcut OFF            -> `hl.unbind("SUPER + T")`
#   * add your own shortcut            -> `hl.bind("SUPER + Y", hl.dsp.exec_cmd("kitty"))`
#
# Those live in ~/.config/illogical-impulse/keybinds.json (this script is its only
# writer), and are turned into ~/.config/hypr/custom/keybind-overrides.lua, which
# custom/keybinds.lua requires at the very end so it wins over everything above it.
#
# Usage:
#   apply.sh                              regenerate and reload
#   apply.sh --no-reload                  regenerate only
#   apply.sh --disable 'SUPER + T'        add to the removed list
#   apply.sh --enable  'SUPER + T'        drop from the removed list
#   apply.sh --remove-custom 2            drop custom entry 2 (0-based)
#   apply.sh --add-keys 'SUPER + Y' --add-cmd 'kitty' --add-desc 'Custom: kitty'

set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/keybinds.json"
OUT="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/keybind-overrides.lua"
RELOAD=1
DISABLE=""
ENABLE=""
REMOVE_CUSTOM=""
ADD_KEYS=""
ADD_CMD=""
ADD_DESC=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-reload) RELOAD=0 ;;
        --disable) shift; DISABLE="${1:-}" ;;
        --enable) shift; ENABLE="${1:-}" ;;
        --remove-custom) shift; REMOVE_CUSTOM="${1:-}" ;;
        --add-keys) shift; ADD_KEYS="${1:-}" ;;
        --add-cmd) shift; ADD_CMD="${1:-}" ;;
        --add-desc) shift; ADD_DESC="${1:-}" ;;
    esac
    shift || true
done

python3 - "$CONFIG" "$OUT" "$DISABLE" "$ENABLE" "$REMOVE_CUSTOM" "$ADD_KEYS" "$ADD_CMD" "$ADD_DESC" <<'PY'
import json
import os
import re
import sys

config_path, out_path, disable, enable, remove_custom, add_keys, add_cmd, add_desc = sys.argv[1:9]

try:
    with open(config_path) as fh:
        data = json.load(fh)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
removed = [k for k in (data.get("removed") or []) if isinstance(k, str)]
custom = [c for c in (data.get("custom") or []) if isinstance(c, dict)]

# Key combos are passed through Hyprland, so keep them to characters it accepts in
# a config: modifiers, digits, letters and the usual key names.
SAFE_KEYS = re.compile(r"^[A-Za-z0-9 +_,:()\-.]+$")


def clean_keys(keys):
    keys = " ".join(str(keys).split())
    return keys if keys and SAFE_KEYS.match(keys) else None


if disable:
    k = clean_keys(disable)
    if k and k not in removed:
        removed.append(k)
if enable:
    k = clean_keys(enable)
    if k:
        removed = [r for r in removed if r != k]
if remove_custom != "":
    try:
        idx = int(remove_custom)
        if 0 <= idx < len(custom):
            custom.pop(idx)
    except ValueError:
        pass
if add_keys:
    k = clean_keys(add_keys)
    if k and add_cmd:
        custom.append({
            "keys": k,
            "command": str(add_cmd),
            "description": str(add_desc) or ("Custom: " + k),
        })

data["removed"] = removed
data["custom"] = custom
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as fh:
    json.dump(data, fh, indent=2)

lines = [
    "-- GENERATED FILE -- do not edit by hand.",
    "--",
    "-- Written by scripts/keybinds/apply.sh from",
    "-- ~/.config/illogical-impulse/keybinds.json. Manage it from",
    "-- Settings > Keybinds (Super+I, then the Keybinds page). Anything typed in here",
    "-- is overwritten the next time a shortcut is added or switched off.",
    "",
    "-- Shortcuts switched off in the settings.",
]
for k in removed:
    lines.append('hl.unbind("%s")' % k.replace('"', ''))

if custom:
    lines.append("")
    lines.append("-- Shortcuts added in the settings.")
    for entry in custom:
        keys = clean_keys(entry.get("keys"))
        command = str(entry.get("command") or "").strip()
        if not keys or not command:
            continue
        desc = str(entry.get("description") or ("Custom: " + keys)).replace("\\", "\\\\").replace('"', '\\"')
        cmd = command.replace("\\", "\\\\").replace('"', '\\"')
        lines.append('hl.bind("%s", hl.dsp.exec_cmd("%s"), { description = "%s" })' % (keys, cmd, desc))

body = "\n".join(lines) + "\n"

try:
    current = open(out_path).read()
except OSError:
    current = None

if current != body:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as fh:
        fh.write(body)

sys.stderr.write("keybinds: removed=%d custom=%d\n" % (len(removed), len(custom)))
PY

if [ "$RELOAD" = "1" ]; then
    # Not fatal: this also runs from contexts where Hyprland may be restarting.
    hyprctl reload >/dev/null 2>&1 || true
fi
