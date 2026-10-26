#!/usr/bin/env bash
# Notification popup check: does a notification arrive as a CARD, or as the
# invisible sliver that "notifications do not show" turned out to be?
#
# 2026-10-20: the popup's window lost its width in an edit that read like a
# tidy-up. The surface still mapped -- so nothing in the shell's own state said
# anything was wrong: the notification was in the bell, the timer was armed, the
# entries were written to disk -- and it mapped 100px wide down the right edge
# of the screen instead of 422. Everything downstream looked healthy and the
# user saw nothing at all.
#
# So this check measures the two things that were true when it worked and false
# when it did not, from OUTSIDE the app: the compositor's own view of the
# surface (its width, and that it sits against the right edge), and its
# disappearance when the timer runs out. Nothing here reads the shell's
# internals, which is the point -- the shell thought it was fine.
set -u

NOTIFY_IFACE=org.freedesktop.Notifications
NOTIFY_PATH=/org/freedesktop/Notifications
NAMESPACE=quickshell:notificationPopup
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
boo() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected [$3] got [$2]"; }

# The popup's surface as the compositor sees it: "x y w h", or empty when it is
# not mapped. `hyprctl layers` is the only honest witness here -- a shell that
# has the notification in its list looks identical to one that is drawing it.
layer() {
    hyprctl layers -j 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for mon, v in d.items():
    for level in v.get('levels', {}).values():
        for l in level:
            if l.get('namespace') == '$NAMESPACE':
                print(l['x'], l['y'], l['w'], l['h'])
                raise SystemExit(0)
"
}

# The focused monitor, in layout pixels (the unit `hyprctl layers` reports) plus
# the scale a screenshot has to be multiplied by.
read -r MON_W MON_H MON_SCALE <<<"$(hyprctl monitors -j 2>/dev/null | python3 -c "
import json, sys
m = [x for x in json.load(sys.stdin) if x.get('focused')]
if not m:
    print('0 0 1'); raise SystemExit(0)
m = m[0]
scale = m.get('scale', 1) or 1
print(int(m['width'] / scale), int(m['height'] / scale), scale)
")"

# notify-send is not usable on this machine (a libnotify symbol mismatch), and
# it would be a moving part anyway: this talks to the server the shell exports,
# which is exactly what any other app does.
notify() {
    gdbus call --session --dest "$NOTIFY_IFACE" --object-path "$NOTIFY_PATH" \
        --method "$NOTIFY_IFACE.Notify" \
        "${1:-Check}" 0 "" "${2:-Notification check}" "${3:-body}" "[]" "{}" "${4:-4000}" \
        >/dev/null 2>&1
}

wait_for_layer() {
    local i
    for i in $(seq 1 40); do
        [ -n "$(layer)" ] && return 0
        sleep 0.05
    done
    return 1
}

echo "── the notification popup, as the compositor draws it ───────────────"
[ "$MON_W" -gt 0 ] || { echo "  ..    no focused monitor found"; exit 1; }

notify "Check" "Notification check" "This should arrive as a card" 4000
if ! wait_for_layer; then
    bad "a notification puts a popup surface on the screen"
    echo "passed $PASS, failed $FAIL"
    exit 1
fi
ok "a notification puts a popup surface on the screen"

read -r LX LY LW LH <<<"$(layer)"
case "$LW" in (*[!0-9]*|"") LW=0 ;; esac
# 422 at the default 410px card and a 12px gap. The band is generous on
# purpose: the card's width is a taste (410 today), while "collapsed to a
# sliver" is the bug -- and 100 is exactly what that measured.
if [ "$LW" -ge 380 ] && [ "$LW" -le 480 ]; then
    ok "and it is as wide as a notification card, not a sliver ($LW px)"
else
    bad "and it is as wide as a notification card, not a sliver: $LW px"
fi
# The right edge against the screen's right edge: a popup of the right size
# parked in the middle of the screen is a second way to be invisible. A pixel or
# two of slack, because the surface's x arrives already rounded (measured 1706
# against a 1707-wide screen) and the gap is not the thing being asserted.
SLACK=$((MON_W - LX - LW))
boo "and it is against the right edge of the screen" \
    "$([ "$SLACK" -ge -2 ] && [ "$SLACK" -le 2 ] && echo flush || echo "$SLACK px off")" \
    "flush"
boo "and it starts under the bar rather than over it" \
    "$([ "$LY" -ge 40 ] && echo below || echo "at $LY")" "below"

# The card's own pixels: a surface of the right size can still be a transparent
# rectangle. The corner the card actually occupies is sampled from a screenshot
# -- the same witness the eye uses.
if command -v grim >/dev/null 2>&1 && command -v magick >/dev/null 2>&1; then
    # Bounded: a screencopy request can sit unanswered (seen here, mid-session),
    # and a check that hangs is worse than one that says it could not look.
    SHOT=/tmp/notifications-check.png
    CROP_W="$(python3 -c "print(int($LW * $MON_SCALE))")"
    CROP_H="$(python3 -c "print(int(min($LH, 320) * $MON_SCALE))")"
    CROP_X="$(python3 -c "print(int($LX * $MON_SCALE))")"
    CROP_Y="$(python3 -c "print(int($LY * $MON_SCALE))")"
    if timeout 10 grim "$SHOT" >/dev/null 2>&1; then
        COLOURS="$(magick "$SHOT" -crop "${CROP_W}x${CROP_H}+${CROP_X}+${CROP_Y}" +repage -format '%k' info: 2>/dev/null)"
        case "$COLOURS" in (*[!0-9]*|"") COLOURS=0 ;; esac
        [ "$COLOURS" -ge 8 ] \
            && ok "and there is something drawn in it, not an empty rectangle ($COLOURS colours)" \
            || bad "and there is something drawn in it: only $COLOURS colours in the card's corner"
    else
        echo "  ..    the screen could not be read; the card's pixels are not asserted"
    fi
fi

# And it goes away on its own, without touching the notification history. This
# is the other half of "shows like a normal notification": a card that stays
# forever is a card that is stuck, not a notification.
sleep 3.2
boo "the card leaves the corner when the app's time is up" "$(layer)" ""

# ── The chime, and the app that does not get one ──────────────────────────
#
# Two rules that are invisible to every other witness here: a chime that played
# and a chime that was deliberately skipped look identical from the outside,
# both being "a card appeared". So this asks PipeWire: `pw-mon` reports the
# node the shell spawns for a sound, and the shell tags its own chime
# `ii-system-sound`. One notification from an ordinary app must create one; a
# notification from an app that sounds its own (Discord, WhatsApp) must create
# none, because the app has already made the noise.
#
# The BASELINE is checked first and the rest is skipped when it fails: a
# System Sounds row at zero, or muted, spawns nothing for anything, and that is
# a setting rather than a broken rule -- reporting it as a failure would send
# someone looking for a bug in the wrong place.
chime_nodes() {   # chime_nodes <app> <summary> -- how many chime streams it made
    local app="$1" summary="$2" log="/tmp/notifications-check-pw.$$" mon
    rm -f "$log"
    timeout 5 pw-mon > "$log" 2>&1 &
    mon=$!
    sleep 0.7
    notify "$app" "$summary" "notification sound probe" 1200
    sleep 1.1
    kill "$mon" 2>/dev/null
    wait "$mon" 2>/dev/null
    grep -c 'application.name = "ii-system-sound"' "$log" 2>/dev/null || true
    rm -f "$log"
}

if command -v pw-mon >/dev/null 2>&1; then
    echo "── the chime: played for an app, skipped for one that sounds itself ──"
    BASE="$(chime_nodes Check "the shell's own chime")"
    case "$BASE" in (*[!0-9]*|"") BASE=0 ;; esac
    if [ "$BASE" -ge 1 ]; then
        ok "an ordinary notification plays the shell's chime ($BASE mentions in pw-mon)"
        case "$(chime_nodes Discord "an app with its own sound")" in
            (0) ok "a Discord notification does not (Discord sounds it)" ;;
            (*) bad "a Discord notification does not chime: the shell played one anyway" ;;
        esac
        case "$(chime_nodes 'WhatsApp Desktop' "an app with its own sound")" in
            (0) ok "a WhatsApp notification does not (WhatsApp sounds it)" ;;
            (*) bad "a WhatsApp notification does not chime: the shell played one anyway" ;;
        esac
    else
        echo "  ..    nothing reached PipeWire for an ordinary notification --"
        echo "  ..    the System Sounds row is off or muted; the chime rules are not asserted"
    fi
    # The rule itself, without depending on any audio state: the daemon's own
    # answer for a sender it has never seen a notification from.
    case "$(qs -c ii ipc call notifications sound Discord '' '' 2>/dev/null)" in
        (*"no shell chime"*) ok "and the rule says so for Discord, in words" ;;
        (*) bad "and the rule says so for Discord: '$(qs -c ii ipc call notifications sound Discord '' '')'" ;;
    esac
    case "$(qs -c ii ipc call notifications sound Kitty '' '' 2>/dev/null)" in
        (*"shell chime at"*) ok "while an app with no sound of its own keeps the shell's" ;;
        (*) bad "while an app with no sound of its own keeps the shell's" ;;
    esac
    # These probes are the check's own cards; the suite leaves the bell as it
    # found it.
    qs -c ii ipc call notifications clear >/dev/null 2>&1
fi

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
