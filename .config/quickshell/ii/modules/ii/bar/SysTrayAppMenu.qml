pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.modules.common
import qs.modules.common.widgets
import qs.services

// ── The menu on a shell-owned tray icon ──────────────────────────────────
//
// A real tray item opens the app's OWN menu over D-Bus, which
// `SysTrayMenu` renders from a `QsMenuHandle`. Thunderbird has no tray item
// and so no such handle, and `Quickshell.Widgets` has no `Menu` type to
// synthesise one from -- the only things producing a QsMenuHandle are
// registered SNI apps. So this is a small menu of our own, wearing the same
// clothes as `SysTrayMenu` (colLayer0, windowRounding, colLayer0Border,
// 36px RippleButton rows) so it does not read as a different kind of popup
// when it opens beside a real tray menu.
PopupWindow {
    id: root
    // The registry entry this menu belongs to. Null until a row opens it.
    property var entry: null
    // Bound by the caller, which is the only thing that knows whether the
    // app is parked or showing right now. Read fresh on every open rather
    // than cached, so the label cannot go stale.
    property bool appHidden: false

    signal menuClosed
    signal menuOpened(qsWindow: var)

    color: "transparent"
    implicitWidth: background.implicitWidth
    implicitHeight: background.implicitHeight

    function open() {
        root.visible = true;
        root.menuOpened(root);
    }

    function close() {
        root.visible = false;
        root.menuClosed();
    }

    MouseArea {
        anchors.fill: parent
        // The click-away catcher. Without it the menu is a floating card
        // that nothing dismisses, and a menu you cannot cancel is a menu
        // you have to guess the exit of.
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: root.close()

        StyledRectangularShadow {
            target: background
            opacity: background.opacity
        }

        Rectangle {
            id: background
            readonly property real padding: 4
            anchors.centerIn: parent

            color: Appearance.colors.colLayer0
            radius: Appearance.rounding.windowRounding
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
            clip: true

            opacity: 0
            Component.onCompleted: opacity = 1
            implicitWidth: rows.implicitWidth + background.padding * 2
            implicitHeight: rows.implicitHeight + background.padding * 2

            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            ColumnLayout {
                id: rows
                spacing: 0

                // Show / Hide is one row, not two: it always does the
                // thing you did not do last, and a menu with a greyed-out
                // "Hide" when it is already hidden is a row that teaches
                // you nothing.
                RippleButton {
                    id: toggleRow
                    buttonRadius: background.radius - background.padding
                    horizontalPadding: 12
                    implicitWidth: contentItem.implicitWidth + horizontalPadding * 2
                    implicitHeight: 36
                    Layout.fillWidth: true

                    visible: TrayApps.isRunning(root.entry?.cls)
                    releaseAction: () => {
                        TrayApps.toggle(root.entry?.cls);
                        root.close();
                    }

                    contentItem: RowLayout {
                        anchors {
                            verticalCenter: parent.verticalCenter
                            left: parent.left
                            right: parent.right
                            leftMargin: toggleRow.horizontalPadding
                            rightMargin: toggleRow.horizontalPadding
                        }
                        spacing: 8
                        MaterialSymbol {
                            iconSize: 20
                            text: root.appHidden ? "visibility" : "visibility_off"
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: root.appHidden ? "Show" : "Hide to tray"
                        }
                    }
                }

                // Shown only when the app is not running, so an already-
                // hidden app can still be started from its own icon.
                RippleButton {
                    id: openRow
                    buttonRadius: background.radius - background.padding
                    horizontalPadding: 12
                    implicitWidth: contentItem.implicitWidth + horizontalPadding * 2
                    implicitHeight: 36
                    Layout.fillWidth: true

                    visible: !TrayApps.isRunning(root.entry?.cls)
                    releaseAction: () => {
                        TrayApps.launch(root.entry?.cls);
                        root.close();
                    }

                    contentItem: RowLayout {
                        anchors {
                            verticalCenter: parent.verticalCenter
                            left: parent.left
                            right: parent.right
                            leftMargin: openRow.horizontalPadding
                            rightMargin: openRow.horizontalPadding
                        }
                        spacing: 8
                        MaterialSymbol {
                            iconSize: 20
                            text: "launch"
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: "Open"
                        }
                    }
                }

                // The only row that really quits. Everything else about
                // this app is reversible; a hidden window is still a
                // running process, and there has to be a way to say no.
                RippleButton {
                    id: quitRow
                    buttonRadius: background.radius - background.padding
                    horizontalPadding: 12
                    implicitWidth: contentItem.implicitWidth + horizontalPadding * 2
                    implicitHeight: 36
                    Layout.fillWidth: true

                    visible: TrayApps.isRunning(root.entry?.cls)
                    releaseAction: () => {
                        TrayApps.quit(root.entry?.cls);
                        root.close();
                    }

                    contentItem: RowLayout {
                        anchors {
                            verticalCenter: parent.verticalCenter
                            left: parent.left
                            right: parent.right
                            leftMargin: quitRow.horizontalPadding
                            rightMargin: quitRow.horizontalPadding
                        }
                        spacing: 8
                        MaterialSymbol {
                            iconSize: 20
                            text: "close"
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: "Quit"
                        }
                    }
                }
            }
        }
    }
}
