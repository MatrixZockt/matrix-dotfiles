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
#   filemanager.sh picker <token>  the portal's FileChooser dialog: a DEDICATED
#                                  transient instance (never the app) that reads
#                                  II_FILES_PICKER, shows the dialog, writes its
#                                  result and quits. A DIALOG has to be a layer
#                                  surface to sit above the app that asked for
#                                  it, so it is a separate QML file.
#
# ── Every launch is a NEW WINDOW (2026-10-14, requested) ─────────────────────
# This script used to be single-instance: it looked for a running copy, pressed
# it over IPC and started one only when there was nothing to press. Files is an
# ordinary window now, and the request that came with it was explicit -- "make
# sure I can open multiple and it doesn't switch to the already open file
# manager" -- so all of that is gone: no instance lookup, no `files open`/`files
# toggle` press, no stale-copy replacement, and no launch lock (the lock existed
# so two launches could not both decide to start one; two launches now both
# start one, which is the point).
#
# What that costs, in return for the request: a launch is a cold start (~1s),
# where pressing a warm copy used to be ~50ms. What it buys: a second SUPER + E
# on a Files window you are working in gives you a second Files instead of
# throwing you out of the first.
#
# The `close` verb went with the raising: it was how the bar's own menus told
# the single popup to stand down (they shared one focus grab). A window does not
# compete with a menu for the session's input -- it sits behind it like any other
# window and is there when the menu closes -- so BarAnchoredPanel no longer calls
# it and nothing else ever did.
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
    exec setsid qs -p "$picker_qml_path" >/dev/null 2>&1
fi

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
# Picker mode never reaches this line -- it exec'd away at the top.
qs -c "$shell" ipc call loading display "Files" >/dev/null 2>&1 || true

setsid qs -p "$qml_path" >"$applog" 2>&1 &

# ── Is the WINDOW on screen? Asked of the compositor, not of the app ─────────
# Answering IPC and being on screen are two different moments, and this script
# used to call the first one success: in the old WINDOW form the app could map
# and then be closed a second later (its process warm, its IPC answering, its
# screen empty) in 3 of 5 launches -- "sometimes opens invisible" -- and in the
# POPUP form it answered IPC from a hidden surface by design, so "it answers"
# was never the question. The compositor lists this instance's pid for its
# window, so that is what is asked, and nothing else. `timeout` because a wedged
# compositor socket must not hang a launcher; no hyprctl at all (another session,
# another compositor) leaves the check as it was rather than failing for a reason
# that has nothing to do with the app.
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
            window_on_screen "$pid" && exit 0
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
