#!/usr/bin/env bash
# Open the Files app -- the QML file manager, an ordinary desktop WINDOW.
#
#   filemanager.sh                 a NEW Files window
#   filemanager.sh <path>          a new Files window AT that folder -- or AT the
#                                  folder of that file with the file's row
#                                  selected (what the desktop entry's Exec passes
#                                  when a folder is double-clicked, and what the
#                                  FileManager1 service passes when another app
#                                  asks for "show in file manager")
#   filemanager.sh spare           preload ONE hidden copy and exit (autostart)
#   filemanager.sh picker <token>  the portal's FileChooser dialog: a DEDICATED
#                                  transient instance (never the app) that reads
#                                  II_FILES_PICKER, shows the dialog, writes its
#                                  result and quits. A DIALOG has to be a layer
#                                  surface to sit above the app that asked for
#                                  it, so it is a separate QML file.
#
# ── It opens INSTANTLY, out of a warm copy (2026-11-18, requested) ───────────
#
# "The file manager is supposed to open instantly when I open it with SUPER + E."
#
# Measured before this change, twice, from keypress to a window in `hyprctl
# clients`: 1929 ms and 1791 ms. Measured after it, on a warm spare through the
# same keybind: 147-266 ms, the spread being where in the launcher's own poll a
# press lands; the map itself is ~180 ms of that and is the app's first frame. The `qs` binary itself starts in ~50 ms, so
# essentially ALL of it is this app's own QML -- 14 000 lines of
# FileManagerContent, the theme, the services, the first folder read. Nothing in
# that budget can be shaved by a flag: it has to be paid, or it has to be paid
# EARLY, while nobody is waiting.
#
# So it is paid early. One copy is kept alive, fully constructed, with its window
# never mapped (`II_FILES_PRELOAD=1` -> filemanager.qml's `visible: false`):
#
#   * a SUPER + E press CLAIMS that copy over IPC (`files preloadOpen <path>`) --
#     the window is a map, not a load -- and then starts a replacement spare in
#     the background, so the next press is instant again;
#   * the FIRST press after login is already warm too, because `filemanager.sh
#     spare` runs from custom/execs.lua at login;
#   * if there is no spare (it died, the claim raced, this is a session where the
#     autostart never ran), the press COLD-STARTS exactly as before: ~1.8 s, and
#     the spare it spawns on the way out makes that a one-off.
#
# What this keeps from the 2026-10-14 request ("every launch is a NEW WINDOW, and
# it doesn't switch to the already open file manager"): absolutely that. The
# spare has never been on screen, so claiming it is not raising an existing
# window -- a second SUPER + E still gives a second Files, and the first one is
# left alone. Nothing looks for a window the user is using; only for one that
# has never been shown. `preloadOpen` answering "already" is the one case where
# the copy found was not a spare any more, and the launcher's answer there is to
# start its own window rather than to steal that one.
#
# What it costs, said plainly: one idle process (~130 MB) for the spare. It
# draws nothing (no surface is mapped), runs no animation, and exists only to
# make the next press instant. That is the trade this file makes.
set -u

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
shell_dir="$(dirname "$(dirname "$(dirname "$script_path")")")"
qml_path="$shell_dir/filemanager.qml"
picker_qml_path="$shell_dir/filemanager-picker.qml"
shell="$(basename "$shell_dir")"

# ── Picker mode: its own process, no window ──────────────────────────────────
if [ "${1:-}" = "picker" ]; then
    token="${2:-}"
    if [ -z "$token" ]; then
        echo "usage: filemanager.sh picker <token>" >&2
        exit 1
    fi
          export II_FILES_PICKER="$token"
      # Its output goes to a file, not to the void: "the dialog did not appear"
      # was undiagnosable for exactly as long as this said /dev/null. The portal
      # backend already keeps the spawn's stderr next to it; this keeps the
      # DIALOG's own words, which is what says why it never mapped.
      picker_log="${XDG_RUNTIME_DIR:-/tmp}/ii-portal/picker-app.log"
      mkdir -p "${picker_log%/*}" 2>/dev/null
      exec setsid qs -p "$picker_qml_path" >>"$picker_log" 2>&1
fi

spare_log="${XDG_RUNTIME_DIR:-/tmp}/ii-${shell}-files-spare.log"
# The spare's pid, written by the spare ITSELF (see `spare` mode below). The
# alternative -- scanning /proc for a process whose environment says PRELOAD --
# worked and cost 60 ms of the press: two forks per candidate (tr + grep) over
# every qs on the machine. A press is a menu-speed gesture, so the pid is a file
# here and the /proc read is spent on ONE pid to verify it is still the spare
# (see spare_pid) instead of on all of them.
spare_file="${XDG_RUNTIME_DIR:-/tmp}/ii-${shell}-files-spare.pid"

# ── Which windows does the compositor have on screen, by pid? ────────────────
# One read, reused by everything below: it is both "what is on screen" (the
# launch check) and "which preloaded copy is still HIDDEN" (the spare list) --
# a claimed spare is a normal window whose environment still says PRELOAD, so
# the environment alone would keep counting it as available.
window_pids() {
    command -v hyprctl >/dev/null 2>&1 || return 0
    timeout 3 hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    clients = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(" ".join(str(c.get("pid")) for c in clients))'
}

# ── Is the recorded spare still a spare? ────────────────────────────────────
# A pid file on its own would be a lie after a reboot, a kill -9 or a session
# that reused the number, so the file is only a HINT: the answer comes from that
# one process's own /proc environment. II_FILES_PRELOAD says it was started as a
# spare and II_FILES_SPARE says it is THIS shell's (a second checkout, or a
# differently-named config, never claims this one's). A claimed spare keeps both
# variables for the rest of its life, which is fine: `preloadOpen` answers
# "already" for it, and the launcher's reply to that is its own window.
spare_pid() {
    local pid
    [ -r "$spare_file" ] || return 1
    pid="$(cat "$spare_file" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
        | grep -Fqx "II_FILES_PRELOAD=1" || return 1
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
        | grep -Fqx "II_FILES_SPARE=${shell_dir}" || return 1
    printf '%s\n' "$pid"
}

# ── Preload one hidden copy, at most one ────────────────────────────────────
# Detached from this script's death (setsid) and from its stdout: a spare is
# alive for as long as nobody wants it, which is usually longer than the launch
# that started it. `exec` at the end of `spare` mode is what keeps a wrapper bash
# out of the process list -- the spare IS the qs process.
# ── One spare, never two ─────────────────────────────────────────────────────
# The pid file is the fast path (that is all a press uses), and this scan is the
# BACKSTOP: after a claim that could not be confirmed, the file has been dropped
# but the process may still be alive and hidden. Spawning on top of one would
# leave two idle 130 MB copies for the rest of the session, so the backstop looks
# for a live preloaded process of this shell with no window on screen and adopts
# it -- by writing its pid back -- instead of starting another. It runs after the
# press is already answered (or on the cold path's way out), so its cost is not
# a press's cost.
spawn_spare() {
    local candidate on_screen
    [ -n "$(spare_pid)" ] && return 0
    on_screen=" $(window_pids) "
    for candidate in $(pgrep -x qs); do
        tr '\0' '\n' < "/proc/$candidate/environ" 2>/dev/null \
            | grep -Fqx "II_FILES_PRELOAD=1" || continue
        tr '\0' '\n' < "/proc/$candidate/environ" 2>/dev/null \
            | grep -Fqx "II_FILES_SPARE=${shell_dir}" || continue
        case "$on_screen" in *" $candidate "*) continue ;; esac
        printf '%s\n' "$candidate" > "$spare_file" 2>/dev/null
        return 0
    done
    II_FILES_PRELOAD=1 II_FILES_SPARE="$shell_dir" \
        setsid sh -c 'echo $$ > "$1"; exec qs -p "$2"' sh "$spare_file" "$qml_path" \
        >>"$spare_log" 2>&1 </dev/null &
    return 0
}

if [ "${1:-}" = "spare" ]; then
    if [ -n "$(spare_pid)" ]; then
        exit 0                     # idempotent: a reload must not stack one
    fi
    export II_FILES_PRELOAD=1 II_FILES_SPARE="$shell_dir"
    # `$$` is written by the process that then BECOMES qs (exec keeps the pid),
    # so the file names the qs process exactly -- no guessing, no `$!` of a
    # wrapper that has already exited.
    exec setsid sh -c 'echo $$ > "$1"; exec qs -p "$2"' sh "$spare_file" "$qml_path" \
        >>"$spare_log" 2>&1 </dev/null
fi

# ── Is this pid's WINDOW on screen? Asked of the compositor, not of the app ──
# Answering IPC and being on screen are two different moments, and this script
# used to call the first one success: in the old WINDOW form the app could map
# and then be closed a second later (its process warm, its IPC answering, its
# screen empty) in 3 of 5 launches -- "sometimes opens invisible". The
# compositor lists this instance's pid for its window, so that is what is asked,
# and nothing else. `timeout` because a wedged compositor socket must not hang a
# launcher; no hyprctl at all (another session, another compositor) leaves the
# check as it was rather than failing for a reason that has nothing to do with
# the app.
window_on_screen() {
    command -v hyprctl >/dev/null 2>&1 || return 0
    timeout 3 hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
want = int(sys.argv[1])
try:
    clients = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if any(c.get("pid") == want for c in clients) else 1)' "${1:?}" 2>/dev/null
}

# ── Optional folder argument ─────────────────────────────────────────────
# A path (or file:// URL -- that is what a freedesktop caller passes) is decoded
# and handed to the app, which starts there.
want_path=""
want_select=""
want_reveal=""
if [ "${1:-}" != "" ]; then
    want_path="$1"
    case "$want_path" in
        file://*) want_path="${want_path#file://}" ;;
    esac
    want_path="$(printf '%s' "$want_path" | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read()),end="")' 2>/dev/null || printf '%s' "$want_path")"
fi

# ── A FILE is revealed, not listed ───────────────────────────────────────────
# "Show in file manager" hands over the FILE (Brave's finished download, an
# "open containing folder" next to any item), and a file is not a folder: the
# app used to be started with that path as its folder, so the window came up
# empty -- the request looked like it did nothing. So the argument is split
# here, where it is free (`test -d` is a syscall): a folder is the start path,
# and a file's FOLDER is the start path with the file named for selection.
#
# THE SPLIT IS WHY THIS IS BASH AND NOT QML. QML cannot stat a path
# synchronously, so the question is answered once, here, before the app starts,
# and the app is only told the two answers (II_FILES_START / II_FILES_SELECT).
if [ -n "$want_path" ] && [ ! -d "$want_path" ]; then
    want_reveal="$want_path"
    want_select="$(basename -- "$want_path")"
    want_path="$(dirname -- "$want_path")"
fi

# ── THE WARM PATH: claim the spare ──────────────────────────────────────────
# `preloadOpen` maps the window and navigates it, all in the process that is
# already loaded. The answer is read, not assumed: "ok" is a spare that was
# still hidden, "already" is one a competing press claimed a moment earlier (and
# starting a second window is the correct answer there, not showing that one
# again), and no answer at all is a spare that has died since the pid was read.
#
# A file to REVEAL is handed over as its path: the app's own openPath decides
# folder-vs-file (it is the same function the desktop entry and the portal
# already drive), and doing it there keeps one implementation of "reveal" rather
# than a second one in bash that has to agree about selection.
warm_claim() {
    local pid answer
    pid="$(spare_pid)"
    [ -n "$pid" ] || return 1
    if [ -n "$want_reveal" ]; then
        answer="$(qs ipc --pid "$pid" call files preloadOpen "$want_reveal" 2>/dev/null)" || return 1
    else
        answer="$(qs ipc --pid "$pid" call files preloadOpen "${want_path:--}" 2>/dev/null)" || return 1
    fi
    if [ "$answer" != "ok" ]; then
        # Not a spare any more (a competing press claimed it), or the pid file
        # outlived the process it named. Either way this file no longer
        # describes a hidden copy, and leaving it would make every future spawn
        # think one already exists.
        rm -f "$spare_file"
        return 1
    fi
    # Consumed: from here on this process is an ordinary Files window, and the
    # replacement spare is the spawn below. Dropping the file is what says so.
    rm -f "$spare_file"
    # The map is the only thing left to wait for, and it is short: a second (50 x
    # 20 ms) is already generous for a constructed window, and it is bounded so a
    # spare that answers but never maps falls through to a cold start instead of
    # hanging the key.
    for _ in $(seq 1 50); do
        window_on_screen "$pid" && return 0
        sleep 0.02
    done
    return 1
}

if warm_claim; then
    # Replace what was just used, in the background: the press is already
    # answered, and the next one has to be instant too.
    spawn_spare
    exit 0
fi

# ── The cold path: nothing warm to claim ────────────────────────────────────
# Its output goes to a log rather than to the void, so a failed launch can say
# WHY: the last line the app printed is the sentence that explains the failure,
# and "Couldn't open Files" on its own explains nothing.
applog="${XDG_RUNTIME_DIR:-/tmp}/ii-${shell}-files-app.log"
: >"$applog" 2>/dev/null || applog="/dev/null"

if [ -n "$want_path" ]; then
    export II_FILES_START="$want_path"
fi
if [ -n "$want_select" ]; then
    export II_FILES_SELECT="$want_select"
fi
# The tag is what makes "the instance THIS launch started" answerable. Two
# launches run at once on purpose now, so "a Files window is on screen" would
# happily be the OTHER launch's window -- and a launch that quietly died while
# an older copy was up would read as a success. The app ignores the variable;
# it is here so the loop below can find its own process in /proc.
launch_tag="$$-$(date +%s%N)"
export II_FILES_LAUNCH_TAG="$launch_tag"

# ── "Opening Files" while the window is coming up ───────────────────────────
# The main shell owns the island row and the bar line; this script owns the
# wait. `display` takes the window baseline BEFORE the new instance exists, so
# its window is what the watcher sees as new and dismisses the wait the moment
# it is on screen. A launch that fails ends the wait with `fail` in the
# branches below (which now also pulses the thin whole-screen red border).
# Picker mode never reaches this line -- it exec'd away at the top, and so does
# the warm path: a map does not need to be announced.
qs -c "$shell" ipc call loading display "Files" >/dev/null 2>&1 || true

setsid qs -p "$qml_path" >"$applog" 2>&1 &

# Wait for it to answer AND for its window to appear. The end of the wait is "a
# window is on screen", "its process is gone" or "it has been alive without
# answering for a minute" -- not a flat twelve seconds, which used to declare a
# failure while a cold instance was still loading ("sometimes apps can't be
# opened").
listening() {
    [ -n "${1:-}" ] && qs ipc --pid "$1" call files ping >/dev/null 2>&1
}

launched_pid() {
    local candidate
    for candidate in $(pgrep -x qs); do
        tr '\0' '\n' < "/proc/$candidate/environ" 2>/dev/null \
            | grep -q "^II_FILES_LAUNCH_TAG=${launch_tag}$" || continue
        printf '%s\n' "$candidate"
        return
    done
}

seen_pid=""
nothing_on_screen=""
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
    pid="$(launched_pid)"
    [ -n "$pid" ] && seen_pid="$pid"
    if [ -n "$pid" ] && listening "$pid"; then
        # A cold start of this app is about a second; the window comes up with
        # it. The wait here is for the app whose QML is ready ahead of its first
        # frame, and it is bounded so that "answers but draws nothing" is
        # reported instead of waited on forever.
        for _ in $(seq 1 25); do
            window_on_screen "$pid" && { spawn_spare; exit 0; }
            sleep 0.2
        done
        nothing_on_screen="$pid"
        break
    fi
    if [ -n "$seen_pid" ] && [ -z "$pid" ]; then
        sleep 0.3          # let the app's final line reach the log
        break
    fi
done

if [ -n "$nothing_on_screen" ]; then
    qs -c "$shell" ipc call loading fail "Couldn't open Files (it started, but nothing came on screen)" >/dev/null 2>&1
    exit 1
fi

reason="$(tail -n 5 "$applog" 2>/dev/null | tr -d '\r' \
    | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-140)"
if [ -n "$reason" ]; then
    qs -c "$shell" ipc call loading fail "Couldn't open Files (exited: ${reason})" >/dev/null 2>&1
    exit 1
fi
qs -c "$shell" ipc call loading fail "Couldn't open Files (no answer in 60s)" >/dev/null 2>&1
exit 1
