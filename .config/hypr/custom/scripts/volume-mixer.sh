#!/usr/bin/env bash
# ── The volume mixer, and never a side effect of dictation ───────────────────
#
# CTRL + SUPER + V opens the mixer (hyprland/keybinds.lua) and dictation pastes
# its sentence with a Ctrl+V chord, delivered as real key events through
# ydotool. A paste that lands while SUPER is down is therefore read by the
# compositor as this shortcut, and pavucontrol opened over the text being
# dictated, now and then, for no reason the user could see.
#
# SUPER is down for most of a dictation session -- the next sentence starts the
# moment the last one was let go of -- so the window for this is not small.
# dictate.sh already refuses to inject anything while SUPER is held (see
# wait_for_super there). What is left is a gap of a few events: the daemon sees
# the key release on its own evdev handle and records it in a file, the
# compositor sees the same release on its own and clears its modifier mask, and
# the paste is thrown into the space between the two.
#
# So the chord is answered only when SUPER is really free: never while the
# daemon says it is held, and not in the fraction of a second after it says it
# was let go. Reaching for the mixer yourself is unaffected -- that needs SUPER
# pressed deliberately, at a moment when nothing else just happened.
#
# Every suppression is logged next to the dictation's own state, because a
# shortcut that silently does nothing is a bug report of its own; this way the
# log says whether the guard fired or the mixer never got the key at all.
set -u

STATE="${XDG_RUNTIME_DIR:-/tmp}/ii-dictate"
SUPER_FILE="$STATE/super"
LOG="$STATE/volume-mixer.log"

# How recently the daemon must have written "up" for a press to be suspect.
# 0.4s is generous against the compositor's own input latency, and far shorter
# than anyone's reach for the mixer after letting go of SUPER.
SETTLE_MS=400

drop() {
    mkdir -p "$STATE" 2>/dev/null
    printf '%s  mixer shortcut dropped: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" \
        >>"$LOG" 2>/dev/null
    exit 0
}

if [ -r "$SUPER_FILE" ]; then
    [ "$(cat "$SUPER_FILE" 2>/dev/null)" = down ] \
        && drop "SUPER is held (a dictation paste)"

    # Epoch seconds as a fraction; `%.9Y` is GNU stat and prints 1758...123456789.
    wrote="$(stat -Lc '%.9Y' "$SUPER_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s.%N)"
    age_ms="$(awk -v n="$now" -v w="$wrote" \
        'BEGIN { printf "%d", (n - w) * 1000 }' 2>/dev/null || echo 999999)"
    case "${age_ms:-999999}" in
        ''|*[!0-9]*) age_ms=999999 ;;
    esac
    [ "$age_ms" -lt "$SETTLE_MS" ] \
        && drop "SUPER came up ${age_ms}ms ago (a dictation paste)"
fi

exec ~/.config/hypr/hyprland/scripts/launch_first_available.sh 'pavucontrol-qt' 'pavucontrol'
