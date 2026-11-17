#!/usr/bin/env bash
# Send Ctrl+V to the focused window -- once a window actually HAS the keyboard,
# and once that window's text field has the CARET again.
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
# WHY THE CARET HAS TO BE PUT BACK (the second half of the same report: "the
# paste is not where I clicked"):
#
#   Taking the keyboard away and handing it back does not restore WHERE the text
#   field's caret was. A window can be perfectly focused while no input box is
#   selected -- GTK and Electron both drop the widget's focus on keyboard leave,
#   and a chat app you had clicked into comes back with the window active and the
#   message box unfocused. Ctrl+V then goes to a window with nowhere to put the
#   text, and the sentence is lost with no error anywhere. There is no Wayland
#   call for "where is the text field", so this asks the accessibility tree --
#   the same helper the SUPER dictation uses before it types, because it is the
#   same problem. Apps that publish no tree answer "no-a11y" and keep the old
#   behaviour.
#
# The keystroke itself is ydotool -- a real Ctrl+V at the kernel input layer,
# the command the shell's own stash branch has always used -- rather than
# Hyprland's `send_shortcut` dispatcher: that one answers "ok" and the key never
# reaches the client (verified against a live terminal, where nothing arrived).
set -u

# Never hang: if the popup is somehow still mapped after this, paste anyway
# rather than silently dropping the user's Enter.
LAYER_GONE_DEADLINE_MS=2000
# How long to wait for an application window to hold the keyboard again. One
# frame is enough when nothing is busy; the ceiling is what a person would not
# notice on a loaded machine.
FOCUS_DEADLINE_MS=600

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/ii-clipboard"
PASTE_LOG="$STATE_DIR/paste.log"
FOCUS_HELPER="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/custom/scripts/dictate-focus.py"

mkdir -p "$STATE_DIR" 2>/dev/null || true

start_ms=$(date +%s%3N)
now() { date +%s%3N; }

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

# ── 2. an application has to hold the keyboard again ────────────────────────
# The popup unmapping and the keyboard being handed back are two events, and a
# keystroke that falls between them goes to nothing at all. Ask Hyprland who is
# focused until the answer is a real window (empty means the transition is still
# in progress; a quickshell surface is not a paste target).
focus_ms=0
focus_class=""
while :; do
    read -r focus_class <<EOF
$(hyprctl activewindow -j 2>/dev/null \
    | sed -n 's/.*"class": *"\([^"]*\)".*/\1/p' | head -1)
EOF
    case "$focus_class" in
        ""|quickshell*|qs-*) ;;
        *) break ;;
    esac
    if [ "$focus_ms" -ge "$FOCUS_DEADLINE_MS" ]; then
        break
    fi
    sleep 0.02
    focus_ms=$(($(now) - start_ms - layer_ms))
done

# ── 3. put the caret back where the user clicked ────────────────────────────
# "already" means the app kept its caret; "focused" means one was found and
# given the focus; "no-entry"/"no-a11y" mean this app does not expose its
# widgets and there is nothing more to do than send the keys.
caret="skipped"
if [ -r "$FOCUS_HELPER" ]; then
    caret="$(timeout 2s python3 "$FOCUS_HELPER" 2>/dev/null)" || caret="error"
    case "$caret" in
        focused) sleep 0.15 ;;   # let the toolkit move the caret before the key
        *);;
    esac
fi

# Let the client notice it has been refocused. A window that has just been handed
# the keyboard processes the focus event before it accepts input, and a paste
# sent into that gap is dropped. This is about one frame plus the client's own
# event handling, and is far below the delay a person would notice.
sleep 0.12

# One line per paste, for the next time this misbehaves: which window got the
# keys, how long the two handovers took, and what the caret helper answered.
# The pasted text is never logged.
printf '%s class=%s layer=%sms focus=%sms caret=%s\n' \
    "$(date +%H:%M:%S)" "${focus_class:-none}" "$layer_ms" "$focus_ms" "$caret" \
    >>"$PASTE_LOG" 2>/dev/null || true

# PASTE_DRY_RUN=1 stops before the keystroke: the handover and the caret work
# can then be exercised without typing into whatever happens to be focused.
if [ "${PASTE_DRY_RUN:-0}" = "1" ]; then
    exit 0
fi

exec ydotool key -d 1 29:1 47:1 47:0 29:0
