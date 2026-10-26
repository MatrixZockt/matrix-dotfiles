import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * The desktop's small bottom-corner message.
 *
 * It is painted from the BAR's own tokens -- `colBarBackground` for the fill
 * and `colOnLayer0` for the ink, with `windowRounding` for the corners, exactly
 * as the bar's islands are painted (fill-only, no hairline). A message from the
 * desktop should look like a piece of the desktop that came loose, not like a
 * separate app's toast: the bar is the surface the user already reads for
 * state, so the card borrows its material instead of introducing a second one
 * (the earlier plan -- the pale green restart card -- was dropped for exactly
 * that reason: it was a colour from outside the theme).
 *
 * Two callers share it on purpose (the clipboard "copied" toast and the corner
 * notice behind SUPER+CTRL+M); the last time this shell grew two similar cards
 * they drifted apart in radius and timing. One file, one motion.
 *
 * MOTION. In: the card springs out of 60% and overshoots once -- spring 2.6,
 * damping 0.22, so one visible boing then a settle. Out: the same spring in
 * reverse, back down to 60% while the opacity goes. Both were asked for as
 * "goofy" (2026-10-19); the 4% landing this replaces was a hair of scale and
 * read as a fade.
 *
 * The sentence is LATCHED when shown (`shownText`), so a host that clears its
 * model while the card fades cannot collapse the card's width mid-animation --
 * that resize is what used to read as the card sliding away as it left.
 *
 * The card is a picture, never a target: its hosts sit on layer surfaces with
 * an empty mask, so nothing here takes a click.
 */
Rectangle {
    id: root

    // The sentence, and the glyph beside it.
    property string text: ""
    property string icon: "check_circle"
    // How long the card stands before it closes itself. A host that owns its
    // own clock (the corner notice keeps one for its IPC state) sets
    // `autoHide: false` and calls hide() itself.
    property int lifetimeMs: 1200
    property bool autoHide: true
    // Open state. Hosts may also close it early with `hide()`.
    property bool shown: false

    // Emitted once the close animation has played, so a host can tear its
    // window down without guessing at a duration.
    signal finished()

    // The line that is currently PAINTED. Kept apart from `text` for the reason
    // in the header: the box must keep the size the eye saw while it fades.
    property string shownText: ""
    property string shownIcon: "check_circle"

    implicitWidth: row.implicitWidth + 24
    implicitHeight: row.implicitHeight + 14
    // The clock island, to the pixel: `rounding.normal` (8), the bar's fill,
    // and the bar's own hairline. The hairline is what the "black box" report
    // was missing -- without an edge, a #131313 fill on a dark wallpaper has no
    // boundary and reads as a hole. The clock island in the screenshot the user
    // sent measures #131313 fill, #25272C edge, and `colBarBackgroundBorder`
    // evaluates to exactly that.
    radius: Appearance.rounding.normal
    color: Appearance.colors.colBarBackground
    border.width: 1
    border.color: Appearance.colors.colBarBackgroundBorder
    // The status line runs EDGE TO EDGE (see the bottom of CornerNotice), so
    // the card clips its own content: without this the 2px line pokes past
    // the rounded corners at full width. Nothing else extends beyond the box.
    clip: true
    opacity: 0
    scale: 0.6
    visible: opacity > 0.001

    function show(line, glyph, ms) {
        root.shownText = line ?? "";
        root.shownIcon = (glyph && glyph.length > 0) ? glyph : "check_circle";
        if (ms !== undefined && ms > 0)
            root.lifetimeMs = ms;
        closeAnim.stop();
        root.shown = true;
        if (root.autoHide)
            life.restart();
    }

    function hide() {
        life.stop();
        root.shown = false;
    }

    Timer {
        id: life
        interval: root.lifetimeMs
        repeat: false
        running: root.autoHide && root.shown
        onTriggered: root.hide()
    }

    // In: the card pops out of a point -- spring, so it overshoots once and
    // settles. A 4% scale is a landing; this is a BOING, and it was asked for
    // as "goofy" (2026-10-19), so it is deliberately more spring than the rest
    // of the shell uses.
    SequentialAnimation {
        id: openAnim
        ParallelAnimation {
            NumberAnimation {
                target: root
                property: "opacity"
                to: 1
                duration: 140
                easing.type: Easing.OutCubic
            }
            SpringAnimation {
                target: root
                property: "scale"
                to: 1
                spring: 2.6
                damping: 0.22
                epsilon: 0.001
            }
        }
    }

    // Out: a smaller bounce on the way down, then the fade. The overshoot on
    // the way out is what sells it as the same object bouncing back rather than
    // as a box dissolving.
    SequentialAnimation {
        id: closeAnim
        ParallelAnimation {
            NumberAnimation {
                target: root
                property: "opacity"
                to: 0
                duration: 240
                easing.type: Easing.OutCubic
            }
            SpringAnimation {
                target: root
                property: "scale"
                to: 0.6
                spring: 2.6
                damping: 0.24
                epsilon: 0.001
            }
        }
        ScriptAction { script: root.finished() }
    }

    // A second show() while the card is up replaces the line and restarts the
    // clock instead of queueing -- same contract as every other corner card.
    onShownChanged: shown ? openAnim.restart() : closeAnim.restart()

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 8

        MaterialSymbol {
            Layout.alignment: Qt.AlignVCenter
            text: root.shownIcon
            iconSize: 17
            color: Appearance.colors.colOnLayer0
        }

        StyledText {
            Layout.alignment: Qt.AlignVCenter
            text: root.shownText
            color: Appearance.colors.colOnLayer0
            font.pixelSize: Appearance.font.pixelSize.small
        }
    }
}
