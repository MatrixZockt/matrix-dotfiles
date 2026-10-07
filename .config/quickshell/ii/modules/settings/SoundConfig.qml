import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

/**
 * Windows-Settings "Sound" as its own page (slug `sound`), and the content
 * behind "Bluetooth & devices" grouping. Output/input device choice lives
 * here; per-app mixing stays in the right sidebar where the volume control
 * is one click away.
 */
ContentPage {
    id: root
    forceWidth: true

    // The device lists come from Audio.devices() which returns PwNode objects;
    // they can be momentarily empty while PipeWire settles.
    readonly property bool hasOutput: Audio.outputDevices.length > 0
    readonly property bool hasInput: Audio.inputDevices.length > 0

    ContentSection {
        icon: "volume_up"
        title: Translation.tr("Output")

        StyledComboBox {
            id: outputSelector
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            buttonIcon: "speaker"
            textRole: "displayName"
            enabled: root.hasOutput

            model: root.hasOutput ? Audio.outputDevices.map(d => ({
                displayName: Audio.friendlyDeviceName(d),
                value: d.id
            })) : []

            currentIndex: {
                const id = Pipewire.defaultAudioSink?.id;
                return model.findIndex(item => item.value === id);
            }

            onActivated: index => {
                const dev = Audio.outputDevices.find(d => d.id === model[index].value);
                if (dev) Audio.setDefaultSink(dev);
            }
        }

        StyledText {
            Layout.leftMargin: 16
            visible: !root.hasOutput
            text: Translation.tr("No output devices found.")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.smaller
        }
    }

    ContentSection {
        icon: "mic"
        title: Translation.tr("Input")

        StyledComboBox {
            id: inputSelector
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            buttonIcon: "mic"
            textRole: "displayName"
            enabled: root.hasInput

            model: root.hasInput ? Audio.inputDevices.map(d => ({
                displayName: Audio.friendlyDeviceName(d),
                value: d.id
            })) : []

            currentIndex: {
                const id = Pipewire.defaultAudioSource?.id;
                return model.findIndex(item => item.value === id);
            }

            onActivated: index => {
                const dev = Audio.inputDevices.find(d => d.id === model[index].value);
                if (dev) Audio.setDefaultSource(dev);
            }
        }

        StyledText {
            Layout.leftMargin: 16
            visible: !root.hasInput
            text: Translation.tr("No input devices found.")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.smaller
        }
    }

    ContentSection {
        icon: "hearing"
        title: Translation.tr("Volume behaviour")

        ConfigSwitch {
            buttonIcon: "hearing"
            text: Translation.tr("Earbang protection")
            checked: Config.options.audio.protection.enable
            onCheckedChanged: Config.options.audio.protection.enable = checked
            StyledToolTip {
                text: Translation.tr("Prevents abrupt volume increments and restricts the volume limit.")
            }
        }
        ConfigRow {
            enabled: Config.options.audio.protection.enable
            ConfigSpinBox {
                icon: "arrow_warm_up"
                text: Translation.tr("Max allowed increase")
                value: Config.options.audio.protection.maxAllowedIncrease
                from: 0
                to: 100
                stepSize: 2
                onValueChanged: Config.options.audio.protection.maxAllowedIncrease = value
            }
            ConfigSpinBox {
                icon: "volume_up"
                text: Translation.tr("Volume limit")
                value: Config.options.audio.protection.maxAllowed
                from: 0
                to: 154
                stepSize: 2
                onValueChanged: Config.options.audio.protection.maxAllowed = value
            }
        }
    }

    ContentSection {
        icon: "music_note"
        title: Translation.tr("System sounds")

        ConfigRow {
            uniform: true
            ConfigSwitch {
                buttonIcon: "battery_full"
                text: Translation.tr("Battery")
                checked: Config.options.sounds.battery
                onCheckedChanged: Config.options.sounds.battery = checked
            }
            ConfigSwitch {
                buttonIcon: "av_timer"
                text: Translation.tr("Pomodoro")
                checked: Config.options.sounds.pomodoro
                onCheckedChanged: Config.options.sounds.pomodoro = checked
            }
        }
    }
}
