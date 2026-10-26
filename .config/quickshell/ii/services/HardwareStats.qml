pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * The half of the machine the resource graphs never looked at.
 *
 * ResourceUsage answers two questions: how busy is the processor, and how full is
 * the memory. On a machine that also has a graphics chip, a disk and a network
 * card that is not a picture of the machine -- it is a picture of a third of it,
 * which is exactly why the resource view used to read as "CPU only".
 *
 * This service fills the rest in, in two halves:
 *
 *   * what the hardware *is* -- processor name and thread count, graphics chip,
 *     every physical disk, every network interface. Discovered once at startup by
 *     a single shell pass; nothing here runs on a timer.
 *   * what it is doing right now -- graphics clock, disk read/write, network
 *     in/out. Those are plain byte counters in /proc and /sys, so they are read as
 *     deltas between two samples rather than as absolute numbers (a counter that
 *     only ever grows says nothing about "now").
 *
 * The sampling hangs off ResourceUsage's existing tick instead of starting a timer
 * of its own, and it only runs while something is actually looking at the numbers
 * (`active`). A closed monitor therefore costs nothing at all -- no process, no
 * file read, no wake-up of its own.
 */
Singleton {
    id: root

    // ── Who is watching ──────────────────────────────────────────────────
    //
    // A SET of owners, not a flag. `active` used to be a plain bool that every
    // surface wrote for itself, so the last writer decided for everybody: the
    // overlay closing set it false while the settings window's task manager was
    // still open, and that page's sampling stopped dead with no way for it to
    // know or to ask again. Three surfaces want these numbers now (the overlay
    // widget, the task manager, and the island's System tab), which is past the
    // point where a bool can say what is meant. Same convention as
    // ProcessList.setActive, so the shell has one way to say "I am looking".
    property var _watchers: ({})
    // True while ANYONE is looking. Nothing is sampled otherwise.
    readonly property bool active: Object.keys(root._watchers).length > 0

    function setActive(owner, want) {
        const next = Object.assign({}, root._watchers);
        if (want)
            next[owner] = true;
        else
            delete next[owner];
        const wasActive = root.active;
        root._watchers = next;
        // Prime the counters on the way in, but only when nothing has been read
        // yet. The rates below are DELTAS between two samples, so the first
        // numbers after a cold start are whatever a gap with no previous
        // reading averages to -- on a fresh session, "0 B/s" under a disk that
        // is working. Calling sample() twice inside one tick instead would
        // divide a ~0 delta by the 0.2 s floor and zero out a real reading, so
        // this fires only when there is no previous sample to measure against.
        if (!wasActive && root.active && root.lastDiskCounters === null)
            root.sample();
        // The RC6 counter keeps counting while nobody is watching. Dropping the
        // baseline on the way IN means the first sample after a closed panel is
        // a new measurement rather than an average over the minutes it was
        // shut, which would draw one bogus spike at the left edge of the graph.
        // (No baseline reset here: the gap test in applyGpuLoad already drops a
        // stale delta, and resetting would guarantee an empty reading for the
        // first second of every open.)
    }
    // Bumped on every sample so bindings reading the arrays below re-evaluate.
    property int revision: 0

    readonly property int historyLength: ResourceUsage.historyLength
    // References the graphs are drawn against. Fixed rather than self-scaling: a
    // graph that silently rescales hides the very thing you are watching for.
    readonly property real diskFullScale: 200 * 1024 * 1024  // 200 MB/s
    readonly property real netFullScale: 10 * 1024 * 1024     // 10 MB/s

    // ── Inventory ────────────────────────────────────────────────────────────
    property bool inventoryReady: false
    property string cpuName: ""
    property int cpuThreads: 0
    property string cpuMaxFreq: ""
    property var gpuNames: []
    property var disks: []     // { name, model, size, readBps, writeBps, maxSeen, history }
    property var networks: []  // { name, rxBps, txBps, maxSeen, history }

    // Graphics clock, when the driver exposes one (Intel and AMD both do).
    property string gpuClockPath: ""
    property string gpuClockMaxPath: ""
    property real gpuClockMhz: -1
    property real gpuClockMaxMhz: -1
    property var gpuHistory: []
    // WHICH CARD that clock belongs to. On a machine with two graphics chips
    // the clock file is ONE card's (`card2/gt_cur_freq_mhz` is the Intel iGPU
    // here) while the set of GPU names is both, so a view that prints the
    // clock beside "the GPU" has to know whether it is describing the card it
    // named -- the mismatch this exists to end (a 4070 reading "1517 MHz"
    // while it sat at 0% with no processes).
    property string gpuClockCard: ""     // /sys/class/drm/cardN/
    property string gpuClockPci: ""      // 0000:00:02.0
    property string gpuClockDriver: ""   // i915 / xe / amdgpu / nvidia

    // ── A graphics chip's busy fraction, when its driver publishes one ────
    //
    // amdgpu's `device/gpu_busy_percent` is a real percentage and the only
    // source trusted here. It is read for the card that owns the clock above,
    // so a row about a chip can lead with that chip's own load instead of a
    // clock that says nothing about how hard it is working.
    //
    // i915's RC6 residency was tried for this and REMOVED (2026-10-23): the
    // counter on this laptop is frozen -- read a second apart,
    // `gt/gt0/rc6_residency_ms` does not advance a single millisecond -- so
    // 1 - idle/wall evaluated to a permanent 100%. That is how the GPU tile
    // came to read "Intel Graphics 100%" on an idle machine: not a busy chip,
    // a dead counter. A number that is always 100% is worse than no number,
    // because nothing downstream can tell it from a real reading, so the
    // source is gone rather than clamped or special-cased.
    // -1 means "not readable on this machine", the same contract as every
    // other unknown here -- never 0.
    property string gpuLoadKind: ""      // "busy"
    property string gpuLoadPath: ""
    property real gpuLoad: -1
    property var gpuLoadHistory: []

    property var lastDiskCounters: null
    property var lastNetCounters: null
    // Separate clocks on purpose. The disk and the network counters are read from
    // two different files, and each one has to be divided by the time since *its*
    // own previous reading -- sharing one clock makes whichever file finishes
    // second look like it moved its whole counter in a fifth of a second.
    property real lastDiskTime: 0
    property real lastNetTime: 0

    // Runs once at startup. `-P` gives one `KEY="value"` line per disk, which is
    // the whole reason this is a shell script and not a JSON parser: it keeps the
    // parsing in the service, where it can be seen and changed.
    readonly property string inventoryScript: `
printf 'cpu|%s|%s|%s\n' \
    "$(awk -F: '/model name/{sub(/^[ ]+/, "", $2); print $2; exit}' /proc/cpuinfo)" \
    "$(nproc 2>/dev/null)" \
    "$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
lspci 2>/dev/null | grep -iE 'vga|3d|display' | while IFS= read -r line; do
    printf 'gpu|%s\n' "$(printf '%s' "$line" | sed -E 's/^[0-9a-fA-F:.]+ [^:]*: //')"
done
for card in /sys/class/drm/card[0-9]*/; do
    if [ -r "$card/gt_cur_freq_mhz" ]; then
        printf 'gpuclock|%s|%s|%s|%s|%s\n' \
            "$card/gt_cur_freq_mhz" "$card/gt_max_freq_mhz" "$card" \
            "$(basename "$(readlink -f "$card/device" 2>/dev/null)" 2>/dev/null)" \
            "$(grep -o 'DRIVER=[a-zA-Z0-9_]*' "$card/device/uevent" 2>/dev/null | head -1 | cut -d= -f2)"
        break
    fi
done
# A graphics chip's busy fraction, when its driver publishes one honestly:
# amdgpu's gpu_busy_percent, already a percentage. Nothing else is sampled --
# see the gpuLoad block above for why i915's RC6 counter was removed instead
# of being worked around.
for card in /sys/class/drm/card[0-9]*/; do
    if [ -r "$card/device/gpu_busy_percent" ]; then
        printf 'gpuload|busy|%s\n' "$card/device/gpu_busy_percent"
        break
    fi
done
LC_ALL=C lsblk -d -P -o NAME,MODEL,SIZE,TYPE 2>/dev/null | while IFS= read -r line; do
    # zram / loop / ram devices are not disks you read data from. zram is
    # compressed RAM used as swap: on this machine it was a second "Disk" tile
    # permanently reading 0 B/s, which is exactly the kind of tile that made the
    # dashboard look like charts for the sake of charts.
    case "$line" in
    *'NAME="zram'*|*'NAME="loop'*|*'NAME="ram'*) continue ;;
    esac
    case "$line" in *'TYPE="disk"'*) printf 'disk|%s\n' "$line";; esac
done
for net in /sys/class/net/*; do
    name=$(basename "$net")
    # Physical interfaces only: virtual bridges and container links are noise on
    # a traffic dashboard, and there can be a dozen of them.
    case "$name" in
    lo|docker*|veth*|virbr*|br-*|tun*|tap*|wg*) continue ;;
    esac
    printf 'net|%s\n' "$name"
done
`

    Process {
        id: inventoryProc
        running: true
        command: ["bash", "-c", root.inventoryScript]
        stdout: StdioCollector {
            onStreamFinished: root.readInventory(text)
        }
    }

    function field(line, name) {
        const match = line.match(new RegExp(name + '="([^"]*)"'));
        return match ? match[1] : "";
    }

    function newNetwork(name) {
        return {
            name: name,
            rxBps: 0,
            txBps: 0,
            maxSeen: 1,
            history: []
        };
    }

    function readInventory(text) {
        const gpus = [];
        const disks = [];
        const networks = [];
        for (const line of String(text ?? "").split("\n")) {
            if (!line)
                continue;
            const parts = line.split("|");
            switch (parts[0]) {
            case "cpu": {
                root.cpuName = parts[1] ?? "";
                root.cpuThreads = parseInt(parts[2] ?? "0", 10) || 0;
                const khz = parseInt(parts[3] ?? "0", 10) || 0;
                root.cpuMaxFreq = khz > 0 ? `${(khz / 1000000).toFixed(1)} GHz` : "";
                break;
            }
            case "gpu":
                if (parts[1])
                    gpus.push(parts[1]);
                break;
            case "gpuclock":
                root.gpuClockPath = parts[1] ?? "";
                root.gpuClockMaxPath = parts[2] ?? "";
                root.gpuClockCard = parts[3] ?? "";
                root.gpuClockPci = parts[4] ?? "";
                root.gpuClockDriver = parts[5] ?? "";
                break;
            case "gpuload":
                root.gpuLoadKind = parts[1] ?? "";
                root.gpuLoadPath = parts[2] ?? "";
                break;
            case "disk": {
                const name = root.field(parts[1] ?? "", "NAME");
                if (!name)
                    break;
                disks.push({
                    name: name,
                    model: root.field(parts[1] ?? "", "MODEL").trim(),
                    size: root.field(parts[1] ?? "", "SIZE"),
                    readBps: 0,
                    writeBps: 0,
                    maxSeen: 1,
                    history: []
                });
                break;
            }
            case "net":
                if (parts[1])
                    networks.push(root.newNetwork(parts[1]));
                break;
            }
        }
        root.gpuNames = root.rankGpus(gpus);
        root.disks = disks;
        root.networks = networks;
        root.inventoryReady = true;
    }

    // lspci lists the host's VGA devices in bus order, which on an Optimus
    // laptop puts the Intel iGPU FIRST -- and every consumer of gpuNames
    // reads [0] as "the graphics card". On this Razer Blade that meant the
    // island's GPU tile described the iGPU while the machine's real GPU (the
    // one that renders, the one people mean) sat second in the list.
    //
    // rankGpus fixes both halves of that:
    //   * the dGPU leads. Vendor-name match (NVIDIA/GeForce, and discrete
    //     Radeon RX / Arc lines) sorts ahead of everything else -- no model
    //     is hardcoded; whatever dGPU the machine carries wins.
    //   * the name is the human one. lspci prints a chip code plus the
    //     marketing name in brackets ("AD106M [GeForce RTX 4070 Max-Q /
    //     Mobile]"); the bracket content is what a spec sheet and a human
    //     both call the card, so when brackets exist they replace the raw
    //     line. Intel entries carry no brackets and pass through verbatim.
    function rankGpus(list) {
        const cleaned = (list ?? []).map(n => {
            // The model is the LAST bracket group: AMD/ATI lines carry a
            // vendor-alias bracket first ("[AMD/ATI] Navi 31 [Radeon RX
            // 7900 XTX]"), and taking the first bracket would print the
            // vendor. Lines with no brackets (Intel) pass through verbatim.
            const matches = String(n).match(/\[([^\]]+)\]/g);
            if (matches && matches.length > 0)
                return matches[matches.length - 1].slice(1, -1).trim();
            return String(n);
        });
        const score = n => /nvidia|geforce|radeon rx|arc a\d/i.test(n) ? 0 : 1;
        return cleaned.slice().sort((a, b) => score(a) - score(b));
    }

    // ── Sampling ─────────────────────────────────────────────────────────────
    // One tick of the resource service, when there is something to show it to.
    Connections {
        target: ResourceUsage
        function onTick() {
            if (root.active)
                root.sample();
        }
    }

    // Counted so the probe can tell "the sampler never ran" from "the sampler
    // ran and had nothing to say", which look identical from the outside.
    property int sampleCount: 0

    function sample() {
        if (!root.inventoryReady)
            return;
        root.sampleCount++
        diskstatsFile.reload();
        netdevFile.reload();
        if (root.gpuClockPath !== "")
            gpuClockFile.reload();
        if (root.gpuLoadPath !== "")
            gpuLoadFile.reload();
    }

    // One handler each, not two. Both `onLoaded` and `onTextChanged` fire for the
    // same reload (the new text is what announced the load), so handling both ran
    // the delta maths twice per tick -- the second pass comparing a counter with
    // itself and overwriting the true rate with zero. `onLoaded` alone is exactly
    // one measurement per reload.
    FileView {
        id: diskstatsFile
        path: "/proc/diskstats"
        onLoaded: root.applyDiskCounters(text())
    }

    FileView {
        id: netdevFile
        path: "/proc/net/dev"
        onLoaded: root.applyNetCounters(text())
    }

    FileView {
        id: gpuClockFile
        path: root.gpuClockPath === "" ? "/dev/null" : root.gpuClockPath
        onLoaded: root.applyGpuClock(text())
    }

    FileView {
        id: gpuClockMaxFile
        path: root.gpuClockMaxPath === "" ? "/dev/null" : root.gpuClockMaxPath
        onLoaded: root.applyGpuClockMax(text())
        onTextChanged: root.applyGpuClockMax(text())
    }

    FileView {
        id: gpuLoadFile
        path: root.gpuLoadPath === "" ? "/dev/null" : root.gpuLoadPath
        // A machine whose driver publishes no load has no file to read, and
        // "Read of /dev/null failed" once per reload is noise about a state
        // that is correct. A path that EXISTS and then fails still prints.
        printErrors: root.gpuLoadPath !== ""
        onLoaded: root.applyGpuLoad(text())
    }
    // Sectors are 512 bytes here by definition, whatever the device's own sector
    // size is, so the counter converts to bytes with a fixed number.
    function applyDiskCounters(text) {
        const counters = {};
        for (const line of String(text ?? "").split("\n")) {
            const fields = line.trim().split(/\s+/);
            if (fields.length < 14)
                continue;
            const name = fields[2];
            counters[name] = {
                read: (parseInt(fields[5], 10) || 0) * 512,
                write: (parseInt(fields[9], 10) || 0) * 512
            };
        }
        const previous = root.lastDiskCounters;
        const now = Date.now();
        const span = previous ? Math.max(0.2, (now - root.lastDiskTime) / 1000) : 0;
        root.lastDiskCounters = counters;
        root.lastDiskTime = now;
        if (!previous)
            return;
        const updated = root.disks.map(disk => {
            const before = previous[disk.name];
            const after = counters[disk.name];
            if (!before || !after)
                return disk;
            const readBps = Math.max(0, (after.read - before.read) / span);
            const writeBps = Math.max(0, (after.write - before.write) / span);
            const maxSeen = Math.max(disk.maxSeen, readBps, writeBps);
            const history = disk.history.concat([Math.min(1, Math.max(readBps, writeBps) / root.diskFullScale)]).slice(-root.historyLength);
            return Object.assign({}, disk, { readBps: readBps, writeBps: writeBps, maxSeen: maxSeen, history: history });
        });
        root.disks = updated;
        root.revision++;
    }

    function applyNetCounters(text) {
        const counters = {};
        for (const line of String(text ?? "").split("\n")) {
            const colon = line.indexOf(":");
            if (colon < 0)
                continue;
            const name = line.slice(0, colon).trim();
            const fields = line.slice(colon + 1).trim().split(/\s+/);
            if (fields.length < 9)
                continue;
            counters[name] = {
                rx: parseInt(fields[0], 10) || 0,
                tx: parseInt(fields[8], 10) || 0
            };
        }
        const previous = root.lastNetCounters;
        const now = Date.now();
        const span = previous ? Math.max(0.2, (now - root.lastNetTime) / 1000) : 0;
        root.lastNetCounters = counters;
        root.lastNetTime = now;
        if (!previous)
            return;
        const updated = root.networks.map(net => {
            const before = previous[net.name];
            const after = counters[net.name];
            if (!before || !after)
                return net;
            const rxBps = Math.max(0, (after.rx - before.rx) / span);
            const txBps = Math.max(0, (after.tx - before.tx) / span);
            const maxSeen = Math.max(net.maxSeen, rxBps, txBps);
            const history = net.history.concat([Math.min(1, Math.max(rxBps, txBps) / root.netFullScale)]).slice(-root.historyLength);
            return Object.assign({}, net, { rxBps: rxBps, txBps: txBps, maxSeen: maxSeen, history: history });
        });
        root.networks = updated;
        root.revision++;
    }

    function applyGpuClock(text) {
        const value = parseInt(String(text ?? "").trim(), 10);
        root.gpuClockMhz = isNaN(value) ? -1 : value;
        if (root.gpuClockMaxMhz <= 0)
            return;
        const fraction = Math.min(1, Math.max(0, root.gpuClockMhz / root.gpuClockMaxMhz));
        root.gpuHistory = root.gpuHistory.concat([fraction]).slice(-root.historyLength);
        root.revision++;
    }

    function applyGpuClockMax(text) {
        const value = parseInt(String(text ?? "").trim(), 10);
        root.gpuClockMaxMhz = isNaN(value) ? -1 : value;
    }

    function applyGpuLoad(text) {
        const raw = parseFloat(String(text ?? "").replace(/[^0-9.]/g, ""));
        if (isNaN(raw)) {
            root.gpuLoad = -1;
            return;
        }
        // Only an already-a-percentage source reaches this point.
        if (root.gpuLoadKind !== "busy")
            return;
        const load = raw / 100;
        root.gpuLoad = Math.max(0, Math.min(1, load));
        root.gpuLoadHistory = root.gpuLoadHistory.concat([root.gpuLoad]).slice(-root.historyLength);
        root.revision++;
    }

    // Read-only probe, in the same spirit as the other services' `state()`:
    // what the GPU numbers ARE, so a wrong one can be diagnosed from a
    // terminal instead of by looking at a graph and guessing.
    //
    //   qs -c ii ipc call hardwareStats gpu
    IpcHandler {
        target: "hardwareStats"

        function gpu(): string {
            const pct = root.gpuLoad >= 0 ? `${(root.gpuLoad * 100).toFixed(0)}%` : "--";
            return `active=${root.active} samples=${root.sampleCount} `
                 + `card=${root.gpuClockCard} pci=${root.gpuClockPci} driver=${root.gpuClockDriver} `
                 + `clock=${root.gpuClockMhz}/${root.gpuClockMaxMhz} `
                 + `loadKind=${root.gpuLoadKind} loadPath=${root.gpuLoadPath} load=${pct} `
                 + `n=${root.gpuLoadHistory.length} historyTail=${root.gpuLoadHistory.length > 0 ? (root.gpuLoadHistory[root.gpuLoadHistory.length - 1] * 100).toFixed(0) : "--"}`;
        }
    }

    // ── Printing ─────────────────────────────────────────────────────────────
    function formatBytes(bytes) {
        const value = Number(bytes) || 0;
        if (value < 1024)
            return `${value.toFixed(0)} B/s`;
        if (value < 1024 * 1024)
            return `${(value / 1024).toFixed(1)} KB/s`;
        if (value < 1024 * 1024 * 1024)
            return `${(value / 1024 / 1024).toFixed(1)} MB/s`;
        return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB/s`;
    }
}
