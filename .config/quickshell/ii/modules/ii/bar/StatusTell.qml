import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * The fullscreen tell.
 *
 * Most status signals ride the bar's indication line -- but the bar does not
 * exist over a fullscreen app, and a video or a game is exactly where a
 * "charger connected" blink matters most (the plug, not the movie, made the
 * sound change). So this tiny surface draws the SAME pulse language in the
 * top-right corner, and only while a fullscreen window covers the screen:
 * a 110x3 rounded line, a 380ms blink in the pulse's colour, then gone.
 *
 * Overlay layer with an empty mask: it is a picture, not a target -- it must
 * render over the fullscreen client and it must never eat a click, a key or
 * the cursor.
 */
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: tell
        required property var modelData
        screen: modelData
        color: "transparent"
        WlrLayershell.namespace: "quickshell:statusTell"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        anchors { top: true; right: true }
        margins {
            top: 6
            right: 10
        }

        readonly property var monitor: Hyprland.monitorFor(tell.modelData)
        // A fullscreen window on THIS monitor -- the same reading the dock and
        // the desktop pill use, so every surface agrees on what fullscreen is.
        readonly property bool fullscreenOnMonitor: Hyprland.workspaces.values.some(ws =>
            ws.monitor === tell.monitor && ws.active
            && ws.toplevels.values.some(t => t.wayland?.fullscreen))

        readonly property bool pulseLive: StatusSignal.hasPulse
        // One blink per pulse: the id changes, the blink restarts.
        onPulseLiveChanged: if (pulseLive) blinkAnim.restart()

        implicitWidth: 110
        implicitHeight: 3

        visible: fullscreenOnMonitor && pulseLive
        mask: Region { item: null }

        Rectangle {
            id: blinkBar
            anchors.fill: parent
            radius: height / 2
            color: StatusSignal.pulse?.color ?? Appearance.colors.colPrimary

            SequentialAnimation {
                id: blinkAnim
                NumberAnimation {
                    target: blinkBar
                    property: "opacity"
                    to: 1
                    duration: 90
                }
                PauseAnimation { duration: 200 }
                NumberAnimation {
                    target: blinkBar
                    property: "opacity"
                    to: 0
                    duration: 320
                    easing.type: Easing.OutQuad
                }
            }
            Component.onCompleted: opacity = 0
        }
    }
}
