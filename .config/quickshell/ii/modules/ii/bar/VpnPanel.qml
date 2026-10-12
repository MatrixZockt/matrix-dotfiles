import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell

/**
 * The VPN popup app, opened by clicking the bar's VPN label.
 *
 * One row per connection, each with its own on/off switch, plus a list of
 * the machines that connection can see. Tailscale is the only connection
 * today -- but the panel is built around a LIST rather than around Tailscale,
 * so a second VPN (or a second tailnet) is a new entry in `connections`
 * rather than a second popup that would have to re-invent this one.
 *
 * Tailscale is a mesh, not a single tunnel, so "connect to the Pi" is the
 * tailnet coming up and the Pi being on it. Both halves are shown: the switch
 * is the tailnet, and the devices below say whether the machine you actually
 * wanted is reachable. A switch that says "on" while the Pi is offline is
 * exactly the confusion this is meant to remove.
 */
BarAnchoredPanel {
    id: root

    contentWidth: 340

    onOpened: {
        Tailscale.refresh();
        // The preferences too, not just the status: this panel's own switch
        // reads the tailnet, while the settings page behind the tune button
        // reads the prefs -- and a page that opened on stale ones would show
        // switches that disagree with the daemon.
        Tailscale.refreshPrefs();
    }

    function openFullSettings() {
        root.close();
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/launch/settings.sh"), "network", "vpn"]);
    }

    // ── The connections this bar can switch ────────────────────────────
    // A binding, deliberately: it re-evaluates whenever any Tailscale state
    // it reads changes, and the Repeater below rebuilds its rows with it.
    // That is what keeps each switch honest -- a click writes the switch
    // locally, and the next real state change rebuilds the row from the
    // service, so a command that failed snaps the switch back on its own.
    readonly property var connections: [
        {
            "id": "tailscale",
            "label": "My-Tailnet",
            "detail": Translation.tr("Tailscale"),
            "statusText": Tailscale.statusText,
            "address": Tailscale.selfIp,
            "connected": Tailscale.connected,
            "busy": Tailscale.busy,
            "available": Tailscale.available,
            "icon": Tailscale.connected ? "vpn_lock" : "vpn_key_off",
            "setEnabled": (on) => Tailscale.setEnabled(on)
        }
    ]

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        // ── Header ─────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: Tailscale.connected ? "vpn_lock" : "vpn_key_off"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("VPN")
                font.pixelSize: Appearance.font.pixelSize.title
                color: Appearance.colors.colOnLayer0
            }
            // The same door the Wi-Fi and Bluetooth menus carry: everything
            // this panel does not show -- exit node, routes, DNS, SSH, the
            // log-in and log-out -- lives on the Network page's VPN tab, and
            // this walks straight to it.
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

        // ── The connection switches ────────────────────────────────────
        Repeater {
            model: root.connections

            delegate: ConfigSwitch {
                id: connectionSwitch
                required property var modelData

                Layout.fillWidth: true
                iconSize: Appearance.font.pixelSize.larger
                buttonIcon: modelData.icon
                text: modelData.label
                enabled: modelData.available && !modelData.busy
                // One-way, from the service. Safe to write over: the row is
                // rebuilt from `connections` on every state change, which is
                // where this binding comes from in the first place.
                checked: modelData.connected
                onCheckedChanged: {
                    // Only a press is a request. The build and every rebuild
                    // set `checked` too, and that is not the user asking for
                    // anything.
                    if (checked === modelData.connected) return;
                    modelData.setEnabled(checked);
                }
            }
        }

        // ── What the connection can actually see ───────────────────────
        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 2
            visible: Tailscale.installed
            text: Translation.tr("Devices on the tailnet")
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1
        }

        StyledText {
            Layout.fillWidth: true
            visible: Tailscale.installed && Tailscale.peers.length === 0
            text: Translation.tr("None — the VPN is off.")
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
        }

        Repeater {
            model: Tailscale.peers

            delegate: Rectangle {
                id: peerRow
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: 44
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer1

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 12
                        rightMargin: 12
                    }
                    spacing: 10

                    // Online is the only thing about a peer that changes, and
                    // it is the only thing worth colouring: a green dot means
                    // this is a machine you can reach right now.
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 8
                        implicitHeight: 8
                        radius: 4
                        color: peerRow.modelData.online
                            ? Appearance.colors.colPrimary
                            : ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.5)
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: peerRow.modelData.name
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: peerRow.modelData.online
                            ? Appearance.colors.colOnLayer1
                            : ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.35)
                    }
                    StyledText {
                        text: peerRow.modelData.ip
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer2
                    }
                }
            }
        }

        // ── Re-authentication ──────────────────────────────────────────
        // A node whose key expired stays off the tailnet until someone opens
        // a browser, and it looks exactly like a VPN that will not turn on --
        // so the one case that needs a click offers it here rather than
        // making the user go and find the URL somewhere else.
        RippleButton {
            id: signInButton
            Layout.fillWidth: true
            Layout.topMargin: 2
            visible: Tailscale.loginRequired && Tailscale.authUrl !== ""
            implicitHeight: 38
            buttonRadius: Appearance.rounding.normal
            colBackground: Appearance.colors.colPrimary
            colBackgroundHover: Appearance.colors.colPrimaryHover
            onClicked: Quickshell.execDetached(["xdg-open", Tailscale.authUrl])
            contentItem: StyledText {
                anchors.centerIn: parent
                text: Translation.tr("Sign in to Tailscale")
                color: Appearance.colors.colOnPrimary
                font.pixelSize: Appearance.font.pixelSize.small
            }
        }
    }
}
