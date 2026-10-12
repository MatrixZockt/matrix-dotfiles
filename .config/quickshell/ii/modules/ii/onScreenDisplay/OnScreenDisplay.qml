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
        {
            id: "performanceMode",
            sourceUrl: "indicators/PerformanceModeIndicator.qml"
        },
    ]

    function triggerOsd() {
        GlobalStates.osdVolumeOpen = true;
        // The mode notice is a small table, not a bar: four measurements to
        // read, and the two slowest are hardware -- the graphics ceiling and
        // the CPU package cap, which follow a switch by 90-400 ms and
        // 390-650 ms respectively (measured 2026-10-12; the cap used to take
        // 3.0-5.3 s before a switch asked power-autoswitch to converge). The
        // card re-reads over that stretch -- its own schedule runs to 4.5 s --
        // so it has to still be on screen afterwards to be read: the
        // configured time plus enough for the last values to land and be
        // looked at. A volume step is glanced at; this is read. Assigned
        // rather than bound, because the value now depends on WHICH indicator
        // is showing.
        osdTimeout.interval = Config.options.osd.timeout
            + (root.currentIndicator === "performanceMode" ? 4000 : 0);
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

    Connections {
        // A power-mode switch, announced.
        //
        // Reported from PowerMode's own record of the change rather than from
        // whichever control made it (the island's three buttons, the settings
        // page, an edit of config.json): the service is the one place all of
        // them pass through, and it is also the only place that still knows
        // what the machine was on a moment before (see PowerMode.lastChange
        // and changeSeq).
        target: PowerMode
        function onChangeSeqChanged() {
            root.currentIndicator = "performanceMode";
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

    // Brief "copied" toast — bottom-right, shown when the clipboard gains content
    // from somewhere other than the shell itself. Deliberately NOT routed through
    // the notification service, so it never enters the notification history.
    //
    // WHERE. Bottom-right, and the margin accounts for the bar rather than assuming
    // an edge: the bar IS at the bottom on this desktop (waffles.bar.bottom), and
    // this card used to anchor to the TOP with the bar's height folded into its top
    // margin -- space reserved for a bar that is not there, on the edge the card
    // was not on. Both layouts are handled, so the file is right either way.
    //
    // HOW LONG. This is the only owner of the card's lifetime: fade in, hold, fade
    // out, then tell the service it is finished. There used to be a timer here and
    // another in the service (1200 ms against 1500 ms), each with its own idea of
    // when the card was over. Hovering pauses the sequence where it stands -- the
    // card waits for the eyes that are on it -- and a NEW copy while it is up
    // restarts it instead of being swallowed, which is what `copyToastSeq` is for.
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
                bottom: true
            }
            // The GROUP form (`margins.right:`), NOT `margins: { ... }`. Assigning a
            // JS object to a value type is rejected at load -- "Unable to assign
            // QJSValue to Margins" -- and the margins then stay at ZERO, which is how
            // this card ended up welded into the corner with no breathing room on
            // either anchored edge. ReloadPopup.qml spells it this way for the same
            // reason, and a probe confirmed the group form moves the window.
            //
            // The bar's side comes from `Config.options.bar.bottom` -- the LIVE bar
            // setting. This read `waffles.bar.bottom`, which is the OTHER look's bar
            // option and is true, so the card reserved space on an edge with no bar
            // on it (the bar is at the top on this desktop, verified against the
            // compositor) and floated a bar-height too high.
            margins.left: Appearance.sizes.elevationMargin
            margins.top: Appearance.sizes.elevationMargin
            margins.right: Appearance.sizes.elevationMargin
            margins.bottom: Appearance.sizes.elevationMargin
                + (Config.options?.bar?.bottom === true ? Appearance.sizes.barHeight : 0)
            implicitWidth: copyToastContent.implicitWidth + Appearance.sizes.elevationMargin * 2
            implicitHeight: copyToastContent.implicitHeight + Appearance.sizes.elevationMargin * 2
            visible: copyToastLoader.active

            HoverHandler {
                id: copyToastHover
                onHoveredChanged: hovered ? copyToastLife.pause() : copyToastLife.resume()
            }

            // The card's whole life in one place: in, hold, out, done. The hold is
            // the only number here that is a judgement call (how long a glance
            // takes); the two fades come from the theme so the card moves with the
            // rest of the shell rather than beside it.
            SequentialAnimation {
                id: copyToastLife
                NumberAnimation {
                    target: copyToastContent
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: Appearance.animation.elementMoveFast.duration
                    easing.type: Appearance.animation.elementMoveFast.type
                    easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                }
                PauseAnimation { duration: 900 }
                NumberAnimation {
                    target: copyToastContent
                    property: "opacity"
                    to: 0
                    duration: Appearance.animation.elementMoveExit.duration
                    easing.type: Appearance.animation.elementMoveExit.type
                    easing.bezierCurve: Appearance.animation.elementMoveExit.bezierCurve
                }
                ScriptAction { script: Cliphist.copyToastVisible = false }
            }

            Connections {
                target: Cliphist
                function onCopyToastSeqChanged() { copyToastLife.restart() }
            }

            Component.onCompleted: copyToastLife.restart()

            StyledRectangularShadow {
                target: copyToastContent
            }
            Rectangle {
                id: copyToastContent
                anchors.centerIn: parent
                implicitWidth: copyToastRow.implicitWidth + 18
                implicitHeight: copyToastRow.implicitHeight + 12
                // NOT the pill the volume/brightness card wears (`full`): asked
                // for as "less rounded". A rounded rectangle at 10 px on a card
                // this tall still reads as the same family of card without
                // being a capsule.
                radius: Appearance.rounding.large
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: Appearance.colors.colLayer0Border
                // A hair of scale as it arrives, so the card reads as landing
                // rather than switching on. Opacity alone reads as a fade of
                // something that was already there.
                scale: 0.96
                Component.onCompleted: scale = 1
                Behavior on scale {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }

                RowLayout {
                    id: copyToastRow
                    anchors.centerIn: parent
                    spacing: 6

                    MaterialSymbol {
                        text: "content_copy"
                        iconSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer0
                    }

                    StyledText {
                        text: {
                            const t = (Cliphist.lastCopiedText || "").trim()
                            return t.length === 0 ? Translation.tr("Copied") : t
                        }
                        // One step up from `smallie` (13 -> 15), which is also
                        // the size the icon beside it already draws at -- so the
                        // pair stays level instead of the words looking pinned
                        // to a bigger glyph.
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer0
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "osdVolume"

        // Which indicator is up, and whether the OSD is up at all -- the same
        // "read it without a pointer" affordance the services keep, because a
        // card that failed to load and a card nobody triggered look identical
        // in a screenshot of the rest of the screen.
        function state(): string {
            return `indicator=${root.currentIndicator} open=${GlobalStates.osdVolumeOpen} timeout=${osdTimeout.interval}`;
        }

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
