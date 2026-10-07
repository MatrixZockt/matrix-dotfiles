#!/usr/bin/env bash
# splash.sh -- show a small loading indicator until the real shell is on screen.
#
# WHY A SEPARATE PROCESS. The indicator has to be on screen BEFORE the desktop
# finishes loading, so it cannot be part of the `ii` config: `ii` is the thing
# being waited for. This runs its own tiny Quickshell instance
# (~/.config/quickshell/splash) which imports almost nothing and maps a single
# centred surface in well under a second.
#
# WHY IT IS DISMISSED FROM OUTSIDE. Nothing in `ii` knows this exists, on
# purpose -- wiring a "the splash may go now" call into the shell's startup
# path would edit the desktop's startup for a cosmetic feature. Instead this
# watches Hyprland for the moment the real shell puts a surface on the screen
# and then kills the splash.
#
# HOW "THE SHELL IS UP" IS DECIDED. `hyprctl clients` does not list
# layer-shell surfaces, so it cannot see the bar at all and would report a
# working shell as an empty desktop. `hyprctl layers -j` does list them, with
# the namespace and the owning pid of each. The shell's surfaces are all named
# `quickshell:*` and are owned by a process whose command line is `qs -c ii`.
# Both are checked, so neither the splash's own surface nor a layer left over
# from a previous shell can be mistaken for the desktop having loaded.
#
# IF THE SHELL NEVER ARRIVES, the timeout kills the splash and you are left
# looking at the compositor, which is exactly the state you would have been in
# anyway. Failing open, not closed.
set -u

SPLASH_CONFIG="${SPLASH_CONFIG:-splash}"
TIMEOUT="${SPLASH_TIMEOUT:-45}"
LOG=/tmp/ii_splash.log

log() { echo "[splash] $(date '+%H:%M:%S') $*" >>"$LOG"; }

# WHICH CONFIG GETS SHOWN.
#
# Two, because they answer two different questions.
#
# `splash` is the login backdrop: a flat surface that removes the black flash
# before the desktop appears, and deliberately silent because the user asked
# for the "Starting ii…" message to be gone generally. During ordinary startup
# that is right -- a caption describing a shell that is a second away is noise.
#
# `splashfb` is the failsafe indicator, and it draws a spinner. It is used when
# and only when SPLASH_FORCE is set, i.e. when reset-shell.sh deliberately killed
# the shell and is now waiting 8-50s for it to come back. Showing the silent
# backdrop there is what produced "no feedback": measured, the backdrop paints
# #141414 over Hyprland's #0A0A0A background, a 10/255 difference that is
# invisible across a desk. The surface was mapped, the process was alive, and
# the screen looked black. A backdrop meant to be "not a black flash" cannot be
# the thing that tells you the desktop is coming back.
if [ "${SPLASH_FORCE:-0}" = "1" ]; then
    SPLASH_CONFIG="${SPLASH_FEEDBACK_CONFIG:-splashfb}"
fi
# Everything that can be on screen, for the "is one already up?" guard below.
# Checking only $SPLASH_CONFIG would let a silent login backdrop and a failsafe
# indicator coexist, which is two full-screen surfaces fighting for the display.
SPLASH_ALL_CONFIGS="$SPLASH_CONFIG splash splashfb"

# Exact shell detection -- see shell-pids.sh. `pgrep -f "qs -c ii"` matches
# any process whose ARGUMENTS mention the string, so with a decoy around this
# script would decide a shell was already running and never show the indicator
# at all -- precisely when it is most needed.
. "$HOME/.config/quickshell/ii/scripts/launch/shell-pids.sh"

# A splash PROCESS is not the same as a splash ON SCREEN, and conflating them
# silently disables the indicator. Measured on this machine: a splash started at
# 13:29:12 outlived the shell it was watching and was still present at 13:30:44,
# and every reset in that window logged "splash already running" and exited
# without showing anything -- no card, no spinner, just the bare background
# during a multi-second reload. That is precisely the "I get no feedback"
# report, and it recurred on every press until the stale process happened to
# die on its own.
#
# So the guard asks the only question that matters -- is a splash surface
# actually mapped right now -- and anything that fails that test is a corpse
# left over from a previous run, which is cleared out before proceeding.
splash_surface_pid() {
    SPLASH_NS_LIST="quickshell:splash quickshell:splashfb" python3 - <<'PY'
import json, os, subprocess
wanted = set((os.environ.get("SPLASH_NS_LIST") or "").split())
try:
    data = json.loads(subprocess.run(["hyprctl", "layers", "-j"],
                                     capture_output=True, text=True, timeout=5).stdout or "{}")
except Exception:
    raise SystemExit
for monitors in data.values():
    for level in (monitors.get("levels") or {}).values():
        for surface in level or []:
            if (surface.get("namespace") or "") in wanted:
                print(surface.get("pid"))
                raise SystemExit
PY
}

live_splash="$(splash_surface_pid)"
if [ -n "$live_splash" ] && kill -0 "$live_splash" 2>/dev/null; then
    log "splash already on screen (pid $live_splash)"
    exit 0
fi

# Nothing is on screen. Any surviving splash process from an earlier run is a
# leftover, and leaving it in place is what makes every later call refuse.
for _cfg in $SPLASH_ALL_CONFIGS; do
    for _stale in $(pgrep -f "[q]s -c $_cfg" 2>/dev/null); do
        log "clearing stale splash pid $_stale ($_cfg, no surface)"
        kill "$_stale" 2>/dev/null || true
    done
done
sleep 0.2

# Nothing to show a splash for if a shell is already alive -- this is called
# just before the shell is exec'd, so a hit here means a race we lost.
#
# EXCEPT WHEN THE CALLER SAYS OTHERWISE. reset-shell.sh shows the indicator
# BEFORE it kills the shell, so at that moment a shell IS running and this
# check would refuse -- which is precisely the case the user needs told about.
# `SPLASH_FORCE=1` is that caller saying "I know, show it anyway"; it does not
# disable the "another splash is already up" check above, because two splashes
# at once is still wrong.
if [ "${SPLASH_FORCE:-0}" != "1" ] && [ -n "$(shell_pids "$qsConfig")" ]; then
    log "shell already running, not showing splash"
    exit 0
fi

# PRE-CREATE THE RELOAD-DONE MARKER BEFORE THE CARD STARTS.
#
# splashfb polls this path to learn that reset-shell.sh has confirmed the
# reload finished, and a FileView on a MISSING file logs "Read of ... failed:
# File does not exist." on every poll. At the 100ms poll interval that is ten
# warnings a second for the life of the card -- the same disease this desktop
# just spent 80 seconds and 875 MB recovering from (see services/AppSearch.qml's
# tokenScore).
#
# It MUST be written BEFORE `qs` is launched. Writing it after starts the card
# polling a path that does not exist yet, which is exactly the flood above, and
# measured: 33 warnings in the first four seconds.
#
# Its CONTENTS are a fresh token: the card remembers the token it was born
# holding and treats any CHANGE as "the reload is confirmed". Existence alone
# cannot be the signal, because the file always exists.
#
# The path is a literal, matching splashfb/shell.qml's doneMarker exactly. It
# was originally $XDG_RUNTIME_DIR here and Quickshell.env there, and the two
# disagreed -- the QML fell back to /tmp -- so the card watched a file nobody
# wrote. One literal on both sides cannot drift.
if [ "$SPLASH_CONFIG" = "splashfb" ]; then
    printf 'splash:%s:%s\n' "$$" "$(date +%s%N)" >/tmp/ii-reload-done 2>/dev/null || true
fi

setsid qs -c "$SPLASH_CONFIG" >>"$LOG" 2>&1 </dev/null &

# Find the splash's own pid. `setsid` may fork, so $! is not reliable; matching
# the config name is. The HIGHEST matching pid, not the first: the one just
# started is always the newest, and taking the oldest would leave the watcher
# attached to a corpse while the visible indicator ran unsupervised.
SPLASH_PID=""
for _ in $(seq 1 40); do
    SPLASH_PID="$(pgrep -f "[q]s -c $SPLASH_CONFIG" 2>/dev/null | sort -n | tail -1)"
    [ -n "$SPLASH_PID" ] && break
    sleep 0.05
done

if [ -z "$SPLASH_PID" ]; then
    log "splash failed to start; see $LOG"
    exit 0
fi

log "splash up (pid $SPLASH_PID), waiting for the shell"

# One watcher process rather than a shell loop calling hyprctl hundreds of
# times: the polling is a Python loop that spawns hyprctl itself, and it exits
# the moment the shell appears or the timeout expires.
python3 - "$SPLASH_PID" "$TIMEOUT" "${SPLASH_FORCE:-0}" <<'PY'
import json, os, signal, subprocess, sys, time

splash_pid, timeout = int(sys.argv[1]), float(sys.argv[2])
# 1 when this splash was forced on by reset-shell.sh BEFORE it killed the
# shell. In that case "a shell surface is on screen" is true for the shell
# that is about to be killed, so the watcher would dismiss the indicator
# instantly -- telling the user nothing. So in forced mode the watcher first
# WAITS for the old shell to actually go away, and only then starts looking
# for the new one. That is what makes the indicator honest: it appears while
# the desktop is being torn down and stays until the desktop is back.
forced = sys.argv[3] == "1"
saw_shell_gone = not forced


def shell_is_drawn():
    """True once a `qs -c ii` process owns a mapped layer surface."""
    try:
        out = subprocess.run(
            ["hyprctl", "layers", "-j"], capture_output=True, text=True, timeout=5
        ).stdout
        data = json.loads(out or "{}")
    except Exception:
        return False

    pids = set()
    for monitors in data.values():
        for level in (monitors.get("levels") or {}).values():
            for surface in level or []:
                ns = surface.get("namespace") or ""
                pid = surface.get("pid")
                if ns.startswith("quickshell:") and pid and pid != splash_pid:
                    pids.add(pid)

    for pid in pids:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if "qs -c ii" in cmd:
            return True
    return False


def any_shell_process():
    """True while ANY `qs -c ii` process exists, on any display."""
    try:
        out = subprocess.run(["pgrep", "-x", "qs"], capture_output=True,
                             text=True, timeout=5).stdout
    except Exception:
        return False
    for line in out.split():
        try:
            with open(f"/proc/{line.strip()}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if "qs -c ii" in cmd:
            return True
    return False


def remove_splash(reason):
    """Take the indicator down, and make sure it actually goes.

    A bare SIGTERM was not enough. Measured: a splash dismissed at 13:29:12 was
    still alive at 13:30:44, with no layer surface left, so it showed nothing
    while still making every later splash.sh call refuse with "splash already
    running". A dismissed indicator that lingers as a process is worse than one
    that never appeared, because it disables the next one too. So escalate.
    """
    print(f"[splash] {time.strftime('%H:%M:%S')} {reason}")
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(splash_pid, sig)
        except OSError:
            return
        for _ in range(30):
            time.sleep(0.05)
            try:
                os.kill(splash_pid, 0)
            except OSError:
                return  # gone; nothing left to escalate to
    print(f"[splash] {time.strftime('%H:%M:%S')} pid {splash_pid} survived SIGKILL")


deadline = time.time() + timeout
while time.time() < deadline:
    if forced and not saw_shell_gone:
        # Wait for the outgoing shell to die before believing anything about
        # surfaces. Without this the indicator is dismissed by the very shell
        # it was raised to replace.
        if not any_shell_process():
            saw_shell_gone = True
    elif saw_shell_gone and shell_is_drawn():
        remove_splash("shell is on screen, dismissing")
        sys.exit(0)
    time.sleep(0.15)

remove_splash(f"timed out after {timeout:.0f}s, removing")
sys.exit(0)
PY
