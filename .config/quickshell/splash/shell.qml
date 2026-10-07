//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// ── The startup backdrop (silent) ──────────────────────────────────────────
//
// THIS USED TO SAY "Starting ii…". It does not any more, and there is nothing
// here to bring it back: no card, no BusyIndicator, no Text, no glyph. The
// whole config is one full-screen rectangle.
//
// WHY IT IS BLANK. The user asked for the message to be removed permanently,
// and the honest way to do that is to delete the thing that drew it rather
// than to rename the string or hide it behind a property. A "starting…"
// caption on a shell that takes ~2.4 s to map its first layer is noise: by
// the time anyone could read it, the desktop it describes is already there.
//
// WHAT IS LEFT, AND WHY IT IS NOT WORTH DELETING. The one useful part of
// this file was never the words -- it was arriving FAST. Between Hyprland
// accepting a client and `qs -c ii` finishing loading there is a window in
// which the screen shows Hyprland's `misc:background_color` (#0A0A0A, measured
// on this machine, effectively black). This config imports almost nothing and
// maps its surface in ~0.24 s, so it puts a flat #141414 there before the
// desktop arrives. #141414 against #0A0A0A is a difference you cannot see
// across a desk; what you do not get is the black flash, and nothing appears
// in the gap that was not already there.
//
// If this file is ever deleted outright, the only cost is that #0A0A0A flash
// at login. Nothing in `ii` knows this config exists and nothing depends on
// its contents -- splash.sh matches on the PROCESS (`qs -c splash`), not on
// anything drawn here -- so deleting it is safe too, if the flash is
// preferred to the maintenance.
//
// WHY IT IS DISMISSED FROM OUTSIDE. Nothing in `ii` knows this exists, and
// adding a "tell the backdrop I'm ready" call to that config would mean
// editing the desktop's startup path for a cosmetic feature. Instead
// splash.sh watches Hyprland for a `quickshell:*` layer belonging to a
// `qs -c ii` process -- the real desktop actually being on screen -- and
// kills this. The shell needs to know nothing, and a shell that fails or
// hangs still ends with no backdrop, because the watcher has a hard timeout.
//
// NOT FOCUSABLE, so it can never take a keypress during login.

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    // Prefixed names, not `surface`/`primary`/`outline`: ShellRoot already
    // declares members under several of the obvious names, and redeclaring one
    // as a property fails the whole config at load with "Cannot assign a
    // value to a signal". This is the dark desktop's background, from
    // custom/theme.lua and MaterialThemeLoader.
    readonly property color splashBg: "#141414"

    PanelWindow {
        id: overlay

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        exclusiveZone: 0
        // Never take focus, never take the keyboard away from the greeter's
        // successor during the login handshake.
        focusable: false
        color: root.splashBg

        WlrLayershell.namespace: "quickshell:splash"

        // Deliberately no children. Anything drawn in here would be a message
        // about a shell that is already, by the time it appears, on screen.
    }
}