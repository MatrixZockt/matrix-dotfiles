pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Remembers which apps you actually open.
 *
 * The SUPER panel used to open with nothing in it: you had to type before there
 * was anything to look at, and the only "history" it offered was whatever the
 * search happened to match. This service is what fills that gap -- every app
 * launched from the panel is recorded here, and the panel offers the most recent
 * ones back as a row of tiles while the search field is still empty.
 *
 * The list lives in a small JSON file under the shell's state directory, so it
 * survives restarts. Only the id, name and icon of each entry are kept: nothing
 * about *when* or *how often* you opened something is needed to show a short row
 * of tiles.
 */
Singleton {
    id: root

    readonly property string storePath: `${Directories.state}/user/recentApps.json`
    // A row of tiles, not a list: eight is as many as fits before the row starts
    // to read as a wall.
    readonly property int maxEntries: 8

    // Most recently used first, each one `{ id, name, icon }`.
    property var recent: []

    function load() {
        const parsed = [];
        for (const raw of storeAdapter.recent) {
            try {
                const item = JSON.parse(raw);
                if (item && item.id)
                    parsed.push(item);
            } catch (error) {
                // A damaged line is skipped rather than wiping the whole list.
            }
        }
        const folded = root.fold(parsed);
        root.recent = folded;
        // A list that shrank was carrying duplicates or dead entries; write the
        // cleaned version back so it does not have to be rebuilt every start.
        //
        // On the next tick, not now: writing an adapter from inside the view's own
        // load handler is swallowed -- the file keeps its old contents and the
        // duplicates come back on the next read, which is exactly what happened
        // when this ran inline.
        if (folded.length !== parsed.length)
            Qt.callLater(root.save);
    }

    function save() {
        storeAdapter.recent = root.recent.map(item => JSON.stringify(item));
        storeView.writeAdapter();
    }

    // ── One app, one tile ────────────────────────────────────────────────────
    // The same program can arrive under more than one id: the launcher hands over
    // `kitty` in one place and `kitty.desktop` in another, and a desktop entry can
    // be found by file name or by its reverse-domain name. Recorded as-is, the
    // same app then sat in the row twice -- and a row of identical tiles is worse
    // than no row at all, because it stops being recognisable at a glance. These
    // three functions reduce an id to the single entry it really names, and the
    // list is folded on that identity every time it is read or written.
    function canonicalId(id) {
        if (!id)
            return "";
        const bare = String(id).replace(/\.desktop$/, "");
        const entry = DesktopEntries.byId(id)
            ?? DesktopEntries.byId(bare)
            ?? DesktopEntries.heuristicLookup(bare);
        const resolved = entry?.id ? String(entry.id) : bare;
        return resolved.replace(/\.desktop$/, "");
    }

    // True once the applications are actually known. Desktop entries load
    // asynchronously, and an empty catalogue at startup means "not yet", not
    // "nothing resolves" -- treating those the same would wipe the list.
    readonly property bool entriesReady: DesktopEntries.applications.values.length > 0

    // The same app: either two spellings of one entry, or two records that resolve
    // to the same name and the same icon.
    function sameApp(a, b) {
        if (root.canonicalId(a.id) === root.canonicalId(b.id))
            return true;
        return (a.name ?? "") !== "" && a.name === b.name
            && (a.icon ?? "") === (b.icon ?? "");
    }

    // Deduplicate, drop entries whose application is gone, and cap the length.
    function fold(items) {
        const out = [];
        for (const item of items) {
            if (!item?.id)
                continue;
            // An app that is no longer installed -- or a stray entry that has
            // since been deleted -- should not keep a tile in the row for ever.
            if (root.entriesReady && !root.entryFor(item.id))
                continue;
            if (out.some(existing => root.sameApp(existing, item)))
                continue;
            out.push(item);
        }
        return out.slice(0, root.maxEntries);
    }

    // Called when an app is launched from the panel.
    function record(entry) {
        if (!entry || !entry.id || String(entry.id).length === 0)
            return;
        const item = {
            id: root.canonicalId(entry.id),
            name: entry.name ?? entry.id,
            icon: entry.icon ?? ""
        };
        const rest = root.recent.filter(existing => !root.sameApp(existing, item));
        root.recent = root.fold([item].concat(rest));
        root.save();
    }

    function clear() {
        root.recent = [];
        root.save();
    }

    // Desktop entry ids are written both with and without the `.desktop` suffix
    // depending on where they come from, and the lookup only takes one of those,
    // so both spellings are tried before giving up.
    function entryFor(id) {
        if (!id)
            return null;
        const bare = String(id).replace(/\.desktop$/, "");
        return DesktopEntries.byId(id)
            ?? DesktopEntries.byId(bare)
            ?? DesktopEntries.heuristicLookup(bare);
    }

    // The icon to draw for a remembered app.
    //
    // The name recorded alongside the id is tried first: it is the name the
    // desktop entry itself used when the app was launched, so it is exactly what
    // the launcher drew then. Re-reading the entry is the second choice, and the
    // class-name guess is the last resort -- all three used to be one lookup, which
    // is why every tile fell back to the same generic icon.
    function resolveIcon(id, storedIcon) {
        if (storedIcon && storedIcon.length > 0 && AppSearch.iconExists(storedIcon))
            return storedIcon;
        const entry = root.entryFor(id);
        if (entry && entry.icon && entry.icon.length > 0)
            return entry.icon;
        return AppSearch.guessIcon(String(id ?? "").replace(/\.desktop$/, ""));
    }

    function launch(id) {
        const entry = root.entryFor(id);
        if (entry)
            entry.execute();
    }

    // The command line that launches a remembered app, for callers that hand the
    // launch to something else -- GlobalStates.openApp watches the program and
    // can say whether it arrived, which requires the command rather than a
    // fire-and-forget execute(). Empty when the app is no longer installed.
    function commandFor(id) {
        const parts = root.entryFor(id)?.command ?? [];
        return parts.length > 0 ? parts.join(" ") : "";
    }

    // Once the catalogue finishes loading, fold again: this is what clears out
    // entries that were written while the shell could not yet tell whether their
    // application still exists.
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            if (!root.entriesReady)
                return;
            const __t = Date.now();
            const folded = root.fold(root.recent);
            const __d = Date.now() - __t;
            if (__d > 15) console.log("[slow] appUsageFold " + __d + "ms");
            if (folded.length === root.recent.length)
                return;
            root.recent = folded;
            root.save();
        }
    }

    FileView {
        id: storeView
        path: root.storePath
        watchChanges: false
        onLoaded: root.load()
        onLoadFailed: error => {
            root.recent = [];
            // First run: create an empty store so writes have somewhere to go.
            if (error == FileViewError.FileNotFound) {
                storeAdapter.recent = [];
                storeView.writeAdapter();
            }
        }
        adapter: JsonAdapter {
            id: storeAdapter
            property list<string> recent: []
        }
    }

    IpcHandler {
        target: "appUsage"

        function clear(): void {
            root.clear();
        }
    }
}

