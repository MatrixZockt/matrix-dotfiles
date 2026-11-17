#!/usr/bin/env bash
# Send Ctrl+V into the window the popup was opened FROM -- once that window is
# focused again and its text field has the caret.
#
# This is the second half of the clipboard popup's paste. The first half is
# Cliphist.paste(), which decodes the chosen entry back onto the clipboard; the
# keystroke that actually pastes it is sent here, and it is sent from a script
# rather than a one-liner inside the QML because the whole difficulty is WHEN
# and WHERE it is sent -- timing and targeting worth being able to run and watch
# by hand.
#
# Two problems, three jobs.
#
# 1. THE POPUP HOLDS THE KEYBOARD WHILE IT IS OPEN. It has to
#    (WlrKeyboardFocus.Exclusive in ClipboardListWindow.qml, so the arrows and
#    RETURN work without a click first), and a synthesised Ctrl+V goes to
#    whatever holds the keyboard at that instant -- so a paste fired while the
#    popup was still up landed in the popup's own search field. What has to be
#    gone is the popup's LAYER SURFACE: `hyprctl layers` lists it as
#    `namespace: quickshell:clipboard` while mapped and not at all once closed
#    (measured: 1 line open, 0 lines closed). So this waits for that, not for a
#    fixed sleep, and not on `hyprctl activewindow`, which reports the window
#    underneath for the whole time the popup is up and cannot tell the two
#    states apart.
#
# 2. FOCUS FOLLOWS THE MOUSE HERE (`input:follow_mouse = 1`). When the popup
#    unmaps the keyboard does not go back to the window it came from -- it goes
#    to whatever window the POINTER happens to be over. Reported as: the value
#    only lands if the cursor is over the app you meant, and the input box you
#    had selected stops being selected the moment the popup opens. So the popup
#    records which window it was opened from (`paste-keystroke.sh remember`,
#    called when it opens) and this focuses THAT address again, waits until
#    Hyprland agrees it is active, and only then sends the key.
#
# 3. A FOCUSED WINDOW IS NOT A CARET. Handing the keyboard back does not restore
#    which input box was selected: a chat app comes back with the window active
#    and the message box unfocused, and Ctrl+V into that is silently dropped.
#    There is no Wayland call for "where is the text field", so this asks the
#    accessibility tree -- the same helper SUPER dictation uses before it types,
#    because it is the same problem. Apps that publish no tree answer "no-a11y"
#    and keep whatever caret they had.
#
# The keystroke itself is ydotool -- a real Ctrl+V at the kernel input layer,
# the command the shell's own stash branch has always used -- rather than
# Hyprland's `send_shortcut` dispatcher: that one answers "ok" and the key never
# reaches the client (verified against a live terminal, where nothing arrived).
set -u

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/ii-clipboard"
OWNER_FILE="$STATE_DIR/owner"
PASTE_LOG="$STATE_DIR/paste.log"
FOCUS_HELPER="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/scripts/dictate-focus.py"

# Never hang: if the popup is somehow still mapped after this, paste anyway
# rather than silently dropping the user's Enter.
LAYER_GONE_DEADLINE_MS=2000
# How long to wait for the remembered window (or any application window) to
# hold the keyboard again. One frame is enough when nothing is busy; the ceiling
# is what a person would not notice on a loaded machine.
FOCUS_DEADLINE_MS=600

mkdir -p "$STATE_DIR" 2>/dev/null || true
now() { date +%s%3N; }

# Focus a window by address, on either kind of Hyprland.
#
# This desktop runs the Lua config: `hyprctl dispatch` wraps whatever it is given
# in `return hl.dispatch(...)`, so the argument has to be a DISPATCHER object and
# the stock `focuswindow address:0x…` is a Lua syntax error that answers
# "error: … ')' expected near 'address'" and does nothing. Measured here: the
# plain form silently left the focus where it was, which is how a "restore" can
# look implemented and paste into the wrong window anyway. So try the dispatcher
# this config itself uses (see cover.lua focusAddr), then the stock command, and
# let the caller decide whether it worked by asking Hyprland who is focused.
focus_address() {
    local target="$1"
    hyprctl dispatch "hl.dsp.focus({ window = hl.get_window(\"address:$target\") })" >/dev/null 2>&1
    sleep 0.05
    [ "$(active_window | cut -d' ' -f1)" = "$target" ] && return 0
    hyprctl dispatch focuswindow "address:$target" >/dev/null 2>&1
    return 0
}

# "0x55d3… com.example.App" for whatever window Hyprland considers active.
active_window() {
    hyprctl activewindow -j 2>/dev/null | python3 -c '
import json, sys
try:
    window = json.load(sys.stdin)
except Exception:
    sys.exit(0)
address = window.get("address") or ""
if address in ("", "0x0"):
    sys.exit(0)
print(address, window.get("class") or "")
' 2>/dev/null
}

# ── the "remember" half: called by the popup when it opens ──────────────────
if [ "${1:-}" = "remember" ]; then
    target="$(active_window)"
    if [ -n "$target" ]; then
        printf '%s\n' "$target" >"$OWNER_FILE"
    fi
    exit 0
fi

# FOCUS-FOLLOWS-MOUSE IS SWITCHED OFF FOR THIS PASTE.
#
# `input:follow_mouse = 1` on this desktop means ANY pointer motion re-focuses
# whatever window is under the cursor. So the popup closing, the remembered
# window taking the keyboard back, and the chord going out are three separate
# moments -- and a hand that moves the mouse in between (which it always does:
# the click on an entry is followed by moving away) hands the keyboard to the
# window under the cursor again, tens of milliseconds before Ctrl+V is sent.
# That is exactly "the clipboard value goes into the window I was hovering, not
# the one I selected", with the script's own log happily saying the focus was
# restored, because it was -- and then it was stolen again.
#
# `hyprctl keyword` does not work on this build ("keyword can't work with
# non-legacy parsers"), the option goes through the Lua config instead. The old
# value is put back no matter how this script ends, and never left at 0.
follow_mouse="$(hyprctl getoption input:follow_mouse 2>/dev/null | sed -n 's/^int: *//p' | head -1)"
restore_follow_mouse() {
    if [ -n "${follow_mouse:-}" ] && [ "${follow_mouse:-1}" != "0" ]; then
        hyprctl eval "hl.config({ input = { follow_mouse = $follow_mouse } })" >/dev/null 2>&1
    fi
    return 0
}
trap restore_follow_mouse EXIT INT TERM
if [ -n "${follow_mouse:-}" ] && [ "${follow_mouse:-0}" != "0" ]; then
    hyprctl eval 'hl.config({ input = { follow_mouse = 0 } })' >/dev/null 2>&1
fi

start_ms=$(now)

# ── 1. the popup's surface has to be gone ───────────────────────────────────
while :; do
    if ! hyprctl layers 2>/dev/null | grep -q "namespace: quickshell:clipboard"; then
        break
    fi
    if [ $(($(now) - start_ms)) -ge "$LAYER_GONE_DEADLINE_MS" ]; then
        break
    fi
    sleep 0.02
done
layer_ms=$(($(now) - start_ms))

# ── 2. the window the popup was opened from gets the keyboard back ──────────
owner_addr=""
owner_class=""
if [ -r "$OWNER_FILE" ]; then
    read -r owner_addr owner_class <"$OWNER_FILE" || true
fi

restored="none"
if [ -n "$owner_addr" ]; then
    current="$(active_window)"
    if [ "${current%% *}" != "$owner_addr" ]; then
        focus_address "$owner_addr"
        deadline=$((start_ms + FOCUS_DEADLINE_MS))
        while [ "$(now)" -lt "$deadline" ]; do
            [ "$(active_window | cut -d' ' -f1)" = "$owner_addr" ] && break
            sleep 0.02
        done
        # Reported, because a restore that did not take is the difference between
        # "pasted into the app" and "pasted into whatever the pointer was on".
        if [ "$(active_window | cut -d' ' -f1)" = "$owner_addr" ]; then
            restored="yes"
        else
            restored="failed"
        fi
    else
        restored="already"
    fi
fi
owner_ms=$(($(now) - start_ms - layer_ms))

# ── 3. some application has to hold the keyboard ────────────────────────────
# The popup unmapping and the keyboard being handed back are two events, and a
# keystroke that falls between them goes to nothing at all.
focus_class=""
focus_ms=0
while :; do
    focus_class="$(active_window | cut -d' ' -f2-)"
    case "$focus_class" in
        ""|quickshell*|qs-*) ;;
        *) break ;;
    esac
    if [ "$focus_ms" -ge "$FOCUS_DEADLINE_MS" ]; then
        break
    fi
    sleep 0.02
    focus_ms=$(($(now) - start_ms - layer_ms - owner_ms))
done

# ── 4. put the caret back where the user clicked ────────────────────────────
# "already" means the app kept its caret; "focused" means one was found and
# given the focus; "no-entry"/"no-a11y" mean this app does not expose its
# widgets, and the keys go wherever the app last had the caret.
caret="skipped"
if [ -r "$FOCUS_HELPER" ]; then
    caret="$(timeout 2s python3 "$FOCUS_HELPER" 2>/dev/null)" || caret="error"
    [ "$caret" = "focused" ] && sleep 0.15   # let the toolkit move the caret
fi

# Let the client notice it has been refocused. A window that has just been handed
# the keyboard processes the focus event before it accepts input, and a paste
# sent into that gap is dropped. This is about one frame plus the client's own
# event handling, and is far below the delay a person would notice.
sleep 0.12

# Last check before the key: is the remembered window still the focused one?
# With follow_mouse held off it should be; if something else managed to take it
# anyway (a window opening, a workspace switch), take it back now.
if [ -n "$owner_addr" ]; then
    focus_address "$owner_addr"
    sleep 0.05
fi

# One line per paste, for the next time this misbehaves: which window the popup
# came from, whether the keyboard had to be taken back, both handover timings,
# what the caret helper answered, and whether the pointer was free to steal the
# focus at that moment. The pasted text is never logged.
follow_now="$(hyprctl getoption input:follow_mouse 2>/dev/null | sed -n 's/^int: *//p' | head -1)"
printf '%s owner=%s class=%s restored=%s layer=%sms owner_wait=%sms focus=%sms caret=%s follow=%s\n' \
    "$(date +%H:%M:%S)" "${owner_addr:-none}" "${focus_class:-none}" "$restored" \
    "$layer_ms" "$owner_ms" "$focus_ms" "$caret" "${follow_now:-?}" \
    >>"$PASTE_LOG" 2>/dev/null || true

# PASTE_DRY_RUN=1 stops before the keystroke: the targeting, the handover and
# the caret work can then be exercised without typing into whatever is focused.
if [ "${PASTE_DRY_RUN:-0}" = "1" ]; then
    exit 0
fi

ydotool key -d 1 29:1 47:1 47:0 29:0
status=$?
# The key is delivered by the compositor to whoever holds the keyboard at that
# instant, which just happened; a moment is enough for the app to take the
# selection, and only then does pointer-follows-focus come back.
sleep 0.12
restore_follow_mouse
trap - EXIT
exit $status
