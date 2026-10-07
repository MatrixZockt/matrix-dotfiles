#!/usr/bin/env bash
# dismiss-loading.sh -- take the shell loading indicator off the screen, now.
#
# WHY THIS EXISTS. The indicator is a full-screen layer surface. If it is ever
# left up over a desktop that has in fact finished loading -- because the
# watcher that normally removes it died, or it started before a reset and the
# reset's own teardown raced it -- the user is left staring at a spinner on a
# desktop that is otherwise perfectly working, with no way to get rid of it and
# no way to tell that what they are looking at is not the real shell.
#
# That is the worst failure this mechanism has, and it is strictly worse than
# showing no indicator at all: an indicator that cannot be dismissed removes the
# user's ability to act while telling them nothing true. So the escape hatch is
# a key, not a heuristic.
#
# IT REMOVES THE INDICATOR AND NOTHING ELSE. No shell is killed, nothing is
# restarted, no config is touched. If the shell really is still loading, this
# just takes the card away and leaves the load to finish on its own -- the
# user gets their screen back either way, which is the whole point.
set -u

LOG=/tmp/ii_splash.log
log() { echo "[dismiss] $(date '+%H:%M:%S') $*" >>"$LOG" 2>/dev/null || true; }

removed=0
for _cfg in splashfb splash; do
    for _pid in $(pgrep -f "[q]s -c $_cfg" 2>/dev/null); do
        # Term, then confirm, then force: an indicator that ignores SIGTERM is
        # exactly the case this script exists for, so it must not stop at the
        # polite signal.
        kill "$_pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$_pid" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$_pid" 2>/dev/null; then
            kill -9 "$_pid" 2>/dev/null || true
            log "forced pid $_pid ($_cfg)"
        fi
        removed=$((removed + 1))
        log "removed indicator pid $_pid ($_cfg)"
    done
done

if [ "$removed" -eq 0 ]; then
    log "nothing to dismiss"
fi
exit 0