import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell

/**
 * The devices this shell has connected to before that the adapter is not
 * currently listing.
 *
 * Wi-Fi gets this for free. nmcli keeps every saved network in its own config,
 * so a network joined last month is still listable and still joinable in one
 * click. Bluetooth has no such thing: the device list is only what the adapter
 * currently knows, and for anything out of range that is nothing. So a device
 * you paired once simply disappears, and the only way back is to hunt for it
 * with discovery and hope it answers.
 *
 * That is this memory, and it lives in one component because three different
 * screens list bluetooth devices -- the sidebar dialog, the settings app's
 * network page, and the bar's quick panel. A history that only showed up in
 * one of them would be the same bug in a different place.
 *
 * It is a `DialogListGroup` like the two live groups below it, so the three
 * read as one dialog rather than three widgets that happen to be stacked. It
 * is `visible: false` when there is nothing remembered, so a machine that has
 * never connected anything shows exactly the list it always did.
 */
DialogListGroup {
    id: root

    title: Translation.tr("Recent")
    visible: BluetoothStatus.recentDevices.length > 0

    Repeater {
        model: BluetoothStatus.recentDevices
        delegate: RippleButton {
            id: recentRow
            required property var modelData

            Layout.fillWidth: true
            Layout.preferredHeight: 46
            buttonRadius: Appearance.rounding.normal
            colBackground: "transparent"
            colBackgroundHover: Appearance.colors.colLayer3Hover
            onClicked: BluetoothStatus.connectRemembered(recentRow.modelData)

            contentItem: RowLayout {
                spacing: 16

                MaterialSymbol {
                    text: "history"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    Layout.fillWidth: true
                    // A remembered device often has no name cached -- only the
                    // address -- so the MAC is shown rather than an empty row.
                    text: recentRow.modelData?.name
                        || recentRow.modelData?.mac
                        || ""
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnSurfaceVariant
                    elide: Text.ElideRight
                }
                StyledText {
                    // While we are hunting for it, say so: the click looks like
                    // it did nothing otherwise, because nothing happens on the
                    // row until discovery actually turns the device up.
                    text: BluetoothStatus.pendingMac === recentRow.modelData?.mac
                        ? Translation.tr("Searching…")
                        : Translation.tr("Reconnect")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
            }
        }
    }
}
