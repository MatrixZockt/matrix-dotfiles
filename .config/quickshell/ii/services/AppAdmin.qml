pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.services

/**
 * Everything an app offers beyond "open it": run as administrator, repair,
 * uninstall, uninstall and delete the data.
 *
 * The answers come from scripts/system/app-actions.py, which is what actually
 * knows that an app is a pacman package or a flatpak or a file in your home
 * directory -- no .desktop file records that, so it is looked up. This service
 * is the QML side of that script: one probe per menu, one run per click, and
 * the text of what happened.
 *
 * WHY THE SCRIPT AND NOT THE SHELL. Three reasons, and the first one is the
 * whole point:
 *
 *   * the actions are only offered when they are real. A flatpak has no
 *     "run as administrator" and an AppImage has nothing to repair, so the
 *     list is built from what was FOUND rather than from a fixed table here.
 *   * every command is built where it can also be READ. `plan` returns the
 *     same command line `run` would execute, which is what the confirmation
 *     shows -- and what `--dry-run` prints, so the whole set is checkable
 *     without root and without touching anybody's data.
 *   * removing a package is not the same act as knowing which package it is.
 *     Resolution belongs in a program that can be run from a terminal.
 *
 * Nothing here escalates by itself: the script invokes pkexec, and this
 * desktop's existing polkit agent (PolkitContent.qml, the same prompt the file
 * manager's mount uses) asks the human. A cancelled prompt is reported as
 * cancelled and not as a failure, because they are different things.
 */
Singleton {
    id: root

    readonly property string scriptPath: `${Directories.scriptPath}/system/app-actions.py`

    // ── The app the menu is about ─────────────────────────────────────────
    property var entry: null       // the DesktopEntry, kept for its name/icon
    property var plan: null        // the probe result, or null while probing
    property bool probing: false
    property string probeError: ""

    // ── The planned command for a destructive option ──────────────────────
    // Filled by `requestPlan`, read by the menu's confirmation step. It is a
    // fresh plan from the script rather than something the menu assembled, so
    // what is confirmed is exactly what will run.
    property var pendingPlan: null
    property bool planning: false

    // ── A running action ──────────────────────────────────────────────────
    property bool busy: false
    property bool resultOk: true
    property string resultText: ""
    property string lastAction: ""

    readonly property var actions: (plan && plan.actions) ? plan.actions : []
    readonly property var appActions: (plan && plan.appActions) ? plan.appActions : []
    readonly property var dataPaths: (plan && plan.dataPaths) ? plan.dataPaths : []
    readonly property string kind: plan ? String(plan.kind ?? "") : ""
    readonly property string packageName: plan ? String(plan.package ?? "") : ""

    // ── Probing ───────────────────────────────────────────────────────────
    Process {
        id: probeProc
        property string payload: ""
        command: []
        stdout: StdioCollector {
            onStreamFinished: probeProc.payload = String(this.text ?? "")
        }
        onExited: (code, status) => root.finishProbe(probeProc.payload, code)
    }

    function probe(entry) {
        if (!entry || entry.shellApp === true) {
            // A shell window is not an installed app: there is no package to
            // inspect and nothing to uninstall, so no menu is offered at all
            // (the caller checks `available()` too).
            root.entry = entry;
            root.plan = null;
            root.probeError = "";
            return;
        }
        root.entry = entry;
        root.plan = null;
        root.pendingPlan = null;
        root.resultText = "";
        root.probeError = "";
        root.probing = true;
        probeProc.payload = "";
        probeProc.command = root.probeCommand(String(entry.id ?? ""));
        restart(probeProc);
    }

    // The entry's own parsed command is handed to the script as an override:
    // Quickshell has already resolved the Exec line, and `open` should launch
    // exactly what the launcher would have launched, not a second reading of
    // the same file that might disagree.
    function probeCommand(id) {
        const argv = [];
        if (root.entry && root.entry.command)
            for (const word of root.entry.command)
                argv.push(String(word));
        const cmd = ["python3", root.scriptPath, "probe", "--id", id];
        if (argv.length > 0)
            cmd.push("--exec-json", JSON.stringify(argv));
        return cmd;
    }

    function finishProbe(text, code) {
        root.probing = false;
        const body = String(text ?? "").trim();
        if (body.length === 0) {
            root.probeError = code === 0
                ? "The app helper returned nothing."
                : `The app helper exited with status ${code}.`;
            return;
        }
        try {
            const parsed = JSON.parse(body);
            root.plan = parsed;
            root.probeError = "";
        } catch (error) {
            // Shown rather than swallowed: a launcher row that silently has no
            // menu is indistinguishable from a launcher row with a broken one.
            root.probeError = "Could not read the app's details.";
            console.log(`[appAdmin] probe output not JSON: ${body.slice(0, 200)}`);
        }
    }

    // Is a context menu worth offering for this entry at all?
    function available(entry) {
        return !!entry && entry.shellApp !== true;
    }

    // ── Planning (what the confirmation shows) ────────────────────────────
    Process {
        id: planProc
        property string payload: ""
        command: []
        stdout: StdioCollector {
            onStreamFinished: planProc.payload = String(this.text ?? "")
        }
        onExited: (code, status) => root.finishPlan(planProc.payload)
    }

    function requestPlan(action) {
        if (!root.entry)
            return;
        root.planning = true;
        root.pendingPlan = null;
        planProc.payload = "";
        planProc.command = ["python3", root.scriptPath, "plan",
                            "--id", String(root.entry.id ?? ""), "--action", String(action)];
        restart(planProc);
    }

    function finishPlan(text) {
        root.planning = false;
        try {
            root.pendingPlan = JSON.parse(String(text ?? "").trim());
        } catch (error) {
            root.pendingPlan = { ok: false, cmd: "", action: "" };
        }
    }

    // ── Running ───────────────────────────────────────────────────────────
    Process {
        id: runProc
        property string payload: ""
        command: []
        stdout: StdioCollector {
            onStreamFinished: runProc.payload = String(this.text ?? "")
        }
        onExited: (code, status) => root.finishRun(runProc.payload)
    }

    // Runs an option the script has already offered. The ACTION is passed,
    // never a command line: the script rebuilds the command from a fresh probe
    // of the app, so a menu left open while the app was uninstalled underneath
    // it cannot remove something else.
    function run(action, dryRun) {
        if (!root.entry || root.busy)
            return;
        root.busy = true;
        root.lastAction = String(action);
        root.resultText = "";
        runProc.payload = "";
        const cmd = ["python3", root.scriptPath, "run",
                     "--id", String(root.entry.id ?? ""), "--action", String(action)];
        if (dryRun === true)
            cmd.push("--dry-run");
        runProc.command = cmd;
        restart(runProc);
    }

    function finishRun(text) {
        root.busy = false;
        const body = String(text ?? "").trim();
        let parsed = null;
        try {
            parsed = JSON.parse(body);
        } catch (error) {
            parsed = null;
        }
        if (!parsed) {
            root.resultOk = false;
            root.resultText = body.length > 0 ? body : "No answer from the app helper.";
            return;
        }
        root.resultOk = parsed.ok === true;
        root.resultText = String(parsed.output ?? "").trim() || "Done.";
    }

    function clear() {
        root.entry = null;
        root.plan = null;
        root.pendingPlan = null;
        root.resultText = "";
        root.probeError = "";
        root.busy = false;
        root.lastAction = "";
    }

    // `Process.running` has to go false before true again, or a second
    // identical request is a no-op and the menu looks frozen. Every call site
    // goes through here rather than setting the two lines itself.
    function restart(proc) {
        proc.running = false;
        proc.running = true;
    }

    // The overlay's right-click menu is a layer surface, so a synthetic
    // pointer can hover it but never press it. These run the same functions
    // the rows call, which is what makes the whole feature answerable from a
    // terminal instead of asserted.
    IpcHandler {
        target: "appAdmin"

        function state(): string {
            if (!root.plan)
                return "no plan" + (root.probing ? " (probing)" : "");
            return JSON.stringify({
                id: root.plan.id,
                kind: root.kind,
                package: root.packageName,
                version: root.plan.version,
                repo: root.plan.repo,
                desktopFile: root.plan.desktopFile,
                binary: root.plan.binary,
                dataPaths: root.dataPaths,
                actions: root.actions.map(a => a.id),
                appActions: root.appActions.map(a => a.id),
                busy: root.busy,
                resultOk: root.resultOk,
                result: root.resultText
            });
        }

        // Probe by desktop id, without a menu: `qs -c ii ipc call appAdmin probe firefox.desktop`
        function probe(id: string): string {
            // Both spellings, and the heuristic as a last resort -- the same
            // three lookups AppUsage makes, because "the id" is not one thing.
            const bare = String(id).replace(/\.desktop$/, "");
            const found = DesktopEntries.byId(id)
                ?? DesktopEntries.byId(bare)
                ?? DesktopEntries.heuristicLookup(bare);
            if (!found)
                return "not found: " + id;
            root.probe(found);
            return "probing " + id;
        }

        function planOf(action: string): string {
            root.requestPlan(action);
            return "planning " + action;
        }

        function pending(): string {
            if (root.planning)
                return "planning…";
            if (!root.pendingPlan)
                return "none";
            return JSON.stringify(root.pendingPlan);
        }

        // Run an option for whatever was probed last.
        function act(action: string, dry: bool): string {
            root.run(action, dry === true);
            return "running " + action + (dry ? " (dry run)" : "");
        }

        function result(): string {
            return (root.busy ? "busy: " : "") + root.resultText;
        }
    }
}
