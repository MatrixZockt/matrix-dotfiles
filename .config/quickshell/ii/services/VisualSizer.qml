pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

import qs.services
import qs.modules.common

/**
 * The visual window sizer (the "option D" resize tool) -- state and IPC.
 * The overlay itself (frame, handles, drag logic) lives in
 * modules/ii/visualSizer/VisualSizerWindow.qml, which is mounted by the
 * panel family like every other layer surface; a Singleton cannot own a
 * window, so this object only carries the state the window renders.
 *
 * Arming it freezes a full-screen OVERLAY layer around the focused window:
 * an accent-colored frame hugging the window's exact box, with eight drag
 * handles (4 corners, 4 edges) and a center drag surface for moving. Dragging
 * a handle resizes the window live, one cheap pixel dispatch per pointer
 * frame; the arrow keys nudge the size; Escape/Enter, a click on any other
 * window, or 15 seconds of inactivity all disarm it.
 *
 * Why an overlay instead of dispatching the compositor's SUPER+right-drag:
 * the handles are visible targets -- you can SEE what you are about to grab,
 * including on a touchscreen where no SUPER is available, and the accent
 * border makes the resizable surface obvious against any wallpaper.
 *
 * Arming paths:
 *   * IPC:              qs -c ii ipc call sizer arm "0x..."   (or no arg = focused)
 *   * keybind:          SUPER+SHIFT+R (custom/keybinds.lua, armed from Lua)
 *   * dock right-click: "Resize…" menu item calls VisualSizer.arm(addr) in-process
 */
Singleton {
    id: root

    readonly property bool armed: root.targetAddr !== ""
    // The Hyprland address (with 0x) of the window being resized.
    property string targetAddr: ""
    // Current box, in LOGICAL pixels (same space as client at/size values).
    property real winX: 0
    property real winY: 0
    property real winW: 0
    property real winH: 0
    readonly property bool targetFloating: root._targetFloating

    // Drag session state (bitfield: 1=N 2=E 4=S 8=W; 0 = moving).
    property int dragMode: 0
    property bool dragging: false
    property real pressX: 0
    property real pressY: 0
    property real origX: 0
    property real origY: 0
    property real origW: 0
    property real origH: 0

    property bool _targetFloating: true

    readonly property int minW: 220
    readonly property int minH: 140
    readonly property real nudgeStep: 6
    readonly property real nudgeStepBig: 24

    function arm(addrString) {
        // Accept anything: "0x..." (hyprctl), bare hex (QML HyprlandToplevel
        // addresses have no prefix), even a doubled "0x0x..." from copy-paste
        // confusion between the two formats. Normalize to exactly one 0x.
        let addr = (addrString ?? "").trim().replace(/^(0x)+/i, "");
        if (!addr) {
            const t = Hyprland.activeToplevel?.HyprlandToplevel;
            addr = t?.address ? `${t.address}` : "";
            if (!addr) {
                // The event-driven cache can be cold (fresh shell, no focus
                // change since): ask the compositor who is focused right now.
                focusQueryProc.command = ["bash", "-c",
                    `hyprctl -j activewindow | python3 -c "import json,sys;print(json.load(sys.stdin).get('address',''))"`];
                focusQueryProc.running = true;
                return true; // continues in the collector's callback
            }
        }
        if (!addr) {
            return false;
        }
        root.targetAddr = `0x${addr}`;
        root.dragging = false;
        root.dragMode = 0;
        root.syncGeometry();
        timeoutTimer.restart();
        // Keep the session's keyboard on this frame even if the user's last
        // click was inside a popup app (their layer surfaces can hold
        // exclusive keyboard and would otherwise swallow the arrow nudges).
        GlobalFocusGrab.dismiss();
        return true;
    }

    function disarm() {
        root.targetAddr = "";
        root.dragging = false;
        root.dragMode = 0;
        timeoutTimer.stop();
    }

    // Keep the auto-dismiss alive while the user is actively dragging or
    // nudging (the overlay calls this; ids inside the singleton are not
    // reachable from outside, so the timer is driven through this API).
    function bumpTimeout() {
        if (root.armed)
            timeoutTimer.restart();
    }

    function state(): string {
        if (!root.armed)
            return "armed=false";
        return `armed=true target=${root.targetAddr} box=${Math.round(root.winX)},${Math.round(root.winY)} ${Math.round(root.winW)}x${Math.round(root.winH)} floating=${root._targetFloating} dragging=${root.dragging} accent=${Appearance.colors.colPrimary}`;
    }

    // Pull the target's live box from the compositor (by address).
    function syncGeometry() {
        if (!root.armed)
            return;
        geoProc.command = ["bash", "-c",
            `hyprctl -j clients | python3 -c "import json,sys;a='${root.targetAddr}';c=next((x for x in json.load(sys.stdin) if x['address']==a),None);print(json.dumps({'at':c['at'],'size':c['size'],'floating':c['floating']}) if c else '{}')"`];
        geoProc.running = true;
    }

    function applyGeometry(text) {
        let d = {};
        try { d = JSON.parse(text || "{}"); } catch (e) { return; }
        if (!d.at || !d.size)
            return; // window gone
        root._targetFloating = !!d.floating;
        root.winX = d.at[0]; root.winY = d.at[1];
        root.winW = d.size[0]; root.winH = d.size[1];
    }

    // Push the current box to the compositor. Move is skipped when the box
    // did not translate (pure edge resize), so tiled windows resize in place.
    function commit() {
        if (!root.armed)
            return;
        const w = `"address:${root.targetAddr}"`;
        Hyprland.dispatch(`hl.dsp.window.resize({ window = ${w}, x = ${Math.round(root.winW)}, y = ${Math.round(root.winH)} })`);
        if (root._targetFloating)
            Hyprland.dispatch(`hl.dsp.window.move({ window = ${w}, x = ${Math.round(root.winX)}, y = ${Math.round(root.winY)} })`);
    }

    Process {
        id: geoProc
        stdout: StdioCollector {
            onStreamFinished: root.applyGeometry(text)
        }
    }

    // The "arm on the focused window" fallback for a cold activeToplevel
    // cache: re-enters arm() with the compositor's answer.
    Process {
        id: focusQueryProc
        stdout: StdioCollector {
            onStreamFinished: {
                const a = text.trim();
                if (a)
                    root.arm(a);
            }
        }
    }

    Timer {
        id: timeoutTimer
        interval: 15000
        onTriggered: root.disarm()
    }

    // A click on any OTHER window means the user moved on: disarm. Layer-shell
    // keyboard focus does not change Hyprland's focused toplevel, so this only
    // fires for real windows.
    Connections {
        target: Hyprland
        function onActiveToplevelChanged() {
            if (!root.armed || root.dragging)
                return;
            const addr = Hyprland.activeToplevel?.HyprlandToplevel?.address;
            if (!addr)
                return; // a layer surface took focus (e.g. a panel): ignore
            if (`0x${addr}` !== root.targetAddr)
                root.disarm();
        }
    }

    IpcHandler {
        target: "sizer"

        // IPC parameters are required, so the "use the focused window" path
        // gets its own function; the keybind calls this one.
        function armFocused(): void {
            root.arm("");
        }
        function arm(addr: string): void {
            root.arm(addr);
        }
        function cancel(): void {
            root.disarm();
        }
        function state(): string {
            return root.state();
        }
    }
}
