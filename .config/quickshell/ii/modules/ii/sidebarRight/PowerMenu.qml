// The power menu: what to do with the machine right now.
//
// Opened from the power button in the top-right corner of the right sidebar --
// the corner people already reach for, and the one that had no entry for any
// of this until now.
//
// Three actions, and the distinction between them is the whole design:
//
//   Sleep     Reversible, and keeps everything. Screen off, machine asleep,
//             every app and window and setting exactly where it was left. It is
//             emphatically NOT a logout: nothing is closed, nothing is killed,
//             and waking it brings the same session back. Its sub-label names
//             the mechanism that will actually be used -- "Suspend" or
//             "Hibernate" -- read from systemd-logind rather than assumed,
//             because the honest answer differs per machine and a menu that
//             promises hibernate on a machine that cannot hibernate is a lie.
//   Restart   Ends the session.
//   Power off Ends the session, and the machine with it.
//
// Restart and Power off turn into a question on first click, because they are
// the two rows here that throw away what you had open.
//
// It lives in its own popup window rather than inside the sidebar because the
// sidebar is narrow and a menu drawn inside it would be clipped by it. The
// anchoring approach is copied from SessionMenu next door, including its
// geometry-snapshot trick: an `anchor.item` binding keeps a live pointer to
// the button, and if that button is destroyed while the popup still points at
// it -- sidebar teardown, or a reload with the menu open -- Quickshell
// segfaults in PopupAnchor. A plain rect leaves no item pointer to dangle.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

PopupWindow {
    id: root

    // The thing the menu hangs off -- the power button.
    required property Item anchorItem

    color: "transparent"
    visible: false

    readonly property real padding: Appearance.sizes.elevationMargin
    implicitWidth: card.implicitWidth + root.padding * 2
    implicitHeight: card.implicitHeight + root.padding * 2

    // Which destructive row is waiting for a second click, and the countdown
    // that takes the question back if you change your mind and do nothing.
    property string confirmingKey: ""

    // "hibernate" or "suspend", probed from logind rather than guessed.
    // Empty until the probe answers, which is why the Sleep row falls back to a
    // generic wording instead of showing a blank.
    property string sleepMode: ""

    readonly property string sleepModeLabel: root.sleepMode === "hibernate"
        ? Translation.tr("Hibernate")
        : (root.sleepMode === "suspend" ? Translation.tr("Suspend") : "")

    Timer {
        id: confirmTimeout
        interval: 4000
        onTriggered: root.confirmingKey = ""
    }

    // Re-probed each time the menu opens rather than cached for the life of
    // the shell: the answer can change (a swapfile added, `resume=` set on the
    // kernel command line), and Sleep is the one row here whose real behaviour
    // depends on it.
    Process {
        id: modeProbe
        command: ["bash", Quickshell.shellPath("scripts/session/sleep.sh"), "--mode"]
        stdout: SplitParser {
            onRead: data => {
                const mode = data.trim();
                if (mode === "hibernate" || mode === "suspend")
                    root.sleepMode = mode;
            }
        }
    }

    onVisibleChanged: {
        if (root.visible) {
            modeProbe.running = true;
        } else {
            // Every path that hides this menu has to drop the flag, not just
            // close(): if it were left set, the sidebar would never close on
            // pointer-out again for the rest of the session.
            GlobalStates.sidebarRightPopupOpen = false;
            root.confirmingKey = "";
            confirmTimeout.stop();
        }
    }

    // Last-resort release of the flag. Every path that hides this menu already
    // clears it, but if the item is ever destroyed without close() running, a
    // flag left set would suspend the sidebar's pointer-out close for the rest
    // of the session -- the sidebar would stop dismissing itself and simply
    // refuse to go away.
    Component.onDestruction: GlobalStates.sidebarRightPopupOpen = false;

    function open() {
        // Snapshot the button's geometry ONCE, while both it and its window are
        // alive, and anchor to the window rather than to the item. See the note
        // at the top of this file for why an item pointer must not be used.
        const win = anchorItem?.QsWindow?.window;
        if (!win || !anchorItem)
            return;
        const mapped = anchorItem.mapToItem(win.contentItem, 0, 0);
        anchor.rect = Qt.rect(mapped.x, mapped.y, anchorItem.width, anchorItem.height);
        anchor.window = win;
        root.visible = true;
        // Tells the sidebar not to close itself on pointer-out while this menu
        // is up: the menu is a different surface, so the cursor leaving the
        // sidebar to reach it is expected, not a dismissal.
        GlobalStates.sidebarRightPopupOpen = true;
        GlobalFocusGrab.addDismissable(root);
    }

    function close() {
        root.visible = false;
        GlobalStates.sidebarRightPopupOpen = false;
        GlobalFocusGrab.removeDismissable(root);
    }

    Connections {
        target: GlobalFocusGrab
        function onDismissed() {
            root.close();
        }
    }

    // Clicking anywhere else drops the menu, exactly like the other panels.
    MouseArea {
        anchors.fill: parent
        onPressed: root.close()
    }

    readonly property var actions: [
        {
            key: "sleep",
            icon: "bedtime",
            label: Translation.tr("Sleep"),
            // No danger flag: nothing here is thrown away, and a Sleep that
            // asked "are you sure?" before a five-second round trip back would
            // be the most annoying row in the menu.
            danger: false,
            subtitle: root.sleepModeLabel,
            run: () => Session.sleep()
        },
        {
            key: "reboot",
            icon: "restart_alt",
            label: Translation.tr("Restart"),
            danger: true,
            subtitle: "",
            run: () => Session.reboot()
        },
        {
            key: "poweroff",
            icon: "settings_power",
            label: Translation.tr("Power off"),
            danger: true,
            subtitle: "",
            run: () => Session.poweroff()
        }
    ]

    function runAction(action) {
        // A destructive row acts on the second click; the first one only asks.
        if (action.danger && root.confirmingKey !== action.key) {
            root.confirmingKey = action.key;
            confirmTimeout.restart();
            return;
        }
        root.close();
        action.run();
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        implicitWidth: column.implicitWidth + 8
        implicitHeight: column.implicitHeight + 8
        color: Appearance.colors.colLayer0
        radius: Appearance.rounding.windowRounding
        border.width: 1
        border.color: Appearance.colors.colLayer0Border
        clip: true

        ColumnLayout {
            id: column
            anchors.centerIn: parent
            spacing: 0

            StyledText {
                Layout.leftMargin: 14
                Layout.rightMargin: 14
                Layout.topMargin: 10
                Layout.bottomMargin: 6
                text: Translation.tr("Power")
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }

            Repeater {
                model: root.actions

                delegate: Item {
                    id: row
                    required property var modelData
                    Layout.fillWidth: true
                    implicitWidth: 230
                    // Taller for the row that carries a sub-label, so the two
                    // kinds of row do not silently reflow the list as the Sleep
                    // mode is discovered.
                    implicitHeight: row.modelData.subtitle ? 46 : 36

                    RippleButton {
                        id: rowButton
                        anchors.fill: parent
                        buttonRadius: card.radius - 4
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        colRipple: Appearance.colors.colLayer1Active
                        onClicked: root.runAction(row.modelData)

                        readonly property bool confirming: row.modelData.danger
                            && root.confirmingKey === row.modelData.key

                        contentItem: RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 12
                                rightMargin: 12
                            }
                            spacing: 10

                            MaterialSymbol {
                                Layout.alignment: Qt.AlignVCenter
                                text: row.modelData.icon
                                iconSize: 18
                                color: rowButton.confirming
                                    ? Appearance.colors.colError
                                    : Appearance.colors.colOnLayer0
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 0

                                StyledText {
                                    Layout.fillWidth: true
                                    text: rowButton.confirming
                                        ? Translation.tr("Click again to %1")
                                            .arg(row.modelData.label.toLowerCase())
                                        : row.modelData.label
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: rowButton.confirming
                                        ? Appearance.colors.colError
                                        : Appearance.colors.colOnLayer0
                                }

                                // The mechanism Sleep will actually use, and
                                // only when it is known -- an empty sub-label
                                // would otherwise still take up its line.
                                StyledText {
                                    Layout.fillWidth: true
                                    visible: text.length > 0
                                    text: row.modelData.subtitle
                                    font.pixelSize: Appearance.font.pixelSize.smallie
                                    color: Appearance.colors.colSubtext
                                }
                            }
                        }
                    }
                }
            }

            // The one line that stops Sleep being mistaken for Log out, which
            // is the mistake this row invites: both end your evening, only one
            // of them keeps your work.
            StyledText {
                Layout.leftMargin: 14
                Layout.rightMargin: 14
                Layout.topMargin: 8
                Layout.bottomMargin: 10
                Layout.maximumWidth: 230
                wrapMode: Text.WordWrap
                text: Translation.tr("Sleep turns the screen off and leaves every app and setting open.")
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }
        }
    }

    // Anchored below the power button, right edges aligned: the xdg-popup
    // pairing that actually puts a popup *under* something. The rect and window
    // are filled in by open() from a geometry snapshot (see the note there).
    anchor {
        adjustment: PopupAdjustment.SlideX | PopupAdjustment.SlideY
        edges: Edges.Bottom | Edges.Right
        gravity: Edges.Bottom | Edges.Left
        margins {
            bottom: 8
        }
    }
}