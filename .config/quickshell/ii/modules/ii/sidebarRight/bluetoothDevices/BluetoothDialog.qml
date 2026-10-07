import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.sidebarRight.bluetoothDevices
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * "Bluetooth devices".
 *
 * Same two-group treatment as the Wi-Fi dialog: the devices you have actually
 * paired get a card, and the ones the adapter is merely overhearing get
 * another. The old dialog listed connected, paired and unpaired devices in one
 * continuous column in exactly that order, which meant the boundary between
 * "mine" and "someone else's" was a position you had to count to.
 */
WindowDialog {
    id: root
    backgroundHeight: 600

    // Split off the paired half of `friendlyDeviceList` rather than filtering
    // the whole list twice: the service already builds it in exactly this
    // order, so the two views are the two halves of one sorted list.
    readonly property var pairedDevices: BluetoothStatus.friendlyDeviceList
        .filter(d => (d?.paired || d?.connected) ?? false)
    readonly property var nearbyDevices: BluetoothStatus.friendlyDeviceList
        .filter(d => !((d?.paired || d?.connected) ?? false))

    WindowDialogTitle {
        text: Translation.tr("Bluetooth devices")
    }
    WindowDialogSeparator {
        visible: !(Bluetooth.defaultAdapter?.discovering ?? false)
            && root.pairedDevices.length === 0
            && BluetoothStatus.recentDevices.length === 0
    }
    StyledIndeterminateProgressBar {
        visible: Bluetooth.defaultAdapter?.discovering ?? false
        Layout.fillWidth: true
        Layout.topMargin: -8
        Layout.bottomMargin: -8
        Layout.leftMargin: -Appearance.rounding.large
        Layout.rightMargin: -Appearance.rounding.large
    }

    // Devices the adapter has forgotten but the shell has not. Above the live
    // list, because a device you actually use should not have to compete with
    // whatever the adapter happens to be hearing right now. It keeps its own
    // component -- three screens list bluetooth devices and the history has to
    // appear in all of them -- but it is now a card like everything else here.
    BluetoothRecentSection {
        Layout.fillWidth: true
    }

    DialogListGroup {
        title: Translation.tr("Paired devices")
        visible: root.pairedDevices.length > 0

        Repeater {
            model: root.pairedDevices
            delegate: BluetoothDeviceItem {
                required property var modelData
                device: modelData
                Layout.fillWidth: true
            }
        }
    }

    DialogListGroup {
        title: Bluetooth.defaultAdapter?.discovering ?? false
            ? Translation.tr("Discovering")
            : Translation.tr("Nearby")
        // This is the group that scrolls, so it takes whatever height the
        // dialog has left over.
        stretches: true

        StyledListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 0
            animateAppearance: false

            model: ScriptModel {
                values: root.nearbyDevices
            }
            delegate: BluetoothDeviceItem {
                required property var modelData
                device: modelData
                width: ListView.view.width
            }
        }
    }

    WindowDialogSeparator {}
    WindowDialogButtonRow {
        DialogButton {
            buttonText: Translation.tr("Details")
            onClicked: {
                Quickshell.execDetached(["bash", "-c", `${Config.options.apps.bluetooth}`]);
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
