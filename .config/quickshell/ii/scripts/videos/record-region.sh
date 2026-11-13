#!/usr/bin/env bash
# Region/fullscreen recording for the shell, on gpu-screen-recorder.
#
# WHY THIS EXISTS AND WHY IT IS NOT record.sh. record.sh is built on
# wf-recorder, which is not installed on this machine -- its start path fails
# before the first frame -- and wf-recorder has no pause at all: the only way
# to "pause" is to stop the file and start another one. This machine has an
# the discrete GPU, so gpu-screen-recorder is both the hardware encoder and the only
# backend here that can pause a running capture (SIGUSR2 toggles pause,
# SIGINT finalises the file).
#
# The tricky part is the PID. The shell (services/QuickRecord.qml) starts a
# recording through `Quickshell.execDetached`, which does not hand back a
# child, and Quickshell's Process type has no pid property either -- so pause
# and stop would have nothing to signal. Hence the pid file: this script is
# the one process that knows gsr's pid, and every verb but `start` reads it.
#
# Verbs:
#   record-region.sh start region WxH+X+Y [sound]   -> prints the output path
#   record-region.sh start monitor [sound]          -> prints the output path
#   record-region.sh where                          -> the clip directory (temp
#                                                      unless savePath is set)
#   record-region.sh pause | resume | toggle-pause
#   record-region.sh stop                           -> prints the final path
#   record-region.sh state                          -> "recording pid=… paused=0 mode=… region=x,y,w,h path=… elapsed=37"
#
# `state` is the only thing a caller needs to poll: it is correct whether the
# recording was started here, by another shell instance, or by hand.
#
# WHY `state` CARRIES THE REGION (2026-10-22: "show the space that its
# recording"). The shell draws a frame around what is being captured and puts
# the control box next to it, so it needs the rectangle -- in LOGICAL pixels,
# the space every QML surface draws in. The region is written here, at start,
# rather than reconstructed in QML, for the same reason everything else in this
# file lives here: a recording started from a terminal or by another shell
# instance must be drawn around exactly like one started from the snip UI.
set -u

RUNDIR="${XDG_RUNTIME_DIR:-/tmp}/qs-recorder"
PIDFILE="$RUNDIR/pid"
STATEFILE="$RUNDIR/state"
LOGFILE="$RUNDIR/gsr.log"
mkdir -p "$RUNDIR"

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse"
custom_out=$(jq -r '.screenRecord.savePath // empty' "$config_dir/config.json" 2>/dev/null)

# ── Where a clip goes ────────────────────────────────────────────────────
# TEMPORARY BY DEFAULT (asked for 2026-10-22: "they should only be saved temp so
# i can copy the video like a snip i can copy").
#
# Empty `screenRecord.savePath` now means exactly what empty `screenSnip.savePath`
# has always meant: keep it temporary and put it on the clipboard. The clip lands
# in a cache directory and is pruned -- it is a thing you PASTE, not a folder you
# leaf through. Set a path there and every clip is kept there instead, which is
# what the old default (~/Videos) did to every take ever recorded: the folder
# filled up with files nobody had asked to keep.
#
# NOT $XDG_RUNTIME_DIR: that is tmpfs, i.e. RAM. A 1600p60 clip is ~40 MB/s, so a
# couple of long takes in the runtime dir is a machine that starts swapping. The
# cache is a real disk that nothing backs up and that this script prunes.
CLIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/illogical-impulse/recordings"
if [[ -n "$custom_out" ]]; then
    OUTDIR="$custom_out"
    TEMPORARY=0
else
    OUTDIR="$CLIP_CACHE"
    TEMPORARY=1
fi
# How many temporary clips survive (newest first) and how much they may take in
# total. The count alone would let ten long takes eat the disk; the size alone
# would delete the one you just recorded on a busy afternoon.
MAX_CLIPS=10
MAX_BYTES=$((2 * 1024 * 1024 * 1024))

# Keep the newest MAX_CLIPS under MAX_BYTES, and point `latest.mp4` at the newest
# so there is one stable place to look instead of hunting for a timestamp.
prune_clips() {
    [[ "$TEMPORARY" == "1" && -d "$OUTDIR" ]] || return 0
    local -a files
    mapfile -t files < <(ls -1t "$OUTDIR"/*.mp4 2>/dev/null | grep -v '/latest\.mp4$')
    local i=0 total=0 size f
    for f in "${files[@]}"; do
        [[ -n "$f" ]] || continue
        size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        i=$((i + 1))
        if (( i > MAX_CLIPS )) || (( total + size > MAX_BYTES )); then
            rm -f -- "$f"
        else
            total=$((total + size))
        fi
    done
    if (( ${#files[@]} > 0 )) && [[ -n "${files[0]:-}" && -e "${files[0]}" ]]; then
        ln -sfn -- "$(basename "${files[0]}")" "$OUTDIR/latest.mp4"
    fi
}

now() { date +%s; }

alive() {
    local pid="$1"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

read_pid() { [[ -f "$PIDFILE" ]] && cat "$PIDFILE" 2>/dev/null || true; }

state_get() { # key
    [[ -f "$STATEFILE" ]] && sed -n "s/^$1=//p" "$STATEFILE" 2>/dev/null | head -1
}

state_set() { # key value
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    if [[ -f "$STATEFILE" ]]; then
        grep -v "^$key=" "$STATEFILE" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATEFILE"
}

# The LOGICAL rectangle of that monitor, for the frame the shell draws around
# it. `hyprctl monitors -j` reports x/y in the layout's logical space but
# width/height as the physical resolution, so the size is divided by the scale --
# 2560x1600 at 1.5 is 1706x1066 of logical screen, and drawing the frame at
# 2560x1600 would put three quarters of it off the display.
# The NAME of the monitor to capture, taken from Hyprland rather than gsr.
#
# This is the third spelling of "the screen" in this file, and the first two
# were refused by gsr on this machine (both measured 2026-10-22): `-w focused`
# requires `-s` and then fails with "window capture only works in a pure X11
# session", and `-w monitor` is read as a DISPLAY NAME -- it answered 'display
# "monitor" not found, expected one of: "screen", "eDP-1"'. The monitor's own
# name works, verified: a 1.5 s take at `-w eDP-1` produced a 248 KB mp4 at
# 2560x1600. Hyprland already knows which monitor is focused, so ask it.
focused_monitor_name() {
    hyprctl monitors -j 2>/dev/null | jq -r '
        (map(select(.focused == true)) | .[0]) as $m
        | if $m == null then empty else $m.name end' 2>/dev/null | head -1
}

logical_region_for_monitor() {
    hyprctl monitors -j 2>/dev/null | jq -r '
        (map(select(.focused == true)) | .[0]) as $m
        | if $m == null then empty
          else "\($m.x),\($m.y),\(($m.width / $m.scale) | floor),\(($m.height / $m.scale) | floor)"
          end' 2>/dev/null | head -1
}

cmd_start() {
    local mode="${1:-monitor}" geometry="${2:-}" sound="${3:-}"
    local pid; pid=$(read_pid)
    if alive "$pid"; then
        echo "already recording (pid $pid)" >&2
        return 3
    fi

    mkdir -p "$OUTDIR" || return 1
    prune_clips
    local path="$OUTDIR/recording_$(date '+%Y-%m-%d_%H.%M.%S').mp4"

    local args=(-c mp4 -f 60 -o "$path" -cursor yes)
    local region=""
    case "$mode" in
        region)
            [[ -n "$geometry" ]] || { echo "region needs WxH+X+Y" >&2; return 2; }
            args+=(-w region -region "$geometry")
            # gsr speaks "WxH+X+Y"; everything in the shell thinks "x,y,w,h".
            region=$(printf '%s' "$geometry" \
                | sed -E 's/^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$/\3,\4,\1,\2/')
            ;;
        monitor|fullscreen|"")
            # The focused monitor, BY NAME -- see focused_monitor_name() for why
            # neither `focused` nor `monitor` is what gsr wants here. Every
            # SUPER+R recording before 2026-10-22 died inside 400 ms and the
            # shell's stop answered "not recording".
            mode=monitor
            local mname; mname=$(focused_monitor_name)
            [[ -n "$mname" ]] || { echo "no focused monitor" >&2; return 1; }
            args+=(-w "$mname")
            region=$(logical_region_for_monitor)
            ;;
        *)
            echo "unknown mode: $mode" >&2
            return 2
            ;;
    esac
    # Silent by default (chosen 2026-10-21): a quick clip of a region is
    # usually "look at this", and starting the microphone uninvited is a
    # surprise nobody wants. `sound` opts into desktop audio + mic.
    if [[ "$sound" == "sound" ]]; then
        args+=(-a "default_output|default_input")
    fi

    # setsid: the recording must outlive the caller, which is a detached
    # process from QML. Bash's $! is then gsr's own pid (setsid execs when it
    # is not a process-group leader, which a background child never is).
    setsid gpu-screen-recorder "${args[@]}" >"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    printf 'pid=%s\npath=%s\nstarted=%s\npaused_total=0\npaused_at=0\nmode=%s\nregion=%s\n' \
        "$pid" "$path" "$(now)" "$mode" "$region" > "$STATEFILE"

    # gsr takes a moment to open the capture; if it died instantly (no
    # encoder, session not ready, another instance) say so instead of handing
    # back a path to a file that will never exist.
    sleep 0.4
    if ! alive "$pid"; then
        echo "gpu-screen-recorder exited immediately:" >&2
        tail -3 "$LOGFILE" >&2
        rm -f "$PIDFILE" "$STATEFILE"
        return 1
    fi
    echo "$path"
}

cmd_pause() {
    local pid; pid=$(read_pid)
    alive "$pid" || { echo "not recording" >&2; return 1; }
    [[ "$(state_get paused_at)" != "0" ]] && return 0
    kill -USR2 "$pid" 2>/dev/null || return 1
    state_set paused_at "$(now)"
}

cmd_resume() {
    local pid; pid=$(read_pid); local paused_at total
    alive "$pid" || { echo "not recording" >&2; return 1; }
    paused_at=$(state_get paused_at)
    [[ "$paused_at" == "0" || -z "$paused_at" ]] && return 0
    kill -USR2 "$pid" 2>/dev/null || return 1
    total=$(state_get paused_total); total=${total:-0}
    state_set paused_total "$(( total + $(now) - paused_at ))"
    state_set paused_at 0
}

cmd_toggle_pause() {
    local paused_at; paused_at=$(state_get paused_at)
    if [[ "$paused_at" == "0" || -z "$paused_at" ]]; then cmd_pause; else cmd_resume; fi
}

# ── The clipboard ────────────────────────────────────────────────────────
# A finished clip is COPIED, the way a snip is copied (asked for 2026-10-22:
# "at the end of the recording i want it copied (like the snip would copy)").
#
# A snip copies PNG bytes because an image is a thing you paste. A recording is
# a FILE, and "copied like Ctrl+C in a file manager" (asked for 2026-10-22) is a
# stronger claim than `text/uri-list`: that is one type, and a file manager's
# copy is a SET of them -- `x-special/gnome-copied-files`, the mate/nemo spelling
# with the same bytes, and the uri-list. That is what clip-file.py puts on the
# selection (see its header for why wl-copy cannot: it serves exactly one type and
# adds a text/plain fallback, so a GTK app asked for a file saw nothing).
#
# Detached on purpose. The clipboard is a LAZY handover: the bytes are only read
# when something pastes, so the process that owns the selection has to outlive
# this script -- which runs inside the QML Process whose stdout is being
# collected, and a surviving child holding that pipe would hang the "Copied"
# toast forever. Hence setsid plus stdin/stdout to /dev/null.
#
# A temp clip also DELETES ITSELF after RECORD_CLIP_TTL seconds (asked for
# 2026-10-22: "have the recording disappear after a while exactly like the
# screenshots"). A screenshot can vanish the instant it is copied because its
# bytes are on the clipboard; a video cannot -- nothing accepts a pasted video
# stream, and holding a 200 MB mp4 in wl-copy to fake it would be a copy of the
# file in RAM. So the file lives as long as the clipboard can hand it over, plus
# a window you can still open it in, and then it is gone. `screenRecord.savePath`
# keeps clips that were asked for, and those are never touched.
RECORD_CLIP_TTL="${RECORD_CLIP_TTL:-600}"
CLIP_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clip-file.py"

copy_to_clipboard() {
    local path="$1" pid
    [[ -n "$path" && -f "$path" ]] || return 1
    if [[ -x "$CLIP_HELPER" ]] && command -v python3 >/dev/null 2>&1; then
        local args=()
        [[ "$TEMPORARY" == "1" ]] && args=(--transient "$RECORD_CLIP_TTL")
        setsid "$CLIP_HELPER" "${args[@]}" "$path" >/dev/null 2>&1 </dev/null &
        pid=$!
        # It only earns the word "copied" if it is actually holding the
        # selection: python without GTK4-GObject (or without a display) fails
        # within a few hundred ms, and reporting a copy that never happened is
        # worse than saying nothing.
        sleep 0.6
        if alive "$pid"; then
            return 0
        fi
    fi
    # Fallback: a single-type copy is still better than no clipboard at all.
    command -v wl-copy >/dev/null 2>&1 || return 1
    local uri
    uri=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$path" 2>/dev/null) \
        || uri="file://$path"
    # NOT `< /dev/null` on wl-copy: the URI arrives on stdin, and redirecting
    # it there hands an empty selection to the clipboard with the right type
    # and no content (measured 2026-10-22). Only stdout/stderr are silenced.
    printf '%s\r\n' "$uri" | wl-copy --type text/uri-list >/dev/null 2>&1 || return 1
}

cmd_stop() {
    local pid path; pid=$(read_pid); path=$(state_get path)
    if ! alive "$pid"; then
        rm -f "$PIDFILE" "$STATEFILE"
        echo "not recording" >&2
        return 1
    fi
    # SIGINT is the graceful stop: it flushes and finalises the mp4. SIGKILL
    # here would leave a file that no player can read.
    kill -INT "$pid" 2>/dev/null
    for _ in $(seq 1 50); do
        alive "$pid" || break
        sleep 0.1
    done
    if alive "$pid"; then
        echo "recorder did not stop; still pid $pid" >&2
        return 1
    fi
    rm -f "$PIDFILE" "$STATEFILE"
    # The path is always line 1 -- callers parse it. Then two optional lines:
    # `copied` when the clipboard has it, and `temp` when the file is a
    # cache-dir clip that will be pruned (the shell says "Copied" for those
    # instead of "Saved", because nothing was saved).
    echo "$path"
    copy_to_clipboard "$path" && echo "copied"
    prune_clips
    [[ "$TEMPORARY" == "1" ]] && echo "temp"
    return 0
}

cmd_state() {
    local pid path started total paused_at elapsed paused mode region
    pid=$(read_pid); path=$(state_get path)
    if ! alive "$pid"; then
        rm -f "$PIDFILE" "$STATEFILE" 2>/dev/null
        echo "idle"
        return 0
    fi
    started=$(state_get started); started=${started:-$(now)}
    total=$(state_get paused_total); total=${total:-0}
    paused_at=$(state_get paused_at); paused_at=${paused_at:-0}
    paused=0; [[ "$paused_at" != "0" ]] && paused=1
    elapsed=$(( $(now) - started - total ))
    [[ "$paused" == "1" ]] && elapsed=$(( elapsed - ($(now) - paused_at) ))
    (( elapsed < 0 )) && elapsed=0
    # mode/region sit BEFORE path on purpose: the shell reads the path with
    # `/path=(.*) elapsed=\d+$/`, and a recording made before these keys existed
    # simply has them empty (the frame then just does not draw).
    mode=$(state_get mode); region=$(state_get region)
    echo "recording pid=$pid paused=$paused mode=$mode region=$region path=$path elapsed=$elapsed"
}

verb="${1:-}"; shift || true
case "$verb" in
    where) echo "$OUTDIR"; exit 0 ;;
    start) cmd_start "$@" ;;
    pause) cmd_pause ;;
    resume) cmd_resume ;;
    toggle-pause) cmd_toggle_pause ;;
    stop) cmd_stop ;;
    state) cmd_state ;;
    *)
        echo "usage: $(basename "$0") start region WxH+X+Y [sound] | start monitor [sound] | pause | resume | toggle-pause | stop | state" >&2
        exit 2
        ;;
esac
