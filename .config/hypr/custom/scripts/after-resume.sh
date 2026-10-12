#!/usr/bin/env bash
# after-resume.sh -- what runs on every wake (hypridle after_sleep_cmd).
#
# Three jobs, in this order.
#
#  0. BLOCK SLEEP for a grace period. Comes FIRST because it is the whole
#     point of the ordering: everything else here can take up to a minute to
#     finish, and the failure this guards against lands inside the first
#     twenty seconds (see step 0 below).
#
#  1. Bring the desktop back. `screensaver.sh --restore` re-lights the panel and
#     puts back any compositor setting the idle mode borrowed. This is the
#     original after_sleep_cmd, unchanged -- keeping it first means the screen
#     is usable the moment the machine returns.
#
#  2. Re-apply the ALC298 internal-speaker registers.
#
# WHY THIS EXISTS. The internal speakers on this Blade are not enabled by any
# mixer setting: the codec's autoconfig reports `speaker_outs=0`, so the generic
# driver never powers the speaker amplifier, and the only thing that turns it on
# is programming a long list of vendor/coefficient registers directly --
# /usr/local/sbin/razer-blade-speakers, run as root by razer-speakers.service.
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
#     simply logged `Suspending...` -- so something in userspace asked for
#     them over logind's D-Bus. logind does not record WHO called it, and the
#     shell's own log for that boot is gone, so the exact caller could not be
#     identified after the fact. Nothing in this config can do it on its own:
#     the only automatic sleep paths here (screensaver.sh's long-idle tier and
#     the shell's battery threshold) were both verifiably OFF/irrelevant
#     (longIdleSuspend=false, battery at 80%).
#   * The lid switch never reported `Lid opened` after the resume, which is a
#     known Razer Blade firmware bug (kernel bz 191211).
#
# So the loop is "something asks for sleep within seconds of every wake", and
# the requester could not be pinned down after the fact. This guard does not
# need to know which of them it is: it makes the machine REFUSE to sleep at
# all for a short window after it wakes, so the loop cannot close, whichever
# of the above is behind it.
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
#   LidSwitchIgnoreInhibited=yes   Closing the lid still sleeps immediately,
#                                 even mid-grace. The one path that was already
#                                 correct is left completely untouched.
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
# THE GRACE PERIOD PRESERVES THE THING THAT WAS ASKED FOR: closing the lid
# still sleeps, immediately and always. logind's own default is
# `LidSwitchIgnoreInhibited=yes`, so a lid close ignores inhibitors by design.
# Only the software/power-key routes that caused the loop are held off, which
# is exactly the set the loop belonged to. Set the window to 0 to disable the
# guard.
RESUME_SLEEP_GUARD_SEC=90
if [ "$RESUME_SLEEP_GUARD_SEC" -gt 0 ] && command -v systemd-inhibit >/dev/null 2>&1; then
    # Detached from this script's lifetime on purpose: the guard has to OUTLIVE
    # the notebook's own work (which can spend up to ~40s waiting on the
    # speaker service below). `setsid` gives it its own session so hypridle
    # exiting or the script finishing cannot take it down with them, and the
    # redirects detach it from the journal pipes as well.
    setsid systemd-inhibit --what=sleep --mode=block \
        --why="ii: post-resume grace period" \
        sleep "$RESUME_SLEEP_GUARD_SEC" >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
    # Recorded so the guard is answerable after the fact, in the same spirit as
    # the rest of this setup: "why did my machine not sleep at 08:12" is a
    # journal query.
    logger -t after-resume "post-resume sleep guard armed for ${RESUME_SLEEP_GUARD_SEC}s" 2>/dev/null || true
fi

# 1. Panel and compositor first, so the desktop is usable immediately.
"$HOME/.config/hypr/custom/scripts/screensaver.sh" --restore

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

# 3. Then the speaker amp. A brief pause so the codec has settled after resume;
#    the service's own ExecStartPre covers the rest.
sleep 2
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart razer-speakers.service >/dev/null 2>&1 || true
    # WAIT for the unit to finish, and this is load-bearing rather than
    # defensive: it is a oneshot with RemainAfterExit AND an ExecStartPost that
    # re-runs the register writes ~5s later, and its ExecStart resets the
    # hardware "Speaker" control. Restoring the volume before that lands just
    # lets the reset win -- measured: the sink snapped back to 24% when the
    # restore ran early. "active" here means the whole chain (Pre, Start, Post)
    # is done. Bounded so a wedged unit cannot hold the resume path open.
    for _ in $(seq 1 40); do
        [ "$(systemctl is-active razer-speakers.service 2>/dev/null)" = active ] && break
        sleep 1
    done
fi

# 4. Put the volume/mute back now that the codec is fully programmed.
if [ -n "${sink:-}" ] && [ -n "${vol:-}" ]; then
    pactl set-sink-volume "$sink" "$vol" >/dev/null 2>&1 || true
    case "${mute:-no}" in
        yes) pactl set-sink-mute "$sink" 1 >/dev/null 2>&1 || true ;;
        no)  pactl set-sink-mute "$sink" 0 >/dev/null 2>&1 || true ;;
    esac
fi
