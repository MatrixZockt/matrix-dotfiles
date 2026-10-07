pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The session menu: what happens to the machine and to this session.
 *
 * Opened by the username in the right sidebar -- the name of the person the
 * actions apply to is the natural place to hang them off, and it is the corner
 * that used to hold a distribution logo and then an uptime figure, neither of
 * which could be clicked or acted on.
 *
 * "Lock" sits at the top because it is the reversible one: it keeps the whole
 * session alive behind the password prompt (Windows-style), so a stray click
 * costs nothing. "Log out" is the session-ender; restart and shut down ask
 * once more before doing anything. Everything else here is either harmless or
 * instantly reversible (suspend and hibernate both come back exactly where
 * they left off), but a single stray click on "Shut down" throws away
 * everything you had open -- so those two rows turn into a question for a few
 * seconds instead of acting on the first click.
 *
 * It lives in its own popup window rather than inside the sidebar because the
 * sidebar is narrow and a menu drawn inside it would be clipped by it.
 */
PopupWindow {
    id: root

    // The thing the menu hangs off -- the username pill.
    required property Item anchorItem

    color: "transparent"
    visible: false

    readonly property real padding: Appearance.sizes.elevationMargin
    implicitWidth: card.implicitWidth + root.padding * 2
    implicitHeight: card.implicitHeight + root.padding * 2

    // Which destructive row is waiting for a second click, and the countdown that
    // takes the question back if you change your mind by doing nothing.
    property string confirmingKey: ""

    Timer {
        id: confirmTimeout
        interval: 4000
        onTriggered: root.confirmingKey = ""
    }

    onVisibleChanged: {
        if (!root.visible) {
            GlobalStates.sidebarRightPopupOpen = false;
            root.confirmingKey = "";
            confirmTimeout.stop();
        }
    }

    // Same safety net as the power menu next door: never leave
    // `sidebarRightPopupOpen` set on the way out, or the sidebar stops
    // dismissing itself on pointer-out for the rest of the session.
    Component.onDestruction: GlobalStates.sidebarRightPopupOpen = false;

    function open() {
        // Snapshot the pill's geometry ONCE, while both the pill and its window
        // are alive, and anchor to the window instead of to the item.
        //
        // An `anchor.item` binding keeps a live pointer to the pill for as long
        // as this popup exists. If the pill is destroyed out from under the
        // popup -- sidebar teardown, or a hot reload while the menu is open --
        // Quickshell 0.2.1 segfaults in PopupAnchor::setItem() ->
        // onItemWindowChanged() -> QQuickItem::window() on the freed item. That
        // is not theoretical: it is the exact stack in the 09:22 crash report
        // (crashes/6p70bclt). With a plain rect there is no item pointer left to
        // dangle, so teardown and reloads are safe.
        const win = anchorItem?.QsWindow?.window;
        if (!win || !anchorItem)
            return;
        const mapped = anchorItem.mapToItem(win.contentItem, 0, 0);
        anchor.rect = Qt.rect(mapped.x, mapped.y, anchorItem.width, anchorItem.height);
        anchor.window = win;
        root.visible = true;
        // Same reason as the power menu next door: this menu is a separate
        // popup window, so the cursor leaving the sidebar to reach it must not
        // be read as "the pointer left the panel, close it" -- doing that tore
        // the menu down as the user moved toward it.
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
            key: "lock",
            icon: "lock",
            label: Translation.tr("Lock"),
            danger: false,
            run: () => Session.lock()
        },
        {
            key: "logout",
            icon: "logout",
            label: Translation.tr("Log out"),
            danger: false,
            run: () => Session.logout()
        },
        {
            key: "suspend",
            icon: "bedtime",
            label: Translation.tr("Suspend"),
            danger: false,
            run: () => Session.suspend()
        },
        {
            key: "hibernate",
            icon: "ac_unit",
            label: Translation.tr("Hibernate"),
            danger: false,
            run: () => Session.hibernate()
        },
        {
            key: "separator",
            icon: "",
            label: "",
            danger: false,
            run: () => {}
        },
        {
            key: "reboot",
            icon: "restart_alt",
            label: Translation.tr("Restart"),
            danger: true,
            run: () => Session.reboot()
        },
        {
            key: "poweroff",
            icon: "settings_power",
            label: Translation.tr("Shut down"),
            danger: true,
            run: () => Session.poweroff()
        }
    ]

    function runAction(action) {
        if (action.key === "separator")
            return;
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
                Layout.bottomMargin: 8
                text: SystemInfo.username
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }

            Repeater {
                model: root.actions

                delegate: Item {
                    id: row
                    required property var modelData
                    Layout.fillWidth: true
                    implicitWidth: 220
                    implicitHeight: modelData.key === "separator" ? 11 : 36

                    Rectangle {
                        visible: row.modelData.key === "separator"
                        anchors.centerIn: parent
                        width: parent.width - 20
                        height: 1
                        color: Appearance.colors.colOutlineVariant
                    }

                    RippleButton {
                        anchors.fill: parent
                        visible: row.modelData.key !== "separator"
                        enabled: visible
                        buttonRadius: card.radius - 4
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        onClicked: root.runAction(row.modelData)

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
                                color: row.modelData.danger && root.confirmingKey === row.modelData.key
                                    ? Appearance.colors.colError
                                    : Appearance.colors.colOnLayer0
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                text: (row.modelData.danger && root.confirmingKey === row.modelData.key)
                                    ? Translation.tr("Click again to %1").arg(row.modelData.label.toLowerCase())
                                    : row.modelData.label
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: row.modelData.danger && root.confirmingKey === row.modelData.key
                                    ? Appearance.colors.colError
                                    : Appearance.colors.colOnLayer0
                            }
                        }
                    }
                }
            }
        }
    }

    // Anchor below the username pill, right edges aligned, growing down and left
    // from the pill's bottom-right corner: the xdg-popup pairing that actually
    // puts a popup *under* something -- anchor on the edge you hang from, gravity
    // in the direction it grows -- the same one every tooltip here uses. The rect
    // and window are filled in by open(), from a geometry snapshot taken while
    // the pill is still alive (see the comment there for why item must not be
    // used). PopupAdjustment.SlideX is the on-screen safety net; ResizeY is
    // intentionally omitted so the menu never gets squeezed into a strange shape.
    anchor {
        adjustment: PopupAdjustment.SlideX | PopupAdjustment.SlideY
        edges: Edges.Bottom | Edges.Right
        gravity: Edges.Bottom | Edges.Left
        margins {
            bottom: 8
        }
    }
}
