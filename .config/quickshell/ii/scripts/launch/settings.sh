#!/usr/bin/env bash
# Open the settings app -- or, when a copy of it is already open, walk that copy
# to the page you asked for.
#
#   settings.sh                     the app, wherever it was left
#   settings.sh network wifi        the app, on Settings > Network > Wi-Fi
#   settings.sh network bluetooth   the app, on Settings > Network > Bluetooth
#
# Every caller goes through here: the bar's Wi-Fi and Bluetooth icons, the
# overview's and the sidebars' Settings buttons, the launcher entry, and the
# SUPER + Escape keybind. "Open the settings app" used to mean "start another copy
# of it", so clicking the Wi-Fi icon and then the Bluetooth icon left two settings
# windows stacked on each other -- and no way to get back to one.
#
# A copy that is already open takes the request over IPC: it switches to the page
# (and the tab within it) and stays the only copy. Starting a second copy is then
# only what happens when there is nothing to ask.
#
# The copy is addressed by PID, not by config: the desktop shell and the settings
# app are two Quickshell instances of the same configuration directory
# (`qs -c ii` and `qs -p .../settings.qml`), so asking for "the ii instance" is
# ambiguous and could land on the shell, which has no `settings` target at all --
# and a call that fails to land looks exactly like "nothing is running", i.e. the
# duplicate this script exists to prevent.
set -u

# Resolved from this script's own location (`<config>/scripts/launch/settings.sh`)
# rather than from an environment variable, so it works no matter who calls it:
# the shell, Hyprland, or a terminal.
script_path="$(readlink -f "${BASH_SOURCE[0]}")"
shell_dir="$(dirname "$(dirname "$(dirname "$script_path")")")"
qml_path="$shell_dir/settings.qml"
shell="$(basename "$shell_dir")"

page="${1:-}"
section="${2:-}"

settings_pids() {
    # `qs` by process name first, then by command line: matching on the command
    # line alone also matches a shell whose arguments happen to mention the path
    # (this script, a grep, the editor that is looking at it), and answering with
    # one of those looks exactly like a call that landed on nothing.
    for pid in $(pgrep -x qs); do
        if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "settings\.qml"; then
            printf '%s\n' "$pid"
        fi
    done
}

settings_pid() {
    settings_pids | head -1
}

listening() {
    # Answers only once the app's IPC is up, which is the honest "there is an app
    # here I can talk to" test -- a process existing is not the same thing.
    [ -n "${1:-}" ] && qs ipc --pid "$1" call settings ping >/dev/null 2>&1
}

answer() {
    # Nothing is being waited for any more, so let the shell's "starting" card go
    # if something raised one (the launcher entry does). Harmless when nothing did.
    qs -c "$shell" ipc call loading dismiss >/dev/null 2>&1
}

# ── One launch at a time ──────────────────────────────────────────────────────
# Two clicks landing close together -- Wi-Fi, then Bluetooth -- used to be able to
# leave two copies: the second call found a process that existed but was not
# listening yet, and "found but not listening" was treated as "nothing is
# running", so it started its own. The lock makes the second call wait for the
# first to finish starting; it then finds an app it can talk to and just walks it
# to its page, which is what the caller meant either way.
#
# The lock is taken by re-running this script under `flock`, not by locking a file
# descriptor here: the app is started from inside this script and a child inherits
# open file descriptors -- including a lock's, which would then be held for as
# long as the app runs, so every later click would queue behind it. `flock -o`
# closes the lock before running the command, so nothing started here can hold it.
#
# If the lock is already held when we arrive, the work is done without it. Whoever
# holds it is doing the same job as this script, and a click that lands while
# something is wedged should open the app late rather than never.
lock_dir="${XDG_RUNTIME_DIR:-/tmp}/quickshell-${shell}"
if [ -z "${SETTINGS_LAUNCH_LOCKED:-}" ] && command -v flock >/dev/null 2>&1; then
    mkdir -p "$lock_dir" 2>/dev/null
    if flock -n "$lock_dir/settings-launch.lock" true 2>/dev/null; then
        SETTINGS_LAUNCH_LOCKED=1 exec flock -o -w 20 "$lock_dir/settings-launch.lock" \
            bash "$script_path" "$@"
    fi
    SETTINGS_LAUNCH_LOCKED=1
fi

pid="$(settings_pid)"
if [ -n "$pid" ]; then
    if qs ipc --pid "$pid" call settings open "$page" "$section" >/dev/null 2>&1; then
        answer
        exit 0
    fi

    # There is a process, but it is not answering. Usually that is a copy started by
    # hand -- the lock only serializes this script -- which is still loading, so give
    # it a moment and try again, following a newer pid if one appears.
    for _ in $(seq 1 30); do
        sleep 0.1
        newer="$(settings_pid)"
        [ -n "$newer" ] && pid="$newer"
        if listening "$pid"; then
            qs ipc --pid "$pid" call settings open "$page" "$section" >/dev/null 2>&1
            answer
            exit 0
        fi
    done

    # Still silent after three seconds. That is an app from a build that cannot be
    # talked to -- the floating-window version had no `settings` target at all, so
    # clicking the Wi-Fi icon put another one on screen every time -- or one that
    # wedged while loading. Leaving it in place is exactly how a desktop ends up
    # with several settings apps at once, so it is replaced rather than stacked on:
    # asked to quit first, so it can take its own child processes with it, and only
    # killed if that does not take.
    for stale in $(settings_pids); do
        # `quit` takes a mode and has no default: called bare it fails with
        # "Too few arguments" and the stale copy is left running (which is how
        # duplicate settings instances stacked up). "in" = the plain close.
        qs ipc --pid "$stale" call settings quit in >/dev/null 2>&1
    done
    sleep 0.5
    for stale in $(settings_pids); do
        pkill -P "$stale" 2>/dev/null
        kill "$stale" 2>/dev/null
    done
    sleep 0.4
fi

# Nothing is listening: start it. Detached, so it outlives a shell reload, and on
# the page that was asked for -- the app reads these two as its opening position
# (services/SettingsNav.qml).
#
# Its output goes to a log rather than to the void, because a launch that fails
# has to be able to say WHY. "Couldn't open the settings app" on its own leaves
# the user with nothing to act on, while the app's own last line -- a QML type
# that would not resolve, a page that threw on load, "cannot open display" -- is
# the actual answer. Truncated per launch, so what the card quotes is from THIS
# run and not the one before it.
applog="${XDG_RUNTIME_DIR:-/tmp}/ii-${shell}-settings-app.log"
: >"$applog" 2>/dev/null || applog="/dev/null"

setsid env QS_SETTINGS_PAGE="$page" QS_SETTINGS_SECTION="$section" \
    qs -p "$qml_path" >"$applog" 2>&1 &

# Then wait for it to answer, because a window the compositor is still placing
# is not something the shell notices on its own, and a launch that never
# arrives would otherwise leave a click that did nothing at all.
#
# The wait ends one of three ways, and only one of them is a failure:
#
#   * it answers                     -- opened (up in well under a second here)
#   * the process is GONE            -- it is not coming, and the log says why
#   * still alive after a full minute -- wedged, and that is the reason
#
# It used to end after twelve seconds flat and call the app broken, which is the
# "sometimes apps can't be opened" report: this app is a whole second Quickshell
# instance, and on a loaded machine it can still be loading at twelve seconds --
# at which point the script reported a failure and the app appeared a moment
# later anyway. A process that is alive is a launch in progress, so the clock
# here is only ever about a process that has stopped making progress.
seen_pid=""
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
    pid="$(settings_pid)"
    [ -n "$pid" ] && seen_pid="$pid"
    if listening "$pid"; then
        answer
        if [ -n "$page" ]; then
            qs ipc --pid "$pid" call settings open "$page" "$section" >/dev/null 2>&1
        fi
        exit 0
    fi
    # A process that APPEARED and then went away is the failure; "no pid yet"
    # is not one (qs takes a moment to reach the process table).
    if [ -n "$seen_pid" ] && [ -z "$pid" ]; then
        sleep 0.3          # let the app's final line reach the log
        break
    fi
done

reason="$(tail -n 5 "$applog" 2>/dev/null | tr -d '\r' \
    | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-140)"
if [ -n "$reason" ]; then
    qs -c "$shell" ipc call loading fail "Couldn't open the settings app (exited: ${reason})" >/dev/null 2>&1
    exit 1
fi
qs -c "$shell" ipc call loading fail "Couldn't open the settings app (no answer in 60s)" >/dev/null 2>&1
exit 1
