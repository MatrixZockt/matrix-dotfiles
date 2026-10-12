#!/usr/bin/env bash
# Open the Files app (the QML file manager popup), single-instance like
# settings.sh: a copy that is already running is just raised (the IPC `open`
# makes its layer visible again), otherwise one is started.
#
#   filemanager.sh                 the Files app (single instance)
#   filemanager.sh <path>          the Files app, opened AT that folder -- or
#                                  AT the folder of that file with the file's
#                                  row selected (what the desktop entry's Exec
#                                  passes when a folder is double-clicked, and
#                                  what the FileManager1 service passes when
#                                  another app asks for "show in file manager")
#   filemanager.sh picker <token>  the portal's FileChooser dialog: a
#                                  DEDICATED transient instance (never the
#                                  app) that reads II_FILES_PICKER, shows the
#                                  dialog, writes its result and quits. A
#                                  DIALOG has to be a layer surface to sit
#                                  above the app that asked for it, so it is a
#                                  separate QML file.
set -u

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
shell_dir="$(dirname "$(dirname "$(dirname "$script_path")")")"
qml_path="$shell_dir/filemanager.qml"
picker_qml_path="$shell_dir/filemanager-picker.qml"
shell="$(basename "$shell_dir")"

# ── Picker mode: its own process, no lock, no raise ──────────────────────────
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
# A path (or file:// URL -- that is what a freedesktop caller passes) is kept
# and handed to whichever becomes the one instance: an already-open Files is
# asked to walk there, a new one starts there.
want_path=""
want_select=""
want_reveal=""
if [ "${1:-}" != "" ] && [ "${1:-}" != "picker" ]; then
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
# THE SPLIT IS WHY THIS IS BASH AND NOT QML. The shell that the app is handed
# the same way over its `openPath` IPC answers the question itself (it has a
# process to ask); at startup there is no process yet, and QML cannot stat a
# path synchronously -- so the question is answered once, here, and the app is
# only told the two answers.
if [ -n "$want_path" ] && [ ! -d "$want_path" ]; then
    want_reveal="$want_path"
    want_select="$(basename -- "$want_path")"
    want_path="$(dirname -- "$want_path")"
fi

# Ask a running copy to show itself -- at the folder when one was named.
raise_files() {
    # A FILE is sent over IPC as itself, not as the split pair: the running
    # app answers "this file" with its own openPath (the folder, then the row),
    # and the pair above exists only because a path that cannot be stat'ed
    # before the app starts has to be resolved by something that can. Sending
    # the folder here would raise the window and stop there -- the file the
    # caller asked for would simply not be selected.
    if [ -n "$want_reveal" ]; then
        qs ipc --pid "$1" call files openPath "$want_reveal" >/dev/null 2>&1
    elif [ -n "$want_path" ]; then
        qs ipc --pid "$1" call files openPath "$want_path" >/dev/null 2>&1
    else
        qs ipc --pid "$1" call files open >/dev/null 2>&1
    fi
}

fm_pids() {
    for pid in $(pgrep -x qs); do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "filemanager\\.qml" || continue
        # A picker instance is a transient portal dialog, not the Files popup.
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^II_FILES_PICKER=' && continue
        printf '%s\n' "$pid"
    done
}
fm_pid() { fm_pids | head -1; }

listening() {
    [ -n "${1:-}" ] && qs ipc --pid "$1" call files ping >/dev/null 2>&1
}

lock_dir="${XDG_RUNTIME_DIR:-/tmp}/quickshell-${shell}"
if [ -z "${FM_LAUNCH_LOCKED:-}" ] && command -v flock >/dev/null 2>&1; then
    mkdir -p "$lock_dir" 2>/dev/null
    if flock -n "$lock_dir/fm-launch.lock" true 2>/dev/null; then
        # "$@" matters: the wait below is the same launch, and a folder
        # argument that did not survive it would open the wrong place.
        FM_LAUNCH_LOCKED=1 exec flock -o -w 20 "$lock_dir/fm-launch.lock" \
            bash "$script_path" "$@"
    fi
    FM_LAUNCH_LOCKED=1
fi

pid="$(fm_pid)"
if [ -n "$pid" ]; then
    if listening "$pid"; then
        raise_files "$pid"
        exit 0
    fi
    for _ in $(seq 1 30); do
        sleep 0.1
        newer="$(fm_pid)"
        [ -n "$newer" ] && pid="$newer"
        if listening "$pid"; then
            raise_files "$pid"
            exit 0
        fi
    done
    # Stale copy: replace it.
    for stale in $(fm_pids); do
        qs ipc --pid "$stale" call files quit in >/dev/null 2>&1
    done
    sleep 0.5
    for stale in $(fm_pids); do
        pkill -P "$stale" 2>/dev/null
        kill "$stale" 2>/dev/null
    done
    sleep 0.4
fi

# Its output goes to a log rather than to the void, so a failed launch can say
# WHY the way open.sh does: the last line the app printed is the sentence that
# explains the failure, and "Couldn't open Files" on its own explains nothing.
applog="${XDG_RUNTIME_DIR:-/tmp}/ii-${shell}-files-app.log"
# The app is an ordinary window now, so there is no popup veil to frost and no
# presence file to publish: the compositor treats it like any other app.
: >"$applog" 2>/dev/null || applog="/dev/null"

if [ -n "$want_path" ]; then
    export II_FILES_START="$want_path"
fi
if [ -n "$want_select" ]; then
    export II_FILES_SELECT="$want_select"
fi

setsid qs -p "$qml_path" >"$applog" 2>&1 &

# Wait for it to answer. The end of the wait is "it answered", "its process is
# gone" or "it has been alive without answering for a minute" -- not a flat
# twelve seconds, which used to declare a failure while a cold instance was
# still loading and is the "sometimes apps can't be opened" report.
seen_pid=""
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
    pid="$(fm_pid)"
    [ -n "$pid" ] && seen_pid="$pid"
    if listening "$pid"; then
        exit 0
    fi
    if [ -n "$seen_pid" ] && [ -z "$pid" ]; then
        sleep 0.3          # let the app's final line reach the log
        break
    fi
done

reason="$(tail -n 5 "$applog" 2>/dev/null | tr -d '\r' \
    | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-140)"
if [ -n "$reason" ]; then
    qs -c "$shell" ipc call loading fail "Couldn't open Files (exited: ${reason})" >/dev/null 2>&1
    exit 1
fi
qs -c "$shell" ipc call loading fail "Couldn't open Files (no answer in 60s)" >/dev/null 2>&1
exit 1
