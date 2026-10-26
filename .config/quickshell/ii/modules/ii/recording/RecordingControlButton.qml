import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick

/**
 * One small icon button for the recording control box: 30x30, circular hover.
 *
 * Its own file rather than an inline `component` because the box lives inside
 * a `Scope`, and an inline component is not a type there -- the shell refused
 * to load with "ControlButton is not a type" and took the whole panel family
 * with it.
 *
 * The glyph is a MaterialSymbol rather than an image so it inherits the
 * theme's icon font and weight, and hover FILLS it (the axis) instead of
 * scaling it -- a scaled native glyph smears, which MaterialSymbol.qml
 * documents at length.
 */
Rectangle {
    id: button

    property string icon
    property string tooltip
    property color tint: Appearance.colors.colOnLayer0
    signal clicked()

    implicitWidth: 30
    implicitHeight: 30
    radius: 15
    color: hover.containsMouse ? ColorUtils.transparentize(tint, 0.86) : "transparent"

    Behavior on color {
        ColorAnimation { duration: 110 }
    }

    MaterialSymbol {
        anchors.centerIn: parent
        text: button.icon
        iconSize: 18
        fill: hover.containsMouse ? 1 : 0
        color: button.tint
        autoHover: true
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }

    StyledToolTip {
        text: button.tooltip
    }
}
