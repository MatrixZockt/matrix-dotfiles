#!/usr/bin/env bash
#
# A warm whisper.cpp server for dictation.
#
# Why this exists: whisper-cli loads the model from disk on every run, and on
# this machine that load is most of the wait -- a 9 second clip took 2.7s
# through the CUDA build, of which the model load was over a second, and the
# same clip through a server that already holds the model takes 0.2s. Dictation
# is a rhythm thing: a fifth of a second after you let go of SUPER feels like it
# heard you, two seconds feels like it is thinking about it.
#
# It is a loopback-only server on purpose. Nothing leaves the machine -- the
# audio is posted to 127.0.0.1 and the text comes back.
#
#   dictate-server.sh start | stop | status | run
#
# `run` is the FOREGROUND form, for systemd (dictate-server.service): execs the
# server in place of the shell so the unit supervises the real process, and
# keeps the pidfile pointed at itself so `status` and `stop` still work. `start`
# (the detached form) stays for a hand-start from a terminal.
#
# Settings come from ~/.config/ii-dictate.conf, same file as the rest:
#   MODEL=ggml-small.bin       which model to hold in memory (multilingual: the
#                              .en models ignore every language but English)
#   LANGUAGE=auto              whisper language, "auto" to detect it per request
#   DICTATE_PORT=8917          loopback port (dictate.sh reads the same value)
#
set -uo pipefail

DATA="$HOME/.local/share/ii-dictate"
STATE="${XDG_RUNTIME_DIR:-/tmp}/ii-dictate"
PIDFILE="$STATE/server.pid"
LOGFILE="$STATE/server.log"

MODEL="${MODEL:-ggml-small.bin}"
LANGUAGE="${LANGUAGE:-auto}"
DICTATE_PORT="${DICTATE_PORT:-8917}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/ii-dictate.conf"
[ -r "$CONFIG" ] && . "$CONFIG"
mkdir -p "$STATE"

server_bin() {
    # The CUDA build first: it is the one that makes small.en usable at
    # dictation speed. The CPU build stays as the fallback for a machine
    # without a working NVIDIA driver, where it is slower but correct.
    local cuda="$DATA/whisper.cpp/build-cuda/bin/whisper-server"
    local cpu="$DATA/whisper.cpp/build/bin/whisper-server"
    [ -x "$cuda" ] && { printf '%s' "$cuda"; return 0; }
    [ -x "$cpu" ] && { printf '%s' "$cpu"; return 0; }
    return 1
}

listening() {
    curl -s --max-time 0.4 -o /dev/null "http://127.0.0.1:${DICTATE_PORT}/" 2>/dev/null
}

running_pid() {
    [ -f "$PIDFILE" ] || return 1
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

start() {
    # execs.lua is file-scope and runs again on every Hyprland reload, so
    # "start" has to mean "make sure", not "spawn another".
    if listening || running_pid >/dev/null; then
        return 0
    fi
    local bin model
    bin="$(server_bin)" || { echo "no whisper-server build in $DATA/whisper.cpp" >&2; return 1; }
    model="$DATA/models/$MODEL"
    [ -f "$model" ] || { echo "no model at $model" >&2; return 1; }
    setsid "$bin" -m "$model" -l "$LANGUAGE" --host 127.0.0.1 \
        --port "$DICTATE_PORT" -mc 0 --convert >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
}

stop() {
    local pid
    pid="$(running_pid)" || { rm -f "$PIDFILE"; return 0; }
    kill "$pid" 2>/dev/null
    rm -f "$PIDFILE"
}

run() {
    local bin model
    bin="$(server_bin)" || { echo "no whisper-server build in $DATA/whisper.cpp" >&2; return 1; }
    model="$DATA/models/$MODEL"
    [ -f "$model" ] || { echo "no model at $model" >&2; return 1; }
    # Own pidfile while we are the server, so a hand `stop` still means stop.
    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT
    exec "$bin" -m "$model" -l "$LANGUAGE" --host 127.0.0.1 \
        --port "$DICTATE_PORT" -mc 0 --convert
}

case "${1:-start}" in
    start) start ;;
    run) run ;;
    stop) stop ;;
    status)
        if listening; then echo "listening on 127.0.0.1:$DICTATE_PORT (model $MODEL)"
        elif running_pid >/dev/null; then echo "starting/loading (model $MODEL)"
        else echo "not running"; fi
        ;;
    *) echo "usage: dictate-server.sh start|stop|status|run" >&2; exit 2 ;;
esac
