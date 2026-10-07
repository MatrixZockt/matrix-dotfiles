import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.sidebarRight.bluetoothDevices
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth

/**
 * The Bluetooth popup app, opened by clicking the bar's bluetooth icon: a
 * small floating window over the blurred backdrop, with the device list the
 * sidebar's dialog used to hold. Reuses the same BluetoothDeviceItem rows.
 * Discovery runs only while the app is open.
 */
BarAnchoredPanel {
    id: root

    contentWidth: 360

    onOpened: {
        Bluetooth.defaultAdapter.enabled = true;
        Bluetooth.defaultAdapter.discovering = true;
    }

    // See WifiPanel: the quick menu lists and connects; pairing management and
    // the adapter toggles live in the settings app's Network page.
    function openFullSettings() {
        root.close();
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/launch/settings.sh"), "network", "bluetooth"]);
    }
    // Discovery runs only while the app is up. Via Connections (not an inline
    // onOpenChanged) so the base component's own open handling still runs.
    Connections {
        target: root
        function onOpenChanged() {
            if (!root.open && (Bluetooth.defaultAdapter?.discovering ?? false))
                Bluetooth.defaultAdapter.discovering = false;
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        // ── Header ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: "bluetooth"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Bluetooth devices")
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
            visible: Bluetooth.defaultAdapter?.discovering ?? false
            Layout.fillWidth: true
        }

        // Recent devices: the adapter has forgotten, the shell has not.
        // Shared with the sidebar dialog and the settings network page --
        // three screens list bluetooth devices and a history that showed up in
        // only one of them would be the same bug in a different place.
        BluetoothRecentSection {}

        // ── Device list: capped, scrollable ──────────────────────────────
        StyledListView {
            id: deviceList
            Layout.fillWidth: true
            // See WifiPanel: undefined before the first layout pass.
            Layout.preferredHeight: Math.min(contentHeight ?? 0, 320)
            clip: true
            spacing: 0

            model: ScriptModel {
                values: BluetoothStatus.friendlyDeviceList
            }
            delegate: BluetoothDeviceItem {
                required property BluetoothDevice modelData
                device: modelData
                anchors.left: parent?.left
                anchors.right: parent?.right
            }
        }
    }
}
