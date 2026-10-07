//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// ── The "Reloading Quickshell" indication ───────────────────────────────────
//
// Shown the instant SUPER+CTRL+B is pressed, while the shell is being torn down
// and reloaded. It is a separate config (like green-reloaded) because it has to
// draw while the shell itself is gone -- there is no notification daemon on this
// desktop, the shell IS the daemon, so the only thing that can speak during the
// reload is another qs process.
//
// Deliberately as plain as it can be: a card, a label, a bar. It is on screen
// for the whole reload, sitting on the same GPU and the same CPU that is busy
// compiling the real shell, so anything decorative here would be paying for
// itself out of the reload's budget.
//
// The bar is the same device the natural popup uses (see ii/ReloadPopup.qml):
// its width runs out over the time the card expects to live, so it doubles as
// "how much longer". 12s covers an ordinary restart on this machine (measured
// 11-12s idle); the reload script takes it down early the moment the real shell
// answers, so a slow reload does not leave a bar that ran out lying on screen.
//
// NOT focusable: it must never take the keypress that started the reload.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property color cardBg: "#ffD9E2F0"
    readonly property color cardFg: "#ff0C1F13"

    // Backstop only. The reload script dismisses this card when the shell is
    // back; this makes sure a card whose script died cannot sit there forever.
    Timer {
        interval: 12000
        running: true
        onTriggered: Qt.quit()
    }

    PanelWindow {
        id: popup

        anchors.top: true
        margins.top: 0
        exclusiveZone: 0
        focusable: false

        implicitWidth: rect.width + 24
        implicitHeight: rect.height + 24
        color: "transparent"

        WlrLayershell.namespace: "quickshell:reloading-shell"

        Rectangle {
            id: rect
            anchors.centerIn: parent
            color: root.cardBg
            implicitHeight: layout.implicitHeight + 30
            implicitWidth: layout.implicitWidth + 30
            radius: 12

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
                    text: "Reloading Quickshell…"
                    color: root.cardFg
                }
            }

            // The bar: the time this card expects to be up, running out.
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
                    duration: 12000
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
    }
}
