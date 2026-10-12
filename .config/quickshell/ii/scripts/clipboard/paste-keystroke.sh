#!/usr/bin/env bash
# Send Ctrl+V to the focused window -- once a window actually HAS the keyboard.
#
# This is the second half of the clipboard popup's paste. The first half is
# Cliphist.paste(), which decodes the chosen entry back onto the clipboard; the
# keystroke that actually pastes it is sent here, and it is sent from a script
# rather than a one-liner inside the QML because the whole difficulty is WHEN
# it is sent -- timing that is worth being able to run and watch by hand.
#
# WHY THE WAIT IS REQUIRED (the bug this replaces):
#
#   The popup holds the keyboard EXCLUSIVELY while it is open
#   (WlrKeyboardFocus.Exclusive in ClipboardListWindow.qml -- so the arrows and
#   RETURN work without a click first). A synthesised Ctrl+V goes to whatever
#   holds the keyboard at that instant, so a paste fired while the popup was
#   still up landed in the popup's OWN search field, and the window the user
#   wanted to paste into got nothing. Retrying after the popup happened to have
#   closed sometimes landed, which is exactly the reported "it pastes on the
#   twentieth try".
#
#   What has to be gone is the popup's layer surface: `hyprctl layers` lists it
#   as `namespace: quickshell:clipboard` while it is mapped and does not list it
#   once it is closed (measured: 1 line open, 0 lines closed). So this waits for
#   THAT -- not for a fixed sleep, and not on `hyprctl activewindow`, which
#   keeps reporting the window underneath for the whole time the popup is up
#   and so cannot tell the two states apart.
#
# The keystroke itself is ydotool -- a real Ctrl+V at the kernel input layer,
# the command the shell's own stash branch has always used -- rather than
# Hyprland's `send_shortcut` dispatcher: that one answers "ok" and the key never
# reaches the client (verified against a live terminal, where nothing arrived).
set -u

# Never hang: if the popup is somehow still mapped after this, paste anyway
# rather than silently dropping the user's Enter.
LAYER_GONE_DEADLINE_MS=2000

start_ms=$(date +%s%3N)

while :; do
    if ! hyprctl layers 2>/dev/null | grep -q "namespace: quickshell:clipboard"; then
        break
    fi
    now_ms=$(date +%s%3N)
    if [ $((now_ms - start_ms)) -ge "$LAYER_GONE_DEADLINE_MS" ]; then
        break
    fi
    sleep 0.02
done

# Let the client notice it has been refocused. A window that has just been handed
# the keyboard processes the focus event before it accepts input, and a paste
# sent into that gap is dropped. This is about one frame plus the client's own
# event handling, and is far below the delay a person would notice.
sleep 0.12

exec ydotool key -d 1 29:1 47:1 47:0 29:0
