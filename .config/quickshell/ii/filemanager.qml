// Files -- the file manager, as an ORDINARY DESKTOP WINDOW.
//
// It used to be a full-screen layer-shell "popup": a veil over the whole
// screen, an edge-anchored card, a presence file, a four-finger close-drag and
// a morph into a real window. That machinery is gone on purpose (requested):
// the app opens as an xdg toplevel, sits in the tiling layout (attached), and
// responds to the desktop's own window commands -- SUPER + F fills the screen,
// the four-finger swipe up maximises it, SUPER + Q closes it, it tiles beside
// whatever else is open. Same conversion the settings app already had.
//
// WHY THIS MATTERS BEYOND LOOKS: a layer surface is not a window. The
// compositor cannot tile it, focus it, fullscreen it or close it, so as long as
// Files was a popup, every one of those commands silently did nothing -- which
// is exactly "it always opens fullscreen and I cannot do anything about it".
// A plain `Window`, not a PanelWindow: PanelWindow is backed by the layer
// shell, and this app must be a toplevel.
//
// The portal's FileChooser dialog is the one surface that still needs to be a
// layer-shell app (it must sit above the app that asked for it, and its answer
// goes back over the portal's job/result files), so it lives in its own file:
// filemanager-picker.qml. `scripts/launch/filemanager.sh` picks between them.
//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import qs.modules.filemanager

Window {
    id: root

    // A real app window: solid, titled, in the layout. `color: transparent` is
    // for the rounded corners; the opaque surface is the Rectangle below, the
    // same recipe (and the same colour) the settings window uses, so two
    // Quickshell windows look like two windows of one desktop.
    color: "transparent"
    visible: true
    title: Translation.tr("Files")
    // Deliberately NOT floated and NOT centred by a window rule: the tiling
    // layout attaches it, which is what "opens attached" means here (see
    // custom/rules.lua). From there SUPER + F / the four-finger swipe up fill
    // the screen, exactly as they do for any other window.
    width: 1080
    height: 720
    minimumWidth: 640
    minimumHeight: 480

    Rectangle {
        id: winBg
        anchors.fill: parent
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colTerminalSurfaceSolid
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
    }

    FileManagerContent {
        id: content
        anchors.fill: parent
        onQuitRequested: root.quitApp()
    }

    Component.onCompleted: {
        // This app is its own Quickshell instance: the theme has to be applied
        // in THIS process, not only in the shell that launched it.
        MaterialThemeLoader.reapplyTheme()
    }

    // Closing is not just `Qt.quit()`: as its own Quickshell instance the app
    // pulls in services that own child processes, and Qt only cleans up the
    // processes it started itself. Every close path lands here -- the
    // compositor's close (SUPER + Q, the titlebar, killactive), the IPC `quit`
    // and the content's own button.
    function quitApp() {
        childReaper.running = true;
    }
    function showNow() {
        root.visible = true;
        root.requestActivate();
    }
    // ── Closing HIDES; the process stays warm ────────────────────────────
    //
    // A cold start is about a second (Quickshell, this app's QML, the first
    // lsblk read), a raise of the copy that is already here is about fifty
    // milliseconds. "The file manager does not open instantly" was that second,
    // paid on every open because the window's close was the process's quit. So
    // closing now unmaps the window and leaves the process behind, which is the
    // same arrangement `scripts/launch/filemanager.sh` is already built around
    // (an instance that answers IPC is raised instead of started).
    //
    // The countdown is what keeps that from meaning "a file manager is always
    // running". Its `running` is BOUND to the window being hidden rather than
    // started and stopped by hand: an idle quit that has to be cancelled by
    // every path that shows the window is one missed call away from closing a
    // window someone is looking at, and a binding cannot miss one. Hidden for
    // `idleQuit` -> the copy lets itself go; shown again -> the count starts
    // over. Every real quit path -- the IPC `quit`, the child reaper, Qt
    // quitting -- is untouched.
    onClosing: function(close) {
        close.accepted = false;
        root.visible = false;
    }
    Timer {
        id: idleQuit
        interval: 5 * 60 * 1000
        running: !root.visible && !content.pickerMode
        onTriggered: root.quitApp()
    }
    Process {
        id: childReaper
        // Captured while this app is provably alive.
        property string pid: `${Quickshell.processId}`
        command: ["sh", "-c", `me=$$; kids=$(pgrep -P ${pid} 2>/dev/null | grep -vw "$me"); [ -n "$kids" ] && kill $kids 2>/dev/null; exit 0`]
        onExited: {
            Network.stopStrayProcesses();
            Qt.quit();
        }
    }

    // ── IPC: `qs ipc --pid <pid> call files open|openPath|quit|probe...` ───
    // The same target the picker instances answer on, so a caller addresses
    // whichever form it has a pid for and does not care which one it is.
    IpcHandler {
        target: "files"
        function ping(): string { return "files"; }
        function open(): void {
            // A window that already exists has nothing to "show": raise it and
            // give it focus, which is what pressing SUPER + E on an open Files
            // is asking for.
            root.showNow();
        }
        // A path, which may be a FOLDER (open it) or a FILE (the desktop's "show
        // this in the file manager": go to the folder it lives in and select it,
        // rather than trying to list a file as though it were a folder). Every
        // caller of this -- the desktop entry, the portal, another app's "show
        // in folder" -- passes whatever it happens to have, and both answers are
        // this one function.
        function openPath(path: string): void {
            root.showNow();
            content.openPath(path);
        }
        function quit(mode: string): void {
            root.quitApp();
        }
        // ── Probe hooks ───────────────────────────────────────────────────
        // The manager, driven and read from a terminal with no pointer
        // involved (scripts/system/files-check.sh asserts on the JSON).
        function probeState(): string { return content.probeState(); }
        function probeList(limit: string): string { return content.probeList(Number(limit)); }
        function probeVolumes(): string { return content.probeVolumes(); }
        // The navigation pane as it is drawn (the drive order, the Advanced fold,
        // the eject/unmount label), the phones on the USB bus, and the two
        // layout answers that only a resize can give.
        function probeNav(): string { return content.probeNav(); }
        // The same list as it is DRAWN: which rows are on screen, in which order,
        // and at what y -- the difference between the model being right and the
        // pane showing it.
        function probeNavDrawn(): string { return content.probeNavDrawn(); }
        function probeNavQuick(): string { return content.probeNavQuick(); }
        function probeMtp(): string { return content.probeMtp(); }
        function probeMtpScan(): void { content.scanMtpDevices(); }
        function probeMtpMount(name: string): void { content.mountMtp(content.mtpDeviceByName(name)); }
        function probeMtpUnmount(name: string): void { content.unmountMtp(content.mtpDeviceByName(name)); }
        function probeAdvanced(flag: string): void {
            content.showAdvancedVolumes = flag !== "0" && flag !== "false";
        }
        function probeLayout(): string { return content.probeLayout(); }
        function probeColumns(): string { return content.probeColumns(); }
        function probeResize(width: string, height: string): void {
            root.width = Math.max(root.minimumWidth, Number(width));
            root.height = Math.max(root.minimumHeight, Number(height));
        }
        function probePathEdit(): void { content.beginPathEdit(); }
        function probeCrumbHit(): string { return content.probeCrumbHit(); }
        function probePathDone(): void { content.finishPathEdit(); }
        // The keyboard's route, readable and walkable from a terminal: which
        // area Tab is on, what the arrows are on inside it, and the same steps
        // the keys take. "The Tab key does nothing" is checkable here without
        // pressing Tab.
        function probeFocusArea(): string { return content.focusArea; }
        function probeFocusLabel(): string { return content.focusLabel(); }
        function probeFocusStep(delta: string): void {
            content.stepFocusArea(Number(delta) < 0 ? -1 : 1);
        }
        function probeFocusIndex(delta: string): void {
            content.stepFocusIndex(Number(delta) < 0 ? -1 : 1);
        }
        function probeFocusActivate(): void { content.activateFocus(); }
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
        // Clicking a drive ROW, as opposed to the small control beside it: it
        // opens a mounted drive and mounts an unmounted one. Checkable without
        // a pointer because it is the same function the row's MouseArea calls,
        // and because "it opened" is a path a script can read back.
        function probeRowOpen(device: string): void {
            const v = content.volumeByPath(device);
            if (v) content.rowActivate(v);
        }
        // ── Drive actions ─────────────────────────────────────────────────
        // A drive's menu, as the ids the menu would run, plus the command line
        // each one resolves to. Both are readable WITHOUT root and without
        // touching a drive: nothing here runs until probeDriveAction, and that
        // one is a dry run. This is what makes "Rename a USB stick" checkable
        // by a script that cannot possibly rename the machine's SSD.
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
        // The prompt, driven and answered from here: what it says about its own
        // target, what it pre-fills, and what committing it decides. The answer
        // is the status note or an error, never the same "nothing happened".
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
        function probeDrivePromptCancel(): void { content.closeVolumePrompt(); }
        // The same commit, with the write suppressed -- what a check uses, so
        // that asserting "formatting asks for confirmation" cannot format
        // anything. The status line and the command it decided on are both
        // returned, because those are the two halves of the decision.
        function probeDrivePromptCommitDry(value: string): string {
            content.dryRun = true;
            content.answerVolumePrompt(value);
            content.dryRun = false;
            return content.statusNote + "|" + content.lastVolumeCommand;
        }
        function probeMountNames(): string { return JSON.stringify(content.mountNames); }
        // ── The desktop half of copy and drag ─────────────────────────────
        // Copying a file is a claim on the whole desktop, so the proof of it is
        // not this app's own list -- it is what another program would receive.
        // probeClipboard reports what was published; the check suite then reads
        // the live clipboard back with wl-paste, which is the same thing a
        // desktop app does when it pastes.
        function probeCopy(cut: string): void {
            content.copySelection(cut === "1" || cut === "true");
        }
        function probeClipboard(): string { return content.probeClipboard(); }
        function probeDragPayload(name: string): string { return content.probeDragPayload(name); }
        // What the eject control asks before it acts, and what the answer would
        // run -- without running it.
        function probeUnmountAsk(device: string): string {
            const v = content.volumeByPath(device);
            if (!v) return "";
            content.requestUnmount(v);
            return content.volumePromptTitle() + "|" + content.volumePromptKind + "|" + content.volumePromptHint();
        }
        // ── Previews ──────────────────────────────────────────────────────
        // The pane reads the selection, so this drives it the way a person
        // does: select a row, turn the pane on, wait for the answer. `wait`
        // exists because a preview of a text file or a PDF is a process, and a
        // probe that answers before the process does would be asserting on an
        // empty pane.
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
        function probeDriveInfo(device: string): string {
            const v = content.volumeByPath(device);
            if (!v) return "";
            return JSON.stringify({ menu: content.volumeActionIds(v), label: content.volumeLabel(v), name: content.mountNameFor(v) });
        }
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
        // Tab control.
        function tabCount(): int { return content.tabs.length; }
        function tabActive(): int { return content.activeTab; }
        function tabNames(): string { return content.tabs.map(t => content.tabLabel(t)).join("|"); }
        function tabPath(): string { return content.currentFolderPath(); }
        function tabNew(path: string): void { content.newTab(path && path.length > 0 ? path : undefined); }
        function tabSelect(index: string): void { content.selectTab(Number(index)); }
        function tabClose(index: string): void { content.closeTab(Number(index)); }
    }

    // Escape closes, as it does in any window's "get me out" sense.
    Shortcut {
        sequence: "Escape"
        context: Qt.ApplicationShortcut
        onActivated: root.quitApp()
    }
}
