import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.common.functions

ScrollBar {
    id: root

    policy: ScrollBar.AsNeeded
    topPadding: Appearance.rounding.normal
    bottomPadding: Appearance.rounding.normal

    // Which edge of its surface the bar belongs on.
    //
    // Qt parks an ATTACHED scroll bar against the right edge of its flickable,
    // and does it by writing the bar's `x`. So neither of the two obvious ways
    // to move it works: a bound `x` is destroyed by that write, and an anchor
    // is refused outright -- anchoring `left: parent.left` makes Qt report
    // "Possible anchor loop detected on horizontal anchor" and leave the bar
    // where it was (Qt 6.7, which is why the file manager's bar sat on the
    // right while claiming to be on the left). A TRANSLATE is the move that
    // sticks: it does not touch the geometry Qt owns, it is applied after it,
    // and Qt's input delivery maps through it, so hover and drag land on the
    // pixels you can see.
    //
    // Expressed here rather than at the call site because it is a property of
    // the bar, not of the list that owns it, and `false` is the case that
    // leaves Qt's own placement exactly as it was.
    //
    // The file manager is why it exists: its content pane has a fixed left edge
    // that the eye already reads as "the start of the list", so the bar belongs
    // there, where it is not competing with the columns' right-aligned numbers.
    property bool onLeft: false
    transform: Translate {
        x: (root.onLeft && parent) ? -(parent.width - root.width) : 0
    }

    // Whether the hairline is on screen whenever the content OVERFLOWS, rather
    // than only while the pointer is on the surface.
    //
    // A bar you have to hover to discover does not answer "is there more below
    // me?" until you are already committed to scrolling. `policy: AlwaysOn` is
    // the other answer to that and a worse one: it draws a full-length thumb in
    // a file list that has nothing to scroll, which says the opposite of the
    // truth. This says the true thing at rest -- thumb when there is more, no
    // thumb when there is not -- and keeps the hover behaviour underneath it.
    //
    // It is NOT written as `active:`, which is where it started and where it was
    // wrong: Qt fills `active` in on an attached bar itself -- as the pointer and
    // the view move -- and that write BREAKS a binding written on the property.
    // So the bar showed its thumb at rest until the first hover, and after the
    // pointer left, `active` was left false by Qt and the thumb was gone for
    // good: a bar that answered "is there more below me?" only until you touched
    // it. The same facts are read here instead, off properties we only READ
    // (hovered, pressed, size) plus the policy, and Qt keeps `active` for
    // itself.
    property bool showWhenScrollable: false
    readonly property bool showThumb: root.policy === ScrollBar.AlwaysOn
        || (root.size < 1.0 && (root.hovered || root.pressed || root.showWhenScrollable))
    // Slimmer than Qt's default (which reads as a system scrollbar) and, more
    // importantly, never WIDER than that: an interactive ScrollBar reserves
    // its full width inside the flickable's right edge, so at the old default
    // the bar ate into the column and the page labels ended the scroll bar's
    // width short -- "overlapping" it. A lane of 10px with the handle inset by
    // its padding: visible, out of the text's way.
    implicitWidth: 10
    // How thick the thumb itself is, independent of the lane -- the knob that
    // says "hairline, not a second column" while the lane stays wide enough to
    // grab.
    //
    // It is expressed as PADDING below rather than as a width on the handle,
    // and the difference is not cosmetic: Qt sizes an attached bar's handle
    // itself, from the lane's width minus the bar's horizontal padding, so a
    // width written on the handle is a number nobody reads. That is exactly what
    // had happened here -- the file manager asked for a 2px hairline and was
    // drawn a 4px one (measured: the handle's rect came back `x 222, width 4` in
    // an 8px lane) until the padding moved the number into a place Qt obeys.
    property int handleWidth: 6
    leftPadding: Math.max(0, Math.round((root.implicitWidth - root.handleWidth) / 2))
    rightPadding: root.leftPadding
    // The lane also keeps a transparent minimum, so hover-target and reserved
    // space stay the same whether or not the thumb is on screen.
    contentItem: Rectangle {
        implicitHeight: root.visualSize
        radius: width / 2
        color: Appearance.colors.colOnSurfaceVariant

        opacity: root.showThumb ? 0.5 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: 350
                easing.type: Appearance.animation.elementMoveFast.type
                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
            }
        }
    }
}
