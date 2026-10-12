import qs.services
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications

/**
 * A group of notifications from the same app.
 * Similar to Android's notifications
 */
MouseArea { // Notification group area
    id: root
    property var notificationGroup
    // Card hover timing, matching the action plates inside it.
    readonly property int hoverDuration: Math.round(70 * Appearance.animationCurves.motionScale)
    readonly property int hoverCurve: Easing.OutCubic
    property var notifications: notificationGroup?.notifications ?? []
    property int notificationCount: notifications.length
    property bool multipleNotifications: notificationCount > 1
    // THE CARD'S OWN EXPANSION STATE -- deliberately separate from `expanded`
    // below, because a card has two independent reasons to be open.
    //
    //   localExpanded  what this card's own chevron says
    //   shownExpanded what it actually looks like, once the list-wide view
    //                  mode has had its say
    //
    // They used to be the same property, which is why the view button could
    // not work: setting every card's `expanded` destroyed the record of
    // which cards the user had opened by hand, so collapsing one card and
    // then flipping the view threw that choice away. The old writable
    // `expanded` is gone rather than left shadowed by a readonly one of a
    // similar name -- two properties that differ only by a prefix is exactly
    // the kind of pair that gets assigned to the wrong one.
    property bool localExpanded: false

    // Whether this card is the transient top-right popup or a row in the
    // sidebar's history list. Both users exist, and several decisions below
    // hinge on which one this is.
    property bool popup: false

    // Is the pointer over the app-name button?
    //
    // Owned by the CARD rather than left inside the header because someone
    // outside has to be able to read it: the card's own tooltip (in
    // NotificationListView) has to stand down while the name's tooltip is up,
    // or hovering the name paints two labels at once. It is assigned from the
    // hit area below rather than bound to it -- an object cannot see an id
    // declared in its children, only the other way round -- and this way the
    // only writer is the hover handler itself.
    property bool appNameHovered: false

    // The list-wide "show everything" switch, owned by NotificationListView
    // and pushed down here. FALSE by default, so the popup -- which is the
    // other user of this component -- keeps its old behaviour of never being
    // force-opened, and so a card created outside a list (nothing does that
    // today, but) is still just its own chevron.
    property bool expandAll: false

    // What is actually on screen.
    //
    // The view mode is a DEFAULT, not an override: a card the user has since
    // closed by hand stays closed while the view is "all expanded", which is
    // the whole point of keeping the two states apart. `localExpanded` is
    // read as "the user opened it" only when the view is not forcing the
    // issue.
    readonly property bool shownExpanded: root.expandAll || root.localExpanded

    // The chevron points at what a press will DO, not at what is on screen.
    // That is why this reads `shownExpanded`: with the view on "all
    // expanded", every card is open and every chevron points up to close.
    readonly property bool isExpanded: root.shownExpanded
    property real padding: 10

    // ── The delete gutter ───────────────────────────────────────────────────
    //
    // Delete lives OUTSIDE the card, on its left, in a strip the card is
    // Does this card have anything hidden? Set by its NotificationItem, which
    // is the only thing that can MEASURE it -- the answer depends on the body
    // text at the width this row actually has, and the row is what knows that.
    //
    // Only meaningful for the sidebar, where a card is one notification. A
    // popup card can also be hiding further notifications from the same app,
    // so it counts as having more to show regardless.
    property bool anyTruncated: false

    function hasMoreToShow() {
        return root.popup || root.multipleNotifications || root.anyTruncated;
    }
    implicitHeight: background.implicitHeight

    property real dragConfirmThreshold: 70 // Drag further to discard notification
    property real dismissOvershoot: 20 // Account for gaps and bouncy animations
    property var qmlParent: root?.parent?.parent // There's something between this and the parent ListView
    property var parentDragIndex: qmlParent?.dragIndex
    property var parentDragDistance: qmlParent?.dragDistance
    property var dragIndexDiff: Math.abs(parentDragIndex - index)
    property real xOffset: dragIndexDiff == 0 ? parentDragDistance : 
        Math.abs(parentDragDistance) > dragConfirmThreshold ? 0 :
        dragIndexDiff == 1 ? (parentDragDistance * 0.3) :
        dragIndexDiff == 2 ? (parentDragDistance * 0.1) : 0

    function destroyWithAnimation(left = false) {
        root.qmlParent.resetDrag()
        background.anchors.leftMargin = background.anchors.leftMargin; // Break binding
        destroyAnimation.left = left;
        destroyAnimation.running = true;
    }

    // ── The "look here" flash (the bar's bell) ────────────────────────────
    //
    // Pressing the notification bell opens the sidebar AND flashes the newest
    // notification, because opening a list of eight rows does not by itself
    // answer "which of these is the one that just arrived". The flash is the
    // answer, and it is deliberately quick and self-cancelling: it points, it
    // does not become a state the user then has to dismiss.
    //
    // Watched through a Timer rather than a binding on the service's token.
    // A binding would be evaluated whenever the token changed, but the group
    // holding the notification may not EXIST yet at that moment -- the sidebar
    // is still animating in, so its delegate is created after the press. A
    // one-shot timer started on creation catches both orders: press-then-build
    // and build-then-press, and the liveness window in the service means a
    // delegate that arrives late does not inherit a stale flash.
    // `!root.popup` is load-bearing. This one component is the delegate for
    // BOTH lists -- the sidebar's history and the transient popup -- and the
    // popup's copy is created the instant a notification arrives, which is
    // inside the highlight window. Without the gate a press would flash the
    // same notification twice, in two places, and the popup's flash would be
    // the one that dies first.
    readonly property bool isHighlightTarget:
        !root.popup
        && Notifications.highlightIsLive()
        && root.notifications.some((n) => n?.notificationId === Notifications.highlightNotificationId)

    Timer {
        id: highlightArm
        interval: 40
        repeat: false
        onTriggered: if (root.isHighlightTarget) highlightPulse.restart()
    }

    // Re-arms on every press, so pressing the bell twice flashes twice.
    Connections {
        target: Notifications
        function onHighlightTokenChanged() { highlightArm.restart(); }
    }

    SequentialAnimation {
        id: highlightPulse
        // Bright, brief, gone. Rising fast reads as "this one"; lingering
        // reads as "this one is selected", which it is not.
        NumberAnimation {
            target: highlightWash
            property: "opacity"; to: 1
            duration: 90; easing.type: Easing.OutCubic
        }
        PauseAnimation { duration: 70 }
        NumberAnimation {
            target: highlightWash
            property: "opacity"; to: 0
            duration: 420; easing.type: Easing.InOutQuad
        }
    }

    // ── The popup's drop-in ─────────────────────────────────────────────
    //
    // Popup only, and that gate is the whole point: the sidebar's list was
    // already there when you opened it, so a card dropping into it would be
    // theatre. The corner popup is an ARRIVAL, and falling in from above the
    // top edge is what makes it read as having just arrived rather than as
    // something that has always been sitting in the corner.
    //
    // A `transform`, not `y`. A delegate's `y` belongs to the ListView, which
    // rewrites it every time it lays items out, so an animation on a property
    // something else owns gets cancelled the moment that owner touches it. A
    // Translate in the transform list is applied on top of whatever position
    // the view chose, so the card moves and the view never has an opinion.
    //
    // On ROOT, not on `background`, and the placement is load-bearing. The
    // drop shadow is a SIBLING of the card that anchors itself to it, and
    // anchoring follows position but knows nothing about transforms: a
    // translate on the card alone leaves the shadow parked at the resting
    // place with a floating rectangle of shadow where the card is not yet.
    // Shadow and card are both children of root, so one transform on root
    // carries the shadow down with the card.
    transform: Translate {
        id: dropTranslate
        y: 0
    }

    // ── The popup's drop-in, tuned ───────────────────────────────────────
    //
    // SLOWER AND SOFTER than the rest of the shell's motion, on purpose. This
    // is the one animation the user is looking straight at, in the corner of
    // their eye, with nothing else moving -- so it is the one that can afford
    // to be unhurried. A 350ms `elementMoveFast` here read as a flick: the
    // card was essentially in place before the eye finished travelling to it.
    //
    // 520ms, and matched to the fade-and-scale running alongside it on
    // `elementMove`'s 500ms. The two are one gesture, so they have to share a
    // clock: a drop that outran its own fade leaves the card visibly hanging
    // in mid-air while it is still becoming opaque.
    readonly property real dropDuration: 520

    // The curve. `elementMoveFast` was expressive but very front-loaded
    // ([0.42, 1.67, ...]) -- most of the distance covered early, which is
    // exactly the "too quick" quality. This one starts gently, spends most of
    // its time in the middle of the travel where the movement is easy to
    // follow, and the 1.28 first control point carries it just PAST its
    // resting line before it comes back. That small overshoot is what turns
    // an arrival into a landing: the card is dropped, it hits, it settles.
    //
    // The overshoot is held to about 3% of the travel. The popup list spaces
    // its cards by 3px, and a card that dipped much further than that would
    // briefly overlap the one below it during the settle -- a collision that
    // only shows up when two notifications arrive together, which is exactly
    // when the eye is on them.
    //
    // Deliberately hand-written rather than one of the shell's shared curves.
    // `expressiveDefaultSpatial` has no overshoot at all (it parks flat), and
    // Material's multi-segment `emphasized` cannot be expressed as the single
    // cubic that `Easing.BezierSpline` takes.
    readonly property list<real> dropCurve: [0.34, 1.18, 0.66, 1.0]

    SequentialAnimation {
        id: dropIn
        running: false
        NumberAnimation {
            target: dropTranslate
            property: "y"
            to: 0
            duration: Math.round(root.dropDuration * Appearance.animationCurves.motionScale)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.dropCurve
        }
    }

    function startDropIn() {
        if (!root.popup) return;
        // Measured on the NEXT tick, not now. The travel distance is the
        // card's own height, and at `Component.onCompleted` the text inside it
        // has not been laid out yet, so `implicitHeight` can still be 0 and
        // the card would drop four pixels and call it a day. The floor of 40
        // is a card that has not resolved its height for any reason.
        Qt.callLater(() => {
            if (!root.popup) return;
            dropTranslate.y = -(Math.max(background.implicitHeight, 40) + 10);
            dropIn.restart();
        });
    }

    Component.onCompleted: {
        highlightArm.restart();
        startDropIn();
    }

    hoverEnabled: true
    onContainsMouseChanged: {
        if (!root.popup) return;
        if (root.containsMouse) root.notifications.forEach(notif => {
            Notifications.cancelTimeout(notif.notificationId);
        });
        else root.notifications.forEach(notif => {
            Notifications.timeoutNotification(notif.notificationId);
        });
    }

    SequentialAnimation { // Drag finish animation
        id: destroyAnimation
        property bool left: true
        running: false

        NumberAnimation {
            target: background.anchors
            property: "leftMargin"
            to: (root.width + root.dismissOvershoot) * (destroyAnimation.left ? -1 : 1)
            duration: Appearance.animation.elementMove.duration
            easing.type: Appearance.animation.elementMove.type
            easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
        }
        onFinished: () => {
            root.notifications.forEach((notif) => {
                Qt.callLater(() => {
                    Notifications.discardNotification(notif.notificationId);
                });
            });
        }
    }

    function toggleExpanded() {
        if (root.shownExpanded) implicitHeightAnim.enabled = true;
        else implicitHeightAnim.enabled = false;
        // Only ever the CARD's own state. The list-wide mode is applied by
        // NotificationListView through `expandAll` and is deliberately not
        // written here, so pressing one chevron cannot quietly un-do the view
        // the whole list is in.
        root.localExpanded = !root.shownExpanded;
    }

    // Open the app that sent this notification.
    //
    // This used to be what a click ANYWHERE on the card did, whenever the
    // notification happened to fit in one row -- so the same gesture opened
    // the hidden text or launched Firefox depending on how long the message
    // was, which is the worst of both: the verb changes under the pointer and
    // nothing on screen says which one you are about to get.
    //
    // It is now bound to the app NAME only. Clicking the card expands it;
    // clicking the name is the one deliberate gesture that launches something,
    // and it is labelled, hittable and visible as such.
    function openSenderApp() {
        if (!root.notifications || root.notifications.length === 0)
            return;
        Notifications.focusSender(root.notifications[0]);
    }

    DragManager { // Drag manager
        id: dragManager
        anchors.fill: parent
        interactive: !root.shownExpanded
        automaticallyReset: false
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onPressed: {
            // Right-click is the same verb as the chevron, so it obeys the
            // same rule: nothing hidden, nothing to expand.
            if (mouse.button === Qt.RightButton && root.hasMoreToShow())
                root.toggleExpanded();
        }

        onClicked: (mouse) => {
            if (mouse.button === Qt.MiddleButton)
                root.destroyWithAnimation();
            else if (mouse.button === Qt.LeftButton) {
                // The popup has no expansion to spend a click on -- it is one
                // card, briefly, and the text is already fully visible -- so
                // it keeps the jump.
                if (root.popup) {
                    // The card and the app go together.
                    //
                    // The popup's click is "take me there", and the notification
                    // that asked the question has been answered: leaving it in
                    // the corner means a card that describes what the user is
                    // now looking at, hanging over the window they just
                    // brought forward, until its own timeout gets around to it.
                    // It is the same departure the delete button performs
                    // (slide out, then discard), so the click and the delete
                    // differ in what they DO, not in how the card leaves.
                    //
                    // Dismissed AFTER the jump, not before: `focusSender` is
                    // what raises or launches the app, and it reads the
                    // notification to do it.
                    root.openSenderApp();
                    root.destroyWithAnimation();
                    return;
                }
                // In the SIDEBAR the app NAME launches, and the rest of
                // the card expands. Opening the app is now the name's job
                // (openSenderApp), so a click on the card body can never
                // surprise you by bringing an application to the front.
                //
                // Resolved by WHERE the pointer is rather than by a second
                // clickable area stacked on top: a MouseArea over the name
                // that took the press would also take the drag, and a
                // notification could no longer be swiped away by starting the
                // swipe on its header. This way the name's hit area exists for
                // hover and for the click decision, and the card's own
                // DragManager still owns every gesture.
                if (appNameHit.containsMouse) {
                    root.openSenderApp();
                    return;
                }
                root.toggleExpanded();
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

    StyledRectangularShadow {
        target: background
        visible: popup
    }
    Rectangle { // Background of the notification
        id: background
        // Full width, edge to edge. It was inset to make room for a delete
        // gutter outside the card, and that gutter is gone: the delete sits
        // INSIDE the row now, beside the copy icon. Taking a third of the
        // panel's width back is the whole point -- a notification is mostly
        // text, and text that is not shown is the most expensive thing a
        // list of notifications can spend.
        anchors.left: parent.left
        anchors.leftMargin: root.xOffset
        width: parent.width
        // SOLID fill, in both states.
        //
        // The sidebar card used to be `colLayer2`, and that is where the "the
        // row is a black box" bug came from. `colLayer2` is
        // `solveOverlayColor(colLayer1Base, surfaceContainer, 1 - contentTransparency)`:
        // at the shell's transparency setting that is a 10-20% ALPHA tint, not
        // a colour. Composited over the sidebar it reads ~#222 -- fine. But the
        // sidebar is itself translucent, so whatever window is behind it shows
        // through the card too: over a dark window the same card composites to
        // #060606, while the sidebar around it stays #21. Hence a black slab
        // floating in the middle of the panel, with the copy and delete icons
        // sitting on it and nothing else in the row visible.
        //
        // `colBackgroundSurfaceContainer` is the popup's card token, which is
        // transparentized against `backgroundTransparency` (small) rather than
        // against the user's content transparency -- which is exactly the
        // difference between "a surface" and "a tint of whatever is behind".
        // One card, one fill, sidebar and popup.
        color: Appearance.colors.colBackgroundSurfaceContainer
        radius: Appearance.rounding.normal
        Behavior on anchors.leftMargin {
            enabled: !dragManager.dragging
            NumberAnimation {
                duration: Appearance.animation.elementMove.duration
                easing.type: Appearance.animation.elementMove.type
                easing.bezierCurve: Appearance.animationCurves.expressiveFastSpatial
            }
        }
        
        clip: true
        implicitHeight: root.shownExpanded ? 
            row.implicitHeight + padding * 2 :
            Math.min(80, row.implicitHeight + padding * 2)

        Behavior on implicitHeight {
            id: implicitHeightAnim
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        // The flash itself. A plain overlay rather than an animated
        // `background.color`: the card's colour carries its own state
        // (hover, drag, expanded) and animating it from two places at once
        // is how those states end up fighting. An overlay on top of the
        // fill, under the content, cannot.
        Rectangle {
            id: highlightWash
            anchors.fill: parent
            radius: Appearance.rounding.normal
            color: Appearance.colors.colPrimary
            opacity: 0
            // Under the row: the wash is a tint on the card, not a scrim over
            // the text. Declared first so the RowLayout above it wins.
        }

        // The card's hover state.
        //
        // A translucent wash of the foreground colour rather than a different
        // fill colour, and that is the whole point. Swapping the fill for a
        // "hover" token was tried and the card went DARKER: these layer
        // tokens are solved against the surface BENEATH them, so
        // `colLayer2Hover` is not "colLayer2, but lighter" -- it is a
        // composite computed for a different backdrop, and on this card it
        // came out darker than the fill it was replacing. Reaching for a
        // token to lighten a surface is arithmetic with no error message; a
        // low-opacity wash over whatever is beneath is guaranteed to lighten,
        // whatever the theme and the transparency setting have done to the
        // layers below.
        //
        // Same structure as the highlight wash above it, and for the same
        // reason: a tint UNDER the content.
        Rectangle {
            id: hoverWash
            anchors.fill: parent
            radius: Appearance.rounding.normal
            color: Appearance.colors.colPrimary
            // Low enough to read as the card catching the light rather than
            // as a second highlight, and -- now that the card fill is solid --
            // high enough to actually be seen against it. At 0.05 over a #16
            // card this was a two-level difference the eye discards; 0.09 is
            // visible without competing with the highlight wash.
            opacity: (!root.popup && root.containsMouse) ? 0.09 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: root.hoverDuration
                    easing.type: root.hoverCurve
                }
            }
        }

        RowLayout { // Left column for icon, right column for content
            id: row
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: root.padding
            spacing: 10

            NotificationAppIcon { // Icons
                Layout.alignment: Qt.AlignTop
                Layout.fillWidth: false
                image: root?.multipleNotifications ? "" : notificationGroup?.notifications[0]?.image ?? ""
                appIcon: root.notificationGroup?.appIcon
                summary: root.notificationGroup?.notifications[root.notificationCount - 1]?.summary
                urgency: root.notifications.some(n => n.urgency === NotificationUrgency.Critical.toString()) ? 
                    NotificationUrgency.Critical : NotificationUrgency.Normal
            }

            ColumnLayout { // Content
                Layout.fillWidth: true
                spacing: root.shownExpanded ? (root.multipleNotifications ? 
                    (notificationGroup?.notifications[root.notificationCount - 1].image != "") ? 35 : 
                    5 : 0) : 0
                // spacing: 00
                Behavior on spacing {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }

                Item { // App name (or summary when there's only 1 notif) and time
                    id: topRow
                    // spacing: 0
                    Layout.fillWidth: true
                    // Breathing room under the chevron.
                    //
                    // The content column's spacing is ZERO while the card is
                    // collapsed, and the chevron is visible while collapsed
                    // whenever the card has something hidden behind it. So the
                    // chevron's hover plate ran straight into the first
                    // notification's row -- which is where the × lives -- and
                    // the two read as one long smear rather than two controls
                    // that happen to stack. Only when the chevron is on screen;
                    // a card with nothing to expand does not pay for it.
                    Layout.bottomMargin: expandButton.visible ? 5 : 0
                    property real fontSize: Appearance.font.pixelSize.smaller
                    property bool showAppName: root.multipleNotifications
                    implicitHeight: Math.max(topTextRow.implicitHeight, expandButton.implicitHeight, countBadge.implicitHeight)

                    // The count, and it lives OUTSIDE the button.
                    //
                    // It was inside, to the left of the chevron, which is what
                    // made the button a variable-width lozenge: the badge
                    // widened it, the centred glyph slid left with it, and the
                    // arrow stopped lining up with the × below it. A label is
                    // not a control and has no business changing a control's
                    // size, so it now sits on the card as a label, beside the
                    // square, where it costs the button nothing.
                    StyledText {
                        id: countBadge
                        anchors.right: expandButton.left
                        anchors.rightMargin: 5
                        anchors.verticalCenter: expandButton.verticalCenter
                        visible: expandButton.visible && root.notificationCount > 1
                        text: root.notificationCount
                        font.pixelSize: topRow.fontSize
                        color: Appearance.colors.colSubtext
                    }

                    RowLayout {
                        id: topTextRow
                        anchors.left: parent.left
                        anchors.right: countBadge.visible ? countBadge.left : expandButton.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 5
                        Item {
                            // The app name is a BUTTON now, so it gets a box
                            // to be hit in. Declared as a sibling of the time
                            // rather than as a MouseArea over the text, so the
                            // target is the text's own width -- a hit area
                            // stretched to the whole row would swallow the
                            // click that is supposed to expand the card, which
                            // is the one thing the card body is for.
                            id: appNameBox
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            implicitHeight: appName.implicitHeight

                            readonly property color restingColor: topRow.showAppName ?
                                Appearance.colors.colSubtext :
                                Appearance.colors.colOnLayer2
                            readonly property bool hovered: appNameHit.containsMouse

                            // The hover PLATE.
                            //
                            // The colour step alone was the whole affordance,
                            // and a line of text that changes tone under the
                            // pointer reads as a list row being highlighted --
                            // not as a button. The card's other controls (the
                            // chevron, the row's action plates) all answer
                            // hover with a wash behind them, so the name
                            // answering the same way is what makes it one of
                            // them: a target, not a label.
                            //
                            // Sized to the PAINTED text rather than to the box:
                            // the box is `Layout.fillWidth` and can be most of
                            // the row, and a highlight that wide would look
                            // like the row was selected. `paintedWidth` is what
                            // an ELIDED line actually drew, so the plate stops
                            // where the words stop instead of running on into
                            // the ellipsis and past it.
                            Rectangle {
                                id: appNamePlate
                                // The label gets ROOM inside the box: 8px either
                                // side, 5px above and below. At 6/3 the wash sat
                                // exactly on the glyphs -- touching the border on
                                // the top and bottom of every ascender and
                                // descender -- and a box that tight reads as the
                                // text having been SELECTED rather than as a
                                // button waiting to be pressed. These are the
                                // numbers the plate is anchored by, so the
                                // hit area below follows them (one rectangle,
                                // one target) and a bigger label only grows the
                                // box with it.
                                //
                                // Declared before the anchors that use them, so
                                // `padH` is already set when the left inset
                                // below asks for it.
                                readonly property real padH: 8
                                readonly property real padV: 5

                                // Both sides, not just the right.
                                //
                                // The width already gives the words `padH` on
                                // the right; on the LEFT the label is flush with
                                // the box, because it has to be -- the name lines
                                // up with the notification body underneath it, so
                                // the text cannot be pushed inwards without
                                // breaking that alignment. The plate therefore
                                // reaches `padH` back out of the box instead, and
                                // the two paddings come out equal. Before this the
                                // wash started dead on the first glyph with all of
                                // its air on the far side of the word.
                                //
                                // The reach lands in the row's 10px gap to the
                                // app icon, so the plate still clears the icon by
                                // 2px -- it never covers it.
                                anchors.left: parent.left
                                anchors.leftMargin: -padH
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(appName.paintedWidth, appNameBox.width) + padH * 2
                                height: appName.implicitHeight + padV * 2
                                radius: Appearance.rounding.verysmall
                                // A `colPrimary` wash, not a `colLayerNHover`
                                // token: those carry `1 - contentTransparency`
                                // in their alpha and land a couple of values
                                // from invisible on a solid card. Same recipe as
                                // the chevron's plate.
                                color: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.16)
                                opacity: appNameBox.hovered ? 1 : 0
                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: root.hoverDuration
                                        easing.type: root.hoverCurve
                                    }
                                }
                            }

                            StyledText {
                                id: appName
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: (topRow.showAppName ?
                                    notificationGroup?.appName :
                                    notificationGroup?.notifications[0]?.summary) || ""
                                font.pixelSize: topRow.showAppName ?
                                    topRow.fontSize :
                                    Appearance.font.pixelSize.small
                                color: appNameBox.hovered ?
                                    Appearance.colors.colPrimary :
                                    appNameBox.restingColor

                                Behavior on color {
                                    ColorAnimation {
                                        duration: 100
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            // Hover is a plain MouseArea with hoverEnabled
                            // rather than a TapHandler, which has no `hovered`
                            // anywhere in its Qt 6 chain -- the property reads
                            // undefined, so a TapHandler-based affordance here
                            // would silently never light up.
                            MouseArea {
                                id: appNameHit
                                // The plate IS the target: same rectangle, so the
                                // thing that lights up under the pointer is the
                                // thing a click acts on. It used to fill the box,
                                // which is `Layout.fillWidth` -- the wash would
                                // then end at the words while the click zone ran
                                // on into the empty space beside them, so a click
                                // out there opened the app instead of expanding
                                // the card (the opposite of what this header is
                                // documented to do).
                                anchors.fill: appNamePlate
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                                propagateComposedEvents: true
                                cursorShape: Qt.PointingHandCursor

                                // Report the hover UP to the card: the card's
                                // own tooltip stands down while this one is up
                                // (see NotificationListView), and the plate and
                                // the name's colour read the same flag.
                                onContainsMouseChanged: root.appNameHovered = containsMouse

                                StyledToolTip {
                                    // The name is a button, and nothing else on
                                    // the card said what pressing it does: the
                                    // card's tooltip talks about the card, and
                                    // the pointer cursor is only visible once
                                    // the pointer is already there. This is the
                                    // label for the control itself.
                                    //
                                    // `alternativeVisibleCondition` rather than
                                    // the parent's `hovered`: the plate already
                                    // reads `containsMouse`, and a tooltip that
                                    // needs a different hover property of the
                                    // same MouseArea to be real is a tooltip
                                    // that silently never shows up (the trap
                                    // the `hovered` note above is about).
                                    text: Translation.tr("Click to open %1")
                                        .arg(root.notificationGroup?.appName || Translation.tr("the app"))
                                    extraVisibleCondition: false
                                    alternativeVisibleCondition: appNameBox.hovered
                                }
                            }
                        }
                        StyledText {
                            id: timeText
                            // Layout.fillWidth: true
                            Layout.rightMargin: 10
                            horizontalAlignment: Text.AlignLeft
                            text: NotificationUtils.getFriendlyNotifTimeString(notificationGroup?.time)
                            font.pixelSize: topRow.fontSize
                            color: Appearance.colors.colSubtext
                        }
                    }
                    NotificationGroupExpandButton {
                        id: expandButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        count: root.notificationCount
                        // The arrow is the one place that must reflect the CARD's real state
                        // rather than the list's intent, so it is driven by
                        // `isExpanded` and not by `localExpanded`: with the
                        // view on "all expanded" every chevron reads as
                        // "close me", which is exactly what pressing one does.
                        expanded: root.isExpanded
                        fontSize: topRow.fontSize
                        // Only offered when it would do something. A chevron
                        // on a notification with nothing hidden behind it is
                        // an affordance for a state that cannot exist, and it
                        // stays on screen once expanded so the row can be
                        // closed again.
                        visible: root.isExpanded || root.hasMoreToShow()
                        onClicked: { root.toggleExpanded() }
                        altAction: () => { root.toggleExpanded() }

                        StyledToolTip {
                            text: Translation.tr("Tip: right-clicking a notification\nalso expands it")
                        }
                    }
                }

                StyledListView { // Notification body (expanded)
                    id: notificationsColumn
                    implicitHeight: contentHeight
                    Layout.fillWidth: true
                    spacing: root.shownExpanded ? 5 : 3
                    // clip: true
                    interactive: false
                    Behavior on spacing {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                    model: ScriptModel {
                        values: root.shownExpanded ? root.notifications.slice().reverse() : 
                            root.notifications.slice().reverse().slice(0, 2)
                    }
                    delegate: NotificationItem {
                        required property int index
                        required property var modelData
                        notificationObject: modelData
                        // The card's two expansion inputs reach the row here, and the ROW needs
                        // only the resolved answer.
                        expanded: root.shownExpanded
                        onlyNotification: (root.notificationCount === 1)
                        // Passed down so the row can tell the sidebar's history
                        // list from the transient popup: the sidebar rows get
                        // the To Do list's always-visible copy button, the
                        // popup keeps its single ripple delete.
                        popup: root.popup
                        opacity: (!root.shownExpanded && index == 1 && root.notificationCount > 2) ? 0.5 : 1
                        visible: root.shownExpanded || (index < 2)
                        anchors.left: parent?.left
                        anchors.right: parent?.right

                        // Report truncation UP. The chevron and the
                        // click-to-expand both live on the card, and neither
                        // can work without knowing whether this row is hiding
                        // anything -- which only the row can measure.
                        onIsTruncatedChanged: {
                            // Only the sidebar's single-notification cards
                            // take their state from this. A popup card with
                            // several notifications has several rows
                            // reporting, and last-writer-wins would make its
                            // chevron flicker between rows.
                            if (!root.popup)
                                root.anyTruncated = isTruncated;
                        }

                        // Clicking a row while the card is already expanded
                        // collapses it: same verb, same affordance, and the
                        // row's own drag manager is what receives the click
                        // once the group has stopped accepting them.
                        onRowClicked: root.toggleExpanded()
                    }
                }

            }
        }
    }
}










