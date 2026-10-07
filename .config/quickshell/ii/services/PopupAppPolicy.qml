pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.modules.common

// ── Per-app popup handling ────────────────────────────────────────────
//
// The compositor decides on its own that "an app's second window is a
// popup": a dialog, a settings window, a sign-in sheet floats and centres
// instead of tiling (custom/general.lua). It is a good rule and it is the
// right default -- but it is a rule with no off switch, and some apps open a
// second window that is a real application window rather than a dialog.
// TradingView was what made the absence obvious.
//
// So: the off switch, per app, in the shell's own settings. Three jobs.
//
//   1. REMEMBER which apps exist. Every app id the compositor has reported
//      is recorded (see scan() below), so the settings list fills itself by
//      use -- an app installed today is in the list the first time it opens,
//      which is the only honest reading of "new apps show up there too". No
//      .desktop scan and no install hook to keep working.
//
//   2. ANSWER "may this app's window float?". True unless the app is in
//      `apps.popupHandlingOff`.
//
//   3. PUBLISH the exceptions where the compositor can read them. Hyprland's
//      Lua config cannot see the shell's Config; it can read a file.
//
// WHY A FILE AND NOT AN IPC CALL: the classifier runs on every window open.
// Asking the shell over IPC would spawn a `qs` process per window -- tens of
// milliseconds on the critical path of a window appearing. The file is an
// io.open and a few string matches.
//
// WHY THE FILE LISTS EXCEPTIONS, NOT THE INVENTORY: the Lua side has to
// behave identically whether or not the shell is running. An empty or
// missing file therefore means "the classifier applies to everything", which
// is exactly what this machine did before any of it existed -- so a shell
// that has not started yet, or a cache that got cleared, degrades to the old
// rules and never to "nothing floats".
Singleton {
    id: root

    // In the cache, not the config dir: derived state, rewritten whenever the
    // setting changes, and nothing a human needs to read or edit by hand.
    // The cache ROOT, not a subdirectory of it -- a directory that may not
    // exist is a write that can fail, and this file has to be there.
    readonly property string bridgePath: `${Directories.cache}/popup-handling-off.txt`

    // The authoritative list: app ids with popup handling switched off.
    readonly property var offList: Config.ready
        ? (Config.options?.apps?.popupHandlingOff ?? [])
        : []

    // Every app id this machine has shown a window for, across EVERY workspace,
// kept as it goes. This is the inventory the settings page lists.
    //
    // ToplevelManager rather than the dock's TaskbarApps, and the difference
    // matters: TaskbarApps deliberately lists only the CURRENT workspace's
    // windows plus pins (so the dock does not fill with everything on every
    // desktop). For "which apps do I have" that is the wrong question -- it
    // showed ONE app out of the eight running, because one terminal was on
    // the active workspace and nothing was pinned.
    //
    // Deliberately not persisted: apps uninstalled months ago would otherwise
    // sit in the settings forever, rediscovered from nothing.
    property var seen: ({})

    readonly property var known: Object.keys(seen).sort()

    // The model the settings list binds to. Exceptions come FIRST and stay
    // there even if the app has not been seen since login, so the switch you
    // just turned off can never scroll out of reach.
    readonly property var list: (() => {
        const extra = offList.filter(c => known.indexOf(c) === -1);
        return extra.concat(known);
    })()

    function isOff(appId) {
        if (!appId) return false;
        return offList.indexOf(appId) !== -1;
    }

    // What the switch in the settings is bound to. ON = the classifier may
    // treat this app's extra windows as popups.
    function isPopupAllowed(appId) {
        return !isOff(appId);
    }

    function setPopupAllowed(appId, allowed) {
        if (!appId) return;
        const next = offList.filter(c => c !== appId);
        if (!allowed) next.push(appId);
        // Sorted, so the bridge file is stable: a list that reorders itself
        // on every toggle makes the file's contents unreadable and makes
        // "did this change" impossible to eyeball.
        Config.options.apps.popupHandlingOff = next.slice().sort();
        writeDebounce.restart();
    }

    // Note an app as existing. Returns true when it was NEW, so a caller can
    // tell a real addition from a repeat.
    function noteApp(appId) {
        if (!appId || appId === "quickshell") return false;
        const key = String(appId).toLowerCase();
        if (Object.prototype.hasOwnProperty.call(seen, key)) return false;
        seen = Object.assign({}, seen, { [key]: true });
        return true;
    }

    // ── First sight ────────────────────────────────────────────────────
    // A poll, not an event subscription. The list is small (one entry per
    // distinct app ever run) and the work per tick is a walk of the open
    // windows comparing strings; at 2s that is nothing, and it costs no API
    // surface. It runs whether or not the settings window is open, which is
    // the point -- an app has to be in the list before you go looking for it.
    //
    // HyprlandData.windowList rather than ToplevelManager: it is the
    // compositor's OWN client list (`hyprctl clients`), across every
    // workspace, and its `class` strings are exactly what the Lua classifier
    // compares against -- so the name in the settings list is the name the
    // compositor matches, not a second spelling of it.
    //
    // (ToplevelManager was tried first and `ToplevelManager` would not resolve
    // in this file at all, in a singleton with the same pragmas and the same
    // explicit `import Quickshell.Hyprland` as HyprlandData.qml, which uses it
    // fine. Rather than keep guessing at that, this asks a singleton in the
    // same directory that already holds the answer.)
    //
    // `toplevels.values`, not `toplevels`: this build reaches the collection
    // through .values (see TaskbarApps and HyprlandData).
    function scan() {
        try {
            for (const w of HyprlandData.windowList ?? []) {
                noteApp(w?.class ?? "");
            }
        } catch (e) {
            // Reported, NOT swallowed. A scan that dies part-way leaves every
            // app it had not reached yet invisible, and "the list is short"
            // is not a symptom anybody can act on.
            print("[popupApps] scan failed: " + (e?.message ?? e));
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.scan()
    }

    // ── For the settings list ──────────────────────────────────────────

    // ── Startup ───────────────────────────────────────────────────────
    // Called once from shell.qml, because nothing else constructs this
    // singleton until the settings page reads one of its properties, and the
    // file it owns is read by the compositor on every window open.
    function load() {
        // Order matters: the bridge file is the part the compositor depends
        // on, and it must be written even if the inventory fails outright. An
        // earlier version scanned first and unguarded, so a single failure
        // there meant the exceptions were never published -- the setting would
        // sit there, correct, doing nothing.
        writeBridge();
        scan();
    }

    // ── The bridge ─────────────────────────────────────────────────────
    // Written when the exception list changes, NOT on a timer. The
    // compositor reads this while a window is opening, and a file that is
    // rewritten as it is being read can be read half-written.
    function writeBridge() {
        const lines = offList.slice().sort();
        // `setText()`, not `text = ...`: FileView's text property is read-only
        // in this build, and assigning to it throws a TypeError -- which, from
        // inside a Timer handler, means the write silently never happens and
        // the file simply never appears.
        bridgeText.setText(lines.length === 0 ? "" : lines.join("\n") + "\n");
    }

    FileView {
        id: bridgeText
        path: root.bridgePath
        watchChanges: false
        blockWrites: false
        printErrors: false
    }

    Timer {
        id: writeDebounce
        interval: 120
        onTriggered: root.writeBridge()
    }

    // Publish as soon as the config is readable. Without this the file is
    // absent until the first toggle, and the compositor's "missing file"
    // path would be the only one that ever runs -- so the exceptions would
    // look like they worked on the first try after a reboot and then stop.
    Connections {
        target: Config
        function onReadyChanged() {
            // The config has just become readable, so the exception list has
            // only now got its real value: publish it.
            if (Config.ready) writeDebounce.restart();
        }
    }
    Component.onCompleted: {
        load();
    }

    // ── For the settings list ──────────────────────────────────────────
    // The desktop entry for an app id, which is what gives the row a real
    // name and an icon instead of a raw WM class. Null is normal: an app
    // launched from a binary with no .desktop installed has no entry, and the
    // list must still show it.
    function entryFor(appId) {
        try {
            return DesktopEntries.heuristicLookup(appId);
        } catch (e) {
            return null;
        }
    }

    function nameFor(appId) {
        const e = entryFor(appId);
        return e?.name || appId || "";
    }

    function iconFor(appId) {
        const e = entryFor(appId);
        return e?.icon || "";
    }

    // ── Inspection ─────────────────────────────────────────────────────
    // There is no pixel-free way to see this list -- it lives in a layer-shell
    // settings page -- so it gets a command line, the same way the island's
    // geometry does:
    //   qs -c ii ipc call popupApps list
    IpcHandler {
        target: "popupApps"

        function list(): void {
            scan();
            const names = root.list.map(id => root.nameFor(id) + " [" + id + "]");
            print("[popupApps] " + names.length + " app(s): "
                + (names.join("  |  ") || "none seen yet"));
            print("[popupApps] popup handling OFF for: "
                + (root.offList.join(", ") || "(nothing -- the classifier "
                    + "applies to every app)"));
            print("[popupApps] bridge " + root.bridgePath + " -> "
                + (root.offList.length ? root.offList.join(",") : "(empty)"));
        }
    }
}