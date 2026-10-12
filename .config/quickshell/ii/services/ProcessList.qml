pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.services

/**
 * The process table behind the task manager.
 *
 * Sampling is on purpose, not continuous: reading every process on the machine
 * costs a process of its own (scripts/system/processes.py), so it only runs
 * while the card that shows the result is actually on screen, and only every
 * other resources tick (~2s). A task manager closed is a task manager that
 * costs nothing.
 *
 * Sorting, filtering and grouping happen here rather than in the view: the list
 * is one array of plain objects, and "which is heaviest" is a question about the
 * data, not about the widgets drawing it. The view asks for `rows` and draws
 * what it gets, which is also what makes the same table work whether it is
 * grouped by application or flat.
 *
 * Grouping is the one idea borrowed wholesale from the other task manager
 * people know: one row per application, its helpers folded into it, because
 * "why is my fan on" is answered by "Electron 40%" and never by four identical
 * renderer rows.
 */
Singleton {
    id: root

    // Which surfaces currently WANT the sampler running. `active` used to be
    // a plain writable bool, and with three writers the last one to write
    // won: the desktop overview armed it on open and never released it, so a
    // single look at the workspace grid left the process sampler running its
    // python subprocess + full rebuild every ~2 s for the rest of the session
    // -- the "costs nothing when closed" contract above was only true until
    // the first overview open. Owners register and release themselves;
    // `active` is true while ANY of them still wants the table.
    property var _activeOwners: ({})
    readonly property bool active: Object.keys(_activeOwners).length > 0
    function setActive(owner, want): void {
        const next = Object.assign({}, root._activeOwners);
        if (want)
            next[owner] = true;
        else
            delete next[owner];
        const wasActive = root.active;
        root._activeOwners = next;
        // The FIRST surface to ask for the table gets it now, not on the next
        // resources tick pair. Sampling is driven by that tick (see below), so
        // without this the task manager opened onto "Reading the process
        // list..." for up to 2 s + the 0.35 s sample -- measured 1.5-2.5 s of
        // empty table on every open, which is what "opening it lags" feels
        // like. One sample on the way in; the tick keeps it fresh after.
        if (!wasActive && root.active)
            root.sample();
    }

    property var processes: []
    // Bumped on every successful sample, so the view can re-evaluate anything
    // it derives from the list.
    property int revision: 0
    property bool sampling: false
    // The last snapshot text that parsed successfully. apply() compares
    // against it so an unchanged table skips the whole revision cascade
    // (filter, sort, row rebuild, view model swap) instead of paying it to
    // learn nothing moved.
    property string lastSnapshot: ""

    property string query: ""
    property string sortKey: "cpu"       // "cpu" | "memory" | "name" | "user" | "pid"
    property bool sortAscending: false

    // Applications folded into one row. OFF by default now.
    //
    // It used to be on, on the reasoning that the grouped view answers "what
    // is eating the machine". In practice it was the wrong default for a task
    // manager: every row was a folder that had to be expanded before the
    // process you actually wanted to end was visible, the per-process rows
    // were hidden behind chevrons, and acting on a GROUP row kills the app's
    // main pid -- which respawns its workers, so the app comes straight back
    // and the kill reads as "it didn't work".
    //
    // One row per process is what a task manager is for: find the process,
    // click it once, end it. The toggle above is kept for looking at the
    // whole app at once, and it is now opt-in rather than the default.
    property bool grouped: false
    property var expandedGroups: []

    // The last refusal, in words. Set when a kill is rejected (a process owned
    // by another user, or one the kernel protects) and cleared on the next
    // successful action, so the card can stay honest without a dialog.
    property string lastError: ""
    property string lastErrorSubject: ""

    readonly property int count: processes.length

    // The classes of apps with a window open RIGHT NOW, normalized. The Apps
    // page sorts these to the top: "what am I running" is the question that
    // page answers, and the thing you opened five minutes ago should not be
    // buried under a hundred helper processes. Reads the shell's live window
    // list (HyprlandData refreshes on every compositor event), so a group
    // created by opening a window floats up within a second.
    readonly property var openWindowClasses: {
        const _ = HyprlandData.windowList;
        const set = {};
        for (let i = 0; i < (HyprlandData.windowList ?? []).length; i++) {
            const cls = normalizeName(HyprlandData.windowList[i]?.class ?? "");
            if (cls.length > 0) set[cls] = true;
        }
        return set;
    }

    // Names differ by convention everywhere: the window class is
    // "@codebuff/freebuff-desktop" while the process group is
    // "@codebufffreebuff-desktop", the class is "brave-browser" while the
    // binary is "brave". Comparing the raw strings missed both (observed in
    // a live probe). Normalizing to [a-z0-9] and allowing either side to
    // contain the other catches package-vs-binary naming without ever
    // matching "code" against "codebuff" -- wait, it does, which is why the
    // containment needs BOTH directions gated on the SHORTER name being at
    // least 4 characters: single/two-letter groups like "qs" would match
    // almost anything otherwise.
    function normalizeName(s) {
        return String(s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
    }

    function isWindowed(name) {
        const n = normalizeName(name);
        if (n.length === 0) return false;
        if (openWindowClasses[n] === true) return true;
        for (const cls in openWindowClasses) {
            if (cls.length < 4 && n.length < 4) continue;
            if ((cls.length >= 4 && cls.indexOf(n) >= 0)
                || (n.length >= 4 && n.indexOf(cls) >= 0))
                return true;
        }
        return false;
    }

    // The desktop-entry icon for a row's app, resolved once per call and
    // cached by Quickshell's own icon path cache. Falls through to the shell's
    // generic app glyph for anything without a desktop entry (AppImages and
    // helpers), and to the Material glyph the flat Processes page uses.
    //
    // Memoised HERE as well, by name: with grouping on, one sample asks for an
    // icon per GROUP (500+ on this machine), and the two caches together were
    // still the difference between a 170 ms sample and a 365 ms one -- measured
    // flat vs grouped on the same table. One object lookup per row instead.
    property var iconCache: ({})
    function iconFor(row) {
        if (!root.grouped || row.kind !== "group")
            return null; // the view shows its Material glyph
        const name = String(row.name ?? "");
        if (name.length === 0) return null;
        if (Object.prototype.hasOwnProperty.call(root.iconCache, name))
            return root.iconCache[name];
        const url = Quickshell.iconPath(AppSearch.guessIcon(name), "");
        const value = url === "" ? null : url;
        const next = Object.assign({}, root.iconCache);
        next[name] = value;
        root.iconCache = next;
        return value;
    }
    readonly property real totalCpu: {
        const _ = root.revision;
        return root.processes.reduce((sum, process) => sum + (process.cpu ?? 0), 0);
    }
    readonly property real totalMemory: {
        const _ = root.revision;
        return root.processes.reduce((sum, process) => sum + (process.memory ?? 0), 0);
    }
    // Everything owned by the user, which is what "my" total means in a task
    // manager: the kernel's own threads are not what you are trying to account
    // for when something is eating the machine.
    readonly property real userCpu: {
        const _ = root.revision;
        return root.processes.filter(p => p.user === SystemInfo.username)
            .reduce((sum, process) => sum + (process.cpu ?? 0), 0);
    }

    function matches(process) {
        const query = root.query.trim().toLowerCase();
        if (query.length === 0)
            return true;
        return (process.app ?? "").toLowerCase().includes(query)
            || (process.name ?? "").toLowerCase().includes(query)
            || (process.command ?? "").toLowerCase().includes(query)
            || String(process.pid).includes(query)
            || (process.user ?? "").toLowerCase().includes(query);
    }

    // One comparator, so a group and a process sort by the same rule and the
    // header arrows mean the same thing in both views.
    // NOTE: `filtered` inlines this same arithmetic on purpose (a QML call per
    // comparison was the hot cost); if this function changes, change it there.
    function compare(left, right, key, direction) {
        if (key === "name" || key === "user") {
            const a = String(left[key] ?? "").toLowerCase();
            const b = String(right[key] ?? "").toLowerCase();
            return a < b ? -direction : a > b ? direction : 0;
        }
        return ((left[key] ?? 0) - (right[key] ?? 0)) * direction;
    }

    readonly property var filtered: {
        const _ = root.revision;
        const key = root.sortKey;
        const direction = root.sortAscending ? 1 : -1;
        const src = root.processes;
        // The comparator is INLINED from compare() below (keep the two in
        // sync) because a QML function call per comparison -- n log n of them
        // per sample -- was the bulk of this binding's measured ~0.5 s per
        // revision. A plain JS closure is the same arithmetic at ~0 cost.
        const cmp = (a, b) => {
            if (key === "name" || key === "user") {
                const x = String(a[key] ?? "").toLowerCase();
                const y = String(b[key] ?? "").toLowerCase();
                return x < y ? -direction : x > y ? direction : 0;
            }
            return ((a[key] ?? 0) - (b[key] ?? 0)) * direction;
        };
        // The empty query is the steady state: nobody is typing in a table
        // that sits open. One copy + the inlined sort, with no per-row
        // matches() call (each of those re-trims the same query too).
        if (root.query.trim().length === 0)
            return src.slice().sort(cmp);
        return src.filter(root.matches).sort(cmp);
    }

    // The rows the table draws. A flat array either way, so the view is always a
    // ListView with one delegate; a group's children are the rows after it, and
    // the `depth` is what indents them.
    readonly property var rows: {
        const _ = root.revision;
        const list = root.filtered;
        if (!root.grouped) {
            return list.map(process => ({
                kind: "process",
                depth: 0,
                key: "pid:" + process.pid,
                process: process,
                name: process.app ?? process.name,
                pid: process.pid,
                pids: [process.pid],
                user: process.user,
                state: process.state,
                cpu: process.cpu,
                memory: process.memory
            }));
        }

        // Fold by application name. Plain objects rather than a Map: this runs
        // in the QML engine, where the safe subset is what the language-ish
        // parts of ECMAScript guarantee, and an object with a parallel key order
        // is the same thing with none of the doubt.
        const buckets = {};
        const order = [];
        for (const process of list) {
            const key = (process.app ?? process.name ?? "?").toLowerCase();
            if (buckets[key] === undefined) {
                buckets[key] = [];
                order.push(key);
            }
            buckets[key].push(process);
        }

        const groups = order.map(key => {
            const members = buckets[key];
            const heaviest = members.reduce((best, p) => (p.cpu > best.cpu ? p : best), members[0]);
            return {
                kind: "group",
                depth: 0,
                key: "app:" + key,
                name: members[0].app ?? members[0].name,
                pid: heaviest.pid,
                pids: members.map(p => p.pid),
                user: heaviest.user,
                // The state of the busiest member, not blank: with grouping on
                // -- the default -- a blank Status column would be a column of
                // nothing, and "what is this application doing" is exactly what
                // the column is for.
                state: heaviest.state,
                cpu: members.reduce((sum, p) => sum + (p.cpu ?? 0), 0),
                memory: members.reduce((sum, p) => sum + (p.memory ?? 0), 0),
                count: members.length,
                expanded: root.expandedGroups.includes(key),
                members: members
            };
        });

        const key = root.sortKey;
        const direction = root.sortAscending ? 1 : -1;
        // The chosen column is the ORDER -- over every application, top to
        // bottom -- and having a window open only breaks TIES inside it.
        //
        // It used to be a TIER: windowed groups were lifted above everything
        // else and sorted among themselves, so clicking CPU or Memory put
        // some other application on top. The column said "most used first" and
        // the page answered "what you have open, then the rest", which reads
        // as the sort doing nothing -- and when the biggest consumer on the
        // machine is a background one (a model server, an indexer) it is
        // buried under every open window. "What am I running" is still
        // answered by this page, by the rows themselves; it is no longer an
        // ordering rule that overrides the one the user picked.
        //
        // Resolved ONCE per group, before the sort, for two reasons that are
        // both measured: asking inside the comparator is ~9,000 answers for
        // 500 groups (n log n of them), and each answer walks the window set
        // with two-sided containment over normalized names. And the
        // comparator itself is INLINED here for the same reason `filtered`
        // inlines it below -- a QML function call per comparison was the bulk
        // of that binding's cost. Together this is the whole difference
        // between the flat page's ~170 ms sample and the grouped page's
        // ~365 ms one: the shell's UI thread stalls for that long every
        // sample, and a stall that lands mid-animation reads as the whole
        // bar freezing.
        const windowed = {};
        for (const g of groups)
            windowed[g.name] = root.isWindowed(g.name) ? 1 : 0;
        const cmp = (a, b) => {
            if (key === "name" || key === "user") {
                const x = String(a[key] ?? "").toLowerCase();
                const y = String(b[key] ?? "").toLowerCase();
                return x < y ? -direction : x > y ? direction : 0;
            }
            return ((a[key] ?? 0) - (b[key] ?? 0)) * direction;
        };
        groups.sort((a, b) => {
            const order = cmp(a, b);
            if (order !== 0)
                return order;
            const wa = windowed[a.name] ?? 0;
            const wb = windowed[b.name] ?? 0;
            return wb - wa;
        });

        const rows = [];
        for (const group of groups) {
            rows.push(group);
            if (!group.expanded)
                continue;
            for (const process of group.members) {
                rows.push({
                    kind: "process",
                    depth: 1,
                    key: "pid:" + process.pid,
                    process: process,
                    name: process.app ?? process.name,
                    pid: process.pid,
                    pids: [process.pid],
                    user: process.user,
                    state: process.state,
                    cpu: process.cpu,
                    memory: process.memory
                });
            }
        }
        return rows;
    }

    function setSort(key) {
        if (root.sortKey === key)
            root.sortAscending = !root.sortAscending;
        else {
            root.sortKey = key;
            // Numeric columns read best biggest-first, names read best A-Z.
            root.sortAscending = key === "name" || key === "user";
        }
    }

    function toggleGroup(name) {
        const key = String(name ?? "").toLowerCase();
        root.expandedGroups = root.expandedGroups.includes(key)
            ? root.expandedGroups.filter(entry => entry !== key)
            : root.expandedGroups.concat([key]);
    }

    function collapseAll() {
        root.expandedGroups = [];
    }

    // Called once at startup by shell.qml, and it does nothing on purpose.
    //
    // A Quickshell singleton is created the first time something *reads* it, and
    // this one is read by a card that is only built when the task manager is
    // opened -- which also means its IPC handler does not exist before that, so
    // `qs -c ii ipc call processList ...` would fail on a fresh session. Touching
    // it from the shell's startup code is what makes the service (and its
    // handler) exist from login. It samples nothing: `active` is still false.
    function attach() {
    }

    function sample() {
        if (sampler.running)
            return;
        root.sampling = true;
        sampler.running = true;
    }

    function apply(text) {
        const data = String(text ?? "");
        try {
            if (data === root.lastSnapshot) {
                // Byte-identical table: nothing downstream can change, so the
                // revision cascade stays down. Parsed first, recorded after,
                // so a failed parse never poisons the comparison.
                root.sampling = false;
                return;
            }
            const parsed = JSON.parse(data);
            root.lastSnapshot = data;
            root.processes = parsed;
            root.revision++;
        } catch (error) {
            console.log("[ProcessList] could not read the process snapshot:", error);
        }
        root.sampling = false;
    }

    // ── Ending tasks ─────────────────────────────────────────────────────────
    // One pid, or a whole application's tree: the button on a group row says
    // "End task" and means the application, which is what the other task
    // manager does with its grouped rows.
    //
    // The killer is ONE Process, and a request that arrives while it is
    // already running used to be dropped on the floor: assigning `running =
    // true` to a running process does nothing, so the second click on End
    // task in the space of a kill silently did not happen. Escalation made
    // that window a full second wide. A request made in that window is
    // queued and run the moment the current one exits, so every click does
    // something.
    property var pendingKill: null
    function applyKill(req) {
        root.lastError = "";
        root.lastErrorSubject = req.subject;
        killer.pids = req.pids;
        killer.force = req.force;
        killer.subject = req.subject;
        killer.running = true;
    }
    function requestKill(pids, force, subject) {
        const list = (pids ?? []).filter(pid => pid && pid > 1);
        if (list.length === 0)
            return;
        const req = { pids: list, force: force, subject: subject ?? "" };
        if (killer.running) {
            root.pendingKill = req; // the runner drains it on exit
            return;
        }
        root.applyKill(req);
    }
    function endTask(pids, subject) {
        root.requestKill(pids, false, subject);
    }

    // The unceremonious version: SIGKILL, no save prompts, no cleanup. What
    // "it will not close" needs -- and what the right-click offers.
    function forceKill(pids, subject) {
        root.requestKill(pids, true, subject);
    }

    function dismissError() {
        root.lastError = "";
        root.lastErrorSubject = "";
    }

    function readKillResult(text) {
        try {
            const result = JSON.parse(text);
            const failed = result.failed ?? [];
            if (failed.length === 0)
                return;
            // The kernel's own wording, translated into the one everybody who
            // has used a task manager already knows.
            const refused = failed.some(entry => /not permitted|operation not permitted/i.test(entry.error ?? ""));
            root.lastError = refused
                ? Translation.tr("Access is denied.")
                : (failed[0].error ?? Translation.tr("Could not end the task."));
        } catch (error) {
            console.log("[ProcessList] could not read the kill result:", error);
            root.lastError = Translation.tr("Could not end the task.");
        }
    }

    // ── Sampling ─────────────────────────────────────────────────────────────
    // Driven by the resources tick so the process list and the graphs on the
    // same card are never a second apart, and halved so the heaviest thing this
    // card ever does happens half as often as the cheap file reads.
    property int ticks: 0
    Connections {
        target: ResourceUsage
        function onTick() {
            if (!root.active)
                return;
            root.ticks++;
            if (root.ticks % 2 === 0)
                root.sample();
        }
    }

    Process {
        id: sampler
        command: ["python3", `${Directories.scriptPath}/system/processes.py`]
        stdout: StdioCollector {
            onStreamFinished: root.apply(text)
        }
    }

    Process {
        id: killer
        property var pids: []
        property bool force: false
        property string subject: ""
        command: ["python3", `${Directories.scriptPath}/system/processes.py`, "--kill", ...(killer.force ? ["--force"] : []), ...killer.pids.map(pid => String(pid))]
        stdout: StdioCollector {
            onStreamFinished: root.readKillResult(text)
        }
        onExited: (exitCode, exitStatus) => {
            root.sample();
            // Drain a request that arrived while this one was running. Deferred
            // by a turn: `running` is cleared by the Process itself as part of
            // handling the exit, and starting it again from inside the handler
            // would race that.
            if (root.pendingKill) {
                const req = root.pendingKill;
                root.pendingKill = null;
                Qt.callLater(() => root.applyKill(req));
            }
        }
    }

    IpcHandler {
        target: "processList"

        function refresh(): void {
            root.sample();
        }

        // The two actions, over IPC so a keybind or a script can end a task
        // the same way the buttons do -- and so the button path can be
        // exercised without a click. Same functions, same killer process:
        //   qs -c ii ipc call processList end 1234
        //   qs -c ii ipc call processList force 1234
        function end(pid: string): string {
            const n = Number(pid);
            if (!Number.isFinite(n) || n <= 1)
                return `end: "${pid}" is not a pid`;
            root.endTask([n], String(pid));
            return `ending ${n}`;
        }

        function force(pid: string): string {
            const n = Number(pid);
            if (!Number.isFinite(n) || n <= 1)
                return `force: "${pid}" is not a pid`;
            root.forceKill([n], String(pid));
            return `force killing ${n}`;
        }

        // A one-line report, for scripts and for checking this service without
        // a screenshot: `qs -c ii ipc call processList status`.
        function status(): string {
            const top = root.rows[0];
            const err = root.lastError.length > 0
                ? ` error=${root.lastErrorSubject}:${root.lastError}` : "";
            return `${root.count} processes, ${root.rows.length} rows, `
                + `sample #${root.revision}, top: ${top ? `${top.name} ${top.cpu.toFixed(1)}%` : "none"}${err}`;
        }

        // Which owners currently hold the sampler open (see setActive).
        // `qs -c ii ipc call processList owners`.
        function owners(): string {
            const list = Object.keys(root._activeOwners);
            return `active=${root.active} owners=[${list.join(", ")}]`
                + ` sample #${root.revision}`;
        }
    }
}
