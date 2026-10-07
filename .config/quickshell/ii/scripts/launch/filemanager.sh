#!/usr/bin/env bash
# Open the Files app (the QML file manager popup), single-instance like
# settings.sh: a copy that is already running is just raised (the IPC `open`
# makes its layer visible again), otherwise one is started.
#
#   filemanager.sh                 the Files popup (single instance)
#   filemanager.sh picker <token>  the portal's FileChooser dialog: a
#                                  DEDICATED transient instance (never the
#                                  popup) that reads II_FILES_PICKER, shows
#                                  the compact dialog, writes its result and
#                                  quits by itself.
set -u

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
shell_dir="$(dirname "$(dirname "$(dirname "$script_path")")")"
qml_path="$shell_dir/filemanager.qml"
shell="$(basename "$shell_dir")"

# ── Picker mode: its own process, no lock, no raise ──────────────────────────
if [ "${1:-}" = "picker" ]; then
    token="${2:-}"
    if [ -z "$token" ]; then
        echo "usage: filemanager.sh picker <token>" >&2
        exit 1
    fi
    export II_FILES_PICKER="$token"
    exec setsid qs -p "$qml_path" >/dev/null 2>&1
fi

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
        FM_LAUNCH_LOCKED=1 exec flock -o -w 20 "$lock_dir/fm-launch.lock" \
            bash "$script_path"
    fi
    FM_LAUNCH_LOCKED=1
fi

pid="$(fm_pid)"
if [ -n "$pid" ]; then
    if listening "$pid"; then
        qs ipc --pid "$pid" call files open >/dev/null 2>&1
        exit 0
    fi
    for _ in $(seq 1 30); do
        sleep 0.1
        newer="$(fm_pid)"
        [ -n "$newer" ] && pid="$newer"
        if listening "$pid"; then
            qs ipc --pid "$pid" call files open >/dev/null 2>&1
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

setsid qs -p "$qml_path" >/dev/null 2>&1 &

for _ in $(seq 1 120); do
    sleep 0.1
    pid="$(fm_pid)"
    if listening "$pid"; then
        python3 ~/.config/hypr/custom/scripts/hypr-idle-options.py popup-blur-on \
            >/dev/null 2>&1 || true
        exit 0
    fi
done

qs -c "$shell" ipc call loading fail "Couldn't open Files" >/dev/null 2>&1
exit 1
