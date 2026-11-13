#!/usr/bin/env bash
# lid-guard.sh -- decide, from the LID ITSELF, what the post-resume grace does.
#
# WHY THIS EXISTS.
#
# after-resume.sh arms a grace period after every wake: for 90 seconds the
# machine refuses to sleep, because on this laptop the wake path is what re-arms
# a sleep loop. That script's header is where the incidents are documented.
# This file is the half of the guard that was missing until 2026-10-14.
#
# THE MISSING HALF -- 2026-10-14, and the same shape on the 13th and the 12th.
#
# The machine woke from its overnight S3 at 08:41:24. The guard was armed a
# second later and verified held (`CanSuspend` answered "inhibited"). It still
# went to sleep at 08:41:51 -- 27 seconds after waking -- with
# `systemd-logind: Suspending...` and NO lid and NO button event in the
# journal. What the user was left with was a laptop that had to be
# force-powered-off: the sleep that followed stalled 20 seconds on a task stuck
# in a FUSE lookup, aborted, fell straight into an s2idle sleep nobody asked
# for, and the panel had been left dark by before-sleep.sh. "I opened the lid
# and it did not turn on."
#
# The requester was the LID, and logind's own documentation is why a sleep
# blocker could not stop it:
#
#   logind.conf(5): "LidSwitchIgnoreInhibited= ... defaults to yes. This means
#   that ... the lid switch does not respect suspend blockers by default, but
#   the power and sleep keys do."
#
# ...and why it fired ~27 seconds after the wake, with no event to point at:
#
#   logind.conf(5): "HoldoffTimeoutSec= Specifies a period of time after system
#   startup or system resume in which systemd will hold off on reacting to lid
#   events. ... Defaults to 30s."
#
# The lid switch on this machine never reports `Lid opened` after a resume
# (KEYBOARD firmware, kernel bz 191211), so logind's cached lid state is still
# "closed" from the night before. The holdoff expires, logind re-runs the lid
# action against that stale state, and `HandleLidSwitch=suspend` sleeps the
# machine the user is looking at.
#
# WHAT THIS FILE IS FOR.
#
# The way through is the one lock the lid DOES respect -- also logind.conf(5):
#
#   "Low level inhibitor locks (handle-power-key, handle-suspend-key,
#    handle-hibernate-key, handle-lid-switch, handle-reboot-key), are always
#    honored, irrespective of this setting."
#
# so after-resume.sh now arms `--what=sleep:handle-lid-switch`, and the stale
# action is impossible for the length of the grace. That leaves one thing to
# keep true, and it is this script's whole job: a lid close that happens INSIDE
# the grace is a real request to sleep, and logind will not perform it -- with
# the handoff declared it has been told something else is handling the lid, and
# it acts on events, not on a lid it never handled. So this watcher reads the
# lid itself and performs that sleep.
#
# WHERE THE LID STATE COMES FROM, AND WHY IT CHANGED ON 2026-10-16.
#
# This script used to read /proc/acpi/button/lid, on the claim that the file is
# "the driver's own current state" and that it is logind's cached flag which
# lies. The second half is true; the first half was wrong, and the wrong half
# slept this machine on the morning of 2026-10-16. journalctl -b -1, that day:
#
#   10:19:46  resume (the lid was opened to wake it)
#   10:19:48  the post-resume guard is armed, CanSuspend=inhibited
#   10:20:24  lid-guard: "lid shut for 19 reads at 36s into the grace"
#   10:20:29  PM: suspend entry (deep) -- a machine whose owner was logged in
#
# Nineteen reads in a row, spanning that whole window. The file is NOT a cached
# copy: acpi_button_state_seq_show() calls the _LID method on every read
# (drivers/acpi/button.c), so those were nineteen live firmware answers of
# "closed" -- for a lid that was open. The firmware lies about _LID, and on
# this laptop it never sends an `open` notification after a resume to correct it
# (kernel bz 191211; the driver's own DMI quirk table carries the same
# complaint for sibling models: "notification of the LID device only happens on
# close, not on open and _LID always returns closed"). An unquirked machine
# runs lid_init_state=method, which believes that stale value -- so at resume
# the driver, the input switch, that file and logind all said "closed"
# together, and the one component that then acted on it was this script.
#
# Two changes make the value trustworthy again, and this watcher needs both.
#
#   1. lid-init-state.service (hyprland/extras/etc/systemd/system/) sets
#      button.lid_init_state=open, the switch the kernel's own quirk table
#      throws for exactly this firmware. It is what the driver needs to REPORT
#      the lid as open at resume instead of trusting _LID. Runtime-set because
#      `button` is built into this kernel.
#
#   2. This script reads logind's LidClosed property -- the same signal the lid
#      ACTION is performed against, and the only one of the two that is
#      event-driven -- instead of the raw _LID read. With (1) in place that
#      property is "open" for the whole grace after a wake (no stale value can
#      survive the resume, because the driver reports a change) and "closed"
#      the moment a genuine close is reported, which is precisely the question
#      this watcher asks. The kernel comment on that path is the guarantee it
#      rests on: "the close event is reliable".
#
# And because (2) is only safe with (1), this script now REFUSES to act when
# the kernel is not in that mode: a value a stale firmware can produce is not a
# value to put a machine to sleep on. The refusal is logged with the reason, so
# "why did my lid stop sleeping the machine" is one journal query. See
# --lid-kernel-policy below to turn the refusal off.
#
# AND WHY IT WAITS, TWICE.
#
#   --min-age 35    Never act inside the first 35 seconds. logind itself
#                   distrusts the lid for 30 after a resume (the holdoff
#                   above); refusing to believe it for a few seconds longer
#                   costs a deliberately-closed lid only those seconds, and it
#                   is the window in which a reading is most likely to be the
#                   stale one this file exists to work around.
#   --confirm 5     5 reads, 2 seconds apart: ten seconds of a lid that really
#                   is shut -- not a flap, and not one bad read that would put
#                   the machine to sleep in a bag.
#
# Then it RELEASES the guard before asking for the sleep. An inhibitor owner
# asking logind to sleep would be refused by its own inhibitor, so this waits
# for logind to stop refusing -- `CanSuspend`, logind's own answer -- before
# running the sleep command. Getting that order wrong is a silent no-op, which
# is this project's recurring failure mode.
#
# AND WHY IT ASKS LOGIND RATHER THAN READING THE INHIBITOR LIST. Two wakes close
# together arm two guards with the same `--why`, and a search of
# `systemd-inhibit --list` for that string then finds the other one and refuses
# a sleep nobody was blocking. There is also a gap between the owner process
# dying and logind dropping the inhibitor. CanSuspend answers the question that
# actually matters -- will the sleep be refused -- and it is the same signal
# after-resume.sh logs when it arms the guard.
#
# Usage (only --inhibitor-pid is required):
#   lid-guard.sh --inhibitor-pid PID [--why STRING] [--lid PATH] [--grace SEC]
#                [--confirm N] [--min-age SEC] [--suspend-cmd CMD]
#                [--lid-source auto|logind|file] [--lid-param PATH]
#                [--lid-kernel-policy open|any]
#
#   LID_GUARD_SUSPEND_CMD  env override for the command run at the end
#                          (default `systemctl suspend`). The check suite
#                          points it at a recorder, so the decision logic is
#                          verified without ever sleeping the machine.
#   II_LID_BUSCTL          where to ask logind from (default `busctl`). The
#                          check suite points it at a stub so both answers can
#                          be exercised without a lid to close.
#   II_LID_PARAM           the kernel parameter that gate reads (default
#                          /sys/module/button/parameters/lid_init_state).
#
# Exit: 0 nothing to do, or slept as asked; 1 could not act (always logged).
set -u

inhibitor_pid=""
why="ii: post-resume grace period"
lid=/proc/acpi/button/lid/LID0/state
# `auto` is what after-resume.sh gets: ask logind, fall back to the file only
# when logind cannot answer at all. `file` is for the check suite (a fake lid it
# can write to) and for a session with no logind running.
lid_source="${II_LID_SOURCE:-auto}"
lid_param="${II_LID_PARAM:-/sys/module/button/parameters/lid_init_state}"
lid_kernel_policy="${II_LID_KERNEL_POLICY:-open}"
busctl_bin="${II_LID_BUSCTL:-busctl}"
grace=90
confirm=5
min_age=35
suspend_cmd="${LID_GUARD_SUSPEND_CMD:-systemctl suspend}"

log() { logger -t lid-guard "$*" 2>/dev/null || true; }

while [ $# -gt 0 ]; do
    case "$1" in
    --inhibitor-pid) inhibitor_pid="${2:-}"; shift 2 ;;
    --why)           why="${2:-}";           shift 2 ;;
    --lid)           lid="${2:-}";           shift 2 ;;
    --lid-source)    lid_source="${2:-auto}"; shift 2 ;;
    --lid-param)     lid_param="${2:-}";     shift 2 ;;
    --lid-kernel-policy) lid_kernel_policy="${2:-open}"; shift 2 ;;
    --grace)         grace="${2:-90}";       shift 2 ;;
    --confirm)       confirm="${2:-5}";      shift 2 ;;
    --min-age)       min_age="${2:-35}";     shift 2 ;;
    --suspend-cmd)   suspend_cmd="${2:-}";   shift 2 ;;
    *) log "unknown argument '$1'"; exit 1 ;;
    esac
done

if [ -z "$inhibitor_pid" ]; then
    log "no --inhibitor-pid given: there is no guard to release, so nothing can be done"
    exit 1
fi

# logind's own answer to "is the lid shut", which is the signal the ACTION is
# taken against and the only one here that is event-driven -- see the header.
# Prints "closed"/"open", or nothing at all when logind cannot be asked (no
# busctl, no logind, no session bus), which is what lets the caller fall back
# to the file instead of guessing.
logind_lid_closed() {
    local out
    out="$("$busctl_bin" get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager LidClosed 2>/dev/null)" || return 0
    case "$out" in
    "b true") printf 'closed' ;;
    "b false") printf 'open' ;;
    esac
}

# The ACPI button device spells it `state:      open` / `state:      closed`
# with the padding, so match the word rather than the whole line. An unreadable
# file counts as NOT closed, and that is deliberate: a missing sensor must
# never be read as "the lid is shut, sleep the machine".
lid_closed() {
    local state=""
    case "$lid_source" in
    logind) state="$(logind_lid_closed)" ;;
    file)   state="" ;;
    *)      state="$(logind_lid_closed)" ;;   # auto
    esac
    if [ -n "$state" ]; then
        [ "$state" = closed ]
        return $?
    fi
    case "$(cat "$lid" 2>/dev/null || true)" in
    *closed*) return 0 ;;
    *) return 1 ;;
    esac
}

# Is the kernel reporting the lid itself, or believing _LID? Only the former
# makes the value above safe to sleep a machine on (see the header). `open` in
# brackets is how param_get_lid_init_state() marks the selected value, e.g.
# `ignore [open] method disabled`.
kernel_reports_lid_honestly() {
    [ "$lid_kernel_policy" = any ] && return 0
    [ "$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p' "$lid_param" 2>/dev/null)" = "$lid_kernel_policy" ]
}

# logind's own answer to "would a sleep be refused right now". Measured on
# this box (2026-10-14): `yes` with nothing blocking, `inhibited` while the
# guard is. A `delay` inhibitor (NetworkManager, UPower, hypridle's own) does
# NOT make it anything but `yes`, which is what makes it usable here.
can_suspend() {
    if command -v busctl >/dev/null 2>&1; then
        busctl call org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager CanSuspend 2>/dev/null \
            | sed -n 's/^s "\(.*\)"$/\1/p'
    fi
}
guard_clear() {
    case "$(can_suspend)" in
    inhibited|no|challenge) return 1 ;;
    *) return 0 ;;
    esac
}

# The deadline below, not the inhibitor's liveness, is what ends this watcher.
# `kill -0` on the pid we were handed would be shorter, but it is wrong twice
# over: `setsid` may not have handed us the process that owns the inhibitor at
# all, and a guard that was released early is no reason to stop reading the
# lid -- if the lid really is shut, the sleep is still the right answer.
# Refuse before reading anything, and say why. The failure this prevents is the
# 2026-10-16 morning: acting on a value the firmware can be lying about. A
# refusal is the safe direction -- it costs a lid closed inside the grace its
# sleep until logind takes the lid back over, whereas acting wrongly sleeps the
# machine its owner is looking at.
if ! kernel_reports_lid_honestly; then
    log "declining to act: $lid_param reports '$(cat "$lid_param" 2>/dev/null || echo unreadable)' -- the kernel is still trusting _LID, whose stale 'closed' after a resume is exactly what this watcher must not sleep a machine on (needs button.lid_init_state=open, see lid-init-state.service)"
    exit 1
fi

start=$(date +%s)
closed=0
while :; do
    age=$(( $(date +%s) - start ))
    if lid_closed; then
        closed=$(( closed + 1 ))
    else
        closed=0
    fi

    if [ "$closed" -ge "$confirm" ] && [ "$age" -ge "$min_age" ]; then
        log "lid shut for ${closed} reads at ${age}s into the grace -- releasing the guard and sleeping, which is what a closed lid asks for"
        kill "$inhibitor_pid" 2>/dev/null || true
        released=0
        for _ in $(seq 1 50); do
            if guard_clear; then
                released=1
                break
            fi
            sleep 0.1
        done
        if [ "$released" != 1 ]; then
            # Five seconds is 50x the time this has ever taken. Ask anyway rather
            # than drop a closed lid on the floor: the sleep is the thing the
            # user asked for, and a refusal will say so in the record below.
            log "logind still refuses a sleep 5s after the guard was asked to go -- asking anyway"
        fi
        if bash -c "$suspend_cmd"; then
            log "guard released; sleep performed"
            exit 0
        fi
        log "guard released, but the sleep was not performed (refused or failed): $suspend_cmd"
        exit 1
    fi

    [ "$age" -ge "$grace" ] && exit 0
    sleep 2
done
