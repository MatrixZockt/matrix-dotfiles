// The MERGED sound + music bar: concept A3.
//
// ── What this is ────────────────────────────────────────────────────────
// The panel had two separate objects stacked on top of each other: a
// spectrum of pills standing on a thin volume line, and below it the music
// status bar with its own plate. They read as two controls that happened to
// be near each other.
//
// This makes them one line with two meanings. The bars grow straight up out
// of the PROGRESS TRACK, so the volume hairline and the seek line are the
// same line:
//
//   * how far along the track is lit, and how far is dim  -> song position
//   * how tall the bars are allowed to get                 -> volume
//
// Nothing is stacked, so there is no seam between two objects that could
// look wrong, and one line answers three questions instead of two lines
// answering two.
//
// ── Why it is its own file and not a mode of `SeekStatusBar` ───────────
// The two are not variants. `SeekStatusBar` puts the times at the two ENDS
// of the same row as the track; this one puts them on a row BELOW, because
// the bars need the full width above and a time at each end would box them
// in. That is a different internal layout, not a different skin -- and
// `SeekStatusBar` is used by the sidebar's music tab, which has no spectrum
// at all. Restructuring a widget two surfaces depend on, to serve a third
// surface that has a different shape, is the trade this avoids.
//
// If the merge is ever wanted in the sidebar too, the honest move is to give
// `SeekStatusBar` a `spectrum` mode and retire this file -- not to have two
// scrubbers.
//
// ── Two hit zones, and why there are two ───────────────────────────────
// This used to be one control that both seeked and set the volume, which
// only worked because they lived on separate rows. Now they share a line, so
// one drag cannot mean two things. They are split by HEIGHT instead:
//
//   the bars (upper) drag to set VOLUME  -- "make me taller or shorter"
//   the line (lower)  drags to seek      -- with the caret and time bubble
//
// The wheel nudges volume anywhere over the bar, as it always did.
//
// Plain Rectangles throughout: QtQuick.Shapes does not paint on this
// machine, which is documented at length in TransportMark.qml.
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    // Mirrors the panel's player. Passed in rather than reached for, so this
    // stays a widget.
    property real position: 0
    property real duration: 0
    property real volume: 1
    property bool active: false

    /**
     * Are the little up-and-down lines drawn at all?
     *
     * They are the SPECTRUM -- the bars standing on the seek line -- and not
     * the line, the time stamps or the volume they carry. Requested
     * 2026-10-03: the panel hides just these while no music is playing and
     * brings them back when it starts, leaving the rest of the bar exactly
     * where it was.
     *
     * `showSpectrum` on the bars alone, deliberately, and not on this widget:
     * hiding the widget would take the seek line, the elapsed time, the total
     * and the drag target with it, and would collapse the row in the panel's
     * ColumnLayout -- which is a different, much larger change than the one
     * that was asked for. `barsZone` keeps its height either way, so the line
     * stays pinned to the bottom of the row and does not move when the
     * spectrum comes and goes.
     *
     * It scales the bars down, it does not switch them off. A `visible` cut
     * made them blink out between one frame and the next, which reads as a
     * glitch; `spectrumSink` takes every bar to zero height instead, so they
     * fall onto the line and sit inside it -- the spectrum merges into the
     * song bar, which is what was asked for. The bar's feet are anchored at
     * `y: bars.height - height`, so shrinking the height drops the TOP of
     * each bar while the foot stays welded to the top edge of the line: they
     * descend into it rather than sliding along it.
     *
     * Defaults to true so the widget is unchanged for any caller that does not
     * pass it.
     */
    property bool showSpectrum: true

    // 1 when the spectrum is up, 0 when it has merged into the line. Animated
    // on its OWN property and not on the bars' `height`, because the `height`
    // comment below explains why a Behavior there is the wrong tool for a
    // value that changes 30-60 times a second: this one only moves when
    // playback starts or stops, so it animates as a state change while the
    // audio keeps driving height directly.
    //
    // NOT `readonly`. QML refuses a `Behavior on` attached to a read-only
    // property ("Invalid property assignment: 'spectrumSink' is a read-only
    // property") and takes the whole config down, so this is a plain property
    // carrying a binding. Nothing assigns to it; it is the one writable
    // property in this widget.
    property real spectrumSink: showSpectrum ? 1 : 0
    Behavior on spectrumSink {
        NumberAnimation {
            // Slow enough to read as the bars settling, not a snap.
            duration: 260
            easing.type: Easing.OutCubic
        }
    }

    readonly property real fraction: duration > 0
        ? Math.max(0, Math.min(1, position / duration)) : 0

    // Hover and drag share one flag, as in SeekStatusBar: the caret and the
    // bubble are the same state.
    property bool pointerOn: false
    // WHERE the pointer is, as a fraction. The caret follows this and not
    // `fraction` -- the playhead arrives from the daemon a moment after the
    // seek, so a mark drawn from it sits where the pointer is not.
    property real pointerFraction: 0

    signal seekRequested(real fraction)
    // Where the track's two ends are, and where the middle of the times row is,
    // all in root's coordinates.

    // NOT `mapToItem`. That was the first attempt at fixing the bubble being
    // off-centre, and it is worse than the bug: `mapToItem` is an ordinary C++
    // call, so a BINDING that uses it has no dependencies at all -- Qt cannot
    // see that its answer changed when the layout changed, so it is evaluated
    // once during construction, before the layout exists, and then frozen at
    // whatever it guessed. Measured: `lineLeft` sat at 0 forever while the
    // same expression read on demand returned 4.
    //
    // Every term below is a real property read, so each one re-evaluates when
    // the layout moves -- resize the window, change the font scale, open the
    // panel, and the bubble and the caret stay on the cursor.
    //
    // `col` is in the sum because `anchors.margins` insets the LAYOUT, not its
    // children: `col` itself sits at `pad` inside root and `barsZone` sits at
    // 0 inside `col`. (Measured: `barsZone.x` is 0, `col.x` is 4, and the
    // line is 4px from root's edge -- which is exactly the 4px the bubble was
    // short by before.)
    readonly property real lineLeft: col.x + barsZone.x + line.x
    readonly property real lineRight: lineLeft + line.width
    // The bars, then `gap`, then the row: the same three numbers the
    // ColumnLayout is built from, which is what makes this AGREE with the row
    // instead of merely resembling it.
    readonly property real timesCentreY: col.y + barsZone.y + barsZone.height
        + root.gap + root.timesHeight / 2
    // How far BELOW the stamps' centre the hovered number sits. It used to sit
    // on their centre, which put its top edge 1px under the caret's foot and
    // left no air at all; and it no longer has to share their height, because
    // it is not one of them -- it is a caption for the mark above it, and a
    // caption wants air. 6.5 puts six clear pixels between the two.
    readonly property real hoverDrop: 6.5

    // Still declared, still unused by this widget, and still connected by the
    // panel. It is the bar's public contract: removing it takes the panel's
    // `onVolumeRequested` handler with it, which is a load error for the whole
    // config and not a warning.
    signal volumeRequested(real level)

    // The height is NOT a guess. It is the sum of the three rows and the two
    // margins, and every row below carries a FIXED preferred height to match.
    // It used to be a flat 62 while the content wanted 79, and a
    // ColumnLayout that cannot fit its children does not clip them -- it
    // spills them past the bottom edge, which is how the two times ended up
    // sitting OUTSIDE the plate, on top of the playlist's column headings.
    //
    //     8 (top margin) + 22 (bars and line) + 4 (gap) + 14 (times)
    //       + 8 (bottom margin) = 56
    // The proportions of the A3 mockup, matched one for one EXCEPT the
    // track's thickness, which was asked to be two thirds of the mockup's:
    //   * bars standing with their feet on the track's bottom edge, so the
    //     track runs behind them rather than under them with a gap;
    //   * a track of `lineHeight` below, radius half of it so the ends stay
    //     a clean pill whatever that number becomes.
    readonly property int barsHeight: 28
    readonly property int timesHeight: 13
    // 4px: two thirds of the 6px the mockup drew, which is what was asked
    // for. The mockup's 6px was right for a bar with no spectrum sitting on
    // it; with 28px of bars standing on top, the same line read as a heavy
    // band under a light texture. The radius follows at half the height, so
    // the ends stay a clean pill.
    readonly property int lineHeight: 4
    // Settable, and the caller sets it low: this widget no longer draws a
    // plate, so `pad` is the only thing standing between the bars and the
    // edge of whatever contains it.
    property int pad: 8
    readonly property int gap: 4
    implicitHeight: root.pad * 2 + root.barsHeight + root.gap + root.timesHeight
    implicitWidth: 200

    function fmtTime(s) {
        const t = Math.max(0, Math.floor(s ?? 0));
        const m = Math.floor(t / 60);
        return `${m}:${(t % 60) < 10 ? "0" : ""}${t % 60}`;
    }

    // NO PLATE.
    //
    // There used to be a `colLayer2` surface filling this widget. It is gone,
    // and deliberately: it sits on a card that already has its own surface, so
    // it read as a box inside a box and made the bar look like a separate
    // widget dropped into the card rather than part of it. The line now has to
    // carry the row by itself, which is why `pad` is the caller's to set.
    //
    // Nothing replaces the disabled state the plate's opacity used to carry:
    // `seekDrag` is already disabled when `active` is false, and an
    // unseekable player shows an empty line rather than a dimmed one.

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: root.pad
        spacing: root.gap

        // ── The bars, STANDING ON the line ────────────────────────────
        //
        // One item holds both, and the line is pinned to its BOTTOM with the
        // bars rising off the line's top edge. They used to be two sibling
        // rows with a gap between them, which is what the "bars floating above
        // a line" preview showed: the concept is that they stand ON the
        // track, and a 4px gap plus a centred 6px line put ~11px of air
        // between a bar's feet and the thing it is supposed to be standing on.
        Item {
            id: barsZone
            Layout.fillWidth: true
            Layout.preferredHeight: root.barsHeight

            // The line, at the very bottom.
            //
            // `lineHeight` and a radius of half of it -- so the two can never
            // drift apart, and the ends stay a clean pill at any thickness.
            Rectangle {
                id: line
                anchors.bottom: parent.bottom
                width: parent.width
                height: root.lineHeight
                radius: root.lineHeight / 2
                color: Appearance.colors.colLayer3
                Rectangle {
                    width: root.fraction * parent.width
                    height: parent.height
                    radius: parent.radius
                    color: Appearance.colors.colPrimary
                    Behavior on width {
                        enabled: !seekDrag.held
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                }
            }            // The bars.
            //
            // Their feet sit exactly ON the line's top edge -- `bottomMargin`
            // is bound to `lineHeight`, so the two cannot drift apart when
            // either is changed. That is the whole geometry: the spectrum
            // stands on the music bar, and the music bar is never drawn over
            // the bottom of a bar.
            //
            // It used to be `0`, which buried the bottom 4px of every bar in
            // the track and left a hairline of the line cutting across the
            // row of feet; and then a flat `3`, which left the bottom pixel
            // of each foot still touching. Bound to the line's own height,
            // the feet and the top of the line are the same edge.
            Item {
                id: bars
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.lineHeight
                width: parent.width
                height: parent.height - root.lineHeight
                // NOT `visible: root.showSpectrum`. The line above is a
                // sibling, not a child, so it is unaffected either way; the
                // bars themselves are taken down to nothing by
                // `spectrumSink` in their height binding below, so they sink
                // into the line rather than disappearing between frames.

                // One pill per ~12px, which is the density of the sound bar
                // this replaced and of the A3 mockup.
                //
                // It was 7px, which was a mistake: at 720px wide that is a
                // hundred bars, and a hundred 5px marks do not read as a
                // spectrum at all -- they read as a dotted texture, and the
                // whole thing stopped looking like the design that was
                // approved. Bar width has to be measured against how the eye
                // groups marks, not against how finely the position can be
                // resolved.
                readonly property int count: Math.max(12, Math.floor(width / 12))
                readonly property real gap: 3
                readonly property real pillW: Math.max(3,
                    (width - gap * (count - 1)) / count)

                // The same mean ~283 / p90 ~590 scaling the old sound bar
                // used, so the two read as the same instrument.
                function bandFor(i) {
                    const p = AudioVisualizer.points;
                    if (!p || p.length < 3) return 0;
                    const idx = Math.round(i / (count - 1) * (p.length - 1));
                    const raw = p[Math.max(0, Math.min(p.length - 1, idx))];
                    return Math.pow(Math.min(1, raw / 700), 0.7);
                }

                Repeater {
                    model: bars.count
                    Rectangle {
                        required property int index
                        readonly property real at: bars.count > 1
                            ? index / (bars.count - 1) : 0
                        // Lit up to the playhead, dim ahead of it. That split
                        // IS the progress -- there is no second line to
                        // disagree with it.
                        readonly property bool lit: at <= root.fraction

                        width: bars.pillW
                        // VOLUME is the ceiling: at half volume the bars can
                        // never reach the top, which is what lets one line say
                        // two things without a legend.
                        //
                        // `* root.spectrumSink` is the only thing this switch
                        // adds, and it multiplies OUTSIDE the `Math.max(2,…)`
                        // floor on purpose. Inside the floor every bar would
                        // stay a 2px stub at sink 0 -- a dotted texture
                        // sitting on the line, which is the thing being
                        // removed. Outside it, sink 0 is a true zero height
                        // and the bar is gone into the line, while sink 1 is
                        // bit-for-bit the height it always was.
                        height: Math.max(2,
                            bars.bandFor(index) * root.volume * bars.height)
                            * root.spectrumSink
                        y: bars.height - height
                        x: index * (bars.pillW + bars.gap)
                        color: Appearance.colors.colPrimary
                        opacity: lit ? 1 : 0.26
                        // A 2px cap, NOT a dome. The mockup drew these as
                        // `border-radius: 2px 2px 0 0` -- square feet on the
                        // line and only the two top corners eased -- and this
                        // was a half-width radius on each, which turns a 9px
                        // bar into a lozenge. Sixty domes in a row read as a
                        // row of pills, which is a different object from the
                        // one that was approved.
                        //
                        // The feet are square for the same reason the old
                        // sound bar had them square: rounding them would cut a
                        // notch of background out of the top of the line under
                        // every bar and the row would stop reading as standing
                        // on something.
                        topLeftRadius: 2
                        topRightRadius: 2
                        // NO `Behavior on height`, and that is the whole fix
                        // for the bars being slow to reach their height.
                        //
                        // There was a 90ms OutCubic one here, carried over from
                        // the old standalone sound bar, and it is the wrong
                        // tool for a signal that updates 30-60 times a
                        // second. A `Behavior` restarts its animation from
                        // wherever the property currently IS every time the
                        // target moves, so on a continuously-changing value
                        // it never arrives -- it is a low-pass filter, not an
                        // animation. The visible result is a bar that sits
                        // below the music and creeps up after it, and on a
                        // cold start, where the first frames are small
                        // anyway, a row of stubs that grows for no reason.
                        //
                        // cava's own output is already smoothed (it has
                        // gravity), so the widget adding a second layer of
                        // smoothing on top is what made it lag. Direct
                        // binding: the bar is exactly the music.
                        Behavior on opacity {
                            NumberAnimation { duration: 70 }
                        }
                    }
                }
            }

            // The hover mark, ADAPTIVE.
            //
            // It used to be a plain white 2px caret. That works over the
            // unplayed grey line and is INVISIBLE over the played part of the
            // same line, which is `colPrimary` -- so the one thing you need to
            // see is gone for exactly half the bar. The lit spectrum bars are
            // white for the same reason, and the caret's top reaches into them.
            //
            // So it reads what is underneath it. `onPlayed` is true when the
            // pointer is at or before the playhead, which is precisely when
            // the pixels below are white; there the mark inverts to
            // `colOnPrimary` inside a light keyline. Anywhere else it is white
            // in a dark one. Nothing else on the bar changes, and the mark is
            // legible at 0%, at 50% and at 100%.
            //
            // 4px wide, not 2: the inner mark is 2px and the keyline is the
            // 1px either side of it. A `border` cannot do this -- on a 2px rect
            // a border eats the mark -- so it is two stacked rects.
            Item {
                id: hoverMark
                readonly property bool shown: root.pointerOn && root.active
                readonly property bool onPlayed: root.pointerFraction <= root.fraction
                width: 4
                height: 10
                visible: hoverMark.shown
                opacity: hoverMark.shown ? 1 : 0
                // In `line`'s coordinates, which are `barsZone`'s: the line
                // spans the zone's full width and sits flush at its left edge,
                // so the fraction along it IS the offset from the mark's
                // origin. (The bubble below lives in root's coordinates, so it
                // is a child of root, not of this zone -- see `lineLeft` for
                // why both of them are written as plain sums.)
                x: Math.max(0, Math.min(line.width - width,
                    root.pointerFraction * line.width - width / 2))
                // Straddles the line's middle. 10px, not the 14 it was: five
                // below the line was five pixels of caret inside the hovered
                // number, which is the spacing this whole pass is about.
                y: line.y + line.height / 2 - height / 2
                Behavior on opacity { NumberAnimation { duration: 110 } }

                Rectangle { // the keyline
                    anchors.fill: parent
                    radius: width / 2
                    opacity: hoverMark.onPlayed ? 0.55 : 0.85
                    color: hoverMark.onPlayed
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colOnPrimary
                }
                Rectangle { // the mark itself
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: 1
                    color: hoverMark.onPlayed
                        ? Appearance.colors.colOnPrimary
                        : Appearance.colors.colPrimary
                }
            }
        }

        // ── The two times, on their own row ────────────────────────────
        //
        // A FIXED height, so the column above can be given an exact budget
        // and the whole thing cannot overflow its plate.
        //
        // Each stamp is WRAPPED. That is not decoration: the row is 13px and
        // a 15px font is 19px tall, so the text does not fit its cell -- and
        // when an item is taller than its cell, a layout stops honouring
        // `Qt.AlignVCenter` and pins it to the TOP. Measured: both stamps sat
        // at y=36, i.e. 3px above where `AlignVCenter` asked for, with their
        // optical middle at 45.5 while the row's middle was 42.5.
        //
        // The hover chip is centred on the row's middle, so it was 3px above
        // the two numbers it is meant to be a third of -- which is exactly the
        // "not quite the same spacing" in the screenshot, and the kind of
        // thing that survives every amount of staring at coordinates.
        //
        // A full-height `Item` with the text anchored to its middle centres a
        // too-tall child properly, and the wrapper's own implicit sizes are 0,
        // so the row stays 13px and the widget keeps the height it has.
        RowLayout {
            id: timesRow
            Layout.fillWidth: true
            Layout.preferredHeight: root.timesHeight
            spacing: 8
            // Both stamps are wrapped so a 19px line box can be centred in a 13px
            // cell -- see the note above. They do NOT hide on hover: the
            // bubble is opaque and covers whatever it passes over, which is
            // what it is for.
            Item {
                Layout.fillHeight: true
                implicitWidth: elapsedStamp.implicitWidth
                StyledText {
                    id: elapsedStamp
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.fmtTime(root.position)
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                }
            }
            Item { Layout.fillWidth: true; Layout.fillHeight: true }
            Item {
                Layout.fillHeight: true
                implicitWidth: totalStamp.implicitWidth
                StyledText {
                    id: totalStamp
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.fmtTime(root.duration)
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                    opacity: 0.7
                }
            }
        }
    }

    // ── The time bubble, under the hover mark ────────────────────────────
    //
    // Filled `colPrimary` pill, semi-bold number -- the look this started
    // with. A hairline border with no fill was tried and taken back out; do
    // not re-litigate it without being asked.
    //
    // It is NOT on the stamps' row and NOT their height. It is a caption for
    // the mark above it, six pixels below the stamps' centre and three pixels
    // shorter than they are, so there is air between the two instead of a
    // caret's foot inside the number.
    //
    // The two geometry bugs from the first pass are still fixed, because they
    // were never about the look:
    //
    // 1. The bubble was `pad` pixels LEFT of the cursor, always. `anchorX`
    //    was `pointerFraction * barsZone.width` -- a position in the ZONE's
    //    coordinates -- while `x` is a position in root's, and the line
    //    starts `pad` in. `anchorX` is now the cursor's x in the same space
    //    `x` is written in.
    // 2. It hung 4px below this widget, over the playlist's column headings.
    //
    // Still: no animation on x (it is where the click will land, and an
    // easing tooltip lies while you read it), and the body is clamped to the
    // track's two ends rather than the widget's.
    Item {
        id: bubble
        readonly property bool shown: root.pointerOn && root.active
        // The cursor's x in root's coordinates -- the ONE space `x` below is
        // written in, which is the whole fix for "a bit off-centre". It is
        // `lineLeft + fraction * line.width` and nothing else: a sum of three
        // tracked properties, so it cannot disagree with where the seek
        // actually lands.
        readonly property real anchorX: root.lineLeft
            + root.pointerFraction * line.width

        visible: bubble.shown
        opacity: bubble.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 110 } }

        width: bubbleText.implicitWidth + 10
        // The font's line box less three of its leading, with five pixels of
        // padding either side. It does NOT have to match the stamps' 19px: it
        // is a caption for the mark above it, not a third timestamp, and at
        // the stamps' size it read as a slab rather than as a number.
        height: Math.max(14, bubbleText.implicitHeight - 3)
        // Clamped to the TRACK, so at the extremes the chip stops at the end of
        // the line instead of `pad` beyond it. The arrow is not clamped, so
        // it keeps pointing at the cursor even when the body has given up
        // and slid sideways -- which is the whole reason the body is allowed
        // to move at all.
        x: Math.max(root.lineLeft, Math.min(root.lineRight - width,
            bubble.anchorX - width / 2))
        // Below the stamps' centre by `hoverDrop`, not on it: six pixels of
        // nothing between this and the mark that points at it. The bottom
        // three pixels sit in the panel's own bottom margin, which is what
        // that margin is for.
        y: root.timesCentreY + root.hoverDrop - height / 2

        // `colPrimary`, filled: the design this started as. A transparent chip with
        // a hairline border and a "gap instead of an arrow" was tried and
        // taken back out -- it read as a control rather than as the number
        // the pointer is over, and the gap had to be bought by shortening the
        // caret, which made the bar look like it had lost something.
        Rectangle {
            anchors.fill: parent
            radius: Appearance.rounding.small
            color: Appearance.colors.colPrimary
        }
        StyledText {
            id: bubbleText
            anchors.centerIn: parent
            text: root.fmtTime(root.pointerFraction * root.duration)
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: Font.DemiBold
            color: Appearance.colors.colOnPrimary
        }
        // No arrow. It existed to bridge a gap that no longer exists -- with
        // six pixels of air, a 6px diamond floating in the middle of it just
        // filled the gap back in and pointed at nothing. The mark above is
        // already on the cursor's x, and the pill's clamp moves it at most a
        // few pixels from there, so the vertical pair still reads as one.
    }

    // ── Hit zone: THE WHOLE BAR SEEKS ──────────────────────────────────
    //
    // This used to be split by HEIGHT -- the bars dragged the volume, the
    // line dragged the position -- because the two shared a line and one drag
    // could not mean two things. That split was the bug: it put the volume
    // zone over 28 of the 43 pixels, so clicking anywhere that looked like
    // "the bar" changed the VOLUME, and only a press near the very bottom
    // seeked. Clicking to change the song time felt broken because two thirds
    // of the thing you were clicking was not the control.
    //
    // Now the whole widget seeks. It is one line answering one question, and
    // the gesture over it is the gesture everyone already expects.
    //
    // Volume keeps its wheel nudge below, and its tooltip, and loses its
    // drag. That is a real loss and it is the deliberate price of fixing this.
    MouseArea {
        id: seekDrag
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.active
        readonly property bool held: pressed
        cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor

        function fractionAt(mx) {
            // Measured against `line`, which is the visible track and spans
            // the full width of the widget -- the bars sit on it and do not
            // narrow it, and the times below it are the same width.
            return Math.max(0, Math.min(1, mapToItem(line, mx, 0).x / line.width));
        }
        function apply(mx) {
            const f = fractionAt(mx);
            root.pointerFraction = f;
            root.seekRequested(f);
        }
        onEntered: {
            root.pointerOn = true;
            root.pointerFraction = fractionAt(mouseX);
        }
        onExited: root.pointerOn = false
        onPressed: m => apply(m.x)
        onPositionChanged: m => {
            if (pressed) apply(m.x);
            else {
                root.pointerOn = true;
                root.pointerFraction = fractionAt(m.x);
            }
        }
    }

    // ── Hit zone 2 of 2: REMOVED ───────────────────────────────────────
    //
    // There used to be a second MouseArea here, over the bars, that dragged
    // the volume, with the seek MouseArea below it over the line. It is gone.
    //
    // The split was deliberate -- one drag cannot mean two things once the
    // volume and the position share a line -- and it was wrong. It gave the
    // volume 28 of the widget's 43 pixels, so clicking almost anywhere that
    // looked like "the bar" changed the VOLUME and only a press near the very
    // bottom moved the song. That is exactly the "glitchy, doesn't work well"
    // it was reported as: two thirds of the control was not the control.
    //
    // The whole widget seeks now. Volume keeps its wheel nudge below and
    // loses its drag, which is a real loss and the deliberate price of the
    // fix. `volumeRequested` stays on the widget because the wheel still
    // raises it.
}
