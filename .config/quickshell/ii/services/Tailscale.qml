pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

/**
 * Tailscale, as the shell sees it.
 *
 * One source of truth for both places the shell shows the VPN: the quick
 * toggle in the right sidebar and the label in the bar's right island. Both
 * of them draw from here rather than each running the CLI, so the two can
 * never disagree about whether the tailnet is up -- and neither can drift
 * away from the daemon, because this polls.
 *
 * The commands are run as the desktop user, not as root. `tailscaled` is
 * configured with `--operator=matrix` for exactly that reason: without it
 * every `up`/`down` here would need a password, and a switch that asks for
 * one is not a switch.
 *
 * `up`/`down` (rather than starting and stopping `tailscaled`) is the right
 * verb for a UI toggle. `tailscale down` takes the machine off the tailnet
 * while leaving the daemon and the node key in place, so bringing it back is
 * instant and needs no re-authentication -- which is what "turn the VPN off"
 * means to someone pressing a switch. Stopping the service would instead
 * make the toggle unavailable the moment it was switched off.
 */
Singleton {
    id: root

    // ── The daemon's own word for what it is doing ─────────────────────
    // `BackendState` from `tailscale status --json`, kept verbatim so the UI
    // can say the same thing the CLI does: Running, Stopped, NeedsLogin,
    // Starting, NoState.
    property string backendState: "Unknown"
    // The CLI answered at all. Without this the toggle has nothing to offer
    // and is shown unavailable rather than merely "off".
    property bool installed: false
    // A control command is in flight. The switch is disabled meanwhile so a
    // second press cannot race the first.
    property bool busy: false
    // Where to send the user when the node needs to log in again.
    property string authUrl: ""

    // ── This machine ───────────────────────────────────────────────────
    property string selfName: ""
    property string selfIp: ""

    // ── The rest of the tailnet ────────────────────────────────────────
    // [{ key, name, ip, online, os, exitNode, exitNodeOption }]
    property var peers: []

    // ── Preferences: everything `tailscale set` can change ─────────────
    //
    // Raw, and read from `tailscale debug prefs`, which prints the daemon's
    // preferences as one JSON object. `debug` is not a promised-stable
    // interface, so this read is best-effort by design: a parse failure keeps
    // the values already here (see applyPrefs) rather than inventing any, and
    // the switches then show the last thing the daemon actually said.
    //
    // `tailscale status --json` is NOT enough for this: it reports the tailnet,
    // not this client's preferences -- nothing in it says whether routes are
    // accepted, DNS is taken from the tailnet, or the machine is an exit node.
    property var prefs: ({})

    // Named accessors, so no view has to know the daemon's key spellings.
    // `CorpDNS` is `--accept-dns` and `RouteAll` is `--accept-routes`; both
    // are the prefs' names for the flag, not a mistake.
    readonly property bool acceptRoutes: prefs.RouteAll === true
    readonly property bool acceptDns: prefs.CorpDNS !== false
    readonly property bool runSSH: prefs.RunSSH === true
    readonly property bool shieldsUp: prefs.ShieldsUp === true
    readonly property bool exitNodeAllowLanAccess: prefs.ExitNodeAllowLANAccess === true
    readonly property string exitNodeId: String(prefs.ExitNodeID ?? "")
    readonly property string exitNodeIp: String(prefs.ExitNodeIP ?? "")
    readonly property bool usingExitNode: exitNodeId.length > 0 || exitNodeIp.length > 0
    // Advertising this machine AS an exit node is not a flag of its own in the
    // prefs: the daemon stores it as the default route inside AdvertiseRoutes.
    // So it is derived here, and the explicit `--advertise-exit-node` flag is
    // what the switch below sends.
    readonly property var advertiseRoutes: Array.isArray(prefs.AdvertiseRoutes)
        ? prefs.AdvertiseRoutes : []
    readonly property bool advertiseExitNode:
        root.advertiseRoutes.indexOf("0.0.0.0/0") !== -1

    // The machines that could serve as an exit node right now: the peers that
    // advertise themselves as one. From `status --json`'s documented
    // `ExitNodeOption`, NOT from `tailscale exit-node list` -- that prints a
    // human table, and a table that changes column widths is not something to
    // parse a settings page out of.
    readonly property var exitNodeOptions: root.peers.filter(peer => peer.exitNodeOption === true)

    readonly property bool connected: backendState === "Running"
    readonly property bool loginRequired: backendState === "NeedsLogin"
    readonly property bool available: installed

    readonly property string statusText: {
        switch (backendState) {
        case "Running": return Translation.tr("Connected");
        case "Stopped": return Translation.tr("Off");
        case "NoState": return Translation.tr("Off");
        case "Starting": return Translation.tr("Connecting…");
        case "NeedsLogin": return Translation.tr("Sign-in required");
        case "Unknown": return installed ? Translation.tr("Unavailable") : Translation.tr("Not installed");
        default: return backendState;
        }
    }

    function peerByName(hostName) {
        const wanted = String(hostName ?? "").toLowerCase();
        for (const peer of root.peers) {
            if (String(peer.name ?? "").toLowerCase() === wanted)
                return peer;
        }
        return null;
    }

    function refresh() {
        if (!statusProc.running)
            statusProc.running = true;
    }

    function refreshPrefs() {
        if (!prefsProc.running)
            prefsProc.running = true;
    }

    // ── Changing the preferences ───────────────────────────────────────
    //
    // All of these go through the SAME process as up/down, because they are
    // the same kind of thing: one `tailscale` verb, one shot, and the identical
    // handling afterwards -- busy while in flight, a notification on failure,
    // and a re-read once the daemon has settled.
    //
    // `tailscale set`, not `tailscale up`: `up` requires the COMPLETE set of
    // desired options on every run, so using it here would make changing one
    // switch silently re-send every other setting as whatever this shell
    // happens to think it is. `set` changes only what it is given.
    function runControl(args) {
        if (root.busy)
            return;
        root.busy = true;
        controlProc.command = ["tailscale"].concat(args);
        controlProc.running = true;
    }

    // Every switch in the settings page has this shape: `--flag` turns it on,
    // `--flag=false` turns it off. The UI passes the flag name and the state.
    function setToggle(flag, on) {
        root.runControl(["set", on ? flag : flag + "=false"]);
    }

    function setExitNode(ipOrName) {
        const value = String(ipOrName ?? "");
        root.runControl(["set", value.length > 0 ? "--exit-node=" + value : "--exit-node="]);
    }

    function setAdvertiseRoutes(cidrList) {
        root.runControl(["set", "--advertise-routes=" + String(cidrList ?? "")]);
    }

    // A separate account or a fresh login. `logout` expires the node's key (a
    // later `up` needs the browser again); `down` does not, which is why the
    // switch above uses down and this is a button of its own.
    function login() {
        root.runControl(["login"]);
    }

    function logout() {
        root.runControl(["logout"]);
    }

    function setEnabled(on) {
        if (root.busy)
            return;
        // Already there. A press that changes nothing should still answer,
        // so re-read rather than silently doing nothing.
        if (on === root.connected) {
            root.refresh();
            return;
        }
        root.busy = true;
        // Optimistic, and at the right moment: coming up is not instant, and
        // a switch that springs back under the finger while the daemon works
        // reads as "it refused". `Starting` is the real state for that beat
        // anyway, so the label stays honest.
        root.backendState = on ? "Starting" : "Stopped";
        controlProc.command = ["tailscale", on ? "up" : "down"];
        controlProc.running = true;
    }

    function toggle() {
        root.setEnabled(!root.connected);
    }

    // ── Keeping up with the daemon ──────────────────────────────────────
    // The state also changes for reasons this shell never sees: the daemon's
    // own reconnect, a key expiring, a node removed from the admin console.
    // A toggle showing the wrong thing is worse than no toggle, so the truth
    // is re-read on a timer rather than only after our own commands.
    Timer {
        interval: 5000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Process {
        id: statusProc
        command: ["tailscale", "status", "--json"]
        stdout: StdioCollector {
            id: statusCollector
            onStreamFinished: root.applyStatus(statusCollector.text)
        }
        onExited: (exitCode, exitStatus) => {
            // Non-zero is how the CLI says "not installed" or "the daemon is
            // not answering". Both mean there is nothing to switch.
            if (exitCode !== 0) {
                root.installed = false;
                root.peers = [];
                root.backendState = "Unknown";
            }
        }
    }

    Process {
        id: prefsProc
        command: ["tailscale", "debug", "prefs"]
        stdout: StdioCollector {
            id: prefsCollector
            onStreamFinished: root.applyPrefs(prefsCollector.text)
        }
    }

    function applyPrefs(text) {
        if (!text || text.length === 0)
            return;
        let data = null;
        try {
            data = JSON.parse(text);
        } catch (error) {
            // Best-effort interface (see the note on `prefs`): keep what we
            // have rather than blanking the switches into a lie.
            return;
        }
        if (!data)
            return;
        root.prefs = data;
    }

    function applyStatus(text) {
        if (!text || text.length === 0)
            return;
        let data = null;
        try {
            data = JSON.parse(text);
        } catch (error) {
            // A half-written line from a daemon that is starting. The poll
            // below will come back with a whole one.
            return;
        }
        if (!data)
            return;

        root.installed = true;
        root.backendState = String(data.BackendState ?? "Unknown");
        root.authUrl = String(data.AuthURL ?? "");

        const self = data.Self ?? null;
        root.selfName = String(self?.HostName ?? "");
        const selfIps = self?.TailscaleIPs ?? [];
        root.selfIp = selfIps.length > 0 ? String(selfIps[0]) : "";

        // The peer map is keyed by node key. Only entries with an address
        // are listed: a peer still being provisioned has none, and a row
        // that cannot be connected to is not worth showing.
        const list = [];
        const map = data.Peer ?? {};
        for (const key of Object.keys(map)) {
            const peer = map[key] ?? {};
            const ips = peer.TailscaleIPs ?? [];
            if (ips.length === 0)
                continue;
            const dnsName = String(peer.DNSName ?? "");
            list.push({
                "key": key,
                "name": String(peer.HostName ?? "") || dnsName.split(".")[0] || "?",
                "ip": String(ips[0]),
                "online": peer.Online === true,
                "os": String(peer.OS ?? ""),
                "exitNode": peer.ExitNode === true,
                "exitNodeOption": peer.ExitNodeOption === true
            });
        }
        // Online first, then alphabetical: the machine you are about to use
        // is the one you are looking for, and it should not be buried under
        // the ones that are switched off.
        list.sort((a, b) => {
            if (a.online !== b.online)
                return a.online ? -1 : 1;
            return a.name.localeCompare(b.name);
        });
        root.peers = list;
    }

    Process {
        id: controlProc
        onExited: (exitCode, exitStatus) => {
            root.busy = false;
            if (exitCode !== 0) {
                Quickshell.execDetached(["notify-send", "-a", "Shell",
                    Translation.tr("Tailscale"),
                    Translation.tr("The command failed. Run <tt>tailscale status</tt> to see why.")]);
            }
            // The daemon answers a beat after the command returns -- the
            // backend is still starting when `tailscale up` exits. Reading
            // immediately would latch the optimistic value above and report
            // "Connecting…" for a tailnet that is already up.
            settle.restart();
        }
    }

    Timer {
        id: settle
        interval: 700
        repeat: false
        onTriggered: {
            root.refresh();
            // The preference we just wrote is the daemon's now, and the daemon
            // may have normalised it (an exit node named by hostname comes
            // back as an ID). Re-read rather than trusting the request.
            root.refreshPrefs();
        }
    }
}
