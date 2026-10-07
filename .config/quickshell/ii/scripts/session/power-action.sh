#!/usr/bin/env bash
# Restart or power off -- in order, and without cutting anything off mid-write.
#
# The shell used to do this in one step: SIGTERM every window's pid, then
# `reboot`/`systemctl poweroff` immediately afterwards. That is the abrupt
# version, and it loses work in two separate ways. The SIGTERMs go out and the
# machine is torn down in the same instant, so an application that was in the
# middle of saving -- a browser writing session state, an editor flushing a
# buffer, a document autosaving -- never gets to finish, and it is killed by
# the shutdown instead. And nothing held a logind inhibitor, so a pending
# update or an uninterruptible task could veto the whole thing at the last
# moment, or the reboot could simply fail.
#
# This does it in the order a careful person would:
#
#   1. take a shutdown inhibitor, so nothing can veto or delay this while it
#      is in progress (and so the reason is recorded in the journal)
#   2. ASK every window's application to close -- SIGTERM, which is the polite
#      request, so each app can save and exit on its own terms
#   3. WAIT for them, up to GRACE seconds, and only then force the stragglers
#      with SIGKILL. An app that ignores the polite request gets the rough one;
#      an app that was saving gets to finish first, which is the whole point.
#   4. sync, to push those writes all the way to the disk before the machine
#      starts tearing itself down
#   5. hand over to systemd, which stops services in dependency order, unmounts
#      filesystems cleanly, and does the actual power transition
#
# Usage:
#   power-action.sh reboot|poweroff     do it
#   power-action.sh <action> --dry-run  report what would happen, do nothing

set -uo pipefail

ACTION="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ "$ACTION" != "reboot" && "$ACTION" != "poweroff" ]]; then
    echo "usage: $(basename "$0") reboot|poweroff [--dry-run]" >&2
    exit 64
fi

# Long enough that a big save finishes, short enough that a hung app does not
# sit there for a minute after you asked to shut down.
# Overridable from the environment so the escalation below can be exercised
# without a real twelve-second wait.
GRACE="${GRACE:-12}"
POLITE=TERM

# Every process behind a window, deduplicated: one app can own several windows,
# and asking the same pid to close five times is noise in the logs.
window_pids() {
    hyprctl clients -j 2>/dev/null | jq -r '.[].pid' 2>/dev/null |
        sort -un | grep -E '^[0-9]+$'
}

alive_pids() {
    local pid
    for pid in "$@"; do
        kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
    done
}

if [[ $DRY_RUN -eq 1 ]]; then
    mapfile -t PIDS < <(window_pids)
    echo "action:      $ACTION"
    echo "apps to ask: ${#PIDS[@]} (${PIDS[*]:-none})"
    echo "grace:       ${GRACE}s of SIG$POLITE before SIGKILL"
    echo "inhibitor:   $(command -v systemd-inhibit >/dev/null 2>&1 && echo available || echo MISSING)"
    exit 0
fi

# ── 1. Hold a shutdown inhibitor for the whole sequence ─────────────────────
# `delay` mode makes logind wait for us rather than proceeding immediately,
# and any other inhibitor that wants to block (an update being installed, a
# package transaction running) gets a chance to finish or be reported instead
# of the machine yanking itself out from under it.
#
# The recursion guard reads $2, NOT $1. $1 is always the action ("reboot" /
# "poweroff"); "--inner" arrives as the second argument. Testing $1 against
# "--inner" is always true, so the script re-executed itself through
# systemd-inhibit forever and the machine never shut down at all -- a failure
# that only appears when someone actually clicks the button.
if [[ "${2:-}" != "--inner" ]] && command -v systemd-inhibit >/dev/null 2>&1; then
    exec systemd-inhibit \
        --what=shutdown \
        --mode=delay \
        --who="ii power menu" \
        --why="Powering $ACTION from the desktop shell" \
        "$0" "$ACTION" --inner
fi

# ── 2 & 3. Ask, wait, then insist ───────────────────────────────────────────
mapfile -t PIDS < <(window_pids)
if [[ ${#PIDS[@]} -gt 0 ]]; then
    echo "Closing ${#PIDS[@]} application(s) politely..."
    kill -"$POLITE" "${PIDS[@]}" 2>/dev/null

    waited=0
    REMAINING=("${PIDS[@]}")
    while [[ $waited -lt $GRACE ]]; do
        sleep 0.5
        waited=$((waited + 1))
        mapfile -t REMAINING < <(alive_pids "${PIDS[@]}")
        [[ ${#REMAINING[@]} -eq 0 ]] && break
    done

    if [[ ${#REMAINING[@]} -gt 0 ]]; then
        echo "${#REMAINING[@]} did not close in ${GRACE}s: ${REMAINING[*]}"
        echo "Forcing them (they may lose unsaved work)."
        kill -KILL "${REMAINING[@]}" 2>/dev/null
        # A moment for the kernel to reap them, so systemd does not meet them
        # mid-teardown and log a pile of failures on the way down.
        sleep 0.5
    else
        echo "All applications closed cleanly."
    fi
fi

# ── 4. Flush writes to disk ─────────────────────────────────────────────────
# Anything the applications just saved is still only in the page cache at this
# point. sync puts it on the disk before the shutdown starts unmounting.
sync

# ── 5. Hand over to systemd ─────────────────────────────────────────────────
# systemctl does the ordered, correct shutdown: stop services in dependency
# order, unmount filesystems, and power off or reboot. loginctl is the fallback
# for the rare case the bus call itself fails.
echo "System is $ACTION now."
if ! systemctl "$ACTION"; then
    loginctl "$ACTION" 2>/dev/null || loginctl "$ACTION"
fi