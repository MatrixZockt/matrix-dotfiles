import qs
import qs.modules.common
import qs.services
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications

Item { // Notification item area
    id: root
    property var notificationObject
    property bool expanded: false

    // The row was clicked with the primary button. The group that owns the
    // expansion state listens for this; the row cannot expand itself, because
    // `expanded` is a binding on it.
    signal rowClicked()
    property bool onlyNotification: false
    property real fontSize: Appearance.font.pixelSize.small

    // ── The action buttons' box ────────────────────────────────────────────
    //
    // ONE number, used as the button box, the hover backdrop, and the
    // collapsed row's minimum height. Three uses of one value is the point:
    // the row is exactly as tall as its buttons, and the buttons are exactly
    // as wide as the space the row reserves for them, so nothing overflows
    // and nothing needs a second guess about where the centre is.
    //
    // 26 and not 30: this row is ONE line of text, and at 30 the row grew by
    // a third to accommodate the icon. 26 is still a comfortable target and
    // keeps a notification card about as tall as the one-line row it replaced.
    readonly property real actionSize: 26

    // The plate and the pointer target, which are NOT the same number.
    //
    // The plate is 26 -- that is what the row is sized around and what you
    // see. The target is 34: the plate plus 4px of bleed on every side. The
    // bleed exists because 5.5px of slop around a 15px glyph is not a hit
    // box, it is a rounding error: at that size the pointer has to be
    // essentially ON the × for the row to react, and the reaction then looks
    // like it is tracking the glyph rather than the box.
    //
    // 4px, not the 6px of the 38px version that was tried and reverted. Two
    // reasons. It is small enough to stay well clear of the card's own edge
    // -- the group's padding is 10, so the target keeps 6px inside the card
    // and cannot be clipped by it. And it is small enough that the strip of
    // target with no plate drawn over it is not a visible dead ring.
    //
    // The bleed is SYMMETRIC on purpose. The failure this fixes was one-sided:
    // approaching the × from the right did nothing until the cursor was on
    // the glyph, while the left and the top behaved. A symmetric target has
    // no side to get wrong, and if the right side is still dead after this
    // then the cause is an ancestor clip rather than the size, and that is a
    // different thing to go looking for.
    readonly property real actionHitSize: actionSize + 8

    // The glyph inside that box. Smaller than the box so the hover backdrop
    // reads as a plate under the icon rather than as a tight frame around it.
    readonly property real actionIconSize: 15

    // Hover is FAST. 70ms and decelerating: quick enough to feel like the
    // button is simply lit, slow enough that it stays a transition rather
    // than a pop. Scaled by motionScale so the shell's power mode keeps
    // working. Same numbers as the To Do list's task row, because the two
    // panels are read together.
    readonly property int hoverDuration: Math.round(70 * Appearance.animationCurves.motionScale)
    readonly property int hoverCurve: Easing.OutCubic

    // The dismiss slide.
    //
    // It was `Appearance.animation.elementMove`: 500ms on the shell's default
    // spatial curve. That number is right for an element MOVING somewhere --
    // 500ms is long on purpose, because the eye is tracking it and a fast
    // move is a move you cannot follow.
    //
    // A dismissal is not a move. Nothing follows the card out; the list
    // closes the gap behind it. So the entire cost of the long duration is a
    // wait between the click and the list agreeing with you, and 500ms of it
    // reads as the shell not having heard you rather than as polish.
    //
    // 180ms, and OutQuint rather than a bezier. The quint has most of its
    // velocity in the first few frames, so the card is already moving before
    // the click has finished registering, and the short tail keeps it from
    // blinking out instead of leaving. Scaled by motionScale like every other
    // duration in the shell, so the power mode keeps working.
    readonly property int dismissDuration: Math.round(180 * Appearance.animationCurves.motionScale)
    property real padding: onlyNotification ? 0 : 8
    property real summaryElideRatio: 0.85

    // Whether this row is the transient top-right popup or a row in the right
    // SIDEBAR's history list. The two share this component, and the hover
    // actions below are a sidebar-only affordance -- the same `!root.popup`
    // split NotificationGroup already uses to stop a notification appearing in
    // both places at once and flashing twice.
    property bool popup: false

    // There is no copy button.
    //
    // It was here for a while and it was a waste of the most valuable space
    // on the row. A notification you want to keep is one you have already read,
    // and the text you would want to copy is in the source app, which is one
    // click away and has it selectable, with a working selection, and a
    // history. Copying it out of a notification puts it on the clipboard as
    // anonymous text with no app, no title and no way back to where it came
    // from -- strictly worse than the thing the button was standing in for.
    //
    // So the row keeps exactly one action, and it is the one that cannot be
    // done anywhere else: dismiss this one notification. That also hands the
    // body text 26px of width back, which is a sentence's worth on a panel
    // this narrow.

    property real dragConfirmThreshold: 70 // Drag further to discard notification
    property real dismissOvershoot: notificationIcon.implicitWidth + 20 // Account for gaps and bouncy animations
    property var qmlParent: root?.parent?.parent // There's something between this and the parent ListView
    property var parentDragIndex: qmlParent?.dragIndex ?? -1
    property var parentDragDistance: qmlParent?.dragDistance ?? 0
    property var dragIndexDiff: Math.abs(parentDragIndex - index)
    property real xOffset: dragIndexDiff == 0 ? parentDragDistance : 
        Math.abs(parentDragDistance) > dragConfirmThreshold ? 0 :
        dragIndexDiff == 1 ? (parentDragDistance * 0.3) :
        dragIndexDiff == 2 ? (parentDragDistance * 0.1) : 0

    implicitHeight: background.implicitHeight

    function destroyWithAnimation(left = false) {
        root.qmlParent.resetDrag()
        background.anchors.leftMargin = background.anchors.leftMargin; // Break binding
        destroyAnimation.left = left;
        destroyAnimation.running = true;
    }

    TextMetrics {
        id: summaryTextMetrics
        font.pixelSize: root.fontSize
        text: root.notificationObject.summary || ""
    }

    // ── Truncation measurement ──────────────────────────────────────────────
    //
    // A collapsed sidebar row shows exactly ONE line of the body, elided --
    // see `bodyPreviewText`. So "this notification has more to say" is
    // precisely "this body does not fit in one line at the width this row
    // actually has", and that is measured rather than counted, for the same
    // reason the To Do list measures: a character threshold is wrong in both
    // directions -- 40 characters can wrap to three lines in a narrow panel,
    // and 90 characters of short words can fit in one.
    //
    // A hidden Text, not TextMetrics. TextMetrics cannot answer "how many
    // lines"; and the VISIBLE text cannot either, because `maximumLineCount:
    // 1` caps its own lineCount at the thing being tested -- the cap is
    // exactly the signal that was thrown away. This one carries the same
    // font, text and width and no cap, so its lineCount is the real answer.
    //
    // `false` while expanded, because there is no longer a one-line budget
    // to overflow: the whole body is on screen. Callers decide what to do
    // with an expanded row on their own terms.
    Text {
        id: bodyMeasure
        visible: false
        font: bodyPreviewText.font
        textFormat: bodyPreviewText.textFormat
        text: bodyPreviewText.text
        width: bodyPreviewText.width
        wrapMode: Text.WordWrap
    }

    readonly property bool isTruncated: {
        if (root.expanded)
            return false;
        if (bodyMeasure.width <= 0)
            return false;
        return bodyMeasure.lineCount > 1;
    }

    SequentialAnimation { // Drag finish animation
        id: destroyAnimation
        property bool left: true
        running: false

        NumberAnimation {
            target: background.anchors
            property: "leftMargin"
            to: (root.width + root.dismissOvershoot) * (destroyAnimation.left ? -1 : 1)
            duration: root.dismissDuration
            // OutQuint, not the shell's spatial bezier. See the note on
            // `dismissDuration`: this is a dismissal, not a move, and what it
            // needs is velocity in the first frames.
            easing.type: Easing.OutQuint
        }
        onFinished: () => {
            Notifications.discardNotification(notificationObject.notificationId);
        }
    }

    // (A `hoverDel` HoverHandler lived here and existed only to reveal the
    // popup's delete button. The button is always visible now -- see the note
    // on it -- so the handler had no reader left and is gone.)

    DragManager { // Drag manager
        id: dragManager
        anchors.fill: root
        anchors.leftMargin: root.expanded ? -notificationIcon.implicitWidth : 0
        interactive: expanded
        automaticallyReset: false
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton

        onClicked: (mouse) => {
            if (mouse.button === Qt.MiddleButton) {
                root.destroyWithAnimation();
            } else if (mouse.button === Qt.LeftButton) {
                // The group owns the expansion state (`expanded` here is bound
                // to it), so the row reports the click and the group decides.
                root.rowClicked();
            }
        }

        onDraggingChanged: () => {
            if (dragging) {
                root.qmlParent.dragIndex = root.index ?? root.parent.children.indexOf(root);
            }
        }

        onDragDiffXChanged: () => {
            root.qmlParent.dragDistance = dragDiffX;
        }

        onDragReleased: (diffX, diffY) => {
            if (Math.abs(diffX) > root.dragConfirmThreshold)
                root.destroyWithAnimation(diffX < 0);
            else 
                dragManager.resetDrag();
        }
    }

    NotificationAppIcon { // App icon
        id: notificationIcon
        opacity: (!onlyNotification && notificationObject.image != "" && expanded) ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        image: notificationObject.image
        anchors.right: background.left
        anchors.top: background.top
        anchors.rightMargin: 10
    }

    Rectangle { // Background of notification item
        id: background
        width: parent.width
        anchors.left: parent.left
        radius: Appearance.rounding.small
        anchors.leftMargin: root.xOffset

        Behavior on anchors.leftMargin {
            enabled: !dragManager.dragging
            NumberAnimation {
                duration: Appearance.animation.elementMove.duration
                easing.type: Appearance.animation.elementMove.type
                easing.bezierCurve: Appearance.animationCurves.expressiveFastSpatial
            }
        }

        color: (expanded && !onlyNotification) ? 
            (notificationObject.urgency == NotificationUrgency.Critical) ? 
                ColorUtils.mix(Appearance.colors.colSecondaryContainer, Appearance.colors.colLayer2, 0.35) :
                (Appearance.colors.colLayer3) :
            ColorUtils.transparentize(Appearance.colors.colLayer3)

        implicitHeight: expanded ? (contentColumn.implicitHeight + padding * 2) : summaryRow.implicitHeight
        Behavior on implicitHeight {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }

        ColumnLayout { // Content column
            id: contentColumn
            anchors.fill: parent
            anchors.margins: expanded ? root.padding : 0
            spacing: 3

            Behavior on anchors.margins {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            RowLayout { // Summary row
                id: summaryRow
                visible: !root.onlyNotification || !root.expanded
                Layout.fillWidth: true
                // Tall enough for the ACTION button's target, not just
                // for the text.
                //
                // It used to be the summary's height alone, which made the row
                // exactly one line high while the action was centred inside it
                // -- so it hung over the card's top and bottom edges, and its
                // hover backdrop would have spilled outside the card entirely.
                // The card clips, so the spill was not merely untidy: the
                // clipped part of the target stops receiving the pointer, and
                // a target whose edges are dead feels broken. A row is as tall
                // as its tallest thing.
                implicitHeight: Math.max(
                    summaryText.implicitHeight,
                    bodyPreviewText.implicitHeight,
                    root.actionSize
                )
                StyledText {
                    id: summaryText
                    Layout.fillWidth: summaryTextMetrics.width >= root.width * root.summaryElideRatio
                    visible: !root.onlyNotification
                    font.pixelSize: root.fontSize
                    color: Appearance.colors.colOnLayer3
                    elide: Text.ElideRight
                    text: root.notificationObject.summary || ""
                }
                StyledText {
                    id: bodyPreviewText
                    opacity: !root.expanded ? 1 : 0
                    visible: opacity > 0
                    Layout.fillWidth: true
                    Behavior on opacity {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                    font.pixelSize: root.fontSize
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                    wrapMode: Text.Wrap // Needed for proper eliding????
                    maximumLineCount: 1
                    textFormat: Text.StyledText
                    text: {
                        return NotificationUtils.processNotificationBody(notificationObject.body, notificationObject.appName || notificationObject.summary).replace(/\n/g, "<br/>")
                    }
                }
                // The row's one action, matching the To Do list's task row so the two
                // panels in the same sidebar are read the same way: no row
                // tint on hover, and the ONLY feedback being the action icon
                // itself.
                //
                // Sidebar-only, and ALWAYS visible rather than revealed on
                // hover -- the sidebar's rule (see the To Do list's rows) is
                // that a row does not change appearance when the pointer
                // passes over it, and an action that appears with the pointer
                // is an action you have to hunt for.
                //
                // What reacts to hover is the button, not the row: a backdrop
                // behind the glyph and a brighter glyph. A target the pointer
                // is over has to look like a target, or the action is
                // undiscoverable -- the two are not in tension, since one is
                // "this row is under the pointer" and the other is "this
                // button is under the pointer".
                //
                // The popup keeps the ripple delete it always had, in the
                // corner a corner card puts it in. Same action, same look;
                // only the chrome around it differs.
                RowLayout {
                    Layout.fillWidth: false
                    Layout.fillHeight: false
                    Layout.alignment: Qt.AlignVCenter
                    // FIXED whether or not anything is hovered, and this is
                    // load-bearing rather than cosmetic: a width that changed
                    // on hover would change how much body text fits on the
                    // row, which would change `isTruncated`, which would make
                    // the row's expandability flicker as the pointer crossed
                    // it. A measurement that moves with the pointer is not a
                    // measurement.
                    Layout.preferredWidth: root.actionSize
                    Layout.preferredHeight: root.actionSize
                    spacing: 0
                    // GONE once the row is open.
                    //
                    // The collapsed row has exactly one job beyond reading:
                    // get this notification out of the list quickly. The open
                    // row is a different object -- it is the notification, in
                    // full, with the actions the sending app offered for it --
                    // and on that one a floating × in the corner is a
                    // duplicate of the Close button down below, sitting far
                    // enough away to be a second, ambiguous target. Thunderbird
                    // also has its own "Delete", which deletes the MAIL; two
                    // delete-looking controls on one card, one of which erases
                    // an email, is the worst possible thing to leave lying
                    // around.
                    visible: !root.popup && !root.expanded

                    // Dismiss this one notification.
                    //
                    // It sits inside the row rather than in a strip of its own
                    // outside the card. It was tried there -- a 30px gutter the
                    // card was inset to make room for -- and it cost the row a
                    // third of the panel's width to hold one icon, which is
                    // the wrong trade for a list that is mostly text.
                    Item {
                        Layout.preferredWidth: root.actionSize
                        Layout.preferredHeight: root.actionSize
                        Layout.alignment: Qt.AlignVCenter

                        // The bleed is drawn INTO the row's own padding
                        // rather than past it: the target overhangs the plate
                        // by 4px a side, and `contentColumn` spans the whole
                        // card, so those 4px land inside the card rather than
                        // on whatever is beyond it.

                        // Hover backdrop, and the hover box.
                        //
                        // 26x26, exactly as it always was, and this square is
                        // also the pointer target -- the one you have to hit.
                        // Growing it to 38 was wrong; see the note on
                        // `actionSize`.
                        //
                        // The colour is a translucent `colPrimary` wash rather
                        // than a layer token, and that is the whole trick:
                        // every `colLayerNHover` token in this theme carries
                        // the SAME alpha as the fill it is meant to lighten,
                        // because both are `solveOverlayColor`d against
                        // `1 - contentTransparency`. Solved side by side over
                        // the card they land three values apart (#2A vs #22),
                        // which is not a hover state, it is a rounding error.
                        // A white wash over an opaque card always lightens, by
                        // an amount we choose, whatever the theme and the
                        // transparency slider have done.
                        Rectangle {
                            anchors.fill: parent
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colPrimary
                            opacity: deleteHover.containsMouse ? 0.14 : 0

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: root.hoverDuration
                                    easing.type: root.hoverCurve
                                }
                            }
                        }

                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "close"
                            iconSize: root.actionIconSize
                            color: deleteHover.containsMouse
                                ? Appearance.colors.colPrimary
                                : Appearance.m3colors.m3outline
                        }

                        // The hover SOURCE, and the tap.
                        //
                        // `anchors.fill: parent` -- the SAME square as the
                        // plate above, so `containsMouse` is true exactly
                        // where the plate lights and nowhere else. That
                        // coincidence is the whole point, and it is why this
                        // must never be sized independently of the plate: a
                        // target larger than its plate gives you a ring around
                        // the button that lights nothing and dismisses
                        // nothing, and a target smaller than it gives you a
                        // plate you cannot click the middle of.
                        //
                        // The glyph is 15 inside a 26 box, so the trigger is
                        // the box. You never have to hit the × itself.
                        //
                        // A zero-button MouseArea, declared FIRST so it reports
                        // hover without taking the tap from the handler that
                        // performs it. Not the TapHandler, which has no
                        // `hovered` anywhere in its Qt 6 chain (such a read is
                        // silently `undefined`), and not a HoverHandler, which
                        // was tried here and reported `hovered` stuck TRUE on
                        // every row at once. A MouseArea is what this card's
                        // own hover uses (see NotificationGroup's
                        // `root.containsMouse`), so the two agree by
                        // construction.
                        MouseArea {
                            id: deleteHover
                            // Centred on the plate and 4px larger on every
                            // side -- `anchors.fill` would clamp it back to
                            // the plate and put us where we started.
                            anchors.centerIn: parent
                            width: root.actionHitSize
                            height: root.actionHitSize
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                            propagateComposedEvents: true
                        }

                        TapHandler {
                            id: deleteMouse
                            onTapped: root.destroyWithAnimation()
                        }
                    }
                }

                // The popup's own single delete: a ripple button, not a pair
                // of plain icons.
                //
                // ALWAYS THERE, and that is the fix rather than the styling.
                // It used to be revealed by the pointer -- `visible: root.popup
                // && (hoverDel.hovered || opacity > 0)`, faded in on `hovered`
                // -- and a control that appears under the pointer is a control
                // that takes its own space from the text as it arrives. The row
                // is one line of body text, so the notification re-flowed the
                // instant the pointer crossed it: the text elided differently,
                // the content jumped sideways, and the card read as extending
                // itself at the pointer even when it had everything it needed
                // to say on one line already.
                //
                // Worse, the reveal was circular: the button is there to
                // dismiss with, but the only way to see it was to point at the
                // card -- the one gesture a notification is not asking for.
                // Visible now, like the sidebar row's plate, so hovering a card
                // changes nothing at all.
                RippleButton {
                    Layout.fillWidth: false
                    // Never on a signal: "Copied" is not something to throw
                    // away, and a delete icon is the exact notification chrome
                    // this card is supposed to stop wearing.
                    visible: root.popup && !(root.notificationObject?.isSignal ?? false)
                    implicitWidth: 24
                    implicitHeight: 24
                    // The same wash as the sidebar's delete plate, and for the same
                    // reason: a layer token carries the fill's own alpha and
                    // vanishes into a solid card. See the note on that plate.
                    colRipple: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.18)
                    onClicked: root.destroyWithAnimation()
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "delete"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colSubtext
                    }
                }
            }

            ColumnLayout { // Expanded content
                id: expandedContentColumn
                Layout.fillWidth: true
                opacity: root.expanded ? 1 : 0
                visible: opacity > 0

                StyledText { // Notification body (expanded)
                    id: notificationBodyText
                    Behavior on opacity {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                    Layout.fillWidth: true
                    font.pixelSize: root.fontSize
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    textFormat: Text.RichText
                    text: {
                        return `<style>img{max-width:${expandedContentColumn.width}px;}</style>` + 
                            `${NotificationUtils.processNotificationBody(notificationObject.body, notificationObject.appName || notificationObject.summary).replace(/\n/g, "<br/>")}`
                    }

                    onLinkActivated: (link) => {
                        Qt.openUrlExternally(link)
                        GlobalStates.sidebarRightOpen = false
                    }
                    
                    PointingHandLinkHover {}
                }

                Item {
                    Layout.fillWidth: true
                    implicitWidth: actionsFlickable.implicitWidth
                    implicitHeight: actionsFlickable.implicitHeight

                    layer.enabled: true
                    layer.effect: OpacityMask {
                        maskSource: Rectangle {
                            width: actionsFlickable.width
                            height: actionsFlickable.height
                            radius: Appearance.rounding.small
                        }
                    }

                    ScrollEdgeFade {
                        target: actionsFlickable
                        vertical: false
                    }

                    StyledFlickable { // Notification actions
                        id: actionsFlickable
                        anchors.fill: parent
                        implicitHeight: actionRowLayout.implicitHeight
                        contentWidth: actionRowLayout.implicitWidth

                        Behavior on opacity {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on height {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on implicitHeight {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }

                        RowLayout {
                            id: actionRowLayout
                            Layout.alignment: Qt.AlignBottom

                            NotificationActionButton {
                                Layout.fillWidth: true
                                buttonText: Translation.tr("Close")
                                urgency: notificationObject.urgency
                                implicitWidth: (notificationObject.actions.length == 0) ? ((actionsFlickable.width - actionRowLayout.spacing) / 2) : 
                                    (contentItem.implicitWidth + leftPadding + rightPadding)

                                onClicked: {
                                    root.destroyWithAnimation()
                                }

                                contentItem: MaterialSymbol {
                                    iconSize: Appearance.font.pixelSize.larger
                                    horizontalAlignment: Text.AlignHCenter
                                    color: (notificationObject.urgency == NotificationUrgency.Critical) ? 
                                        Appearance.m3colors.m3onSurfaceVariant : Appearance.m3colors.m3onSurface
                                    text: "close"
                                }
                            }// The actions the SENDING APP offered.
                            //
                            // This is the part of the row that is not ours, and
                            // it is the reason the open card is worth opening:
                            // Thunderbird offers "Mark as Read" and "Delete",
                            // where Delete removes the MAIL rather than the
                            // notification that mentioned it; a calendar
                            // offers Snooze; a chat client offers Reply. None of
                            // that can be reconstructed from the text we were
                            // handed, and inventing substitutes for it -- which
                            // is what a generic row of our own buttons is --
                            // throws away the one thing the app knew and we did
                            // not.
                            //
                            // So there is nothing here but what the app sent,
                            // plus Close. No copy button: the text is already
                            // on screen in full, and pasting it out of a
                            // notification loses the one thing that made it
                            // findable later -- which app it came from.
                            Repeater {
                                id: actionRepeater
                                model: notificationObject.actions
                                NotificationActionButton {
                                    id: notifAction
                                    required property var modelData
                                    Layout.fillWidth: true
                                    // `text` is the localised label the app
                                    // asked for; `title` is the raw one.
                                    // Prefer the localised form and fall back,
                                    // because a few apps send an empty `text`.
                                    buttonText: (modelData.text && modelData.text.length)
                                        ? modelData.text
                                        : (modelData.title || "")
                                    urgency: notificationObject.urgency
                                    onClicked: {
                                        Notifications.attemptInvokeAction(notificationObject.notificationId, modelData.identifier);
                                    }
                                }
                            }

                        }
                    }
                }
            }
        }
    }
}












