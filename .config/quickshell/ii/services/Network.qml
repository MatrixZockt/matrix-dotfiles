pragma Singleton
pragma ComponentBehavior: Bound

// Took many bits from https://github.com/caelestia-dots/shell (GPLv3)

import Quickshell
import Quickshell.Io
import QtQuick
import qs.services.network

/**
 * Network service with nmcli.
 */
Singleton {
    id: root

    property bool wifi: true
    property bool ethernet: false

    property bool wifiEnabled: false
    property bool wifiScanning: false
    property bool wifiConnecting: connectProc.running
    property WifiAccessPoint wifiConnectTarget
    readonly property list<WifiAccessPoint> wifiNetworks: []
    readonly property WifiAccessPoint active: wifiNetworks.find(n => n.active) ?? null
    readonly property list<var> friendlyWifiNetworks: [...wifiNetworks].sort((a, b) => {
        if (a.active && !b.active)
            return -1;
        if (!a.active && b.active)
            return 1;
        return b.strength - a.strength;
    })
    property string wifiStatus: "disconnected"

    property string networkName: ""
    property int networkStrength
    // ── Addresses ───────────────────────────────────────────────────────
    // The IPv4 of each connected link, kept SEPARATE rather than collapsed
    // into one "the IP", because which one is the machine's address depends
    // on which link is up -- and the bar's wifi icon reports a different
    // thing for each (see `primaryIp`).
    property string wiredIp: ""
    property string wifiIp: ""
    // The address of the link the bar should speak for: the wire when it
    // is up, the radio otherwise. A wired connection has no network NAME
    // worth putting in a tooltip -- every wired link is called "Wired
    // connection 1" -- so the address is the only thing that tells you
    // anything. On wifi it is the other way round: the SSID is the useful
    // half, and the address is a column of digits you already know.
    readonly property string primaryIp: root.ethernet ? root.wiredIp : root.wifiIp
    property string materialSymbol: root.ethernet
        ? "lan"
        : (root.wifiEnabled && root.wifiStatus === "connected")
            ? (
                (root.active?.strength ?? 0) > 83 ? "signal_wifi_4_bar" :
                (root.active?.strength ?? 0) > 67 ? "network_wifi" :
                (root.active?.strength ?? 0) > 50 ? "network_wifi_3_bar" :
                (root.active?.strength ?? 0) > 33 ? "network_wifi_2_bar" :
                (root.active?.strength ?? 0) > 17 ? "network_wifi_1_bar" :
                "signal_wifi_0_bar"
            )
            : (root.wifiStatus === "connecting")
                ? "signal_wifi_statusbar_not_connected"
                : (root.wifiStatus === "disconnected")
                    ? "wifi_find"
                    : (root.wifiStatus === "disabled")
                        ? "signal_wifi_off"
                        : "signal_wifi_bad"

    // Control
    function enableWifi(enabled = true): void {
        const cmd = enabled ? "on" : "off";
        enableWifiProc.exec(["nmcli", "radio", "wifi", cmd]);
    }

    function toggleWifi(): void {
        enableWifi(!wifiEnabled);
    }

    function rescanWifi(): void {
        wifiScanning = true;
        rescanProcess.running = true;
    }

    function connectToWifiNetwork(accessPoint: WifiAccessPoint): void {
        accessPoint.askingPassword = false;
        root.wifiConnectTarget = accessPoint;
        // We use this instead of `nmcli connection up SSID` because this also creates a connection profile
        connectProc.exec(["nmcli", "dev", "wifi", "connect", accessPoint.ssid])

    }

    function disconnectWifiNetwork(): void {
        if (active) disconnectProc.exec(["nmcli", "connection", "down", active.ssid]);
    }

    function openPublicWifiPortal() {
        Quickshell.execDetached(["xdg-open", "https://nmcheck.gnome.org/"]) // From some StackExchange thread, seems to work
    }

    function changePassword(network: WifiAccessPoint, password: string, username = ""): void {
        // TODO: enterprise wifi with username
        network.askingPassword = false;
        changePasswordProc.exec({
            "environment": {
                "PASSWORD": password,
                "SSID": network.ssid
            },
            "command": ["bash", "-c", 'nmcli connection modify "$SSID" wifi-sec.psk "$PASSWORD"']
        })
    }

    Process {
        id: enableWifiProc
    }

    Process {
        id: connectProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        stdout: SplitParser {
            onRead: line => {
                // print(line)
                getNetworks.running = true
            }
        }
        stderr: SplitParser {
            onRead: line => {
                // print("err:", line)
                if (line.includes("Secrets were required")) {
                    root.wifiConnectTarget.askingPassword = true
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.wifiConnectTarget.askingPassword = (exitCode !== 0)
            root.wifiConnectTarget = null
        }
    }

    Process {
        id: disconnectProc
        stdout: SplitParser {
            onRead: getNetworks.running = true
        }
    }

    Process {
        id: changePasswordProc
        onExited: { // Re-attempt connection after changing password
            connectProc.running = false
            connectProc.running = true
        }
    }

    Process {
        id: rescanProcess
        command: ["nmcli", "dev", "wifi", "list", "--rescan", "yes"]
        stdout: SplitParser {
            onRead: {
                wifiScanning = false;
                getNetworks.running = true;
            }
        }
    }

    // Status update
    function update() {
        updateConnectionType.startCheck();
        wifiStatusProcess.running = true
        updateNetworkName.running = true;
        updateNetworkStrength.running = true;
        updateIpAddresses.startCheck();
    }

    // `nmcli monitor` is a plain output stream: nothing tells it when its
    // parent is gone, so every shell instance -- and every popup host that
    // mounted this service -- used to leave one behind, ~10 MB each. The
    // wrapper pins the owner pid up front and takes the monitor down when that
    // pid goes away, so the watcher's life is exactly its owner's. The trap
    // also covers an orderly stop (`stopStrayProcesses()`), and the poll
    // covers a SIGKILL where no trap can run.
    //
    // IT IS NOT SUFFICIENT ALONE, and the gap is the shell being killed
    // outright: the wrapper is a direct child, so it dies with the shell and
    // neither the trap nor the owner-poll ever runs, leaving the monitor
    // holding a D-Bus connection to nobody. Sweeping that survivor is
    // `sweepStrayNetworkMonitors` in the shell watchdog
    // (scripts/launch/shell-watchdog.sh), which is where the sweep lives now.
    //
    // It USED to live here, as a second `Process` beside this one -- and that
    // block never ran. Not once, over repeated restarts, with nothing in the
    // log: a sibling `Process` with `running: true` in this singleton was
    // simply not started, while this one was. A plain bash script that the
    // watchdog already executes on every launch is a far better place for a
    // guarantee than a QML element that may not be instantiated at all, so
    // the sweep moved rather than being retried here.
    Process {
        id: subscriber
        running: true
        command: ["bash", "-c",
            "owner=$PPID; nmcli monitor & mpid=$!; " +
            "trap 'kill -9 $mpid 2>/dev/null; exit 0' TERM INT HUP; " +
            "while kill -0 $owner 2>/dev/null; do sleep 2; done; " +
            "kill -9 $mpid 2>/dev/null"]
        stdout: SplitParser {
            onRead: root.update()
        }
    }

    // The one thing in this service that outlives whoever started it: nothing sends
    // `nmcli monitor` a signal when its parent goes away, so a settings app that
    // started its own Network left a watcher behind every time it was closed --
    // twenty-three of them were running on this machine after an afternoon of
    // opening and closing Settings, one per launch. The app stops it on the way out
    // (see `quitApp` in settings.qml), and the command above also self-terminates
    // when its owner dies, so a crash cannot leak one either.
    function stopStrayProcesses() {
        subscriber.running = false;
    }

    Process {
        id: updateConnectionType
        property string buffer
        command: ["sh", "-c", "nmcli -t -f TYPE,STATE d status && nmcli -t -f CONNECTIVITY g"]
        running: true
        function startCheck() {
            buffer = "";
            updateConnectionType.running = true;
        }
        stdout: SplitParser {
            onRead: data => {
                updateConnectionType.buffer += data + "\n";
            }
        }
        onExited: (exitCode, exitStatus) => {
            const lines = updateConnectionType.buffer.trim().split('\n');
            const connectivity = lines.pop() // none, limited, full
            let hasEthernet = false;
            let hasWifi = false;
            let wifiStatus = "disconnected";
            lines.forEach(line => {
                if (line.includes("ethernet") && line.includes("connected"))
                    hasEthernet = true;
                else if (line.includes("wifi:")) {
                    if (line.includes("disconnected")) {
                        wifiStatus = "disconnected"
                    }
                    else if (line.includes("connected")) {
                        hasWifi = true;
                        wifiStatus = "connected"

                        if (connectivity === "limited") {
                            hasWifi = false;
                            wifiStatus = "limited"
                        }
                    }
                    else if (line.includes("connecting")) {
                        wifiStatus = "connecting"
                    }
                    else if (line.includes("unavailable")) {
                        wifiStatus = "disabled"
                    }
                }
            });
            root.wifiStatus = wifiStatus;
            root.ethernet = hasEthernet;
            root.wifi = hasWifi;
        }
    }

    Process {
        id: updateNetworkName
        command: ["sh", "-c", "nmcli -t -f NAME c show --active | head -1"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                root.networkName = data;
            }
        }
    }

    // The two addresses above, one query, on the same triggers as
    // everything else (`update()`).
    //
    // A SEPARATE process from `updateConnectionType` rather than a fourth
    // field on its query. That process already pops its last line off as
    // the connectivity word and then walks the rest positionally, so
    // changing its output shape means touching the wifi/wired detection
    // that decides the bar's icon -- for the sake of two strings that are
    // only ever read by a tooltip. One more `nmcli` on a network CHANGE is
    // not a cost worth that risk with; it is not a poll.
    //
    // The device is part of the key rather than assumed, because both links
    // can be up at once (this machine is on the wire AND on wifi, and they
    // are on different subnets). The awk remembers the device from the
    // `GENERAL.DEVICE` line and pairs it with the `IP4.ADDRESS` line that
    // follows it -- in terse mode nmcli prints the FIELD NAME in front of
    // every value, and with `-g` the two values land on separate lines with
    // no way to tell which device each belongs to. Devices with no address
    // are dropped here rather than in QML.
    Process {
        id: updateIpAddresses
        property string buffer
        running: true
        function startCheck() {
            buffer = "";
            updateIpAddresses.running = true;
        }
        // `LANG=C` because the fields are parsed, not read, and a
        // localised nmcli would hand back translated headers and a decimal
        // comma in some builds.
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        command: ["sh", "-c",
            "nmcli -t -f GENERAL.DEVICE,IP4.ADDRESS d show | awk -F: '"
            + "/^GENERAL\\.DEVICE:/ { dev = $2; next } "
            + "/^IP4\\.ADDRESS/ { if (length($2) > 0) print dev \"=\" $2 }"
            + "'"]
        stdout: SplitParser {
            onRead: data => {
                updateIpAddresses.buffer += data + "\n";
            }
        }
        onExited: {
            const lines = updateIpAddresses.buffer.trim();
            let wired = "";
            let wifi = "";
            if (lines.length > 0) {
                for (const line of lines.split("\n")) {
                    const eq = line.lastIndexOf("=");
                    if (eq <= 0)
                        continue;
                    const dev = line.slice(0, eq);
                    // The prefix length is NetworkManager bookkeeping, not
                    // part of the address; "192.168.1.50/24" in a tooltip
                    // reads as a typo.
                    const addr = line.slice(eq + 1).split("/")[0];
                    if (addr.length === 0)
                        continue;
                    if (dev === "lo")
                        continue;
                    if (dev.startsWith("wl"))
                        wifi = addr;
                    else if (dev.startsWith("en") || dev.startsWith("eth"))
                        wired = addr;
                }
            }
            // Assigned unconditionally, including to "". A link that goes
            // down must CLEAR its address, or the bar keeps quoting the
            // address of a connection that is no longer there -- which is
            // worse than quoting nothing.
            root.wiredIp = wired;
            root.wifiIp = wifi;
        }
    }

    Process {
        id: updateNetworkStrength
        running: true
        command: ["sh", "-c", "nmcli -f IN-USE,SIGNAL,SSID device wifi | awk '/^\\*/{if (NR!=1) {print $2}}'"]
        stdout: SplitParser {
            onRead: data => {
                root.networkStrength = parseInt(data);
            }
        }
    }

    Process {
        id: wifiStatusProcess
        command: ["nmcli", "radio", "wifi"]
        Component.onCompleted: running = true
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        stdout: StdioCollector {
            onStreamFinished: {
                root.wifiEnabled = text.trim() === "enabled";
            }
        }
    }

    Process {
        id: getNetworks
        running: true
        command: ["nmcli", "-g", "ACTIVE,SIGNAL,FREQ,SSID,BSSID,SECURITY", "d", "w"]
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        stdout: StdioCollector {
            onStreamFinished: {
                const PLACEHOLDER = "STRINGWHICHHOPEFULLYWONTBEUSED";
                const rep = new RegExp("\\\\:", "g");
                const rep2 = new RegExp(PLACEHOLDER, "g");

                const allNetworks = text.trim().split("\n").map(n => {
                    const net = n.replace(rep, PLACEHOLDER).split(":");
                    return {
                        active: net[0] === "yes",
                        strength: parseInt(net[1]),
                        frequency: parseInt(net[2]),
                        ssid: net[3],
                        bssid: net[4]?.replace(rep2, ":") ?? "",
                        security: net[5] || ""
                    };
                }).filter(n => n.ssid && n.ssid.length > 0);

                // Group networks by SSID and prioritize connected ones
                const networkMap = new Map();
                for (const network of allNetworks) {
                    const existing = networkMap.get(network.ssid);
                    if (!existing) {
                        networkMap.set(network.ssid, network);
                    } else {
                        // Prioritize active/connected networks
                        if (network.active && !existing.active) {
                            networkMap.set(network.ssid, network);
                        } else if (!network.active && !existing.active) {
                            // If both are inactive, keep the one with better signal
                            if (network.strength > existing.strength) {
                                networkMap.set(network.ssid, network);
                            }
                        }
                        // If existing is active and new is not, keep existing
                    }
                }

                const wifiNetworks = Array.from(networkMap.values());

                const rNetworks = root.wifiNetworks;

                const destroyed = rNetworks.filter(rn => !wifiNetworks.find(n => n.frequency === rn.frequency && n.ssid === rn.ssid && n.bssid === rn.bssid));
                for (const network of destroyed)
                    rNetworks.splice(rNetworks.indexOf(network), 1).forEach(n => n.destroy());

                for (const network of wifiNetworks) {
                    const match = rNetworks.find(n => n.frequency === network.frequency && n.ssid === network.ssid && n.bssid === network.bssid);
                    if (match) {
                        match.lastIpcObject = network;
                    } else {
                        rNetworks.push(apComp.createObject(root, {
                            lastIpcObject: network
                        }));
                    }
                }
            }
        }
    }

    Component {
        id: apComp

        WifiAccessPoint {}
    }
}
