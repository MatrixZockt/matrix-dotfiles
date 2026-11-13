import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    // Grow the panel, on demand.
    //
    // The count label is this control. It was `enabled: false` for a long
    // time -- a button that looked pressable and did nothing -- and making it
    // expand every notification was wrong too: it spent the one control you
    // press when you want to see MORE on screen on making the rows taller,
    // which is the opposite of giving you more list.
    //
    // So it does what the fullscreen button used to do, and what its name
    // always suggested: the notification card takes the sidebar's full
    // height, and the quick panel, the sliders and the media strip step
    // aside while it does. The host owns the reaction (see SidebarRightContent).
    //
    // Opt-in, because the left sidebar's tab hosts this same list in a panel
    // that has nothing to step aside.
    property bool extendable: false
    property bool extended: false
    signal extendToggled()

    // Which of the two lists this panel is showing: the notifications that
    // are still here, or the ones that came before them. The rewind button in
    // the row at the bottom is the only thing that sets it.
    property bool showingHistory: false

    NotificationListView { // Scrollable window
        id: listview
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: statusRow.top
        anchors.bottomMargin: 5

        clip: true
        layer.enabled: true
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: listview.width
                height: listview.height
                radius: Appearance.rounding.normal
            }
        }

        popup: false
    }

    // Placeholder when list is empty
    PagePlaceholder {
        shown: Notifications.list.length === 0
        icon: "notifications"
        description: Translation.tr("Nothing")
        shape: MaterialShape.Shape.Ghostish
        descriptionHorizontalAlignment: Text.AlignHCenter
    }

    // ── History: the last few, rewound ──────────────────────────────────
    //
    // The list above is what is still there; this is what WAS there.
    // Dismissing a notification removes it for good, so "what did that
    // actually say?" had no answer once its card was gone. The rewind button
    // at the bottom brings back the last Notifications.historyMax arrivals,
    // newest first, and the same button returns to the live list.
    //
    // A card laid over the list rather than another page: this is a look back
    // at the same list, so it belongs in the same place, and the row of
    // controls that summoned it stays exactly where it was (the clear button
    // clears whichever of the two you are looking at -- see there).
    Item {
        id: historyView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: statusRow.top
        anchors.bottomMargin: 5
        visible: opacity > 0
        opacity: root.showingHistory ? 1 : 0
        scale: root.showingHistory ? 1 : 0.98
        Behavior on opacity {
            NumberAnimation {
                duration: Math.round(140 * Appearance.animationCurves.motionScale)
                easing.type: Easing.OutCubic
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: Math.round(140 * Appearance.animationCurves.motionScale)
                easing.type: Easing.OutCubic
            }
        }

        StyledRectangle {
            anchors.fill: parent
            radius: Appearance.rounding.normal
            // Pane, over the sidebar's own background: the history is a layer
            // brought up over the list and should read as one.
            contentLayer: StyledRectangle.ContentLayer.Pane
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                MaterialSymbol {
                    text: "history"
                    iconSize: Appearance.font.pixelSize.huge
                    color: Appearance.colors.colOnLayer1
                }
                StyledText {
                    text: Translation.tr("History")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer1
                }
                Item { Layout.fillWidth: true }
                StyledText {
                    text: Translation.tr("%1 of the last %2")
                        .arg(Notifications.history.length)
                        .arg(Notifications.historyMax)
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }
            }

            ListView {
                id: historyList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 4
                model: Notifications.historyNewestFirst

                delegate: Rectangle {
                    id: historyRow
                    required property var modelData
                    width: historyList.width
                    height: rowLayout.implicitHeight + 12
                    radius: Appearance.rounding.small
                    color: historyHover.containsMouse
                        ? Appearance.colors.colLayer2Hover
                        : Appearance.colors.colLayer2

                    RowLayout {
                        id: rowLayout
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 8

                        NotificationAppIcon {
                            implicitSize: 26
                            appIcon: historyRow.modelData.appIcon ?? ""
                            summary: historyRow.modelData.summary ?? ""
                            image: historyRow.modelData.image ?? ""
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            StyledText {
                                Layout.fillWidth: true
                                text: historyRow.modelData.summary
                                    || historyRow.modelData.appName
                                    || ""
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.weight: Font.Medium
                                color: Appearance.colors.colOnLayer2
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            StyledText {
                                Layout.fillWidth: true
                                visible: text !== ""
                                text: historyRow.modelData.body ?? ""
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                // A notification body is text from a sender,
                                // not markup: it is drawn, never interpreted.
                                textFormat: Text.PlainText
                            }
                        }

                        StyledText {
                            Layout.alignment: Qt.AlignTop
                            text: NotificationUtils.getFriendlyNotifTimeString(historyRow.modelData.time)
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }
                    }

                    MouseArea {
                        id: historyHover
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: Notifications.history.length === 0
                horizontalAlignment: Text.AlignHCenter
                text: Translation.tr("Nothing yet. The notifications you get will show up here.")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }
        }
    }

    ButtonGroup {
        id: statusRow
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }

        NotificationStatusButton {
            Layout.fillWidth: false
            buttonIcon: "notifications_paused"
            toggled: Notifications.silent
            onClicked: () => {
                Notifications.silent = !Notifications.silent;
            }
        }
        // The count, and the way to give the list the whole sidebar.
        //
        // `toggled` when extended, so the panel being in its tall state is
        // visible from the row rather than only from what the sidebar did
        // with its other widgets.
        NotificationStatusButton {
            enabled: root.extendable
            Layout.fillWidth: true
            buttonText: Translation.tr("%1 notifications").arg(Notifications.list.length)
            toggled: root.extended
            onClicked: {
                root.extendToggled();
            }
            StyledToolTip {
                text: root.extended
                    ? Translation.tr("Shrink the notification list back")
                    : Translation.tr("Give the notification list the whole sidebar")
            }
        }
        // ── REWIND: the last few that came before ──
        //
        // `history` is the clock with the arrow running backwards, and it is
        // the whole point of the button. `toggled` keeps which list is on
        // screen legible from the row itself, not only from the glyph.
        NotificationStatusButton {
            Layout.fillWidth: false
            buttonIcon: "history"
            toggled: root.showingHistory
            onClicked: {
                root.showingHistory = !root.showingHistory;
                if (root.showingHistory)
                    historyList.positionViewAtBeginning();
            }
            StyledToolTip {
                text: root.showingHistory
                    ? Translation.tr("Back to the current notifications")
                    : Translation.tr("Show the last %1 notifications").arg(Notifications.historyMax)
            }
        }

        // The VIEW button: the list's two states, every notification
        // maximised or every one minimised, in one press.
        //
        // This replaces the fullscreen button that stood here. That one asked
        // the host for more sidebar, which spent a button press to make room
        // for notifications and left the notifications themselves exactly as
        // long as they were -- the opposite of what pressing a button in a
        // list of notifications is for. This one changes what the list SHOWS.
        //
        // The icon is the ACTION, not the state: `unfold_more` while the list
        // is collapsed (pressing opens it), `unfold_less` while it is open
        // (pressing closes it). `toggled` fills the button when the view is
        // "all maximised", so the state is legible without reading the glyph.
        NotificationStatusButton {
            Layout.fillWidth: false
            buttonIcon: listview.expandAll ? "unfold_less" : "unfold_more"
            toggled: listview.expandAll
            onClicked: {
                listview.expandAll = !listview.expandAll;
            }
            StyledToolTip {
                text: listview.expandAll
                    ? Translation.tr("Minimise all notifications")
                    : Translation.tr("Maximise all notifications")
            }
        }
        // Whichever list is on screen is the one this clears. Clearing the
        // history while the history is up is the only thing "clear" can
        // sensibly mean there, and it keeps a rewind from taking the live
        // notifications with it.
        NotificationStatusButton {
            Layout.fillWidth: false
            buttonIcon: "delete_sweep"
            onClicked: () => {
                if (root.showingHistory)
                    Notifications.clearHistory();
                else
                    Notifications.discardAllNotifications();
            }
            StyledToolTip {
                text: root.showingHistory
                    ? Translation.tr("Forget the history, keep the notifications")
                    : Translation.tr("Clear all notifications")
            }
        }
    }
}

