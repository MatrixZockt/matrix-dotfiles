import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property string text
    property bool shown: false
    property real horizontalPadding: 10
    property real verticalPadding: 5
    property alias font: tooltipTextObject.font
    // How wide the text may grow before it wraps. Without this the text below
    // has `wrapMode: Text.Wrap` and no width to wrap inside, so it never wraps
    // and the tooltip grows to the length of the whole string -- off the edge
    // of the screen for anything long.
    property real maximumTextWidth: 420
    // Bounded by the same ceiling the text wraps at, so a long string makes
    // the card grow to the wrap width and no further -- the text above is
    // `width`-constrained, but its `implicitWidth` is still the natural
    // single-line length, which is what used to push the tooltip off-screen.
    implicitWidth: Math.min(tooltipTextObject.implicitWidth, root.maximumTextWidth)
        + 2 * root.horizontalPadding
    implicitHeight: tooltipTextObject.implicitHeight + 2 * root.verticalPadding

    property bool isVisible: backgroundRectangle.implicitHeight > 0

    Rectangle {
        id: backgroundRectangle
        anchors {
            bottom: root.bottom
            horizontalCenter: root.horizontalCenter
        }
        // Same card as the battery/clock popups (StyledPopup): surface container,
        // hairline border. The wifi and bluetooth hover chips now read as the
        // same family of popup instead of the old inverse-tooltip grey, and the
        // light theme gets the light card automatically -- these are theme
        // tokens, not baked colours.
        color: Appearance?.m3colors.m3surfaceContainer ?? "#3C4043"
        border.width: 1
        border.color: Appearance?.colors.colLayer0Border ?? "transparent"
        radius: Appearance?.rounding.verysmall ?? 7
        opacity: shown ? 1 : 0
        implicitWidth: shown ? (Math.min(tooltipTextObject.implicitWidth, root.maximumTextWidth)
            + 2 * root.horizontalPadding) : 0
        implicitHeight: shown ? (tooltipTextObject.implicitHeight + 2 * root.verticalPadding) : 0
        clip: true

        Behavior on implicitWidth {
            animation: Appearance?.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        Behavior on implicitHeight {
            animation: Appearance?.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        Behavior on opacity {
            animation: Appearance?.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        StyledText {
            id: tooltipTextObject
            anchors.centerIn: parent
            text: root.text
            font.pixelSize: Appearance?.font.pixelSize.smaller ?? 14
            font.hintingPreference: Font.PreferNoHinting // Prevent shaky text
            color: Appearance?.colors.colOnSurfaceVariant ?? "#FFFFFF"
            wrapMode: Text.Wrap
            // Wrapping is what makes `wrapMode` above do anything at all, and
            // wrapping needs a real WIDTH to wrap inside: `Text` has no
            // `maximumWidth` property, and assigning one is a hard
            // "Cannot assign to non-existent property" that fails the whole
            // configuration -- the bar, the sidebars and everything else with
            // it. A negative width is Qt's "as wide as the text wants", which
            // is the old unconstrained behaviour.
            //
            // It must be `min(natural, max)`, not `max`. Giving the text the
            // full 420 unconditionally made it WIDER THAN ITS OWN CARD
            // whenever the string was shorter than that -- and the card sets
            // `clip: true`, so the overhang was sliced off both ends. That is
            // why "Power - sleep, restart or shut down" rendered as
            // "tart or shut down": the text overflowed the box it lives in,
            // centred, and lost its first characters. Matching the text to the
            // card also leaves the natural width alone, so `implicitWidth` on
            // the card above stays the length of the string and the box is
            // still exactly as wide as it needs to be.
            width: root.maximumTextWidth > 0
                ? Math.min(implicitWidth, root.maximumTextWidth)
                : -1
        }
    }   
}

