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

vocab_args() {
    # THE VOCABULARY PROMPT.
    #
    # whisper's decoder can be handed a piece of text it imagines it has just
    # written, and it then spells what it hears the way that text spells it. One
    # comma-separated list of the names and jargon this desktop actually talks
    # about buys correct "Grafizum", "Quickshell" and "hyprctl" for free -- the
    # cost is a few context tokens and no measurable time, because it rides along
    # with the request the server was going to make anyway.
    #
    # It lives HERE rather than in each client on purpose: this one process
    # answers both the hold-SUPER dictation and the WhisperFlow app, so both get
    # the same words from one file and neither client needs to know the feature
    # exists. A client that sends its own `prompt` form field (WhisperFlow does,
    # when it re-decodes a clip to steer away from music) overrides it for that
    # one request, which is the right precedence.
    #
    # `--carry-initial-prompt` keeps it applied when a long recording is decoded
    # in more than one window; without it only the first window would see it.
    #
    # NOTE, 2026-11-18: dictate.sh now SENDS this same list with every request
    # (dictate_prompt), so the hold-SUPER dictation follows an edit to words.txt
    # without any restart -- this copy is what a request that brings no prompt
    # of its own gets (WhisperFlow), and it is read at server start.
    #
    # And `-mc` must not be 0: with no text context whisper drops the initial
    # prompt entirely ("initial prompt is too long (...), will use only the last
    # 1 tokens"), which is why the vocabulary did nothing for a long time. 448 is
    # the model's own context; half of it is what a prompt is allowed to use.
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/ii-dictate/words.txt"
    [ -r "$file" ] || return 0
    local words
    words="$(sed -e 's/#.*//' "$file" | sed '/^[[:space:]]*$/d' |
        head -100 | paste -sd, - | sed -e 's/,/, /g' -e 's/[[:space:]]\{2,\}/ /g')"
    [ -n "$words" ] || return 0
    printf -- '--prompt\0%s\0--carry-initial-prompt\0' "$words"
}

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

# ── The first request after a start is not free ──────────────────────────
#
# Measured 2026-11-18 on this machine: the first inference on a freshly started
# server spent 7.2s of wall clock for 1.5s of logged work -- CUDA module load,
# ggml graph allocation, the first kernel launches. Everything after it is
# 0.3-0.9s. The person who pays that 7s is whoever dictates first, which is
# indistinguishable from "dictation is sometimes broken".
#
# So the server warms ITSELF: a detached process waits for the port, sends one
# throwaway second of silence, and exits. A cgroup stop still takes it down with
# the server, and a failed warm-up costs nothing (the dictation that follows just
# pays the cold first request as before).
warmup_wav() {
    local f="$STATE/warmup.wav"
    [ -s "$f" ] && { printf '%s' "$f"; return 0; }
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono \
        -t 1 -c:a pcm_s16le "$f" >/dev/null 2>&1 || return 1
    [ -s "$f" ] && printf '%s' "$f"
}

warm_in_background() {
    local wav
    wav="$(warmup_wav)" || return 0
    ( i=0
      while [ "$i" -lt 150 ]; do
          curl -s --max-time 0.4 -o /dev/null "http://127.0.0.1:${DICTATE_PORT}/" 2>/dev/null && break
          sleep 0.2
          i=$(( i + 1 ))
      done
      curl -s --max-time 120 -o /dev/null -F "file=@$wav" -F response_format=json \
          "http://127.0.0.1:${DICTATE_PORT}/inference" 2>/dev/null
    ) >/dev/null 2>&1 &
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
    local -a vocab=()
    # -d '' because the words list is passed NUL-separated: terms may contain
    # spaces ("pull request") and must survive as ONE argument.
    mapfile -d '' -t vocab < <(vocab_args)
    warm_in_background
    setsid "$bin" -m "$model" -l "$LANGUAGE" --host 127.0.0.1 \
        --port "$DICTATE_PORT" -mc 448 --convert "${vocab[@]}" >>"$LOGFILE" 2>&1 &
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
    local -a vocab=()
    mapfile -d '' -t vocab < <(vocab_args)
    warm_in_background
    exec "$bin" -m "$model" -l "$LANGUAGE" --host 127.0.0.1 \
        --port "$DICTATE_PORT" -mc 448 --convert "${vocab[@]}"
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
