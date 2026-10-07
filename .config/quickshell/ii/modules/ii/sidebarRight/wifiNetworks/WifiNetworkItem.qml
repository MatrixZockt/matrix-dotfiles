import qs
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import qs.services.network
import QtQuick
import QtQuick.Layouts

/**
 * One network, as a row inside a `DialogListGroup`.
 *
 * The row is two lines now: the SSID, and a meta line that spells out what the
 * two old trailing icons were trying to say between them -- the state, the
 * security type and the band. That is the whole point of the redesign. "check"
 * next to a name tells you the network is joined; "lock" tells you it is
 * encrypted; neither tells you which band, and both compete with the SSID for
 * the same horizontal space. One muted line under the name says all of it and
 * leaves the right-hand edge free for a single control.
 */
DialogListItem {
    id: root
    required property WifiAccessPoint wifiNetwork
    enabled: !(Network.wifiConnectTarget === root.wifiNetwork && !wifiNetwork?.active)

    active: (wifiNetwork?.askingPassword || wifiNetwork?.active) ?? false

    // Rows sit inside a card now, so the row's own hover plate is a rounded
    // inset rather than a full-bleed band -- a full-bleed one squared off the
    // card's corners and read as a rendering bug.
    buttonRadius: Appearance.rounding.normal
    verticalPadding: 12

    onClicked: {
        Network.connectToWifiNetwork(wifiNetwork);
    }

    // The band's name, derived from the channel frequency. nmcli hands over a
    // number in MHz and nothing else, and "2412" is not a label -- but 2.4 and
    // 5 GHz networks sitting in one alphabetical list is exactly the confusion
    // the meta line exists to remove.
    readonly property string band: {
        const mhz = wifiNetwork?.frequency ?? 0;
        if (mhz <= 0) return "";
        if (mhz < 3000) return "2.4 GHz";
        if (mhz < 6000) return "5 GHz";
        return "6 GHz";
    }
    readonly property string securityLabel: {
        const raw = (wifiNetwork?.security ?? "").trim();
        if (raw.length === 0) return Translation.tr("Open");
        // nmcli can report a list ("WPA1 WPA2"). The strongest entry is the
        // one worth showing; the full string is unreadable at this size.
        const order = ["WPA3", "WPA2", "WPA1", "SAE", "RSN", "WEP"];
        return order.find(k => raw.includes(k)) ?? raw.split(/\s+/)[0];
    }
    readonly property bool isConnected: wifiNetwork?.active ?? false
    readonly property string metaText: {
        const bits = [];
        if (root.isConnected) bits.push(Translation.tr("Connected"));
        bits.push(root.securityLabel);
        if (root.band.length > 0) bits.push(root.band);
        return bits.join(`  ·  `);
    }

    contentItem: ColumnLayout {
        anchors {
            fill: parent
            topMargin: root.verticalPadding
            bottomMargin: root.verticalPadding
            leftMargin: root.horizontalPadding
            rightMargin: root.horizontalPadding
        }
        spacing: 0

        RowLayout {
            spacing: 16

            // The signal glyph is now purely a signal reading -- the state and
            // the lock moved into the meta line, so the icon is free to be the
            // thing it is actually good at: how strong the network is.
            MaterialSymbol {
                iconSize: Appearance.font.pixelSize.larger
                property int strength: root.wifiNetwork?.strength ?? 0
                text: strength > 80 ? "signal_wifi_4_bar" : strength > 60 ? "network_wifi_3_bar" : strength > 40 ? "network_wifi_2_bar" : strength > 20 ? "network_wifi_1_bar" : "signal_wifi_0_bar"
                color: root.isConnected
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnSurfaceVariant
            }

            ColumnLayout {
                spacing: 3
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: root.isConnected ? Font.DemiBold : Font.Normal
                    color: root.isConnected
                        ? Appearance.colors.colOnLayer0
                        : Appearance.colors.colOnSurfaceVariant
                    elide: Text.ElideRight
                    text: root.wifiNetwork?.ssid ?? Translation.tr("Unknown")
                    textFormat: Text.PlainText
                }

                RowLayout {
                    spacing: 6
                    Layout.fillWidth: true

                    // A dot, not an icon. The old row spelled the state out with
                    // a full-size glyph on the right; at this size a 5px dot
                    // reads the same and stops the meta line looking like a
                    // toolbar.
                    Rectangle {
                        visible: root.isConnected
                        implicitWidth: 5
                        implicitHeight: 5
                        radius: 3
                        color: Appearance.colors.colPrimary
                    }

                    StyledText {
                        Layout.fillWidth: true
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: root.isConnected
                            ? Appearance.colors.colSubtext
                            : Appearance.colors.colSubtext
                        opacity: root.isConnected ? 1 : 0.85
                        elide: Text.ElideRight
                        text: root.metaText
                    }
                }
            }

            // While a join is in flight the row has to say so, because the click
            // otherwise looks like it did nothing. Same reason the old code
            // swapped the trailing icon for `settings_ethernet`.
            MaterialSymbol {
                visible: Network.wifiConnectTarget === root.wifiNetwork && !root.isConnected
                text: "progress_activity"
                iconSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colPrimary

                RotationAnimation on rotation {
                    running: parent.visible
                    loops: Animation.Infinite
                    from: 0; to: 360
                    duration: 1200
                }
            }
        }

        ColumnLayout { // Password
            id: passwordPrompt
            Layout.topMargin: 10
            visible: root.wifiNetwork?.askingPassword ?? false

            MaterialTextField {
                id: passwordField
                Layout.fillWidth: true
                placeholderText: Translation.tr("Password")

                // Password
                echoMode: TextInput.Password
                inputMethodHints: Qt.ImhSensitiveData

                onAccepted: {
                    Network.changePassword(root.wifiNetwork, passwordField.text);
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4

                Item {
                    Layout.fillWidth: true
                }

                DialogButton {
                    buttonText: Translation.tr("Cancel")
                    onClicked: {
                        root.wifiNetwork.askingPassword = false;
                    }
                }

                DialogButton {
                    buttonText: Translation.tr("Connect")
                    onClicked: {
                        Network.changePassword(root.wifiNetwork, passwordField.text);
                    }
                }
            }
        }

        ColumnLayout { // Public wifi login page
            id: publicWifiPortal
            Layout.topMargin: 10
            visible: (root.wifiNetwork?.active && (root.wifiNetwork?.security ?? "").trim().length === 0) ?? false

            RowLayout {
                DialogButton {
                    Layout.fillWidth: true
                    buttonText: Translation.tr("Open network portal")
                    colBackground: Appearance.colors.colLayer4
                    colBackgroundHover: Appearance.colors.colLayer4Hover
                    colRipple: Appearance.colors.colLayer4Active
                    onClicked: {
                        Network.openPublicWifiPortal()
                        GlobalStates.sidebarRightOpen = false
                    }
                }
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
