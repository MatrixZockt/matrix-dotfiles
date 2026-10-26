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

    function recount() {
        const text = editor.text;
        root.lineTotal = text.split("\n").length;
        const words = text.trim();
        root.wordTotal = words.length === 0 ? 0 : words.split(/\s+/).length;
        root.updateCursor();
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
        root.filePath = p;
        writer.target = p;
        writer.command = ["bash", "-c", writer.command[2], "writer", p];
        writer.stdinEnabled = true;
        writer.running = true;
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
        const job = JSON.stringify({
            op: kind === "save" ? "save" : "open",
            dir: dir.length > 0 ? dir : "/",
            name: kind === "save" ? (root.filePath.length > 0 ? root.docName : "") : "",
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

                ToolButton {
                    icon: "wrap_text"
                    toggled: root.wrapLines
                    shortcut: Translation.tr("Wrap long lines")
                    onActivated: root.wrapLines = !root.wrapLines
                }
            }
        }

        // ── The page ────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Appearance.colors.colLayer0Base

            ScrollView {
                id: scroller
                anchors.fill: parent
                anchors.margins: 1
                clip: true
                ScrollBar.vertical.policy: ScrollBar.AsNeeded
                ScrollBar.horizontal.policy: root.wrapLines ? ScrollBar.AlwaysOff : ScrollBar.AsNeeded

                // A TextArea has to be a DIRECT child of a ScrollView to scroll
                // at all (the attached `TextArea.flickable` form is the older
                // Qt 5 spelling and warns on this Qt); its width is pinned to
                // the viewport, which is what makes wrapping follow the window
                // instead of running off to the right forever.
                TextArea {
                    id: editor
                    anchors {
                        left: parent.left
                        right: parent.right
                    }
                    wrapMode: root.wrapLines ? TextEdit.Wrap : TextEdit.NoWrap
                    selectByMouse: true
                    persistentSelection: true
                    textFormat: TextEdit.PlainText
                    renderType: Text.NativeRendering
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.small
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
                note: root.statusNote
            });
        }
        function probeText(): string { return editor.text; }
        function setText(text: string): void { editor.text = text; }
        function append(text: string): void { editor.text = editor.text + text; }
        function save(): void { root.save(); }
        function saveAs(path: string): void { root.saveTo(path); }
        function openDialog(): void { root.askOpen(); }
        function saveAsDialog(): void { root.askSaveAs(); }
        function toggleWrap(): void { root.wrapLines = !root.wrapLines; }
        // The same request the window manager's close button makes, for a
        // script that put a document in front of someone and is done with it.
        function closeWindow(): void { root.close(); }
    }
}
