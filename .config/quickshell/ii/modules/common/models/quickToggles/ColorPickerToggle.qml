import QtQuick
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    name: Translation.tr("Color picker")
    hasStatusText: false
    toggled: false
    icon: "colorize"

    mainAction: () => {
        // Close the sidebar first, then open the picker: the freeze must not
        // capture the panel that launched it. (Same 300ms as before, when
        // this invoked hyprpicker -- which was never installed.)
        GlobalStates.sidebarRightOpen = false;
        delayedActionTimer.start();
    }
    Timer {
        id: delayedActionTimer
        interval: 300
        repeat: false
        onTriggered: {
            GlobalStates.colorPickerOpen = true;
        }
    }

    tooltipText: Translation.tr("Color picker")
}
