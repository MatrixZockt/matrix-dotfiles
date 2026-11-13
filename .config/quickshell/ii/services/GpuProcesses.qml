pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * GpuProcesses — WHICH program is using the graphics card, not just how busy
 * the card is as a whole.
 *
 * The task manager could already answer "the card is at 35%" and not "because
 * of what". On a laptop with two graphics chips that gap is the whole question:
 * the card can read a third-busy with nothing deliberately opened, because the
 * desktop shell, the browser's compositor and a mail client's renderer all hold
 * the card open and redraw into it.
 *
 * WHERE THE NUMBERS COME FROM
 * ---------------------------
 * `nvidia-smi pmon -c 1` is the only interface that attributes work to a PID
 * for GRAPHICS clients. `--query-compute-apps` lists compute only, which on a
 * desktop session is usually nothing at all; the plain `nvidia-smi` process
 * table gives memory per PID but no utilisation. pmon gives both kinds, one
 * line per client, with `sm` (shader cores busy, a percentage of the sample
 * window) and `mem` (memory-controller busy).
 *
 * What it does NOT give is memory in bytes; that lives in the process table.
 * The column therefore shows utilisation, which is the number that answers
 * "what is working", and the memory figure stays where it already was — in the
 * card-wide readout (SystemNow's VRAM row).
 *
 * COST, AND WHY IT IS GATED
 * -------------------------
 * Each sample is one process spawn, and nvidia-smi OPENS the device — a card
 * that has managed to reach its low-power state is woken by the read. So this
 * runs only while the task manager's table is actually on screen (`setActive`,
 * the same owner convention ProcessList and HardwareStats use), at 2 s, which
 * is the process table's own cadence. Closed task manager, no spawns, no wakes.
 */
Singleton {
    id: root

    // ── Who is looking ───────────────────────────────────────────────────
    // A SET of owners rather than a flag, for the reason spelled out in
    // ProcessList: with more than one surface able to want these numbers, a
    // bool means the last writer decides for everybody.
    property var _owners: ({})
    readonly property bool active: Object.keys(root._owners).length > 0

    function setActive(owner, want): void {
        const next = Object.assign({}, root._owners);
        if (want)
            next[owner] = true;
        else
            delete next[owner];
        const wasActive = root.active;
        root._owners = next;
        // First surface in gets a reading straight away instead of an empty
        // column for two seconds.
        if (!wasActive && root.active)
            root.poll();
    }

    // ── State ────────────────────────────────────────────────────────────
    // True once a sample actually named at least one client. A machine with no
    // NVIDIA card (or no driver) reads false, and the column shows "—" rather
    // than a wall of zeroes that would look like measured idleness.
    property bool available: false
    // pid -> { sm, mem }, replaced wholesale per sample.
    property var perPid: ({})
    // Bumped per sample so views (and ProcessList's row builder) re-evaluate.
    property int revision: 0

    /**
     * The card's utilisation for one row: the SUM over the row's processes.
     *
     * A grouped row is an application, and an application can be several
     * clients (a browser's gpu-process plus its renderers), so the row means
     * "what this app is doing to the card", which is the sum. Capped at 100
     * because two processes at 60% each is not 120% of a card.
     */
    function percentFor(pids): real {
        if (!pids || pids.length === 0)
            return 0;
        const table = root.perPid;
        let sum = 0;
        for (let i = 0; i < pids.length; i++) {
            const entry = table[pids[i]];
            if (entry)
                sum += entry.sm;
        }
        return Math.min(100, sum);
    }

    function parse(text): void {
        const next = {};
        let named = false;
        const lines = String(text ?? "").split("\n");
        for (const line of lines) {
            const trimmed = line.trim();
            // "# gpu pid type sm mem enc dec jpg ofa command" is a header, and
            // pmon prints two of them.
            if (trimmed.length === 0 || trimmed.charAt(0) === "#")
                continue;
            const f = trimmed.split(/\s+/);
            // gpu, pid, type, sm, mem at minimum before the command name.
            if (f.length < 5)
                continue;
            const pid = Number(f[1]);
            if (!Number.isFinite(pid) || pid <= 0)
                continue;
            // "-" is pmon's "this client had no activity in the window", which
            // is a real zero, not an unknown: the client is open and idle.
            const sm = f[3] === "-" ? 0 : Number(f[3]);
            const mem = f[4] === "-" ? 0 : Number(f[4]);
            next[pid] = {
                sm: Number.isFinite(sm) ? sm : 0,
                mem: Number.isFinite(mem) ? mem : 0
            };
            named = true;
        }
        root.perPid = next;
        root.available = named;
        root.revision++;
    }

    function poll(): void {
        if (pollProc.running)
            return;
        pollProc.running = true;
    }

    Process {
        id: pollProc
        command: ["sh", "-c", "nvidia-smi pmon -c 1 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: root.parse(this.text)
        }
        // A card that is asleep, a driver that is mid-reset: the read simply
        // yields nothing, and the last known table stays until a sample lands.
        stderr: StdioCollector {}
    }

    Timer {
        // The process table samples on the resources tick (~2 s); matching it
        // means one fresh set of numbers per table rebuild rather than numbers
        // that move under a table that is not being rebuilt.
        interval: 2000
        repeat: true
        running: root.active
        triggeredOnStart: true
        onTriggered: root.poll()
    }
}
