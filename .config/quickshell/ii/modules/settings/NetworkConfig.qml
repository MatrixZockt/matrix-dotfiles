import qs
import qs.services
import qs.services.network
import qs.modules.common
import qs.modules.common.widgets
// The dotted form, not a relative path. Note that these two directories needed
// a `qmldir` to be importable at all: Quickshell resolves `qs.modules...` by
// looking for one, and without it the import silently yielded no types and the
// page came up blank. See the qmldir in each of those directories.
import qs.modules.ii.sidebarRight.wifiNetworks
import qs.modules.ii.sidebarRight.bluetoothDevices
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth


/**
 * Networking, in full.
 *
 * The bar's Wi-Fi and Bluetooth icons used to open a small popup holding
 * nothing but a list of names. That is enough to join a network you already
 * know and nothing else: no adapter toggle, no rescan, no way to see what the
 * radio is actually doing. This page is the same content the popup showed,
 * with the controls around it that make it a real settings page -- and the
 * popup now opens this page instead.
 *
 * Both lists reuse the exact same row components the rest of the shell uses
 * (`WifiNetworkItem`, `BluetoothDeviceItem`), so joining a network, entering a
 * password, pairing a device and forgetting one all behave identically here and
 * everywhere else. Nothing about the networking logic lives in this file.
 *
 * The two radios are tabs rather than one long page: they are two switches that
 * are never both being adjusted at once, and the bar's icons open this page on
 * whichever tab you clicked (`QS_SETTINGS_SECTION`, set by the bar).
 */
ContentPage {
    id: root
    forceWidth: true

    readonly property var sections: [
        { key: "wifi", name: Translation.tr("Wi-Fi"), icon: "wifi" },
        { key: "bluetooth", name: Translation.tr("Bluetooth"), icon: "bluetooth" }
    ]

    // Which tab is open. Where it starts comes from whoever opened the app: the
    // bar's Wi-Fi icon asks for the Wi-Fi tab, its Bluetooth icon for the
    // Bluetooth tab, and a plain "Network" from the rail gets Wi-Fi, because a
    // machine here without Wi-Fi is the rarer case (services/SettingsNav).
    property string section: root.sections.some(entry => entry.key === SettingsNav.requestedSection)
        ? SettingsNav.requestedSection
        : "wifi"

    // ...and it can change while the page is on screen. Clicking the bar's
    // Bluetooth icon with this page already open walks it from the Wi-Fi tab to
    // the Bluetooth one instead of starting a second copy of the app, so the
    // request has to be able to arrive at any time -- see SettingsNav and
    // scripts/launch/settings.sh. A signal, not a binding: the request can name
    // the tab that is already showing, and no property change would say so.
    Connections {
        target: SettingsNav
        function onSectionRequested(section) {
            if (root.sections.some(entry => entry.key === section))
                root.section = section;
        }
    }

    // Ask for fresh lists as the page opens.
    //
    // Not belt-and-braces: the collector that fills `Network.wifiNetworks`
    // starts with the service, and in the settings app -- a separate Quickshell
    // process from the desktop shell -- that first run is not enough on its own
    // (the list came up empty until a scan was requested, which is what the old
    // Wi-Fi popup did in its own onOpened for the same reason). Asking for a
    // rescan both refreshes the list and restarts the collector.
    Component.onCompleted: {
        if (!Network.wifiEnabled)
            Network.enableWifi();
        Network.rescanWifi();
        root.syncRadios();
    }

    // Discovery is expensive, so it is only on while the Bluetooth tab is the
    // one being looked at -- the same rule the Bluetooth popup used, moved from
    // "the page is open" to "the tab is open".
    onSectionChanged: root.syncRadios()
    function syncRadios() {
        const wanted = root.section === "bluetooth";
        if (Bluetooth.defaultAdapter === null)
            return;
        if (wanted && !BluetoothStatus.enabled)
            Bluetooth.defaultAdapter.enabled = true;
        Bluetooth.defaultAdapter.discovering = wanted;
    }
    Component.onDestruction: {
        if (Bluetooth.defaultAdapter?.discovering ?? false)
            Bluetooth.defaultAdapter.discovering = false;
    }

    // ── Tabs ─────────────────────────────────────────────────────────────
    // A segmented control, not two links: both options are always visible, so
    // "where is the Bluetooth list" is answered by looking rather than by
    // remembering that it used to be further down the page.
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 44
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer1

        RowLayout {
            anchors {
                fill: parent
                margins: 4
            }
            spacing: 4

            Repeater {
                model: root.sections
                delegate: RippleButton {
                    id: tab
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    buttonRadius: Appearance.rounding.verysmall
                    colBackground: "transparent"
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    colBackgroundToggled: Appearance.colors.colSecondaryContainer
                    colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
                    toggled: root.section === tab.modelData.key
                    onClicked: root.section = tab.modelData.key

                    contentItem: RowLayout {
                        anchors.centerIn: parent
                        spacing: 8

                        MaterialSymbol {
                            text: tab.modelData.icon
                            iconSize: 17
                            color: tab.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            text: tab.modelData.name
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: tab.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                    }
                }
            }
        }
    }


    // ── Wi-Fi ────────────────────────────────────────────────────────────
    ContentSection {
        visible: root.section === "wifi"
        icon: "wifi"
        title: Translation.tr("Wi-Fi")

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ConfigSwitch {
                buttonIcon: "wifi"
                text: Translation.tr("Wi-Fi")
                checked: Network.wifiEnabled
                onCheckedChanged: {
                    if (Network.wifiEnabled !== checked)
                        Network.enableWifi(checked);
                }
            }

            RippleButton {
                Layout.fillWidth: false
                implicitWidth: 40
                implicitHeight: 40
                buttonRadius: Appearance.rounding.small
                colBackground: Appearance.colors.colLayer1
                colBackgroundHover: Appearance.colors.colLayer1Hover
                enabled: Network.wifiEnabled && !Network.wifiScanning
                onClicked: Network.rescanWifi()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "refresh"
                    iconSize: Appearance.font.pixelSize.large
                    color: parent.parent.enabled ? Appearance.colors.colOnLayer1 : Appearance.colors.colOnLayer1Inactive
                }
                StyledToolTip {
                    text: Translation.tr("Scan again")
                }
            }
        }

        // What the radio is doing, spelled out rather than implied by the icon
        // colour: connected name and signal, or "off", or "scanning".
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: Network.wifiEnabled

            StyledText {
                Layout.fillWidth: true
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.small
                text: {
                    if (!Network.wifiEnabled) return Translation.tr("Wi-Fi is off");
                    return Network.wifiStatus === "connected"
                        ? Translation.tr("Connected to %1").arg(Network.networkName)
                        : Network.wifiStatus;
                }
            }

            StyledIndeterminateProgressBar {
                visible: Network.wifiScanning
                Layout.fillWidth: false
                Layout.preferredWidth: 120
            }
        }

        // The list. Capped so a street with forty access points scrolls inside
        // the page instead of pushing everything below it off the bottom.
        StyledListView {
            id: wifiList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight ?? 0, 420)
            Layout.topMargin: 4
            clip: true
            spacing: 0
            visible: Network.wifiEnabled

            model: ScriptModel {
                values: Network.friendlyWifiNetworks
            }
            delegate: WifiNetworkItem {
                required property WifiAccessPoint modelData
                wifiNetwork: modelData
                width: ListView.view.width
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Network.wifiEnabled && Network.friendlyWifiNetworks.length === 0
            color: Appearance.colors.colOnLayer1Inactive
            text: Network.wifiScanning
                ? Translation.tr("Looking for networks…")
                : Translation.tr("No networks found.")
        }
    }

    // ── Bluetooth ────────────────────────────────────────────────────────
    ContentSection {
        visible: root.section === "bluetooth"
        icon: "bluetooth"
        title: Translation.tr("Bluetooth")

        ConfigSwitch {
            buttonIcon: "bluetooth"
            text: Translation.tr("Bluetooth")
            checked: BluetoothStatus.enabled
            enabled: BluetoothStatus.available
            onClicked: {
                if (!Bluetooth.defaultAdapter) return;
                // Turning the adapter on should start looking straight away --
                // a radio that is on but not scanning looks broken.
                Bluetooth.defaultAdapter.enabled = !BluetoothStatus.enabled;
                Bluetooth.defaultAdapter.discovering = BluetoothStatus.enabled ? false : true;
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: BluetoothStatus.enabled

            StyledText {
                Layout.fillWidth: true
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.small
                // The status line is the elastic one in this row: it is the
                // least urgent text on the page and it has a sensible short
                // form, so it gives up width before the switch's label does.
                elide: Text.ElideRight
                text: {
                    const count = BluetoothStatus.activeDeviceCount;
                    if (count === 0) return BluetoothStatus.enabled
                        ? Translation.tr("No device connected")
                        : Translation.tr("Bluetooth is off");
                    return Translation.tr("%1 device(s) connected").arg(count);
                }
            }

            ConfigSwitch {
                // Sized to its own content, NOT to a fixed 190px.
                //
                // It used to carry `Layout.preferredWidth: 190` with
                // `Layout.fillWidth: false`, which is a hard squeeze: the icon,
                // the label and the switch itself all have to fit inside 190,
                // and on a narrow window the label was the thing that gave --
                // "Scan for devices" rendered as "Scan for device" with the
                // switch jammed against it. A control's own label must never
                // be the thing that truncates, so the button now takes exactly
                // the width it needs and the status text beside it (which
                // elides gracefully and carries the least urgent information)
                // absorbs the difference instead.
                Layout.fillWidth: false
                Layout.minimumWidth: implicitWidth
                buttonIcon: "search"
                text: Translation.tr("Scan for devices")
                checked: Bluetooth.defaultAdapter?.discovering ?? false
                onClicked: {
                    if (!Bluetooth.defaultAdapter) return;
                    Bluetooth.defaultAdapter.discovering = !(Bluetooth.defaultAdapter.discovering ?? false);
                }
            }
        }

        // Everything the adapter has paired, as a plain flat list under the
        // search row. The section below it (BluetoothRecentSection) covers the
        // other half of "previously connected": the devices the adapter has
        // itself forgotten but this shell still remembers by address. The two
        // are exclusive, so a device never shows up in both at once.
        //
        // Rows are separated by a 1px hairline rather than grouped into a card
        // like `BluetoothDeviceItem` below: a skim-readable roster of names,
        // not a stack of interactive boxes. Not visible while the radio is off
        // -- nothing on the Bluetooth tab is, and a frozen list under an off
        // switch invites clicking a row that can only fail.
        ColumnLayout {
            id: previousDevicesSection
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 0
            visible: BluetoothStatus.enabled && BluetoothStatus.pairedButNotConnectedDevices.length > 0

            Repeater {
                model: ScriptModel {
                    values: BluetoothStatus.pairedButNotConnectedDevices
                }

                delegate: ColumnLayout {
                    id: previousDeviceRow
                    required property BluetoothDevice modelData
                    readonly property bool last: index === BluetoothStatus.pairedButNotConnectedDevices.length - 1

                    Layout.fillWidth: true
                    spacing: 0

                    RippleButton {
                        id: previousDeviceButton
                        Layout.fillWidth: true
                        implicitHeight: 44
                        buttonRadius: Appearance.rounding.normal
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        pointingHandCursor: true
                        onClicked: BluetoothStatus.connectDevice(previousDeviceRow.modelData)

                        contentItem: RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: Appearance.rounding.large
                                rightMargin: Appearance.rounding.large
                            }
                            spacing: 16

                            MaterialSymbol {
                                text: Icons.getBluetoothDeviceMaterialSymbol(previousDeviceRow.modelData?.icon || "")
                                iconSize: Appearance.font.pixelSize.larger
                                color: Appearance.colors.colOnSurfaceVariant
                            }

                            StyledText {
                                Layout.fillWidth: true
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colOnSurfaceVariant
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                                text: previousDeviceRow.modelData?.name || Translation.tr("Unknown device")
                            }

                            StyledText {
                                text: Translation.tr("Connect")
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                            }
                        }
                    }

                    // The separator the page asked for: one thin modern line
                    // between entries, none after the last one so the row
                    // doesn't trail a rule into the live-device list below.
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        visible: !previousDeviceRow.last
                        color: Appearance.colors.colOutline
                        opacity: 0.5
                    }
                }
            }
        }

        BluetoothRecentSection {}

        StyledListView {
            id: deviceList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight ?? 0, 420)
            Layout.topMargin: 4
            clip: true
            spacing: 0
            visible: BluetoothStatus.enabled

            model: ScriptModel {
                values: BluetoothStatus.friendlyDeviceList
            }
            delegate: BluetoothDeviceItem {
                required property BluetoothDevice modelData
                device: modelData
                width: ListView.view.width
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: !BluetoothStatus.available
            color: Appearance.colors.colOnLayer1Inactive
            text: Translation.tr("No Bluetooth adapter found on this machine.")
        }
    }
}

