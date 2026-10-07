import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.common.functions

ScrollBar {
    id: root

    policy: ScrollBar.AsNeeded
    topPadding: Appearance.rounding.normal
    bottomPadding: Appearance.rounding.normal
    active: hovered || pressed
    // Slimmer than Qt's default (which reads as a system scrollbar) and, more
    // importantly, never WIDER than that: an interactive ScrollBar reserves
    // its full width inside the flickable's right edge, so at the old default
    // the bar ate into the column and the page labels ended the scroll bar's
    // width short -- "overlapping" it. 4px content in a 10px lane: visible,
    // out of the text's way.
    implicitWidth: 10
    // How thick the thumb itself is, independent of the lane. An always-on bar
    // in a long list wants to be a hairline, not a second column.
    property int handleWidth: 4
    // The lane also gets a transparent minimum, so hover-target and reserved
    // space stay the same whether or not the thumb is on screen.
    contentItem: Rectangle {
        implicitWidth: root.handleWidth
        implicitHeight: root.visualSize
        radius: width / 2
        color: Appearance.colors.colOnSurfaceVariant

        opacity: root.policy === ScrollBar.AlwaysOn || (root.active && root.size < 1.0) ? 0.5 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: 350
                easing.type: Appearance.animation.elementMoveFast.type
                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
            }
        }
    }
}
