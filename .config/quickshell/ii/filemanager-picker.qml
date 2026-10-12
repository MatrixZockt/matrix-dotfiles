// Files (picker) -- the portal's FileChooser dialog, and the ONE surface of the
// file manager that stays a layer-shell app.
//
// WHY THIS IS A SEPARATE FILE FROM filemanager.qml. The Files app is an
// ordinary desktop window now -- it tiles, it takes SUPER+F, the compositor
// closes it -- but a file dialog is not a window: it is a request from another
// application, it must sit above whatever that application is, and its answer
// goes back over the portal's job/result files. Those are two different
// contracts (an xdg toplevel and a layer surface are different kinds of
// object), and a QML root has one fixed type, so they are two files. The
// launch script picks: `filemanager.sh picker <token>` runs this one.
//
// The dialog drives itself from II_FILES_PICKER: the job file names the mode,
// the folder and the default name; the result file is the answer; then the
// process quits. Same protocol the portal has always spoken.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import qs.modules.filemanager

PanelWindow {
    id: root

    // The job/result protocol requires a token; without one there is nothing to
    // answer, and the launcher never starts this file without it.
    readonly property string pickerToken: Quickshell.env("II_FILES_PICKER") ?? ""
    readonly property string pickerDir: `${Quickshell.env("XDG_RUNTIME_DIR")}/ii-portal`

    exclusiveZone: -1
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "quickshell:files"
    // Yield to a layer-shell sibling that must sit above the dialog (the
    // wallpaper explorer) -- the flag file PopupApps publishes.
    WlrLayershell.layer: PopupApps.yieldLayer ? WlrLayer.Top : WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property real anchorMargin: Appearance.sizes.hyprlandGapsOut
    readonly property real cardWidth: root.width - root.anchorMargin * 2
    readonly property real cardHeight: root.height - root.anchorMargin * 2

    Component.onCompleted: PopupApps.setYield(true)
    Component.onDestruction: PopupApps.setYield(false)

    // ── Answering, and leaving ──────────────────────────────────────────
    function quitApp() {
        root.pickerCancel();
    }

    function pickerWriteResult(cancelled, uris) {
        if (!root.pickerToken) return;
        // The portal contract wants a list; anything single arrives wrapped.
        const list = Array.isArray(uris) ? uris : (uris ? [String(uris)] : []);
        const payload = JSON.stringify({ cancelled: cancelled, uris: list });
        pickerResultWriter.command = ["bash", "-c",
            `mkdir -p '${root.pickerDir}' && printf '%s' '${payload.replace(/'/g, `'\\''`)}' > '${root.pickerDir}/${root.pickerToken}.result.json'`];
        pickerResultWriter.running = true;
    }

    function pickerAccept(uris) {
        if (root.pickerWritten) return;
        root.pickerWritten = true;
        root.pickerWriteResult(false, uris);
        pickerQuitTimer.start();
    }
    function pickerCancel() {
        if (root.pickerWritten) return;
        // A dialog that answers "no" must say why. A cancellation has five
        // possible authors -- Escape, a tap outside the card, the job file going
        // away, the content asking to quit, the launcher dismissing the dialog
        // -- and the answer the caller receives looks identical for all five.
        // The stack names the one that fired, which is the only trace such a
        // dialog leaves.
        console.log("[picker] cancelled by:", new Error().stack);
        root.pickerWritten = true;
        root.pickerWriteResult(true, []);
        pickerQuitTimer.start();
    }

    Process {
        id: pickerResultWriter
        command: []
    }
    Timer {
        id: pickerQuitTimer
        interval: 160
        onTriggered: Qt.quit()
    }

    // Orphan guard. The backend deletes the job file once the request is over
    // -- whether it was answered, closed by the app, or timed out. If that
    // happens while the dialog is still up (the app withdrew its request, or
    // the backend gave up), the dialog would otherwise sit there forever with
    // nobody waiting for its answer. Seeing the job file gone means there is
    // nothing left to answer, so the dialog goes away.
    Timer {
        id: pickerOrphanCheck
        interval: 1000
        repeat: true
        running: !root.pickerWritten
        onTriggered: {
            pickerJobProbe.command = ["sh", "-c",
                `[ -f '${root.pickerDir}/${root.pickerToken}.json' ] && echo yes || echo no`];
            pickerJobProbe.running = false;
            pickerJobProbe.running = true;
        }
    }
    Process {
        id: pickerJobProbe
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                if (String(this.text ?? "").trim() === "no" && !root.pickerWritten)
                    Qt.quit();
            }
        }
    }

    // ── The job file ────────────────────────────────────────────────────
    property string pickerOp: "open"
    property string pickerStartDir: ""
    property string pickerName: ""
    property bool pickerDirectory: false
    property bool pickerWritten: false

    FileView {
        id: pickerJob
        path: `${root.pickerDir}/${root.pickerToken}.json`
        watchChanges: false
        onLoaded: root.pickerJobLoaded()
        onLoadFailed: pickerJobRetry.start()
    }

    // The portal writes the job file and starts the dialog, and those two are
    // not ordered: the dialog can be up before the file is readable. Cancelling
    // on the first miss -- which is what this used to do -- makes the race
    // visible as a dialog that answers "cancelled" the instant it appears.
    Timer {
        id: pickerJobRetry
        // 250ms, not less: this reloads a FileView, and reloading one whose
        // attempt is still running aborts that attempt and reports a failure --
        // which is how a retry loop ends up starving the very load it is
        // waiting for.
        interval: 250
        repeat: true
        property int tries: 0
        onRunningChanged: if (running) tries = 0
        onTriggered: {
            if (++tries > 8) { stop(); root.pickerCancel(); return; }
            pickerJob.reload();
        }
    }

    function pickerJobLoaded() {
        let job = {};
        try {
            job = JSON.parse(pickerJob.text());
        } catch (e) {
            pickerJobRetry.start();   // caught half-written: try again
            return;
        }
        pickerJobRetry.stop();
        root.pickerOp = job.op ?? "open";
        root.pickerStartDir = job.dir ?? "";
        root.pickerName = job.name ?? "";
        root.pickerDirectory = job.directory ?? false;
        if (root.pickerStartDir.length > 0)
            content.pickerNavigate(root.pickerStartDir);
    }

    // ── IPC ─────────────────────────────────────────────────────────────
    // The same target name as the app (`files`), so every caller -- the launch
    // script, the check suite -- talks to whichever instance it is addressing
    // without caring which form it wears.
    IpcHandler {
        target: "files"
        function ping(): string { return "files"; }
        function open(): void {
            root.visible = true;
        }
        function openPath(path: string): void {
            root.visible = true;
            content.navigateTo(path);
        }
        function quit(mode: string): void {
            root.pickerCancel();
        }
        // Probe hooks: the dialog driven and read from a terminal with no
        // pointer involved (scripts/system/files-check.sh).
        function probeState(): string { return content.probeState(); }
        function probeList(limit: string): string { return content.probeList(Number(limit)); }
        function probeVolumes(): string { return content.probeVolumes(); }
        function probeMenu(): string { return content.probeMenu(); }
        function probePath(): string { return content.currentFolderPath(); }
        function probeGo(path: string): void { root.visible = true; content.navigateTo(path); }
        function probeBack(): void { content.goBack(); }
        function probeForward(): void { content.goForward(); }
        function probeUp(): void { content.goUp(); }
        function probeSelect(name: string): void { content.selectName(name); }
        function probeActivate(index: string): void { content.activate(Number(index)); }
        function probeView(mode: string): void { content.viewMode = mode === "tiles" ? "tiles" : "details"; }
        function probeHidden(flag: string): void { content.showHidden = flag === "1" || flag === "true"; }
        function probeExtensions(flag: string): void { content.showExtensions = flag === "1" || flag === "true"; }
        function probeFilter(text: string): void { content.filter = text; }
        function probeSort(field: string, reversed: string): void {
            content.sortField = Number(field);
            content.sortReversed = reversed === "1" || reversed === "true";
        }
        function probeRename(name: string): void { content.beginRename(content.currentFolderPath() + "/" + name); }
        function probeRenameCommit(name: string): void { content.renameDraft = name; content.commitRename(); }
        function probeTrash(name: string): void { content.trashItems([content.currentFolderPath() + "/" + name]); }
        function probeHardDelete(name: string): void {
            content.deleteItems([content.currentFolderPath() + "/" + name]);
        }
        function probeInfo(name: string): void { content.showInfo(content.currentFolderPath() + "/" + name); }
        function probeInfoText(): string { return content.infoText; }
        function probeMount(device: string): void {
            const v = content.volumeByPath(device);
            if (v) content.mountVolume(v);
        }
        function probeUnmount(device: string): void {
            const v = content.volumeByPath(device);
            if (v) content.unmountVolume(v);
        }
        // ── Drive actions ─────────────────────────────────────────────────
        // The same surface the window form answers on, because a drive's
        // right-click menu is the same menu in both forms: what changes here is
        // the SURFACE, not what you can do to a drive. Nothing below runs
        // anything -- probeDriveAction is a dry run that reports the command
        // line, which is what makes the menu checkable without root.
        function probeDriveMenu(device: string): string {
            const v = content.volumeByPath(device);
            return v ? content.volumeActionIds(v).join("|") : "";
        }
        function probeDriveCommand(action: string, device: string, arg: string): string {
            const v = content.volumeByPath(device);
            if (!v) return "";
            return content.volumeActionCommand(action, v, arg ?? "");
        }
        function probeDriveAction(action: string, device: string, arg: string): string {
            const v = content.volumeByPath(device);
            if (!v) return "";
            content.dryRun = true;
            const cmd = content.runVolumeAction(action, v, arg ?? "");
            content.dryRun = false;
            return cmd;
        }
        function probeDrivePrompt(kind: string, device: string): string {
            const v = content.volumeByPath(device);
            if (!v) return "";
            content.openVolumePrompt(kind, v);
            return content.volumePromptTitle() + "|" + content.volumePromptDraft + "|" + content.volumePromptHint();
        }
        function probeDrivePromptCommit(value: string): string {
            content.answerVolumePrompt(value);
            return content.statusNote + "|" + content.lastVolumeCommand;
        }
        function probeDrivePromptCommitDry(value: string): string {
            content.dryRun = true;
            content.answerVolumePrompt(value);
            content.dryRun = false;
            return content.statusNote + "|" + content.lastVolumeCommand;
        }
        function probeDrivePromptCancel(): void { content.closeVolumePrompt(); }
        function probeMountNames(): string { return JSON.stringify(content.mountNames); }
        function probeDriveInfo(device: string): string {
            const v = content.volumeByPath(device);
            if (!v) return "";
            return JSON.stringify({ menu: content.volumeActionIds(v), label: content.volumeLabel(v), name: content.mountNameFor(v) });
        }
        // ── Previews ──────────────────────────────────────────────────────
        // The pane is a window affordance (a dialog asks a question, and a
        // preview is not part of the answer), so these exist for symmetry: a
        // probe that reads the preview state is answered the same way in both
        // forms, and says "the pane is off" in the picker.
        function probePreviewSelect(name: string): void {
            if (name && name.length > 0) content.selectName(name);
        }
        function probePreviewPane(flag: string): void {
            content.previewPane = flag !== "0" && flag !== "false";
        }
        function probeTilePreviews(flag: string): void {
            content.tilePreviews = flag !== "0" && flag !== "false";
        }
        function probePreviewRefresh(): void { content.refreshPreview(); }
        function probePreview(): string { return content.probePreview(); }
        // Menu control: a menu is a pointer gesture, and this stack can be
        // driven end-to-end without one.
        function menuAt(x: string, y: string, target: string): void {
            content.openMenu(Number(x), Number(y), target ?? "");
        }
        function menuCount(): int { return content.menuItems.length; }
        function menuRun(index: string): void {
            const i = Number(index);
            if (i >= 0 && i < content.menuItems.length) content.runMenu(content.menuItems[i]);
        }
        function menuClose(): void { content.closeMenu(); }
        // Tab control. The dialog keeps the same hooks as the app so one suite
        // can drive either form; the tab strip itself is hidden while a dialog
        // is up (FileManagerContent.tabsAvailable).
        function tabCount(): int { return content.tabs.length; }
        function tabActive(): int { return content.activeTab; }
        function tabNames(): string { return content.tabs.map(t => content.tabLabel(t)).join("|"); }
        function tabPath(): string { return content.currentFolderPath(); }
        function tabNew(path: string): void { content.newTab(path && path.length > 0 ? path : undefined); }
        function tabSelect(index: string): void { content.selectTab(Number(index)); }
        function tabClose(index: string): void { content.closeTab(Number(index)); }
        // Picker-specific control. The portal path never needs it (the dialog
        // drives itself from II_FILES_PICKER); it exists so the picker can be
        // driven end-to-end without a pointer.
        function pickerAcceptWith(urisJson: string): void {
            let uris = urisJson;
            try { uris = JSON.parse(urisJson); } catch (e) { /* bare path */ }
            root.pickerAccept(Array.isArray(uris) ? uris : [uris]);
        }
        function pickerCancelNow(): void { root.pickerCancel(); }
        function probePickerConfirm(): void { root.visible = true; content.pickerConfirm(); }
        function probePickerName(name: string): void { content.pickerName = name; }
        function probePickerMode2(kind: string, directory: string): void {
            content.pickerOp = kind;
            content.pickerDirectory = directory === "1" || directory === "true";
        }
    }

    // ── The dialog ──────────────────────────────────────────────────────
    // Edge-anchored, per the house rule -- a floating card in the middle of the
    // screen is the in-between that rule bans -- with a denser scrim than the
    // other popups, because this one is modal over an app you are still working
    // in.
    Rectangle {
        id: backdrop
        anchors.fill: parent
        color: CF.ColorUtils.transparentize(Appearance.m3colors.m3background, 0.42)
        TapHandler {
            // Clicking the scrim means "no thank you" -- but only when the tap
            // landed outside the card: this handler is passive, so it observes
            // every tap in the surface, including the ones the folder tiles
            // handle.
            onTapped: (event) => {
                const p = event.point.position;
                const inside = p.x >= card.x && p.x <= card.x + card.width
                    && p.y >= card.y && p.y <= card.y + card.height;
                if (inside) return;
                root.pickerCancel();
            }
        }
    }

    Rectangle {
        id: card
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        width: root.cardWidth
        height: root.cardHeight
        radius: Appearance.rounding.windowRounding
        color: CF.ColorUtils.transparentize(Appearance.m3colors.m3background, 0.28)
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
        clip: true

        FileManagerContent {
            id: content
            anchors.fill: parent
            anchors.margins: 6
            pickerMode: true
            pickerOp: root.pickerOp
            pickerName: root.pickerName
            pickerDirectory: root.pickerDirectory
            onPickerAccepted: (uris) => root.pickerAccept(uris)
            onPickerCancelled: root.pickerCancel()
            onQuitRequested: root.pickerCancel()
        }
    }

    // ESCAPE HAS ONE OWNER, AND IT IS NOT A SHORTCUT.
    //
    // A dialog is dismissed with Escape, and the obvious way to arrange that is
    // an application-wide Shortcut -- which is what stood here. It was removed
    // because the content's key layer already answers Escape, and answers it
    // better: FileManagerContent's keyLayer decides what Escape MEANS in the
    // dialog it is in -- close the drive menu, drop the rename, dismiss the
    // volume prompt, or, in picker mode, cancel the dialog (its
    // ShortcutOverride is what keeps a menu from being swallowed by a cancel).
    // An application-wide Shortcut knows only the last of those, and it fires
    // whenever the app has focus rather than when the key reached the dialog.
    // One owner, and it is the one that knows the context.
}
