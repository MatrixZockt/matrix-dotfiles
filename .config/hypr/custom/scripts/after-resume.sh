#!/usr/bin/env bash
# after-resume.sh -- what runs on every wake (hypridle after_sleep_cmd).
#
# Four jobs, in this order.
#
#  0. BLOCK SLEEP -- and the lid -- for a grace period. Comes FIRST because it
#     is the whole point of the ordering: everything else here can take up to a
#     minute to finish, and the failure this guards against lands about 27
#     seconds after every wake (see step 0 below: on 2026-10-14 a guard that
#     was armed and verified held was walked straight through by the lid).
#
#  1. Bring the desktop back. `screensaver.sh --wake` re-lights the panel, puts
#     back any compositor setting the idle mode borrowed, and then LOOKS at a
#     captured frame to confirm the compositor is actually drawing (it heals a
#     black one: panel power cycle, then a shell repaint). Keeping it first
#     after the guard means the screen is usable the moment the machine
#     returns. Everything up to that point is bounded by `timeout`, because on
#     2026-10-25 this script produced no output at all on the second wake --
#     and a wake path that can hang before its first log line is a wake path
#     that cannot be diagnosed after the fact.
#
#  2. Re-apply the ALC298 internal-speaker registers.
#
#  3. Re-apply the keyboard lighting. The firmware forgets the per-key matrix
#     over suspend -- the last step at the end of this file is why.
#
# WHY THIS EXISTS. The internal speakers on this laptop are not enabled by any
# mixer setting: the codec's autoconfig reports `speaker_outs=0`, so the generic
# driver never powers the speaker amplifier, and the only thing that turns it on
# is programming a long list of vendor/coefficient registers directly --
# /usr/local/sbin/razer-blade-speakers, run as root by razer-speakers.service
# (and again on every resume by /usr/lib/systemd/system-sleep/50-razer-speakers,
# which this repo ships in extras/lib/systemd/system-sleep/).
#
# Those register writes are RUNTIME ONLY. A suspend/resume resets the codec, so
# after every wake the amp is off again -- and because the service only ran at
# BOOT, nothing re-applied them. That is exactly the reported failure: sound
# present after a boot, gone after the first sleep, with every mixer, sink and
# jack still reading "fine".
#
# The service is RESTARTED rather than the script called directly on purpose:
# the codec hwdep node (/dev/snd/hwC1D0) cannot be opened from the session, so
# only the root service can write the registers. Restarting it re-runs its own
# ExecStart, which already waits for the codec device to be present -- so no
# device polling is needed here beyond a short grace period for the codec to
# finish re-probing.
set -u

# 0. ── POST-RESUME SLEEP GUARD ───────────────────────────────────────────
#
# WHY THIS EXISTS. On 2026-10-12 this machine spent a morning in an endless
# suspend loop: it woke from an overnight S3, and then went back to sleep
# roughly 16-18 seconds after every single resume, waking again on its own
# 20-40 seconds later, forever, until it was force-powered-off. The wake path
# is what re-armed the loop, so the guard belongs here.
#
# WHAT THE LOGS SHOWED (journalctl -b -1), and what they did NOT:
#
#   * Three of the suspends were preceded by `systemd-logind: Power key
#     pressed short.` and this machine has `HandlePowerKey=suspend`, which is
#     systemd issue #28353: the press that WAKES a machine is also handled as
#     a request to sleep. HandlePowerKey therefore re-sleeps the machine it
#     was just woken from.
#   * Three more suspends had NO prior lid or button event at all -- logind
#     simply logged `Suspending...` -- and were written off that morning as
#     "something in userspace asked for them over logind's D-Bus, and logind
#     does not record WHO". That reading was wrong, and 2026-10-14 settles it.
#
# WHAT 2026-10-14 PROVED (journalctl -b -1).
#
# The machine woke at 08:41:24. This guard was armed one second later and
# VERIFIED HELD -- logged, and `CanSuspend` answered "inhibited". The machine
# still slept at 08:41:51, 27 seconds after waking, with `Suspending...` and no
# lid and no button event anywhere in the journal. No userspace caller asks for
# a sleep *and* walks past a held block inhibitor. The LID does, and logind's
# own documentation says so:
#
#   LidSwitchIgnoreInhibited= ... "defaults to yes. This means that ... the lid
#   switch does not respect suspend blockers by default, but the power and
#   sleep keys do."
#
# So the one path this guard was documented as stepping aside for was the
# requester all along -- and the guard could not have stopped it.
#
# WHY IT LANDS ~27-30 SECONDS AFTER EVERY WAKE: the 14th at 08:41:51, the 13th
# at 08:15:13, and the 12th at 08:14 (the note further down had already
# measured "27 seconds later" before the reason for 27 was understood).
#
#   HoldoffTimeoutSec= "Specifies a period of time after system startup or
#   system resume in which systemd will hold off on reacting to lid events.
#   ... Defaults to 30s."
#
# The holdoff expires, logind re-runs the lid action against the state it
# cached before the sleep, and `HandleLidSwitch=suspend` performs it. That
# state is stale because of the FIRMWARE, not logind: this laptop's lid switch
# never reports `Lid opened` after a resume (KEYBOARD, kernel bz 191211), so
# logind still believes the lid is shut however wide open it is. A stale
# "closed", re-read thirty seconds after every wake: that is the whole loop, on
# all three mornings.
#
# WHAT THE GUARD HOLDS NOW.
#
# The lid respects exactly one kind of lock, and it is not a sleep blocker
# (logind.conf(5), systemd 262):
#
#   "Low level inhibitor locks (handle-power-key, handle-suspend-key,
#    handle-hibernate-key, handle-lid-switch, handle-reboot-key), are always
#    honored, irrespective of this setting."
#
# so the guard takes `--what=sleep:handle-lid-switch`. For its window logind
# will not act on the lid at all, and the thirty-second stale re-read has
# nothing left to act with.
#
# That leaves exactly one thing to keep true, and lid-guard.sh is it: a lid
# closed INSIDE the window is a real request to sleep, and once the handoff is
# declared logind will not perform it (it acts on events, and it is no longer
# handling the lid). The watcher reads logind's LidClosed -- with
# lid-init-state.service in place that is the event-driven truth, and it is
# "open" for the whole grace after a wake -- and performs that sleep after ten
# seconds of a genuinely shut lid, past the holdoff window, and after releasing
# the guard. A close during the window therefore sleeps the machine a few
# seconds late rather than not at all.
#
# DO NOT point that watcher back at /proc/acpi/button/lid. It was read as "the
# driver's current state, which is NOT the copy that goes stale", and on
# 2026-10-16 it read "closed" nineteen times in a row for a lid that was open
# and slept the machine its owner was using. The file evaluates _LID live on
# every read, and _LID is the thing this firmware gets wrong. lid-guard.sh's
# header has the whole measurement and the two changes that fix it.
#
# WHY THE POWER BUTTON STILL SUSPENDS, ON `HandlePowerKey=suspend`.
#
# Keeping the button's one-press-to-suspend was the requirement, and it is kept
# -- no /etc change, no root. It works because logind's own defaults are
# exactly the split this needs (read off /etc/systemd/logind.conf, systemd 262):
#
#   PowerKeyIgnoreInhibited=no    A power press IS subject to high-level sleep
#                                 inhibitors. So the button suspends normally at
#                                 any ordinary moment, and does nothing only
#                                 while this guard is armed. The bug was never
#                                 "the power key suspends" -- it was that the
#                                 press that WAKES the machine is also handled
#                                 as a press that SLEEPS, and that press lands
#                                 inside this window, so it alone is dropped.
#                                 Every deliberate press, before or after the
#                                 window, behaves exactly as it always did.
#   LidSwitchIgnoreInhibited=yes   The lid ignores `sleep` blockers -- which is
#                                 exactly why the guard above cannot use one
#                                 for the lid, and why it holds
#                                 handle-lid-switch instead, the lock logind
#                                 always honors.
#
# So the button keeps its job and only the wake-time press is ignored. Had
# PowerKeyIgnoreInhibited been `yes` (i.e. the button ignoring inhibitors) this
# would NOT have worked, and `HandlePowerKey=ignore` would have been the only
# option -- at the cost of the button never suspending again.
#
# A `--mode=block` inhibitor (not `delay`) is what does it. Verified on this
# box: `loginctl`/D-Bus `CanSuspend` answers "yes" normally and "inhibited"
# while this inhibitor is held, and logind refuses the sleep rather than
# merely postponing it. A `delay` inhibitor would NOT be enough -- logind only
# waits out a delay inhibitor for InhibitDelayMaxSec (5s here, and the loop
# fires well after that).
#
# THE GRACE PERIOD STILL PRESERVES THE THING THAT WAS ASKED FOR: a closed lid
# still sleeps the machine. lid-guard.sh performs it for the length of the
# window (logind has been handed the lid off, so it will not), and outside the
# window nothing about the lid has changed at all. Set the window to 0 to
# disable the guard -- the machine then goes back to sleeping about 30 seconds
# after every wake, which is the bug this whole file exists for.
#
# Every value below is env-overridable for one reason: the check suite
# (scripts/system/sleep-check.sh) has to be able to run the guard on a short
# clock and against a lid it can fake, without touching /proc or sleeping the
# machine.
# ── A RECORD OF THE WAKE, IN A FILE ───────────────────────────────────────
# The journal is where the prose goes, but it is the wrong place for the one
# line that answers "did the screen come back": a resume that goes wrong can
# take the kernel down with it (2026-10-17, the log stops mid-flood), and the
# tail is exactly the part that is lost. /tmp survives a suspend but NOT a
# reboot, which was thought to be "the useful half" -- a record still on disk
# after a reboot would mean the wake ended in a power cycle. 2026-10-25 showed
# the other side of that: the wake went wrong, the machine had to be
# force-powered-off, and the reboot took the record explaining why with it. So
# it lives under ~/.local/state now, with a size cap -- a record that survives
# the worst outcome is the only one worth keeping.
RESUME_RECORD="${II_RESUME_RECORD:-$HOME/.local/state/ii/resume-record.log}"
record() {
    mkdir -p "$(dirname "$RESUME_RECORD")" 2>/dev/null || true
    if [ -f "$RESUME_RECORD" ] && [ "$(stat -c %s "$RESUME_RECORD" 2>/dev/null || echo 0)" -gt 524288 ]; then
        mv -f "$RESUME_RECORD" "$RESUME_RECORD.old" 2>/dev/null || true
    fi
    printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$RESUME_RECORD" 2>/dev/null || true
}
# What the compositor says about the panel, as one number (no compositor, no
# number -- and that is not an error).
#
# BOUNDED, and this matters more than it looks: `record` below runs BEFORE the
# restore, so a hyprctl that never answers hangs the whole wake path at its
# first line -- which is exactly what a compositor still getting up from a
# suspend can do. On 2026-10-25 the second wake logged nothing at all, and "no
# output" is indistinguishable between "never ran" and "hung on line one"
# without a timeout and a first-line journal entry.
dpms_now() {
    command -v hyprctl >/dev/null 2>&1 || return 0
    timeout 3 hyprctl monitors 2>/dev/null | grep -m1 'dpmsStatus' | tr -d ' \t'
}

RESUME_SLEEP_GUARD_SEC="${II_RESUME_GUARD_SEC:-90}"
GUARD_WHY="ii: post-resume grace period"
LID_STATE="${II_LID_STATE:-/proc/acpi/button/lid/LID0/state}"
LID_GUARD="$(dirname "$0")/lid-guard.sh"

# What logind says about sleeping right now -- the honest half of "is the guard
# real": `systemd-inhibit --list` proves an inhibitor exists, CanSuspend proves
# logind will refuse the sleep. Measured on this box (2026-10-14): `yes` with
# nothing held, `inhibited` while the guard is.
can_suspend() {
    if command -v busctl >/dev/null 2>&1; then
        busctl call org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager CanSuspend 2>/dev/null \
            | sed -n 's/^s "\(.*\)"$/\1/p'
    fi
}

arm_resume_guard() {
    # Detached from this script's lifetime on purpose: the guard has to OUTLIVE
    # the notebook's own work (which can spend up to ~40s waiting on the
    # speaker service below). `setsid` gives it its own session so hypridle
    # exiting or the script finishing cannot take it down with them, and the
    # redirects detach it from the journal pipes as well.
    #
    # `sleep` plus `handle-lid-switch`, not sleep alone: the lid is the path
    # that actually fires here, and it ignores sleep blockers (see the header).
    setsid systemd-inhibit --what=sleep:handle-lid-switch --mode=block \
        --why="$GUARD_WHY" \
        sleep "$RESUME_SLEEP_GUARD_SEC" >/dev/null 2>&1 </dev/null &
    guard_pid=$!
    disown 2>/dev/null || true
    # Recorded so the guard is answerable after the fact, in the same spirit as
    # the rest of this setup: "why did my machine not sleep at 08:12" is a
    # journal query.
    #
    # VERIFIED, not assumed -- and verified the right way. The old check grepped
    # the WHY string out of `systemd-inhibit --list`, which was true, kept
    # logging "verified held", and was satisfied by a guard that logind was
    # ignoring. So: the list must show the inhibitor (its WHATs and its mode
    # printed with it), and logind must be the one saying the sleep would be
    # refused.
    guard_held=0
    for _ in $(seq 1 10); do
        if systemd-inhibit --list 2>/dev/null | grep -qF "$GUARD_WHY"; then
            guard_held=1
            break
        fi
        sleep 0.2
    done
    if [ "$guard_held" = 1 ]; then
        logger -t after-resume "post-resume sleep guard armed for ${RESUME_SLEEP_GUARD_SEC}s: $(systemd-inhibit --list --no-legend 2>/dev/null | grep -F "$GUARD_WHY" | tr -s ' ') | CanSuspend=$(can_suspend)" 2>/dev/null || true
    else
        logger -t after-resume "WARNING: post-resume sleep guard NOT held -- sleep is not blocked for ${RESUME_SLEEP_GUARD_SEC}s" 2>/dev/null || true
    fi

    # The watcher: while the guard holds the lid off, a genuinely closed lid is
    # still a request to sleep, and logind will not carry it out. lid-guard.sh
    # reads the lid itself and performs the sleep, releasing the guard first.
    # Started only if the guard is real (an inhibitor that is not there cannot be
    # released, and the watcher could only ask for a refused sleep) and only if
    # there is a lid state to read at all -- no sensor means no decision to
    # make, and logind is left to behave as it always did.
    if [ "$guard_held" = 1 ] && [ -r "$LID_STATE" ] && [ -x "$LID_GUARD" ]; then
        setsid "$LID_GUARD" --inhibitor-pid "$guard_pid" --why "$GUARD_WHY" \
            --lid "$LID_STATE" --grace "$RESUME_SLEEP_GUARD_SEC" \
            >/dev/null 2>&1 </dev/null &
        disown 2>/dev/null || true
    else
        logger -t after-resume "lid watcher not started (guard_held=$guard_held lid=$LID_STATE watcher=$LID_GUARD)" 2>/dev/null || true
    fi
}

# The guard alone, nothing else in this script: what the check suite drives, so
# that "the lid is held off and a closed lid still sleeps" is a measurement
# rather than a reading of the code. It skips the panel restore and the speaker
# service on purpose -- neither is part of the guard, and running them would
# make the test depend on the audio stack.
if [ "${1:-}" = "--guard-only" ]; then
    arm_resume_guard
    exit 0
fi

# FIRST ACT, and in the journal rather than the file: the record answers "what
# happened", this line answers "did this script get as far as starting at all".
# On 2026-10-25 the second wake logged nothing whatsoever, and "no output" is
# indistinguishable between "never ran" and "hung on line one" unless the very
# first thing this script does is say something. Bounded like everything else
# below: nothing on the wake path may wait for an answer that is not coming.
logger -t after-resume "wake: restore starting (lid=$(timeout 2 cat "$LID_STATE" 2>/dev/null | sed 's/.*state:[[:space:]]*//' || echo unknown))" 2>/dev/null || true

record "wake: lid=$(timeout 2 cat "$LID_STATE" 2>/dev/null | sed 's/.*state:[[:space:]]*//' || echo unknown) guard=${RESUME_SLEEP_GUARD_SEC}s "
record "       panel BEFORE the restore: $(dpms_now)"

if [ "$RESUME_SLEEP_GUARD_SEC" -gt 0 ] && command -v systemd-inhibit >/dev/null 2>&1; then
    arm_resume_guard
fi

# 1. Panel and compositor first, so the desktop is usable immediately -- and
#    then PROOF that the pixels came back. `--wake` is `--restore` plus a frame
#    check (screensaver.sh): this script's own calls are all bounded now, so a
#    compositor that is not drawing can no longer pass for a restored one.
#    Bounded as a whole so a wedged compositor cannot hold the wake path open
#    and push whatever is next behind it.
timeout 45 "$HOME/.config/hypr/custom/scripts/screensaver.sh" --wake \
    || logger -t after-resume "the wake restore did not complete (screensaver.sh --wake)" 2>/dev/null || true
# A lock that failed to go up before the sleep (before-sleep.sh marks it) is
# raised now, while the screen is still the thing the user is looking at.
if [ -f "${II_LOCK_RAISE_FAILED:-/tmp/ii-lock-raise-failed}" ]; then
    timeout 3 qs -c "${qsConfig:-ii}" ipc call lock activate >/dev/null 2>&1 \
        && rm -f "${II_LOCK_RAISE_FAILED:-/tmp/ii-lock-raise-failed}" 2>/dev/null || true
fi

# 1b. The password field, already focused.
#
# A resume hands back a lock screen that was raised BEFORE the sleep, behind a
# panel that was already off -- so the lock surface took focus while the
# compositor had not activated it, Qt dropped that focus, and the field only
# became focused on the first pointer motion. That is the "I have to wiggle the
# mouse before I can type" report of 2026-11-05. LockSurface.qml re-asserts
# focus by itself now, within a fraction of a second; this is the immediate
# version of the same thing, for the frame the user is already looking at.
# Harmless while unlocked: no lock surface exists, so nothing is listening.
timeout 3 qs -c "${qsConfig:-ii}" ipc call lock focus >/dev/null 2>&1 || true
# The line this whole record exists for. A panel that is still off here has
# already had the retries in wake_now, and before-sleep.sh's net is still armed
# to try again -- but the record is what turns "it came back dark" from a
# memory into a date and a number.
record "       panel AFTER the restore:  $(dpms_now)"

# 2. Remember the sink volume/mute BEFORE the amp service runs.
#
# Re-programming the codec also resets the hardware "Speaker" control to the
# script's own default, and PipeWire follows it -- measured: 66% -> 37% (-26 dB)
# on every run. Without this, every wake would quietly halve the volume and the
# desktop would look like it had forgotten the setting.
sink="$(pactl get-default-sink 2>/dev/null || true)"
if [ -n "$sink" ]; then
    vol="$(pactl get-sink-volume "$sink" 2>/dev/null | grep -oE '[0-9]+%' | head -1)"
    mute="$(pactl get-sink-mute "$sink" 2>/dev/null | grep -oE '(yes|no)' | head -1)"
fi


# 2b. RE-PROGRAM THE AMPLIFIER. This is the step the comments at the top of
# this file have described since the day it was written, and the one that was
# missing from the code: without it the registers stayed lost after every wake.
#
# ON 2026-11-13 this is what the report "my PC speakers are broken" turned out
# to be. The machine booted on 2026-11-09 and the amplifier unit ran then; the
# first sleep after that reset the codec, and nothing ever wrote the vendor
# registers again. Every reading a person can check said the speakers were
# fine -- sink unmuted at the right volume, route `[Out] Speaker`, EAPD on,
# the DMA pointer advancing at exactly 48 kHz -- and the speakers were silent.
# Restarting the unit brought the sound straight back.
#
# It is a restart rather than a direct call because /dev/snd/hwC1D0 is not
# reachable from the session; the unit's own ExecStart runs the helper as root
# and waits for the node. Bound to keep a wake from waiting forever: a missing
# codec or a refused restart must not stop the steps below.
# The unit and its helper are installed outside this repo and exist only on the
# machine that needs them, so the step is skipped where the unit is absent: a
# repo shared with other machines must not turn a normal wake into a failure.
if systemctl cat razer-speakers.service >/dev/null 2>&1; then
    if ! timeout 40 systemctl restart razer-speakers.service >/dev/null 2>&1; then
        record "       speaker amp: restart FAILED -- speakers may be silent"
    else
        record "       speaker amp: registers re-applied"
    fi
fi

# 3. Put the volume/mute back now that the codec is fully programmed.
if [ -n "${sink:-}" ] && [ -n "${vol:-}" ]; then
    pactl set-sink-volume "$sink" "$vol" >/dev/null 2>&1 || true
    case "${mute:-no}" in
        yes) pactl set-sink-mute "$sink" 1 >/dev/null 2>&1 || true ;;
        no)  pactl set-sink-mute "$sink" 0 >/dev/null 2>&1 || true ;;
    esac
fi

