#!/bin/bash
# Restart the desktop shell (quickshell ii). Lives outside /tmp so a wiped
# tmpdir can't leave us "verifying" against a shell that never restarted.
#
# Hardened against the double-instance race: two racing `qs` processes fight
# over layer surfaces and the global-shortcut registration, which is how the
# SUPER key "died" once. Kill EVERY old instance and WAIT until the process
# table is clean before starting the new one.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

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
