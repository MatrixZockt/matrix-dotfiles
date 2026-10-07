import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import Quickshell.Io

QuickToggleButton {
    id: nightLightButton
    toggled: Hyprsunset.temperatureActive
    // Lamp vs. moon: the same distinction the Android-style toggle makes (see
    // modules/common/models/quickToggles/NightLightToggle.qml) -- every crescent
    // in this icon set ("dark_mode", "bedtime", "nightlight") belongs to Dark
    // Mode, so Night Light uses the lamp.
    buttonIcon: Config.options.light.night.automatic ? "wb_twilight" : "table_lamp"
    onClicked: {
        Hyprsunset.toggleTemperature()
    }

    altAction: () => {
        Config.options.light.night.automatic = !Config.options.light.night.automatic
    }

    Component.onCompleted: {
        Hyprsunset.fetchState()
    }
    
    StyledToolTip {
        text: Translation.tr("Night Light | Right-click to toggle Auto mode")
    }
}
