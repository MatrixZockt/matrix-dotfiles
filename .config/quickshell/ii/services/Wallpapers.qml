import qs.modules.common
import qs.modules.common.models
import qs.modules.common.functions
import qs.services
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
pragma Singleton
pragma ComponentBehavior: Bound

/**
 * Provides a list of wallpapers and an "apply" action that calls the existing
 * switchwall.sh script. Pretty much a limited file browsing service.
 */
Singleton {
    id: root

    property string thumbgenScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/thumbgen-venv.sh`
    property string generateThumbnailsMagickScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/generate-thumbnails-magick.sh`
    property alias directory: folderModel.folder
    readonly property string effectiveDirectory: FileUtils.trimFileProtocol(folderModel.folder.toString())
    property url defaultFolder: Qt.resolvedUrl(`${Directories.pictures}/Wallpapers`)
    property alias folderModel: folderModel // Expose for direct binding when needed
    property string searchQuery: ""
    readonly property list<string> extensions: [ // TODO: add videos
        "jpg", "jpeg", "png", "webp", "avif", "bmp", "svg"
    ]
    property list<string> wallpapers: [] // List of absolute file paths (without file://)
    readonly property bool thumbnailGenerationRunning: thumbgenProc.running
    property real thumbnailGenerationProgress: 0

    signal changed()
    signal thumbnailGenerated(directory: string)
    signal thumbnailGeneratedFile(filePath: string)

    function load () {} // For forcing initialization
    
    function openFallbackPicker(darkMode = Appearance.m3colors.darkmode) {
        Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", darkMode ? "dark" : "light"]);
    }

    // ── Wallpaper collection ────────────────────────────────────────────
    // The carousel owns its copies: applying a wallpaper from OUTSIDE this
    // folder imports (copies) it here first, so the file picked from
    // ~/Downloads (or anywhere temporary) can be deleted right after --
    // the applied wallpaper, the history entry and the config all point at
    // the shell's own copy, never at the borrowed original.
    readonly property string collectionDir: `${FileUtils.trimFileProtocol(Directories.pictures)}/Wallpapers`

    // ── The live clock wallpaper ────────────────────────────────────────
    //
    // A carousel entry like any other: a file in the collection, with a
    // thumbnail, that the selector lists and the carousel holds in its
    // history. It is not a picture to be DRAWN -- selecting it flips
    // `background.clockWallpaper.enable` on, and ClockWallpaper.qml becomes the
    // desktop -- and it deliberately leaves `background.wallpaperPath` alone,
    // so the palette, the picture behind it and the lock screen are untouched
    // and picking a normal wallpaper afterwards is one click, not a re-theme.
    readonly property string clockWallpaperName: "Clock (live).png"
    readonly property string clockWallpaperPath: `${root.collectionDir}/${root.clockWallpaperName}`
    readonly property bool clockWallpaperActive: Config.options.background.clockWallpaper?.enable ?? false
    readonly property string currentWallpaperPath: Config.options.background.wallpaperPath

    function isClockWallpaper(path): bool {
        if (!path) return false;
        const p = FileUtils.trimFileProtocol(String(path));
        return p === root.clockWallpaperPath || p.split("/").pop() === root.clockWallpaperName;
    }

    function applyClockWallpaper() {
        if (!root.clockWallpaperActive)
            Config.options.background.clockWallpaper.enable = true;
        // Recorded so it takes its place in the carousel like every other pick
        // (newest first), instead of being invisible next time the carousel is
        // opened.
        WallpaperHistory.record(root.clockWallpaperPath);
        root.changed();
    }

    // ANY real picture becoming the wallpaper turns the clock wallpaper off.
    // The shell's own applies do that below, but a wallpaper can also arrive
    // from outside it -- switchwall.sh in a terminal, --random, the fallback
    // picker -- and that pathway only ever shows up as a config change. Without
    // this, picking a picture that way would leave the user on a black screen
    // with a clock on it.
    onCurrentWallpaperPathChanged: {
        if (Config.options.background.clockWallpaper?.enable)
            Config.options.background.clockWallpaper.enable = false;
    }

    function apply(path, darkMode = Appearance.m3colors.darkmode) {
        if (!path || path.length === 0) return;
        if (root.isClockWallpaper(path)) {
            root.applyClockWallpaper();
            return;
        }
        const src = FileUtils.trimFileProtocol(path);
        // Already part of the collection (the selector's own folder, or an
        // imported copy being re-applied): nothing to import.
        if (src === root.collectionDir || src.startsWith(root.collectionDir + "/")) {
            root.applyInternal(src, darkMode);
            return;
        }
        importProc.import_(src, darkMode);
    }

    function applyInternal(path, darkMode = Appearance.m3colors.darkmode) {
        if (!path || path.length === 0) return;
        // The clock entry can reach here from a caller that skipped apply()
        // (the importer, a re-apply of the collection path). It is never handed
        // to switchwall.sh -- there is no image to switch to.
        if (root.isClockWallpaper(path)) {
            root.applyClockWallpaper();
            return;
        }
        // A real picture: the clock wallpaper steps aside.
        if (Config.options.background.clockWallpaper?.enable)
            Config.options.background.clockWallpaper.enable = false;
        Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", darkMode ? "dark" : "light", "--image", path]);
        // Take the decision here as well, instead of only letting switchwall.sh
        // write it into the config from the outside. Two reasons:
        //   * the desktop must follow the moment you pick a wallpaper, not when
        //     a separate process' jq write happens to land and be noticed;
        //   * the shell writes this same config file whenever any option
        //     changes, so if its in-memory value were still the OLD path, that
        //     write would put the old path back -- the "it only changes after a
        //     reload" symptom, except the reload would then show the old one.
        if (Config.options.background.wallpaperPath !== path)
            Config.options.background.wallpaperPath = path;
        // History: every applied image becomes a carousel entry (the desktop
        // widget and the Appearance page read it). switchwall.sh also writes
        // the config, but the history records the APPLY action itself so the
        // ordering is usage-based, newest first.
        WallpaperHistory.record(path);
        // With a separate light/dark wallpaper turned on, remember this picture
        // against the theme it was chosen for. Picking a wallpaper is then two
        // independent decisions instead of one that overwrites the other.
        if (Config.options.background.separateThemeWallpaper) {
            if (darkMode)
                Config.options.background.wallpaperPathDark = path;
            else
                Config.options.background.wallpaperPathLight = path;
        }
        // Re-read the generated palette at once too. switchwall.sh regenerates
        // it in its own time (and on a KDE box it even throws on a step that
        // does not exist here), so waiting for the file watch to notice is what
        // made the desktop look like it needed a reload.
        MaterialThemeLoader.reapplyTheme();
        root.changed()
    }

    // The importer. Copies $1 (the picked file) into $2 (the collection),
    // keeping the original's mtime (thumbnails and the selector's "newest
    // first" sort stay honest about when the picture was made, not when it
    // was copied). Same-name copies are kept instead of duplicated when the
    // content is identical; a same-name DIFFERENT image gets " (2)" before
    // the extension, never an overwrite. Prints the final path on stdout;
    // exit 1 only when the copy itself failed.
    Process {
        id: importProc
        property string src: ""
        property bool darkMode: true
        function import_(source, darkMode) {
            importProc.src = source;
            importProc.darkMode = darkMode;
            // $1 = source file, $2 = destination folder -- as ARGUMENTS, not
            // interpolated: a quote or space in a path must not reach bash's
            // parser.
            exec(["bash", "-c",
                'mkdir -p "$2" || exit 1\n'
                + 'base=$(basename "$1")\n'
                + 'name="${base%.*}"; ext="${base##*.}"\n'
                + 'dest="$2/$base"; i=2\n'
                + 'while [ -e "$dest" ]; do\n'
                + '  cmp -s "$1" "$dest" && break\n'
                + '  dest="$2/$name ($i).$ext"\n'
                + '  i=$((i+1))\n'
                + 'done\n'
                + 'if [ ! -e "$dest" ]; then cp --preserve=timestamps "$1" "$dest" || exit 1; fi\n'
                + 'printf %s "$dest"\n',
                "wallpaper-import", importProc.src, root.collectionDir])
        }
        stdout: StdioCollector { id: importCollector }
        onExited: (exitCode, exitStatus) => {
            const dest = importCollector.text.trim();
            if (exitCode === 0 && dest.length > 0)
                root.applyInternal(dest, importProc.darkMode);
            else {
                // Import failed (permissions, disk full): apply the original
                // anyway -- today's behaviour is better than a dead click.
                console.log("[Wallpapers] import into collection failed for", importProc.src);
                root.applyInternal(importProc.src, importProc.darkMode);
            }
        }
    }

    // Switch the light/dark theme. This is the one place that decides how it is
    // done: with a separate light/dark wallpaper turned on it brings that theme's
    // own wallpaper back as it regenerates the palette, so the two wallpapers
    // behave like two themes instead of two unrelated pictures.
    function setTheme(darkMode) {
        const separate = Config.options.background.separateThemeWallpaper;
        const slot = darkMode
            ? Config.options.background.wallpaperPathDark
            : Config.options.background.wallpaperPathLight;
        if (separate && slot && slot.length > 0)
            Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", darkMode ? "dark" : "light", "--image", slot]);
        else
            Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", darkMode ? "dark" : "light", "--noswitch"]);
    }

    Process {
        id: selectProc
        property string filePath: ""
        property bool darkMode: Appearance.m3colors.darkmode
        function select(filePath, darkMode = Appearance.m3colors.darkmode) {
            selectProc.filePath = filePath
            selectProc.darkMode = darkMode
            selectProc.exec(["test", "-d", FileUtils.trimFileProtocol(filePath)])
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                setDirectory(selectProc.filePath);
                return;
            }
            root.apply(selectProc.filePath, selectProc.darkMode);
        }
    }

    function select(filePath, darkMode = Appearance.m3colors.darkmode) {
        selectProc.select(filePath, darkMode);
    }

    function randomFromCurrentFolder(darkMode = Appearance.m3colors.darkmode) {
        if (folderModel.count === 0) return;
        const randomIndex = Math.floor(Math.random() * folderModel.count);
        const filePath = folderModel.get(randomIndex, "filePath");
        print("Randomly selected wallpaper:", filePath);
        root.select(filePath, darkMode);
    }

    Process {
        id: validateDirProc
        property string nicePath: ""
        function setDirectoryIfValid(path) {
            validateDirProc.nicePath = FileUtils.trimFileProtocol(path).replace(/\/+$/, "")
            if (/^\/*$/.test(validateDirProc.nicePath)) validateDirProc.nicePath = "/";
            validateDirProc.exec([
                "bash", "-c",
                `if [ -d "${validateDirProc.nicePath}" ]; then echo dir; elif [ -f "${validateDirProc.nicePath}" ]; then echo file; else echo invalid; fi`
            ])
        }
        stdout: StdioCollector {
            onStreamFinished: {
                    root.directory = Qt.resolvedUrl(validateDirProc.nicePath)
                const result = text.trim()
                if (result === "dir") {
                } else if (result === "file") {
                    root.directory = Qt.resolvedUrl(FileUtils.parentDirectory(validateDirProc.nicePath))
                } else {
                    // Ignore
                }
            }
        }
    }
    function setDirectory(path) {
        validateDirProc.setDirectoryIfValid(path)
    }
    function navigateUp() {
        folderModel.navigateUp()
    }
    function navigateBack() {
        folderModel.navigateBack()
    }
    function navigateForward() {
        folderModel.navigateForward()
    }

    // Folder model
    FolderListModelWithHistory {
        id: folderModel
        folder: Qt.resolvedUrl(root.defaultFolder)
        caseSensitive: false
        nameFilters: root.extensions.map(ext => `*${searchQuery.split(" ").filter(s => s.length > 0).map(s => `*${s}*`)}*.${ext}`)
        showDirs: true
        showDotAndDotDot: false
        showOnlyReadable: true
        sortField: FolderListModel.Time
        sortReversed: false
        onCountChanged: {
            root.wallpapers = []
            for (let i = 0; i < folderModel.count; i++) {
                const path = folderModel.get(i, "filePath") || FileUtils.trimFileProtocol(folderModel.get(i, "fileURL"))
                if (path && path.length) root.wallpapers.push(path)
            }
        }
    }

    // Thumbnail generation
    function generateThumbnail(size: string) {
        if (!["normal", "large", "x-large", "xx-large"].includes(size)) throw new Error("Invalid thumbnail size");
        thumbgenProc.directory = root.directory
        thumbgenProc.running = false
        thumbgenProc.command = [
            "bash", "-c",
            `${thumbgenScriptPath} --size ${size} --machine_progress -d ${FileUtils.trimFileProtocol(root.directory)} || ${generateThumbnailsMagickScriptPath} --size ${size} -d ${FileUtils.trimFileProtocol(root.directory)}`,
        ]
        // console.log("[Wallpapers] Updating thumbnails with command ", thumbgenProc.command.join(" "))
        root.thumbnailGenerationProgress = 0
        thumbgenProc.running = true
    }
    Process {
        id: thumbgenProc
        property string directory
        stdout: SplitParser {
            onRead: data => {
                // print("thumb gen proc:", data)
                let match = data.match(/PROGRESS (\d+)\/(\d+)/)
                if (match) {
                    const completed = parseInt(match[1])
                    const total = parseInt(match[2])
                    root.thumbnailGenerationProgress = completed / total
                }
                match = data.match(/FILE (.+)/)
                if (match) {
                    const filePath = match[1]
                    root.thumbnailGeneratedFile(filePath)
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            // print("[Wallpapers] Thumbnail generation completed with exit code", exitCode)
            root.thumbnailGenerated(thumbgenProc.directory)
        }
    }

    IpcHandler {
        target: "wallpapers"

        function apply(path: string): void {
            root.apply(path);
        }
    }
}
