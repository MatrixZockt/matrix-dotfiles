import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.modules.common

/**
 * The one-pixel-scale answer to "is this desktop floating?".
 *
 * SUPER + D detaches every window on the desktop and is pressable again to put
 * them back (custom/general.lua, toggleWorkspaceFloat). That is a mode with no
 * other tell: the windows look exactly as they did, they simply move under the
 * pointer now, and a mode you cannot see is a mode you press twice by mistake.
 * So a dot -- 7px, the accent colour, bottom centre, above where the desktop
 * pill lives -- is drawn for as long as the ACTIVE desktop is in float mode, and
 * it pulses once when the mode changes so the press itself is answered.
 *
 * Deliberately not a notification and not a label: nothing to read, nothing to
 * dismiss, no text, no card. It is a status light, and it is per desktop,
 * because the mode is per desktop -- desktop 3 floating says nothing about
 * desktop 5.
 *
 * HOW IT LEARNS. The compositor does the toggling, so the compositor says so:
 * toggleWorkspaceFloat ends with
 *
 *     qs -c ii ipc call floatMode set <workspace id> <0|1>
 *
 * and this holds the set of desktops that call has named. The surface itself
 * stays MAPPED and only its contents change -- toggling `visible` on a layer
 * surface remaps it, and every remap flashes the whole desktop (the lesson the
 * dock and the desktop pill both already paid for). It draws nothing and owns
 * no input when the active desktop is not in the set.
 */
Scope {
    id: root

    // Desktop (Hyprland workspace) id -> true, for every desktop SUPER+D has
    // left in float mode. String keys: this crosses IPC as JSON.
    property var floatDesktops: ({})
    // The desktop whose mode changed last, and a flag for the single pulse that
    // answers it. Per instance this is shared: there is one screen here, and on
    // several the pulse is a beat of feedback either way.
    property int lastChanged: -1
    property bool pulse: false

    function isFloat(id) {
        return !!root.floatDesktops[String(id)];
    }

    function setFloat(id, on) {
        const key = String(id);
        if (isNaN(Number(key))) return;
        const next = Object.assign({}, root.floatDesktops);
        if (on) next[key] = true;
        else delete next[key];
        root.floatDesktops = next;
        root.lastChanged = Number(key);
        // The dot itself answers the press: a short swell and settle. Re-running
        // it on a repeat press of the same state is the point -- a press that
        // changed nothing still gets an answer.
        dotPulse.restart();
    }

    function clearAll() {
        root.floatDesktops = ({});
        root.lastChanged = -1;
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: surface
            required property var modelData
            screen: modelData

            readonly property var monitor: Hyprland.monitorFor(surface.modelData)
            readonly property int activeId: surface.monitor?.activeWorkspace?.id ?? -1
            readonly property bool on: root.isFloat(surface.activeId)

            color: "transparent"
            WlrLayershell.namespace: "quickshell:floatMode"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: -1
            // 44 clears the desktop pill (bottom margin 12 plus its own height),
            // so the two never draw into each other.
            anchors.bottom: true
            margins.bottom: 44
            implicitWidth: 20
            implicitHeight: 20
            // Always mapped; the dot inside is what comes and goes.
            visible: true
            // Picture, not a target: nothing here is clickable, so it must never
            // swallow a press aimed at the window underneath.
            mask: Region {}

            Item {
                id: dotRoot
                anchors.centerIn: parent
                width: 20
                height: 20
                opacity: surface.on ? 1 : 0
                scale: 1

                Behavior on opacity {
                    NumberAnimation {
                        duration: surface.on ? 140 : 260
                        easing.type: Easing.OutCubic
                    }
                }

                // A halo, not decoration: the dot has to stay visible over a
                // white document as well as over a dark terminal, and 7px of
                // accent colour alone disappears on a light window. At 22% it
                // reads as the same dot on any background without turning into
                // a badge.
                Rectangle {
                    anchors.centerIn: parent
                    width: 13
                    height: 13
                    radius: 6.5
                    color: Appearance.colors.colPrimary
                    opacity: 0.22
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 7
                    height: 7
                    radius: 3.5
                    color: Appearance.colors.colPrimary
                    opacity: 0.95
                }
            }

            SequentialAnimation {
                id: dotPulse
                running: false
                // A press that turned the mode ON pulses the dot it just showed;
                // a press that turned it OFF gives the fading dot the same beat,
                // so both directions are answered by the same tell.
                NumberAnimation { target: dotRoot; property: "scale"; to: 1.6; duration: 120; easing.type: Easing.OutCubic }
                NumberAnimation { target: dotRoot; property: "scale"; to: 1; duration: 220; easing.type: Easing.InOutCubic }
            }
        }
    }

    IpcHandler {
        target: "floatMode"

        // qs -c ii ipc call floatMode set <desktop> <0|1>
        function set(id: string, on: string): void {
            root.setFloat(Number(String(id)), String(on) === "1" || String(on) === "true");
        }
        // qs -c ii ipc call floatMode clear
        function clear(): void {
            root.clearAll();
        }
        // qs -c ii ipc call floatMode state
        function state(): string {
            return JSON.stringify({
                floatDesktops: Object.keys(root.floatDesktops),
                lastChanged: root.lastChanged
            });
        }
    }
}
