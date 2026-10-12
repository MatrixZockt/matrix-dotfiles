import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire

ColumnLayout {
    id: root
    required property bool isSink
    // The output tab lists EVERY app, not just the ones making a sound right
    // now: a volume you can only set after the noise starts is a volume you
    // could not have set before the game launched. The input tab stays a list
    // of live capture streams, because a microphone that does not exist has
    // nothing to pre-set (see Audio.buildMixerApps).
    readonly property list<var> appPwNodes: isSink ? Audio.mixerApps : Audio.inputAppNodes
    readonly property list<var> devices: isSink ? Audio.outputDevices : Audio.inputDevices
    readonly property bool hasApps: appPwNodes.length > 0
    spacing: 16

    DialogSectionListView {
        Layout.fillHeight: true
        topMargin: 14

        model: ScriptModel {
            values: root.appPwNodes
        }
        delegate: VolumeMixerEntry {
            anchors {
                left: parent?.left
                right: parent?.right
            }
            required property var modelData
            row: modelData
            isSink: root.isSink
        }
        PagePlaceholder {
            icon: "widgets"
            title: Translation.tr("No applications")
            shown: !root.hasApps
            shape: MaterialShape.Shape.Cookie7Sided
        }
    }

    // The system output bar.
    //
    // Every other row in this list is an APPLICATION's own stream, and each of
    // those can sit at 100% while the machine is still effectively silent: in
    // PipeWire the device is a separate control of its own, and it is the one
    // that decides how loud everything without a row of its own comes out --
    // notification sounds, the shell's own UI noises, whatever the compositor
    // routes. There was no bar for it anywhere in the mixer, so the only way
    // to reach it was the momentary OSD.
    //
    // It sits below the apps and above the device picker rather than at the
    // top: it is the fallback, not the thing you reach for first, and the
    // list above it should not have to move to make room for it.
    component SystemOutputRow: RowLayout {
        id: systemRow
        readonly property var sink: Audio.sink
        spacing: 6
        visible: root.isSink && systemRow.sink !== null && systemRow.sink !== undefined

        // The sink's volume is a plain property on the node, exactly like an
        // app row's -- so it needs the same tracker, or the bar would only
        // follow the mouse and never the media keys.
        PwObjectTracker {
            objects: systemRow.sink ? [systemRow.sink] : []
        }

        MouseArea {
            property real size: 36
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            Layout.preferredWidth: size
            Layout.preferredHeight: size

            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: {
                if (systemRow.sink?.audio)
                    systemRow.sink.audio.muted = !systemRow.sink.audio.muted;
            }

            StyledToolTip {
                text: systemRow.sink?.audio?.muted ? Translation.tr("Click to unmute") : Translation.tr("Click to mute")
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: systemRow.sink?.audio?.muted ? "volume_off"
                    : Audio.currentVolume() <= 0.001 ? "volume_mute"
                    : Audio.currentVolume() < 0.5 ? "volume_down"
                    : "volume_up"
                iconSize: 22
                color: Appearance.colors.colOnLayer1
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: -4

            StyledText {
                Layout.fillWidth: true
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
                elide: Text.ElideRight
                // "System" says what the row CONTROLS; the device name says
                // what it is acting on, which matters because the default
                // device can change under this row at any time (a headset
                // plugged in, a monitor unplugged).
                text: `${Translation.tr("System")} • ${Audio.shortDeviceName(systemRow.sink)}`
            }

            StyledSlider {
                id: systemSlider
                // The SYSTEM row is on the shell's scale (100% = the loud end,
                // `Audio.hardMaxValue`); an app's row below is on PipeWire's own
                // (100% = its unity gain), which is what a stream's node means.
                value: Audio.currentVolume()
                onMoved: Audio.setSinkVolume(value)
                configuration: StyledSlider.Configuration.S
            }
        }
    }

    SystemOutputRow {
        Layout.fillWidth: true
    }

    StyledComboBox {
        id: deviceSelector
        Layout.fillHeight: false
        Layout.fillWidth: true
        Layout.bottomMargin: 6
        model: root.devices.map(node => Audio.friendlyDeviceName(node))
        currentIndex: root.devices.findIndex(item => {
            if (root.isSink) {
                return item.id === Pipewire.defaultAudioSink?.id
            } else {
                return item.id === Pipewire.defaultAudioSource?.id
            }
        })
        onActivated: (index) => {
            print(index)
            const item = root.devices[index]
            if (root.isSink) {
                Audio.setDefaultSink(item)
            } else {
                Audio.setDefaultSource(item)
            }
        }
    }

    component DialogSectionListView: StyledListView {
        Layout.fillWidth: true
        Layout.topMargin: -22
        Layout.bottomMargin: -16
        Layout.leftMargin: -Appearance.rounding.large
        Layout.rightMargin: -Appearance.rounding.large
        topMargin: 12
        bottomMargin: 12
        leftMargin: 20
        rightMargin: 20

        clip: true
        spacing: 4
        animateAppearance: false
    }

    Component {
        id: listElementComp
        ListElement {}
    }
}
