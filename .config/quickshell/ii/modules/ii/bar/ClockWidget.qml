import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

Item {
    id: root
    property bool borderless: Config.options.bar.borderless
    property bool showDate: Config.options.bar.verbose

    // The time is deliberately much bigger than the rest of the bar; the date sits
    // to its right, smaller. Date format comes from `time.dateFormat` in the shell
    // config ("dd MMMM" reads as e.g. "12 September").
    property int timeSize: 26
    property int dateSize: Appearance.font.pixelSize.small

    // The calendar popup is CLICK driven (see ClockWidgetPopup / StyledPopup
    // clickOnly): hovering the clock no longer pops it up, clicking does.
    property bool popupOpen: false

    implicitWidth: rowLayout.implicitWidth
    implicitHeight: Appearance.sizes.barHeight

    // Hover background, matching the bar's other buttons.
    transform: Scale {
        xScale: mouseArea.containsMouse ? 1.05 : 1
        yScale: mouseArea.containsMouse ? 1.05 : 1
        Behavior on xScale {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        Behavior on yScale {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
    }

    Rectangle {
        id: hoverBackground
        anchors.fill: parent
        anchors.margins: 3
        radius: Appearance.rounding.normal
        color: mouseArea.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
    }

    RowLayout {
        id: rowLayout

        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 8
        spacing: 12

        StyledText {
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: root.timeSize
            color: Appearance.colors.colOnLayer1
            text: DateTime.time
        }

        StyledText {
            visible: root.showDate
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: root.dateSize
            color: Appearance.colors.colSubtext
            text: DateTime.longDate
        }

        // Right padding, so the hover background has even margins.
        Item {
            Layout.preferredWidth: 8
            Layout.fillHeight: true
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: !Config.options.bar.tooltips.clickToShow
        acceptedButtons: Qt.LeftButton

        onClicked: {
            root.popupOpen = !root.popupOpen
        }

        // Calendar lives here now: the sidebar's calendar tab was removed, so
        // clicking the clock/date opens the month calendar as a floating app.
        ClockWidgetPopup {
            id: calendarPopup
            anchorItem: mouseArea

            Connections {
                target: root
                function onPopupOpenChanged() {
                    calendarPopup.open = root.popupOpen;
                }
            }
            Connections {
                target: calendarPopup
                function onOpenChanged() {
                    // Closed from outside (backdrop click, Escape, focus grab):
                    // un-press the clock so the next click opens it again.
                    if (!calendarPopup.open && root.popupOpen)
                        root.popupOpen = false;
                }
            }
        }
    }
}
