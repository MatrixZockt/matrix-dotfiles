import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root
    property string protectionMessage: ""
    property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)

    property string currentIndicator: "volume"
    property var indicators: [
        {
            id: "volume",
            sourceUrl: "indicators/VolumeIndicator.qml"
        },
        {
            id: "brightness",
            sourceUrl: "indicators/BrightnessIndicator.qml"
        },
        {
            id: "gamma",
            sourceUrl: "indicators/GammaIndicator.qml"
        },
    ]

    function triggerOsd() {
        GlobalStates.osdVolumeOpen = true;
        osdTimeout.restart();
    }

    Timer {
        id: osdTimeout
        interval: Config.options.osd.timeout
        repeat: false
        running: false
        onTriggered: {
            GlobalStates.osdVolumeOpen = false;
            root.protectionMessage = "";
        }
    }

    Connections {
        target: Brightness
        function onBrightnessChanged() {
            // Brightness feedback rides the bar's indication line now (the
            // meter face, services/StatusSignal): the bar fills to the value
            // instead of a capsule dropping in. The floating OSD stays for
            // gamma only.
            root.protectionMessage = "";
            StatusSignal.meter("brightness", Brightness.brightnessFraction());
        }
    }

    Connections {
        target: Hyprsunset
        function onGammaChangeAttempt() {
            root.protectionMessage = "";
            root.currentIndicator = "gamma";
            root.triggerOsd();
        }
    }

    Connections {
        // Volume feedback rides the bar's indication line too (see the
        // brightness connection above).
        target: Audio.sink?.audio ?? null
        function onVolumeChanged() {
            if (!Audio.ready)
                return;
            StatusSignal.meter("volume", Audio.currentVolume());
        }
        function onMutedChanged() {
            if (!Audio.ready)
                return;
            StatusSignal.meter("volume", Audio.currentVolume());
        }
    }

    Connections {
        // Listen to protection triggers
        target: Audio
        function onSinkProtectionTriggered(reason) {
            root.protectionMessage = reason;
            root.currentIndicator = "volume";
            root.triggerOsd();
        }
    }

    Loader {
        id: osdLoader
        active: GlobalStates.osdVolumeOpen

        sourceComponent: PanelWindow {
            id: osdRoot
            color: "transparent"

            Connections {
                target: root
                function onFocusedScreenChanged() {
                    osdRoot.screen = root.focusedScreen;
                }
            }

            WlrLayershell.namespace: "quickshell:onScreenDisplay"
            WlrLayershell.layer: WlrLayer.Overlay
            anchors {
                top: !Config.options.bar.bottom
                bottom: Config.options.bar.bottom
            }
            mask: Region {
                item: osdValuesWrapper
            }

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            margins {
                top: Appearance.sizes.barHeight
                bottom: Appearance.sizes.barHeight
            }

            implicitWidth: columnLayout.implicitWidth
            implicitHeight: columnLayout.implicitHeight
            visible: osdLoader.active

            ColumnLayout {
                id: columnLayout
                anchors.horizontalCenter: parent.horizontalCenter

                Item {
                    id: osdValuesWrapper
                    // Extra space for shadow
                    implicitHeight: contentColumnLayout.implicitHeight
                    implicitWidth: contentColumnLayout.implicitWidth
                    clip: true

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: GlobalStates.osdVolumeOpen = false
                    }

                    Column {
                        id: contentColumnLayout
                        anchors {
                            top: parent.top
                            left: parent.left
                            right: parent.right
                        }
                        spacing: 0

                        Loader {
                            id: osdIndicatorLoader
                            source: root.indicators.find(i => i.id === root.currentIndicator)?.sourceUrl
                        }

                        Item {
                            id: protectionMessageWrapper
                            anchors.horizontalCenter: parent.horizontalCenter
                            implicitHeight: protectionMessageBackground.implicitHeight
                            implicitWidth: protectionMessageBackground.implicitWidth
                            opacity: root.protectionMessage !== "" ? 1 : 0

                            StyledRectangularShadow {
                                target: protectionMessageBackground
                            }
                            Rectangle {
                                id: protectionMessageBackground
                                anchors.centerIn: parent
                                color: Appearance.m3colors.m3error
                                property real padding: 10
                                implicitHeight: protectionMessageRowLayout.implicitHeight + padding * 2
                                implicitWidth: protectionMessageRowLayout.implicitWidth + padding * 2
                                radius: Appearance.rounding.normal

                                RowLayout {
                                    id: protectionMessageRowLayout
                                    anchors.centerIn: parent
                                    MaterialSymbol {
                                        id: protectionMessageIcon
                                        text: "dangerous"
                                        iconSize: Appearance.font.pixelSize.hugeass
                                        color: Appearance.m3colors.m3onError
                                    }
                                    StyledText {
                                        id: protectionMessageTextWidget
                                        horizontalAlignment: Text.AlignHCenter
                                        color: Appearance.m3colors.m3onError
                                        wrapMode: Text.Wrap
                                        text: root.protectionMessage
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Brief "copied" toast — top-right corner, shown when the clipboard gains new
    // content. Deliberately NOT routed through the notification service, so it never
    // enters the notification history, and it disappears on its own after a moment.
    //
    // NOTE: the icon is a MaterialSymbol rather than an Image. QtQuick's Image has no
    // `color` property, and assigning one made this whole file fail to compile, which
    // took the bar down with it.
    Loader {
        id: copyToastLoader
        active: Cliphist.copyToastVisible && !GlobalStates.screenLocked
        sourceComponent: PanelWindow {
            id: copyToastWindow
            color: "transparent"
            screen: root.focusedScreen
            WlrLayershell.namespace: "quickshell:copyToast"
            WlrLayershell.layer: WlrLayer.Overlay
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            anchors {
                right: true
                top: true
            }
            margins: {
                const m = Appearance.sizes.elevationMargin
                return { left: m, top: m + Appearance.sizes.barHeight, right: m, bottom: m }
            }
            implicitWidth: copyToastContent.implicitWidth + Appearance.sizes.elevationMargin * 2
            implicitHeight: copyToastContent.implicitHeight + Appearance.sizes.elevationMargin * 2
            visible: copyToastLoader.active

            HoverHandler {
                id: copyToastHover
            }
            Timer {
                interval: 1200
                running: Cliphist.copyToastVisible && !copyToastHover.hovered
                onTriggered: Cliphist.copyToastVisible = false
            }

            StyledRectangularShadow {
                target: copyToastContent
            }
            Rectangle {
                id: copyToastContent
                anchors.centerIn: parent
                implicitWidth: copyToastRow.implicitWidth + 22
                implicitHeight: copyToastRow.implicitHeight + 16
                radius: Appearance.rounding.full
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: Appearance.colors.colLayer0Border

                RowLayout {
                    id: copyToastRow
                    anchors.centerIn: parent
                    spacing: 8

                    MaterialSymbol {
                        text: "content_copy"
                        iconSize: Appearance.font.pixelSize.large
                        color: Appearance.colors.colOnLayer0
                    }

                    StyledText {
                        text: {
                            const t = (Cliphist.lastCopiedText || "").trim()
                            if (t.length === 0)
                                return Translation.tr("Copied")
                            return t.length > 40 ? t.slice(0, 37) + "..." : t
                        }
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer0
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "osdVolume"

        function trigger() {
            root.triggerOsd();
        }

        function hide() {
            GlobalStates.osdVolumeOpen = false;
        }

        function toggle() {
            GlobalStates.osdVolumeOpen = !GlobalStates.osdVolumeOpen;
        }
    }
    GlobalShortcut {
        name: "osdVolumeTrigger"
        description: "Triggers volume OSD on press"

        onPressed: {
            root.triggerOsd();
        }
    }
    GlobalShortcut {
        name: "osdVolumeHide"
        description: "Hides volume OSD on press"

        onPressed: {
            GlobalStates.osdVolumeOpen = false;
        }
    }
}
