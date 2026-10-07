#!/usr/bin/env bash
# XF86KbdBrightnessUp / XF86KbdBrightnessDown handler (bound in custom/keybinds.lua).
#
# Steps the keyboard backlight by 25% via the openrazer driver's sysfs file,
# which is group-writable by the "openrazer" group this user belongs to -- so
# this works even if openrazer-daemon is down. (The daemon persists the value
# itself when it is running.)
#
# Best-effort notification afterwards, since the keyboard has no on-screen
# slider: notify-send if available, else the shell's notification service, else
# nothing. A lighting key must never block on a missing notifier.
set -u

# $1 = "up" (default) or "down". Up wraps 100 -> 0; down clamps at 0.
DIR=${1:-up}
STEP=25
BRIGHTNESS_FILE=""
for d in /sys/bus/hid/drivers/razerkbd/*/matrix_brightness; do
    [ -e "$d" ] && BRIGHTNESS_FILE="$d"
done

if [ -z "$BRIGHTNESS_FILE" ]; then
    notify-send -a keyboard "Keyboard light" "openrazer driver not loaded" -t 1200 2>/dev/null
    exit 0
fi

current=$(cat "$BRIGHTNESS_FILE" 2>/dev/null) || current=0
if [ "$DIR" = down ]; then
    new=$((current - STEP))
    [ "$new" -lt 0 ] && new=0
else
    new=$((current + STEP))
    [ "$new" -gt 100 ] && new=0
fi
echo "$new" > "$BRIGHTNESS_FILE" 2>/dev/null || exit 0
# The device commits the write over a slow USB round-trip; settle before the
# notification reads the value back, or a rapid second press can read stale.
sleep 0.12

if command -v notify-send >/dev/null 2>&1; then
    notify-send -a keyboard -h int:value:"$new" "Keyboard light" "$new%" -t 1200 2>/dev/null
fi
