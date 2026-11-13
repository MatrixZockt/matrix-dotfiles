// The greeter's battery, wrapped so that its native module can fail quietly.
//
// Main.qml loads this file through a Loader and reads `percent` / `onAc` off
// the loaded item. That is the whole safety argument: `import "battery"` is the
// one line in the theme that can fail (plugin not built, built against another
// Qt, missing from a copied theme directory), and a failed import in a Loader's
// own component takes down only that component. The login form, the clock, the
// password field and the power actions are in Main.qml and cannot be affected
// by anything here.
//
// The values themselves come from battery/batteryplugin.cpp, which reads
// /sys/class/power_supply/BAT*/ (see the header there for why this cannot be
// done in QML).

import QtQuick
import "battery"

Item {
    visible: false

    readonly property bool present: Battery.present
    readonly property int percent: Battery.percent
    readonly property bool charging: Battery.charging
    readonly property bool onAc: Battery.onAc
}
