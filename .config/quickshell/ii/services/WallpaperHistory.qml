import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common
import qs.modules.common.functions
pragma Singleton

pragma ComponentBehavior: Bound

/**
 * Wallpaper history -- the carousel's LIBRARY.
 *
 * Every wallpaper that has been SELECTED -- i.e. it became the desktop
 * background through any pathway -- is recorded here with its thumbnail,
 * newest first, and STAYS until it is explicitly deleted from the carousel
 * (the card's remove action). Selections are never silently dropped: the
 * old maxEntries=30 cap silently ate older choices, which read as "the
 * wallpapers I picked vanish from the carousel". The only ways out of the
 * list are the user's own remove, or selecting the same image again (which
 * just moves it to the front).
 *
 * Recording happens in two places on purpose: Wallpapers.apply() (the
 * shell's own apply action) and onCurrentWallpaperChanged here -- the one
 * binding that sees EVERY pathway, including switchwall.sh rewriting the
 * config from outside the shell (terminal, --random, the fallback picker).
 * Backing store: a JSON file in the state directory. The desktop widget's
 * carousel reads this; the settings Appearance page shows the same grid.
 */
Singleton {
    id: root

    readonly property string historyPath: `${Directories.state}/wallpaper-history.json`
    // Library, not a rolling window: high enough to be "never drops
    // anything" in practice (paths are tiny strings), while still bounding
    // the file against pathological growth.
    readonly property int maxEntries: 500

    property var entries: [] // [{ path, thumb, ts }]
    property bool ready: false
    // NOTE on ghosts: the launcher (scripts/launch/shell.sh) prunes missing
    // files from the history BEFORE this shell starts -- in-QML pruning
    // raced the shell's own startup record()/save() and kept losing. So on
    // load, the file is already clean; a ghost appearing mid-session (a
    // file deleted while running) is pruned at the next shell start.

    // The active wallpaper is always first in the carousel: it is what is on
    // screen right now, so it is what "current" means.
    readonly property string currentWallpaper: Config.options.background.wallpaperPath

    // Any image that BECOMES the wallpaper is a carousel member from that
    // moment on, whatever changed it: the shell's apply action, switchwall.sh
    // from a terminal, --random, the fallback picker -- they all end up here
    // as a config change, and this is the single hook that sees them all.
    // (Wallpapers.apply records as well; the two dedupe into one entry.)
    // Gated on `ready` so the startup load cannot clobber the store before
    // it is read -- onLoaded seeds the current wallpaper itself.
    onCurrentWallpaperChanged: {
        if (!root.ready) return;
        const cur = String(root.currentWallpaper ?? "");
        if (cur.length === 0) return;
        root.record(cur);
    }

    FileView {
        id: historyView
        path: root.historyPath
        watchChanges: false
        printErrors: false
        onLoaded: {
            try {
                root.entries = (JSON.parse(historyView.text()) ?? []);
            } catch (e) {
                root.entries = [];
            }
            // The current wallpaper is always part of the history: if the
            // store was fresh (or the image predates the feature), seed it.
            const cur = root.currentWallpaper;
            if (cur && cur.length > 0 && !root.entries.includes(cur)) {
                root.entries = [cur, ...root.entries].slice(0, root.maxEntries);
                root.save();
            }
            root.ready = true;
        }
        onLoadFailed: {
            // Fresh install: no history yet. Seed with the current wallpaper
            // so the carousel is never empty.
            const cur = root.currentWallpaper;
            if (cur && cur.length > 0) {
                root.entries = [cur];
                root.save();
            }
            root.ready = true;
        }
    }

    function save() {
        historyView.setText(JSON.stringify(root.entries.slice(0, root.maxEntries)));
    }

    function record(path) {
        if (!path || path.length === 0) return;
        const normalized = String(path);
        // Newest first; drop an existing entry for the same image so it moves
        // to the front rather than duplicating.
        root.entries = [normalized, ...root.entries.filter(e => e !== normalized)].slice(0, root.maxEntries);
        root.save();
    }

    // Drop one entry from the carousel. Deliberately history-only: the image
    // on disk is the user's file, and a widget has no business deleting it.
    // Entries are plain paths (the ThumbnailImage widget shown for them is
    // derived, not stored), so filtering one string out is the whole job.
    function remove(path) {
        if (!path || path.length === 0) return;
        const target = String(path);
        const next = root.entries.filter(e => String(e) !== target);
        if (next.length === root.entries.length) return;
        root.entries = next;
        root.save();
    }

    // The carousel's model: the history in ITS OWN order, and nothing else.
    //
    // This used to lift the current wallpaper to the front and push every
    // other entry down one. That made the ring's ORDER a function of which
    // wallpaper happened to be active: with spooky-devil third in the
    // history, choosing it moved it to slot 0 and shifted heartbeat and
    // funny-programmer along, so browsing the carousel visibly reshuffled
    // itself on every apply, every --random and every auto-switch tick.
    // "The order keeps changing" was not the history being rewritten -- the
    // stored file is stable -- it was this reordering, redone each time the
    // current wallpaper changed.
    //
    // "Which card is in the middle" is a VIEW question, not a data one, and
    // the carousel already answers it: centreOn()/indexOf() scroll the ring
    // to whichever entry matches currentPath. So the list stays put and only
    // the highlight moves.
    readonly property var images: root.entries

    // Thumbnails are generated by the existing pipeline (thumbgen). For a
    // path, guess the thumbnail location the same way WallpaperSelector does.
    function thumbnailFor(path) {
        if (!path) return "";
        const base = String(path).split("/").pop().replace(/\.[^.]+$/, "");
        return `${Quickshell.env("HOME")}/.cache/thumbnails/x-large/${base}.png`;
    }

    Component.onCompleted: historyView.reload()
}
