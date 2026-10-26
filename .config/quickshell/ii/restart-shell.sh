#!/bin/bash
# Restart the desktop shell (quickshell ii). Lives outside /tmp so a wiped
# tmpdir can't leave us "verifying" against a shell that never restarted.
#
# Hardened against the double-instance race: two racing `qs` processes fight
# over layer surfaces and the global-shortcut registration, which is how the
# SUPER key "died" once. Kill EVERY old instance and WAIT until the process
# table is clean before starting the new one.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# The pointer's theme, stated here as well as in scripts/launch/shell.sh -- this
# launcher bypasses that script (`setsid qs` below) and so used to hand the
# shell whatever its own parent had. That parent can be a session started
# before the borderless Bibata themes were removed, i.e. it can name
# `Bibata-Modern-Ice-NoLine`, which is not installed: every app the shell then
# launches inherits a theme that resolves to nothing and draws a fallback
# pointer (the plain white arrow reported inside some apps). One installed name,
# never swapped per mode or per window.
export XCURSOR_THEME=Bibata-Modern-Ice

# Take the shell's ATTACHED helpers down with it, before the shell itself.
#
# pkill below ends `qs` and nothing else: every long-lived helper the shell
# spawned -- the `nmcli monitor` wrapper, `udevadm monitor`, the `wl-paste`
# watchers, the python input watcher -- stays behind, reparented to init, still
# holding memory and a D-Bus connection to a shell that no longer exists. One
# set leaked per restart until this was added (measured 2026-10-16: sixteen
# `nmcli monitor` processes at once). Order matters: the parent link is what
# identifies a helper as the shell's, and it is gone the moment the shell dies.
# Applications are spared -- they detach with `setsid` and the helper only takes
# processes still attached to the shell's session (see shell-tree.sh, and its
# `--self-test`).
tree_helper="$HOME/.config/quickshell/ii/scripts/launch/shell-tree.sh"
if [ -r "$tree_helper" ]; then
    # shellcheck source=/dev/null
    . "$tree_helper"
    stopped=$(shell_tree_stop "$(pgrep -f '[q]s -c ii' 2>/dev/null | tr '\n' ' ')")
    [ "$stopped" -gt 0 ] && echo "stopped $stopped attached helper process(es)"
fi

pkill -f '[q]s -c ii' 2>/dev/null
for _ in $(seq 1 24); do
    pgrep -f '[q]s -c ii' >/dev/null || break
    sleep 0.25
done
if pgrep -f '[q]s -c ii' >/dev/null; then
    pkill -9 -f '[q]s -c ii' 2>/dev/null
    sleep 0.5
fi

setsid qs -c ii > /tmp/qs-restart.log 2>&1 < /dev/null &
sleep 4
count=$(pgrep -cf '[q]s -c ii')
new=$(pgrep -f '[q]s -c ii' | head -1)
if [ -n "$new" ] && [ "$count" -eq 1 ]; then
    echo "shell restarted: pid $new (single instance)"
elif [ -n "$new" ]; then
    echo "WARNING: $count instances running (pids: $(pgrep -f '[q]s -c ii' | tr '\n' ' '))" >&2
else
    echo "ERROR: shell did not come up; see /tmp/qs-restart.log" >&2
    exit 1
fi
