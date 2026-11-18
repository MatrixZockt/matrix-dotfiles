#!/usr/bin/env bash
# The shared half of "keep one copy of this app warm, so opening it is a MAP".
#
# WHY THIS EXISTS. Every app in this suite is its own `qs -p <app>.qml` process,
# and what a launch costs is not the `qs` binary (~50 ms) but that process's own
# QML: the theme singletons, the services, the first data read. Measured on this
# machine, cold to a window:
#
#   Files        ~1.8-2.0 s   (14 000 lines of FileManagerContent)
#   Text Editor  ~0.8-1.4 s
#   Settings     ~1.0 s
#
# None of that can be shaved by a flag; it has to be paid, or paid EARLY while
# nobody is waiting. So the launcher keeps one fully constructed copy alive with
# its window never mapped (`II_<APP>_PRELOAD=1` -> the app's `visible: false`),
# and a launch CLAIMS it over IPC: the app maps the window in the process that is
# already loaded. A replacement spare is started as the press is answered, so the
# next press is instant too.
#
# WHAT THIS KEEPS. Every launch of Files and Text Editor is still a NEW window
# (requested): the spare has never been on screen, so claiming it is not raising
# a window somebody is using. Nothing here looks for a window the user has; only
# for one that has never been shown. `preloadOpen` answering anything other than
# "ok" is the one case where the copy found was not a spare any more, and the
# launcher's answer there is to start its own window rather than steal that one.
#
# WHAT IT COSTS. One idle process per warm app: no surface mapped, no animation,
# ~90 MB RSS, 0 % CPU. The apps' own idle timers bound it further: a spare that
# nobody claims quits after half an hour (see the Timer in texteditor.qml and
# settings.qml), so a session that stops using an app stops paying for it. Files
# is the exception, on purpose: it is preloaded at login and stays warm, because
# "SUPER + E is instant" was the request that started all of this.
#
# API (source this file, then):
#
#   warm_setup <shell_dir> <app> <qml_path>
#       `app` is BOTH the IPC target the spare answers on (files/editor/settings)
#       and the env-tag stem (II_FILES_PRELOAD, II_EDITOR_SPARE, ...).
#   warm_pid            the live spare of THIS shell+app, or a failed exit
#   warm_spawn          make sure one exists (idempotent, never two)
#   warm_exec_spare     become the spare (for `filemanager.sh spare` at login)
#   warm_claim <verb> [args...]   claim it; 0 = a window is on screen now
#   warm_on_screen <pid>          does this pid have a window in `hyprctl clients`
#   warm_window_pids              every pid the compositor has a window for
#
# Deliberately no `set -e`: this file is sourced by launchers that handle their
# own failures, and a test whose whole meaning is "did it fail" must not abort.

# ── Resolve this app's names ────────────────────────────────────────────────
warm_setup() {
    warm_shell_dir="$(readlink -f "${1:?warm_setup: shell dir}")"
    warm_app="${2:?warm_setup: app}"
    warm_qml="${3:?warm_setup: qml path}"
    warm_shell="$(basename "$warm_shell_dir")"
    warm_prefix="II_$(printf '%s' "$warm_app" | tr '[:lower:]' '[:upper:]')"
    local runtime="${XDG_RUNTIME_DIR:-/tmp}"
    # Same names the Files launcher used before this was shared, so an existing
    # spare is still found after an update.
    warm_pid_file="$runtime/ii-${warm_shell}-${warm_app}-spare.pid"
    warm_log="$runtime/ii-${warm_shell}-${warm_app}-spare.log"
}

# ── Which windows does the compositor have on screen, by pid? ───────────────
# One read, reused: it is both "what is on screen" and "is this preloaded copy
# still HIDDEN" -- a claimed spare is a normal window whose environment still
# says PRELOAD, so the environment alone would keep counting it as available.
warm_window_pids() {
    command -v hyprctl >/dev/null 2>&1 || return 0
    timeout 3 hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    clients = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(" ".join(str(c.get("pid")) for c in clients))'
}

# ── Is this pid's WINDOW on screen? ────────────────────────────────────────
# Asked of the compositor, not of the app: answering IPC and being on screen are
# two different moments, and a launcher that called the first one success
# reported "opened" over an empty screen. `timeout` because a wedged compositor
# socket must not hang a launcher; no hyprctl at all (another session, another
# compositor) leaves the answer to the app rather than failing for a reason that
# has nothing to do with it.
warm_on_screen() {
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

# ── Is this process a spare of THIS shell and app? ─────────────────────────
# Two tags, both required: II_<APP>_PRELOAD says it was started as a spare, and
# II_<APP>_SPARE says it is THIS config directory's (a second checkout, or a
# differently-named config, can never claim this one's). A claimed spare keeps
# both for the rest of its life, which is fine -- the app answers "already".
warm_is_spare() {
    local pid="${1:-}" env
    [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
    env="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null)" || return 1
    printf '%s\n' "$env" | grep -Fqx "${warm_prefix}_PRELOAD=1" || return 1
    printf '%s\n' "$env" | grep -Fqx "${warm_prefix}_SPARE=${warm_shell_dir}" || return 1
}

# ── Is the recorded spare still a spare? ───────────────────────────────────
# A pid file on its own is a lie after a reboot, a kill -9, a session that reused
# the number, or the app's own idle timer quitting the spare, so the file is only
# a HINT: the answer comes from that one process's own /proc environment. Reading
# one pid is why this is a file and not a scan -- a scan of every `qs` on the
# machine cost 60 ms of a keypress.
warm_pid() {
    local pid
    [ -r "$warm_pid_file" ] || return 1
    pid="$(cat "$warm_pid_file" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    warm_is_spare "$pid" || return 1
    printf '%s\n' "$pid"
}

# ── Start one spare (unless one already exists, or one is alive and hidden) ──
# The pid file is the fast path; the /proc scan below is the BACKSTOP, for the
# case a claim could not be confirmed: the file has been dropped but the process
# may still be alive and hidden, and spawning on top of it would leave two idle
# copies for the rest of the session. So a live, windowless preload is ADOPTED
# (its pid written back) instead of a second one being started. It runs after the
# press is already answered, so its cost is never a press's cost.
#
# `setsid` detaches it from this script's death and its stdout, and `echo $$ >
# $file; exec qs` is what makes the file name the qs process exactly (exec keeps
# the pid, so there is no wrapper's `$!` to get wrong).
warm_spawn() {
    local candidate on_screen
    [ -n "$(warm_pid)" ] && return 0
    on_screen=" $(warm_window_pids) "
    for candidate in $(pgrep -x qs); do
        warm_is_spare "$candidate" || continue
        case "$on_screen" in *" $candidate "*) continue ;; esac
        printf '%s\n' "$candidate" >"$warm_pid_file" 2>/dev/null
        return 0
    done
    env "${warm_prefix}_PRELOAD=1" "${warm_prefix}_SPARE=$warm_shell_dir" \
        setsid sh -c 'echo $$ > "$1"; exec qs -p "$2"' sh "$warm_pid_file" "$warm_qml" \
        >>"$warm_log" 2>&1 </dev/null &
    return 0
}

# ── Become the spare (autostart: `filemanager.sh spare`) ───────────────────
# Idempotent: a config reload must not stack a second copy.
warm_exec_spare() {
    [ -n "$(warm_pid)" ] && exit 0
    export "${warm_prefix}_PRELOAD=1" "${warm_prefix}_SPARE=$warm_shell_dir"
    exec setsid sh -c 'echo $$ > "$1"; exec qs -p "$2"' sh "$warm_pid_file" "$warm_qml" \
        >>"$warm_log" 2>&1 </dev/null
}

# ── Claim the spare: the press is a MAP, not a LOAD ────────────────────────
# The answer is read, not assumed:
#   "ok"       a spare that was still hidden -- now a normal window
#   "already"  one a competing press claimed a moment earlier; the caller starts
#              its own window, which is what the second press meant
#   no answer  a spare that died (or its idle timer quit it) since the pid was
#              read; the caller cold-starts, and its way out preloads a new one
# The file is dropped in every failing case, because it would otherwise keep
# every future spawn believing a hidden copy exists.
warm_claim() {
    local pid answer
    pid="$(warm_pid)" || return 1
    [ -n "$pid" ] || return 1
    answer="$(qs ipc --pid "$pid" call "$warm_app" "$@" 2>/dev/null)" || { rm -f "$warm_pid_file"; return 1; }
    if [ "$answer" != "ok" ]; then
        rm -f "$warm_pid_file"
        return 1
    fi
    rm -f "$warm_pid_file"
    # The map is all that is left to wait for, and it is short: a second is
    # generous for a constructed window. Bounded so a spare that answers but
    # never maps falls through to a cold start instead of hanging the key.
    for _ in $(seq 1 50); do
        warm_on_screen "$pid" && return 0
        sleep 0.02
    done
    return 1
}
