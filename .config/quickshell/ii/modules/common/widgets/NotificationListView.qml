pragma ComponentBehavior: Bound

import qs.modules.common.widgets
import qs.services
import QtQuick
import Quickshell
import Quickshell.Widgets

StyledListView { // Scrollable window
    id: root
    property bool popup: false

    // ── The view: all minimised, or all maximised ──────────────────────
    //
    // One switch for the whole list, owned HERE rather than in each card,
    // because a ListView recycles its delegates: state held on a card is
    // state that vanishes when the card scrolls off and reappears wrongly
    // on whatever notification scrolls into its place. This lives above the
    // view for the same reason the To Do list keys its expansion by index.
    //
    // FALSE on the popup, and the popup is the only other user of this
    // component -- a corner card must never be force-opened by a button
    // pressed in a sidebar that is not even visible.
    property bool expandAll: false

    spacing: 3

    // The popup's arrival is a DROP (see the translate in NotificationGroup),
    // and a scale from nothing on top of a drop is two entrances competing for
    // the same half-second: the card appears to inflate out of the corner
    // while it is also falling into it. 0.92 keeps enough scale change to
    // read as depth -- the card is nearer the viewer on the way down -- and
    // deep enough to be felt over the drop's full 520ms, without fighting
    // it. The sidebar list below is a list that was already there, so it
    // keeps the default pop.
    addScaleFrom: root.popup ? 0.92 : 0

    // ONE CARD PER NOTIFICATION, newest first.
    //
    // This used to be a list of APP NAMES, one card each, with the app's
    // notifications stacked inside the card behind a count badge and a
    // right-click to expand. Four things an app sent you arrived as one
    // row with two peeking out of it.
    //
    // `flatCards` hands over one-notification groups, so the card component
    // is unchanged -- it is already in its single-notification shape when
    // there is only one -- and the list simply stops folding them together.
    model: ScriptModel {
        values: root.popup ? Notifications.flatPopupCards : Notifications.flatCards
    }
    delegate: NotificationGroup {
        // An id on the delegate, and load-bearing. Inside a delegate `root`
        // is the LISTVIEW -- the delegate's own root object is a
        // NotificationGroup whose `root` lives in another file -- so a
        // tooltip reading `root.anyTruncated` from here reads a property the
        // listview does not have, and quietly gets `undefined`, which is
        // falsy, which made the tooltip silently fall through to its other
        // branch forever. Naming the card is what makes it addressable.
        id: notifCard

        required property int index
        required property var modelData
        popup: root.popup
        width: ListView.view.width // https://doc.qt.io/qt-6/qml-qtquick-listview.html
        notificationGroup: modelData
        expandAll: root.expandAll

        StyledToolTip {
            // The one honest label for what a click does.
            //
            // In the SIDEBAR the card click only ever expands, and the app
            // NAME is what opens the app -- so the label says which of those
            // is available here. A card with nothing to expand gets the
            // "click the name" label, because that is the only thing a click
            // on it CAN do, and telling someone to click a card that will not
            // respond is worse than telling them what will.
            //
            // Inside the popup there is nothing to expand and no name worth
            // aiming at, so the whole card is the jump and keeps the old
            // label.
            text: notifCard.popup
                ? Translation.tr("Click to go to %1").arg(notifCard.notificationGroup?.appName || "the app")
                : (notifCard.hasMoreToShow()
                    ? Translation.tr("Click to expand")
                    : Translation.tr("Click the name to go to %1").arg(notifCard.notificationGroup?.appName || "the app"))
        }
    }
}
