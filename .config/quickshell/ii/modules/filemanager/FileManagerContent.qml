// Files -- the file manager, shaped like Windows Explorer.
//
// ── Why this file reads the way it does ────────────────────────────────
//
// The layout is Explorer's, top to bottom, because that is the muscle memory
// the user asked for:
//
//   [ command bar ]   New · Cut · Copy · Paste · Rename · Delete · Refresh · Sort · View
//   [ address bar ]   ← → ↑ ⟳ |  This PC › home › matrix › Downloads        [search]
//   [ nav pane ]      Quick access (Home, Desktop, Documents, ...)
//                     This PC      (every volume, capacity bar, mount control)
//   [ file pane ]     Name | Date modified | Type | Size      (details)
//   [ status bar ]    12 items · 1 selected · 402 GB free of 949 GB
//
// Colours, radii and fonts are the shell's own tokens (Appearance.*) -- the
// theme is untouched; only the arrangement is Explorer's.
//
// ── Two personalities, one component ───────────────────────────────────
//
//   window mode  the Files app. Double-click opens: a folder is entered, a
//                file goes to its default app through `gio open`.
//   picker mode  the portal's FileChooser dialog. Double-click does NOTHING
//                but select -- a file dialog's contract is that folders are
//                opened by walking into them and the answer is given with the
//                Open/Save button. A double-click that navigated (or that
//                confirmed a choice) is exactly what the user does not want
//                here, and it is the one place this file deliberately does not
//                behave like the window.
//
// ── Volumes are the real work ──────────────────────────────────────────
//
// `lsblk -J` is the source of truth for what is plugged in (on this machine
// the Windows SSD, an exFAT USB stick and an SD card -- all three visible
// here). This desktop has no udisks2, so mounting goes through pkexec, which
// is what its own polkit agent is for: the shell shows the prompt, and the
// mount happens only if the user approves it. A volume that is not mounted is
// mounted under /run/media/$USER/<label>; a mounted one is opened where it
// is. Read-only filesystems (squashfs/erofs images on the SD card) get `ro`,
// vfat/exFAT/NTFS get the uid/gid options that make them writable by the
// person who plugged them in, and nothing here ever writes to a volume:
// mount, unmount, browse, read -- and the only destructive action is Delete,
// which goes to the Trash.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import Qt.labs.folderlistmodel

Item {
    id: root

    // ── The scroll bar the three content views wear ─────────────────────
    //
    // A 2px hairline on the LEFT edge of the pane, on screen whenever there is
    // anything below the fold, and gone when the folder fits -- see
    // StyledScrollBar's `onLeft` and `showWhenScrollable` for why those two are
    // properties of the bar rather than of each list.
    //
    // LEFT because the pane's left edge is already the start of the list and the
    // right edge is where the numbers are: the Size column is right-aligned
    // against it, so a bar there sits in the same 10px the dates and sizes end
    // in. (The file manager was the reason `onLeft` exists at all.)
    //
    // ONE component for all three views (This PC's tiles, the details list, the
    // big tiles) because they are the same surface to the person using it --
    // exactly one is visible at a time -- and three copies is how they drift.
    //
    // 8px of LANE is enough to grab; 2px of ink is what reads as a hairline
    // rather than a second column. The two are separate numbers for that reason
    // -- and `handleWidth` is where the second one goes, not the handle's own
    // width (Qt writes that; see StyledScrollBar).
    component FilesScrollBar: StyledScrollBar {
        policy: ScrollBar.AsNeeded
        implicitWidth: 8
        handleWidth: 2
        onLeft: true
        showWhenScrollable: true
    }

    // ── Picker mode (portal FileChooser dialogs) ────────────────────────
    property bool pickerMode: false
    property string pickerOp: "open"      // "open" | "save"
    property string pickerName: ""        // pre-filled filename for save
    property bool pickerDirectory: false  // choosing a folder, not a file
    signal quitRequested()
    signal pickerAccepted(var uris)
    signal pickerCancelled()

    // ── Identity ────────────────────────────────────────────────────────
    readonly property string homeDir: Quickshell.env("HOME") ?? "/"
    readonly property string userName: Quickshell.env("USER") ?? "user"
    readonly property int userUid: 1000

    // ── View state ──────────────────────────────────────────────────────
    property bool showHidden: false
    property string filter: ""
    // Explorer's two shapes: the details list (default) and tiles.
    //
    // Per FOLDER, not global. The mode you choose while looking at a folder
    // belongs to that folder (Persistent.states.fileManagerFolderViews), and
    // every other folder -- including the subfolder you walk into next -- opens
    // in the default, details. `viewMode` is still the single live property all
    // three views bind to; savedViewFor/setViewMode are the only places that
    // move a folder's stored choice into it and back out again.
    property string viewMode: "details"   // "details" | "tiles"
    function savedViewFor(p) {
        const key = String(p ?? "");
        if (key.length === 0) return "details";
        const list = Persistent.states.fileManagerFolderViews ?? [];
        for (let i = list.length - 1; i >= 0; i--) {
            const e = list[i];
            if (e && e.path === key)
                return e.view === "tiles" ? "tiles" : "details";
        }
        return "details";
    }
    function setViewMode(mode) {
        const want = (mode === "tiles") ? "tiles" : "details";
        root.viewMode = want;
        // "This PC" is not a folder on disk, so there is nothing to remember.
        if (root.atThisPc) return;
        const key = String(root.path ?? "");
        if (key.length === 0) return;
        // Touching a folder again moves it to the end of the list, which is
        // what makes the cap below drop the folders you never revisit.
        const list = (Persistent.states.fileManagerFolderViews ?? [])
            .filter(e => e && e.path !== key);
        list.push({ path: key, view: want });
        Persistent.states.fileManagerFolderViews = list.slice(-256);
    }
    // ── How big a tile is ───────────────────────────────────────────────
    //
    // REQUESTED (2026-10-24): "in the file open screen of the file manager i
    // want a view change added so i can select to see invisible files or change
    // the size of the files to see them bigger or listed". That is three
    // wishes about one thing -- how much of the folder you can see at once --
    // and the first two already exist in the app: the tiles/details toggle and
    // the hidden-files eye. What was missing is the middle one: in the tiles
    // view the cell was chosen for you (a 260 px cap), so "bigger" was not a
    // thing you could ask for.
    //
    // A STEP, not a size in pixels. The grid shares the pane's leftover width
    // between its columns (see tilesView), so a chosen "137 px tile" is not
    // something the layout can promise -- it rounds the columns up and hands
    // the remainder back. A cap per step is the number that actually decides
    // the column count, so the three steps are three caps and the tiles land as
    // big as those allow.
    property int tileSize: 1              // 0 small, 1 medium, 2 large
    readonly property var tileSizeCaps: [150, 240, 400]
    readonly property int tileCellCap: root.tileSizeCaps[Math.max(0, Math.min(root.tileSizeCaps.length - 1, root.tileSize))]
    function stepTileSize(delta) {
        root.tileSize = Math.max(0, Math.min(root.tileSizeCaps.length - 1, root.tileSize + delta));
    }
    property int sortField: 0             // 0 name, 1 time, 2 type, 3 size
    property bool sortReversed: false
    // Nowhere else does the manager hide a volume, so this is the only
    // preference with no Explorer equivalent: names are shown as they are on
    // disk and the Type column spells the extension out.
    property bool showExtensions: true

    // ── "This PC" is not a path ─────────────────────────────────────────
    // Nothing on disk is called this, and it must never reach FolderListModel
    // as a folder -- that is how a sentinel string ends up in a file dialog's
    // return value.
    readonly property string thisPc: "thispc:"
    property bool atThisPc: false

    // ── Path + history ──────────────────────────────────────────────────
    property string path: Quickshell.env("II_FILES_START") ?? root.homeDir
    property var history: []
    property int historyIndex: 0

    // ── Selection ───────────────────────────────────────────────────────
    // Paths, not indices: the model re-sorts under the selection and an index
    // would then point at a different file.
    property var selection: []
    property int selIndex: -1             // the keyboard cursor
    property int anchorIndex: -1          // shift-click anchor
    readonly property bool hasSelection: root.selection.length > 0

    // ── Volumes ─────────────────────────────────────────────────────────
    // Two sources, one list. `blockVolumes` is what lsblk reports (disks and
    // their partitions); `mtpVolumes` is what the USB bus reports (phones and
    // cameras, which have no /dev node and so can never be block volumes). A
    // phone shown in the drive list is the whole point of the second source,
    // and keeping them apart until they are merged is what lets each be
    // refreshed for its own reason -- a stick lands as a udev block event, a
    // phone lands as a udev USB event.
    property var blockVolumes: []
    property var mtpVolumes: []
    property var volumes: []
    property var volumeUsage: ({})
    property bool udisksAvailable: false
    // Which drive is being mounted right now, and the last failure worth
    // showing on a row. The ROW is where the click happened, so the row is
    // where the answer has to appear: the privileged command behind it can take
    // a second or more, and a click that changes nothing visible reads as a
    // button that does not work. The status bar note and the notification stay
    // as they were; this is the one that is where the eyes already are.
    property string mountingPath: ""
    property string mountFailurePath: ""
    property string mountFailure: ""
    property string statusNote: ""
    // The title row's HUD: how many of the listed rows are folders. Derived
    // from `rows` rather than counted while listing, so the number on screen
    // cannot disagree with the list under it.
    readonly property int folderCount: root.rows.filter(r => r.isDir).length

    // ── Tabs ────────────────────────────────────────────────────────────
    property var tabs: []
    property int activeTab: 0
    readonly property bool tabsAvailable: !root.pickerMode

    // ── The rows on screen ──────────────────────────────────────────────
    //
    // The list is FilteredListModel-free on purpose: Qt's FolderListModel
    // applies `nameFilters` to FILES ONLY, so a search box wired to it leaves
    // every folder on screen, and its sort cannot mix folders ahead of files
    // the way Explorer's does. So the folder's entries are read out once per
    // change, filtered and sorted here, and the views bind to the result.
    // That also means the row the keyboard walks and the row the eye sees are
    // the same list by construction.
    property var rows: []
    property int rawCount: 0
    function timeValue(v) {
        const d = (v instanceof Date) ? v : new Date(Number(v ?? 0));
        return (d && !isNaN(d.getTime())) ? d.getTime() : 0;
    }
    function rebuildRows() {
        const needle = root.filter.trim().toLowerCase();
        const out = [];
        const n = folderModel.count;
        for (let i = 0; i < n; i++) {
            const name = String(folderModel.get(i, "fileName"));
            if (needle.length > 0 && name.toLowerCase().indexOf(needle) === -1)
                continue;
            const isDir = folderModel.get(i, "fileIsDir") === true;
            out.push({
                name: name,
                path: String(folderModel.get(i, "filePath")),
                isDir: isDir,
                size: Number(folderModel.get(i, "fileSize") ?? 0),
                modified: folderModel.get(i, "fileModified"),
                kind: root.kindFor(name, isDir),
                icon: root.iconFor(name, isDir),
                // Is this a file whose CONTENT can be drawn? Images, and now
                // videos -- a video is shown as ONE FRAME pulled out of it a
                // second in, which is a preview of the thing itself rather than
                // a made-up picture. Everything else keeps its icon: a preview
                // of an archive is still a lie.
                preview: !isDir && (root.imageExts.indexOf(root.suffixOf(name)) !== -1
                    || root.videoExts.indexOf(root.suffixOf(name)) !== -1)
            });
        }
        const field = root.sortField;
        const dir = root.sortReversed ? -1 : 1;
        const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
        out.sort((a, b) => {
            // Folders ahead of files is Explorer's own order, and it holds for
            // every column rather than only for Name.
            if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
            let d = 0;
            if (field === 0) d = byName(a, b);
            else if (field === 1) d = root.timeValue(a.modified) - root.timeValue(b.modified) || byName(a, b);
            else if (field === 2) d = a.kind.localeCompare(b.kind) || byName(a, b);
            else d = (root.sizeFor(a) - root.sizeFor(b)) || byName(a, b);
            return d * dir;
        });
        root.rawCount = n;
        root.rows = out;
        // The listing was re-read, so the rows on screen may be looking at
        // folders that changed inside: see requestDirSize.
        root.listingGeneration++;
        // A selection of rows that are no longer listed is dropped; one of
        // them surviving under a new index is why the cursor is re-resolved by
        // path rather than by number.
        if (root.selection.length > 0) {
            const live = root.selection.filter(p => root.indexOfPath(p) !== -1);
            if (live.length !== root.selection.length)
                root.selection = live;
        }
        if (root.selIndex >= 0 && root.selIndex >= out.length)
            root.selIndex = out.length - 1;
    }
    Timer {
        // Debounced: FolderListModel fills a large folder in chunks and emits
        // count for each one, and rebuilding the whole list per chunk would
        // make opening a folder with thousands of files quadratic.
        id: rowsDebounce
        interval: 50
        onTriggered: root.rebuildRows()
    }
    // Folder sizes arrive one at a time, long after the rows were built, so a
    // column sorted BY size has to be re-sorted when they land -- otherwise the
    // order belongs to a list of zeros and the column lies. Debounced the same
    // way, and only while that column is the one being sorted: under Name, a
    // size arriving changes no order, so there is nothing to redo.
    Timer {
        id: sizeSortSettle
        interval: 250
        onTriggered: root.rebuildRows()
    }
    Connections {
        target: FolderSizes
        function onRevisionChanged() {
            if (root.sortField === 3)
                sizeSortSettle.restart();
        }
    }
    onFilterChanged: rowsDebounce.restart()
    onSortFieldChanged: rowsDebounce.restart()
    onSortReversedChanged: rowsDebounce.restart()

    function entry(i) {
        return (i >= 0 && i < root.rows.length) ? root.rows[i] : null;
    }
    function indexOfPath(p) {
        for (let i = 0; i < root.rows.length; i++)
            if (root.rows[i].path === String(p))
                return i;
        return -1;
    }
    function pathAt(i) {
        return (i >= 0 && i < root.rows.length) ? root.rows[i].path : "";
    }
    function nameAt(i) {
        return (i >= 0 && i < root.rows.length) ? root.rows[i].name : "";
    }
    function isDirAt(i) {
        return i >= 0 && i < root.rows.length && root.rows[i].isDir;
    }
    function isDirPath(p) {
        return root.isDirAt(root.indexOfPath(p));
    }

    // ── Naming / formatting ─────────────────────────────────────────────
    readonly property var imageExts: ["png", "jpg", "jpeg", "webp", "gif", "bmp", "avif", "svg", "tif", "tiff", "heic"]
    readonly property var videoExts: ["mp4", "mkv", "webm", "mov", "avi", "m4v"]
    readonly property var audioExts: ["mp3", "flac", "wav", "ogg", "opus", "m4a"]
    readonly property var archiveExts: ["zip", "tar", "gz", "xz", "zst", "7z", "rar", "bz2"]
    readonly property var codeExts: ["sh", "py", "js", "qml", "lua", "c", "cpp", "h", "rs", "go", "ts", "json", "yml", "yaml", "toml"]
    readonly property var docExts: ["pdf", "txt", "md", "doc", "docx", "odt", "rtf", "xls", "xlsx", "ods", "ppt", "pptx", "epub"]
    // Text this app can SHOW, as opposed to merely name: the preview pane prints
    // these with `head`, so the list is deliberately the formats where that is
    // readable. A .docx is text to `kindFor` and binary to `head`, and pretending
    // otherwise is how a preview turns into a wall of replacement characters.
    readonly property var textExts: ["txt", "md", "log", "ini", "conf", "cfg", "desktop", "service", "timer", "socket", "mount", "env", "yml", "yaml", "toml", "xml", "rss", "atom", "plist", "css", "less", "scss", "sass", "sql", "diff", "patch", "srt", "vtt", "ass", "ssa", "sub", "nfo", "asc", "pem", "crt", "key", "nix", "lua", "qml", "js", "mjs", "cjs", "ts", "py", "sh", "bash", "zsh", "fish", "c", "h", "hpp", "cc", "rs", "go", "java", "kt", "kts", "php", "rb", "pl", "swift", "dart", "scala", "clj", "ex", "exs", "hs", "ml", "zig", "v", "tex", "bib", "rst", "adoc", "org", "gradle", "cmake", "properties", "ps1", "bat", "cmd", "vue", "svelte", "astro", "lock", "map", "gitignore", "gitconfig", "editorconfig", "dockerignore", "npmignore", "make", "mk"]
    readonly property var appExts: ["desktop", "appimage", "exe", "msi"]
    // ── What the pane can READ, as opposed to merely name ───────────────
    //
    // These lists exist so the pane can ask the right question of the right
    // format. The reading itself is one helper (scripts/system/file-preview.py)
    // because every one of these answers the same thing -- some text, a grid of
    // cells, or a list of names -- and the pane only needs to know which of its
    // three views to show.
    readonly property var tableExts: ["csv", "tsv", "tab"]
    readonly property var jsonExts: ["json", "jsonl", "ndjson", "geojson", "webmanifest", "ipynb"]
    readonly property var markupExts: ["html", "htm", "xhtml"]
    readonly property var markdownExts: ["md", "markdown", "mdown"]
    // Office formats are zips or RTF, which python's stdlib opens without any
    // external converter. The 1990s binaries (.doc/.xls/.ppt) are here too so
    // they are told apart from an unknown file: what the pane can honestly say
    // about them is that no reader is installed.
    readonly property var officeExts: ["docx", "docm", "odt", "ott", "rtf", "pptx", "odp", "epub", "xlsx", "xlsm", "ods", "ots", "doc", "xls", "ppt"]
    readonly property var spreadsheetExts: ["csv", "tsv", "tab", "xlsx", "xlsm", "xls", "ods", "ots"]

    function suffixOf(name) {
        const n = String(name ?? "");
        const i = n.lastIndexOf(".");
        return i > 0 ? n.substring(i + 1).toLowerCase() : "";
    }
    function stemOf(name) {
        const n = String(name ?? "");
        const i = n.lastIndexOf(".");
        return i > 0 ? n.substring(0, i) : n;
    }
    function hasExt(name, list) {
        return list.indexOf(root.suffixOf(name)) !== -1;
    }
    function displayName(name, isDir) {
        if (root.showExtensions || isDir)
            return String(name ?? "");
        return root.stemOf(name);
    }
    function kindFor(name, isDir) {
        if (isDir) return Translation.tr("File folder");
        const s = root.suffixOf(name);
        if (root.hasExt(name, root.imageExts)) return Translation.tr("Image");
        if (root.hasExt(name, root.videoExts)) return Translation.tr("Video");
        if (root.hasExt(name, root.audioExts)) return Translation.tr("Audio");
        if (root.hasExt(name, root.archiveExts)) return Translation.tr("Archive");
        // A spreadsheet is not a "Document" in the Type column: it is the one
        // kind of office file whose PREVIEW is a grid, and saying so is the
        // difference between a user expecting pages and getting cells.
        if (root.hasExt(name, root.spreadsheetExts)) return Translation.tr("Spreadsheet");
        if (root.hasExt(name, root.codeExts) || root.hasExt(name, root.jsonExts)) return Translation.tr("Code");
        if (root.hasExt(name, root.markupExts)) return Translation.tr("Web page");
        if (root.hasExt(name, root.docExts)) return Translation.tr("Document");
        if (root.hasExt(name, root.appExts)) return Translation.tr("Application");
        if (s.length === 0) return Translation.tr("File");
        return s.toUpperCase() + " " + Translation.tr("file");
    }
    function iconFor(name, isDir) {
        if (isDir) return "folder";
        const s = root.suffixOf(name);
        if (root.imageExts.indexOf(s) !== -1) return "image";
        if (root.videoExts.indexOf(s) !== -1) return "movie";
        if (root.audioExts.indexOf(s) !== -1) return "music_note";
        if (root.archiveExts.indexOf(s) !== -1) return "folder_zip";
        if (root.spreadsheetExts.indexOf(s) !== -1) return "table_chart";
        if (root.codeExts.indexOf(s) !== -1 || root.jsonExts.indexOf(s) !== -1) return "code";
        if (root.markupExts.indexOf(s) !== -1) return "language";
        if (root.appExts.indexOf(s) !== -1) return "apps";
        if (s === "pdf") return "picture_as_pdf";
        if (root.docExts.indexOf(s) !== -1) return "description";
        if (s === "iso" || s === "img") return "album";
        return "draft";
    }
    function fmtSize(bytes, isDir) {
        if (isDir) return "";
        const b = Number(bytes ?? 0);
        if (!isFinite(b) || b <= 0) return "";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let i = 0, v = b;
        while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
        return (v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)) + " " + units[i];
    }
    // `fileModified` arrives as a Date when the model hands over a QDateTime
    // and as millis when it hands over a number; both shapes are accepted here
    // so the column cannot go blank because of which one it was.
    function fmtTime(value) {
        let d = null;
        if (value instanceof Date) d = value;
        else d = new Date(Number(value ?? 0));
        if (!d || isNaN(d.getTime()) || d.getTime() <= 0) return "";
        const p = n => (n < 10 ? "0" : "") + n;
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
    }
    function fmtCapacity(bytes) {
        return root.fmtSize(bytes, false);
    }

    // ── A folder's size ─────────────────────────────────────────────────
    //
    // The Size column used to be empty for every folder, because a folder's
    // size is a TREE WALK (`du`) and there is no cheap way to have it at paint
    // time -- FolderListModel reports a directory's own inode, which is what
    // made "folders have no size" true rather than lazy. FolderSizes walks the
    // tree off the paint path, one folder at a time, and caches it.
    //
    // `revision` is threaded through as an ARGUMENT on purpose: a function call
    // on a singleton creates no QML dependency, so a binding written as
    // `FolderSizes.bytes(p)` would be evaluated once and then never again when
    // the answer landed. Passing the counter in is what makes the cell fill in
    // on its own.
    function sizeTextFor(entry, revision) {
        if (!entry) return "";
        if (!entry.isDir) return root.fmtSize(entry.size, false);
        const bytes = FolderSizes.bytes(entry.path);
        if (bytes >= 0) return root.fmtSize(bytes, false);
        // Not known yet: say so, rather than showing an empty cell that looks
        // like an empty folder. Nothing at all once the walk has failed
        // (timeout, unreadable), because "measuring" would be a lie by then.
        return FolderSizes.pending(entry.path) ? "…" : "";
    }
    // What the Size column SORTS by, so the number under the cursor and the
    // order in the column are the same number. A folder that is not measured
    // yet sorts as 0 -- with the empty ones, where it will stay if the walk
    // fails -- rather than jumping to the top when the answer arrives.
    function sizeFor(entry) {
        if (!entry) return 0;
        if (!entry.isDir) return Number(entry.size ?? 0);
        const bytes = FolderSizes.bytes(entry.path);
        return bytes >= 0 ? bytes : 0;
    }
    // The row asks for its own folder, and it asks again when the LISTING is
    // re-read -- which is the half that is easy to get wrong. A delegate is not
    // rebuilt by a re-sort or a re-read (measured: a full rebuild with the same
    // rows asks nothing at all), so a number measured before something changed
    // inside a folder would stay wrong for the rest of the session. Every
    // rebuild bumps `listingGeneration`, the row asks again on that, and the
    // folder that changed hands in a new mtime and is walked once more while
    // everything else answers from the cache.
    //
    // A row only ever asks for ITS OWN folder, so the walking stays tied to
    // what the view actually drew: a folder nobody scrolled to is never
    // measured at all.
    property int listingGeneration: 0
    function requestDirSize(entry) {
        if (!entry || !entry.isDir) return;
        FolderSizes.request(entry.path, root.timeValue(entry.modified));
    }
    function firstLine(text) {
        const t = String(text ?? "").trim();
        const i = t.indexOf("\n");
        return i === -1 ? t : t.substring(0, i);
    }

    // ── Shell helpers (one place that quotes, one place that runs) ──────
    // Everything that touches the filesystem goes through gio, so nothing is
    // ever rm'd by accident and files open with the application the desktop
    // has registered for them.
    function shq(s) {
        return "'" + String(s ?? "").replace(/'/g, "'\\''") + "'";
    }
    Process {
        id: shellProc
        property string mode: ""
        property string payload: ""
        property string output: ""
        command: []
        stdout: StdioCollector {
            onStreamFinished: shellProc.output = String(this.text ?? "")
        }
        onExited: (code, status) => root.handleShellDone(shellProc.mode, shellProc.payload, code)
    }
    // ── The launch feedback this window raises (and must end) ─────────────
    //
    // Double-clicking a file hands it to another app, and that was invisible
    // from here: no island row, no line under the bar -- the Super menu shows
    // "Opening ⟨app⟩" for the SAME kind of launch and Files showed nothing.
    // The bar, the island row and the card live in the MAIN shell (a
    // different qs process than this window), so the announce goes over IPC
    // through the same two functions every shell-side script uses.
    //
    // `display` is the right primitive, deliberately not `arm`: a caller
    // that owns the wait zeroes the failsafe, and nothing here could renew
    // it -- `gio open` exits in milliseconds whatever it managed to start.
    // The consequence is that only WE can end this wait when no new window
    // arrives to end it, which is what openDismissTimer below is for.
    //
    // The announced name is the FILE's, matching how the island pairs the
    // row: label "Opening" + this value as the bare name, never a sentence.
    property string openAnnounced: ""
    // Inside ONE shell line with the launch itself (see openEntry): the IPC
    // must land BEFORE the program runs, or a window that beats the announce
    // sets the shell's baseline after it exists and is never seen as new.
    function announcePrefix(name) {
        return "qs -c ii ipc call loading display " + root.shq(name) + " >/dev/null 2>&1; ";
    }
    function ipcLoading(fn, arg) {
        const argv = ["qs", "-c", "ii", "ipc", "call", "loading", fn];
        if (arg !== undefined && arg !== null && String(arg) !== "")
            argv.push(String(arg));
        Quickshell.execDetached(argv);
    }
    // The success ending: late on purpose (the shell's own window watcher
    // beats us whenever the app maps a NEW window), and guarded (the shell
    // retires the wait only while it still carries OUR name, so a launch
    // started in the meantime is never dismissed by us).
    //
    // The guard used to live here, as a regex over `loading state` collected
    // from a second qs process. That read is the one step with no answer when
    // it fails -- a name containing a quote truncated the match, a spawn that
    // did not answer matched nothing -- and the result was the reported
    // "permanent bar": a file opened from Files announced "Opening <name>"
    // and the wait was never ended by anyone (display arms no failsafe), so
    // the row and the full-width line stayed for the rest of the session.
    // Comparing the name in the shell removes the parse entirely; the 30 s
    // ceiling in GlobalStates remains the backstop if this IPC never lands.
    Timer {
        id: openDismissTimer
        interval: 3500
        repeat: false
        onTriggered: root.ipcLoading("dismissIf", root.openAnnounced)
    }
    function sh(cmd, mode, payload) {
        shellProc.mode = mode ?? "";
        shellProc.payload = payload ?? "";
        shellProc.output = "";
        shellProc.command = ["bash", "-c", cmd];
        shellProc.running = false;
        shellProc.running = true;
    }
    function notify(title, body, critical) {
        root.sh("notify-send -a 'Files' -u " + (critical ? "critical" : "normal")
            + " " + root.shq(title) + " " + root.shq(body));
    }
    // One handler for every helper call. The alternative -- reassigning a
    // callback property per operation -- is where a stale closure silently
    // answers for the wrong file.
    function handleShellDone(mode, payload, code) {
        if (mode === "info") {
            root.parseInfo(shellProc.output);
            return;
        }
        if (mode === "drive-info") {
            root.parseDriveInfo(shellProc.output);
            return;
        }
        if (mode === "mount-names") {
            root.parseMountNames(shellProc.output);
            return;
        }
        // The save prompt's "does this name exist" check. `exists` opens the
        // replace prompt; `free` answers the dialog the way it always did.
        if (mode === "save-check") {
            if (String(shellProc.output ?? "").trim() === "exists") {
                root.confirmingSavePath = String(payload ?? "");
                root.confirmingSaveName = root.baseName(String(payload ?? ""));
                root.confirmingSave = true;
            } else {
                root.answerSave(String(payload ?? ""));
            }
            return;
        }
        if (mode === "column-widths") {
            // A broken preference is not an error: the defaults are right there.
            try {
                const parsed = JSON.parse(String(shellProc.output ?? "").trim() || "{}");
                if (parsed && typeof parsed === "object") {
                    root.columnWidths = parsed;
                    // A size saved in a WIDER window is simply out of range here;
                    // the floor is applied now and the ceiling on the next drag,
                    // because the grid this ceiling is read off does not have a
                    // size yet this early in startup.
                    if (Number.isFinite(Number(parsed.preview)))
                        root.previewPaneWidth = Math.max(root.previewPaneMinWidth, Math.round(Number(parsed.preview)));
                    if (Number.isFinite(Number(parsed.previewHeight)))
                        root.previewStackHeight = Math.max(root.previewMinHeight, Math.round(Number(parsed.previewHeight)));
                }
            } catch (e) {
                root.columnWidths = ({});
            }
            return;
        }
        // ── Previews ──────────────────────────────────────────────────────
        // Every one of these answers the SAME question -- what is in this file
        // -- in whichever way that file allows. `payload` is the path the answer
        // is for, so a result that arrives after the selection moved on is
        // dropped instead of being shown against the wrong file.
        if (mode === "preview-text") {
            if (payload !== root.previewEntryPath) return;
            const body = String(shellProc.output ?? "");
            root.previewText = body;
            const e = root.previewEntry;
            if (e && e.size > 4000)
                root.previewNote = Translation.tr("first 4 KB of") + " " + root.fmtSize(e.size, false);
            return;
        }
        if (mode === "preview-file") {
            if (payload !== root.previewEntryPath) return;
            let d = null;
            try {
                d = JSON.parse(String(shellProc.output ?? ""));
            } catch (error) {
                d = null;
            }
            if (!d || typeof d !== "object") {
                // The helper always answers JSON; no answer means it could not
                // run at all, which is worth saying rather than showing blank.
                root.previewView = "text";
                root.previewNote = Translation.tr("Could not read this file");
                return;
            }
            const view = String(d.view ?? "text");
            root.previewView = (view === "table" || view === "list") ? view : "text";
            root.previewText = String(d.text ?? "");
            root.previewNote = String(d.note ?? "");
            root.previewTable = (d.table && typeof d.table === "object")
                ? d.table : root.emptyPreviewTable();
            root.previewEntries = Array.isArray(d.entries) ? d.entries : [];
            return;
        }
        if (mode === "preview-page") {
            if (payload !== root.previewEntryPath) return;
            const first = root.firstLine(shellProc.output);
            if (first === "missing")
                root.previewNote = Translation.tr("Install poppler (pdftoppm) to preview PDFs");
            else if (first.length > 0)
                root.previewPage = root.fileUri(first);
            else
                root.previewNote = Translation.tr("Could not render this PDF");
            return;
        }
        if (mode === "preview-media") {
            if (payload !== root.previewEntryPath) return;
            const out = String(shellProc.output ?? "");
            if (out.indexOf("ffprobe missing") !== -1) {
                root.previewNote = Translation.tr("Install ffmpeg (ffprobe) for media details");
                return;
            }
            const facts = {};
            for (const line of out.split("\n")) {
                const i = line.indexOf("=");
                if (i > 0) facts[line.slice(0, i).trim()] = line.slice(i + 1).trim();
            }
            const bits = [];
            const secs = Number(facts.duration ?? 0);
            if (secs > 0) {
                const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60), s = Math.floor(secs % 60);
                bits.push((h > 0 ? h + ":" + String(m).padStart(2, "0") : String(m)) + ":" + String(s).padStart(2, "0"));
            }
            if (facts.width && facts.height) bits.push(facts.width + "×" + facts.height);
            if (facts.codec_name) bits.push(facts.codec_name);
            const br = Number(facts.bit_rate ?? 0);
            if (br > 0) bits.push(root.fmtSize(br / 8, false) + "/s");
            root.previewNote = bits.join(" · ");
            return;
        }
        if (mode === "preview-folder") {
            if (payload !== root.previewEntryPath) return;
            const facts = {};
            for (const line of String(shellProc.output ?? "").split("\n")) {
                const i = line.indexOf("|");
                if (i > 0) facts[line.slice(0, i).trim()] = line.slice(i + 1).trim();
            }
            const n = Number(facts.entries ?? 0), d = Number(facts.dirs ?? 0);
            const bits = [n + " " + (n === 1 ? Translation.tr("item") : Translation.tr("items"))];
            if (d > 0) bits.push(d + " " + Translation.tr("folder(s)"));
            if (facts.size) bits.push(facts.size);
            root.previewNote = bits.join(" · ");
            return;
        }
        // A drive action (label, format, check, TRIM, remount). These go
        // through polkit, so the exit code is the only thing to trust: "label"
        // on a filesystem whose tool is missing exits non-zero with a message,
        // and that message is what gets shown rather than a silent nothing.
        if (mode === "volume") {
            root.statusNote = "";
            if (code !== 0) {
                root.notify(root.volumeActionLabel(root.lastVolumeAction) + " " + Translation.tr("failed"),
                    root.firstLine(shellProc.output), true);
            } else {
                root.statusNote = root.volumeActionLabel(root.lastVolumeAction) + " "
                    + Translation.tr("done") + ": " + (root.firstLine(shellProc.output) || "ok");
            }
            root.refreshVolumes();
            return;
        }
        // ── Does the desktop have an application for this file? ──────────
        // `open-check` prints two lines: the content type it resolved, then the
        // desktop id the system would use for it (empty when nothing claims the
        // type). The empty id IS the no-handler case: the chooser opens on the
        // file that was double-clicked, instead of a `gio open` that would only
        // have written a complaint to stderr.
        //
        // The id is asked for with `xdg-mime query default` rather than parsed
        // out of gio's "No default applications for …" sentence, because that
        // sentence is TRANSLATED. It only matched on an English session; on any
        // other, every no-handler file fell through to `gio open` and failed
        // after the fact -- i.e. a double-click that did nothing.
        if (mode === "open-check") {
            const lines = String(shellProc.output ?? "").split("\n");
            const type = String(lines[0] ?? "").trim();
            const handler = String(lines[1] ?? "").trim();
            if (type.length === 0 || handler.length === 0) {
                // A TEXT FILE that nothing has claimed is not a mystery worth a
                // dialog: this desktop HAS a text editor, and "which
                // application?" asked about a .conf is a worse answer than just
                // opening it in that editor. The chooser is kept for the types
                // where the question is real (a binary blob, a format with
                // several plausible apps).
                if (root.isTextualMime(type)) {
                    root.openAnnounced = root.baseName(payload);
                    root.sh(root.announcePrefix(root.openAnnounced)
                        + "bash " + root.shq(Quickshell.shellPath("scripts/launch/texteditor.sh"))
                        + " " + root.shq(payload), "open", payload);
                    return;
                }
                root.askOpenWith(payload);
                return;
            }
            root.openAnnounced = root.baseName(payload);
            root.sh(root.announcePrefix(root.openAnnounced) + "gio open " + root.shq(payload), "open", payload);
            return;
        }
        if (mode === "open-with-list") {
            // A list for a file the user has already closed the chooser on is
            // dropped: `payload` is the path the answer is for.
            if (payload !== root.openWithPath) return;
            let data = null;
            try {
                data = JSON.parse(String(shellProc.output ?? "").trim() || "null");
            } catch (e) {
                data = null;
            }
            if (!data) {
                root.openWithNote = Translation.tr("Could not read the list of applications");
                return;
            }
            root.openWithMime = String(data.mime ?? "");
            root.openWithApps = data.apps ?? [];
            root.openWithNote = root.openWithApps.length === 0
                ? Translation.tr("No application on this system can open this file")
                : "";
            return;
        }
        if (mode === "open-with-run") {
            if (code !== 0) {
                openDismissTimer.stop();
                root.openAnnounced = "";
                root.notify(Translation.tr("Could not open"),
                    root.firstLine(shellProc.output) || root.baseName(payload), true);
                return;
            }
            openDismissTimer.restart();
            return;
        }
        // ── The launch feedback's two endings ─────────────────────────────
        // openEntry announced this attempt into the main shell (`loading
        // display`), so it has to be ended HERE on both outcomes: a failure
        // ends the wait with the reason (red faces on the line and island,
        // plus the whole-screen border flare), and a success starts the
        // guarded dismiss below.
        if (mode === "open" || mode === "appimage") {
            const launchName = root.baseName(payload);
            if (code !== 0) {
                openDismissTimer.stop();
                root.openAnnounced = "";
                root.ipcLoading("error", Translation.tr("Couldn't open") + " " + launchName);
            } else {
                // gio exits in milliseconds, so a wait with no new window is
                // common (file went to a window already on screen) and only
                // we can end it -- display armed no failsafe (see GlobalStates).
                openDismissTimer.restart();
            }
        }
        if (mode === "open" && code !== 0) {
            root.statusNote = "";
            root.notify(Translation.tr("Could not open"), root.firstLine(shellProc.output) || root.baseName(payload), true);
            return;
        }
        if (mode === "open" || mode === "appimage")
            return;
        if (mode === "mkdir" || mode === "touch") {
            // A create that failed has to SAY so. It used to be silent, and
            // that silence is the whole "New file does nothing" report: the
            // command behind it did not exist, exited 1, and nothing anywhere
            // looked at the exit code.
            if (code !== 0) {
                root.statusNote = "";
                root.notify(Translation.tr("Could not create it"),
                    root.firstLine(shellProc.output) || root.baseName(payload), true);
                return;
            }
            root.refresh();
            root.pendingSelectName = root.baseName(payload);
            pendingSelectTimer.attempts = 0;
            pendingSelectTimer.restart();
            return;
        }
        // A path handed over from outside: a folder is entered, a file is shown
        // in its folder with the row selected.
        if (mode === "open-path") {
            const target = String(payload ?? "");
            if (String(shellProc.output ?? "").trim() === "dir") {
                root.navigateTo(target);
                return;
            }
            root.navigateTo(root.dirName(target));
            root.pendingSelectName = root.baseName(target);
            pendingSelectTimer.attempts = 0;
            pendingSelectTimer.restart();
            return;
        }
        if (mode === "mount") {
            root.mountingPath = "";
            if (code !== 0) {
                root.statusNote = "";
                const why = root.firstLine(shellProc.output) || root.volumeLabelOf(payload);
                // Kept on the row as well as pushed as a notification: the
                // notification is a card that leaves, and the reason a drive did
                // not open is worth having next to the drive until it is tried
                // again -- which is exactly what the next mount click clears.
                root.mountFailurePath = String(payload ?? "");
                root.mountFailure = why;
                root.notify(Translation.tr("Mount failed"), why, true);
                return;
            }
            root.mountFailurePath = "";
            root.mountFailure = "";
            root.statusNote = "";
            root.mountOpenAfter = payload;
            root.refreshVolumes();
            return;
        }
        if (mode === "unmount") {
            root.statusNote = "";
            if (code !== 0) {
                root.notify(Translation.tr("Unmount failed"),
                    root.firstLine(shellProc.output) || Translation.tr("Something still has it open."), true);
                return;
            }
            root.refreshVolumes();
            return;
        }
        // ── Phones ─────────────────────────────────────────────────────────
        // Mounting a device is a FUSE mount: either it landed or it printed why
        // (something else already has the device, in MTP's single-session
        // protocol). And "landed" is not the end of it -- see mtp-contents.
        if (mode === "mtp-mount") {
            root.statusNote = "";
            if (code !== 0) {
                root.notify(Translation.tr("Could not open the device"),
                    root.firstLine(shellProc.output)
                        || Translation.tr("Something else may already be reading it."), true);
                root.scanMtpDevices();
                return;
            }
            root.scanMtpDevices();
            root.checkMtpContents(root.mtpDeviceByName(payload), true);
            return;
        }
        if (mode === "mtp-unmount") {
            root.statusNote = "";
            if (code !== 0)
                root.notify(Translation.tr("Could not eject the device"),
                    root.firstLine(shellProc.output)
                        || Translation.tr("Something is still reading it."), true);
            root.scanMtpDevices();
            return;
        }
        // A mount that produced nothing is the ONE state worth explaining, and
        // it is not an error: an MTP device that has not been unlocked, or
        // whose "allow access to phone data" prompt is still unanswered, hands
        // over no storages at all and the mount is a real, empty directory.
        // Walking into it would show "this folder is empty" about a phone that
        // is full, so it is not walked into -- the status bar says what to do
        // about it instead. A mount with contents is walked into, because that
        // is the "it appeared" the whole feature is for.
        if (mode === "mtp-contents" || mode === "mtp-contents-quiet") {
            const d = root.mtpDeviceByName(payload);
            const dir = d ? root.mtpMountPoint(d) : String(payload ?? "");
            if (String(shellProc.output ?? "").trim().length > 0) {
                root.statusNote = "";
                root.markMtpAnswering(dir);
                if (mode === "mtp-contents") root.navigateTo(dir);
            } else {
                root.markMtpSilent(dir);
                root.statusNote = root.mtpUnlockHint(d);
                root.scheduleMtpRetry(d);
            }
            return;
        }
        if (mode === "rescan") {
            root.statusNote = "";
            // The refresh either reveals the partitions or leaves the row as
            // it was; a rescan is meant to be repeatable, not to be trusted.
            root.refreshVolumes();
            if (code !== 0)
                root.notify(Translation.tr("Could not re-read the drive"),
                    root.firstLine(shellProc.output) || root.volumeLabelOf(payload), true);
            return;
        }
        // Mutations land here: the listing has to be re-read, and a selection
        // that pointed at a name that just moved is dropped rather than left
        // pointing at nothing.
        if (mode === "paste" || mode === "trash" || mode === "delete" || mode === "rename") {
            root.statusNote = "";
            if (code !== 0 && mode !== "trash")
                root.notify(Translation.tr("Operation failed"), root.firstLine(shellProc.output), true);
            root.refresh();
        }
    }
    // Set by an in-flight create so the row the user just asked for lands
    // selected -- the create is named in the dialog before it exists, so there
    // is no second rename step waiting for it here.
    property string pendingSelectName: ""
    Timer {
        id: pendingSelectTimer
        interval: 160
        repeat: true
        property int attempts: 0
        onTriggered: {
            if (root.pendingSelectName.length === 0) { stop(); return; }
            const i = root.indexOfPath(root.currentFolderPath() + "/" + root.pendingSelectName);
            if (i >= 0) {
                root.selectIndex(i, false, false);
                root.scrollToIndex(i);
                root.pendingSelectName = "";
                stop();
                return;
            }
            attempts += 1;
            if (attempts > 20) stop();
        }
    }

    // ── Listing ─────────────────────────────────────────────────────────
    FolderListModel {
        id: folderModel
        folder: root.asUrl(root.path)
        showFiles: true
        showHidden: root.showHidden
        // No sorting or filtering here: this model is read out and re-ordered
        // by rebuildRows(), which is the only place that has to agree with
        // what the views show.
    }
    function asUrl(p) {
        const clean = String(p ?? "");
        if (clean.length === 0)
            return "file://" + root.homeDir;
        return clean.startsWith("file:") ? clean : "file://" + clean;
    }
    // The folder as a plain path, and the one place the path is READ from the
    // model rather than from `root.path`. That distinction matters: a binding
    // that calls a function tracks nothing, so every property that must react
    // to navigation (breadcrumbs, the nav pane's highlight, free space) binds
    // to THIS, which is a tracked read of `folderModel.folder`.
    readonly property string folderPath: {
        const raw = String(folderModel.folder ?? "").replace(/^file:\/+/, "/").replace(/\/+$/, "");
        return raw.length === 0 ? "/" : raw;
    }
    function currentFolderPath() {
        return root.folderPath;
    }
    function baseName(p) {
        const s = String(p ?? "").replace(/\/+$/, "");
        return s.slice(s.lastIndexOf("/") + 1);
    }
    function dirName(p) {
        const s = String(p ?? "").replace(/\/+$/, "");
        const i = s.lastIndexOf("/");
        return i <= 0 ? "/" : s.slice(0, i);
    }
    function fileUri(p) {
        return "file://" + String(p ?? "");
    }
    // A file:// URI that survives a space, a hash or an umlaut.
    //
    // `fileUri` above is enough for Qt, which is handed a path it already
    // understands. It is NOT enough for the DESKTOP: text/uri-list is a wire
    // format, and an unescaped space in it makes the receiving app read two
    // URIs (or none). So segments are percent-encoded on the way out.
    function uriFor(p) {
        const s = String(p ?? "");
        if (s.length === 0) return "";
        return "file://" + s.split("/").map(seg => encodeURIComponent(seg)).join("/");
    }
    // The body of a text/uri-list: one URI per line, CRLF, trailing newline.
    // The trailing CRLF is not decoration -- the spec wants it, and a receiver
    // that reads line by line drops the last entry without it.
    function uriListFor(paths) {
        const list = paths ?? [];
        if (list.length === 0) return "";
        return list.map(p => root.uriFor(p)).join("\r\n") + "\r\n";
    }
    // What a drag OUT of this window carries. The selection when the row under
    // the pointer is part of it (so four selected files drag as four), and the
    // single row otherwise -- dragging an unselected file moves THAT file, not
    // whatever happened to be selected before.
    function dragUriListFor(path) {
        const p = String(path ?? "");
        if (p.length === 0) return "";
        if (root.selection.indexOf(p) !== -1 && root.selection.length > 1)
            return root.uriListFor(root.selection);
        return root.uriListFor([p]);
    }

    // ── Navigation ──────────────────────────────────────────────────────
    //
    // Opening a path that came from OUTSIDE this app. The desktop entry, the
    // portal and every other app's "show this in the file manager" hand over a
    // path that may be a folder OR a file, and the two answers differ:
    //
    //   a folder  walk into it;
    //   a file    go to the folder it lives in and SELECT it -- Explorer's own
    //             behaviour, and the whole reason to ask for a file's location.
    //
    // The question is put to the filesystem rather than to the current listing,
    // because the path being opened is usually nowhere near the folder on
    // screen: `isDirPath` looks a name up in the rows, which can only ever
    // answer for what is already displayed.
    function openPath(p) {
        const target = String(p ?? "").replace(/\/+$/, "");
        if (target.length === 0) return;
        root.sh("test -d " + root.shq(target) + " && echo dir || echo file", "open-path", target);
    }
    function navigateTo(p, record) {
        const dest = String(p ?? "");
        if (dest.length === 0)
            return;
        if (dest === root.thisPc) {
            root.atThisPc = true;
            root.selection = [];
            root.selIndex = -1;
            root.filter = "";
            return;
        }
        root.atThisPc = false;
        root.path = dest;
        // The folder being entered wears its OWN saved view, not the one the
        // folder we came from was wearing.
        root.viewMode = root.savedViewFor(dest);
        folderModel.folder = root.asUrl(dest);
        root.selection = [];
        root.selIndex = -1;
        root.anchorIndex = -1;
        root.statusNote = "";
        root.filter = "";
        if (record !== false) {
            const next = root.history.slice(0, root.historyIndex + 1);
            if (next[next.length - 1] !== dest)
                next.push(dest);
            root.history = next;
            root.historyIndex = next.length - 1;
        }
        root.syncTab();
    }
    function goBack() {
        if (root.historyIndex <= 0) return;
        root.historyIndex -= 1;
        root.navigateTo(root.history[root.historyIndex], false);
    }
    function goForward() {
        if (root.historyIndex >= root.history.length - 1) return;
        root.historyIndex += 1;
        root.navigateTo(root.history[root.historyIndex], false);
    }
    function goUp() {
        if (root.atThisPc) return;
        const p = String(folderModel.parentFolder ?? "");
        if (p.length === 0) return;
        root.navigateTo(p.replace(/^file:\/+/, "/"));
    }
    function refresh() {
        // Re-assigning the same URL is a no-op, so the re-read is forced with
        // a trailing slash that comes and goes. The directory is the SAME one
        // either way -- which matters: the obvious "knock it to /​ and back"
        // version really did navigate to root for a frame, and a phone call at
        // that moment (a probe, a click, the new item's own refresh) saw a
        // root folder instead of the one on screen.
        const cur = String(folderModel.folder ?? "");
        folderModel.folder = cur.endsWith("//") ? cur.slice(0, -1) : cur + "/";
        root.statusNote = "";
    }

    // ── Open with ───────────────────────────────────────────────────────
    //
    // The other half of a double-click. `gio open` is the right answer only
    // while something IS the default for the file's type; a file nobody claims
    // (a .dat, a project file from an app that was uninstalled, a script
    // without a handler) used to fail after the fact with a sentence in the
    // compositor's journal, which from the user's side is "double-click does
    // nothing". This asks the question FIRST -- see `openEntry` -- and answers
    // it with a list of the applications that can take the file.
    property bool openWithOpen: false
    property string openWithPath: ""
    property var openWithApps: []
    property string openWithMime: ""
    property string openWithNote: ""

    // "Is this a text file?" in the only terms that matter here: the content
    // type says so. Used ONLY where no application is registered for the type,
    // so it can never override a working association -- it fills the hole where
    // a double-click used to open a chooser.
    // What a double-click on a file of this type would do WHEN NOTHING CLAIMS
    // THE TYPE: the text editor for text, the chooser for anything else. A
    // probe rather than a launch, so the rule is checked without opening a
    // window for every content type in the shared MIME database.
    function probeOpenPlan(mime: string): string {
        return root.isTextualMime(mime) ? "editor" : "chooser";
    }
    function isTextualMime(t) {
        const type = String(t ?? "");
        if (type.length === 0) return false;
        if (type.indexOf("text/") === 0) return true;
        return ["application/json", "application/xml", "application/x-yaml",
            "application/yaml", "application/toml", "application/javascript",
            "application/x-desktop", "application/x-shellscript",
            "application/x-php", "application/x-ruby"].some(function (prefix) {
                return type === prefix || type.indexOf(prefix) === 0;
            });
    }
    function askOpenWith(p) {
        const path = String(p ?? "");
        if (path.length === 0 || root.isDirPath(path)) return;
        root.closeMenu();
        root.openWithPath = path;
        root.openWithApps = [];
        root.openWithMime = "";
        root.openWithNote = Translation.tr("Looking for applications") + "…";
        root.openWithOpen = true;
        root.sh("python3 " + root.shq(Quickshell.shellPath("scripts/system/open-with.py"))
            + " list " + root.shq(path), "open-with-list", path);
    }
    function closeOpenWith() {
        root.openWithOpen = false;
        root.openWithApps = [];
        root.openWithNote = "";
        root.openWithPath = "";
        root.openWithMime = "";
    }
    function runOpenWith(app) {
        const id = String(app?.id ?? "");
        const path = root.openWithPath;
        if (id.length === 0 || path.length === 0) return;
        // The launch feedback the shell shows for any app opened from here: the
        // app's own name, announced before it starts, ended by its window (or
        // by the failure below).
        root.openAnnounced = String(app?.name ?? id);
        root.closeOpenWith();
        root.sh(root.announcePrefix(root.openAnnounced)
            + "python3 " + root.shq(Quickshell.shellPath("scripts/system/open-with.py"))
            + " run " + root.shq(path) + " " + root.shq(id), "open-with-run", path);
    }

    // ── Opening ─────────────────────────────────────────────────────────
    function openEntry(i) {
        if (i < 0 || i >= root.rows.length)
            return;
        const p = root.pathAt(i);
        if (root.isDirAt(i)) {
            root.navigateTo(p);
            return;
        }
        // An AppImage is INSTALLED, not run in place (desktop policy since
        // 2026-09-26): double-clicking one moves it to ~/Applications and
        // wires its icon into the app menu. The helper is idempotent.
        if (/\.appimage$/i.test(p)) {
            // Same announce-and-end contract as the `gio open` below: an
            // AppImage being installed IS an app being opened from here.
            root.openAnnounced = root.baseName(p);
            root.sh(root.announcePrefix(root.openAnnounced)
                + "$HOME/.local/bin/install-appimage " + root.shq(p)
                + " && notify-send -a 'Files' -i application-x-executable 'AppImage installed'"
                + " \"$(basename -- " + root.shq(p) + ") — added to the app menu\""
                + " || notify-send -a 'Files' 'AppImage install failed' 'see journalctl --user -xe' -u critical",
                "appimage", p);
            return;
        }
        // ── Is there anything to open it WITH? ─────────────────────────────
        // Asked before the launch, not after it. `gio open` fails only once it
        // has run, and its complaint is a localized sentence on stderr -- so
        // the fact "no application is registered for this type" arrived as a
        // status note nobody looked at, i.e. as nothing happening. The content
        // type's DEFAULT application is one cheap query (`xdg-mime query
        // default`, ~30ms measured) and its absence is exactly the case that
        // gets the chooser instead of a launch that was never going to work.
        if (root.pickerMode) {
            root.openAnnounced = root.baseName(p);
            root.sh(root.announcePrefix(root.openAnnounced) + "gio open " + root.shq(p), "open", p);
            return;
        }
        root.sh("t=$(xdg-mime query filetype " + root.shq(p) + " 2>/dev/null); "
            + "printf '%s\\n' \"$t\"; xdg-mime query default \"$t\" 2>/dev/null", "open-check", p);
    }
    // The double-click. WINDOW MODE opens anything; PICKER MODE opens FOLDERS.
    //
    // Inside a file dialog a double-click on a FILE would answer a question the
    // user has not been asked yet, so that is still only a selection. A folder
    // is not an answer though -- it is the way through the tree -- and a dialog
    // that made you hunt for a breadcrumb to enter the folder you just
    // double-clicked was asked to stop doing that (REQUESTED 2026-10-13:
    // "open folders with double click also ... in the add folder or file file
    // manager version"). Entering the folder IS the answer in a folder picker:
    // pickerConfirm hands over the folder being looked at.
    function activate(i) {
        if (i < 0 || i >= root.rows.length)
            return;
        if (root.pickerMode && !root.isDirAt(i)) {
            root.selectIndex(i, false, false);
            return;
        }
        root.openEntry(i);
    }

    // ── Selection ───────────────────────────────────────────────────────
    function selectIndex(i, additive, range) {
        // Clicking a row IS using the list: whatever Tab had the keyboard on,
        // the keyboard is back on the files now, and the ring says so.
        root.setFocusArea("list");
        if (i < 0 || i >= root.rows.length) {
            if (!additive)
                root.selection = [];
            root.selIndex = -1;
            return;
        }
        root.selIndex = i;
        if (range && root.anchorIndex >= 0) {
            const lo = Math.min(root.anchorIndex, i);
            const hi = Math.max(root.anchorIndex, i);
            const picked = [];
            for (let k = lo; k <= hi; k++)
                picked.push(root.pathAt(k));
            root.selection = picked;
        } else if (additive) {
            const p = root.pathAt(i);
            const list = root.selection.slice();
            const at = list.indexOf(p);
            if (at === -1) list.push(p);
            else list.splice(at, 1);
            root.selection = list;
            root.anchorIndex = i;
        } else {
            root.selection = [root.pathAt(i)];
            root.anchorIndex = i;
        }
    }
    function selectName(name) {
        const i = root.indexOfPath(root.currentFolderPath() + "/" + name);
        if (i >= 0) {
            root.selectIndex(i, false, false);
            root.scrollToIndex(i);
        }
    }
    function selectAll() {
        const all = [];
        for (let i = 0; i < root.rows.length; i++)
            all.push(root.pathAt(i));
        root.selection = all;
    }
    function stepSelection(delta) {
        if (root.rows.length === 0) return;
        const next = root.selIndex < 0
            ? (delta > 0 ? 0 : root.rows.length - 1)
            : Math.max(0, Math.min(root.rows.length - 1, root.selIndex + delta));
        root.selectIndex(next, false, false);
        root.scrollToIndex(next);
    }
    function scrollToIndex(i) {
        if (root.viewMode === "tiles")
            tilesView.positionViewAtIndex(i, GridView.Contain);
        else
            detailsView.positionViewAtIndex(i, ListView.Contain);
    }
    function isSelected(p) {
        return root.selection.indexOf(String(p)) !== -1;
    }
    // A row that has been CUT and is waiting for its paste. It is still on
    // disk -- nothing moves until the paste -- so the row is the only place
    // that can say what Ctrl+X did to it: see cutOpacity, which greys the
    // icon and the name the way Explorer does.
    function isCut(p) {
        const q = String(p);
        for (let i = 0; i < root.clipboard.length; i++) {
            const c = root.clipboard[i];
            if (c && c.cut && String(c.path) === q) return true;
        }
        return false;
    }

    // ── Tabs (Explorer's; also what the IPC tab hooks drive) ────────────
    function tabSnapshot() {
        return {
            path: root.path,
            atThisPc: root.atThisPc,
            history: root.history.slice(),
            historyIndex: root.historyIndex,
            selection: root.selection.slice()
        };
    }
    function syncTab() {
        if (root.tabs.length === 0) return;
        const list = root.tabs.slice();
        list[root.activeTab] = root.tabSnapshot();
        root.tabs = list;
    }
    function tabLabel(t) {
        if (!t) return "";
        if (t.atThisPc) return Translation.tr("This PC");
        const p = String(t.path ?? "/");
        const base = p === "/" ? "/" : p.slice(p.lastIndexOf("/") + 1);
        return base.length > 0 ? base : p;
    }
    function applyTab(i) {
        const t = root.tabs[i];
        if (!t) return;
        root.activeTab = i;
        root.history = (t.history ?? [root.homeDir]).slice();
        root.historyIndex = t.historyIndex ?? 0;
        if (t.atThisPc) root.navigateTo(root.thisPc);
        else root.navigateTo(t.path ?? root.homeDir, false);
    }
    function newTab(p) {
        const target = (typeof p === "string" && p.length > 0) ? p : root.path;
        root.syncTab();
        root.tabs = root.tabs.concat([{
            path: target,
            atThisPc: false,
            history: [target],
            historyIndex: 0,
            selection: []
        }]);
        root.applyTab(root.tabs.length - 1);
    }
    function selectTab(i) {
        if (i < 0 || i >= root.tabs.length || i === root.activeTab) return;
        root.syncTab();
        root.applyTab(i);
    }
    function closeTab(i) {
        if (root.tabs.length <= 1) return;
        root.syncTab();
        const list = root.tabs.slice();
        list.splice(i, 1);
        root.tabs = list;
        root.activeTab = -1;
        root.applyTab(Math.max(0, Math.min(i, list.length - 1)));
    }
    function pickerNavigate(p) {
        if (String(p ?? "").length > 0)
            root.navigateTo(p);
    }

    // ── Volumes ─────────────────────────────────────────────────────────
    Process {
        id: lsblkProc
        command: ["bash", "-c",
            "lsblk -J -b -o NAME,PATH,LABEL,FSTYPE,SIZE,TYPE,TRAN,RM,MODEL,MOUNTPOINTS,ROTA,PKNAME,UUID 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: root.parseLsblk(this.text)
        }
    }
    // ── What kind of drive is this? ─────────────────────────────────────
    //
    // Explorer shows a different little drawing for a USB stick, a card, a
    // solid-state disk and a spinning one, and so does this: `tran` says how
    // the device is attached (usb / mmc / nvme / sata) and `rota` says whether
    // the medium spins. `rota` is the only honest way to tell an SSD from an
    // HDD on the same transport -- guessing from the name is guessing.
    // Does anything in this device's subtree carry a filesystem? A disk whose
    // partitions are readable is described by those partitions, and adding the
    // disk row as well would say "no filesystem found" directly above the two
    // rows that found one.
    function subtreeHasVolume(node) {
        const fs = String(node?.fstype ?? "");
        if (fs.length > 0 && fs.toLowerCase() !== "swap") return true;
        for (const kid of (node?.children ?? []))
            if (root.subtreeHasVolume(kid)) return true;
        return false;
    }
    function kindOfDrive(v) {
        const tran = String(v?.tran ?? "").toLowerCase();
        if (tran === "mmc" || tran === "mmcblk") return "sd";
        if (tran === "usb" || v?.removable === true) return "usb";
        if (tran === "nvme" || v?.rotational === false) return "ssd";
        if (v?.rotational === true) return "hdd";
        return "disk";
    }
    // Names below are checked against the icon font, not guessed: a name the
    // font does not have renders as its own letters (which is what turned the
    // drive rows into the word "harddisk").
    function iconForDrive(kind) {
        switch (kind) {
        case "sd": return "sd_card";
        case "usb": return "usb";
        // A phone or camera on MTP: a device, drawn as one. The same glyph is
        // asserted against the icon font by the check suite, because a name the
        // font does not have renders as its own letters.
        case "mtp": return "smartphone";
        case "ssd": return "hard_drive";
        case "hdd": return "hard_drive_2";
        // Could not tell: a drive is a drive. "harddisk" used to render as
        // those letters; this name is a glyph, and it is the same drawing an
        // SSD gets, which is the honest generalisation for an unknown disk.
        default: return "hard_drive";
        }
    }
    function refreshVolumes() {
        lsblkProc.running = false;
        lsblkProc.running = true;
        // Both sources, one call: every existing caller (the poll timer, a
        // mount that just finished, the refresh button, an insertion) is asking
        // "what is plugged in now?", and a phone is an answer to that question.
        root.scanMtpDevices();
    }
    // A device can be named four ways and all four are legitimate: the USB name
    // the kernel gives it ("1-12"), the path its volume carries in this app
    // ("mtp:1-12"), the name on its box ("SAMSUNG_Android"), or the folder it is
    // mounted in. Refusing three of them made the eject control answer "nothing
    // happened" to anyone who named the phone the way the LIST names it -- which
    // is the only name a person ever sees.
    function mtpDeviceByName(name) {
        const want = String(name ?? "").trim();
        if (want.length === 0) return null;
        for (const d of root.mtpDevices) {
            if (d.name === want
                    || ("mtp:" + d.name) === want
                    || root.mtpLabel(d) === want
                    || root.mtpMountPoint(d) === want)
                return d;
        }
        // A label that is not unique (two phones of the same model, both saying
        // "SAMSUNG_Android") is answered with the first one rather than nothing:
        // the caller asked for a device it can see, and this is one of them.
        return null;
    }
    function parseLsblk(text) {
        let data = null;
        try {
            data = JSON.parse(String(text ?? ""));
        } catch (e) {
            return;
        }
        const out = [];
        for (const disk of (data?.blockdevices ?? [])) {
            const walk = (node, parent) => {
                const fstype = String(node.fstype ?? "");
                const mounts = (node.mountpoints ?? []).filter(m => m && String(m).length > 0);
                const type = String(node.type ?? "");
                if (type === "loop" || type === "zram")
                    return;
                const tran = String(node.tran ?? parent?.tran ?? "").trim();
                const removable = (node.rm === true || node.rm === "1");
                const rotational = (node.rota === true || node.rota === "1");
                const external = removable || ["usb", "mmc"].includes(tran.toLowerCase());
                const hasFs = fstype.length > 0 && fstype.toLowerCase() !== "swap";
                // Swap is hardware, not a place. Everything with a filesystem
                // is a volume; AND so is a plugged-in stick or card whose
                // partition table the kernel has not read yet -- that device
                // has no filesystem to show, and the reason people say "my SD
                // card does not appear" is precisely that it was dropped from
                // the list for not having one. It gets a row and a Rescan
                // instead of silence.
                // An external device with no filesystem ANYWHERE on it still
                // gets a row (that is a card the kernel has not read yet, and
                // dropping it is how "my SD card does not appear" happens), but
                // only as the whole device: one row, not one per empty
                // partition.
                if (hasFs || (external && type === "disk" && !root.subtreeHasVolume(node))) {
                    const kind = root.kindOfDrive({ tran: tran, removable: removable, rotational: rotational });
                    out.push({
                        name: String(node.name ?? ""),
                        path: String(node.path ?? ""),
                        disk: "/dev/" + String(node.pkname ?? node.name ?? ""),
                        label: String(node.label ?? ""),
                        // The volume's identity, which is what the remembered
                        // mount-point name ("drive letter") is keyed by: a
                        // label can be changed, the UUID cannot.
                        uuid: String(node.uuid ?? ""),
                        fstype: hasFs ? fstype : "",
                        hasFs: hasFs,
                        // Read-only in the kernel's eyes (a dying disk, a
                        // remounted-ro system volume). A drive menu that offers
                        // "Remount read-write" only on a volume that IS read-only
                        // needs to know, and it is one field lsblk already sends.
                        readOnly: (node.ro === true || node.ro === "1"),
                        size: Number(node.size ?? 0),
                        tran: tran,
                        removable: removable,
                        rotational: rotational,
                        external: external,
                        kind: kind,
                        icon: root.iconForDrive(kind),
                        model: String(parent?.model ?? node.model ?? "").trim(),
                        // A btrfs system disk has many mount points (/home,
                        // /var/log, ...) and only one of them is the volume's
                        // identity; "/" wins when it is in the list, which is
                        // also what makes an unmountable check meaningful.
                        mountpoint: mounts.length > 0
                            ? String(mounts.indexOf("/") !== -1 ? "/" : mounts[0]) : ""
                    });
                }
                for (const kid of (node.children ?? []))
                    walk(kid, node);
            };
            walk(disk, null);
        }
        root.blockVolumes = out;
        root.applyVolumes();
    }

    // ── The order the drives are listed in ──────────────────────────────
    //
    // Not the alphabet, and not "mounted things first": what the machine IS
    // comes first, biggest first, so the 1 TB system disk is the top row and
    // the other SSD sits directly under it. Then everything you can carry --
    // sticks, cards, phones. Then the plumbing: internal partitions that are
    // small or that nobody mounted, which is where /boot and the leftover
    // Windows partitions live. Those rows are real and must not be lost, but
    // they are not what the list is for, so they sit behind "Advanced"
    // (navAdvancedVolumes) instead of in the middle of it.
    //
    // A size threshold is doing work here that deserves to be said out loud:
    // "a big internal volume is a drive, a small one is a partition" is the
    // rule, and 16 GB is where this machine's own split falls (4 GB /boot,
    // 330 MB EFI, 16 MB reserved, 1 GB recovery, then 949 GB and 475 GB of
    // real storage). It is a rule about scale, not about any particular disk:
    // a 32 GB internal SSD would still be a drive.
    //
    // BEING UNMOUNTED IS NOT WHAT MAKES SOMETHING PLUMBING. The other SSD on
    // this machine -- the 475 GB one holding a Windows install -- is usually
    // NOT mounted, and it is the second drive in this list, not a hidden
    // partition: a big internal volume is a drive whether or not it happens to
    // be mounted right now. What folds away is the plumbing: small partitions
    // and ones with no filesystem on them at all.
    readonly property real plumbingSize: 16 * 1024 * 1024 * 1024
    function volumeGroup(v) {
        if (v.kind === "mtp" || v.external) return 1;      // things you can carry
        if (v.hasFs === false || v.size < root.plumbingSize) return 2;   // plumbing
        return 0;                                            // the machine's own drives
    }
    function compareVolumes(a, b) {
        const ga = root.volumeGroup(a), gb = root.volumeGroup(b);
        if (ga !== gb) return ga - gb;
        // Inside the carried group, anything already open comes first: a phone
        // or stick that is mounted is the one you are about to use.
        if (ga === 1 && !!a.mountpoint !== !!b.mountpoint) return a.mountpoint ? -1 : 1;
        if (b.size !== a.size) return b.size - a.size;
        return root.volumeLabel(a).localeCompare(root.volumeLabel(b));
    }
    // The rows the navigation pane draws, and the ones it keeps behind the
    // Advanced toggle. Everything else in this file reads `volumes`, which
    // holds both groups -- so nothing is invisible to a right-click, a probe or
    // the This PC tiles, it is only folded away in the list.
    readonly property var navVolumes: root.volumes.filter(v => root.volumeGroup(v) !== 2)
    readonly property var navAdvancedVolumes: root.volumes.filter(v => root.volumeGroup(v) === 2)
    property bool showAdvancedVolumes: false
    function applyVolumes() {
        root.volumes = root.blockVolumes.concat(root.mtpVolumes).sort(root.compareVolumes);
        root.refreshUsage();
        // A mount that just landed is walked into, once: mounting a drive and
        // staying in the old folder is the "nothing happened" that makes
        // people think the button is broken.
        //
        // The wish is only cleared when it is GRANTED. Clearing it first was a
        // real bug: the refresh that follows a mount can win the race against
        // the kernel's mount table and see the volume as still unmounted, and
        // the user's drive then never opened -- silently, because the one
        // chance had already been thrown away.
        if (root.mountOpenAfter.length > 0) {
            const want = root.mountOpenAfter;
            for (const v of root.volumes) {
                if (v.path === want && v.mountpoint.length > 0) {
                    root.mountOpenAfter = "";
                    root.navigateTo(v.mountpoint);
                    break;
                }
            }
        }
    }
    property string mountOpenAfter: ""
    function volumeByPath(p) {
        for (const v of root.volumes)
            if (v.path === String(p ?? ""))
                return v;
        return null;
    }
    function volumeLabelOf(p) {
        const v = root.volumeByPath(p);
        return v ? root.volumeLabel(v) : String(p ?? "");
    }
    function volumeLabel(v) {
        if (!v) return "";
        if (v.label.length > 0) return v.label;
        if (v.mountpoint === "/") return Translation.tr("System");
        return v.name;
    }
    function volumeSubtitle(v) {
        const parts = [];
        // A phone's subtitle says what it is and whether it is open, and stops
        // there: MTP has no filesystem format to name, no free-space figure
        // that means anything useful, and the question a person has about this
        // row is only ever "can I look in it yet?".
        if (v.kind === "mtp") {
            parts.push("MTP");
            if (v.mountpoint.length === 0)
                parts.push(Translation.tr("not mounted"));
            else if (root.mtpSilent(v.mountpoint))
                // The honest description of a mount that lists nothing, in the
                // one line a person reads while looking at the row.
                parts.push(Translation.tr("not answering — unlock the phone and allow file access"));
            else
                parts.push(v.mountpoint);
            return parts.join(" · ");
        }
        if (v.hasFs === false)
            parts.push(Translation.tr("no filesystem found"));
        else if (v.fstype.length > 0)
            parts.push(v.fstype.toUpperCase());
        if (v.size > 0) parts.push(root.fmtCapacity(v.size));
        if (v.mountpoint.length > 0) parts.push(v.mountpoint);
        else if (v.hasFs !== false) parts.push(Translation.tr("not mounted"));
        return parts.join(" · ");
    }
    // Capacity bars need a real filesystem report, and only mounted volumes
    // have one. `df -B1` for all of them in ONE call: a call per volume would
    // walk every device on every refresh.
    Process {
        id: usageProc
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                const map = {};
                for (const line of String(this.text ?? "").split("\n")) {
                    const f = line.trim().split(/\s+/);
                    if (f.length < 6) continue;
                    const size = Number(f[1]), used = Number(f[2]), avail = Number(f[3]);
                    let mnt = f[5];
                    for (let i = 6; i < f.length; i++) mnt += " " + f[i];
                    if (isFinite(size) && size > 0)
                        map[mnt] = { size: size, used: used, avail: avail };
                }
                root.volumeUsage = map;
            }
        }
    }
    function refreshUsage() {
        // Free space for what df can answer for. A phone is deliberately not
        // asked: its mount is a FUSE round trip to the device, and one slow or
        // silent device would hold up the ONE df call that answers for every
        // other volume -- a whole list of capacity bars lost to a phone that is
        // asleep. Nothing is shown for it instead, which is honest: capacity
        // over MTP is the phone's business, not this list's.
        const mounts = root.volumes
            .filter(v => v.mountpoint.length > 0 && v.kind !== "mtp")
            .map(v => root.shq(v.mountpoint));
        if (mounts.length === 0) {
            root.volumeUsage = ({});
            return;
        }
        usageProc.command = ["bash", "-c", "df -B1 -P " + mounts.join(" ") + " 2>/dev/null | tail -n +2"];
        usageProc.running = false;
        usageProc.running = true;
    }
    // The free-space figure for whatever folder is on screen: the LONGEST
    // mount point that is a prefix of it, because /home lives on / and a
    // lookup by exact path would answer nothing.
    function usageFor(p) {
        let best = null, bestLen = -1;
        for (const key in root.volumeUsage) {
            const matches = (key === "/") ? String(p).startsWith("/") : (String(p) === key || String(p).startsWith(key + "/"));
            if (matches && key.length > bestLen) {
                best = root.volumeUsage[key];
                bestLen = key.length;
            }
        }
        return best;
    }
    // Everything the status bar's right-hand figure depends on is read HERE,
    // in the binding: the folder, and the map df filled in. A helper call
    // would read the same values but track none of them.
    readonly property var currentUsage: {
        const path = root.folderPath;
        const map = root.volumeUsage;
        let best = null, bestLen = -1;
        for (const key in map) {
            const matches = (key === "/") ? path.startsWith("/") : (path === key || path.startsWith(key + "/"));
            if (matches && key.length > bestLen) {
                best = map[key];
                bestLen = key.length;
            }
        }
        return best;
    }
    readonly property string storageText: {
        const u = root.currentUsage;
        if (!u) return "";
        return `${root.fmtCapacity(u.avail)} ${Translation.tr("free of")} ${root.fmtCapacity(u.size)}`;
    }
    Process {
        id: udisksProbe
        command: ["bash", "-c", "command -v udisksctl >/dev/null 2>&1 && echo yes || echo no"]
        stdout: StdioCollector {
            onStreamFinished: root.udisksAvailable = String(this.text ?? "").trim() === "yes"
        }
    }
    // ── Eject or unmount? The one control that does both ────────────────
    //
    // The single button next to a mounted drive does two different things
    // depending on WHAT is mounted, and the difference is the difference
    // between walking away with the thing in your hand and merely taking a
    // filesystem out of the tree while the hardware stays bolted in:
    //
    //   eject    the medium is going away (a stick, a card, a phone), so the
    //            write cache is flushed and the device is left in a state you
    //            can pull the cable out of;
    //   unmount  the drive stays exactly where it is, attached; only the
    //            filesystem is detached (the system disk, an internal SSD).
    //
    // So the label says which the click is, spelled out on hover rather than
    // inferred from a glyph. Both words are this app's own; neither is reused
    // from the other case, so "Unmount" on an internal drive can never be read
    // as an invitation to yank it out.
    function volumeRemoval(v) {
        if (!v || v.mountpoint.length === 0) return "";
        if (v.kind === "mtp") return "eject";
        return (v.removable || v.external) ? "eject" : "unmount";
    }
    function volumeRemovalTip(v) {
        const removal = root.volumeRemoval(v);
        if (removal === "eject")
            return Translation.tr("Eject") + " — " + Translation.tr("safe to unplug when it is done");
        if (removal === "unmount")
            return Translation.tr("Unmount") + " — " + Translation.tr("this drive stays attached");
        return "";
    }
    // What the control does when the volume is NOT mounted: the same button
    // again, wearing the word for the other direction.
    function volumeControlTip(v) {
        if (!v) return "";
        if (v.mountpoint.length > 0) return root.volumeRemovalTip(v);
        if (v.hasFs === false) return Translation.tr("Re-read this drive");
        if (v.kind === "mtp") return Translation.tr("Mount") + " — " + Translation.tr("read this device's files");
        return Translation.tr("Mount");
    }
    function volumeControlIcon(v) {
        if (!v) return "download";
        if (v.mountpoint.length === 0)
            return v.hasFs === false ? "refresh" : "download";
        // "logout" for unmount: an arrow leaving a bracket, the drawing for
        // "out of the tree" -- while "eject" keeps the upward triangle that
        // means the medium itself is coming out. Both names are asserted
        // against the icon font by the check suite.
        return root.volumeRemoval(v) === "unmount" ? "logout" : "eject";
    }
    // The folder on screen, when that folder IS a phone's mount. Used for the
    // empty-listing sentence below: an MTP mount that has not been granted
    // access is an empty directory, and "This folder is empty" would be a lie
    // about the reason.
    readonly property var currentMtpVolume: {
        const here = root.folderPath;
        for (const v of root.mtpVolumes)
            if (v.mountpoint.length > 0 && here === v.mountpoint) return v;
        return null;
    }
    // Eject is offered for removable media and for anything already living
    // under /run/media or /mnt -- never for the disk the session is running
    // from.
    function volumeUnmountable(v) {
        if (!v || v.mountpoint.length === 0) return false;
        // A phone is not under /run/media and is not a block device, but it is
        // mounted, and taking it out of the tree is exactly this control's job.
        if (v.kind === "mtp") return true;
        return v.removable || v.mountpoint.startsWith("/run/media/") || v.mountpoint.startsWith("/mnt/");
    }
    function mountPointFor(v) {
        return `/run/media/${root.userName}/${root.mountNameFor(v)}`;
    }
    // The name a volume is mounted under: the one its owner picked (“change
    // drive letter”), else its label, else the kernel's name. Sanitised, because
    // this becomes a path component.
    function mountNameFor(v) {
        if (!v) return "";
        const remembered = String(root.mountNames[String(v.uuid ?? "")] ?? "");
        const source = remembered.length > 0 ? remembered
            : (v.label.length > 0 ? v.label : String(v.name ?? ""));
        const clean = source.replace(/[^\w.-]+/g, "_");
        return clean.length > 0 ? clean : String(v.name ?? "drive");
    }
    // Mount options per filesystem. The user-id options are what make an
    // exFAT/vfat/NTFS volume writable by the person who plugged it in; ext4
    // carries its own ownership and rejects them; squashfs and erofs images
    // (the SD card's Home Assistant partitions) are read-only formats and get
    // `ro` so the kernel is told outright rather than failing the write later.
    function mountOptions(fstype, readOnly) {
        const fs = String(fstype ?? "").toLowerCase();
        // Read-only on request, and read-only because the format cannot be
        // written (a squashfs image on the SD card, an iso): the kernel is told
        // outright instead of failing the write later.
        if (readOnly === true || ["squashfs", "erofs", "iso9660", "udf"].includes(fs))
            return "ro,noatime";
        if (["exfat", "vfat", "ntfs", "ntfs3", "fuseblk"].includes(fs))
            return `uid=${root.userUid},gid=${root.userUid},noatime`;
        return "noatime";
    }
    function toggleVolume(v) {
        if (!v) return;
        if (v.mountpoint.length > 0) root.unmountVolume(v);
        else if (v.hasFs === false) root.rescanVolume(v);
        else root.mountVolume(v);
    }
    // What clicking a drive ROW does, as opposed to its small control.
    //
    // These are two different intentions and they used to share one function,
    // which made the row a second eject button: the only way to walk into a
    // mounted drive from the navigation pane was to not click it. Clicking a
    // drive is asking to look inside it -- the This PC tiles have always read
    // it that way -- and the control beside it keeps the mount/eject half.
    //
    // An unmounted drive still mounts on a click, because that is what wanting
    // it means when it is not open yet. A phone that mounted but is answering
    // with nothing is asked for a FRESH session instead of being opened onto an
    // empty folder: see the MTP section's silent-mount handling.
    function rowActivate(v) {
        if (!v) return;
        if (v.mountpoint.length > 0) {
            if (v.kind === "mtp" && root.mtpSilent(v.mountpoint)) {
                const d = root.mtpDeviceByMount(v.mountpoint);
                if (d) { root.remountMtp(d); return; }
            }
            root.navigateTo(v.mountpoint);
            return;
        }
        root.toggleVolume(v);
    }
    // A device with no filesystem on it cannot be mounted -- but it can be
    // asking to be re-read. Cards in particular are inserted before their
    // partition table is visible often enough that "the kernel has not read it
    // yet" is the normal first state of an SD card; partprobe asks again, and
    // the refresh that follows either shows the partitions or keeps saying
    // what it said.
    function rescanVolume(v) {
        if (!v) return;
        // For a phone, "look again" is a fresh look at the USB bus rather than
        // partprobe: there is no partition table to re-read, and the state worth
        // catching is a cable that was replugged.
        if (v.kind === "mtp") {
            root.statusNote = Translation.tr("Looking for") + " " + root.volumeLabel(v) + "…";
            root.scanMtpDevices();
            return;
        }
        const disk = (v.disk && v.disk.length > 0) ? v.disk : v.path;
        root.statusNote = Translation.tr("Rescanning") + " " + root.volumeLabel(v) + "…";
        // pkexec runs blockdev ITSELF, never a shell -- the same reason the
        // mount below does, and it is what lets the polkit rule name
        // /usr/bin/blockdev and check the argument instead of blessing `bash`.
        //
        // blockdev is also the tool that is actually HERE: the `partprobe`
        // this used to try first is not installed on this machine (no
        // util-linux partprobe in PATH), so every rescan ran
        // "partprobe: command not found" and then re-read the table with
        // blockdev anyway. One command that exists beats two, one of which is
        // a guaranteed failure line in the output.
        root.sh("pkexec /usr/bin/blockdev --rereadpt " + root.shq(disk) + " 2>&1",
            "rescan", v.path);
    }
    function mountVolume(v, readOnly) {
        if (!v || v.mountpoint.length > 0) return;
        // A phone has no device node to hand to `mount`, and no privilege is
        // needed to read it: it is mounted through FUSE, by the user, in their
        // own runtime directory.
        if (v.kind === "mtp") {
            root.mountMtp(v.mtp);
            return;
        }
        if (v.hasFs === false) {
            // Nothing to mount yet. Ask the kernel to look again rather than
            // handing `mount` a device it cannot read.
            root.rescanVolume(v);
            return;
        }
        root.mountOpenAfter = "";   // no wish left over from a previous attempt
        const label = root.volumeLabel(v);
        root.statusNote = Translation.tr("Mounting") + " " + label + "…";
        root.mountingPath = v.path;
        root.mountFailurePath = "";
        root.mountFailure = "";
        if (root.udisksAvailable && readOnly !== true) {
            root.sh("udisksctl mount -b " + root.shq(v.path) + " 2>&1", "mount", v.path);
            return;
        }
        // No udisks2 on this desktop, so this is the pkexec path: the shell's
        // own polkit agent puts the prompt on screen before anything is
        // mounted. pkexec drops $USER and $HOME from the environment, so every
        // path in the command is absolute.
        //
        // pkexec runs `mount` ITSELF, never a shell. It used to be
        // `pkexec bash -c "mkdir -p … && mount …"`, and that is why no polkit
        // rule can ever be written for it: the program polkit sees is `bash`,
        // and allowing bash allows everything. `mount --mkdir` (util-linux 2.42
        // on this machine) creates the mount point itself, so the command is
        // mount's own argv -- which is what lets
        // /etc/polkit-1/rules.d/10-ii-removable-mount.rules name
        // /usr/bin/mount and check the target, instead of blessing a shell.
        const mnt = root.mountPointFor(v);
        root.sh("pkexec /usr/bin/mount --mkdir -t " + (v.fstype || "auto")
            + " -o " + root.mountOptions(v.fstype, readOnly === true)
            + " " + root.shq(v.path) + " " + root.shq(mnt) + " 2>&1",
            "mount", v.path);
    }
    // The line that closes this volume, kept apart from RUNNING it so the
    // confirmation below can say exactly what it is about to do -- and so a
    // check can read it without an unmount being the price.
    function volumeUnmountCommand(v) {
        if (!v) return "";
        if (v.kind === "mtp") {
            const dir = root.mtpMountPoint(v.mtp);
            return "fusermount3 -u " + root.shq(dir) + " 2>&1 || fusermount -u " + root.shq(dir)
                + " 2>&1 || umount " + root.shq(dir) + " 2>&1";
        }
        if (!root.volumeUnmountable(v)) return "";
        if (root.udisksAvailable) return "udisksctl unmount -b " + root.shq(v.path) + " 2>&1";
        // Absolute, like the mount above and for the same reason: a polkit rule
        // matches on the program's path, and `umount` resolved through PATH is
        // whatever PATH happens to say at the time.
        return "pkexec /usr/bin/umount " + root.shq(v.mountpoint) + " 2>&1";
    }
    function unmountVolume(v) {
        // A phone is not unmounted by `umount`: it is a FUSE mount, so the
        // question is the same but the answer belongs to fusermount.
        if (v && v.kind === "mtp") {
            root.unmountMtp(v.mtp);
            return;
        }
        if (!root.volumeUnmountable(v)) return;
        const label = root.volumeLabel(v);
        root.statusNote = Translation.tr("Unmounting") + " " + label + "…";
        if (root.udisksAvailable)
            root.sh("udisksctl unmount -b " + root.shq(v.path) + " 2>&1", "unmount", v.path);
        else
            root.sh("pkexec /usr/bin/umount " + root.shq(v.mountpoint) + " 2>&1", "unmount", v.path);
    }
    // ── Asking before it goes ───────────────────────────────────────────
    //
    // The small control beside a drive is the one click in this window that
    // takes something away rather than showing it: an eject you did not mean
    // costs a replug, and an unmount that lands while something is still
    // writing is worse than that. So the control ASKS -- and the row beside it
    // stays what it always should have been, which is "open this".
    //
    // Mounting is not asked about: attaching a drive takes nothing away.
    // Counted, so a check can tell "the control asked" from "the control
    // unmounted": the number moves where the question is put on screen.
    property int unmountAsks: 0
    function requestUnmount(v) {
        if (!v) return;
        if (v.mountpoint.length === 0) {
            // Nothing is open, so the control means Mount: no question to ask.
            root.toggleVolume(v);
            return;
        }
        root.unmountAsks++;
        root.openVolumePrompt("confirm", v);
    }

    // ═══ Phones and cameras: the devices that are not disks ═════════════
    //
    // WHY A PHONE NEEDED ITS OWN MACHINERY. Everything above this line is built
    // on `lsblk`, and a phone on MTP is not a block device: no /dev node, no
    // filesystem, nothing for lsblk to report. So the drive list answered "no
    // devices" about a phone that was plugged in and switched to file transfer
    // -- and the deeper reason it stayed that way is that this machine had no
    // MTP stack at all: no libmtp, no gvfs, nothing that could read one.
    //
    // WHAT REPLACED IT. The device is found where it is actually visible --
    // sysfs, via scripts/system/mtp-devices.sh, which reads the one descriptor
    // that identifies MTP (interface class 06, Still Imaging). It is read by
    // mounting it with aft-mtp-mount (from android-file-transfer) under this
    // user's own runtime directory. No root, no pkexec, no polkit prompt: the
    // session's ACL on the USB device node is already enough for the person
    // sitting at the machine, and MTP needs nothing else.
    //
    // Once mounted it IS a path, so the list, the preview pane, the thumbnails,
    // opening, copying and the status bar all work on a phone with no special
    // case of their own. Only three things are special, and each is named where
    // it happens: it cannot be mounted by `mount` (mountVolume/mountMtp), its
    // free space is never asked for (refreshUsage), and the menu it offers is
    // shorter (deviceMenu) because a phone has no filesystem to check, label,
    // TRIM or format.
    property var mtpDevices: []
    property var mtpMounts: ({})
    // ── The phone that mounted and then said nothing ────────────────────
    //
    // A Samsung in file-transfer mode mounts whether or not it has agreed to
    // let anyone read it: the FUSE mount lands, and every listing comes back
    // as an empty directory until the phone is unlocked and its "allow access
    // to phone data" prompt is answered. Measured on the phone attached to
    // this machine: a fresh mount, a clean READDIR, and not one storage -- so
    // "the phone is not showing" is this exact state.
    //
    // Both maps are keyed by the mount point. `mtpEmpty` is "this mount is
    // silent", which the row's subtitle and the click handling both read;
    // `mtpRetried` is the spent part of the retry budget (mtpRetryLimit tries,
    // spaced) for the automatic retry, so a phone that stays locked cannot turn
    // into a remount loop.
    property var mtpEmpty: ({})
    property var mtpRetried: ({})
    readonly property string mtpRoot: (Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp") + "/mtp"
    readonly property string mtpScanScript: Quickshell.shellPath("scripts/system/mtp-devices.sh")
    Process {
        id: mtpScanProc
        command: ["bash", root.mtpScanScript]
        stdout: StdioCollector {
            onStreamFinished: root.parseMtpDevices(this.text)
        }
    }
    function scanMtpDevices() {
        mtpScanProc.running = false;
        mtpScanProc.running = true;
    }
    function mtpLabel(d) {
        const product = String(d?.product ?? "");
        if (product.length > 0) return product;
        const maker = String(d?.manufacturer ?? "");
        if (maker.length > 0) return maker;
        return Translation.tr("Phone or camera");
    }
    // Its directory under XDG_RUNTIME_DIR: the device's own advertised name,
    // sanitised because this becomes a path component. Runtime dir, not /media:
    // nothing about this needs root, and the mount belongs to the session that
    // made it -- closing the session takes it with it.
    function mtpMountPoint(d) {
        const clean = String(root.mtpLabel(d)).replace(/[^\w.-]+/g, "_");
        return root.mtpRoot + "/" + (clean.length > 0 ? clean : "device");
    }
    function mtpIsMounted(d) {
        return !!root.mtpMounts[root.mtpMountPoint(d)];
    }
    function parseMtpDevices(text) {
        const mounts = {};
        const refusing = {};
        const devices = [];
        for (const raw of String(text ?? "").split("\n")) {
            const line = raw.trim();
            if (line.startsWith("mounts|")) {
                // mounts|<dir>|<entries>. The count is how "mounted" and
                // "readable" are told apart: an AFT session that was refused
                // storages is a real, empty directory that keeps answering
                // nothing for its whole life, and the shell mounts one of
                // those every time the phone is plugged in before it is
                // unlocked. Read as "mounted", it is a phone the user opens
                // onto an empty folder with nothing said about it.
                const parts = line.split("|");
                const dir = String(parts[1] ?? "").trim();
                if (dir.length === 0) continue;
                // Recorded as mounted EITHER WAY: the mount really is there,
                // and the row that says "mounted, but the phone is not showing"
                // is the one that explains how to fix it. A refusing phone is
                // not "not mounted" -- that is the sentence the person already
                // read before they opened this app.
                mounts[dir] = true;
                if (Number(String(parts[2] ?? "-1")) <= 0) refusing[dir] = true;
                continue;
            }
            if (!line.startsWith("dev|")) continue;
            const f = line.split("|");
            if (f.length < 6) continue;
            devices.push({
                name: f[1],
                vendor: f[2],
                productId: f[3],
                manufacturer: f[4],
                product: f[5]
            });
        }
        root.mtpMounts = mounts;
        root.mtpDevices = devices;
        // One record per device, shaped like a volume -- because that is what
        // the list, the menu and the navigation pane already know how to draw.
        // `path` is deliberately NOT a /dev path: nothing may hand this to
        // `mount`, and a key that looks like a device would invite exactly that.
        const vols = devices.map(d => ({
            name: d.name,
            path: "mtp:" + d.name,
            disk: "",
            label: root.mtpLabel(d),
            uuid: "",
            fstype: "mtp",
            hasFs: true,
            readOnly: false,
            size: 0,
            tran: "usb",
            removable: true,
            rotational: false,
            external: true,
            kind: "mtp",
            icon: root.iconForDrive("mtp"),
            model: String(d.manufacturer ?? ""),
            mountpoint: root.mtpIsMounted(d) ? root.mtpMountPoint(d) : "",
            mtp: d
        }));
        root.pruneMtpState(vols);
        root.mtpVolumes = vols;
        root.applyVolumes();
        // And the half this app never used to ask: a phone that is ALREADY
        // mounted was taken as a phone that is open. It is not -- the shell
        // auto-mounts the moment the USB event arrives, which is before the
        // phone has been unlocked or its "allow access to phone data" prompt
        // has been answered, and that session stays empty for good. So every
        // MOUNTED phone is asked what it lists, here, whoever put it up.
        //
        // The answer comes out of the scan itself (mounts|<dir>|<entries>), so
        // asking costs no second look at the phone: >0 answers, 0 is a live
        // session the phone refused storages for, -1 did not answer at all.
        // Either way the state is written down, and the row and the retry
        // handle it -- which is what makes the silent-mount handling below
        // reachable for a phone THIS APP did not mount.
        for (const d of devices) {
            const dir = root.mtpMountPoint(d);
            if (!root.mtpMounts[dir]) continue;
            if (refusing[dir]) {
                root.markMtpSilent(dir);
                root.statusNote = root.mtpUnlockHint(d);
                root.scheduleMtpRetry(d);
            } else {
                root.markMtpAnswering(dir);
            }
        }
    }
    // Mounting is the whole point, so the two failure modes are answered in
    // words instead of a blank folder:
    //
    //   * no mounter installed -- say which package provides it, because
    //     "nothing happened" is the report this feature exists to end;
    //   * mounted but EMPTY -- which is not a failure of this app at all. When
    //     a phone has not been unlocked, or the "allow access to phone data"
    //     prompt on its screen has not been answered, MTP answers with no
    //     storages and the mount is a legitimately empty directory. That state
    //     is said out loud, with the two things that fix it.
    function mountMtp(d) {
        if (!d) return;
        const dir = root.mtpMountPoint(d);
        // Asking for the device again is asking for a fresh session, so the
        // retry budget is renewed here -- and only here, by a person.
        const retried = Object.assign({}, root.mtpRetried);
        delete retried[dir];
        root.mtpRetried = retried;
        root.statusNote = Translation.tr("Opening") + " " + root.mtpLabel(d) + "…";
        root.sh("command -v aft-mtp-mount >/dev/null 2>&1 || { "
            + "echo 'aft-mtp-mount is not installed (pacman -S android-file-transfer)'; exit 127; }; "
            + "mkdir -p " + root.shq(dir)
            + " && aft-mtp-mount " + root.shq(dir) + " 2>&1",
            "mtp-mount", d.name);
    }
    function unmountMtp(d) {
        if (!d) return;
        const dir = root.mtpMountPoint(d);
        root.statusNote = Translation.tr("Ejecting") + " " + root.mtpLabel(d) + "…";
        root.sh("fusermount3 -u " + root.shq(dir) + " 2>&1 || fusermount -u " + root.shq(dir)
            + " 2>&1 || umount " + root.shq(dir) + " 2>&1", "mtp-unmount", d.name);
    }
    // Is the phone actually showing its files? Asked of the mount itself, which
    // is the only honest source: an MTP mount that has been refused access looks
    // exactly like an empty card.
    //
    // `walkIn` is the difference between the two callers, and it is not
    // cosmetic: the Mount action and the row click want to end up INSIDE the
    // phone (mounting a device and staying where you were reads as the button
    // doing nothing), while a scan -- which runs on every USB event -- must
    // never move the folder the person is looking at. A phone plugged in by
    // somebody else is not a request to open it.
    // The scan, fed by hand (scripts/system/files-check.sh).
    //
    // The silent-mount state has to be checkable on a machine whose phone
    // answers willingly, and a phone that refuses is not something a script can
    // arrange -- it is the phone's own permission that decides. So the scan is
    // given its input directly, which is the same thing the shell reads off the
    // bus, pipe separated, one record per line:
    //
    //     mounts|<mount point>|<entries>      dev|<usb>|<vid>|<pid>|<maker>|<product>
    //
    // The next real scan overwrites whatever this writes, exactly as it would
    // for a replug.
    function probeMtpFeed(text) {
        root.parseMtpDevices(String(text ?? ""));
        const first = root.mtpVolumes.length > 0 ? root.mtpVolumes[0] : null;
        return JSON.stringify({
            mounted: Object.keys(root.mtpMounts),
            silent: Object.keys(root.mtpEmpty),
            retried: root.mtpRetried,
            retryLimit: root.mtpRetryLimit,
            hint: root.mtpUnlockHint(first ? first.mtp : null),
            rowMountPoint: first ? first.mountpoint : "",
            rowSilent: first ? root.mtpSilent(first.mountpoint) : null,
            devices: root.mtpVolumes.length
        });
    }
    function checkMtpContents(d, walkIn) {
        const dir = root.mtpMountPoint(d);
        root.sh("ls -A " + root.shq(dir) + " 2>/dev/null | head -n 1",
            walkIn ? "mtp-contents" : "mtp-contents-quiet", dir);
    }
    function mtpActionWord(v) {
        return (v && v.mountpoint.length > 0) ? Translation.tr("Eject") : Translation.tr("Mount");
    }
    // ── A phone that mounted but answers with nothing ───────────────────
    function mtpSilent(dir) {
        return !!root.mtpEmpty[String(dir ?? "")];
    }
    function mtpDeviceByMount(dir) {
        const at = String(dir ?? "");
        for (const v of root.mtpVolumes) {
            if (v.mountpoint === at) return v.mtp;
        }
        return null;
    }
    function markMtpSilent(dir) {
        const at = String(dir ?? "");
        if (at.length === 0 || root.mtpEmpty[at]) return;
        root.mtpEmpty = Object.assign({}, root.mtpEmpty, { [at]: true });
        // Said out loud, once: the status line is easy to miss, and a phone
        // that lists nothing reads as the file manager being broken rather
        // than as the phone withholding its storage.
        root.notify(Translation.tr("Phone is not answering"),
            root.mtpUnlockHint(root.mtpDeviceByMount(at)), true);
    }
    function markMtpAnswering(dir) {
        const at = String(dir ?? "");
        if (!root.mtpEmpty[at]) return;
        const next = Object.assign({}, root.mtpEmpty);
        delete next[at];
        root.mtpEmpty = next;
    }
    // The retry is a FRESH MTP session, not another listing of the same one: an
    // AFT mount that was refused storages keeps answering "nothing" for the
    // life of that session even after the phone has been unlocked. So the
    // mount is taken down and put back up, which is the only thing that picks
    // up a permission granted late.
    function remountMtp(d) {
        if (!d) return;
        const dir = root.mtpMountPoint(d);
        root.statusNote = Translation.tr("Looking again for") + " " + root.mtpLabel(d) + "…";
        // The take-down has TWO halves, and the second one is not tidiness.
        // Unmounting normally takes the FUSE process with it; when it does not,
        // that leftover keeps the phone's single MTP interface claimed, and the
        // mount that follows can claim nothing and comes up as another empty
        // directory -- measured on this machine as libusb_claim_interface()
        // reporting "device is busy" while aft-mtp-mount still exited 0. That is
        // how a retry fails silently and the phone stays empty forever.
        root.sh("fusermount3 -u " + root.shq(dir) + " >/dev/null 2>&1 || fusermount -u "
            + root.shq(dir) + " >/dev/null 2>&1 || umount " + root.shq(dir) + " >/dev/null 2>&1; "
            + "pkill -x -f " + root.shq("aft-mtp-mount " + dir) + " >/dev/null 2>&1; "
            + "sleep 1; mkdir -p " + root.shq(dir) + " && aft-mtp-mount " + root.shq(dir) + " 2>&1",
            "mtp-mount", d.name);
    }
    // A few automatic tries, spaced, after a silent answer: the hand that plugs
    // a phone in unlocks it right after, and the tap on the phone's own prompt
    // lands seconds later. One try was too few for that -- the phone shows the
    // prompt, the person reads it, and the attempt has already come and gone --
    // while a budget of three covers the half-minute it actually takes and still
    // stops. A person pressing Mount or the row again renews it.
    readonly property int mtpRetryLimit: 3
    function scheduleMtpRetry(d) {
        if (!d) return;
        const dir = root.mtpMountPoint(d);
        const made = Number(root.mtpRetried[dir] ?? 0);
        if (made >= root.mtpRetryLimit) return;
        root.mtpRetried = Object.assign({}, root.mtpRetried, { [dir]: made + 1 });
        mtpRetryTimer.dir = dir;
        // Spaced further apart each time: the first is for the prompt that is
        // on screen right now, the last is for a phone that was picked up and
        // unlocked well after the cable went in.
        mtpRetryTimer.interval = 4000 + made * 5000;
        mtpRetryTimer.restart();
    }
    Timer {
        id: mtpRetryTimer
        interval: 4000
        property string dir: ""
        onTriggered: {
            if (!root.mtpSilent(mtpRetryTimer.dir)) return;
            const d = root.mtpDeviceByMount(mtpRetryTimer.dir);
            if (d) root.remountMtp(d);
        }
    }
    // A device that has left the bus takes its state with it, so unplugging a
    // phone and plugging it back in is a clean slate rather than a remembered
    // complaint. Pruned on every scan, which is the one place the bus is read.
    function pruneMtpState(vols) {
        const live = {};
        for (const v of vols) {
            if (v.mountpoint.length > 0) live[v.mountpoint] = true;
        }
        const keep = map => {
            const next = {};
            for (const k in map) {
                if (live[k]) next[k] = map[k];
            }
            return next;
        };
        root.mtpEmpty = keep(root.mtpEmpty);
        root.mtpRetried = keep(root.mtpRetried);
    }
    // The unlock hint, written once, in the two places that show it (the status
    // bar after a mount, and the empty listing of a mounted-but-silent phone).
    function mtpUnlockHint(d) {
        return Translation.tr("Unlock the phone and tap Allow file access, then open it again")
            + (d ? " (" + root.mtpLabel(d) + ")" : "");
    }

    // ═══ Drive actions: what a drive's own menu offers ══════════════════
    //
    // On Windows a drive's right-click menu is Open, Eject, Rename, Change
    // drive letter, Properties, Check, Optimise, Format. Linux splits that
    // across different tools and most of them need root, so every action here
    // is ONE command line (volumeActionCommand) run through the shell's own
    // polkit prompt -- and building the command separately from running it is
    // what makes the whole set checkable without root and without touching
    // anybody's data (scripts/system/files-check.sh asserts the strings;
    // `dryRun` is how it does that).
    //
    // They apply to EVERY drive the app lists, internal ones included: an SSD
    // holding a Windows install is a drive you may just as well want to check,
    // rename or optimise as a stick.
    property bool dryRun: false
    property string lastVolumeCommand: ""
    property string lastVolumeAction: ""

    // ── Drive letters, in the only form Linux has ───────────────────────
    // Windows gives a volume a LETTER; here the equivalent is where it is
    // mounted, which this app already derives from the label. This is the
    // per-volume override: pick a name once and every later mount uses it.
    // Keyed by UUID, because the label is exactly the thing you may change.
    //
    // Plain JSON under the shell's state directory. It cannot live in the
    // shell's Persistent state: this app is its own process, and two writers on
    // one file means the last writer wins.
    readonly property string mountNamesPath: `${Quickshell.env("HOME")}/.local/state/quickshell/files-mount-names.json`
    property var mountNames: ({})
    // Read through a shell rather than a FileView: the file legitimately does
    // not exist until the first drive letter is chosen, and a FileView that
    // reads a missing path logs a scene warning on every launch. `cat` failing
    // is simply an empty string.
    function loadMountNames() {
        root.sh("cat " + root.shq(root.mountNamesPath) + " 2>/dev/null", "mount-names");
    }
    function parseMountNames(text) {
        const body = String(text ?? "").trim();
        if (body.length === 0) return;
        try {
            const parsed = JSON.parse(body);
            if (parsed && typeof parsed === "object")
                root.mountNames = parsed;
        } catch (e) {
            console.log("[files] mount names not readable, starting empty:", e);
        }
    }
    Process {
        id: mountNamesWriter
        command: []
    }
    function saveMountNames() {
        const path = CF.FileUtils.trimFileProtocol(root.mountNamesPath);
        const payload = JSON.stringify(root.mountNames);
        mountNamesWriter.command = ["bash", "-c",
            `mkdir -p '${path.split("/").slice(0, -1).join("/")}'`
            + ` && printf '%s' '${payload.replace(/'/g, `'\\''`)}' > '${path}'`];
        mountNamesWriter.running = false;
        mountNamesWriter.running = true;
    }
    function mountNameOf(v) { return v ? root.mountNameFor(v) : ""; }
    function setMountName(v, name) {
        if (!v) return "";
        const key = String(v.uuid ?? "");
        const clean = String(name ?? "").trim().replace(/[^\w.-]+/g, "_");
        if (key.length === 0) {
            root.statusNote = Translation.tr("This volume has no UUID to remember a name by.");
            return "";
        }
        if (clean.length === 0) {
            // Empty means "back to the label", which is the default state.
            const next = Object.assign({}, root.mountNames);
            delete next[key];
            root.mountNames = next;
        } else {
            root.mountNames = Object.assign({}, root.mountNames, { [key]: clean });
        }
        root.saveMountNames();
        const mounted = v.mountpoint.length > 0;
        root.statusNote = Translation.tr("Drive letter") + ": " + root.mountNameFor(v)
            + (mounted ? " — " + Translation.tr("takes effect the next time you mount it") : "");
        root.refreshVolumes();
        return clean;
    }

    // ── Which filesystem can do which ───────────────────────────────────
    // A label tool, per filesystem. Empty means "this format cannot be
    // relabelled from here", and the action is offered disabled rather than
    // failing after the fact.
    function labelToolFor(fs) {
        switch (String(fs ?? "").toLowerCase()) {
        case "exfat": return "exfatlabel";
        case "vfat": case "fat": case "fat32": case "msdos": return "fatlabel";
        case "ntfs": case "ntfs3": case "fuseblk": return "ntfslabel";
        case "ext2": case "ext3": case "ext4": return "e2label";
        case "btrfs": return "btrfs filesystem label";
        default: return "";
        }
    }
    function canRelabel(v) { return !!v && root.labelToolFor(v.fstype).length > 0; }
    // Formatting writes a new filesystem, so it is offered only for a volume
    // that is NOT mounted (mkfs on a mounted filesystem is a data-loss race) and
    // only for the formats the tools here can make.
    function formatToolFor(fs) {
        switch (String(fs ?? "").toLowerCase()) {
        case "exfat": return "mkfs.exfat";
        case "vfat": case "fat": case "fat32": return "mkfs.vfat";
        case "ntfs": case "ntfs3": case "fuseblk": return "mkfs.ntfs";
        case "ext4": return "mkfs.ext4";
        default: return "";
        }
    }
    function canFormat(v) {
        if (!v || v.mountpoint.length > 0 || v.hasFs === false) return false;
        return root.formatToolFor(v.fstype).length > 0;
    }
    function volumeActionLabel(action) {
        switch (action) {
        case "label": return Translation.tr("Renaming");
        case "format": return Translation.tr("Formatting");
        case "check": return Translation.tr("Checking");
        case "trim": return Translation.tr("Optimising");
        case "remount-ro": case "remount-rw": return Translation.tr("Remounting");
        default: return Translation.tr("Working on");
        }
    }

    // Every drive action, as the command line it would run. An empty string
    // means "this action does not apply to this volume" -- the same test the
    // menu's `enabled` uses, so a disabled row can never fire something
    // unexpected.
    function volumeActionCommand(action, v, arg) {
        if (!v) return "";
        // Nothing in this list applies to a phone: no label tool for MTP, no
        // mkfs, no fsck, no TRIM, no remount. An empty string is how the menu
        // already says "this action does not apply", so the drive menu can
        // share the test rather than special-case the device.
        if (v.kind === "mtp") return "";
        const dev = root.shq(v.path);
        const name = String(arg ?? "");
        switch (action) {
        case "label": {
            const tool = root.labelToolFor(v.fstype);
            if (tool.length === 0 || name.length === 0) return "";
            if (tool === "btrfs filesystem label")
                return "pkexec btrfs filesystem label " + dev + " " + root.shq(name) + " 2>&1";
            return "pkexec " + tool + " " + dev + " " + root.shq(name) + " 2>&1";
        }
        case "format": {
            const tool = root.formatToolFor(v.fstype);
            if (tool.length === 0 || v.mountpoint.length > 0) return "";
            const flag = (tool === "mkfs.vfat" || tool === "mkfs.exfat") ? " -n " : " -L ";
            const label = name.length > 0 ? flag + root.shq(name) : "";
            return "pkexec " + tool + label + " " + dev + " 2>&1";
        }
        case "check":
            // -n never writes: a check that repairs without asking is a check
            // nobody asked for. Mounted volumes are excluded (fsck refuses, and
            // a live filesystem can change underneath it).
            if (v.mountpoint.length > 0 || v.hasFs === false) return "";
            return "pkexec fsck -n " + dev + " 2>&1";
        case "trim":
            if (v.mountpoint.length === 0) return "";
            return "pkexec fstrim -v " + root.shq(v.mountpoint) + " 2>&1";
        case "remount-ro":
            if (v.mountpoint.length === 0) return "";
            return "pkexec mount -o remount,ro " + root.shq(v.mountpoint) + " 2>&1";
        case "remount-rw":
            if (v.mountpoint.length === 0) return "";
            return "pkexec mount -o remount,rw " + root.shq(v.mountpoint) + " 2>&1";
        default:
            return "";
        }
    }
    function runVolumeAction(action, v, arg) {
        if (!v) return "";
        const cmd = root.volumeActionCommand(action, v, arg);
        root.lastVolumeAction = action;
        root.lastVolumeCommand = cmd;
        if (cmd.length === 0) {
            root.statusNote = Translation.tr("That action does not apply to this drive.");
            return "";
        }
        if (root.dryRun) return cmd;
        root.statusNote = root.volumeActionLabel(action) + " " + root.volumeLabel(v) + "…";
        root.sh(cmd, "volume", v.path);
        return cmd;
    }

    // ── The prompt (label / drive letter / format) ──────────────────────
    // var, not string, for the same reason infoTarget is: "no prompt" has to be
    // distinguishable from "a prompt on an empty device".
    property var volumePromptDevice: null
    // The volume the prompt is about, HELD rather than looked up.
    //
    // The lookup version (volumeByPath on every read) had a race with the
    // refresh: `applyVolumes` replaces the whole list when lsblk answers, and a
    // prompt that happened to be read while a fresh, momentarily-empty list was
    // in place answered "no target" -- so the confirmation's own answer did
    // nothing, silently, which is the worst possible way for a "are you sure?"
    // to fail. A snapshot of the volume cannot go missing underneath the dialog.
    property var volumePromptVolume: null
    property string volumePromptKind: ""       // "label" | "letter" | "format" | "confirm"
    property string volumePromptDraft: ""
    readonly property var volumePromptTarget: root.volumePromptVolume
        ?? (root.volumePromptDevice ? root.volumeByPath(root.volumePromptDevice) : null)
    function volumePromptTitle() {
        switch (root.volumePromptKind) {
        case "label": return Translation.tr("Rename this drive");
        case "letter": return Translation.tr("Change drive letter");
        case "format": return Translation.tr("Format this drive");
        case "confirm":
            return root.volumeRemoval(root.volumePromptTarget) === "eject"
                ? Translation.tr("Eject this drive?")
                : Translation.tr("Unmount this drive?");
        default: return "";
        }
    }
    function volumePromptHint() {
        const v = root.volumePromptTarget;
        switch (root.volumePromptKind) {
        case "label":
            return Translation.tr("The name the drive carries, e.g. BACKUP. This rewrites the filesystem's label.");
        case "letter":
            return Translation.tr("This desktop has no letters: a drive's \"letter\" is where it is mounted (/run/media/%1/…). Type the name to use.").arg(root.userName);
        case "format":
            return Translation.tr("This ERASES everything on %1 and makes a new %2 filesystem. Type the drive's name (%3) to confirm.")
                .arg(root.volumeLabel(v ?? {}).length > 0 ? root.volumeLabel(v) : String(v?.name ?? ""))
                .arg(String(v?.fstype ?? "").toUpperCase())
                .arg(root.volumeLabel(v ?? {}).length > 0 ? root.volumeLabel(v) : String(v?.name ?? ""));
        case "confirm":
            if (root.volumeRemoval(v) === "eject")
                return Translation.tr("Its filesystems are closed, and once this finishes it is safe to unplug. Nothing on it is written or removed.");
            return Translation.tr("It stays exactly where it is; only its filesystems are closed. Anything still reading it will lose access.");
        default:
            return "";
        }
    }
    function openVolumePrompt(kind, v) {
        if (!v) return;
        // A fresh prompt has no last command: the code that reports what a
        // prompt DID reads this, and a stale line from the previous action is
        // how a check ends up asserting on the wrong command.
        root.lastVolumeCommand = "";
        root.lastVolumeAction = "";
        root.volumePromptKind = kind;
        root.volumePromptDevice = v.path;
        root.volumePromptVolume = v;
        root.volumePromptDraft = kind === "letter" ? root.mountNameFor(v)
            : (kind === "label" ? v.label : "");
        Qt.callLater(() => { volumePromptField.forceActiveFocus(); volumePromptField.selectAll(); });
    }
    function closeVolumePrompt() {
        root.volumePromptKind = "";
        root.volumePromptDevice = null;
        root.volumePromptVolume = null;
        root.volumePromptDraft = "";
        if (keyLayer)
            keyLayer.forceActiveFocus();
    }
    // The typed answer, from outside the dialog as well as from its own button:
    // the field is the source of truth for what was typed (that is where a
    // keyboard put it), so anything driving the prompt has to fill it in.
    function answerVolumePrompt(value) {
        volumePromptField.text = String(value ?? "");
        root.volumePromptDraft = String(value ?? "");
        root.commitVolumePrompt();
    }
    function commitVolumePrompt() {
        const v = root.volumePromptTarget;
        const kind = root.volumePromptKind;
        const value = String(volumePromptField.text ?? "").trim();
        if (!v || kind.length === 0) { root.closeVolumePrompt(); return; }
        if (kind === "confirm") {
            // Nothing is typed here: the answer is the button. What the answer
            // WILL run is recorded either way, so a check can read the decision
            // (probeDrivePromptCommitDry) instead of making it.
            root.lastVolumeAction = "unmount";
            root.lastVolumeCommand = root.volumeUnmountCommand(v);
            root.closeVolumePrompt();
            if (root.dryRun) return;
            root.unmountVolume(v);
            return;
        }
        if (kind === "letter") {
            root.setMountName(v, value);
            root.closeVolumePrompt();
            return;
        }
        if (kind === "format") {
            // The typed confirmation is the whole guard: the word that has to be
            // typed is the drive's own name, which nobody types by accident.
            const expect = root.volumeLabel(v).length > 0 ? root.volumeLabel(v) : String(v.name ?? "");
            if (value !== expect) {
                root.statusNote = Translation.tr("Not formatted: type the drive's name exactly to confirm.");
                return;
            }
            root.closeVolumePrompt();
            root.runVolumeAction("format", v, v.label);
            return;
        }
        if (kind === "label") {
            if (value.length === 0) { root.closeVolumePrompt(); return; }
            root.closeVolumePrompt();
            root.runVolumeAction("label", v, value);
        }
    }
    // What the drive menu will offer for this volume, in order -- read by the
    // check suite so the menu's contents are asserted, not assumed.
    function volumeActionIds(v) {
        return root.deviceMenu(v).filter(i => i.separator !== true).map(i => i.id + (i.enabled ? "" : "(disabled)"));
    }

    // ── File operations ─────────────────────────────────────────────────
    // A name nothing else in this folder has yet: "New folder (2)", the way
    // Explorer counts, rather than "New folder 2".
    function uniqueName(dir, base) {
        let candidate = base, n = 2;
        while (root.nameExistsInFolder(candidate))
            candidate = base + " (" + (n++) + ")";
        return dir + "/" + candidate;
    }
    // Creating something while a search is active would otherwise drop it out
    // of the list the moment it appears; the filter steps aside for a create,
    // which is what Explorer does too.
    function clearFilterForCreate() {
        if (root.filter.length > 0) {
            root.filter = "";
            searchInput.text = "";
        }
    }
    // New file and New folder both ASK for the name first, in the same dialog
    // Rename uses, with the draft "New file.txt" or "New folder" selected whole.
    //
    // The name used to be the app's -- "New file.txt" was created on the spot,
    // with no way to type one, and no way to choose an EXTENSION at all. A name
    // the app picks for you is not a name; it is a placeholder you then have to
    // rename. Asked first, nothing is created unless it is wanted, and the file
    // is born with the name (and the extension) it was typed with.
    function newFolder() {
        root.beginCreate("folder");
    }
    function newFile() {
        root.beginCreate("file");
    }
    // What a typed name is allowed to be, before the filesystem is touched: a
    // slash is not a name (it is a path), the ends are trimmed, and an empty
    // string is a cancel. A leading dot is left alone -- ".env" is a file
    // people make on purpose.
    function cleanCreateName(name) {
        return String(name ?? "").trim().replace(/^\/+|\/+$/g, "");
    }
    function createNamed(kind, name) {
        const clean = root.cleanCreateName(name);
        if (clean.length === 0 || clean.indexOf("/") !== -1) {
            root.notify(Translation.tr("Could not create it"),
                Translation.tr("A name cannot be empty or contain a slash."), true);
            return;
        }
        if (root.nameExistsInFolder(clean)) {
            root.notify(Translation.tr("Could not create it"),
                Translation.tr("A file or folder with that name already exists."), true);
            return;
        }
        const target = root.currentFolderPath() + "/" + clean;
        // `gio mkdir` for the folder; plain `touch` for the file, because gio
        // has no `touch` command at all. `gio touch` printed its own usage and
        // exited 1, and that exit code was thrown away -- which is exactly why
        // "New file" did nothing whatsoever, however the name was chosen.
        if (kind === "folder")
            root.sh("gio mkdir " + root.shq(target) + " 2>&1", "mkdir", target);
        else
            root.sh("touch -- " + root.shq(target) + " 2>&1", "touch", target);
    }
    function nameExistsInFolder(name) {
        for (let i = 0; i < folderModel.count; i++)
            if (String(folderModel.get(i, "fileName")) === String(name))
                return true;
        return false;
    }
    function renameItem(p, name) {
        if (!p || !name) return;
        const clean = String(name).trim();
        if (clean.length === 0 || clean.indexOf("/") !== -1 || clean === root.baseName(p))
            return;
        // Renaming onto a name that is taken would silently replace a file.
        // Explorer asks; asking costs a dialog this app does not have, so it
        // refuses and says why instead -- the one behaviour here that favours
        // not losing data over imitating Windows.
        if (root.nameExistsInFolder(clean)) {
            root.notify(Translation.tr("Could not rename"),
                Translation.tr("A file or folder with that name already exists."));
            return;
        }
        root.sh("gio move " + root.shq(p) + " " + root.shq(root.dirName(p) + "/" + clean) + " 2>&1",
            "rename", p);
    }
    function trashItems(paths) {
        const list = (paths && paths.length ? paths : root.selection).slice();
        if (list.length === 0) return;
        root.sh(list.map(p => "gio trash " + root.shq(p)).join("; ") + " 2>&1",
            "trash", list.join("\n"));
    }
    function deleteItems(paths) {
        const list = (paths && paths.length ? paths : root.selection).slice();
        if (list.length === 0) return;
        root.sh(list.map(p => "rm -rf -- " + root.shq(p)).join("; ") + " 2>&1",
            "delete", list.join("\n"));
    }
    function copyPath(p) {
        // An array is a multi-selection: several paths, one per line --
        // Explorer's "Copy as path". A string or nothing is the one path or
        // the folder itself, exactly as before.
        const body = Array.isArray(p) ? p.join("\n")
            : String(p || root.currentFolderPath());
        root.sh("printf %s " + root.shq(body) + " | wl-copy");
    }
    function openInTerminal(p) {
        const dir = (!p || p.length === 0)
            ? root.currentFolderPath()
            : (root.isDirPath(p) ? p : root.dirName(p));
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/launch/open.sh"),
            "Terminal", "kitty --directory " + root.shq(dir)]);
    }
    function showInfo(p) {
        const target = String(p ?? root.currentFolderPath());
        root.infoTarget = target;
        root.infoText = Translation.tr("Reading") + "…";
        // A DRIVE's Properties is this same dialog, filled from the device
        // instead of from stat(2). Recognizing it by looking the path up in the
        // volume list is what lets "Properties" mean the same thing whether the
        // drive is mounted or sitting there unmounted with no filesystem yet.
        const vol = root.volumeByPath(target);
        if (vol) {
            root.sh(root.driveInfoCommand(vol), "drive-info", target);
            return;
        }
        // `stat` for the metadata every file has; `du` only for a folder,
        // because it walks the tree and is not something to run per file.
        root.sh("p=" + root.shq(target) + "; "
            + "stat -c '%n|%F|%s|%y|%A|%U:%G' \"$p\" 2>/dev/null; "
            + "if [ -d \"$p\" ]; then du -sh \"$p\" 2>/dev/null | cut -f1 | sed 's/^/size|/'; fi",
            "info", target);
    }
    // The facts a drive's Properties page shows, asked of the kernel rather than
    // guessed from lsblk's earlier pass: partition size, whether it is writable,
    // whether it is spinning rust or flash (that is what decides whether
    // "Optimise" is a TRIM or a defragment), the discard granularity that says
    // whether the drive supports it at all, its filesystem/label/UUID, the disk
    // it lives on, and how it is currently mounted (read-only options included).
    //
    // `-P` (key="value" pairs) rather than columns: a label or a mount option
    // contains spaces and commas, and a column parser gets those wrong in
    // silence. There is no smartctl here: SMART needs a root-owned device and
    // the tool installed, so the health line says what is missing instead.
    function driveInfoCommand(v) {
        const dev = root.shq(v.path);
        const disk = root.shq(v.disk);
        return `dev=${dev}; disk=${disk}; `
            + `lsblk -b -dn -P -o NAME,SIZE,RO,ROTA,FSTYPE,LABEL,UUID,PTTYPE,PARTTYPE "$dev" 2>/dev/null | sed 's/^/blk|/'; `
            + `lsblk -b -dn -P -o DISC-GRAN,DISC-MAX "$dev" 2>/dev/null | sed 's/^/dsc|/'; `
            + `lsblk -d -nP -o NAME,SIZE,VENDOR,MODEL,SERIAL,TRAN,ROTA "$disk" 2>/dev/null | sed 's/^/dsk|/'; `
            + `findmnt -P -o SOURCE,TARGET,FSTYPE,OPTIONS -S "$dev" 2>/dev/null | sed 's/^/mnt|/'; `
            + `df -B1 --output=size,used,avail,pcent "$dev" 2>/dev/null | tail -n +2 | sed 's/^/use|/'; `
            + `command -v smartctl >/dev/null 2>&1 && echo 'smt|present' || echo 'smt|missing'`;
    }
    // `KEY="value"` pairs, tagged by which question they answer.
    function parseDriveInfo(text) {
        const blk = {}, dsc = {}, dsk = {}, mnt = {};
        let used = "";
        for (const line of String(text ?? "").split("\n")) {
            const trimmed = line.trim();
            const bar = trimmed.indexOf("|");
            if (bar < 0) continue;
            const tag = trimmed.slice(0, bar);
            const rest = trimmed.slice(bar + 1);
            if (tag === "use") { used = rest; continue; }
            const obj = {};
            const re = /([A-Z][A-Z-]*)="([^"]*)"/g;
            let m;
            while ((m = re.exec(rest)) !== null) obj[m[1]] = m[2];
            if (tag === "blk") Object.assign(blk, obj);
            else if (tag === "dsc") Object.assign(dsc, obj);
            else if (tag === "dsk") Object.assign(dsk, obj);
            else if (tag === "mnt") Object.assign(mnt, obj);
        }
        const out = [];
        const push = (key, value) => {
            if (value === undefined || value === null || String(value).length === 0) return;
            out.push(Translation.tr(key) + ": " + value);
        };
        push("Device", blk.NAME ?? root.infoTarget);
        const bytes = Number(blk.SIZE ?? 0);
        if (bytes > 0) push("Capacity", root.fmtCapacity(bytes) + " (" + root.fmtSize(bytes, false) + ")");
        if (used.length > 0) {
            const f = used.trim().split(/\s+/);
            if (f.length >= 4) push("Used", root.fmtCapacity(Number(f[1])) + " / " + f[3]);
        }
        push("Filesystem", blk.FSTYPE);
        push("Label", blk.LABEL);
        push("UUID", blk.UUID);
        push("Partition table", blk.PTTYPE ? blk.PTTYPE.toUpperCase() : "");
        push("Read-only", blk.RO === "1" ? Translation.tr("yes") : Translation.tr("no"));
        // The rot/blk fields are what "Optimise" hangs on: flash says TRIM,
        // spinning rust says defragment -- which is a job for another tool, so
        // the line is honest about which one this drive is.
        const flash = Number(dsk.ROTA ?? blk.ROTA ?? 1) === 0;
        push("Drive type", flash ? Translation.tr("solid-state") : Translation.tr("mechanical"));
        const gran = String(dsc["DISC-GRAN"] ?? "");
        if (gran.length > 0)
            push("TRIM support", /^0B?$/.test(gran) ? Translation.tr("no") : Translation.tr("yes") + " (" + gran + ")");
        push("Disk", dsk.NAME ? "/dev/" + dsk.NAME : "");
        push("Maker", [dsk.VENDOR, dsk.MODEL].filter(s => s && s.trim().length > 0).join(" ").trim());
        push("Serial", dsk.SERIAL);
        push("Connection", dsk.TRAN ? dsk.TRAN.toUpperCase() : (root.volumeByPath(root.infoTarget)?.tran ?? "").toUpperCase());
        if (mnt.TARGET) {
            push("Mounted at", mnt.TARGET);
            push("Mount options", mnt.OPTIONS);
        } else if (blk.FSTYPE) {
            push("Mounted at", Translation.tr("not mounted"));
        }
        // The "drive letter" that will be used the NEXT time it is mounted,
        // and where a Windows-style letter would point.
        const vol = root.volumeByPath(root.infoTarget);
        if (vol) {
            push("Drive name", root.mountNameFor(vol));
            push("Mount path", root.mountPointFor(vol));
            if (!root.canRelabel(vol)) out.push(Translation.tr("Renaming") + ": " + Translation.tr("this filesystem cannot be relabelled from here") + " (" + (vol.fstype || "—") + ")");
        }
        const smart = String(text ?? "").includes("smt|present");
        push("Health", smart ? Translation.tr("run smartctl for SMART health") : Translation.tr("smartmontools not installed"));
        root.infoText = out.join("\n");
    }
    function parseInfo(text) {
        const lines = String(text ?? "").split("\n").filter(l => l.length > 0);
        if (lines.length === 0) {
            root.infoText = Translation.tr("No information");
            return;
        }
        let out = "";
        for (const line of lines) {
            const f = line.split("|");
            if (f.length < 6) {
                if (f.length >= 2)
                    out += Translation.tr("Size on disk") + ": " + f[1] + "\n";
                continue;
            }
            out += Translation.tr("Name") + ": " + f[0] + "\n";
            out += Translation.tr("Type") + ": " + f[1] + "\n";
            out += Translation.tr("Size") + ": " + root.fmtSize(f[2], false) + "\n";
            out += Translation.tr("Modified") + ": " + f[3] + "\n";
            out += Translation.tr("Permissions") + ": " + f[4] + "\n";
            out += Translation.tr("Owner") + ": " + f[5] + "\n";
        }
        out += Translation.tr("Location") + ": " + root.dirName(root.infoTarget ?? "") + "\n";
        root.infoText = out;
    }

    // ── Previews ────────────────────────────────────────────────────────
    //
    // Two separate answers to "show me the file", because they are two
    // different questions:
    //
    //   the pane   one file, big, while you walk the list -- a preview pane on
    //              the right edge, opened from the View menu or Ctrl+P. It shows
    //              images (through the shell's thumbnail cache, so a 40 MP photo
    //              is not decoded at full size to fit 300 px), the first page of
    //              a PDF, the first few KB of a text file, and for everything
    //              else an honest card saying what it is.
    //   the tiles  every file in the folder at once: large tiles draw the image
    //              itself instead of a generic picture icon.
    //
    // Neither of them OPENS anything. A preview is a look, not a launch, and the
    // app's contract -- double-click opens -- stays exactly where it was.
    property bool previewPane: false
    // Large tiles with real pictures. On by default, because "tiles show the
    // image instead of the placeholder icon" is the whole point of a tile; the
    // switch exists for folders of thousands of photos, where generating them
    // all is work nobody asked for.
    property bool tilePreviews: true
    // What the pane is currently looking at, when exactly one row is selected.
    readonly property var previewEntry: {
        if (root.selection.length !== 1) return null;
        const i = root.indexOfPath(root.selection[0]);
        return i >= 0 ? root.rows[i] : null;
    }
    readonly property string previewEntryPath: root.previewEntry ? root.previewEntry.path : ""
    readonly property string previewKind: root.previewKindFor(root.previewEntry)
    property string previewText: ""
    property string previewPage: ""      // a rendered PDF page, as a file URI
    property string previewNote: ""      // folder counts, "too large", "no preview"
    // ── What the pane is DRAWING ────────────────────────────────────────
    //
    // `previewKind` is the classification (and what the row was flagged with);
    // `previewView` is the shape of the answer -- image, video, pdf, text,
    // table, list, audio, folder. They are the same thing for most files, and
    // deliberately not for the ones whose answer depends on the CONTENT: an
    // .xlsx is an "office" file whose preview is a table, a .docx is an office
    // file whose preview is text, and a .bin may be either. So the helper
    // decides the view and the pane draws it, rather than the extension doing
    // the deciding twice.
    property string previewView: ""
    property var previewTable: ({ header: [], rows: [], totalRows: 0, totalCols: 0 })
    property var previewEntries: []
    function emptyPreviewTable() {
        return ({ header: [], rows: [], totalRows: 0, totalCols: 0 });
    }
    function previewKindFor(e) {
        if (!e) return "";
        if (e.isDir) return "folder";
        const s = root.suffixOf(e.name);
        if (root.imageExts.indexOf(s) !== -1) return "image";
        if (s === "pdf") return "pdf";
        if (root.videoExts.indexOf(s) !== -1) return "video";
        if (root.audioExts.indexOf(s) !== -1) return "audio";
        // Order matters: json before "text" (both lists contain it, and json
        // has a better answer than its source), markup before text for .html,
        // markdown before text for .md.
        if (root.jsonExts.indexOf(s) !== -1) return "json";
        if (root.tableExts.indexOf(s) !== -1) return "table";
        if (root.markupExts.indexOf(s) !== -1) return "markup";
        if (root.markdownExts.indexOf(s) !== -1) return "markdown";
        if (root.officeExts.indexOf(s) !== -1) return "office";
        if (root.archiveExts.indexOf(s) !== -1) return "archive";
        if (root.textExts.indexOf(s) !== -1) return "text";
        // Anything else is still a file with contents in it. `auto` looks at the
        // BYTES: text behind an odd extension reads as text, and a real binary
        // is named by `file` and shown as hex, which is the only honest preview
        // of it.
        return "auto";
    }
    function previewHeadline() {
        const e = root.previewEntry;
        if (!e) return root.selection.length > 1 ? Translation.tr("Several items selected") : Translation.tr("Nothing selected");
        return root.displayName(e.name, e.isDir);
    }
    function previewSubtitle() {
        const e = root.previewEntry;
        if (!e) return "";
        const parts = [e.kind];
        if (!e.isDir) parts.push(root.fmtSize(e.size, false));
        parts.push(root.fmtTime(e.modified));
        return parts.filter(s => String(s ?? "").length > 0).join(" · ");
    }
    // The words the pane falls back to when there is no picture to draw. One
    // function, used by the pane AND by the IPC probe, so what a check reads is
    // what the user reads -- not a re-implementation of it that can drift.
    function previewBodyText() {
        const e = root.previewEntry;
        // The views that draw their own body say nothing here: an image, a
        // video frame, a rendered page, text, a table or a file list that is
        // on screen does not also need a sentence saying so.
        if (root.previewView === "image" || root.previewView === "video"
            || root.previewView === "pdf" || root.previewView === "text"
            || root.previewView === "table" || root.previewView === "list")
            return "";
        if (!e)
            return root.selection.length > 1
                ? Translation.tr("Several items selected") : Translation.tr("Select one item to preview it");
        // A file whose CONTENTS have to be read is briefly neither: the answer
        // is a fork away. Saying so is better than "no preview" for a third of
        // a second, which is what the words column used to claim about a file
        // it was about to show perfectly well.
        if (root.previewView.length === 0) return Translation.tr("Reading") + "…";
        if (root.previewNote.length > 0) return root.previewNote;
        if (root.previewKindFor(e) === "folder") return Translation.tr("Counting") + "…";
        return Translation.tr("No preview for this kind of file");
    }
    Timer {
        id: previewDebounce
        interval: 140
        onTriggered: root.refreshPreview()
    }
    // Re-asked whenever the SELECTED PATH changes or the pane opens -- not on
    // every keystroke of a walk through the list, which is what the debounce is
    // for (holding Down through 200 rows must not fork 200 processes).
    onPreviewEntryPathChanged: previewDebounce.restart()
    onPreviewPaneChanged: previewDebounce.restart()
    function refreshPreview() {
        root.previewText = "";
        root.previewPage = "";
        root.previewNote = "";
        root.previewView = "";
        root.previewTable = root.emptyPreviewTable();
        root.previewEntries = [];
        if (!root.previewPane || root.pickerMode) return;
        const e = root.previewEntry;
        if (!e) return;
        const kind = root.previewKind;
        // The kinds whose view is the kind: what is drawn needs no decoding, so
        // it can be named here and drawn at once.
        if (kind === "image" || kind === "video" || kind === "pdf"
            || kind === "audio" || kind === "folder" || kind === "text")
            root.previewView = kind;
        if (kind === "image")
            return;   // drawn straight from the file, nothing to ask for
        if (kind === "text") {
            // 4000 bytes, not the whole file: a 2 GB log is not a preview, and
            // `head` stops reading when it has enough.
            root.sh("head -c 4000 -- " + root.shq(e.path) + " 2>/dev/null", "preview-text", e.path);
            return;
        }
        if (kind === "pdf") {
            // Poppler's pdftoppm, into /tmp, keyed by the file's path so walking
            // back and forth does not re-render. Missing tool is answered in
            // words rather than with a blank box.
            const out = "/tmp/qs-files-preview-" + Qt.md5(e.path);
            root.sh("command -v pdftoppm >/dev/null 2>&1 || { echo missing; exit 0; }; "
                + "rm -f " + root.shq(out) + "*.png; "
                + "pdftoppm -png -r 70 -f 1 -l 1 " + root.shq(e.path) + " " + root.shq(out) + " >/dev/null 2>&1; "
                + "ls " + root.shq(out) + "*.png 2>/dev/null | head -1",
                "preview-page", e.path);
            return;
        }
        if (kind === "video" || kind === "audio") {
            // Where ffprobe exists, say how long it is and how big the picture
            // is; where it does not, the card still names the file. The video's
            // PICTURE is not described here -- ThumbnailImage grabs a frame for
            // it -- so these are the facts printed under that frame.
            root.sh("command -v ffprobe >/dev/null 2>&1 || { echo 'ffprobe missing'; exit 0; }; "
                + "ffprobe -v error -show_entries format=duration,bit_rate -show_entries stream=width,height,codec_name "
                + "-of default=noprint_wrappers=1 " + root.shq(e.path) + " 2>&1",
                "preview-media", e.path);
            return;
        }
        if (kind === "folder") {
            const d = root.shq(e.path);
            root.sh("d=" + d + "; printf 'entries|%s\\n' \"$(ls -A \"$d\" 2>/dev/null | wc -l)\"; "
                + "printf 'dirs|%s\\n' \"$(find \"$d\" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)\"; "
                + "du -sh \"$d\" 2>/dev/null | cut -f1 | sed 's/^/size|/'",
                "preview-folder", e.path);
            return;
        }
        // Everything whose contents have to be READ: json, csv/tsv, html, md,
        // office, archives, and whatever an unknown file turns out to be. One
        // helper, one JSON answer, and the view comes back with it.
        root.sh("python3 " + root.shq(Quickshell.shellPath("scripts/system/file-preview.py"))
            + " " + root.shq(kind) + " " + root.shq(e.path),
            "preview-file", e.path);
    }

    // ── Clipboard (Explorer's cut/copy/paste) ───────────────────────────
    //
    // There are TWO clipboards here and they are not the same one.
    //
    // `clipboard` is this app's: a list of paths, which is what makes Paste,
    // Cut and the menu's enabled state work inside the window. On its own it is
    // invisible to every other program, and that was the report: a file copied
    // here could not be pasted into anything else, because nothing had ever
    // been put on the desktop's clipboard at all. Copying a file in a file
    // manager is a claim on the WHOLE desktop -- "here is a file, take it" -- so
    // it is published as text/uri-list, the one format every desktop app (Qt,
    // GTK, browsers, Electron, LibreOffice, chat clients) reads a file paste
    // from. The URI list is written by wl-copy, which stays alive to serve it;
    // that is the clipboard protocol working, not a leak.
    property var clipboard: []            // [{path, cut}]
    // How far a cut item's icon and title are faded until its paste. Half: the
    // choice is made and still undoable (copy something else, or paste it
    // where it belongs), which is what "slightly greyed out" has to read as --
    // not as a row that is disabled or gone.
    readonly property real cutOpacity: 0.5
    // Counted so a check can see that the desktop half actually happened.
    property int clipboardPublished: 0
    readonly property string clipboardType: "text/uri-list"
    // The owner of the desktop clipboard. It is a process on purpose: a file
    // copy has to serve THREE mime names at once (text/uri-list, GTK's
    // x-special/gnome-copied-files and KDE's cut marker) so that every app on
    // the desktop -- not only the toolkit this shell happens to use -- pastes a
    // FILE, and `wl-copy` can only advertise one type per selection. See
    // scripts/system/file-clipboard.py for the full reasoning.
    readonly property string clipboardHelper: Quickshell.shellPath("scripts/system/file-clipboard.py")
    readonly property string clipboardPidFile: (Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp") + "/ii-files-clipboard.pid"
    // Ends the helper that is serving a selection, if that helper is still the
    // one on the clipboard. The command line is checked before the pid is
    // signalled: a pid file from an earlier session can name a pid that some
    // unrelated process has since been given, and killing that is not a cleanup.
    function clipboardStopCommand() {
        return "p=" + root.shq(root.clipboardPidFile) + "; "
            + "if [ -s \"$p\" ]; then pid=$(cat \"$p\"); "
            + "grep -qa file-clipboard.py \"/proc/$pid/cmdline\" 2>/dev/null && kill \"$pid\" 2>/dev/null; "
            + "rm -f \"$p\"; fi";
    }
    function publishClipboard(cut) {
        const list = root.clipboard;
        if (list.length === 0) return;
        root.clipboardPublished++;
        // The previous owner has to go FIRST: two processes claiming the same
        // selection is a race whose loser is whichever one the pasting app
        // happens to read. Then one helper owns it until another copy (from
        // here or from anywhere else) takes the clipboard away.
        root.sh(root.clipboardStopCommand() + "; setsid python3 " + root.shq(root.clipboardHelper)
            + " " + (cut ? "cut" : "copy")
            + list.map(c => " " + root.shq(c.path)).join("")
            + " >/dev/null 2>&1 & echo $! > " + root.shq(root.clipboardPidFile), "clipboard");
    }
    function copySelection(cut) {
        if (root.selection.length === 0) return;
        root.clipboard = root.selection.map(p => ({ path: p, cut: !!cut }));
        root.publishClipboard(!!cut);
        root.statusNote = root.selection.length + " "
            + (cut ? Translation.tr("item(s) to move") : Translation.tr("item(s) copied"));
    }
    // The one line that moves ONE item into a folder -- and the only place the
    // destination name is decided.
    //
    // gio copy/move have no -f (passing it is an instant "Unknown option" and
    // nothing is copied -- which is exactly why Paste used to do nothing at
    // all), and a write onto an existing name must not clobber it. Explorer's
    // answer to a collision is "Keep both", and so is this: the incoming file
    // lands as "name - copy.ext", or "name - copy (2)" when even that is
    // taken.
    //
    // Paste and every drop target build their shell lines from this one
    // function, because a paste and a drop are the same operation and two
    // copies of the naming rule is how they would come to disagree.
    function transferCommand(srcPath, destDir, move) {
        const verb = move ? "gio move" : "gio copy";
        return `src=${root.shq(srcPath)}; dst=${root.shq(destDir)}; base=$(basename -- "$src"); target="$dst/$base"; `
            + `if [ -e "$target" ]; then stem="${'$'}{base%.*}"; ext="${'$'}{base##*.}"; `
            + `if [ "$stem" = "$base" ]; then ext=""; else ext=".$ext"; fi; `
            + `target="$dst/$stem - copy$ext"; i=2; while [ -e "$target" ]; do target="$dst/$stem - copy ($i)$ext"; i=$((i+1)); done; fi; `
            + `${verb} "$src" "$target"`;
    }
    function pasteInto(dir) {
        const dest = String(dir ?? root.currentFolderPath());
        if (root.clipboard.length === 0) return;
        const cmds = root.clipboard.map(c => root.transferCommand(c.path, dest, c.cut));
        // A cut is consumed by the paste; a copy stays on the clipboard, which
        // is what makes "paste three times" work.
        //
        // The spent cut is taken off the DESKTOP clipboard too, or the same
        // files could be dropped into a second folder afterwards and moved
        // twice -- and that cleanup rides on THIS shell line rather than on a
        // sh() of its own. sh() drives one Process, and a second sh() in the
        // same turn rewrote that Process's command while the first was still
        // starting: only the cleanup ever ran, the cut was cleared off the
        // clipboard anyway, and NOTHING moved. That was the whole of the
        // reported "cut and paste does not work" (copy+paste never showed it,
        // because a copy has no cleanup step and so only ever calls sh() once).
        if (root.clipboard.every(c => c.cut)) {
            root.clipboard = [];
            cmds.unshift(root.clipboardStopCommand());
        }
        root.statusNote = Translation.tr("Pasting") + "…";
        root.sh(cmds.join("; ") + " 2>&1", "paste", dest);
    }

    // ── Drops ───────────────────────────────────────────────────────────
    //
    // The other half of a drag: what this window does when something is
    // dragged ONTO it. Qt's Wayland drag machinery was always in this process
    // (the drag OUT has used it since it was written); what was missing was a
    // DropArea to receive it.
    //
    // A drop names its own destination by WHERE it lands:
    //   a folder row or tile   -> that folder
    //   a breadcrumb           -> that ancestor
    //   a place or a drive     -> that location
    //   anything else in here  -> the folder on screen
    // One function performs the transfer, so all four behave identically.
    //
    // The path the pointer is currently over while something is being dragged
    // over this window ("" when nothing is). The row, the tile, the place, the
    // drive and the breadcrumb each read it to light up when the drag is over
    // THEM -- the accent wash and rail, one rule in one place.
    //
    // The pane draws nothing of its own: it is the fallback destination, and a
    // border around the whole list saying "you could drop this anywhere in
    // here" is the ring this pane was explicitly asked not to have. The target
    // under the pointer is the answer, and when nothing is lit the folder on
    // screen is still where it would go.
    property string dropTargetPath: ""
    // One spelling for a target, so a row's path, a breadcrumb's path and the
    // folder the pane is showing compare equal: no trailing slash. "/" keeps
    // its own spelling -- stripping it would leave "", i.e. "no target", which
    // is the one answer a drop on the root must never get.
    function dropPathKey(p) {
        const s = String(p ?? "");
        return s.length <= 1 ? s : s.replace(/\/+$/, "");
    }
    function dropEntered(path) {
        const key = root.dropPathKey(path);
        if (key.length > 0) root.dropTargetPath = key;
    }
    // Guarded rather than unconditional: moving from a row out onto the pane
    // behind it delivers the pane's enter and the row's exit in whichever order
    // the compositor feels like, and a blind clear would wipe the highlight off
    // the target the pointer is now actually over.
    function dropExited(path) {
        const key = root.dropPathKey(path);
        if (key.length > 0 && root.dropTargetPath === key) root.dropTargetPath = "";
    }
    // A drop has happened, so nothing is lit any more -- unconditionally, which
    // is what makes it different from dropExited. Every destination calls this
    // before handing the drop over.
    //
    // It is a separate function (rather than `root.dropTargetPath = ""` at each
    // of the six call sites) because those six were written against it and it
    // did not exist: every drop into this window threw
    //     TypeError: Property 'clearDropTarget' ... is not a function
    // BEFORE receiveDrop was reached, so nothing was ever transferred and the
    // window looked like it accepted the file and then ignored it.
    function clearDropTarget() {
        root.dropTargetPath = "";
    }

    // file:// URLs as the drag protocol carries them, in the local paths the
    // rest of the app speaks.
    function dropPathsOf(urls) {
        const out = [];
        const list = urls ?? [];
        for (let i = 0; i < list.length; i++) {
            let s = String(list[i] ?? "");
            if (s.length === 0) continue;
            if (s.indexOf("file://") === 0) {
                s = s.slice(7);
                try { s = decodeURIComponent(s); } catch (e) { /* leave it raw */ }
            }
            if (s.length > 0 && out.indexOf(s) === -1) out.push(s);
        }
        return out;
    }

    // Which of these paths a drop into destDir would actually transfer. One
    // rule, read by the transfer and by the probe, so "what would happen" and
    // "what happened" cannot come to different answers.
    function dropWorkList(paths, destDir, move) {
        const destKey = root.dropPathKey(destDir);
        if (destKey.length === 0) return [];
        const out = [];
        for (const p of (paths ?? [])) {
            const src = root.dropPathKey(p);
            // Nothing into nowhere, and nothing into itself: a folder dropped on
            // its own row would otherwise be copied into itself, which `gio`
            // would either refuse or fill with a copy of itself.
            if (src.length === 0 || src === destKey) continue;
            // Moving a file into the folder it already lives in is a no-op, not
            // a rename. A COPY there is still meaningful -- that is how a
            // duplicate is made -- so only the move is filtered out.
            if (move && root.dropPathKey(root.dirName(src)) === destKey) continue;
            out.push(src);
        }
        return out;
    }
    // Copy or move every dropped item into destDir. Returns how many were
    // actually transferred, so a probe can assert on the decision instead of
    // on the side effect.
    function receiveDrop(urls, destDir, move) {
        const dest = root.dropPathKey(destDir);
        const work = root.dropWorkList(root.dropPathsOf(urls), dest, move);
        if (work.length === 0) return 0;
        root.statusNote = (move ? Translation.tr("Moving") : Translation.tr("Copying")) + "…";
        root.sh(work.map(p => root.transferCommand(p, dest, move)).join("; ") + " 2>&1", "paste", dest);
        return work.length;
    }

    // ── Menus ───────────────────────────────────────────────────────────
    // One list feeds the context menu, the command bar's Sort/View popover and
    // the IPC probe: one place to add an action, one place that can run it.
    property var menuItems: []
    // The menu's own box, in one place: the width the popup is given, and the
    // height its rows add up to (see menuHeight). Kept as properties so the
    // placement above and the popup below cannot disagree about the size.
    readonly property int menuWidth: 258
    function menuHeight(items) {
        const list = items ?? [];
        if (list.length === 0) return 0;
        // 6px of padding top and bottom, 30px a row, 7px a separator, 1px
        // between them -- the same numbers the delegate and the ColumnLayout
        // use, which is what makes where the menu is put a decision rather
        // than a guess.
        let h = 12;
        for (const i of list)
            h += (i && i.separator === true ? 7 : 30) + 1;
        return h - 1;
    }
    property bool menuOpen: false
    property real menuX: 0
    property real menuY: 0
    property string menuTarget: ""
    function sep() { return { id: "sep", label: "", icon: "", enabled: false, separator: true }; }
    function sortMenuItems() {
        const cur = root.sortField;
        const mark = f => cur === f ? (root.sortReversed ? " ↓" : " ↑") : "";
        return [
            { id: "sortName", label: Translation.tr("Name") + mark(0), icon: "sort_by_alpha", enabled: true },
            { id: "sortTime", label: Translation.tr("Date modified") + mark(1), icon: "schedule", enabled: true },
            { id: "sortType", label: Translation.tr("Type") + mark(2), icon: "category", enabled: true },
            { id: "sortSize", label: Translation.tr("Size") + mark(3), icon: "data_usage", enabled: true },
            root.sep(),
            { id: "viewDetails", label: Translation.tr("Details view"), icon: "list", enabled: true },
            { id: "viewTiles", label: Translation.tr("Tiles view"), icon: "grid_view", enabled: true },
            root.sep(),
            { id: "togglePreviewPane", label: root.previewPane ? Translation.tr("Hide the preview pane") : Translation.tr("Show the preview pane"), icon: "preview", enabled: !root.pickerMode },
            { id: "toggleTilePreviews", label: root.tilePreviews ? Translation.tr("Hide file previews in tiles") : Translation.tr("Show file previews in tiles"), icon: "image", enabled: true },
            root.sep(),
            { id: "toggleHidden", label: root.showHidden ? Translation.tr("Hide hidden files") : Translation.tr("Show hidden files"), icon: "visibility", enabled: true },
            { id: "toggleExtensions", label: root.showExtensions ? Translation.tr("Hide file extensions") : Translation.tr("Show file extensions"), icon: "extension", enabled: true }
        ];
    }
    // The two creates, in one place. They are the first rows of the empty-space
    // menu and the WHOLE of the command bar's New popover -- which exists
    // because a folder with files in it has no empty space left to right-click,
    // and "how do I add a file" should not depend on there being a gap between
    // the rows.
    function createMenuItems() {
        return [
            { id: "newFolder", label: Translation.tr("New folder"), icon: "create_new_folder", enabled: true },
            { id: "newFile", label: Translation.tr("New file"), icon: "note_add", enabled: true }
        ];
    }
    function folderMenu() {
        return [
            ...root.createMenuItems(),
            root.sep(),
            { id: "paste", label: Translation.tr("Paste"), icon: "content_paste", enabled: root.clipboard.length > 0 },
            { id: "selectAll", label: Translation.tr("Select all"), icon: "select_all", enabled: true },
            { id: "newTab", label: Translation.tr("Open in new tab"), icon: "tab", enabled: root.tabsAvailable && !root.atThisPc },
            { id: "newWindowTab", label: Translation.tr("New tab"), icon: "add", enabled: root.tabsAvailable },
            root.sep(),
            { id: "sortName", label: Translation.tr("Sort by name"), icon: "sort_by_alpha", enabled: true },
            { id: "sortTime", label: Translation.tr("Sort by date modified"), icon: "schedule", enabled: true },
            { id: "sortType", label: Translation.tr("Sort by type"), icon: "category", enabled: true },
            { id: "sortSize", label: Translation.tr("Sort by size"), icon: "data_usage", enabled: true },
            { id: "viewDetails", label: Translation.tr("Details view"), icon: "list", enabled: true },
            { id: "viewTiles", label: Translation.tr("Tiles view"), icon: "grid_view", enabled: true },
            { id: "togglePreviewPane", label: root.previewPane ? Translation.tr("Hide the preview pane") : Translation.tr("Show the preview pane"), icon: "preview", enabled: !root.pickerMode },
            { id: "toggleTilePreviews", label: root.tilePreviews ? Translation.tr("Hide file previews in tiles") : Translation.tr("Show file previews in tiles"), icon: "image", enabled: true },
            { id: "toggleHidden", label: root.showHidden ? Translation.tr("Hide hidden files") : Translation.tr("Show hidden files"), icon: "visibility", enabled: true },
            { id: "toggleExtensions", label: root.showExtensions ? Translation.tr("Hide file extensions") : Translation.tr("Show file extensions"), icon: "extension", enabled: true },
            root.sep(),
            { id: "refresh", label: Translation.tr("Refresh"), icon: "refresh", enabled: true },
            { id: "terminal", label: Translation.tr("Open in terminal"), icon: "terminal", enabled: true },
            { id: "properties", label: Translation.tr("Properties"), icon: "info", enabled: true }
        ];
    }
    function entryMenu(p) {
        const isDir = root.isDirPath(p);
        return [
            { id: "open", label: Translation.tr("Open"), icon: "open_in_new", enabled: true },
            // Files only: "open a folder WITH something" is not a thing, and the
            // row would be a dead one under every right-click on a directory.
            { id: "openWith", label: Translation.tr("Open with…"), icon: "apps", enabled: !isDir },
            { id: "openTab", label: Translation.tr("Open in new tab"), icon: "tab", enabled: isDir && root.tabsAvailable },
            root.sep(),
            { id: "cut", label: Translation.tr("Cut"), icon: "content_cut", enabled: true },
            { id: "copy", label: Translation.tr("Copy"), icon: "content_copy", enabled: true },
            { id: "pasteInto", label: Translation.tr("Paste into folder"), icon: "content_paste", enabled: isDir && root.clipboard.length > 0 },

            // Rename names ONE thing: greyed over a multi-selection rather
            // than renaming only the row under the pointer (see menuTargets).
            { id: "rename", label: Translation.tr("Rename"), icon: "edit", enabled: root.menuTargets(p).length === 1 },
            { id: "trash", label: Translation.tr("Delete"), icon: "delete", enabled: true },
            root.sep(),
            { id: "copyPath", label: Translation.tr("Copy path"), icon: "link", enabled: true },
            { id: "terminal", label: Translation.tr("Open in terminal"), icon: "terminal", enabled: true },
            { id: "properties", label: Translation.tr("Properties"), icon: "info", enabled: true }
        ];
    }
    // A drive's menu, in the order the other OS puts it in: open it, mount or
    // eject it, then the things you came here to CHANGE, then the things that
    // inspect or maintain it. Every row's `enabled` is the same test the action
    // itself makes, so a greyed row and a refused action can never disagree.
    function deviceMenu(v) {
        const mounted = !!v && v.mountpoint.length > 0;
        // A phone gets its own, shorter menu. The rest of the drive menu is
        // about a filesystem (check it, label it, format it, TRIM it) and a
        // phone has none of those things: offering them greyed out would be
        // four dead rows in the one menu that should be obvious.
        if (v && v.kind === "mtp") {
            return [
                { id: "openDevice", label: Translation.tr("Open"), icon: "folder_open", enabled: mounted },
                { id: "mountDevice", label: Translation.tr("Mount"), icon: "download", enabled: !mounted },
                { id: "unmountDevice", label: Translation.tr("Eject"), icon: "eject", enabled: mounted },
                { id: "rescanDevice", label: Translation.tr("Look for it again"), icon: "refresh", enabled: true },
                root.sep(),
                { id: "copyPath", label: Translation.tr("Copy path"), icon: "link", enabled: mounted },
                { id: "properties", label: Translation.tr("Properties"), icon: "info", enabled: true }
            ];
        }
        return [
            { id: "openDevice", label: Translation.tr("Open"), icon: "folder_open", enabled: mounted },
            { id: "openTerminalDevice", label: Translation.tr("Open in terminal"), icon: "terminal", enabled: mounted },
            { id: "mountDevice", label: Translation.tr("Mount"), icon: "download", enabled: v && !mounted && v.hasFs !== false },
            { id: "unmountDevice", label: Translation.tr("Eject"), icon: "eject", enabled: root.volumeUnmountable(v) },
            { id: "rescanDevice", label: Translation.tr("Re-read this drive"), icon: "refresh", enabled: v && v.hasFs === false },
            root.sep(),
            { id: "driveLetter", label: Translation.tr("Change drive letter…"), icon: "drive_file_rename_outline", enabled: !!v },
            { id: "driveLabel", label: Translation.tr("Rename this drive…"), icon: "label", enabled: root.canRelabel(v) },
            { id: "properties", label: Translation.tr("Properties"), icon: "info", enabled: true },
            root.sep(),
            { id: "driveCheck", label: Translation.tr("Check this drive…"), icon: "fact_check", enabled: root.volumeActionCommand("check", v).length > 0 },
            { id: "driveTrim", label: Translation.tr("Optimise (TRIM)"), icon: "auto_awesome", enabled: root.volumeActionCommand("trim", v).length > 0 },
            { id: "driveRemountRo", label: Translation.tr("Remount read-only"), icon: "lock", enabled: root.volumeActionCommand("remount-ro", v).length > 0 && !v?.readOnly },
            { id: "driveRemountRw", label: Translation.tr("Remount read-write"), icon: "lock_open", enabled: root.volumeActionCommand("remount-rw", v).length > 0 && !!v?.readOnly },
            root.sep(),
            { id: "driveFormat", label: Translation.tr("Format…"), icon: "format_color_reset", enabled: root.canFormat(v) }
        ];
    }
    // The set a menu action runs on. The row handlers only collapse the
    // selection when the right-clicked row is NOT part of it, so a menu opened
    // over a multi-selection has to act on the WHOLE selection -- Cut, Copy,
    // Delete, Copy path, Open -- and not only the row under the pointer. An
    // empty-space menu (no target) is the selection as well; a target outside
    // any selection (a drive row) resolves to itself.
    function menuTargets(target) {
        const t = String(target ?? "");
        if (t.length === 0) return root.selection;
        return root.isSelected(t) ? root.selection : [t];
    }
    function openMenu(x, y, target) {
        root.menuTarget = String(target ?? "");
        const vol = root.volumeByPath(root.menuTarget);
        if (vol)
            root.menuItems = root.deviceMenu(vol);
        else if (root.menuTarget === "sort:")
            root.menuItems = root.sortMenuItems();
        // The command bar's New: the two creates, anchored under the word.
        else if (root.menuTarget === "create:")
            root.menuItems = root.createMenuItems();
        else if (root.menuTarget.length > 0 && root.menuTarget !== root.thisPc)
            root.menuItems = root.entryMenu(root.menuTarget);
        else
            root.menuItems = root.folderMenu();
        // ── Where the menu is put ───────────────────────────────────────
        // At the pointer, and then BACK INSIDE THE CARD. Opened in the lower
        // half of the pane, a 258x600 menu of rows ran off the bottom of the
        // card and off the surface with it -- and a row that is past the edge
        // is a row that is not drawn and cannot be clicked, so the menu the
        // user was looking at was the half that did nothing. It moves up (and
        // left, near the right edge) instead, the way Explorer's does, so the
        // LAST row is always on screen and always clickable.
        const w = root.menuWidth;
        const h = root.menuHeight(root.menuItems);
        const margin = 8;
        root.menuX = Math.max(margin, Math.min(Number(x ?? 0), root.width - w - margin));
        root.menuY = Math.max(margin, Math.min(Number(y ?? 0), root.height - h - margin));
        root.menuOpen = true;
    }
    // The context menu is parented to this root, so a press that happened down
    // inside a view's content has to be mapped up into ROOT coordinates before
    // `openMenu` is given it. Handing over the press's own local x/y -- which is
    // what the row, tile and This-PC call sites used to do -- places the menu at
    // that offset inside its own row instead of at the pointer, so it appeared
    // near the top-left of the pane wherever you clicked. The two newest sites
    // (the sort popover and the drive rows) already map; this is that in one
    // place so every future one gets it for free.
    function openMenuAt(item, x, y, target) {
        const p = item.mapToItem(root, x, y);
        root.openMenu(p.x, p.y, target);
    }
    // Right-click on EMPTY space in a folder. Passing no target is not an
    // oversight: it is exactly the signal `openMenu` reads as "the folder's own
    // menu" -- New folder, New file, Paste, Select all, the tab rows, sort,
    // view, hidden files, Refresh, Open in terminal, Properties. On this machine
    // a two-finger tap IS a right button (tap_button_map 1/2/3 with
    // clickfinger_behavior, see custom/general.lua), so the tap arrives here as
    // this press and needs no gesture handling of its own.
    function openFolderMenuAt(item, x, y) {
        root.openMenuAt(item, x, y, "");
    }
    // New drop-down, always available however full the folder is. It opens
    // UNDER the command (not at the pointer) because a menu that covers the
    // word it came from reads as having been dropped on top of it.
    function openCreateMenu() {
        root.openMenuAt(newCommand, 0, newCommand.height + 6, "create:");
    }
    function closeMenu() {
        root.menuOpen = false;
        root.menuItems = [];
    }
    function runMenu(item) {
        const id = typeof item === "string" ? item : (item?.id ?? "");
        const target = root.menuTarget;
        const vol = root.volumeByPath(target);
        root.closeMenu();
        switch (id) {
        case "openWith": {
            // One file at a time: the chooser is a question about THIS document
            // (which app, which type), and asking it for five selections would
            // have to answer "which app for which file".
            const ts = root.menuTargets(target).filter(p => !root.isDirPath(p));
            if (ts.length === 1) root.askOpenWith(ts[0]);
            break;
        }
        case "open": {
            const ts = root.menuTargets(target);
            if (ts.length <= 1) {
                if (target) root.openEntry(root.indexOfPath(target));
                break;
            }
            // Several selected, Explorer's Open: every FILE is launched, and
            // every other FOLDER opens in a tab -- one pane can only show one
            // folder, so the pane keeps following the row under the pointer.
            let enter = root.isDirPath(target) ? target : "";
            for (const p of ts) {
                if (root.isDirPath(p)) {
                    if (p === target) continue;
                    if (root.tabsAvailable) root.newTab(p);
                    // No tabs to put it in: fall back ONLY when the pane has
                    // nowhere to go yet -- a folder the pointer is NOT on
                    // must never displace the folder that was clicked.
                    else if (enter.length === 0) enter = p;
                } else {
                    const i = root.indexOfPath(p);
                    if (i >= 0) root.openEntry(i);
                }
            }
            if (enter) root.navigateTo(enter);
            break;
        }
        case "openTab": if (target) root.newTab(target); break;
        case "newTab": if (target) root.newTab(target); break;
        case "newWindowTab": root.newTab(""); break;
        case "newFolder": root.newFolder(); break;
        case "newFile": root.newFile(); break;
        case "paste": root.pasteInto(root.currentFolderPath()); break;
        case "pasteInto": if (target) root.pasteInto(target); break;
        case "selectAll": root.selectAll(); break;
        case "viewDetails": root.setViewMode("details"); break;
        case "viewTiles": root.setViewMode("tiles"); break;
        case "togglePreviewPane": root.previewPane = !root.previewPane; break;
        case "toggleTilePreviews": root.tilePreviews = !root.tilePreviews; break;
        case "toggleHidden": root.showHidden = !root.showHidden; break;
        case "toggleExtensions": root.showExtensions = !root.showExtensions; break;
        case "sortName": root.setSort(0); break;
        case "sortTime": root.setSort(1); break;
        case "sortType": root.setSort(2); break;
        case "sortSize": root.setSort(3); break;
        case "refresh": root.refresh(); break;
        case "cut": root.copySelection(true); break;
        case "copy": root.copySelection(false); break;
        case "rename": root.beginRename(target); break;
        // Every one of these acts on the whole selection, never on only the
        // right-clicked row -- see menuTargets().
        case "trash": root.trashItems(root.menuTargets(target)); break;
        case "delete": root.deleteItems(root.menuTargets(target)); break;
        case "copyPath": root.copyPath(root.menuTargets(target)); break;
        case "terminal": root.openInTerminal(target); break;
        case "openTerminalDevice": if (vol) root.openInTerminal(vol.mountpoint); break;
        case "openDevice": if (vol) root.navigateTo(vol.mountpoint); break;
        case "mountDevice": if (vol) root.mountVolume(vol); break;
        case "unmountDevice": if (vol) root.unmountVolume(vol); break;
        case "rescanDevice": if (vol) root.rescanVolume(vol); break;
        case "driveLetter": if (vol) root.openVolumePrompt("letter", vol); break;
        case "driveLabel": if (vol) root.openVolumePrompt("label", vol); break;
        case "driveFormat": if (vol) root.openVolumePrompt("format", vol); break;
        case "driveCheck": if (vol) root.runVolumeAction("check", vol); break;
        case "driveTrim": if (vol) root.runVolumeAction("trim", vol); break;
        case "driveRemountRo": if (vol) root.runVolumeAction("remount-ro", vol); break;
        case "driveRemountRw": if (vol) root.runVolumeAction("remount-rw", vol); break;
        // A drive's Properties is the drive's, mounted or not: passing the
        // device answers that question with the same dialog either way.
        // Properties with NO target is the FOLDER's: the empty-space menu has no
        // path to hand over, and `showInfo` only defaults on a null -- an empty
        // string is a path it will stat quite happily and then show nothing for,
        // so that row opened a dialog stuck on "Reading…". Drives are unaffected:
        // `vol` is non-null for them, so they keep their device path.
        case "properties": root.showInfo(vol ? vol.path : (target.length > 0 ? target : root.currentFolderPath())); break;
        default: break;
        }
    }
    function setSort(field) {
        if (root.sortField === field) root.sortReversed = !root.sortReversed;
        else root.sortField = field;
    }

    // ── The name prompt: rename, and the name a new file or folder gets ──
    // ONE dialog for the three places a name is typed, because they differ in
    // exactly two things: its title, and what Enter does with the name.
    // `creating` says which of the two creates is being named -- "" means this
    // is a rename of `renamePath`.
    property bool renaming: false
    property string renamePath: ""
    // TWO boxes, because a name and its extension are two decisions -- and the
    // extension is the one nobody wants to retype. `renameDraft` is the name
    // box, `renameExt` the extension box (no dot, and its OWN case: a rename of
    // IMG_0421.JPG must not come back as .jpg). They are joined by
    // composePromptName() at commit time, so "rename the stem, keep the type" is
    // the default path rather than a thing to remember. A folder, a dotfile and
    // a file with no extension show the one box: there is nothing to keep.
    property string renameDraft: ""
    property string renameExt: ""
    property bool renameExtShown: false
    property string creating: ""        // "" | "file" | "folder"
    // The extension, with its case left alone. suffixOf() lowercases on purpose
    // (it answers "is this an image?"); a name being renamed is not a question
    // about kind, so it gets its own splitter instead of mutating the suffix.
    function extOfName(name) {
        const n = String(name ?? "");
        const i = n.lastIndexOf(".");
        return i > 0 ? n.substring(i + 1) : "";
    }
    // What the two boxes add up to. With no extension box the name is passed
    // through as typed; an emptied extension box is how the extension is
    // REMOVED ("notes", never "notes.").
    function composePromptName() {
        const base = String(root.renameDraft ?? "").trim().replace(/[. ]+$/, "");
        if (!root.renameExtShown) return base;
        const ext = String(root.renameExt ?? "").trim().replace(/^[. ]+/, "");
        if (ext.length === 0) return base;
        if (base.length === 0) return "";
        return base + "." + ext;
    }
    function beginRename(p) {
        if (!p) return;
        const name = root.baseName(p);
        const isDir = root.isDirPath(p);
        root.creating = "";
        root.renamePath = String(p);
        // A folder's dots are part of its name ("2026.10.backup"); only a file
        // is split, and only when it has something after the dot.
        root.renameDraft = isDir ? name : root.stemOf(name);
        root.renameExt = isDir ? "" : root.extOfName(name);
        root.renameExtShown = root.renameExt.length > 0;
        root.renaming = true;
        Qt.callLater(() => { renameField.forceActiveFocus(); renameField.selectAll(); });
    }
    function beginCreate(kind) {
        root.clearFilterForCreate();
        root.creating = (kind === "folder" ? "folder" : "file");
        const offered = root.defaultCreateName(root.creating);
        root.renamePath = "";
        // The offered "New file.txt" is split the same way, so the name box is
        // "New file" and the extension box already says "txt" -- which is the
        // extension the person can change without touching the name.
        root.renameDraft = root.creating === "folder" ? offered : root.stemOf(offered);
        root.renameExt = root.creating === "folder" ? "" : root.extOfName(offered);
        root.renameExtShown = root.renameExt.length > 0;
        root.renaming = true;
        Qt.callLater(() => { renameField.forceActiveFocus(); renameField.selectAll(); });
    }
    // The draft the prompt starts with, extension and all: the point of asking
    // is that the extension is editable, so the draft has to have one. The name
    // is unique in this folder already ("New folder (2)", "New file (2).txt"),
    // so the offered default never lands on top of something; a name the user
    // types that IS taken is refused with a reason rather than silently
    // replacing a file. The whole line is selected, so typing replaces it.
    function defaultCreateName(kind) {
        const base = kind === "folder" ? Translation.tr("New folder")
            : Translation.tr("New file") + ".txt";
        const candidate = root.uniqueName(root.currentFolderPath(), base);
        return candidate.slice(candidate.lastIndexOf("/") + 1);
    }
    function namePromptTitle() {
        if (root.creating === "folder") return Translation.tr("New folder");
        if (root.creating === "file") return Translation.tr("New file");
        return Translation.tr("Rename");
    }
    function namePromptAction() {
        return root.creating.length > 0 ? Translation.tr("Create") : Translation.tr("Rename");
    }
    // A script's way into the prompt: it hands over the NAME it wants to end up
    // with, and this splits it into the two boxes exactly as the dialog holds
    // them -- so `probeRenameCommit "notes.md"` commits the same thing a person
    // typing "notes" into the name box and leaving ".md" alone would.
    function probeSetPromptName(name) {
        const n = String(name ?? "");
        if (root.creating === "folder") {
            root.renameDraft = n;
            root.renameExt = "";
            root.renameExtShown = false;
            return;
        }
        const ext = root.extOfName(n);
        root.renameDraft = ext.length > 0 ? root.stemOf(n) : n;
        root.renameExt = ext;
        root.renameExtShown = ext.length > 0;
    }
    function commitRename() {
        const target = root.renamePath;
        const draft = root.composePromptName();
        const kind = root.creating;
        root.renaming = false;
        root.renamePath = "";
        root.renameDraft = "";
        root.renameExt = "";
        root.renameExtShown = false;
        root.creating = "";
        keyLayer.forceActiveFocus();
        if (kind.length > 0) {
            root.createNamed(kind, draft);
            return;
        }
        root.renameItem(target, draft);
    }
    function cancelRename() {
        root.renaming = false;
        root.renamePath = "";
        root.renameDraft = "";
        root.renameExt = "";
        root.renameExtShown = false;
        root.creating = "";
        keyLayer.forceActiveFocus();
    }
    property bool confirmingDelete: false
    function askPermanentDelete() {
        if (root.selection.length === 0) return;
        root.confirmingDelete = true;
    }
    // var, not string: the dialog's visibility is "is there a target", and a
    // string property turns that null into "" -- a dialog that can never open.
    property var infoTarget: null
    property string infoText: ""

    // ── Picker result, and the save name split in two ───────────────────
    //
    // A save dialog asks two questions and used to ask them in one box: the
    // name and the type. The type is the half nobody wants to retype and the
    // half a typo breaks silently -- a name that loses its "g" still saves, as
    // a file nothing will open. So the name box holds the STEM and a second,
    // separate control holds the extension, the same split the rename prompt
    // already makes (see composePromptName).
    //
    // The extension control is not a field at rest. It is a label that says what
    // the file will be called, and it becomes a field only when it is asked to
    // -- a double click or a double tap on the box. A dialog that arrives with
    // the caret parked inside the extension the application suggested is a
    // dialog where the first letter of "my report" lands inside ".png".
    property string saveStem: ""
    property string saveExt: ""
    // The extension the APPLICATION asked for, kept untouched: it is the label
    // that floats onto the top line when the box opens (see the picker footer),
    // so the box can be changed or emptied without losing what it started as.
    property string saveExtDefault: ""
    property bool saveExtEditing: false

    // ── How wide the name box is ────────────────────────────────────────
    //
    // The box is as wide as the name in it. Filling the bar (what it did
    // first) left a field the width of the dialog with six characters in it,
    // and the type pushed out to the far side of that emptiness; a fixed width
    // would break the other way on a long name. So: one word at rest, wider as
    // the name is typed, and capped by what the bar can spare -- past that the
    // box stops growing and the TEXT scrolls inside it instead, which is what
    // a field should do rather than pushing the type off the end.
    //
    // The minimum is MEASURED, not a number: it is a word in the field's own
    // font (see `saveNameMin` below), so changing the font size does not leave
    // the box the wrong length. The 28 is the box's own insets (8 + 8) plus the
    // caret's width, so the last letter is never against the border.
    readonly property real saveNameMinWidth: saveNameMin.advanceWidth + 28
    // Everything the bar cannot give the name: the caption, the type's box and
    // the two gaps between the three of them.
    readonly property real saveNameMaxWidth: Math.max(saveNameMinWidth,
        pickerFields.width - saveNameCaption.implicitWidth - saveExtBox.width - 20)

    // The small label above the open field: the default extension, dotted,
    // exactly as it will read in the finished name.
    function saveExtLabel() {
        return root.saveExtDefault.length > 0
            ? "." + root.saveExtDefault
            : Translation.tr("Extension");
    }

    // Splits the name the application suggested, when it arrives.
    //
    // A folder, a dotfile and a name without a dot all end up with no extension
    // half, which is the only correct reading of "Notes" -- the second dot of
    // ".bashrc" is not a type.
    function syncSaveName() {
        const name = String(root.pickerName ?? "");
        const ext = root.extOfName(name);
        root.saveStem = ext.length > 0 ? root.stemOf(name) : name;
        root.saveExt = ext;
        root.saveExtDefault = ext;
        root.saveExtEditing = false;
    }
    onPickerNameChanged: root.syncSaveName()

    // What the two halves add up to. An emptied extension box is how a type is
    // removed, so the name never comes back with a trailing dot.
    function saveComposedName() {
        const base = String(root.saveStem ?? "").trim().replace(/[. ]+$/, "");
        if (base.length === 0)
            return "";
        const ext = String(root.saveExt ?? "").trim().replace(/^[. ]+/, "");
        return ext.length > 0 ? base + "." + ext : base;
    }

    function openSaveExtEditor() {
        if (root.pickerOp !== "save") return;
        root.saveExtEditing = true;
        // Selected on arrival, like the rename prompt's extension box: the box
        // exists to be typed over, and a caret in front of "png" is how a
        // keystroke silently makes it "xpng".
        Qt.callLater(() => { saveExtField.forceActiveFocus(); saveExtField.selectAll(); });
    }
    function closeSaveExtEditor() {
        root.saveExtEditing = false;
    }

    // The save prompt's own state, so the two boxes can be read and driven from
    // a terminal (scripts/system/files-check.sh) the way the rename prompt's
    // are (probeRenameDialog). `label` is the floating one: what the open
    // extension box writes on its top line.
    function probeSavePrompt() {
        return JSON.stringify({
            stem: root.saveStem,
            ext: root.saveExt,
            defaultExt: root.saveExtDefault,
            editing: root.saveExtEditing,
            label: root.saveExtLabel(),
            composed: root.saveComposedName(),
            // The name box's geometry, because "the box grows with the name and
            // then the text scrolls" is a claim about numbers: how wide the box
            // is, where the type's box sits, and whether the text is wider than
            // the field it is in.
            nameWidth: Math.round(saveNameFrame.width),
            nameX: Math.round(saveNameFrame.x),
            nameMin: Math.round(root.saveNameMinWidth),
            nameMax: Math.round(root.saveNameMaxWidth),
            extX: Math.round(saveExtBox.x),
            extW: Math.round(saveExtBox.width),
            fieldsW: Math.round(pickerFields.width),
            captionW: Math.round(saveNameCaption.width),
            overflow: saveName.contentWidth > saveName.width + 0.5
        });
    }
    function probeSaveStem(value) {
        root.saveStem = String(value ?? "");
        return root.probeSavePrompt();
    }
    // The double click, without a pointer: the same function the box's own
    // handler calls, so a check of "it opens as a field" is a check of the path
    // a real tap takes.
    function probeSaveExtOpen() {
        root.openSaveExtEditor();
        return root.probeSavePrompt();
    }
    function probeSaveExt(value) {
        root.saveExt = String(value ?? "");
        return root.probeSavePrompt();
    }
    function probeSaveExtClose() {
        root.closeSaveExtEditor();
        return root.probeSavePrompt();
    }

    // ── The replace prompt ──────────────────────────────────────────────
    // Save on a name that is already taken asks before answering. The dialog's
    // answer IS the replacement -- the application writes to the URI it is
    // handed -- so the confirmation has to happen HERE, before the result file
    // is written; after that the file is already gone.
    property bool confirmingSave: false
    property string confirmingSavePath: ""
    property string confirmingSaveName: ""
    function answerSave(path) {
        const p = String(path ?? "");
        if (p.length === 0) return;
        root.pickerAccepted([root.fileUri(p)]);
    }
    function acceptSaveReplace() {
        if (!root.confirmingSave) return;
        const path = root.confirmingSavePath;
        root.confirmingSave = false;
        root.confirmingSavePath = "";
        root.confirmingSaveName = "";
        root.answerSave(path);
    }
    function cancelSaveReplace() {
        root.confirmingSave = false;
        root.confirmingSavePath = "";
        root.confirmingSaveName = "";
    }
    function probeSaveReplace() {
        return JSON.stringify({
            open: root.confirmingSave,
            name: root.confirmingSaveName,
            path: root.confirmingSavePath,
            composed: root.saveComposedName(),
        });
    }

    readonly property string actionLabel:
        root.pickerOp === "save" ? Translation.tr("Save")
        : (root.pickerDirectory ? Translation.tr("Select folder") : Translation.tr("Open"))
    readonly property bool pickerCanConfirm:
        root.pickerOp === "save" ? true
        : (root.pickerDirectory ? root.folderPath.length > 0 : root.selection.length > 0)
    function pickerConfirm() {
        if (!root.pickerMode) return;
        // Where this answer came from, remembered for the NEXT dialog. Most
        // portal callers name no folder, so without this every dialog started
        // at home and the second upload from a project was another walk to it
        // (see Persistent.states.pickerDir). Written before the branches so
        // every kind of answer -- a file, a folder, a save name -- records the
        // same thing: the folder the person was standing in when they said yes.
        if (Persistent.states)
            Persistent.states.pickerDir = root.currentFolderPath();
        if (root.pickerOp === "save") {
            // The two boxes, joined: the app is handed one name, because that is
            // what a file is called (see saveComposedName).
            const name = root.saveComposedName();
            if (name.length === 0) return;
            // ── Saving OVER something is a question, not a habit ──────────
            // The name box arrives holding the application's suggestion, and
            // clicking a row in the list is how a folder's contents are read
            // before saying yes -- so "Save" can easily name a file that is
            // already there. Answering straight away replaced it with no word
            // said, and the file that went was somebody's. The name is put to
            // the filesystem first (the pane can be filtered or a refresh
            // behind, so `test -e` is the answer, not the row list) and an
            // existing name opens the replace prompt below.
            root.sh("test -e " + root.shq(root.currentFolderPath() + "/" + name)
                + " && printf exists || printf free", "save-check",
                root.currentFolderPath() + "/" + name);
            return;
        }
        if (root.pickerDirectory) {
            // A folder picker's answer is the folder being LOOKED AT, which is
            // why the Open button is the only way to say yes here.
            root.pickerAccepted([root.fileUri(root.currentFolderPath())]);
            return;
        }
        if (root.selection.length === 0) return;
        // Several files at once is a valid answer for a file picker, so a
        // multi-selection is handed over whole.
        root.pickerAccepted(root.selection.map(p => root.fileUri(p)));
    }

    // ── Breadcrumbs ─────────────────────────────────────────────────────
    readonly property var crumbs: {
        if (root.atThisPc)
            return [{ label: Translation.tr("This PC"), path: root.thisPc }];
        const p = root.folderPath;
        const parts = p.split("/").filter(s => s.length > 0);
        const out = [{ label: Translation.tr("This PC"), path: root.thisPc }];
        let acc = "";
        for (const part of parts) {
            acc += "/" + part;
            out.push({ label: part, path: acc });
        }
        return out;
    }
    property bool editingPath: false
    function beginPathEdit() {
        root.editingPath = true;
        Qt.callLater(() => { pathLabel.forceActiveFocus(); pathLabel.selectAll(); });
    }
    function finishPathEdit() {
        if (!root.editingPath) return;
        root.editingPath = false;
        const p = String(pathLabel.text ?? "").trim();
        keyLayer.forceActiveFocus();
        if (p.length === 0) return;
        root.navigateTo(p.replace(/^~/, root.homeDir));
    }

    // ── The keyboard's route through the window: Tab ─────────────────────
    //
    // Explorer moves the keyboard focus around the window with Tab (Shift+Tab
    // back) and F6 cycles the big panes. This app had NONE of that: the arrows,
    // Home/End, Backspace and Escape were handled on one key layer, and Tab was
    // not handled at all -- so a window that is perfectly usable with a mouse
    // had no keyboard route through its own controls, which is what "the Tab
    // key does not act like a Tab" was.
    //
    // The stops are the AREAS rather than every control: that is Explorer's own
    // granularity, and it keeps ONE place -- this list, and the key layer that
    // walks it -- that knows the order, instead of a per-widget focus chain that
    // every new button silently falls out of. Inside an area the arrows walk
    // that area's own controls, and Enter presses the one they are on.
    //
    // The tab strip is inside the command bar, so "toolbar" is the stop that
    // covers both; the chips are still what a click uses.
    readonly property var focusAreas: ["toolbar", "address", "search", "list", "nav", "status"]
    property string focusArea: "list"
    property int focusIndex: 0
    function focusAreaVisible(area) {
        // The toolbar is a stop in a dialog as well now, because it no longer
        // holds only file commands: the view controls live there, and a control
        // Tab cannot reach is a control the keyboard cannot use. The walk inside
        // it already skips what is not drawn, so in a dialog the arrows pass over
        // New/Cut/Rename and land on the list/grid, size and hidden-files
        // buttons -- exactly the row that is on screen.
        if (area === "toolbar")
            return true;
        if (area === "address" || area === "search" || area === "status")
            return !root.pickerMode;
        if (area === "nav") return root.showNav;
        return true;                                  // the file list is always there
    }
    // What the keyboard is on, in words -- the label a probe reports and the
    // only honest way to check this without a pair of hands.
    function focusLabel() {
        if (root.focusArea === "toolbar" || root.focusArea === "nav") {
            const c = root.focusCandidates();
            const it = c[Math.max(0, Math.min(c.length - 1, root.focusIndex))];
            if (!it) return root.focusArea;
            return String(it.tip ?? it.label ?? "");
        }
        return root.focusArea;
    }
    // The controls the arrows walk inside the focused area. Only the two areas
    // that HAVE such a row need to answer: the toolbar is a row of buttons, the
    // nav pane is a column of rows. The others act as a whole (Enter opens the
    // path, Enter takes the caret to the search box, the arrows are the list's
    // own and stayed where they were).
    function focusCandidates(area) {
        const a = area ?? root.focusArea;
        const out = [];
        const kids = a === "toolbar" ? commandRow.children : (a === "nav" ? navColumn.children : []);
        for (let i = 0; i < (kids ? kids.length : 0); i++) {
            const k = kids[i];
            if (!k || k.visible === false || k.enabled === false) continue;
            if (a === "toolbar") {
                if (typeof k.pressFromKeyboard !== "function") continue;   // separators
            } else if (typeof k.activated !== "function") {
                continue;                                                   // headings
            }
            out.push(k);
        }
        return out;
    }
    // The control the arrows are on, lit the way a hover lights it, cleared and
    // set in ONE place -- so a walk can never leave two of them lit, and a new
    // walkable row only has to carry the property.
    function refreshFocusHighlight() {
        for (const a of ["toolbar", "nav"]) {
            const c = root.focusCandidates(a);
            for (let i = 0; i < c.length; i++)
                if (c[i].keyFocused !== undefined) c[i].keyFocused = false;
        }
        if (root.focusArea === "toolbar" || root.focusArea === "nav") {
            const c = root.focusCandidates();
            const it = c[Math.max(0, Math.min(c.length - 1, root.focusIndex))];
            if (it && it.keyFocused !== undefined) it.keyFocused = true;
        }
    }
    function setFocusArea(area) {
        if (area === root.focusArea) return;
        root.focusArea = area;
        root.focusIndex = 0;
        root.refreshFocusHighlight();
    }
    function stepFocusArea(delta) {
        const areas = root.focusAreas.filter(a => root.focusAreaVisible(a));
        if (areas.length === 0) return;
        const at = areas.indexOf(root.focusArea);
        const next = at < 0 ? 0 : (at + delta + areas.length) % areas.length;
        root.setFocusArea(areas[next]);
    }
    function stepFocusIndex(delta) {
        const c = root.focusCandidates();
        if (c.length === 0) return;
        const at = root.focusIndex < 0 ? 0 : root.focusIndex;
        root.focusIndex = (at + delta + c.length) % c.length;
        root.refreshFocusHighlight();
        // The nav pane scrolls: a row the arrows walked onto has to be ON
        // SCREEN, or the ring is on something nobody can see.
        if (root.focusArea === "nav" && navFlick) {
            const r = c[root.focusIndex];
            const top = r.y, bottom = r.y + r.height;
            if (top < navFlick.contentY) navFlick.contentY = top;
            else if (bottom > navFlick.contentY + navFlick.height)
                navFlick.contentY = bottom - navFlick.height;
        }
    }
    // Enter (or Space) on the focused area. Every branch is an existing action
    // of this window, not a new one: the same functions the clicks call.
    function activateFocus() {
        if (root.focusArea === "toolbar") {
            const b = root.focusCandidates()[root.focusIndex];
            if (b) b.pressFromKeyboard();
            return;
        }
        if (root.focusArea === "nav") {
            const r = root.focusCandidates()[root.focusIndex];
            if (!r) return;
            if (typeof r.activated === "function") r.activated();
            else if (r.volume !== undefined) root.rowActivate(r.volume);
            return;
        }
        if (root.focusArea === "address") { root.beginPathEdit(); return; }
        if (root.focusArea === "search") { searchInput.forceActiveFocus(); return; }
        if (root.focusArea === "list" && root.selIndex >= 0) root.activate(root.selIndex);
    }

    // ── Shared geometry ─────────────────────────────────────────────────
    readonly property int rowH: 30
    // Selection is a MARKER INSIDE the row, not a box round it (REQUESTED
    // 2026-10-17, chosen from the file-selection study): a neutral wash with a
    // light rail on its left. Three reasons it is shaped this way:
    //   * the 1 px outline it replaces ran edge to edge, so its left side lay
    //     under the left scroll lane and read as a box drawn OUTSIDE the list
    //     rather than a state of the row;
    //   * the wash is grey (colOnLayer0, not colPrimary), so the marker never
    //     competes with the accent the folder icons already use;
    //   * every number lives here, not in the delegates, so the details list,
    //     the tiles, the places and the drive rows cannot drift apart, and the
    //     probe can report what is drawn.
    readonly property string selectionStyle: "rail"
    readonly property int selectionBorder: 0
    // The rail's width, and the 8 px lane the left scrollbar is drawn in: the
    // marker starts AT the lane, so scrollbar ink never crosses the selection.
    readonly property int selectionRail: 2
    readonly property int selectionLane: 8
    // The marker's breathing room inside a row: 2 above and below, 4 at the
    // right end so it does not touch the Size column's wall.
    readonly property int selectionGap: 2
    readonly property int selectionRightGap: 4
    readonly property int selectionRadius: 6
    // Three weights of the same grey: the picked row, the row the keyboard is
    // on (a touch stronger), and a hover (a touch weaker).
    readonly property var selectionWashColor: CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.925)
    readonly property var selectionWashStrongColor: CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88)
    readonly property var selectionWashHoverColor: CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.955)
    readonly property var selectionRailColor: CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.3)
    // ── What a drop target looks like ───────────────────────────────────
    // The same wash-and-rail as the selection, in the ACCENT -- because this is
    // not "where you are", it is "what will happen if you let go", and that is
    // the one state in this window that is worth the colour. It is spent only
    // while a drag is actually over the target, so it never competes with the
    // selection for the rest of the time.
    readonly property var dropWashColor: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.8)
    readonly property var dropRailColor: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.25)
    // One question, asked by every target in this file: is something being
    // dragged onto THIS path right now. Keeps the highlight rule in one place
    // instead of six copies of a string comparison.
    function isDropTarget(path) {
        const p = root.dropPathKey(path);
        return p.length > 0 && root.dropTargetPath === p;
    }
    // Column widths: sized by DRAGGING the divider before a column (see
    // HeaderCell's handle) and kept in a small JSON file beside the drive-letter
    // one -- the same shape, for the same reason. A width a person chose is a
    // preference, and a preference that resets is one nobody sets twice.
    readonly property int colMinWidth: 56
    readonly property string columnWidthsPath:
        `${Quickshell.env("HOME")}/.local/state/quickshell/files-column-widths.json`
    property var columnWidths: ({})
    property int colDate: root.columnWidths.date ?? 168
    property int colType: root.columnWidths.type ?? 132
    property int colSize: root.columnWidths.size ?? 96
    // ── Dragging a divider ──────────────────────────────────────────────
    // The arithmetic is HERE, out of the MouseArea, so that the pointer and a
    // test drive the same code -- and so the one rule it encodes is written
    // down instead of having to be reverse-engineered from a handler:
    //
    // THE RULER IS WINDOW COORDINATES. `mouse.x` is local to the cell being
    // dragged, and that cell's left edge IS the divider being dragged, so
    // measuring against it made the width fight its own reaction -- the pointer
    // moved, the width changed, the cell moved, and the next event was measured
    // from the new place: the divider stuttered and ran at the wrong speed.
    // Window coordinates are the frame the pointer moves in and the window does
    // not move.
    //
    // And the sign: the handle is on the LEFT edge of its column, and these
    // columns are pushed right by the flexible Name column, so a column that
    // GROWS pulls its own left edge -- the handle under the pointer -- to the
    // left. Subtracting sends the divider exactly with the pointer.
    property var columnDrag: null
    function columnDragBegin(cell, sceneX) {
        if (!cell || cell.widthSetter === null || cell.widthSetter === undefined)
            return false;
        root.columnDrag = { cell: cell, startWidth: cell.widthValue, startX: sceneX, clamped: false };
        return true;
    }
    function columnDragTo(sceneX) {
        const d = root.columnDrag;
        if (!d) return -1;
        const asked = Math.round(d.startWidth - (sceneX - d.startX));
        const floored = Math.max(root.colMinWidth, asked);
        // The ceiling keeps the flexible Name column at its own floor: past it
        // the layout cannot draw what the drag is setting, so the drag would go
        // on moving a number nothing follows. Clamping is right; clamping in
        // SILENCE is what read as a glitch, so the state is recorded -- against
        // what the pointer ASKED for, both ends, so the flag cannot be quietly
        // half-true the way a flag read off the clamped value would be.
        const ceiling = d.cell.maxWidth;
        const capped = ceiling > root.colMinWidth ? Math.min(floored, ceiling) : floored;
        d.clamped = capped !== asked;
        d.cell.widthSetter(capped);
        return capped;
    }
    function columnDragEnd() {
        const was = root.columnDrag !== null;
        root.columnDrag = null;
        if (was) root.saveColumnWidths();
        return was;
    }
    // ── Dragging the preview's own divider ──────────────────────────────
    // The same rule as above, one boundary over: WINDOW coordinates, because the
    // pane's edge IS the divider -- measured locally, the width would fight its
    // own reaction and the divider would stutter and run at the wrong speed.
    // And the same sign, because this divider is the preview's LEFT (or TOP)
    // edge: the preview is the far pane, so a preview that GROWS drags its own
    // edge inward, towards the list -- subtracting sends the edge exactly with
    // the pointer.
    //
    // Both axes ride one machine: which one is live is the layout's answer
    // (previewBelow), not the pointer's, because the dragged edge in the stacked
    // layout is the top one and it is measured in y.
    property var previewDrag: null
    function previewClamp(axis, asked) {
        const floor = axis === "height" ? root.previewMinHeight : root.previewPaneMinWidth;
        const ceiling = axis === "height" ? root.previewPaneMaxHeight : root.previewPaneMaxWidth;
        // The ceiling can land under the floor in a window too small for both;
        // the floor wins, because a preview you cannot see is not a fix for a
        // list you cannot read.
        return Math.max(floor, Math.min(asked, ceiling));
    }
    function previewDragBegin(axis, scenePoint) {
        const h = axis === "height";
        root.previewDrag = {
            axis: h ? "height" : "width",
            startSize: h ? root.previewStackHeight : root.previewPaneWidth,
            start: scenePoint,
            clamped: false
        };
        return true;
    }
    function previewDragTo(scenePoint) {
        const d = root.previewDrag;
        if (!d) return -1;
        const asked = Math.round(d.startSize - (scenePoint - d.start));
        const set = root.previewClamp(d.axis, asked);
        // Recorded against what the pointer ASKED for, both ends, so a drag that
        // is pinned at a limit can say so instead of silently moving a number
        // that nothing follows.
        d.clamped = set !== asked;
        if (d.axis === "height") root.previewStackHeight = set;
        else root.previewPaneWidth = set;
        return set;
    }
    function previewDragEnd() {
        const was = root.previewDrag !== null;
        root.previewDrag = null;
        if (was) root.saveColumnWidths();
        return was;
    }
    // Replay a divider drag from a terminal: the same calls the pointer makes,
    // with the same window coordinates, ONE STEP PER CALL -- because the widths
    // a drag sets and the pixels the layout then draws are two different things,
    // and only the second one is on screen. A caller steps, lets the layout
    // settle, and reads probeColumns to see where the divider ENDED UP. "It
    // glitches when you drag it" in numbers: the divider has to land under the
    // pointer, and it must not drift when a step is large.
    property var probeDragOrigin: null
    function probeColumnDragBegin(index) {
        const cell = headerRow.children[Number(index)];
        if (!cell) return "no such column";
        // 2 px in: inside the grab band, and the pointer keeps that place in
        // the handle for the whole drag, so the cell's left edge has to stay
        // exactly 2 px to the left of wherever the pointer goes.
        const at = cell.mapToItem(root, 0, 0);
        root.probeDragOrigin = { cell: cell, x: Math.round(at.x) + 2 };
        return root.columnDragBegin(cell, root.probeDragOrigin.x) ? "began" : "that column has no handle";
    }
    function probeColumnDragStep(delta) {
        const o = root.probeDragOrigin;
        if (!o) return "no drag in progress";
        const pointer = o.x + Number(delta);
        const set = root.columnDragTo(pointer);
        return JSON.stringify({
            label: String(o.cell.label ?? ""),
            pointer: Math.round(pointer),
            wanted: Math.round(set),
            clamped: root.columnDrag ? root.columnDrag.clamped === true : false
        });
    }
    function probeColumnDragEnd() {
        return root.columnDragEnd() ? "ended" : "no drag in progress";
    }
    // ── The preview's divider, as a probe ───────────────────────────────
    // The same three answers the columns' probe gives, for the same reason: the
    // band asks the pointer to look like the two-headed arrow WITHOUT a pointer
    // having to be on the glass, and a drag is replayed through the very
    // functions the MouseArea calls, one step per call, so "the pane follows the
    // pointer" is a number and not an impression.
    //
    // Which band is live is the layout's answer (previewBelow), because in the
    // stacked layout the edge worth dragging is the top one. That index is also
    // the only seam the mouse and this share: both read previewDivider().
    function previewDivider() {
        return root.previewBelow ? previewDividerUnder : previewDividerSide;
    }
    function probePreviewDivider() {
        const band = root.previewDivider();
        const at = band.mapToItem(root, 0, 0);
        const axis = root.previewBelow ? "height" : "width";
        return JSON.stringify({
            axis: axis,
            // The cursor as a NAME: the flag on the item is a number, and a
            // number would not say which of the two arrows it is.
            cursor: band.cursorShape === Qt.SizeHorCursor ? "size-horizontal"
                : (band.cursorShape === Qt.SizeVerCursor ? "size-vertical" : String(band.cursorShape)),
            bandWidth: Math.round(band.width),
            bandHeight: Math.round(band.height),
            bandX: Math.round(at.x),
            bandY: Math.round(at.y),
            visible: band.visible === true,
            hovered: band.containsMouse === true,
            dragging: band.dragging === true,
            size: axis === "height" ? root.previewStackHeight : root.previewPaneWidth,
            min: axis === "height" ? root.previewMinHeight : root.previewPaneMinWidth,
            max: axis === "height" ? root.previewPaneMaxHeight : root.previewPaneMaxWidth,
            below: root.previewBelow,
            pane: root.previewPane
        });
    }
    property var probePreviewDragAt: -1
    function probePreviewDragBegin() {
        const band = root.previewDivider();
        const at = band.mapToItem(root, 0, 0);
        const axis = root.previewBelow ? "height" : "width";
        root.probePreviewDragAt = Math.round(axis === "height" ? at.y + 2 : at.x + 2);
        return root.previewDragBegin(axis, root.probePreviewDragAt) ? "began" : "no divider";
    }
    function probePreviewDragStep(delta) {
        if (!root.previewDrag) return "no drag in progress";
        const pointer = root.probePreviewDragAt + Number(delta);
        const set = root.previewDragTo(pointer);
        return JSON.stringify({
            axis: root.previewDrag.axis,
            // Where the pointer is, where the drag started and what the size
            // ended up as -- and NOT where the edge is: the layout has not run
            // yet at this instant, so a position read here would be the one
            // from before the step. A caller reads that one from
            // probePreviewDivider after letting the layout settle, which is the
            // only reading that has pixels behind it.
            pointer: Math.round(pointer),
            from: Math.round(root.probePreviewDragAt),
            wanted: set,
            clamped: root.previewDrag.clamped === true,
            width: root.previewPaneWidth,
            height: root.previewStackHeight,
            below: root.previewBelow
        });
    }
    function probePreviewDragEnd() {
        return root.previewDragEnd() ? "ended" : "no drag in progress";
    }
    function loadColumnWidths() {
        root.sh("cat " + root.shq(root.columnWidthsPath) + " 2>/dev/null", "column-widths");
    }
    function saveColumnWidths() {
        const path = CF.FileUtils.trimFileProtocol(root.columnWidthsPath);
        // The preview's size rides along in the same file: one preference store,
        // one writer, and the reader below is already running at startup.
        const payload = JSON.stringify({ date: root.colDate, type: root.colType, size: root.colSize,
            preview: root.previewPaneWidth, previewHeight: root.previewStackHeight });
        columnWidthsWriter.command = ["bash", "-c",
            `mkdir -p '${path.split("/").slice(0, -1).join("/")}'`
            + ` && printf '%s' '${payload.replace(/'/g, `'\\''`)}' > '${path}'`];
        columnWidthsWriter.running = false;
        columnWidthsWriter.running = true;
    }
    Process { id: columnWidthsWriter }
    readonly property int navWidth: 208
    readonly property bool showNav: !root.pickerMode || root.width >= 720
    // ── Where the preview goes ──────────────────────────────────────────
    // Beside the files while there is room for both, underneath them when there
    // is not. The question is asked of the space the two panes will actually
    // get -- the window minus the navigation pane and the body margins -- and
    // not of the window itself, because the answer is about the file list: at
    // 700 px of window with a 208 px pane in it there are only 480 px left for
    // four columns of file details, and a 300 px preview next to that is not
    // "well spaced" by any measure.
    //
    // How BIG the preview is, however, is not the layout's decision to make once
    // and for all: the divider between the two panes is draggable (the
    // previewDivider bands on previewCard), so these two sizes are plain
    // writable state, persisted in the same preference file as the column
    // widths -- a size you chose that resets on relaunch is one nobody sets
    // twice.
    property int previewPaneWidth: 300
    property int previewStackHeight: 320
    // The floors. A pane narrower than this is a caption, not a preview.
    readonly property int previewPaneMinWidth: 160
    readonly property int previewMinHeight: 140
    // ONE number for "how little file list is still a list", asked by BOTH the
    // drag's ceiling below and the question below that -- which is why widening
    // the preview can flip it underneath the list instead of squeezing four
    // columns into a smear.
    readonly property int fileListMinWidth: 400
    readonly property int fileListMinHeight: 240
    readonly property bool previewBelow: {
        const body = root.width - (root.showNav ? root.navWidth + 18 : 12);
        // 400 px of file list is the floor: below that the four columns of
        // details stop being columns and start being a smear, at which point the
        // preview is worth more underneath the list than beside it. The default
        // window (1080) keeps its preview on the right; a half-screen window on
        // a laptop does not, which is the case this was asked for.
        return body < root.previewPaneWidth + root.fileListMinWidth;
    }
    // What the drag may reach, read off the LIVE grid rather than computed from
    // the window: contentGrid is the box the two panes are actually laid out in,
    // so its size is the only one that cannot disagree with the pixels on
    // screen. The list keeps its floor at both ends -- when the preview is
    // beside the list that is a width, when it is underneath it is a height.
    readonly property int previewPaneMaxWidth: Math.max(root.previewPaneMinWidth,
        contentGrid.width - contentGrid.columnSpacing - root.fileListMinWidth)
    readonly property int previewPaneMaxHeight: Math.max(root.previewMinHeight,
        contentGrid.height - contentGrid.rowSpacing - root.fileListMinHeight)
    readonly property int commandBarHeight: 40
    // Quiet lock: the header reads the way the lock screen does -- the micro
    // row (nav, crumbs, search) first, the folder's name at quietTitlePx under
    // it with the counts and the free space as tracked micro-caps on its right,
    // and the commands as words UNDER the name, not in a bar above it. That is
    // the order the design study drew (design: the "Quiet lock" study, the .top
    // block: kicker -> huge -> cmdrow), so the name leads and the actions follow.
    //
    // 38 px, not the study's 41: the study drew the name on an 853 px mock, and
    // at this window's font the 41 px line read a size larger than the drawing.
    // Light weight, -0.038 em tracking, same as the lock screen's own line.
    readonly property int quietTitlePx: 38
    // 48, not 46: a 38 px line in this font is 48 px tall once the descender
    // is in it (probeQuietHeader measures the box), so a 46 px row let the name
    // spill 2 px into the command row below.
    readonly property int quietTitleRowHeight: 48
    // The study's own rhythm, in px: 8 above the name, 48 for the line itself,
    // then the 40 px command row. The gap above is what the crumbs row used to
    // have all to itself, and without it the name read as hanging off the path
    // box -- the "title spacing" that was wrong.
    readonly property int addressBarHeight: 26 + 8 + 48
    readonly property int statusBarHeight: 26

    // ── The window ──────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Address bar ────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            id: addressBar
            Layout.preferredHeight: root.addressBarHeight
            // Air above the micro row: with the commands moved down to the
            // bottom of the header there is nothing pinning this row to the
            // window's top edge any more, and a path glued to it read as
            // cropped rather than as quiet.
            Layout.topMargin: 10
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            radius: Appearance.rounding.small
            // Quiet lock: no card fill. The bar belongs to the window, and the
            // two rows below hold themselves together with type and spacing
            // rather than with a box.
            color: "transparent"
            FocusRing { area: "address" }

            ColumnLayout {
            anchors.fill: parent
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                // Fixed, so the title row below gets exactly the rest of the
                // bar: two flexible rows would split 72 px wherever the layout
                // engine felt like it, and the crumbs would sit lower on some
                // days than others.
                Layout.preferredHeight: 26
                Layout.minimumHeight: 26
                Layout.maximumHeight: 26
                Layout.leftMargin: 4
                Layout.rightMargin: 6
                spacing: 2

                IconButton { symbol: "arrow_back"; tip: Translation.tr("Back"); enabled: root.historyIndex > 0; onActivated: root.goBack() }
                IconButton { symbol: "arrow_forward"; tip: Translation.tr("Forward"); enabled: root.historyIndex < root.history.length - 1; onActivated: root.goForward() }
                IconButton { symbol: "arrow_upward"; tip: Translation.tr("Up"); enabled: !root.atThisPc; onActivated: root.goUp() }

                // ── The path box ────────────────────────────────────────────
                // A boxed path with a hairline and rounded corners, because two
                // different clicks live in here and the box is what says so:
                //
                //   on a folder in the path   walk there. The crumb keeps its
                //                            own click, and the crumbs are drawn
                //                            OVER the background click -- they
                //                            are declared after it -- so a click
                //                            that lands on a name goes to the
                //                            name and everything else falls
                //                            through to the box.
                //   anywhere else in the box  the path opens for editing, fully
                //                            selected, so it can be copied or
                //                            typed over (Explorer's Alt+D/Ctrl+L
                //                            behaviour, on a larger target).
                Item {
                    id: pathBox
                    Layout.fillWidth: true
                    Layout.minimumWidth: 96
                    Layout.fillHeight: true
                    // Crumbs that do not fit are not drawn at all (crumbFit),
                    // and this is the second belt: a path that is somehow wider
                    // than its box is cut off at the border rather than spilling
                    // under the search field next to it.
                    clip: true

                    // ── Fitting the path into the box ──────────────────────
                    // This machine's own home is five levels deep, so a path
                    // longer than the window is the normal case, not the edge
                    // case. The box cannot grow -- the search field lives to its
                    // right and the two must never overlap -- so the crumbs are
                    // measured and only the ones that fit are kept, from the
                    // current folder backwards, with a leading "…" standing for
                    // the levels that were folded away. Clicking the "…" walks
                    // to the oldest hidden level: the same gesture its name
                    // would have given.
                    TextMetrics {
                        id: crumbMetrics
                        font.family: Appearance.font.family.main
                        font.pixelSize: Appearance.font.pixelSize.smaller
                    }
                    readonly property int crumbChevron: 17   // glyph + its spacing
                    property var crumbFit: ({ items: [], hidden: 0 })
                    // Counted so a check can tell "the bar re-measured" from "the
                    // bar is showing whatever it measured last time".
                    property int fitCount: 0
                    // MEASURED, NOT BOUND. A binding cannot ask TextMetrics for a
                    // width: reading `advanceWidth` depends on `text`, and
                    // setting `text` from inside that same binding is a binding
                    // that invalidates itself -- QML's answer is a loop warning
                    // and a property that settles wherever it happens to. So the
                    // widths are taken in a plain call, and the result is written
                    // to `crumbFit` like any other piece of state.
                    function crumbWidth(label) {
                        // Measured in exactly what is drawn. The crumbs are
                        // upper-cased for the quiet-lock voice, and TextMetrics
                        // has no letterSpacing, so the tracking is added by hand,
                        // per character. Skipping either one under-measures the
                        // crumb, and the fit then puts a crumb past the wall of
                        // the box it was supposed to fit in.
                        const shown = String(label ?? "").toUpperCase();
                        crumbMetrics.text = shown;
                        return Math.ceil(crumbMetrics.advanceWidth) + 16 + crumbChevron
                            + Math.ceil(shown.length * 1.8);
                    }
                    function refitCrumbs() {
                        fitCount++;
                        const all = root.crumbs;
                        const budget = Math.max(44, width - 4);
                        const kept = [];
                        let hidden = 0;
                        if (all.length > 0) {
                            // Room is reserved for the "…" chip even when it
                            // turns out not to be needed: an ellipsis that gets
                            // clipped away is an affordance nobody can click.
                            const reserve = crumbWidth("…");
                            let used = 0;
                            for (let i = all.length - 1; i >= 0; i--) {
                                const w = crumbWidth(all[i].label);
                                // The first crumb drawn is always kept: the folder
                                // you are IN is the one thing that must never be
                                // elided away.
                                if (kept.length > 0 && used + w + reserve > budget) break;
                                used += w;
                                kept.unshift(all[i]);
                            }
                            hidden = all.length - kept.length;
                            if (hidden > 0)
                                kept.unshift({ label: "…", path: all[hidden - 1].path });
                        }
                        crumbFit = { items: kept, hidden: hidden };
                    }
                    // The two things that change the answer: the box getting
                    // narrower, and the path itself. The latter arrives as a
                    // change of `crumbs` on the root, which is watched from in
                    // here so this can never fire before the box exists.
                    onWidthChanged: refitCrumbs()
                    Component.onCompleted: refitCrumbs()
                    Connections {
                        target: root
                        function onCrumbsChanged() { pathBox.refitCrumbs(); }
                    }

                    // The box's own hairline and rounded corners, with an id so
                    // a check can measure them rather than take the comment's
                    // word for it (probeLayout reports border and radius).
                    Rectangle {
                        id: pathBoxFrame
                        anchors.fill: parent
                        radius: Appearance.rounding.small
                        color: "transparent"
                        border.width: 1
                        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.45)
                    }

                    // Declared FIRST so the crumbs sit on top of it: a click in
                    // the empty part of the box lands here and edits the path.
                    MouseArea {
                        id: pathBoxEmpty
                        anchors.fill: parent
                        visible: !root.editingPath
                        hoverEnabled: true
                        cursorShape: Qt.IBeamCursor
                        onClicked: root.beginPathEdit()
                    }

                    Row {
                        id: crumbRow
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 2
                        spacing: 2
                        visible: !root.editingPath
                        Repeater {
                            id: crumbRepeater
                            model: pathBox.crumbFit.items
                            delegate: Row {
                                required property var modelData
                                required property int index
                                spacing: 2
                                Rectangle {
                                    height: 24
                                    width: crumbText.implicitWidth + 16
                                    radius: Appearance.rounding.small
                                    color: root.isDropTarget(modelData.path)
                                        ? root.dropWashColor
                                        : (crumbHover.containsMouse
                                            ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.86)
                                            : "transparent")
                                    StyledText {
                                        id: crumbText
                                        anchors.centerIn: parent
                                        // Quiet lock: the path above the name is
                                        // tracked micro-caps -- the same voice as
                                        // the HUD numbers on the right, and one
                                        // step below the name in weight.
                                        text: String(modelData.label ?? "").toUpperCase()
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        font.letterSpacing: 1.8
                                        font.weight: Font.Medium
                                        color: Appearance.colors.colSubtext
                                    }
                                    MouseArea {
                                        id: crumbHover
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.navigateTo(modelData.path)
                                    }
                                    // A crumb is a folder you can already see, so
                                    // it is also the shortest way to say "put it
                                    // in there": dropping a file on an ancestor
                                    // copies it into that ancestor.
                                    DropArea {
                                        objectName: "drop-crumb"
                                        anchors.fill: parent
                                        onEntered: root.dropEntered(modelData.path)
                                        onExited: root.dropExited(modelData.path)
                                        onDropped: drop => {
                                            if (!drop.hasUrls) return;
                                            root.clearDropTarget();
                                            root.receiveDrop(drop.urls, modelData.path,
                                                drop.action === Qt.MoveAction);
                                        }
                                    }
                                }
                                MaterialSymbol {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: index < pathBox.crumbFit.items.length - 1
                                    text: "chevron_right"
                                    iconSize: 15
                                    color: Appearance.m3colors.m3outline
                                }
                            }
                        }
                    }

                    StyledTextInput {
                        id: pathLabel
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 4
                        verticalAlignment: TextInput.AlignVCenter
                        visible: root.editingPath
                        text: root.currentFolderPath()
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        onActiveFocusChanged: if (!activeFocus && root.editingPath) root.finishPathEdit()
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) {
                                root.editingPath = false;
                                keyLayer.forceActiveFocus();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                root.finishPathEdit();
                                event.accepted = true;
                            }
                        }
                        // While the path is being typed, Escape must not reach
                        // the app-level shortcut that closes the whole popup.
                        Keys.onShortcutOverride: event => {
                            if (event.key === Qt.Key_Escape) event.accepted = true;
                        }
                    }
                }

                // Searching filters the folder you are in, which is what
                // Explorer's box does before it walks an index.
                Rectangle {
                    id: searchBox
                    FocusRing { area: "search" }
                    // Wide enough to type in, never wider than a fifth of the
                    // bar. This is the box that used to run into the path when
                    // the window was made small; it now gives way as well as the
                    // crumbs do, and it has a floor so it cannot vanish into a
                    // sliver. Two shrinking boxes with floors cannot overlap.
                    Layout.preferredWidth: root.pickerMode ? 0
                        : Math.round(Math.max(124, Math.min(200, root.width * 0.2)))
                    Layout.minimumWidth: root.pickerMode ? 0 : 124
                    Layout.preferredHeight: 26
                    visible: !root.pickerMode
                    radius: Appearance.rounding.small
                    color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.25)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 4
                        MaterialSymbol { text: "search"; iconSize: 14; color: Appearance.m3colors.m3outline }
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            StyledTextInput {
                                id: searchInput
                                anchors.fill: parent
                                verticalAlignment: TextInput.AlignVCenter
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                onTextChanged: root.filter = text
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: searchInput.text.length === 0
                                text: Translation.tr("Search")
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                            }
                        }
                    }
                }
            }

                // Air between the path and the name, counted rather than left
                // to the layout: the title row is a fixed height, so a gap that
                // is not a row of its own would land under the name instead of
                // over it.
                Item { Layout.fillWidth: true; Layout.preferredHeight: 8 }

                // ── The folder's name, huge ────────────────────────────
                // What this window is showing, at the size that question
                // deserves, with the numbers that answer "how much of it" as
                // tracked micro-caps on the right. The path stays above in the
                // crumbs: this line is the answer, not the location. A click on
                // the name opens the path for editing -- the same thing the
                // crumbs' empty space does, on a target you can find.
                RowLayout {
                    id: quietTitleRow
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: root.quietTitleRowHeight
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    spacing: 12

                    Item {
                        id: quietTitleHit
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        StyledText {
                            id: quietTitle
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            // Explicit width, so a name too long for the row
                            // elides at the HUD instead of running under it.
                            width: Math.min(implicitWidth, parent.width)
                            text: root.atThisPc
                                ? Translation.tr("This PC")
                                : (root.crumbs.length > 0 ? root.crumbs[root.crumbs.length - 1].label : "")
                            font.pixelSize: root.quietTitlePx
                            font.weight: Font.Light
                            // -0.038 em at this size, in px: the tracking the
                            // lock screen sets its clock in. It tracks the size
                            // rather than being a constant, so the name keeps
                            // the drawing's fit if the size is tuned again.
                            font.letterSpacing: -0.038 * root.quietTitlePx
                            color: Appearance.colors.colOnLayer0
                            elide: Text.ElideRight
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.IBeamCursor
                            onClicked: root.beginPathEdit()
                        }
                    }

                    // The HUD: how much is here and how much room is left.
                    // Right-aligned, three lines, micro-caps -- the same voice
                    // as the crumbs on the row above.
                    ColumnLayout {
                        id: quietHud
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                        spacing: 3
                        StyledText {
                            Layout.alignment: Qt.AlignRight
                            text: root.rows.length + " " + Translation.tr("items").toUpperCase()
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            font.letterSpacing: 1.8
                            font.weight: Font.Medium
                            color: Appearance.colors.colSubtext
                        }
                        StyledText {
                            Layout.alignment: Qt.AlignRight
                            text: root.folderCount + " " + Translation.tr("folders").toUpperCase()
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            font.letterSpacing: 1.8
                            font.weight: Font.Medium
                            color: Appearance.colors.colSubtext
                        }
                        StyledText {
                            Layout.alignment: Qt.AlignRight
                            visible: root.storageText.length > 0
                            text: root.storageText.toUpperCase()
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            font.letterSpacing: 1.8
                            font.weight: Font.Medium
                            color: Appearance.colors.colSubtext
                        }
                    }
                }
            }   // the ColumnLayout: micro row over title row
        }

        // ── Command bar ─────────────────────────────────────────────────
        // UNDER the name, which is the study's order and the point of it: the
        // folder you are in is the loudest thing on the bar, and the words that
        // act on it sit under that line as a footnote rather than over it as a
        // toolbar. One hairline closes the header; the body needs no top rule
        // of its own.
        Rectangle {
            Layout.fillWidth: true
            id: commandBar
            Layout.preferredHeight: visible ? root.commandBarHeight : 0
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            // NOT hidden by a dialog any more. It used to be, because every one
            // of its commands acted on FILES (New, Cut, Rename, Delete) and a
            // dialog has no business renaming anything. But the row also holds
            // the controls that are about LOOKING at the folder rather than
            // changing it, and those are exactly what the file-open screen was
            // missing (REQUESTED 2026-10-24: "in the file open screen ... a
            // view change added so i can select to see invisible files or
            // change the size"). So the row stays and the file commands alone
            // stand down in a dialog (each one's own `visible` below).
            visible: true
            color: "transparent"
            FocusRing { area: "toolbar" }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: Appearance.colors.colOutlineVariant
            }
            RowLayout {
                id: commandRow
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 2

                // Quiet lock: the file actions are words, not glyphs in boxes.
                // Same handlers, same tooltips, same enabled rules as the
                // buttons they replace -- only the drawing changed.
                // New is a drop-down of the two creates rather than a shortcut
                // for "folder": the toolbar is the one place that is always
                // there, so a FILE has to be reachable from it too (the
                // empty-space menu is not an option in a folder with files).
                QuietCommand {
                    id: newCommand
                    label: Translation.tr("New")
                    primary: true
                    tip: Translation.tr("New folder or file")
                    // The file commands: the app's, not a dialog's. See the note
                    // on the bar's own `visible` above.
                    visible: !root.pickerMode
                    onActivated: root.openCreateMenu()
                }
                QuietCommand { label: Translation.tr("Cut"); tip: Translation.tr("Cut"); enabled: root.hasSelection; visible: !root.pickerMode; onActivated: root.copySelection(true) }
                QuietCommand { label: Translation.tr("Copy"); tip: Translation.tr("Copy"); enabled: root.hasSelection; visible: !root.pickerMode; onActivated: root.copySelection(false) }
                QuietCommand {
                    label: Translation.tr("Paste")
                    tip: Translation.tr("Paste")
                    enabled: root.clipboard.length > 0
                    visible: !root.pickerMode
                    onActivated: root.pasteInto(root.currentFolderPath())
                }
                QuietCommand {
                    label: Translation.tr("Rename")
                    tip: Translation.tr("Rename")
                    enabled: root.selection.length === 1
                    visible: !root.pickerMode
                    onActivated: root.beginRename(root.selection[0])
                }
                QuietCommand { label: Translation.tr("Delete"); tip: Translation.tr("Delete"); enabled: root.hasSelection; visible: !root.pickerMode; onActivated: root.trashItems(root.selection) }
                QuietCommand { label: Translation.tr("Refresh"); tip: Translation.tr("Refresh"); visible: !root.pickerMode; onActivated: root.refresh() }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 20; color: Appearance.colors.colOutlineVariant; visible: !root.pickerMode }
                IconButton {
                    id: sortBtn
                    symbol: "sort"
                    tip: Translation.tr("Sort")
                    visible: !root.pickerMode
                    onActivated: (px, py) => {
                        const p = sortBtn.mapToItem(root, px, py);
                        root.openMenu(p.x, p.y + 6, "sort:");
                    }
                }
                // ── The three controls a dialog DOES want ─────────────────
                // List/grid, how big the tiles are, and whether dotfiles are
                // shown. They sat in this row all along for the app; from
                // 2026-10-24 they are what the row holds in the file-open
                // screen too.
                //
                // The word is there because in a dialog the row has no other
                // words to explain itself: in the app it opens with NEW / CUT /
                // COPY and reads as a command bar, while here it would be four
                // glyphs floating under the folder's name, which is the kind of
                // thing you do not find. Tracked micro-caps, the same as every
                // other label on this header.
                StyledText {
                    Layout.leftMargin: 4
                    Layout.rightMargin: 2
                    visible: root.pickerMode
                    text: Translation.tr("View").toUpperCase()
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    font.letterSpacing: 1.9
                    font.weight: Font.Medium
                    color: Appearance.colors.colSubtext
                }
                IconButton {
                    id: viewToggleBtn
                    symbol: root.viewMode === "details" ? "grid_view" : "list"
                    tip: root.viewMode === "details" ? Translation.tr("Tiles view") : Translation.tr("Details view")
                    onActivated: root.setViewMode(root.viewMode === "details" ? "tiles" : "details")
                }
                // The tile size, one step a press. Drawn only in the view it
                // applies to -- a details row's height is the list's own
                // decision, so a "smaller" there would be a button that does
                // nothing.
                IconButton {
                    id: sizeMinus
                    symbol: "zoom_out"
                    tip: Translation.tr("Smaller tiles")
                    visible: root.viewMode === "tiles"
                    enabled: root.tileSize > 0
                    onActivated: root.stepTileSize(-1)
                }
                IconButton {
                    id: sizePlus
                    symbol: "zoom_in"
                    tip: Translation.tr("Bigger tiles")
                    visible: root.viewMode === "tiles"
                    enabled: root.tileSize < root.tileSizeCaps.length - 1
                    onActivated: root.stepTileSize(1)
                }
                IconButton {
                    id: previewPaneBtn
                    symbol: root.previewPane ? "side_navigation" : "preview"
                    tip: root.previewPane ? Translation.tr("Hide the preview pane") : Translation.tr("Show a preview of the selected file")
                    active: root.previewPane
                    // A preview pane is the window's shape, not the dialog's:
                    // the card is 1100 wide and a third of it spent on a
                    // preview is a third of the answer missing.
                    visible: !root.pickerMode
                    onActivated: root.previewPane = !root.previewPane
                }
                IconButton {
                    id: hiddenBtn
                    symbol: root.showHidden ? "visibility_off" : "visibility"
                    tip: root.showHidden ? Translation.tr("Hide hidden files") : Translation.tr("Show hidden files")
                    active: root.showHidden
                    onActivated: root.showHidden = !root.showHidden
                }
                Item { Layout.fillWidth: true }
                // Tabs, once there is more than one: the strip is what makes
                // them discoverable and is where they are closed (middle-click
                // or right-click, as in a browser).
                RowLayout {
                    visible: root.tabsAvailable && root.tabs.length > 1
                    spacing: 4
                    Repeater {
                        model: root.tabs
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            Layout.preferredHeight: 26
                            implicitWidth: Math.min(150, tabText.implicitWidth + 26)
                            radius: Appearance.rounding.small
                            color: index === root.activeTab
                                ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)
                                : (tabHover.containsMouse
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88) : "transparent")
                            // A tab title is cut at the tab's own wall: the
                            // 150 px cap is the tab's width, and the title stops
                            // there (elided) instead of running on through the
                            // close glyph and the next tab -- MEASURED before
                            // this: a 124 px slot painting 381 px at 0.3
                            // opacity, over two other tabs and the "+".
                            CutLabel {
                                id: tabText
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 26
                                text: root.tabLabel(modelData)
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colOnLayer0
                            }
                            MaterialSymbol {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                text: "close"
                                iconSize: 13
                                color: Appearance.m3colors.m3outline
                            }
                            MouseArea {
                                id: tabHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mouse => {
                                    if (mouse.button === Qt.LeftButton) root.selectTab(index);
                                    else root.closeTab(index);
                                }
                            }
                        }
                    }
                }
                IconButton { id: newTabBtn; symbol: "add"; tip: Translation.tr("New tab"); visible: root.tabsAvailable; onActivated: root.newTab("") }
            }
        }


        // ── Body: navigation pane + file pane ──────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 6
            spacing: 6

            Rectangle {
                id: navPane
                Layout.preferredWidth: root.showNav ? root.navWidth : 0
                Layout.fillHeight: true
                visible: root.showNav
                radius: Appearance.rounding.small
                color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.55)
                clip: true
                FocusRing { area: "nav" }

                Flickable {
                    id: navFlick
                    anchors.fill: parent
                    anchors.margins: 6
                    contentHeight: navColumn.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: StyledScrollBar {}

                    ColumnLayout {
                        id: navColumn
                        width: parent.width
                        spacing: 2

                        NavHeading { text: Translation.tr("Quick access") }
                        Repeater {
                            id: quickRepeater
                            model: root.quickPlaces
                            delegate: NavRow {
                                required property var modelData
                                label: modelData.label
                                symbol: modelData.icon
                                path: modelData.path
                                active: !root.atThisPc && root.folderPath === modelData.path
                                onActivated: root.navigateTo(modelData.path)
                            }
                        }

                        NavHeading {
                            text: Translation.tr("This PC")
                            extra: true
                            onExtraActivated: root.refreshVolumes()
                        }
                        NavRow {
                            label: Translation.tr("This PC")
                            symbol: "computer"
                            active: root.atThisPc
                            onActivated: root.navigateTo(root.thisPc)
                        }
                        Repeater {
                            id: navVolumeRepeater
                            model: root.navVolumes
                            delegate: NavVolumeRow {
                                required property var modelData
                                volume: modelData
                            }
                        }
                        // ── Advanced: the plumbing ──────────────────────────
                        // Small internal partitions and unmounted leftover ones
                        // (/boot, the EFI and recovery partitions, the other
                        // half of a Windows install). They are drives you can
                        // open and mount like any other, and they are exactly
                        // the rows that make the list look like a disk dump, so
                        // they are folded behind one label instead of removed.
                        NavHeading {
                            visible: root.navAdvancedVolumes.length > 0
                            text: Translation.tr("Advanced")
                            expandable: true
                            expanded: root.showAdvancedVolumes
                            onExpandToggled: root.showAdvancedVolumes = !root.showAdvancedVolumes
                        }
                        Repeater {
                            id: navAdvancedRepeater
                            model: root.showAdvancedVolumes ? root.navAdvancedVolumes : []
                            delegate: NavVolumeRow {
                                required property var modelData
                                volume: modelData
                            }
                        }
                        Item { Layout.preferredHeight: 6 }
                    }
                }
            }

            // ── Files and preview: beside each other, or stacked ────────
            //
            // One grid, two columns normally (files | preview) and one column
            // once the window is too small for two to be well spaced -- at which
            // point the preview moves UNDER the file list, where it still shows
            // the selection instead of squeezing the columns into slivers.
            // GridLayout rather than RowLayout because that switch is exactly
            // what it is for: the same two items, one property away from being a
            // row or a column.
            //
            // The threshold is measured against the space the grid will actually
            // get (the window minus the navigation pane and the body margins),
            // not against the window, because 700 px of window with a 208 px
            // navigation pane in it is only about 480 px of files -- where a
            // 300 px preview leaves four columns of nothing.
            GridLayout {
                id: contentGrid
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: root.previewBelow ? 1 : 2
                columnSpacing: 6
                rowSpacing: 6

                // ── The file pane ────────────────────────────────────────
                Rectangle {
                    id: filePane
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Appearance.rounding.small
                    color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.7)
                    clip: true
                    // NO ring here (REQUESTED 2026-10-13: "remove that ugly
                    // line around the content"). The list is the DEFAULT area
                    // -- `focusArea` starts on it and every click on a row,
                    // a tile or the empty space brings it back (see
                    // `selectIndex`) -- so its ring was not feedback, it was a
                    // border the app appeared to have grown: always on screen,
                    // always in the same place, saying the same thing. The
                    // areas a look at the window does NOT otherwise account
                    // for keep theirs, which is where a ring is still the only
                    // answer to "where did Tab put the keyboard"; in the list
                    // the selection highlight already gives that answer, and
                    // with nothing selected the arrows have nothing to walk.

                    // ── Empty space: the folder's own menu ──────────────────
                    //
                    // The pane itself, and first, so it sits under everything
                    // the ColumnLayout draws. This is the one that answers for
                    // a folder with NOTHING in it: both views are gated on
                    // `rows.length > 0` (they are not even visible), so nothing
                    // else in here is on screen to be pressed, and the
                    // right-click a person makes in an empty folder is aimed at
                    // this rectangle. It also covers every other part of the
                    // pane that is not a row -- under the last row of a short
                    // listing, the strip beside the cells of a part-filled
                    // tiles row, the status bar's own background.
                    //
                    // Right button only: the left press stays the view's (drag
                    // to select, click to clear), exactly as before.
                    MouseArea {
                        id: paneEmptySpace
                        anchors.fill: parent
                        z: -1
                        acceptedButtons: Qt.RightButton
                        onClicked: mouse => root.openFolderMenuAt(paneEmptySpace, mouse.x, mouse.y)
                    }

                    // ── Dropping onto the pane ─────────────────────────────
                    // The fallback destination, and the only one that needs no
                    // aim: whatever is dropped anywhere in here that is not a
                    // folder row, a tile, a breadcrumb or a place lands in the
                    // folder on screen. Declared before the ColumnLayout, so
                    // the rows and the tiles inside it are picked first -- a
                    // drag over the pane and not over any of them keeps this
                    // one, and that is what makes the pane a target too.
                    DropArea {
                        id: paneDropArea
                        objectName: "drop-pane"
                        anchors.fill: parent
                        enabled: !root.atThisPc
                        onEntered: root.dropEntered(root.currentFolderPath())
                        onExited: root.dropExited(root.currentFolderPath())
                        onDropped: drop => {
                            if (!drop.hasUrls) return;
                            const dest = root.currentFolderPath();
                            root.clearDropTarget();
                            root.receiveDrop(drop.urls, dest, drop.action === Qt.MoveAction);
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // This PC: one tile per volume, which is exactly the shape
                        // Explorer shows when you click it.
                        GridView {
                            id: pcGrid
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.atThisPc
                            cellWidth: 240
                            cellHeight: 88
                            leftMargin: 10
                            topMargin: 10
                            clip: true
                            ScrollBar.vertical: FilesScrollBar {}
                            model: root.volumes
                            delegate: Rectangle {
                                required property var modelData
                                width: pcGrid.cellWidth - 12
                                height: pcGrid.cellHeight - 12
                                radius: Appearance.rounding.small
                                color: pcHover.containsMouse
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88) : "transparent"
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 12
                                    MaterialSymbol {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: modelData.icon
                                        iconSize: 34
                                        color: modelData.mountpoint.length > 0
                                            ? Appearance.colors.colPrimary : Appearance.m3colors.m3outline
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 3
                                        CutLabel {
                                            Layout.fillWidth: true
                                            text: root.volumeLabel(modelData)
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            color: Appearance.colors.colOnLayer1
                                        }
                                        CutLabel {
                                            Layout.fillWidth: true
                                            text: root.volumeSubtitle(modelData)
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            color: Appearance.colors.colSubtext
                                        }
                                        CapacityBar {
                                            Layout.fillWidth: true
                                            usage: root.volumeUsage[modelData.mountpoint] ?? null
                                        }
                                    }
                                }
                                MouseArea {
                                    id: pcHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.RightButton) {
                                            root.openMenuAt(pcHover, mouse.x, mouse.y, modelData.path);
                                            return;
                                        }
                                        if (modelData.mountpoint.length > 0)
                                            root.navigateTo(modelData.mountpoint);
                                        else
                                            root.toggleVolume(modelData);
                                    }
                                    onDoubleClicked: mouse => {
                                        if (mouse.button !== Qt.LeftButton) return;
                                        if (modelData.mountpoint.length > 0)
                                            root.navigateTo(modelData.mountpoint);
                                        else
                                            root.toggleVolume(modelData);
                                    }
                                }
                            }
                        }

                        // Details header: click a column to sort by it, click it
                        // again to reverse.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: (!root.atThisPc && root.viewMode === "details") ? 28 : 0
                            visible: !root.atThisPc && root.viewMode === "details"
                            color: "transparent"
                            RowLayout {
                                id: headerRow
                                anchors.fill: parent
                                // The same lane the rows reserve, so "Name"
                                // still starts over the icons it titles.
                                anchors.leftMargin: root.selectionLane + 8
                                anchors.rightMargin: 8
                                spacing: 0
                                // The name column keeps the app's own column floor
                                // (colMinWidth) so it can never be squeezed to
                                // nothing: with the labels cut at their boxes, a
                                // column given zero width is a name with no
                                // letters in it at all. The fixed columns give
                                // way first -- they hang off the right edge and
                                // are cut by the list, which is what a column too
                                // narrow for the card has always done here.
                                HeaderCell {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: root.colMinWidth
                                    label: Translation.tr("Name"); field: 0
                                }
                                HeaderCell {
                                    Layout.preferredWidth: root.colDate
                                    label: Translation.tr("Date modified"); field: 1
                                    resizable: true; widthValue: root.colDate
                                    widthSetter: (w) => root.colDate = w
                                }
                                HeaderCell {
                                    Layout.preferredWidth: root.colType
                                    label: Translation.tr("Type"); field: 2
                                    resizable: true; widthValue: root.colType
                                    widthSetter: (w) => root.colType = w
                                }
                                HeaderCell {
                                    Layout.preferredWidth: root.colSize
                                    label: Translation.tr("Size"); field: 3; alignRight: true
                                    resizable: true; widthValue: root.colSize
                                    widthSetter: (w) => root.colSize = w
                                }
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: (!root.atThisPc && root.viewMode === "details") ? 1 : 0
                            visible: !root.atThisPc && root.viewMode === "details"
                            color: Appearance.colors.colOutlineVariant
                        }

                        // Details list.
                        StyledListView {
                            id: detailsView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: !root.atThisPc && root.viewMode === "details" && root.rows.length > 0
                            clip: true
                            ScrollBar.vertical: FilesScrollBar {}
                            model: root.rows
                            spacing: 0
                            // ── Empty space: the folder's own menu ─────────────────
                            // Declared as a child of the view, so it lands in the
                            // view's CONTENT item: it scrolls with the rows and
                            // `mapToItem(root, …)` above turns a press into the
                            // right root coordinates. `z: -1` keeps it under every
                            // row, so it only ever sees a press that missed a file
                            // -- empty space, by definition. The height covers the
                            // viewport too when the folder is short, so the whole
                            // pane below the last row counts as empty.
                            MouseArea {
                                id: detailsEmptySpace
                                width: detailsView.width
                                height: Math.max(detailsView.height, detailsView.contentHeight)
                                z: -1
                                acceptedButtons: Qt.RightButton
                                onClicked: mouse => root.openFolderMenuAt(detailsEmptySpace, mouse.x, mouse.y)
                            }
                            delegate: Rectangle {
                                id: rowRoot
                                required property int index
                                required property var modelData

                                // ── The drag itself ─────────────────────────────
                                // The payload hangs off the ROW, and the drag is
                                // started by a DragHandler rather than by
                                // MouseArea::drag.active. Reason: with
                                // `Drag.Automatic` driven off the MouseArea's
                                // own drag, the press starts an INTERNAL move
                                // (the 1x1 proxy follows the pointer) and no
                                // other application is ever handed an offer --
                                // which is exactly the report "the card rides
                                // along, the drop does nothing". A handler that
                                // sets Drag.active from its own activation
                                // starts a real system drag, image and all; the
                                // MouseArea below keeps clicks, selection and
                                // the context menu.
                                Drag.dragType: Drag.Automatic
                                Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
                                Drag.mimeData: ({ [root.clipboardType]: root.dragUriListFor(modelData.path) })
                                // The card hangs above-left of the pointer (see
                                // dragGhostHotSpot), and its picture is already
                                // made by the time this row is pressed: entering
                                // it warmed the card.
                                Drag.hotSpot: root.dragGhostHotSpot
                                Drag.imageSource: root.dragGhostImage
                                DragHandler {
                                    target: null
                                    acceptedButtons: Qt.LeftButton
                                    onActiveChanged: rowRoot.Drag.active = active
                                }

                                Component.onCompleted: root.requestDirSize(modelData)
                                onModelDataChanged: root.requestDirSize(modelData)
                                // The listing this row belongs to has been
                                // re-read: see requestDirSize.
                                Connections {
                                    target: root
                                    function onListingGenerationChanged() { root.requestDirSize(modelData); }
                                }

                                width: detailsView.width
                                height: root.rowH
                                // The row itself paints nothing: the marker
                                // under the cells is the selection (see
                                // rowMark below). Its old outline drew on this
                                // rectangle's edge, which is where the left
                                // scroll lane is -- a box outside the list.
                                color: "transparent"
                                radius: Appearance.rounding.unsharpen
                                RowLayout {
                                    anchors.fill: parent
                                    // Above the marker, which is declared later so
                                    // it paints first: a negative z hid the marker
                                    // entirely (it went under the view's own
                                    // background), so the cells are lifted instead.
                                    z: 1
                                    // A row that was cut is the one that is about
                                    // to move, so its icon and its four cells are
                                    // faded -- the marker under them (the wash and
                                    // the rail) is NOT, because where the eye is
                                    // and where the item is going are two answers.
                                    opacity: root.isCut(modelData.path) ? root.cutOpacity : 1
                                    Behavior on opacity {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                    }
                                    // Past the scroll lane, so the icon column
                                    // never sits under the bar (the header's
                                    // margin moves with it, keeping the two
                                    // rulers aligned).
                                    anchors.leftMargin: root.selectionLane + 8
                                    anchors.rightMargin: 8
                                    spacing: 0
                                    // The same 8 px inset the "Name" title has
                                    // inside its cell (see HeaderCell), so the
                                    // icons sit under the word instead of 8 px
                                    // to its left. The margin is inside the
                                    // flexible width, so the three fixed columns
                                    // still begin exactly where the header lays
                                    // them out.
                                    RowLayout {
                                        Layout.fillWidth: true
                                        // Icon (18) + spacing (8) + the column
                                        // floor, so the cell this label lives in
                                        // cannot be squeezed to nothing either:
                                        // a floor on the label alone would still
                                        // be handed a zero-width parent.
                                        Layout.minimumWidth: root.colMinWidth + 26
                                        Layout.leftMargin: 8
                                        spacing: 8
                                        MaterialSymbol {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: modelData.icon
                                            iconSize: 18
                                            color: modelData.isDir ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                                        }
                                        // The name column is the one that
                                        // flexes, so a long name is cut at that
                                        // column's wall (see CutLabel) and
                                        // cannot reach the date beside it. The
                                        // floor is the app's own column minimum,
                                        // so there is always a wall to be cut at
                                        // and never a column of zero.
                                        CutLabel {
                                            id: rowNameLabel
                                            Layout.fillWidth: true
                                            Layout.minimumWidth: root.colMinWidth
                                            text: root.displayName(modelData.name, modelData.isDir)
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: Appearance.colors.colOnLayer0
                                        }
                                    }
                                    // CutLabel, not a bare StyledText: a column
                                    // dragged narrower than its text used to
                                    // paint the date straight over Type, and a
                                    // text that has no wall of its own has no
                                    // way to say so. Same treatment as the name
                                    // on its left -- the label stops at the
                                    // column's edge with an ellipsis (see
                                    // CutLabel).
                                    CutLabel {
                                        // The column's width MINUS its inset.
                                        // The cell above this one is exactly
                                        // colDate wide and insets its label 8,
                                        // so this cell must add up to the same
                                        // 8 + (colDate - 8). Written as an
                                        // outside margin over the FULL width it
                                        // made this column 8 px wider in the rows
                                        // than in the header -- which is the date
                                        // drifting 16 px left of its own title,
                                        // the type 8 px, and the numbers hanging
                                        // 8 px past "Size".
                                        Layout.preferredWidth: root.colDate - 8
                                        Layout.leftMargin: 8
                                        text: root.fmtTime(modelData.modified)
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                    }
                                    CutLabel {
                                        Layout.preferredWidth: root.colType - 8
                                        Layout.leftMargin: 8
                                        text: modelData.kind
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                    }
                                    // Cut at the column like the two before it.
                                    // A size is short, but "13.3 / 310 GB" is
                                    // not, and a narrow Size column is exactly
                                    // where a number without a wall hangs over
                                    // the pane's edge.
                                    CutLabel {
                                        // Right-aligned, and 8 px clear of the
                                        // column's end -- which is exactly where
                                        // "Size" ends its own label. The margin
                                        // goes on the right for the same reason
                                        // as the two above: inside the width, so
                                        // the three fixed columns still add up
                                        // to what the header lays out.
                                        Layout.preferredWidth: root.colSize - 8
                                        Layout.rightMargin: 8
                                        horizontalAlignment: Text.AlignRight
                                        text: root.sizeTextFor(modelData, FolderSizes.revision)
                                        font.family: Appearance.font.family.numbers
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                    }
                                }
                                // ── The selected row's marker ───────────────
                                // A wash and a rail, both GREY: the fill says
                                // "this row", the rail says "this is the one
                                // the cursor is on", and nothing takes the
                                // accent away from the folder icons. Inset past
                                // the left scroll lane, with 2 px above and
                                // below, so it never touches the pane edge or
                                // the row seam.
                                //
                                // The cells carry z: 1 instead of this marker
                                // wearing z: -1: a negative z put the marker
                                // under the view's own background, where it was
                                // invisible. Declared last, at z: 0, it paints
                                // over the row and under the lifted cells -- and
                                // the row's first child stays the layout, which
                                // is what the column probes read.
                                Rectangle {
                                    id: rowMark
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.leftMargin: root.selectionLane
                                    anchors.rightMargin: root.selectionRightGap
                                    anchors.topMargin: root.selectionGap
                                    anchors.bottomMargin: root.selectionGap
                                    radius: root.selectionRadius
                                    color: root.isSelected(modelData.path)
                                        ? root.selectionWashColor
                                        : (rowHover.containsMouse ? root.selectionWashHoverColor : "transparent")
                                    Rectangle {
                                        visible: root.isSelected(modelData.path)
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        anchors.leftMargin: 2
                                        anchors.topMargin: 3
                                        anchors.bottomMargin: 3
                                        width: root.selectionRail
                                        radius: width / 2
                                        color: root.selectionRailColor
                                    }
                                }
                                // ── A name the column cut ──────────────────
                                // Name is the flexible column, so a long one ends
                                // in an ellipsis -- which says a name went on and
                                // not what it went on TO. Resting the pointer on
                                // the row for half a second shows the whole name;
                                // a name that already fits says nothing, because
                                // a bubble repeating every row you pass is noise.
                                //
                                // The wait is what makes it a tooltip rather
                                // than a flicker: sweeping the pointer down the
                                // list on the way somewhere else never opens one.
                                property bool nameTipWanted: false
                                Timer {
                                    id: rowNameTipTimer
                                    interval: 550
                                    repeat: false
                                    running: rowHover.containsMouse && !rowRoot.nameTipWanted
                                        && rowNameLabel.truncated
                                    onTriggered: rowRoot.nameTipWanted = true
                                }
                                StyledToolTip {
                                    id: rowNameTip
                                    // Under the row's left edge, where the name
                                    // starts, so the bubble reads as a label on
                                    // the row rather than on the pane.
                                    x: 8
                                    y: rowRoot.height + 4
                                    text: rowNameLabel.text
                                    extraVisibleCondition: false
                                    alternativeVisibleCondition: rowRoot.nameTipWanted
                                        && rowHover.containsMouse
                                }
                                MouseArea {
                                    id: rowHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    // ── Dragging a file OUT of the window ──────
                                    // A drag is the same claim as the clipboard,
                                    // made with the hand instead of with Copy:
                                    // the desktop's drag protocol carries a mime
                                    // type, so the payload is the same
                                    // text/uri-list the clipboard publishes.
                                    // `dragType: Automatic` means Qt starts the
                                    // drag from this item's own drag becoming
                                    // active -- "when using Drag.Automatic you
                                    // should also bind the active property to
                                    // MouseArea::drag.active" -- and that binding
                                    // is what makes a press-and-move leave the
                                    // window at all.
                                    //
                                    // The picture that rides with the pointer
                                    // has to be given to Qt BEFORE this starts:
                                    // qquickdrag reads its loader at startDrag,
                                    // so an image that arrives afterwards is
                                    // drawn by nobody, while the drag itself
                                    // still delivers the file. Qt only takes one
                                    // from Drag.imageSource -- not from an item
                                    // -- and a grab is asynchronous, so the card
                                    // is photographed when the pointer ENTERS
                                    // the row (above) and the press merely hands
                                    // the finished picture over. Starting the
                                    // drag by hand once a press-time grab came
                                    // back does not work either: the drag is then
                                    // begun outside the mouse event that Wayland
                                    // takes its serial from, the image shows and
                                    // the file is never delivered to anyone.
                                    onEntered: root.warmDragCard(modelData.path)
                                    // Leaving drops a tip that is already up: it
                                    // belongs to the row it was asked about, and
                                    // the next row must ask for its own.
                                    onExited: rowRoot.nameTipWanted = false
                                    // Pressing is a different gesture: a bubble
                                    // left hanging over a drag card is in the way.
                                    onPressed: {
                                        rowRoot.nameTipWanted = false;
                                        root.beginDrag(modelData.path);
                                    }
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.RightButton) {
                                            if (!root.isSelected(modelData.path)) root.selectIndex(index, false, false);
                                            root.openMenuAt(rowHover, mouse.x, mouse.y, modelData.path);
                                            return;
                                        }
                                        root.selectIndex(index,
                                            (mouse.modifiers & Qt.ControlModifier) !== 0,
                                            (mouse.modifiers & Qt.ShiftModifier) !== 0);
                                    }
                                    // The double-click contract, in one place: the
                                    // window opens, the picker only selects.
                                    onDoubleClicked: mouse => {
                                        if (mouse.button === Qt.LeftButton) root.activate(index);
                                    }
                                }
                                // ── Dropping ONTO this row ─────────────────
                                // A folder row is a destination: what lands on
                                // it is copied or moved into it, exactly as if
                                // it had been pasted there. Declared after the
                                // MouseArea and inside the row, so the pointer
                                // picks it before the pane behind it -- and a
                                // DropArea takes neither clicks nor hover, so
                                // the row itself is untouched while nothing is
                                // being dragged.
                                DropArea {
                                    objectName: "drop-row"
                                    anchors.fill: parent
                                    // The view's own visibility is part of it:
                                    // a list that is not on screen is not a
                                    // destination either. Without this the
                                    // hidden view's delegates still sit in the
                                    // item tree, and a drop aimed at the tiles
                                    // could land on a row nobody can see.
                                    enabled: modelData.isDir === true && detailsView.visible
                                    onEntered: root.dropEntered(modelData.path)
                                    onExited: root.dropExited(modelData.path)
                                    onDropped: drop => {
                                        if (!drop.hasUrls) return;
                                        root.clearDropTarget();
                                        root.receiveDrop(drop.urls, modelData.path,
                                            drop.action === Qt.MoveAction);
                                    }
                                }
                            }
                        }

                        // Tiles.
                        // StyledGridView and not a bare GridView: the tiles used
                        // to scroll through Qt's defaults while the details list
                        // beside them scrolled through StyledListView's tuned
                        // path, so the two views of one folder disagreed about
                        // scrolling -- reported as "very difficult" in the big
                        // icon view. Same scroll contract as the list now; every
                        // property below (cells, margins, menu, delegate) is
                        // unchanged.
                        StyledGridView {
                            id: tilesView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: !root.atThisPc && root.viewMode === "tiles" && root.rows.length > 0
                            clip: true
                            ScrollBar.vertical: FilesScrollBar {}
                            // ── The tiles use the room they are given ──────────
                            // Fixed 132x112 cells left every wide pane hugging the
                            // left edge with empty space around the last tile, and
                            // a picture area that never grew past ~100 px. So the
                            // column count is chosen so a cell lands at most 260 px
                            // and the leftover width is SHARED between the columns:
                            // the tiles (and the previews inside them) grow with the
                            // pane instead of staying thumbnail-sized. The height
                            // follows the tile's own 132:112 proportion so the
                            // picture area keeps its shape at any size.
                            // The cap the PERSON chose (root.tileSizeCaps), not a
                            // fixed 260: this is what "bigger"/"smaller" moves.
                            readonly property int tileMaxCell: root.tileCellCap
                            readonly property int tileAvailW: Math.max(80, width - root.selectionLane)
                            readonly property int tileCols: Math.max(1, Math.ceil(tileAvailW / tileMaxCell))
                            cellWidth: Math.max(80, Math.floor(tileAvailW / tileCols))
                            cellHeight: Math.round(cellWidth * 112 / 132)
                            // The scrollbar's 8 px lane is reserved here too:
                            // the first column of tiles starts after it.
                            leftMargin: root.selectionLane
                            model: root.rows
                            // The same empty-space menu as the details list, and
                            // the same rules: a child of the grid, so it lives in
                            // the content and scrolls with the tiles, below them in
                            // z so a right press on a tile still belongs to the
                            // tile. The part-filled last row and every pixel past
                            // the last tile are this area's.
                            MouseArea {
                                id: tilesEmptySpace
                                width: Math.max(tilesView.width, tilesView.contentWidth)
                                height: Math.max(tilesView.height, tilesView.contentHeight)
                                z: -1
                                acceptedButtons: Qt.RightButton
                                onClicked: mouse => root.openFolderMenuAt(tilesEmptySpace, mouse.x, mouse.y)
                            }
                            delegate: Rectangle {
                                id: tileRoot
                                required property int index
                                required property var modelData

                                // Same drag as the details row, and for the
                                // same reason it hangs off the tile and is
                                // started by a DragHandler: the payload is the
                                // file(s), and only a handler-driven
                                // Drag.active hands other applications an
                                // offer (see the details row).
                                Drag.dragType: Drag.Automatic
                                Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
                                Drag.mimeData: ({ [root.clipboardType]: root.dragUriListFor(modelData.path) })
                                Drag.hotSpot: root.dragGhostHotSpot
                                Drag.imageSource: root.dragGhostImage
                                DragHandler {
                                    target: null
                                    acceptedButtons: Qt.LeftButton
                                    onActiveChanged: tileRoot.Drag.active = active
                                }

                                width: tilesView.cellWidth - 8
                                height: tilesView.cellHeight - 8
                                radius: Appearance.rounding.small
                                // The same marker as the details row: the tile
                                // paints nothing itself, tileMark below does
                                // the wash and the rail.
                                color: "transparent"
                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 6
                                    z: 1
                                    // The tile half of the cut fade (see the
                                    // details row): the picture and the title, not
                                    // the marker under them.
                                    opacity: root.isCut(modelData.path) ? root.cutOpacity : 1
                                    Behavior on opacity {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                    }
                                    // The picture area. A tile is supposed to show the
                                    // FILE, so an image gets drawn here instead of the
                                    // category icon -- generated through the shared
                                    // thumbnail cache, which is what keeps a folder of
                                    // 40 MP photos from being decoded at full size
                                    // hundreds of times -- and a clip from being
                                    // scanned hundreds of times, since its frame comes
                                    // out of the same cache. Everything else (folders,
                                    // documents, archives) keeps its icon.
                                    Item {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        MaterialSymbol {
                                            anchors.centerIn: parent
                                            visible: !tilePreview.active || tilePreview.item === null || tilePreview.item.undecodable
                                            text: modelData.icon
                                            // The icon grows with the tile, the same way
                                            // the picture does: 40 px at the smallest
                                            // cell (what it always was), ~92 px at the
                                            // biggest, never past 128.
                                            iconSize: Math.max(40, Math.min(128, Math.round((tilesView.cellHeight - 62) * 0.65)))
                                            color: modelData.isDir ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                                        }
                                        Loader {
                                            id: tilePreview
                                            anchors.fill: parent
                                            active: root.tilePreviews && modelData.preview
                                            // Built in the DELEGATE's context, not at the
                                            // file level: `modelData` only exists here.
                                            sourceComponent: Component {
                                                ThumbnailImage {
                                                    id: tileThumb
                                                    anchors.fill: parent
                                                    sourcePath: modelData.path
                                                    // A clip is drawn as one of its
                                                    // own frames, so a folder of
                                                    // videos reads as a wall of
                                                    // pictures rather than a row of
                                                    // identical film icons.
                                                    videoFrame: root.previewKindFor(modelData) === "video"
                                                    fillMode: Image.PreserveAspectFit
                                                }
                                            }
                                        }
                                    }
                                    // Same wall rule as everywhere else, one
                                    // line longer: a tile's title is bounded by
                                    // its own box -- the wrap folds it inside
                                    // the tile's width and the two-line cap stops
                                    // it at the tile's height -- and the elide is
                                    // what says the second line was cut rather
                                    // than having ended there.
                                    StyledText {
                                        id: tileTitle
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignHCenter
                                        text: root.displayName(modelData.name, modelData.isDir)
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colOnLayer0
                                        elide: Text.ElideRight
                                        maximumLineCount: 2
                                        wrapMode: Text.Wrap
                                    }
                                }
                                // The same "what was cut off" answer the details
                                // row gives, for the same reason: a tile's title
                                // is a two-line cap, and a long name stops with an
                                // ellipsis. Half a second on the tile shows the
                                // rest; a title that fits stays quiet.
                                property bool nameTipWanted: false
                                Timer {
                                    id: tileNameTipTimer
                                    interval: 550
                                    repeat: false
                                    running: tileHover.containsMouse && !tileRoot.nameTipWanted
                                        && tileTitle.truncated
                                    onTriggered: tileRoot.nameTipWanted = true
                                }
                                StyledToolTip {
                                    id: tileNameTip
                                    x: 8
                                    y: tileRoot.height + 4
                                    text: tileTitle.text
                                    extraVisibleCondition: false
                                    alternativeVisibleCondition: tileRoot.nameTipWanted
                                        && tileHover.containsMouse
                                }
                                // The tile's selection marker: a wash with the
                                // same left rail, drawn under the picture and
                                // the title. A tile is not beside the scroll
                                // lane, so this one is inset only enough to
                                // keep the radius legible.
                                Rectangle {
                                    id: tileMark
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    radius: Appearance.rounding.small
                                    color: root.isSelected(modelData.path)
                                        ? root.selectionWashColor
                                        : (tileHover.containsMouse ? root.selectionWashHoverColor : "transparent")
                                    Rectangle {
                                        visible: root.isSelected(modelData.path)
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        anchors.leftMargin: 3
                                        anchors.topMargin: 5
                                        anchors.bottomMargin: 5
                                        width: root.selectionRail
                                        radius: width / 2
                                        color: root.selectionRailColor
                                    }
                                }
                                MouseArea {
                                    id: tileHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onExited: tileRoot.nameTipWanted = false
                                    // Same drag as the details row: the payload is
                                    // the file(s), not the picture, and the image
                                    // is grabbed on the press, before the drag can
                                    // start (see the details row for why).
                                    // Same card as the details row, warmed the
                                    // same way: a tile is entered before it is
                                    // pressed, just like a row.
                                    onEntered: root.warmDragCard(modelData.path)
                                    // Same reason as the details row: a press
                                    // starts a drag, and a tip left over the tile
                                    // would ride along with it.
                                    onPressed: {
                                        tileRoot.nameTipWanted = false;
                                        root.beginDrag(modelData.path);
                                    }
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.RightButton) {
                                            if (!root.isSelected(modelData.path)) root.selectIndex(index, false, false);
                                            root.openMenuAt(tileHover, mouse.x, mouse.y, modelData.path);
                                            return;
                                        }
                                        root.selectIndex(index,
                                            (mouse.modifiers & Qt.ControlModifier) !== 0,
                                            (mouse.modifiers & Qt.ShiftModifier) !== 0);
                                    }
                                    onDoubleClicked: mouse => {
                                        if (mouse.button === Qt.LeftButton) root.activate(index);
                                    }
                                }
                                // The same destination rule as a details row:
                                // a tile that is a folder takes what is dropped
                                // on it, and the tile's own click and hover are
                                // unaffected.
                                DropArea {
                                    objectName: "drop-tile"
                                    anchors.fill: parent
                                    enabled: modelData.isDir === true && tilesView.visible
                                    onEntered: root.dropEntered(modelData.path)
                                    onExited: root.dropExited(modelData.path)
                                    onDropped: drop => {
                                        if (!drop.hasUrls) return;
                                        root.clearDropTarget();
                                        root.receiveDrop(drop.urls, modelData.path,
                                            drop.action === Qt.MoveAction);
                                    }
                                }
                            }
                        }

                        // Empty folder / empty device, in words: a file manager
                        // that shows nothing at all looks broken.
                        StyledText {
                            id: emptyState
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: !root.atThisPc && root.rows.length === 0
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: root.currentMtpVolume !== null
                                ? root.mtpUnlockHint(root.currentMtpVolume.mtp)
                                : ((root.filter.length > 0 && root.rawCount > 0)
                                    ? Translation.tr("No items match your search")
                                    : Translation.tr("This folder is empty"))
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                            // ── Empty space: the folder's own menu ──────────
                            // A folder with no rows hides BOTH views (each is
                            // gated on the row count), so this message is the
                            // only thing left in the pane -- and the only thing
                            // a right-click can be aimed at. It answers with the
                            // folder's own menu, the same one empty space below
                            // a listing gets. It lives here, in the pane's own
                            // column, because that is where every other
                            // working press target in this file sits (the drive
                            // rows, the header cells, the nav rows); the pane
                            // and view catchers below cover the rest.
                            MouseArea {
                                id: emptySpaceArea
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                onClicked: mouse => root.openFolderMenuAt(emptySpaceArea, mouse.x, mouse.y)
                            }
                        }
                    }
                }

                // ── The preview pane ────────────────────────────────────
                // Explorer's preview pane, showing the ONE selected file. It is
                // a pane and not a window on purpose: walking the list with the
                // arrow keys re-previews as you go, which is the thing you
                // actually want from a preview -- a window per file would have
                // to be dismissed between every look.
                //
                // It sits beside the files when there is room for both and
                // under them when there is not (previewBelow), and either way a
                // hairline divides the two halves of the window rather than
                // leaving them as cards that happen to be adjacent. The line is
                // drawn on the edge that faces the list, so it follows the pane
                // when the pane moves.
                Rectangle {
                    id: previewCard
                    Layout.preferredWidth: visible
                        ? (root.previewBelow ? contentGrid.width : root.previewPaneWidth) : 0
                    Layout.preferredHeight: (visible && root.previewBelow) ? root.previewStackHeight : 0
                    Layout.fillWidth: root.previewBelow
                    Layout.fillHeight: !root.previewBelow
                    visible: root.previewPane && !root.pickerMode
                    radius: Appearance.rounding.small
                    color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.55)
                    clip: true

                    // The separator: vertical while the files and the preview
                    // are side by side, horizontal once the preview has moved
                    // underneath. One hairline, on the edge that faces the list.
                    // It goes flat while the band beside it is being dragged or
                    // merely hovered, the same answer the column dividers give:
                    // the line is there to be grabbed, so it says so.
                    Rectangle {
                        id: previewEdgeSide
                        visible: !root.previewBelow
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 1
                        color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant,
                            previewDividerSide.dragging ? 0 : (previewDividerSide.containsMouse ? 0.25 : 0.65))
                    }
                    Rectangle {
                        id: previewEdgeUnder
                        visible: root.previewBelow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: 1
                        color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant,
                            previewDividerUnder.dragging ? 0 : (previewDividerUnder.containsMouse ? 0.25 : 0.65))
                    }

                    // ── The divider you can grab ────────────────────────────
                    // The pane's size is a choice, so its edge facing the list is
                    // a handle: 8 px of lane, exactly the width the column
                    // dividers use, so the two read as one language -- and the
                    // two-headed arrow appears just as it does there.
                    //
                    // It lives INSIDE the pane (the columns' band lives inside
                    // its cell for the same reason): a handle straddling the
                    // boundary belongs to two items at once, and the pointer
                    // only gets the resize cursor on whichever half the hit test
                    // hands over. Nothing of the pane's own content sits in
                    // these 8 px -- the layout keeps a 10 px margin -- so the
                    // band costs the preview nothing.
                    //
                    // The drag itself is the same shape as the columns' drag:
                    // window coordinates, clamp against a live ceiling, remember
                    // that it clamped. See previewDragBegin.
                    MouseArea {
                        id: previewDividerSide
                        visible: !root.previewBelow
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 8
                        hoverEnabled: true
                        cursorShape: Qt.SizeHorCursor
                        property bool dragging: false
                        onPressed: mouse => {
                            previewDividerSide.dragging = root.previewDragBegin("width",
                                previewDividerSide.mapToItem(null, mouse.x, mouse.y).x);
                        }
                        onPositionChanged: mouse => {
                            if (previewDividerSide.dragging)
                                root.previewDragTo(previewDividerSide.mapToItem(null, mouse.x, mouse.y).x);
                        }
                        onReleased: {
                            if (previewDividerSide.dragging) root.previewDragEnd();
                            previewDividerSide.dragging = false;
                        }
                        onCanceled: previewDividerSide.dragging = false
                    }
                    // Same handle, other edge: once the preview is underneath
                    // the list, the divider that matters is the horizontal one,
                    // and the pane is sized by its height. Without this the
                    // feature would do nothing in a half-screen window, where
                    // the pane is always stacked.
                    MouseArea {
                        id: previewDividerUnder
                        visible: root.previewBelow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: 8
                        hoverEnabled: true
                        cursorShape: Qt.SizeVerCursor
                        property bool dragging: false
                        onPressed: mouse => {
                            previewDividerUnder.dragging = root.previewDragBegin("height",
                                previewDividerUnder.mapToItem(null, mouse.x, mouse.y).y);
                        }
                        onPositionChanged: mouse => {
                            if (previewDividerUnder.dragging)
                                root.previewDragTo(previewDividerUnder.mapToItem(null, mouse.x, mouse.y).y);
                        }
                        onReleased: {
                            if (previewDividerUnder.dragging) root.previewDragEnd();
                            previewDividerUnder.dragging = false;
                        }
                        onCanceled: previewDividerUnder.dragging = false
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            // The name in this pane is bounded by the pane's own
                            // edge, so it is cut there like every other label --
                            // but it elides in the MIDDLE, where the end of a
                            // name (its extension) is worth more than its
                            // beginning: "holiday-photo…holiday-photo.jpg" says
                            // what the two ends are, a right-edge cut says only
                            // that the name went on.
                            StyledText {
                                Layout.fillWidth: true
                                text: root.previewHeadline()
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colOnLayer0
                                elide: Text.ElideMiddle
                            }
                            IconButton {
                                symbol: "close"
                                tip: Translation.tr("Close the preview pane")
                                onActivated: root.previewPane = false
                            }
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: root.previewSubtitle()
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }

                        // An image, drawn through the shared thumbnail cache: the
                        // cache is keyed by size, so this is a cheap bucket and a
                        // 40 MP photo is never decoded at full size just to be shown
                        // at 280 px. `PreserveAspectFit` because a preview that
                        // crops is a preview that hides things.
                        //
                        // A VIDEO gets the same box, holding one frame grabbed
                        // out of the clip: the pane shows what the file looks
                        // like, and the ffprobe facts print underneath it.
                        //
                        // Behind a Loader, and only for pictures and clips: a
                        // ThumbnailImage pointed at a .txt spends its budget
                        // forking magick on a file that can never decode, which is
                        // exactly the loop the widget's own latch was written
                        // about.
                        Item {
                            id: previewImageBox
                            Layout.fillWidth: true
                            // The picture gets the whole pane, in BOTH directions.
                            //
                            // It used to be a fixed 220 px box, and that was the
                            // bug behind "extending the pane does not make the
                            // preview bigger": the image is fitted with
                            // PreserveAspectFit, which fits INSIDE its box -- so a
                            // wider pane only added empty space at the picture's
                            // sides, and a shorter picture stayed exactly as tall
                            // as it always was. Filling the leftover height (the
                            // header and the subtitle above it are the only fixed
                            // rows) lets the box follow the divider, and the
                            // stacked pane's height along with it.
                            Layout.fillHeight: true
                            Layout.preferredHeight: visible ? 220 : 0
                            // No floor: in a short pane the picture shrinks
                            // instead of pushing the name row out of the card.
                            Layout.minimumHeight: 0
                            visible: root.previewView === "image" || root.previewView === "video"
                            Loader {
                                id: previewImageLoader
                                anchors.fill: parent
                                active: root.previewView === "image" || root.previewView === "video"
                                sourceComponent: Component {
                                    ThumbnailImage {
                                        id: previewImage
                                        anchors.fill: parent
                                        sourcePath: root.previewEntryPath
                                        videoFrame: root.previewView === "video"
                                        fillMode: Image.PreserveAspectFit
                                    }
                                }
                            }
                            // What stands in for the picture when there is not
                            // going to be one: a broken image for a file that
                            // will not decode, a film icon for a clip with no
                            // frame grabber on the system, which is a different
                            // disappointment and deserves its own word.
                            MaterialSymbol {
                                anchors.centerIn: parent
                                visible: previewImageLoader.item !== null && previewImageLoader.item.undecodable
                                text: root.previewView === "video" ? "movie" : "broken_image"
                                iconSize: 40
                                color: Appearance.m3colors.m3outline
                            }
                        }

                        // A PDF's first page, rendered by poppler at reading
                        // resolution (70 dpi) -- not at print resolution.
                        Item {
                            id: previewPageBox
                            Layout.fillWidth: true
                            // Same rule as the image above: a rendered page is a
                            // picture, so it grows with the pane rather than
                            // sitting at a fixed 300 px in the middle of it.
                            Layout.fillHeight: true
                            Layout.preferredHeight: visible ? 300 : 0
                            Layout.minimumHeight: 0
                            visible: root.previewView === "pdf"
                            Image {
                                anchors.fill: parent
                                visible: root.previewPage.length > 0
                                source: root.previewPage
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }
                            StyledText {
                                anchors.centerIn: parent
                                width: parent.width
                                visible: root.previewPage.length === 0
                                horizontalAlignment: Text.AlignHCenter
                                text: root.previewNote.length > 0 ? root.previewNote : Translation.tr("Rendering") + "…"
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                                wrapMode: Text.Wrap
                            }
                        }

                        // Text, as text: the first few KB (or whatever the
                        // helper made of it), monospaced, scrollable.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.previewView === "text"
                            radius: Appearance.rounding.small
                            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.35)
                            clip: true
                            Flickable {
                                anchors.fill: parent
                                anchors.margins: 6
                                contentWidth: width
                                contentHeight: previewTextBody.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: StyledScrollBar {}
                                StyledText {
                                    id: previewTextBody
                                    width: parent.width
                                    text: root.previewText.length > 0 ? root.previewText
                                        : Translation.tr("Reading") + "…"
                                    font.family: Appearance.font.family.monospace
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colOnLayer0
                                    wrapMode: Text.WrapAnywhere
                                }
                            }
                        }

                        // ── A table: csv, tsv, and every spreadsheet that is
                        // really one ────────────────────────────────────────
                        // The header is a separate Flickable from the body for
                        // one reason: it has to stay put while the rows scroll
                        // DOWN and follow them while they scroll ACROSS. That
                        // coupling is the whole trick of a table in a pane this
                        // narrow -- a header that scrolls away leaves numbered
                        // cells, and one that does not scroll sideways labels
                        // the wrong column the moment you reach column six.
                        Rectangle {
                            id: previewTableBox
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.previewView === "table"
                            radius: Appearance.rounding.small
                            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.35)
                            clip: true
                            readonly property int cellWidth: 132
                            readonly property int rowHeight: 24
                            readonly property int columnCount: Math.max(1,
                                (root.previewTable && root.previewTable.header)
                                    ? root.previewTable.header.length : 0)
                            readonly property int columnsWidth: columnCount * cellWidth

                            Flickable {
                                id: previewTableHead
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: previewTableBox.rowHeight
                                contentWidth: previewTableBox.columnsWidth
                                contentX: previewTableBody.contentX
                                interactive: false
                                clip: true
                                Row {
                                    Repeater {
                                        model: (root.previewTable && root.previewTable.header)
                                            ? root.previewTable.header : []
                                        delegate: Item {
                                            required property var modelData
                                            width: previewTableBox.cellWidth
                                            height: previewTableBox.rowHeight
                                            StyledText {
                                                anchors.fill: parent
                                                anchors.leftMargin: 6
                                                anchors.rightMargin: 6
                                                verticalAlignment: Text.AlignVCenter
                                                text: String(modelData ?? "")
                                                font.pixelSize: Appearance.font.pixelSize.smallest
                                                font.weight: Font.DemiBold
                                                color: Appearance.colors.colSubtext
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                }
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 1
                                    color: Appearance.colors.colOutlineVariant
                                }
                            }

                            ListView {
                                id: previewTableBody
                                anchors.top: previewTableHead.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                model: (root.previewTable && root.previewTable.rows)
                                    ? root.previewTable.rows : []
                                contentWidth: previewTableBox.columnsWidth
                                flickableDirection: Flickable.HorizontalAndVerticalFlick
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: StyledScrollBar {}
                                delegate: Item {
                                    required property var modelData
                                    required property int index
                                    width: previewTableBody.contentWidth
                                    height: previewTableBox.rowHeight
                                    Rectangle {
                                        anchors.fill: parent
                                        color: index % 2 === 0 ? "transparent"
                                            : CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.75)
                                    }
                                    Row {
                                        Repeater {
                                            model: modelData
                                            delegate: Item {
                                                required property var modelData
                                                width: previewTableBox.cellWidth
                                                height: previewTableBox.rowHeight
                                                StyledText {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: 6
                                                    anchors.rightMargin: 6
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: String(modelData ?? "")
                                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                                    color: Appearance.colors.colOnLayer0
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ── A list: what is INSIDE an archive ──────────────
                        // Not the archive's type -- its contents. A zip that
                        // previews as the word "Archive" has told the user
                        // nothing they could not see from the icon.
                        Rectangle {
                            id: previewListBox
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.previewView === "list"
                            radius: Appearance.rounding.small
                            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.35)
                            clip: true
                            ListView {
                                anchors.fill: parent
                                anchors.margins: 6
                                model: root.previewEntries
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: StyledScrollBar {}
                                delegate: Item {
                                    required property var modelData
                                    width: previewListBox.width - 12
                                    height: 22
                                    RowLayout {
                                        anchors.fill: parent
                                        spacing: 6
                                        MaterialSymbol {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: root.iconFor(String(modelData.name ?? ""), modelData.dir === true)
                                            iconSize: 14
                                            color: Appearance.colors.colSubtext
                                        }
                                        StyledText {
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            text: String(modelData.name ?? "")
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            color: Appearance.colors.colOnLayer0
                                            elide: Text.ElideMiddle
                                        }
                                        StyledText {
                                            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                                            text: String(modelData.size ?? "")
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            color: Appearance.colors.colSubtext
                                        }
                                    }
                                }
                            }
                        }

                        // Everything else, in words: what it is, and how big/how
                        // long. A file that cannot be previewed is still worth
                        // describing, and saying so is better than a blank panel.
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.previewView === "audio"
                                || root.previewView === "folder" || root.previewView === ""
                            spacing: 8
                            Item { Layout.fillHeight: true }
                            MaterialSymbol {
                                Layout.alignment: Qt.AlignHCenter
                                text: root.previewEntry ? root.previewEntry.icon : "draft"
                                iconSize: 44
                                color: Appearance.m3colors.m3outline
                            }
                            StyledText {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: root.previewBodyText()
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                                wrapMode: Text.Wrap
                            }
                            StyledText {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                visible: root.previewEntry !== null
                                text: Translation.tr("Press Enter to open it")
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                            }
                            Item { Layout.fillHeight: true }
                        }

                        // "first 4 KB of 12 MB", and the same line for a PDF that
                        // could not be rendered. Nothing is said when there is
                        // nothing worth saying.
                        StyledText {
                            Layout.fillWidth: true
                            // The one line that says more than the body can: a
                            // video's length and codec, a PDF's "could not
                            // render", a table's row count, a zip's item count.
                            visible: root.previewNote.length > 0
                                && (root.previewView === "text" || root.previewView === "pdf"
                                    || root.previewView === "video" || root.previewView === "table"
                                    || root.previewView === "list")
                            text: root.previewNote
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }

        // ── Picker actions ─────────────────────────────────────────────
        //
        // The bar is the dialog's deciding half: the name is typed here and the
        // dialog is answered here, and it is the only part of the surface that
        // is a decision rather than a place. It used to be transparent -- a row
        // of controls floating over the bottom of the list, reading as the last
        // line of the content -- so it now has a surface of its own: the layer
        // above the rows, a hairline and the house rounding, which is the
        // treatment the status bar under it already gets in the app. Same bar,
        // same meaning: the list is what you are looking at, this is what you
        // say about it.
        Rectangle {
            id: pickerBar
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 64 : 0
            visible: root.pickerMode
            radius: Appearance.rounding.small
            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.35)
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.55)

            // The fields, from the left edge to wherever the buttons begin.
            //
            // Two rows rather than one with a spacer: a spacer only pushes the
            // buttons to the right while the fields are WIDE, and in open mode
            // there are no fields at all -- so the buttons drifted into the
            // middle of the bar. Anchored to the edge, they are on the edge in
            // every mode.
            //
            // A plain Item rather than a RowLayout, because these fields are
            // CHAINED, not distributed: the type's box sits against the name
            // box's right edge and travels with it as the name grows. A layout
            // spreads the leftover space between its children instead, which is
            // the drift this replaces -- measured with a two-word name, the
            // name box was 148 wide and the type's box sat another 300px along
            // the bar from the box it belongs to.
            Item {
                id: pickerFields
                anchors.left: parent.left
                anchors.right: pickerActions.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 12
                anchors.rightMargin: 10
                // One word in the field's own font, which is what the name box
                // is never narrower than. Not drawn -- it exists to be measured.
                TextMetrics {
                    id: saveNameMin
                    font: saveName.font
                    text: Translation.tr("Filename") + " "
                }
                StyledText {
                    id: saveNameCaption
                    visible: root.pickerOp === "save"
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: Translation.tr("Name")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                // The name, in a frame of its own. The bar is a surface, so a
                // bare TextInput on it reads as text lying on the bar rather
                // than as the box you type into; the frame is what says "this
                // is the field" -- the same frame the rename prompt's name box
                // has, because it is the same question.
                Rectangle {
                    id: saveNameFrame
                    visible: root.pickerOp === "save"
                    anchors.left: saveNameCaption.right
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    // The box follows its own text (see saveNameMinWidth /
                    // saveNameMaxWidth). It never goes below one word, and once
                    // it has run out of bar it stops growing and the text
                    // scrolls inside it instead.
                    width: Math.min(root.saveNameMaxWidth,
                        Math.max(root.saveNameMinWidth, saveName.contentWidth + 26))
                    height: 38
                    // The field scrolls inside the box when the name outgrows
                    // it; this keeps a long word from painting over the border
                    // on the way there.
                    clip: true
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer0
                    border.width: 1
                    border.color: saveName.activeFocus
                        ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
                        : CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
                    StyledTextInput {
                        id: saveName
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        text: root.saveStem
                        // Guarded: the field's text IS this property, so an
                        // unconditional write would be a write on every
                        // keystroke to the value it already has.
                        onTextChanged: if (text !== root.saveStem) root.saveStem = text
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                root.pickerConfirm();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Tab) {
                                // One Tab reaches the type, as it does in the
                                // rename prompt: the two boxes are one name.
                                root.openSaveExtEditor();
                                event.accepted = true;
                            }
                        }
                    }
                }
                // The extension: a label until it is asked to be a field.
                //
                // A double click (or a double tap -- Qt turns one into the
                // other) opens it. Until then it is the second half of the
                // name, written plainly, and the pointer over it turns into a
                // text cursor so the gesture is at least discoverable without
                // the box looking like something it can swallow a keystroke
                // with.
                Rectangle {
                    id: saveExtBox
                    visible: root.pickerOp === "save"
                    // Against the name box's right edge: it is the second half
                    // of one name, so it travels with the first half rather
                    // than sitting wherever the bar has space.
                    anchors.left: saveNameFrame.right
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    // SNUG TO WHAT IT HOLDS, by request: at a fixed 112px a
                    // three-letter type sat with about 40px of air on each
                    // side, which read as a wide empty field rather than as
                    // the second half of the name. The width now follows the
                    // content -- the type at rest, the floating label while
                    // the box is open -- plus the same 8px insets the open
                    // field uses, so the type never touches the border and no
                    // space is carried unused. The cap keeps a long extension
                    // (".tar.gz") from eating the name field next to it; the
                    // floor keeps a one-letter type from becoming a dot. Both
                    // are read from the items themselves rather than guessed
                    // from the English word "Extension" -- the label is
                    // translated.
                    width: Math.min(120, Math.max(64,
                        Math.max(saveExtRestRow.implicitWidth,
                                 saveExtFloatLabel.implicitWidth) + 16))
                    height: 38
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer0
                    border.width: 1
                    border.color: root.saveExtEditing
                        ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
                        : (saveExtHit.containsMouse
                            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.25)
                            : CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6))

                    // AT REST: the type as a fact. Emptied, the box still has
                    // to look like the place a type goes, so it says so
                    // quietly.
                    RowLayout {
                        id: saveExtRestRow
                        anchors.centerIn: parent
                        visible: !root.saveExtEditing
                        spacing: 1
                        StyledText {
                            visible: root.saveExt.length > 0
                            text: "."
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                        }
                        StyledText {
                            text: root.saveExt.length > 0
                                ? root.saveExt : Translation.tr("ext")
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: root.saveExt.length > 0
                                ? Appearance.colors.colOnLayer0
                                : Appearance.colors.colSubtext
                        }
                    }

                    // OPEN: the default extension on the top line, the field
                    // under it.
                    //
                    // The floating label is the extension the APPLICATION asked
                    // for, kept beside the one being typed rather than instead
                    // of it. It is the "Email" of a login field: when the box
                    // is live, the box says what it was going to be. Nothing
                    // overwrites it, so changing the type does not lose the
                    // one the dialog arrived with -- and an emptied box still
                    // shows what it would have been.
                    Item {
                        anchors.fill: parent
                        visible: root.saveExtEditing
                        StyledText {
                            id: saveExtFloatLabel
                            anchors.top: parent.top
                            anchors.topMargin: 3
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            text: root.saveExtLabel()
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }
                        RowLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            anchors.top: saveExtFloatLabel.bottom
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 4
                            spacing: 1
                            // The dot is drawn, never typed: the box's text is
                            // just "png", so no leading dot can make a name
                            // like "notes..png".
                            StyledText {
                                text: "."
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                            }
                            StyledTextInput {
                                id: saveExtField
                                Layout.fillWidth: true
                                verticalAlignment: TextInput.AlignVCenter
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                text: root.saveExt
                                onTextChanged: if (text !== root.saveExt) root.saveExt = text
                                // Selected on arrival, so typing replaces the
                                // type rather than prefixing it.
                                onActiveFocusChanged: {
                                    if (activeFocus) selectAll();
                                    else root.closeSaveExtEditor();
                                }
                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        root.pickerConfirm();
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Escape) {
                                        // Closes the BOX, not the dialog: the
                                        // name being typed survives a step
                                        // back out of the type.
                                        root.closeSaveExtEditor();
                                        saveName.forceActiveFocus();
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                                        saveName.forceActiveFocus();
                                        saveName.selectAll();
                                        event.accepted = true;
                                    }
                                }
                                Keys.onShortcutOverride: event => {
                                    if (event.key === Qt.Key_Escape) event.accepted = true;
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: saveExtHit
                        anchors.fill: parent
                        hoverEnabled: true
                        // A live field keeps its own presses (caret, selection);
                        // the box is only a hit target while it is a label.
                        enabled: !root.saveExtEditing
                        cursorShape: Qt.IBeamCursor
                        onDoubleClicked: root.openSaveExtEditor()
                    }
                }
            }
            RowLayout {
                id: pickerActions
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                ActionButton {
                    implicitWidth: 100
                    label: Translation.tr("Cancel")
                    onActivated: root.pickerCancelled()
                }
                ActionButton {
                    implicitWidth: 140
                    primary: true
                    enabled: root.pickerCanConfirm
                    label: root.actionLabel
                    onActivated: root.pickerConfirm()
                }
            }
        }

        // ── Status bar ─────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            id: statusBar
            Layout.preferredHeight: visible ? root.statusBarHeight : 0
            visible: !root.pickerMode
            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.7)
            FocusRing { area: "status" }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 12
                CutLabel {
                    Layout.fillWidth: true
                    text: {
                        const n = root.rows.length;
                        const sel = root.selection.length;
                        let s = n + " " + (n === 1 ? Translation.tr("item") : Translation.tr("items"));
                        if (sel > 0) s += " · " + sel + " " + Translation.tr("selected");
                        if (root.statusNote.length > 0) s += " · " + root.statusNote;
                        return s;
                    }
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: root.storageText
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }
            }
        }
    }

    // ── The drag image ──────────────────────────────────────────────
    //
    // What you are CARRYING, drawn as a card: the file's own icon and its name
    // -- or how many files, when the drag carries a selection.
    //
    // Qt is handed a picture of this card, not the card: it is photographed
    // with grabToImage() and the resulting URL is given to Drag.imageSource.
    // That is why the card never has to be on screen -- it is parked outside
    // the window for its whole life -- where the older way (Drag.source: Qt
    // renders the named item into the drag image) only draws anything when that
    // item is visible, so the card had to be put where the drag began and taken
    // away again a moment later: a copy of the card in the list, on every drag.
    //
    // WHEN it is photographed is the part that decides whether anything is
    // carried at all: see warmDragCard. The short version is that a drag takes
    // its picture at drag start, so the picture is made while the pointer is
    // still hovering the row, not on the press.
    //
    // One card serves both views: the details row and the tile each grab this
    // same item rather than carrying a hidden copy per delegate.
    property string dragGhostIcon: "draft"
    property string dragGhostLabel: ""
    // The picture Qt is told to draw under the hand. Every drag in both views
    // binds Drag.imageSource to THIS, rather than each delegate holding its own:
    // one card, one picture, and a press can hand it over without touching a
    // delegate at all (which is also what makes it testable -- see
    // probeDragBegin).
    property string dragGhostImage: ""
    // Whether the last grab produced a picture at all. Not the same question as
    // "is the card right": Qt hands back an empty result when it could not grab,
    // and a drag with no picture still delivers its file to whoever is waiting.
    property bool dragGhostGrabbed: false
    // Where a CHECK asked for the last picture to be written. Never set by a
    // real drag (saving a PNG on every press would be a file manager writing
    // files nobody asked for), and the only way to look at the pixels rather
    // than at the promise of them.
    property string dragGhostFile: ""
    // ── Why a cache, and not one grab per press ─────────────────────────
    //
    // Every part of this has to be ready BEFORE the hand moves: Qt takes the
    // drag image when the drag STARTS (qquickdrag reads its loader at
    // startDrag), so a picture that is still being photographed at the moment
    // the 8 px threshold is crossed never reaches the compositor. The file
    // still arrives, and the drag looks like nothing is being carried -- the
    // exact complaint that put this cache here.
    //
    // So the card is photographed while the pointer is still HOVERING a row
    // (entering it is worth a whole frame of head start), and the URL is kept
    // against what the card SAID -- its icon and its label. A press then finds
    // the picture already made and hands it over in the same event that starts
    // the drag. The grab is not wasted work: it is the same card that would be
    // drawn, taken a moment earlier.
    property var dragGhostCache: ({})
    property bool dragGhostGrabPending: false
    // How many cards are worth holding. A folder of ten thousand files would
    // otherwise hold ten thousand pictures; the pointer can only ever be over
    // one row, so this is a small ring rather than a mirror of the folder.
    readonly property int dragGhostCacheLimit: 32
    // Where the hand holds the card, measured against the running compositor
    // rather than reasoned about: at hotspot (0,0) the drag surface's
    // BOTTOM-LEFT lands on the pointer, so the card hangs UP over the row it
    // came from. A negative y therefore pulls it back down by its own height,
    // and a negative x pushes it right, leaving a small gap -- the card sits
    // just below and to the right of the cursor, beside the pointer instead of
    // under it, so whatever is about to be dropped on stays visible.
    readonly property int dragGhostGap: 6
    readonly property point dragGhostHotSpot:
        Qt.point(-dragGhostGap, -(dragGhost.height + dragGhostGap))
    function rowForPath(path) {
        const rows = root.rows;
        for (let i = 0; i < rows.length; i++) {
            if (rows[i].path === path)
                return rows[i];
        }
        return null;
    }
    function dragGhostIconFor(path) {
        const entry = root.rowForPath(path);
        return entry && entry.icon ? entry.icon : "draft";
    }
    function dragGhostLabelFor(path) {
        const p = String(path ?? "");
        if (p.length === 0) return "";
        // The drag carries the whole selection when the row under the hand is
        // part of it; the card says so rather than naming one file out of four.
        if (root.selection.indexOf(p) !== -1 && root.selection.length > 1)
            return root.selection.length + " " + Translation.tr("items");
        const entry = root.rowForPath(p);
        return entry ? root.displayName(entry.name, entry.isDir) : root.baseName(p);
    }
    // One grab, one place that reads its answer, so a press and a probe cannot
    // disagree about what came back. `saveTo` is the check suite's file, or
    // empty for a real drag. The result's own width and height are NOT read:
    // an ItemGrabResult in QML has `url`, `image` and saveToFile(), and no size
    // properties at all -- `result.width` is undefined, which is how a probe
    // can be written that looks like it checks the picture and does not.
    function noteGrab(result, saveTo) {
        const url = result && result.url ? String(result.url) : "";
        root.dragGhostImage = url;
        root.dragGhostGrabbed = url.length > 0;
        root.dragGhostFile = "";
        if (url.length > 0 && String(saveTo ?? "").length > 0
                && result.saveToFile(String(saveTo)) === true)
            root.dragGhostFile = String(saveTo);
    }
    // What the card WILL say for this file, independent of what it is saying
    // now: the cache key, and the only thing the picture depends on.
    function dragCardKey(path) {
        return root.dragGhostIconFor(path) + "\u0000" + root.dragGhostLabelFor(path);
    }
    function cachedCard(path) {
        const cache = root.dragGhostCache ?? ({});
        return String(cache[root.dragCardKey(path)] ?? "");
    }
    // Photograph the card for this file if it is not already in hand. Called
    // when the pointer ENTERS a row: by the time a press becomes a drag there
    // has been at least a frame, usually many, so the picture is waiting.
    function warmDragCard(path) {
        if (root.cachedCard(path).length > 0)
            return true;
        // One at a time. Sweeping the pointer down a list would otherwise ask
        // for a grab per row, and every one of them renders a frame.
        if (root.dragGhostGrabPending)
            return false;
        const key = root.dragCardKey(path);
        root.dragGhostIcon = root.dragGhostIconFor(path);
        root.dragGhostLabel = root.dragGhostLabelFor(path);
        root.dragGhostGrabPending = true;
        // A turn of the event loop, because the card's width is its row's
        // implicit width: grabbed in the same breath, the picture can be of the
        // card at its previous size, or with the previous name on it.
        Qt.callLater(function () {
            dragGhost.grabToImage(function (result) {
                root.dragGhostGrabPending = false;
                const url = result && result.url ? String(result.url) : "";
                if (url.length === 0)
                    return;
                const cache = Object.assign({}, root.dragGhostCache ?? ({}));
                const keys = Object.keys(cache);
                if (keys.length >= root.dragGhostCacheLimit)
                    delete cache[keys[0]];
                cache[key] = url;
                root.dragGhostCache = cache;
            });
        });
        return false;
    }
    // The press. Hands over a picture in the SAME event when one was warmed --
    // that is what makes the card follow the cursor -- and only falls back to
    // photographing on the spot when it was not (a keyboard-initiated drag, a
    // pointer that arrived and pressed within one frame). The fallback is worth
    // keeping: without it those drags would carry nothing at all.
    function beginDrag(path) {
        root.dragGhostIcon = root.dragGhostIconFor(path);
        root.dragGhostLabel = root.dragGhostLabelFor(path);
        root.dragGhostFile = "";
        const ready = root.cachedCard(path);
        root.dragGhostImage = ready;
        root.dragGhostGrabbed = ready.length > 0;
        if (ready.length > 0)
            return;
        Qt.callLater(function () {
            dragGhost.grabToImage(function (result) {
                root.noteGrab(result, "");
            });
        });
    }
    Rectangle {
        id: dragGhost
        // Parked outside the window: in the scene, never in sight. Being off
        // screen is not what stops a grab -- that was checked, not assumed: a
        // card 98x36 here photographs as 147x54 (1.5x dpr) with its icon and
        // its name in it, because the grab renders the item's own subtree into
        // a layer rather than reading it back off the screen. What a grab does
        // need is a window that is visible; an item in a hidden window gets no
        // answer at all.
        x: -4000
        y: -4000
        visible: true
        width: Math.min(280, ghostRow.implicitWidth + 22)
        height: 36
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer2
        border.width: 1
        border.color: Appearance.colors.colOutlineVariant
        Row {
            id: ghostRow
            // Hung from the LEFT edge, not centred: the hand holds the icon
            // (Drag.hotSpot 18,18), and a centred row puts the icon wherever
            // the name happens to be long -- so the card would slide sideways
            // under the pointer as the label changed. 11 px of margin either
            // side is what makes the card's width formula symmetrical.
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: root.dragGhostIcon
                iconSize: 18
                color: Appearance.colors.colOnLayer2
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(220, implicitWidth)
                text: root.dragGhostLabel
                elide: Text.ElideMiddle
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer2
            }
        }
    }

    // ── A press anywhere else ends the path edit ─────────────────────────
    //
    // The path box leaves edit mode when it loses FOCUS (the pathLabel's own
    // onActiveFocusChanged) or when Enter/Escape is pressed inside it -- and
    // nothing a click can land on takes focus in this app: the rows, the pane,
    // the nav and the toolbar are MouseAreas, and a MouseArea does not take
    // focus. So once the box was opened -- clicking the empty part of it, or
    // Ctrl+L -- the full path stayed on screen until one of those keys was
    // pressed, and clicking into the folder did not put the breadcrumbs back.
    //
    // This is the "anywhere else" half, and it is ONE catcher rather than a
    // line in every press target in the file (a list that had already grown one
    // hole: a folder with no rows had nothing on screen to aim at). It is
    // enabled only while the path is being edited, and it does not SWALLOW the
    // press: `mouse.accepted = false` (in every case, including inside the box)
    // hands it on to whatever is under it, so the click is still the click it
    // would have been -- the caret still lands where it was clicked inside the
    // box, a file still selects, a right-click still opens its menu.
    MouseArea {
        id: pathEditDismiss
        anchors.fill: parent
        // Present only while it is doing its job. A full-window MouseArea that
        // merely sits there DISABLED is still the topmost item under the
        // pointer, and the cursor the pointer shows comes from that item -- so
        // `enabled: false` alone left this layer answering for every pixel in
        // the window with a plain arrow, over whatever the app had actually
        // asked for (the I-beam in the path box, the hand over a button, the
        // resize arrows on a column divider).
        visible: root.editingPath
        enabled: root.editingPath
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        // Composed events (clicked/doubleClicked/pressAndHold) have to be
        // allowed to travel down too, or a row below would get the press and
        // never the click that selecting it is made of.
        propagateComposedEvents: true
        onPressed: mouse => {
            const p = pathEditDismiss.mapToItem(pathBox, mouse.x, mouse.y);
            // Inside the box the press is the edit itself -- it positions the
            // caret -- so there is nothing to finish, only to pass on.
            if (!pathBox.contains(p))
                root.finishPathEdit();
            mouse.accepted = false;
        }
    }

    // ── Context menu (and the command bar's Sort popover) ───────────────
    Popup {
        id: contextMenu
        x: root.menuX
        y: root.menuY
        width: root.menuWidth
        // The popup's box, spelled out, because left to itself it was 12px.
        //
        // A Popup is sized from its content item's implicit height, and a
        // ColumnLayout of plain `Item` delegates contributes nothing to it:
        // every delegate sets Layout.preferredHeight (30, or 7 for a
        // separator) and has no implicitHeight at all. So the box measured
        // 258x12 -- two paddings and no rows -- while the rows DREW 599px
        // below it, and Qt routes a click by the popup's own geometry. Only
        // the top sliver of a menu was clickable; a press lower down was
        // "outside the popup", so it dismissed the menu and fell through to
        // the file list behind it. Measured, with a real pointer: a press on
        // row 5 of 12 closed the menu and selected the file under it. That is
        // the whole of "the buttons displayed do nothing".
        //
        // The rows are the same 30/7px the layout uses, so the box and what
        // is drawn are one number (menuHeight).
        height: root.menuHeight(root.menuItems)
        padding: 6
        visible: root.menuOpen
        onClosed: root.closeMenu()
        background: Rectangle {
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 1
            Repeater {
                model: root.menuItems
                delegate: Item {
                    required property var modelData
                    Layout.fillWidth: true
                    // `!!` on both reads: a plain item has no `separator` key
                    // at all, and binding `undefined` to a bool is a runtime
                    // warning per row per rebuild for no reason.
                    Layout.preferredHeight: (modelData.separator === true) ? 7 : 30
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: modelData.separator === true
                        color: Appearance.colors.colOutlineVariant
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: modelData.separator !== true
                        radius: Appearance.rounding.small
                        color: itemHover.containsMouse && modelData.enabled
                            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.8) : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 10
                            MaterialSymbol {
                                text: modelData.icon
                                iconSize: 16
                                color: modelData.enabled ? Appearance.colors.colOnLayer1 : Appearance.m3colors.m3outline
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: modelData.label
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: modelData.enabled ? Appearance.colors.colOnLayer0 : Appearance.m3colors.m3outline
                            }
                        }
                        MouseArea {
                            id: itemHover
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !modelData.separator && modelData.enabled
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.runMenu(modelData)
                        }
                    }
                }
            }
        }
    }

    // ── Rename dialog (preselected, Enter commits, Escape cancels) ──────
    Popup {
        id: renamePopup
        anchors.centerIn: parent
        width: 380
        padding: 14
        visible: root.renaming
        modal: true
        closePolicy: Popup.NoAutoClose
        background: Rectangle {
            id: renamePopupBg
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 10
            StyledText {
                // "New file" / "New folder" / "Rename": the same dialog, and
                // the title is the only thing that says which of the three it
                // is doing.
                text: root.namePromptTitle()
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
            // The name box, with a border of its own. The popup around it is
            // already a bordered surface, so an input that is only a bare
            // TextInput reads as text floating in the dialog rather than as the
            // thing you are typing into: this is the one field in the window
            // that expects a keystroke the moment it appears, and it says so.
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Rectangle {
                    id: renameFieldFrame
                    Layout.fillWidth: true
                    Layout.preferredHeight: 30
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer1
                    border.width: 1
                    border.color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
                    StyledTextInput {
                        id: renameField
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        text: root.renameDraft
                        onTextChanged: root.renameDraft = text
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                root.commitRename();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Escape) {
                                root.cancelRename();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Tab && root.renameExtShown) {
                                // One Tab reaches the extension, and lands with it
                                // selected: the box exists to be changed, and a
                                // caret parked in front of "png" is how a
                                // keystroke silently makes it "xpng".
                                renameExtField.forceActiveFocus();
                                renameExtField.selectAll();
                                event.accepted = true;
                            }
                        }
                        Keys.onShortcutOverride: event => {
                            if (event.key === Qt.Key_Escape) event.accepted = true;
                        }
                    }
                }
                // The extension in a box of its own. It arrives filled with the
                // file's OWN extension (case and all), so renaming the stem is
                // the whole job and the old "retype the .png or lose it" is
                // gone. Emptied, it removes the extension; edited, it is the
                // only thing that changes it -- what the name box says about
                // dots is a name, not a type.
                Rectangle {
                    id: renameExtFrame
                    visible: root.renameExtShown
                    Layout.preferredWidth: 92
                    Layout.preferredHeight: 30
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer1
                    border.width: 1
                    border.color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 1
                        // The dot is drawn by the dialog, not typed by anyone:
                        // the box's text is just "png", so a stray leading dot
                        // cannot make a name like "notes..txt".
                        StyledText {
                            text: "."
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                        }
                        StyledTextInput {
                            id: renameExtField
                            Layout.fillWidth: true
                            verticalAlignment: TextInput.AlignVCenter
                            text: root.renameExt
                            onTextChanged: root.renameExt = text
                            // Reached with Tab, this lands SELECTED: the box
                            // holds the type that is being replaced.
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    root.commitRename();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Escape) {
                                    root.cancelRename();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                                    renameField.forceActiveFocus();
                                    renameField.selectAll();
                                    event.accepted = true;
                                }
                            }
                            Keys.onShortcutOverride: event => {
                                if (event.key === Qt.Key_Escape) event.accepted = true;
                            }
                        }
                    }
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                ActionButton { implicitWidth: 96; label: Translation.tr("Cancel"); onActivated: root.cancelRename() }
                ActionButton { implicitWidth: 110; primary: true; label: root.namePromptAction(); onActivated: root.commitRename() }
            }
        }
    }

    // ── Permanent-delete confirmation (Trash needs no asking) ───────────
    Popup {
        id: confirmPopup
        anchors.centerIn: parent
        width: 420
        padding: 14
        visible: root.confirmingDelete
        modal: true
        closePolicy: Popup.NoAutoClose
        background: Rectangle {
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 10
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Delete permanently? These items will not go to the Trash.")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer0
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                ActionButton { implicitWidth: 96; label: Translation.tr("Cancel"); onActivated: root.confirmingDelete = false }
                ActionButton {
                    implicitWidth: 110
                    danger: true
                    label: Translation.tr("Delete")
                    onActivated: {
                        root.confirmingDelete = false;
                        keyLayer.forceActiveFocus();
                        root.deleteItems(root.selection);
                    }
                }
            }
        }
    }

    // ── Replace confirmation (save only) ────────────────────────────────
    // "Save" on a name that is already there. Cancel keeps the dialog and the
    // typed name (that is what makes this a question rather than a refusal);
    // Replace answers the dialog with that file's URI, which is what the
    // application asked for and what lets it write over the file.
    //
    // Escape closes it like the button does. The content's own Escape would
    // otherwise leave the whole dialog, losing the name the person just typed
    // over a prompt they had not answered yet.
    Popup {
        id: replaceSavePopup
        anchors.centerIn: parent
        width: 440
        padding: 14
        visible: root.confirmingSave
        modal: true
        closePolicy: Popup.CloseOnEscape
        onClosed: {
            if (root.confirmingSave)
                root.cancelSaveReplace();
        }
        background: Rectangle {
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 10
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Replace “%1”? A file with that name is already in this folder.")
                    .arg(root.confirmingSaveName)
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer0
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                ActionButton {
                    implicitWidth: 96
                    label: Translation.tr("Cancel")
                    onActivated: root.cancelSaveReplace()
                }
                ActionButton {
                    implicitWidth: 120
                    danger: true
                    label: Translation.tr("Replace")
                    onActivated: root.acceptSaveReplace()
                }
            }
        }
    }

    // ── Properties ──────────────────────────────────────────────────────
    Popup {
        id: infoPopup
        anchors.centerIn: parent
        width: 480
        padding: 14
        visible: root.infoTarget !== null
        modal: true
        onClosed: root.infoTarget = null
        background: Rectangle {
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 10
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Properties")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.fillWidth: true
                text: root.infoText
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }
            ActionButton {
                Layout.alignment: Qt.AlignRight
                implicitWidth: 96
                label: Translation.tr("Close")
                onActivated: root.infoTarget = null
            }
        }
    }

    // ── Open with ───────────────────────────────────────────────────────
    //
    // The list is the applications that DECLARE this file's type, and when
    // none does (the case that brought the user here) every installed
    // application, because an empty dialog is not an answer. The default
    // handler is first and labelled, so the row under the pointer is the one a
    // plain double-click would have used anyway.
    Popup {
        id: openWithPopup
        anchors.centerIn: parent
        width: 440
        padding: 14
        visible: root.openWithOpen
        modal: true
        onClosed: root.closeOpenWith()
        background: Rectangle {
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 8
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Open with")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
            // Which file, and what the desktop thinks it IS -- the second half
            // is the reason a chooser was needed at all.
            StyledText {
                Layout.fillWidth: true
                text: root.baseName(root.openWithPath)
                    + (root.openWithMime.length > 0 ? "  ·  " + root.openWithMime : "")
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
                elide: Text.ElideMiddle
                wrapMode: Text.Wrap
            }
            StyledText {
                Layout.fillWidth: true
                visible: root.openWithNote.length > 0
                text: root.openWithNote
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }
            ListView {
                id: openWithList
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? Math.min(root.openWithApps.length * 40, 320) : 0
                visible: root.openWithApps.length > 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.openWithApps
                delegate: Rectangle {
                    required property var modelData
                    width: openWithList.width
                    height: 40
                    radius: Appearance.rounding.small
                    color: openWithRow.containsMouse
                        ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84) : "transparent"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 8
                        spacing: 10
                        Image {
                            Layout.preferredWidth: 22
                            Layout.preferredHeight: 22
                            sourceSize.width: 44
                            sourceSize.height: 44
                            fillMode: Image.PreserveAspectFit
                            source: Quickshell.iconPath(
                                String(modelData.icon ?? "").length > 0
                                    ? String(modelData.icon)
                                    : String(modelData.id ?? "").replace(/\.desktop$/, ""),
                                Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: -2
                            StyledText {
                                Layout.fillWidth: true
                                text: modelData.name ?? ""
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colOnLayer0
                            }
                            StyledText {
                                Layout.fillWidth: true
                                visible: String(modelData.generic ?? "").length > 0
                                text: modelData.generic ?? ""
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                            }
                        }
                        StyledText {
                            visible: modelData.default === true
                            text: Translation.tr("Default")
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colPrimary
                        }
                    }
                    MouseArea {
                        id: openWithRow
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.runOpenWith(modelData)
                    }
                }
            }
            ActionButton {
                Layout.alignment: Qt.AlignRight
                implicitWidth: 96
                label: Translation.tr("Cancel")
                onActivated: root.closeOpenWith()
            }
        }
    }

    // ── The drive prompt: rename, drive letter, format ─────────────────
    // One dialog for the three actions that need a word typed before they can
    // run. Rename and drive letter differ only in where the word goes (the
    // filesystem's label, or the mount point) so they share a body; Format uses
    // the same box but makes the typed word a confirmation of the drive's own
    // name, because it is the one action here that destroys data.
    Popup {
        id: volumePromptPopup
        anchors.centerIn: parent
        width: 440
        padding: 14
        visible: root.volumePromptKind.length > 0
        modal: true
        closePolicy: Popup.NoAutoClose
        background: Rectangle {
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 10
            StyledText {
                Layout.fillWidth: true
                text: root.volumePromptTitle()
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
            // Which drive is about to change. A prompt that does not name its
            // target is how "I formatted the wrong stick" happens.
            StyledText {
                Layout.fillWidth: true
                text: {
                    const v = root.volumePromptTarget;
                    if (!v) return "";
                    return root.volumeLabel(v) + "  ·  " + v.path + "  ·  " + root.volumeSubtitle(v);
                }
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }
            StyledText {
                Layout.fillWidth: true
                text: root.volumePromptHint()
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: root.volumePromptKind === "format" ? Appearance.colors.colError : Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }
            StyledTextInput {
                id: volumePromptField
                // The confirmation has nothing to type: its answer is the
                // button, so the field is not drawn at all.
                visible: root.volumePromptKind !== "confirm"
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                verticalAlignment: TextInput.AlignVCenter
                onTextChanged: root.volumePromptDraft = text
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.commitVolumePrompt();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape) {
                        root.closeVolumePrompt();
                        event.accepted = true;
                    }
                }
                Keys.onShortcutOverride: event => {
                    if (event.key === Qt.Key_Escape) event.accepted = true;
                }
            }
            // The drive letter's whole payoff, shown before it is applied:
            // the mount point the name produces.
            StyledText {
                Layout.fillWidth: true
                visible: root.volumePromptKind === "letter"
                text: `/run/media/${root.userName}/${String(root.volumePromptDraft ?? "").trim().replace(/[^\w.-]+/g, "_")}`
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                ActionButton {
                    implicitWidth: 96
                    label: Translation.tr("Cancel")
                    onActivated: root.closeVolumePrompt()
                }
                ActionButton {
                    implicitWidth: 110
                    primary: root.volumePromptKind !== "format"
                    danger: root.volumePromptKind === "format"
                    label: root.volumePromptKind === "format" ? Translation.tr("Format")
                        : (root.volumePromptKind === "letter" ? Translation.tr("Apply")
                            : (root.volumePromptKind === "confirm"
                                ? (root.volumeRemoval(root.volumePromptTarget) === "eject"
                                    ? Translation.tr("Eject") : Translation.tr("Unmount"))
                                : Translation.tr("Rename")))
                    onActivated: root.commitVolumePrompt()
                }
            }
        }
    }

    // ── Keyboard: Explorer's, as far as it makes sense here ─────────────
    // Ctrl+P toggles the preview pane, the same chord Explorer and every other
    // file manager puts on it. Not in the picker: a file dialog asks a question,
    // and a preview pane is not part of the answer.
    Shortcut {
        sequence: "Ctrl+P"
        enabled: !root.pickerMode
        onActivated: root.previewPane = !root.previewPane
    }
    // Ctrl+T toggles the pictures in the large tiles.
    Shortcut {
        sequence: "Ctrl+T"
        enabled: !root.pickerMode
        onActivated: root.tilePreviews = !root.tilePreviews
    }
    Shortcut { sequence: "Ctrl+A"; onActivated: root.selectAll() }
    Shortcut {
        sequence: "F2"
        enabled: root.selection.length === 1 && !root.pickerMode
        onActivated: root.beginRename(root.selection[0])
    }
    Shortcut {
        sequence: "Delete"
        enabled: root.hasSelection && !root.pickerMode
        onActivated: root.trashItems(root.selection)
    }
    Shortcut {
        sequence: "Shift+Delete"
        enabled: root.hasSelection && !root.pickerMode
        onActivated: root.askPermanentDelete()
    }
    Shortcut { sequence: "Ctrl+C"; enabled: root.hasSelection; onActivated: root.copySelection(false) }
    Shortcut {
        sequence: "Ctrl+X"
        enabled: root.hasSelection && !root.pickerMode
        onActivated: root.copySelection(true)
    }
    Shortcut {
        sequence: "Ctrl+V"
        enabled: root.clipboard.length > 0 && !root.pickerMode
        onActivated: root.pasteInto(root.currentFolderPath())
    }
    Shortcut {
        sequence: "Ctrl+Shift+N"
        enabled: !root.pickerMode
        onActivated: root.newFolder()
    }
    // The file half of the pair, next to the folder's: Ctrl+Shift+N makes a
    // folder, Ctrl+Alt+N a file -- Explorer's own pair, so there is one to
    // remember rather than one to guess at.
    Shortcut {
        sequence: "Ctrl+Alt+N"
        enabled: !root.pickerMode
        onActivated: root.newFile()
    }
    Shortcut {
        sequence: "Ctrl+L"
        enabled: !root.pickerMode
        onActivated: root.beginPathEdit()
    }
    Shortcut { sequence: "F5"; onActivated: root.refresh() }
    Shortcut { sequence: "Alt+Left"; onActivated: root.goBack() }
    Shortcut { sequence: "Alt+Right"; onActivated: root.goForward() }
    Shortcut {
        sequence: "Return"
        // Only while the FILE LIST is the focused area: once Tab has moved the
        // keyboard to the toolbar, Enter belongs to the button the arrows are
        // on (the key layer), not to whatever row the mouse selected before.
        enabled: !root.renaming && !root.editingPath && root.focusArea === "list"
            && (root.pickerMode ? root.pickerCanConfirm : root.selIndex >= 0)
        // Enter means "the default button" in a dialog and "open the selected
        // thing" in a window -- two different verbs that both live on Enter.
        onActivated: {
            if (root.pickerMode) root.pickerConfirm();
            else root.activate(root.selIndex);
        }
    }

    // ── "Dismiss" as a verb, in one place ───────────────────────────────
    //
    // Escape and a press outside the dialog are the same request: take away
    // the thing that is in the way. The key layer below used to spell that
    // ladder out inline, which was fine while Escape was its only caller; the
    // picker's backdrop press is the second one (filemanager-picker.qml), and
    // two copies of "menu, then prompt, then leave" is how a dialog ends up
    // closing the menu on one route and the whole thing on the other.
    //
    // The ladder: an OPEN MENU or an OPEN PROMPT is what is in the way, so
    // that closes first and the file list stays -- one press, one thing, the
    // way Escape has always worked here. With neither, the answer is the
    // dialog's own answer: cancel in a picker, quit in the window.
    //
    // NOT the rename prompt, deliberately: it is a modal Popup that owns
    // Escape itself (its ShortcutOverride keeps the key from reaching this
    // layer), and a backdrop press is not going to be the first route into it
    // that the dialog does not guard. Rename stays a keyboard-only exit.
    function dismissTopLevel(): void {
        if (root.volumePromptKind.length > 0) root.closeVolumePrompt();
        else if (root.menuOpen) root.closeMenu();
        else if (root.pickerMode) root.pickerCancelled();
        else root.quitRequested();
    }

    // Arrow keys and Escape live on the pane's key layer, where they belong:
    // a Shortcut for every arrow would fight the search box, and Escape here
    // has to defer to the app-level shortcut that closes the popup -- except
    // when a menu or a dialog is up, which is what the override guards.
    Item {
        id: keyLayer
        anchors.fill: parent
        // UNDER everything, and it has to be: this layer covers the whole
        // window, and the cursor the pointer shows is resolved from the item
        // that is on top at that point. Sitting on top of the app with no
        // cursor of its own, it answered for every pixel in the window -- so
        // the whole app was stuck on the default arrow: no I-beam over the path
        // box, no hand over a button or a tab, and no resize arrows on a column
        // divider, no matter what each of them asked for. The key events this
        // exists for are delivered to the FOCUSED item, which is set by
        // forceActiveFocus() at every point of use -- focus does not care about
        // stacking, so nothing about the keyboard changes.
        z: -1
        focus: true
        Keys.onPressed: event => {
            if (root.editingPath || root.renaming) return;
            // ── Tab / Shift+Tab: the areas (see focusAreas) ────────────────
            // Handled HERE and not as a Shortcut: Qt Quick matches no Shortcut
            // for Tab at all, because Tab is the window's own focus-traversal
            // key and never reaches the shortcut map (verified: a Shortcut on
            // "Tab" fires never, while the same handling here does). Accepting
            // it here is also what stops Qt's traversal from doing something
            // half-way on a window that has no `activeFocusOnTab` items.
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                const back = event.key === Qt.Key_Backtab
                    || ((event.modifiers & Qt.ShiftModifier) !== 0);
                root.stepFocusArea(back ? -1 : 1);
                event.accepted = true;
                return;
            }
            // ── The focused AREA decides what the arrows and Enter do ─────
            // Tab picked the area (the two Shortcuts above); these are the keys
            // INSIDE it, and every one of them ends in a function the mouse
            // already calls.
            if (root.focusArea === "toolbar" && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
                root.stepFocusIndex(event.key === Qt.Key_Left ? -1 : 1);
                event.accepted = true;
                return;
            }
            if (root.focusArea === "nav" && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
                root.stepFocusIndex(event.key === Qt.Key_Up ? -1 : 1);
                event.accepted = true;
                return;
            }
            if (root.focusArea !== "list" && (event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) {
                root.activateFocus();
                event.accepted = true;
                return;
            }
            // Escape walks back to the list first, and only then does what it
            // has always done (close the menu, leave the app).
            if (root.focusArea !== "list" && event.key === Qt.Key_Escape
                    && !root.menuOpen && root.volumePromptKind.length === 0) {
                root.setFocusArea("list");
                event.accepted = true;
                return;
            }
            // Everything below belongs to the FILE LIST, and only to it: with
            // the ring on the toolbar, Down must not also walk the files.
            if (root.focusArea !== "list") return;
            if (event.key === Qt.Key_Down) { root.stepSelection(1); event.accepted = true; }
            else if (event.key === Qt.Key_Up) { root.stepSelection(-1); event.accepted = true; }
            else if (event.key === Qt.Key_Home) { root.selectIndex(0, false, false); root.scrollToIndex(0); event.accepted = true; }
            else if (event.key === Qt.Key_End) {
                root.selectIndex(root.rows.length - 1, false, false);
                root.scrollToIndex(root.rows.length - 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Backspace) {
                root.goUp();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.dismissTopLevel();
                event.accepted = true;
            }
        }
        Keys.onShortcutOverride: event => {
            if (event.key === Qt.Key_Escape && (root.menuOpen || root.renaming || root.editingPath
                    || root.volumePromptKind.length > 0 || root.confirmingSave))
                event.accepted = true;
        }
    }

    // ── Inline components ───────────────────────────────────────────────

    // The keyboard's ring. Drawn INSIDE the area it belongs to -- one line per
    // area in the layout, no coordinate math and no z-order guessing -- and,
    // for the areas that still carry one, the only thing that tells the eye
    // where Tab has taken the keyboard. The file list deliberately does NOT
    // (see the pane): it is the default area, so its ring stood there looking
    // like a border rather than like an answer.
    component FocusRing: Rectangle {
        id: ring
        property string area: ""
        anchors.fill: parent
        anchors.margins: 1
        radius: Appearance.rounding.small
        color: "transparent"
        // ONE pixel, half-strength, not two at full accent. The history is
        // worth keeping: 2026-10-11 thinned and dimmed this ring ("that weird
        // light line around the pane") on the reasoning that it has to stay
        // findable, and 2026-10-13 the list's was removed outright, because on
        // the area the keyboard SITS in a ring is not findable information --
        // it is furniture. What is left appears only where Tab has actually
        // taken the keyboard, which is the one case it has to answer for.
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.25)
        visible: root.focusArea === ring.area
        z: 20
    }

    // ── A command, the quiet-lock way ─────────────────────────────────
    //
    // The bar's file actions as tracked micro-capitals that underline on hover,
    // instead of glyphs sitting in their own boxes. The window has exactly one
    // loud thing in it now -- the folder's name -- and one outlined thing, the
    // selection; a row of filled buttons competed with both, which is the report
    // that started this.
    //
    // It carries the contract the keyboard walker needs (`pressFromKeyboard`,
    // `keyFocused`, `tip`), so the arrows and Enter walk and press these exactly
    // as they did the buttons they replaced.
    component QuietCommand: Item {
        id: cmd
        property string label: ""
        property string tip: ""
        // The one word that is always lit and always underlined: New is the
        // action the bar exists for.
        property bool primary: false
        property bool keyFocused: false
        signal activated(real px, real py)
        function pressFromKeyboard() {
            cmd.activated(cmd.width / 2, cmd.height / 2);
        }
        implicitWidth: cmdText.implicitWidth + 14
        implicitHeight: 30
        opacity: enabled ? 1 : 0.3

        StyledText {
            id: cmdText
            anchors.centerIn: parent
            // Full-width plus, the same glyph the menu rows use.
            text: (cmd.primary ? "\uFF0B " : "") + String(cmd.label).toUpperCase()
            font.pixelSize: Appearance.font.pixelSize.smallest
            font.letterSpacing: 1.9
            font.weight: Font.Medium
            color: (cmd.keyFocused || cmdHover.containsMouse)
                ? Appearance.colors.colOnLayer0
                : Appearance.colors.colSubtext
        }
        // The rule under the word. Scaled from its left edge rather than
        // widened: animating `width` would re-lay-out the whole row every frame,
        // and this is a 1 px line whose only job is to say "this is live".
        Rectangle {
            anchors.left: cmdText.left
            anchors.right: cmdText.right
            anchors.top: cmdText.bottom
            anchors.topMargin: 2
            height: 1
            color: (cmdHover.containsMouse || cmd.keyFocused)
                ? Appearance.colors.colOnLayer0
                : CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.45)
            // A Scale transform, not `scale`: that property is one real number
            // for the whole item, so growing the rule with it would grow its
            // height too. This scales on x alone (`Behavior on scale` is also
            // not a thing for a plain real -- QML rejects it at load, which is
            // how this was caught).
            transform: Scale {
                origin.x: 0
                origin.y: 0.5
                xScale: (cmdHover.containsMouse || cmd.keyFocused) ? 1 : (cmd.primary ? 1 : 0)
                Behavior on xScale {
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                }
            }
        }
        MouseArea {
            id: cmdHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: cmd.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: cmd.activated(mouse.x, mouse.y)
            ToolTip.visible: cmdHover.containsMouse && cmd.tip.length > 0
            ToolTip.text: cmd.tip
            ToolTip.delay: 500
        }
    }

    component IconButton: Rectangle {
        id: btn
        property string symbol: ""
        property string tip: ""
        property bool active: false
        // Read by the key layer: this is the button the ARROWS are on inside
        // the toolbar stop, and `pressFromKeyboard` is how Enter presses it --
        // the same signal a click emits, so a key can do nothing a mouse could
        // not.
        property bool keyFocused: false
        function pressFromKeyboard() {
            btn.activated(btn.width / 2, btn.height / 2);
        }
        // Both coordinates and no coordinates are accepted: the Sort button
        // needs the point the click landed on to place its popover, and every
        // other button ignores the arguments.
        signal activated(real px, real py)
        implicitWidth: 34
        implicitHeight: 30
        radius: Appearance.rounding.small
        opacity: enabled ? 1 : 0.35
        color: btn.keyFocused
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.55)
            : (btn.active
                ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.8)
                : (btnHover.containsMouse ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.86) : "transparent"))
        MaterialSymbol {
            anchors.centerIn: parent
            text: btn.symbol
            iconSize: 17
            color: (btn.keyFocused || btn.active)
                ? Appearance.colors.colPrimary
                : (btnHover.containsMouse ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1)
        }
        MouseArea {
            id: btnHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: btn.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated(mouse.x, mouse.y)
            ToolTip.visible: btnHover.containsMouse && btn.tip.length > 0
            ToolTip.text: btn.tip
            ToolTip.delay: 500
        }
    }

    component ActionButton: Rectangle {
        id: action
        property string label: ""
        property bool primary: false
        property bool danger: false
        signal activated()
        implicitWidth: 100
        implicitHeight: 30
        radius: Appearance.rounding.small
        opacity: enabled ? 1 : 0.4
        // Danger is the shell's tonal error, not a 15% wash of it: a
        // transparentized colError under colOnError text is dark red on dark
        // maroon in the dark theme -- the label and its button were the same
        // colour, and "Replace" read as a disabled word on a disabled box.
        // colErrorContainer + colOnErrorContainer is the pairing the rest of the
        // desktop uses for a destructive button (the resource monitor's End
        // task), and it is legible in both themes.
        color: action.danger
            ? (actionHover.containsMouse
                ? Appearance.colors.colErrorContainerHover
                : Appearance.colors.colErrorContainer)
            : (action.primary
                ? (actionHover.containsMouse ? Appearance.colors.colPrimaryHover : Appearance.colors.colPrimary)
                : (actionHover.containsMouse
                    ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.86)
                    : CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.4)))
        StyledText {
            anchors.centerIn: parent
            text: action.label
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: action.primary ? Appearance.colors.colOnPrimary
                : (action.danger ? Appearance.colors.colOnErrorContainer : Appearance.colors.colOnLayer0)
        }
        MouseArea {
            id: actionHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: action.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: action.activated()
        }
    }

    component NavHeading: Item {
        id: heading
        property string text: ""
        property bool extra: false
        // A heading that can be FOLDED: the label plus a chevron pointing the
        // way the click will take it. Separate from `extra` (the Refresh glyph)
        // because they are different promises -- one re-reads the list, the
        // other unfolds rows that are already there.
        property bool expandable: false
        property bool expanded: false
        signal extraActivated()
        signal expandToggled()
        Layout.fillWidth: true
        implicitHeight: 26
        Rectangle {
            anchors.fill: parent
            visible: heading.expandable
            radius: Appearance.rounding.small
            color: headingHover.containsMouse
                ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88) : "transparent"
        }
        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: heading.text
            font.pixelSize: Appearance.font.pixelSize.smallest
            font.weight: Font.Medium
            color: Appearance.colors.colSubtext
        }
        MaterialSymbol {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            visible: heading.extra
            text: "refresh"
            iconSize: 14
            color: Appearance.m3colors.m3outline
        }
        MaterialSymbol {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            visible: heading.expandable
            text: heading.expanded ? "expand_less" : "expand_more"
            iconSize: 16
            color: Appearance.m3colors.m3outline
        }
        MouseArea {
            id: headingHover
            anchors.fill: parent
            // A foldable heading is a button across its whole width, chevron
            // included; the Refresh heading keeps its right margin, which is
            // what leaves that glyph its own clicks.
            anchors.rightMargin: heading.expandable ? 0 : 18
            hoverEnabled: true
            enabled: heading.extra || heading.expandable
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (heading.expandable) heading.expandToggled();
                else heading.extraActivated();
            }
        }
    }

    component NavRow: Rectangle {
        id: navRow
        property string label: ""
        property string symbol: ""
        property bool active: false
        // The folder this row leads to. Empty for a row that is not a folder --
        // "This PC" is a list of drives, not a place a file can be put -- and
        // an empty path is what makes this row refuse a drop instead of
        // guessing at one.
        property string path: ""
        // Read by the probe: is the pointer on this row right now. The rows
        // above the drives are hoverable too, and "is the highlight actually
        // drawn" is a question only the row can answer.
        readonly property bool hovered: navHover.containsMouse
        signal activated()
        // Read by the key layer: this is the row the ARROWS are on inside the
        // nav stop (see refreshFocusHighlight).
        property bool keyFocused: false
        Layout.fillWidth: true
        implicitHeight: 30
        radius: Appearance.rounding.small
        // Selection belongs to navMark, the same wash-and-rail the file rows
        // wear: one language for "this is the one you are on" in both panes.
        color: "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 6
            spacing: 8
            z: 1
            MaterialSymbol {
                text: navRow.symbol
                iconSize: 17
                // Brighter, not coloured: the accent is not this row's to spend.
                color: navRow.active ? Appearance.colors.colOnLayer0 : Appearance.colors.colOnLayer1
            }
            CutLabel {
                Layout.fillWidth: true
                text: navRow.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer0
            }
        }
        // The place's marker: grey wash plus the rail, the keyboard's row
        // filled one weight stronger than the picked one. The row's layout is
        // lifted (z: 1) instead of this marker going negative, which is what
        // made a negative z disappear behind the view.
        Rectangle {
            id: navMark
            anchors.fill: parent
            anchors.margins: 2
            radius: Appearance.rounding.small
            color: root.isDropTarget(navRow.path)
                ? root.dropWashColor
                : (navRow.keyFocused
                    ? root.selectionWashStrongColor
                    : (navRow.active
                        ? root.selectionWashColor
                        : (navHover.containsMouse ? root.selectionWashHoverColor : "transparent")))
            Rectangle {
                visible: navRow.active || navRow.keyFocused || root.isDropTarget(navRow.path)
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 2
                anchors.topMargin: 4
                anchors.bottomMargin: 4
                width: root.selectionRail
                radius: width / 2
                color: root.isDropTarget(navRow.path) ? root.dropRailColor : root.selectionRailColor
            }
        }
        MouseArea {
            id: navHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: navRow.activated()
        }
        // A place is a destination too: dropping a file on "Home" puts it at
        // the top of your home folder, which is one gesture instead of two.
        DropArea {
            objectName: "drop-place"
            anchors.fill: parent
            enabled: navRow.path.length > 0
            onEntered: root.dropEntered(navRow.path)
            onExited: root.dropExited(navRow.path)
            onDropped: drop => {
                if (!drop.hasUrls) return;
                root.clearDropTarget();
                root.receiveDrop(drop.urls, navRow.path, drop.action === Qt.MoveAction);
            }
        }
    }

    // A volume row: a place row plus what makes a volume different -- a
    // capacity bar and a mount/eject control that is always visible. A hidden
    // control on the one list that only exists because something is plugged in
    // is a control nobody finds.
    component NavVolumeRow: Rectangle {
        id: volRow
        required property var volume
        // Read by the probe: which half of the row the pointer is over.
        readonly property bool rowHovered: volHover.containsMouse
        readonly property bool controlHovered: volControl.containsMouse
        // The drive you are in. One name for it, because the row's marker and
        // the icon both ask the question and two copies is how they disagree.
        readonly property bool current: volume.mountpoint.length > 0
            && root.folderPath === volume.mountpoint && !root.atThisPc
        Layout.fillWidth: true
        implicitHeight: 48
        radius: Appearance.rounding.small
        color: "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 6
            spacing: 8
            z: 1
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: volume.icon
                iconSize: 18
                color: volRow.current
                    ? Appearance.colors.colOnLayer0 : Appearance.m3colors.m3outline
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                CutLabel {
                    Layout.fillWidth: true
                    text: root.volumeLabel(volume)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnLayer0
                }
                CutLabel {
                    Layout.fillWidth: true
                    // The row answers the click, in the row: "Mounting…" while the
                    // privileged command runs (and it can take a second), and the
                    // reason in place of the device's details if it failed. The
                    // subtitle is the line that was already there, so nothing
                    // moves; only what it says changes.
                    readonly property bool busy: root.mountingPath === volume.path
                    readonly property bool failed: !busy
                        && root.mountFailurePath === volume.path && root.mountFailure.length > 0
                    text: busy ? Translation.tr("Mounting…")
                        : (failed ? root.mountFailure : root.volumeSubtitle(volume))
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: failed ? Appearance.colors.colError
                        : (busy ? Appearance.colors.colPrimary : Appearance.colors.colSubtext)
                }
                CapacityBar {
                    Layout.fillWidth: true
                    usage: root.volumeUsage[volume.mountpoint] ?? null
                    visible: root.mountingPath !== volume.path
                }
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 14
                    visible: root.mountingPath === volume.path
                    MaterialLoadingIndicator {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 14
                        loading: true
                    }
                }
            }
            // The mount / eject / re-read control, always visible (a hidden
            // control on the one list that exists because something is plugged
            // in is a control nobody finds). Its own 22 px hit box, because a
            // glyph-sized target is a target you miss, and hovering it says
            // WHICH verb this is -- see volumeControlTip.
            //
            // It is also a BUTTON now, in the way a button announces itself:
            // a round state layer under the glyph on hover, the glyph itself
            // taking the theme's accent, and the theme's own label. It used to
            // be a bare glyph that answered a hover with Qt's default tooltip --
            // a white box with black text in the middle of a themed window --
            // and the one thing a control with two meanings cannot afford is to
            // look like it is not one.
            Item {
                id: volControlBox
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                visible: root.volumeUnmountable(volume) || volume.mountpoint.length === 0
                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: volControl.containsMouse
                        ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.86) : "transparent"
                }
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: root.volumeControlIcon(volume)
                    iconSize: 17
                    color: volControl.containsMouse
                        ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                    Behavior on color { ColorAnimation { duration: 120 } }
                }
                MouseArea {
                    id: volControl
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Mounting happens on the click; taking a drive away asks
                    // first (requestUnmount).
                    onClicked: root.requestUnmount(volume)
                }
                // The shell's own tooltip, not Qt's: same bubble, same font,
                // same colours as every other label on this desktop.
                StyledToolTip {
                    text: root.volumeControlTip(volume)
                    extraVisibleCondition: false
                    alternativeVisibleCondition: volControl.containsMouse
                }
            }
        }
        // The drive's marker: the same grey wash and rail as a place row.
        Rectangle {
            id: volMark
            anchors.fill: parent
            anchors.margins: 2
            radius: Appearance.rounding.small
            color: root.isDropTarget(volRow.volume.mountpoint)
                ? root.dropWashColor
                : (volRow.current
                    ? root.selectionWashColor
                    : (volHover.containsMouse ? root.selectionWashHoverColor : "transparent"))
            Rectangle {
                visible: volRow.current || root.isDropTarget(volRow.volume.mountpoint)
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 2
                anchors.topMargin: 6
                anchors.bottomMargin: 6
                width: root.selectionRail
                radius: width / 2
                color: root.selectionRailColor
            }
        }
        MouseArea {
            id: volHover
            anchors.fill: parent
            anchors.rightMargin: 28   // leave the eject control its own clicks
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                // Right-click is THE drive menu -- the one the This PC tiles
                // open, with Rename, Change drive letter, Checks, Format,
                // Properties and Eject. It was only reachable from a tile, so a
                // two-finger tap on a drive in this pane (which is what a
                // right-click IS on a touchpad) did nothing at all.
                //
                // The point is mapped to the app root rather than passed as
                // local coordinates: the menu is positioned in that space, and
                // this row lives in the navigation pane, not in the content
                // area where the other callers sit.
                if (mouse.button === Qt.RightButton) {
                    const p = volHover.mapToItem(root, mouse.x, mouse.y);
                    root.openMenu(p.x, p.y, volume.path);
                    return;
                }
                root.rowActivate(volume);
            }
            onDoubleClicked: mouse => {
                if (mouse.button !== Qt.LeftButton) return;
                root.rowActivate(volume);
            }
        }
        // A mounted drive takes a drop the same way a folder row does. The
        // eject control keeps its own 28 px: a drop that landed on it would be
        // a drop on a button, and the button's answer is to take the drive
        // away -- so that strip falls through to the pane instead (which has no
        // destination here) and simply does nothing.
        DropArea {
            objectName: "drop-drive"
            anchors.fill: parent
            anchors.rightMargin: 28
            enabled: volRow.volume.mountpoint.length > 0
            onEntered: root.dropEntered(volRow.volume.mountpoint)
            onExited: root.dropExited(volRow.volume.mountpoint)
            onDropped: drop => {
                if (!drop.hasUrls) return;
                root.clearDropTarget();
                root.receiveDrop(drop.urls, volRow.volume.mountpoint,
                    drop.action === Qt.MoveAction);
            }
        }
    }

    component CapacityBar: Item {
        id: cap
        property var usage: null
        implicitHeight: 4
        Layout.fillWidth: true
        Rectangle {
            anchors.fill: parent
            radius: 2
            color: CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.86)
        }
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            radius: 2
            width: (cap.usage && cap.usage.size > 0)
                ? Math.max(2, parent.width * Math.min(1, cap.usage.used / cap.usage.size)) : 0
            color: (cap.usage && cap.usage.size > 0
                    && cap.usage.used / cap.usage.size > 0.9
                    && cap.usage.avail < 2 * 1024 * 1024 * 1024)
                ? Appearance.colors.colError : Appearance.colors.colPrimary
        }
    }

    // ── CutLabel: the label that is cut at its wall ────────────────────────
    //
    // A label too wide for its box is CUT at the box: full strength, an
    // ellipsis where the wall stopped it, and nothing painted past it. That is
    // what every file manager does, and it is where this app ended up after
    // the opposite (LayeredLabel, retired 2026-10-16): the whole text kept,
    // dimmed to 0.3 and painted on past its own box, with the neighbour
    // declared later painting over it to read as a layer.
    //
    // What that looked like in this window, MEASURED with probeTextOverlap
    // before the change: a tab title laid out at 124 px painting 381 px wide
    // at 0.3 opacity, straight through the close glyph, the next tab's title
    // and the "+" button; a file name painting 381 px at 0.3 opacity under
    // "Date modified" and "Type". Greyed out AND through the wall -- the pair
    // of complaints this replaces.
    //
    // The wall is the label's OWN box, not a `clip` on some ancestor: every
    // use here sits in a layout that hands the label a width (a RowLayout's
    // fillWidth, a header cell's column, a tab's inner width), and `elide` is
    // the one treatment that cannot paint past the width it was given. A clip
    // would hide the same pixels while leaving the box beside it to be told
    // apart from this one by eye.
    component CutLabel: StyledText {
        id: cutLabel
        // The wall, in one property. With an elide the text stops at the width
        // the layout handed it down, and the ellipsis is what says the name
        // goes on rather than having ended there by itself.
        elide: Text.ElideRight
    }

    component HeaderCell: Rectangle {
        id: header
        property string label: ""
        property int field: 0
        property bool alignRight: false
        // Set on the columns whose width is a CHOICE (Date modified, Type,
        // Size): the divider at their left edge can be grabbed and dragged, and
        // the line follows the pointer. Name carries no handle of its own -- it
        // is the flexible column, taking whatever the fixed ones leave -- which
        // is what makes dragging read as one strip of columns rather than four
        // boxes that happen to sit together.
        property bool resizable: false
        property int widthValue: 0
        property var widthSetter: null
        // The grab band: how far INTO this cell, from its left edge, still means
        // "the divider". It has to live inside the cell -- a handle that
        // straddles the boundary belongs to two items at once, and the pointer
        // only gets the resize cursor on the half that the hit test happens to
        // hand over, which is why the two arrows came and went. Eight pixels is
        // a band you can land on without aiming.
        readonly property int grabBand: header.resizable ? 8 : 0
        // How wide this column may get before the flexible Name column would be
        // pushed below its own floor. Past that the layout stops drawing what
        // the drag is setting: the divider quits following the pointer while
        // the number keeps growing, which is the rest of "it glitches out".
        readonly property real maxWidth: {
            const row = header.parent;
            if (!row || !row.width) return -1;
            let others = 0;
            const kids = row.children;
            for (let i = 0; i < kids.length; ++i) {
                const cell = kids[i];
                if (cell !== header && cell.resizable) others += cell.width;
            }
            return row.width - others - root.colMinWidth;
        }
        implicitHeight: 28
        radius: Appearance.rounding.small
        // A column title that does not fit is cut at its own cell's wall (the
        // CutLabel on the title below): "Date modi…" rather than a title
        // running on over the column to its right.
        //
        // Two earlier shapes of this, both MEASURED with the overlap probe and
        // both wrong in the same way: anchored to one side only, a Text takes
        // its implicit width, so a squeezed column drew its title straight over
        // its neighbour -- "Name ↑" sitting on "Date modified" by 14 px in a
        // 520-wide card, and by 38 px at 460, where the Name column collapses to
        // nothing and both titles start at the same x. Then the title slid
        // under the next column instead and dimmed to 0.3 on the way, which is
        // greyed out AND over the wall at once. A cell's title belongs to the
        // cell.
        //
        // Nothing in here lives outside the cell (the divider is at x=0, the
        // grab band is inside it), so the cell itself needs no clip.
        // Tinted when the pointer is on the cell -- but not when it is on the
        // divider, where the cell is not what the pointer is pointing at.
        color: headerHover.containsMouse && !headerHover.onDivider
            ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88) : "transparent"
        // The title is the column it belongs to, and it is laid out in the
        // width of that column -- but it is never cut to fit: a title wider than
        // its cell paints its whole self, slides under the next column's title
        // (which is declared after it and so paints over it) and dims there.
        CutLabel {
            anchors.left: header.alignRight ? undefined : parent.left
            anchors.right: header.alignRight ? parent.right : undefined
            // 8, not 4: the header label and the cells under it are the same
            // column, so they clear the divider by the same amount.
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            // The width the title is LAID OUT in: the column minus those two
            // insets. `Math.max(0, ...)` because a collapsed column (the card
            // narrower than its own four columns) hands out a negative one.
            width: Math.max(0, parent.width - 16)
            horizontalAlignment: header.alignRight ? Text.AlignRight : Text.AlignLeft
            text: header.label + (root.sortField === header.field ? (root.sortReversed ? " ↓" : " ↑") : "")
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: root.sortField === header.field
                ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
        }
        // The divider's line: ONE pixel, at the boundary between this column
        // and the one before it, inset 4px top and bottom so it reads as a
        // column break and not as a wall.
        //
        // AT x=0, inside this cell -- not straddling the boundary. It used to
        // sit at -0.5, which put half its pixels in the cell to the LEFT, a
        // cell with no handle of its own: pressing the visible line you were
        // aiming at then landed on the wrong side of it about half the time,
        // and a press that means SORT looks exactly like a press that means
        // DRAG until you move. The handle and the grab band are now the same
        // object -- the eight pixels starting at this line.
        Rectangle {
            visible: header.resizable
            x: 0
            y: 4
            width: 1
            height: parent.height - 8
            color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant,
                headerHover.dragging ? 0 : (headerHover.onDivider ? 0.25 : 0.65))
        }
        // One MouseArea for the whole cell, because the cell only ever does two
        // things and both are decided by where in it the pointer is: on the
        // divider at its left edge it resizes this column, anywhere else it
        // sorts by it. Two overlapping MouseAreas used to divide that up, and
        // the cursor was the casualty.
        MouseArea {
            id: headerHover
            anchors.fill: parent
            hoverEnabled: true
            // Two facts, split apart so that a check can read the one that does
            // not need a real pointer on the glass: whether this point IS the
            // divider, and whether the pointer is here at all.
            readonly property bool inBand:
                header.resizable && mouseX < header.grabBand
            readonly property bool onDivider: inBand && containsMouse
            // What this cell asks the pointer to look like when it is here.
            // Readable without hovering, which is what makes "the divider shows
            // the resize arrows" checkable from a terminal.
            readonly property int cursorIfHovered:
                inBand ? Qt.SizeHorCursor : Qt.PointingHandCursor
            property bool dragging: false
            // Set when a drag ends, so the click that follows it -- releasing a
            // drag IS a click as far as the MouseArea is concerned -- does not
            // also re-sort the list.
            property bool didDrag: false
            property real startWidth: 0
            property real startX: 0
            cursorShape: headerHover.cursorIfHovered
            onPressed: mouse => {
                headerHover.didDrag = false;
                if (!headerHover.onDivider) return;
                // Window coordinates, not this cell's: see columnDragBegin.
                headerHover.dragging = root.columnDragBegin(header,
                    headerHover.mapToItem(null, mouse.x, mouse.y).x);
            }
            onPositionChanged: mouse => {
                if (!headerHover.dragging) return;
                root.columnDragTo(headerHover.mapToItem(null, mouse.x, mouse.y).x);
            }
            onReleased: {
                if (!headerHover.dragging) return;
                headerHover.dragging = false;
                headerHover.didDrag = true;
                root.columnDragEnd();
            }
            onCanceled: {
                headerHover.dragging = false;
                root.columnDragEnd();
            }
            onClicked: if (!headerHover.didDrag) root.setSort(header.field)
        }
    }

    // ── Places (Quick access) ───────────────────────────────────────────
    readonly property var quickPlaces: [
        { label: Translation.tr("Home"), icon: "home", path: root.homeDir },
        { label: Translation.tr("Desktop"), icon: "desktop_windows", path: root.homeDir + "/Desktop" },
        { label: Translation.tr("Documents"), icon: "description", path: root.homeDir + "/Documents" },
        { label: Translation.tr("Downloads"), icon: "download", path: root.homeDir + "/Downloads" },
        { label: Translation.tr("Pictures"), icon: "image", path: root.homeDir + "/Pictures" },
        { label: Translation.tr("Music"), icon: "music_note", path: root.homeDir + "/Music" },
        { label: Translation.tr("Videos"), icon: "movie", path: root.homeDir + "/Videos" },
        { label: Translation.tr("File system"), icon: "hard_drive", path: "/" }
    ]

    // ── Scriptable state ────────────────────────────────────────────────
    // These exist so the whole app can be driven and CHECKED from a terminal
    // without a pointer: navigate, select, act, and read back what happened.
    function probeState() {
        return JSON.stringify({
            pickerMode: root.pickerMode,
            path: root.currentFolderPath(),
            atThisPc: root.atThisPc,
            count: root.rows.length,
            rawCount: root.rawCount,
            viewMode: root.viewMode,
            tileSize: root.tileSize,
            sortField: root.sortField,
            sortReversed: root.sortReversed,
            showHidden: root.showHidden,
            showExtensions: root.showExtensions,
            filter: root.filter,
            selection: root.selection,
            selIndex: root.selIndex,
            historyIndex: root.historyIndex,
            historyLength: root.history.length,
            tabs: root.tabs.length,
            activeTab: root.activeTab,
            clipboard: root.clipboard.length,
            // How many times this app has put something on the DESKTOP's
            // clipboard: the internal list above can be full while the desktop
            // half never happened, which is exactly the state that made
            // "paste into another app" do nothing.
            clipboardPublished: root.clipboardPublished,
            clipboardType: root.clipboardType,
            ejectAsks: root.unmountAsks,
            renaming: root.renaming,
            volumes: root.volumes.length,
            udisks: root.udisksAvailable,
            // The fast path, as two numbers: the udev socket is being read
            // (hotplugEvents) and what came off it was acted on
            // (hotplugRefreshes). A watcher that is running but forwarding
            // nothing reads as alive in every other way.
            hotplug: (hotplugWatch.running ? "on" : "off") + "/" + root.hotplugEvents
                + "/" + root.hotplugRefreshes,
            statusNote: root.statusNote,
            storage: root.storageText
        });
    }
    // ── Open with ───────────────────────────────────────────────────────
    // The chooser's own state, and the double-click that reaches it: a file
    // nobody handles has to arrive at this list, and that is what a check can
    // assert without a pointer.
    function probeOpenWith() {
        return JSON.stringify({
            open: root.openWithOpen,
            path: root.openWithPath,
            mime: root.openWithMime,
            note: root.openWithNote,
            count: root.openWithApps.length,
            apps: root.openWithApps.map(a => ({
                id: a.id, name: a.name, default: a.default === true
            }))
        });
    }
    function probeOpenName(name) {
        const p = root.currentFolderPath().replace(/\/$/, "") + "/" + String(name ?? "");
        const i = root.indexOfPath(p);
        if (i >= 0) root.openEntry(i);
        return i;
    }
    // Folder sizes, as the manager has them: every folder row on screen with
    // the number the column would draw, and the walker's own state. The second
    // half is the honest answer to "is this feature costing the disk anything
    // right now" -- `queued` and `active` have to reach nothing and STAY there
    // once the visible rows are measured, because nothing here polls.
    function probeSizes() {
        const rows = [];
        for (const r of root.rows) {
            if (!r.isDir) continue;
            rows.push({
                name: r.name,
                bytes: FolderSizes.bytes(r.path),
                shown: root.sizeTextFor(r, FolderSizes.revision),
                pending: FolderSizes.pending(r.path),
                note: FolderSizes.note(r.path)
            });
            if (rows.length >= 24) break;
        }
        return JSON.stringify({ rows: rows, walker: JSON.parse(FolderSizes.probe()) });
    }
    function probeList(limit) {
        const max = Number(limit ?? 40);
        const out = [];
        for (let i = 0; i < Math.min(root.rows.length, max); i++) {
            const r = root.rows[i];
            out.push({
                name: r.name,
                path: r.path,
                dir: r.isDir,
                size: r.size,
                // What the Size column DRAWS for this row: the raw size above
                // is 0 for every folder, so it cannot tell a check whether a
                // folder's weight reached the screen.
                sizeText: root.sizeTextFor(r, FolderSizes.revision),
                modified: root.fmtTime(r.modified),
                type: r.kind,
                selected: root.isSelected(r.path)
            });
        }
        return JSON.stringify(out);
    }
    // What the preview pane is showing, read out. The pane is driven by the
    // selection, so a script asserts it the way a person would: select a row,
    // then read what the pane decided about it.
    function probePreview() {
        return JSON.stringify({
            pane: root.previewPane,
            tiles: root.tilePreviews,
            viewMode: root.viewMode,
            path: root.previewEntryPath,
            kind: root.previewKind,
            // What is actually DRAWN, which is not the same question as what
            // kind of file it is: an .xlsx is kind "office" and view "table".
            view: root.previewView,
            tableHeader: root.previewTable ? (root.previewTable.header ?? []) : [],
            tableRows: root.previewTable && root.previewTable.rows ? root.previewTable.rows.length : 0,
            tableCols: root.previewTable ? (root.previewTable.totalCols ?? 0) : 0,
            tableFirst: root.previewTable && root.previewTable.rows
                ? root.previewTable.rows.slice(0, 3) : [],
            // The table's and the list's own boxes, where they are drawn: a
            // view that has the data but no space in the layout is a bug that
            // looks like "the preview works" from the data alone.
            tableBox: root.previewView === "table"
                ? root.paneRect(previewTableBox, "previewTable") : null,
            listBox: root.previewView === "list"
                ? root.paneRect(previewListBox, "previewList") : null,
            tableShown: root.probeTableShown(),
            listCount: root.previewEntries.length,
            listFirst: root.previewEntries.slice(0, 6).map(function (entry) {
                return String(entry.name ?? "");
            }),
            headline: root.previewHeadline(),
            subtitle: root.previewSubtitle(),
            page: root.previewPage,
            note: root.previewNote,
            body: root.previewBodyText(),
            textLength: root.previewText.length,
            text: root.previewText.slice(0, 400),
            entryPreviewable: root.previewEntry ? root.previewEntry.preview === true : false,
            // The PICTURE's own box, where it is drawn. The pane's width alone
            // is not the question the request asked: a fixed-height image box
            // meant a wider pane handed the picture nothing at all. This rect
            // has to grow with the pane -- and the bucket the thumbnail is
            // generated at, so a checked resize is a sharper picture too.
            image: root.previewKind === "image" && previewImageLoader.item !== null
                ? root.paneRect(previewImageBox, "previewImage") : null,
            imageBucket: root.previewKind === "image" && previewImageLoader.item !== null
                ? previewImageLoader.item.thumbnailSizeName : "",
            // And the pixels the picture itself covers inside that box: with
            // PreserveAspectFit the box can grow and the picture still not, so
            // this is the number that answers "did it get bigger" rather than
            // "did the pane get bigger".
            imagePainted: root.previewKind === "image" && previewImageLoader.item !== null
                ? { width: Math.round(previewImageLoader.item.paintedWidth),
                    height: Math.round(previewImageLoader.item.paintedHeight) }
                : null,
            // A video uses the same box and the same loader, with a frame from
            // the clip in it -- so the check that matters is that something is
            // actually PAINTED there, not that a branch was taken.
            frame: root.previewKind === "video" && previewImageLoader.item !== null
                ? root.paneRect(previewImageBox, "previewFrame") : null,
            framePainted: root.previewKind === "video" && previewImageLoader.item !== null
                ? { width: Math.round(previewImageLoader.item.paintedWidth),
                    height: Math.round(previewImageLoader.item.paintedHeight) }
                : null
        });
    }
    // The table as the grid built it: how many row delegates exist, how wide a
    // column is, and the height the rows add up to. A table can hold the right
    // data and still draw nothing if its delegate model never resolves, and
    // that is invisible from the data alone.
    function probeTableShown() {
        if (root.previewView !== "table") return null;
        return {
            rows: previewTableBody.count,
            columns: previewTableBox.columnCount,
            cellWidth: previewTableBox.cellWidth,
            contentWidth: Math.round(previewTableBody.contentWidth),
            contentHeight: Math.round(previewTableBody.contentHeight)
        };
    }
    function probeVolumes() {
        return JSON.stringify(root.volumes.map(v => ({
            name: v.name,
            path: v.path,
            disk: v.disk,
            label: v.label,
            fstype: v.fstype,
            hasFs: v.hasFs,
            readOnly: v.readOnly,
            // The UUID is the volume's identity, and the key a chosen mount
            // name ("drive letter") is remembered under -- a label can be
            // renamed, this cannot.
            uuid: v.uuid,
            size: v.size,
            tran: v.tran,
            removable: v.removable,
            rotational: v.rotational,
            external: v.external,
            kind: v.kind,
            icon: v.icon,
            mountpoint: v.mountpoint,
            unmountable: root.volumeUnmountable(v),
            usage: root.volumeUsage[v.mountpoint] ?? null
        })));
    }
    // ── The navigation pane, read out as the rows it draws ──────────────
    // Which rows are in the list, in what order, which are folded behind
    // "Advanced", and what the mount/eject control says it would do. The whole
    // of "the 1 TB is on top, then the other SSD, then what you can carry, and
    // the leftovers are folded away" is this function, and "what the label says
    // when you hover it" is controlTip.
    function probeNav() {
        const group = v => v.external || v.kind === "mtp"
            ? (v.kind === "mtp" ? "phone" : "removable")
            : (root.volumeGroup(v) === 2 ? "advanced" : "disk");
        const row = v => ({
            label: root.volumeLabel(v),
            group: group(v),
            kind: v.kind,
            path: v.path,
            mounted: v.mountpoint.length > 0,
            icon: v.icon,
            controlIcon: root.volumeControlIcon(v),
            controlTip: root.volumeControlTip(v),
            unmountable: root.volumeUnmountable(v)
        });
        return JSON.stringify({
            rows: root.navVolumes.map(row),
            advanced: root.navAdvancedVolumes.map(row),
            showAdvanced: root.showAdvancedVolumes,
            advancedCount: root.navAdvancedVolumes.length
        });
    }
    // The phones and cameras on the USB bus, as devices rather than volumes:
    // what was found, where it would mount, whether it is mounted, and whether
    // anything is installed that can read one.
    function probeMtp() {
        return JSON.stringify({
            mounter: root.mtpMounter ? "aft-mtp-mount" : "missing",
            script: root.mtpScanScript,
            root: root.mtpRoot,
            devices: root.mtpDevices.map(d => ({
                name: d.name,
                vendor: d.vendor,
                product: d.product,
                manufacturer: d.manufacturer,
                label: root.mtpLabel(d),
                mountPoint: root.mtpMountPoint(d),
                mounted: root.mtpIsMounted(d)
            })),
            volumes: root.mtpVolumes.map(v => ({
                label: v.label,
                path: v.path,
                kind: v.kind,
                mountpoint: v.mountpoint,
                inList: root.volumes.some(o => o.path === v.path),
                inNav: root.navVolumes.some(o => o.path === v.path),
                // Mounted but answering with nothing: the phone is locked or
                // has not been allowed yet. Reported because it is the one
                // state a person reads as "the phone is not showing".
                silent: root.mtpSilent(v.mountpoint),
                subtitle: root.volumeSubtitle(v)
            })),
            hint: root.mtpUnlockHint(null)
        });
    }
    // The two things only a resize can prove: where the preview pane went, and
    // how much of the path survived in the address bar at that width.
    //
    // `barGap` is the answer to "does the search box run into the path": both
    // boxes are measured as they are DRAWN (in the window's own coordinates),
    // and the space between them is reported. A negative gap is an overlap, a
    // zero gap is two boxes touching, and anything above zero is room. It is
    // measured rather than reasoned about because the two boxes are laid out by
    // the same RowLayout and reasoning about a layout is how the overlap got
    // there in the first place.
    //
    // `navDrawn` is the drive list as it is actually on screen: the labels in
    // draw order with the y each one sits at, from the rows that exist right
    // now -- so "the 1 TB disk is the top row", "the extras are only there once
    // Advanced is open" and "the phone sits between the stick and nothing" are
    // all one assertion each, instead of a story about a model.
    function drawnRows(repeater) {
        const rows = [];
        for (let i = 0; i < repeater.count; i++) {
            const item = repeater.itemAt(i);
            if (!item) continue;
            const at = item.mapToItem(root, 0, 0);
            // The small control's own box, in the same coordinates as the row:
            // it is the one target on a drive row that does something OTHER
            // than open the drive, so "which pixel is the eject button" has to
            // be answerable without a pointer -- a real click can then be put
            // on it, and a hover can be shown to raise the label.
            const layout = item.children.length > 0 ? item.children[0] : null;
            const rawControl = (layout && layout.children.length > 2) ? layout.children[2] : null;
            // An INVISIBLE control is not a target: a hidden item still has a
            // position (the layout gives it none, so it reports the row's own
            // left edge), and reporting that as "the eject button is here" is
            // how a check ends up clicking the row by accident.
            const control = (rawControl && rawControl.visible) ? rawControl : null;
            const centre = control ? control.mapToItem(root, control.width / 2, control.height / 2) : null;
            rows.push({
                label: root.volumeLabel(item.volume),
                kind: item.volume.kind,
                y: Math.round(at.y),
                x: Math.round(at.x),
                width: Math.round(item.width),
                height: Math.round(item.height),
                control: centre ? { x: Math.round(centre.x), y: Math.round(centre.y) } : null,
                // Which half of the row the pointer is actually over. Hover is
                // the only part of a row a script cannot otherwise reach, and
                // "the left side does not respond" is a report about exactly
                // this -- so the answer is readable rather than assumed.
                hovered: item.rowHovered === true,
                controlHovered: item.controlHovered === true,
                controlVisible: control !== null,
                controlTip: root.volumeControlTip(item.volume)
            });
        }
        return rows;
    }
    // The rename dialog's name box as the eye reads it. "Give the box a border"
    // is a claim about pixels, so it is read off the drawn items -- the frame's
    // border width and colour, and the two surfaces that colour has to be told
    // apart from (the field's own fill, the dialog behind it). A border that is
    // the colour of its own fill is not a border, and the probe says so.
    function probeRenameDialog() {
        const frame = renameFieldFrame, pop = renamePopupBg, field = renameField;
        const hex = c => {
            if (!c || c.r === undefined) return String(c);
            const two = v => { const h = Math.round(v * 255).toString(16); return h.length < 2 ? "0" + h : h; };
            return "#" + two(c.r) + two(c.g) + two(c.b);
        };
        const border = hex(frame.border.color);
        return JSON.stringify({
            open: root.renaming,
            border: frame.border.width,
            borderColor: border,
            fieldColor: hex(frame.color),
            popupColor: hex(pop.color),
            // Not the fill, not the dialog, and not a transparent ghost: only
            // then is the field visibly an input rather than floating text.
            distinct: border !== hex(frame.color) && border !== hex(pop.color)
                && (frame.border.color.a === undefined || frame.border.color.a > 0.2),
            radius: frame.radius,
            width: Math.round(frame.width),
            height: Math.round(frame.height),
            // focus: the item holds the keyboard; activeFocus: the surface it
            // sits on is the active window too. The first is what beginRename
            // promises, and it is the one a layer-surface dialog can keep.
            focus: field.focus,
            activeFocus: field.activeFocus,
            text: field.text,
            // Which of the three the dialog is doing, what it says it is, and
            // the name it offers. A prompt that asked for the name of a NEW
            // FILE but was titled "Rename" would be the old bug with a box on
            // it, so the title and the button are readable here too.
            mode: root.creating.length > 0 ? root.creating : "rename",
            title: root.namePromptTitle(),
            action: root.namePromptAction(),
            // The NAME box's text, and separately the extension box's: the two
            // are what the person sees, and `name` is what the pair will become
            // if Enter is pressed now.
            draft: root.renameDraft,
            ext: renameExtField.text,
            extShown: root.renameExtShown,
            extFocus: renameExtField.activeFocus,
            name: root.composePromptName()
        });
    }
    // ── The content views' scroll bars, as they are LAID OUT ─────────────
    //
    // "A thin one on the left, on screen when there is more to scroll" is a
    // claim about three numbers (where the lane sits, how wide the ink is, when
    // the bar is drawn) and none of them can be read off a screenshot of a
    // folder that happens to fit on screen. This answers all of them for
    // whichever view is showing, next to whether the content actually overflows
    // -- so a test can assert the bar is on screen exactly when it should be.
    function probeScrollBars() {
        const views = [
            { which: "thisPc", view: pcGrid },
            { which: "details", view: detailsView },
            { which: "tiles", view: tilesView }
        ];
        const out = [];
        for (const v of views) {
            const bar = v.view.ScrollBar.vertical;
            const content = bar ? bar.contentItem : null;
            out.push({
                which: v.which,
                shown: v.view.visible,
                overflows: v.view.contentHeight > v.view.height,
                view: root.paneRect(v.view, v.which),
                lane: bar ? root.paneRect(bar, "lane") : null,
                onLeft: bar ? bar.onLeft : null,
                handleWidth: bar ? bar.handleWidth : null,
                laneWidth: bar ? Math.round(bar.width) : null,
                handleHeight: content ? Math.round(content.height) : null,
                // Where the INK is, not just the lane it lives in: the thumb's
                // own rect in the window's coordinates, which is the thing the
                // eye sees inside the 8px lane.
                ink: content ? root.paneRect(content, "ink") : null,
                inkOpacity: content ? Math.round(content.opacity * 100) / 100 : null,
                size: bar ? Math.round(bar.size * 1000) / 1000 : null,
                active: bar ? bar.active : null,
                hovered: bar ? bar.hovered : null,
                showWhenScrollable: bar ? bar.showWhenScrollable : null,
                // How far down the list the view ITSELF is, not where the
                // thumb is drawn: the two agree, but only this one can answer
                // "did dragging the bar move the list?" -- which used to be
                // asked of the first row's delegate being destroyed, and that
                // is a proxy that changes with the window's height (the same
                // 40px of pointer scrolls the content further in a short
                // surface than in a tall one) rather than with the fact.
                contentY: Math.round(v.view.contentY),
                contentHeight: Math.round(v.view.contentHeight),
                viewHeight: Math.round(v.view.height),
                policy: bar ? (bar.policy === ScrollBar.AlwaysOn ? "AlwaysOn"
                    : bar.policy === ScrollBar.AsNeeded ? "AsNeeded" : "AlwaysOff") : null
            });
        }
        return JSON.stringify(out);
    }
    // What the quiet-lock header is actually drawn as.
    //
    // The three parts of it are the whole design -- the folder's name at the
    // size the lock screen sets its clock in, the crumbs above it as tracked
    // micro-caps, the HUD numbers on the right -- and none of them is a
    // property a human can read off a screenshot in this client. So the probe
    // reports the numbers the eye would be checking: the pixel size and the
    // tracking, the case, and whether the commands are still words (and still
    // pressable) rather than the boxes they replaced.
    function probeQuietHeader() {
        const cmds = [];
        for (const k of root.focusCandidates("toolbar")) {
            if (k.label === undefined) continue;                 // separators, icons
            cmds.push({ label: k.label, primary: k.primary === true, enabled: k.enabled });
        }
        return JSON.stringify({
            title: quietTitle.text,
            titlePx: quietTitle.font.pixelSize,
            titleWeight: quietTitle.font.weight,
            titleTracking: quietTitle.font.letterSpacing,
            titleWidth: Math.round(quietTitle.paintedWidth),
            // Where each band is DRAWN, and therefore the order the request was
            // about: the name's line, the command words' row under it, and the
            // gap between the two. A screenshot shows the order; these numbers
            // are what a check can assert without one.
            titleTop: Math.round(quietTitle.mapToItem(root, 0, 0).y),
            titleBottom: Math.round(quietTitle.mapToItem(root, 0, quietTitle.height).y),
            commandTop: Math.round(commandRow.mapToItem(root, 0, 0).y),
            commandBottom: Math.round(commandRow.mapToItem(root, 0, commandRow.height).y),
            commandsUnderTitle: commandRow.mapToItem(root, 0, 0).y
                >= quietTitle.mapToItem(root, 0, quietTitle.height).y,
            crumbs: pathBox.crumbFit.items.map(c => c.label),
            crumbPx: crumbMetrics.font.pixelSize,
            hud: quietHudLines(),
            commands: cmds,
            barHeight: root.addressBarHeight,
            // Selection is the wash-and-rail marker now. The style name travels
            // with the numbers that draw it -- the rail's width and the lane the
            // left scrollbar owns -- so a check asserts the shape that is on
            // screen rather than the name alone.
            selectionStyle: root.selectionStyle,
            selectionBorder: root.selectionBorder,
            selectionRail: root.selectionRail,
            selectionLane: root.selectionLane,
        });
    }
    function quietHudLines() {
        const out = [];
        for (let i = 0; i < quietHud.children.length; i++) {
            const c = quietHud.children[i];
            if (c.text !== undefined && c.text.length > 0 && c.visible !== false)
                out.push(c.text);
        }
        return out;
    }

    function probeLayout() {
        const pathRight = pathBox.mapToItem(root, pathBox.width, 0).x;
        // Where the path box sits vertically too: the empty part of it is the
        // one element in the window whose cursor is an I-beam, so a test that
        // hovers it ("do cursors work here at all?") needs its rect.
        const pathTop = pathBox.mapToItem(root, 0, 0).y;
        const searchLeft = searchBox.visible ? searchBox.mapToItem(root, 0, 0).x : -1;
        return JSON.stringify({
            width: root.width,
            height: root.height,
            pathBoxWidth: pathBox.width,
            pathBoxRight: Math.round(pathRight),
            pathBoxTop: Math.round(pathTop),
            pathBoxHeight: Math.round(pathBox.height),
            // The path box as the eye reads it: a hairline all the way round,
            // with rounded corners.
            pathBoxBorder: pathBoxFrame.border.width,
            pathBoxRadius: pathBoxFrame.radius,
            searchWidth: searchBox.width,
            searchLeft: Math.round(searchLeft),
            // The overlap question, answered in numbers: how many pixels sit
            // between the path box's right edge and the search box's left one.
            barGap: searchBox.visible ? Math.round(searchLeft - pathRight) : -1,
            fitCount: pathBox.fitCount,
            previewBelow: root.previewBelow,
            previewPane: root.previewPane,
            previewPaneWidth: root.previewPaneWidth,
            previewStackHeight: root.previewStackHeight,
            navWidth: root.showNav ? root.navWidth : 0,
            statusBarHeight: root.statusBarHeight,
            addressBarHeight: root.addressBarHeight,
            separator: "hairline",
            // The two panes where they are drawn, and which edge the hairline is
            // on: the vertical one (beside) or the horizontal one (underneath).
            list: root.paneRect(filePane, "files"),
            preview: root.paneRect(previewCard, "preview"),
            // The grid both panes live in, so "these two do not overlap" can be
            // checked against the box that holds them.
            grid: root.paneRect(contentGrid, "grid"),
            edgeSideVisible: previewEdgeSide.visible,
            edgeUnderVisible: previewEdgeUnder.visible,
            edgeSideSize: previewEdgeSide.width,
            edgeUnderSize: previewEdgeUnder.height,
            crumbs: root.crumbs.map(t => t.label),
            crumbsShown: pathBox.crumbFit.items.map(t => t.label),
            crumbsHidden: pathBox.crumbFit.hidden,
            editingPath: root.editingPath
        });
    }
    // The details columns as they are DRAWN, which is the only place a dragged
    // width can be seen from the outside: the three chosen widths, and each
    // header cell where it actually sits. A width that was set but never
    // reached the layout would read as a correct number here and nowhere else.
    // The drawn text inside a cell: the cell itself when it IS the text (Date
    // modified, Type and Size are StyledText), otherwise the first child that
    // is text (the Name cell is a row of icon + name).
    function columnTextOf(cell) {
        if (cell.contentWidth !== undefined)
            return cell;
        const kids = cell.children;
        for (let i = 0; i < kids.length; i++)
            if (kids[i].contentWidth !== undefined)
                return kids[i];
        return null;
    }
    // One column strip over one ruler. The widths (Date modified, Type, Size)
    // are ONE set of numbers drawn TWICE -- as the header strip and again in
    // every row -- so "the columns line up" is a claim about two layouts that
    // only a reading of both can settle. Cells AND text: a cell can sit exactly
    // where it should and still draw its text 8 px off, which is precisely the
    // bug this measures.
    function columnsOf(strip, isHeader) {
        const out = [];
        if (!strip) return out;
        for (let i = 0; i < strip.children.length; i++) {
            const cell = strip.children[i];
            const cAt = cell.mapToItem(root, 0, 0);
            const t = root.columnTextOf(cell);
            const tAt = t ? t.mapToItem(root, 0, 0) : null;
            // Where the GLYPHS are, not where the item is. A Text item is often
            // wider than its own content, and Size is exactly that case: the
            // numbers are drawn at the right edge of a 96 px box, so reading
            // them as "x + contentWidth" would report an 8 px overhang as a
            // 70 px miss and send someone hunting a bug that is not there.
            const right = t && t.horizontalAlignment === Text.AlignRight;
            const drawnX = tAt ? Math.round(tAt.x + (right ? t.width - t.contentWidth : 0)) : -1;
            const drawnW = t ? Math.round(t.contentWidth) : 0;
            out.push({
                label: isHeader ? String(cell.label ?? "") : "",
                x: Math.round(cAt.x),
                y: Math.round(cAt.y),
                width: Math.round(cell.width),
                height: Math.round(cell.height),
                textX: drawnX,
                // The right edge is what a right-aligned column has to match:
                // the numbers have to end where the title ends, not start
                // where it starts.
                textRight: tAt ? drawnX + drawnW : -1,
                text: t ? String(t.text) : ""
            });
        }
        return out;
    }
    // What the pointer is ON, as the header itself sees it: for every column,
    // whether its cell contains the pointer, whether that counts as the divider,
    // and the cursor the cell is asking for. "The cursor does not change" is
    // two questions -- is the app asking at all, and is the ask reaching the
    // screen -- and this answers the first one without a pair of eyes on it.
    function probeHeaderHover() {
        const out = [];
        if (typeof headerRow !== "undefined" && headerRow) {
            for (let i = 0; i < headerRow.children.length; i++) {
                const cell = headerRow.children[i];
                const at = cell.mapToItem(root, 0, 0);
                // The cell's own MouseArea: the one child that can ask for a
                // cursor at all.
                let hover = null;
                const kids = cell.children;
                for (let j = 0; j < kids.length; j++) {
                    if (kids[j].cursorShape !== undefined) { hover = kids[j]; break; }
                }
                out.push({
                    label: String(cell.label ?? ""),
                    x: Math.round(at.x),
                    y: Math.round(at.y),
                    height: Math.round(cell.height),
                    width: Math.round(cell.width),
                    resizable: cell.resizable === true,
                    band: cell.grabBand,
                    containsMouse: hover ? hover.containsMouse === true : false,
                    onDivider: hover ? hover.onDivider === true : false,
                    // The value itself, not a guess about it: Qt.SizeHorCursor
                    // is 7, and the flag beside it is the comparison the cell
                    // is actually making.
                    cursor: hover ? hover.cursorShape : -1,
                    sizeHor: hover ? hover.cursorShape === Qt.SizeHorCursor : false
                });
            }
        }
        return JSON.stringify(out);
    }
    // The stack of items under one point, top of the stack LAST, walked with
    // the same childAt() lookup Qt itself uses to route a click and to decide
    // whose cursor is the cursor. "The cursor does not change" is answered here
    // when the item the pointer is really on is not the item that asked.
    //    Written as a walk of the children lists instead of with
    //    QQuickItem.childAt(): that one answers "which item would take the
    //    MOUSE", which is a different question from "which item is drawn here"
    //    -- and what the pointer looks like follows what is DRAWN.
    function topChildAt(item, x, y) {
        const kids = item.children;
        let best = null;
        for (let i = 0; i < kids.length; i++) {
            const kid = kids[i];
            if (!kid.visible || kid.opacity === 0)
                continue;
            const at = kid.mapToItem(item, 0, 0);
            if (x < at.x || y < at.y || x > at.x + kid.width || y > at.y + kid.height)
                continue;
            // A drop destination is not something the pointer can be OVER.
            // A DropArea takes drags and nothing else -- no buttons, no hover
            // -- and Qt's own hit testing walks straight past it to whatever
            // is behind (see the delivery agent's pointerTarget). This walk
            // has to do the same, or every destination reads as a layer
            // standing between a control and the pointer.
            if (String(kid.objectName ?? "").indexOf("drop-") === 0)
                continue;
            // Later children draw on top of earlier ones at the same z.
            if (best === null || kid.z >= best.z)
                best = kid;
        }
        return best;
    }
    // Is `item` at or below `root` in `ancestor`'s branch of the tree?
    function isWithin(item, ancestor) {
        let walk = item;
        for (let guard = 0; walk && guard < 60; guard++) {
            if (walk === ancestor) return true;
            walk = walk.parent;
        }
        return false;
    }
    // EVERY item that asks the pointer to look like something, and whether the
    // pointer would actually be over it -- the ask is resolved from the topmost
    // item at that point, so an ask that is covered is an ask that never
    // happens. `blocked` is the bug this exists to catch: a window-wide layer
    // with no ask of its own standing above the UI left the whole app on the
    // default arrow (the key layer, and a dismisser that was only disabled).
    // Written as a walk over the tree rather than at chosen coordinates, so a
    // NEW layer anywhere shows up here instead of only under one of them.
    function probeCursorAsks() {
        const out = [];
        const visit = (item) => {
            const kids = item.children;
            for (let i = 0; i < kids.length; i++) {
                const kid = kids[i];
                const asks = kid.cursorShape !== undefined ? kid.cursorShape
                    : (kid.cursorIfHovered !== undefined ? kid.cursorIfHovered : null);
                // Only DISTINCTIVE asks are interesting. Every MouseArea has a
                // cursorShape and most leave it at the default arrow, so a
                // covered arrow-asker loses nothing -- there is nothing to
                // report -- and including them buries the ones that matter.
                const distinctive = asks !== null && asks !== Qt.ArrowCursor;
                if (distinctive && kid.visible && kid.width > 1 && kid.height > 1) {
                    let at = null;
                    try {
                        at = kid.mapToItem(root, kid.width / 2, kid.height / 2);
                    } catch (e) {
                        at = null;                 // a popup, in its own window
                    }
                    if (at && at.x >= 0 && at.y >= 0 && at.x <= root.width && at.y <= root.height) {
                        let top = root, px = at.x, py = at.y;
                        for (let guard = 0; guard < 40; guard++) {
                            const kid2 = root.topChildAt(top, px, py);
                            if (!kid2) break;
                            const kAt = kid2.mapToItem(top, 0, 0);
                            px -= kAt.x;
                            py -= kAt.y;
                            top = kid2;
                        }
                        const covered = !root.isWithin(top, kid);
                        const topAsks = top.cursorShape !== undefined ? top.cursorShape
                            : (top.cursorIfHovered !== undefined ? top.cursorIfHovered : null);
                        out.push({
                            who: String(kid).split("(")[0],
                            asks: asks,
                            // The layer that answered instead, and whether it had
                            // an ask of its own (one that does is a layer doing
                            // its own job, not a blocker).
                            top: String(top).split("(")[0],
                            topSize: Math.round(top.width) + "x" + Math.round(top.height),
                            topAsks: topAsks,
                            blocked: covered && topAsks !== asks
                                && (topAsks === null || topAsks === Qt.ArrowCursor)
                        });
                    }
                    visit(kid);
                } else if (kid.visible) {
                    visit(kid);
                }
            }
        };
        visit(root);
        return JSON.stringify(out);
    }
    function probeHit(x, y) {
        const chain = [];
        let item = root, px = x, py = y;
        for (let guard = 0; item && guard < 40; guard++) {
            const at = item.mapToItem(root, 0, 0);
            chain.push({
                type: String(item).split("(")[0],
                at: Math.round(at.x) + "," + Math.round(at.y),
                size: Math.round(item.width) + "x" + Math.round(item.height),
                cursorShape: item.cursorShape !== undefined ? item.cursorShape : null,
                // The ask without the hover, where the item has one (the header
                // cells do: see cursorIfHovered).
                cursorIfHovered: item.cursorIfHovered !== undefined ? item.cursorIfHovered : null,
                hoverEnabled: item.hoverEnabled !== undefined ? item.hoverEnabled : null,
                buttons: item.acceptedButtons !== undefined ? item.acceptedButtons : null,
                visible: item.visible === true,
                z: item.z
            });
            const kid = root.topChildAt(item, px, py);
            if (!kid)
                break;
            const kAt = kid.mapToItem(item, 0, 0);
            px = px - kAt.x;
            py = py - kAt.y;
            item = kid;
        }
        return JSON.stringify(chain);
    }
    // ── probeTextOverlap: text sitting on top of other text ────────────────
    //
    // The one visual complaint QML cannot be asked about directly, and the one
    // the eye catches instantly: two labels sharing pixels. Walks every visible
    // item under root, keeps those that DRAW TEXT (Text, TextInput,
    // MaterialSymbol -- anything with a non-empty `text`), and reports every
    // pair whose rects intersect by more than `tolerance` points on BOTH axes.
    //
    // Ancestor/descendant pairs are skipped: a text inside its own container is
    // what a layout is FOR. A rect is also cut down by every clipping ancestor,
    // and it is measured at the width the text PAINTS (contentWidth when it
    // neither elides nor wraps), so a label that has escaped the box it was
    // given is caught rather than read as "it fits".
    //
    // Each rect comes with the window it is seen through: the item's z, its
    // opacity times every ancestor's, and when it is painted. That is what says
    // which of the two should have won.
    //
    // ── What a label too wide for its box is allowed to do ────────────────
    //
    // It is CUT at the box (CutLabel: full strength, elided, nothing painted
    // past the width it was handed). Two readings say whether that is what
    // happened, and both are expected to be ZERO:
    //
    //   * `overBox` -- a label with more text than its box and no elide, i.e.
    //     painting past the width it was given. That is a wall being crossed:
    //     a tab title through the next tab, a file name under the date column.
    //   * `cutAndDimmed` -- a label being cut at its wall AND dimmed on the way.
    //     That is the retired treatment exactly (LayeredLabel, until
    //     2026-10-16: the whole text kept, 0.3 opacity, painted over the
    //     neighbour) -- greyed out AND through the wall, which were the two
    //     complaints, so both halves are asserted.
    //
    // `cutAtWall` is the treatment ENGAGED: labels being cut. A run that never
    // reports one has not exercised the rule at all, which is the failure a
    // green run hides best, so the suite names the fixture's over-long label
    // and requires that label to be in there.
    //
    // `overlaps` stays as it was: two labels at comparable weight on the same
    // pixels, which is a collision whatever the treatment is.
    //
    // How wide a label's WHOLE text is. This cannot be asked of the label:
    // `contentWidth` on an elided Text reports the width it was CUT to, so a
    // label being cut at its wall would read as one that fits. Same string,
    // same font, asked of the metrics instead.
    TextMetrics { id: labelMetrics }
    function probeTextOverlap(tolerance) {
        const slack = Number(tolerance ?? 1);
        // Below this a label reads as background rather than as a label. It is
        // below the 0.3 the retired treatment dimmed to, with room for a real
        // fade to be told apart from it.
        const BEHIND_AT = 0.55;
        // What a label is actually SEEN at: its own opacity times every
        // ancestor's, because a dimmed label inside a faded pane is dimmer
        // still.
        const seenOpacity = item => {
            let a = 1;
            for (let it = item; it; it = it.parent)
                if (it.opacity !== undefined)
                    a *= it.opacity;
            return a;
        };
        const notes = [];
        let paintOrder = 0;
        // Being cut at its wall: the treatment working. `shows` is how much of
        // the label is left on screen, so a box squeezed to nothing can be told
        // apart from a label that was cut properly.
        const cut = [];
        // ... and the same situation WITHOUT the cut: more text than box, no
        // elide, so the label paints past the width it was given.
        const overBox = [];
        // Labels that PAINT TALLER than the box they were given. The pair scan
        // below only ever intersects rects, and a rect is built from `height`,
        // so a wrapped label whose third line is laid out under its own bottom
        // edge is invisible to it -- while the eye sees that line sitting on
        // whatever is below the box. Reported separately, and expected empty.
        const tall = [];
        // Labels a clipping ancestor cuts while they still had more to say.
        // With every label cut at its own box this should hold no labels: what
        // is left is the deliberate case the path box documents (crumbs too
        // wide for the box are fitted first, then clipped as a second belt).
        const clipped = [];
        const isAncestor = (a, b) => {
            for (let it = b; it; it = it.parent)
                if (it === a)
                    return true;
            return false;
        };
        // What the eye can actually receive from an item: its own rect, cut
        // down by every clipping ancestor. The distinction is the whole point --
        // a label that is inside a box with `clip: true` and hangs past the box's
        // edge is NOT an overlap, it is a label that was cut off at the border,
        // and reporting it as one would send the fix to the wrong place. The
        // path box in the address bar is exactly that case, deliberately.
        // How wide an item actually PAINTS. A Text inside a squeezed layout is
        // handed a width it does not fit into, and without an elide or a wrap it
        // draws the whole string anyway -- past the box it was given. Taking
        // `width` for that would report "no overlap" about a label bleeding into
        // the column beside it, which is the exact complaint this probe exists
        // to answer, so the content width is part of the measurement.
        const paintedW = item => {
            const elides = item.elide !== undefined && item.elide !== Text.ElideNone;
            const wraps = item.wrapMode !== undefined && item.wrapMode !== Text.NoWrap;
            let w = item.width;
            if (item.contentWidth !== undefined && !elides && !wraps)
                w = Math.max(w, item.contentWidth);
            return w;
        };
        // The width the label is HOLDING, elide or not.
        const fullWidth = item => {
            if (item.font !== undefined)
                labelMetrics.font = item.font;
            labelMetrics.text = String(item.text);
            return labelMetrics.advanceWidth;
        };
        const rectOf = item => {
            const at = item.mapToItem(root, 0, 0);
            let x = at.x, y = at.y, w = paintedW(item), h = item.height;
            let cut = false;
            for (let it = item; it; it = it.parent) {
                if (it.clip !== true)
                    continue;
                cut = true;
                const c = it.mapToItem(root, 0, 0);
                const x2 = Math.min(x + w, c.x + it.width);
                const y2 = Math.min(y + h, c.y + it.height);
                x = Math.max(x, c.x);
                y = Math.max(y, c.y);
                w = Math.max(0, x2 - x);
                h = Math.max(0, y2 - y);
            }
            return { x: x, y: y, w: w, h: h, cut: cut };
        };
        const walk = (item, path) => {
            if (!item || item.visible === false)
                return;
            if (item.text !== undefined && String(item.text).length > 0) {
                const at = item.mapToItem(root, 0, 0);
                const seen = rectOf(item);
                if (seen.w > 0 && seen.h > 0)
                    notes.push({
                        item: item,
                        type: String(item).split("(")[0],
                        path: path,
                        text: String(item.text),
                        x: seen.x, y: seen.y, w: seen.w, h: seen.h,
                        raw: [Math.round(at.x), Math.round(at.y), Math.round(paintedW(item)), Math.round(item.height)],
                        cut: seen.cut,
                        // Depth, measured: the opacity it is seen at, its z, and
                        // when it is painted (QML paints siblings in tree
                        // order, so the later one is the one on top).
                        alpha: seenOpacity(item),
                        order: paintOrder++, zValue: item.z
                    });
                if (seen.cut && paintedW(item) > seen.w + 1)
                    clipped.push({
                        text: String(item.text).slice(0, 40),
                        path: path,
                        wants: Math.round(paintedW(item)),
                        shows: Math.round(seen.w)
                    });
                if (item.contentHeight !== undefined && item.contentHeight > item.height + 1)
                    tall.push({
                        text: String(item.text).slice(0, 40),
                        path: path,
                        box: Math.round(item.height),
                        laidOut: Math.round(item.contentHeight),
                        wrapped: item.wrapMode !== undefined && item.wrapMode !== Text.NoWrap,
                        elides: item.elide !== undefined && item.elide !== Text.ElideNone
                    });
                // ── The wall rules for this label ──────────────────────
                // Wrapped text is out of scope: it folds itself inside its box
                // by construction, and the elide on its last line is the cap.
                const elides = item.elide !== undefined && item.elide !== Text.ElideNone;
                const wraps = item.wrapMode !== undefined && item.wrapMode !== Text.NoWrap;
                const held = fullWidth(item);
                if (!wraps && held > item.width + 1) {
                    const entry = {
                        text: String(item.text).slice(0, 48),
                        path: path,
                        wants: Math.round(held),
                        shows: Math.round(Math.max(0, item.width)),
                        opacity: Number(seenOpacity(item).toFixed(2))
                    };
                    if (elides)
                        cut.push(entry);
                    else
                        overBox.push(entry);
                }
            }
            const kids = item.children;
            if (kids)
                for (let i = 0; i < kids.length; i++)
                    walk(kids[i], path + "/" + i);
        };
        walk(root, "");
        const pairs = [];
        const dimmedPairs = [];
        for (let i = 0; i < notes.length; i++) {
            for (let j = i + 1; j < notes.length; j++) {
                const a = notes[i], b = notes[j];
                if (isAncestor(a.item, b.item) || isAncestor(b.item, a.item))
                    continue;
                const ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
                const oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
                if (ox <= slack || oy <= slack)
                    continue;
                // Who is in FRONT: the higher z, and at equal z the one painted
                // later -- which in QML is the one declared later, because
                // siblings paint in tree order.
                const aInFront = a.zValue !== b.zValue ? a.zValue > b.zValue : a.order > b.order;
                const front = aInFront ? a : b;
                const behind = aInFront ? b : a;
                const note = {
                    front: front.text, behind: behind.text,
                    frontType: front.type, behindType: behind.type,
                    overlap: Math.round(ox) + "x" + Math.round(oy),
                    behindRect: [Math.round(behind.x), Math.round(behind.y), Math.round(behind.w), Math.round(behind.h)],
                    frontRect: [Math.round(front.x), Math.round(front.y), Math.round(front.w), Math.round(front.h)],
                    behindRaw: behind.raw, frontRaw: front.raw,
                    behindCut: behind.cut, frontCut: front.cut,
                    frontZ: front.item.z, behindZ: behind.item.z,
                    // Is the one painted behind actually BEHIND to the eye, or
                    // just as strong as the label on top of it?
                    behindOpacity: Number(behind.alpha.toFixed(2)),
                    frontOpacity: Number(front.alpha.toFixed(2))
                };
                if (behind.alpha <= BEHIND_AT)
                    dimmedPairs.push(note);
                else
                    pairs.push(note);
            }
        }
        const cutDim = cut.filter(c => c.opacity <= BEHIND_AT);
        return JSON.stringify({
            view: root.viewMode,
            texts: notes.length,
            // Two labels at comparable weight on the same pixels: a collision.
            overlaps: pairs.length,
            // A pair whose label behind is DIMMED. Not a treatment any more --
            // the two halves of the complaint (greyed out, and over the wall)
            // arrived together, so this is the signature of the old one.
            dimmedPairs: dimmedPairs.length,
            dimmedPairList: dimmedPairs.slice(0, 8),
            // The treatment engaged: labels being cut at their own box.
            cutAtWall: cut.length,
            // Sixteen, not ten: a narrow card cuts every fixed column's label as
            // well, and the fixture's own name has to stay inside the report for
            // the assertion that names it to mean anything.
            cut: cut.slice(0, 16),
            // More text than box with no elide: the label paints past the wall.
            overBox: overBox.length,
            overBoxList: overBox.slice(0, 8),
            // Cut at the wall AND dimmed: the retired treatment, in full.
            cutAndDimmed: cutDim.length,
            cutAndDimmedList: cutDim.slice(0, 8),
            // Labels laid out taller than their own box: text painting below the
            // thing that is supposed to bound it.
            paintsTall: tall.length,
            tall: tall.slice(0, 6),
            // Labels a clipping ancestor cut short (with text left over).
            clipped: clipped.length,
            cutLabels: clipped.slice(0, 8),
            pairs: pairs.slice(0, 8)
        });
    }
    // Put the app in one view for a measurement. A probe setter, like
    // probeResize: the View menu's own action is the same assignment, and
    // driving a popup to choose a view mode would measure the popup.
    //
    // Deliberately the LIVE property and not setViewMode(): a probe is not the
    // person choosing a view, so it must not write a folder's preference.
    function probeViewMode(mode) {
        const want = String(mode ?? "");
        if (want === "tiles" || want === "details")
            root.viewMode = want;
        return root.viewMode;
    }
    // ── Cut and paste, from a terminal ─────────────────────────────────
    // The two operations Ctrl+X and Ctrl+V are bound to. They are driven here
    // for the same reason every other probe exists: a check that has to own the
    // keyboard can only be as reliable as the window's activation, and the cut
    // path is one that copy never exercises (see pasteInto on why the cleanup
    // step and the move have to share one shell line).
    function probeCut(name) {
        if (name !== undefined && name !== null && String(name) !== "")
            root.selectName(String(name));
        root.copySelection(true);
        return String(root.clipboard.length);
    }
    function probePaste(dir) {
        const dest = (dir === undefined || dir === null || String(dir) === "")
            ? root.currentFolderPath() : String(dir);
        root.pasteInto(dest);
        return String(root.clipboard.length);
    }
    // The same reading for one row, by index. The first row of any sorted list
    // is a folder, and a folder has no size -- which is the one column whose
    // answer needs a file to read.
    function probeColumnsAt(index: string) {
        const i = Number(index);
        const row = detailsView.itemAtIndex(i);
        return JSON.stringify({
            row: i,
            cells: row ? root.columnsOf(row.children[0], false) : []
        });
    }
    function probeColumns() {
        const first = detailsView.itemAtIndex(0);
        return JSON.stringify({
            date: root.colDate,
            type: root.colType,
            size: root.colSize,
            min: root.colMinWidth,
            cells: (typeof headerRow !== "undefined" && headerRow)
                ? root.columnsOf(headerRow, true) : [],
            // The first row's own strip, from the same cells the eye reads.
            rowCells: first ? root.columnsOf(first.children[0], false) : []
        });
    }
    // A pane as it is laid out in the window's own coordinates.
    function paneRect(item, role) {
        const at = item.mapToItem(root, 0, 0);
        return {
            role: role,
            visible: item.visible,
            x: Math.round(at.x),
            y: Math.round(at.y),
            width: Math.round(item.width),
            height: Math.round(item.height)
        };
    }
    // The Quick access rows (Home, Desktop, Documents, …) where they are drawn,
    // in the window's own coordinates -- the same answer the drive rows already
    // give, for the rows above them.
    function probeNavQuick() {
        const rows = [];
        for (let i = 0; i < quickRepeater.count; i++) {
            const item = quickRepeater.itemAt(i);
            if (!item) continue;
            const at = item.mapToItem(root, 0, 0);
            rows.push({
                label: item.label,
                path: item.modelData ? item.modelData.path : "",
                x: Math.round(at.x),
                y: Math.round(at.y),
                width: Math.round(item.width),
                height: Math.round(item.height),
                active: item.active === true,
                hovered: item.hovered === true
            });
        }
        return JSON.stringify({ rows: rows, visible: navPane.visible });
    }
    // The navigation pane as drawn: the drive rows the pane is showing, the
    // order they are in, and whether the folded ones are on screen at all.
    function probeNavDrawn() {
        const rows = root.drawnRows(navVolumeRepeater);
        return JSON.stringify({
            rows: rows,
            advancedDrawn: root.drawnRows(navAdvancedRepeater),
            showAdvanced: root.showAdvancedVolumes,
            firstRowY: rows.length > 0 ? rows[0].y : -1,
            // Top to bottom, as drawn: the y of each row, which is the part a
            // model cannot lie about.
            ordered: rows.every((r, i) => i === 0 || rows[i - 1].y <= r.y)
        });
    }
    // A hit test through the SAME lookup Qt uses to route a click: `childAt`
    // returns the topmost child at a point, so this answers "if I clicked here,
    // who would get it?" with no pointer involved. The two answers that matter
    // are the two halves of the path box -- a click on a folder name has to
    // reach the crumb, and a click in the empty part of the box has to reach the
    // box itself (which opens the path for editing). The order those two are
    // declared in is the whole reason it works, and this is what proves it.
    function probeCrumbHit() {
        // The cursor is asked of the item AND its ancestors: the click that
        // navigates is owned by a MouseArea underneath the label that is drawn on
        // top of it, and `childAt` answers with the label. What makes the click a
        // navigation is the pointing hand somewhere up the chain, so that is what
        // this looks for -- otherwise the answer would be "the crumb is not
        // clickable" about a crumb that navigates perfectly well.
        function pointsSomewhere(item) {
            let at = item;
            while (at) {
                if (at.cursorShape === Qt.PointingHandCursor) return true;
                at = at.parent;
            }
            return false;
        }
        // ...and in the item's own subtree, because the topmost item at a
        // crumb's centre is the LABEL drawn over the crumb's MouseArea: the
        // label sits on top, does not accept mouse events, and the click falls
        // straight through to the MouseArea under it. A real pointer has done
        // exactly that (clicking the crumb walked to /home/user), so the
        // question this answers is "is a MouseArea in the way or under it",
        // not "is the topmost child the MouseArea itself".
        function holdsClick(item) {
            if (!item) return false;
            if (item.cursorShape === Qt.PointingHandCursor) return true;
            const kids = item.children ?? [];
            for (let i = 0; i < kids.length; i++) {
                if (holdsClick(kids[i])) return true;
            }
            return false;
        }
        const crumbs = [];
        const items = pathBox.crumbFit.items;
        for (let i = 0; i < items.length; i++) {
            const holder = crumbRepeater.itemAt(i);
            if (!holder) {
                crumbs.push({ label: items[i].label, hit: "none", navigates: false });
                continue;
            }
            const pill = holder.children[0];
            const centre = pill.mapToItem(pathBox, pill.width / 2, pill.height / 2);
            const hit = pathBox.childAt(centre.x, centre.y);
            // The pill's centre in the WINDOW's own coordinates too, so a real
            // click can be aimed at it: the hit test is a prediction, and a
            // pointer is the only thing that settles whether the prediction
            // holds.
            const screen = pill.mapToItem(root, pill.width / 2, pill.height / 2);
            crumbs.push({
                label: items[i].label,
                path: items[i].path,
                hit: hit === pathBoxEmpty ? "box" : (hit === null ? "nothing" : "crumb"),
                navigates: !!hit && hit !== pathBoxEmpty
                    && (pointsSomewhere(hit) || holdsClick(pill)),
                x: Math.round(screen.x),
                y: Math.round(screen.y)
            });
        }
        // And a point in the empty part of the box: just past the last crumb,
        // where there is nothing to navigate to -- which is where the path is
        // supposed to open for editing.
        let emptyX = Math.max(6, pathBox.width - 12);
        const lastItem = crumbRepeater.count > 0 ? crumbRepeater.itemAt(crumbRepeater.count - 1) : null;
        if (lastItem) {
            const edge = lastItem.mapToItem(pathBox, lastItem.width, 0).x;
            emptyX = Math.min(Math.max(edge + 8, 6), Math.max(6, pathBox.width - 12));
        }
        const emptyHit = pathBox.childAt(emptyX, pathBox.height / 2);
        const emptyAt = pathBox.mapToItem(root, emptyX, pathBox.height / 2);
        return JSON.stringify({
            crumbs: crumbs,
            empty: {
                hit: emptyHit === pathBoxEmpty ? "box"
                    : (emptyHit === null ? "nothing" : "other"),
                opensEditor: emptyHit === pathBoxEmpty,
                x: Math.round(emptyAt.x),
                y: Math.round(emptyAt.y)
            },
            shown: items.length,
            hidden: pathBox.crumbFit.hidden
        });
    }
    function probeMenu() {
        return JSON.stringify(root.menuItems.map(i => ({ id: i.id, label: i.label, enabled: i.enabled })));
    }
    // WHERE the menu is drawn, and how tall its rows make it. A menu whose last
    // row sits past the bottom of the card is a row that cannot be clicked, and
    // "the menu's buttons do nothing" is exactly that -- so the position, the
    // row count and the height the rows add up to are all readable here.
    // The tile grid's cell, as the grid decided it: "the tiles use the space
    // they are given" is a number a script can read, not a screenshot.
    function probeTileCell() {
        return JSON.stringify({
            cellW: tilesView.cellWidth, cellH: tilesView.cellHeight,
            cols: tilesView.tileCols, avail: tilesView.tileAvailW,
            // The step the cell was chosen from, so "bigger" is a number a
            // script can ask for rather than a picture it has to believe.
            size: root.tileSize, cap: tilesView.tileMaxCell
        });
    }
    // The tile-size step, settable and readable. A probe setter like
    // probeViewMode: it moves the LIVE step (the same one the buttons move) and
    // reports where it landed, so the suite can press "bigger" twice and read
    // the cell that came out.
    function probeTileSize(step) {
        const n = Number(step);
        if (!isNaN(n))
            root.tileSize = Math.max(0, Math.min(root.tileSizeCaps.length - 1, Math.round(n)));
        return root.tileSize;
    }
    // Which of the bar's view controls are actually ON SCREEN, in the form the
    // app is in. "The dialog has no way to do X" is the complaint this whole
    // change answers, so whether each control is visible (and the file commands
    // are not) is a fact worth being able to assert: a `visible:false` here and
    // a control missing from the card look identical in a screenshot.
    function probeViewControls() {
        return JSON.stringify({
            picker: root.pickerMode,
            bar: commandBar.visible,
            viewMode: root.viewMode,
            view: viewToggleBtn.visible,
            size: sizePlus.visible,
            sizeStep: root.tileSize,
            sizeCap: root.tileCellCap,
            hidden: hiddenBtn.visible,
            hiddenOn: root.showHidden,
            newFile: newCommand.visible,
            tabs: newTabBtn.visible,
            preview: previewPaneBtn.visible
        });
    }
    function probeMenuRect() {
        const h = root.menuHeight(root.menuItems);
        const w = root.menuWidth;
        return JSON.stringify({
            open: root.menuOpen,
            // Where the menu was PUT (the placement decision, clamped into the
            // card by openMenu).
            at: [Math.round(root.menuX), Math.round(root.menuY)],
            size: [w, Math.round(h)],
            rows: root.menuItems.length,
            card: [Math.round(root.width), Math.round(root.height)],
            lastRowBottom: Math.round(root.menuY + h),
            // The last row on the card, and so reachable: one number, and the
            // whole point of moving a menu that would have run off the bottom.
            fits: root.menuY + h <= root.height && root.menuX + w <= root.width,
            // The popup's OWN box, as Qt has it -- the number that decides
            // whether a click lands on a row or falls through to the list
            // behind. It was 12 (two paddings, no rows) while the rows drew
            // 599px; it has to equal rowsHeight for the rows to be clickable.
            box: [Math.round(contextMenu.width), Math.round(contextMenu.height)],
            rowsHeight: Math.round(h)
        });
    }

    // What the app has published for other programs to take: the internal list,
    // who owns the desktop selection and which mime names that owner serves.
    // Read by the check suite, which ALSO reads the live clipboard back with
    // wl-paste -- the difference between "it says it copied" and "another
    // program can paste a FILE".
    function probeClipboard() {
        return JSON.stringify({
            entries: root.clipboard,
            published: root.clipboardPublished,
            type: root.clipboardType,
            helper: root.clipboardHelper,
            pidFile: root.clipboardPidFile,
            uris: root.clipboard.length > 0 ? root.uriListFor(root.clipboard.map(c => c.path)) : ""
        });
    }
    // The payload a drag of this row would carry, for the same reason.
    function probeDragPayload(name) {
        const p = root.currentFolderPath() + "/" + String(name ?? "");
        return root.dragUriListFor(p);
    }

    // ── The card that rides with the pointer ────────────────────────────
    //
    // The drag image is the one part of a drag that no receiving program can
    // report on: a drag whose picture never came back still delivers the file,
    // so a receiver saying "I got it" proves nothing about what the person was
    // carrying. It is also the part that used to be a copy of the row painted
    // into the list, which is why "the card is not in the window" is asserted
    // rather than assumed.
    //
    // probeDragGrab does what a press does -- say what the card is, then
    // photograph it -- without starting a drag, and probeDragCard reads the
    // answer back once the grab has landed. Two calls, because grabToImage is
    // asynchronous: a single probe would have to lie about the picture.
    function probeDragGrab(name, saveTo) {
        const p = root.currentFolderPath() + "/" + String(name ?? "");
        root.dragGhostIcon = root.dragGhostIconFor(p);
        root.dragGhostLabel = root.dragGhostLabelFor(p);
        root.dragGhostGrabbed = false;
        root.dragGhostImage = "";
        root.dragGhostFile = "";
        Qt.callLater(function () {
            dragGhost.grabToImage(function (result) {
                root.noteGrab(result, saveTo);
            });
        });
        return JSON.stringify({ asked: String(name ?? ""), saveTo: String(saveTo ?? "") });
    }
    function probeDragCard(name) {
        const p = root.currentFolderPath() + "/" + String(name ?? "");
        const at = dragGhost.mapToItem(root, 0, 0);
        const w = Math.round(dragGhost.width);
        const h = Math.round(dragGhost.height);
        return JSON.stringify({
            // What it says, decided from the file rather than from the last
            // drag, so a label left over from the drag before this one shows.
            icon: String(root.dragGhostIconFor(p)),
            label: String(root.dragGhostLabelFor(p)),
            // The card as it is DRAWN: a long name must not widen it past its
            // cap (the label elides), and the height is the icon's row.
            size: [w, h],
            // Where it sits in the window. Parked means outside it: a card at
            // 0,0 is a second copy of the row floating over the list.
            at: [Math.round(at.x), Math.round(at.y)],
            parked: at.x + w < 0 || at.y + h < 0 || at.x > root.width || at.y > root.height,
            // The picture, and whether there is one at all. `file` is set only
            // when a check asked for the pixels to be written somewhere; a
            // drag never writes one.
            grabbed: root.dragGhostGrabbed === true,
            image: root.dragGhostImage,
            file: root.dragGhostFile,
            // Whether this file's card is ALREADY in hand, waiting for a press.
            // That is the difference between a drag that carries a picture and
            // one that starts before its picture exists.
            ready: root.cachedCard(p).length > 0,
            cached: Object.keys(root.dragGhostCache ?? ({})).length,
            // Where the hand holds it: the card's top-left, so it hangs off the
            // pointer's tip and travels with it.
            hotSpot: [root.dragGhostHotSpot.x, root.dragGhostHotSpot.y],
            // What the app says the hand is carrying, for the same file: the
            // card and the payload have to be about the same thing.
            payload: root.dragUriListFor(p)
        });
    }
    // What the pointer entering a row does: photographs the card so the press
    // has one to hand over. Reports whether it was already in hand.
    function probeDragWarm(name) {
        const p = root.currentFolderPath() + "/" + String(name ?? "");
        const had = root.cachedCard(p).length > 0;
        root.warmDragCard(p);
        return JSON.stringify({ name: String(name ?? ""), had: had, pending: root.dragGhostGrabPending });
    }
    // The press itself, without a pointer: what beginDrag hands Qt, read back
    // in the same breath. A drag can only carry a card that is non-empty HERE,
    // because Qt takes the image when the drag starts and not afterwards.
    function probeDragBegin(name) {
        const p = root.currentFolderPath() + "/" + String(name ?? "");
        root.beginDrag(p);
        return JSON.stringify({
            name: String(name ?? ""),
            image: root.dragGhostImage,
            immediately: root.dragGhostImage.length > 0,
            label: root.dragGhostLabel
        });
    }

    // ── Drops ───────────────────────────────────────────────────────────
    //
    // A drop is a pointer gesture and this stack is driven without one, so the
    // two halves of it are asked separately.
    //
    // probeDropPlan is the interesting one: it reports what the window WOULD do
    // with a drop, changing nothing. Asserting on that instead of on the
    // filesystem is what lets a check say "a move into the folder you are
    // already in is refused" without building a tree to lose a file in.
    //
    // probeDrop then performs the same decision, so the two cannot disagree: the
    // transfer is the plan applied.
    function probeDropPlan(urls, destDir, move) {
        const wantsMove = move === true || move === "true" || move === "1" || move === "move";
        const dest = root.dropPathKey(destDir);
        const arrived = root.dropPathsOf(urls);
        const work = root.dropWorkList(arrived, dest, wantsMove);
        return JSON.stringify({
            dest: dest,
            action: wantsMove ? "move" : "copy",
            received: arrived,
            work: work,
            refused: arrived.filter(p => work.indexOf(p) === -1),
            command: work.length > 0
                ? work.map(p => root.transferCommand(p, dest, wantsMove)).join("; ")
                : ""
        });
    }
    function probeDrop(urls, destDir, move) {
        const wantsMove = move === true || move === "true" || move === "1" || move === "move";
        const transferred = root.receiveDrop(urls, destDir, wantsMove);
        return JSON.stringify({ transferred: transferred, status: root.statusNote });
    }
    // What the window is saying about a drag in flight: the path a drop would
    // land in right now, and the colours the target wears while it is one. A
    // highlight nobody can read is not feedback.
    function probeDropState() {
        return JSON.stringify({
            target: root.dropTargetPath,
            wash: String(root.dropWashColor),
            rail: String(root.dropRailColor)
        });
    }
    // Every destination, walked off the LIVE item tree rather than counted in
    // the source: a DropArea that was declared and never enabled looks exactly
    // like one that is not there, and only the running tree can tell the two
    // apart. `enabled` is the interesting field -- the pane refuses while at
    // This PC, a row refuses unless it is a folder, "This PC" itself has no
    // path to take anything -- and the geometry is what says the target is on
    // the row it claims to belong to rather than over the whole pane.
    function probeDropAreas() {
        const found = [];
        function walk(item) {
            const kids = item ? item.children : null;
            if (!kids) return;
            for (let i = 0; i < kids.length; i++) {
                const kid = kids[i];
                if (!kid) continue;
                // Named, not class-matched: every destination carries a
                // `drop-…` objectName, which is also the label this reports.
                // Asking the class name would have meant matching on Qt's
                // internal spelling of DropArea, which is not a contract.
                const tag = String(kid.objectName ?? "");
                if (tag.indexOf("drop-") === 0) {
                    let x = 0, y = 0;
                    try {
                        const p = kid.mapToItem(root, 0, 0);
                        x = Math.round(p.x); y = Math.round(p.y);
                    } catch (e) { /* not on screen; geometry is not the point here */ }
                    found.push({
                        name: tag,
                        enabled: kid.enabled === true,
                        x: x, y: y,
                        width: Math.round(kid.width), height: Math.round(kid.height),
                        holding: kid.containsDrag === true
                    });
                    continue;
                }
                walk(kid);
            }
        }
        walk(root);
        return JSON.stringify({ count: found.length, enabled: found.filter(a => a.enabled).length, areas: found });
    }

    // ── Bring-up ────────────────────────────────────────────────────────
    // The states file can finish loading after this component does, so the
    // startup folder's own view is applied once more when it arrives --
    // otherwise the folder would open in details on a cold start and in its
    // saved view on a warm one, depending on who won the race.
    Connections {
        target: Persistent
        function onReadyChanged() {
            if (Persistent.ready)
                root.viewMode = root.savedViewFor(root.path);
        }
    }
    Component.onCompleted: {
        root.loadMountNames();
        root.loadColumnWidths();
        root.history = [root.currentFolderPath()];
        root.historyIndex = 0;
        // The folder this app was started in may have a view of its own.
        root.viewMode = root.savedViewFor(root.path);
        root.tabs = [root.tabSnapshot()];
        root.activeTab = 0;
        root.refreshVolumes();
        udisksProbe.running = true;
        mtpMounterProbe.running = true;
        // ── The file a launcher was handed, if it was handed one ─────────
        // "Show in file manager" hands over a FILE, and the app is STARTED
        // with it whenever no copy is up yet -- the common case, since the
        // manager lets itself go five minutes after it is hidden. The launcher
        // has already split that into the folder (II_FILES_START, the `path`
        // default above) and the name (II_FILES_SELECT, here): a file URL is
        // not a folder, and taken verbatim it listed nothing at all.
        //
        // The row is selected with the same machinery an in-flight create uses
        // (pendingSelectTimer), so the reveal waits for the listing the way
        // everything else here does instead of racing it. This is the startup
        // half of the open-path branch further down, which answers the same
        // request when the app is already running (SUPER+E, the desktop entry,
        // the FileManager1 service raising this copy).
        const startSelect = Quickshell.env("II_FILES_SELECT") ?? "";
        if (startSelect.length > 0) {
            root.pendingSelectName = startSelect;
            pendingSelectTimer.attempts = 0;
            pendingSelectTimer.restart();
        }
    }

    // ── Hotplug: at once, and free when nothing is happening ────────────
    //
    // WHERE THE TEN SECONDS WENT. The list was kept up to date by a poll, so a
    // stick that was pushed in appeared somewhere in the next ten seconds --
    // routinely a good while after your hand had left it, which does not read as
    // "it noticed late" but as "it did not notice". A stick going in is a kernel
    // event and the kernel announces it on a socket: `udevadm monitor` IS that
    // announcement, one line per event, read here as a stream. It costs nothing
    // while nothing happens -- it is a blocking read on a netlink socket, not a
    // process that wakes up -- and it answers in about a tenth of a second.
    //
    // Both subsystems, because both are pluggable: `block` is the stick and the
    // card, `usb` is the phone (which is never a block device at all -- see the
    // MTP section).
    //
    // The poll stays, at a slower beat, as the safety net: a device that was
    // already plugged in when this process started, or a missed event, still
    // shows up, just later.
    // Counted, and reported through probeState, because "it is instant" is not
    // something a terminal can watch happen: the count is the proof that the
    // socket is being READ (events are arriving and being acted on) rather than
    // a watcher that looks alive and forwards nothing.
    property int hotplugEvents: 0
    property int hotplugRefreshes: 0
    Process {
        id: hotplugWatch
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=block", "--subsystem-match=usb"]
        running: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                const event = String(line ?? "");
                // add/remove for the two that matter, and change because a card
                // whose partition table the kernel has just read is announced
                // that way -- which is exactly the SD card that "does not
                // appear".
                if (event.indexOf(" add ") === -1 && event.indexOf(" remove ") === -1
                        && event.indexOf(" change ") === -1)
                    return;
                root.hotplugEvents++;
                hotplugDebounce.restart();
            }
        }
        // The watcher must never be allowed to stay dead on its own: the poll
        // would keep the list honest, but this is the difference between a tenth
        // of a second and fifteen.
        onExited: hotplugRestart.running = true
    }
    Timer {
        // One insertion arrives as several lines (the disk, each partition, the
        // by-id links); one refresh answers all of them.
        id: hotplugDebounce
        interval: 140
        onTriggered: { root.hotplugRefreshes++; root.refreshVolumes(); }
    }
    Timer {
        id: hotplugRestart
        interval: 3000
        onTriggered: hotplugWatch.running = true
    }
    Timer {
        // The safety net, now that udev does the noticing: fifteen seconds
        // instead of ten, because its job is no longer speed.
        interval: 15000
        repeat: true
        running: true
        onTriggered: root.refreshVolumes()
    }
    property bool mtpMounter: false
    Process {
        id: mtpMounterProbe
        command: ["bash", "-c", "command -v aft-mtp-mount >/dev/null 2>&1 && echo yes || echo no"]
        stdout: StdioCollector {
            onStreamFinished: root.mtpMounter = String(this.text ?? "").trim() === "yes"
        }
    }
    Connections {
        target: folderModel
        // Any change to the folder, its contents or its hidden-file filter
        // re-reads the rows (debounced), which is also where a selection that
        // no longer exists gets pruned.
        function onCountChanged() { rowsDebounce.restart(); }
        function onFolderChanged() { rowsDebounce.restart(); }
    }
}
