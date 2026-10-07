import qs.services
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts

RippleButton { // Expand button
    id: root
    required property int count
    required property bool expanded
    property real fontSize: Appearance?.font.pixelSize.small ?? 12
    property real iconSize: Appearance?.font.pixelSize.normal ?? 16

    // THE SAME BOX as the row's ×.
    //
    // Not "about the same": the same number, in the same place, with the same
    // shape and the same hover behaviour. Two controls stacked on the
    // right-hand edge of a card that do one thing each have to be the same
    // box, or the card reads as though something is misaligned -- and you
    // cannot work out what, because there is nothing to point at.
    //
    // It used to size itself to `badge + glyph + inset`, which made it a
    // lozenge whose width depended on how many notifications there were.
    // `boxSize` replaces all of that with one square.
    //
    // Must stay equal to `actionSize` in NotificationItem.qml. That is a
    // duplication, and it is deliberate: the two files have no business
    // importing each other to agree on 26.
    readonly property real boxSize: 26

    implicitWidth: boxSize
    implicitHeight: boxSize

    // Zeroed because a Control's padding is added around the content, and
    // this control's content is one glyph that has to land dead centre in a
    // box of an exact size. Any padding here is padding that pushes it off.
    padding: 0
    leftPadding: 0
    rightPadding: 0
    topPadding: 0
    bottomPadding: 0

    buttonRadius: Appearance.rounding.small

    // NO resting fill.
    //
    // There was a `colPrimary` wash at 0.07 sitting under the glyph at all
    // times, which meant the chevron wore a permanent box that the pointer
    // never earned. The × does not: its plate is transparent until
    // `containsMouse`. Two controls stacked on the same edge of a card, one
    // of which is always boxed and one of which is not, reads as one of them
    // being selected.
    //
    // And it is not a `colLayerNHover` token either -- those carry
    // `1 - contentTransparency` in their alpha, so on a solid card the hover
    // state lands a couple of values from transparent and you cannot see it.
    // A `colPrimary` wash always lightens an opaque surface, by an amount we
    // choose.
    colBackground: "transparent"
    colBackgroundHover: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.16)
    colRipple: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.24)

    // One glyph, centred BY THE CONTROL.
    //
    // `anchors.centerIn: parent` on a `contentItem` is a mistake: a Control
    // owns its contentItem's geometry and lays it out after you, so the
    // anchor and the layout fight, and the glyph lands wherever the fight
    // stopped -- which is how it ended up off-centre in its own box.
    // Alignment is the supported way to say "centre me": the Control gives
    // the contentItem the box, and the text centres itself inside it.
    contentItem: MaterialSymbol {
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "expand_more"
        iconSize: root.iconSize
        color: Appearance.colors.colOnLayer2
        rotation: expanded ? 180 : 0
        Behavior on rotation {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
    }
}
