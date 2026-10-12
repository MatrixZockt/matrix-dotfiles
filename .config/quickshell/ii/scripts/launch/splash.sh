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
#
# The sweep asks shell_pids, NOT `pgrep -f "[q]s -c $_cfg"`, and that is not
# tidiness -- the pgrep form killed the wrong process, live, while this line
# was being measured. `-f` matches the whole command line with the pattern
# unanchored, so ANY process whose arguments merely mention the string is a
# target: a bash running a test script that contains it, an editor with the
# file open, a terminal showing the source. That happened here -- a shell
# running a test whose text included `qs -c splash` was killed by this loop,
# mid-command, which looks exactly like a random unexplained death. shell_pids
# matches the entire command line exactly (see shell-pids.sh), so a bystander
# cannot match at all.
#
# The `comm` check is belt and braces on a kill path: whatever matches, only a
# real quickshell binary is ever signalled.
for _cfg in $SPLASH_ALL_CONFIGS; do
    for _stale in $(shell_pids "$_cfg"); do
        [ "$(cat "/proc/$_stale/comm" 2>/dev/null)" = "qs" ] || continue
        log "clearing stale splash pid $_stale ($_cfg, no surface)"
        kill "$_stale" 2>/dev/null || true
    done
done
sleep 0.2

# Nothing to show a splash for if the DESKTOP IS ON SCREEN.
#
# "A `qs -c ii` process exists" is NOT that question, and answering it instead
# is why the splash was absent at exactly the moment it exists for. Measured at
# login: the launcher called this script ~6 s after the compositor came up, the
# old guard found the still-loading shell's process and answered "shell already
# running", and the user watched a bare background for the whole load. A
# loading shell, a shell whose bar just crashed, and the shell of the session
# that was logged out of a moment ago all answer "yes" to the process test.
#
# The bar's own published state is the honest test, and it is already the
# desktop's own handshake -- Bar.qml writes $XDG_RUNTIME_DIR/ii-bar-visible.json
# ({visible,stripH,midL,midR,ts}, refreshed every 2 s while the bar is up) and
# the compositor's gesture gate reads it. A fresh `visible:true` means a bar is
# really on screen -- not merely that a process is alive -- so there is nothing
# left to cover. Anything else (no file, a stale one, or `visible:false`)
# means the desktop is not up yet: show the backdrop.
#
# EXCEPT WHEN THE CALLER SAYS OTHERWISE. reset-shell.sh shows the indicator
# BEFORE it kills the shell, so at that moment a shell IS running and this
# check would refuse -- which is precisely the case the user needs told about.
# `SPLASH_FORCE=1` is that caller saying "I know, show it anyway"; it does not
# disable the "another splash is already up" check above, because two splashes
# at once is still wrong.
#
# AND THE FILE ALONE IS NOT ENOUGH EITHER. It has to be a fresh `visible:true`
# written by a shell that is STILL RUNNING, because the file outlives the shell
# that wrote it and is refreshed every 2 s while a bar is up. Measured on the
# login sequence: kill the shell, and the marker left behind still reads
# {"visible":true,"ts":<3 s ago>} -- a stale-but-fresh claim from a corpse.
# Guarding on the file alone therefore reproduced the very bug this is meant to
# fix: the cover refused to appear at login, because the previous session's bar
# had published seconds before. A live `qs -c ii` process is what distinguishes
# the two cases, so both are required: a shell exists AND its bar says it is on
# screen.
#
desktop_on_screen() {
    local config="${qsConfig:-ii}"
    [ -n "$(shell_pids "$config")" ] || return 1
    local f="${XDG_RUNTIME_DIR:-/tmp}/ii-bar-visible.json"
    [ -f "$f" ] || return 1
    BAR_STATE="$f" python3 - <<'PY' 2>/dev/null
import json, os, time
try:
    with open(os.environ["BAR_STATE"]) as fh:
        d = json.load(fh)
except Exception:
    raise SystemExit(1)
# Same 10 s staleness window the compositor's reader uses: a wedged shell's
# last "visible" must not make us skip the backdrop forever.
fresh = time.time() - float(d.get("ts") or 0) < 10
raise SystemExit(0 if d.get("visible") and fresh else 1)
PY
}

if [ "${SPLASH_FORCE:-0}" != "1" ] && desktop_on_screen; then
    log "desktop already on screen (bar published), not showing splash"
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
#
# Its stdout goes to $LOG, NOT inherited. Callers start this script with
# `>/dev/null 2>&1` (shell.sh does), so every print() below -- the two lines
# that say WHY the cover went away -- was written to /dev/null. The result was
# an indicator whose failure was undiagnosable from the log: "the cover never
# disappeared" and "the cover disappeared too early" look identical, and
# neither leaves a trace. log() writes to $LOG already; the watcher now does
# too, and the two halves of one launch read as one story.
python3 - "$SPLASH_PID" "$TIMEOUT" "${SPLASH_FORCE:-0}" >>"$LOG" 2>&1 <<'PY'
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
    """True once the shell's BAR is drawn -- not merely any surface.

    MEASURED, which is why this is not the weaker test it looks like:

        +0.7 s  `qs -c ii` process exists
        +1.1 s  first surface mapped (quickshell:background -- a wallpaper)
        +4.0 s  `quickshell:bar` mapped
        +5.1 s  the bar publishes visible:true

    Dismissing on the first surface therefore hands the user a desktop that
    looks loaded and is not: walls, no bar, nothing to click, for three and a
    half seconds. That is the "blank screen at login" this indicator exists to
    end, so the indicator stays until the bar itself is up.

    `quickshell:bar` is the shell's own namespace for the bar
    (WlrLayershell.namespace in Bar.qml), and the surface is mapped whenever
    the bar is loaded -- a slid-away bar under auto-hide still has its layer
    mapped (it is the margin that moves, not the surface), so this cannot wait
    forever on an auto-hidden bar.
    """
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
                if (surface.get("namespace") or "") == "quickshell:bar":
                    pid = surface.get("pid")
                    if pid and pid != splash_pid:
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
