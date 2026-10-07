import QtQuick
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    property bool auto: Config.options.light.night.automatic

    name: Translation.tr("Night Light")
    statusText: (auto ? Translation.tr("Auto, ") : "") + (toggled ? Translation.tr("Active") : Translation.tr("Inactive"))

    toggled: Hyprsunset.temperatureActive
    // A lamp, never a moon. The moon marks belong to Dark Mode: "dark_mode",
    // "bedtime" and "nightlight" are all crescents in this icon set ("nightlight"
    // especially -- its lamp shares the outline of a waning moon), which is why
    // Night Light and Dark Mode sitting next to each other looked like the same
    // button twice. "table_lamp" is the one light glyph with no lunar geometry in
    // it. Automatic gets the sun-on-the-horizon mark instead, which says what the
    // mode actually is -- the temperature following the sun.
    icon: auto ? "wb_twilight" : "table_lamp"
    
    mainAction: () => {
        Hyprsunset.toggleTemperature()
    }
    hasMenu: true

    Component.onCompleted: {
        Hyprsunset.fetchState()
    }
    
    tooltipText: Translation.tr("Night Light | Right-click to configure")
}
