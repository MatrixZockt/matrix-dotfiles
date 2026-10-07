pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

/**
 * RazerService — the shell's bridge to Razer Command Center.
 *
 * Why a Process and not a DBus client: the Command Center owns the open
 * razer devices; concurrent access from two processes is exactly the kind
 * of fight that ends with a wedged daemon. Every mutation goes through the
 * app's own headless CLI (--use-profile / --kbd-brightness / --set-profile /
 * --autodim), which serializes behind the app's logic. The store
 * (~/.config/razer-command-center/lighting.json) is read here only to name
 * and count the profiles for the switcher chips.
 */
Singleton {
    id: root

    // ── lighting profiles (read-only mirror of the app's store) ─────────
    property var profiles: []            // [{name, keys?, color}]
    property int active: 0
    property bool loading: false

    // ── keyboard state (mirrors the daemon via the app's CLI) ───────────
    property int kbdBrightness: 25
    property bool kbdLightOn: true

    // ── power profile passthrough (powerprofilesctl) ────────────────────
    property string powerProfile: "balanced"
    readonly property var powerProfiles: [
        { value: "performance", name: "Performance", icon: "local_fire_department", color: "#e5534b" },
        { value: "balanced",    name: "Balanced",    icon: "balance",               color: "#3fb950" },
        { value: "power-saver", name: "Power Saver", icon: "energy",                color: "#3f8cfe" }
    ]
    readonly property var powerIcon: (root.powerProfiles.find(p => p.value === root.powerProfile)
                                      ?? root.powerProfiles[1]).icon
    readonly property var powerColor: (root.powerProfiles.find(p => p.value === root.powerProfile)
                                       ?? root.powerProfiles[1]).color

    // ── store reader ────────────────────────────────────────────────────
    FileView {
        id: storeView
        path: `${Quickshell.env("HOME")}/.config/razer-command-center/lighting.json`
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: (error) => { root.loading = false; }

        onLoaded: {
            root.loading = false;
            try {
                const data = JSON.parse(storeView.text());
                const list = (data.profiles ?? []).map((p, i) => {
                    // A representative color per profile: the first painted
                    // key wins; a painted profile always has one.
                    let color = "#3fb950";
                    const keys = p.keys ?? {};
                    for (const k in keys) { color = keys[k]; break; }
                    return { name: p.name ?? `Profile ${i + 1}`, color: color };
                });
                root.profiles = list;
                root.active = Math.max(0, Math.min(data.active ?? 0, list.length - 1));
            } catch (e) {
                root.profiles = [];
            }
        }
    }

    function refresh() {
        root.loading = true;
        storeView.reload();
    }

    // ── power / GPU / hardware readout ───────────────────────────────────
    // A file, not a Process. The app is already resident for the whole
    // session and already republishes this snapshot every 5 s; asking it for
    // the same thing over its CLI would cost ~460 ms per call, because its
    // module level imports pull in Gtk and Adw before any argument is read.
    // Reading a file the app maintains costs nothing and cannot block.
    property bool powerLoaded: false
    property bool acOnline: false
    property int batteryPct: -1
    property string batteryStatus: ""
    property real batteryWatts: NaN        // NaN = not reported, not zero
    property int batteryCycles: -1
    property string batteryWallTime: ""
    property bool batteryWallTimeEstimated: false
    property string gpuState: "?"
    property real gpuLoad: NaN
    property real gpuWatts: NaN
    property string gpuPstate: ""
    property real gpuTempC: NaN
    property real gpuVramMb: NaN
    property string cpuModel: ""
    property string gpuName: ""
    property real ramTotalGb: NaN
    property string device: ""
    property string wallWattsReason: ""

    readonly property bool gpuAwake: gpuState === "active"
    // What the app means by "asleep": the DRM runtime status, straight from
    // sysfs. Not an estimate -- when this says suspended the card really has
    // no client holding it open.
    readonly property bool gpuAsleep: gpuState === "suspended"
        || gpuState === "suspending"

    FileView {
        id: powerView
        path: `${Quickshell.env("HOME")}/.config/razer-command-center/power.json`
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: (error) => { root.powerLoaded = false; }
        onLoaded: root.ingestPower(powerView.text())
    }

    /** Turn the published snapshot into properties, defensively.
     *
     * Every numeric field goes through `num()` because the app sends null
     * for anything the firmware does not report, and JSON null becomes NaN
     * here. NaN is the point: the panel draws a dash for a reading nobody
     * took, which is a different statement from "0 W".
     */
    function ingestPower(text) {
        let d;
        try { d = JSON.parse(text ?? ""); } catch (e) { return; }
        if (!d || typeof d !== "object") return;
        const num = (v) => (typeof v === "number" && isFinite(v)) ? v : NaN;
        root.acOnline = d.ac_online === true;
        root.batteryPct = num(d.battery_pct);
        root.batteryStatus = d.battery_status ?? "";
        root.batteryWatts = num(d.battery_watts);
        root.batteryCycles = num(d.battery_cycles);
        root.batteryWallTime = d.battery_wall_time ?? "";
        root.batteryWallTimeEstimated = d.battery_wall_time_estimated === true;
        root.gpuState = d.gpu_state ?? "?";
        root.gpuLoad = num(d.gpu_load);
        root.gpuWatts = num(d.gpu_watts);
        root.gpuPstate = d.gpu_pstate ?? "";
        root.gpuTempC = num(d.gpu_temp_c);
        root.gpuVramMb = num(d.gpu_vram_mb);
        root.cpuModel = d.cpu_model ?? "";
        root.gpuName = d.gpu_name ?? "";
        root.ramTotalGb = num(d.ram_total_gb);
        root.device = d.device ?? "";
        root.wallWattsReason = d.wall_watts_reason ?? "";
        root.powerLoaded = true;
    }

    /** "12 W" / "--" -- the only formatter the power tiles need. */
    function watts(v) {
        return isFinite(v) ? `${Math.round(v)} W` : "--";
    }

    // ── mutations: always through the app's CLI, never direct hw access ──
    function useProfile(idx) {
        root.active = idx;
        Quickshell.execDetached(["razer-command-center", "--use-profile", String(idx)]);
    }

    function setKbdBrightness(v) {
        root.kbdBrightness = Math.max(0, Math.min(100, Math.round(v)));
        Quickshell.execDetached(["razer-command-center", "--kbd-brightness", String(root.kbdBrightness)]);
    }

    function setKbdLight(on) {
        root.kbdLightOn = on;
        Quickshell.execDetached(["razer-command-center", "--kbd-light", on ? "on" : "off"]);
    }

    function setPowerProfile(value) {
        root.powerProfile = value;
        Quickshell.execDetached(["razer-command-center", "--set-profile", value]);
    }

    // ── power profile poller (3 s, cheap: powerprofilesctl reads dbus) ──
    Process {
        id: profilePoll
        command: ["powerprofilesctl", "get"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t.length > 0)
                    root.powerProfile = t;
            }
        }
    }
    Timer {
        interval: 3000
        running: true
        repeat: true
        onTriggered: profilePoll.running = true
    }

    // ── keyboard state poller (10 s, sysfs read, wakes nothing) ─────────
    Process {
        id: kbdPoll
        command: ["bash", "-c",
                  "b=$(cat /sys/bus/hid/drivers/razerkbd/*/matrix_brightness 2>/dev/null | head -1); " +
                  "m=$(cat /sys/bus/hid/drivers/razerkbd/*/matrix_brightness_max 2>/dev/null | head -1); " +
                  "[ -n \"$b\" ] && [ -n \"$m\" ] && echo $((b * 100 / m)) || echo -"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t !== "" && t !== "-") {
                    const v = parseInt(t);
                    if (!isNaN(v)) {
                        root.kbdBrightness = v;
                        root.kbdLightOn = v > 0;
                    }
                }
            }
        }
    }
    Timer {
        interval: 10000
        running: true
        repeat: true
        onTriggered: kbdPoll.running = true
    }

    Component.onCompleted: refresh()
}
