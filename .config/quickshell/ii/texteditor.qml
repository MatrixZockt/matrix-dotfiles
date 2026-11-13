// Text Editor -- the desktop's plain-text editor, the job Windows Notepad does.
//
// WHAT IT IS. A real window, an ordinary xdg toplevel, in its own process: it
// tiles, it takes SUPER+Q, the compositor closes it, and a second launch is a
// second editor. The files here are small text files, and this is the answer to
// "open it and change one line" -- not an IDE (code-oss exists for that), and
// deliberately without syntax highlighting, tabs or a project tree, because
// every one of those is a way for a Notepad to stop being instant.
//
// WHAT IT IS PART OF. It is the same family as Files and Settings: the window
// paints the terminal grey (`colTerminalSurfaceSolid`), the toolbar and status
// band are layer-1 surfaces, and the theme is applied IN THIS PROCESS
// (`MaterialThemeLoader.reapplyTheme()`), because a standalone Quickshell
// instance otherwise draws on the stock light palette.
//
// WHAT IT LEARNED FROM REAL NOTEPADS. Find & replace with a match counter
// (Ctrl+F, Esc closes only the bar), a match-case toggle, zoom (Ctrl+= / Ctrl+-
// / Ctrl+0), and insert date & time (F5). Save as decides the format by
// extension: .txt and friends are written as text, .pdf and .html are CONVERTED
// (scripts/system/text-export.py) and leave the document itself untouched -- a
// file named .pdf that contains plain text is a broken file that looks like a
// bug in the next app that opens it.
//
// OPENING AND SAVING go through the SAME file dialog every other app on this
// desktop gets: the Files picker (filemanager-picker.qml), driven over its
// job/result-file protocol exactly like the portal drives it. There is no
// second, private file browser here -- a text editor with its own open dialog
// is an app that has to be learned twice.
//
// SAVING IS ATOMIC. The text goes to a temporary file in the target's own
// directory and is renamed over it. `cat > file` truncates first, so a crash,
// a full disk or a kill during the write would leave an empty file where the
// user's document was; a rename either happens or it does not.
//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

Window {
    id: root

    color: "transparent"
    visible: true
    width: 940
    height: 700
    minimumWidth: 420
    minimumHeight: 300
    title: (root.dirty ? "• " : "") + root.docName + " — " + Translation.tr("Text Editor")

    // ── The document ────────────────────────────────────────────────────
    property string filePath: ""
    // What is on DISK, as far as this window knows. `dirty` is the difference
    // between that and what is on screen, which is why it is one comparison and
    // not a flag somebody has to remember to clear: saving assigns this, undo
    // past the last save makes it true again by itself.
    property string savedText: ""
    readonly property bool dirty: editor.text !== root.savedText
    readonly property string docName: root.filePath.length > 0
        ? String(root.filePath).split("/").pop() : Translation.tr("Untitled")

    property bool wrapLines: true
    property string statusNote: ""
    // Shown when a close is asked for with unsaved text: the close is refused,
    // and the window offers the three answers instead of guessing one.
    property bool askDiscard: false

    // Cursor and counts are pushed, not bound: they are read off the text, and a
    // binding that calls a function tracks nothing.
    property int cursorLine: 1
    property int cursorCol: 1
    property int lineTotal: 1
    property int wordTotal: 0

    // ── Zoom ────────────────────────────────────────────────────────────
    // A multiplier, not a font size: the size it multiplies is the theme's, so
    // a theme change moves the base and keeps the zoom the user chose.
    property real zoom: 1.0
    readonly property int baseFontSize: Appearance.font.pixelSize.small
    function setZoom(next) {
        root.zoom = Math.max(0.6, Math.min(3.0, Math.round(next * 100) / 100));
    }
    function zoomIn() { root.setZoom(root.zoom + 0.1); }
    function zoomOut() { root.setZoom(root.zoom - 0.1); }
    function zoomReset() { root.zoom = 1.0; }

    // ── Find & replace ─────────────────────────────────────────────────
    // Plain, case-optionally-sensitive substring search -- what Notepad's Find
    // does and what people reach for. `findHits` holds the character offset of
    // every match, so the bar can say "3 of 17" and Replace all can work from
    // the same list instead of rescanning a document it is rewriting.
    property bool findOpen: false
    property string findTerm: ""
    property string replaceTerm: ""
    property bool findCaseSensitive: false
    property var findHits: []
    property int findIndex: -1
    // True while Replace all is rewriting the document: the text changes once
    // per match, and each one would otherwise kick off a full rescan of a
    // document that is halfway through being rewritten.
    property bool findBusy: false
    readonly property int findCount: root.findHits.length
    readonly property int findPosition: root.findCount === 0 ? 0 : root.findIndex + 1

    function findFold(text) {
        return root.findCaseSensitive ? String(text) : String(text).toLowerCase();
    }
    function findScan() {
        const term = root.findTerm;
        const hits = [];
        if (term.length > 0) {
            const hay = root.findFold(editor.text);
            const needle = root.findFold(term);
            let at = hay.indexOf(needle);
            while (at !== -1) {
                hits.push(at);
                at = hay.indexOf(needle, at + needle.length);
            }
        }
        root.findHits = hits;
        if (hits.length === 0) {
            root.findIndex = -1;
            return;
        }
        // The match at or after the caret is the one the bar should be "on",
        // so typing in the search box does not jump the view to the top of the
        // document when the caret is halfway down it.
        let index = hits.findIndex(function (hit) { return hit >= editor.cursorPosition; });
        if (index < 0) index = 0;
        root.findIndex = index;
    }
    function findReveal() {
        if (root.findIndex < 0 || root.findIndex >= root.findHits.length) return;
        const start = root.findHits[root.findIndex];
        const end = start + root.findTerm.length;
        editor.cursorPosition = start;
        editor.select(start, end);
        // Scrolling is the page's job, and only when the match is actually out
        // of view -- a search that always re-centres is unusable on a long file.
        const rect = editor.positionToRectangle(start);
        const top = page.contentY;
        const bottom = top + page.height;
        if (rect.y < top + 8)
            page.contentY = Math.max(0, rect.y - 8);
        else if (rect.y + rect.height > bottom - 8)
            page.contentY = rect.y + rect.height - page.height + 8;
    }
    function findJump(delta) {
        const count = root.findHits.length;
        if (count === 0) return;
        root.findIndex = ((root.findIndex + delta) % count + count) % count;
        root.findReveal();
    }
    function openFind() {
        root.findOpen = true;
        // The bar has to be VISIBLE before a field inside it can take focus, so
        // the focus is asked for once the layout has run -- asking in the same
        // frame is the difference between a find bar you can type into and one
        // that looks ready and silently swallows keystrokes.
        Qt.callLater(function () {
            findField.forceActiveFocus();
            findField.selectAll();
        });
        root.findScan();
    }
    function closeFind() {
        root.findOpen = false;
        editor.forceActiveFocus();
    }
    function replaceCurrent() {
        if (root.findTerm.length === 0) return;
        if (root.findHits.length === 0) { root.findScan(); return; }
        const start = root.findHits[root.findIndex];
        const end = start + root.findTerm.length;
        // Replace acts on the match the bar is on, and moves to it first if the
        // selection has drifted -- pressing it twice must not replace twice in
        // the same place, which is what a blind "replace at caret" does.
        if (editor.selectionStart !== start || editor.selectionEnd !== end) {
            root.findReveal();
            return;
        }
        editor.remove(start, end);
        editor.insert(start, root.replaceTerm);
        editor.cursorPosition = start + root.replaceTerm.length;
        root.findScan();
        root.findReveal();
    }
    function replaceEverything() {
        if (root.findTerm.length === 0 || root.findHits.length === 0) return;
        const hits = root.findHits.slice();
        const termLength = root.findTerm.length;
        // Applied through the editor's own edit calls, right to left, for two
        // reasons. Right to left keeps every offset computed above valid as the
        // rewrite proceeds. And going through `remove`/`insert` instead of
        // assigning `text` is what keeps the work on the UNDO STACK: a document
        // rewritten in one assignment cannot be got back with Ctrl+Z, and a
        // replace-all you cannot undo is a replace-all that eats a file.
        root.findBusy = true;
        for (let i = hits.length - 1; i >= 0; i--) {
            editor.remove(hits[i], hits[i] + termLength);
            editor.insert(hits[i], root.replaceTerm);
        }
        root.findBusy = false;
        editor.cursorPosition = hits[0];
        root.statusNote = Translation.tr("Replaced %1").arg(hits.length);
        root.findScan();
    }

    // ── Insert date & time (F5, as in every notepad) ────────────────────
    function insertAtCursor(snippet) {
        const at = editor.cursorPosition;
        editor.insert(at, snippet);
        editor.cursorPosition = at + snippet.length;
    }
    function insertDateTime() {
        root.insertAtCursor(Qt.formatDateTime(new Date(), "hh:mm dd-MM-yyyy"));
    }

    function recount() {
        const text = editor.text;
        root.lineTotal = text.split("\n").length;
        const words = text.trim();
        root.wordTotal = words.length === 0 ? 0 : words.split(/\s+/).length;
        root.updateCursor();
        if (!root.findBusy && root.findOpen && root.findTerm.length > 0)
            root.findScan();
    }
    function updateCursor() {
        const upto = editor.text.substring(0, editor.cursorPosition);
        const lines = upto.split("\n");
        root.cursorLine = lines.length;
        root.cursorCol = lines[lines.length - 1].length + 1;
    }

    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme();
        const start = String(Quickshell.env("II_EDITOR_FILE") ?? "");
        if (start.length > 0)
            root.loadPath(start);
    }

    // ── Reading ─────────────────────────────────────────────────────────
    // `cat`, through a Process, rather than a FileView: the editor has to open
    // the file it was TOLD to open and then never re-read it behind the user's
    // back -- a file watcher that reloads while you are typing is how an editor
    // loses an edit. `cat` also reports failure by exit code, which is what
    // makes "this file has no read permission" sayable instead of an empty
    // document.
    Process {
        id: reader
        property string target: ""
        command: ["bash", "-c", 'cat -- "$1"', "reader", ""]
        stdout: StdioCollector {
            id: readerOut
        }
        onExited: (code, status) => {
            if (code !== 0) {
                // A file that is not there yet is not an error: that is a new
                // document ("save as" into a name that does not exist).
                root.savedText = "";
                editor.text = "";
                root.statusNote = String(readerOut.text ?? "").trim().length > 0
                    ? Translation.tr("Could not read this file") : "";
                return;
            }
            editor.text = String(readerOut.text ?? "");
            root.savedText = editor.text;
            editor.cursorPosition = 0;
            root.statusNote = "";
            root.recount();
        }
    }

    function loadPath(path) {
        const p = String(path ?? "");
        if (p.length === 0) return;
        root.filePath = p;
        reader.target = p;
        reader.command = ["bash", "-c", 'cat -- "$1"', "reader", p];
        reader.running = false;
        reader.running = true;
    }

    // ── Writing ─────────────────────────────────────────────────────────
    // The text arrives on STDIN, never as an argument: a document is not a
    // command line, and quoting megabytes of it into one is how an editor
    // corrupts a file that contains a quote.
    Process {
        id: writer
        stdinEnabled: true
        property string target: ""
        property bool afterSaveAs: false
        // mktemp in the TARGET's directory (same filesystem, so the rename is
        // atomic), copy the old file's mode onto it, then rename over it. A
        // brand-new file gets 0644 -- mktemp's 0600 would make the document
        // unreadable to anything but this user for no reason anyone asked for.
        command: ["bash", "-c",
            't="$1"; d=$(dirname -- "$t"); tmp=$(mktemp -p "$d" .ii-edit-XXXXXX) || exit 1; '
            + 'cat > "$tmp" || { rm -f "$tmp"; exit 1; }; '
            + 'if [ -e "$t" ]; then chmod --reference="$t" "$tmp" 2>/dev/null; else chmod 644 "$tmp"; fi; '
            + 'mv -f -- "$tmp" "$t"', "writer", ""]
        onRunningChanged: {
            if (!writer.running) return;
            writer.write(editor.text);
            writer.stdinEnabled = false;   // end of input, or cat never returns
        }
        onExited: (code, status) => {
            root.statusNote = "";
            if (code !== 0) {
                root.statusNote = Translation.tr("Could not save the file");
                return;
            }
            root.savedText = editor.text;
            root.statusNote = Translation.tr("Saved") + " " + root.docName;
        }
    }

    function saveTo(path) {
        const p = String(path ?? "");
        if (p.length === 0) return;
        // A .pdf or .html file is not a document this editor can keep editing:
        // it is an EXPORT of the text. Writing plain text into a file named
        // .pdf would produce something that opens as an error in every reader,
        // so the format decides which way the bytes go -- and an export leaves
        // the document exactly as it was, path and dirty flag included.
        if (root.formatFor(p) !== "text") {
            root.exportTo(p);
            return;
        }
        root.filePath = p;
        writer.target = p;
        writer.command = ["bash", "-c", writer.command[2], "writer", p];
        writer.stdinEnabled = true;
        writer.running = true;
    }

    // ── Exporting to a real document ────────────────────────────────────
    //
    // The conversion lives in scripts/system/text-export.py, with no
    // dependency on anything that may not be installed: this machine has no
    // cupsfilter, no ps2pdf, no ghostscript, no pandoc and no libreoffice, so
    // the script writes the PDF itself with the base-14 Courier font every
    // reader already has.
    //
    // Save-as decides by extension, so "notes.pdf" and "notes.html" work from
    // the one dialog -- and the Export button in the bar opens that dialog with
    // the PDF name already in it, so the feature is discoverable rather than a
    // trick you have to know.
    property string exportedName: ""
    property string exportedFormat: ""

    function formatFor(path) {
        const p = String(path).toLowerCase();
        if (p.endsWith(".pdf")) return "pdf";
        if (p.endsWith(".html") || p.endsWith(".htm")) return "html";
        return "text";
    }
    function exportTo(path) {
        const p = String(path ?? "");
        if (p.length === 0) return;
        const format = root.formatFor(p);
        if (format === "text") {
            root.saveTo(p);
            return;
        }
        root.exportedName = p.split("/").pop();
        root.exportedFormat = format.toUpperCase();
        root.statusNote = "";
        exportProcess.command = ["bash", "-c",
            'exec python3 "$1" --format "$2" --output "$3" --title "$4"',
            "exporter",
            Quickshell.shellPath("scripts/system/text-export.py"),
            format, p,
            root.filePath.length > 0 ? root.docName : Translation.tr("Untitled")];
        exportProcess.stdinEnabled = true;
        exportProcess.running = false;
        exportProcess.running = true;
    }
    function askExport() {
        root.pickerRequest("export");
    }

    Process {
        id: exportProcess
        stdinEnabled: true
        onRunningChanged: {
            if (!exportProcess.running) return;
            exportProcess.write(editor.text);
            exportProcess.stdinEnabled = false;   // or the converter waits for EOF
        }
        onExited: (code, status) => {
            if (code !== 0) {
                root.statusNote = Translation.tr("Could not export") + " " + root.exportedName;
                return;
            }
            root.statusNote = Translation.tr("Exported") + " " + root.exportedName
                + " · " + root.exportedFormat;
        }
    }
    function save() {
        if (root.filePath.length === 0) {
            root.askSaveAs();
            return;
        }
        root.saveTo(root.filePath);
    }
    function newDocument() {
        // A new document is a DISCARD of the old one, so it asks the same
        // question a close does rather than throwing the text away silently.
        if (root.dirty) {
            root.askDiscard = true;
            return;
        }
        editor.text = "";
        root.savedText = "";
        root.filePath = "";
        root.statusNote = "";
        root.recount();
    }
    function askOpen() {
        root.pickerRequest("open");
    }
    function askSaveAs() {
        root.pickerRequest("save");
    }

    // ── The file dialog: the Files picker, over its own job protocol ─────
    //
    // The portal writes `<token>.json`, starts `filemanager.sh picker <token>`,
    // and reads `<token>.result.json` back. This does the same, for the same
    // reason: the picker is the ONE file dialog on this desktop, and an editor
    // that grew its own would be a second set of sorting, places and drives to
    // keep in step.
    readonly property string portalDir: (Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp") + "/ii-portal"
    readonly property string launcher: Quickshell.shellPath("scripts/launch/filemanager.sh")
    property string pickerToken: ""
    property string pickerKind: ""      // "open" | "save"
    property bool pickerBusy: false

    function pickerRequest(kind) {
        if (root.pickerBusy) return;
        const token = "editor-" + Date.now() + "-" + Math.floor(Math.random() * 9000 + 1000);
        const dir = root.filePath.length > 0
            ? root.filePath.substring(0, root.filePath.lastIndexOf("/"))
            : (String(Quickshell.env("HOME") ?? "/"));
        const wantsName = kind === "save" || kind === "export";
        const suggested = kind === "export"
            ? ((root.filePath.length > 0 ? root.docName : Translation.tr("Untitled")) + ".pdf")
            : (root.filePath.length > 0 ? root.docName : "");
        const job = JSON.stringify({
            op: kind === "open" ? "open" : "save",
            dir: dir.length > 0 ? dir : "/",
            name: wantsName ? suggested : "",
            directory: false
        });
        root.pickerToken = token;
        root.pickerKind = kind;
        root.pickerBusy = true;
        root.statusNote = "";
        jobWriter.command = ["bash", "-c",
            `mkdir -p '${root.portalDir}' && printf '%s' '${job.replace(/'/g, `'\\''`)}' > '${root.portalDir}/${token}.json'`];
        jobWriter.running = false;
        jobWriter.running = true;
    }
    function pickerFinish() {
        root.pickerBusy = false;
        pickerPoll.stop();
        cleanupProc.command = ["bash", "-c",
            `rm -f '${root.portalDir}/${root.pickerToken}.json' '${root.portalDir}/${root.pickerToken}.result.json'`];
        cleanupProc.running = false;
        cleanupProc.running = true;
        root.pickerToken = "";
        root.pickerKind = "";
    }

    Process {
        id: jobWriter
        // The dialog is started only once its job file exists: the picker retries
        // a missing job for two seconds, but starting it after the write is what
        // makes the first load succeed instead of relying on that retry.
        onExited: (code, status) => {
            if (code !== 0) {
                root.pickerBusy = false;
                root.statusNote = Translation.tr("Could not open the file dialog");
                return;
            }
            Quickshell.execDetached(["bash", root.launcher, "picker", root.pickerToken]);
        }
    }
    Process {
        id: cleanupProc
    }
    Process {
        id: resultProbe
        command: ["bash", "-c", "test -f \"$1\" && cat -- \"$1\"", "probe", ""]
        stdout: StdioCollector {
            id: resultOut
        }
        onExited: (code, status) => {
            if (code !== 0 || root.pickerToken.length === 0)
                return;
            const body = String(resultOut.text ?? "").trim();
            if (body.length === 0)
                return;
            let answer = null;
            try { answer = JSON.parse(body); } catch (e) { return; }
            const uri = (answer && answer.uris && answer.uris.length > 0) ? String(answer.uris[0]) : "";
            const kind = root.pickerKind;
            root.pickerFinish();
            if (!answer || answer.cancelled || uri.length === 0)
                return;
            // file:///home/a b/c.txt -> /home/a b/c.txt
            let path = uri.replace(/^file:\/\//, "");
            try { path = decodeURIComponent(path); } catch (e) { /* keep raw */ }
            if (kind === "save")
                root.saveTo(path);
            else if (kind === "export")
                root.exportTo(path);
            else
                root.loadPath(path);
        }
    }
    Timer {
        id: pickerPoll
        interval: 250
        repeat: true
        running: root.pickerBusy && root.pickerToken.length > 0
        onTriggered: {
            resultProbe.command = ["bash", "-c", "test -f \"$1\" && cat -- \"$1\"", "probe",
                `${root.portalDir}/${root.pickerToken}.result.json`];
            resultProbe.running = false;
            resultProbe.running = true;
        }
    }

    // ── Closing ─────────────────────────────────────────────────────────
    function quitNow() {
        // A dialog left open would keep its own process alive with nothing to
        // answer (it polls for the job file this window is about to delete).
        if (root.pickerToken.length > 0) {
            cleanupProc.command = ["bash", "-c",
                `rm -f '${root.portalDir}/${root.pickerToken}.json'`];
            cleanupProc.running = false;
            cleanupProc.running = true;
        }
        Qt.quit();
    }
    onClosing: function(close) {
        if (!root.dirty) {
            close.accepted = true;
            root.quitNow();
            return;
        }
        // Refused, and the window asks: Save / Don't save / Cancel. A close
        // that silently discarded a document is the one thing a text editor
        // must never do.
        close.accepted = false;
        root.askDiscard = true;
    }

    // ── The look ────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colTerminalSurfaceSolid
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
    }

    component ToolButton: Rectangle {
        id: btn

        property string icon: ""
        property string label: ""
        property bool toggled: false
        property string shortcut: ""
        signal activated()

        implicitHeight: 30
        implicitWidth: btnRow.implicitWidth + 20
        radius: Appearance.rounding.small
        color: btnMouse.containsMouse || btn.toggled
            ? Appearance.colors.colLayer1Hover : "transparent"
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        RowLayout {
            id: btnRow
            anchors.centerIn: parent
            spacing: 6
            MaterialSymbol {
                visible: btn.icon.length > 0
                text: btn.icon
                iconSize: Appearance.font.pixelSize.small
                color: btn.toggled ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
            }
            StyledText {
                visible: btn.label.length > 0
                text: btn.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: btn.toggled ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
            }
        }

        MouseArea {
            id: btnMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated()
        }
        ToolTip {
            visible: btnMouse.containsMouse && btn.shortcut.length > 0
            delay: 700
            text: btn.shortcut
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 1
        spacing: 0

        // ── The command bar ─────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 46
            color: Appearance.colors.colLayer1
            radius: Appearance.rounding.windowRounding

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 4

                ToolButton {
                    icon: "note_add"
                    label: Translation.tr("New")
                    shortcut: "Ctrl+N"
                    onActivated: root.newDocument()
                }
                ToolButton {
                    icon: "folder_open"
                    label: Translation.tr("Open")
                    shortcut: "Ctrl+O"
                    onActivated: root.askOpen()
                }
                ToolButton {
                    icon: "save"
                    label: Translation.tr("Save")
                    shortcut: "Ctrl+S"
                    onActivated: root.save()
                }
                ToolButton {
                    icon: "save_as"
                    label: Translation.tr("Save as")
                    shortcut: "Ctrl+Shift+S"
                    onActivated: root.askSaveAs()
                }
                // Export opens the same dialog with "<name>.pdf" already in
                // it. The extension is the format: type .html there for a web
                // page, or .pdf (the default) for a printable document.
                ToolButton {
                    icon: "picture_as_pdf"
                    label: Translation.tr("Export")
                    shortcut: Translation.tr("Export to PDF (name it .html for a web page)")
                    onActivated: root.askExport()
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 20
                    Layout.leftMargin: 6
                    Layout.rightMargin: 6
                    color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)
                }

                // The wrap toggle, LABELLED and out of the corner.
                //
                // It used to be a bare icon pinned to the right end of the bar,
                // which is the one place a click lands when you click near the
                // top-right of a window to focus it. One of those clicks turns
                // wrapping off, and an unwrapped editor is the report "the text
                // just runs on one row forever" -- there is nothing else in
                // this file that can produce that, measured: prose, a 300-char
                // unbroken token, CRLF, CR-only and a 20,000-char single line all
                // wrap at the page width. So the control is named like every
                // other button here and sits next to the file name instead of
                // under the pointer's arrival point.
                ToolButton {
                    icon: "wrap_text"
                    label: Translation.tr("Wrap")
                    toggled: root.wrapLines
                    shortcut: Translation.tr("Wrap long lines at the window edge")
                    onActivated: root.wrapLines = !root.wrapLines
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 20
                    Layout.leftMargin: 6
                    Layout.rightMargin: 6
                    color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)
                }

                StyledText {
                    Layout.fillWidth: true
                    Layout.leftMargin: 2
                    text: root.docName
                    elide: Text.ElideMiddle
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }

                StyledText {
                    visible: root.statusNote.length > 0
                    text: root.statusNote
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                    Layout.maximumWidth: 260
                }

            }
        }

        // ── Find & replace ──────────────────────────────────────────────
        // In the window, between the bar and the page, and only while it is
        // open -- a floating panel would sit on top of the line being searched
        // for, which is the one thing a find bar must never do.
        Rectangle {
            visible: root.findOpen
            Layout.fillWidth: true
            implicitHeight: visible ? 48 : 0
            color: Appearance.colors.colLayer1

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 6

                ToolbarTextField {
                    id: findField
                    // The two fields absorb all the slack between them, and the
                    // close button at the end of the row stays pinned right
                    // because of it. A spacer item here instead of that would
                    // take a third share and squeeze both fields to a sliver.
                    Layout.fillWidth: true
                    Layout.minimumWidth: 130
                    Layout.maximumWidth: 340
                    Layout.fillHeight: false
                    Layout.preferredHeight: 32
                    colBackground: Appearance.colors.colLayer1Hover
                    placeholderText: Translation.tr("Find")
                    text: root.findTerm
                    onTextEdited: {
                        root.findTerm = text;
                        root.findScan();
                        root.findReveal();
                    }
                    onAccepted: root.findJump(1)
                    Keys.onDownPressed: root.findJump(1)
                    Keys.onUpPressed: root.findJump(-1)
                    Keys.onEscapePressed: root.closeFind()
                }
                StyledText {
                    Layout.preferredWidth: 74
                    horizontalAlignment: Text.AlignRight
                    text: root.findTerm.length === 0 ? ""
                        : (root.findCount === 0 ? Translation.tr("No matches")
                                                : root.findPosition + " / " + root.findCount)
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.findCount === 0 && root.findTerm.length > 0
                        ? Appearance.colors.colTertiary : Appearance.colors.colSubtext
                }
                ToolButton {
                    icon: "keyboard_arrow_up"
                    shortcut: "Shift+Enter"
                    onActivated: root.findJump(-1)
                }
                ToolButton {
                    icon: "keyboard_arrow_down"
                    shortcut: "Enter"
                    onActivated: root.findJump(1)
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 20
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)
                }

                ToolbarTextField {
                    id: replaceField
                    Layout.fillWidth: true
                    Layout.minimumWidth: 130
                    Layout.maximumWidth: 340
                    Layout.fillHeight: false
                    Layout.preferredHeight: 32
                    colBackground: Appearance.colors.colLayer1Hover
                    placeholderText: Translation.tr("Replace with")
                    text: root.replaceTerm
                    onTextEdited: root.replaceTerm = text
                    onAccepted: root.replaceCurrent()
                    Keys.onEscapePressed: root.closeFind()
                }
                ToolButton {
                    label: Translation.tr("Replace")
                    onActivated: root.replaceCurrent()
                }
                ToolButton {
                    label: Translation.tr("All")
                    shortcut: Translation.tr("Replace every match")
                    onActivated: root.replaceEverything()
                }

                // Match case, as a toggle: the "Aa" is what every find bar in
                // every editor uses for this, so it needs no label.
                ToolButton {
                    icon: "match_case"
                    toggled: root.findCaseSensitive
                    shortcut: Translation.tr("Match case")
                    onActivated: {
                        root.findCaseSensitive = !root.findCaseSensitive;
                        root.findScan();
                    }
                }
                ToolButton {
                    icon: "close"
                    shortcut: "Esc"
                    onActivated: root.closeFind()
                }
            }
        }

        // ── The page ────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Appearance.colors.colLayer0Base

            // A StyledFlickable (the shell's scrolling surface), not a ScrollView,
            // and the difference is not taste.
            //
            // This was a ScrollView with the TextArea anchored to `parent.left`
            // and `parent.right`, and that parent is the ScrollView's CONTENT
            // item -- which is only as wide as the content asks for. With four
            // short lines in it the editor measured **122x422 inside a 1691x422
            // page**: a sliver of editable surface down the left edge of the
            // window, with wrapping happening at 122px, and every click to the
            // right of it landing on empty background instead of in the text.
            // That is the whole report -- "doesn't use the whole space it has"
            // and "I can't click anywhere to type" are one bug, not two.
            //
            // So the geometry is stated instead of inferred. The text area is
            // given the viewport's width (minus the scrollbar it sits beside)
            // and the taller of its own content and the viewport. Filling the
            // page is what makes any click inside it a click in the text, and
            // growing with the content is what keeps the rest of a long
            // document clickable too; the Flickable scrolls the overflow.
            StyledFlickable {
                id: page
                anchors.fill: parent
                anchors.margins: 1
                clip: true

                readonly property real textWidth: root.wrapLines
                    ? width - (ScrollBar.vertical.visible ? ScrollBar.vertical.width : 0)
                    : Math.max(width, editor.implicitWidth)
                contentWidth: textWidth
                contentHeight: Math.max(editor.implicitHeight, height)

                ScrollBar.vertical: StyledScrollBar { showWhenScrollable: true }
                ScrollBar.horizontal: StyledScrollBar {
                    policy: root.wrapLines ? ScrollBar.AlwaysOff : ScrollBar.AsNeeded
                    implicitHeight: 10
                }
                TextArea {
                    id: editor
                    width: page.textWidth
                    height: page.contentHeight
                    wrapMode: root.wrapLines ? TextEdit.Wrap : TextEdit.NoWrap
                    selectByMouse: true
                    persistentSelection: true
                    textFormat: TextEdit.PlainText
                    renderType: Text.NativeRendering
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: root.baseFontSize * root.zoom
                    color: Appearance.colors.colOnLayer0
                    selectionColor: Appearance.colors.colPrimary
                    selectedTextColor: Appearance.colors.colOnPrimary
                    placeholderText: Translation.tr("Type here…")
                    placeholderTextColor: Appearance.colors.colSubtext
                    padding: 14
                    background: null
                    onTextChanged: root.recount()
                    onCursorPositionChanged: root.updateCursor()
                }
            }
        }

        // ── Unsaved changes ────────────────────────────────────────────
        // The three answers, offered in place. The window refuses the close
        // first (see `onClosing`) and only then shows this -- so the text is
        // still here to be saved, which is the whole point of asking.
        Rectangle {
            visible: root.askDiscard
            Layout.fillWidth: true
            implicitHeight: visible ? 48 : 0
            color: CF.ColorUtils.transparentize(Appearance.colors.colErrorContainer, 0.2)

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 10
                spacing: 6

                MaterialSymbol {
                    text: "error"
                    iconSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnErrorContainer
                }
                StyledText {
                    Layout.fillWidth: true
                    text: Translation.tr("Save changes to \"%1\"?").arg(root.docName)
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnErrorContainer
                }
                ToolButton {
                    icon: "save"
                    label: Translation.tr("Save")
                    onActivated: {
                        root.askDiscard = false;
                        root.save();
                    }
                }
                ToolButton {
                    icon: "delete_forever"
                    label: Translation.tr("Don't save")
                    onActivated: {
                        root.askDiscard = false;
                        root.savedText = editor.text;   // deliberate: the discard is the user's choice
                        root.quitNow();
                    }
                }
                ToolButton {
                    label: Translation.tr("Cancel")
                    onActivated: root.askDiscard = false
                }
            }
        }

        // ── The status band ─────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 30
            color: Appearance.colors.colLayer1
            radius: Appearance.rounding.windowRounding

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                StyledText {
                    text: Translation.tr("Ln") + " " + root.cursorLine + ", " + Translation.tr("Col") + " " + root.cursorCol
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: "·"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: root.wordTotal + " " + Translation.tr("words")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: "·"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: editor.text.length + " " + Translation.tr("characters")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: "·  UTF-8"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                // Wrapping is on unless someone turned it off; when it is off
                // the long lines are the point, so the state says so instead of
                // leaving the reader to wonder why nothing stops at the edge.
                StyledText {
                    visible: !root.wrapLines
                    text: Translation.tr("·  no wrap")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colTertiary
                }
                StyledText {
                    visible: root.zoom !== 1.0
                    text: "·  " + Math.round(root.zoom * 100) + "%"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colTertiary
                }

                Item { Layout.fillWidth: true }

                StyledText {
                    visible: root.dirty
                    text: Translation.tr("Modified")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colTertiary
                }
                StyledText {
                    visible: !root.dirty && root.filePath.length > 0
                    text: root.filePath
                    elide: Text.ElideMiddle
                    Layout.maximumWidth: 420
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
            }
        }
    }

    // ── Keyboard ────────────────────────────────────────────────────────
    // The four a Notepad user's hands already know. Undo/redo, select-all and
    // the clipboard are TextEdit's own and need no wiring here.
    Shortcut { sequence: "Ctrl+N"; onActivated: root.newDocument() }
    Shortcut { sequence: "Ctrl+O"; onActivated: root.askOpen() }
    Shortcut { sequence: "Ctrl+S"; onActivated: root.save() }
    Shortcut { sequence: "Ctrl+Shift+S"; onActivated: root.askSaveAs() }
    Shortcut { sequence: "Ctrl+F"; onActivated: root.openFind() }
    Shortcut { sequence: "Ctrl+H"; onActivated: root.openFind() }
    // The date, as Notepad's F5 -- and Ctrl+E for keyboards whose F-row is
    // someone else's (this desktop's F-keys are mostly the compositor's).
    Shortcut { sequence: "F5"; onActivated: root.insertDateTime() }
    Shortcut { sequence: "Ctrl+E"; onActivated: root.insertDateTime() }
    Shortcut { sequence: "Ctrl+="; onActivated: root.zoomIn() }
    Shortcut { sequence: "Ctrl++"; onActivated: root.zoomIn() }
    Shortcut { sequence: "Ctrl+-"; onActivated: root.zoomOut() }
    Shortcut { sequence: "Ctrl+0"; onActivated: root.zoomReset() }
    // Esc closes the find bar, and only the find bar: a stray Esc must never
    // close a window that has unsaved text in it.
    Shortcut {
        sequence: "Esc"
        enabled: root.findOpen
        onActivated: root.closeFind()
    }

    // ── Driven from a terminal ──────────────────────────────────────────
    // The same contract Files has: one window, its state readable as JSON, so
    // the editor can be exercised end to end (open, type, save, reopen) with
    // no pointer -- which is how it was verified.
    IpcHandler {
        target: "editor"
        function ping(): string { return "editor"; }
        function openPath(path: string): void { root.loadPath(path); }
        function probeState(): string {
            return JSON.stringify({
                path: root.filePath,
                name: root.docName,
                dirty: root.dirty,
                chars: editor.text.length,
                lines: root.lineTotal,
                words: root.wordTotal,
                line: root.cursorLine,
                column: root.cursorCol,
                wrap: root.wrapLines,
                discarding: root.askDiscard,
                note: root.statusNote,
                zoom: root.zoom,
                findOpen: root.findOpen,
                findTerm: root.findTerm,
                findMatches: root.findCount,
                findPosition: root.findPosition,
                matchCase: root.findCaseSensitive,
                canUndo: editor.canUndo,
                canRedo: editor.canRedo,
                // The geometry the app itself believes it has, so "the window
                // is the size of its tile" and "the text page is the size of
                // the window" can be asked rather than guessed at from pixels.
                size: Math.round(root.width) + "x" + Math.round(root.height),
                page: Math.round(page.width) + "x" + Math.round(page.height),
                textArea: Math.round(editor.width) + "x" + Math.round(editor.height),
                visualLines: editor.lineCount,
                implicit: Math.round(editor.implicitWidth) + "x" + Math.round(editor.implicitHeight),
                screen: Screen.width + "x" + Screen.height,
                dpr: Screen.devicePixelRatio
            });
        }
        function probeText(): string { return editor.text; }
        function setText(text: string): void { editor.text = text; }
        function append(text: string): void { editor.text = editor.text + text; }
        function save(): void { root.save(); }
        function saveAs(path: string): void { root.saveTo(path); }
        function openDialog(): void { root.askOpen(); }
        function saveAsDialog(): void { root.askSaveAs(); }
        function exportDialog(): void { root.askExport(); }
        function exportAs(path: string): void { root.exportTo(path); }
        function toggleWrap(): void { root.wrapLines = !root.wrapLines; }
        function find(term: string): string {
            root.findOpen = true;
            root.findTerm = term;
            root.findScan();
            root.findReveal();
            return JSON.stringify({ matches: root.findCount, position: root.findPosition });
        }
        function findNext(): string {
            root.findJump(1);
            return JSON.stringify({ position: root.findPosition });
        }
        function findPrevious(): string {
            root.findJump(-1);
            return JSON.stringify({ position: root.findPosition });
        }
        function matchCase(on: bool): void {
            root.findCaseSensitive = on;
            root.findScan();
        }
        function replaceWith(text: string): string {
            root.replaceTerm = text;
            root.replaceCurrent();
            return JSON.stringify({ matches: root.findCount });
        }
        function replaceAllWith(text: string): string {
            root.replaceTerm = text;
            const before = root.findCount;
            root.replaceEverything();
            return JSON.stringify({ replaced: before, matches: root.findCount });
        }
        function closeFind(): void { root.closeFind(); }
        function setZoom(level: real): void { root.setZoom(level); }
        function insertDate(): void { root.insertDateTime(); }
        function selection(): string {
            return JSON.stringify({
                start: editor.selectionStart,
                end: editor.selectionEnd,
                text: editor.selectedText
            });
        }
        // The same request the window manager's close button makes, for a
        // script that put a document in front of someone and is done with it.
        function closeWindow(): void { root.close(); }
    }
}
