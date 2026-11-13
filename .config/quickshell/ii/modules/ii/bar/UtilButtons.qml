import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower

/**
 * The utility buttons on the bar (the cluster left of the desktops).
 *
 * Which ones are shown *and* in what order is a setting: Settings > Bar >
 * "Utility buttons" lists them and lets them be dragged around, and this row
 * follows that order. The order is read from `Config.options.bar.utilButtons.order`
 * and anything the saved order does not mention is appended, so a button added
 * later can never silently disappear from the bar.
 *
 * The toggles keep icons that follow their own state (mic muted, keyboard up,
 * dark/light, power profile) -- reordering them does not freeze any of that.
 */
Item {
    id: root
    property bool borderless: Config.options.bar.borderless
    implicitWidth: rowLayout.implicitWidth + rowLayout.spacing * 2
    implicitHeight: rowLayout.implicitHeight

    // Every button this row knows about.
    readonly property list<string> allKeys: [
        "screenSnip", "screenRecord", "colorPicker", "keyboardToggle",
        "micToggle", "darkModeToggle", "performanceProfileToggle"
    ]
    // The saved order, with anything it leaves out appended in the fallback order.
    readonly property list<string> orderedKeys: {
        const saved = Config.options?.bar.utilButtons.order ?? [];
        const known = saved.filter(key => root.allKeys.indexOf(key) !== -1);
        return known.concat(root.allKeys.filter(key => known.indexOf(key) === -1));
    }

    function isShown(key) {
        switch (key) {
        case "screenSnip": return Config.options.bar.utilButtons.showScreenSnip;
        case "screenRecord": return Config.options.bar.utilButtons.showScreenRecord;
        case "colorPicker": return Config.options.bar.utilButtons.showColorPicker;
        case "keyboardToggle": return Config.options.bar.utilButtons.showKeyboardToggle;
        case "micToggle": return Config.options.bar.utilButtons.showMicToggle;
        case "darkModeToggle": return Config.options.bar.utilButtons.showDarkModeToggle;
        case "performanceProfileToggle": return Config.options.bar.utilButtons.showPerformanceProfileToggle;
        }
        return false;
    }

    function componentFor(key) {
        switch (key) {
        case "screenSnip": return screenSnipButton;
        case "screenRecord": return screenRecordButton;
        case "colorPicker": return colorPickerButton;
        case "keyboardToggle": return keyboardToggleButton;
        case "micToggle": return micToggleButton;
        case "darkModeToggle": return darkModeToggleButton;
        case "performanceProfileToggle": return performanceProfileToggleButton;
        }
        return null;
    }

    RowLayout {
        id: rowLayout

        spacing: 4
        anchors.centerIn: parent

        Repeater {
            model: root.orderedKeys
            delegate: Loader {
                required property string modelData
                active: root.isShown(modelData)
                visible: active
                sourceComponent: root.componentFor(modelData)
            }
        }
    }

    // Screen snip
    Component {
        id: screenSnipButton
        CircleUtilButton {
            Layout.alignment: Qt.AlignVCenter
            buttonSize: 46 // bigger hit area, easier to click
            onClicked: Quickshell.execDetached(["qs", "-p", Quickshell.shellPath(""), "ipc", "call", "region", "screenshot"]);
            MaterialSymbol {
                horizontalAlignment: Qt.AlignHCenter
                fill: 1
                text: "crop_free"
                iconSize: Appearance.font.pixelSize.huge
                color: Appearance.colors.colOnLayer2
            }
        }
    }

    // Screen record
    //
    // Through QuickRecord, i.e. the same recorder SUPER+R and the snip's record
    // mode use. It used to exec `record.sh`, which is built on wf-recorder -- not
    // installed on this machine, so the button was a no-op that left nothing
    // behind: no file, no toast, no way to tell it had done anything at all.
    Component {
        id: screenRecordButton
        CircleUtilButton {
            Layout.alignment: Qt.AlignVCenter
            onClicked: QuickRecord.toggle()
            MaterialSymbol {
                horizontalAlignment: Qt.AlignHCenter
                fill: 1
                text: "videocam"
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colOnLayer2
            }
        }
    }

    // Colour picker
    Component {
        id: colorPickerButton
        CircleUtilButton {
            Layout.alignment: Qt.AlignVCenter
            onClicked: GlobalStates.colorPickerOpen = true
            MaterialSymbol {
                horizontalAlignment: Qt.AlignHCenter
                fill: 1
                text: "colorize"
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colOnLayer2
            }
        }
    }

    // On-screen keyboard: the icon fills in while the keyboard is up.
    Component {
        id: keyboardToggleButton
        CircleUtilButton {
            readonly property bool active: GlobalStates.oskOpen
            Layout.alignment: Qt.AlignVCenter
            onClicked: GlobalStates.oskOpen = !GlobalStates.oskOpen
            MaterialSymbol {
                horizontalAlignment: Qt.AlignHCenter
                fill: parent.active ? 1 : 0
                text: "keyboard"
                iconSize: Appearance.font.pixelSize.large
                color: parent.active ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer2
            }
        }
    }

    // Microphone mute. Off (muted) is the state worth shouting about.
    Component {
        id: micToggleButton
        CircleUtilButton {
            readonly property bool muted: Pipewire.defaultAudioSource?.audio?.muted ?? false
            Layout.alignment: Qt.AlignVCenter
            onClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_SOURCE@", "toggle"])
            MaterialSymbol {
                horizontalAlignment: Qt.AlignHCenter
                fill: parent.muted ? 1 : 0
                text: parent.muted ? "mic_off" : "mic"
                iconSize: Appearance.font.pixelSize.large
                color: parent.muted ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer2
            }
        }
    }

    // Dark/light. The icon is whichever mode pressing it would switch to, so it
    // turns over the moment the theme does.
    Component {
        id: darkModeToggleButton
        CircleUtilButton {
            readonly property bool dark: Appearance.m3colors.darkmode
            Layout.alignment: Qt.AlignVCenter
            buttonSize: 40 // bigger hit area, easier to click
            onClicked: event => {
                // Routed through MaterialThemeLoader.switchMode: with a template
                // active it copies the other palette of the SAME template over
                // colors.json (instant, no wallpaper pipeline needed). Falls
                // back to Wallpapers.setTheme's wallpaper regeneration when no
                // template is active.
                if (!MaterialThemeLoader.switchMode(!darkModeToggleButton.dark))
                    Wallpapers.setTheme(!darkModeToggleButton.dark);
            }
            MaterialSymbol {
                horizontalAlignment: Qt.AlignHCenter
                fill: 0
                text: parent.dark ? "light_mode" : "dark_mode"
                iconSize: Appearance.font.pixelSize.hugeass
                color: Appearance.colors.colOnLayer2
            }
        }
    }

    // Power profile: one icon per profile.
    Component {
        id: performanceProfileToggleButton
        CircleUtilButton {
            readonly property int profile: PowerProfiles.profile
            Layout.alignment: Qt.AlignVCenter
            onClicked: event => {
                if (PowerProfiles.hasPerformanceProfile) {
                    switch(PowerProfiles.profile) {
                        case PowerProfile.PowerSaver: PowerProfiles.profile = PowerProfile.Balanced
                        break;
                        case PowerProfile.Balanced: PowerProfiles.profile = PowerProfile.Performance
                        break;
                        case PowerProfile.Performance: PowerProfiles.profile = PowerProfile.PowerSaver
                        break;
                    }
                } else {
                    PowerProfiles.profile = PowerProfiles.profile == PowerProfile.Balanced ? PowerProfile.PowerSaver : PowerProfile.Balanced
                }
            }
            MaterialSymbol {
                horizontalAlignment: Qt.AlignHCenter
                fill: 0
                text: switch(parent.profile) {
                    case PowerProfile.PowerSaver: return "energy_savings_leaf"
                    case PowerProfile.Balanced: return "airwave"
                    case PowerProfile.Performance: return "local_fire_department"
                }
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colOnLayer2
            }
        }
    }
}
