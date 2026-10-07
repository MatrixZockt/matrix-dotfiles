#!/usr/bin/env bash
# Start the adaptive cursor picker exactly once.
#
# Same shape and the same reasoning as scripts/window-border-hint.sh: the
# autostart in custom/execs.lua runs on every parse AND every reload, and a
# config reload would otherwise stack a second copy of the daemon. Two copies
# would fight over the cursor theme, each setting it from its own sample of the
# pointer position, which reads as a pointer that flickers between the solid and
# rimmed variants while the mouse sits still.
#
# The `pgrep -f "[c]ursor-adapt.py"` character class is load-bearing for the
# same reason it is there: a plain pattern matches this script's own command
# line, so a guard that kills itself looks exactly like "the daemon keeps
# dying for no reason".
set -u

if pgrep -f "[c]ursor-adapt.py" >/dev/null 2>&1; then
    exit 0
fi

# The daemon shells out to `hyprctl cursorpos` and `grim`, both of which need a
# live compositor and a Wayland session. A config parse that happens before the
# session is complete would spawn one that exits immediately and never returns,
# so only start once the signature is actually present.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    exit 0
fi

if ! command -v grim >/dev/null 2>&1; then
    exit 0
fi

exec "$HOME/.config/hypr/custom/scripts/cursor-adapt.py" \
    >/tmp/cursor-adapt.out 2>&1