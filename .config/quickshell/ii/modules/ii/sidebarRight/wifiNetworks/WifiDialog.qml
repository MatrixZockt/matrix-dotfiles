import qs
import qs.services
import qs.services.network
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell

/**
 * "Connect to Wi-Fi".
 *
 * Rebuilt as two groups rather than one flat list. The old list was a single
 * full-bleed column sorted by signal strength with the joined network pinned
 * to the top, which meant the row you actually care about was distinguished
 * only by a `check` glyph -- the same glyph that marks a lock on every other
 * row. Splitting "the one you are on" out into its own card makes the
 * connection state a POSITION, and leaves the second card to be a clean list
 * of everything you could switch to.
 */
WindowDialog {
    id: root
    backgroundHeight: 600

    // The joined network, if any. A property rather than a filter inside the
    // model so the group can be hidden outright when there is nothing to show
    // -- an empty "Connected" card is worse than no card.
    readonly property var activeNetwork: Network.friendlyWifiNetworks.find(n => n.active) ?? null

    WindowDialogTitle {
        text: Translation.tr("Connect to Wi-Fi")
    }
    WindowDialogSeparator {
        visible: !Network.wifiScanning
    }
    StyledIndeterminateProgressBar {
        visible: Network.wifiScanning
        Layout.fillWidth: true
        Layout.topMargin: -8
        Layout.bottomMargin: -8
        Layout.leftMargin: -Appearance.rounding.large
        Layout.rightMargin: -Appearance.rounding.large
    }

    DialogListGroup {
        title: Translation.tr("Connected")
        visible: root.activeNetwork !== null

        WifiNetworkItem {
            Layout.fillWidth: true
            wifiNetwork: root.activeNetwork
        }
    }

    DialogListGroup {
        title: Translation.tr("Available networks")
        // This is the group that scrolls, so it takes whatever height the
        // dialog has left over.
        stretches: true

        StyledListView {
            id: availableList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 0
            animateAppearance: false

            model: ScriptModel {
                values: Network.friendlyWifiNetworks.filter(n => !n.active)
            }
            delegate: WifiNetworkItem {
                required property WifiAccessPoint modelData
                wifiNetwork: modelData
                width: ListView.view.width
            }
        }
    }

    WindowDialogSeparator {}
    WindowDialogButtonRow {
        DialogButton {
            buttonText: Translation.tr("Details")
            onClicked: {
                Quickshell.execDetached(["bash", "-c", `${Network.ethernet ? Config.options.apps.networkEthernet : Config.options.apps.network}`]);
                GlobalStates.sidebarRightOpen = false;
            }
        }

        Item {
            Layout.fillWidth: true
        }

        DialogButton {
            buttonText: Translation.tr("Done")
            onClicked: root.dismiss()
        }
    }
}
