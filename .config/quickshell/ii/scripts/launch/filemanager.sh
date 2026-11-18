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

# ── The warm copy ───────────────────────────────────────────────────────────
# The pid file, the /proc verification of it, the backstop that adopts a hidden
# copy instead of stacking a second one, and the claim itself all live in one
# shared file now (warm.sh), because Files, Text Editor and Settings use the same
# mechanism and one copy of that reasoning is worth more than three that agree
# until one of them is edited. Same file names it had before, so a spare that is
# already running is still found.
source "$shell_dir/scripts/launch/warm.sh"
warm_setup "$shell_dir" files "$qml_path"

if [ "${1:-}" = "spare" ]; then
    # Idempotent (a config reload must not stack one), and it `exec`s, so the pid
    # the spare writes is the qs process's own.
    warm_exec_spare
fi

# `warm_on_screen` (warm.sh) is the compositor check this script used to keep
# here: answering IPC and being on screen are two different moments, and a
# launcher that called the first one success reported "opened" over an empty
# screen ("sometimes opens invisible", 3 of 5 launches in the old window form).

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
# already loaded. warm_claim reads the answer instead of assuming it: "ok" is a
# spare that was still hidden, "already" is one a competing press claimed a
# moment earlier (and starting a second window is the correct answer there, not
# showing that one again), and no answer at all is a spare that has died since
# the pid was read.
#
# A file to REVEAL is handed over as its path: the app's own openPath decides
# folder-vs-file (it is the same function the desktop entry and the portal
# already drive), and doing it there keeps one implementation of "reveal" rather
# than a second one in bash that has to agree about selection.
claim_status=1
if [ -n "$want_reveal" ]; then
    warm_claim preloadOpen "$want_reveal" && claim_status=0
else
    warm_claim preloadOpen "${want_path:--}" && claim_status=0
fi
if [ "$claim_status" -eq 0 ]; then
    # Replace what was just used, in the background: the press is already
    # answered, and the next one has to be instant too.
    warm_spawn
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
            warm_on_screen "$pid" && { warm_spawn; exit 0; }
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
