import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

/**
 * The right-hand half of the clipboard popup: the selected entry, in full.
 *
 * The list can only ever show one elided line per row, which is enough to pick
 * something you already recognise and useless for the case that actually sends
 * people hunting through a history -- "which of these screenshots is the one I
 * want", "what was the end of that paste". So the row that is selected (by the
 * keyboard cursor, by hover, or by a click) is shown here properly:
 *
 *     text / link / command   the whole thing, scrollable, wrapped
 *     image                   the picture large, plus its pixel size and weight
 *     file                    name, folder, type, size -- and for a video its
 *                             duration and a frame from one second in
 *
 * NOTHING here is invented from a guess about a clipboard entry: cliphist
 * stores no MIME metadata, so the kind comes from the content (an image is a
 * `[[ binary data ... png 1064x591 ]]` line, a file is a `file://` line) and
 * the file facts come from the file on disk, via `stat`/`ffprobe`. A path that
 * no longer exists says so instead of showing a broken picture.
 */
Rectangle {
    id: pane

    property string entry: ""
    // Emitted when the user presses the pane's own actions. The window owns
    // pasting and closing, so the pane only asks.
    signal pasteRequested()
    signal openRequested(string path)

    readonly property var cliphist: Cliphist

    // ── What the entry is ─────────────────────────────────────────────────
    readonly property int entryId: {
        const id = parseInt(String(pane.entry ?? "").split("\t")[0]);
        return isNaN(id) ? -1 : id;
    }

    // ── The FULL value, decoded ───────────────────────────────────────────
    //
    // `cliphist list` is a PREVIEW list: every entry comes back cut to about a
    // hundred characters and ending in "…". The popup was treating that as the
    // entry itself, so this pane -- the one place meant to show a paste in full
    // -- could only ever show its first line, no matter what the box did. (A
    // paste measured here: `list` gave 109 bytes, `decode` gave 6010.)
    //
    // So the selected entry is decoded (`cliphist decode <id>`), which returns
    // the real content. Only for entries that are not pictures: an image
    // decodes to PNG bytes, and Cliphist.imagePreviewFile already turns that
    // into the picture drawn below.
    property string decodedBody: ""
    readonly property string listBody: Cliphist.entryContent(pane.entry)
    readonly property string body: {
        if (pane.entry === "")
            return "";
        if (!pane.isImage && pane.decodedBody !== "")
            return pane.decodedBody;
        return pane.listBody;
    }
    // One decode per selection, never per repaint, and started from a 0ms timer
    // for the same reason as the file probe: `command` is a binding, and
    // starting the process in the same statement runs the PREVIOUS entry's id.
    function loadFullEntry() {
        pane.decodedBody = "";
        if (pane.entryId < 0 || pane.isImage)
            return;
        decodeTimer.restart();
    }
    Timer {
        id: decodeTimer
        interval: 0
        repeat: false
        onTriggered: {
            decodeProc.running = false;
            decodeProc.running = true;
        }
    }
    Process {
        id: decodeProc
        command: ["cliphist", "decode", String(pane.entryId)]
        stdout: StdioCollector {
            onStreamFinished: pane.decodedBody = String(text ?? "")
        }
    }

    readonly property bool isImage: Cliphist.entryIsImage(pane.entry)

    // A file copy is one `file://` URI per line; the first one is what the
    // pane previews, and the count says when there are more.
    readonly property var fileUris: {
        if (pane.isImage || pane.entry === "")
            return [];
        return pane.body.split("\n").map(line => line.trim()).filter(line => line.startsWith("file://"));
    }
    readonly property string filePath: {
        if (pane.fileUris.length === 0)
            return "";
        const raw = pane.fileUris[0].replace(/^file:\/\//, "");
        try {
            return decodeURIComponent(raw);
        } catch (error) {
            return raw;
        }
    }
    readonly property string fileName: {
        const parts = pane.filePath.split("/");
        return parts.length > 0 ? parts[parts.length - 1] : pane.filePath;
    }
    readonly property string fileFolder: {
        const idx = pane.filePath.lastIndexOf("/");
        return idx > 0 ? pane.filePath.slice(0, idx) : pane.filePath;
    }
    // What is IN that file, from the name alone. cliphist never stores video or
    // audio data -- a copied video is a URI pointing at the file -- so this is
    // the only honest way to call a file "a video".
    readonly property string fileSubKind: {
        const ext = (pane.filePath.toLowerCase().split(".").pop() ?? "");
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

    readonly property string kind: {
        if (pane.entry === "")
            return "none";
        if (pane.isImage)
            return "image";
        if (pane.fileUris.length > 0)
            return pane.fileSubKind;
        if (/^https?:\/\/\S+$/.test(pane.body))
            return "link";
        if (/^[\s$#❯>]*(sudo |find |curl |wget |git |npm |pnpm |yarn |apt |pacman|cd |ls |echo |cat |grep |python3? |pip |cargo |docker |systemctl |hyprctl |qs |bash |sh |chmod |mkdir |rm |mv |cp )/.test(pane.body))
            return "command";
        return "text";
    }

    readonly property string kindLabel: {
        switch (pane.kind) {
            case "image": return Translation.tr("Image");
            case "video": return Translation.tr("Video");
            case "audio": return Translation.tr("Audio");
            case "pdf": return Translation.tr("PDF");
            case "archive": return Translation.tr("Archive");
            case "file": return Translation.tr("File");
            case "link": return Translation.tr("Link");
            case "command": return Translation.tr("Shell command");
            case "text": return Translation.tr("Text");
            default: return "";
        }
    }

    readonly property string kindGlyph: {
        switch (pane.kind) {
            case "image": return "image";
            case "video": return "movie";
            case "audio": return "music_note";
            case "pdf": return "picture_as_pdf";
            case "archive": return "folder_zip";
            case "file": return "draft";
            case "link": return "link";
            case "command": return "chevron_right";
            case "text": return "text_snippet";
            default: return "content_paste";
        }
    }

    // The image's own size, which cliphist writes into the entry itself:
    //   "[[ binary data 985 KiB png 2558x1554 ]]"
    readonly property var imageMeta: {
        const m = /\[\[\s*binary data\s+([^\]]+?)\s+([a-z0-9]+)\s+(\d+)x(\d+)\s*\]\]/.exec(pane.entry);
        if (!m)
            return { size: "", dims: "" };
        return { size: m[1], dims: `${m[3]}×${m[4]}` };
    }

    // THE WHOLE ENTRY, never a cut-down version of it.
    //
    // This used to stop at 6000 characters and say "truncated for the preview",
    // which defeats the one job this pane has: a paste you cannot identify from
    // its first line is exactly the one you open the pane for. The box grows to
    // the height the entry needs instead (see desiredHeight below and the card
    // height in ClipboardListWindow), and anything taller than the screen --
    // which is the only thing that can still be too big -- scrolls in the
    // Flickable it is drawn in.
    readonly property string textBody: {
        if (pane.kind === "image" || pane.fileUris.length > 0)
            return "";
        return pane.body;
    }

    // ── File facts, from the file itself ──────────────────────────────────
    // Asked for whenever the selection changes, not on every repaint: one
    // `stat`/`ffprobe`/`ffmpeg` run per selection, never per frame.
    property string fileBytes: ""
    property int videoSeconds: 0
    property int posterGeneration: 0
    property bool fileMissing: false
    readonly property string posterPath: pane.entryId < 0
        ? "" : Directories.cliphistDecode + "/video-" + pane.entryId + ".png"

    readonly property string humanSize: {
        const bytes = Number(pane.fileBytes);
        if (!isFinite(bytes) || bytes <= 0)
            return "";
        const units = ["B", "KiB", "MiB", "GiB"];
        let value = bytes;
        let unit = 0;
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024;
            unit++;
        }
        return (unit === 0 ? Math.round(value) : value.toFixed(value < 10 ? 1 : 0)) + " " + units[unit];
    }

    readonly property string humanDuration: {
        if (pane.videoSeconds <= 0)
            return "";
        const minutes = Math.floor(pane.videoSeconds / 60);
        const seconds = Math.floor(pane.videoSeconds % 60);
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
    }

    // The one honest line under the title: whatever we actually know.
    readonly property string metaLine: {
        if (pane.kind === "image") {
            const bits = [];
            if (pane.imageMeta.dims) bits.push(pane.imageMeta.dims);
            if (pane.imageMeta.size) bits.push(pane.imageMeta.size);
            return bits.join(" · ");
        }
        if (pane.fileUris.length > 0) {
            const bits = [];
            if (pane.humanDuration) bits.push(pane.humanDuration);
            if (pane.humanSize) bits.push(pane.humanSize);
            if (pane.fileUris.length > 1) bits.push(pane.fileUris.length + " " + Translation.tr("files"));
            return bits.join(" · ");
        }
        const chars = pane.body.length;
        if (chars === 0)
            return "";
        const lines = pane.body.split("\n").length;
        return chars + " " + Translation.tr("characters") + (lines > 1 ? " · " + lines + " " + Translation.tr("lines") : "");
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }

    property string probeScript: ""

    function runProbe() {
        pane.fileBytes = "";
        pane.videoSeconds = 0;
        pane.fileMissing = false;
        if (pane.filePath.length === 0)
            return;
        const path = pane.shellQuote(pane.filePath);
        const poster = pane.shellQuote(pane.posterPath);
        const parts = [];
        parts.push("command -v mkdir >/dev/null 2>&1 && mkdir -p " + pane.shellQuote(Directories.cliphistDecode) + " 2>/dev/null");
        parts.push("if [ ! -e " + path + " ]; then echo MISSING; exit 0; fi");
        parts.push("stat -c %s " + path + " 2>/dev/null || echo ''");
        if (pane.fileSubKind === "video") {
            parts.push("ffprobe -v error -show_entries format=duration -of csv=p=0 " + path + " 2>/dev/null | head -1");
            parts.push("ffmpeg -nostdin -loglevel error -ss 1 -i " + path
                + " -frames:v 1 -vf scale=640:-2 -y " + poster + " >/dev/null 2>&1 || true");
        }
        pane.probeScript = parts.join("\n");
        // Started from a 0ms timer, not here: `command` is a binding on
        // probeScript, and starting the process in the same statement ran the
        // PREVIOUS selection's script (measured: a video whose poster was never
        // written while the pane kept warning that the file did not exist).
        probeTimer.restart();
    }

    Timer {
        id: probeTimer
        interval: 0
        repeat: false
        onTriggered: {
            probe.running = false;
            probe.running = true;
        }
    }

    Process {
        id: probe
        command: ["bash", "-c", pane.probeScript]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = String(text ?? "").split("\n");
                if ((lines[0] ?? "").trim() === "MISSING") {
                    pane.fileMissing = true;
                    pane.fileBytes = "";
                    pane.videoSeconds = 0;
                    return;
                }
                pane.fileBytes = (lines[0] ?? "").trim();
                const seconds = parseFloat((lines[1] ?? "").trim());
                pane.videoSeconds = isFinite(seconds) ? seconds : 0;
                pane.posterGeneration += 1;
            }
        }
    }

    // Deferred by one tick: `filePath` and `body` are derived from `entry`, and a
    // change handler that reads them can still see the OLD entry's values
    // (measured: a 36-character file entry reported an empty path, so the probe
    // returned early every time and no poster was ever written).
    onEntryChanged: {
        Qt.callLater(pane.runProbe);
        Qt.callLater(pane.loadFullEntry);
    }
    // The entry the popup opens with is already selected, so there is no change
    // to react to: the first selection has to be probed here.
    Component.onCompleted: {
        Qt.callLater(pane.runProbe);
        Qt.callLater(pane.loadFullEntry);
    }
    // A file copy that was cut in the list line only knows its real path once
    // the decode lands, so the probe has to run again for it.
    onDecodedBodyChanged: Qt.callLater(pane.runProbe)

    // ── How tall the box wants to be ──────────────────────────────────────
    //
    // The card asks this pane how much room its entry needs and grows to it
    // (bounded by the screen). Without that request a long paste was drawn
    // inside a 460px card no matter what, which is why the pane had to scroll
    // -- and why it used to cut the text at 6000 characters instead.
    //
    // The text height comes from an invisible copy of the same Text at the same
    // width and font, so what is measured is exactly what is drawn. The image
    // height comes from the dimensions cliphist wrote into the entry, scaled to
    // the pane's inner width, so a picture is asked for its true aspect ratio
    // rather than a guess. Both are pure functions of the entry and the pane's
    // width -- never of the card's height -- so this cannot size what sizes it.
    readonly property real innerWidth: Math.max(120, pane.width - 20)
    // The pane's own furniture: the 10px inset top and bottom, the kind row,
    // the gap to the body and the action row.
    readonly property real chromeHeight: 84
    readonly property real bodyDesiredHeight: {
        if (pane.entry === "")
            return 0;
        if (pane.kind === "image") {
            const m = /(\d+)x(\d+)/.exec(pane.entry);
            if (m) {
                const w = Number(m[1]);
                const h = Number(m[2]);
                if (w > 0 && h > 0)
                    return Math.max(100, pane.innerWidth * h / w);
            }
            return 200;
        }
        if (pane.kind === "video" && posterPreview.status === Image.Ready && posterPreview.implicitHeight > 0)
            return Math.max(100, pane.innerWidth * posterPreview.implicitHeight / posterPreview.implicitWidth);
        if (pane.fileUris.length > 0)
            return 150;
        return Math.max(60, textSizer.implicitHeight);
    }
    readonly property real desiredHeight: pane.chromeHeight + pane.bodyDesiredHeight
    // Read by the popup's geometry diagnostic: how much text the box was
    // actually given. `cliphist list` cut it to ~100 characters, so this
    // number is also the check that the decode above happened.
    readonly property int bodyChars: pane.textBody.length
    // Asked of the Layout the pane sits in: this is the whole mechanism.
    Layout.preferredHeight: pane.desiredHeight

    // Measured, never drawn (it is hidden), at the exact width and font of the
    // real body text.
    StyledText {
        id: textSizer
        visible: false
        width: pane.innerWidth
        text: pane.textBody
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        font.pixelSize: Appearance.font.pixelSize.smaller
    }

    // A faint inset of its own, so the preview reads as a separate half of the
    // card instead of as text floating over the list's right edge.
    radius: Appearance.rounding.small
    color: ColorUtils.transparentize(Appearance.colors.colLayer2, 0.72)
    border.width: 1
    border.color: Appearance.colors.colLayer0Border
    clip: true

    // ── Nothing selected ──────────────────────────────────────────────────
    ColumnLayout {
        anchors.centerIn: parent
        width: parent.width - 40
        visible: pane.entry === ""
        spacing: 8

        MaterialSymbol {
            Layout.alignment: Qt.AlignHCenter
            text: "content_paste"
            iconSize: 26
            color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.35)
        }
        StyledText {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: Translation.tr("Select an entry to see it here")
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.2)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        visible: pane.entry !== ""
        spacing: 8

        // ── What this is ──────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            MaterialSymbol {
                text: pane.kindGlyph
                iconSize: 15
                color: Appearance.colors.colPrimary
            }
            StyledText {
                text: pane.kindLabel.toUpperCase()
                font.pixelSize: Appearance.font.pixelSize.smaller
                font.weight: Font.Medium
                font.letterSpacing: 0.6
                color: Appearance.colors.colPrimary
            }
            // A file's own name belongs next to its kind, not only inside the
            // body: for a video the body is the frame, and "VIDEO" on its own
            // says nothing about WHICH video. Elided in the middle so both the
            // start and the extension survive.
            StyledText {
                visible: pane.fileUris.length > 0 && pane.kind !== "image"
                Layout.fillWidth: true
                Layout.maximumWidth: 170
                text: pane.fileMissing
                    ? Translation.tr("file is gone")
                    : pane.fileName
                elide: Text.ElideMiddle
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: pane.fileMissing
                    ? Appearance.colors.colError
                    : Appearance.colors.colOnLayer1
            }
            Item { Layout.fillWidth: true }
            StyledText {
                Layout.maximumWidth: 150
                text: pane.metaLine
                elide: Text.ElideLeft
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
        }

        // ── The thing itself ──────────────────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            // Image: the decoded snapshot, as large as the pane allows.
            StyledImage {
                id: imagePreview
                anchors.fill: parent
                visible: pane.kind === "image"
                fillMode: Image.PreserveAspectFit
                cache: false
                source: pane.kind === "image" ? Cliphist.imagePreviewFile(pane.entry) : ""
            }
            MaterialSymbol {
                anchors.centerIn: parent
                visible: pane.kind === "image" && imagePreview.status !== Image.Ready
                text: "image"
                iconSize: 32
                color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.3)
            }
            // The same reload-on-arrival trick the rows use: the decode batch
            // lands after the popup opened, and a source set before the file
            // existed keeps its miss.
            Connections {
                target: Cliphist
                function onImageDecodeGenerationChanged() {
                    if (pane.kind !== "image") return;
                    const file = Cliphist.imagePreviewFile(pane.entry);
                    imagePreview.source = "";
                    imagePreview.source = file;
                }
            }

            // Video: a frame from one second in, with a play glyph over it so a
            // still picture is never mistaken for a wallpaper copy.
            Item {
                anchors.fill: parent
                visible: pane.kind === "video"

                StyledImage {
                    id: posterPreview
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    cache: false
                    source: pane.kind === "video" ? pane.posterPath : ""
                }
                Connections {
                    target: pane
                    function onPosterGenerationChanged() {
                        if (pane.kind !== "video") return;
                        posterPreview.source = "";
                        posterPreview.source = pane.posterPath;
                    }
                }
                Rectangle {
                    anchors.centerIn: parent
                    visible: posterPreview.status !== Image.Ready
                    width: 56
                    height: 56
                    radius: width / 2
                    color: ColorUtils.transparentize(Appearance.colors.colLayer2, 0.2)
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "movie"
                        iconSize: 26
                        color: Appearance.colors.colSubtext
                    }
                }
            }

            // A file that is not a picture or a video: what it is, where it is,
            // and how big it is.
            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width
                visible: pane.kind !== "image" && pane.kind !== "video"
                    && pane.fileUris.length > 0
                spacing: 6
                MaterialSymbol {
                    Layout.alignment: Qt.AlignHCenter
                    text: pane.kindGlyph
                    iconSize: 34
                    color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.15)
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignHCenter
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    maximumLineCount: 2
                    elide: Text.ElideMiddle
                    text: pane.fileMissing
                        ? Translation.tr("This file is gone")
                        : pane.fileName
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer1
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignHCenter
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    maximumLineCount: 3
                    elide: Text.ElideMiddle
                    text: pane.fileMissing
                        ? pane.filePath
                        : pane.fileFolder
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
            }

            // Text, a link, a shell command: the whole value, wrapped and
            // scrollable rather than cut to four lines.
            Flickable {
                id: textFlick
                anchors.fill: parent
                visible: pane.kind !== "image" && pane.kind !== "video"
                    && pane.fileUris.length === 0
                contentWidth: width
                contentHeight: textColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: textColumn
                    width: textFlick.width
                    spacing: 6

                    StyledText {
                        Layout.fillWidth: true
                        text: pane.textBody
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer1
                        linkColor: Appearance.colors.colPrimary
                    }
                }
            }
        }

        // ── Actions ───────────────────────────────────────────────────────
        RowLayout {
            id: actionRow
            Layout.fillWidth: true
            spacing: 6

            // Filled with the primary tone on purpose: the default RippleButton
            // background is fully transparent, and the label below is drawn in
            // colOnPrimary -- near-black -- so on this dark card the button was
            // there and completely unreadable (measured by screenshot).
            RippleButton {
                id: pasteButton
                implicitWidth: 96
                implicitHeight: 28
                buttonRadius: Appearance.rounding.small
                colBackground: Appearance.colors.colPrimary
                colBackgroundHover: Appearance.colors.colPrimaryHover
                onClicked: pane.pasteRequested()
                contentItem: RowLayout {
                    anchors.centerIn: parent
                    spacing: 5
                    MaterialSymbol {
                        text: "content_paste_go"
                        iconSize: 14
                        color: Appearance.colors.colOnPrimary
                    }
                    StyledText {
                        text: Translation.tr("Paste")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnPrimary
                    }
                }
                StyledToolTip {
                    text: Translation.tr("Paste this entry — Return does the same")
                }
            }

            RippleButton {
                visible: pane.fileUris.length > 0 && !pane.fileMissing
                implicitWidth: 92
                implicitHeight: 28
                buttonRadius: Appearance.rounding.small
                colBackground: Appearance.colors.colLayer2
                colBackgroundHover: Appearance.colors.colLayer2Hover
                onClicked: pane.openRequested(pane.filePath)
                contentItem: RowLayout {
                    anchors.centerIn: parent
                    spacing: 5
                    MaterialSymbol {
                        text: "open_in_new"
                        iconSize: 14
                        color: Appearance.colors.colOnLayer1
                    }
                    StyledText {
                        text: Translation.tr("Open")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer1
                    }
                }
                StyledToolTip {
                    text: pane.filePath
                }
            }

            Item { Layout.fillWidth: true }
        }
    }
}
