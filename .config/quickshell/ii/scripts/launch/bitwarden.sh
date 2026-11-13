#!/usr/bin/env bash
# Bitwarden, opened so the FIRST press shows the window.
#
# The app has "start to tray" enabled in its own settings (`startToTray` in
# ~/.config/Bitwarden/data.json), and it means it literally: a start maps no
# window at all. The tray icon appears, the vault runs, nothing is on screen.
# A start while an instance is ALREADY running is different -- the new
# process hands over to the running one and the running one shows itself --
# which is why the app has always needed two clicks.
#
# Measured on this machine (hyprctl clients, 0.5s sampling):
#
#   cold start        (no instance)          -> 0 windows after 20s, tray icon only
#   start when hidden (instance, no window)  -> window after ~1.5s
#   start when shown  (window already up)    -> window stays, nothing happens
#
# So this does the second click itself, and only when it is needed: a start
# that produced no window within GRACE gets one nudge, which is exactly the
# start the user used to perform by hand. Nothing here touches Bitwarden's own
# settings -- the tray icon at login and close-to-tray both keep working.
#
# It also refuses to add a pointless start when a window is already open: the
# app would ignore it, so the launcher focuses what is there instead.
set -u

app="${BITWARDEN_BIN:-bitwarden-desktop}"
# How long a start gets to produce a window before it is assumed to have gone
# to the tray. The window of a *showing* start appears at ~1.5s, so anything
# past the grace is the tray case and not a slow one.
grace_ms=3000
timeout_ms=15000

# Prints "<address> <workspace-id>" for the app's own toplevels, one per line.
# `hyprctl clients -j` is one JSON blob, so it is parsed rather than grepped --
# the field order in that blob is not ours to rely on. The match is the
# Electron WM class (StartupWMClass=Bitwarden in the .desktop file), the same
# thing the float rule in hypr/rules.lua keys on. A browser tab merely titled
# "... - Bitwarden" carries a different class and cannot pass for the app.
bitwarden_windows() {
    hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    clients = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in clients:
    if c.get("class") == "Bitwarden":
        print(c.get("address", ""), (c.get("workspace") or {}).get("id", ""))
'
}

read -r existing wsid <<<"$(bitwarden_windows | head -1)"

if [ -n "${existing:-}" ]; then
    # Already on screen: bring it to the front rather than start a copy the
    # app is going to ignore. The workspace switch comes first because
    # focusing a window on another workspace is a silent no-op (the shell's
    # own focus helper, GlobalStates.qml, does the same two steps).
    [ -n "${wsid:-}" ] && hyprctl dispatch "hl.dsp.focus({ workspace = ${wsid} })" >/dev/null 2>&1
    hyprctl dispatch "hl.dsp.focus({ window = hl.get_window(\"address:${existing}\") })" >/dev/null 2>&1
    exit 0
fi

start_ms=$(date +%s%3N)
deadline_ms=$(( start_ms + timeout_ms ))
nudged=0

"$app" "$@" &
started=$!

# Poll rather than sleep a guessed amount: on a warm profile the window is up
# in well under a second, and on a cold one the nudge must not fire while the
# app is still reading its data directory.
while :; do
    now=$(date +%s%3N)
    if [ -n "$(bitwarden_windows)" ]; then
        # Stay with the app, as open.sh does: the pid chain from the shell's
        # launcher down to the window's process is what tells the compositor
        # this window was opened from here (and should join the layout rather
        # than float like the browser extension's copy).
        wait "$started" 2>/dev/null
        exit 0
    fi
    if [ "$nudged" -eq 0 ] && [ $(( now - start_ms )) -ge "$grace_ms" ]; then
        nudged=1
        # The start the user used to make by hand: it finds the instance
        # above, hands over, and that instance shows its window.
        "$app" "$@" >/dev/null 2>&1
        continue
    fi
    [ "$now" -ge "$deadline_ms" ] && break
    sleep 0.1
done

# No window in 15s. Leave the app running (it may still be migrating or
# waiting on a slow profile) rather than kill a vault that is about to appear.
kill -0 "$started" 2>/dev/null || exit 1
wait "$started" 2>/dev/null
exit 0
