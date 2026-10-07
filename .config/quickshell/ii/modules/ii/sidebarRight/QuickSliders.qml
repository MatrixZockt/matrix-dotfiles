import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.UPower

Rectangle {
    id: root

    property var screen: root.QsWindow.window?.screen
    property var brightnessMonitor: Brightness.getMonitorForScreen(screen)

    implicitWidth: contentItem.implicitWidth + root.horizontalPadding * 2
    implicitHeight: contentItem.implicitHeight + root.verticalPadding * 2
    radius: Appearance.rounding.normal
    color: Appearance.colors.colLayer1
    property real verticalPadding: 2
    property real horizontalPadding: 8

    Column {
        id: contentItem
        anchors {
            fill: parent
            leftMargin: root.horizontalPadding
            rightMargin: root.horizontalPadding
            topMargin: root.verticalPadding
            bottomMargin: root.verticalPadding
        }

        Loader {
            anchors {
                left: parent.left
                right: parent.right
            }
            visible: active
            active: Config.options.sidebar.quickSliders.showBrightness
            sourceComponent: QuickSlider {
                materialSymbol: "light_mode"
                showPercentInside: true
                // A plain display-brightness bar: the whole track is the
                // built-in panel's 0-100% and nothing else. It used to be a
                // hybrid where the bottom 30% drove hyprsunset gamma and the
                // top 70% drove the panel, which meant the number inside the
                // bar and the position of the handle disagreed about what
                // the slider was even showing. Gamma is still reachable from
                // the night light toggle and the brightness keys.
                //
                // `root.brightnessMonitor` is undefined for the first moments
                // of a session (Brightness.monitorForScreen resolves lazily),
                // so every read is optional-chained and falls back to 0 --
                // the same guard the audio sliders use below.
                value: root.brightnessMonitor?.brightness ?? 0
                tooltipContent: `${Math.round((root.brightnessMonitor?.brightness ?? 0) * 100)}%`
                onMoved: {
                    if (root.brightnessMonitor)
                        root.brightnessMonitor.setBrightness(value)
                }
            }
        }

        Loader {
            anchors {
                left: parent.left
                right: parent.right
            }
            visible: active
            active: Config.options.sidebar.quickSliders.showVolume
            sourceComponent: QuickSlider {
                materialSymbol: "volume_up"
                showPercentInside: true
                // Optional chaining, like the rest of the shell: the audio service
                // has no sink for the first moments of a session (and none at all
                // on a machine with no output device), and `Audio.sink.audio`
                // threw "Cannot read property 'audio' of null" into the log on
                // every login because of it.
                value: Audio.sink?.audio?.volume ?? 0
                onMoved: {
                    if (Audio.sink?.audio)
                        Audio.sink.audio.volume = value
                }
            }
        }

        Loader {
            anchors {
                left: parent.left
                right: parent.right
            }
            visible: active
            active: Config.options.sidebar.quickSliders.showMic
            sourceComponent: QuickSlider {
                materialSymbol: "mic"
                // Same guard as the output slider above: `Audio.source` is null
                // whenever no capture node exists (or during PipeWire churn),
                // and the bare access threw TypeErrors that broke this slider.
                value: Audio.source?.audio?.volume ?? 0
                onMoved: {
                    if (Audio.source?.audio)
                        Audio.source.audio.volume = value
                }
            }
        }
    }

    component QuickSlider: StyledSlider { 
        id: quickSlider
        required property string materialSymbol
        property string secondaryMaterialSymbol
        /// Percentage label rendered INSIDE the track, on the filled (left) side
        /// next to the leading icon. Off by default; the volume slider turns it on.
        property bool showPercentInside: false
        configuration: StyledSlider.Configuration.M
        stopIndicatorValues: []
        dividerValues: secondaryMaterialSymbol.length > 0 ? [secondaryIcon.iconLocation] : []
        
        MaterialSymbol {
            id: icon
            property bool nearFull: quickSlider.value >= 0.9
            anchors {
                verticalCenter: quickSlider.verticalCenter
                right: nearFull ? quickSlider.handle.right : quickSlider.right
                rightMargin: nearFull ? 14 : 8
            }
            iconSize: 20
            color: nearFull ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSecondaryContainer
            text: quickSlider.materialSymbol

            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
            Behavior on anchors.rightMargin {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
        }

        // The percentage, inside the bar on its filled left side. Always
        // visible -- the user asked for the number at all times, not just
        // when the value is convenient -- so the color adapts instead of the
        // label hiding: on the accent fill it reads on-primary, and when the
        // fill has not reached it yet (quiet volume) it falls back to the
        // unfilled-track color. The 8px left inset mirrors the volume
        // icon's 8px right inset, so the row is symmetric.
        StyledText {
            visible: quickSlider.showPercentInside
            text: `${Math.round(quickSlider.value * 100)}%`
            font.pixelSize: Appearance.font.pixelSize.smaller
            anchors {
                verticalCenter: quickSlider.verticalCenter
                left: quickSlider.left
                leftMargin: 8
            }
            color: quickSlider.leftPadding + quickSlider.effectiveDraggingWidth * quickSlider.value
                >= anchors.leftMargin + implicitWidth + 6 ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSecondaryContainer
            opacity: 0.95
        }

        MaterialSymbol {
            id: secondaryIcon
            visible: secondaryMaterialSymbol.length > 0
            property real iconLocation: 0.3
            property bool nearIcon: iconLocation - quickSlider.value <= 0.1 && iconLocation - quickSlider.value > (quickSlider.handleWidth + 8 - 14) / quickSlider.effectiveDraggingWidth
            anchors {
                verticalCenter: quickSlider.verticalCenter
                right: nearIcon ? quickSlider.handle.right : quickSlider.right
                rightMargin: nearIcon ? 14 : (1 - iconLocation) * quickSlider.effectiveDraggingWidth + quickSlider.rightPadding + 8
            }
            iconSize: 20
            color: quickSlider.value >= iconLocation - 0.1 ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSecondaryContainer
            text: secondaryMaterialSymbol

            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
        }
    }
}
