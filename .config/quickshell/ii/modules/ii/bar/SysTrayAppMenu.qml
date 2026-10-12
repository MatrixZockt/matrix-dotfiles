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
// `SysTrayMenu` renders from a `QsMenuHandle`. Thunderbird and WhatsApp have
// no tray item and so no such handle, and `Quickshell.Widgets` has no `Menu`
// type to synthesise one from -- the only things producing a QsMenuHandle are
// registered SNI apps. So this is a menu of our own.
//
// IT IS DRESSED AS `SysTrayMenu`, NUMBER FOR NUMBER. Two menus open from the
// same tray, one icon apart; when they disagreed the shell-owned one read as a
// different kind of popup rather than as the same menu about another app. What
// that means concretely, all of it copied from `SysTrayMenu`/`SysTrayMenuEntry`:
//
//   * the panel: colLayer0, windowRounding, a 1px colLayer0Border, 4px padding;
//   * rows 36px tall with 12px of horizontal padding, an icon box of 20 and
//     8px to the label;
//   * the label at `font.pixelSize.smallie` -- `StyledText`'s own default is
//     `small` (15px), which made this menu's text visibly larger than every
//     other menu in the tray;
//   * the separator exactly as `SysTrayMenuEntry` draws one: a 1px line with
//     4px above and below, spanning the panel inside its padding.
//
// The separator is the one the native menu draws between the shell's own row
// and the app's entries -- `colSubtext`, above the first row that belongs to
// the app. That is the line under "Unpin" in Discord's menu, and the only one
// this menu has an equivalent for: our app contributes at most one row besides
// Quit (Open when it is not running, Quit when it is), so there is nothing for
// a second hairline to divide. `SysTrayMenuEntry`'s darker separator between
// an app's own entries marks a split this menu cannot have.
//
// What deliberately does NOT carry over is the pin row. `TrayService` pins by
// StatusNotifier item id, and these apps have no SNI item -- a "Pin" row here
// could never change anything, and a dead control is worse than a missing one.
//
// The app's own icon is used for "Open <app>" (as Discord shows its logo beside
// "Open Discord"); the shell's rows keep Material glyphs, the same way the
// shell's own pin row does in the native menu.
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

    // `SysTrayMenu`'s numbers, named once. Every row below reads these, so a
    // row cannot drift from the native menu's geometry one edit at a time.
    readonly property int rowHeight: 36
    readonly property int rowPadding: 12
    readonly property int iconBox: 20

    readonly property string appName: root.entry?.name ?? ""

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
                // The rows sit INSIDE the plate. `SysTrayMenu` gets this from
                // `margins: popupBackground.padding` on its StackView; without
                // the same inset here the rows were flush against the top-left
                // border while the plate carried 8px of dead space on the right
                // and bottom -- a menu that looks crooked next to the native one.
                anchors.fill: parent
                anchors.margins: background.padding
                spacing: 0

                // Show / Hide is one row, not two: it always does the
                // thing you did not do last, and a menu with a greyed-out
                // "Hide" when it is already hidden is a row that teaches
                // you nothing.
                RippleButton {
                    id: toggleRow
                    buttonRadius: background.radius - background.padding
                    horizontalPadding: root.rowPadding
                    implicitWidth: contentItem.implicitWidth + horizontalPadding * 2
                    implicitHeight: root.rowHeight
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
                            iconSize: root.iconBox
                            text: root.appHidden ? "visibility" : "visibility_off"
                        }
                        StyledText {
                            Layout.fillWidth: true
                            // `smallie`, not the 15px default: see the note on
                            // the row recipe at the top of this file.
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            text: root.appHidden ? "Show" : "Hide to tray"
                        }
                    }
                }

                // The shell's own separator, under the shell's own row --
                // `colSubtext`, exactly as in `SysTrayMenu`.
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: Appearance.colors.colSubtext
                    Layout.topMargin: 4
                    Layout.bottomMargin: 4
                    // Nothing to divide when the top row is not there (the
                    // app is not running, so only Open/launch is offered).
                    visible: toggleRow.visible
                }

                // Shown only when the app is not running, so an already-
                // hidden app can still be started from its own icon. It wears
                // the APP's icon, the way "Open Discord" wears Discord's.
                RippleButton {
                    id: openRow
                    buttonRadius: background.radius - background.padding
                    horizontalPadding: root.rowPadding
                    implicitWidth: contentItem.implicitWidth + horizontalPadding * 2
                    implicitHeight: root.rowHeight
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
                        // A 20px box whether or not the artwork loads, so the
                        // label column stays aligned with the rows above it --
                        // the same reserved column `SysTrayMenuEntry` keeps for
                        // entries that carry no icon.
                        Item {
                            implicitWidth: root.iconBox
                            implicitHeight: root.iconBox
                            IconImage {
                                anchors.centerIn: parent
                                asynchronous: true
                                source: TrayApps.iconFor(root.entry)
                                implicitSize: root.iconBox
                                mipmap: true
                            }
                        }
                        StyledText {
                            Layout.fillWidth: true
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            text: "Open " + root.appName
                        }
                    }
                }

                // The only row that really quits. Everything else about
                // this app is reversible; a hidden window is still a
                // running process, and there has to be a way to say no.
                RippleButton {
                    id: quitRow
                    buttonRadius: background.radius - background.padding
                    horizontalPadding: root.rowPadding
                    implicitWidth: contentItem.implicitWidth + horizontalPadding * 2
                    implicitHeight: root.rowHeight
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
                            iconSize: root.iconBox
                            text: "close"
                        }
                        StyledText {
                            Layout.fillWidth: true
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            text: "Quit " + root.appName
                        }
                    }
                }
            }
        }
    }
}
