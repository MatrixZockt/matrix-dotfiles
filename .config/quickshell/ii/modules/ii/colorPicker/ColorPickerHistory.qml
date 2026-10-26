pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick

// The recent-colours card: the last few picked hexes, bottom-left, so an
// earlier colour can be taken without picking it again.
//
// It is drawn INSIDE the picker's own window (ColorPickerSurface.qml) and not
// as a window of its own. That is the whole design: SUPER + C is one key for
// both jobs, so the card comes up with the crosshair -- and a second
// layer-shell window would have to fight the picker for the compositor's input
// grab and for keyboard focus. Both of those fights were real in the earlier
// standalone window: a `Region` mask made the card's clicks clear the grab
// instead of reaching a row, and taking Exclusive focus for Escape then stopped
// click-outside from dismissing anything. One window, one input owner, no grab.
Item {
    id: root

    // Newest first. Each entry is a "#RRGGBB" string.
    property var colors: []

    // A colour was chosen from the card. The picker copies it and closes --
    // choosing IS the whole interaction, so there is nothing left to dismiss
    // afterwards.
    signal copyColor(string hex)

    visible: root.colors.length > 0
    implicitWidth: card.width
    implicitHeight: card.height

    StyledRectangularShadow {
        target: card
        radius: card.radius
    }

    Rectangle {
        id: card
        width: 236
        implicitHeight: historyColumn.implicitHeight + card.padding * 2
        property real padding: 10
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer0
        border.width: 1
        border.color: Appearance.colors.colLayer0Border

        // Clicks on the card's own empty space stop here instead of falling
        // through to the picker underneath, which would pick a colour the
        // moment someone reached for a row.
        MouseArea {
            anchors.fill: parent
        }

        Column {
            id: historyColumn
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: card.padding
            }
            spacing: 1

            StyledText {
                text: Translation.tr("Recent colors")
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
                leftPadding: 6
                bottomPadding: 2
            }

            Repeater {
                model: root.colors

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    width: historyColumn.width
                    height: 36
                    radius: Appearance.rounding.small
                    color: rowArea.containsMouse ? Appearance.colors.colLayer1 : "transparent"

                    // Declared FIRST, so the swatch, the hex and the copy button
                    // are all drawn above it: they render on top, and the button
                    // takes its own clicks. Anywhere else on the row still lands
                    // here.
                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.copyColor(row.modelData)
                    }

                    Row {
                        anchors {
                            verticalCenter: parent.verticalCenter
                            left: parent.left
                            leftMargin: 6
                            right: copyButton.left
                            rightMargin: 6
                        }
                        spacing: 10

                        // The same swatch the pill uses, outlined so a white
                        // pick stays visible on the card.
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18
                            height: 18
                            radius: 5
                            color: row.modelData
                            border.width: 1
                            border.color: Appearance.colors.colLayer0Border
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData
                            color: Appearance.colors.colOnLayer0
                        }
                    }

                    // The copy button: an explicit affordance, because a row
                    // that only copies when clicked gives no sign that it does.
                    // It performs the same copy-and-close as the row.
                    Rectangle {
                        id: copyButton
                        anchors {
                            right: parent.right
                            rightMargin: 4
                            verticalCenter: parent.verticalCenter
                        }
                        width: 26
                        height: 26
                        radius: Appearance.rounding.small
                        color: copyArea.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"

                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "content_copy"
                            iconSize: 15
                            color: copyArea.containsMouse ? Appearance.colors.colOnLayer1 : Appearance.colors.colOnLayer1Inactive
                            // Driven by the button's own area: `autoHover`
                            // walks the parent chain and would find nothing
                            // here, since the MouseArea is a sibling.
                            fill: copyArea.containsMouse ? 1 : 0
                        }

                        MouseArea {
                            id: copyArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.copyColor(row.modelData)
                        }
                    }
                }
            }
        }
    }
}
