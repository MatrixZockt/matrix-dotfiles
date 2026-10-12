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
    property string viewMode: "details"   // "details" | "tiles"
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
                // Is this a file whose CONTENT can be drawn? Only images: a
                // preview of a video or an archive is a lie unless a thumbnailer
                // for it exists, and this desktop has magick and Qt's own image
                // plugins, which is exactly what ThumbnailImage uses.
                preview: !isDir && root.imageExts.indexOf(root.suffixOf(name)) !== -1
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
            else d = (a.size - b.size) || byName(a, b);
            return d * dir;
        });
        root.rawCount = n;
        root.rows = out;
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
    readonly property var textExts: ["txt", "md", "log", "csv", "tsv", "ini", "conf", "cfg", "desktop", "service", "env", "json", "yml", "yaml", "toml", "xml", "html", "css", "sql", "diff", "patch", "srt", "vtt", "nix", "lua", "qml", "js", "ts", "py", "sh", "bash", "zsh", "c", "cpp", "h", "hpp", "rs", "go", "java", "php", "rb", "pl", "make", "mk", "gitignore", "editorconfig"]
    readonly property var appExts: ["desktop", "appimage", "exe", "msi"]

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
        if (root.hasExt(name, root.codeExts)) return Translation.tr("Code");
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
        if (root.codeExts.indexOf(s) !== -1) return "code";
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
        if (mode === "column-widths") {
            // A broken preference is not an error: the defaults are right there.
            try {
                const parsed = JSON.parse(String(shellProc.output ?? "").trim() || "{}");
                if (parsed && typeof parsed === "object")
                    root.columnWidths = parsed;
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
        if (mode === "open" && code !== 0) {
            root.statusNote = "";
            root.notify(Translation.tr("Could not open"), root.firstLine(shellProc.output) || root.baseName(payload), true);
            return;
        }
        if (mode === "mkdir" || mode === "touch") {
            root.refresh();
            root.pendingSelectName = root.baseName(payload);
            root.pendingRenameOnCreate = (mode === "mkdir");
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
            root.checkMtpContents(root.mtpDeviceByName(payload));
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
        if (mode === "mtp-contents") {
            const d = root.mtpDeviceByName(payload);
            const dir = d ? root.mtpMountPoint(d) : String(payload ?? "");
            if (String(shellProc.output ?? "").trim().length > 0) {
                root.statusNote = "";
                root.markMtpAnswering(dir);
                root.navigateTo(dir);
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
    // selected -- and, for a folder, straight into Rename, which is exactly
    // the sequence Explorer puts you in.
    property string pendingSelectName: ""
    property bool pendingRenameOnCreate: false
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
                if (root.pendingRenameOnCreate)
                    root.beginRename(root.pathAt(i));
                root.pendingSelectName = "";
                root.pendingRenameOnCreate = false;
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
            root.sh("$HOME/.local/bin/install-appimage " + root.shq(p)
                + " && notify-send -a 'Files' -i application-x-executable 'AppImage installed'"
                + " \"$(basename -- " + root.shq(p) + ") — added to the app menu\""
                + " || notify-send -a 'Files' 'AppImage install failed' 'see journalctl --user -xe' -u critical",
                "appimage", p);
            return;
        }
        root.sh("gio open " + root.shq(p), "open", p);
    }
    // The double-click. WINDOW MODE opens; PICKER MODE does not.
    //
    // This is the one behaviour deliberately not mirroring Explorer: inside a
    // file dialog a double-click on a folder that navigated would fight the
    // button the dialog is actually asking about, and a double-click on a file
    // would answer a question the user has not been asked yet. So in picker
    // mode a double-click is only a selection.
    function activate(i) {
        if (i < 0 || i >= root.rows.length)
            return;
        if (root.pickerMode) {
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
    // `mtpRetried` is the one-shot budget for the automatic retry, so a phone
    // that stays locked cannot turn into a remount loop.
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
        const devices = [];
        for (const raw of String(text ?? "").split("\n")) {
            const line = raw.trim();
            if (line.startsWith("mounts|")) {
                const dir = line.slice(7).trim();
                if (dir.length > 0) mounts[dir] = true;
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
        // one-shot retry budget is renewed here -- and only here, by a person.
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
    function checkMtpContents(d) {
        const dir = root.mtpMountPoint(d);
        root.sh("ls -A " + root.shq(dir) + " 2>/dev/null | head -n 1", "mtp-contents", dir);
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
        root.sh("fusermount3 -u " + root.shq(dir) + " >/dev/null 2>&1 || fusermount -u "
            + root.shq(dir) + " >/dev/null 2>&1 || umount " + root.shq(dir) + " >/dev/null 2>&1; "
            + "sleep 1; mkdir -p " + root.shq(dir) + " && aft-mtp-mount " + root.shq(dir) + " 2>&1",
            "mtp-mount", d.name);
    }
    // One automatic try, a few seconds after the first silent answer: the hand
    // that plugs a phone in unlocks it right after, and the tap on the phone's
    // own prompt lands seconds later. Anything more than one is a device being
    // argued with; a person pressing Mount or the row again renews the budget.
    function scheduleMtpRetry(d) {
        if (!d) return;
        const dir = root.mtpMountPoint(d);
        if (root.mtpRetried[dir]) return;
        root.mtpRetried = Object.assign({}, root.mtpRetried, { [dir]: true });
        mtpRetryTimer.dir = dir;
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
    function uniqueName(dir, base) {
        // "New folder (2)", the way Explorer counts, rather than "New folder 2".
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
    function newFolder() {
        root.clearFilterForCreate();
        const target = root.uniqueName(root.currentFolderPath(), Translation.tr("New folder"));
        root.sh("gio mkdir " + root.shq(target) + " 2>&1", "mkdir", target);
    }
    function newFile() {
        root.clearFilterForCreate();
        const target = root.uniqueName(root.currentFolderPath(), Translation.tr("New file") + ".txt");
        root.sh("gio touch " + root.shq(target) + " 2>&1", "touch", target);
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
        root.sh("printf %s " + root.shq(p || root.currentFolderPath()) + " | wl-copy");
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
    function previewKindFor(e) {
        if (!e) return "";
        if (e.isDir) return "folder";
        const s = root.suffixOf(e.name);
        if (root.imageExts.indexOf(s) !== -1) return "image";
        if (s === "pdf") return "pdf";
        if (root.videoExts.indexOf(s) !== -1) return "video";
        if (root.audioExts.indexOf(s) !== -1) return "audio";
        if (root.textExts.indexOf(s) !== -1) return "text";
        return "";
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
        // The kinds that draw their own body say nothing here: an image that is
        // on screen does not also need a sentence under it.
        if (root.previewKind === "image" || root.previewKind === "pdf" || root.previewKind === "text")
            return "";
        if (!e)
            return root.selection.length > 1
                ? Translation.tr("Several items selected") : Translation.tr("Select one item to preview it");
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
        if (!root.previewPane || root.pickerMode) return;
        const e = root.previewEntry;
        if (!e) return;
        const kind = root.previewKind;
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
            // is; where it does not, the card still names the file. No frame
            // grabbing: that is a thumbnailer this desktop does not have.
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
        }
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
    // Counted so a check can see that the desktop half actually happened.
    property int clipboardPublished: 0
    readonly property string clipboardType: "text/uri-list"
    function publishClipboard(cut) {
        const list = root.clipboard;
        if (list.length === 0) return;
        const body = root.uriListFor(list.map(c => c.path));
        if (body.length === 0) return;
        root.clipboardPublished++;
        // `printf %s` and not `echo`: the body is a wire format with CRLF in it,
        // and echo is free to eat or add newlines of its own.
        root.sh("printf %s " + root.shq(body) + " | wl-copy --type " + root.clipboardType, "clipboard");
    }
    function copySelection(cut) {
        if (root.selection.length === 0) return;
        root.clipboard = root.selection.map(p => ({ path: p, cut: !!cut }));
        root.publishClipboard(!!cut);
        root.statusNote = root.selection.length + " "
            + (cut ? Translation.tr("item(s) to move") : Translation.tr("item(s) copied"));
    }
    function pasteInto(dir) {
        const dest = String(dir ?? root.currentFolderPath());
        if (root.clipboard.length === 0) return;
        // One shell line per item, each one deciding its own destination name:
        // gio copy/move have no -f (passing it is an instant "Unknown option"
        // and nothing is copied -- which is exactly why Paste used to do
        // nothing at all), and a paste onto an existing name must not clobber
        // it. Explorer's answer to a collision is "Keep both", and so is this:
        // the incoming file lands as "name - copy.ext", or "name - copy (2)"
        // when even that is taken.
        const cmds = root.clipboard.map(c => {
            const verb = c.cut ? "gio move" : "gio copy";
            return `src=${root.shq(c.path)}; dst=${root.shq(dest)}; base=$(basename -- "$src"); target="$dst/$base"; `
                + `if [ -e "$target" ]; then stem="${'$'}{base%.*}"; ext="${'$'}{base##*.}"; `
                + `if [ "$stem" = "$base" ]; then ext=""; else ext=".$ext"; fi; `
                + `target="$dst/$stem - copy$ext"; i=2; while [ -e "$target" ]; do target="$dst/$stem - copy ($i)$ext"; i=$((i+1)); done; fi; `
                + `${verb} "$src" "$target"`;
        });
        // A cut is consumed by the paste; a copy stays on the clipboard, which
        // is what makes "paste three times" work.
        if (root.clipboard.every(c => c.cut)) root.clipboard = [];
        root.statusNote = Translation.tr("Pasting") + "…";
        root.sh(cmds.join("; ") + " 2>&1", "paste", dest);
    }

    // ── Menus ───────────────────────────────────────────────────────────
    // One list feeds the context menu, the command bar's Sort/View popover and
    // the IPC probe: one place to add an action, one place that can run it.
    property var menuItems: []
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
    function folderMenu() {
        return [
            { id: "newFolder", label: Translation.tr("New folder"), icon: "create_new_folder", enabled: true },
            { id: "newFile", label: Translation.tr("New file"), icon: "note_add", enabled: true },
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
            { id: "openTab", label: Translation.tr("Open in new tab"), icon: "tab", enabled: isDir && root.tabsAvailable },
            root.sep(),
            { id: "cut", label: Translation.tr("Cut"), icon: "content_cut", enabled: true },
            { id: "copy", label: Translation.tr("Copy"), icon: "content_copy", enabled: true },
            { id: "pasteInto", label: Translation.tr("Paste into folder"), icon: "content_paste", enabled: isDir && root.clipboard.length > 0 },
            { id: "rename", label: Translation.tr("Rename"), icon: "edit", enabled: true },
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
    function openMenu(x, y, target) {
        root.menuTarget = String(target ?? "");
        const vol = root.volumeByPath(root.menuTarget);
        if (vol)
            root.menuItems = root.deviceMenu(vol);
        else if (root.menuTarget === "sort:")
            root.menuItems = root.sortMenuItems();
        else if (root.menuTarget.length > 0 && root.menuTarget !== root.thisPc)
            root.menuItems = root.entryMenu(root.menuTarget);
        else
            root.menuItems = root.folderMenu();
        root.menuX = Number(x ?? 0);
        root.menuY = Number(y ?? 0);
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
        case "open": if (target) root.openEntry(root.indexOfPath(target)); break;
        case "openTab": if (target) root.newTab(target); break;
        case "newTab": if (target) root.newTab(target); break;
        case "newWindowTab": root.newTab(""); break;
        case "newFolder": root.newFolder(); break;
        case "newFile": root.newFile(); break;
        case "paste": root.pasteInto(root.currentFolderPath()); break;
        case "pasteInto": if (target) root.pasteInto(target); break;
        case "selectAll": root.selectAll(); break;
        case "viewDetails": root.viewMode = "details"; break;
        case "viewTiles": root.viewMode = "tiles"; break;
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
        case "trash": root.trashItems(target ? [target] : root.selection); break;
        case "delete": root.deleteItems(target ? [target] : root.selection); break;
        case "copyPath": root.copyPath(target || root.currentFolderPath()); break;
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

    // ── Rename / delete-confirm / properties state ──────────────────────
    property bool renaming: false
    property string renamePath: ""
    property string renameDraft: ""
    function beginRename(p) {
        if (!p) return;
        root.renamePath = String(p);
        root.renameDraft = root.baseName(p);
        root.renaming = true;
        Qt.callLater(() => { renameField.forceActiveFocus(); renameField.selectAll(); });
    }
    function commitRename() {
        const target = root.renamePath;
        const draft = root.renameDraft;
        root.renaming = false;
        root.renamePath = "";
        root.renameDraft = "";
        keyLayer.forceActiveFocus();
        root.renameItem(target, draft);
    }
    function cancelRename() {
        root.renaming = false;
        root.renamePath = "";
        root.renameDraft = "";
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

    // ── Picker result ───────────────────────────────────────────────────
    readonly property string actionLabel:
        root.pickerOp === "save" ? Translation.tr("Save")
        : (root.pickerDirectory ? Translation.tr("Select folder") : Translation.tr("Open"))
    readonly property bool pickerCanConfirm:
        root.pickerOp === "save" ? true
        : (root.pickerDirectory ? root.folderPath.length > 0 : root.selection.length > 0)
    function pickerConfirm() {
        if (!root.pickerMode) return;
        if (root.pickerOp === "save") {
            const name = String(saveName.text ?? "").trim();
            if (name.length === 0) return;
            root.pickerAccepted([root.fileUri(root.currentFolderPath() + "/" + name)]);
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
        if (area === "toolbar" || area === "address" || area === "search" || area === "status")
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
    function loadColumnWidths() {
        root.sh("cat " + root.shq(root.columnWidthsPath) + " 2>/dev/null", "column-widths");
    }
    function saveColumnWidths() {
        const path = CF.FileUtils.trimFileProtocol(root.columnWidthsPath);
        const payload = JSON.stringify({ date: root.colDate, type: root.colType, size: root.colSize });
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
    readonly property int previewPaneWidth: 300
    readonly property int previewStackHeight: 320
    readonly property bool previewBelow: {
        const body = root.width - (root.showNav ? root.navWidth + 18 : 12);
        // 400 px of file list is the floor: below that the four columns of
        // details stop being columns and start being a smear, at which point the
        // preview is worth more underneath the list than beside it. The default
        // window (1080) keeps its preview on the right; a half-screen window on
        // a laptop does not, which is the case this was asked for.
        return body < root.previewPaneWidth + 400;
    }
    readonly property int commandBarHeight: 40
    readonly property int addressBarHeight: 38
    readonly property int statusBarHeight: 26

    // ── The window ──────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Command bar ─────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            id: commandBar
            Layout.preferredHeight: visible ? root.commandBarHeight : 0
            visible: !root.pickerMode
            color: "transparent"
            FocusRing { area: "toolbar" }
            RowLayout {
                id: commandRow
                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                spacing: 2

                IconButton { symbol: "create_new_folder"; tip: Translation.tr("New folder"); onActivated: root.newFolder() }
                IconButton { symbol: "content_cut"; tip: Translation.tr("Cut"); enabled: root.hasSelection; onActivated: root.copySelection(true) }
                IconButton { symbol: "content_copy"; tip: Translation.tr("Copy"); enabled: root.hasSelection; onActivated: root.copySelection(false) }
                IconButton {
                    symbol: "content_paste"
                    tip: Translation.tr("Paste")
                    enabled: root.clipboard.length > 0
                    onActivated: root.pasteInto(root.currentFolderPath())
                }
                IconButton {
                    symbol: "edit"
                    tip: Translation.tr("Rename")
                    enabled: root.selection.length === 1
                    onActivated: root.beginRename(root.selection[0])
                }
                IconButton { symbol: "delete"; tip: Translation.tr("Delete"); enabled: root.hasSelection; onActivated: root.trashItems(root.selection) }
                IconButton { symbol: "refresh"; tip: Translation.tr("Refresh"); onActivated: root.refresh() }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 20; color: Appearance.colors.colOutlineVariant }
                IconButton {
                    id: sortBtn
                    symbol: "sort"
                    tip: Translation.tr("Sort")
                    onActivated: (px, py) => {
                        const p = sortBtn.mapToItem(root, px, py);
                        root.openMenu(p.x, p.y + 6, "sort:");
                    }
                }
                IconButton {
                    symbol: root.viewMode === "details" ? "grid_view" : "list"
                    tip: root.viewMode === "details" ? Translation.tr("Tiles view") : Translation.tr("Details view")
                    onActivated: root.viewMode = root.viewMode === "details" ? "tiles" : "details"
                }
                IconButton {
                    symbol: root.previewPane ? "side_navigation" : "preview"
                    tip: root.previewPane ? Translation.tr("Hide the preview pane") : Translation.tr("Show a preview of the selected file")
                    active: root.previewPane
                    onActivated: root.previewPane = !root.previewPane
                }
                IconButton {
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
                            StyledText {
                                id: tabText
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 26
                                text: root.tabLabel(modelData)
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colOnLayer0
                                elide: Text.ElideMiddle
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
                IconButton { symbol: "add"; tip: Translation.tr("New tab"); visible: root.tabsAvailable; onActivated: root.newTab("") }
            }
        }

        // ── Address bar ────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            id: addressBar
            Layout.preferredHeight: root.addressBarHeight
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            radius: Appearance.rounding.small
            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.55)
            FocusRing { area: "address" }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 6
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
                        crumbMetrics.text = String(label ?? "");
                        return Math.ceil(crumbMetrics.advanceWidth) + 16 + crumbChevron;
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
                                    color: crumbHover.containsMouse
                                        ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.86)
                                        : "transparent"
                                    StyledText {
                                        id: crumbText
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colOnLayer1
                                    }
                                    MouseArea {
                                        id: crumbHover
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.navigateTo(modelData.path)
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
                    FocusRing { area: "list" }

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
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: root.volumeLabel(modelData)
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            color: Appearance.colors.colOnLayer1
                                            elide: Text.ElideRight
                                        }
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: root.volumeSubtitle(modelData)
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            color: Appearance.colors.colSubtext
                                            elide: Text.ElideRight
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
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 0
                                HeaderCell { Layout.fillWidth: true; label: Translation.tr("Name"); field: 0 }
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
                                required property int index
                                required property var modelData

                                width: detailsView.width
                                height: root.rowH
                                color: root.isSelected(modelData.path)
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.72)
                                    : (rowHover.containsMouse
                                        ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9) : "transparent")
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 0
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        MaterialSymbol {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: modelData.icon
                                            iconSize: 18
                                            color: modelData.isDir ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                                        }
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: root.displayName(modelData.name, modelData.isDir)
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: Appearance.colors.colOnLayer0
                                            elide: Text.ElideRight
                                        }
                                    }
                                    StyledText {
                                        Layout.preferredWidth: root.colDate
                                        // Clear of the 1px grab-divider at this
                                        // column's left edge: the two used to
                                        // touch, which read as the date being
                                        // part of the divider rather than a
                                        // column of its own. Same inset the
                                        // header label uses, so the two line up.
                                        Layout.leftMargin: 8
                                        text: root.fmtTime(modelData.modified)
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                    }
                                    StyledText {
                                        Layout.preferredWidth: root.colType
                                        Layout.leftMargin: 8
                                        text: modelData.kind
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        Layout.preferredWidth: root.colSize
                                        horizontalAlignment: Text.AlignRight
                                        text: root.fmtSize(modelData.size, modelData.isDir)
                                        font.family: Appearance.font.family.numbers
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                    }
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
                                    // Automatic means Qt runs the drag from the
                                    // press-and-move itself -- there is no ghost
                                    // image to chase and no window to create, and
                                    // on Wayland that is the only shape that
                                    // works (the compositor owns the drag).
                                    property bool draggingOut: false
                                    Drag.dragType: Drag.Automatic
                                    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
                                    Drag.mimeData: ({ [root.clipboardType]: root.dragUriListFor(modelData.path) })
                                    Drag.hotSpot: Qt.point(14, 14)
                                    Drag.onDragStarted: draggingOut = true
                                    Drag.onDragFinished: draggingOut = false
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
                            }
                        }

                        // Tiles.
                        GridView {
                            id: tilesView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: !root.atThisPc && root.viewMode === "tiles" && root.rows.length > 0
                            clip: true
                            cellWidth: 132
                            cellHeight: 112
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
                                required property int index
                                required property var modelData

                                width: tilesView.cellWidth - 8
                                height: tilesView.cellHeight - 8
                                radius: Appearance.rounding.small
                                color: root.isSelected(modelData.path)
                                    ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.72)
                                    : (tileHover.containsMouse
                                        ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9) : "transparent")
                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 6
                                    // The picture area. A tile is supposed to show the
                                    // FILE, so an image gets drawn here instead of the
                                    // category icon -- generated through the shared
                                    // thumbnail cache, which is what keeps a folder of
                                    // 40 MP photos from being decoded at full size
                                    // hundreds of times. Everything else (folders,
                                    // video, documents) keeps its icon: a preview of a
                                    // video without a frame grabber is not a preview.
                                    Item {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        MaterialSymbol {
                                            anchors.centerIn: parent
                                            visible: !tilePreview.active || tilePreview.item === null || tilePreview.item.undecodable
                                            text: modelData.icon
                                            iconSize: 40
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
                                                    fillMode: Image.PreserveAspectFit
                                                }
                                            }
                                        }
                                    }
                                    StyledText {
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
                                MouseArea {
                                    id: tileHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    // Same drag as the details row: the payload is
                                    // the file(s), not the picture.
                                    property bool draggingOut: false
                                    Drag.dragType: Drag.Automatic
                                    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
                                    Drag.mimeData: ({ [root.clipboardType]: root.dragUriListFor(modelData.path) })
                                    Drag.hotSpot: Qt.point(14, 14)
                                    Drag.onDragStarted: draggingOut = true
                                    Drag.onDragFinished: draggingOut = false
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
                    Rectangle {
                        id: previewEdgeSide
                        visible: !root.previewBelow
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 1
                        color: Appearance.colors.colOutlineVariant
                    }
                    Rectangle {
                        id: previewEdgeUnder
                        visible: root.previewBelow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: 1
                        color: Appearance.colors.colOutlineVariant
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
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
                        // Behind a Loader, and only for images: a ThumbnailImage
                        // pointed at a .txt spends its budget forking magick on a
                        // file that can never decode, which is exactly the loop the
                        // widget's own latch was written about.
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: visible ? 220 : 0
                            visible: root.previewKind === "image"
                            Loader {
                                id: previewImageLoader
                                anchors.fill: parent
                                active: root.previewKind === "image"
                                sourceComponent: Component {
                                    ThumbnailImage {
                                        id: previewImage
                                        anchors.fill: parent
                                        sourcePath: root.previewEntryPath
                                        fillMode: Image.PreserveAspectFit
                                    }
                                }
                            }
                            MaterialSymbol {
                                anchors.centerIn: parent
                                visible: previewImageLoader.item !== null && previewImageLoader.item.undecodable
                                text: "broken_image"
                                iconSize: 40
                                color: Appearance.m3colors.m3outline
                            }
                        }

                        // A PDF's first page, rendered by poppler at reading
                        // resolution (70 dpi) -- not at print resolution.
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: visible ? 300 : 0
                            visible: root.previewKind === "pdf"
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

                        // Text, as text: the first few KB, monospaced, scrollable.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.previewKind === "text"
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

                        // Everything else, in words: what it is, and how big/how
                        // long. A file that cannot be previewed is still worth
                        // describing, and saying so is better than a blank panel.
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.previewKind === "video" || root.previewKind === "audio"
                                || root.previewKind === "folder" || root.previewKind === ""
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
                            visible: root.previewNote.length > 0
                                && (root.previewKind === "text" || root.previewKind === "pdf")
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
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 46 : 0
            visible: root.pickerMode
            color: "transparent"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 8
                StyledText {
                    visible: root.pickerOp === "save"
                    text: Translation.tr("Name")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledTextInput {
                    id: saveName
                    visible: root.pickerOp === "save"
                    Layout.preferredWidth: 260
                    Layout.preferredHeight: 28
                    verticalAlignment: TextInput.AlignVCenter
                    text: root.pickerName
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.pickerConfirm();
                            event.accepted = true;
                        }
                    }
                }
                Item { Layout.fillWidth: true }
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
                StyledText {
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
                    elide: Text.ElideRight
                }
                StyledText {
                    text: root.storageText
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }
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
        width: 258
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
            radius: Appearance.rounding.normal
            color: Appearance.m3colors.m3surfaceContainer
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        }
        contentItem: ColumnLayout {
            spacing: 10
            StyledText {
                text: Translation.tr("Rename")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
            StyledTextInput {
                id: renameField
                Layout.fillWidth: true
                Layout.preferredHeight: 28
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
                    }
                }
                Keys.onShortcutOverride: event => {
                    if (event.key === Qt.Key_Escape) event.accepted = true;
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                ActionButton { implicitWidth: 96; label: Translation.tr("Cancel"); onActivated: root.cancelRename() }
                ActionButton { implicitWidth: 110; primary: true; label: Translation.tr("Rename"); onActivated: root.commitRename() }
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

    // Arrow keys and Escape live on the pane's key layer, where they belong:
    // a Shortcut for every arrow would fight the search box, and Escape here
    // has to defer to the app-level shortcut that closes the popup -- except
    // when a menu or a dialog is up, which is what the override guards.
    Item {
        id: keyLayer
        anchors.fill: parent
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
            } else if (event.key === Qt.Key_Backspace) { root.goUp(); event.accepted = true;            } else if (event.key === Qt.Key_Escape) {
                if (root.volumePromptKind.length > 0) {
                    root.closeVolumePrompt();
                    event.accepted = true;
                } else if (root.menuOpen) {
                    root.closeMenu();
                    event.accepted = true;
                } else if (root.pickerMode) {
                    root.pickerCancelled();
                    event.accepted = true;
                } else {
                    root.quitRequested();
                    event.accepted = true;
                }
            }
        }
        Keys.onShortcutOverride: event => {
            if (event.key === Qt.Key_Escape && (root.menuOpen || root.renaming || root.editingPath || root.volumePromptKind.length > 0))
                event.accepted = true;
        }
    }

    // ── Inline components ───────────────────────────────────────────────

    // The keyboard's ring. Drawn INSIDE the area it belongs to -- one line per
    // area in the layout, no coordinate math and no z-order guessing -- and it
    // is the only thing that tells the eye where Tab has taken the keyboard.
    component FocusRing: Rectangle {
        id: ring
        property string area: ""
        anchors.fill: parent
        anchors.margins: 1
        radius: Appearance.rounding.small
        color: "transparent"
        // ONE pixel, half-strength, not two at full accent (REQUESTED
        // 2026-10-11: "that weird light line around the pane"). The ring still
        // has to be findable -- it is the only thing that says which pane the
        // keyboard is in -- so it is thinned and dimmed rather than removed:
        // a 1px line in the accent colour reads as a marker, where 2px of it
        // read as a border the app had grown by accident.
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.25)
        visible: root.focusArea === ring.area
        z: 20
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
        color: action.danger
            ? (actionHover.containsMouse
                ? CF.ColorUtils.transparentize(Appearance.colors.colError, 0.7)
                : CF.ColorUtils.transparentize(Appearance.colors.colError, 0.85))
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
                : (action.danger ? Appearance.colors.colOnError : Appearance.colors.colOnLayer0)
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
        color: navRow.keyFocused
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.55)
            : (navRow.active
                ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)
                : (navHover.containsMouse ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88) : "transparent"))
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 6
            spacing: 8
            MaterialSymbol {
                text: navRow.symbol
                iconSize: 17
                color: navRow.active ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
            }
            StyledText {
                Layout.fillWidth: true
                text: navRow.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer0
                elide: Text.ElideRight
            }
        }
        MouseArea {
            id: navHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: navRow.activated()
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
        Layout.fillWidth: true
        implicitHeight: 48
        radius: Appearance.rounding.small
        color: (volume.mountpoint.length > 0 && root.folderPath === volume.mountpoint && !root.atThisPc)
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)
            : (volHover.containsMouse ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88) : "transparent")
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 6
            spacing: 8
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: volume.icon
                iconSize: 18
                color: volume.mountpoint.length > 0
                    ? Appearance.colors.colPrimary : Appearance.m3colors.m3outline
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                StyledText {
                    Layout.fillWidth: true
                    text: root.volumeLabel(volume)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnLayer0
                    elide: Text.ElideRight
                }
                StyledText {
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
                    elide: Text.ElideRight
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
        implicitHeight: 28
        radius: Appearance.rounding.small
        color: headerHover.containsMouse
            ? CF.ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88) : "transparent"
        StyledText {
            anchors.left: header.alignRight ? undefined : parent.left
            anchors.right: header.alignRight ? parent.right : undefined
            // 8, not 4: the header label and the cells under it are the same
            // column, so they clear the divider by the same amount.
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: header.label + (root.sortField === header.field ? (root.sortReversed ? " ↓" : " ↑") : "")
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: root.sortField === header.field
                ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
        }
        MouseArea {
            id: headerHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setSort(header.field)
        }
        // The grab line. ONE pixel of divider, inside a 7px hit area centred on
        // the boundary, so it can be caught without pixel-hunting -- and on top
        // of the sort area, because a press that starts here is a drag and must
        // not also re-sort the list.
        Item {
            id: resizer
            visible: header.resizable
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 4
            anchors.bottomMargin: 4
            x: -3
            width: 7
            property real startWidth: 0
            property real startX: 0
            property bool dragging: false
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 1
                height: parent.height
                color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant,
                    resizer.dragging ? 0 : (resizeArea.containsMouse ? 0.25 : 0.65))
            }
            MouseArea {
                id: resizeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeHorCursor
                onPressed: mouse => {
                    resizer.dragging = true;
                    resizer.startWidth = header.widthValue;
                    resizer.startX = mouse.x;
                }
                onPositionChanged: mouse => {
                    if (!pressed || header.widthSetter === null) return;
                    // MINUS the drag, not plus it. This handle sits on the LEFT
                    // edge of its column, and the fixed columns it belongs to
                    // are pushed to the right by the flexible Name column: a
                    // column that GROWS therefore drags its own left edge --
                    // the handle under the pointer -- to the LEFT. Adding the
                    // delta made the divider run away from the pointer (and at
                    // twice the pointer's speed, since both moved), which is
                    // the "too sensitive, and the wrong way" the columns did.
                    // Subtracting it sends the divider with the pointer: the
                    // column gives up exactly the width the pointer took.
                    header.widthSetter(Math.max(root.colMinWidth,
                        Math.round(resizer.startWidth - (mouse.x - resizer.startX))));
                }
                onReleased: {
                    resizer.dragging = false;
                    root.saveColumnWidths();
                }
                onCanceled: resizer.dragging = false;
            }
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
            headline: root.previewHeadline(),
            subtitle: root.previewSubtitle(),
            page: root.previewPage,
            note: root.previewNote,
            body: root.previewBodyText(),
            textLength: root.previewText.length,
            text: root.previewText.slice(0, 400),
            entryPreviewable: root.previewEntry ? root.previewEntry.preview === true : false
        });
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
    function probeLayout() {
        const pathRight = pathBox.mapToItem(root, pathBox.width, 0).x;
        const searchLeft = searchBox.visible ? searchBox.mapToItem(root, 0, 0).x : -1;
        return JSON.stringify({
            width: root.width,
            height: root.height,
            pathBoxWidth: pathBox.width,
            pathBoxRight: Math.round(pathRight),
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
    function probeColumns() {
        const cells = [];
        if (typeof headerRow !== "undefined" && headerRow) {
            for (let i = 0; i < headerRow.children.length; i++) {
                const c = headerRow.children[i];
                const at = c.mapToItem(root, 0, 0);
                cells.push({
                    label: c.label,
                    x: Math.round(at.x),
                    y: Math.round(at.y),
                    width: Math.round(c.width),
                    height: Math.round(c.height),
                    resizable: c.resizable === true
                });
            }
        }
        return JSON.stringify({
            date: root.colDate,
            type: root.colType,
            size: root.colSize,
            min: root.colMinWidth,
            cells: cells
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
    // What the app has published for other programs to take: the internal list,
    // the mime type, and the exact body it handed to wl-copy. Read by the check
    // suite, which ALSO reads it back off the real clipboard with wl-paste --
    // the difference between "it says it copied" and "another program can
    // paste it".
    function probeClipboard() {
        return JSON.stringify({
            entries: root.clipboard,
            published: root.clipboardPublished,
            type: root.clipboardType,
            payload: root.uriListFor(root.clipboard.map(c => c.path))
        });
    }
    // The payload a drag of this row would carry, for the same reason.
    function probeDragPayload(name) {
        const p = root.currentFolderPath() + "/" + String(name ?? "");
        return root.dragUriListFor(p);
    }

    // ── Bring-up ────────────────────────────────────────────────────────
    Component.onCompleted: {
        root.loadMountNames();
        root.loadColumnWidths();
        root.history = [root.currentFolderPath()];
        root.historyIndex = 0;
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
