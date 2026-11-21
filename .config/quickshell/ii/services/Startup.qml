pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.modules.common
import qs.services

/**
 * Apps that start with the desktop.
 *
 * One list, edited from two places (Settings > Startup and the Task Manager's
 * Startup page, both hosting modules/common/widgets/StartupAppsPanel.qml), and
 * run once per login from here.
 *
 * WHY THE SHELL DOES THE LAUNCHING, not Hyprland's exec-once list. An app that
 * lives in the system tray has to end up IN the tray -- no window on any
 * desktop, nothing to see at login -- and only the shell knows what a tray is:
 * the vault is `special:tray`, the parking dispatch is the one TrayApps already
 * uses for the close gesture, and the window list that says "it has arrived" is
 * this process's. A compositor-side autostart would start the app and have no
 * way to put it away again.
 *
 * The entry list is a small JSON store (one JSON object per line, the shape
 * AppUsage already uses), so it survives restarts and can be read by a script.
 * Fields:
 *
 *   id       desktop entry id without `.desktop` -- the identity used for
 *            deduplication and for the toggles
 *   name     label to show, from the entry
 *   icon     themed icon name, from the entry
 *   command  shell line, quoted from the entry's argv (never its Exec string:
 *            that still carries %u/%f field codes, which a shell would pass
 *            through to the app as arguments)
 *   cls      the app's window class, used to find the window it opens and park
 *            it. From the tray registry when the app has one (WhatsApp,
 *            Thunderbird), otherwise the entry id -- good enough for the apps
 *            people autostart, and a wrong guess only means the window shows
 *            normally instead of going to the tray
 *   enabled  starts at login
 *   tray     park its window in the tray instead of showing it
 */
Singleton {
    id: root

    readonly property string storePath: `${Directories.state}/user/startupApps.json`

    // Written once per login session, before anything is launched. The shell is
    // restarted by every QML save and by its watchdog, and a restart must not
    // start a second copy of every autostart app -- so the marker (not a
    // property, which a restart forgets) is what "this session already started
    // them" means. XDG_RUNTIME_DIR is per-login, so a new login starts clean.
    readonly property string sessionMarker:
        `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/ii-startup-apps-launched`

    property var entries: []

    // Windows waiting to be parked: [{ id, cls, until }]. A tray entry is
    // watched for its window for 30s after launch -- the slowest measured cold
    // start on this machine (Thunderbird) is 8s, and the tail exists for a
    // first run that has to unpack itself.
    property var pendingPark: []

    // ── The store ──────────────────────────────────────────────────────────
    function load() {
        const out = [];
        for (const raw of storeAdapter.items) {
            try {
                const item = JSON.parse(raw);
                if (!item || !item.id || !item.command)
                    continue;
                out.push({
                    id: String(item.id),
                    name: String(item.name ?? item.id),
                    icon: String(item.icon ?? ""),
                    command: String(item.command),
                    cls: String(item.cls ?? ""),
                    enabled: item.enabled !== false,
                    tray: item.tray === true,
                });
            } catch (error) {
                // A damaged line is skipped, not the whole list.
            }
        }
        root.entries = out;
        // The store arrives ASYNCHRONOUSLY, after shell.qml's
        // Component.onCompleted has already asked for a session start -- with
        // an empty list, which reads as "nothing to start" and returned. So
        // the read is the second trigger, and `sessionStarted` is what keeps
        // the two of them from launching everything twice.
        if (out.length > 0)
            Qt.callLater(root.beginSession);
    }

    function save() {
        storeAdapter.items = root.entries.map(item => JSON.stringify(item));
        storeView.writeAdapter();
    }

    function entryFor(id) {
        return root.entries.find(item => item.id === id) ?? null;
    }

    function set(id, patch) {
        root.entries = root.entries.map(item =>
            item.id === id ? Object.assign({}, item, patch) : item);
        root.save();
    }

    function remove(id) {
        root.entries = root.entries.filter(item => item.id !== id);
        root.save();
    }

    // ── Adding a desktop entry ─────────────────────────────────────────────
    // The command is built from the PARSED argv (entry.command), re-quoted into
    // one shell line: open.sh takes a shell line because launcher entries are
    // shell lines, and QML's parsed argv has already dropped the %u/%f codes
    // that entry.execString still contains.
    function shellQuote(word) {
        return `'${String(word).replace(/'/g, `'\\''`)}'`;
    }

    function commandFor(entry) {
        const argv = Array.from(entry?.command ?? []);
        if (argv.length === 0)
            return "";
        const line = argv.map(word => root.shellQuote(word)).join(" ");
        const dir = String(entry?.workingDirectory ?? "").trim();
        return dir.length > 0 ? `cd ${root.shellQuote(dir)} && ${line}` : line;
    }

    // The window class this app will use. The tray registry is the authority
    // for the apps it knows (its `bins` list is the same one the launcher's
    // tray permission matches), and the desktop id is the fallback.
    function guessClass(id, command) {
        const text = `${id} ${command}`.toLowerCase();
        const known = TrayApps.registry.find(item =>
            (item.bins ?? []).some(bin => text.includes(String(bin).toLowerCase())));
        if (known)
            return known.cls;
        return String(id ?? "").replace(/\.desktop$/, "");
    }

    function add(entry) {
        if (!entry || !entry.id)
            return;
        const id = String(entry.id).replace(/\.desktop$/, "");
        if (root.entryFor(id)) {
            // Already in the list but switched off: adding it again is the
            // user asking for it to start.
            root.set(id, { enabled: true });
            return;
        }
        const command = root.commandFor(entry);
        if (command.length === 0)
            return;
        const known = TrayApps.registry.some(item =>
            root.guessClass(id, command) === item.cls);
        const item = {
            id,
            name: String(entry.name ?? id),
            icon: String(entry.icon ?? ""),
            command,
            cls: root.guessClass(id, command),
            enabled: true,
            // An app the shell already keeps a tray icon for starts in the
            // tray; everything else starts with its window, and the row's
            // switch is how that is changed.
            tray: known,
        };
        root.entries = root.entries
            .concat([item])
            .sort((a, b) => String(a.name).localeCompare(String(b.name)));
        root.save();
    }

    // ── Launch ─────────────────────────────────────────────────────────────
    // Through open.sh, like every other launch the shell makes, with
    // `tray-allowed` because this is NOT a user asking to see the app: the
    // third word tells open.sh to skip its tray-permission grant, so the
    // close-to-tray watcher is free to park the window the moment it appears.
    function launch(entry) {
        if (!entry || !entry.command)
            return;
        Quickshell.execDetached([
            "bash", Quickshell.shellPath("scripts/launch/open.sh"),
            entry.name ?? entry.id, entry.command, "tray-allowed",
        ]);
        if (entry.tray)
            root.watchForPark(entry);
    }

    function watchForPark(entry) {
        const cls = String(entry?.cls ?? "").trim();
        if (cls.length === 0 || root.pendingPark.some(p => p.id === entry.id))
            return;
        root.pendingPark = root.pendingPark.concat([{
            id: entry.id, cls, until: Date.now() + 30000,
        }]);
    }

    function launchEnabled() {
        for (const entry of root.entries) {
            if (entry.enabled)
                root.launch(entry);
        }
    }

    // ── Parking ────────────────────────────────────────────────────────────
    // The window has to be moved as soon as it EXISTS. `follow = false` so the
    // desktop the user is looking at does not jump to the vault, and the same
    // move form TrayApps uses (string workspace + address selector -- verified
    // on this compositor).
    function parkPending() {
        if (root.pendingPark.length === 0)
            return;
        const windows = HyprlandData.windowList ?? [];
        const left = [];
        for (const pending of root.pendingPark) {
            const want = String(pending.cls).toLowerCase();
            const hits = windows.filter(w => {
                const cls = String(w.class ?? "").toLowerCase();
                if (cls.length === 0)
                    return false;
                return cls === want || (want.length >= 4 && cls.includes(want));
            }).filter(w => !w.workspace || w.workspace.name !== "special:tray");
            if (hits.length > 0) {
                for (const w of hits) {
                    // Not a fullscreen window into the vault: it comes out of
                    // the tray as a window later, never as a screen-covering
                    // borderless app (the same rule TrayApps.park keeps).
                    if (w.fullscreen && w.fullscreen !== 0) {
                        Hyprland.dispatch(`hl.dsp.focus({ window = hl.get_window("address:${w.address}") })`);
                        Hyprland.dispatch(`hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })`);
                    }
                    Hyprland.dispatch(`hl.dsp.window.move({ workspace = "special:tray", follow = false, window = "address:${w.address}" })`);
                }
                continue; // parked; this entry is done
            }
            if (Date.now() < pending.until)
                left.push(pending);
        }
        root.pendingPark = left;
    }

    // ── Once per login ─────────────────────────────────────────────────────
    // The marker is checked by a process rather than guessed from a property:
    // the shell reloads on every QML save, and `entries` being empty on the
    // first tick is not "nothing to start".
    property bool sessionStarted: false

    function beginSession() {
        if (root.sessionStarted || root.entries.length === 0)
            return;
        root.sessionStarted = true;
        markerCheck.running = false;
        markerCheck.running = true;
    }

    Timer {
        interval: 700
        repeat: true
        running: root.pendingPark.length > 0
        onTriggered: root.parkPending()
    }

    Process {
        id: markerCheck
        command: ["bash", "-c", `test -f ${root.shellQuote(root.sessionMarker)}`]
        onExited: exitCode => {
            if (exitCode === 0)
                return; // this login already started them
            markerWrite.running = false;
            markerWrite.running = true;
            root.launchEnabled();
        }
    }

    Process {
        id: markerWrite
        command: ["bash", "-c", `: > ${root.shellQuote(root.sessionMarker)}`]
    }

    FileView {
        id: storeView
        path: root.storePath
        watchChanges: false
        onLoaded: root.load()
        onLoadFailed: error => {
            root.entries = [];
            if (error == FileViewError.FileNotFound) {
                storeAdapter.items = [];
                storeView.writeAdapter();
            }
        }
        adapter: JsonAdapter {
            id: storeAdapter
            property list<string> items: []
        }
    }

    IpcHandler {
        target: "startup"

        function launch(): void {
            root.launchEnabled();
        }

        function status(): string {
            const on = root.entries.filter(e => e.enabled);
            return `${on.length} of ${root.entries.length} enabled: `
                + on.map(e => `${e.name}${e.tray ? " (tray)" : ""}`).join(", ");
        }
    }
}
