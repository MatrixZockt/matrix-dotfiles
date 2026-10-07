import qs
import qs.services
import qs.services.network
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.sidebarRight.wifiNetworks
import QtQuick
import QtQuick.Layouts
import Quickshell

/**
 * The Wi-Fi popup app, opened by clicking the bar's network icon: a small
 * floating window over the blurred backdrop, with the network list the
 * sidebar's dialog used to hold. Reuses the same WifiNetworkItem rows, so
 * joining (including password prompts) behaves exactly as there.
 */
BarAnchoredPanel {
    id: root

    contentWidth: 360

    onOpened: {
        Network.enableWifi();
        Network.rescanWifi();
    }

    // The whole Network page of the settings app, for the things a quick menu
    // should not try to hold: the adapter toggle, the Bluetooth device list,
    // pairing. Closes the popup first so the two do not overlap.
    function openFullSettings() {
        root.close();
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/launch/settings.sh"), "network", "wifi"]);
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        // ── Header ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: "wifi"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Wi-Fi")
                font.pixelSize: Appearance.font.pixelSize.title
                color: Appearance.colors.colOnLayer0
            }
            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: root.openFullSettings()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "tune"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer0
                }
                StyledToolTip {
                    text: Translation.tr("Open network settings")
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

        StyledIndeterminateProgressBar {
            visible: Network.wifiScanning
            Layout.fillWidth: true
        }

        // ── Network list: capped, scrollable, and never fighting the card's
        // own scroll: the card is tall enough for the list's 320 cap, so the
        // outer scroll only ever matters for the header. ────────────────────
        StyledListView {
            id: wifiList
            Layout.fillWidth: true
            // `?? 0`: before the first layout pass contentHeight is undefined,
            // and Math.min(undefined, 320) assigns undefined to an int width
            // property (a warning per open for no reason).
            Layout.preferredHeight: Math.min(contentHeight ?? 0, 320)
            clip: true
            spacing: 0

            model: ScriptModel {
                values: Network.friendlyWifiNetworks
            }
            delegate: WifiNetworkItem {
                required property WifiAccessPoint modelData
                wifiNetwork: modelData
                width: ListView.view.width
            }
        }
    }
}
