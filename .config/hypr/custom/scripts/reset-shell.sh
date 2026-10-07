#!/usr/bin/env bash
# ── Failsafe: reset the desktop shell ─────────────────────────────────────────
# Bound to  SUPER + CTRL + B  (see custom/keybinds.lua).
#
# What this is for
# ----------------
# Quickshell is a single process that draws the bar, both sidebars, the dock and
# every popup, and it holds the keyboard and pointer for as long as one of those
# is open. So a half-applied reload, a popup that will not close, a dock stuck
# open or input that seems swallowed all *look* like a frozen desktop even though
# your applications are running fine. Killing that one process and starting it
# again puts a clean shell back in about a second.
#
# Nothing on disk is changed by this script: no settings, no wallpaper, no window
# layout, no open applications, no clipboard history. Only the shell is restarted.
#
# hyprlock is deliberately NOT touched. If the session is locked, the lock screen
# must stay up — killing it would leave the session unlocked.

set -u

qs_config="${qsConfig:-ii}"
log_file="${XDG_RUNTIME_DIR:-/tmp}/qs-reset.log"

# The shared, CORRECT shell detection. See shell-pids.sh for why the obvious
# `pgrep -f "qs -c ii"` is wrong: it matches the FULL COMMAND LINE, so any
# process that merely MENTIONS the string -- another agent session, a grep, an
# editor, a test harness -- looks like a shell. This script and shell.sh both
# then read that decoy's WAYLAND_DISPLAY, conclude "a shell is already up", and
# exit without starting anything. That was the reported bug: pressing
# SUPER+CTRL+B with no shell did nothing, while the same key worked moments
# later when no decoy happened to be running.
. "$HOME/.config/quickshell/ii/scripts/launch/shell-pids.sh"

# ── One reset at a time (requested 2026-10-02) ──────────────────────────
#
# Taken FIRST, before anything is killed and before the "reloading" notice
# goes out, so two presses serialise here instead of both racing on.
#
# Why this script needs its own lock when shell.sh already has one: shell.sh's
# guard answers "is a shell running?", and this script's first act is to make
# that answer "no". Every liveness-keyed guard is therefore useless for the
# moments right after the kill -- which is exactly when a SECOND press lands.
#
# And a second press is not a hypothetical. This is the failsafe: it is
# pressed when the desktop looks stuck, and a press that has visibly done
# nothing for a second looks stuck too, so people press it again. The window
# is not "double-tap by accident", it is the expected response to the exact
# symptom this script is called for.
#
# `shell-watchdog.service` also polls every 5s and launches the moment
# `qs -c ii` is gone, so it can legitimately arrive inside this window too.
# shell.sh's flock arbitrates that correctly -- but the failsafe should not
# depend on a downstream arbitration being reached at all, least of all when
# the desktop is already in the state that made someone reach for it.
#
# The descriptor is NOT held across the launch, and it is NOT inheritable.
# Both matter, and the second one is not theoretical.
#
# Observed on the first run of this lock: `wl-copy`, spawned by the shell at
# 22:39, was still holding `fd 8 -> ii-shell-reset.lock` with PPID 1 long after
# the reset finished. `fuser` named it. Every later press of the failsafe then
# blocked 30s and exited with NO output at all -- which reads as "the key does
# nothing", the precise failure this script exists to prevent, and it would
# have persisted for the rest of the session because nothing ever clears it.
#
# This is the same inheritance hazard shell.sh documents at length for ITS fd
# 9, where `qs` and every child it spawns held the lock and outlived the
# shell. The lesson transfers: a lock spanning an exec/spawn boundary must not
# be inheritable, or the holder is whichever child happened to exit last.
#
# So the lock is taken inside a subshell, which re-executes the whole reset
# with the lock held and closes fd 8 across every exec inside it. The lock
# covers the reset; it never covers the shell's life.
if [ -z "${SHELL_RESET_LOCKED:-}" ]; then
    _lock="${XDG_RUNTIME_DIR:-/tmp}/ii-shell-reset.lock"
    {
        flock -w 30 8 || {
            echo "[reset] reset lock busy after 30s; not starting another reset" \
                >>"$log_file" 2>/dev/null || true
            exit 0
        }
        # `8>&-` on the inner invocation is the load-bearing part: it closes the
        # lock fd for the restarted script ONLY, so the parent keeps holding it
        # for the whole reset while nothing the reset spawns inherits it.
        #
        # Verified directly rather than assumed, because both plausible
        # alternatives are wrong here. A plain `exec 8>lock` leaks: after a
        # completed reset, fuser still named nmcli, sleep, python3 and awk as
        # holders. Relying on the compound-command redirection alone leaks too,
        # for the same reason -- the tools this script spawns are not the
        # compound command, they are its descendants.
        #
        # A leaked lock does not merely slow the next reset down: it wedges it
        # permanently. Every later press blocks for 30s and exits silently, and
        # nothing ever clears it. Measured on this machine before the fix --
        # `wl-copy` (PPID 1, spawned by the shell) held fd 8 for the rest of the
        # session and the failsafe did nothing at all.
        #
        # `timeout` IS THE BOUND ON THE HANG THAT PRODUCES IT. Closing fd 8 stops
        # the lock being INHERITED by things the reset spawns; it cannot stop the
        # reset itself from hanging, because the outer script's one job is to
        # wait for the inner one, and the inner one waits for the shell it
        # launched. That is not hypothetical -- measured: a reset started at
        # 17:45 was still alive and still holding fd 8 seven minutes later,
        # blocked in do_wait on the shell it had started, and every press in
        # that window logged "reset lock busy after 30s; not starting another
        # reset" and did nothing at all. That IS the reported "the command does
        # nothing", so the wait is now bounded rather than open-ended.
        #
        # 180s is comfortably longer than the work: the cold confirmation loop
        # below is 2 attempts x 200 x 0.25s, and the hot path's is 60 x 0.5s.
        # If the bound is ever hit, the watchdog service still restores the
        # shell within 5s, which is a far better outcome than a key that never
        # works again for the rest of the session.
        SHELL_RESET_LOCKED=1 timeout --kill-after=10 180 "$0" "$@" 8>&-
    } 8>"$_lock"
    exit $?
fi

# ── NO NOTIFICATION, AND WHY (2026-10-02) ─────────────────────────────────
#
# This file used to announce "reloading shell" here, and also carried a
# long-standing failure notification at the bottom. Both are GONE, and the
# reason is a measured property of this desktop rather than a preference.
#
# There is no notification daemon here. The shell IS the daemon: the only
# name on the session bus is
#
#   org.kde.StatusNotifierHost-<shellpid>
#
# i.e. it is owned by the very process this script kills. So a notification
# can only be displayed by a shell that is already running -- which is
# exactly the state that does not need telling, because the bar is on screen
# and the user pressed the key deliberately.
#
# Measured with the shell stopped and the watchdog masked, so nothing could
# restart it underneath the test:
#
#   $ notify-send -a Shell -u critical "test" "no shell"
#   Failed to show notification: GDBus.Error:org.freedesktop.DBus.Error
#     .ServiceUnknown: The name is not activatable     (rc=1)
#
# Zenity was tried as an independent path, since it is a separate process and
# does not go through the shell. It is not independent: it speaks the same
# D-Bus interface, and says so itself --
#
#   GLib-GIO-WARNING: unable to send notifications through
#     org.freedesktop.Notifications: ServiceUnknown
#
# No standalone daemon is installed (dunst, mako, swaync, deconiq, notify-osd
# all absent), so there is nothing on this system that could render a
# notification without the shell. Rather than keep a call that is guaranteed
# to fail in the one case that matters -- pressing the failsafe with the
# shell ALREADY closed -- the notification is removed.
#
# The silence is bounded and honest instead: the bar coming back is its own
# confirmation, and the one genuinely ambiguous case (the shell started and
# then died on a broken config) is written to the log below and to
# /tmp/ii_shell.log, which is where a bug in a config can actually be read.
#
# If a standalone daemon is ever installed, this is the place to reintroduce
# the notice -- nothing else needs to change, and the call would then work in
# precisely the case it currently cannot.

# ── Tell the watchdog to keep its hands off ──────────────────────────────
#
# shell-watchdog.sh polls every 5s and launches the shell the moment it sees
# none. The very first thing this script does is kill the shell, so without
# this flag the watchdog reliably launches one of its own *inside* this reset's
# window, and you get two shells starting at once. shell.sh's flock makes that
# safe rather than duplicated -- but "safe" here means you end up with whichever
# launcher won a race, at a moment you did not choose, which is a large part of
# why this command felt unreliable.
#
# Measured on 2026-10-03: the reset ran at 09:03:28 and /tmp/ii_shell.log gained
# two `Launching config` lines back to back (543 and 547), with the watchdog
# logging "relaunched shell" at 09:03:25 AND 09:03:40.
#
# The flag is removed by the trap below on every exit path, including failure,
# so a reset that dies cannot leave the watchdog permanently disabled. The
# watchdog additionally ignores a flag older than 120s, which covers the case
# where this process is killed hard enough to skip the trap.
reset_flag="${XDG_RUNTIME_DIR:-/tmp}/ii-shell-reset.active"
: > "$reset_flag" 2>/dev/null || true
cleanup_reset_flag() { rm -f "$reset_flag" 2>/dev/null || true; }
trap cleanup_reset_flag EXIT INT TERM

# ── Show the green "Quickshell reloaded" confirmation card ───────────────
#
# Called on the success paths below. The dark splashfb spinner (raised in step
# 0a before the kill) is dismissed first, then a green card with "Quickshell
# reloaded" is launched for a few seconds and dismisses itself.
#
# The dark spinner stays up during the reload (that is the whole point of step
# 0a -- feedback while the desktop is being torn down and rebuilt). The green
# card is the SUCCESS signal, shown only after reset-shell.sh has confirmed the
# shell is actually back (wallpaper + sidebars + bar mapped, and answering IPC).
#
# Why dismiss the dark card first: if both were left up, the user would see the
# dark "Shell reloaded" tick AND the green card at the same time, which reads as
# two different outcomes. Dismissing the dark one first makes the green card the
# single, unambiguous success signal.
show_green_reloaded() {
    # Take the dark splashfb spinner down if it is still up. It may already have
    # been dismissed by splash.sh's watcher (cold path) or self-quit (hot path),
    # so this is best-effort.
    bash "$HOME/.config/hypr/custom/scripts/dismiss-loading.sh" \
        >/dev/null 2>&1 || true
    # Launch the green card. setsid + detached so it survives this script
    # exiting.
    setsid qs -c green-reloaded >/dev/null 2>&1 </dev/null &
    echo "[reset] green Quickshell-reloaded card launched (pid $!)" \
        >>"$log_file" 2>/dev/null || true
}

# 0. THERE IS DELIBERATELY NO FAST PATH HERE.
#
# There was one. It triggered Quickshell's own hot reload (rewrite shell.qml's
# bytes with identical content) because that returns in ~2.5 s against ~10-50 s
# for a cold restart. It was removed because the hot reload does NOT bring this
# desktop back, and that is the whole point:
#
#   * the wallpaper layer (quickshell:background) does not come back
#   * neither sidebar (quickshell:sidebarLeft / sidebarRight) comes back
#   * the bar's island loses its battery and bluetooth icons, because those
#     bind to system buses and are not re-registered by a reload
#   * the middle bar and the sidebars cannot be opened
#
# All of it appears on its own 20-30 s later, by which point Quickshell's own
# "Quickshell reloaded" popup has been claiming success for most of that time.
#
# An earlier version of this tried to keep the fast path but VERIFY it, and
# escalated to a cold restart when the tree came back partial. Measured, that
# is strictly worse than never doing it: the user still sat through the whole
# broken half-shell -- blank wallpaper, no sidebars, dead bar -- for the 20-30 s
# before the restart even began, and then waited for the restart on top. It
# turned a single slow-but-correct reload into a slow reload preceded by a
# broken one.
#
# So: one clean teardown, one clean start, and the indicator stays up for all
# of it. Correct and honestly slow beats fast and visibly broken -- especially
# in a failsafe, which is pressed precisely when the desktop is already in a
# state that looks broken.
#
# If an instant, COMPLETE reload is wanted, the work is in the QML: finding why
# those services do not re-register across a reload. That is a real fix and it
# is not something that can be wrapped around from out here.

# 0a. SHOW THE INDICATOR BEFORE ANYTHING ELSE HAPPENS.
#
# The ask was a feedback signal that works "also when not having shell loaded",
# and this is the only place that can be true. Everything below -- the key
# release sweep, the helper pkills, the shell kill, the wait for the process
# table to drain, the relaunch and the 2.5s the config takes to load -- adds up
# to several seconds. Measured on this machine from the keypress: the shell was
# gone at 0.0s, the first layer surface came back at ~9.5s, and in between the
# screen was Hyprland's bare background colour with nothing at all on it. That
# silence is indistinguishable from a hang, and it is the whole reason someone
# presses the failsafe a second time.
#
# It used to be shown by shell.sh, which is the wrong place for this path:
# shell.sh runs AFTER the teardown, and (correctly, for a login) refuses to
# show anything while a shell is alive -- which during a reset it always is.
# So it is raised here instead, forced, and splash.sh's watcher waits for the
# old shell to actually die before it starts looking for the new one.
#
# `SPLASH_FORCE` only waives the "a shell is already running" refusal. It does
# not waive "another splash is already up", so repeated presses cannot stack
# indicators.
# `SPLASH_FORCE=1` goes in front of `setsid`, not in front of `bash`. Written
# as `SPLASH_FORCE=1 setsid bash splash.sh` it looks right and is not: the
# assignment lands on the `setsid` process, which does not pass its own
# environment through to the script it execs. Measured -- the log said "shell
# already running, not showing splash" on a reset where no shell was running,
# which is exactly the bug this was meant to introduce feedback for.
#
# The 130s timeout is not arbitrary: it is sized to OUTLIVE THIS SCRIPT's own
# patience. Step 4 below waits 50s per attempt and retries once, so the reset
# itself can take ~100s. splash.sh's own default of 45s was shorter than that,
# which meant that on a slow load -- and this machine's shell has measured
# 9.4s idle but over 50s while other sessions are running -- the indicator
# timed out and vanished while the desktop was still loading, putting the user
# back on a bare background with nothing on it. An indicator that gives up
# before the thing it is reporting on has given up is worse than none, because
# it has already told the user something is under way and then stopped. The
# watcher's timeout is self-cleaning, so a generous value cannot leave the
# splash stranded if the shell never arrives.
setsid env SPLASH_FORCE=1 SPLASH_TIMEOUT="${SPLASH_TIMEOUT:-130}" bash \
    "$HOME/.config/quickshell/ii/scripts/launch/splash.sh" \
    >/dev/null 2>&1 </dev/null &

# A splash that cannot start leaves the user with nothing at all, which is the
# case this whole mechanism exists to cover -- so the signal is confirmed
# rather than assumed. `splash.sh` is a second Quickshell instance; if THAT
# cannot come up (a broken splash config, no free GPU memory) there is no
# indicator, and the fallback is the one thing that needs no compositor
# surface, no daemon and no shell: a scrollback line on the tty the desktop
# was started from.
#
# Only when the splash is genuinely absent, so the common case stays clean.
sleep 0.6
if ! pgrep -f "[q]s -c splash" >/dev/null 2>&1; then
    {
        printf '\n[ii] shell reset: no splash available, reloading the desktop shell...\n'
    } >/dev/tty 2>/dev/null || true
    echo "[reset] splash did not start; fell back to the tty notice" \
        >>"$log_file" 2>/dev/null || true
fi

# 0. Let go of every button and key first.
#
# The shell drives the on-screen keyboard, and the user's own hotkeys drive a lot
# of other things, through ydotool -- which types into a virtual device whose
# button and key state belongs to the *session*, not to the program that sent it.
# A press without its release (an interrupted script, a hotkey killed halfway)
# leaves that button held down, and from that moment the pointer moves but no
# click ever lands: the press has already happened, so nothing new gets pressed.
# "I cannot click anything" is exactly this. Sending a complete click for each
# button ends with every one of them up, and releasing all 249 keycodes ends with
# no modifier left down, whatever the shell was doing.
if command -v ydotool >/dev/null 2>&1; then
    ydotool click --next-delay 0 0x00 0x01 0x02 0x03 0x04 >/dev/null 2>&1
    ydotool key --key-delay 0 $(seq 0 248 | sed 's/$/:0/') >/dev/null 2>&1
fi

# 1. Drop anything that could be sitting in front of everything or holding input:
#    the shell's helper windows (settings / launcher / pickers, started as `qs -p`)
#    and the small fuzzel / wlogout overlays.
pkill -f "qs -p" 2>/dev/null
pkill -x fuzzel 2>/dev/null
pkill -x wlogout 2>/dev/null

# 2. Stop the shell, and WAIT until the process table is actually clean.
#
# The wait is the fix, not a nicety. This used to sleep a fixed 0.6s and then
# start a shell of its own -- while `shell-watchdog.service` polls every 5s and
# launches one the moment `qs -c ii` is gone. Two shells racing over layer
# surfaces and the global-shortcut registration is how the SUPER key "died"
# once; that is documented in ../../quickshell/ii/restart-shell.sh, which was
# hardened against exactly this race. This script never was.
#
# WHY NOT `pkill -x qs` HERE. It killed the splash too. The indicator is a
# second Quickshell instance started ~0.6s earlier in step 0a, so it has the
# very same process name, and `pkill -x qs` cannot tell the desktop from the
# thing announcing the desktop's replacement. Measured on this machine: the
# splash mapped `quickshell:splash` at 0.8s after the keypress and was gone by
# 2.4s, killed here rather than by its own watcher -- and the desktop's first
# layer surface did not come back for another ~13s. From the user's side that
# is a splash that blinks and then a black screen: indistinguishable from no
# feedback at all, which is the exact complaint step 0a was added to answer.
#
# So the teardown is explicit about what it spares: every quickshell instance
# EXCEPT the one running the splash config. Everything else is still killed
# broadly, because a stale `qs` left holding layer surfaces is precisely what
# this step exists to clear.
splash_config="${SPLASH_CONFIG:-splash}"
for _pid in $(pgrep -x qs 2>/dev/null; pgrep -x quickshell 2>/dev/null); do
    _cmd="$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)"
    case "$_cmd" in
        *"qs -c $splash_config"*|*"quickshell -c $splash_config"*|\
        *"--config $splash_config"*)
            echo "[reset] leaving splash pid $_pid up" >>"$log_file" 2>/dev/null || true
            continue
            ;;
    esac
    kill "$_pid" 2>/dev/null || true
done

for _ in $(seq 1 40); do
    [ -n "$(shell_pids "$qs_config")" ] || break
    sleep 0.25
done
if [ -n "$(shell_pids "$qs_config")" ]; then
    # Kill by PID, from the exact list, rather than `pkill -9 -x qs`. The
    # pattern kills every qs on the machine -- including a `qs -p` helper
    # window the user has open -- and `pkill -f` would additionally hit any
    # process whose ARGUMENTS happen to mention the config name.
    for _pid in $(shell_pids "$qs_config"); do kill -9 "$_pid" 2>/dev/null || true; done
    sleep 0.5
fi

# 3. Bring it back THE WAY every other launcher on this desktop does.
#
# This used to be a bare `setsid qs -c "$qs_config"`, which made it the only
# place in the desktop that started a shell WITHOUT going through shell.sh --
# and shell.sh is where all of the hard-won correctness lives: it reaps shells
# belonging to dead sessions, takes an flock so two launchers cannot both
# believe they won, writes the started-stamp that closes the gap between `exec`
# and the process becoming visible to pgrep, re-probes WAYLAND_DISPLAY through
# session-env, and pins ~/.local/bin onto PATH.
#
# Skipping all of that is why this key could close the desktop and leave it
# closed: a bare `setsid qs` inherits whatever environment the keybind handed
# over, and when that environment is wrong the shell dies on its first frame
# with nothing on screen to say so.
#
# The stamp is cleared first, and deliberately: it exists to stop a second
# launcher duplicating one that started in the last few seconds, but after we
# have just KILLED the shell it is stale by definition, and leaving it would
# make shell.sh decline the restart and report "no shell" while the watchdog
# slowly noticed instead. No shell is running at this point (checked above),
# and shell.sh's own per-session check and flock arbitrate anything that races
# us from here.
#
# The launch itself lives in launch_once() in step 4, so the retry there reuses
# this exact path instead of growing a second, subtly different one.

# The reset itself is done -- the shell has been launched. The lock is dropped
# as soon as this script exits (see the subshell above), so a second press is
# not made to wait out the confirmation loop below.
#
# 4. Confirm it came back.
#
# The test is the shell's own IPC, NOT the presence of a `qs` process, and that
# distinction is the entire difference between this working and not.
#
# `pgrep` only proves a process was started. A `qs` process exists several
# seconds before its QML has evaluated, and it also exists for the whole of the
# failure this failsafe exists for: a shell that starts, hits a broken config,
# and exits again. So a pgrep-based check reports success for exactly the state
# the user is complaining about -- the desktop visibly empty, the command
# having said nothing wrong. That is the "it only closes the shell" report.
#
# `qs -c ii ipc call bar gapState` cannot be answered by a process that has not
# finished loading, because answering it requires a loaded Bar.qml with a live
# IpcHandler. Measured latency once loaded: ~50-80ms. So it is both a real
# readiness signal and cheap enough to poll every half second.
launch_once() {
    # The stamp is cleared here, not once at the top, so a retry is not blocked
    # by the stamp the first attempt legitimately wrote.
    rm -f "${XDG_RUNTIME_DIR:-/tmp}/ii-shell.started" 2>/dev/null || true
    if PROBED="$("$HOME/.local/bin/session-env" 2>/dev/null)"; then
        # setsid + a redirected stdin so the launcher survives this script
        # exiting and can never hold whatever started it. shell.sh ends in
        # `exec qs`, so it would otherwise run in this script's foreground.
        setsid env $PROBED bash "$HOME/.config/quickshell/ii/scripts/launch/shell.sh" \
            >>"$log_file" 2>&1 </dev/null &
    else
        # No live compositor to probe, so there is nothing better to launch
        # into. The confirmation loop below will say plainly whether it took.
        setsid qs -c "$qs_config" >>"$log_file" 2>&1 </dev/null &
    fi
}
launch_once

# ── How "loaded" is decided ───────────────────────────────────────────────
#
# The original test was `timeout 10 qs -c ii ipc call bar gapState`, and it is
# the second half of this bug. Measured on this machine, that call costs
# ~2400ms when the shell IS up and the full 10s timeout when it is not. The
# confirmation loop runs it 40 times, so confirming a perfectly healthy shell
# took tens of seconds, and during that wait:
#
#   * the retry's kill fires while a shell is mid-load and kills it
#   * launch_once runs again, and the two overlap into a DUPLICATE shell
#
# Observed directly while fixing this: two `qs -c ii` processes alive
# together, which is the exact bug shell.sh's flock exists to prevent.
#
# A much cheaper and more direct readiness signal is available: ask the
# COMPOSITOR whether the shell owns a layer surface. `hyprctl layers -j` costs
# 38ms, and a config whose QML has evaluated owns several `quickshell:*`
# surfaces (measured: bar, background, sidebarLeft, sidebarRight,
# desktopIndicator, edgeReveal, screenCorners). A `qs` process that exists but
# has not finished loading owns none.
#
# Both checks are kept, in cost order: the layer test decides, and the IPC call
# is the final confirmation that the loaded shell is actually ANSWERING. Using
# only the cheap one would be a weaker claim; using only the expensive one is
# what made this feel broken.
shell_has_surfaces() {
    python3 - "$qs_config" <<'PY' 2>/dev/null
import json, subprocess, sys
config = sys.argv[1]
try:
    out = subprocess.run(["hyprctl", "layers", "-j"], capture_output=True,
                         text=True, timeout=5).stdout
    data = json.loads(out or "{}")
except Exception:
    sys.exit(1)
for monitors in data.values():
    for level in (monitors.get("levels") or {}).values():
        for surface in level or []:
            if not (surface.get("namespace") or "").startswith("quickshell:"):
                continue
            pid = surface.get("pid")
            if not pid:
                continue
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as fh:
                    cmd = fh.read().replace(b"\0", b" ").decode(errors="replace")
            except OSError:
                continue
            if f"qs -c {config}" in cmd:
                sys.exit(0)
sys.exit(1)
PY
}

# The IPC confirmation is the expensive one, and its cost depends entirely on
# whether the shell is up. Measured on this machine: ~65ms when it is, and the
# FULL timeout when it is not, because the call blocks until the timeout kills
# it. That asymmetry is what made this feel broken -- the first poll of a shell
# that is still loading ate 10s of the wait, so 60 iterations could spend the
# entire budget on probes that were never going to answer.
#
# 3s is comfortably above the ~65ms a live shell answers in and low enough that
# a not-yet-loaded one costs a third of what it used to.
shell_is_loaded() {
    timeout 3 qs -c "$qs_config" ipc call bar gapState >/dev/null 2>&1
}

loaded=0
# Two attempts. The first is the normal path; the second exists because a
# launch can lose a race it should have won (a launcher mid-exec holding
# shell.sh's flock, for instance), and retrying once costs ~10s in a case where
# the alternative is a desktop with no shell until someone presses the key
# again.
for attempt in 1 2; do
    # 200 x 0.25s = 50s of patience per attempt, ~100s in total.
    #
    # The budget is generous because the shell's OWN load time is not ours to
    # control, and it varies by more than an order of magnitude on this
    # machine: measured 9.4s when idle, and past 50s under the load this
    # desktop actually runs at (load average was measured at 17-40 while these
    # runs were failing). A budget tuned to the idle figure is a budget that
    # fails exactly when the desktop is busy, which is when someone reaches
    # for the failsafe.
    for _ in $(seq 1 200); do
        # Cheap gate: is there a process at all? `qs` is visible to pgrep well
        # before its QML has evaluated, so this only skips the work below while
        # nothing has started yet.
        if [ -z "$(shell_pids "$qs_config")" ]; then
            sleep 0.25
            continue
        fi
        # The 13ms compositor check decides: a config whose QML has evaluated
        # owns `quickshell:*` surfaces, one that has not owns none.
        shell_has_surfaces || { sleep 0.25; continue; }
        # And the real confirmation: the loaded shell actually answers. Only
        # reached once surfaces exist, so this is never a 3s wait on a shell
        # that plainly has not finished loading.
        if shell_is_loaded; then
            loaded=1
            break
        fi
        sleep 0.25
    done
    [ "$loaded" -eq 1 ] && break
    [ "$attempt" -eq 1 ] || break
    echo "[reset] shell did not load on the first attempt; retrying once" \
        >>"$log_file" 2>/dev/null || true
    # Clear a shell that came up but is wedged, so the retry is a real restart
    # and not a second launcher talking to a half-dead one. By PID from the
    # exact list: a `qs -p` helper is neither ours nor what we are waiting for.
    for _pid in $(shell_pids "$qs_config"); do kill -9 "$_pid" 2>/dev/null || true; done
    sleep 1
    launch_once
done

if [ "$loaded" -eq 1 ]; then
        # Deliberately SILENT.
        #
        # It is tempting to confirm here -- the process exists, so "reloaded"
        # is defensible. Two reasons not to, and both are about this desktop
        # specifically rather than about caution in general:
        #
        #   * The notification daemon IS the shell. `org.freedesktop.Notifications`
        #     is owned by this very process (measured: the only host on the bus
        #     is org.kde.StatusNotifierHost-<shellpid>). At the instant this
        #     branch runs, the process has only just appeared -- it has not
        #     evaluated its QML and has not claimed the bus name. So a
        #     confirmation sent now is dropped, and the one moment that could
        #     tell the user the wait is over is the moment it cannot be
        #     delivered.
        #
        #   * A `qs` process existing is not a loaded config. That was the
        #     second reason this branch could not confirm, and it is now fixed
        #     at the source: `loaded` is only set by a real IPC round trip
        #     against a live Bar.qml, so this branch genuinely knows the config
        #     loaded. It still cannot SHOW that, only know it.
        #
        # The bar reappearing is the confirmation, and unlike a notification it
        # cannot be wrong -- the process that would render one is the process
        # this script kills. Silence here is not a missing feature: a message
        # that cannot be delivered is worse than none.
        #
        # But the user DOES want a visible success signal: a green "Quickshell
        # reloaded" card. We can launch that here because the shell is now alive
        # and answering IPC (loaded=1 was set by shell_is_loaded above). The card
        # is a separate qs process with its own layer surface, so it does not
        # depend on the shell's notification bus.
        show_green_reloaded
        exit 0
fi

# ── The one failure worth recording (2026-10-02) ─────────────────────────
#
# Reached when the shell did not become answerable over IPC within two
# attempts. The usual cause on this desktop is a config with an error: the
# shell starts, cannot finish loading, and exits again. There is no
# notification for it -- see the note at the top of this file for why one
# cannot be shown -- so the log is the whole report, and it names the log that
# holds the actual parse error rather than leaving the user to guess.
#
# Logged unconditionally rather than only on the way out, so a reset that
# half-worked is still visible afterwards.
echo "[reset] shell did not load after 2 attempts (no IPC response). Likely a broken config -- check /tmp/ii_shell.log since the last 'Launching config' line" \
    >>"$log_file" 2>/dev/null || true
exit 1
