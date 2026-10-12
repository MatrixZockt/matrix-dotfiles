// The transport marks: skip-previous, play, pause, skip-next.
//
// This is the top bar's island design, extracted so the left sidebar's music
// tab draws the same marks. The previous attempt used NowBarPanel's transport
// (32/28/28 RippleButtons with a ShapePath triangle) and the owner was right
// that it did not look like the bar at all: the bar's ISLAND is a different
// design, and it is the one on screen in the screenshot.
//
// Three things make it look like the bar rather than merely share its numbers:
//
//  1. THE GLYPH IS THE FONT. `play_arrow`, `skip_previous` and `skip_next`
//     come from Material Symbols Rounded, hinted, at em 20. The old attempt
//     drew the triangle as a `ShapePath`; NowBar.qml records that Shapes do
//     not paint on this machine's setup ("19 path nodes, fill #e2e2e2,
//     visible true, scale 1.0 ... and NOTHING painted", under either
//     renderer, at 1x and 8x). That is why the drawn triangle read as ugly:
//     it was never the smooth hinted glyph it was supposed to be.
//
//  2. THE MARKS ARE POSITIONED FROM THEIR INK. A ligature's layout box is a
//     full em (20px) whatever is drawn inside it -- `skip_next` puts 12px of
//     ink in a 20px box, and the ink is not guaranteed to be centred in it.
//     Centring the box centres the empty space. `TextMetrics.tightBoundingRect`
//     measures the real glyph with the real font (taken FROM the glyph, so
//     family, opsz and weight are the ones in use) and the art is positioned
//     from the ink's own centre.
//
//  3. SMALL. 25x25 for every mark, against the 28/32/28 this replaces. And
//     the skips carry NO pad at all -- the bar's arrows are bare marks, and a
//     padded arrow "reads heavier than the song title they flank", which is
//     the exact complaint about the old buttons. Only play/pause gets a pad,
//     because it is the control people press, and even that is a faint 0.32
//     wash rather than a button.
//
// HOVER IS THE RING, and only the ring: a 1px accent border, 0.55 on hover
// and 0.8 held. No growth (a control that grows when the pointer arrives moves
// the thing you were reaching for, and at this size the swell read as a
// flicker), no fill swell. Play additionally switches the font's FILL axis
// from 0 to 1 -- whole numbers only, because a value BETWEEN the axis's two
// real stops renders `play_arrow` as a hollow triangle with a smaller solid
// triangle inside it, which is the artefact this whole design avoids.
import qs.modules.common
import qs.modules.common.widgets
import QtQuick

Item {
    id: root

    // "play_arrow" | "pause" | "skip_previous" | "skip_next" | "shuffle" | "repeat"
    //
    // `playing` is a convenience over the top of that: it picks pause or
    // play_arrow so a caller does not have to build the string itself and get
    // it subtly wrong.
    //
    // `modeOn` is for the two MODE marks (shuffle, repeat): while engaged the
    // ring is on and the glyph is accented at rest -- the Spotify lit-dot,
    // expressed with this mark's own 1px ring language instead of a dot.
    property string glyph: "play_arrow"
    property bool playing: false

    property bool modeOn: false

    readonly property bool isPause: glyph === "pause"
    readonly property bool isSkip: glyph === "skip_previous" || glyph === "skip_next"
    readonly property bool isMode: glyph === "shuffle" || glyph === "repeat"

    // Only play/pause gets the pad. The bar's skips are bare marks on purpose.
    //
    // `outlined` turns the pad OFF and gives the mark a resting border
    // instead. It exists because a 34px play button with a background that
    // only appears on hover looks unfinished at rest -- there is nothing
    // there until the pointer arrives, so the most important control in the
    // panel is a blank rounded rectangle nine times out of ten. An outline is
    // always visible and brightens, which is how an outlined button is
    // supposed to behave.
    property bool outlined: false
    readonly property bool padded: !isSkip && !outlined

    property bool hovered: false
    property bool pressedMark: false
    // Disabled is a real state: the sidebar's skips have nothing to skip
    // through until a track exists, and the island's own answer to "cannot
    // do this yet" is a dimmed mark rather than a hidden one.
    readonly property bool active: input.enabled
    opacity: root.active ? 1 : 0.4
    Behavior on opacity {
        NumberAnimation { duration: 110 }
    }

    signal triggered()

    // The bar's own number, from SkipArrow.ringSize / IslandButton's pad.
    //
    // Settable, because one size is not right for every surface. 25px is the
    // ISLAND's mark and it is right at the top bar and in the sidebar, where
    // the mark sits beside a song title. It is too small for the popped-out
    // panel's play button, which is a primary control on its own -- so the
    // caller raises `box` and `em` together and the two stay proportional.
    property real box: 25
    // The bar's own em, from SkipArrow.em and IslandButton.glyphSize: the two
    // marks are the same size by construction.
    property real em: 20
    // `rounding.small` (6px) at BOTH sizes, and it was `rounding.normal` (8px)
    // when the panel's outlined button was outlined at 34px. That was a
    // visible step too far: at that size 8px reads as a rounded chip rather
    // than as a button with an edge, and the mockup it was compared against
    // drew it at 6px. Scaling the radius with the box was the right instinct
    // and the wrong amount of it -- the two marks should share one corner.
    readonly property real radius: Appearance.rounding.small

    readonly property color markColor: (root.hovered || root.pressedMark || root.modeOn)
        ? Appearance.colors.colPrimary
        : Appearance.colors.colOnLayer0

    implicitWidth: root.box
    implicitHeight: root.box

    // ── The pad: play/pause only, and only a whisper of one ─────────────
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Appearance.colors.colLayer1Hover
        // Always something, low. At rest this used to be fully invisible with
        // an inactive glyph on top, which made the one control people need
        // first a dim smudge they had to already know was there.
        opacity: root.pressedMark ? 1 : 0.32
        visible: root.padded
        Behavior on opacity {
            NumberAnimation { duration: 110 }
        }
    }

    // ── The ring: the ONLY hover tell, for all three marks ──────────────
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: 1
        border.color: Appearance.colors.colPrimary
        // An OUTLINED mark keeps a faint ring at rest, so it reads as a
        // button when the pointer is somewhere else entirely. Without it the
        // larger play button is an empty rounded rectangle until hovered.
        // Press keeps a brighter ring than hover, so a held press still reads
        // as harder than a pass-over.
        opacity: root.modeOn
            ? (root.pressedMark ? 0.95 : (root.hovered ? 0.7 : 0.9))
            : root.outlined
            ? (root.pressedMark ? 0.95 : (root.hovered ? 0.7 : 0.28))
            : (root.hovered ? 0.55 : (root.pressedMark ? 0.8 : 0))
        Behavior on opacity {
            NumberAnimation { duration: 110 }
        }
    }

    // ── Play ────────────────────────────────────────────────────────────
    MaterialSymbol {
        anchors.centerIn: parent
        visible: !root.isPause && !root.isSkip
        text: root.glyph
        iconSize: root.em
        // WHOLE numbers only. 0 is a clean empty outline at rest, 1 is solid
        // on hover, and anything between them is the shape-inside-a-shape.
        // A LIT mode mark stays filled at rest -- that is the state being
        // advertised; the ring alone would be too quiet for on/off.
        fill: (root.hovered || root.pressedMark || (root.modeOn && root.isMode))
            ? 1 : 0
        color: root.markColor
        // Pressing dips the glyph; hovering does NOT scale it. These are
        // natively rendered, so a scale transform smears the raster -- the
        // same blur the bar's icons had.
        scale: root.pressedMark ? 0.82 : 1
        Behavior on scale {
            NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
        }
    }

    // ── Pause: two pill bars, hollow at rest, solid on hover ─────────────
    //
    // The font's own pause glyph is the wrong shape for this (the owner asked
    // for bars thinner and rounder than it offers), and the FILL axis cannot
    // help a two-bar mark the way it helps a triangle. PLAIN RECTANGLES
    // deliberately: core QtQuick, proven all over the shell, and immune to
    // the Shape-does-not-paint problem above.
    Item {
        anchors.centerIn: parent
        width: 13
        height: 13
        visible: root.isPause
        scale: root.pressedMark ? 0.82 : 1
        Behavior on scale {
            NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
        }
        readonly property bool solid: root.hovered || root.pressedMark

        Rectangle {
            width: 5; height: 13; radius: 2.5
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: parent.solid ? Appearance.colors.colPrimary : "transparent"
            border.width: 1.7
            border.color: parent.solid
                ? Appearance.colors.colPrimary
                : Appearance.colors.colOnLayer0
            Behavior on color { ColorAnimation { duration: 110 } }
            Behavior on border.color { ColorAnimation { duration: 110 } }
        }
        Rectangle {
            width: 5; height: 13; radius: 2.5
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: parent.solid ? Appearance.colors.colPrimary : "transparent"
            border.width: 1.7
            border.color: parent.solid
                ? Appearance.colors.colPrimary
                : Appearance.colors.colOnLayer0
            Behavior on color { ColorAnimation { duration: 110 } }
            Behavior on border.color { ColorAnimation { duration: 110 } }
        }
    }

    // ── Skips: the font's own |◀ and ▶|, positioned from their ink ───────
    //
    // Drawn as ONE glyph (skip_previous / skip_next) rather than a chevron
    // with a bar stuck on the front: the two-piece version's bar was 9px
    // against the triangle's 15px of ink, so it stopped halfway up the arrow
    // and hung off one side -- which reads as a lowercase k. The font's mark
    // is drawn by the same people who drew the play_arrow beside it, so the
    // triangle and the bar are already the right weight for each other.
    TextMetrics {
        id: ink
        font: mark.font
        text: root.glyph
    }

    Item {
        id: art
        anchors.centerIn: parent
        visible: root.isSkip
        // The art's box IS the ink, so it is 12px at em 20 rather than 20.
        width: ink.tightBoundingRect.width
        height: ink.tightBoundingRect.height

        MaterialSymbol {
            id: mark
            // The text box is the glyph's own ADVANCE and x is set so the INK
            // lands dead centre of `art`. No horizontal anchor: an anchor and
            // an explicit x cannot both be set, and the measurement is what
            // the position has to come from.
            width: ink.advanceWidth
            // `tightBoundingRect.x` is measured from the item's LEFT edge
            // here, so this centres the ink horizontally.
            x: -ink.tightBoundingRect.x
            // VERTICALLY this is Qt's job. `tightBoundingRect.y` is measured
            // from the BASELINE, not from the top of the item, so treating it
            // as a top-relative offset puts the whole glyph a line box out.
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph
            iconSize: root.em
            // FILL PINNED at 0 on the skips. The ring is the hover tell, and
            // two animated layers over one 25px mark -- a border fading in
            // while the glyph simultaneously grows from outline to solid --
            // is what read as a weird transition rather than as a hover.
            fill: 0
            color: root.markColor
            scale: root.pressedMark ? 0.82 : 1
            Behavior on scale {
                NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
            }
        }
    }

    // ── Input ───────────────────────────────────────────────────────────
    //
    // A plain MouseArea rather than RippleButton. RippleButton is a Button with
    // a 30px implicit background and a ripple, which is the wrong instrument
    // for a 25px mark on a card: it is what made these buttons read as heavy.
    //
    // `hoverEnabled` is constant and the handlers below are guarded by
    // `root.active` instead, rather than binding `hoverEnabled` to it: a
    // MouseArea cannot take `hoverEnabled` twice, and QML treats the second
    // assignment as a hard "Property value set multiple times" that fails the
    // whole config rather than letting the last one win.
    MouseArea {
        id: input
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
        acceptedButtons: Qt.LeftButton
        onEntered: if (root.active) root.hovered = true
        onExited: root.hovered = false
        onPressed: root.pressedMark = true
        onReleased: {
            root.pressedMark = false;
            if (root.active)
                root.triggered();
        }
        onCanceled: root.pressedMark = false
    }
}