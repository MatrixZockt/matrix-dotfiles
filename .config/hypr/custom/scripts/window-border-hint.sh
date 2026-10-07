#!/usr/bin/env bash
# Start the window border hint exactly once.
#
# Same shape and the same reasoning as scripts/launch/shell.sh: the autostart
# in custom/execs.lua runs on every parse AND every reload, and a config reload
# would otherwise stack a second copy of the daemon. Two daemons would fight
# over the same border colour, each restoring it when the other had just set
# it, which reads as a border that flickers between black and the resting
# colour as the pointer moves.
#
# The `pgrep -f "[w]indow-border-hint.py"` character class is load-bearing: a
# plain pattern would match this script's own command line (and the exec
# shell's), so a "guard" that kills itself looks exactly like "the hint keeps
# dying for no reason".
set -u

if pgrep -f "[w]indow-border-hint.py" >/dev/null 2>&1; then
    exit 0
fi

# The daemon talks to Hyprland over $HYPRLAND_INSTANCE_SIGNATURE and drives the
# pointer position with hyprctl. A config parse that happens before the
# compositor environment is complete would spawn one that exits immediately and
# never comes back, so only start when the signature is actually present.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    exit 0
fi

exec "$HOME/.config/hypr/custom/scripts/window-border-hint.py" \
    >/tmp/window-border-hint.log 2>&1
