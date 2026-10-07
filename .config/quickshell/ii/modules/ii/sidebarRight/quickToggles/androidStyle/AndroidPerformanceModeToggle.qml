import qs.modules.common
import qs.modules.common.models.quickToggles
import qs.modules.common.widgets
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

// The performance mode button in the android-style quick panel. Same switch as
// the top bar's icon, the classic panel's button and the settings app's toggle
// -- all four go through services/PerformanceMode.qml, which owns the config
// value and the script that applies it.
AndroidQuickToggleButton {
    toggleModel: PerformanceToggle {}
}
