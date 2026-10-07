import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs.modules.ii.sidebarRight.calendar
import QtQuick
import QtQuick.Layouts

// The calendar popup app: clicking the clock opens it as a small floating
// card over the blurred backdrop (see BarAnchoredPanel), not a popup hanging
// off the bar.
BarAnchoredPanel {
    id: root

    contentWidth: 320

    // Only the weekday name is shown under the calendar now; the long date,
    // uptime and to-do block that used to sit there were removed on request.
    property string weekdayName: Qt.locale().toString(DateTime.clock.date, "dddd")

    ColumnLayout {
        id: columnLayout
        Layout.fillWidth: true
        spacing: 2

        // Month calendar, opened by clicking the clock/date in the bar.
        // Scroll on it (or PageUp/PageDown) to move between months.
        CalendarWidget {
            id: calendarWidget
            Layout.fillWidth: true
            Layout.preferredHeight: calendarWidget.implicitHeight
        }

        StyledText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.normal
            text: root.weekdayName
        }
    }
}
