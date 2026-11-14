#!/usr/bin/env bash
# shell-watchdog.sh -- keep the desktop's soft parts alive.
#
# Runs as shell-watchdog.service (systemd --user). One guard:
#
#  1. SHELL GUARD  -- relaunches the Quickshell shell (`qs -c ii`) when it
#     dies. The bar, panels, OSDs and every shell-integrated keybind depend
#     on it. Uses the same single-instance launch script as login, so a
#     reload/reboot/watchdog race can never stack two bars.
#
set -u

LAUNCH="$HOME/.config/quickshell/ii/scripts/launch/shell.sh"

# Exact shell detection. `pgrep -f "qs -c ii"` matches the full command line,
# so it is also true when some unrelated process merely MENTIONS that string --
# another agent session's wrapper, a grep, an editor. The watchdog used it to
# decide "a shell is alive, do nothing", which meant that with a decoy running
# and the real shell dead, the watchdog stood down and never relaunched. See
# shell-pids.sh.
# shell_pids is sourced once, outside the loop, so the cost is paid at start.
. "$HOME/.config/quickshell/ii/scripts/launch/shell-pids.sh"
: "${qsConfig:=ii}"
shell_up() { [ -n "$(shell_pids "$qsConfig")" ]; }
RESET_FLAG="${XDG_RUNTIME_DIR:-/tmp}/ii-shell-reset.active"

log() { echo "[shell-watchdog] $(date '+%H:%M:%S') $*" >>/tmp/shell-watchdog.log; }

# ── Relaunch backoff ─────────────────────────────────────────────────────
#
# WHY THIS EXISTS, and it is the whole freeze.
#
# Guard 1 below used to relaunch the shell and then sleep a flat 5 s, forever.
# That is correct for the case it was written for -- a shell that CRASHED,
# which a relaunch usually fixes. It is exactly wrong for the other case: a
# shell whose CONFIG FAILS TO LOAD.
#
# A config that fails to load is deterministic. Quickshell resolves the whole
# QML tree eagerly, so ONE bad file -- a missing type, an unbalanced brace, a
# property that does not exist -- makes the top-level panel family
# "unavailable", and the entire shell refuses to start. Relaunching it five
# seconds later re-parses the same tree, hits the same error, and dies again.
# The loop then spins at the watchdog's cadence for as long as the file stays
# broken, and every iteration is a multi-second stall of the whole desktop:
# that is the "freezes for a second or two, over and over" report.
#
# Measured on this machine before this block existed -- from the log, not
# inferred: 243 relaunches, 134 "Failed to load configuration" errors, and a
# relaunch-interval histogram whose dominant bucket was 12 s (87 times), with
# clusters at 5 s, 8 s, 11 s, 13 s and 14 s. The watchdog's own cgroup had
# burned 6 h 11 m of CPU over a 13 h uptime, i.e. roughly half the wall time
# spent reloading a shell that could not load.
#
# So a shell that dies AGAIN quickly is not relaunched quickly: it backs off.
# A one-off crash still gets its 5 s relaunch (the counter only grows when the
# previous launch also died fast), while a broken config settles into a quiet
# wait that is easy to read in the log, instead of an endless freeze storm.
RAPID=0                 # consecutive relaunches where the shell died fast
RAPID_WINDOW=60         # "died fast" = gone again within this many seconds
BACKOFF_START=5         # the ordinary cadence, unchanged
BACKOFF_MAX=60          # cap: never wait longer than this
LAST_LAUNCH=0           # epoch of the last relaunch, 0 = never

# ── Stray `nmcli monitor` sweep ──────────────────────────────────────────
#
# The shell's Network service (services/Network.qml) starts `nmcli monitor`
# to watch for network changes. That is a plain output stream: nothing tells
# it when its owner is gone, and the wrapper the shell puts around it is a
# DIRECT CHILD -- so when the shell is killed outright, the wrapper dies with
# it, its trap and its owner-poll never run, and the monitor is orphaned while
# still holding a D-Bus connection to nobody. ~10 MB each, and they
# accumulated one per shell restart until twenty were running.
#
# WHY HERE AND NOT IN THE QML. It was in services/Network.qml, as a second
# `Process` beside the subscriber -- and that block never ran, not once, over
# repeated restarts and with nothing in the log. This script already runs on
# every launch, so the sweep does too.
#
# WHY NOT `ppid 1`. That is the textbook "ownerless" test and it is wrong on
# this machine: the shell is started by shell-watchdog.service, so the kernel
# reparents its orphans to the systemd USER manager, and the strays were
# observed at ppid 5094 -- never 1. The sweep matched none of them.
#
# The test that holds up is OWNERSHIP, not a pid: a live monitor is a child of
# the wrapper script, and that wrapper is the only process whose argv carries
# the marker below. Anything else -- reparented to the user manager,
# reparented to init, parent long dead -- is a stray, and no particular
# reparenting behaviour has to be known to catch it.
#
# `pgrep -x nmcli` matches the process NAME, so this loop cannot see the
# watchdog or any shell: a `pgrep -f 'nmcli monitor'` would match this very
# script, and selecting by name makes the loop incapable of shooting itself.
sweepStrayNetworkMonitors() {
    local killed=0
    for p in $(pgrep -x nmcli 2>/dev/null); do
        # Only the long-lived watcher, never a transient `nmcli -t ...` call.
        [ "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)" = "nmcli monitor " ] || continue
        local pp; pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        [ -z "$pp" ] && continue
        local pcmd; pcmd=$(tr '\0' ' ' <"/proc/$pp/cmdline" 2>/dev/null)
        case "$pcmd" in
            *"nmcli monitor & mpid="*) continue ;;   # ours, still owned
        esac
        kill -9 "$p" 2>/dev/null && killed=$((killed + 1))
    done
    [ "$killed" -gt 0 ] && log "swept $killed stray nmcli monitor(s)"
    return 0
}

# ── Stray `udevadm monitor` sweep ─────────────────────────────────────────
#
# The shell's Volumes service (services/Volumes.qml) watches the hotplug bus
# with `udevadm monitor`, started as a `Process` -- a DIRECT CHILD of `qs`.
# Nothing tells that child when its owner is gone, and the QML-level restart
# (onExited) only ever runs while the shell is ALIVE, so a shell that is killed
# rather than exited leaves the monitor behind for good. One per restart, and
# this machine restarts its shell a lot while its config is being worked on:
# measured 2026-10-14, 25 of them, the oldest from 09:48, each still holding a
# netlink socket to the hotplug group.
#
# WHY THE PARENT IS THE TEST, and not "did my shell start it". A live monitor
# is a direct child of `qs -c ii`. A stray has been reparented -- observed at
# pid 1 and at the systemd USER manager (`/usr/lib/systemd/systemd --user`),
# never at the shell. So the test is the parent's own argv: anything started by
# a human, from a terminal, has a SHELL as its parent and is left strictly
# alone, while anything owned by an init process belongs to a shell that is
# already gone. `pgrep -x udevadm` matches the process NAME, so this loop
# cannot see the watchdog itself or a `pgrep -f` about it.
#
# IT RUNS ON ITS OWN LOOP, and that is the correction this needed. The obvious
# place for it -- the top of the main loop below -- is NOT a timer: that loop
# BLOCKS. `env ... bash "$LAUNCH"` leaves the shell as this script's child, so
# the shell's lifetime IS one iteration of the loop, and everything at the top
# of it runs once per shell exit (which is also why guard 2, the KEYBOARD check,
# only gets a look in then). Measured while the shell was up: zero CPU ticks in
# twelve seconds, and a `/proc` wchan of `do_wait`.
#
# So the sweep gets a loop that is not blocked by the shell. Fifteen seconds is
# well inside "a background process that is not wanted" -- one `pgrep` and a
# read of a few `/proc` files -- while still being quick enough that a stray is
# gone by the time anybody looks.
sweepStrayUdevMonitors() {
    local killed=0
    for p in $(pgrep -x udevadm 2>/dev/null); do
        # Only this shell's watcher, never some other udevadm call.
        #
        # Matched as a SUBSTRING, not for equality, and that is not laziness:
        # the shell spawns `udevadm` through PATH, so argv[0] here is
        # "/usr/bin/udevadm" and an exact comparison against "udevadm ..."
        # matched nothing at all -- the first cut of this sweep reaped zero
        # processes and left all 22 in place, which is exactly the kind of
        # silence the log line at the end is there to make visible.
        local cmd; cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)
        case "$cmd" in
            *"udevadm monitor --udev --subsystem-match=block --subsystem-match=usb"*) ;;
            *) continue ;;
        esac
        local pp; pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        [ -z "$pp" ] && continue
        local pcmd; pcmd=$(tr '\0' ' ' <"/proc/$pp/cmdline" 2>/dev/null)
        case "$pcmd" in
            # Owned by a live shell: the shell reaps it (and onExited restarts
            # it) itself. Not ours to touch.
            *"qs -c ii"*) continue ;;
            # Reparented to an init: its shell is gone, and the socket with it.
            *systemd*) kill -9 "$p" 2>/dev/null && killed=$((killed + 1)) ;;
        esac
    done
    [ "$killed" -gt 0 ] && log "swept $killed stray udevadm monitor(s)"
    return 0
}

# ── Guard 0a: strays from a shell that is already gone ───────────────────
# Started once, off the main loop, so it keeps working while the shell is up --
# which is when the file manager's own copies of the shell's watchers are left
# behind, and when the main loop is blocked. Same process group, so stopping
# the service stops this too.
#
# THE NETWORK SWEEP BELONGS HERE TOO, and its absence here was a real leak.
#
# It used to run only in the relaunch branch of the main loop, which fires
# when THIS watchdog finds the shell dead. A restart the watchdog did not
# perform -- reload-shell.sh, reset-shell.sh, the keybind that re-execs the
# shell -- never enters that branch, so the monitor its shell leaves behind
# was never swept: one orphan per such restart, reparented to init, holding
# an 11 MB D-Bus connection to nobody. Measured 2026-10-16: 16 `nmcli
# monitor` processes live at once, uptimes stepping 2411/1916/1893/.../775 s
# -- one per shell restart in the preceding forty minutes, exactly the
# restarts done while the config was being worked on. Their wrappers carry
# the marker below and are spared, so running this every 15 s neither touches
# the live shell's own watcher nor fights the pre/post-launch sweeps.
(
    while true; do
        sweepStrayUdevMonitors
        sweepStrayNetworkMonitors
        sleep 15
    done
) &

# ── Guard 0b: a shell that is ALIVE but not ANSWERING ──────────────────────
#
# WHY THIS EXISTS. On 2026-11-14 a dictation stalled and the shell it was talking
# to stopped answering IPC entirely: `qs -c ii ipc call` simply never returned.
# Every SUPER action on this desktop is an IPC call into the shell, so from the
# user's side the Super key was dead, the dictation pill sat on "transcribing",
# and nothing ever recovered -- the shell process was still ALIVE, so guard 1
# below (whose only test is `shell_up`) saw a healthy desktop and did nothing.
#
# WHAT IT LOOKED LIKE while it happened: the shell at ~20 % CPU, `timeout 6 qs -c
# ii ipc call theme mode` timing out, two `qs ipc call cliphistService quietFor`
# clients hung for minutes, and `qs kill` hanging too, so a hand-run reload left
# the old shell running and the new one unable to claim its surfaces.
#
# THE TEST asks the cheapest real IPC function and requires an ANSWER, not just
# an exit status: `qs ipc call` against a wedged shell still exits 0, and with a
# wrong function name it prints "Function not found." and exits 0 as well, so
# status alone is not evidence of life. Two misses 15 s apart mean wedged rather
# than busy, and a shell that started less than 20 s ago is skipped so login is
# never mistaken for a hang. Recovery is the ordinary reload script, which now
# force-kills anything `qs kill` cannot reach.
#
# Its own loop, like the sweeps: the main loop below is blocked inside the shell's
# lifetime and cannot look at a shell that has not exited.
(
    misses=0
    last_restart=0
    while true; do
        sleep 15
        if ! shell_up; then
            misses=0
            continue
        fi
        first_pid="$(shell_pids "$qsConfig" | head -1)"
        up=$(ps -o etimes= -p "${first_pid:-0}" 2>/dev/null | tr -d ' ')
        if [ -z "$up" ] || [ "$up" -lt 20 ]; then
            misses=0
            continue
        fi
        answer=$(timeout 6 qs -c "$qsConfig" ipc call theme state 2>/dev/null)
        case "$answer" in
            mode=*) misses=0; continue ;;
        esac
        misses=$(( misses + 1 ))
        log "shell did not answer IPC (${misses}/2; got '${answer:-nothing}')"
        if [ "$misses" -ge 2 ]; then
            misses=0
            if [ $(( $(date +%s) - last_restart )) -lt 60 ]; then
                continue
            fi
            last_restart=$(date +%s)
            log "shell is WEDGED -- every SUPER action is dead while it answers nothing; restarting it"
            bash "$HOME/.config/hypr/custom/scripts/reload-shell.sh" >>/tmp/shell-watchdog.log 2>&1 || true
        fi
    done
) &

while true; do
    # Reset to the ordinary cadence each pass; the relaunch branch below
    # lengthens it only when the shell is failing to come up.
    SLEEP=$BACKOFF_START

    # ── Guard 0: stand down while the failsafe is running ─────────────────
    #
    # This is not politeness between two launchers, it is the whole bug.
    #
    # reset-shell.sh's FIRST act is to kill `qs -c ii`. The instant that
    # happens this loop's `pgrep` below answers "no shell", and on a tick that
    # lands inside the reset's own window it launches a shell of its own --
    # concurrently with the one the reset is launching. shell.sh's flock picks
    # a winner, so the outcome is not two bars; it is that the shell you end
    # up with is whichever launcher won, at a moment you did not choose.
    #
    # Measured on 2026-10-03, from the log rather than inferred: the reset ran
    # at 09:03:28 and /tmp/ii_shell.log gained TWO `Launching config` lines
    # back to back (543, 547), with the watchdog logging "relaunched shell" at
    # both 09:03:25 and 09:03:40. Two shells started; one survived.
    #
    # The flag is written by the reset before it kills anything and removed on
    # its way out (including on failure, via trap), so the window this closes
    # is exactly the window where "no shell" is expected rather than alarming.
    # Checking a flag and not, say, pausing the service also means a reset that
    # dies without cleaning up cannot wedge the watchdog off permanently --
    # the stale flag is older than a couple of minutes below, and ignored.
    #
    # KEYBOARD GUARD STILL RUNS. It is unrelated to the shell and a reset must not
    # stop brightness/volume keys from being rescued, so this skips guard 1
    # only and falls through to guard 2.
    reset_active() {
        [ -f "$RESET_FLAG" ] || return 1
        # A flag older than 120s belongs to a reset that died without removing
        # it. Ignoring it is what keeps a crash from disabling the watchdog.
        [ $(( $(date +%s) - $(stat -c %Y "$RESET_FLAG" 2>/dev/null || echo 0) )) -lt 120 ]
    }

    # ── Guard 1: the shell ────────────────────────────────────────────────
    if ! shell_up && ! reset_active; then
        # The session environment is PROBED, never read from
        # `systemctl --user show-environment`. The user manager is started
        # once per boot but displays are allocated per login, so after a few
        # logins it advertises a dead one (here: wayland-2 while the live
        # session is wayland-1). A relaunch that trusted it started `qs`
        # against a socket with no server, `wl_display_connect` was refused,
        # and the loop below logged "relaunched shell" every 5 s forever
        # while the bar stayed gone. session-env connect-probes the sockets
        # and returns the compositor that is actually listening.
        if ! SESSION_ENV="$("$HOME/.local/bin/session-env")"; then
            # No compositor yet (or we are on a tty). Do not launch into a
            # guessed environment; try again on the next tick.
            #
            # Throttled, and loud about being throttled. This used to log the
            # identical line every 5 s, and on 2026-10-04 that produced 413
            # identical lines in a row -- forty minutes during which the
            # desktop had no shell at all and the log said exactly the same
            # thing every time. Identical repeated lines are invisible: the
            # eye skips them and `tail` shows nothing but the same sentence,
            # so the one piece of evidence that the watchdog had been useless
            # for the whole session was the evidence nobody reads.
            #
            # Now it reports the streak length, so "we have been unable to
            # find your compositor for N ticks" is visible on its own, and a
            # session that never recovers can be told apart from a login
            # still settling by counting rather than by reading.
            noplay=$(( ${noplay:-0} + 1 ))
            if [ $(( noplay % 12 )) -eq 1 ]; then
                if [ "$noplay" -eq 1 ]; then
                    log "no live compositor, skipping shell relaunch (waiting)"
                else
                    log "no live compositor for ${noplay} consecutive ticks (~$(( noplay * 5 / 60 )) min), still not launching"
                fi
            fi
            sleep 5
            continue
        fi
        # A compositor is back. Only worth saying if we had actually gone
        # without one, otherwise this is noise on every ordinary relaunch.
        if [ "${noplay:-0}" -gt 0 ]; then
            log "compositor is back after ${noplay} tick(s) without one"
        fi
        noplay=0
        # shell.sh holds its own single-instance guard, so the pgrep above
        # racing a slow start cannot stack a second bar.
        #
        # Swept BEFORE the launch, so the new shell's own watcher is not up
        # yet and cannot be mistaken for a stray. Anything still running at
        # this point belongs to a shell that is already gone.
        sweepStrayNetworkMonitors
        sweepStrayUdevMonitors
        env $SESSION_ENV bash "$LAUNCH" >>/tmp/shell-watchdog.log 2>&1 || true
        # ...and again AFTER it, because the pre-launch sweep alone loses a
        # race. A dying shell takes its wrapper down with it, and the kernel
        # reparents the orphaned monitor a moment LATER -- measured: the
        # pre-launch sweep found nothing, the monitor was still parented to
        # a live wrapper at that instant, and one tick later it was sitting
        # at ppid 5094 with nobody owning it. One leaked per restart again,
        # which is the exact bug this exists to stop.
        #
        # Safe to run against a shell that has just started: the new
        # watcher's wrapper carries the marker, so it is spared.
        sweepStrayNetworkMonitors
        log "relaunched shell with $(echo "$SESSION_ENV" | tr '\n' ' ')"
        # A launch that is followed by a death is not a crash to retry at once:
        # see the backoff note at the top. The delay is decided HERE and paid
        # by this iteration's own sleep, so a normal crash keeps its 5 s.
        now=$(date +%s)
        if [ "$LAST_LAUNCH" -gt 0 ] && [ $((now - LAST_LAUNCH)) -lt "$RAPID_WINDOW" ]; then
            RAPID=$((RAPID + 1))
        else
            RAPID=0
        fi
        LAST_LAUNCH=$now
        # Capped before the shift: the delay is clamped to BACKOFF_MAX anyway,
        # and an unbounded count would eventually shift past the word size.
        [ "$RAPID" -gt 8 ] && RAPID=8
        if [ "$RAPID" -gt 0 ]; then
            SLEEP=$(( BACKOFF_START * (1 << (RAPID - 1)) ))
            [ "$SLEEP" -gt "$BACKOFF_MAX" ] && SLEEP=$BACKOFF_MAX
            # Said out loud, WITH THE LIKELY CAUSE. This state used to be
            # invisible: the log showed only fast repeated "relaunched shell"
            # lines and never named the file that would not load, so a desktop
            # freezing every few seconds looked like the watchdog doing its job.
            # The cause is three lines further into /tmp/ii_shell.log, under
            # "Failed to load configuration".
            log "shell died again within ${RAPID_WINDOW}s (${RAPID} in a row) -> waiting ${SLEEP}s instead of relaunching immediately; the config most likely FAILS TO LOAD (see 'Failed to load configuration' + 'caused by' in /tmp/ii_shell.log)"
        fi
    elif ! shell_up && reset_active; then
        # Expected, not a fault: the failsafe is mid-restart. Staying quiet
        # here is deliberate -- this branch runs every 5s for the length of the
        # reset, and a log line per tick would bury the one real message.
        :
    fi


    sleep "$SLEEP"
done
