import QtQuick
import qs.modules.common.models.hyprland
import qs.services

/**
 * Performance mode, as a toggle the bar and the quick panel can both show.
 *
 * It is not a game-mode-style "turn half the desktop off" switch: nothing about
 * the look changes. It drops the motion budget -- animations off, hand-played
 * transitions cut short -- and that is all. See services/PerformanceMode.qml.
 */
QuickToggleModel {
    id: root
    name: Translation.tr("Performance mode")
    toggled: PerformanceMode.enabled
    icon: "speed"

    mainAction: () => {
        PerformanceMode.toggle();
    }

    tooltipText: Translation.tr("Performance mode — fewer animations, snappier interface")
}
