//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// ── The "Quickshell reloaded" card ──────────────────────────────────────────
//
// Shown by reload-shell.sh once the shell is actually answering IPC again.
//
// WHY THIS EXISTS AS A SEPARATE CONFIG RATHER THAN THE REAL THING. Quickshell's
// own reload popup (ii/ReloadPopup.qml) is driven by `Quickshell.onReloadCompleted`
// -- a signal that is only emitted for an IN-PLACE reload, when a config file
// changes under a running shell. A restart never emits it, so on this reload
// path the real popup can never appear, no matter what the shell's config says.
// It is also switched off outright in shell.qml (`QS_NO_RELOAD_POPUP=1`).
//
// So this is that popup, reproduced: same top-centre placement, same card size
// and radius, same colours, same label, and the same shrinking bar along the
// bottom that says how long the message has left. What is dropped is the reload
// plumbing (there is nothing to listen to) and the failure branch (a reload
// that failed shows nothing at all -- see reload-shell.sh).
//
// It quits itself when the bar runs out, exactly like the real one, and a click
// dismisses it early. NOT focusable, so it never takes a keypress.

import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property color cardBg: "#ffD1E8D5"
    readonly property color cardFg: "#ff0C1F13"

    PanelWindow {
        id: popup

        anchors.top: true
        margins.top: 0
        exclusiveZone: 0
        focusable: false

        implicitWidth: rect.width + shadow.radius * 2
        implicitHeight: rect.height + shadow.radius * 2
        color: "transparent"

        WlrLayershell.namespace: "quickshell:green-reloaded"

        Rectangle {
            id: rect
            anchors.centerIn: parent
            color: root.cardBg
            implicitHeight: layout.implicitHeight + 30
            implicitWidth: layout.implicitWidth + 30
            radius: 12

            // Fills the card, so a click anywhere on it dismisses it.
            MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                onPressed: Qt.quit()
            }

            ColumnLayout {
                id: layout
                spacing: 10
                anchors {
                    top: parent.top
                    topMargin: 10
                    horizontalCenter: parent.horizontalCenter
                }

                Text {
                    renderType: Text.NativeRendering
                    font.family: "Google Sans Flex"
                    font.pointSize: 14
                    text: "Quickshell reloaded"
                    color: root.cardFg
                }
            }

            // The bar: how long the message has left, running out.
            Rectangle {
                z: 2
                id: bar
                color: root.cardFg
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.margins: 10
                height: 5
                radius: 9999

                PropertyAnimation {
                    id: anim
                    target: bar
                    property: "width"
                    from: rect.width - bar.anchors.margins * 2
                    to: 0
                    duration: 1000
                    onFinished: Qt.quit()
                    // Stays put while the pointer is on the card, so a message
                    // being read does not vanish underneath it.
                    paused: mouseArea.containsMouse
                }
            }
            Rectangle {
                z: 1
                id: barBg
                color: "#4027643e"
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.margins: 10
                height: 5
                radius: 9999
                width: rect.width - bar.anchors.margins * 2
            }

            Component.onCompleted: anim.start()
        }

        DropShadow {
            id: shadow
            anchors.fill: rect
            horizontalOffset: 0
            verticalOffset: 2
            radius: 6
            samples: radius * 2 + 1
            color: "#44000000"
            source: rect
        }
    }
}
