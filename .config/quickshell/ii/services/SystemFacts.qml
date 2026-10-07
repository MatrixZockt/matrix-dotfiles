pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

/**
 * What this machine IS, as opposed to what it is doing.
 *
 * `HardwareStats` reads live figures (usage, clocks, throughput) and cannot say
 * which processor it is reading them from. A task manager that shows "CPU 12%"
 * and nothing else is missing half of the answer, which is the half people
 * actually open it for: which chip, how many real cores, which driver, what
 * model of disk, how much memory and how fast.
 *
 * All of it comes from one run of scripts/system/facts.py, read once at startup
 * and cached -- none of it changes while the machine is on, so re-reading it on
 * a timer would be reading the same bytes to get the same answer.
 */
Singleton {
    id: root

    property var facts: ({})
    property bool ready: false
    property bool failed: false

    readonly property var system: facts.system ?? ({})
    readonly property var cpu: facts.cpu ?? ({})
    readonly property var memory: facts.memory ?? ({})
    readonly property var gpus: facts.gpus ?? []
    readonly property var disks: facts.disks ?? []
    readonly property var networks: facts.networks ?? []
    readonly property var batteries: facts.batteries ?? []
    readonly property var temperatures: facts.temperatures ?? []
    readonly property var displays: facts.displays ?? []

    readonly property var connectedDisplays: displays.filter(display => display.connected)

    function apply(text) {
        try {
            root.facts = JSON.parse(text);
            root.ready = true;
            root.failed = false;
        } catch (error) {
            // A parse failure means the script printed something other than its
            // JSON -- a traceback, most likely. Keep the previous facts rather
            // than blanking every spec line on screen.
            root.failed = true;
            console.log("[SystemFacts] could not read the hardware facts:", error);
        }
    }

    function refresh() {
        root.failed = false;
        reader.running = true;
    }

    // Bytes as people read them.
    //
    // A plain amount, NOT a rate: `HardwareStats.formatBytes` exists for the disk
    // and network graphs and says "MB/s" on the end of everything it is given,
    // which is right for a throughput and wrong for "this disk is 256 GB".
    function bytes(value) {
        const amount = Number(value) || 0;
        const units = ["B", "KB", "MB", "GB", "TB", "PB"];
        let index = 0;
        let scaled = amount;
        while (scaled >= 1024 && index < units.length - 1) {
            scaled /= 1024;
            index++;
        }
        const decimals = index === 0 ? 0 : (scaled < 10 ? 1 : 0);
        return `${scaled.toFixed(decimals)} ${units[index]}`;
    }

    // Battery capacities are read from /sys in milliwatt-hours, which is the one
    // unit on this page that is neither a byte nor a hertz: 31620 mWh is a 31.6 Wh
    // battery, and printing that through the byte formatter said "30.2 MB".
    function wattHours(value) {
        const mwh = Number(value) || 0;
        if (mwh >= 1000)
            return `${(mwh / 1000).toFixed(1)} Wh`;
        return `${mwh.toFixed(0)} mWh`;
    }

    // "3d 4h 12m" -- the machine's uptime, which is the one spec that is not a
    // fixed fact but belongs next to them.
    function uptime(seconds) {
        const total = Math.max(0, Math.round(seconds ?? 0));
        const days = Math.floor(total / 86400);
        const hours = Math.floor((total % 86400) / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        if (days > 0)
            return `${days}d ${hours}h ${minutes}m`;
        if (hours > 0)
            return `${hours}h ${minutes}m`;
        return `${minutes}m`;
    }

    function batteryHealth(battery) {
        const design = battery?.energyFullDesign ?? 0;
        const full = battery?.energyFull ?? 0;
        if (design <= 0 || full <= 0)
            return "";
        return Math.round((full / design) * 100) + "%";
    }

    IpcHandler {
        target: "systemFacts"

        function refresh(): void {
            root.refresh();
        }
    }

    Process {
        id: reader
        running: true
        command: ["python3", `${Directories.scriptPath}/system/facts.py`]
        stdout: StdioCollector {
            onStreamFinished: root.apply(text)
        }
    }
}
