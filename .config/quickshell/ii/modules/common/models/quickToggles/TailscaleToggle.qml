import QtQuick
import Quickshell
import qs.services
import qs.modules.common

/**
 * The sidebar's Tailscale switch.
 *
 * A thin view over the Tailscale service: the toggle owns no state of its
 * own, so the switch here, the label in the bar's right island and the
 * daemon itself can never disagree.
 */
QuickToggleModel {
    id: root

    name: Translation.tr("Tailscale")
    icon: Tailscale.connected ? "vpn_lock" : "vpn_key_off"
    available: Tailscale.available
    toggled: Tailscale.connected
    hasStatusText: true
    statusText: Tailscale.statusText
    tooltipText: Translation.tr("Tailscale VPN — Home-VPN")
    mainAction: () => Tailscale.toggle()
}
