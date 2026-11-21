// Settings > Startup apps.
//
// The page is a thin host: the list, the search-and-add field and the two
// switches per row live in modules/common/widgets/StartupAppsPanel.qml, which
// the Task Manager's Startup page renders too. One list, two doors -- and the
// app that actually starts things at login is services/Startup.qml, in the
// SHELL process, not this one. Nothing here needs to call into the shell: the
// settings are read from the shared store when the session starts.
import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    id: root
    forceWidth: true

    ContentSection {
        icon: "rocket_launch"
        title: Translation.tr("Start at login")

        StartupAppsPanel {
            Layout.fillWidth: true
        }
    }
}
