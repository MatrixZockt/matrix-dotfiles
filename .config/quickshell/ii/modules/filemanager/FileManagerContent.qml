// FileManagerContent -- the manager itself, rebuilt to be read at a glance
// rather than read line by line.
//
//   ┌ places ─┬── breadcrumbs + filter ───────────────┬ preview ┐
//   │ Home    │  [ thumbnails, or name+size rows ]    │ big art │
//   │ Docs    │                                        │ details │
//   │ ...     │                                        │ actions │
//   └─────────┴── key hints / selection ───────────────┴─────────┘
//
// Why: a list of filenames tells you nothing about which picture is which, and
// this desktop is driven from a touchpad, not a mouse -- so the whole app has to
// be reachable without hunting for a small target. Hence three panes (see at a
// glance), a preview pane (what IS this file), and a key layer plus a visible
// hint strip (do it without moving the pointer).
//
// The same component serves three callers, so the layout adapts:
//   * the Files popup            (1020x680) -> rail + grid + preview
//   * the morphed window         (fullscreen) -> rail + grid + preview
//   * the portal FileChooser     (680x540)  -> single pane + action bar
//
// Mutations go through gio (`gio trash`, `gio open`, `gio move`, `gio mkdir`),
// so nothing is ever rm'd and files open with the right application.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import qs.modules.common.models

Item {
    id: root

    signal quitRequested()

    // ── Picker mode (portal FileChooser dialogs) ─────────────────────────
    // The same manager as a dialog: navigation, hidden files and typing a
    // name all stay; the choice goes back through pickerAccepted /
    // pickerCancelled and the caller (ii-portal) closes the loop.
    property bool pickerMode: false
    property string pickerOp: "open"      // "open" (pick file/folder) | "save"
    property string pickerName: ""        // pre-filled filename for save
    property bool pickerDirectory: false  // choosing a folder, not a file
    signal pickerAccepted(var uris)
    signal pickerCancelled()

    // ── State ────────────────────────────────────────────────────────────
    readonly property string homeDir: Quickshell.env("HOME") ?? "/"
    readonly property string startFolder: {
        const env = Quickshell.env("II_FILES_START") ?? "";
        return env.length > 0 ? env : homeDir;
    }
    property bool showHidden: false
    property string viewMode: "grid"      // "grid" (thumbnails) | "list" (rows)

    // ── Tabs ─────────────────────────────────────────────────────────────
    // Each tab is a PLACE, and it keeps its own back/forward history: the
    // live model state is snapshotted into the outgoing tab and restored into
    // the incoming one, so two tabs never share a trail. A tab is
    //   { path: <fold path>, history: <list<url>>, index: <history index> }
    property var tabs: []
    property int activeTab: 0
    readonly property bool tabsAvailable: !root.pickerMode
    property bool showPreview: true
    property string filter: ""
    property int selIndex: -1

    // Layout adapts to the surface we were given, not to a mode flag.
    readonly property bool showRail: !root.pickerMode && root.width >= 820
    readonly property bool showPreviewPane: !root.pickerMode && root.showPreview && root.width >= 960
    // Sized so the middle pane still gets four 150px columns in the popup card
    // (1020 wide) and six in the morphed full-screen window -- the layout the
    // design proposal showed.
    readonly property int railWidth: 152
    readonly property int previewWidth: 244

    // ── Local button (BarContent's HoverIconButton is file-local there) ───
    component ToolButton: Rectangle {
        id: tb
        property alias symbol: tbIcon
        property string tooltipText: ""
        property bool hovered: false
        property bool active: false
        signal activated()
        implicitWidth: 32
        implicitHeight: 32
        radius: Appearance.rounding.full
        color: tb.active
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)
            : tb.hovered ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.84) : "transparent"
        opacity: enabled ? 1 : 0.35
        HoverHandler {
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: tb.hovered = hovered
        }
        TapHandler {
            onTapped: tb.activated()
        }
        MaterialSymbol {
            id: tbIcon
            anchors.centerIn: parent
            iconSize: 18
            color: tb.active ? Appearance.colors.colPrimary
                : tb.hovered ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
        }
    }

    // ── Folder model ─────────────────────────────────────────────────────
    // FolderListModel wants a URL, not a path. A bare path IS accepted but the
    // hidden-file filter is skipped for it (it only applies to local URLs), so
    // the popup listed every dotfile in home whatever showHidden said.
    function asUrl(p) {
        p = String(p ?? "");
        if (p.length === 0) return "file://" + root.homeDir;
        return p.startsWith("file:") ? p : "file://" + p;
    }
    function navigateTo(p) {
        // The sentinel is not a folder. Anything that lands here is a real
        // path, which means leaving the virtual This PC view behind.
        if (p === root.thisPcSentinel) {
            root.showThisPC();
            return;
        }
        root.thisPCMode = false;
        // A category belongs to the folder it was picked in. Carrying it into
        // the next folder is how a file manager convinces you a folder is
        // empty when it simply holds other kinds of thing.
        root.category = "";
        root.selIndex = -1;
        folderModel.folder = root.asUrl(p);
    }
    function currentFolderPath() {
        return String(folderModel.folder).replace(/^file:\/\//, "").replace(/\/+$/, "");
    }
    function tabSnapshot() {
        return {
            path: root.currentFolderPath(),
            history: folderModel.folderHistory.slice(),
            index: folderModel.currentFolderHistoryIndex
        };
    }
    function tabsInit() {
        if (root.tabs.length > 0)
            return;
        root.tabs = [root.tabSnapshot()];
        root.activeTab = 0;
    }
    function tabSaveActive() {
        if (root.tabs.length === 0)
            return;
        const next = root.tabs.slice();
        next[root.activeTab] = root.tabSnapshot();
        root.tabs = next;
    }
    function tabLabel(t) {
        const path = (t && t.path) ? t.path : root.homeDir;
        return root.shortName(path);
    }
    function newTab(path) {
        root.tabsInit();
        root.tabSaveActive();
        const target = path ?? root.currentFolderPath() ?? root.homeDir;
        const next = root.tabs.slice();
        // A fresh tab starts with a fresh trail (its own history).
        next.push({ path: target, history: [root.asUrl(target)], index: 0 });
        root.tabs = next;
        root.activeTab = next.length - 1;
        root.applyTab();
    }
    function closeTab(i) {
        root.tabsInit();
        const which = (i === undefined || i < 0) ? root.activeTab : i;
        // The last tab closes the surface, the way a browser's last tab does.
        if (root.tabs.length <= 1) {
            if (root.pickerMode)
                root.pickerCancelled();
            else
                root.quitRequested();
            return;
        }
        root.tabSaveActive();
        const next = root.tabs.slice();
        next.splice(which, 1);
        root.tabs = next;
        root.activeTab = Math.max(0, Math.min(which <= root.activeTab ? root.activeTab - 1 : root.activeTab,
            next.length - 1));
        root.applyTab();
    }
    function selectTab(i) {
        root.tabsInit();
        if (i === root.activeTab || i < 0 || i >= root.tabs.length)
            return;
        root.tabSaveActive();
        root.activeTab = i;
        root.applyTab();
    }
    function cycleTab(step) {
        root.tabsInit();
        const n = root.tabs.length;
        if (n <= 1)
            return;
        root.selectTab(((root.activeTab + step) % n + n) % n);
    }
    function applyTab() {
        const t = root.tabs[root.activeTab];
        if (!t)
            return;
        root.selIndex = -1;
        // Restore without teaching the history a new entry.
        folderModel.lockNextNavigation();
        folderModel.folder = root.asUrl(t.path);
        if (Array.isArray(t.history) && t.history.length > 0) {
            folderModel.folderHistory = t.history.slice();
            folderModel.currentFolderHistoryIndex = Math.max(0, Math.min(t.index ?? 0, t.history.length - 1));
        } else {
            folderModel.folderHistory = [root.asUrl(t.path)];
            folderModel.currentFolderHistoryIndex = 0;
        }
    }

    function shortName(p) {
        p = String(p ?? "");
        if (!p || p === "/" || p.endsWith("file:///")) return "/";
        const parts = p.replace(/^file:\/\//, "").split("/").filter(s => s.length > 0);
        return parts.length ? parts[parts.length - 1] : "/";
    }

    // Navigation inside the active tab renames its chip. The other tabs keep
    // their saved snapshots untouched.
    Connections {
        target: folderModel
        function onFolderChanged() {
            if (root.tabs.length === 0)
                return;
            const next = root.tabs.slice();
            const t = next[root.activeTab];
            if (!t)
                return;
            next[root.activeTab] = Object.assign({}, t, { path: root.currentFolderPath() });
            root.tabs = next;
        }
    }

    // One handler only: QML allows a single Component.onCompleted per object,
    // and the free-space probe below also needs to start at load.
    Component.onCompleted: {
        root.tabsInit();
        dfProc.running = true;
    }

    FolderListModelWithHistory {
        id: folderModel
        folder: root.asUrl(root.startFolder)
        showFiles: true
        showDirsFirst: true
        showHidden: root.showHidden
        // Sorting is part of the view, so it lives on the model. Name is the
        // default the app shipped with.
        sortField: root.sortMode === 1 ? FolderListModel.Time
            : (root.sortMode === 2 ? FolderListModel.Size : FolderListModel.Name)
        sortReversed: root.sortReversed
        // ONE property does all the filtering here, because
        // FolderListModelWithHistory has no `filter` of its own and its
        // `nameFilters` ORs the list together. So "Images" + "logo" is built
        // by CROSSING the typed pattern with each extension --
        // ["*logo*.png", "*logo*.jpg", ...] -- rather than by handing over
        // two filters. The union of that list is exactly the intersection we
        // want, which is the one thing an OR cannot express on its own.
        nameFilters: root.nameFilterGlobs
        // NOTE: deliberately no onFolderChanged here. Declaring one *replaces*
        // the handler FolderListModelWithHistory defines for itself, so history
        // was never recorded and Back/Forward stayed dead. The path field syncs
        // through a Connections, which adds to it instead of shadowing it.
    }

    // Breadcrumb segments. Reading `folderModel.folder` inside the binding is
    // what makes this re-evaluate on navigation -- a plain function call from
    // the Repeater would be evaluated once and never again.
    readonly property var crumbSegments: {
        // This PC is not a path, so there is no chain to build for it. It
        // gets its own crumb, and that crumb is how you get out of it.
        if (root.thisPCMode)
            return [{ label: Translation.tr("This PC"), path: root.thisPcSentinel }];
        const raw = String(folderModel.folder ?? "");
        const path = raw.replace(/^file:\/\//, "").replace(/\/+$/, "");
        const parts = path.split("/").filter(s => s.length > 0);
        const out = [{ label: "/", path: "/" }];
        let acc = "";
        for (const part of parts) {
            acc += "/" + part;
            out.push({ label: part, path: acc });
        }
        return out;
    }

    // Free space at a glance, so "why can't I copy this" is answered in place.
    property string storageText: ""
    Process {
        id: dfProc
        command: ["bash", "-c", "df -h --output=size,used,avail / | tail -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = String(this.text ?? "").trim().split(/\s+/);
                if (p.length >= 3) root.storageText = p[1] + " / " + p[0] + " " + Translation.tr("used");
            }
        }
    }

    // ── Formatting helpers ───────────────────────────────────────────────
    readonly property var imageExtensions: ["png", "jpg", "jpeg", "webp", "gif", "bmp", "avif", "svg", "tif", "tiff", "heic"]
    readonly property var videoExtensions: ["mp4", "mkv", "webm", "mov", "avi", "m4v"]
    readonly property var audioExtensions: ["mp3", "flac", "wav", "ogg", "opus", "m4a"]
    readonly property var docExtensions: ["pdf", "txt", "md", "doc", "docx", "odt", "xls", "xlsx", "ods", "ppt", "pptx", "epub"]

    function suffixOf(name) {
        const n = String(name ?? "");
        const i = n.lastIndexOf(".");
        return i > 0 ? n.substring(i + 1).toLowerCase() : "";
    }
    function hasExt(name, list) { return list.indexOf(root.suffixOf(name)) !== -1; }
    function isImage(name) { return root.hasExt(name, root.imageExtensions); }
    function isVideo(name) { return root.hasExt(name, root.videoExtensions); }

    function iconFor(name, isDir) {
        if (isDir) return "folder";
        const s = root.suffixOf(name);
        if (root.imageExtensions.indexOf(s) !== -1) return "image";
        if (root.videoExtensions.indexOf(s) !== -1) return "movie";
        if (root.audioExtensions.indexOf(s) !== -1) return "music_note";
        if (s === "pdf") return "picture_as_pdf";
        if (["zip", "tar", "gz", "xz", "zst", "7z", "rar"].indexOf(s) !== -1) return "folder_zip";
        if (["sh", "py", "js", "qml", "lua", "c", "cpp", "rs", "go", "ts", "json", "yml", "yaml", "toml"].indexOf(s) !== -1) return "code";
        if (["md", "txt", "doc", "docx", "odt", "rtf"].indexOf(s) !== -1) return "description";
        return "draft";
    }
    function kindFor(name, isDir) {
        if (isDir) return Translation.tr("Folder");
        const s = root.suffixOf(name);
        if (root.imageExtensions.indexOf(s) !== -1) return Translation.tr("Image");
        if (root.videoExtensions.indexOf(s) !== -1) return Translation.tr("Video");
        if (root.audioExtensions.indexOf(s) !== -1) return Translation.tr("Audio");
        if (s === "pdf") return Translation.tr("PDF document");
        if (root.docExtensions.indexOf(s) !== -1) return Translation.tr("Document");
        if (s.length === 0) return Translation.tr("File");
        return s.toUpperCase() + " " + Translation.tr("file");
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
    function fmtTime(ms) {
        const t = Number(ms ?? 0);
        if (!isFinite(t) || t <= 0) return "";
        const d = new Date(t);
        const p = n => (n < 10 ? "0" : "") + n;
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
    }

    // ── Selection ────────────────────────────────────────────────────────
    function role(index, name) {
        if (index < 0 || index >= folderModel.count) return "";
        return folderModel.get(index, name);
    }
    function selectedName() { return root.role(root.selIndex, "fileName"); }
    function selectedPath() { return root.role(root.selIndex, "filePath"); }
    function selectedIsDir() { return root.role(root.selIndex, "fileIsDir"); }
    function selectedSize() { return root.role(root.selIndex, "fileSize"); }
    function selectedModified() { return root.role(root.selIndex, "fileModified"); }

    function selectIndex(i) {
        if (i < 0 || i >= folderModel.count) return;
        root.selIndex = i;
        gridView.currentIndex = i;
        listView.currentIndex = i;
        // Keep the selection on screen without stealing the pointer.
        if (root.viewMode === "grid") gridView.positionViewAtIndex(i, GridView.Contain);
        else listView.positionViewAtIndex(i, ListView.Contain);
    }
    function stepSelection(d) {
        const next = root.selIndex < 0 ? (d > 0 ? 0 : folderModel.count - 1) : root.selIndex + d;
        root.selectIndex(Math.max(0, Math.min(folderModel.count - 1, next)));
    }
    function stepVertical(d) {
        // In the grid a "row" is gridView.columns wide; in the list it is one row.
        const step = root.viewMode === "grid" ? Math.max(1, gridView.columns) * d : d;
        root.stepSelection(step);
    }
    function activate(index) {
        if (index < 0 || index >= folderModel.count) return;
        const isDir = folderModel.get(index, "fileIsDir");
        const path = folderModel.get(index, "filePath");
        if (root.pickerMode && !isDir) {
            if (root.pickerOp === "save") {
                pickerNameField.text = folderModel.get(index, "fileName");
                pickerNameField.forceActiveFocus();
            } else if (!root.pickerDirectory) {
                root.pickerAccepted([root.fileUri(path)]);
            }
            return;
        }
        root.openEntry(path, isDir);
    }
    function openSelected() { root.activate(root.selIndex); }

    function goUp() {
        // Nothing above This PC, exactly as in Explorer. Silently doing
        // nothing beats a dead control that still looks live.
        if (root.thisPCMode) return;
        const p = folderModel.parentFolder;
        if (p !== "") root.navigateTo(String(p));
    }
    function goBack() {
        // Leaving the virtual view is a back step the folder history knows
        // nothing about, so it is handled here rather than swallowed.
        if (root.thisPCMode) { root.thisPCMode = false; return; }
        if (folderModel.currentFolderHistoryIndex > 0) folderModel.navigateBack();
    }
    function goForward() {
        if (folderModel.currentFolderHistoryIndex < folderModel.folderHistory.length - 1) folderModel.navigateForward();
    }
    function refresh() {
        // FolderListModel has no refresh(); re-assigning the folder is the
        // supported way to re-stat the directory.
        const cur = String(folderModel.folder);
        folderModel.folder = "";
        folderModel.folder = cur;
    }

    // ── gio wrappers (trash instead of rm; open with the default app) ─────
    Process {
        id: gioProc
        property string mode: ""
        command: []
    }
    function gio(args, mode) {
        gioProc.mode = mode ?? "";
        gioProc.command = ["gio"].concat(args);
        gioProc.running = false;
        gioProc.running = true;
    }
    function openEntry(path, isDir) {
        if (path === "" || path === null || path === undefined) return;
        if (isDir) { root.navigateTo(path); return; }
        // An AppImage gets INSTALLED, not run-in-place (desktop policy since
        // 2026-09-26): double-clicking one moves it to ~/Applications, wires
        // its icon and launcher into the app menu, and cleans the extraction
        // leftovers. Running straight from ~/Downloads is exactly how stray
        // unlaunched apps happen. The helper is idempotent and safe to
        // re-trigger; a notification says what was installed.
        const p = String(path);
        if (/\.appimage$/i.test(p)) {
            root.sh("$HOME/.local/bin/install-appimage " + root.shq(p)
                + " && notify-send -a 'Files' -i application-x-executable"
                + " 'AppImage installed' \"$(basename -- " + root.shq(p) + ") — added to the app menu\""
                + " || notify-send -a 'Files' 'AppImage install failed' \"see journalctl --user -xe\" -u critical");
            return;
        }
        gio(["open", path], "open");
    }
    function trashSelected() {
        const p = root.selectedPath();
        if (!p) return;
        gio(["trash", p], "trash");
        root.selIndex = -1;
    }
    function renameSelected(name) {
        const p = root.selectedPath();
        if (!p || !name || name === root.shortName(p)) return;
        const dir = p.substring(0, p.lastIndexOf("/")) || "/";
        gio(["move", p, dir + "/" + name], "rename");
    }
    function newFolder() {
        const dir = root.currentFolderPath();
        const base = Translation.tr("New folder");
        let candidate = dir + "/" + base;
        let n = 2;
        while (true) {
            let exists = false;
            for (let i = 0; i < folderModel.count; i++) {
                if (folderModel.get(i, "fileName") === root.shortName(candidate)) { exists = true; break; }
            }
            if (!exists) break;
            candidate = dir + "/" + base + " " + (n++);
        }
        gio(["mkdir", candidate], "mkdir");
    }

    // Does `path` already exist in the folder we are looking at? Used to walk
    // "New folder", "New folder 2", ... instead of colliding with the first
    // free name the desktop's own file manager would pick.
    function nameExistsIn(path) {
        const want = root.shortName(path);
        for (let i = 0; i < folderModel.count; i++)
            if (folderModel.get(i, "fileName") === want) return true;
        return false;
    }

    // ── Generic shell escape hatch ────────────────────────────────────────
    // gio covers trash / open / move / mkdir but has no "make an empty file"
    // and no clipboard, so the few operations it cannot express run through sh.
    // Everything that reaches sh goes through shq() first -- a filename with a
    // quote or a space must not become a second command.
    Process {
        id: shProc
        command: []
        // A mutation changes the listing; re-stat the directory when it is
        // done so the new item is there immediately (the model's watcher is
        // good but not instant).
        onExited: root.refresh()
    }
    function shq(s) { return "'" + String(s ?? "").replace(/'/g, "'\\''") + "'"; }
    function sh(cmd) {
        shProc.command = ["sh", "-c", cmd];
        shProc.running = false;
        shProc.running = true;
    }

    function newFile() {
        const dir = root.currentFolderPath();
        const base = Translation.tr("New file");
        let candidate = dir + "/" + base;
        let n = 2;
        while (root.nameExistsIn(candidate)) candidate = dir + "/" + base + " " + (n++);
        root.sh("touch -- " + root.shq(candidate));
    }
    function newFileAt(parentDir, name) {
        const candidate = parentDir + "/" + name;
        root.sh("touch -- " + root.shq(candidate));
    }
    function openInTerminal(path) {
        const dir = (path && path.length > 0) ? path : root.currentFolderPath();
        Quickshell.execDetached(["kitty", "--directory", dir]);
    }
    function copyPath(path) {
        const p = (path && path.length > 0) ? path : root.currentFolderPath();
        root.sh("printf %s " + root.shq(p) + " | wl-copy");
    }

    // ── Windows SSD ──────────────────────────────────────────────────────
    // The one thing the manager cannot do for itself: mounting needs root.
    // It goes through pkexec, so polkit shows a dialog on screen and the user
    // approves it -- without a registered auth agent pkexec instead falls back
    // to a textual agent, finds no controlling terminal and fails outright,
    // which is why this could not be wired up before.
    //
    // Deliberately not an fstab entry: that would mount it at every boot with
    // no way to ask, and Windows keeps the volume dirty anyway.
    readonly property string ssdDevice: "/dev/nvme1n1p3"
    readonly property string ssdMount: "/mnt/winssd"
    property bool ssdMounted: false
    // Set by the toggle so the state check knows to walk in once it lands.
    property bool ssdOpenAfter: false

    Process {
        id: ssdState
        command: ["sh", "-c", "mountpoint -q " + root.ssdMount]
        onExited: (exitCode) => {
            root.ssdMounted = (exitCode === 0);
            if (root.ssdMounted && root.ssdOpenAfter) {
                root.ssdOpenAfter = false;
                root.navigateTo(root.ssdMount);
            }
        }
    }
    function refreshSsdState() {
        ssdState.running = false;
        ssdState.running = true;
    }

    Process {
        id: ssdToggle
        command: ["sh", "-c", "true"]
        onExited: root.refreshSsdState()
    }

    // One command for both directions, so the button cannot end up out of step
    // with reality the way two separate branches would. Feedback rides along
    // in the shell (notify-send) for the same reason the AppImage install
    // above does it: the user gets told either way, and the QML side only has
    // to re-read the mount state.
    function toggleSsd() {
        const dev = shq(ssdDevice);
        const mnt = shq(ssdMount);
        ssdToggle.command = ["sh", "-c",
            "if mountpoint -q " + mnt + "; then"
            + " pkexec umount " + mnt
            + "   && notify-send -a 'Files' 'Windows SSD unmounted'"
            + "   || notify-send -a 'Files' 'Unmount failed' 'something still has it open' -u critical;"
            + " else"
            + " pkexec mount -t ntfs3 -o uid=1000,gid=1000,noatime " + dev + " " + mnt
            + "   && notify-send -a 'Files' 'Windows SSD mounted'"
            + "   || notify-send -a 'Files' 'Mount failed' 'was the polkit request declined?' -u critical;"
            + " fi"];
        ssdToggle.running = false;
        ssdToggle.running = true;
    }

    // Prime the button's state when the manager is built. A one-shot timer
    // rather than Component.onCompleted: this object already owns that
    // handler further up, and QML keeps only the first one registered.
    Timer {
        interval: 120
        running: true
        onTriggered: root.refreshSsdState()
    }

    // ── Navigation model ─────────────────────────────────────────────────
    // Explorer's shape, which is the one people already have the muscle
    // memory for: QUICK ACCESS (where you live), THIS PC (the whole machine),
    // DEVICES (what you plug in) and CATEGORIES (this folder, by kind).
    //
    // It is DATA, not four hand-built blocks of QML: `allPlaces` carries a
    // `section` tag and the rail renders whatever the section list says. One
    // place to add a row, one place to reorder, and the pin/hide machinery
    // below keeps working because it never learned what a "place" looked
    // like -- it only ever knew about paths.
    //
    // thisPcSentinel is a sentinel, not a path: nothing on disk is called that, and
    // it must never reach FolderListModel as a folder.
    readonly property string thisPcSentinel: "thispc:"
    property bool thisPCMode: false

    readonly property var allPlaces: [
        // ── Quick access ──
        { label: "Home", icon: "home", path: homeDir, section: "quick" },
        { label: "Desktop", icon: "desktop_windows", path: homeDir + "/Desktop", section: "quick" },
        { label: "Documents", icon: "description", path: homeDir + "/Documents", section: "quick" },
        { label: "Downloads", icon: "download", path: homeDir + "/Downloads", section: "quick" },
        { label: "Pictures", icon: "image", path: homeDir + "/Pictures", section: "quick" },
        { label: "Music", icon: "music_note", path: homeDir + "/Music", section: "quick" },
        { label: "Videos", icon: "movie", path: homeDir + "/Videos", section: "quick" },
        // ── This PC ──
        { label: "This PC", icon: "computer", path: thisPcSentinel, section: "pc" },
        { label: "Wallpapers", icon: "wallpaper", path: homeDir + "/Pictures/Wallpapers", section: "pc" },
        { label: "Filesystem", icon: "sd_storage", path: "/", section: "pc" },
        // ── Devices ──
        // The Windows SSD is the reason this section exists. `mountpoint` is
        // what the rail and the drive tiles both ask, so a drive can never
        // claim to be connected when it is not.
        { label: "Windows (SSD-475GB)", icon: "harddisk", path: "/mnt/winssd",
          section: "devices", drive: true, mountpoint: "/mnt/winssd",
          detail: "NVMe · NTFS" }
    ]

    // Section order and headings. A section with no visible rows is dropped
    // by the projection below rather than drawn as an empty heading.
    readonly property var navSections: [
        { id: "quick", title: Translation.tr("Quick access"), icon: "home" },
        { id: "pc", title: Translation.tr("This PC"), icon: "computer" },
        { id: "devices", title: Translation.tr("Devices"), icon: "usb" }
    ]

    // Hidden places are removed from VIEW, never from the master list, so a
    // row can always come back. Pinned rows float to the top of their own
    // section rather than to the top of the rail: a pinned Download belongs
    // among the places you go, not above the machine it lives on.
    readonly property var navSectionsVisible: root.navSections
        .map(section => {
            const live = root.allPlaces.filter(
                p => p.section === section.id && !root.hiddenPlaces.includes(p.path));
            const isPinned = p => root.pinnedPlaces.includes(p.path);
            const rows = live.filter(isPinned).concat(live.filter(p => !isPinned(p)));
            return { id: section.id, title: section.title, icon: section.icon, rows: rows };
        })
        .filter(section => section.rows.length > 0)

    // ── Drives ───────────────────────────────────────────────────────────
    // What "This PC" shows. Fixed disks and removable ones in one list, the
    // way Explorer does it, because the question the pane answers is "what
    // can I open" and not "what kind of thing is it".
    readonly property var drives: [
        { id: "ssd", label: "Windows (SSD-475GB)", sub: "NVMe · NTFS",
          icon: "harddisk", path: "/mnt/winssd", device: "/dev/nvme1n1p3",
          mountpoint: "/mnt/winssd", removable: true },
        { id: "root", label: "Filesystem", sub: "Linux · Btrfs",
          icon: "sd_storage", path: "/", mountpoint: "/", removable: false },
        { id: "home", label: "Home", sub: "Btrfs",
          icon: "home", path: homeDir, mountpoint: homeDir, removable: false }
    ]

    // ── Categories ───────────────────────────────────────────────────────
    // Unlike a place, a category does not navigate: it narrows the folder you
    // are already in. That is what makes it a category rather than another
    // shortcut, and it is why the chip in the toolbar can always clear it.
    // The active category id, "" meaning none. Declared HERE rather than being
    // read off activeCategory: everything downstream (the chip, the glob
    // list, the reset-on-navigate) needs to tell "no category" apart from
    // "a category whose id happens to be empty", and only the raw flag can.
    property string category: ""

    readonly property var categories: [
        { id: "", label: "All files", icon: "folder", filters: [] },
        { id: "images", label: "Images", icon: "image",
          filters: [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".heic", ".tiff"] },
        { id: "audio", label: "Audio", icon: "music_note",
          filters: [".mp3", ".flac", ".wav", ".ogg", ".m4a", ".aac", ".opus"] },
        { id: "video", label: "Video", icon: "movie",
          filters: [".mp4", ".mkv", ".mov", ".webm", ".avi", ".mkv"] },
        { id: "docs", label: "Documents", icon: "description",
          filters: [".pdf", ".odt", ".docx", ".doc", ".txt", ".md", ".csv", ".xlsx", ".pptx", ".rtf", ".epub"] },
        { id: "archives", label: "Archives", icon: "folder_zip",
          filters: [".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar", ".zst"] },
        { id: "code", label: "Code", icon: "code",
          filters: [".js", ".ts", ".tsx", ".jsx", ".py", ".qml", ".json", ".sh", ".lua",
                    ".css", ".html", ".kt", ".kts", ".java", ".c", ".cpp", ".h", ".rs", ".go", ".toml", ".yaml", ".yml"] }
    ]
    readonly property var activeCategory:
        root.categories.find(c => c.id === root.category) ?? root.categories[0]

    // The one list handed to the model. Categories carry EXTENSIONS (".png")
    // rather than whole globs precisely so this can be built: a glob and an
    // extension cannot be concatenated into anything meaningful, but an
    // extension is just the tail of the pattern you were going to write.
    readonly property var nameFilterGlobs: {
        const text = root.filter.length > 0 ? "*" + root.filter + "*" : "*";
        const exts = root.category !== "" ? root.activeCategory.filters : null;
        // No category and no text: no list at all, which is how you ask the
        // model for "everything" (an empty ["*"] would be a behaviour change).
        if (exts === null && root.filter.length === 0) return [];
        // A category on its own: every extension, unconstrained.
        if (exts === null) return [text];
        // A category narrows the typed pattern to files that are BOTH.
        return exts.map(ext => text + ext);
    }

    function setCategory(id) {
        // Only the flag moves. `nameFilters` is a BINDING on the model (it
        // carries the typed filter too), so assigning to it from here would
        // silently destroy that binding and the filter box would stop working
        // for the rest of the session.
        root.category = (root.category === id) ? "" : id;
    }

    // ── This PC ──────────────────────────────────────────────────────────
    // A sentinel path that never reaches the model, plus the two ways out of
    // it: a tile opens the drive, and the toolbar's back button still means
    // something because the crumb bar shows This PC rather than a folder.
    function showThisPC() {
        root.thisPCMode = true;
        root.selIndex = -1;
        root.filter = "";
        root.category = "";
    }
    function openDrive(mountpoint) {
        const d = root.driveByMount(mountpoint);
        if (!d) return;
        if (!root.isMounted(mountpoint)) {
            // Not connected yet: connect it, then walk in once it lands.
            root.ssdOpenAfter = true;
            root.toggleSsd();
            return;
        }
        root.navigateTo(d.path);
    }
    function isMounted(mountpoint) {
        // Drives other than the SSD are always up; asking about them is
        // pointless, and the rail must not grey out a path that plainly works.
        if (!driveByMount(mountpoint) || !driveByMount(mountpoint).removable)
            return true;
        return root.ssdMounted;
    }

    // ── Sorting ──────────────────────────────────────────────────────────
    // 0 name · 1 date · 2 size, plus reversal. Directories stay first either
    // way (showDirsFirst on the model), which is the one thing you never want
    // interleaved with files.
    property int sortMode: 0
    property bool sortReversed: false

    // ── Context menu (right-click) ────────────────────────────────────────
    // Two menus, one skin: the EMPTY AREA offers the things that create or
    // change the view, an ENTRY offers the things that act on that entry. Both
    // list the real keys next to the action, because this app is driven from a
    // touchpad and a menu you have to explore is a menu you cannot use.
    property bool menuOpen: false
    property real menuX: 0
    property real menuY: 0
    property string menuTarget: ""
    property var menuItems: []
    // Set when the menu is about something that is not a file in the listing
    // (a Places row). Left empty, the title falls back to the folder.
    property string menuTitleOverride: ""
    readonly property string menuTargetName:
        root.menuTitleOverride.length > 0 ? root.menuTitleOverride
            : (root.menuTarget.length > 0 ? root.shortName(root.menuTarget) : root.currentFolderPath())

    function openMenu(x, y, target) {
        root.menuTarget = target ?? "";
        root.menuTitleOverride = "";
        root.menuItems = root.menuTarget.length > 0
            ? root.entryMenu(root.menuTarget)
            : root.folderMenu();
        root.menuX = x;
        root.menuY = y;
        root.menuOpen = true;
    }

    // A Places row is not a file in the listing, so it cannot go through
    // openMenu() -- that routes on "is this a path in the current folder".
    // Right-click / two-finger tap on a place opens THIS instead, and reuses
    // the same card, the same dismiss-on-click-outside and the same skin.
    function openPlaceMenu(x, y, path) {
        root.menuTarget = "";
        root.menuTitleOverride = root.placeLabel(path);
        // This PC has no path, so it cannot be opened, pinned or trashed the
        // way a place can -- it gets the one action that means anything here.
        root.menuItems = (path === root.thisPcSentinel) ? root.thisPCMenu() : root.placeMenu(path);
        root.menuX = x;
        root.menuY = y;
        root.menuOpen = true;
    }

    function thisPCMenu() {
        return [
            { label: Translation.tr("Open"), hint: "", icon: "computer", run: () => root.showThisPC() },
            { separator: true },
            { label: Translation.tr("Open in terminal"), hint: "", icon: "terminal",
              run: () => root.openInTerminal("/") }
        ];
    }

    function placeMenu(path) {
        const pinned = root.pinnedPlaces.includes(path);
        const place = root.allPlaces.find(p => p.path === path);
        const isDrive = !!(place && place.drive === true);
        const up = isDrive && root.isMounted(place.mountpoint);
        const out = [];

        if (isDrive) {
            // A drive's first verb is CONNECT or OPEN, never both, and the
            // disconnect is right there instead of hidden behind a submenu.
            out.push({ label: up ? Translation.tr("Open") : Translation.tr("Connect"),
                       hint: "", icon: up ? "folder_open" : "usb",
                       run: () => root.openDrive(place.mountpoint) });
            if (up)
                out.push({ label: Translation.tr("Disconnect"), hint: "", icon: "eject",
                           run: () => { root.ssdOpenAfter = false; root.toggleSsd(); } });
            out.push({ separator: true });
        } else {
            out.push({ label: Translation.tr("Open"), hint: "", icon: "folder_open", run: () => root.navigateTo(path) });
            // The rail only exists when tabs do (`showRail` is false in picker
            // mode, which is the one case with tabsAvailable === false), so
            // there is no branch here to fall through to a duplicate "Open".
            out.push({ label: Translation.tr("Open in new tab"), hint: "Ctrl+T", icon: "tab",
                       run: () => root.openPlaceInTab(path) });
            out.push({ label: Translation.tr("Open in terminal"), hint: "", icon: "terminal", run: () => root.openInTerminal(path) });
            out.push({ separator: true });
        }
        out.push({ label: pinned ? Translation.tr("Unpin from top") : Translation.tr("Pin to top"),
                   hint: "", icon: pinned ? "keep_off" : "keep", checked: pinned,
                   run: () => root.togglePinPlace(path) });
        out.push({ label: Translation.tr("Copy full path"), hint: "", icon: "content_copy",
                   run: () => root.copyPath(path) });
        out.push({ separator: true });
        out.push({ label: Translation.tr("Remove from Places"), hint: "", icon: "close", danger: true,
                   run: () => root.hidePlace(path) });
        return out;
    }

    // Shown in the rail only while something is actually hidden, so a removed
    // folder is always one click from coming back -- you can never end up
    // having lost a place with no way to get it back.
    function hiddenPlacesMenu() {
        return root.hiddenPlaces.map(path => ({
            label: root.placeLabel(path), hint: "", icon: "restore",
            run: () => root.restorePlace(path)
        }));
    }

    function openPlaceInTab(path) {
        root.newTab(path);
    }
    function closeMenu() { root.menuOpen = false; }
    function runMenu(item) {
        root.closeMenu();
        if (item && item.run) item.run();
    }

    function folderMenu() {
        return [
            { label: Translation.tr("New folder"), hint: "Ctrl+N", icon: "create_new_folder", run: () => root.newFolder() },
            { label: Translation.tr("New file"), hint: "", icon: "note_add", run: () => root.newFile() },
            { separator: true },
            { label: Translation.tr("Open in terminal"), hint: "", icon: "terminal", run: () => root.openInTerminal("") },
            { label: Translation.tr("Copy folder path"), hint: "", icon: "content_copy", run: () => root.copyPath("") },
            { separator: true },
            { label: root.viewMode === "grid" ? Translation.tr("List view") : Translation.tr("Grid view"),
              hint: "Ctrl+1", icon: root.viewMode === "grid" ? "view_list" : "grid_view",
              run: () => root.viewMode = root.viewMode === "grid" ? "list" : "grid" },
            { label: root.showHidden ? Translation.tr("Hide hidden files") : Translation.tr("Show hidden files"),
              hint: "Ctrl+H", icon: root.showHidden ? "visibility_off" : "visibility",
              run: () => root.showHidden = !root.showHidden },
            { label: root.showPreview ? Translation.tr("Hide details pane") : Translation.tr("Show details pane"),
              hint: "", icon: "view_sidebar", run: () => root.showPreview = !root.showPreview },
            { separator: true },
            { label: Translation.tr("Sort by name"), hint: "", icon: "sort_by_alpha", checked: root.sortMode === 0, run: () => root.sortMode = 0 },
            { label: Translation.tr("Sort by date"), hint: "", icon: "schedule", checked: root.sortMode === 1, run: () => root.sortMode = 1 },
            { label: Translation.tr("Sort by size"), hint: "", icon: "data_usage", checked: root.sortMode === 2, run: () => root.sortMode = 2 },
            { label: root.sortReversed ? Translation.tr("Oldest / Z first") : Translation.tr("Newest / A first"),
              hint: "", icon: "swap_vert", checked: root.sortReversed, run: () => root.sortReversed = !root.sortReversed },
            { separator: true },
            { label: Translation.tr("Refresh"), hint: "Ctrl+R", icon: "refresh", run: () => root.refresh() }
        ];
    }

    function entryMenu(path) {
        const isDir = path === root.selectedPath() ? root.selectedIsDir() : false;
        const size = path === root.selectedPath() ? root.fmtSize(root.selectedSize(), isDir) : "";
        const when = path === root.selectedPath() ? root.fmtTime(root.selectedModified()) : "";
        const out = [];
        if (size || when)
            out.push({ header: isDir ? Translation.tr("Folder") : size + (when ? " · " + when : "") });
        out.push({ label: Translation.tr("Open"), hint: "Enter", icon: isDir ? "folder_open" : "open_in_new", run: () => root.openEntry(path, isDir) });
        if (isDir)
            out.push({ label: Translation.tr("Open in terminal"), hint: "", icon: "terminal", run: () => root.openInTerminal(path) });
        out.push({ separator: true });
        out.push({ label: Translation.tr("Rename"), hint: "F2", icon: "edit", run: () => { root.selectIndex(root.selIndex); renameDialog.openWith(path); } });
        out.push({ label: Translation.tr("Move to Trash"), hint: "Delete", icon: "delete", danger: true,
                   run: () => { const i = root.indexOfPath(path); if (i >= 0) root.selectIndex(i); root.trashSelected(); } });
        out.push({ label: Translation.tr("Copy full path"), hint: "", icon: "content_copy", run: () => root.copyPath(path) });
        return out;
    }

    // Which row is this path? The menu acts on paths (it can be opened for the
    // selected entry or for the one under the pointer), and the destructive
    // actions go through the selection, so the path has to be mapped back.
    function indexOfPath(path) {
        for (let i = 0; i < folderModel.count; i++)
            if (folderModel.get(i, "filePath") === path) return i;
        return -1;
    }

    // ── Places ───────────────────────────────────────────────────────────
    // `allPlaces` (with its `section` tags) is the MASTER list, defined with
    // the navigation model above; the rail is a projection of it. Hidden and
    // pinned both persist. A rail you have to rebuild after every restart is
    // not a rail, it is a chore -- and it is the reason "remove" has to
    // survive a restart, or the action is a lie.
    property var hiddenPlaces: Persistent.states.fileManagerHiddenPlaces ?? []
    property var pinnedPlaces: Persistent.states.fileManagerPinnedPlaces ?? []

    // Used by the rail's rows, which still think in terms of one flat list.
    readonly property var places: root.navSectionsVisible
        .reduce((acc, section) => acc.concat(section.rows), [])

    // A drive is asked about by its mountpoint, from three different places
    // (the rail row, the This PC tile, the toolbar chip). One lookup.
    function driveByMount(mountpoint) {
        return root.drives.find(d => d.mountpoint === mountpoint) ?? null;
    }

    function placeLabel(path) {
        const p = root.allPlaces.find(x => x.path === path);
        return p ? p.label : path;
    }
    function hidePlace(path) {
        if (!root.hiddenPlaces.includes(path)) {
            root.hiddenPlaces = root.hiddenPlaces.concat([path]);
            Persistent.states.fileManagerHiddenPlaces = root.hiddenPlaces;
        }
        // Hiding a pinned place has to unpin it too, or restoring it would
        // silently promote it to the top of the rail for no reason.
        if (root.pinnedPlaces.includes(path)) {
            root.pinnedPlaces = root.pinnedPlaces.filter(p => p !== path);
            Persistent.states.fileManagerPinnedPlaces = root.pinnedPlaces;
        }
    }
    function restorePlace(path) {
        root.hiddenPlaces = root.hiddenPlaces.filter(p => p !== path);
        Persistent.states.fileManagerHiddenPlaces = root.hiddenPlaces;
    }
    function togglePinPlace(path) {
        const pinned = root.pinnedPlaces.includes(path);
        root.pinnedPlaces = pinned
            ? root.pinnedPlaces.filter(p => p !== path)
            : root.pinnedPlaces.concat([path]);
        Persistent.states.fileManagerPinnedPlaces = root.pinnedPlaces;
    }

    // ── Picker helpers (unchanged contract) ──────────────────────────────
    function pickerNavigate(path) {
        if (!path) return;
        root.navigateTo(path);
    }
    function fileUri(p) {
        return "file://" + String(p).split("/").map(s => encodeURIComponent(s)).join("/");
    }
    function pickerSelection() {
        if (root.pickerOp === "save") {
            const name = pickerNameField.text.trim();
            if (!name) return [];
            return [root.fileUri(root.currentFolderPath() + "/" + name)];
        }
        if (root.pickerDirectory)
            return [root.fileUri(root.currentFolderPath())];
        const p = root.selectedPath();
        return p ? [root.fileUri(p)] : [];
    }
    function pickerPrimary() {
        const uris = root.pickerSelection();
        if (uris.length === 0) {
            if (root.pickerOp === "save") pickerNameField.forceActiveFocus();
            return;
        }
        root.pickerAccepted(uris);
    }
    function enterPressed() {
        if (root.pickerMode && !root.pickerDirectory && !root.selectedIsDir()
                && root.pickerOp === "open" && root.selIndex >= 0) {
            root.pickerPrimary();
            return;
        }
        if (root.selIndex >= 0) root.openSelected();
    }

    function focusHelper() { root.forceActiveFocus(); }

    // ══ Layout ═══════════════════════════════════════════════════════════
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ── Places rail ──────────────────────────────────────────────────
        Rectangle {
            id: rail
            visible: root.showRail
            Layout.preferredWidth: root.showRail ? root.railWidth : 0
            Layout.fillHeight: true
            color: "transparent"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 2

                // ── Sectioned navigation ─────────────────────────────────
                // One Flickable over `navSectionsVisible`, and each section
                // brings its own rows and its own heading. A flat list of
                // folders could not tell you that the SSD is a DEVICE rather
                // than a folder, and once three kinds of thing share a rail
                // the headings are the only thing keeping it scannable.
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: navColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    // Same kinetic glide the breadcrumbs and the listing get:
                    // one desktop, one feel.
                    flickDeceleration: 2500
                    maximumFlickVelocity: 8000

                    ColumnLayout {
                        id: navColumn
                        width: parent.width
                        spacing: 0

                        Repeater {
                            model: root.navSectionsVisible
                            delegate: ColumnLayout {
                                id: sectionCol
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 1

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 10
                                    Layout.bottomMargin: 3
                                    Layout.leftMargin: 8
                                    Layout.rightMargin: 8
                                    spacing: 6
                                    MaterialSymbol {
                                        text: sectionCol.modelData.icon
                                        iconSize: 14
                                        color: Appearance.colors.colSubtext
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: Translation.tr(sectionCol.modelData.title)
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colSubtext
                                        elide: Text.ElideRight
                                    }
                                }

                                Repeater {
                                    model: sectionCol.modelData.rows
                                    delegate: Rectangle {
                                        id: placeRow
                                        required property var modelData
                                        Layout.fillWidth: true
                                        implicitHeight: 32
                                        radius: Appearance.rounding.small
                                        // This PC is selected by its own flag, not
                                        // by path: it is not a path at all, and
                                        // comparing it against the current folder
                                        // would light up whenever the folder
                                        // happened to be anything at all.
                                        readonly property bool isPC:
                                            placeRow.modelData.path === root.thisPcSentinel
                                        readonly property bool selected:
                                            placeRow.isPC
                                                ? root.thisPCMode
                                                : (!root.thisPCMode
                                                    && root.currentFolderPath() === placeRow.modelData.path)
                                        // A drive that is not up says so, and offers
                                        // to be connected. Nothing else in the rail
                                        // carries a second word.
                                        readonly property bool connected:
                                            placeRow.modelData.mountpoint
                                                ? root.isMounted(placeRow.modelData.mountpoint) : true
                                        readonly property bool isDrive:
                                            placeRow.modelData.drive === true

                                        color: placeRow.selected
                                            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84)
                                            : (placeHover.hovered ? Appearance.colors.colLayer1Hover : "transparent")
                                        HoverHandler { id: placeHover; cursorShape: Qt.PointingHandCursor }

                                        TapHandler {
                                            acceptedButtons: Qt.LeftButton
                                            onTapped: {
                                                if (placeRow.isPC) {
                                                    root.showThisPC();
                                                    return;
                                                }
                                                // A disconnected drive CONNECTS on the
                                                // same click that would otherwise open
                                                // it. Explorer asks first; here the ask
                                                // IS the polkit prompt.
                                                if (placeRow.isDrive && !placeRow.connected) {
                                                    root.ssdOpenAfter = true;
                                                    root.toggleSsd();
                                                    return;
                                                }
                                                root.navigateTo(placeRow.modelData.path);
                                            }
                                        }
                                        // Right-click, which on a touchpad IS the
                                        // two-finger tap -- no separate gesture to
                                        // wire up. Separate handler rather than a
                                        // second acceptedButtons on the one above:
                                        // this must NOT also navigate.
                                        TapHandler {
                                            acceptedButtons: Qt.RightButton
                                            onTapped: event => {
                                                const p = placeRow.mapToItem(root, event.position.x, event.position.y);
                                                root.openPlaceMenu(p.x, p.y, placeRow.modelData.path);
                                            }
                                        }

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            spacing: 8
                                            MaterialSymbol {
                                                text: placeRow.modelData.icon
                                                iconSize: 17
                                                color: placeRow.selected
                                                    ? Appearance.colors.colPrimary
                                                    : (placeRow.isDrive && !placeRow.connected
                                                        ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer0)
                                            }
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Translation.tr(placeRow.modelData.label)
                                                font.pixelSize: Appearance.font.pixelSize.smallie
                                                color: placeRow.selected
                                                    ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                                                elide: Text.ElideRight
                                            }
                                            StyledText {
                                                visible: placeRow.isDrive && !placeRow.connected
                                                text: Translation.tr("Connect")
                                                font.pixelSize: Appearance.font.pixelSize.smallest
                                                color: Appearance.colors.colSubtext
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Categories ──
                // Not navigation: a category narrows the folder you are
                // ALREADY in, which is why the toolbar grows a clearable chip
                // while one is active. Chips, not a second list -- eight more
                // rows of rail would push the drives, the things you actually
                // plug in, off the bottom of the panel.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    Layout.topMargin: 10
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        MaterialSymbol {
                            text: "category"
                            iconSize: 14
                            color: Appearance.colors.colSubtext
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: Translation.tr("Categories")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: root.categories
                            delegate: Rectangle {
                                id: catChip
                                required property var modelData
                                readonly property bool active: root.category === modelData.id
                                width: catLabel.implicitWidth + 26
                                height: 24
                                radius: Appearance.rounding.full
                                color: catChip.active
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)
                                    : (catHover.hovered ? Appearance.colors.colLayer1Hover : "transparent")
                                HoverHandler { id: catHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: root.setCategory(catChip.modelData.id) }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 5
                                    MaterialSymbol {
                                        text: catChip.modelData.icon
                                        iconSize: 13
                                        color: catChip.active
                                            ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                                    }
                                    StyledText {
                                        id: catLabel
                                        text: Translation.tr(catChip.modelData.label)
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: catChip.active
                                            ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                                    }
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }

                // The way back. Appears ONLY while something is hidden, so a
                // removed folder is never gone for good -- you cannot lose a
                // place you have no affordance to restore.
                Rectangle {
                    id: restoreRow
                    visible: root.hiddenPlaces.length > 0
                    Layout.fillWidth: true
                    implicitHeight: visible ? 30 : 0
                    radius: Appearance.rounding.small
                    color: restoreHover.hovered ? Appearance.colors.colLayer1Hover : "transparent"
                    HoverHandler { id: restoreHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: event => {
                            const p = restoreRow.mapToItem(root, event.position.x, event.position.y);
                            root.menuTarget = "";
                            root.menuTitleOverride = Translation.tr("Hidden places");
                            root.menuItems = root.hiddenPlacesMenu();
                            root.menuX = p.x;
                            root.menuY = p.y;
                            root.menuOpen = true;
                        }
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 8
                        MaterialSymbol {
                            text: "restore"
                            iconSize: 16
                            color: Appearance.colors.colSubtext
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: Translation.tr("Hidden places")
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                        StyledText {
                            text: root.hiddenPlaces.length
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }
                    }
                }

                // Storage at a glance -- the one "system" fact a file manager
                // should never make you go looking for.
                StyledText {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    text: Translation.tr("Storage") + "\n" + root.storageText
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.WordWrap
                }
            }
        }

        Rectangle {
            visible: root.showRail
            Layout.preferredWidth: root.showRail ? 1 : 0
            Layout.fillHeight: true
            Layout.topMargin: 10
            Layout.bottomMargin: 10
            color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
        }

        // ── Main column ─────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ── Tabs ─────────────────────────────────────────────────────
            // One chip per open place, above the toolbar: click to swap,
            // middle-click or the little x to close, + to add. Scrolls
            // horizontally with the same two-finger glide as every pane.
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: root.tabsAvailable ? 32 : 0
                Layout.topMargin: root.tabsAvailable ? 6 : 0
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                visible: root.tabsAvailable
                spacing: 4

                StyledFlickable {
                    id: tabStrip
                    Layout.fillWidth: true
                    Layout.preferredHeight: 26
                    contentWidth: tabRow.width
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Row {
                        id: tabRow
                        height: tabStrip.height
                        spacing: 4

                        Repeater {
                            model: root.tabs

                            Rectangle {
                                id: tabChip
                                required property var modelData
                                required property int index
                                readonly property bool isActive: index === root.activeTab
                                readonly property bool hasClose: root.tabs.length > 1
                                height: tabRow.height
                                width: Math.min(190, tabLabelText.implicitWidth + (tabChip.hasClose ? 46 : 26))
                                radius: height / 2
                                color: tabChip.isActive
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)
                                    : (tabHover.hovered ? Appearance.colors.colLayer1Hover : "transparent")
                                border.width: 1
                                border.color: tabChip.isActive
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
                                    : Appearance.colors.colLayer0Border
                                Behavior on color {
                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                }

                                HoverHandler {
                                    id: tabHover
                                    cursorShape: Qt.PointingHandCursor
                                }
                                TapHandler {
                                    onTapped: root.selectTab(tabChip.index)
                                }
                                // Middle-click closes, the browser reflex.
                                TapHandler {
                                    acceptedButtons: Qt.MiddleButton
                                    onTapped: root.closeTab(tabChip.index)
                                }

                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    spacing: 6

                                    MaterialSymbol {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "folder"
                                        iconSize: 13
                                        color: tabChip.isActive
                                            ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                                    }
                                    StyledText {
                                        id: tabLabelText
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.tabLabel(tabChip.modelData)
                                        font.pixelSize: Appearance.font.pixelSize.smallie
                                        color: tabChip.isActive
                                            ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
                                        elide: Text.ElideMiddle
                                        width: Math.min(implicitWidth, 116)
                                    }
                                }

                                MaterialSymbol {
                                    id: tabClose
                                    visible: tabChip.hasClose
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.right: parent.right
                                    anchors.rightMargin: 9
                                    text: "close"
                                    iconSize: 12
                                    color: closeHover.hovered
                                        ? Appearance.colors.colError : Appearance.colors.colSubtext
                                    HoverHandler {
                                        id: closeHover
                                        cursorShape: Qt.PointingHandCursor
                                    }
                                    TapHandler {
                                        onTapped: root.closeTab(tabChip.index)
                                    }
                                }
                            }
                        }
                    }
                }

                ToolButton {
                    symbol.text: "add"
                    tooltipText: Translation.tr("New tab  (Ctrl+T)")
                    onActivated: root.newTab()
                }
            }

            // One row of controls: the card's drag zone, and the only chrome.
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                spacing: 2

                ToolButton {
                    symbol.text: "arrow_back"
                    tooltipText: Translation.tr("Back  (Backspace back)")
                    enabled: root.thisPCMode || folderModel.currentFolderHistoryIndex > 0
                    onActivated: root.goBack()
                }
                ToolButton {
                    symbol.text: "arrow_forward"
                    tooltipText: Translation.tr("Forward")
                    enabled: folderModel.currentFolderHistoryIndex < folderModel.folderHistory.length - 1
                    onActivated: root.goForward()
                }
                ToolButton {
                    symbol.text: "arrow_upward"
                    tooltipText: Translation.tr("Parent folder  (Delete/Backspace)")
                    enabled: !root.thisPCMode && folderModel.parentFolder !== ""
                    onActivated: root.goUp()
                }

                // The Windows SSD. One button for both directions: it reports
                // the mount state it actually finds, so it can never offer to
                // mount a drive that is already up. Mounting asks for a
                // password once, then walks straight into the drive.
                ToolButton {
                    symbol.text: root.ssdMounted ? "eject" : "usb"
                    tooltipText: root.ssdMounted
                        ? Translation.tr("Unmount the Windows SSD")
                        : Translation.tr("Mount the Windows SSD")
                    active: root.ssdMounted
                    onActivated: {
                        root.ssdOpenAfter = true;
                        root.toggleSsd();
                    }
                }

                // Breadcrumbs: click a crumb to jump back up that branch.
                // Kinetic: StyledFlickable's wheel handler gives the breadcrumbs
                // the same two-finger glide as every other pane.
                StyledFlickable {
                    id: crumbBar
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    Layout.maximumWidth: root.pickerMode ? 240 : 560
                    contentWidth: crumbRow.width
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Row {
                        id: crumbRow
                        height: crumbBar.height
                        spacing: 2
                        Repeater {
                            model: root.crumbSegments
                            delegate: Rectangle {
                                id: crumb
                                required property var modelData
                                // Inside a Row a child may not anchor, so the
                                // height is taken from the row itself.
                                height: crumbRow.height - 4
                                width: crumbText.implicitWidth + 16
                                radius: Appearance.rounding.small
                                color: crumbHover.hovered
                                    ? Appearance.colors.colLayer1Hover
                                    : (crumb.modelData.path === root.currentFolderPath()
                                        ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84) : "transparent")
                                HoverHandler { id: crumbHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: root.navigateTo(crumb.modelData.path) }
                                StyledText {
                                    id: crumbText
                                    anchors.centerIn: parent
                                    text: crumb.modelData.path === root.homeDir
                                        ? Translation.tr("Home") : crumb.modelData.label
                                    font.pixelSize: Appearance.font.pixelSize.smallie
                                    color: crumb.modelData.path === root.currentFolderPath()
                                        ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                                }
                            }
                        }
                    }
                }

                // The active category, made visible AND clearable.
                // A category is the one filter with no on-screen trace
                // otherwise: pick "Images" and the listing just looks
                // smaller, with nothing saying why. This chip is that
                // answer, and one click puts the folder back.
                Rectangle {
                    visible: root.category !== "" && !root.thisPCMode
                    Layout.preferredWidth: catChipText.implicitWidth + catChipClear.width + 26
                    Layout.preferredHeight: 32
                    radius: Appearance.rounding.full
                    color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84)
                    HoverHandler { id: catChipHover; cursorShape: Qt.PointingHandCursor }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 4
                        spacing: 6
                        MaterialSymbol {
                            text: root.activeCategory.icon
                            iconSize: 14
                            color: Appearance.colors.colPrimary
                        }
                        StyledText {
                            id: catChipText
                            text: Translation.tr(root.activeCategory.label)
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colPrimary
                        }
                        // Separate target from the chip itself: on a touchpad
                        // the X has to be big enough to hit without hitting
                        // the label next to it.
                        Item {
                            id: catChipClear
                            width: 24
                            height: 24
                            Rectangle {
                                anchors.fill: parent
                                radius: Appearance.rounding.full
                                color: catClearHover.hovered
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.6) : "transparent"
                                HoverHandler { id: catClearHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: root.setCategory(root.category) }
                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "close"
                                    iconSize: 14
                                    color: Appearance.colors.colPrimary
                                }
                            }
                        }
                    }
                }

                // Filter: type to narrow, no dialog.
                TextField {
                    id: filterField
                    Layout.preferredWidth: 150
                    Layout.preferredHeight: 32
                    placeholderText: Translation.tr("Filter…")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colOnLayer0
                    placeholderTextColor: Appearance.colors.colOnLayer1Inactive
                    verticalAlignment: TextInput.AlignVCenter
                    leftPadding: 10
                    rightPadding: 10
                    onTextChanged: root.filter = text
                    background: Rectangle {
                        radius: Appearance.rounding.small
                        color: filterField.activeFocus
                            ? Appearance.colors.colLayer1
                            : CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.6)
                        border.width: 1
                        border.color: filterField.activeFocus
                            ? Appearance.colors.colPrimary
                            : CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.7)
                    }
                }

                ToolButton {
                    symbol.text: root.viewMode === "grid" ? "view_list" : "grid_view"
                    tooltipText: root.viewMode === "grid"
                        ? Translation.tr("List view  (Ctrl+1)")
                        : Translation.tr("Thumbnail view  (Ctrl+1)")
                    onActivated: root.viewMode = root.viewMode === "grid" ? "list" : "grid"
                }
                ToolButton {
                    visible: !root.pickerMode
                    active: root.showPreview && root.showPreviewPane
                    symbol.text: "side_navigation"
                    tooltipText: Translation.tr("Preview pane  (Space)")
                    onActivated: root.showPreview = !root.showPreview
                }
                ToolButton {
                    symbol.text: root.showHidden ? "visibility" : "visibility_off"
                    tooltipText: Translation.tr("Hidden files  (Ctrl+H)")
                    onActivated: root.showHidden = !root.showHidden
                }
                ToolButton {
                    symbol.text: "create_new_folder"
                    tooltipText: Translation.tr("New folder  (Ctrl+N)")
                    onActivated: root.newFolder()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.7)
            }

            // ── This PC ──
                // The machine's own answer to "what can I open", as tiles
                // rather than rows: a drive is an object, not a file, and it
                // wants its free space and its connection state on the same
                // line as its name. Clicking a disconnected drive CONNECTS
                // it (the polkit prompt is the confirmation); clicking a
                // connected one opens it. No dialog in between, which is the
                // whole point of having the state on the tile.
                Item {
                    id: thisPCView
                    visible: root.thisPCMode
                    // Layout properties, NOT anchors: this sits inside the
                    // content ColumnLayout beside the listing, and anchoring a
                    // layout-managed item is undefined behaviour (Qt says so
                    // at runtime, and the sibling listing item already does it
                    // this way).
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 6
                    clip: true

                    GridView {
                        id: driveGrid
                        anchors.fill: parent
                        readonly property int cols: Math.max(1, Math.min(4, Math.floor((width - 12) / 230)))
                        cellWidth: cols > 0 ? Math.floor((width - 12) / cols) : 230
                        cellHeight: 116
                        clip: true
                        model: root.drives
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 2500
                        maximumFlickVelocity: 8000
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        delegate: Rectangle {
                            id: driveTile
                            required property var modelData
                            required property int index
                            width: driveGrid.cellWidth - 10
                            height: driveGrid.cellHeight - 10
                            x: 5
                            y: 5
                            radius: Appearance.rounding.large
                            color: driveTileMouse.hovered
                                ? Appearance.colors.colLayer1Hover
                                : Appearance.colors.colLayer1
                            border.width: 1
                            border.color: driveTileMouse.hovered
                                ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.7)
                                : Appearance.colors.colLayer0Border
                            HoverHandler { id: driveTileMouse; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.openDrive(driveTile.modelData.mountpoint) }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 14
                                spacing: 3

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    MaterialSymbol {
                                        text: driveTile.modelData.icon
                                        iconSize: 26
                                        color: root.isMounted(driveTile.modelData.mountpoint)
                                            ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Translation.tr(driveTile.modelData.label)
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            elide: Text.ElideRight
                                        }
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Translation.tr(driveTile.modelData.sub)
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            color: Appearance.colors.colSubtext
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                Item { Layout.fillHeight: true }

                                // The one line that changes what a click will
                                // do, so it is the one line styled differently.
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 22
                                    radius: Appearance.rounding.full
                                    visible: driveTile.modelData.removable === true
                                    color: root.isMounted(driveTile.modelData.mountpoint)
                                        ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.85)
                                        : CF.ColorUtils.transparentize(Appearance.colors.colSubtext, 0.88)
                                    StyledText {
                                        anchors.centerIn: parent
                                        text: root.isMounted(driveTile.modelData.mountpoint)
                                            ? Translation.tr("Connected")
                                            : Translation.tr("Click to connect")
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: root.isMounted(driveTile.modelData.mountpoint)
                                            ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                                    }
                                }
                            }
                        }
                    }
                }

                // ── The listing ──────────────────────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // Empty-folder state -- "nothing here" said out loud, so an
                // empty directory never reads as a broken app.
                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 8
                    visible: folderModel.count === 0 && !root.thisPCMode
                    MaterialSymbol {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.filter.length > 0 ? "search_off" : "folder_off"
                        iconSize: 42
                        color: Appearance.colors.colOnLayer1Inactive
                    }
                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.filter.length > 0
                            ? Translation.tr("Nothing matches “%1”").arg(root.filter)
                            : Translation.tr("This folder is empty")
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colSubtext
                    }
                }

                GridView {
                    id: gridView
                    visible: !root.thisPCMode && root.viewMode === "grid"
                    anchors.fill: parent
                    anchors.margins: 6
                    // Columns follow the space we were given: four across in
                    // the popup card, six in the morphed full-screen window.
                    readonly property int cols: Math.max(2, Math.min(7, Math.floor((width - 12) / 150)))
                    cellWidth: cols > 0 ? Math.floor((width - 12) / cols) : 150
                    cellHeight: 138
                    clip: true
                    model: folderModel
                    currentIndex: -1
                    // Right-click in the empty space between tiles: the folder's
                    // own menu (create, view, sort). Right-clicking a TILE is
                    // handled by the tile above, which is closer to the pointer.
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: event => {
                            const p = gridView.mapToItem(root, event.position.x, event.position.y);
                            root.openMenu(p.x, p.y, "");
                        }
                    }
                    boundsBehavior: Flickable.StopAtBounds
                    // Kinetic glide: a touchpad flick keeps coasting after the
                    // fingers lift, decaying over a distance rather than time,
                    // like a browser.
                    flickDeceleration: 2500
                    maximumFlickVelocity: 8000
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        id: tile
                        required property int index
                        required property string fileName
                        required property string filePath
                        required property bool fileIsDir
                        required property var fileSize
                        width: gridView.cellWidth - 8
                        height: gridView.cellHeight - 8
                        radius: Appearance.rounding.normal
                        color: root.selIndex === tile.index
                            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)
                            : tileHover.hovered ? Appearance.colors.colLayer1Hover : "transparent"
                        border.width: 1
                        border.color: root.selIndex === tile.index
                            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.4)
                            : "transparent"

                        // ── Drag OUT: hand this entry to another app ──
                        //
                        // ONE MouseArea rather than a TapHandler plus a
                        // DragHandler, and the reason is arbitration. A
                        // TapHandler/DragHandler pair on the same item lets
                        // the drag win as soon as the pointer moves past the
                        // PLATFORM's drag threshold, which on a touchpad is a
                        // couple of pixels: a slow, deliberate click jitters
                        // past it, the drag grabs, and the tap is cancelled --
                        // so selecting a file became a gesture that selected
                        // nothing. This measures the movement itself and
                        // ignores anything under 12px, which is what makes
                        // "click" and "drag" two distinguishable intents
                        // rather than one intent the compositor arbitrates.
                        //
                        // Same shape as the tray button's press/release drag
                        // (modules/waffle/bar/tray/Tray.qml), with a gate.
                        // DragManual: a deliberate choice rather than the
                        // platform's low touchpad threshold, so a double-click
                        // is not hijacked by a drag that starts on the first
                        // click's tiny jitter. The 12px gate in onPositionChanged
                        // is what actually decides click vs drag.
                        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
                        Drag.mimeData: {
                            "text/uri-list": tile.filePath,
                            "text/plain": tile.fileName,
                        }
                        Drag.hotSpot.x: width / 2
                        Drag.hotSpot.y: height / 2

                        HoverHandler { id: tileHover; cursorShape: Qt.PointingHandCursor }
                        MouseArea {
                            id: tilePress
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            property point pressAt
                            property bool armed: false
                            onPressed: mouse => {
                                tilePress.pressAt = Qt.point(mouse.x, mouse.y);
                                tilePress.armed = true;
                            }
                            onPositionChanged: mouse => {
                                if (!tilePress.armed) return;
                                const dx = mouse.x - tilePress.pressAt.x;
                                const dy = mouse.y - tilePress.pressAt.y;
                                if (dx * dx + dy * dy <= 12 * 12) return;
                                // Dragging an entry that was not the selection
                                // selects it first, so the drop target receives
                                // what the pointer was actually over.
                                root.selectIndex(tile.index);
                                tile.Drag.active = true;
                            }
                            onReleased: {
                                tile.Drag.active = false;
                                tilePress.armed = false;
                            }
                            onClicked: root.selectIndex(tile.index)
                            onDoubleClicked: root.activate(tile.index)
                        }
                        TapHandler {
                            // Right-click an entry: it becomes the selection (so
                            // the menu's own actions agree with what is
                            // highlighted) and the entry menu opens at the
                            // pointer.
                            acceptedButtons: Qt.RightButton
                            onTapped: event => {
                                root.selectIndex(tile.index);
                                const p = tile.mapToItem(root, event.position.x, event.position.y);
                                root.openMenu(p.x, p.y, tile.filePath);
                            }
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 4

                            // The thumbnail area: real preview for pictures,
                            // a big glyph for everything else.
                            Rectangle {
                                id: thumbArea
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: Appearance.rounding.small
                                color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.7)
                                clip: true

                                // A Loader, not a `visible: false` image: an
                                // invisible ThumbnailImage still fires its
                                // magick generation for every non-picture in
                                // the folder.
                                Loader {
                                    id: tileThumb
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    active: !tile.fileIsDir && root.isImage(tile.fileName)
                                    // True when the image is recognised by
                                    // extension but no decoder can actually
                                    // read it -- a truncated download, a
                                    // mis-named archive (there is a 1.4 GB
                                    // gzip file here named .png), anything
                                    // whose bytes are not the format its
                                    // name claims. The tile then shows the
                                    // icon instead of an empty box that
                                    // looks like the shell forgot to load.
                                    readonly property bool undecodable:
                                        tileThumb.item
                                        && tileThumb.item.undecodable === true
                                    sourceComponent: Component {
                                        ThumbnailImage {
                                            sourcePath: tile.filePath
                                            fillMode: Image.PreserveAspectCrop
                                            // Only generate once the tile has
                                            // been laid out: at construction
                                            // the area is still 0, and the
                                            // component would spend its first
                                            // magick run on the wrong
                                            // ("normal") thumbnail size before
                                            // asking for "large" a moment later.
                                            generateThumbnail: thumbArea.width > 24 && thumbArea.height > 24
                                        }
                                    }
                                }

                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    visible: tile.fileIsDir || !root.isImage(tile.fileName)
                                        || tileThumb.undecodable
                                    text: root.iconFor(tile.fileName, tile.fileIsDir)
                                    iconSize: 40
                                    color: tile.fileIsDir
                                        ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                                }
                            }

                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignHCenter
                                text: tile.fileName
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                elide: Text.ElideMiddle
                                maximumLineCount: 1
                                horizontalAlignment: Text.AlignHCenter
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignHCenter
                                text: root.fmtSize(tile.fileSize, tile.fileIsDir)
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                                visible: text.length > 0
                            }
                        }
                    }
                }

                // StyledListView, not a bare ListView: this is the file
                // manager's MAIN list -- the one with a real chance of being
                // scrolled with a touchpad -- and a bare ListView has no
                // wheel momentum at all, so it stopped dead the instant the
                // fingers lifted. StyledListView carries the shared fling
                // physics and the compositor-delta gain.
                StyledListView {
                    id: listView
                    visible: !root.thisPCMode && root.viewMode === "list"
                    anchors.fill: parent
                    anchors.margins: 4
                    clip: true
                    model: folderModel
                    currentIndex: -1
                    spacing: 0
                    // The styled component supplies the add/remove transitions;
                    // this list has no pop-in, and the default transitions
                    // fought the drag-reorder animation.
                    animateAppearance: false
                    animateMovement: true
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: event => {
                            const p = listView.mapToItem(root, event.position.x, event.position.y);
                            root.openMenu(p.x, p.y, "");
                        }
                    }

                    delegate: Rectangle {
                        id: rowItem
                        required property int index
                        required property string fileName
                        required property string filePath
                        required property bool fileIsDir
                        required property var fileSize
                        required property var fileModified
                        width: ListView.view.width
                        height: 40
                        radius: Appearance.rounding.small
                        color: root.selIndex === rowItem.index
                            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)
                            : rowHover.hovered ? Appearance.colors.colLayer1Hover : "transparent"

                        // Same drag-out contract as the grid tile, and the same
                        // reason it is a MouseArea and not a handler pair: see
                        // DragManual: same reason as the tile delegate (see its
                        // note). A platform-low drag threshold on a touchpad would
                        // hijack a double-click.
                        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
                        Drag.mimeData: {
                            "text/uri-list": rowItem.filePath,
                            "text/plain": rowItem.fileName,
                        }
                        Drag.hotSpot.x: width / 2
                        Drag.hotSpot.y: height / 2

                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        MouseArea {
                            id: rowPress
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            property point pressAt
                            property bool armed: false
                            onPressed: mouse => {
                                rowPress.pressAt = Qt.point(mouse.x, mouse.y);
                                rowPress.armed = true;
                            }
                            onPositionChanged: mouse => {
                                if (!rowPress.armed) return;
                                const dx = mouse.x - rowPress.pressAt.x;
                                const dy = mouse.y - rowPress.pressAt.y;
                                if (dx * dx + dy * dy <= 12 * 12) return;
                                root.selectIndex(rowItem.index);
                                rowItem.Drag.active = true;
                            }
                            onReleased: {
                                rowItem.Drag.active = false;
                                rowPress.armed = false;
                            }
                            onClicked: root.selectIndex(rowItem.index)
                            onDoubleClicked: root.activate(rowItem.index)
                        }
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onTapped: event => {
                                root.selectIndex(rowItem.index);
                                const p = rowItem.mapToItem(root, event.position.x, event.position.y);
                                root.openMenu(p.x, p.y, rowItem.filePath);
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 12
                            spacing: 10
                            MaterialSymbol {
                                text: root.iconFor(rowItem.fileName, rowItem.fileIsDir)
                                iconSize: 20
                                color: rowItem.fileIsDir ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: rowItem.fileName
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                elide: Text.ElideRight
                            }
                            StyledText {
                                text: root.fmtTime(rowItem.fileModified)
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                                visible: !root.pickerMode
                            }
                            StyledText {
                                Layout.preferredWidth: 76
                                text: root.fmtSize(rowItem.fileSize, rowItem.fileIsDir)
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                                horizontalAlignment: Text.AlignRight
                            }
                        }
                    }
                }
            }

            // ── Hint strip (touchpad-first: the keys announce themselves) ──
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.pickerMode ? 0 : 28
                visible: !root.pickerMode
                color: "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10
                    StyledText {
                        text: root.selIndex >= 0
                            ? root.selectedName()
                            : folderModel.count + " " + Translation.tr("items")
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                        Layout.maximumWidth: 220
                    }
                    Item { Layout.fillWidth: true }
                    // The keys, said out loud. Touchpad-first means nothing may
                    // hide behind a menu you have to go find.
                    StyledText {
                        text: Translation.tr("Enter open · Delete/Backspace up · F2 rename · Ctrl+N new · Ctrl+H hidden · Ctrl+1 view · Space preview · / filter")
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                }
            }

            // ── Picker action bar (portal dialogs only) ───────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.pickerMode ? 54 : 0
                visible: root.pickerMode
                color: "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10

                    TextField {
                        id: pickerNameField
                        visible: root.pickerOp === "save"
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        text: root.pickerName
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer0
                        placeholderText: Translation.tr("File name")
                        placeholderTextColor: Appearance.colors.colOnLayer1Inactive
                        verticalAlignment: TextInput.AlignVCenter
                        leftPadding: 10
                        rightPadding: 10
                        background: Rectangle {
                            radius: Appearance.rounding.small
                            color: pickerNameField.activeFocus
                                ? Appearance.colors.colLayer1
                                : CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.6)
                            border.width: 1
                            border.color: pickerNameField.activeFocus
                                ? Appearance.colors.colPrimary
                                : CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.7)
                        }
                        onAccepted: root.pickerPrimary()
                    }

                    StyledText {
                        visible: root.pickerOp !== "save"
                        Layout.fillWidth: true
                        text: root.pickerDirectory
                            ? Translation.tr("Choose this folder, or open another one")
                            : Translation.tr("Double-click a file, or select one and choose Open")
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }

                    RippleButton {
                        implicitWidth: 84; implicitHeight: 30
                        buttonRadius: Appearance.rounding.full
                        colBackground: Appearance.colors.colLayer1Hover
                        buttonText: Translation.tr("Cancel")
                        onClicked: root.pickerCancelled()
                    }
                    RippleButton {
                        implicitWidth: 96; implicitHeight: 30
                        buttonRadius: Appearance.rounding.full
                        colBackground: Appearance.colors.colPrimary
                        buttonText: root.pickerOp === "save" ? Translation.tr("Save")
                            : root.pickerDirectory ? Translation.tr("Choose")
                            : Translation.tr("Open")
                        onClicked: root.pickerPrimary()
                    }
                }
            }
        }

        // ── Preview pane ─────────────────────────────────────────────────
        Rectangle {
            visible: root.showPreviewPane
            Layout.preferredWidth: root.showPreviewPane ? root.previewWidth : 0
            Layout.fillHeight: true
            color: "transparent"

            Rectangle {
                anchors.fill: parent
                anchors.margins: 10
                anchors.leftMargin: 0
                radius: Appearance.rounding.normal
                color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.55)
                border.width: 1
                border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 10

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 150
                        radius: Appearance.rounding.small
                        color: CF.ColorUtils.transparentize(Appearance.colors.colLayer2, 0.5)
                        clip: true

                        Loader {
                            id: previewThumb
                            anchors.fill: parent
                            anchors.margins: 6
                            active: root.selIndex >= 0 && root.isImage(root.selectedName())
                            readonly property bool undecodable:
                                previewThumb.item
                                && previewThumb.item.undecodable === true
                            sourceComponent: Component {
                                ThumbnailImage {
                                    sourcePath: root.selIndex >= 0 ? root.selectedPath() : ""
                                    fillMode: Image.PreserveAspectFit
                                }
                            }
                        }

                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: !(root.selIndex >= 0 && root.isImage(root.selectedName()))
                                || previewThumb.undecodable
                            text: root.selIndex >= 0
                                ? root.iconFor(root.selectedName(), root.selectedIsDir())
                                : "preview"
                            iconSize: 56
                            color: Appearance.colors.colOnLayer1Inactive
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: root.selIndex >= 0 ? root.selectedName() : Translation.tr("Nothing selected")
                        font.pixelSize: Appearance.font.pixelSize.small
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideMiddle
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        visible: root.selIndex >= 0
                        Repeater {
                            model: root.selIndex >= 0 ? [
                                { k: Translation.tr("Kind"), v: root.kindFor(root.selectedName(), root.selectedIsDir()) },
                                { k: Translation.tr("Size"), v: root.fmtSize(root.selectedSize(), root.selectedIsDir()) },
                                { k: Translation.tr("Modified"), v: root.fmtTime(root.selectedModified()) },
                                { k: Translation.tr("Where"), v: root.currentFolderPath() }
                            ] : []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 8
                                StyledText {
                                    Layout.preferredWidth: 62
                                    text: modelData.k
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colSubtext
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: modelData.v
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    elide: Text.ElideMiddle
                                    wrapMode: Text.WrapAnywhere
                                    maximumLineCount: 2
                                }
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    RippleButton {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        buttonRadius: Appearance.rounding.full
                        colBackground: Appearance.colors.colPrimary
                        buttonText: root.selectedIsDir() ? Translation.tr("Open folder") : Translation.tr("Open")
                        enabled: root.selIndex >= 0
                        onClicked: root.openSelected()
                    }
                    RippleButton {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        buttonRadius: Appearance.rounding.full
                        colBackground: Appearance.colors.colLayer2
                        visible: root.selIndex >= 0 && !root.selectedIsDir() && root.isImage(root.selectedName())
                        buttonText: Translation.tr("Set as wallpaper")
                        onClicked: Wallpapers.apply(root.selectedPath())
                    }
                    RippleButton {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        buttonRadius: Appearance.rounding.full
                        colBackground: Appearance.colors.colLayer2
                        visible: root.selIndex >= 0
                        buttonText: Translation.tr("Rename")
                        onClicked: renameDialog.openWith(root.selectedPath())
                    }
                    RippleButton {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        buttonRadius: Appearance.rounding.full
                        colBackground: Appearance.colors.colLayer2
                        visible: root.selIndex >= 0
                        buttonText: Translation.tr("Move to trash")
                        onClicked: root.trashSelected()
                    }
                }
            }
        }
    }

    // ── Keys ─────────────────────────────────────────────────────────────
    // A touchpad-first app lives or dies on this block: every action above is
    // reachable without the pointer. Keys that would fight a text field stand
    // down while one has focus.
    readonly property bool typing: filterField.activeFocus
        || pickerNameField.activeFocus || renameField.activeFocus

    Shortcut { sequence: "Up"; enabled: !root.typing; onActivated: root.stepVertical(-1) }
    Shortcut { sequence: "Down"; enabled: !root.typing; onActivated: root.stepVertical(1) }
    Shortcut { sequence: "Left"; enabled: !root.typing && root.viewMode === "grid"; onActivated: root.stepSelection(-1) }
    Shortcut { sequence: "Right"; enabled: !root.typing && root.viewMode === "grid"; onActivated: root.stepSelection(1) }
    Shortcut { sequence: "Return"; enabled: !root.typing; onActivated: root.enterPressed() }
    Shortcut { sequence: "Enter"; enabled: !root.typing; onActivated: root.enterPressed() }
    Shortcut { sequence: "Backspace"; enabled: !root.typing; onActivated: root.goUp() }
    // Delete acts on the selection; with nothing selected it steps out of the
    // folder, so "delete to go back" works exactly as asked without ever
    // trashing something by accident.
    Shortcut { sequence: "Delete"; enabled: !root.typing; onActivated: root.selIndex >= 0 ? root.trashSelected() : root.goUp() }
    Shortcut { sequence: "Space"; enabled: !root.typing && !root.pickerMode; onActivated: root.showPreview = !root.showPreview }
    Shortcut { sequence: "Alt+Left"; enabled: !root.typing; onActivated: root.goBack() }
    Shortcut { sequence: "Alt+Right"; enabled: !root.typing; onActivated: root.goForward() }
    Shortcut { sequence: "Alt+Up"; enabled: !root.typing; onActivated: root.goUp() }
    Shortcut { sequence: "Home"; enabled: !root.typing; onActivated: root.selectIndex(0) }
    Shortcut { sequence: "End"; enabled: !root.typing && folderModel.count > 0; onActivated: root.selectIndex(folderModel.count - 1) }
    Shortcut { sequence: "PageUp"; enabled: !root.typing; onActivated: root.stepVertical(-4) }
    Shortcut { sequence: "PageDown"; enabled: !root.typing; onActivated: root.stepVertical(4) }
    Shortcut { sequence: "Tab"; enabled: !root.typing; onActivated: root.stepVertical(1) }
    Shortcut { sequence: "Shift+Tab"; enabled: !root.typing; onActivated: root.stepVertical(-1) }
    Shortcut { sequence: "F2"; enabled: !root.typing && root.selIndex >= 0 && !root.pickerMode; onActivated: renameDialog.openWith(root.selectedPath()) }
    // Tabs.
    Shortcut { sequence: "Ctrl+T"; enabled: !root.typing && root.tabsAvailable; onActivated: root.newTab() }
    Shortcut { sequence: "Ctrl+W"; enabled: !root.typing && root.tabsAvailable; onActivated: root.closeTab() }
    Shortcut { sequence: "Ctrl+Tab"; enabled: !root.typing && root.tabsAvailable; onActivated: root.cycleTab(1) }
    Shortcut { sequence: "Ctrl+Shift+Tab"; enabled: !root.typing && root.tabsAvailable; onActivated: root.cycleTab(-1) }
    Shortcut { sequence: "Ctrl+PageDown"; enabled: !root.typing && root.tabsAvailable; onActivated: root.cycleTab(1) }
    Shortcut { sequence: "Ctrl+PageUp"; enabled: !root.typing && root.tabsAvailable; onActivated: root.cycleTab(-1) }
    Shortcut { sequence: "Ctrl+H"; enabled: !root.typing; onActivated: root.showHidden = !root.showHidden }
    Shortcut { sequence: "Ctrl+N"; enabled: !root.typing && !root.pickerMode; onActivated: root.newFolder() }
    Shortcut { sequence: "Ctrl+R"; enabled: !root.typing; onActivated: root.refresh() }
    Shortcut { sequence: "F5"; enabled: !root.typing; onActivated: root.refresh() }
    Shortcut { sequence: "Ctrl+1"; enabled: !root.typing; onActivated: root.viewMode = root.viewMode === "grid" ? "list" : "grid" }
    Shortcut { sequence: "Ctrl+L"; enabled: !root.typing && !root.pickerMode; onActivated: filterField.forceActiveFocus() }
    Shortcut { sequence: "Ctrl+F"; enabled: !root.typing && !root.pickerMode; onActivated: filterField.forceActiveFocus() }
    Shortcut {
        // `/` is the file-manager reflex, but it has to stay typable in a field.
        sequence: "/"
        enabled: !root.typing && !root.pickerMode
        onActivated: filterField.forceActiveFocus()
    }
    // Escape backs out one layer at a time: the context menu first, then the
    // app (or a picker's cancel). One key, never two things at once.
    Shortcut {
        sequence: "Escape"
        enabled: !root.typing
        onActivated: {
            if (root.menuOpen) { root.closeMenu(); return; }
            if (root.pickerMode) { root.pickerCancelled(); return; }
            root.quitRequested();
        }
    }

    // ── Context menu ─────────────────────────────────────────────────────
    // One card, two contents (see folderMenu/entryMenu). It opens AT the
    // pointer, in the surface's own coordinates, and closes on the first press
    // anywhere outside -- including a right-click, so a second right-click
    // simply re-opens it where you are (the same reflex as a browser).
    //
    // The menu is the last child of the root, so it paints over the panes; the
    // press catcher under the card is what makes "click outside to dismiss"
    // work even though the card itself is a plain Rectangle with no input.
    Item {
        id: contextMenu
        anchors.fill: parent
        visible: root.menuOpen
        z: 500

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            // `pressed`, not `clicked`: the menu must be gone before the press
            // reaches whatever is under it, otherwise dismissing the menu also
            // selects a file behind it.
            onPressed: root.closeMenu()
            onWheel: wheel => { root.closeMenu(); wheel.accepted = false; }
        }

        Rectangle {
            id: menuCard
            // Clamped so the card is never half off the surface: a menu that
            // opens past the edge hides exactly the actions that were clicked
            // for.
            readonly property real wantedX: root.menuX
            readonly property real wantedY: root.menuY
            x: Math.max(4, Math.min(wantedX, contextMenu.width - width - 4))
            y: Math.max(4, Math.min(wantedY, contextMenu.height - height - 4))
            width: 262
            height: menuColumn.implicitHeight + 12
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer2
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)

            // Bloom in from the CLICK POINT -- the origin is the menu's own
            // top-left, which is where the pointer was -- and vanish back into
            // it. Asymmetric by design: 200ms out on the emphasized-decelerate
            // curve, 140ms back on the accelerate one, so it feels attached to
            // the right-click rather than to the window.
            scale: root.menuOpen ? 1.0 : 0.94
            opacity: root.menuOpen ? 1.0 : 0.0
            transformOrigin: Item.TopLeft
            Behavior on scale {
                NumberAnimation {
                    duration: root.menuOpen ? 200 : 140
                    easing.type: Easing.Bezier
                    easing.bezierCurve: root.menuOpen
                        ? Appearance.animationCurves.emphasizedDecel
                        : Appearance.animationCurves.emphasizedAccel
                }
            }
            Behavior on opacity {
                NumberAnimation {
                    duration: root.menuOpen ? 200 : 140
                    easing.type: Easing.Bezier
                    easing.bezierCurve: root.menuOpen
                        ? Appearance.animationCurves.emphasizedDecel
                        : Appearance.animationCurves.emphasizedAccel
                }
            }

            ColumnLayout {
                id: menuColumn
                anchors.fill: parent
                anchors.margins: 6
                spacing: 1

                // What the menu is about: the entry's name, or the folder when
                // nothing is targeted. Read-only, but it is the difference
                // between "Delete" and "Delete WHAT".
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 26
                    radius: Appearance.rounding.small
                    color: "transparent"
                    StyledText {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: Text.AlignVCenter
                        text: root.menuTargetName
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideMiddle
                    }
                }

                Repeater {
                    model: root.menuItems

                    // One delegate with three faces (separator / disabled header /
                    // action) rather than a Loader per row: `modelData` has to be
                    // resolvable inside the row, and keeping the row in the
                    // delegate's own scope is what makes that true for all three.
                    delegate: Item {
                        id: menuRow
                        required property var modelData
                        readonly property bool isSep: modelData.separator === true
                        readonly property bool isHeader: !isSep && modelData.header !== undefined
                        Layout.fillWidth: true
                        implicitHeight: isSep ? 9 : (isHeader ? 22 : 30)

                        // ── separator ──
                        Rectangle {
                            visible: menuRow.isSep
                            anchors.fill: parent
                            color: "transparent"
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                height: 1
                                color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
                            }
                        }

                        // ── header (facts about the target, not an action) ──
                        StyledText {
                            visible: menuRow.isHeader
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            text: menuRow.modelData.header ?? ""
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideMiddle
                            verticalAlignment: Text.AlignVCenter
                        }

                        // ── action row ──
                        Rectangle {
                            id: actionRow
                            visible: !menuRow.isSep && !menuRow.isHeader
                            anchors.fill: parent
                            radius: Appearance.rounding.small
                            color: actionHover.hovered
                                ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer2, 0.92)
                                : "transparent"
                            HoverHandler { id: actionHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.runMenu(menuRow.modelData) }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 9
                                MaterialSymbol {
                                    visible: (menuRow.modelData.icon ?? "").length > 0
                                    text: menuRow.modelData.icon ?? ""
                                    iconSize: 16
                                    color: menuRow.modelData.danger
                                        ? Appearance.colors.colError
                                        : (menuRow.modelData.checked ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1)
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: menuRow.modelData.label ?? ""
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: menuRow.modelData.danger
                                        ? Appearance.colors.colError
                                        : Appearance.colors.colOnLayer1
                                    elide: Text.ElideRight
                                }
                                StyledText {
                                    visible: (menuRow.modelData.hint ?? "").length > 0
                                    text: menuRow.modelData.hint ?? ""
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colSubtext
                                }
                                MaterialSymbol {
                                    visible: menuRow.modelData.checked === true
                                    text: "check"
                                    iconSize: 15
                                    color: Appearance.colors.colPrimary
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Rename dialog: minimal, centered, pre-filled, Enter commits ──────
    Rectangle {
        id: renameDialog
        property string targetPath: ""
        function openWith(p) {
            if (!p) return;
            targetPath = p;
            renameField.text = root.shortName(p);
            visible = true;
            renameField.forceActiveFocus();
            renameField.selectAll();
        }
        function commit() {
            root.renameSelected(renameField.text.trim());
            visible = false;
        }
        visible: false
        anchors.centerIn: parent
        width: 320
        height: 108
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer2
        border.width: 1
        border.color: Appearance.colors.colOutlineVariant

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            StyledText {
                text: Translation.tr("Rename")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer2
            }
            TextField {
                id: renameField
                Layout.fillWidth: true
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer1
                background: Rectangle {
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer1
                    border.width: 1
                    border.color: renameField.activeFocus ? Appearance.colors.colPrimary : Appearance.colors.colOutlineVariant
                }
                onAccepted: renameDialog.commit()
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                RippleButton {
                    implicitWidth: 70; implicitHeight: 28
                    buttonRadius: Appearance.rounding.full
                    colBackground: Appearance.colors.colLayer1Hover
                    buttonText: Translation.tr("Cancel")
                    onClicked: renameDialog.visible = false
                }
                RippleButton {
                    implicitWidth: 70; implicitHeight: 28
                    buttonRadius: Appearance.rounding.full
                    colBackground: Appearance.colors.colPrimary
                    buttonText: Translation.tr("Rename")
                    onClicked: renameDialog.commit()
                }
            }
        }
    }
}
