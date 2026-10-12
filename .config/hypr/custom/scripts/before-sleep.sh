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
# WHY wlopm AND NOT hyprctl.
#
# This Hyprland is the Lua-era build: it evals dispatch arguments as Lua, so
# every classic spelling of `dpms off` -- plain, comma, quoted -- is a parse
# error rather than a silent no-op (screensaver.sh documents the same finding).
# wlopm speaks the Wayland output-power protocol directly and works on any
# wlroots-descendant compositor. The dispatch spellings below are the fallback
# for a session with no wlopm.

set -u

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

lock_now() {
    # The shell's own lock: the same one SUPER+L and the session menu raise (the
    # IpcHandler in modules/common/panels/lock/LockScreen.qml). It is a flag on
    # an overlay that already exists, not a process, so raising it here costs
    # nothing and cannot be disturbed by the sleep.
    #
    # qsConfig is how custom/keybinds.lua names the shell's config, so this
    # follows that convention instead of hardcoding "ii".
    qs -c "${qsConfig:-ii}" ipc call lock activate >/dev/null 2>&1 || true
}

# The order is the point of this file, so give it a moment to be true. The
# compositor applies the output-power request on its next commit, and the lock
# is a surface of its own: without this, both can land in the same frame, which
# is exactly the single lit frame the ordering exists to avoid. Safe to wait,
# because this hook runs inside logind's five-second inhibitor window, not
# against a deadline.
# 1. The label. It holds longer than this wait on purpose: the timer behind it
#    is the safety net for a hook that dies, not the schedule.
qs -c "${qsConfig:-ii}" ipc call sleepNotice announce >/dev/null 2>&1 || true
sleep 2

# 2. Then the panel, and 3. the lock behind it. Cleared while the panel is
#    already dark, so the label is never seen leaving -- and nothing about it
#    has to be remembered across the suspend.
panel_off
sleep 0.2
qs -c "${qsConfig:-ii}" ipc call sleepNotice clear >/dev/null 2>&1 || true
lock_now
