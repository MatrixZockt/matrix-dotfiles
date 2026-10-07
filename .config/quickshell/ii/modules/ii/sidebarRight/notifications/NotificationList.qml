import qs.modules.common
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
        NotificationStatusButton {
            Layout.fillWidth: false
            buttonIcon: "delete_sweep"
            onClicked: () => {
                Notifications.discardAllNotifications()
            }
        }
    }
}

