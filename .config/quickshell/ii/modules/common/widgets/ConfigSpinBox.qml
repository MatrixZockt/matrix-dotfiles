import qs.modules.common.widgets
import qs.modules.common
import QtQuick
import QtQuick.Layouts

RowLayout {
    id: root
    property string text: ""
    property string icon
    property alias value: spinBoxWidget.value
    property alias stepSize: spinBoxWidget.stepSize
    property alias from: spinBoxWidget.from
    property alias to: spinBoxWidget.to
    spacing: 10
    Layout.leftMargin: 8
    Layout.rightMargin: 8

    // Hover state, exposed because a tooltip declared inside this row needs
    // something to react to. StyledToolTip decides whether to show itself with
    // `parent.hovered`, and it treats a parent that has no `hovered` property at
    // all as "no condition, so show" -- which is why a StyledToolTip inside this
    // row used to sit on the page permanently, unwrapped, across the full width,
    // instead of appearing on hover. A plain RowLayout has no hover state of its
    // own; this gives it one. (Buttons get theirs from AbstractButton, which is
    // why tooltips inside ConfigSwitch were always fine.)
    property bool hovered: hoverHandler.hovered

    HoverHandler {
        id: hoverHandler
    }

    RowLayout {
        spacing: 10
        OptionalMaterialSymbol {
            icon: root.icon
            opacity: root.enabled ? 1 : 0.4
        }
        StyledText {
            id: labelWidget
            Layout.fillWidth: true
            text: root.text
            color: Appearance.colors.colOnSecondaryContainer
            opacity: root.enabled ? 1 : 0.4
        }
    }

    StyledSpinBox {
        id: spinBoxWidget
        Layout.fillWidth: false
        value: root.value
    }
}
