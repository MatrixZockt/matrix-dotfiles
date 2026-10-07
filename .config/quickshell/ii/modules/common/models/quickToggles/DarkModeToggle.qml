import QtQuick
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    name: Translation.tr("Dark Mode")
    statusText: Appearance.m3colors.darkmode ? Translation.tr("Dark") : Translation.tr("Light")

    toggled: Appearance.m3colors.darkmode
    // The icon SHOWS the mode you are in -- moon in the dark theme, sun in the
    // light one -- instead of the old generic contrast symbol.
    icon: Appearance.m3colors.darkmode ? "dark_mode" : "light_mode"
    
    mainAction: () => {
        // Routed through MaterialThemeLoader: with a template active (the
        // normal case) this copies the same template's other palette over
        // colors.json and the running shell re-applies it instantly. The old
        // route shelled out to switchwall.sh, whose matugen pipeline never ran
        // on this install, so the toggle did nothing.
        MaterialThemeLoader.switchMode(!Appearance.m3colors.darkmode);
    }

    tooltipText: Translation.tr("Dark Mode")
}
