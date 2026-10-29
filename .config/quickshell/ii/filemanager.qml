// Files -- the file manager, as an ORDINARY DESKTOP WINDOW.
//
// This file has had four shapes, and each turn was a measurement rather than a
// guess, so they are worth keeping in one place:
//
//   1. A full-screen layer-shell "popup": a veil, an edge-anchored card, a
//      presence file, a four-finger close-drag and a morph into a window.
//   2. An ordinary desktop window (xdg toplevel), so that the compositor's own
//      commands would work on it: tiling, SUPER + F, SUPER + Q. Measured on
//      2026-10-13, that form produced both of the complaints it was meant to
//      fix, which is why it is gone again:
//        * it opened MAXIMIZED and tiled (Qt visibility Windowed -> Maximized,
//          845x1010 beside whatever was open) -- "too much in fullscreen", and
//          the tiler's decision rather than the app's;
//        * a launch through scripts/launch/filemanager.sh left NO window at all
//          in 3 of 5 tries: the app received a compositor CLOSE request seconds
//          after it mapped and answered by hiding while its process stayed
//          warm, so the launcher's only check (it answers IPC) reported success
//          over an empty screen -- "sometimes opens invisible". Hyprland does
//          not log who asked for that close, but it is a *window* close, and a
//          layer surface is not a window, so it cannot be the target of one.
//   3. A popup again, shaped like the bar's own menus -- see BarAnchoredPanel:
//      one frosted scrim, one centred card, Escape or a click on the backdrop
//      to leave. It mapped on the monitor you were looking at when it opened,
//      and it was not in the tiling layout, so nothing could stretch it.
//   4. A WINDOW again (2026-10-14, requested) -- "attached like it would
//      normally, like any other desktop app", plus the half of that request
//      which retires the single-instance machinery: "make sure I can open
//      multiple and it doesn't switch to the already open file manager".
//
// So this is an ordinary xdg toplevel, exactly like the settings app's: it tiles
// with the rest, SUPER + F fills it, SUPER + Q closes it, the taskbar lists it,
// and the compositor's own close animation is the one you get. There is no
// window RULE for it here on purpose -- no float, no fixed size -- because "like
// any other desktop app" is what rules.lua's catch-all already says; an
// exception would be the special case, not the rule.
//
// What the window form costs, said plainly, because two of those were the whole
// argument for the popup: there is no backdrop to click away and no
// Escape-to-dismiss at the top level (Escape still backs out of the content's
// own modes), the app sits in the tiling layout and in the taskbar's window
// list, and a compositor close request now means what it says -- the WINDOW goes
// away -- so `onClosing` below takes the PROCESS with it. The old window form's
// two measured failures are answered this way:
//   * "opened maximized at 845x1010, the tiler's size" -- it still opens at the
//     tiler's size, and that IS the point now: a normal app's window is the
//     compositor's to place. What it does not do is ask to be the screen.
//   * "no window in 3 of 5 launches, process warm and screen empty" -- that was
//     CLOSING HIDES. The app answered a close request by hiding while it kept
//     answering IPC, so the launcher's only check ("it answers") reported
//     success over an empty screen. Closing ends the process now, and the
//     launcher asks the COMPOSITOR for the window instead of the app for a
//     reply (see scripts/launch/filemanager.sh).
//
// One consequence is worth stating on its own, because it is the requested
// half: EVERY LAUNCH IS A NEW WINDOW, in its own process. Nothing here looks
// for a copy that is already open and nothing raises one -- a second SUPER + E
// on a Files window you are using has to give you a second Files, not throw you
// out of the first. The launcher's instance lookup, the `open`/`toggle`/`close`
// verbs and the idle-quit countdown all went with that; `quit` is the one
// lifecycle verb left, and it means "this process is done".
//
// Kept from the popup form, deliberately:
//   * its OWN PROCESS, so this app's QML, services and lsblk reads stay out of
//     the main shell and a broken instance cannot take the bar with it;
//   * the launch arguments (a folder to start in, a file to reveal and select)
//     and the IPC probe surface the check suite drives it through;
//   * the CONTENT is untouched: modules/filemanager/FileManagerContent.qml
//     still draws the whole app, and the picker still reuses it;
//   * the picker stays its own file (filemanager-picker.qml) and stays a LAYER
//     surface: a file dialog is not a window -- it arrives as another
//     application's request and has to sit above that application -- and a QML
//     root has one fixed type, so those two contracts are two files.
//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import qs.modules.filemanager

// A plain QtQuick Window, not a PanelWindow: PanelWindow is backed by the layer
// shell, and this app has to be an ordinary xdg toplevel -- the thing a
// compositor tiles, floats and closes like any other app.
Window {
    id: root

    // There is deliberately NO `screen:` binding. This build declares the
    // property as QuickshellScreenInfo but its setter wants a QQuickScreenInfo,
    // so any object handed to it is rejected:
    //     WARN filemanager.qml Unable to assign
    //          QuickshellScreenInfo to QQuickScreenInfo
    // The assignment never took effect anyway -- the window simply used the
    // default screen -- so with no binding there is no warning and no behaviour
    // change. Same note, same reason as settings.qml.
    color: "transparent"
    visible: true
    title: Translation.tr("Files")

    // The size it ASKS for. Under the tiler that is a request the compositor
    // answers by tiling the window anyway -- which is what "like any other
    // desktop app" means -- while as a floater it is the size it opens at. The
    // minimum is what keeps the three panes and the preview pane usable when the
    // tiler hands it a narrow tile.
    width: 1100
    height: 760
    minimumWidth: 640
    minimumHeight: 480
    Component.onCompleted: {
        // This app is its own Quickshell instance: the theme has to be applied
        // in THIS process, not only in the shell that launched it.
        MaterialThemeLoader.reapplyTheme();
    }

    // The window's own background -- OPAQUE. A real app window is solid; the
    // grey is the terminal's, the same colour this app has always ended its
    // animations on and what the bar-menu card painted, so nothing about its
    // look changes with the surface kind.
    Rectangle {
        id: winBg

        anchors.fill: parent
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colTerminalSurfaceSolid
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
    }

    // ── The suite's size knob ───────────────────────────────────────────
    // A window's size belongs to the compositor (the tiler, or a drag), so the
    // checks that ask how the panes share a width pin the CONTENT instead of
    // resizing anything on the user's screen: probeResize assigns these two,
    // and the content draws inside them. Both 0 = follow the window, which is
    // what every real use sees.
    property real probeContentWidth: 0
    property real probeContentHeight: 0
    // A pinned size is a SCRIPT's question ("how do the panes share 1080 px?"),
    // never the window's answer -- so a real resize drops it. The tiler handing
    // the window a new size, or a person dragging its edge, means the pinned
    // number is stale by definition, and keeping it is how the app ended up
    // drawing its whole layout into a box shorter than the window: the content
    // stopped, the window carried on, and the band underneath read as a layout
    // bug rather than as the leftover test knob it was.
    // BOTH axes, on either edge: a resize is a resize. Clearing only the axis
    // that moved left the other one pinned, which is the exact mixed state that
    // reads as "the window is taller than anything in it".
    function releaseProbeSize() {
        root.probeContentWidth = 0;
        root.probeContentHeight = 0;
    }
    onWidthChanged: root.releaseProbeSize()
    onHeightChanged: root.releaseProbeSize()

    FileManagerContent {
        id: content
        // Anchored at the top-left rather than filled, so the probe sizes above
        // can pin it; with both of them 0 the width/height bindings ARE the
        // window's own size, which is what `anchors.fill` did.
        anchors {
            left: parent.left
            top: parent.top
        }
        width: root.probeContentWidth > 0 ? root.probeContentWidth : root.width
        height: root.probeContentHeight > 0 ? root.probeContentHeight : root.height
        // Escape asks the content to quit. The content's key layer decides what
        // Escape means first (close a drive menu, drop a rename, finish a path
        // edit), so this only fires when there is nothing left to dismiss -- and
        // at the top level of an ordinary window there is no "leave without
        // closing" to fall back on: the window closes.
        onQuitRequested: root.quitApp()
    }

    // ── Closing ends the PROCESS ─────────────────────────────────────────
    //
    // Closing is not just `Qt.quit()`: as its own Quickshell instance the app
    // pulls in services that own child processes, and Qt only cleans up the
    // processes it started itself. So every close path runs the reaper below and
    // then quits: the compositor's close (SUPER + Q, the titlebar button,
    // killactive), the IPC `quit`, and the content's own button.
    //
    // `onClosing` is what makes the WINDOW's close the process's too. Without it
    // the compositor would destroy the window and leave the instance running
    // with nothing on screen -- a stray process that still answers `files ping`
    // (the exact state that made the old launcher report success over an empty
    // screen), and, since every launch now starts its own window rather than
    // looking for a copy to raise, a process nobody could ever reach again.
    function quitApp() {
        // TEMP DIAGNOSTIC: which path is ending this process? The suite keeps
        // losing instances and every path funnels through here, so the JS stack
        // names the caller (onClosing vs the IPC quit vs quitRequested).
        print("[FM-QUIT] quitApp from: " + (new Error().stack || "?"));
        // The last tab change (or pin) may still be inside Persistent's 100 ms
        // write debounce, and this process is about to stop existing: hand the
        // write over NOW, or closing the window loses the tabs it should keep.
        Persistent.flush();
        childReaper.running = true;
    }
    onClosing: function(close) {
        print("[FM-QUIT] onClosing: the window was closed (compositor/titlebar/Escape-to-close)");
        close.accepted = true;
        root.quitApp();
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

    // ── IPC: `qs ipc --pid <pid> call files quit|openPath|probe...` ─────
    // The same target the picker instances answer on, so a caller addresses
    // whichever form it has a pid for and does not care which one it is.
    //
    // There is no `open`, `toggle` or `close` here any more. Those existed to
    // drive ONE warm surface -- show it, hide it, ask it to stand down for a bar
    // menu -- and a window has no such state: it is on screen for as long as its
    // process lives, and a second window is a second process. `quit` is what is
    // left, and every launch starts its own window (see the header).
    IpcHandler {
        target: "files"
        function ping(): string { return "files"; }
        // A path, which may be a FOLDER (open it) or a FILE (the desktop's "show
        // this in the file manager": go to the folder it lives in and select it,
        // rather than trying to list a file as though it were a folder). Every
        // caller of this -- the desktop entry, the portal, another app's "show
        // in folder" -- passes whatever it happens to have, and both answers are
        // this one function.
        function openPath(path: string): void {
            content.openPath(path);
        }
        function quit(mode: string): void {
            print("[FM-QUIT] IPC quit mode=" + mode);
            root.quitApp();
        }
        // ── Probe hooks ───────────────────────────────────────────────────
        // The manager, driven and read from a terminal with no pointer
        // involved (scripts/system/files-check.sh asserts on the JSON).
        function probeState(): string { return content.probeState(); }
        function probeList(limit: string): string { return content.probeList(Number(limit)); }
        // A folder's Size cell, which is a tree walk behind a cache: what the
        // rows draw, and what the walker is doing (or not doing) right now.
        function probeSizes(): string { return content.probeSizes(); }
        function forgetSize(path: string): void { FolderSizes.forget(path); }
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
        // The scan fed by hand, so the states a phone has to be in to show them
        // -- refusing, silent, retrying -- are reachable on a machine whose
        // phone answers willingly (scripts/system/files-check.sh).
        function probeMtpFeed(text: string): string { return content.probeMtpFeed(text); }
        function probeMtpMount(name: string): void { content.mountMtp(content.mtpDeviceByName(name)); }
        function probeMtpUnmount(name: string): void { content.unmountMtp(content.mtpDeviceByName(name)); }
        function probeAdvanced(flag: string): void {
            content.showAdvancedVolumes = flag !== "0" && flag !== "false";
        }
        function probeScrollBars(): string { return content.probeScrollBars(); }
        function probeLayout(): string { return content.probeLayout(); }
        // The quiet header as it is DRAWN: the name's size, weight and tracking,
        // the HUD lines under it, and -- the thing a screenshot cannot settle --
        // whether the name really sits ABOVE the command words.
        function probeQuietHeader(): string { return content.probeQuietHeader(); }
        function probeColumns(): string { return content.probeColumns(); }
        function probeHeaderHover(): string { return content.probeHeaderHover(); }
        function probeColumnsAt(index: string): string { return content.probeColumnsAt(index); }
        function probeHit(x: string, y: string): string { return content.probeHit(Number(x), Number(y)); }
        function probeCursorAsks(): string { return content.probeCursorAsks(); }
        // Text and text, in numbers: every pair of labels sharing pixels, with
        // the rects, the z and whether anything clips them.
        function probeTextOverlap(tolerance: string): string { return content.probeTextOverlap(Number(tolerance)); }
        function probeViewMode(mode: string): string { return content.probeViewMode(mode); }
        function probeCut(name: string): string { return content.probeCut(name); }
        function probePaste(path: string): string { return content.probePaste(path); }
        function probeColumnDragBegin(index: string): string { return content.probeColumnDragBegin(index); }
        function probeColumnDragStep(delta: string): string { return content.probeColumnDragStep(delta); }
        function probeColumnDragEnd(): string { return content.probeColumnDragEnd(); }
        // The preview pane's divider: the band, the cursor it asks for, and the
        // same replayable drag.
        function probePreviewDivider(): string { return content.probePreviewDivider(); }
        function probePreviewDragBegin(): string { return content.probePreviewDragBegin(); }
        function probePreviewDragStep(delta: string): string { return content.probePreviewDragStep(delta); }
        function probePreviewDragEnd(): string { return content.probePreviewDragEnd(); }
        // The size knob, as seen in the header: a WINDOW's size is the
        // compositor's (the tiler, a drag), so this pins the CONTENT instead.
        // The assertions that use it ask how the bar, the panes and the preview
        // share a width, and that question is the same one whatever is doing the
        // sizing -- so the check keeps its meaning instead of dying with the
        // card.
        function probeResize(width: string, height: string): void {
            // 0 on either axis RELEASES the pin on that axis, so a script can
            // hand the window its own size back instead of having to relaunch.
            const w = Number(width), h = Number(height);
            root.probeContentWidth = w > 0 ? Math.max(360, w) : 0;
            root.probeContentHeight = h > 0 ? Math.max(300, h) : 0;
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
        // The tile cell the grid chose for the pane's width.
        function probeTileCell(): string { return content.probeTileCell(); }
        // The view controls the bar is showing, and the tile-size step they
        // move. The same pair the dialog answers, so one check can read both
        // forms: what differs between them is which controls are on screen.
        function probeViewControls(): string { return content.probeViewControls(); }
        function probeTileSize(step: string): string { return String(content.probeTileSize(Number(step))); }
        function probeMenuRect(): string { return content.probeMenuRect(); }
        // The command bar's New drop-down, opened the way the word does -- so a
        // check can read the two creates without a pointer on the toolbar.
        function probeCreateMenu(): void { content.openCreateMenu(); }
        function probePath(): string { return content.currentFolderPath(); }
        // Nothing to open: a window IS the state (there is no hidden surface to
        // bring up), so this is navigation and nothing else.
        function probeGo(path: string): void { content.navigateTo(path); }
        // What the app believes about its own WINDOW, next to what the
        // compositor says about it (`hyprctl clients`, asserted in the suite):
        // together those two are how "a window really is on screen" is decided,
        // and neither alone can answer it. `visible: false` with a live process
        // is exactly the state the old launcher used to report success over.
        function probeWindow(): string {
            return JSON.stringify({
                title: root.title,
                visible: root.visible,
                width: Math.round(root.width),
                height: Math.round(root.height),
                contentW: Math.round(content.width),
                contentH: Math.round(content.height),
                picker: content.pickerMode
            });
        }
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
        function probeRenameDialog(): string { return content.probeRenameDialog(); }
        // Types into the NAME box only and commits -- the person's half of the
        // two-box prompt ("I renamed the stem; the .png is the dialog's job").
        function probeRenameStem(stem: string): void { content.renameDraft = stem; content.commitRename(); }
        // Hands the prompt a NAME (not a draft): the prompt splits it into its
        // name and extension boxes, so a script commits what a person typing
        // that name would commit -- "notes.md" keeps its .md either way.
        function probeRenameCommit(name: string): void { content.probeSetPromptName(name); content.commitRename(); }
        // Zip and unzip, driven the way the menu drives them: the same set the
        // rows act on (one name here, the whole selection there) and the same
        // helpers, so a check exercises the real path rather than a copy of it.
        function probeCompress(name: string): void {
            content.compressSelection([content.currentFolderPath() + "/" + name]);
        }
        function probeExtract(name: string): void {
            content.extractArchive(content.currentFolderPath() + "/" + name, false);
        }
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
        // The card that rides with the pointer: probeDragGrab photographs it the
        // way a press does, and probeDragCard reports what came back.
        function probeDragGrab(name: string, saveTo: string): string { return content.probeDragGrab(name, saveTo); }
        function probeDragCard(name: string): string { return content.probeDragCard(name); }
        function probeDragWarm(name: string): string { return content.probeDragWarm(name); }
        function probeDragBegin(name: string): string { return content.probeDragBegin(name); }
        // ── The other half: what the window does with something dropped ON it
        // The urls travel as one string with "|" between them, because a path
        // contains spaces and everything else a shell writes, and an IPC
        // signature that had to agree about quoting would be a second place to
        // get it wrong.
        function probeDropPlan(urls: string, dest: string, move: string): string {
            const list = String(urls ?? "").length > 0 ? String(urls).split("|") : [];
            return content.probeDropPlan(list, dest, move);
        }
        function probeDrop(urls: string, dest: string, move: string): string {
            const list = String(urls ?? "").length > 0 ? String(urls).split("|") : [];
            return content.probeDrop(list, dest, move);
        }
        function probeDropState(): string { return content.probeDropState(); }
        function probeDropAreas(): string { return content.probeDropAreas(); }
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
        // What a double-click does with a file type NOTHING has claimed: the
        // text editor for text, the chooser for anything else. Asked as a
        // question so a check can read the rule without opening a window.
        function probeOpenPlan(mime: string): string { return content.probeOpenPlan(mime); }
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
        // ── Open with ────────────────────────────────────────────────────
        // The chooser, driven from a terminal: open it on a file, read the list
        // it resolved, launch from it, or close it. `probeOpenName` is the
        // DOUBLE-CLICK a no-handler file has to survive -- the same call
        // activate() makes.
        function probeOpenName(name: string): int { return content.probeOpenName(name); }
        function probeOpenWith(): string { return content.probeOpenWith(); }
        function probeOpenWithRun(id: string): void {
            const app = content.openWithApps.find(a => a.id === id);
            if (app) content.runOpenWith(app);
        }
        function probeOpenWithCancel(): void { content.closeOpenWith(); }
        // Tab control.
        function tabCount(): int { return content.tabs.length; }
        function tabActive(): int { return content.activeTab; }
        function tabNames(): string { return content.tabs.map(t => content.tabLabel(t)).join("|"); }
        function tabPath(): string { return content.currentFolderPath(); }
        function tabNew(path: string): void { content.newTab(path && path.length > 0 ? path : undefined); }
        function tabSelect(index: string): void { content.selectTab(Number(index)); }
        function tabClose(index: string): void { content.closeTab(Number(index)); }
    }

    // NO application-wide Escape binding here, deliberately. One stood here and
    // it was wrong in two ways: it fired whenever the app had focus rather than
    // when the key reached the content, and it called quitApp() -- it ENDED the
    // process, where in the popup days Escape only meant "leave". Escape is the
    // content's key layer's to answer (it knows a drive menu from a rename box
    // from a path edit), and its answer in app mode is quitRequested, which the
    // window above turns into closing the window -- and the process with it,
    // which is now the same thing.
}
