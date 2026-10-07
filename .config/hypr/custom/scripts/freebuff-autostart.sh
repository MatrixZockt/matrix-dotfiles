#!/usr/bin/env bash
# Freebuff Desktop autostart.
#
# WHY THIS IS A SCRIPT AND NOT A BARE `hl.exec_cmd("freebuff-desktop")`
# ----------------------------------------------------------------------
#  * The old `exec-once = freebuff` line died in the Lua rewrite. It pointed
#    at the bare name `freebuff`, which no longer exists for this purpose
#    anyway: that name was the GUI launcher's until it was renamed to
#    `freebuff-desktop` so it stopped shadowing the real Freebuff CLI on
#    PATH. Re-adding the old line would either start nothing (name gone) or
#    start the CLI. So the entry was silently lost, not broken.
#
#  * It runs on EVERY config parse, not once. custom/execs.lua deliberately
#    starts its autostarts outside the "hyprland.start" hook (Hyprland's Lua
#    port keeps ONE handler per event; the first registration wins, so a
#    second one is dropped without a word). That means this script must be
#    idempotent or a `hyprctl reload` would stack a second Freebuff. It
#    exits immediately when an instance is already alive, and the launcher
#    it calls is single-instance too -- belt and braces.
#
# WHY IT WAITS INSTEAD OF LAUNCHING INSTANTLY
# -------------------------------------------
# At first login the machine is still settling: the shell is starting, the
# GPU is coming up, fonts are cold. The Freebuff launcher's own header
# records that Freebuff's GPU process SIGABRTs on this box under exactly
# that pressure (NVIDIA/intel Wayland, iGPU buffer ENOMEM) -- which is why
# it forces --disable-gpu. Launching into that storm is what made a click
# need "five attempts to appear". So: wait for a real Wayland socket, wait
# for the session to be on a sane workspace, let the load drop, then go.
# Everything is bounded by a deadline; a slow boot delays Freebuff, it
# never prevents it.
#
# WHY IT WAITS FOR A SANE WORKSPACE
# --------------------------------
# The lock screen parks the session on a sentinel workspace (2147483647 - N,
# see modules/ii/lock/Lock.qml). A window created there is invisible from
# every desktop the bar can show -- the "my window jumped to a desktop that
# does not exist" failure. If the session is still parked, wait.
#
# WHY IT SKIPS WHILE LOCKED
# -------------------------
# Booting straight into a locked session should not splash the app across
# the lock surface. The sentinel-workspace check above already covers the
# lock screen; the explicit check is belt and braces for a lock that has
# not yet moved the workspace.
#
#   freebuff-autostart.sh              launch if not running
#
# NOT AN AUTOSTART ANY MORE. It used to be launched from custom/execs.lua
# at every config parse; that entry was removed on 2026-10-04 because the
# app crash-prone GPU process is not worth having on every login. This
# script is now purely a manual tool, and is the one to reach for when
# the session is already warm and a bare launcher is not enough.
#   freebuff-autostart.sh --now        skip all waiting, launch immediately
#   freebuff-autostart.sh --status     report, change nothing
set -uo pipefail

LOG=/tmp/freebuff-autostart.log
LAUNCHER="$HOME/.local/bin/freebuff-desktop"
# The process pattern, matched with pgrep -f against the full command line.
#
# A literal dash, NOT `%-`. pgrep uses POSIX ERE, where `%-` is the two
# literal characters `%` and `-` -- the backslash-percent escaping belongs to
# Lua patterns, not ERE. Written as `%-` the pattern requires a `%` in the
# command line, so it matches NOTHING and this whole script would have read
# "not running" on every single check, including the ones that are supposed
# to notice a successful launch.
#
# The `@codebuff` prefix is load-bearing too: a bare `freebuff-desktop`
# would match THIS LAUNCHER's own command line, so pgrep would always report
# "already running" and Freebuff would never launch at all.
CLASS_PAT='@codebufffreebuff-desktop'

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

running() { pgrep -f "$CLASS_PAT" >/dev/null 2>&1; }

# Is the session on a workspace a normal user can see? 1..100 mirrors the
# sane-id rule in services/HyprlandData.qml and custom/scripts/workspace-sanity.sh.
on_sane_workspace() {
    local id
    id=$(hyprctl activeworkspace -j 2>/dev/null \
         | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id", 0))
except Exception: print(0)' 2>/dev/null) || id=0
    [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= 100 ))
}

if [[ "${1:-}" == "--status" ]]; then
    if running; then echo "freebuff: running"; else echo "freebuff: not running"; fi
    on_sane_workspace && echo "workspace: sane" || echo "workspace: not sane"
    echo "log: $LOG"
    exit 0
fi

NOW=0
[[ "${1:-}" == "--now" ]] && NOW=1

# Even `--now` needs a display to launch into. The inherited environment is
# not dependable here (see below), so fall back to the probe, but do not wait
# for it: `--now` means the caller already knows a session is up.
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    if PROBED="$("$HOME/.local/bin/session-env" 2>/dev/null)"; then
        eval "export $PROBED"
    fi
fi

if running; then
    log "already running, nothing to do"
    exit 0
fi

if [[ ! -x "$LAUNCHER" ]]; then
    log "FAIL: launcher missing or not executable: $LAUNCHER"
    exit 0
fi

if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    log "FAIL: no WAYLAND_DISPLAY and no live compositor to probe"
    exit 0
fi

if (( NOW == 0 )); then
    # 1. A real Wayland socket.
    #
    # The environment Hyprland hands to its autostart children is NOT a
    # reliable source for WAYLAND_DISPLAY. Measured at the 09:54 boot on
    # 2026-10-04: this script ran, waited its full 30 s and logged
    #
    #     FAIL: no WAYLAND_DISPLAY after 30s, giving up
    #
    # while the compositor was up and `wayland-1` was sitting there
    # connectable the whole time. The old test was
    #
    #     [[ -n "${WAYLAND_DISPLAY:-}" && -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]
    #
    # so a single unset variable condemned the whole session, and the socket
    # check never even ran. Freebuff then simply never started at login.
    #
    # session-env is used instead, for the same reason shell.sh and the
    # watchdog use it: it PROBES the compositor rather than trusting an
    # inherited value, so it cannot be wrong in either direction -- it
    # reports the display that is genuinely accepting connections, and it
    # fails (exit 1) when there is not one yet, which is exactly the
    # condition being waited for here.
    deadline=$((SECONDS + 30))
    SESSION_ENV=""
    while (( SECONDS < deadline )); do
        if SESSION_ENV="$("$HOME/.local/bin/session-env" 2>/dev/null)"; then
            break
        fi
        SESSION_ENV=""
        sleep 0.5
    done
    if [[ -z "$SESSION_ENV" ]]; then
        log "FAIL: no live compositor after 30s, giving up"
        exit 0
    fi
    eval "export $SESSION_ENV"
    log "using WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset} HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-unset}"

    # 2. A workspace the user can actually see (see header).
    deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        on_sane_workspace && break
        sleep 1
    done
    on_sane_workspace || log "WARN: still on a non-sane workspace after 60s, launching anyway"

    # 3. Let the login storm pass. Short on purpose: long enough to dodge the
    #    early-boot pressure that makes the GPU process abort, short enough
    #    that Freebuff is up before the user has finished unlocking.
    sleep 6
fi

# Detached, with its own log: the launcher execs an AppImage, which mounts
# into /tmp and can outlive this script. Without the redirect its Electron
# stderr would land in Hyprland's log and bury real errors.

# 4. Did it survive? The launcher's header documents SIGABRTs on this
#    machine; a retry loop turns "five attempts to appear" into one
#    unattended boot. Bounded, with a gap, and it stops the moment an
#    instance is alive so it can never double-launch.
#
# The check comes FIRST in each pass, so every launch gets one full grace
# period before it is judged. Doing it the other way round -- sleep, relaunch,
# then a final instantaneous `running` test -- left the last attempt with no
# time to start at all: the loop would fire a fourth process and then
# immediately declare failure on a process that had not had a chance to
# appear, which is a false FAIL and a stray extra instance besides.
ATTEMPTS=3
GRACE=8
for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    log "launching $LAUNCHER (attempt ${attempt}/${ATTEMPTS})"
    setsid "$LAUNCHER" >>/tmp/freebuff-autostart.out 2>&1 </dev/null &
    sleep "$GRACE"
    if running; then
        log "up on attempt ${attempt}/${ATTEMPTS}"
        exit 0
    fi
    log "WARN: not running after attempt ${attempt}/${ATTEMPTS}"
done

log "FAIL: Freebuff did not come up after ${ATTEMPTS} attempts; see /tmp/freebuff-autostart.out"
exit 0
