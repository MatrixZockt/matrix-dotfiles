#!/usr/bin/env bash
# Play the microphone back through the speakers, so the user can hear themself.
#
# `toggle` (the default) starts it if it is off and stops it if it is on; the
# module id lives in the runtime dir, which camera/mic settings survive a shell
# reload but not a logout. A loopback started by a shell that has since been
# reloaded would otherwise leave the user hearing themself with no way to stop
# it from the panel, so every start first unloads whatever the state file
# remembers.
set -u

state="${XDG_RUNTIME_DIR:-/tmp}/ii-mic-monitor"
action="${1:-toggle}"
source_name="${2:-}"
sink_name="${3:-}"

stop() {
    local id
    id="$(cat "$state" 2>/dev/null || true)"
    if [ -n "$id" ]; then
        pactl unload-module "$id" >/dev/null 2>&1 || true
    fi
    rm -f "$state"
    echo "off"
}

case "$action" in
    status)
        id="$(cat "$state" 2>/dev/null || true)"
        if [ -n "$id" ] && pactl list short modules 2>/dev/null | grep -q "^$id[[:space:]]"; then
            echo "on $id"
        else
            rm -f "$state"
            echo "off"
        fi
        ;;
    off)
        stop
        ;;
    on|toggle)
        if [ "$action" = "toggle" ] && [ -s "$state" ]; then
            stop
            exit 0
        fi
        stop >/dev/null
        [ -n "$source_name" ] || source_name="$(pactl get-default-source 2>/dev/null)"
        [ -n "$sink_name" ] || sink_name="$(pactl get-default-sink 2>/dev/null)"
        if [ -z "$source_name" ] || [ -z "$sink_name" ]; then
            echo "off"
            exit 1
        fi
        id="$(pactl load-module module-loopback "source=$source_name" "sink=$sink_name" latency_msec=30 2>/dev/null)"
        if [ -z "$id" ]; then
            echo "off"
            exit 1
        fi
        printf '%s\n' "$id" > "$state"
        echo "on $id"
        ;;
    *)
        echo "off"
        exit 2
        ;;
esac
