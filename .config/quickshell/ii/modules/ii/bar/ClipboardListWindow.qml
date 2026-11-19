pragma ComponentBehavior: Bound

// `qs` itself, not only its submodules: GlobalStates (the shell's cross-
// component state singleton, and the SUPER-press signal this popup dismisses
// on) is published at the package root. Without this import the connection
// below resolves to nothing and Qt logs "GlobalStates is not defined".
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Wayland

/**
 * Clipboard history popup -- SUPER+V.
 *
 * A top-centre command palette: the card hangs under the top bar instead of
 * chasing the pointer, so it opens in the same place every time and stops
 * covering whatever the pointer was pointing at. It is the same placement and
 * the same card language as the app launcher (AppSearchOverlay.qml), which is
 * the point -- SUPER+V and SUPER+space should feel like the same machine.
 *
 * Keyboard-first, because this popup exists to be used without the mouse:
 *
 *     SUPER+V   open (search field already focused)
 *     UP/DOWN   move the selection, skipping the section headers
 *     RETURN    paste the selected entry into the window underneath
 *     DELETE    delete the selected entry
 *     ESC       clear the query if there is one, otherwise close
 *
 * The SELECTED row is the one that expands: it grows to show the entry in
 * full (up to four lines) plus a type hint -- link / shell command /
 * screenshot / text -- so a row is identifiable at a glance instead of being
 * an ellipsis. Unselected rows stay one line.
 *
 * Sections: Pinned first (pins are content-matched, see Cliphist), then
 * Recent. Every row can be pinned and deleted from its own hover/selection
 * buttons, and the header has a two-step "clear everything".
 *
 * Two panes. The left one is the list, the right one is the selected entry in
 * full -- the whole text, the picture large, a file's name/type/size (and for a
 * video its duration and a frame), because a single elided line is enough to
 * recognise a paste you remember and useless for finding one you do not
 * (ClipboardPreviewPane.qml).
 *
 * Kind filters. A chip row under the search field cuts the list down to Text,
 * Links, Images, Files or Pinned, each with its own count, so "that screenshot"
 * is a click or a keypress away instead of twenty rows of scrolling:
 *
 *     Ctrl+1..6 pick a kind      (the chip you are already on goes back to All)
 *
 * The kinds come from the entries themselves -- cliphist stores no type
 * metadata -- see entryFilterKind(). "Files" is where a video or an audio copy
 * lives: those are stored as a `file://` URI pointing at the file, never as
 * data.
 */
Scope {
    id: root

    property bool open: false

    // ── Placement ─────────────────────────────────────────────────────────
    // The card opens BESIDE the pointer, because that is where the pointer
    // already is when you press SUPER+V and it is the position the old
    // version used. `hyprctl cursorpos` is asked once per open -- it is the
    // only way to know where the pointer is -- and the window stays unmapped
    // until the answer is in, so the card never flashes in one corner and
    // jumps to another.
    property real cursorX: 0
    property real cursorY: 0
    property bool cursorKnown: false      // placement decided (probe answered or timed out)
    property bool placementFallback: false // probe failed: keep the corner fallback
    property real gap: 12                  // distance between the pointer and the card
    property real edgeMargin: Appearance.sizes.elevationMargin + 6

    // The PanelWindow, published back to the root so code OUTSIDE the
    // Variants delegate can reach it. A delegate is its own id scope, so
    // `clipboardWindow` is invisible from the IPC handler here -- the same
    // trap `listView` sets. One reference, set once, and the geometry probe
    // below can read the real on-screen numbers instead of re-deriving them.
    property var panelRef: null
    // Every live row item, for the diagnostics in the IpcHandler below: a
    // readout needs a REAL item's geometry and nothing else reachable from
    // outside the ListView can reach in (the delegate's ids are scoped to it).
    // Replaced as a whole array so bindings notice; rows add and remove
    // themselves as the list grows and the ListView recycles delegates.
    property var rowRefs: []
    // The card Rectangle itself. Separate from panelRef on purpose: the
    // window's implicitWidth/implicitHeight report what it INTENDED to be,
    // which is exactly the number that stayed correct while the card itself
    // was 380x0 and drew nothing. Reading the real item catches that class of
    // bug instead of repeating its assumption.
    property var cardRef: null
    // The preview pane, for the same reason as cardRef: its height REQUEST is
    // what decides how tall the card gets for a long entry, and "the box did
    // not grow" can only be answered by seeing the number it asked for.
    property var paneRef: null

    // ── Image previews ────────────────────────────────────────────────────
    // Decoded in one batch when the card opens, and again when the history
    // changes while it is up: a screenshot taken with the popup open still
    // shows its snapshot. Cliphist owns the batch and the generation counter
    // the rows bind to (see decodeImagePreviews there).
    // Only the rows the card actually shows: the history is capped at
    // maxEntries on screen, and decoding the whole store (measured: 234 PNGs,
    // ~23 MB) to display twenty rows is work nobody sees.
    // The ROWS that are drawn, not the raw history: `entries` is the whole
    // store (measured: 234 images), while the card shows at most a screenful.
    function visibleEntries() {
        const out = [];
        for (const row of root.listRows)
            if (row && row.entry) out.push(row.entry);
        return out;
    }
    onOpenChanged: {
        if (root.open)
            Cliphist.decodeImagePreviews(root.visibleEntries());
    }
    Connections {
        target: Cliphist
        function onEntriesChanged() {
            if (root.open)
                Cliphist.decodeImagePreviews(root.visibleEntries());
        }
    }

    Process {
        id: cursorProbe
        command: ["hyprctl", "cursorpos", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text);
                    root.cursorX = parsed.x;
                    root.cursorY = parsed.y;
                    root.placementFallback = false;
                } catch (error) {
                    root.placementFallback = true;
                }
                root.cursorKnown = true;
            }
        }
    }

    // If hyprctl is unavailable or hangs, show the popup anyway (in the top
    // centre) instead of leaving the key looking dead.
    Timer {
        id: cursorProbeTimeout
        interval: 250
        repeat: false
        onTriggered: {
            if (!root.cursorKnown) {
                root.placementFallback = true;
                root.cursorKnown = true;
            }
        }
    }

    // ── Surfaces ───────────────────────────────────────────────────────────
    //
    // These are the card's three paint layers, and they are deliberately NOT
    // the `col*` appearance colours the rest of this popup used to use.
    //
    // `colBackgroundSurfaceContainer` is `m3surfaceContainer` faded by
    // `Appearance.backgroundTransparency` -- 0.11 on this machine, so 11%
    // see-through. That is correct for a surface that sits over the shell's
    // own blurred scrim, and invisible here: with no blur rule on this
    // namespace there is nothing behind the card worth seeing through it, and
    // the wallpaper behind it is near-black, so 11% of nothing is nothing.
    //
    // `cardSurface` is DARKER and CLEARER than the bar's popup cards, on
    // purpose. It started life as StyledPopup's exact material --
    // m3surfaceContainer at 0.93, the same tone and border as the
    // battery/clock/weather cards -- and that could not read as
    // translucent. The reason is arithmetic rather than taste:
    // m3surfaceContainer resolves to #161616 in this machine's generated
    // theme (luminance 22), NOT the #201f20 fallback written into
    // Appearance.qml. Measured, not estimated: at 0.85 over a white window
    // the card rendered luminance 56, and 0.85*22 + 0.15*255 = 56.95.
    //
    // So the compositing is exact and there was never anything broken to
    // fix. The card just had nothing to be transparent INTO: the desktop
    // behind it measures luminance 29, and 22 and 29 are the same colour
    // to the eye. Darker base + lower alpha is the only combination that
    // moves both numbers at once, because over a backdrop brighter than
    // the card, dropping the alpha on its own makes the card LIGHTER.
    //
    // m3surfaceContainerLow (#121212, luminance 18) at 0.78, against the
    // three backdrops measured on this machine:
    //
    //     backdrop   was (0.93)  was (0.85)   now
    //     black  0        20.5       18.7     14.0
    //     window 29       22.6       23.0     20.4
    //     white  255      37.7       57.0     70.1
    //
    // Darker everywhere, and much more transmissive over anything bright,
    // while still standing clear of a black wallpaper instead of sinking
    // into it. Kitty, which this is imitating, is 0.92 with dynamic
    // background opacity on top.
    //
    // The compositor no longer frosts this layer at all -- see the long
    // comment on the quickshell:clipboard rule in custom/rules.lua. Frost
    // under a surface this dark and this open does not read as glass, it
    // reads as fog.
    // 0.90 rather than 0.78: the card sits over whatever the user was doing,
    // and at 0.78 the window behind it read through the rows. "make it less
    // transparent" (2026-10-28).
    readonly property real cardAlpha: 0.90
    readonly property color cardSurface: ColorUtils.applyAlpha(Appearance.m3colors.m3surfaceContainerLow, cardAlpha)
    readonly property color cardBorder: Appearance.colors.colLayer0Border
    // The three inner tones are NOT "a bit more opaque than the card" -- they
    // are tuned so that, composited OVER the card, they land on a fixed
    // opacity rather than drifting every time cardAlpha moves. Lowering only
    // the base while leaving these alone would quietly make the search field
    // and the selected row MORE opaque than the surface they sit on, which is
    // the single ugliest way a translucent panel can go wrong: solid patches
    // punched into a see-through window.
    //
    // Each value is solved from the target, with a = cardAlpha and
    // x + a(1 - x) = target:
    //     inset    target 0.965 -> x = 0.84
    //     selected target 0.980 -> x = 0.91
    //     hover    target 0.993 -> x = 0.97
    // If cardAlpha moves, these three have to be re-solved with it.
    readonly property color cardInset: ColorUtils.applyAlpha(Appearance.m3colors.m3surfaceContainerHigh, 0.84)
    readonly property color cardSelection: ColorUtils.applyAlpha(Appearance.m3colors.m3surfaceContainerHigh, 0.91)
    readonly property color cardSelectionHover: ColorUtils.applyAlpha(Appearance.m3colors.m3surfaceContainerHigh, 0.97)

    // ── The rows ───────────────────────────────────────────────────────────
    // At most this many entries are ever listed; beyond that the list scrolls.
    readonly property int maxEntries: 20

    // Two-step clear-all: the first press arms it, the second one wipes.
    property bool wipeArmed: false

    // What you type filters the list (fuzzy, the same scorer the overview
    // uses). An empty query means the normal Pinned/Recent view.
    property string searchText: ""
    readonly property bool searching: root.searchText.trim().length > 0

    // Where the keyboard cursor is. This indexes into `entryRowIndices` -- the
    // positions in `listRows` that are actual ENTRIES -- rather than into
    // `listRows` itself, so the arrows step over the "Pinned"/"Recent" headers
    // instead of stopping on them and appearing to do nothing.
    property int cursor: 0

    // The entry the user CLICKED open. Expansion is now a click, not a
    // consequence of the keyboard cursor moving: rows used to grow the moment
    // they were selected (hover included), so scrolling through the list
    // reshaped it under the pointer. Only the clicked row expands, and
    // clicking it again is what pastes it (2026-10-28).
    property string expandedEntry: ""

    // ── Kind filter ────────────────────────────────────────────────────────
    // "All" is the old view. Every other key cuts the list down to one kind,
    // which is the only way to find "that screenshot" in a store that keeps
    // 2000 entries and shows 20.
    //
    // What a kind IS comes from the entry's own content, because cliphist keeps
    // no type metadata: an image is a `[[ binary data … png 1064x591 ]]` line, a
    // file is a `file://` line, a link is a bare http(s) URL, everything else is
    // text. "Files" is the honest home for a video or an audio clip: those are
    // never stored as data, only as a URI pointing at the file on disk, so the
    // pane says which it is from the file's own extension.
    property string filter: "all"

    readonly property var filterDefs: [
        { key: "all", label: Translation.tr("All"), glyph: "apps" },
        { key: "text", label: Translation.tr("Text"), glyph: "text_snippet" },
        { key: "links", label: Translation.tr("Links"), glyph: "link" },
        { key: "images", label: Translation.tr("Images"), glyph: "image" },
        { key: "files", label: Translation.tr("Files"), glyph: "folder" },
        { key: "pinned", label: Translation.tr("Pinned"), glyph: "push_pin" }
    ]

    readonly property string filterLabel: {
        for (const def of root.filterDefs)
            if (def.key === root.filter) return def.label;
        return Translation.tr("All");
    }

    function entryFilterKind(entry) {
        if (Cliphist.entryIsImage(entry))
            return "images";
        if (Cliphist.entryIsFileUri(entry))
            return "files";
        if (/^https?:\/\/\S+$/.test(Cliphist.entryContent(entry)))
            return "links";
        return "text";
    }

    function matchesFilter(entry) {
        if (root.filter === "all")
            return true;
        if (root.filter === "pinned")
            return Cliphist.isPinned(entry);
        return root.entryFilterKind(entry) === root.filter;
    }

    // How many there are of a kind, counted over the whole shown history so the
    // number is worth reading before you click it.
    function filterCount(key) {
        if (key === "all")
            return Cliphist.shownEntries.length;
        if (key === "pinned")
            return Cliphist.shownEntries.filter(entry => Cliphist.isPinned(entry)).length;
        return Cliphist.shownEntries.filter(entry => root.entryFilterKind(entry) === key).length;
    }

    // Picking a kind is a new result set, so the keyboard cursor and the opened
    // row both go back to the top. (The scroll reset happens inside the list:
    // `listView` lives in the delegate's scope and cannot be reached from here.)
    function setFilter(key) {
        if (root.filter === key)
            return;
        root.filter = key;
        root.cursor = 0;
        root.expandedEntry = "";
    }

    // What kind of thing an entry is, which decides its icon, its hint line
    // and whether it gets a thumbnail. Cheap string tests on the content --
    // cliphist stores no type metadata, so this is the only signal available.
    // The `file://` lines of a file copy: one URI per line, one line per file.
    function fileUrisOf(entry) {
        return Cliphist.entryContent(entry).split("\n")
            .map(line => line.trim())
            .filter(line => line.startsWith("file://"));
    }

    function fileNameOf(uri) {
        const raw = String(uri ?? "").replace(/^file:\/\//, "");
        try {
            const parts = decodeURIComponent(raw).split("/");
            return parts[parts.length - 1] || raw;
        } catch (error) {
            const parts = raw.split("/");
            return parts[parts.length - 1] || raw;
        }
    }

    // What is inside the file, from the name alone. A copied video is only ever
    // a URI pointing at a file -- cliphist stores no video data -- so this is
    // the honest way to call one "video".
    function fileSubKindOf(uri) {
        const name = root.fileNameOf(uri).toLowerCase();
        const ext = name.indexOf(".") === -1 ? "" : name.split(".").pop();
        if (["mp4", "mkv", "webm", "mov", "avi", "m4v", "flv", "wmv", "mpg", "mpeg"].indexOf(ext) !== -1)
            return "video";
        if (["mp3", "flac", "wav", "ogg", "m4a", "opus", "aac"].indexOf(ext) !== -1)
            return "audio";
        if (["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "avif", "heic"].indexOf(ext) !== -1)
            return "image";
        if (ext === "pdf")
            return "pdf";
        if (["zip", "tar", "gz", "xz", "7z", "rar", "zst"].indexOf(ext) !== -1)
            return "archive";
        return "file";
    }

    function entryKind(entry) {
        if (Cliphist.entryIsImage(entry))
            return "image";
        if (Cliphist.entryIsFileUri(entry))
            return "file";
        const body = Cliphist.entryContent(entry);
        if (/^https?:\/\/\S+$/.test(body))
            return "link";
        if (/^[\s$#❯>]*(sudo |find |curl |wget |git |npm |pnpm |yarn |apt |pacman |pacman -S|cd |ls |echo |cat |grep |python3? |pip |cargo |docker |systemctl |hyprctl |qs |bash |sh |chmod |mkdir |rm |mv |cp )/.test(body))
            return "command";
        return "text";
    }

    function entryBody(entry) {
        return Cliphist.entryContent(entry);
    }

    // One clean line of an entry: real newlines and runs of spaces flattened,
    // so a multi-line copy reads as a single readable row rather than a mess.
    readonly property var kindHints: ({
        "link": Translation.tr("link"),
        "command": Translation.tr("shell command"),
        "image": Translation.tr("image"),
        "file": Translation.tr("file"),
        "video": Translation.tr("video"),
        "audio": Translation.tr("audio"),
        "pdf": Translation.tr("pdf"),
        "archive": Translation.tr("archive"),
        "text": Translation.tr("text")
    })

    // The image entries carry their own size in the cliphist text:
    //   "[[ binary data 985 KiB png 2558x1554 ]]"
    function imageMeta(entry) {
        const m = /\[\[\s*binary data\s+([^\]]+?)\s+([a-z0-9]+)\s+(\d+)x(\d+)\s*\]\]/.exec(entry);
        if (!m)
            return { size: "", dims: "" };
        return { size: m[1], dims: `${m[3]}×${m[4]}` };
    }

    // The second line under every row. A link gets its host, an image gets its
    // pixel size, everything else just says what it is.
    function hintFor(entry) {
        const kind = root.entryKind(entry);
        if (kind === "link") {
            const body = root.entryBody(entry);
            try {
                const u = new URL(body);
                return u.host.replace(/^www\./, "");
            } catch (e) {
                return Translation.tr("link");
            }
        }
        if (kind === "image") {
            const meta = root.imageMeta(entry);
            const bits = [];
            if (meta.dims) bits.push(meta.dims);
            if (meta.size) bits.push(meta.size);
            return bits.length > 0 ? Translation.tr("image") + " · " + bits.join(" · ") : Translation.tr("image");
        }
        if (kind === "file") {
            const uris = root.fileUrisOf(entry);
            if (uris.length === 0)
                return Translation.tr("file");
            const what = root.kindHints[root.fileSubKindOf(uris[0])] ?? Translation.tr("file");
            return uris.length > 1 ? uris.length + " " + Translation.tr("files") + " · " + what : what;
        }
        return root.kindHints[kind] ?? "";
    }

    // Display rows: section headers interleaved with entries.
    function buildRows() {
        const rows = [];
        // Searching: one flat ranked list, no pinned section -- when you type
        // you are looking for a thing, not organising.
        if (root.searching) {
            const hits = Cliphist.fuzzyQuery(root.searchText.trim())
                .filter(entry => root.matchesFilter(entry))
                .slice(0, root.maxEntries);
            if (hits.length > 0)
                rows.push({ kind: "header", label: Translation.tr("Results") });
            for (let i = 0; i < hits.length; i++)
                rows.push({ kind: "entry", entry: hits[i] });
            return rows;
        }
        // One kind picked: a single flat section, newest first. Pinned entries
        // stay on top because the order they come in is pins-first -- pinning
        // something says you want it, whatever kind it is.
        if (root.filter !== "all") {
            const listed = Cliphist.pinnedEntriesWithPinnedFirst()
                .filter(entry => root.matchesFilter(entry))
                .slice(0, root.maxEntries);
            if (listed.length > 0)
                rows.push({ kind: "header", label: root.filterLabel });
            for (let i = 0; i < listed.length; i++)
                rows.push({ kind: "entry", entry: listed[i] });
            return rows;
        }
        const all = Cliphist.pinnedEntriesWithPinnedFirst();
        const pinned = all.filter(entry => Cliphist.isPinned(entry));
        const rest = all.filter(entry => !Cliphist.isPinned(entry)).slice(0, root.maxEntries);
        if (pinned.length > 0) {
            rows.push({ kind: "header", label: Translation.tr("Pinned") });
            for (let i = 0; i < pinned.length; i++)
                rows.push({ kind: "entry", entry: pinned[i] });
        }
        if (rest.length > 0) {
            rows.push({ kind: "header", label: Translation.tr("Recent") });
            for (let i = 0; i < rest.length; i++)
                rows.push({ kind: "entry", entry: rest[i] });
        }
        return rows;
    }

    readonly property var listRows: buildRows()

    // How many entries are listed right now -- the "N of M" in the header, so a
    // filter that is hiding most of the history says so.
    readonly property int listedCount: {
        let count = 0;
        for (const row of root.listRows)
            if (row.kind === "entry") count += 1;
        return count;
    }

    // Which rows of `listRows` are entries -- what the cursor walks over.
    readonly property var entryRowIndices: {
        const out = [];
        for (let i = 0; i < root.listRows.length; i++)
            if (root.listRows[i].kind === "entry")
                out.push(i);
        return out;
    }

    // The one row index the cursor is on, or -1 when there is nothing to pick.
    readonly property int selectedRowIndex:
        (root.cursor >= 0 && root.cursor < root.entryRowIndices.length)
            ? root.entryRowIndices[root.cursor]
            : -1

    readonly property var selectedEntry:
        root.selectedRowIndex >= 0 ? root.listRows[root.selectedRowIndex].entry : null

    function moveCursor(delta) {
        const n = root.entryRowIndices.length;
        if (n === 0)
            return;
        // Wrap: stepping down past the last entry returns to the first. A list
        // you can get stuck at the bottom of is worse than a list that loops.
        root.cursor = ((root.cursor + delta) % n + n) % n;
    }

    function pasteSelected() {
        if (root.selectedEntry === null)
            return;
        Cliphist.paste(root.selectedEntry);
        root.close();
    }

    function deleteSelected() {
        if (root.selectedEntry === null)
            return;
        Cliphist.deleteEntry(root.selectedEntry);
    }

    function togglePinSelected() {
        if (root.selectedEntry === null)
            return;
        Cliphist.togglePin(root.selectedEntry);
    }

    function clearAll() {
        Cliphist.wipe();
        Cliphist.clearPinned();
        root.wipeArmed = false;
    }

    // Arming the wipe is only good for a moment: forget it if you wander off.
    Timer {
        id: wipeArmTimer
        interval: 4000
        repeat: false
        onTriggered: root.wipeArmed = false
    }

    function toggle() {
        if (!root.open) {
            // Which window owns this paste, captured BEFORE the popup takes the
            // keyboard: see Cliphist.rememberPasteTarget and
            // scripts/clipboard/paste-keystroke.sh (follow_mouse sends the keys
            // to whatever the pointer is over otherwise).
            Cliphist.rememberPasteTarget()
            root.cursorKnown = false;
            cursorProbe.running = true;
            cursorProbeTimeout.restart();
        } else {
            cursorProbeTimeout.stop();
        }
        root.open = !root.open;
    }

    function close() {
        root.open = false;
        // Forget the old pointer position so the next open does not briefly
        // show the card where it was last time.
        root.cursorKnown = false;
        cursorProbeTimeout.stop();
        // A closed popup has no expanded row; the next open starts compact.
        root.expandedEntry = "";
    }

    Variants {
        model: Quickshell.screens


        PanelWindow {
            id: clipboardWindow
            required property var modelData

            // Publish to the root (see the note on root.panelRef). Folded into
            // this ONE Component.onCompleted deliberately: a second one on the
            // same object is a hard load failure in Quickshell 0.3.1
            // ("Property value set multiple times") and takes the whole config
            // out with it.
            Component.onCompleted: {
                root.panelRef = clipboardWindow;
                root.cardRef = popupCard;
                root.paneRef = previewPane;
            }
            Component.onDestruction: {
                if (root.panelRef === clipboardWindow)
                    root.panelRef = null;
                if (root.cardRef === popupCard)
                    root.cardRef = null;
                if (root.paneRef === previewPane)
                    root.paneRef = null;
            }

            screen: modelData

            readonly property real screenW: modelData?.width ?? 0
            readonly property real screenH: modelData?.height ?? 0
            readonly property real edgeMargin: root.edgeMargin

            // A compact card. It is deliberately smaller than the version it replaced
            // (400x520) in BOTH directions: the old one was a tall panel of
            // 44px rows whose whole job is "pick one of these", and it covered
            // half the screen next to the pointer. CAPPED against the space
            // between the pointer and the far edge, so it can never be wider
            // than the room it opens into.
            // 440 wide (was 380): the rows carry a thumbnail, a line of text
            // and the two actions, and at 380 an image row's dimensions and
            // the entry were always elided. "slightly bigger" (2026-10-28).
            // 760 with a 272px preview pane: the list keeps the 440 it had and
            // the rest is the preview, so the card grows sideways instead of
            // making the rows taller. It still shrinks on a narrow screen (the
            // pane keeps its width and the list takes what is left).
            readonly property real cardW: Math.max(300, Math.min(760, screenW - root.edgeMargin * 2))
            // Height is decided together with the position (see below) so the
            // two cannot chase each other: the card is never taller than the
            // room on whichever side of the pointer it opens towards.
            readonly property real naturalContentHeight: popupCard.naturalHeight
            readonly property real minPopupHeight: 180
            // 400 (was 360): with 46px rows and the wider card the list was
            // showing barely six entries before scrolling. "slightly bigger"
            // (2026-10-28).
            // 460 (was 400): the preview pane needs room for a picture and a
            // few lines of it, and the list gets the same rows either way.
            // NO 460 CAP ANY MORE. The preview pane asks for the height its
            // entry needs (ClipboardPreviewPane.desiredHeight), and a long
            // paste -- the case this pane exists for -- needs more than 460.
            // The card grows to the entry and is still clamped to the screen
            // below, so the only thing that can be too tall for it is an entry
            // taller than the display, and that one scrolls.
            readonly property real maxPopupHeight: Math.max(460, screenH - root.edgeMargin * 2)
            // What the LIST is allowed to be, kept at its old height (460 - 140
            // = 320). Only the preview may grow the card: without this, twenty
            // rows would make every open a screen-tall card regardless of the
            // entry in the preview.
            readonly property real maxListHeight: Math.max(120,
                Math.min(320, screenH - root.edgeMargin * 2 - 140))

            // Pointer position relative to this monitor.
            readonly property real localX: root.cursorX - (modelData?.x ?? 0)
            readonly property real localY: root.cursorY - (modelData?.y ?? 0)
            readonly property bool anchorToCursor: root.cursorKnown && !root.placementFallback

            // Clear screen above and below the pointer, and the best side
            // horizontally. The card opens towards whichever has more room and
            // is then CLAMPED into the screen, so it is always fully visible --
            // never clipped by an edge, never under the bar.
            readonly property real roomBelow: Math.max(0, screenH - root.edgeMargin - (localY + root.gap))
            readonly property real roomAbove: Math.max(0, localY - root.gap - root.edgeMargin)
            readonly property bool placeAbove: (naturalContentHeight > roomBelow) && (roomAbove > roomBelow)
            readonly property real roomBeside: Math.max(minPopupHeight, placeAbove ? roomAbove : roomBelow)
            readonly property real cardH: Math.max(minPopupHeight,
                Math.min(naturalContentHeight,
                    Math.min(maxPopupHeight, Math.min(roomBeside, screenH - root.edgeMargin * 2))))

            // Flip to the other side of the pointer when there is not enough
            // room on the preferred one, then clamp. The clamp is what
            // guarantees the "completely visible" part: whatever the pointer
            // did, both edges of the card land inside the margins.
            readonly property real rawX: (localX + root.gap + cardW > screenW - root.edgeMargin)
                ? localX - root.gap - cardW
                : localX + root.gap
            readonly property real rawY: placeAbove ? localY - root.gap - cardH : localY + root.gap
            readonly property int anchoredX: Math.round(Math.max(root.edgeMargin,
                Math.min(rawX, screenW - cardW - root.edgeMargin)))
            readonly property int anchoredY: Math.round(Math.max(root.edgeMargin,
                Math.min(rawY, screenH - cardH - root.edgeMargin)))

            WlrLayershell.namespace: "quickshell:clipboard"
            WlrLayershell.layer: WlrLayer.Overlay
            // EXCLUSIVE, not OnDemand. This popup is keyboard-first: it grabs
            // the keyboard the moment it opens so UP/DOWN and RETURN work
            // without a click first. OnDemand was the wrong tool here --
            // Hyprland only hands the keyboard to a layer surface once that
            // surface has been CLICKED, so `forceActiveFocus()` gave the QML
            // item focus while the keystrokes went to the window underneath.
            // That is why the arrows did nothing. The grab lasts only as long
            // as the popup is open, and Escape / a click outside releases it.
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            color: "transparent"
            exclusiveZone: 0
            exclusionMode: ExclusionMode.Ignore

            // Wait for the pointer probe before mapping, so the card never
            // appears in the fallback spot and then jumps.
            visible: root.open && root.cursorKnown

            // ── The window is the whole SCREEN now ───────────────────────
            //
            // It used to be exactly card-sized, with `mask: Region { item:
            // popupCard }` so only the card took input, and a separate set of
            // four band WINDOWS covering screen-minus-card to catch presses
            // outside. That did not work, and the reason is stacking, not
            // geometry: the bands mapped correctly and Hyprland reported them
            // tiling the screen minus the card exactly, but they are separate
            // layer surfaces, and they end up BELOW `quickshell:bar` (which is
            // 1707x190 across the top of the Overlay layer) and below anything
            // else the shell has mapped on that layer. Winning an input
            // region against that is a race nobody should enter.
            //
            // So the catcher moves INSIDE this window. One surface, one
            // stacking position -- the one the card already demonstrably
            // receives clicks in -- and the card sits on top of the catcher
            // within the window, which is ordinary QML z-order rather than
            // compositor ordering:
            //
            //     outsideCatcher   (fills the screen, closes on press)
            //       popupCard      (the card, positioned inside the screen)
            //         cardShield   (fills the card, swallows presses)
            //           rows       (their own MouseAreas, on top of that)
            //
            // A press on the card hits the rows, or the shield; a press
            // anywhere else hits the catcher.
            //
            // No mask: a PanelWindow with no mask is interactive across its
            // whole area, which is exactly what the full-screen window wants.
            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }
            margins {
                top: 0
                left: 0
                bottom: 0
                right: 0
            }

            implicitWidth: clipboardWindow.screenW
            implicitHeight: clipboardWindow.screenH

            // The catcher. Declared BEFORE popupCard so the card is stacked
            // over it; a MouseArea that comes later in the file is on top.
            MouseArea {
                id: outsideCatcher
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                // onPressed, not onClicked: the popup is already gone before
                // the button comes back up, so the release cannot land on
                // whatever took its place.
                onPressed: root.close()
            }

            // NO GlobalFocusGrab here at all, in either direction.
            //
            // Outbound: the popup does not register with the grab, because the
            // grab never delivered a dismissal for it anyway (measured -- the
            // sidebar's grab clears on an outside click, this one's stayed
            // active across the same click) and while it was registered
            // Hyprland routed the pointer at the grabbing surface, so an
            // outside press reached neither the card nor the catcher. The
            // keyboard does not need the grab: WlrKeyboardFocus.Exclusive on
            // this window holds it on its own.
            //
            // Inbound -- and this is the one that was actively wrong: a
            // Connections on GlobalFocusGrab.dismissed, kept "so a dismissal
            // triggered by any other popup still closes this one". It fired
            // whenever ANY popup's grab was cleared, including clears that had
            // nothing to do with the clipboard, and closed the popup about a
            // second after it opened -- which is exactly what a stale listener
            // for a mechanism you have left looks like. The popup owns its own
            // dismissal now: the outside catcher below, and Escape.

            onVisibleChanged: {
                if (visible) {
                    // A stale query outlives the popup otherwise -- clearing it
                    // here makes every open a fresh start, with the cursor on
                    // the first entry.
                    //
                    // The FIELD is cleared, not just root.searchText: the field
                    // is what the user reads, and `onTextChanged` only ever
                    // syncs the field INTO the model. Resetting the model alone
                    // left the box showing the previous query while the list
                    // underneath was unfiltered -- the two disagreeing, and the
                    // next keystroke filtering from the stale text.
                    searchInput.clear();
                    root.cursor = 0;
                    // ...and the list itself back to the TOP, which is the half
                    // that was missing.
                    //
                    // The window is only hidden between opens, never destroyed,
                    // so the ListView keeps its `contentY`. The scroll reset used
                    // to live in searchInput.onTextChanged alone, and clearing
                    // an EMPTY field emits nothing -- so a plain reopen (no
                    // query left over) came back scrolled to wherever the last
                    // session ended. The newest copy is row one, so it sat
                    // scrolled off ABOVE the visible area and the card appeared
                    // to open on older entries: "it doesn't show the actual
                    // recent message copied at the top". Reset it here, on
                    // every open, alongside the cursor.
                    if (listView)
                        listView.positionViewAtBeginning();
                    searchInput.forceActiveFocus();
                } else {
                    // The window is off screen, so the keyboard has gone back to
                    // the window underneath -- this surface held it exclusively
                    // (see the keyboardFocus note below). THAT is the moment the
                    // paste keystroke can be sent; sending it while the popup
                    // was still up put the text into this popup's own search
                    // field instead. See Cliphist.paste and
                    // scripts/clipboard/paste-keystroke.sh.
                    Cliphist.sendPendingPaste();
                }
            }

            Rectangle {
                id: popupCard
                // EXPLICIT width AND height, always. This card is a plain
                // Rectangle in no Layout, so it gets no implicit size: an
                // earlier version set only `width`, and the height stayed at 0.
                // The window still reported 380x360 (it read its own
                // implicitWidth/implicitHeight), every diagnostic said the
                // popup was open and correctly positioned, and the card drew
                // nothing at all -- a window-sized thing containing a
                // zero-height thing.
                // Positioned in SCREEN coordinates, translated into this
                // window's coordinates by subtracting where the window itself
                // sits on the screen.
                //
                // The subtraction is load-bearing and not paranoia: a
                // full-screen PanelWindow is NOT placed at 0,0. Quickshell
                // offsets it past the bar's reserved height -- Hyprland
                // reports `quickshell:clipboard x=0 y=45 1707x1022` on a
                // 1067px screen. Using anchoredX/anchoredY raw therefore drew
                // the card 45px below where the placement arithmetic meant it,
                // which is the same class of bug as the card being in the
                // wrong place at all.
                //
                //
                // `parent.x/y` is the window's screen origin as far as QML is
                // concerned, and it reports 0 -- but Hyprland places the surface
                // at y=45, past the bar's reserved strip. The offset is not
                // knowable from inside the window (it is not
                // Appearance.sizes.barHeight, which is 40, and it moved
                // between 45 and 57 when the window was still card-sized and
                // anchored to whichever edge the pointer was on).
                //
                // So the offset is not corrected, it is made HARMLESS: the card
                // is clamped to the window's own height rather than to the
                // screen. `anchoredY` is a screen coordinate and can therefore
                // be up to 45px too low, but it can never put the card past the
                // bottom edge, because the clamp is against 1022 -- the height
                // the card actually has to live in -- not against 1067.
                readonly property real maxY: Math.max(0, (parent.height ?? 0) - clipboardWindow.cardH)
                readonly property real maxX: Math.max(0, (parent.width ?? 0) - clipboardWindow.cardW)
                x: Math.max(0, Math.min(clipboardWindow.anchoredX - (parent.x ?? 0), maxX))
                y: Math.max(0, Math.min(clipboardWindow.anchoredY - (parent.y ?? 0), maxY))
                width: clipboardWindow.cardW
                height: clipboardWindow.cardH

                // Swallows presses on the card's own padding (header, gaps,
                // the strip below the last row) so they do not fall through
                // to the outside catcher behind it. Declared before the
                // ColumnLayout, so the rows are stacked above it and still get
                // their own clicks.
                MouseArea {
                    id: cardShield
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onPressed: mouse => mouse.accepted = true
                }

                // Measured from the list's CONTENT height, not from its own
                // implicit height: the latter is fed by the layout, so using it
                // here would make the card size the layout that sizes the card.
                readonly property real naturalHeight: cardColumn.implicitHeight + 20
                radius: Appearance.rounding.large
                color: root.cardSurface
                border.width: 1
                border.color: root.cardBorder
                clip: true

                ColumnLayout {
                    id: cardColumn
                    anchors.fill: parent
                    anchors.margins: 9
                    spacing: 6

                    // ── Header ────────────────────────────────────────────
                    RowLayout {
                        id: headerRow
                        Layout.fillWidth: true
                        spacing: 10

                        // A font glyph rather than a tinted icon image. The
                        // popup used to tint its icons with a Qt5Compat
                        // ColorOverlay, and tearing those overlays down with the
                        // window segfaulted the whole shell -- every time the
                        // clipboard closed. Glyphs need no tinting, so there is
                        // nothing left to tear down.
                        MaterialSymbol {
                            text: "content_paste"
                            iconSize: 20
                            color: Appearance.colors.colOnLayer1
                        }

                        StyledText {
                            Layout.alignment: Qt.AlignVCenter
                            text: Translation.tr("Clipboard")
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Bold
                            color: Appearance.colors.colOnLayer1
                        }

                        StyledText {
                            Layout.alignment: Qt.AlignVCenter
                            text: {
                                const total = Cliphist.shownEntries.length;
                                const listed = root.listedCount;
                                if (root.searching)
                                    return listed + " " + Translation.tr("of") + " " + total;
                                if (root.filter !== "all")
                                    return listed + " " + Translation.tr("of") + " " + total
                                        + " · " + root.filterLabel;
                                return total + " " + Translation.tr("entries");
                            }
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }

                        Item { Layout.fillWidth: true }

                        // Bulk delete. Deliberately two-step: a single
                        // misclick should not be able to throw the history away.
                        RippleButton {
                            id: clearAllButton
                            implicitWidth: 28
                            implicitHeight: 28
                            buttonRadius: Appearance.rounding.full
                            onClicked: {
                                if (root.wipeArmed) {
                                    root.clearAll();
                                } else {
                                    root.wipeArmed = true;
                                    wipeArmTimer.restart();
                                }
                            }
                            contentItem: MaterialSymbol {
                                anchors.centerIn: parent
                                text: root.wipeArmed ? "dangerous" : "delete_sweep"
                                iconSize: 16
                                color: root.wipeArmed
                                    ? Appearance.colors.colError
                                    : Appearance.colors.colSubtext
                            }
                            StyledToolTip {
                                text: root.wipeArmed
                                    ? Translation.tr("Press again to delete everything (including pins)")
                                    : Translation.tr("Delete all")
                            }
                        }
                    }

                    // ── Search ────────────────────────────────────────────
                    Rectangle {
                        id: searchField
                        Layout.fillWidth: true
                        implicitHeight: 36
                        radius: Appearance.rounding.small
                        color: root.cardInset

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 4
                            spacing: 6

                            MaterialSymbol {
                                text: "search"
                                iconSize: 16
                                color: Appearance.colors.colSubtext
                            }

                            TextField {
                                id: searchInput
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                background: null
                                placeholderText: Translation.tr("Search clipboard…")
                                placeholderTextColor: Appearance.colors.colSubtext
                                color: Appearance.colors.colOnLayer1
                                selectionColor: Appearance.colors.colPrimary
                                selectedTextColor: Appearance.colors.colOnPrimary
                                font.pixelSize: Appearance.font.pixelSize.small
                                verticalAlignment: TextInput.AlignVCenter
                                onTextChanged: {
                                    root.searchText = text;
                                    // A new result set means the old cursor
                                    // position is meaningless.
                                    root.cursor = 0;
                                    if (listView)
                                        listView.positionViewAtBeginning();
                                }
                                Keys.onPressed: event => {
                                    // Navigation and actions live here because
                                    // this field holds the focus for the whole
                                    // time the popup is open -- key events that
                                    // the field does not consume would
                                    // otherwise be typed into the query.
                                    if (event.key === Qt.Key_Down) {
                                        root.moveCursor(1);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Up) {
                                        root.moveCursor(-1);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_PageDown) {
                                        root.moveCursor(5);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_PageUp) {
                                        root.moveCursor(-5);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        // RETURN pastes exactly what is
                                        // selected, not the top hit: the whole
                                        // point of having a selection.
                                        root.pasteSelected();
                                        event.accepted = true;
                                                                          } else if (event.key === Qt.Key_Delete) {
                                          root.deleteSelected();
                                          event.accepted = true;
                                      } else if ((event.modifiers & Qt.ControlModifier) !== 0
                                          && event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
                                          // Ctrl+1..6 pick a kind, in the order the
                                          // chips are drawn.
                                          const picked = event.key - Qt.Key_1;
                                          if (picked < root.filterDefs.length)
                                              root.setFilter(root.filterDefs[picked].key);
                                          event.accepted = true;
                                    } else if (event.key === Qt.Key_Escape) {
                                        if (root.searchText.length > 0)
                                            searchInput.clear();
                                        else
                                            // Close directly rather than going
                                            // through GlobalFocusGrab.dismiss():
                                            // this window is no longer in that
                                            // grab's list, so dismissing would
                                            // clear every OTHER popup on screen
                                            // to close this one.
                                            root.close();
                                        event.accepted = true;
                                    }
                                }
                            }

                            RippleButton {
                                visible: root.searching
                                implicitWidth: 26
                                implicitHeight: 26
                                buttonRadius: Appearance.rounding.full
                                onClicked: searchInput.clear()
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "close"
                                    iconSize: 14
                                    color: Appearance.colors.colSubtext
                                }
                            }
                        }
                    }

                    // ── Kind filter ───────────────────────────────────────
                    // One chip per kind, each with the number of entries it
                    // would show, so the choice is made with the counts in
                    // view rather than by opening four lists. Clicking the chip
                    // that is already active goes back to All; Ctrl+1..6 pick
                    // one from the keyboard.
                    RowLayout {
                        id: filterRow
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: root.filterDefs

                            delegate: Rectangle {
                                id: chip
                                required property var modelData
                                required property int index
                                readonly property bool active: root.filter === modelData.key
                                implicitWidth: chipContent.implicitWidth + 16
                                implicitHeight: 24
                                radius: Appearance.rounding.full
                                color: chip.active
                                    ? Appearance.colors.colPrimary
                                    : (chipMouse.containsMouse ? root.cardSelectionHover : root.cardInset)
                                Behavior on color {
                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(chip)
                                }

                                RowLayout {
                                    id: chipContent
                                    anchors.centerIn: parent
                                    spacing: 4

                                    MaterialSymbol {
                                        text: chip.modelData.glyph
                                        iconSize: 12
                                        color: chip.active
                                            ? Appearance.colors.colOnPrimary
                                            : Appearance.colors.colSubtext
                                    }
                                    StyledText {
                                        text: chip.modelData.label
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: chip.active
                                            ? Appearance.colors.colOnPrimary
                                            : Appearance.colors.colOnLayer1
                                    }
                                    StyledText {
                                        text: root.filterCount(chip.modelData.key)
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: chip.active
                                            ? ColorUtils.transparentize(Appearance.colors.colOnPrimary, 0.25)
                                            : ColorUtils.transparentize(Appearance.colors.colSubtext, 0.1)
                                    }
                                }

                                MouseArea {
                                    id: chipMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.setFilter(chip.active ? "all" : chip.modelData.key)
                                }

                                StyledToolTip {
                                    text: chip.modelData.label + " · Ctrl+" + (chip.index + 1)
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        color: Appearance.colors.colOutlineVariant
                    }

                    // ── Empty states ─────────────────────────────────────
                                          RowLayout {
                          id: listRow
                          Layout.fillWidth: true
                          Layout.fillHeight: true
                          // Same bound as the list below, and for the same
                          // reason: a RowLayout's implicit height is the tallest
                          // child, so without a maximum it asked for every row at
                          // once and pushed the preview pane's actions out of the
                          // card (measured: the card is 460 tall, the left
                          // column asked for 1092).
                          //
                          // The maximum is the CARD's, not the list's: this row
                          // also holds the preview pane, and the pane is what is
                          // allowed to make the card tall (see maxListHeight).
                          Layout.maximumHeight: clipboardWindow.maxPopupHeight
                          spacing: 10

                        ColumnLayout {
                            id: listColumn
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 6
                        ColumnLayout {
                            visible: listView.count === 0
                            Layout.alignment: Qt.AlignHCenter
                            Layout.fillWidth: true
                            Layout.minimumHeight: 120
                            spacing: 8

                            MaterialSymbol {
                                Layout.alignment: Qt.AlignHCenter
                                                                  text: root.searching ? "search_off"
                                      : (root.filter !== "all" ? "filter_alt_off" : "content_paste_off")
                                iconSize: 28
                                color: Appearance.colors.colSubtext
                            }
                            StyledText {
                                Layout.alignment: Qt.AlignHCenter
                                                                  text: root.searching
                                      ? Translation.tr("No matches")
                                      : (root.filter !== "all"
                                          ? Translation.tr("Nothing of this kind")
                                          : Translation.tr("Clipboard is empty"))
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                            }
                            StyledText {
                                                                  visible: !root.searching && root.filter === "all"
                                Layout.alignment: Qt.AlignHCenter
                                Layout.maximumWidth: 320
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: Translation.tr("Copy something and it will show up here")
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.3)
                            }
                        }

                        // ── The list ─────────────────────────────────────────
                        StyledListView {
                            id: listView
                            visible: listView.count > 0
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 54
                                                          // The card is capped at maxPopupHeight, so the list has to
                              // leave room for the header, the search field, the filter
                              // chips, the divider, the card's margins and the layout's
                              // own spacing (measured 139px in total). Asking for the
                              // full maxPopupHeight pushed the preview pane's Paste and
                              // Open buttons off the bottom of a 460px card and they
                              // were clipped away with it.
                              Layout.preferredHeight: Math.min(listView.contentHeight,
                                  clipboardWindow.maxListHeight)
                            spacing: 2
                            clip: true
                            model: root.listRows

                            // Keep the keyboard selection on screen. This lives HERE
                            // rather than in root.moveCursor because `listView` is
                            // declared inside the Variants delegate, and a delegate
                            // is its own id scope -- a function on root cannot see
                            // it. Reacting to the cursor from in here can.
                            Connections {
                                target: root
                                function onCursorChanged() {
                                    if (listView && root.selectedRowIndex >= 0)
                                        listView.positionViewAtIndex(root.selectedRowIndex, ListView.Contain);
                                }
                                // A new kind is a new list, so it starts at the
                                // top. Only reachable from in here: `listView`
                                // belongs to the delegate's id scope.
                                function onFilterChanged() {
                                    if (listView)
                                        listView.positionViewAtBeginning();
                                }
                            }

                            delegate: Loader {
                                id: sectionLoader
                                required property var modelData
                                // Qt 6 only exposes `index` to a delegate when it
                                // is DECLARED. Without this it is undefined, and the
                                // `rowIndex` below then assigned undefined to a
                                // required int on every single row -- logged
                                // repeatedly and leaving the rows without the index
                                // the keyboard selection is matched by.
                                required property int index
                                width: listView.width
                                sourceComponent: modelData.kind === "header" ? sectionHeader : entryRow
                                property var rowData: modelData

                                Component {
                                    id: sectionHeader
                                    Item {
                                        implicitHeight: 24
                                        width: listView.width

                                        StyledText {
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: sectionLoader.rowData.label
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            font.weight: Font.Medium
                                            color: Appearance.colors.colSubtext
                                        }
                                        // The pin glyph on the right of the title
                                        // reads as "these rows are the pinned ones"
                                        // rather than decorating the label.
                                        MaterialSymbol {
                                            visible: sectionLoader.rowData.label === Translation.tr("Pinned")
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "push_pin"
                                            iconSize: 13
                                            color: Appearance.colors.colPrimary
                                        }
                                    }
                                }

                                Component {
                                    id: entryRow
                                    ClipboardEntryItem {
                                        entry: sectionLoader.rowData.entry
                                        rowIndex: sectionLoader.index
                                        selected: root.selectedRowIndex === sectionLoader.index
                                    }
                                }
                            }
                        }
                        }

                        ClipboardPreviewPane {
                            id: previewPane
                            Layout.preferredWidth: 272
                            Layout.fillHeight: true
                            entry: root.selectedEntry === null ? "" : String(root.selectedEntry)
                            onPasteRequested: {
                                if (root.selectedEntry === null)
                                    return;
                                Cliphist.paste(root.selectedEntry);
                                root.close();
                            }
                            onOpenRequested: path => Quickshell.execDetached(["xdg-open", path])
                        }
                    }
                }
            }
        }
    }

    // ── A fresh SUPER press dismisses the popup ────────────────────────────
    //
    // SUPER is the "get me out of here" key everywhere else on this desktop, and
    // it is what dismisses this popup -- but the dismissal belongs HERE, on the
    // shell's own record of the key going down, and not in the compositor's
    // SUPER bind.
    //
    // It used to be a `qs ipc call clipboard close` in custom/keybinds.lua's
    // SUPER_L/SUPER_R bind. In this build a Lua FUNCTION body in `hl.bind`
    // registers as a plain RELEASE bind (the same quirk that makes
    // `{ drag = true }` a no-op -- see the note on the resize drag in that
    // file), so that "on press" close actually fired on the way UP: SUPER+V
    // opened the popup and letting go of SUPER shut it again a beat later,
    // which is exactly the reported "you have to hold SUPER to keep it open".
    //
    // `superDown` is driven by the workspaceNumber global's pressed/released
    // dispatch -- the same signal the bar's workspace-number hint reads, so the
    // edge is the real one by construction. Rising (a fresh press) dismisses;
    // releasing changes nothing, which is what makes SUPER+V survive: SUPER is
    // already down when V opens the popup, so there is no rising edge left to
    // fire until the user presses SUPER again on purpose.
    Connections {
        target: GlobalStates
        function onSuperDownChanged() {
            if (GlobalStates.superDown)
                root.close();
        }
    }

    // ── Dismissal from the compositor's own event stream ───────────────────
    //
    // Changing desktop (a swipe, a gesture, SUPER+number) and putting a window
    // fullscreen both mean the thing under this card just moved. Leaving the
    // card floating over a desktop the user has already left is worse than
    // closing late, so both dismiss it.
    //
    // Hyprland's socket, not a Timer and not a property watch, for three
    // reasons that are all about not being wrong quietly:
    //
    //   * A workspace change and a fullscreen toggle both arrive here as plain
    //     events. Polling HyprlandData would mean re-asking the compositor on
    //     a timer and would still only ever see the state, never the
    //     transition.
    //   * `onRawEvent` also fires for THIS popup's own openlayer and
    //     closelayer -- the card is a layer surface. Anything that reacted to
    //     those would close the popup the instant it opened, which is the
    //     failure this list is written to avoid.
    //   * `fullscreen` fires on the way OUT of fullscreen too. Harmless: the
    //     popup is already closed by then and close() is a no-op.
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (!root.open)
                return;
            if (event.name === "workspace" || event.name === "workspacev2"
                || event.name === "activeworkspace" || event.name === "activeworkspacev2"
                || event.name === "moveworkspace"
                || event.name === "fullscreen")
                root.close();
        }
    }

    GlobalShortcut {
        name: "clipboardToggle"
        description: "Toggles the clipboard popup"

        onPressed: root.toggle()
    }

    IpcHandler {
        target: "clipboard"

        function toggle(): void {
            root.toggle();
        }
        function close(): void {
            root.close();
        }
        // Diagnostic: what the keyboard cursor is sitting on right now, and
        // how many rows there are. Readable without touching the pointer.
        function state(): string {
            const sel = root.selectedEntry === null
                ? "none"
                : String(root.selectedEntry).replace(/\s+/g, " ").slice(0, 60);
            // `expanded` is part of the readout because expansion is now a
            // CLICK rather than a consequence of selection, and a check (or a
            // person) has to be able to see which row is open without
            // measuring the card.
            const open = root.expandedEntry === "" ? "none"
                : String(root.expandedEntry).replace(/\s+/g, " ").slice(0, 40);
            // rowH is the LIVE height of the first compact row. It is here
            // because the compact-row geometry (50 = 6 + 38 + 6 content box)
            // is the whole point of the last change and is not visible in any
            // other readout: 46 means the old rows are still on screen, i.e.
            // the edit did not reload. Rows the user has clicked open report
            // their expanded height instead of the compact one, so only
            // compact rows are counted here.
            const compact = root.rowRefs.filter(r => r && !r.expanded && r.height > 0);
            const rowH = compact.length > 0 ? Math.round(compact[0].height) : -1;
            return `open=${root.open} rows=${root.listRows.length} entries=${root.entryRowIndices.length}`
                + ` cursor=${root.cursor} selected="${sel}" query="${root.searchText}"`
                + ` expanded="${open}" rowH=${rowH} liveRows=${root.rowRefs.length}`
                + ` anchor=${root.cursorKnown && !root.placementFallback}`;
        }
        // Where the card actually landed, and whether it fits on the screen.
        // The clamp is arithmetic, so this proves it: a card whose right or
        // bottom edge exceeds the screen would show up here immediately.
        // Where the card ended up inside the full-screen window, and whether
        // the outside catcher is actually covering the screen around it.
        // Reading the card's REAL position rather than the intended one is the
        // point: a card placed by a stale or wrong conversion still looks
        // correct in every other readout.
        function dismissInfo(): string {
            const c = root.cardRef;
            if (!c)
                return "card: NOT CREATED";
            const w = root.panelRef;
            return `card at ${Math.round(c.x)},${Math.round(c.y)} size=${Math.round(c.width)}x${Math.round(c.height)}`
                + ` window=${Math.round(w?.width ?? 0)}x${Math.round(w?.height ?? 0)}`
                + ` windowScreenOrigin=${Math.round(w?.x ?? 0)},${Math.round(w?.y ?? 0)}`
                + ` catcher covers=${Math.round(w?.width ?? 0)}x${Math.round(w?.height ?? 0)}`
                + ` open=${root.open}`;
        }
        function geometry(): string {
            const w = root.panelRef;
            const c = root.cardRef;
            if (!w || !c)
                return "no panel";
            return `screen=${w.screenW}x${w.screenH}`
                + ` window=${Math.round(w.width)}x${Math.round(w.height)}`
                + ` card=${Math.round(c.width)}x${Math.round(c.height)}`
                + ` at=${w.anchoredX},${w.anchoredY}`
                + ` above=${w.placeAbove}`
                + ` pointer=${Math.round(root.cursorX)},${Math.round(root.cursorY)}`
                + ` visible=${w.visible}`
                + ` natural=${Math.round(c.naturalHeight)}`
                + ` paneWant=${Math.round(root.paneRef?.desiredHeight ?? -1)}`
                + ` paneH=${Math.round(root.paneRef?.height ?? -1)}`
                + ` paneBody=${Math.round(root.paneRef?.bodyDesiredHeight ?? -1)}`
                + ` chars=${root.paneRef?.bodyChars ?? -1}`
                + (c.width > 1 && c.height > 1 ? " HAS-AREA" : " NO-AREA!")
                + (w.anchoredX + w.cardW <= w.screenW && w.anchoredY + w.cardH <= w.screenH
                    && w.anchoredX >= 0 && w.anchoredY >= 0
                    ? " FITS" : " CLIPPED!");
        }
        function move(delta: int): void {
            root.moveCursor(delta);
        }
        function select(): string {
            if (root.selectedEntry === null)
                return "nothing selected";
            Cliphist.paste(root.selectedEntry);
            root.close();
            return "pasted";
        }
        function deleteSelected(): string {
            const before = root.selectedEntry;
            root.deleteSelected();
            return before === null ? "nothing selected" : "deleted";
        }
        function pinSelected(): string {
            const before = root.selectedEntry;
            root.togglePinSelected();
            return before === null ? "nothing selected" : "toggled pin";
        }
        // Diagnostic / test hook: pick a kind without owning the pointer, and
        // report the counts that follow. Same path the chips and Ctrl+1..6 use.
        function filter(key: string): string {
            const wanted = String(key ?? "all");
            if (!root.filterDefs.some(def => def.key === wanted))
                return "unknown kind " + wanted;
            root.setFilter(wanted);
            const counts = root.filterDefs.map(def => def.key + "=" + root.filterCount(def.key)).join(" ");
            return `filter=${root.filter} listed=${root.listedCount} rows=${root.listRows.length} ${counts}`;
        }
        // Diagnostic: open the row whose entry contains `query` -- the state a
        // CLICK produces -- without owning the pointer. Moving the pointer
        // from a script never generates real motion here, so the hover/click
        // routes cannot be exercised from outside; this is the readable half
        // of that. An empty query collapses whatever is open.
        function expandEntry(query: string): string {
            const q = String(query ?? "");
            if (q.length === 0) {
                root.expandedEntry = "";
                return "collapsed";
            }
            for (const row of root.listRows) {
                if (row && row.entry && String(row.entry).indexOf(q) !== -1) {
                    root.expandedEntry = row.entry;
                    return "expanded";
                }
            }
            return "no match";
        }
    }

    // ── One entry row ──────────────────────────────────────────────────────
    // Option B's row: a thumbnail, the text, a hint line under it, and pin and
    // delete on the right. The SELECTED row is the tall one -- it shows the
    // entry in full and reveals its hint line -- so the selection is not just a
    // highlight you have to read carefully.
    component ClipboardEntryItem: Item {
        id: entryRoot
        required property string entry
        required property bool selected
        // The row's position in `listRows`, handed in by the delegate. A
        // Loader delegate has `index`, but the item it LOADS does not -- the
        // property has to be passed in explicitly, and `root.entryRowIndices`
        // is what turns it back into a cursor position.
        required property int rowIndex

        // Open only because the user CLICKED this row (see root.expandedEntry).
        // The keyboard cursor does not expand anything: moving through the
        // list used to reshape it under the pointer.
        readonly property bool expanded: entryRoot.entry === root.expandedEntry

        Component.onCompleted: root.rowRefs = root.rowRefs.concat([entryRoot])
        Component.onDestruction: root.rowRefs = root.rowRefs.filter(r => r !== entryRoot)

        readonly property bool pinned: Cliphist.isPinned(entry)
        readonly property bool isImage: Cliphist.entryIsImage(entry)
        readonly property string kind: root.entryKind(entry)
        readonly property string hint: root.hintFor(entry)

        // One clean line: real newlines and runs of spaces flattened so a
        // multi-line copy reads as a single row.
        // For an IMAGE the row says what the picture IS -- its pixel size and
        // its weight -- because the snapshot beside it is what identifies it
        // now. The word "(image)" was the best a row could do before the
        // previews were decoded reliably.
        readonly property string flatText: {
            if (isImage) {
                const meta = root.imageMeta(entry);
                const bits = [];
                if (meta.dims) bits.push(meta.dims);
                if (meta.size) bits.push(meta.size);
                return bits.join(" · ");
            }
            // A file copy is a list of URIs: show the NAME. A row that read
            // "file:///home/matrix/.cache/illogical-Impulse/rec…" said nothing
            // a person needed and elided away the only part that did.
            if (kind === "file") {
                const uris = root.fileUrisOf(entry);
                if (uris.length === 0)
                    return root.entryBody(entry).replace(/\s+/g, " ").trim();
                const name = root.fileNameOf(uris[0]);
                return uris.length > 1 ? name + "  +" + (uris.length - 1) : name;
            }
            return root.entryBody(entry).replace(/\s+/g, " ").trim();
        }

        // The glyph for this kind of entry. Images get a real thumbnail
        // instead (see the IconImage below) -- nothing is tinted, for the
        // reason in the header comment.
        readonly property string glyph: {
            if (kind === "link") return "link";
            if (kind === "command") return "chevron_right";
            if (kind === "image") return "image";
            if (kind === "file") {
                const uris = root.fileUrisOf(entry);
                const sub = uris.length > 0 ? root.fileSubKindOf(uris[0]) : "file";
                if (sub === "video") return "movie";
                if (sub === "audio") return "music_note";
                if (sub === "pdf") return "picture_as_pdf";
                if (sub === "archive") return "folder_zip";
                if (sub === "image") return "image";
                return "draft";
            }
            return "text_snippet";
        }

        // Room for the pin/delete buttons on the right (two 26px buttons with
        // 2px between them, 6px from the edge) so text can never be drawn
        // underneath them.
        readonly property real actionsWidth: 64
        readonly property real rowPadX: 11

        // The selected row grows; everything else stays one compact line. The
        // hint line only exists on the selected row, which is what makes the
        // expansion read as "this one is open" rather than just highlighted.
        // The CLICKED row is the tall one. 50 compact (was 46): that makes
        // the content box inside a compact row exactly the thumbnail's 38px,
        // so the snapshot, the glyph, the text and the pin/delete buttons all
        // centre on ONE line -- with 38px in a 32px box the thumbnail was
        // pinned to the top and hung 3px below the text's centre, which is
        // the misalignment it looked like.
        implicitHeight: expanded ? contentColumn.implicitHeight + 12 : 50
        width: listView.width

        Rectangle {
            anchors.fill: parent
            radius: Appearance.rounding.small
            color: entryRoot.selected
                ? root.cardSelection
                : (rowMouse.containsMouse ? root.cardSelectionHover : "transparent")
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }

            // The accent bar that marks the keyboard selection. Only drawn for
            // the selected row, so it reads as "the cursor is here" rather than
            // as decoration.
            Rectangle {
                visible: entryRoot.selected
                width: 2.5
                height: parent.height - 14
                anchors.left: parent.left
                anchors.leftMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                radius: 2
                color: Appearance.colors.colPrimary
            }
        }

        // Declared before the row content on purpose: later siblings sit on top
        // and take input first, so this has to be *behind* the action buttons
        // for them to stay clickable.
        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onClicked: {
                // First click OPENS the row; a click on the already-open row
                // pastes it. Expansion used to follow selection, which made
                // the list jump while just looking through it.
                const idx = root.entryRowIndices.indexOf(entryRoot.rowIndex);
                if (idx !== -1)
                    root.cursor = idx;
                if (root.expandedEntry !== entryRoot.entry) {
                    root.expandedEntry = entryRoot.entry;
                    return;
                }
                Cliphist.paste(entryRoot.entry);
                root.close();
            }
        }

        // Latched hover: the action buttons reveal on hover and STAY revealed
        // for a beat after the pointer leaves, so moving the mouse onto the
        // buttons themselves cannot flicker them away mid-move. (The buttons sit
        // on top of the row's MouseArea, so containsMouse alone drops to false
        // the instant the pointer crosses onto a button.)
        property bool hoverLatch: false
        Timer {
            id: hoverReleaseTimer
            interval: 400
            repeat: false
            onTriggered: entryRoot.hoverLatch = false
        }
        Connections {
            target: rowMouse
            function onContainsMouseChanged() {
                if (rowMouse.containsMouse) {
                    hoverReleaseTimer.stop();
                    entryRoot.hoverLatch = true;
                } else {
                    hoverReleaseTimer.restart();
                }
            }
        }

        ColumnLayout {
            id: contentColumn
            anchors.fill: parent
            anchors.leftMargin: entryRoot.rowPadX + 4
            anchors.rightMargin: entryRoot.rowPadX + entryRoot.actionsWidth
            anchors.topMargin: 6
            anchors.bottomMargin: 6
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                // Thumbnail / glyph slot. A fixed square either way, so the
                // text column starts at the same x on every row.
                Item {
                    // A 38px snapshot in a compact row, 96px once the row is
                    // clicked open: big enough to tell two screenshots apart,
                    // which is the whole point of the thumbnail.
                    Layout.preferredWidth: entryRoot.isImage && entryRoot.expanded ? 96 : 38
                    Layout.preferredHeight: entryRoot.isImage && entryRoot.expanded ? 96 : 38
                    // VCentre and not Top: in a compact row the thumbnail and
                    // the text now share the same centre line, and the text
                    // column's own AlignVCenter then agrees with it instead of
                    // centring against a box that starts higher.
                    Layout.alignment: Qt.AlignVCenter

                    Rectangle {
                        anchors.fill: parent
                        radius: Appearance.rounding.small
                        color: entryRoot.isImage
                            ? "transparent"
                            : ColorUtils.transparentize(Appearance.colors.colLayer2, 0.35)
                        visible: !entryRoot.isImage
                    }

                    // The snapshot: the decoded PNG, reloaded when the decode
                    // batch lands. `imageDecodeGeneration` is part of the
                    // source, so the binding re-runs on arrival and no image
                    // cache can hold the pre-decode miss -- the failure mode
                    // the old `imagePreviewPath` call had (it started a decode
                    // from inside a binding and handed back a path before the
                    // file existed).
                    Rectangle {
                        anchors.fill: parent
                        visible: entryRoot.isImage
                        radius: Appearance.rounding.small
                        color: ColorUtils.transparentize(Appearance.colors.colLayer2, 0.45)
                        clip: true

                        // Behind the snapshot, so a decode that failed (an
                        // unsupported format) still reads as "an image" rather
                        // than as an empty square.
                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: previewImage.status !== Image.Ready
                            text: "image"
                            iconSize: entryRoot.expanded ? 28 : 17
                            color: Appearance.colors.colSubtext
                        }

                        StyledImage {
                            id: previewImage
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectCrop
                            cache: false
                            source: entryRoot.isImage ? Cliphist.imagePreviewFile(entryRoot.entry) : ""
                        }
                        // Reload when the decode batch lands. NOT with a
                        // `?v=` cache-buster on the source: Qt treats the query
                        // as part of a local file path and answers "Cannot
                        // open: .../2422.png?v=1" (measured). Clearing the
                        // source first is what makes the assignment re-read the
                        // file instead of keeping the earlier miss.
                        Connections {
                            target: Cliphist
                            function onImageDecodeGenerationChanged() {
                                if (!entryRoot.isImage) return;
                                const file = Cliphist.imagePreviewFile(entryRoot.entry);
                                previewImage.source = "";
                                previewImage.source = file;
                            }
                        }
                    }

                MaterialSymbol {
                    anchors.centerIn: parent
                    visible: !entryRoot.isImage
                    text: entryRoot.glyph
                    iconSize: 15
                    color: entryRoot.selected
                        ? Appearance.colors.colOnLayer1
                        : Appearance.colors.colSubtext
                }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2

                    StyledText {
                        id: entryText
                        Layout.fillWidth: true
                        // The expansion: the selected row wraps (up to four
                        // lines, so one enormous paste cannot push the rest of
                        // the list off the card), every other row is a single
                        // elided line.
                        text: entryRoot.flatText
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: entryRoot.selected
                            ? Appearance.colors.colOnLayer1
                            : ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.18)
                        wrapMode: entryRoot.expanded ? Text.Wrap : Text.NoWrap
                        elide: entryRoot.expanded ? Text.ElideNone : Text.ElideRight
                        maximumLineCount: entryRoot.expanded ? 4 : 1
                        linkColor: Appearance.colors.colPrimary

                        // The full content as a tooltip -- but only once the
                        // row is CLICKED open. On hover it used to pop the
                        // whole paste up over the list while the pointer was
                        // merely crossing it, which was noise; now the full
                        // value appears exactly when you ask for the row.
                        // (The expanded row itself shows at most four wrapped
                        // lines, so this is still what reveals the rest.)
                        // `alternativeVisibleCondition` is the documented way
                        // to drive a StyledToolTip from a parent that has no
                        // `hovered` property -- relying on the internal
                        // condition silently renders nothing.
                        StyledToolTip {
                            alternativeVisibleCondition: entryRoot.expanded
                                && entryRoot.flatText.length > 0
                            // Wider than the card: clipboard entries are
                            // arbitrary pasted text, and this is the one place
                            // that shows one in full. It WRAPS at this width
                            // rather than running off the screen.
                            //
                            // entryRoot.width, not the card's width property:
                            // this is an inline `component`, which is its own
                            // scope -- `clipboardWindow` is not visible in here
                            // and naming it is a ReferenceError. The row is
                            // exactly as wide as the card's list, so this is
                            // the same number by a shorter path.
                            maximumTextWidth: entryRoot.width + 120
                            text: Cliphist.entryContent(entryRoot.entry)
                        }
                    }

                    // The hint line -- type of entry, or the host of a link.
                    // Selected rows only; this is the second half of what makes
                    // the selection an expansion rather than a highlight.
                    StyledText {
                        Layout.fillWidth: true
                        visible: entryRoot.expanded && entryRoot.hint !== ""
                        text: entryRoot.hint
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // The "pinned" marker, always visible for a pinned row (it is a state,
        // not an action), on the left of the action buttons.
        MaterialSymbol {
            visible: entryRoot.pinned
            anchors.right: actionRow.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: "push_pin"
            iconSize: 13
            color: Appearance.colors.colPrimary
        }

        // Row actions: pin and delete. Revealed on hover (latched -- see
        // above), and ALWAYS visible on the selected row, so the keyboard user
        // can see what the buttons are. The space for them is reserved either
        // way (see actionsWidth), so nothing shifts when they appear.
        RowLayout {
            id: actionRow
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            opacity: (entryRoot.hoverLatch || entryRoot.selected) ? 1 : 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            RippleButton {
                implicitWidth: 26
                implicitHeight: 26
                buttonRadius: Appearance.rounding.full
                onClicked: Cliphist.togglePin(entryRoot.entry)
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: entryRoot.pinned ? "keep_off" : "push_pin"
                    iconSize: 15
                    color: Appearance.colors.colOnLayer1
                }
                StyledToolTip {
                    text: entryRoot.pinned ? Translation.tr("Unpin") : Translation.tr("Pin")
                }
            }

            RippleButton {
                implicitWidth: 26
                implicitHeight: 26
                buttonRadius: Appearance.rounding.full
                onClicked: Cliphist.deleteEntry(entryRoot.entry)
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "delete"
                    iconSize: 15
                    color: Appearance.colors.colError
                }
                StyledToolTip {
                    text: Translation.tr("Delete")
                }
            }
        }
    }
}




















