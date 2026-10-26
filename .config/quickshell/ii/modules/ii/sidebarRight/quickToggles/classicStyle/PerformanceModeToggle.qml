import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import Quickshell.Io

// The quick panel's performance mode button. Same switch as the top bar's icon
// and the settings app's toggle -- all three go through
// services/PerformanceMode.qml, which owns the config value and the script
// that applies it, so they can never disagree.
QuickToggleButton {
    id: perfButton
    toggled: PerformanceMode.enabled
    buttonIcon: "speed"
    // Left click: toggle performance mode on/off
    onClicked: {
        PerformanceMode.toggle();
    }
    // Right click: open detailed view
    StyledToolTip {
        text: Translation.tr("Performance mode — fewer animations, snappier interface | Left-click to toggle\nRight-click for details")
    }
}
