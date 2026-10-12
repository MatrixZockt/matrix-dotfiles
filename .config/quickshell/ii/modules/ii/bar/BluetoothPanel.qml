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
        // Discovery only when there is a radio to discover with. Opening a
        // panel must not switch Bluetooth ON: a card you looked at is not a
        // request to change a radio, which is why the Wi-Fi panel states its
        // adapter as a switch and does not flip it on arrival either.
        if (BluetoothStatus.enabled)
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
                text: BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
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

        // ── The radio ─────────────────────────────────────────────────────
        // The switch the panel used to do without (it just switched the
        // adapter on for you). One-way from the service, exactly like the
        // Wi-Fi panel's: a click is a request, a rebuild is the truth.
        ConfigSwitch {
            id: bluetoothSwitch
            Layout.fillWidth: true
            iconSize: Appearance.font.pixelSize.larger
            buttonIcon: BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
            text: Translation.tr("Bluetooth")
            enabled: Bluetooth.defaultAdapter !== null
            checked: BluetoothStatus.enabled
            onCheckedChanged: {
                if (checked === BluetoothStatus.enabled) return;
                if (!Bluetooth.defaultAdapter) return;
                Bluetooth.defaultAdapter.enabled = checked;
                // Leaving discovery running on a radio you just turned off is
                // the one state the adapter cannot actually hold.
                if (!checked)
                    Bluetooth.defaultAdapter.discovering = false;
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: !BluetoothStatus.enabled
            text: Translation.tr("Bluetooth is off.")
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
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
            // A list of paired devices under a radio that is off can only be
            // stale, and the "off" line above already says why it is empty.
            visible: BluetoothStatus.enabled
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
