import qs.modules.common
import qs.modules.common.functions as CF
import qs.modules.common.widgets
import qs.services
import Quickshell
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One task row.
//
// ── Why one row height for everything ──────────────────────────────
// Every row is `rowHeight` tall regardless of how long the task is. The text
// wraps inside that box and is capped at `collapsedLines`; anything past the
// cap is elided. Clicking the row expands it to the full text and the row grows
// to fit. So the list scans as a tidy column of equal rows, and the full text
// is always one click away -- no hover-only reveal, nothing permanently hidden.
//
// ── Completion is the circle, and only the circle ───────────────────
// Tapping anywhere on the row body EXPANDS it; it never toggles done. Marking
// a task finished is a deliberate act aimed at the circle on the left. This is
// the opposite of the previous row, where the text and the done-toggle were the
// same target, so a click to read a task would also complete it.
//
// ── Reordering ─────────────────────────────────────────────────────
// Drag by the grip on the left. The grip is its own hit area with a grab cursor
// so it can never be confused with tapping the text. While dragging, a line
// shows where the row will land; on release the list is reordered in one step.
Item {
    id: root
    required property var taskList
    property string emptyPlaceholderIcon
    property string emptyPlaceholderText

    // Forwarded wheel, for the widget's topmost swipe surface.
    //
    // That surface sits above this whole page and has to answer the wheel
    // itself (the pager is non-interactive so that a mouse drag cannot page
    // it -- see TodoWidget). For the VERTICAL branch it must hand the event
    // to the list underneath, which owns a tuned touchpad path: its own gain,
    // a fling model, a coast timer, and a `Behavior on contentY` that it
    // correctly suspends while a hand is on the pad. Writing contentY from
    // outside would go straight through that Behavior and the list would
    // drift instead of moving.
    //
    // Exposed on the page's ROOT because the page is an `Item`, not a list:
    // the surface only ever holds the page, so the list has to be reachable
    // from here.
    function handleWheel(w) {
        listView.handleWheel(w);
    }
    // ── Separation: detached outlined cards ──────────────────────────
    //
    // This replaced a centred hairline between every pair of rows. That
    // arrangement spent 11px of gap to achieve almost nothing: the row fill
    // was `colLayer1`, which sits only a few steps above the panel behind
    // it, so the gap read as the same colour as the row and a short 1px
    // rule floating in the middle of it had to do all the separating.
    //
    // Now the rows are cards. They rest TRANSPARENT with a hairline outline,
    // so the panel itself is the surface a card sits on and the outline is
    // the whole edge -- which separates far more strongly while costing less
    // vertical space than before.
    //
    // The gap drops from 11 to 9 for the same reason: with a visible edge on
    // each side, the gap no longer has to carry the separation on its own.
    property int todoListItemSpacing: 9

    // Card edge at rest and under the pointer.
    //
    // Derived from theme tokens rather than hardcoded greys, so they follow
    // the theme if it ever changes.
    //
    // The weights were raised from 0.08/0.12 because at those values the edge
    // resolved to #2a292a on a #141313 panel -- 22 luminance units apart,
    // which is invisible in practice. It has to clear roughly three times the
    // panel value before it reads as an edge at all; these land at #3f3d3f
    // and #5a575a.
    //
    // ARGUMENT ORDER MATTERS. `mix(a, b, p)` weights `a` by `p` and `b` by
    // `1 - p` -- so the TEXT colour goes first and the small percentage is the
    // amount of it. Passing them the other way round (which is the natural
    // reading, and the mistake already made once elsewhere in this config with
    // `transparentize`) yields a near-white hairline here.
    readonly property color cardOutline: CF.ColorUtils.mix(
        Appearance.colors.colOnLayer1, Appearance.colors.colLayer1, 0.20)

    // ONE highlight colour, shared by the grip and the card edge.
    //
    // These were two separate values and the card's hover edge came out
    // DARKER (#5a575a) than the grip at rest (#948f94) -- so hovering a row
    // made its own border recede while the dots beside it stayed bright. It
    // read as the card being pushed away from the pointer.
    //
    // `m3outline` is the value the grip and the completion circle are already
    // drawn in, so this makes the hover state one consistent light value
    // across the whole row and never darker than what it replaces.
    readonly property color rowHighlight: Appearance.m3colors.m3outline

    // There is deliberately NO drop-slot highlight.
    //
    // The row the gap is opening for used to take a faint fill of its own and a
    // brighter edge, so the destination was identifiable while the rows around
    // it moved. It read as a mistake, though: the rows that make space are
    // already sliding, and lighting one of them up made it look like THAT row
    // was the one being dragged -- the highlight followed the gap instead of
    // the hand, and the eye read a second carried row.
    //
    // The gap is legible without it. The carried row is unmistakable (active
    // border, own fill, drop shadow, grip icon lit) and it sits between the two
    // rows that parted, so the space it is heading for is simply the space it
    // is over.

    // Only while the row is genuinely in flight, one step above the hover
    // highlight so the picked-up row is unmistakable.
    readonly property color rowActive: Appearance.colors.colPrimary

    // True from the moment the grip is pressed until release. Exists purely so
    // the list can stop flicking for the duration of the gesture.
    property bool gripHeld: false

    // How far the dragged row has been pulled from where it sits in the list.
    //
    // This is what makes the row look like it is being CARRIED rather than
    // just selected: the card follows the pointer, lifted and shadowed, while
    // the slot it came from stays behind.
    property real dragOffsetY: 0

    // The HORIZONTAL half of the same offset, and the reason the carried row
    // used to sit beside the cursor instead of under it.
    //
    // The drag only ever translated on Y, so the row tracked a vertical drag
    // exactly and ignored every sideways millimetre -- which is not a small
    // error, it is one that GROWS with how far you move the mouse, which is
    // exactly how it reads. The row is now carried in both axes from the same
    // press point, so the spot you grabbed is the spot that follows the
    // cursor.
    //
    // Reordering is still decided on Y alone (`updateDropTargetAt` is fed the
    // vertical position), because that is the axis the list is ordered along.
    // Following the pointer sideways moves the card out of its column for the
    // duration of the drag and puts it straight back on release.
    property real dragOffsetX: 0

    // One height for every row -- this is the whole point of the redesign.
    property int rowHeight: 44
    // Lines shown before the text is elided. ONE, deliberately: a collapsed task
    // is a single line with an ellipsis when it does not fit. It was 2, which is
    // what broke clicking -- almost every task wrapped to two lines, so
    // `isTruncated` was false, so the rows accepted no clicks at all.
    property int collapsedLines: 1
    // HARD character cap on the collapsed text.
    //
    // This no longer decides what the user sees -- Qt's `elide` does that,
    // against the capped width, which is exact at any sidebar width. This is
    // the cheap belt-and-braces bound: it keeps `isTruncated` honest on very
    // wide sidebars where the width test alone would say a 200-character task
    // "fits", so a short-but-wide sidebar and a wide one agree about which
    // rows are worth expanding.
    property int maxCollapsedChars: 52

    // Horizontal gutters.
    //
    // Right has no such constraint -- the action buttons own that space -- so it
    // is just the theme's gap token. The two sides ending up different is the
    // point: the circle reads as inset from the sidebar border while the buttons
    // read as tight to the row edge.
    // SYMMETRIC, and back to something modest.
    //
    // They were derived from `hyprlandGapsOut` with big multipliers (x5 left,
    // x6 right), which did two wrong things at once: it made the inset far
    // too large for a list this narrow, and because the multipliers differed
    // the left and right margins were never equal -- the left measured ~59px
    // against ~40px on the right, which reads as the card being shoved off
    // centre.
    //
    // One constant for both, so they cannot drift apart again.
    readonly property int gutterSide: Math.round(Appearance.sizes.hyprlandGapsOut * 3)
    readonly property int gutterLeft: gutterSide
    readonly property int gutterRight: gutterSide

    // Inner padding INSIDE the card, between its border and its contents.
    // Separate from the gutters on purpose: the gutters keep the card off the
    // widget edge, this keeps the grip, circle and buttons off the card's own
    // border. Conflating the two is what made the old margin arrangement look
    // like it was doing nothing.
    readonly property int cardPad: 8

    // Width of the completion circle's slot in the row's RowLayout.
    // Width of the drag grip.
    //
    // The grip used to be a SIBLING of the card, anchored to the delegate's own
    // left edge, while the RowLayout inside the card started independently a
    // few pixels in. The two overlapped, so the grip sat partly on top of the
    // completion circle and had to be given a manual margin to compensate.
    // It is now the RowLayout's first child, so spacing between it and the
    // circle is the layout's job and cannot collide.
    readonly property int gripWidth: 22
    // Width of the completion circle (the 30px hit area, not the 24px ring).
    readonly property int circleWidth: 30
    // RowLayout spacing between the grip, the circle, the text and the buttons.
    readonly property int rowSpacing: 4

    // Grip and circle together. `textColumnWidth` has to subtract both, and
    // they are always adjacent in the layout, so one number cannot drift out
    // of step with the other.
    readonly property int gutterWidth: gripWidth + circleWidth

    // Width reserved for the trailing copy/delete buttons, so the text column
    // is measured against the space that is actually free rather than the full
    // row width.
    //
    // This MUST equal the real width of the button RowLayout, because it is
    // SUBTRACTED from the row. The three slots are 30px each in a RowLayout
    // with `spacing: 0`, so the block is exactly 90.
    //
    // 90, not 60: the row now carries a THIRD slot, edit/save, between
    // copy/cancel and delete. Leaving this at 60 handed `textColumnWidth` 30px
    // MORE than the text actually had, so every task elided early and its last
    // characters ran underneath the delete button. This number and the action
    // RowLayout's real width have to be changed together, always.
    //
    // It used to be 72, described as "two 30px buttons plus a 12px gap on the
    // outside of them" -- but that gap was never actually applied to the
    // layout, so 12px of the 72 was simply dead space between the end of the
    // text and the first button. Combined with the RowLayout's own 4px
    // spacing and the 6px of inset inside the 30px cell before the 18px icon,
    // that put the copy icon a whole 22px from the end of the text -- which
    // is what made the row look like it had a hole in it. The gap between the
    // text and the buttons is `textButtonGap` below, and nothing else.
    readonly property int actionsWidth: 90

    // The gap between the end of the text and the start of the buttons.
    //
    // NOTE: this is the RowLayout's `spacing` budget between the text column and
    // the button block, NOT an extra margin. It was previously applied as a
    // `rightMargin` on the text column, which double-counted the 60px the
    // layout had already reserved for `actionsBlock` and pushed the ellipsis
    // 60px too far left. See `textColumn`.
    readonly property int textButtonGap: 4
    // Vertical padding inside the text block, top and bottom.
    property int textPadding: 10

    // Which row is being dragged, and where it would land. -1 means "not
    // dragging". Held on the list rather than the delegate so the drop line
    // can be drawn by the list itself.
    property int draggingIndex: -1
    property int dropTargetIndex: -1
    // Set by the delegate on release so the list knows the move to commit.
    signal moveRequested(int fromId, int beforeId)

    StyledListView {
        id: listView
        anchors.fill: parent
        spacing: root.todoListItemSpacing
        // No flicking while a grip drag is in progress. Without this the list
        // scrolls under the row being dragged, which both fights the reorder
        // and leaves the drop line pointing at the wrong task.
        interactive: !root.gripHeld
        animateAppearance: false
        // The edge auto-scroll below writes `contentY` on a timer, so the
        // scroll must land 1:1 rather than being eased by the list's
        // `Behavior on contentY`. Easing an already-stepped scroll is what makes
        // an auto-scroll feel like it is lagging behind the cursor.
        wheelAnimEnabled: !root.gripHeld
        // Rows can now be taller than one line when expanded, and a drag can
        // carry a row over its neighbours, so the view must not assume a fixed
        // geometry while either is true.
        clip: true

        // ── Edge auto-scroll ────────────────────────────────────────────
        // Reordering a list longer than the sidebar has to be possible without
        // dragging to the end and waiting there.
        //
        // This is a Flickable, so its own `interactive` is off for the whole
        // gesture (`interactive: !root.gripHeld`) -- otherwise the list would
        // scroll under the row being carried, which fights the reorder and
        // leaves the gap pointing at the wrong task. That leaves the scroll to
        // be driven from here, on a timer, while the pointer is held near an
        // edge.
        //
        // `contentY` is written directly rather than animated: `contentY` has
        // its own `Behavior`, and animating an already-animating scroll is what
        // produces lag. Writing it every tick with a small step reads as
        // smooth because the steps are small and constant.
        //
        // Speed ramps with how DEEP into the edge zone the pointer is, so
        // grazing the edge creeps and pushing into it moves fast. A linear
        // speed makes the transition from "not scrolling" to "scrolling hard"
        // abrupt, which reads as the list lurching.
        readonly property real edgeZone: 70
        readonly property real edgeMaxStep: 18

        function edgeScrollStep(y) {
            const zone = root.edgeZone;
            if (y < zone) {
                // How far into the top zone, 0 at the boundary, 1 at the edge.
                const depth = Math.min(1, (zone - y) / zone);
                return -root.edgeMaxStep * depth;
            }
            const fromBottom = listView.height - y;
            if (fromBottom < zone) {
                const depth = Math.min(1, (zone - fromBottom) / zone);
                return root.edgeMaxStep * depth;
            }
            return 0;
        }

        // Runs only while a row is actually in flight, so it costs nothing
        // outside a drag. 16ms is a frame, and each tick is a small scroll step
        // plus one drop-target refresh, so the gap keeps up with the scroll
        // instead of trailing it.
        Timer {
            id: edgeScroll
            interval: 16
            repeat: true
            running: root.draggingIndex >= 0 && listView.contentHeight > listView.height
            onTriggered: {
                if (root.draggingIndex < 0)
                    return;
                const y = root.pointerInListY;
                const step = root.edgeScrollStep(y);
                if (step === 0)
                    return;
                const maxY = Math.max(0, listView.contentHeight - listView.height);
                const next = Math.max(0, Math.min(maxY, listView.contentY + step));
                if (next === listView.contentY)
                    return;
                listView.contentY = next;
                // The scroll moved the rows under a stationary pointer, so the
                // drop target has to be recomputed from the new content
                // position. Without this the gap would stay on the slot the
                // pointer was over before the scroll started, and the row being
                // carried would travel through a gap that was never there.
                const inList = y >= 0 && y <= listView.height;
                root.updateDropTargetAt(root.pointerInListY + listView.contentY, inList);
            }
        }

        model: ScriptModel {
            id: scriptModel
            values: root.taskList
        }


        delegate: Item {
            id: todoItem
            required property var modelData
            required property int index
            property var item: modelData
            property bool done: item.done
            // Index in the WHOLE list, so every mutation addresses the real
            // entry even when this view is showing a filtered subset.
            // The task's stable id from Todo.qml. Used instead of a positional index
            // because the view is FILTERED, so a row's position here is not its
            // position in the file -- and because ids survive a reorder, which
            // a positional index does not.
            readonly property int taskId: item.id

            // How far this row has slid to open a gap for the carried row.
            //
            // A property of its own so the easing can sit on it. Putting the
            // easing on the Translate instead would also ease the DRAGGED row,
            // which must track the pointer 1:1 -- that lag is what makes a drag
            // feel sticky.
            property real shiftY: root.shiftFor(index)

            // Note: there is no "this row is the drop slot" flag any more. The
            // row the gap is opening for is identified by where it IS -- the
            // rows either side of the carried one have parted -- and marking it
            // with a fill of its own made the row that was making space look
            // like a second carried row. `dropTargetIndex` still exists and
            // still decides the reorder on release; it just paints nothing.

            Behavior on shiftY {
                // Live during the drag. It was suspended, on the theory that a
                // re-targeting NumberAnimation on every delegate would eat the
                // frame the carried row needed. That theory was wrong: the
                // row's lag was a coordinate-space fault (see gripMouse), and
                // it is fixed there. Displacement animating costs a handful of
                // cheap transform updates and nothing else -- the cards are not
                // re-rasterised, only moved.
                //
                // `alwaysRunToEnd: false` is deliberate, and it is the fix for
                // the gap looking uncoordinated.
                //
                // `shiftY` is re-targeted every time the pointer crosses into a
                // new slot, which on a drag down a list is every few hundred
                // milliseconds. With `alwaysRunToEnd: true`, a retarget does not
                // redirect the running ease -- it lets the ease FINISH its
                // journey to the old slot first, and only then starts the next
                // one. So every slot change queues another 130ms of travel on
                // top of the last, and each row arrives at a different moment:
                // the rows that shifted first are already parked while the ones
                // that shifted last are still catching up. That desynchrony is
                // what made the list look like it was thrashing rather than
                // opening a space, and it compounded the further the drag went.
                //
                // Retargeting from the CURRENT value instead means a row eases
                // toward wherever it is being sent and changes its mind
                // mid-flight, so the whole gap stays in step with the cursor.
                // This is the same reasoning, and the same `false`, that the
                // list's own `Behavior on contentY` uses for the identical
                // problem of a value being retargeted while an ease is running.
                NumberAnimation {
                    duration: 130
                    easing.type: Easing.OutCubic
                    alwaysRunToEnd: false
                }
            }

            // Expanded state is per-row and deliberately NOT bound to the
            // delegate's lifetime: ListView recycles delegates as the list
            // scrolls, so storing it here would make one row's expansion pop up
            // on a different row after a scroll. Keyed by the task's index in
            // the full list instead.
            property bool expanded: root.isExpanded(taskId)

            // Is THIS row the one being edited? Derived from the list-level id
            // (see `editingId`) rather than stored here, for the recycling
            // reason in the note above.
            readonly property bool editing: root.editingId === todoItem.taskId

            // True when the pointer is anywhere over this row.
            //
            // Set imperatively from `todoItemMouse.entered/left` rather than
            // bound to `containsMouse`. The fill, the accent bar and the
            // copy/delete button backdrops all read this one flag, so they can
            // never disagree about whether the row is hovered -- and the buttons
            // keep their feedback even when the pointer is over a button, where
            // the row's own MouseArea is not the target.
            property bool rowHovered: false

            // Is this task's text long enough to be cut off?
            //
            // Decided by MEASURING the text at the width this row actually has,
            // not by counting characters. A length threshold would be wrong in
            // both directions: a 40-character task in a narrow window wraps to
            // three lines and is truncated, while a 90-character task full of
            // short words can fit in two lines.
            // Does this task HAVE more text than one line?
            //
            // Deliberately independent of `expanded`. It used to return false
            // while expanded, on the reasoning that an expanded row has nothing
            // left to truncate -- but that also made the row stop accepting
            // clicks, so once a task was expanded it could never be collapsed
            // again. This is a property of the TEXT, not of the current view.
            property bool isTruncated: {
                if (textColumnWidth <= 0)
                    return false;
                return measure.contentWidth > textColumnWidth
                    || todoItem.item.content.length > root.maxCollapsedChars;
            }

            // Width actually available to the task text, derived ARITHMETICALLY from
            // the row width rather than read back from the laid-out Text.
            //
            // It used to be fed by a `Connections { onWidthChanged }` handler on
            // textBlock, starting at 0. That is a fragile path: until (or unless)
            // that callback fired, nothing knew how much room was left, and the
            // full text drew under the buttons instead of being capped.
            // Subtracting the known insets from the list width is deterministic on
            // the first evaluation, with no dependency on a layout callback having
            // happened.
            readonly property real textColumnWidth: {
                const listW = ListView.view ? ListView.view.width : 0;
                return Math.max(0, listW
                    - root.gutterLeft      // card inset, left
                    - root.gutterRight     // card inset, right
                    - root.cardPad * 2     // inner pad, both sides
                    - root.gutterWidth     // grip
                    - root.circleWidth     // the completion toggle
                    - root.actionsWidth    // copy/edit + edit/save + delete
                    - root.rowSpacing * 3); // RowLayout gaps between the four children
            }

            implicitHeight: row.implicitHeight
            width: ListView.view.width
            z: root.draggingIndex === index ? 20 : 0

            // THE ROW FOLLOWS THE POINTER.
            //
            // `transform` rather than `y`, and that is the whole trick. The
            // ListView owns the delegate's `y` -- assigning to it fights the
            // layout and breaks `indexAt` -- whereas a `Translate` is purely
            // visual: the slot stays where it is, so the list does not reflow
            // under the pointer, while the card is carried to wherever the
            // pointer is.
            // The two states are deliberately NOT animated the same way:
            //   dragged   -> tracks the pointer 1:1, no easing, or the row lags
            //                behind your hand and the whole thing feels sticky
            //   displaced -> eases, because that motion is not tracking a finger
            //                and a hard jump reads as a glitch
            transform: Translate {
                x: root.draggingIndex === index ? root.dragOffsetX : 0
                y: root.draggingIndex === index ? root.dragOffsetY : shiftY
            }

            // Hidden measurer. Never rendered; it exists only to report the width of
            // the task text on one line, so `isTruncated` can decide whether
            // this row has anything more to show. Nothing is written to it --
            // it is bound to the task text and only ever read.
            //
            // A Text, NOT TextMetrics. TextMetrics cannot be used for this:
            // `TextMetrics.width` is READ-ONLY in Qt 6, and its `elidedText`
            // is derived from that width -- so there is no way to ask it "does
            // this fit in N pixels". Assigning `width` to it is a load-time
            // error that takes down the entire shell, not just this list.
            // (A Text also has no such restriction, and `contentWidth` reports
            // the unwrapped advance of the string.)
            Text {
                id: measure
                visible: false
                // Must match textBlock exactly, or the measurement describes a
                // different layout than the one on screen.
                font: textBlock.font
                text: todoItem.item.content
                // NoWrap, so `contentWidth` is the width of the text on ONE line
                // -- which is exactly the question being asked. With WordWrap on,
                // contentWidth collapses to the longest word and the fit test
                // would pass for text that in fact needs three lines.
                wrapMode: Text.NoWrap
            }

            // ── Drag source ─────────────────────────────────────────────
            // Only the grip starts a drag (see gripMouse below). The row as a
            // whole is not a drag handle, which is deliberate: a draggable row
            // would swallow the click-to-expand tap, which is the interaction
            // this redesign is built around.

            Rectangle {
                id: row
                anchors.fill: parent
                // THE GUTTERS LIVE HERE, ON THE CARD.
                //
                // They used to be applied as margins on the RowLayout INSIDE
                // the card, which inset the text but left the card itself
                // `anchors.fill: parent` -- so its border was drawn hard against
                // the widget edge no matter how wide the gutters were. Raising
                // the numbers did nothing visible for the thing you were
                // looking at. The card is what needs the space, so the card is
                // what gets it, and the layout inside goes back to flush.
                anchors.leftMargin: root.gutterLeft
                anchors.rightMargin: root.gutterRight

                // One height for every row, unless this row is expanded -- then
                // it grows to whatever the full text needs.
                //
                // The sum is exact because the text carries no padding of its
                // own (see `textBlock`): its `implicitHeight` is the wrapped
                // text and nothing else, so the row is the text plus one
                // `textPadding` above and one below. When the padding lived on
                // the Text as well this same sum counted it twice and left a
                // dead band under the last line.
                implicitHeight: todoItem.editing
                    // While editing, the field decides the height: a correction
                    // can be longer than the task it replaces, and a fixed
                    // row would scroll a caret that has nowhere to go. The
                    // field is anchored top-aligned like `textBlock` below, so
                    // the same padding arithmetic applies to both.
                    ? Math.max(root.rowHeight, editField.implicitHeight + root.textPadding * 2)
                    : (todoItem.expanded
                        ? Math.max(root.rowHeight, textBlock.implicitHeight + root.textPadding * 2)
                        : root.rowHeight)
                // Corner radius: `verysmall` (4px).
                //
                // Was `rounding.full` -- 9999, which on a 44px row is a ~22px
                // lozenge and by far the softest edge in the sidebar. 4px keeps
                // the row in key with the compositor's own rounding without
                // going fully square.
                radius: Appearance.rounding.verysmall

                // ── Card edge, hover and lift ──────────────────────────────
                // The card rests transparent and is defined entirely by its
                // outline. A permanently filled card would put a solid rectangle
                // of colLayer1 back on screen, which is what the old design was
                // already doing badly -- an outline only reads as an edge if
                // there is a different surface on each side of it, and here that
                // surface is the panel.
                border.width: 1

                // Hover fills the card and brightens its edge by one step, in
                // one frame: NO Behaviour on color, because an eased hover fill
                // makes the pointer feel like it is chasing the highlight.
                //
                // LIFTED: the row being carried takes the active colour and
                // fills in.
                // Only the carried row and the hovered row are ever filled.
                // The rows that slide aside to open the gap stay exactly as
                // they are, so nothing in the list but the row under the
                // pointer changes appearance.
                color: root.draggingIndex === todoItem.index
                    ? Appearance.colors.colLayer2
                    : ((todoItem.rowHovered || gripMouse.pressed)
                        ? Appearance.colors.colLayer2
                        : "transparent")
                border.color: root.draggingIndex === todoItem.index
                    ? root.rowActive
                    : ((todoItem.rowHovered || gripMouse.pressed)
                        ? root.rowHighlight
                        : root.cardOutline)
                // NO scale on the carried row.
                //
                // `scale` is the one thing here that could not track the
                // pointer: it scales about the card's CENTRE, so the edges sit
                // 0.02 * height / 2 above and below the slot the Translate put
                // the card in -- a constant ~0.45px off vertically, and ~4.5px
                // outside on each side horizontally, on a 450px card. A 2% lift
                // is barely visible anyway; a card that is not quite under the
                // cursor is very visible.
                //
                // The lift is carried by the fill, the `rowActive` border and
                // the drop shadow below, none of which move any geometry.
                z: root.draggingIndex === todoItem.index ? 2 : 0

                Behavior on implicitHeight {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutCubic
                    }
                }

                // Drop shadow under the carried row, so it reads as being held ABOVE the
                // list rather than painted into it.
                //
                // This config already ships `StyledDropShadow`, which wraps the
                // Qt5Compat type with the properties that actually exist on it
                // and fills in `source` and `samples`. Hand-rolling it instead
                // is a trap: the import exposes the types THEMSELVES rather
                // than a namespace (`GraphicalEffects.DropShadow` does not
                // resolve), and there is no `blurRadius` property at all --
                // it is `radius`. Both mistakes are load-fatal and take the
                // whole shell down, not just this list.
                StyledDropShadow {
                    target: row
                    visible: root.draggingIndex === todoItem.index
                    z: -1
                }

                MouseArea {
                    id: todoItemMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    // Hover only. It no longer expands the row.
                    //
                    // Expanding used to be this area's click, and it filled the
                    // whole card -- so the six controls on the left (grip,
                    // circle) and on the right (copy, delete) sat INSIDE it, and
                    // a press aimed at one of them still expanded the row when
                    // the press missed by a pixel. The controls are the ones
                    // that should own their area, so expansion moved down into
                    // the text column itself, where it reads as "click the text
                    // to read it" and cannot collide with a control.
                    acceptedButtons: Qt.NoButton
                    // Feeds the shared `rowHovered` flag.
                    onEntered: todoItem.rowHovered = true
                    onExited: todoItem.rowHovered = false
                }

                RowLayout {

                // Drag handle, and the RowLayout's FIRST child.
                //
                // It used to be a sibling of the card, anchored to the delegate's
                // own left edge while the card's RowLayout started a few pixels
                // further in. The two overlapped, so the grip sat partly on top
                // of the completion circle and needed a manual margin to
                // compensate. As a child, the spacing between them is the
                // layout's problem and cannot collide.
                //
                // That also settles the drag for good. `todoItemMouse` lives
                // inside `row` with `anchors.fill: parent`; when the grip was a
                // sibling, that MouseArea sat ABOVE it and, on every row whose
                // text is truncated, accepted `Qt.LeftButton` and took the
                // pointer grab -- so `gripMouse` never saw the press at all,
                // which is why pressing and dragging the dots did nothing.
                Item {
                    id: grip
                    Layout.preferredWidth: root.gripWidth
                    Layout.fillHeight: true

                    // THE HOVER TREATMENT.
                    //
                    // The grip had exactly one cue: the icon's colour stepping
                    // from `colPrimary` to `m3onSurface`. On a #141313 panel
                    // those two are close enough in luminance that the change
                    // is invisible until you are already looking for it, so
                    // "hover the dots" did not appear to do anything.
                    //
                    // Three cues now, in increasing order of how hard they are
                    // to miss:
                    //   1. a translucent wash behind the dots that grows into
                    //      a vertical pill on hover -- a drag strip, which is
                    //      how a draggable handle is actually read
                    //   2. the colour step, kept as the finishing touch
                    //
                    // The dots themselves never change SIZE. Growing them was
                    // tried and dropped: on a row this narrow a 1.2x drag
                    // indicator crowded the completion circle next to it, and
                    // the motion drew more attention to the grip than the
                    // highlight did. The wash and the colour step carry it.
                    //
                    // The wash is a low-opacity `colPrimary` rather than a
                    // lighter solid colour, which is the only reliable "lift"
                    // on this surface -- a solid lift has to be solved against
                    // the panel underneath and goes wrong the moment the theme
                    // changes.
                    Rectangle {
                        id: gripWash
                        anchors.centerIn: parent

                        // THE PILL. At rest it is a small dot behind the dots;
                        // on hover it grows into a tall rounded pill that
                        // swallows them.
                        //
                        // Growing the BACKGROUND rather than the dots is the
                        // whole trick. A drag handle is read as a vertical
                        // grab strip, not as a bigger icon, and the six dots
                        // themselves have to stay 18px -- at 1.2x they crowded
                        // the completion circle beside them. So the shape
                        // changes and the glyph does not, which reads as "this
                        // whole strip is live" rather than "the icon is
                        // animating".
                        readonly property bool lit: gripMouse.containsMouse
                                                        || gripMouse.dragging

                        // ── Why this is a TRANSFORM and not a resize ────────
                        //
                        // The obvious way to grow the pill on hover is to
                        // animate `width` and `height`. That is what this did,
                        // and it is why hovering felt heavy: a geometry change
                        // re-lays-out the rectangle on every frame of the
                        // animation, and the whole grip block re-measures with
                        // it, several times per hover.
                        //
                        // The wash is invisible at rest anyway (opacity 0), so
                        // its size at rest is never seen. That makes the resize
                        // redundant: the size can simply BE the lit size, and
                        // only a scale transform varies. A transform is
                        // composited, not re-laid-out, so the grow-in costs one
                        // matrix rather than a layout pass per frame.
                        //
                        // The dots are untouched by either approach -- this is
                        // the background growing, not the glyph.
                        width: 26
                        height: 28
                        // Follows the height, so the strip is a true pill rather
                        // than a rounded rectangle that only looks right at one
                        // particular size.
                        radius: height / 2
                        color: Appearance.colors.colPrimary
                        opacity: lit ? 0.18 : 0.0
                        scale: lit ? 1.0 : 0.72

                        // 70ms, matching NotificationItem's `hoverDuration`
                        // rather than the 200ms `expressiveEffectsDuration`.
                        // Hover feedback has to land inside the frame the user
                        // is still reacting to; a 200ms fade on a pointer the
                        // user has just moved reads as the shell being slow
                        // rather than as the highlight arriving.
                        readonly property int hoverMs:
                            Math.round(70 * Appearance.animationCurves.motionScale)

                        Behavior on scale {
                            NumberAnimation {
                                duration: hoverMs
                                easing.type: Easing.OutCubic
                            }
                        }
                        Behavior on opacity {
                            NumberAnimation {
                                duration: hoverMs
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    MaterialSymbol {
                        id: gripIcon
                        anchors.centerIn: parent
                        text: "drag_indicator"
                        // 18, not 16. The symbol is six dots about 3px across;
                        // at 16 they render as a faint smudge on a #141313 panel
                        // whatever colour you give them.
                        iconSize: 18


                        // `colPrimary` at rest, stepping to `m3onSurface` on
                        // hover and while the row is in flight.
                        color: root.draggingIndex === todoItem.index
                            ? Appearance.m3colors.m3onSurface
                            : (gripMouse.containsMouse
                                ? Appearance.m3colors.m3onSurface
                                : Appearance.colors.colPrimary)
                    }

                    MouseArea {
                        id: gripMouse
                        anchors.fill: parent
                        hoverEnabled: true

                        // THE GRIP SAYS SO WITH ITS CURSOR.
                        //
                        // A third cue, on top of the wash and colour treatment
                        // above -- which is what carries the
                        // affordance on its own. This one is here because a
                        // pointer that turns into a hand is the most direct
                        // statement of "this row can be dragged", and the
                        // shell sets that shape on plenty of other controls,
                        // so it should not be missing here.
                        //
                        // Note it is not load-bearing. Whether a cursorShape
                        // reaches the screen depends on the client and the
                        // compositor both having a cursor theme to draw from
                        // (see hyprland/env.lua, XCURSOR_THEME), which is a
                        // system-level thing this file cannot assume. The
                        // visual cues above are why the grip still reads as
                        // draggable if that ever stops being true.
                        //
                        // Open hand at rest, closed hand once the row is
                        // actually in flight -- the same pairing already used
                        // by AbstractWidget.qml for the desktop's edit-mode
                        // widgets, so the two agree.
                        //
                        // `dragging` and not `dragHeld`: `dragHeld` is true from
                        // the press itself, and the 6px of slop this area
                        // deliberately requires means a plain click on the grip
                        // is a click, not a drag. Closing the hand for a click
                        // that does nothing would be a lie. `dragging` becomes
                        // true only once the threshold is crossed (and is
                        // cleared on release and on cancel).
                        cursorShape: dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                        // A real drag threshold rather than "press = drag": a
                        // plain tap on the grip should not start dragging.
                        property bool dragging: false

                        // The pointer's position at press, in SCENE (window)
                        // coordinates, which do not move with the row.
                        //
                        // This area lives inside the delegate that the drag
                        // translates, so any coordinate measured in its own
                        // space feeds back into itself and the drag oscillates.
                        //
                        // `mouse.x` / `mouse.y` ARE such a local coordinate. Qt
                        // maps each event into the RECEIVING ITEM's space before
                        // handing it over, so they already carry the delegate's
                        // Translate. Subtracting them directly is wrong in a way
                        // that looks almost right: each frame the row moves by
                        // `dragOffset`, so the local pointer appears to move back
                        // by the same amount, and
                        //     offset = pointerDelta - offset
                        // halves the remaining error every frame instead of
                        // converging. The row visibly stutters, and the pointer
                        // has to travel about twice as far to reach the cursor.
                        // That is the jitter.
                        //
                        // `mapToItem(null, ...)` maps through the full chain to
                        // the scene, which is a space nothing in this list
                        // moves. The press point is taken there and every later
                        // delta is measured against it, so `dragOffset` is the
                        // pointer's own travel and the row lands exactly under
                        // the cursor on every frame.
                        property real pressSceneX: 0
                        property real pressSceneY: 0

                        // The grip's OWN origin in scene coordinates, sampled
                        // at press. The grip never moves inside the row, so
                        // this one number is enough to turn any grip-local
                        // coordinate into a scene one for the whole gesture.
                        property real gripSceneX: 0
                        property real gripSceneY: 0

                        // The last pointer position that was actually SAMPLED,
                        // in scene coordinates. Every position update is
                        // measured against this, so replaying the same
                        // position -- which the poll timer does sixteen times a
                        // second -- is a guaranteed no-op rather than a second
                        // source of motion.
                        property real sampleSceneX: 0
                        property real sampleSceneY: 0

                        // Set the first time motion events arrive. The poll
                        // timer exists only for the case where they do not,
                        // and once they have started there is nothing for it to
                        // add -- two writers for one pointer is two chances to
                        // disagree within a frame.
                        property bool motionSeen: false

                        // Grip-local -> scene, by arithmetic.
                        //
                        // `lx`/`ly` are GRIP-LOCAL, and Qt folds the delegate's
                        // `Translate` into them before the handler ever sees
                        // them: a local coordinate is the scene coordinate
                        // MINUS however far the row has already been carried.
                        //
                        // `mapToItem` adds that displacement back, which is
                        // correct for a value measured in the same frame and
                        // wrong for one that is not -- and the poll timer reads
                        // `mouseX`/`mouseY`, which Qt last wrote for an EARLIER
                        // pointer position under an EARLIER transform. Feeding
                        // that stale value back through the chain hands the drag
                        // movement the pointer never made, and because the row
                        // is then displaced by that phantom amount, the next
                        // poll adds it AGAIN. The row accelerates away from a
                        // cursor that is standing still, and reversing the drag
                        // reverses the sign, which is why it reads as the task
                        // sliding up and down on its own.
                        //
                        // The displacement is not a hidden quantity: this grip
                        // only ever carries `root.dragOffset`, written in this
                        // same handler and nowhere else, and the grip's position
                        // within the row is fixed by the layout. So the
                        // conversion is exact arithmetic on the CURRENT
                        // displacement, and it cannot drift no matter how old
                        // the sample is.
                        function sceneAt(lx, ly) {
                            return {
                                x: gripSceneX + lx + root.dragOffsetX,
                                y: gripSceneY + ly + root.dragOffsetY
                            };
                        }

                        // Which MouseArea owns the gesture in flight, and which
                        // row it belongs to.
                        //
                        // Held here rather than on the grip because the text
                        // column can start a drag too (see `textDragMouse`),
                        // and every coordinate in this handler has to be read
                        // from the area that actually holds the grab. One state,
                        // one owner: a drag begun on the text is not a second
                        // implementation of the drag, it is this one with a
                        // different owner.
                        property var dragOwner: null

                        // True from the moment a gesture is armed until its
                        // release is handled. Distinct from `dragging`, which is
                        // only true once the 6px of slop has been crossed:
                        // `dragging` means the row is in flight, this means a
                        // press is down and this area is answerable for it.
                        property bool dragHeld: false

                        // Starts a drag, whoever is asking.
                        //
                        // `source` is the MouseArea holding the press. `originX/Y`
                        // is that area's own (0, 0) in scene coordinates,
                        // captured HERE while the row is still untranslated --
                        // see `sceneAt` for why the origin plus the current
                        // offset is the whole conversion, and why it has to be
                        // taken before the row starts moving.
                        function beginDrag(source, originX, originY, lx, ly) {
                            dragging = false;
                            dragHeld = true;
                            motionSeen = false;
                            dragOwner = source;
                            root.dragOffsetX = 0;
                            root.dragOffsetY = 0;
                            gripSceneX = originX;
                            gripSceneY = originY;
                            const p0 = sceneAt(lx, ly);
                            pressSceneX = p0.x;
                            pressSceneY = p0.y;
                            sampleSceneX = p0.x;
                            sampleSceneY = p0.y;
                            // Stops the list flicking for the whole gesture. Set
                            // on PRESS, not once the drag threshold is crossed:
                            // a Flickable starts moving as soon as the pointer
                            // travels far enough, which is sooner than 6px of
                            // slop, so waiting for the drag to begin meant the
                            // list scrolled out from under the row first.
                            root.gripHeld = true;
                            // Armed on PRESS, not when the 6px slop is crossed.
                            // The sidebar closes on pointer-out after a 200ms
                            // grace, and a press that holds still long enough to
                            // drift past the panel edge never reaches the drag
                            // threshold at all -- so arming it later left the
                            // panel free to close under a gesture that had not
                            // officially started yet. `onReleased` clears it on
                            // every path out.
                            Todo.dragInFlight = true;
                        }

                        onPressed: (mouse) => {
                            const o = mapToItem(null, 0, 0);
                            beginDrag(gripMouse, o.x, o.y, mouse.x, mouse.y);
                            mouse.accepted = true;
                        }
                        // One place where a drag frame is computed, so the motion
                        // handler and the hold timer below cannot disagree.
                        //
                        // It is a FUNCTION, and it re-derives everything from the
                        // press point, so calling it twice with the same pointer
                        // position is a no-op rather than an accumulation.
                        function trackDrag(lx, ly) {
                            // Whoever owns the gesture may drive it; the
                            // CALLERS are what keep the other area out.
                            //
                            // Both the grip and the text column keep receiving
                            // events of their own -- the text takes every click
                            // on the row -- and two areas writing the same
                            // offsets in one frame would move the carried row
                            // twice, which is the drift bug all over again. So
                            // each handler and each poll checks `dragOwner`
                            // against ITSELF before getting here, and this
                            // function stays owner-agnostic: it has to, or a drag
                            // begun on the text could never move at all.
                            //
                            // The guard is the SHARED `dragHeld`, not any one
                            // area's `pressed`: a release from the text column
                            // arrives here too, and by then the grip's own button
                            // is not down at all.
                            if (!dragHeld || !dragOwner)
                                return;

                            // This delegate has been recycled -- the list
                            // scrolled it out of view, or the model changed
                            // under it -- so its `index` is no longer the row
                            // being carried. Carrying on would drag a different
                            // task. The release path still commits using the id
                            // captured at press, so stopping here loses the
                            // gesture, not the data.
                            if (dragging && root.draggingIndex !== todoItem.index)
                                return;

                            // A Qt pointer grab is exclusive: every motion event
                            // after the press arrives here and nowhere else.
                            //
                            // Measured in the SCENE, not in this area's own
                            // space -- see the note on sceneAt. In a
                            // frame-independent space this delta is just how far
                            // the pointer has travelled since the press.
                            const p = sceneAt(lx, ly);

                            // No new pointer position, nothing to do. This is
                            // what makes the poll timer inert: it re-samples the
                            // same standing-still pointer, gets the identical
                            // point back, and returns before writing a single
                            // property. The carried row can only ever move
                            // because the pointer moved.
                            if (p.x === sampleSceneX && p.y === sampleSceneY)
                                return;
                            sampleSceneX = p.x;
                            sampleSceneY = p.y;

                            const dx = p.x - pressSceneX;
                            const dy = p.y - pressSceneY;

                            if (!dragging) {
                                // 6px of slop, so a shaky tap is still a tap.
                                if (Math.sqrt(dx * dx + dy * dy) < 6)
                                    return;
                                dragging = true;
                                root.draggingIndex = todoItem.index;
                                root.dropTargetIndex = todoItem.index;
                                root.grabbedId = todoItem.taskId;
                            }

                            // The drop slot comes from the POINTER, converted
                            // into the list view's own coordinate space in ONE
                            // step: `listView.mapFromItem(gripMouse, ...)` takes
                            // a point expressed in the grip's space -- which is
                            // what the local coordinates already are, Qt having
                            // mapped the event into this area before delivering
                            // it -- and returns the same physical point in the
                            // list's space.
                            //
                            // The previous call converted in two steps and read
                            // the FIRST one in the wrong space:
                            // `mapToItem(listView, p.x, p.y)` is `listView`'s
                            // method, so it treats `(p.x, p.y)` as a grip-local
                            // point -- but `p` came out of
                            // `mapToItem(null, ...)`, i.e. it is already SCENE.
                            // A scene point fed in as a grip-local one lands
                            // offset by the grip's own position inside the
                            // list: the dragged row's index times the row
                            // pitch. That is why the gap opened several rows
                            // below the cursor, and why the lower down the list
                            // you grabbed, the further below it opened.
                            //
                            // Mapping directly from the grip avoids the scene
                            // detour entirely, and a single call has no second
                            // space to confuse. The result is viewport
                            // coordinates; adding `contentY` turns it into a
                            // position in the list's content, which is what
                            // `indexAt` wants.
                            // Read from the OWNING area, not from the grip:
                            // `lx`/`ly` are expressed in whichever space the
                            // press came from, and only that area can map them
                            // back to the list.
                            const inView = listView.mapFromItem(dragOwner, lx, ly);
                            // Published for the edge auto-scroll, which runs on a
                            // timer with no mouse event of its own to read.
                            // Viewport coordinates -- the space the scroll
                            // decision is made in.
                            root.pointerInListY = inView.y;
                            // Only move the slot while the pointer is over the
                            // list. `indexAtPosition` clamps, so a pointer past
                            // either end would name the first or last row.
                            root.updateDropTargetAt(inView.y + listView.contentY,
                                inView.x >= 0 && inView.x <= listView.width
                                && inView.y >= 0 && inView.y <= listView.height);

                            // Both axes from the SAME press point, so the row
                            // is carried by the full pointer delta and the spot
                            // that was grabbed is the spot that tracks the
                            // cursor -- in every direction, not just down.
                            root.dragOffsetX = dx;
                            root.dragOffsetY = dy;
                        }

                        onPositionChanged: (mouse) => {
                            if (dragOwner !== gripMouse)
                                return;
                            motionSeen = true;
                            trackDrag(mouse.x, mouse.y);
                        }

                        // Press-and-hold had to be driven by a timer, not by
                        // motion alone.
                        //
                        // `onPositionChanged` only fires when the pointer
                        // ACTUALLY MOVES. A quick double-tap-and-drag works
                        // because the pointer is already moving by the time the
                        // second press lands, so motion events arrive. Press,
                        // hold still for a moment, THEN drag: on this build the
                        // press is swallowed by the list's own gesture
                        // bookkeeping and the subsequent motion either never
                        // reaches this area or arrives with `pressed` already
                        // cleared, so `onPositionChanged` bails at its first
                        // line and the drag never starts.
                        //
                        // Polling the grab while it is held does not depend on
                        // motion events at all. `mouseX`/`mouseY` are the
                        // MouseArea's own live pointer position under the grab,
                        // so they are correct whether or not a motion event was
                        // delivered -- Qt keeps them current from hover events
                        // too, which is the only thing that can advance the drag
                        // when `onPositionChanged` never fires.
                        //
                        // It stops the moment motion events DO arrive: from then
                        // on `onPositionChanged` owns the pointer and the timer
                        // has nothing left to add. Two writers for one pointer
                        // is two chances to disagree inside a frame, and the one
                        // that disagreed was the row moving by itself.
                        //
                        // Replaying the last sampled position is inert:
                        // `trackDrag` compares it with the sample it already
                        // applied and returns before writing anything, so a
                        // pointer standing perfectly still can never displace
                        // the carried row.
                        Timer {
                            id: holdPoll
                            interval: 16
                            repeat: true
                            running: gripMouse.pressed && !gripMouse.motionSeen
                                && gripMouse.dragOwner === gripMouse
                            onTriggered: gripMouse.trackDrag(gripMouse.mouseX, gripMouse.mouseY)
                        }

                        // Commits the reorder and tears the drag state down.
                        function commitDrag() {
                            Todo.dragInFlight = false;
                            root.gripHeld = false;
                            root.dragOffsetX = 0;
                            root.dragOffsetY = 0;
                            dragging = false;
                            dragOwner = null;
                            const fromId = root.grabbedId;
                            const target = root.dropTargetIndex;
                            root.draggingIndex = -1;
                            root.dropTargetIndex = -1;
                            if (target >= 0 && fromId >= 0) {
                                const beforeId = root.idAtViewIndex(target);
                                if (beforeId >= 0 && beforeId !== fromId)
                                    root.moveRequested(fromId, beforeId);
                            }
                        }

                        // Ends the gesture.
                        //
                        // A function rather than the body of `onReleased`,
                        // because there are now two ways in and both have to end
                        // a drag the same way: the grip and the text column. A
                        // release implemented twice is a release implemented
                        // wrongly once. `lx`/`ly` are in the OWNING area's
                        // coordinates.
                        function finishDrag(lx, ly) {
                            // Whether the pointer is still over the list is
                            // decided FIRST, while the carried row is still in
                            // its dragged position.
                            //
                            // The release position is mapped out of the owning
                            // area's local coordinates, and Qt folded the row's
                            // `Translate` into them when the event was
                            // delivered. Clearing `dragOffset` first drops that
                            // Translate to zero, so the point would be mapped
                            // out of a row that has already jumped back to its
                            // slot -- off by exactly the drag distance, in the
                            // direction the row was carried.
                            //
                            // That error only decides a boundary case, so it
                            // read as an intermittent bug: a drop near the top
                            // or bottom edge would be accepted or cancelled
                            // depending on how far the row had been dragged,
                            // and a drag back onto the same slot would be
                            // judged from a position the pointer was never at.
                            let insideList = false;
                            if (dragging) {
                                const at = listView.mapFromItem(dragOwner, lx, ly);
                                insideList = at.x >= 0 && at.x <= listView.width
                                    && at.y >= 0 && at.y <= listView.height;
                            }

                            // Always cleared, and first, so a drag can never
                            // leave the sidebars pinned open.
                            Todo.dragInFlight = false;
                            root.gripHeld = false;
                            dragHeld = false;
                            root.dragOffsetX = 0;
                            root.dragOffsetY = 0;
                            // The gesture ends the moment the button comes up,
                            // so the owner is dropped HERE rather than at the
                            // end of the handler: every path below returns
                            // early, and a reference to a delegate that is
                            // about to be recycled would outlive the gesture.
                            dragOwner = null;
                            if (!dragging) {
                                // Tapped, not dragged: nothing to do.
                                return;
                            }

                            // Released OUTSIDE the list: cancel, do not reorder.
                            //
                            // `indexAtPosition` clamps to the first and last row,
                            // so a release past either end still produced a
                            // perfectly valid-looking target -- dragging a row out
                            // of the sidebar silently threw it to the top or the
                            // bottom of the list. Leaving the list abandons the
                            // drag instead of aiming at whichever end is nearest.
                            //
                            // The rectangle was tested above, while the row was
                            // still where it was dragged to, so "outside" means
                            // the same thing here as it does on every drag frame:
                            // outside the list's viewport, horizontally as well
                            // as vertically.
                            if (!insideList) {
                                dragging = false;
                                root.draggingIndex = -1;
                                root.dropTargetIndex = -1;
                                return;
                            }

                            commitDrag();
                        }

                        onReleased: (mouse) => {
                            // A drag started somewhere else (the text column)
                            // owns this gesture, so this release is an ordinary
                            // click and must not touch any of its state.
                            if (dragOwner !== gripMouse)
                                return;
                            finishDrag(mouse.x, mouse.y);
                        }
                    }
                }
                    anchors.fill: parent
                    // No horizontal margins. The card is already inset by the
                    // gutters (see `row` above); keeping a second copy of the
                    // same inset here would double it, and the text would sit
                    // 94px from the widget edge with the card 47px away.
                    //
                    // A small symmetric pad instead, so the grip, the circle and
                    // the buttons do not touch the card's own border.
                    anchors.leftMargin: root.cardPad
                    anchors.rightMargin: root.cardPad
                    spacing: 4

                    // Check / uncheck toggle. The ONLY way a task becomes done.
                    //
                    // `Layout.alignment: Qt.AlignTop` is what pins the circle to
                    // the FIRST line of the task rather than the middle of the
                    // block. A RowLayout centres its children by default, so on
                    // an expanded three- or four-line row the circle drifted down
                    // to sit beside the middle of the message -- which reads as
                    // misalignment, since the eye reads the circle as belonging to
                    // the first line.
                    //
                    // The offset is therefore conditional, and must be:
                    //   collapsed -> centre the circle in the row, because the
                    //                text is itself vertically centred and the two
                    //                have to agree.
                    //   expanded   -> the text starts `textPadding` down, so the
                    //                circle starts there too.
                    // A single unconditional margin gets one of those two cases
                    // wrong; measured, an unconditional `textPadding + centre`
                    // pushed the circle 10px BELOW centre on collapsed rows.
                    Item {
                        id: checkToggle
                        Layout.preferredWidth: 30
                        Layout.preferredHeight: 30
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: todoItem.expanded
                            ? root.textPadding
                            : (root.rowHeight - 30) / 2

                        Rectangle {
                            anchors.centerIn: parent
                            width: 24
                            height: 24
                            radius: 12
                            color: todoItem.done
                                ? Appearance.colors.colPrimary
                                : "transparent"
                            border.width: 2
                            border.color: todoItem.done
                                ? Appearance.colors.colPrimary
                                : Appearance.m3colors.m3outline

                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }
                            Behavior on border.color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "check"
                                iconSize: 16
                                color: Appearance.colors.colOnPrimary
                                visible: todoItem.done
                            }
                        }

                        TapHandler {
                            onTapped: {
                                if (!todoItem.done)
                                    Todo.markDoneById(todoItem.taskId);
                                else
                                    Todo.markUnfinishedById(todoItem.taskId);
                            }
                        }
                    }

                    // The task text. Wraps, and is capped at collapsedLines
                    // until the row is expanded -- then it shows in full.
                    Item {
                        id: textColumn
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        // NO rightMargin. This was the cause of the enormous gap
                        // between the ellipsis and the copy button, and it is a
                        // straight double-count.
                        //
                        // The buttons are a SIBLING in this RowLayout
                        // (`actionsBlock`, preferredWidth 60). The layout already
                        // reserves their 60px, because it has to. Reserving them a
                        // second time via `rightMargin` therefore took another
                        // 60px out of the text column -- the text elided 60px
                        // early, and the space sat there empty, reading as a hole
                        // in the middle of the row.
                        //
                        // The gap in front of the buttons is the RowLayout's own
                        // `spacing` (4px) plus the icon inset inside its 30px
                        // cell. Nothing extra is needed, and nothing extra is
                        // wanted: this is a list, not a paragraph.
                        // The text box is clipped as well as the Text itself, so
                        // even a long unbroken word cannot paint past the column
                        // and under the buttons.
                        clip: true

                        // Click the TEXT to read the whole thing.
                        //
                        // It used to be the card-wide area, which meant a press
                        // aimed at the grip or the completion circle could
                        // expand the row instead. Confining it to the text
                        // column gives every control back its own territory:
                        // the text expands, the controls do their own jobs, and
                        // the two can no longer overlap by a pixel.
                        MouseArea {
                            id: textDragMouse
                            anchors.fill: parent
                            // Takes the left button on EVERY row, not only on
                            // the truncated ones.
                            //
                            // It used to accept nothing unless there was text to
                            // reveal, so a click on a short task fell through to
                            // nothing. That is fine for expanding, and fatal for
                            // dragging: Qt only reports a double-click to an area
                            // that accepted the press that produced it, so a
                            // short task could never be picked up by its text no
                            // matter how it was clicked. What there is to expand
                            // is now decided in `onClicked`, where it belongs.
                            acceptedButtons: Qt.LeftButton

                            // While this row is being edited the text column is
                            // a live TextField, so this area must stop taking
                            // presses entirely. Left enabled, it would sit on
                            // top of the field and swallow every click meant for
                            // the caret, and a double-click on the text would
                            // pick the row up for a drag mid-edit.
                            enabled: !todoItem.editing

                            // Set when a release that ended a real drag has to
                            // swallow the click Qt sends immediately after, so a
                            // double-click-drag does not also expand the row it
                            // just dropped. It covers exactly one click and is
                            // reset by it.
                            property bool clickSwallowed: false

                            // A DOUBLE-CLICK picks the row up, so the pointer
                            // never has to find the dots.
                            //
                            // It has to be the double-click and not the press:
                            // Qt delivers the double-click on the SECOND press,
                            // so this is the earliest moment at which a press
                            // can be recognised as the start of a drag. Starting
                            // on `pressed` instead would make every single click
                            // a candidate drag and would lift the row out of the
                            // list before anyone had asked for it.
                            //
                            // Nothing has moved at this point -- the gesture is
                            // only ARMED -- so a double-click that is not
                            // followed by a drag does nothing at all, exactly as
                            // before. Move more than the same 6px of slop the
                            // grip uses and the row follows the pointer, the gap
                            // opens, and release drops it.
                            onDoubleClicked: (mouse) => {
                                const o = mapToItem(null, 0, 0);
                                gripMouse.beginDrag(textDragMouse,
                                    o.x, o.y, mouse.x, mouse.y);
                                mouse.accepted = true;
                            }

                            onPositionChanged: (mouse) => {
                                if (gripMouse.dragOwner !== textDragMouse)
                                    return;
                                gripMouse.motionSeen = true;
                                gripMouse.trackDrag(mouse.x, mouse.y);
                            }

                            // The same press-and-hold fallback the grip has, for
                            // the same reason: on this build a press that is held
                            // still first can swallow the motion events, and only
                            // a poll can notice the pointer moving. It stops as
                            // soon as motion events do arrive, and replays the
                            // last sampled position in the meantime, which
                            // `trackDrag` discards as unchanged.
                            Timer {
                                id: textDragPoll
                                interval: 16
                                repeat: true
                                running: gripMouse.dragOwner === textDragMouse
                                    && gripMouse.dragHeld
                                    && !gripMouse.motionSeen
                                onTriggered: gripMouse.trackDrag(textDragMouse,
                                    textDragMouse.mouseX, textDragMouse.mouseY)
                            }

                            onReleased: (mouse) => {
                                if (gripMouse.dragOwner !== textDragMouse)
                                    return;
                                // Read BEFORE the release tears the gesture
                                // down: `clicked` follows `released`, and the
                                // expand below has to know whether this press
                                // turned into a drag.
                                const wasDrag = gripMouse.dragging;
                                // The release point is folded in before the drag
                                // is torn down, so a row dropped somewhere the
                                // pointer travelled to since the last motion event
                                // lands where it was released rather than where it
                                // was last seen. The grip does the same thing
                                // through its own handlers.
                                gripMouse.trackDrag(mouse.x, mouse.y);
                                gripMouse.finishDrag(mouse.x, mouse.y);
                                if (wasDrag)
                                    clickSwallowed = true;
                            }

                            // Click the TEXT to read the whole thing.
                            //
                            // It used to be the card-wide area, which meant a
                            // press aimed at the grip or the completion circle
                            // could expand the row instead. Confining it to the
                            // text column gives every control back its own
                            // territory: the text expands, the controls do their
                            // own jobs, and the two can no longer overlap by a
                            // pixel.
                            //
                            // It is also the area that starts a drag on a
                            // double-click, so it stays narrow on purpose: the
                            // grip, the circle and the buttons must not be
                            // reachable through it.
                            onClicked: {
                                if (clickSwallowed) {
                                    clickSwallowed = false;
                                    return;
                                }
                                // Nothing to reveal on a task that already fits
                                // on one line, so the click falls through to
                                // nothing rather than toggling a state that does
                                // not exist.
                                if (todoItem.isTruncated)
                                    root.toggleExpanded(todoItem.taskId);
                            }
                        }

                        StyledText {
                            id: textBlock
                            // THE HARD CAP. A one-line row gets a definite width -- the column's
                            // own width -- and the string is elided against
                            // exactly that.
                            //
                            // This used to be `Math.min(parent.width,
                            // root.maxTextWidth)`. The clamp was meant as a
                            // safety ceiling, but a `min()` can only ever make
                            // the box SMALLER than the space it is allowed to
                            // use: any column wider than the ceiling produced a
                            // strip of dead space at the end of every row,
                            // between the ellipsis and the copy button. Since
                            // `elide` already guarantees the glyphs stop inside
                            // this width, the ceiling bought nothing and cost
                            // gap. The text now simply fills its column.
                            //
                            // The hand-rolled truncation this replaced measured
                            // candidate prefixes on a scratch Text and wrote
                            // the results back into it from inside its own
                            // binding. That is a cycle by construction: the
                            // binding read `probe.contentWidth` and wrote
                            // `probe.text`, and Qt reported "Binding loop
                            // detected for property elidedText" on every
                            // delegate. `elide` is Qt's own implementation of
                            // the same idea, with no second object and no loop.
                            width: parent.width
                            // Belt and braces. `elide` already guarantees the
                            // glyphs stop inside `width`; clipping makes that
                            // true even if a future font or a layout pass
                            // hands this box something unexpected.
                            clip: true
                            anchors.verticalCenter: todoItem.expanded
                                ? undefined
                                : parent.verticalCenter
                            anchors.top: todoItem.expanded ? parent.top : undefined
                            // The breathing room, as a margin rather than as
                            // padding ON the text. The circle and the buttons
                            // position themselves with the same `textPadding`
                            // from the top of the row, so the first line of an
                            // expanded task stays level with them.
                            anchors.topMargin: todoItem.expanded
                                ? root.textPadding
                                : 0
                            // Wrapping is what makes a full-width sentence fit
                            // inside the sidebar instead of running off it --
                            // but ONLY when expanded. A collapsed row is one
                            // line, so it must not wrap.
                            wrapMode: todoItem.expanded ? Text.WordWrap : Text.NoWrap
                            // A cap is only a cap while collapsed: -1 means "no
                            // limit", so expanding reveals the rest untouched.
                            maximumLineCount: todoItem.expanded ? -1 : root.collapsedLines
                            // Elide against the capped width. Expanded means
                            // wrap and show everything, so no eliding.
                            elide: todoItem.expanded
                                ? Text.ElideNone
                                : Text.ElideRight
                            text: todoItem.item.content
                            // Hidden while this row is being edited: the
                            // TextField below takes over the same column. Both
                            // are left in the tree rather than swapped by a
                            // Loader so the row never rebuilds around the
                            // caret.
                            visible: !todoItem.editing
                            color: todoItem.done
                                ? Appearance.m3colors.m3outline
                                : Appearance.colors.colOnLayer1

                            // NO `topPadding`/`bottomPadding` here.
                            //
                            // They used to carry the vertical breathing room,
                            // and the row's height added `textPadding * 2` on
                            // top of `textBlock.implicitHeight`. But a Text's
                            // implicitHeight ALREADY includes its padding, so
                            // every expanded row was a full `textPadding` too
                            // tall -- and because the text is top-aligned, all
                            // of that slack landed in one visible band UNDER the
                            // last line: measured off a screenshot, ~12px above
                            // the first line and ~29px below the last, on a row
                            // whose text needed 10 and 10.
                            //
                            // The padding now lives in ONE place, the anchor
                            // margin below, so `implicitHeight` is the height of
                            // the text and nothing else and the row height is a
                            // plain sum of two known numbers.
                            verticalAlignment: todoItem.expanded
                                ? Text.AlignTop
                                : Text.AlignVCenter
                        }

                        // ── The editor ──────────────────────────────────────
                        // A real TextField, in the same column and to the same
                        // measurement rules as `textBlock`, so a task being
                        // edited looks like the task it replaces with a caret
                        // in it.
                        //
                        // `text` is the list-level DRAFT, not the task's
                        // content: nothing is written to the task until commit,
                        // so cancelling is free and typing does not churn the
                        // model (which would rebuild this very delegate).
                        TextField {
                            id: editField
                            visible: todoItem.editing
                            width: parent.width
                            anchors.top: parent.top
                            anchors.topMargin: root.textPadding
                            // Matches `textBlock` exactly. A field measured
                            // against a different font reports a different
                            // height, and the row grows to the wrong size.
                            font: textBlock.font
                            renderType: Text.NativeRendering
                            // Multi-line, because a correction can be longer
                            // than one line and the row is allowed to grow.
                            wrapMode: TextEdit.Wrap
                            selectByMouse: true
                            selectionColor: Appearance.colors.colPrimary
                            selectedTextColor: Appearance.colors.colOnPrimary
                            // No default control chrome: the row's own card
                            // and border are the affordance. A control's own
                            // background inside a card reads as a box in a box.
                            background: null
                            // A visible caret is the whole point of edit mode,
                            // and an outline would compete with the card edge.
                            color: Appearance.colors.colOnLayer1
                            padding: 0
                            text: root.editDraft
                            // `onTextEdited`, NOT `onTextChanged`. `text` is
                            // BOUND to the draft, so writing `editDraft` back
                            // from `onTextChanged` is a binding loop by
                            // construction -- the binding writes the
                            // property whose change handler writes the binding.
                            // `onTextEdited` fires only for user typing, which
                            // is the only case that needs to reach the model.
                            onTextEdited: root.editDraft = text

                            // The existing text starts selected, so typing
                            // REPLACES it. That is the overwhelmingly common
                            // intent when someone edits a task -- they are
                            // fixing a typo or rewording, not appending to the
                            // end -- and it makes one keystroke undo the old
                            // text instead of a manual select-all first.
                            //
                            // ONE handler for both directions: two
                            // `onActiveFocusChanged` blocks on one object is
                            // not additive in QML, the second replaces the
                            // first, and losing the commit-on-blur half would
                            // mean clicking away silently discards an edit.
                            onActiveFocusChanged: {
                                if (activeFocus) {
                                    selectAll();
                                } else if (todoItem.editing) {
                                    // Losing focus commits, so clicking away
                                    // never silently discards what was typed.
                                    // Escape is the way out, and it commits
                                    // nothing.
                                    root.commitEdit(todoItem.taskId);
                                }
                            }

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    root.cancelEdit();
                                    // Give the keyboard back to the list rather
                                    // than letting the field keep a caret on a
                                    // row that is no longer an editor.
                                    listView.forceActiveFocus();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Return
                                           || event.key === Qt.Key_Enter) {
                                    // Commit on Enter. Shift+Enter is NOT a
                                    // newline: this is a one-line-tall list
                                    // row, and a newline here would be a
                                    // newline nobody asked for.
                                    root.commitEdit(todoItem.taskId);
                                    listView.forceActiveFocus();
                                    event.accepted = true;
                                }
                            }

                            // Enter the field as soon as the row becomes the
                            // edited one. Without this the edit mode opens
                            // with no caret and the first keystroke goes
                            // nowhere.
                            onVisibleChanged: {
                                if (visible) {
                                    forceActiveFocus();
                                    selectAll();
                                }
                            }
                        }
                    }

                    // Row actions: copy the text, edit it, or delete the task. All one
                    // click, no dialog. Copy is the one people reach for to
                    // paste a task somewhere else.
                    //
                    // THREE slots, and the width they reserve is `actionsWidth`
                    // (90). The middle one swaps what it DOES with edit state
                    // rather than being added and removed:
                    //   at rest     copy/cancel · edit     · delete
                    //   while edit  cancel       · save     · delete
                    // Keeping the count and the width constant is what stops the
                    // task text from reflowing under the pointer the instant
                    // you open the editor.
                    // Matches the circle's alignment exactly, so the hover actions sit
                    // on the same line as the circle -- otherwise they drift to the
                    // vertical middle of an expanded row while the circle stays at
                    // the top, which looks like the row fell apart.
                    RowLayout {
                        // `editing` is read here so the row REL-AXOUTS around
                        // the save/cancel pair while a task is being edited.
                        // The space is reserved rather than taken, because the
                        // buttons replace copy and delete -- the same two
                        // actions, retitled for what they now do -- so the
                        // action block's width never changes and the task text
                        // cannot reflow under the pointer mid-edit.
                        Layout.preferredWidth: visible ? implicitWidth : 0
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: todoItem.expanded
                            ? root.textPadding
                            : (root.rowHeight - 30) / 2
                        spacing: 0

                        Item {
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            // Always visible -- NOT gated on hover. The row no longer responds to
                            // hovering at all, so a hover-revealed button would
                            // be unreachable-by-design and the copy action
                            // effectively hidden.
                            visible: true

                            // Hover backdrop. The row itself has no hover state (that was removed on
                            // purpose), but the buttons do -- a target the pointer
                            // is over has to look like a target, or the copy action
                            // is undiscoverable.
                            Rectangle {
                                anchors.centerIn: parent
                                width: 26
                                height: 26
                                radius: Appearance.rounding.small
                                color: copyHover.containsMouse
                                    ? Appearance.colors.colLayer1Hover
                                    : "transparent"

                                // No Behaviour: same reasoning as the row fill --
                                // a hover highlight that eases in reads as lag.
                                // One-frame change.
                            }

                            MaterialSymbol {
                                anchors.centerIn: parent
                                // Slot 1 is COPY normally and CANCEL while the
                                // row is being edited. Same button, same
                                // position, same width -- swapping what a slot
                                // DOES rather than adding and removing slots
                                // is what keeps the text column from changing
                                // width the instant edit mode opens.
                                text: todoItem.editing
                                    ? "close"
                                    : (copyFeedback.flash ? "check" : "content_copy")
                                iconSize: todoItem.editing ? 18 : 15
                                color: todoItem.editing
                                    ? (copyHover.containsMouse
                                        ? Appearance.colors.colOnLayer1
                                        : Appearance.m3colors.m3outline)
                                    : (copyFeedback.flash
                                        ? Appearance.colors.colPrimary
                                        : copyHover.containsMouse
                                        ? Appearance.colors.colOnLayer1
                                        : Appearance.m3colors.m3outline)
                            }

                            // The hover SOURCE. A MouseArea, not the TapHandler:
                            // TapHandler has no `hovered` property anywhere in its
                            // Qt 6 inheritance chain (QQuickTapHandler ->
                            // QQuickSinglePointHandler -> QQuickPointerDeviceHandler),
                            // so reading `copyMouse.hovered` silently evaluated to
                            // undefined and the feedback never appeared.
                            //
                            // It sits BEHIND the TapHandler (declared first) and
                            // accepts no buttons, so it reports hover without
                            // stealing the tap from the handler that performs it.
                            MouseArea {
                                id: copyHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                                propagateComposedEvents: true
                            }

                            // Brief checkmark so a copy is confirmed without a
                            // notification (this list is often read mid-task).
                            Timer {
                                id: copyFeedback
                                property bool flash: false
                                interval: 900
                                onTriggered: flash = false
                            }

                            // `hovered` comes from the handler itself rather than a separate
                            // MouseArea, so hover tracking cannot steal the tap
                            // from the same target that reports it.
                            TapHandler {
                                id: copyMouse
                                onTapped: {
                                    // Cancel while editing, copy otherwise.
                                    if (todoItem.editing) {
                                        root.cancelEdit();
                                        return;
                                    }
                                    root.copyText(todoItem.item.content);
                                    copyFeedback.flash = true;
                                    copyFeedback.restart();
                                }
                            }
                        }

                        // ── Slot 2: EDIT normally, SAVE while editing ─────
                        // The edit affordance the row did not have before.
                        // Always visible for the same reason copy is: this
                        // row has no hover state, so a hover-revealed button
                        // would be hidden by design.
                        Item {
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            visible: true

                            Rectangle {
                                anchors.centerIn: parent
                                width: 26
                                height: 26
                                radius: Appearance.rounding.small
                                color: editHover.containsMouse
                                    ? Appearance.colors.colLayer1Hover
                                    : "transparent"
                            }

                            MaterialSymbol {
                                anchors.centerIn: parent
                                // A pencil to edit, a check to commit. They are
                                // the two halves of the same control, so they
                                // share a slot rather than appearing as a
                                // fourth button that pushes the row wider.
                                text: todoItem.editing ? "check" : "edit"
                                iconSize: todoItem.editing ? 18 : 15
                                color: editHover.containsMouse
                                    ? (todoItem.editing
                                        ? Appearance.colors.colPrimary
                                        : Appearance.colors.colOnLayer1)
                                    : Appearance.m3colors.m3outline
                            }

                            // Hover source; see the note on `copyHover` above.
                            MouseArea {
                                id: editHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                                propagateComposedEvents: true
                            }

                            TapHandler {
                                id: editMouse
                                onTapped: {
                                    if (todoItem.editing) {
                                        root.commitEdit(todoItem.taskId);
                                        return;
                                    }
                                    root.beginEdit(todoItem.taskId,
                                                   todoItem.item.content);
                                }
                            }
                        }

                        Item {
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            // Always visible, same reason as copy above.
                            visible: true

                            // Same hover treatment as copy, for the same reason: the row has no
                            // hover state, so each button is its own affordance.
                            Rectangle {
                                anchors.centerIn: parent
                                width: 26
                                height: 26
                                radius: Appearance.rounding.small
                                color: deleteHover.containsMouse
                                    ? Appearance.colors.colLayer1Hover
                                    : "transparent"

                                // No Behaviour: same reasoning as the row fill --
                                // a hover highlight that eases in reads as lag.
                                // One-frame change.
                            }

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "close"
                                iconSize: 18
                                color: deleteHover.containsMouse
                                    ? Appearance.colors.colOnLayer1
                                    : Appearance.m3colors.m3outline
                            }

                            // Hover source; see the note on `copyHover` above.
                            MouseArea {
                                id: deleteHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                                propagateComposedEvents: true
                            }

                            TapHandler {
                                id: deleteMouse
                                onTapped: Todo.deleteById(todoItem.taskId)
                            }
                        }
                    }
                }
            }
        }

        // No flicking while the grip is held: `interactive` above is the
        // Flickable property, and it has to be off for the WHOLE gesture so a
        // left-drag reorders instead of scrolling. That is what `gripHeld` is
        // for.
    }

    // ── Expansion state ────────────────────────────────────────────────────
    // Held here as a set of task IDS, because delegates are recycled and
    // per-delegate state would follow the wrong row after a scroll. Ids rather
    // than positions, so a reorder does not move an expansion onto a different
    // task.
    property var expandedSet: []

    function isExpanded(taskId) {
        return expandedSet.indexOf(taskId) !== -1;
    }

    function toggleExpanded(taskId) {
        if (taskId < 0)
            return;
        const at = expandedSet.indexOf(taskId);
        if (at === -1) {
            // Reassign rather than mutate: ScriptModel watches the reference.
            expandedSet = expandedSet.concat([taskId]);
        } else {
            const next = expandedSet.slice(0);
            next.splice(at, 1);
            expandedSet = next;
        }
    }

    function collapseAll() {
        if (expandedSet.length > 0)
            expandedSet = [];
    }

    // ── Inline editing ──────────────────────────────────────────────────
    //
    // Which task is being edited RIGHT NOW, as a task id, -1 for none.
    //
    // Held here for the same reason `expandedSet` is: delegates are recycled
    // as the list scrolls, so an `editing` flag on the delegate would follow
    // the wrong row after a scroll and leave an editor open on a task nobody
    // asked to change. One id at the list level means exactly one row in the
    // whole widget is in edit mode, and it is always the right one.
    //
    // Only the Unfinished and Done pages share this list, and each page is its
    // own TaskList, so the invariant holds per page.
    property int editingId: -1

    // The text being typed. Kept as a draft, separate from the task, so that
    // a cancelled edit cannot leave a half-typed task behind -- and so nothing
    // is written to disk on every keystroke. `persist()` reassigns `list`, which
    // ScriptModel sees as a change, and doing that per character would rebuild
    // the row under the caret mid-edit.
    property string editDraft: ""

    function beginEdit(id, currentContent) {
        if (id === undefined || id === null)
            return;
        root.editingId = id;
        root.editDraft = String(currentContent ?? "");
        // Editing and reading the full text are the same view, so make sure the
        // row is expanded: otherwise a one-line task puts the caret in a strip
        // one line tall, which is miserable to type a long correction into.
        root.expandForEditing(id);
    }

    function commitEdit(id) {
        if (id === undefined || id === null)
            return;
        // A blank edit is rejected by the service, which leaves the task
        // unchanged; either way leave edit mode so the row goes back to
        // reading normally.
        Todo.editById(id, root.editDraft);
        root.cancelEdit();
    }

    function cancelEdit() {
        root.editingId = -1;
        root.editDraft = "";
    }

    // Expand only if the row is collapsed. Editing an already-expanded row
    // leaves it expanded, so Escape from a long-task edit returns you to the
    // expanded view rather than snapping the text to one line.
    function expandForEditing(id) {
        if (root.isExpanded(id))
            return;
        expandedSet = expandedSet.concat([id]);
    }

    // ── Drag support ───────────────────────────────────────────────────────
    property int grabbedId: -1

    // The pointer's position in the list's VIEWPORT, published by the drag
    // handler so the edge auto-scroll timer can decide which edge the cursor is
    // near. Kept out of the timer on purpose: a timer that polls the mouse
    // would have no mouse to poll, and reading a stale value is how an
    // auto-scroll ends up chasing a cursor that has already moved on.
    property real pointerInListY: -1

    // Safety net for `Todo.dragInFlight`.
    //
    // That flag tells the sidebars to stand down while a task is being dragged,
    // and it is normally cleared in the grip's `onReleased`. A delegate can
    // also be destroyed mid-gesture -- the list scrolling far enough to recycle
    // it, or a filter changing underneath it -- and a destroyed delegate never
    // delivers its release. The flag would then stay set for the rest of the
    // session and neither sidebar would ever close on pointer-out again.
    //
    // `draggingIndex` going negative is the one moment a drag is definitely
    // over, whether or not a release arrived, so it is the right trigger.
    onDraggingIndexChanged: {
        if (draggingIndex < 0)
            Todo.dragInFlight = false;
    }

    // ── Gap opening ───────────────────────────────────────────────────────
    // How far the rows between the dragged one and the drop slot slide, so the
    // list PARTS to let the carried row through instead of the row hovering
    // over a list that has not acknowledged it.
    readonly property real rowPitch: rowHeight + todoListItemSpacing

    // How far the row at `viewIndex` should slide to open a gap.
    //
    // Dragging downward: every row after the dragged one, up to and including
    // the drop slot, slides UP one pitch. Dragging upward: every row from the
    // drop slot up to just before the dragged one slides DOWN one pitch. The
    // dragged row itself never shifts -- it is following the pointer.
    function shiftFor(viewIndex) {
        if (draggingIndex < 0 || dropTargetIndex < 0)
            return 0;
        // `draggingIndex < 0` is also the settle: the instant a drop is
        // committed every row reads zero, so the gap closes by ANIMATING to
        // zero while the reordered model arrives underneath. There is no
        // separate settle state to get wrong.
        if (viewIndex === draggingIndex)
            return 0;
        if (dropTargetIndex > draggingIndex) {
            if (viewIndex > draggingIndex && viewIndex <= dropTargetIndex)
                return -rowPitch;
            return 0;
        }
        if (viewIndex >= dropTargetIndex && viewIndex < draggingIndex)
            return rowPitch;
        return 0;
    }

    // Map a position inside the list view to a row index. Returns the index
    // whose band contains `y`, clamped to the ends so a drag past the top or
    // bottom of the list still resolves to a valid slot.
    function indexAtPosition(y) {
        const count = listView.count;
        if (count === 0)
            return -1;
        const idx = listView.indexAt(listView.contentX + listView.width / 2, y);
        if (idx < 0)
            return y < listView.contentY ? 0 : count - 1;
        return Math.max(0, Math.min(count - 1, idx));
    }

    function updateDropTargetAt(y, insideList) {
        if (draggingIndex < 0) {
            // Safety net for `gripHeld`. If the grab is ever taken away from
            // the grip area before `onReleased` arrives, `gripHeld` would stay
            // true and the list would refuse to scroll for the rest of the
            // session. Any stray motion call is enough to clear it.
            gripHeld = false;
            return;
        }
        // Pointer outside the list: keep the slot where it was. `indexAtPosition`
        // clamps to the ends, so updating anyway would silently retarget the
        // first or last row.
        if (insideList === false)
            return;
        const idx = indexAtPosition(y);
        if (idx < 0)
            return;

        // Commit hysteresis.
        //
        // `indexAt` resolves whichever row's BAND the pointer is in, and two
        // adjacent bands share a boundary. While the pointer rests near one --
        // which is most of the time, because a drag spends most of its life
        // moving slowly -- every subpixel wobble flips the answer between the
        // two rows. Each flip re-targets the whole gap's animation, so the
        // space opens, half closes, opens again: the position it is making
        // space AT appears to jitter between two slots rather than settle on
        // one.
        //
        // Requiring the pointer to travel past the MIDDLE of a row before that
        // row becomes the target gives every row a dead zone in its centre. A
        // wobble inside the zone resolves to the same index every time, so the
        // gap holds still, and the slot changes when the pointer genuinely
        // commits to the next row -- which is also when the user perceives it
        // as having crossed into it.
        //
        // Compared against the CURRENT target rather than unconditionally, so
        // moving back up the list behaves identically to moving down it.
        if (dropTargetIndex >= 0 && idx !== dropTargetIndex) {
            const current = listView.itemAtIndex(dropTargetIndex);
            if (current) {
                const movedDown = idx > dropTargetIndex;
                // The midpoint of the row being entered, in content
                // coordinates -- the same space `y` is already in.
                const mid = current.y + current.height / 2;
                // Crossing DOWN into the next row means being past THIS row's
                // midpoint; crossing UP means being before it.
                if (movedDown ? y < mid : y > mid)
                    return;
            }
        }
        dropTargetIndex = idx;
    }

    // How far this row has slid to open a gap. A property of its own so the
            // Behaviour can sit on it: putting the easing on the Translate
            // would also ease the dragged row, which must track the pointer.
    // The stable id of the task at a position in this (possibly filtered) view.
    function idAtViewIndex(viewIndex) {
        if (viewIndex < 0 || viewIndex >= taskList.length)
            return -1;
        const entry = taskList[viewIndex];
        return entry && entry.id !== undefined ? entry.id : -1;
    }

    // ── Copy ───────────────────────────────────────────────────────────────
    // wl-copy is what the rest of this shell uses for the clipboard, so the
    // task lands in the same place every other copied string does. The text is
    // passed as a single-quoted argument with embedded quotes escaped, so a
    // task containing an apostrophe cannot break out of the quoting.
    function copyText(text) {
        const quoted = "'" + String(text).replace(/'/g, "'\\''") + "'";
        Quickshell.execDetached(["bash", "-c", `printf %s ${quoted} | wl-copy`]);
    }

    // ── Commit the reorder ─────────────────────────────────────────────────
    onMoveRequested: (fromId, beforeId) => {
        // Expanding rows are keyed by task id, and a move does not change an
        // id, so an expanded row stays expanded on the same task. Collapsing
        // anyway was only ever needed because rows were keyed by INDEX.
        Todo.moveBeforeId(fromId, beforeId);
    }

    Item {
        // Placeholder when list is empty
        visible: opacity > 0
        opacity: taskList.length === 0 ? 1 : 0
        anchors.fill: parent

        Behavior on opacity {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 5

            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                iconSize: 55
                color: Appearance.m3colors.m3outline
                text: emptyPlaceholderIcon
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.m3colors.m3outline
                horizontalAlignment: Text.AlignHCenter
                text: emptyPlaceholderText
            }
        }
    }
}







