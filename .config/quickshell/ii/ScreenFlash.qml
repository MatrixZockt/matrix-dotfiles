import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * The whole-screen tell.
 *
 * Most status signals ride the bar's indication line -- but the bar is small
 * and the corner card can be missed. When GlobalStates raises a screen-wide
 * alert (the power failsafe flipping the machine to performance, or its
 * return), the entire screen answers with a double blink: a thin border
 * around the full screen that snaps on, off, on again, then fades away,
 * ~1.1 s total. One double-blink per alert -- a flare, not a lamp.
 *
 * Nothing that has a place ON the bar comes through here. A launch failure
 * used to, and painted the whole screen red twice for an event carried by a
 * 2px line; it is reported by the bar's line and its card instead. This
 * window is only for alerts with nowhere else to be seen.
 *
 * Overlay layer with an empty mask: it is a picture, not a target -- it must
 * render over everything, including fullscreen clients, and it must never eat
 * a click, a key or the cursor. Same contract as StatusTell.
 *
 * There is one of these per screen (Variants over Quickshell.screens); a
 * second monitor blinks in the same instant as the first.
 */
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: flashWindow

        required property var modelData
        screen: modelData
        color: "transparent"
        WlrLayershell.namespace: "quickshell:screenFlash"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Border look. "Thin" is a judgement call at 2560x1600: the user
        // picked 3 over 4 -- deliberate, but lighter on the eye.
        readonly property int thickness: 3
        // The border's colour is part of the message: each alert carries a
        // kind, and the kind picks the colour (GlobalStates holds the
        // palette). The colour is latched when the blink starts so a second
        // alert with a different kind mid-fade swaps the frame cleanly.
        property color flashColor: GlobalStates.screenFlashColorError
        Connections {
            target: GlobalStates
            function onScreenFlashTickChanged() {
                flashWindow.flashColor =
                    GlobalStates.screenFlashKind === GlobalStates.screenFireOrange ? GlobalStates.screenFlashColorFire
                    : GlobalStates.screenFlashKind === GlobalStates.screenFlashGreen ? GlobalStates.screenFlashColorGreen
                    : GlobalStates.screenFlashColorError;
                blinkAnim.restart();
            }
        }

        // 0 = invisible, 1 = fully lit. Driven only by blinkAnim below.
        property real borderOpacity: 0.0
        visible: borderOpacity > 0.0

        // One blink per alert, and the alert has to ASK.
        //
        // This used to fire on the rising edge of `loadingFailFlash` as well,
        // so a failed app launch painted a red border around all2560x1600 of
        // the screen -- the full-screen tell for an event that belongs to a
        // 2px line under the bar. That coupling is gone, and deliberately:
        // the bar's indication line already blinks red twice for exactly this
        // (StatusSignal's failure clock), so the screen-wide version was the
        // same message said twice, once at a volume nobody asked for. The
        // line is where a launch failure is reported; this channel is for
        // things with nowhere else to be seen -- the power failsafe pushing
        // the machine into performance, and its return.
        //
        // So the only way in is `pulseScreenFlash`, and the kind it carries
        // picks the colour. Anything that wants a launch failure announced
        // should call `showLoadingError`, which is the bar's line plus the
        // card that says "Couldn't open X".

        SequentialAnimation {
            id: blinkAnim

            // Blink 1: snap on, hold a beat, snap off.
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 1
                duration: 90
            }
            PauseAnimation { duration: 160 }
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 0
                duration: 90
            }
            // The beat between the two blinks. Short enough to read as one
            // event said twice, long enough that the off-gap is unmistakable.
            PauseAnimation { duration: 110 }
            // Blink 2: snap on, hold, then fade all the way out.
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 1
                duration: 90
            }
            PauseAnimation { duration: 200 }
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 0
                duration: 380
                easing.type: Easing.OutQuad
            }
        }

        // Empty input region: the window covers the screen but passes every
        // event through. Without this, one blink per alert would eat one
        // click per alert.
        mask: Region { item: null }

        // Four thin bars, one per screen edge, inside the transparent window.
        Item {
            id: frame
            anchors.fill: parent
            opacity: flashWindow.borderOpacity

            Rectangle { // top
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                }
                height: flashWindow.thickness
                color: flashWindow.flashColor
            }
            Rectangle { // bottom
                anchors {
                    bottom: parent.bottom
                    left: parent.left
                    right: parent.right
                }
                height: flashWindow.thickness
                color: flashWindow.flashColor
            }
            Rectangle { // left
                anchors {
                    top: parent.top
                    bottom: parent.bottom
                    left: parent.left
                }
                width: flashWindow.thickness
                color: flashWindow.flashColor
            }
            Rectangle { // right
                anchors {
                    top: parent.top
                    bottom: parent.bottom
                    right: parent.right
                }
                width: flashWindow.thickness
                color: flashWindow.flashColor
            }
        }
    }
}
