pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import QtQuick
import qs.modules.common

Singleton {
    id: root

    readonly property bool available: Bluetooth.adapters.values.length > 0
    readonly property bool enabled: Bluetooth.defaultAdapter?.enabled ?? false
    readonly property BluetoothDevice firstActiveDevice: Bluetooth.defaultAdapter?.devices.values.find(device => device.connected) ?? null
    readonly property int activeDeviceCount: Bluetooth.defaultAdapter?.devices.values.filter(device => device.connected).length ?? 0
    readonly property bool connected: Bluetooth.devices.values.some(d => d.connected)

    function sortFunction(a, b) {
        // Ones with meaningful names before MAC addresses
        const macRegex = /^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$/;
        const aIsMac = macRegex.test(a.name);
        const bIsMac = macRegex.test(b.name);
        if (aIsMac !== bIsMac)
            return aIsMac ? 1 : -1;

        // Alphabetical by name
        return a.name.localeCompare(b.name);
    }
    property list<var> connectedDevices: Bluetooth.devices.values.filter(d => d.connected).sort(sortFunction)
    property list<var> pairedButNotConnectedDevices: Bluetooth.devices.values.filter(d => d.paired && !d.connected).sort(sortFunction)
    property list<var> unpairedDevices: Bluetooth.devices.values.filter(d => !d.paired && !d.connected).sort(sortFunction)
    property list<var> friendlyDeviceList: [
        ...connectedDevices,
        ...pairedButNotConnectedDevices,
        ...unpairedDevices
    ]

    // ── The history, so the panel can offer what the adapter forgot ──────
    //
    // Wi-Fi gets this for free: nmcli keeps every saved network in its own
    // config, so a network you joined last month is still listable and still
    // joinable with one click. Bluetooth has no equivalent -- the device list
    // is only what the adapter currently knows, which for anything out of
    // range is nothing at all. So a device you paired once simply vanishes
    // from the panel, and the only way back is to find it with discovery and
    // hope it answers.
    //
    // This is that memory. `recordKnownDevices()` runs whenever the paired or
    // connected set changes, so an entry exists for anything the shell has
    // ever paired, and `recentDevices` is the subset of those that are NOT
    // already in `friendlyDeviceList` -- i.e. exactly the devices the panel
    // would otherwise be unable to offer.
    readonly property var history: Persistent.states.bluetoothHistory ?? []

    // The one place a device's address is read.
    //
    // It used to be spelled `d.deviceAddress ?? d.id` in four separate places.
    // NEITHER of those properties exists on Quickshell's BluetoothDevice -- the
    // real one is `address` (confirmed against
    // /usr/lib/qt6/qml/Quickshell/Bluetooth/quickshell-bluetooth.qmltypes,
    // which lists address/name/deviceName/icon/state/connected/paired/bonded/
    // pairing/trusted/blocked/wakeAllowed/battery/batteryAvailable/adapter).
    // So every read evaluated to `undefined ?? undefined ?? ""`, i.e. the empty
    // string, and `recordKnownDevices` bailed out on its `if (!mac) continue`
    // for every single device. `states.json` held `"bluetoothHistory": []` and
    // never grew: the remembered-devices feature was dead code that looked
    // alive.
    //
    // Centralised here so the same typo cannot be reintroduced in one of the
    // four call sites, and so the MAC format is decided once.
    function macOf(device) {
        return device?.address ?? "";
    }

    // Devices we have connected to before that the adapter is not currently
    // listing. Most recent first, capped so the section cannot grow forever.
    readonly property var recentDevices: {
        const known = new Set(root.friendlyDeviceList.map(d => root.macOf(d)));
        return root.history
            .filter(entry => entry && entry.mac && !known.has(entry.mac))
            .sort((a, b) => (b.lastSeen ?? 0) - (a.lastSeen ?? 0))
            .slice(0, 8);
    }

    // Fold the devices we know into the history.
    //
    // Rewrites the whole list rather than appending, so a device that is
    // already there moves to the top instead of appearing twice -- which is
    // what "recent" has to mean for the order to be worth anything.
    //
    // PAIRED counts, not just connected. It used to record only what was
    // connected at the moment the list changed, which meant the memory was
    // built from the wrong event: pairing is what a user does once and then
    // expects to be remembered, and a device that paired but whose connection
    // came later (or never, because it was out of range) was never written
    // down at all. The name is the thing worth keeping, and the moment the
    // name is known is the moment it paired.
    function recordKnownDevices() {
        if (!root.persistentReady) return;
        const now = Date.now();
        const seen = [...root.connectedDevices, ...root.pairedButNotConnectedDevices];
        const fresh = [];
        for (const d of seen) {
            const mac = root.macOf(d);
            if (!mac || fresh.some(f => f.mac === mac)) continue;
            fresh.push({
                mac: mac,
                // `name` can be empty for a device that has never advertised
                // one; the MAC is a better label than a blank row.
                name: d.name || mac,
                lastSeen: now
            });
        }
        if (fresh.length === 0) return;

        const rest = root.history.filter(e => e && !fresh.some(f => f.mac === e.mac));
        // Cap the tail too, so the file cannot creep upward forever.
        Persistent.states.bluetoothHistory = [...fresh, ...rest].slice(0, 24);
    }

    // Reconnecting to a remembered device.
    //
    // If the adapter still knows it, this is one call. If it does not -- the
    // whole reason the device is in the history -- there is no BluetoothDevice
    // object to call `.connect()` on, so the adapter is woken and told to keep
    // looking; `pendingMac` then connects it the moment discovery turns it up.
    function connectRemembered(entry) {
        if (!entry || !entry.mac) return;
        const live = Bluetooth.devices.values.find(d => root.macOf(d) === entry.mac);
        if (live) {
            root.connectDevice(live);
            return;
        }
        const adapter = Bluetooth.defaultAdapter;
        if (!adapter) return;
        adapter.enabled = true;
        adapter.discovering = true;
        root.pendingMac = entry.mac;
    }

    function connectDevice(device) {
        if (!device) return;
        if (device.connected) return;
        if (!device.paired) device.pair();
        device.connect();
    }

    // The address we are waiting to find. Cleared by whoever acts on it.
    property string pendingMac: ""

    // ── Keeping the history true ─────────────────────────────────────────
    //
    // Both lists are bindings over the live device list, so these fire
    // whenever those sets change: a device pairing, connecting, dropping, or
    // appearing. Recording on the CHANGE rather than on an interval is what
    // keeps the history honest -- it is written at the moment something
    // actually happens, not whenever the panel happened to be open.
    //
    // The pairing list is watched as well as the connected one, so a device
    // enters the memory at the moment it is paired even if it never manages a
    // connection in this session. Without that, the history only ever learned
    // about devices the shell had personally watched connect, and a pairing
    // made in an earlier session -- or one that failed to complete -- left
    // nothing behind for the user to come back to.
    Connections {
        target: root
        function onConnectedDevicesChanged() {
            root.recordKnownDevices();
            // A device we were waiting for has just turned up.
            if (root.pendingMac) {
                const found = root.connectedDevices.find(
                    d => root.macOf(d) === root.pendingMac);
                if (found) {
                    root.pendingMac = "";
                    root.connectDevice(found);
                }
            }
        }
        function onPairedButNotConnectedDevicesChanged() {
            root.recordKnownDevices();
        }
        function onPendingMacChanged() {
            if (root.pendingMac && !root.enabled)
                Bluetooth.defaultAdapter && (Bluetooth.defaultAdapter.enabled = true);
        }
    }

    // The startup ordering hole.
    //
    // `recordKnownDevices` returns early while `Persistent.ready` is false,
    // because writing before the JSON file has loaded would overwrite it. But
    // it is only ever CALLED from the two change handlers in the Connections
    // above -- so if BlueZ populates the device list before states.json
    // finishes loading (the common case: bluetoothd answers in well under a
    // second, the file read does not always), that recording attempt is
    // dropped and never retried, because "the list stopped changing" is not
    // an event anything waits for. Devices that were sitting there the whole
    // time were then never written down at all.
    //
    // Recording again once the file has loaded closes it. This watches
    // `Persistent` itself, NOT `root`: a Connections handler must be named for
    // a signal its own target actually has, and `root` has no `readyChanged`
    // -- Qt rejects the handler outright ("Detected function onReadyChanged ...
    // no signal of the target matches the name"), which silently disables the
    // WHOLE Connections block and with it the pendingMac auto-connect. The
    // guard below therefore tests `Persistent.ready` directly.
    Connections {
        target: Persistent
        function onReadyChanged() {
            if (Persistent.ready)
                root.recordKnownDevices();
        }
    }

    // `Persistent.ready` under a name of its own, because a Connections
    // handler cannot watch another object's property directly.
    readonly property bool persistentReady: Persistent.ready
}



