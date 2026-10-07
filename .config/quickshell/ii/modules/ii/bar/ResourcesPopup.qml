import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.widgets as W
import qs.services
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../../common/widgets" as W2

StyledPopup {
    id: root

    // Helper function to format KB to GB
    function formatKB(kb) {
        return (kb / (1024 * 1024)).toFixed(1) + " GB";
    }

    // One wrapper child: the hardware readouts row PLUS the Razer quick
    // controls below it, so the popup's implicit size covers both.
    Column {
        id: rootColumn
        spacing: 14

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 12

        Column {
            anchors.top: parent.top
            spacing: 8

            StyledPopupHeaderRow {
                icon: "memory"
                label: "RAM"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "clock_loader_60"
                    label: Translation.tr("Used:")
                    value: root.formatKB(ResourceUsage.memoryUsed)
                }
                StyledPopupValueRow {
                    icon: "check_circle"
                    label: Translation.tr("Free:")
                    value: root.formatKB(ResourceUsage.memoryFree)
                }
                StyledPopupValueRow {
                    icon: "empty_dashboard"
                    label: Translation.tr("Total:")
                    value: root.formatKB(ResourceUsage.memoryTotal)
                }
            }
        }

        Column {
            visible: ResourceUsage.swapTotal > 0
            anchors.top: parent.top
            spacing: 8

            StyledPopupHeaderRow {
                icon: "swap_horiz"
                label: "Swap"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "clock_loader_60"
                    label: Translation.tr("Used:")
                    value: root.formatKB(ResourceUsage.swapUsed)
                }
                StyledPopupValueRow {
                    icon: "check_circle"
                    label: Translation.tr("Free:")
                    value: root.formatKB(ResourceUsage.swapFree)
                }
                StyledPopupValueRow {
                    icon: "empty_dashboard"
                    label: Translation.tr("Total:")
                    value: root.formatKB(ResourceUsage.swapTotal)
                }
            }
        }

        Column {
            anchors.top: parent.top
            spacing: 8

            StyledPopupHeaderRow {
                icon: "planner_review"
                label: "CPU"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "bolt"
                    label: Translation.tr("Load:")
                    value: `${Math.round(ResourceUsage.cpuUsage * 100)}%`
                }
            }
        }
    }

    // ── Razer Command Center quick controls ──────────────────────────────
    // Power profile (3 graphical buttons), keyboard light switch, keyboard
    // brightness slider. Every action goes through the app's headless CLI.
    ColumnLayout {
        Layout.fillWidth: false
        width: rootColumn.width
        spacing: 12

        Rectangle { Layout.fillWidth: true; height: 1; color: Appearance.colors.colOutlineVariant }

        // Power profile: three chips with custom-drawn icons.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            W.MaterialSymbol {
                text: "speed"
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Power mode")
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: RazerService.powerProfiles
                delegate: Rectangle {
                    id: pchip
                    required property var modelData
                    required property int index
                    readonly property bool isActive: RazerService.powerProfile === modelData.value
                    Layout.fillWidth: true
                    implicitHeight: 48
                    radius: 12
                    color: isActive
                        ? ColorUtils.applyAlpha(modelData.color, 0.22)
                        : Appearance.colors.colLayer1
                    border.width: 1
                    border.color: isActive ? modelData.color : Appearance.colors.colOutlineVariant
                    Column {
                        anchors.centerIn: parent
                        spacing: 3
                        W2.ModeIcon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            mode: pchip.modelData.value
                            iconColor: isActive ? pchip.modelData.color : Appearance.colors.colSubtext
                            size: 22
                        }
                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: pchip.modelData.name
                            font.pixelSize: Appearance.font.pixelSize.tiny
                            color: isActive ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
                        }
                    }
                    TapHandler {
                        onTapped: RazerService.setPowerProfile(pchip.modelData.value)
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Appearance.colors.colOutlineVariant }

        // Keyboard light: simple on/off + brightness.
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            W.MaterialSymbol {
                text: "keyboard_keys"
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Keyboard light")
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }
            Switch {
                checked: RazerService.kbdLightOn
                onToggled: RazerService.setKbdLight(checked)
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            W.MaterialSymbol {
                text: RazerService.kbdLightOn ? "brightness_6" : "brightness_empty"
                color: Appearance.colors.colSubtext
            }
            StyledSlider {
                Layout.fillWidth: true
                configuration: StyledSlider.Configuration.S
                from: 0
                to: 100
                value: RazerService.kbdBrightness
                enabled: RazerService.kbdLightOn
                onMoved: RazerService.setKbdBrightness(value)
            }
            StyledText {
                text: `${RazerService.kbdBrightness}%`
                font.pixelSize: Appearance.font.pixelSize.tiny
                color: Appearance.colors.colSubtext
            }
        }
    }
    }
}
