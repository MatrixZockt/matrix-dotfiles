#!/usr/bin/env bash
# Run by hypridle as before_sleep_cmd. Three things, in this order: say what is
# happening, take the panel down, raise the lock. The sleeping itself is already
# decided by the time this runs.
#
# WHY THE LABEL COMES FIRST, AND WHY THERE IS A WAIT AT ALL.
#
# A laptop that goes black says nothing about whether it is asleep or dead. For
# two seconds before the screen leaves, the shell puts a wash and a single line
# on it -- "Going to sleep" (see modules/ii/onScreenDisplay/SleepNotice.qml).
# That wait is inside logind's inhibitor window (see the next paragraph), so it
# does NOT delay the sleep: the machine still leaves at the same instant, the
# label just makes use of a window that was empty before.
#
# WHY THE PANEL GOES OFF FIRST.
#
# This hook does not run at the instant the machine sleeps. logind still has to
# wait out hypridle's delay inhibitor, and that is a five-second window; logind
# says so itself:
#
#     systemd-logind: Delay lock is active (UID 1000/matrix, PID .../hypridle)
#                     but inhibitor timeout is reached.
#
# Raising the lock inside that window, and nothing else, paints the login screen
# on a LIT panel for those five seconds -- long enough to read the clock and
# type a password into a machine that is about to leave. That is the whole
# reason for the order here: on a lid close or a power-button tap the screen
# goes dark first, the lock is raised behind it, and the login screen is only
# ever met on the way back.
#
# An output that is off also stays off until something asks for it (see
# wake_now in screensaver.sh), so a keypress in that window cannot reveal the
# lock either. The way back is already covered: hypridle's after_sleep_cmd runs
# `screensaver.sh --restore`, whose first act is panel_on.
#
# AND WHY THERE IS A NET UNDER THAT (the panel net, --panel-back-on).
#
# "The way back is covered" is only true if the sleep happens. It is NOT true
# for a sleep that is refused, or that starts and aborts: hypridle's
# after_sleep_cmd is the wake path, and a sleep that never came back cleanly
# never reaches it. What the user is left with is the one failure this file
# must not produce -- a machine that is AWAKE, running, locked, and showing a
# black panel. That is indistinguishable from a dead laptop, and on 2026-10-14
# it is exactly what happened: a sleep was requested 27 seconds after the wake
# (the lid, see after-resume.sh), its task-freeze stalled 20 seconds on a
# process stuck in a FUSE lookup and aborted, the machine fell straight into an
# s2idle sleep nobody asked for, and the panel was still off. Opening the lid
# showed nothing; the machine had to be force-powered-off.
#
# So the panel is never left to the sleep machinery alone. The moment it goes
# off, this script arms a detached net that brings the desktop back a few
# seconds later *if nothing else has*: the sleep succeeds -> the net waits for
# systemd-sleep to be gone (its own clocks stop advancing during S3 anyway) and
# acts only if the normal wake path never did -- or the sleep fails or is
# refused -> there is no systemd-sleep to wait for, so it fires while the
# machine is awake and puts everything back, then says so in the journal.
#
# WHY IT WAITS, AND WHAT HAPPENED WHEN IT DID NOT (2026-10-25). The old net
# fired on a bare timer, on the reasoning that S3 would freeze its clock until
# the resume. Measured that morning: armed at 08:41:55, the suspend only reached
# its freeze at 08:42:10, so the net fired at 08:42:03 -- DURING the suspend --
# consumed its marker and turned the panel on for a machine on its way to sleep.
# By the time the machine woke, the net was spent and after-resume.sh produced
# no output at all, so nothing restored anything: the owner opened the lid onto
# a black screen with a lone white cursor, typed a password into it that reached
# PAM, and had to force the machine off. The net is now the full wake path
# (screensaver.sh --wake) and it waits for the sleep to really be over before
# spending itself.
#
# The marker (/tmp/ii-panel-off-net) is what makes those two cases
# distinguishable, and it is the contract with screensaver.sh: written here
# before the panel goes off, removed by wake_now only when its own panel_on
# succeeded. A marker the net still finds means the sleep path did not bring
# the panel back. `II_PANEL_NET_DELAY` (seconds, default 8) exists so the check
# suite can exercise all of this in a couple of seconds.

# WHY wlopm AND NOT hyprctl.
#
# This Hyprland is the Lua-era build: it evals dispatch arguments as Lua, so
# every classic spelling of `dpms off` -- plain, comma, quoted -- is a parse
# error rather than a silent no-op (screensaver.sh documents the same finding).
# wlopm speaks the Wayland output-power protocol directly and works on any
# wlroots-descendant compositor. The dispatch spellings below are the fallback
# for a session with no wlopm.

set -u

# The marker the panel net fires on, and the same path screensaver.sh's wake_now
# clears (see the header: that is the whole contract between them).
PANEL_NET="${II_PANEL_NET:-/tmp/ii-panel-off-net}"

panel_off() {
    if command -v wlopm >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        wlopm --off '*' >/dev/null 2>&1 && return 0
    fi
    # No wlopm, or no WAYLAND_DISPLAY in our environment: try both dispatch
    # spellings and let whichever lands win. Failing all of that is not fatal --
    # the lock below is the part that must not be skipped.
    hyprctl dispatch 'hl.dsp.dpms("off")' >/dev/null 2>&1 \
        || hyprctl dispatch dpms off >/dev/null 2>&1 || true
}

panel_on() {
    if command -v wlopm >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        wlopm --on '*' >/dev/null 2>&1 && return 0
    fi
    hyprctl dispatch 'hl.dsp.dpms("on")' >/dev/null 2>&1 \
        || hyprctl dispatch dpms on >/dev/null 2>&1
}

lock_now() {
    # The shell's own lock: the same one SUPER+L and the session menu raise (the
    # IpcHandler in modules/common/panels/lock/LockScreen.qml). It is a flag on
    # an overlay that already exists, not a process, so raising it here costs
    # nothing and cannot be disturbed by the sleep.
    #
    # qsConfig is how custom/keybinds.lua names the shell's config, so this
    # follows that convention instead of hardcoding "ii".
    #
    # BOUNDED, and a failure is MARKED rather than swallowed. This hook runs
    # while the compositor is on its way down: a shell that is busy or wedged at
    # this exact moment makes `qs ipc call` wait for an answer that is not
    # coming, and a hang here would silently skip the one thing this file exists
    # to leave behind. On 2026-10-25 the machine came back to no lock screen at
    # all -- so a raise that does not land writes a marker, and the wake path
    # (screensaver.sh --wake, before-sleep.sh's net, after-resume.sh) raises it
    # again on the way back.
    if timeout 3 qs -c "${qsConfig:-ii}" ipc call lock activate >/dev/null 2>&1; then
        rm -f "${II_LOCK_RAISE_FAILED:-/tmp/ii-lock-raise-failed}" 2>/dev/null || true
        return 0
    fi
    : > "${II_LOCK_RAISE_FAILED:-/tmp/ii-lock-raise-failed}" 2>/dev/null || true
    logger -t before-sleep "the lock raise did not answer -- it will be retried on wake" 2>/dev/null || true
    return 0
}

# The other half of that marker: called from every wake path, so a lock that
# failed to go up before the sleep is up before anyone looks at the screen.
repair_lock() {
    local marker="${II_LOCK_RAISE_FAILED:-/tmp/ii-lock-raise-failed}"
    [ -f "$marker" ] || return 0
    if timeout 3 qs -c "${qsConfig:-ii}" ipc call lock activate >/dev/null 2>&1; then
        rm -f "$marker" 2>/dev/null || true
        logger -t before-sleep "lock raised on wake (the pre-sleep raise had failed)" 2>/dev/null || true
    fi
    return 0
}

# --panel-back-on: what the net runs. Only acts while the marker says a sleep
# attempt turned the panel off and did not bring it back; then it brings the
# whole desktop back and records it. Safe to run at any time -- invoked by the
# net, or by hand when a laptop looks dead but is not.
case "${1:-}" in
--panel-back-on)
    if [ -f "$PANEL_NET" ]; then
        rm -f "$PANEL_NET" 2>/dev/null || true
        # The FULL wake sequence, not panel_on alone. This branch is the path
        # taken when after-resume.sh never got to run -- which is what happened
        # on 2026-10-25: the second wake produced no after-resume output at all,
        # so the panel, the backlight and the compositor options were left
        # exactly as the sleep had left them. A panel that is lit over a 1%
        # backlight or a veil still on is still a screen nobody can use, so the
        # net restores everything and then checks the frame (screensaver.sh
        # --wake). panel_on below is only the fallback for a restore that could
        # not even start.
        if ! timeout 45 "$(dirname "$0")/screensaver.sh" --wake >/dev/null 2>&1; then
            panel_on
            logger -t before-sleep "the wake restore did not run -- panel on alone" 2>/dev/null || true
        fi
        repair_lock
        logger -t before-sleep "panel back on: a sleep attempt left the panel off and never brought it back" 2>/dev/null || true
    fi
    exit 0
    ;;
esac

# The order is the point of this file, so give it a moment to be true. The
# compositor applies the output-power request on its next commit, and the lock
# is a surface of its own: without this, both can land in the same frame, which
# is exactly the single lit frame the ordering exists to avoid. Safe to wait,
# because this hook runs inside logind's five-second inhibitor window, not
# against a deadline.
# 1. The label. It holds longer than this wait on purpose: the timer behind it
#    is the safety net for a hook that dies, not the schedule.
# Every qs call below is bounded. A shell that does not answer is the one thing
# this hook cannot tolerate: an unbounded IPC call here would stall before the
# panel goes down and before the lock goes up, and logind only waits five
# seconds anyway -- the sleep would happen with nothing left behind it.
timeout 3 qs -c "${qsConfig:-ii}" ipc call sleepNotice announce >/dev/null 2>&1 || true
sleep 2

# 2. Then the panel, and 3. the lock behind it. Cleared while the panel is
#    already dark, so the label is never seen leaving -- and nothing about it
#    has to be remembered across the suspend.
panel_off

# 2b. Arm the net that undoes a sleep which never completes (see the header).
#     After panel_off, never before: the marker must not exist while the panel
#     is still lit, or the net would fire on a sleep attempt that had not yet
#     darkened anything. Detached with setsid so it outlives this hook and the
#     sleep.
#     WAITING FOR THE SLEEP TO FINISH is the half that was wrong. The old note
#     claimed "the sleep's own S3/s2idle freeze is what makes it fire on the way
#     back rather than during" -- measured on 2026-10-25, it is not: arming at
#     08:41:55, the freeze only started at 08:42:10, so the net fired at
#     08:42:03 DURING the suspend, consumed its marker, and by the time the
#     machine came back there was nothing left covering the wake. So the net now
#     polls for systemd-sleep: while a sleep is under way it waits (its `sleep`s
#     simply stop advancing during S3 and resume on the way back), and only once
#     that process has gone -- a sleep that finished, or one that aborted -- does
#     it act. A sleep that never started at all (refused, dropped) is acted on
#     immediately, which is the case the net was originally written for.
: > "$PANEL_NET" 2>/dev/null || true
setsid bash -c '
    sleep "${0:-8}"
    marker="$1"
    script="$2"
    [ -f "$marker" ] || exit 0
    if pgrep -f "systemd[-]sleep" >/dev/null 2>&1; then
        for _ in $(seq 1 600); do
            pgrep -f "systemd[-]sleep" >/dev/null 2>&1 || break
            sleep 1
        done
        # Give the compositor a moment after the resume to be ready for us.
        sleep 1
    fi
    [ -f "$marker" ] || exit 0
    exec "$script" --panel-back-on
' "${II_PANEL_NET_DELAY:-8}" "$PANEL_NET" "$0" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

sleep 0.2
timeout 3 qs -c "${qsConfig:-ii}" ipc call sleepNotice clear >/dev/null 2>&1 || true
lock_now
