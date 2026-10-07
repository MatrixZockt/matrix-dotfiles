import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * The battery's attached panel, opened by clicking the bar indicator: a
 * standalone window pinned under the icon (an "attached desktop app"), with
 * the full detail set -- charge in Wh, live wattage in or out, time to
 * full / remaining life, wear, cycles, and the firmware charge-cap note.
 *
 * Sizing: the card is width-fixed and HEIGHT-CAPPED with a scrollbar. The
 * first cut sized the card from its content, and the popup grew past the
 * space between bar and screen edge -- the bottom rows were clipped. The
 * cap here comes from the anchor window's height, so the panel can never
 * exceed the space under the bar.
 */
BarAnchoredPanel {
    id: root

    contentWidth: 300

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        // ── Header ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: "battery_full"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Battery")
                // `title` (22px), not `headline`: this Appearance has no
                // `headline` token, and the undefined value it produced was the
                // "Unable to assign [undefined] to int" warning on every open.
                font.pixelSize: Appearance.font.pixelSize.title
                color: Appearance.colors.colOnLayer0
            }
            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                buttonRadius: height / 2
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

        // ── Body: capped, scrollable -- every row reachable ──────────────
        // StyledScrollView: the shell's kinetic physics (smooth wheel glide,
        // flick momentum) instead of raw ScrollView's stepped scrolling.
        StyledScrollView {
            id: bodyScroll
            Layout.fillWidth: true
            implicitHeight: Math.min(bodyColumn.implicitHeight, 340)
            contentHeight: bodyColumn.implicitHeight

            ColumnLayout {
                id: bodyColumn
                width: parent.width
                spacing: 6

                StyledPopupValueRow {
                    Layout.fillWidth: true
                    icon: "battery_5_bar"
                    label: Translation.tr("Charge:")
                    value: `${Math.round(Battery.percentage * 100)}% · ${Battery.energy.toFixed(1)} / ${Battery.energyCapacity.toFixed(1)} Wh`
                }
                StyledPopupValueRow {
                    Layout.fillWidth: true
                    icon: "sync"
                    label: Translation.tr("Status:")
                    value: {
                        switch (Battery.chargeState) {
                        case 1: return Translation.tr("Charging");
                        case 2: return Translation.tr("Discharging");
                        case 4: return Translation.tr("Full");
                        case 5: return Translation.tr("Waiting to charge");
                        case 6: return Translation.tr("Not charging");
                        default: return Translation.tr("Unknown");
                        }
                    }
                }
                StyledPopupValueRow {
                    Layout.fillWidth: true
                    visible: Battery.energyRate > 0.01 && Battery.chargeState !== 4
                    icon: "bolt"
                    label: Battery.isCharging ? Translation.tr("Charging at:") : Translation.tr("Consuming:")
                    value: `${Battery.energyRate.toFixed(2)} W`
                }
                StyledPopupValueRow {
                    Layout.fillWidth: true
                    visible: Battery.isCharging && Battery.timeToFull > 0
                    icon: "schedule"
                    label: Translation.tr("Full in:")
                    value: root.formatTime(Battery.timeToFull)
                }
                StyledPopupValueRow {
                    Layout.fillWidth: true
                    visible: !Battery.isCharging && Battery.chargeState !== 4 && Battery.timeToEmpty > 0
                    icon: "hourglass_bottom"
                    label: Translation.tr("Battery life:")
                    value: root.formatTime(Battery.timeToEmpty)
                }
                StyledPopupValueRow {
                    Layout.fillWidth: true
                    icon: "heart_check"
                    label: Translation.tr("Health:")
                    value: `${Battery.health.toFixed(1)}%` + (Battery.energyDesign > 0 ? ` · ${Battery.energyDesign.toFixed(1)} Wh design` : "")
                }
                StyledPopupValueRow {
                    Layout.fillWidth: true
                    visible: Battery.cycles >= 0
                    icon: "cyclone"
                    label: Translation.tr("Cycles:")
                    value: `${Battery.cycles}`
                }
                StyledPopupValueRow {
                    Layout.fillWidth: true
                    visible: Battery.isPluggedIn && !Battery.isCharging && Battery.percentage <= 0.55
                    icon: "battery_saver"
                    label: Translation.tr("Charge limit:")
                    value: Translation.tr("On (UEFI)")
                }
            }
        }
    }

    function formatTime(seconds) {
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        return h > 0 ? `${h}h ${m.toString().padStart(2, "0")}m` : `${m}m`;
    }
}
