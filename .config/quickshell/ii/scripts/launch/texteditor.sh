#!/usr/bin/env bash
# Open the Text Editor -- the desktop's plain-text editor (Notepad's job).
#
#   texteditor.sh                  a new, empty document
#   texteditor.sh <path>           a new window with that file in it (the path
#                                  may be a file:// URL: that is what a
#                                  .desktop Exec and the portal pass)
#
# Every launch is a NEW WINDOW and a NEW process, exactly like Files, so the
# editor has ordinary window behaviour: two documents side by side are two
# windows, SUPER+Q closes the one you are in, and the compositor can tile them.
# There is no instance lookup and no IPC press for that reason -- but there IS a
# warm copy, for the same reason Files has one: a cold editor cost 816-1376 ms on
# this machine, nearly all of it its own QML. warm.sh keeps one constructed,
# never-shown copy and this claims it (a map, not a load), then preloads the next
# one. A spare that is never claimed quits after half an hour (the Timer in
# texteditor.qml), so an editor you are not using costs nothing.
#
# The editor is started detached from whoever called (a file manager, a browser
# download, a terminal), because closing the caller must not close the document.
set -u

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
shell_dir="$(dirname "$(dirname "$(dirname "$script_path")")")"
qml_path="$shell_dir/texteditor.qml"
shell="$(basename "$shell_dir")"

source "$shell_dir/scripts/launch/warm.sh"
warm_setup "$shell_dir" editor "$qml_path"

# ── Optional file argument ───────────────────────────────────────────────────
# A file:// URI is decoded first (`%20`, and non-ASCII percent-encoded bytes),
# which is how every freedesktop caller spells a path.
want="${1:-}"
case "$want" in
    file://*) want="${want#file://}" ;;
esac
if [ -n "$want" ]; then
    want="$(printf '%s' "$want" | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read()),end="")' 2>/dev/null || printf '%s' "$want")"
fi

# ── The warm path ──────────────────────────────────────────────────────────
# `preloadOpen` maps the spare and loads the file into it, all in the process
# that is already constructed. "-" is "no file, a new empty document": an empty
# argument is not something the ipc CLI carries reliably.
#
# On success the window is a WINDOW of this launch like any other (SUPER+Q, the
# tiler, its own pid); the replacement spare is started in the background as the
# launch answers, so the next one is instant too. A claim that fails (no spare,
# a competing launch took it, it died) falls through to the cold path below.
if warm_claim preloadOpen "${want:--}"; then
    warm_spawn
    exit 0
fi

# Its output goes to a log rather than to the void, so a failed launch can say
# WHY: the last line the app printed is the sentence that explains the failure.
applog="${XDG_RUNTIME_DIR:-/tmp}/ii-${shell}-editor.log"
: >"$applog" 2>/dev/null || applog="/dev/null"

if [ -n "$want" ]; then
    export II_EDITOR_FILE="$want"
fi

# The tag makes "the instance THIS launch started" answerable when a second
# editor is already up: its pid is found in /proc by its environment, never by
# process name (which would find the other window).
launch_tag="$$-$(date +%s%N)"
export II_EDITOR_LAUNCH_TAG="$launch_tag"

# The wait row is the main shell's (a different qs process); `display` arms it
# and the shell's own window watcher dismisses it when the new window maps.
qs -c "$shell" ipc call loading display "Text Editor" >/dev/null 2>&1 || true

setsid qs -p "$qml_path" >"$applog" 2>&1 &

launched_pid() {
    local candidate
    for candidate in $(pgrep -x qs); do
        tr '\0' '\n' < "/proc/$candidate/environ" 2>/dev/null \
            | grep -q "^II_EDITOR_LAUNCH_TAG=${launch_tag}$" || continue
        printf '%s\n' "$candidate"
        return
    done
}

listening() {
    [ -n "${1:-}" ] && qs ipc --pid "$1" call editor ping >/dev/null 2>&1
}

seen_pid=""
nothing_on_screen=""
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
    pid="$(launched_pid)"
    [ -n "$pid" ] && seen_pid="$pid"
    if [ -n "$pid" ] && listening "$pid"; then
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
    qs -c "$shell" ipc call loading fail "Couldn't open Text Editor (it started, but nothing came on screen)" >/dev/null 2>&1
    exit 1
fi

reason="$(tail -n 5 "$applog" 2>/dev/null | tr -d '\r' \
    | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-140)"
if [ -n "$reason" ]; then
    qs -c "$shell" ipc call loading fail "Couldn't open Text Editor (exited: ${reason})" >/dev/null 2>&1
    exit 1
fi
qs -c "$shell" ipc call loading fail "Couldn't open Text Editor (no answer in 60s)" >/dev/null 2>&1
exit 1
