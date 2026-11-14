import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

/**
 * The sound popup app, opened by a two-finger tap on the bar's sound icon.
 *
 * Two columns, not two lists under each other: OUTPUT on the left with its
 * level, MICROPHONE on the right, so "where does the sound come out" and
 * "which mic hears me" are one glance instead of one scroll. Each device is a
 * CARD -- a tile you press -- rather than a row in a list, because a row means
 * "one of many, keep reading" while a card means "this is the thing, pick it".
 *
 * Sibling of WifiPanel, BluetoothPanel and VpnPanel: same BarAnchoredPanel, so
 * Escape, a backdrop click and the close button all work the same way, and the
 * card floats over the same frosted backdrop.
 *
 * Deliberately NOT the mixer (the sidebar's VolumeDialog): that one is about
 * every app's own stream and needs a window's worth of room. This one answers
 * "which device" at a glance; its tune button opens the full mixer for the
 * per-app levels.
 *
 * NO INLINE `component` DECLARATIONS HERE, deliberately. This Quickshell build
 * refuses them: `component DeviceCard: RippleButton { ... }` failed with
 * "DeviceCard is not a type" reported at its own declaration, which made the
 * panel unavailable and took the entire bar down with it. The card and the
 * heading are therefore their own files (SoundDeviceCard.qml,
 * SoundSectionHeading.qml), which resolve like any other type in this folder.
 */
BarAnchoredPanel {
    id: root

    // Wide enough for two columns of cards and no wider: 640 of content, which
    // the base clamps against the screen either way, and 2 x 167px cards fit
    // the left column exactly -- a card never has to elide a device name into
    // something unrecognisable.
    contentWidth: 640

    readonly property real outputColumnWidth: 340
    readonly property real cardGap: 6
    // Must match `implicitHeight` in SoundDeviceCard.qml: the grid maths below
    // reserves exactly this much per row.
    readonly property real cardHeight: 60

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    // Monitor sources are the sinks' own loopback taps (the HDMI outputs'
    // ".monitor" endpoints). They are real PipeWire sources, so the service's
    // device list honestly contains them -- but they are not microphones and
    // nobody reaches for one deliberately, so the input column leaves them out.
    // The full mixer still lists them.
    readonly property var sinks: Audio.outputDevices
    readonly property var sources: Audio.inputDevices.filter(node =>
        !String(node?.name ?? "").endsWith(".monitor"))

    readonly property bool muted: root.sink?.audio?.muted ?? false
    readonly property bool micMuted: root.source?.audio?.muted ?? false

    // ── The microphone's own answer ────────────────────────────────────────
    // A device name says which mic was PICKED; it says nothing about whether
    // that mic hears anything. The bar below the heading is that second
    // question, answered while the user talks, and the small button beside it
    // plays the mic back through the speakers so the answer can be heard too.
    //
    // Pipewire gives Quickshell no peak value, so the level comes from a
    // helper that records the default source and prints its loudness 10x a
    // second. `micPeak` is not the same thing: it is the recent loudest value,
    // held briefly and then released, so a short word leaves a mark that the
    // eye can still catch after the sound is gone.
    property real micLevel: 0
    property real micPeak: 0
    property bool monitoring: false
    readonly property string micLevelScript: Quickshell.shellPath("scripts/audio/mic-level.py")
    readonly property string micMonitorScript: Quickshell.shellPath("scripts/audio/mic-monitor.sh")
    property string micMonitorAction: "status"

    Process {
        id: micLevelProcess
        // Only while the panel is on screen: recording the microphone for a
        // panel nobody is looking at is a privacy problem, not a feature.
        running: root.open && root.source !== null
        command: root.source ? ["python3", root.micLevelScript, String(root.source.name ?? "")] : []
        stdout: SplitParser {
            onRead: line => {
                const level = parseFloat(line);
                if (!isFinite(level))
                    return;
                root.micLevel = Math.max(0, Math.min(1, level));
                root.micPeak = Math.max(root.micPeak, root.micLevel);
            }
        }
    }

    Process {
        id: micMonitorProcess
        command: ["bash", root.micMonitorScript, root.micMonitorAction,
            String(root.source?.name ?? ""), String(root.sink?.name ?? "")]
        stdout: SplitParser {
            onRead: line => root.monitoring = String(line).startsWith("on")
        }
    }

    // Releasing the peak on a timer rather than on the next quiet sample:
    // levels arrive ten times a second whether or not anything is speaking,
    // and tying the fall to a sample would leave the mark stuck during silence.
    Timer {
        interval: 90
        repeat: true
        running: root.open
        onTriggered: root.micPeak = Math.max(root.micLevel, root.micPeak - 0.035)
    }

    // The loopback is real system state, so it is read back when the panel
    // opens rather than assumed to be off; and it is stopped when the panel
    // closes, because a user who walked away from a mic-to-speakers loop has
    // no visible control left to stop the feedback.
    onOpenChanged: {
        if (root.open) {
            root.micMonitorAction = "status";
            micMonitorProcess.running = true;
            return;
        }
        root.micLevel = 0;
        root.micPeak = 0;
        if (root.monitoring) {
            root.micMonitorAction = "off";
            micMonitorProcess.running = true;
        }
    }

    function toggleMonitoring() {
        root.micMonitorAction = "toggle";
        micMonitorProcess.running = true;
    }

    // Tile grids are two wide. The height is stated rather than measured: a
    // Grid of cards has no implicit height of its own, and a ColumnLayout that
    // sized it from nothing would clip the last row.
    function gridHeightFor(count) {
        const rows = Math.max(1, Math.ceil(count / 2));
        return rows * root.cardHeight + (rows - 1) * root.cardGap;
    }

    // Both defaults, tracked so the level, the mute glyphs and the ticks follow
    // the media keys and a headset being plugged in, not only the pointer.
    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }
    PwObjectTracker {
        objects: root.source ? [root.source] : []
    }

    function openFullMixer() {
        root.close();
        Quickshell.execDetached(["bash", "-c", `${Config.options.apps.volumeMixer}`]);
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 10

        // ── Header ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: root.muted ? "volume_off" : "volume_up"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Sound")
                font.pixelSize: Appearance.font.pixelSize.title
                color: Appearance.colors.colOnLayer0
            }
            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: root.openFullMixer()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "tune"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer0
                }
                StyledToolTip {
                    text: Translation.tr("Open the volume mixer")
                }
            }
            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: root.close()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "close"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer0
                }
            }
        }

        // ── The two columns ───────────────────────────────────────────────
        // Tops aligned, each column owning its own heading: the mic column
        // starts level with the output column, not below it, so the pair reads
        // as one row of two answers.
        RowLayout {
            Layout.fillWidth: true
            spacing: 16

            // OUTPUT ───────────────────────────────────────────────────────
            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: root.outputColumnWidth
                spacing: 8

                SoundSectionHeading {
                    Layout.fillWidth: true
                    label: Translation.tr("Output")
                    showMute: false
                    muted: false
                }

                // The level of whatever output is current, beside the tiles it
                // applies to. Same pair the mixer's System row uses: one mute
                // button, one slider on the shell's own scale, so "100%" here
                // is the loud end and never reads "200%".
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    RippleButton {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        buttonRadius: Appearance.rounding.full
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        onClicked: Audio.toggleMute()
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: root.muted ? "volume_off"
                                : Audio.currentVolume() <= 0.001 ? "volume_mute"
                                : Audio.currentVolume() < 0.5 ? "volume_down"
                                : "volume_up"
                            iconSize: Appearance.font.pixelSize.large
                            color: root.muted ? Appearance.colors.colOutline : Appearance.colors.colOnLayer0
                        }
                        StyledToolTip {
                            text: root.muted ? Translation.tr("Unmute") : Translation.tr("Mute")
                        }
                    }
                    StyledSlider {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        value: Audio.currentVolume()
                        onMoved: Audio.setSinkVolume(value)
                        configuration: StyledSlider.Configuration.S
                    }
                    StyledText {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: 38
                        horizontalAlignment: Text.AlignRight
                        text: root.muted ? Translation.tr("Muted")
                            : `${Math.round(Audio.currentVolume() * 100)}%`
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: root.muted ? Appearance.colors.colOutline : Appearance.colors.colPrimary
                    }
                }

                Grid {
                    id: outputGrid
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.gridHeightFor(root.sinks.length)
                    columns: 2
                    columnSpacing: root.cardGap
                    rowSpacing: root.cardGap
                    Repeater {
                        model: root.sinks
                        delegate: SoundDeviceCard {
                            required property var modelData
                            node: modelData
                            forInput: false
                            width: (outputGrid.width - root.cardGap) / 2
                            height: root.cardHeight
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: root.sinks.length === 0
                    text: Translation.tr("No output devices.")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer1
                }
            }

            // MICROPHONE ───────────────────────────────────────────────────
            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                Layout.fillWidth: true
                spacing: 8

                SoundSectionHeading {
                    Layout.fillWidth: true
                    label: Translation.tr("Microphone")
                    showMute: root.source !== null
                    muted: root.micMuted
                }

                // Above the cards on purpose: the question is asked by
                // talking, and the answer has to be where the eye already is.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 12

                        Rectangle {
                            id: micMeterTrack
                            anchors.fill: parent
                            radius: height / 2
                            color: Appearance.colors.colLayer1
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            height: parent.height
                            radius: height / 2
                            width: micMeterTrack.width * root.micLevel
                            color: Appearance.colors.colPrimary
                            Behavior on width {
                                NumberAnimation {
                                    duration: 70
                                    easing.type: Easing.OutQuad
                                }
                            }
                        }

                        Rectangle {
                            // The held peak, drawn as a thin tick so it reads
                            // as "this is how loud it got" beside the live fill.
                            visible: root.micPeak > 0.02
                            anchors.verticalCenter: parent.verticalCenter
                            x: Math.min(micMeterTrack.width - width, micMeterTrack.width * root.micPeak)
                            width: 2
                            height: parent.height + 2
                            radius: 1
                            color: Appearance.colors.colPrimary
                            opacity: 0.55
                        }
                    }

                    RippleButton {
                        Layout.preferredWidth: 30
                        Layout.preferredHeight: 30
                        buttonRadius: Appearance.rounding.small
                        colBackground: root.monitoring
                            ? Appearance.colors.colPrimaryContainer : "transparent"
                        colBackgroundHover: root.monitoring
                            ? Appearance.colors.colPrimaryContainer
                            : Appearance.colors.colLayer1Hover
                        onClicked: root.toggleMonitoring()
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: root.monitoring ? "hearing" : "hearing"
                            iconSize: Appearance.font.pixelSize.normal
                            color: root.monitoring
                                ? Appearance.colors.colOnPrimaryContainer
                                : Appearance.colors.colOnLayer0
                        }
                        StyledToolTip {
                            text: root.monitoring
                                ? Translation.tr("Stop hearing yourself")
                                : Translation.tr("Hear yourself through the speakers")
                        }
                    }
                }

                Grid {
                    id: inputGrid
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.gridHeightFor(root.sources.length)
                    columns: 2
                    columnSpacing: root.cardGap
                    rowSpacing: root.cardGap
                    Repeater {
                        model: root.sources
                        delegate: SoundDeviceCard {
                            required property var modelData
                            node: modelData
                            forInput: true
                            width: (inputGrid.width - root.cardGap) / 2
                            height: root.cardHeight
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: root.sources.length === 0
                    text: Translation.tr("No microphones.")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer1
                }
            }
        }
    }
}
