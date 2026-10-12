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
 * The Wi-Fi popup app, opened by clicking the bar's Wi-Fi icon: a small
 * floating window over the blurred backdrop, holding the radio switch and the
 * networks you could switch to.
 *
 * This is the sibling of BluetoothPanel and VpnPanel -- same BarAnchoredPanel,
 * same header row, same "list plus the one switch that matters" shape. The
 * three read as one family because they are one thing: what the connectivity
 * icons in the pill open.
 *
 * The rows are the sidebar dialog's own `WifiNetworkItem`s, deliberately.
 * That component already carries the whole join flow -- the password field,
 * the in-flight spinner, the public-portal button -- so this panel adds no
 * second copy of it: a Wi-Fi network that needs a password is joined by
 * clicking the row and typing, here and in the sidebar alike. Pairing
 * management (forgetting, editing, 802.1X) stays in the settings app's
 * Network page, one click away via the header's tune button.
 *
 * Discovery is the SERVICE's job (`Network`), not this file's: the panel only
 * asks for a rescan when it opens, so the list it shows is a fresh one.
 */
BarAnchoredPanel {
    id: root

    contentWidth: 360

    onOpened: {
        // A rescan costs a few seconds of radio time, so it only happens when
        // there is a radio to scan with. With Wi-Fi off the list would be empty
        // anyway, and the switch below is what the panel is for at that point.
        if (Network.wifiEnabled)
            Network.rescanWifi();
    }

    // The joined network gets its own card at the top, like the sidebar dialog:
    // the row you care about is then a POSITION rather than a row that happens
    // to have a dot on it. Both halves are properties so the group can be
    // hidden outright when there is nothing in it -- an empty "Connected" card
    // reads as a failure.
    readonly property var activeNetwork: Network.friendlyWifiNetworks.find(n => n.active) ?? null
    readonly property var otherNetworks: Network.friendlyWifiNetworks.filter(n => !n.active)

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
                text: Network.materialSymbol
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

        // ── The radio ─────────────────────────────────────────────────────
        // The switch is the adapter, and it is driven one-way from the service
        // exactly like the VPN panel's: a click writes the switch, and the next
        // real state change rebuilds it, so a command that failed snaps back on
        // its own rather than leaving a switch lying about the radio.
        ConfigSwitch {
            id: wifiSwitch
            Layout.fillWidth: true
            iconSize: Appearance.font.pixelSize.larger
            buttonIcon: Network.wifiEnabled ? "wifi" : "wifi_off"
            text: Translation.tr("Wi-Fi")
            checked: Network.wifiEnabled
            onCheckedChanged: {
                // Only a press is a request; the builds are not.
                if (checked === Network.wifiEnabled) return;
                Network.enableWifi(checked);
            }
        }

        StyledIndeterminateProgressBar {
            visible: Network.wifiScanning
            Layout.fillWidth: true
        }

        // ── The network you are on ────────────────────────────────────────
        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 2
            visible: root.activeNetwork !== null
            text: Translation.tr("Connected")
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1
        }

        WifiNetworkItem {
            Layout.fillWidth: true
            visible: root.activeNetwork !== null
            wifiNetwork: root.activeNetwork
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 2
            text: Translation.tr("Available networks")
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1
        }

        StyledText {
            Layout.fillWidth: true
            visible: !Network.wifiEnabled
            text: Translation.tr("Wi-Fi is off.")
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
        }

        StyledText {
            Layout.fillWidth: true
            visible: Network.wifiEnabled && root.otherNetworks.length === 0 && !Network.wifiScanning
            text: Translation.tr("No other networks in range.")
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
        }

        // ── The rest of them: capped, scrollable ──────────────────────────
        StyledListView {
            id: networkList
            Layout.fillWidth: true
            visible: Network.wifiEnabled
            // `contentHeight` is undefined before the first layout pass; the
            // cap is what keeps a long list from stretching the card past the
            // base component's own height limit.
            Layout.preferredHeight: Math.min(contentHeight ?? 0, 320)
            clip: true
            spacing: 0
            animateAppearance: false

            model: ScriptModel {
                values: root.otherNetworks
            }
            delegate: WifiNetworkItem {
                required property WifiAccessPoint modelData
                wifiNetwork: modelData
                anchors.left: parent?.left
                anchors.right: parent?.right
            }
        }

        // ── Rescan ────────────────────────────────────────────────────────
        // Only while there is a radio to scan with. A rescan button under a
        // disabled switch is a control that can only fail.
        RippleButton {
            Layout.fillWidth: true
            Layout.topMargin: 2
            visible: Network.wifiEnabled
            enabled: !Network.wifiScanning
            implicitHeight: 38
            buttonRadius: Appearance.rounding.normal
            colBackground: Appearance.colors.colLayer1
            colBackgroundHover: Appearance.colors.colLayer1Hover
            onClicked: Network.rescanWifi()
            contentItem: StyledText {
                anchors.centerIn: parent
                text: Network.wifiScanning
                    ? Translation.tr("Scanning…")
                    : Translation.tr("Rescan")
                color: Appearance.colors.colOnLayer1
                font.pixelSize: Appearance.font.pixelSize.small
            }
        }
    }
}
