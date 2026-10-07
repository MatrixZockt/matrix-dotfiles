// The song status bar: how long the track runs, how far in you are, and a
// seek target that takes a click or a drag anywhere along it.
//
// ── Why this exists ─────────────────────────────────────────────────────
// The previous attempt at this was a 4px hairline under the player with a
// fill and no other tell, and it read as "there is no bar here" -- which was
// the owner's complaint, twice. A hairline is a decoration. What makes a line
// into a CONTROL is that it can be aimed at: a visible thickness, a mark for
// the pointer, and the two numbers that say what the line is measuring. So
// all three are here, and the bar's own height is the hit target rather than
// the 6px of track -- 6px is smaller than the pointer, and the difference
// between a scrubber and a rule is whether you can hit it.
//
// The times sit INSIDE the bar, at its two ends, because the bar's whole job
// is to answer "how long does this go" and "how much is left". Leaving them on
// the player card above meant the bar under it answered nothing on its own.
//
// ── The hover feedback is a TIME BUBBLE AND A CARET ─────────────────────
// There was a ball here: an 11px circle under the pointer. It was rejected as
// the wrong idea, not as a badly drawn one -- a circle says "drag me", which
// is a desktop-file-manager control, and it tells you nothing about where the
// click will land.
//
// What replaced it answers that instead. A 2px caret marks the exact spot on
// the line, and a bubble above it reads out the timestamp you would land on,
// so the bar can be aimed by the number rather than by eye. Four options were
// drawn and compared; this was the chosen one.
//
// Two rules the bubble inherits from that:
//   * NO animation on its x. The bubble is where the click will land, and an
//     easing tooltip is a tooltip that lies while you read it.
//   * It clamps to the bar's own width instead of hanging off the end, but
//     its ARROW stays under the cursor even when the body is clamped --
//     otherwise the tooltip points at the edge of the bar rather than at the
//     thing it is describing.
//
// Plain Rectangles and one Text, as everywhere else in the shell:
// QtQuick.Shapes does not paint on this machine.
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    // Mirrors MusicPlayer.position / .duration / .hasTrack. Passed in rather
    // than reached for, so this stays a widget and not a MusicTab fragment.
    property real position: 0
    property real duration: 0
    property bool active: false

    readonly property real fraction: duration > 0
        ? Math.max(0, Math.min(1, position / duration)) : 0

    // Hover and drag are the same visual state -- a caret and a bubble on the
    // line -- so they are one flag, and the line only has to describe one
    // condition.
    property bool pointerOn: false

    // WHERE the pointer is on the track, as a fraction.
    //
    // The caret and the bubble follow this and not `fraction`. `fraction` is
    // where the song has actually got to, which arrives from the daemon a
    // moment after the seek; a mark drawn from it therefore sat somewhere the
    // pointer was not, so the thing you aimed at and the thing that moved were
    // two different marks. Aiming at the pointer is the whole contract of a
    // scrubber.
    property real pointerFraction: 0

    signal seekRequested(real fraction)

    implicitHeight: 34
    implicitWidth: 200

    function fmtTime(s) {
        const t = Math.max(0, Math.floor(s ?? 0));
        const m = Math.floor(t / 60);
        return `${m}:${(t % 60) < 10 ? "0" : ""}${t % 60}`;
    }

    // ── The bar itself ───────────────────────────────────────────────────
    //
    // A real surface, not a transparent strip: the card above it is a card,
    // and this is the bar, and the two should not blur into one row of grey.
    Rectangle {
        id: plate
        anchors.fill: parent
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer2
        // Dimmed with nothing loaded rather than hidden. A control that only
        // appears once a song starts is one you cannot find while looking for
        // it, which is how it came to be described as deleted.
        opacity: root.active ? 1 : 0.4
        Behavior on opacity {
            NumberAnimation { duration: 120 }
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 10

        StyledText {
            objectName: "elapsedReadout"
            text: root.fmtTime(root.position)
            // FIXED width, so `track.x` cannot move while a scrub is in
            // progress. The label is live text -- 0:59 becomes 1:00 becomes
            // 10:00 -- and a digit wider than the last re-lays the row and
            // shifts the track a pixel or two under the pointer. Sampling the
            // track's origin per event cannot help once the origin itself is
            // moving, so the origin is pinned instead.
            Layout.preferredWidth: 32
            horizontalAlignment: Text.AlignLeft
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
        }

        // ── The track ────────────────────────────────────────────────────
        Item {
            id: track
            Layout.fillWidth: true
            Layout.preferredHeight: 14

            Rectangle {
                id: line
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 6
                radius: 3
                color: Appearance.colors.colLayer3

                Rectangle {
                    width: root.fraction * parent.width
                    height: parent.height
                    radius: parent.radius
                    color: Appearance.colors.colPrimary
                    // No animation while the pointer owns the line: a
                    // smoothly easing fill being dragged at is a fight.
                    Behavior on width {
                        enabled: !drag.held
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                }
            }

            // ── The caret: a hairline at the pointer, not a ball ──────────
            //
            // 2px wide and 16px tall, so it crosses the 6px line rather than
            // sitting on it. A disc would obscure the very thing it points at;
            // a caret can sit ON the line and still let you read the line
            // through it.
            //
            // Deliberately NO animation on x, for the same reason the bubble
            // has none: this is where the click will land, and a mark that
            // eases toward the pointer is a mark that lies while you aim at
            // it.
            Rectangle {
                id: caret
                width: 2
                height: 16
                radius: 1
                visible: root.pointerOn && root.active
                opacity: root.pointerOn && root.active ? 1 : 0
                x: Math.max(0, Math.min(track.width - width, root.pointerFraction * track.width - width / 2))
                y: (track.height - height) / 2
                color: Appearance.colors.colPrimary
                Behavior on opacity {
                    NumberAnimation { duration: 110 }
                }
            }
        }

        StyledText {
            objectName: "durationReadout"
            text: root.fmtTime(root.duration)
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            opacity: 0.7
        }
    }

    // ── The bubble: the timestamp you would land on ─────────────────────
    //
    // A CHILD OF ROOT, not of the RowLayout, and that is deliberate on two
    // counts. It has to float above the bar's own top edge, which a layout
    // child cannot do without distorting the row; and being a later sibling
    // than the plate it paints over the player card above rather than under
    // it.
    //
    // `pointerOn` gates the whole thing, so it only exists over the track --
    // sweeping across the elapsed or total label shows nothing, which is the
    // same rule the seek itself follows.
    Item {
        id: bubble
        readonly property bool shown: root.pointerOn && root.active
        // The cursor's x in ROOT's coordinates: the bubble is positioned
        // against the bar, not against the track inside it.
        readonly property real anchorX: track.x + root.pointerFraction * track.width

        visible: bubble.shown
        opacity: bubble.shown ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: 110 }
        }

        width: bubbleText.implicitWidth + 12
        height: 19
        // Clamped so the bubble never hangs off the end of the bar, and with
        // NO animation on x -- see the header.
        x: Math.max(0, Math.min(root.width - width, bubble.anchorX - width / 2))
        y: -16

        Rectangle {
            anchors.fill: parent
            radius: Appearance.rounding.small
            color: Appearance.colors.colPrimary
        }
        StyledText {
            id: bubbleText
            anchors.centerIn: parent
            // The time the click WOULD land on, not the time it is at. That
            // difference is the entire reason this bubble exists.
            text: root.fmtTime(root.pointerFraction * root.duration)
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: Font.DemiBold
            color: Appearance.colors.colOnPrimary
        }
        // The pointer on the bubble. A rotated square rather than a Shape --
        // see the header on why Shapes are not used here.
        Rectangle {
            id: bubbleArrow
            width: 6
            height: 6
            radius: 1.5
            rotation: 45
            color: Appearance.colors.colPrimary
            anchors.top: parent.bottom
            anchors.topMargin: -3.5
            // Follows the CURSOR, not the bubble's centre. When the bubble has
            // been clamped at either end of the bar its centre no longer sits
            // over the pointer, and an arrow pointing at the clamped position
            // would be pointing at the edge of the bar rather than at the
            // thing it describes.
            x: Math.max(width, Math.min(bubble.width - width, bubble.anchorX - bubble.x)) - width / 2
        }
    }

    // ── Input ────────────────────────────────────────────────────────────
    //
    // The area is the WHOLE bar, not just the 6px of track, and both press
    // and drag seek: clicking ahead then letting go lands there, and clicking
    // anywhere and holding scrubs continuously.
    MouseArea {
        id: drag
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.active
        cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
        readonly property bool held: pressed
        // `mx` is relative to THIS area, which spans the whole bar -- the
        // margins, the elapsed label and the total label included. The track
        // starts somewhere past all of that, so the cursor is mapped into the
        // TRACK's own coordinate space rather than having the track's x
        // subtracted by hand: dividing the raw coordinate by the track's
        // width made every seek land early by however much chrome sat to the
        // left of the line, and `mapToItem` is the conversion that stays
        // correct whatever the two items' coordinate spaces turn out to be.
        function fractionAt(mx) {
            return Math.max(0, Math.min(1, mapToItem(track, mx, 0).x / track.width));
        }
        function apply(mx) {
            const f = fractionAt(mx);
            root.pointerFraction = f;
            root.seekRequested(f);
        }
        // A press that lands on a time label is not a seek. Without this the
        // press clamps to the nearest end, and pressing the TOTAL -- which is
        // the one piece of text on the bar you would never press to seek --
        // threw the song to its last second.
        function onTrack(mx) {
            return mx >= track.x && mx <= track.x + track.width;
        }

        // ── Keeping the sidebar's page swipe off the scrub ───────────────
        //
        // Press and hold the bar, drag sideways, and the song changed tabs:
        // Music gave way to To Do. The bar sits inside the left sidebar's
        // `SwipeView`, which is a Flickable pager, and the pager claims a
        // horizontal drag as soon as the pointer moves -- so the scrub and the
        // page swipe were competing for one gesture and the pager won.
        //
        // The fix is to stop the pagers for the duration of the scrub.
        // `interactive` is what makes them claim drags, it is reachable from
        // here by walking up the parent chain (no reference to the sidebar is
        // imported, so this widget stays usable anywhere), and each value is
        // restored afterwards rather than forced to true -- a caller that had
        // it off keeps it off.
        //
        // EVERY interactive ancestor is locked, not just the nearest one, and
        // that is not tidiness. The measured chain out of this bar is
        //
        //     SeekStatusBar < RowLayout < ColumnLayout < MusicTab
        //         < Item < QQuickListView < SwipeView < ...
        //
        // -- SwipeView pages its content through a ListView, so there are two
        // claimants and they are independent. Locking only the ListView left
        // the SwipeView free to claim the same drag, which is the tab change
        // that was reported. Only the ListView matters while the pointer is
        // held on a bar (the wheel is not being used anyway), but leaving the
        // outer one live is precisely the bug.
        //
        // Locked on PRESS rather than on movement: a pager takes the gesture at
        // the first move, so by the time a drag had started there would be
        // nothing left to win back.
        property var lockedHosts: []
        function lockHost() {
            unlockHost();
            const found = [];
            for (let p = parent; p; p = p.parent) {
                // `interactive` is the discriminator: a plain Item does not
                // have it, a ListView, a Flickable and a SwipeView all do.
                if (p.interactive !== undefined) {
                    found.push({ obj: p, was: p.interactive });
                    p.interactive = false;
                }
            }
            lockedHosts = found;
        }
        function unlockHost() {
            for (let i = 0; i < lockedHosts.length; i++)
                lockedHosts[i].obj.interactive = lockedHosts[i].was;
            lockedHosts = [];
        }
        onEntered: {
            root.pointerOn = onTrack(mouseX);
            root.pointerFraction = fractionAt(mouseX);
        }
        onExited: {
            root.pointerOn = false;
        }
        onPressed: m => {
            lockHost();
            if (onTrack(m.x)) apply(m.x);
        }
        onReleased: unlockHost
        onCanceled: unlockHost
        // A press released outside the area still ends here; without this a
        // drag that wandered off the bar would leave the pager disabled until
        // the next press.
        onPositionChanged: m => {
            if (pressed) {
                // Once held, every position counts -- dragging off the end of
                // the track clamps to the ends rather than freezing.
                apply(m.x);
            } else {
                root.pointerOn = onTrack(m.x);
                root.pointerFraction = fractionAt(m.x);
            }
        }
    }
}
