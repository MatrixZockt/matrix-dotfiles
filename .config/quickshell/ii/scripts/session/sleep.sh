#!/usr/bin/env bash
# Sleep: the screen goes off and the machine goes to sleep with EVERY app,
# every window and every setting exactly where you left it.
#
# This is NOT a logout. Nothing is closed, no process is killed, no session is
# torn down -- Log out (and Restart/Power off, which end the session anyway)
# are the things that do that. Wake the machine and your windows are still open,
# with the same scroll position, the same half-typed document, the same
# terminal working directory.
#
# "Hibernate if the machine can, suspend otherwise" -- both give the user that
# same promise, so the fallback is not a downgrade of intent, it is the same
# promise delivered by a different mechanism. Hibernate is strictly better when
# it exists (the machine uses no power at all, and it survives the battery
# being flat), which is why it is tried first.
#
# The capability is asked of systemd-logind rather than guessed. Asking is what
# makes this correct on every machine: `CanHibernate` is "na" whenever there is
# no on-disk swap to write the image to, or no `resume=` on the kernel command
# line to find it again -- and on a machine that only has zram, hibernate is
# reported as unavailable precisely because the image would not survive.
#
# Usage:
#   sleep.sh          do the sleep
#   sleep.sh --mode   print the mode that would be used, and nothing else
#                     ("hibernate" or "suspend"); no side effects

set -uo pipefail

# systemd-logind knows this machine's real capabilities; we do not guess.
can_hibernate() {
    busctl --quiet call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager CanHibernate 2>/dev/null |
        grep -q '"yes"'
}

# The panel is blanked with Hyprland's DPMS dispatcher. On this Lua-based
# Hyprland the dispatcher is an expression, so it has to be dispatched as one --
# `hyprctl dispatch dpms off` is a parse error here, not a silent no-op. This is
# the same call keybinds.lua makes when the lid closes, which is verified to
# blank eDP-1 completely rather than dim it.
dpms_off() { hyprctl dispatch 'hl.dsp.dpms("off")' >/dev/null 2>&1 || true; }
dpms_on() { hyprctl dispatch 'hl.dsp.dpms("on")' >/dev/null 2>&1 || true; }

if [[ "${1:-}" == "--mode" ]]; then
    if can_hibernate; then
        echo "hibernate"
    else
        echo "suspend"
    fi
    exit 0
fi

# The screen goes off FIRST, while the machine is still awake and can still
# honour it. Suspending blanks the panel by itself, but doing it here means the
# screen is already dark even if the sleep is refused further down -- and, more
# to the point, it means a refused sleep cannot leave someone staring at a
# frozen desktop wondering whether it worked.
dpms_off
sleep 0.4

slept=1

if can_hibernate; then
    # Blocks until the machine wakes, then returns 0.
    systemctl hibernate || slept=0
fi

if [[ $slept -eq 1 ]]; then
    # Either hibernate was never on the table, or it was and it failed --
    # which it can still do at the last moment, if the image turns out not to
    # fit the swap pool. Suspend carries the identical promise to the user, so
    # take it rather than leaving them in front of a black screen.
    systemctl suspend || loginctl suspend 2>/dev/null || slept=0
fi

if [[ $slept -eq 0 ]]; then
    # Refused outright. Put the screen back: the machine is awake and usable,
    # and leaving the panel blanked would be the one genuinely confusing
    # outcome available here.
    dpms_on
    exit 1
fi

# Awake again. Same reasoning as the failure path: the panel is ours to restore,
# rather than relying on the lid switch or a keypress to bring it back.
dpms_on
exit 0