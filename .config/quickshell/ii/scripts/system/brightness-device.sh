#!/usr/bin/env bash
# ── KEYBOARD this laptop (this laptop-0510) patch: the RIGHT backlight ──────────────────
#
# This machine exposes TWO backlight devices: `intel_backlight` (the iGPU,
# which actually drives the built-in panel) and `nvidia_0` (the dGPU's
# controls, which change nothing you can see). Plain `brightnessctl` picks
# whichever the kernel lists first -- here that is nvidia_0 -- so every
# brightness change silently went to a device that does not drive the screen:
# the keys "fired", the display stayed the same.
#
# This script is the one canonical brightness entry point. It resolves the
# correct device from the DRM state instead of trusting enumeration order:
# find the connector named like the panel (eDP-*) that is `connected`, then
# take the backlight whose sysfs device sits under that connector's device
# (matches the iGPU backlight exactly, and would also pick a connected
# connector's backlight on other Optimus laptops).
#
# Usage:
#   brightness-device.sh read      print "a b c CUR MAX" (Quickshell's parser)
#   brightness-device.sh set N     absolute brightness, N percent
#   brightness-device.sh step +N   relative change (+5 / -5), for keybinds
set -u

panel_conn="${BRIGHTNESS_PANEL:-eDP-1}"

resolve_device() {
    # 1) A connected connector matching the panel name.
    local conn card d p
    for conn in /sys/class/drm/*-"$panel_conn"; do
        [ -d "$conn" ] || continue
        [ "$(cat "$conn/status" 2>/dev/null)" = "connected" ] || continue
        d=$(readlink -f "$conn" 2>/dev/null) || continue
        for b in /sys/class/backlight/*; do
            [ -d "$b" ] || continue
            p=$(readlink -f "$b/device" 2>/dev/null) || continue
            # The backlight belongs to this connector, or to the GPU under it.
            case "$d" in
                "$p"|"$p"/*) basename "$b"; return 0 ;;
            esac
        done
    done
    # 2) Fallback: any firmware/raw device (those drive real panels; the
    #    nvidia_0-style nodes this machine also shows are the trap).
    for b in /sys/class/backlight/*; do
        case "$(cat "$b/type" 2>/dev/null)" in
            firmware|raw) basename "$b"; return 0 ;;
        esac
    done
    # 3) Last resort: whatever exists.
    ls /sys/class/backlight/ 2>/dev/null | head -1
}

dev=$(resolve_device)
[ -n "$dev" ] || { echo "no backlight device" >&2; exit 1; }

mode="${1:-read}"
case "$mode" in
    read)
        cur=$(brightnessctl -d "$dev" g) || exit 1
        max=$(brightnessctl -d "$dev" m) || exit 1
        echo "a b c $cur $max"
        ;;
    set)
        n="${2:-100}"
        case "$n" in ''|*[!0-9]*) echo "set: N must be 0-100" >&2; exit 2 ;; esac
        exec brightnessctl -d "$dev" s "${n}%" --quiet
        ;;
    step)
        amt="${2:-+5}"
        case "$amt" in [+-][0-9]*) ;; *) echo "step: use +N or -N" >&2; exit 2 ;; esac
        # brightnessctl's delta syntax is direction-encoded: up is "+N%",
        # down is "N%-" (a leading "-" would parse as command-line options).
        if [ "${amt:0:1}" = "+" ]; then
            exec brightnessctl -d "$dev" s "${amt}%" --quiet
        else
            exec brightnessctl -d "$dev" s "${amt:1}%-" --quiet
        fi
        ;;
    *)
        echo "usage: $0 read | set N | step +N" >&2
        exit 2
        ;;
esac
