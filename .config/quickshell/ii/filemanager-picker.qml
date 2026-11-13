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
// SHAPE (2026-10-23). The card is 1100x760 -- the same size the Files window
// asks for -- centred on its screen, and the card itself is 6% see-through so
// the application that asked for the file is a tint behind it.
//
// The SURFACE is the whole screen again, and that is a decision with a reason
// rather than a return: "tapping outside the file manager popup window ...
// should dismiss the popup window like pressing escape" (REQUESTED 2026-10-23)
// cannot be done from a surface the size of the card. A layer surface receives
// nothing outside its own rectangle, so the only local way to hear a press
// outside is to own that area. Two alternatives were measured and both failed
// in this process: a Hyprland focus grab (the shell's own popup mechanism) is
// armed and stays armed while a press on the desktop goes past it -- no clear,
// no dismissal -- and the event stream that would report a click is not
// delivered to a standalone instance at all (see the poll further down).
//
// So: a transparent catcher behind the card, which is what the earlier "big
// invisible background" complaint was about -- except that this one has a job
// now. A press out there ANSWERS the dialog, so the click is not swallowed for
// nothing, and the area that used to be an invisible no-man's-land is the
// dismissal target the request asked for.
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
    // Anchored to all four edges, which is what makes the surface the screen:
    // the card is a child of it (see `card` below), and the pixels around the
    // card belong to the catcher that answers a press outside.
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "quickshell:files"
    // ── OVERLAY, always ────────────────────────────────────────────────
    // REQUESTED (2026-10-24): "when opening file manager to add file to an app
    // make sure it shows in front of the desktop app ALSO DURING FULLSCREEN".
    //
    // It did not, and the reason was a binding that is gone now: the layer used
    // to be `PopupApps.yieldLayer ? Top : Overlay`, so the dialog dropped to the
    // Top layer as soon as that flag was set -- and the flag was set by THIS
    // FILE, on every open (setYield(true) in Component.onCompleted, which nothing
    // here ever needed: the flag means "a sibling must sit above me").
    //
    // Measured on Hyprland 0.56.2 with a real fullscreen window up: a layer
    // surface that CHANGES layer while mapped comes out of it invisible -- the
    // compositor fades it (`hyprctl layers` says `alpha: 0` for
    // `quickshell:files`, while the dialog's own probe says `visible=true` and
    // `card=1100x760`, its card grab renders, and the screen shows only the app).
    // A surface mapped fresh in Top, or in Overlay, is alpha 1 and draws over the
    // fullscreen window; only the change is fatal. So the dialog keeps ONE layer
    // for its whole life.
    //
    // Overlay and not Top: it is the layer the rest of this shell puts its
    // popups in (bar panels, notifications, OSD, the sidebars' show-in-fullscreen
    // mode), and a file dialog is the one popup that MUST outrank the window that
    // asked for the file. The wallpaper explorer's old "rise above the dialog"
    // arrangement went with the flag: a dialog that can disappear is worse than an
    // explorer the dialog happens to cover, and the explorer opens from a keybind
    // of its own while a dialog is answered.
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property real anchorMargin: Appearance.sizes.hyprlandGapsOut

    // The screen the dialog is centred on, so it can never ask for more of it
    // than the screen has. A panel's own screen is not readable from here -- the
    // QsWindow context belongs to its children, and a layer surface cannot know
    // which monitor asked for it either -- so this is the first screen, clamped;
    // on a one-panel laptop that is simply the panel.
    readonly property real screenW: Quickshell.screens.length > 0 ? Quickshell.screens[0].width : 0
    readonly property real screenH: Quickshell.screens.length > 0 ? Quickshell.screens[0].height : 0

    // The size the dialog asks for: the same 1100x760 the Files window opens at,
    // which is what makes the two forms one app rather than two programs, clipped
    // to the screen with the house gap around it. On a small panel the dialog
    // shrinks instead of becoming that panel with rounded corners; while the
    // screen is unknown it falls back to the size it asks for on this one.
    readonly property real dialogWidth: root.screenW > 0
        ? Math.min(1100, Math.round(root.screenW - root.anchorMargin * 2)) : 1100
    readonly property real dialogHeight: root.screenH > 0
        ? Math.min(760, Math.round(root.screenH - root.anchorMargin * 2)) : 760

    Component.onCompleted: {
        // The theme has to be applied in THIS process, not only in the shell that
        // launched it: this is its own Quickshell instance (same reason as
        // filemanager.qml's own call), and without it the dialog draws on the
        // stock light palette -- a light-grey card under dark-mode file rows,
        // which is the washed-out look the picker was carrying.
        MaterialThemeLoader.reapplyTheme();
    }

    // ── A press outside the dialog answers it, like Escape ──────────────
    //
    // REQUESTED (2026-10-23): "tapping outside the file manager popup window
    // that opens with 'add file' click. Should dismiss the popup window like
    // pressing escape."
    //
    // ── A press outside the card answers the dialog ─────────────────────
    //
    // REQUESTED (2026-10-23): "tapping outside the file manager popup window
    // that opens with 'add file' click. Should dismiss the popup window like
    // pressing escape."
    //
    // The CARD is the dialog; this item is not drawn. It exists for the
    // geography: a layer surface may only receive the presses that fall inside
    // it, so owning the screen is the only way to hear the one that falls
    // outside. Fully transparent on purpose -- a dim veil over the requesting
    // application is a look nobody asked for, and the tint of the app through
    // the card is already the dialog's whole acknowledgement of it.
    //
    // Two mechanisms were tried first and both failed HERE, in this separate
    // process, which is why this is a plain MouseArea:
    //   * the shell's shared GlobalFocusGrab service registered the dialog and
    //     then cancelled it about a second after opening, with no click
    //     anywhere -- in this instance GlobalStates closes "transient popups"
    //     whenever its active workspace changes, including the one hyprctl
    //     reports as the process boots;
    //   * a raw HyprlandFocusGrab armed correctly (and a workspace switch
    //     cleared it, which is why switching desktops works), but a real press
    //     on the desktop outside the card went past it: measured with a
    //     synthesised click, the grab stayed held and the dialog stayed up.
    //
    // `dismissTopLevel`, not `pickerCancel`: it is Escape's own ladder
    // (FileManagerContent.dismissTopLevel), so this gesture and that key answer
    // with the same verb rather than two that drift apart. In practice the
    // dialog is what ends up answering even when a menu is open -- Qt's Popup
    // closes itself on a press outside before this handler runs, so `menuOpen`
    // is already false here (measured) -- and that is the right reading of the
    // request anyway: a press out there is a press on the dialog, not on the
    // menu inside it.
    MouseArea {
        id: pickerBackdrop
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: (mouse) => {
            if (root.pickerWritten)
                return;
            console.log("[picker] press outside the card -- dismissing");
            content.dismissTopLevel();
        }
    }

    // ── Leaving when the desktop under it changes ───────────────────────
    //
    // REQUESTED (2026-10-23): the same sentence, continued -- "switching
    // desktops ... Should dismiss the popup window like pressing escape".
    //
    // A dialog is an answer to a question asked by a window on the desktop it
    // was opened on. Switch away and the question is not in front of you any
    // more: the dialog keeps holding the session's input on a desktop where
    // nobody is looking at it, and (until now) stayed there until it timed out
    // or was cancelled from the page it came from.
    //
    // ── Why this is ASKED and not watched ───────────────────────────────
    //
    // The obvious version listens: `Hyprland.focusedMonitor.activeWorkspace`,
    // or HyprlandData, which reads the same thing on the compositor's own
    // events. Both are dead in THIS process. Measured before writing the rule:
    // a probe instance printed its workspace once at startup and then not one
    // raw event for a whole switch away and back (`PROBE event` never fired),
    // and in the dialog both readers sat on `1` across a switch to `4` while
    // the session was on `4`. A dialog is not the shell: it is a separate
    // Quickshell instance that never sees that event stream, so a rule built on
    // it would be a rule that never fires -- which is exactly what the first
    // two attempts did, silently, the dialog just staying up.
    //
    // `hyprctl` is the reader that works from anywhere, so the desktop is
    // RE-READ twice a second, for as long as the dialog is unanswered. Polling
    // is the honest shape here: the question is cheap (one short-lived fork),
    // the answer only matters while the dialog is up, and a dialog that is
    // dismissed within a second makes the cost invisible. Half a second, not
    // less, because a fork of `hyprctl` is the same thing the shell itself
    // rate-limits -- four a second for a whole dialog lifetime is a hitch
    // looking for somewhere to happen, and nobody can switch desktops and
    // notice 500ms of latency in a dialog that is already leaving.
    //
    // Which desktop it opened ON is the FIRST answer rather than a read at
    // construction -- before the first answer there is nothing to compare
    // against, and 0 is "not known yet" rather than a workspace.
    property int pickerDesktop: 0
    // Counted for the probe below: "no read ever answered" and "every read
    // answered the same workspace" behave identically, and only this tells
    // them apart from a terminal.
    property int pickerDesktopReads: 0

    function pickerSawDesktop(raw: string): void {
        let id = 0;
        try {
            id = Number(JSON.parse(String(raw ?? "")).id ?? 0);
        } catch (error) {
            return;                           // half-written read: skip it
        }
        if (!(id > 0))
            return;
        root.pickerDesktopReads++;
        if (root.pickerDesktop <= 0) {
            root.pickerDesktop = id;          // the first answer: this is opening
            return;
        }
        if (id === root.pickerDesktop)
            return;
        // Cancels the DIALOG, not just the top level: the desktop it belonged
        // to is gone, so a drive menu left open in it has nothing to return to.
        console.log(`[picker] desktop ${root.pickerDesktop} -> ${id} -- dismissing`);
        root.pickerCancel();
    }

    Timer {
        id: pickerDesktopPoll
        interval: 500
        repeat: true
        running: !root.pickerWritten
        onTriggered: {
            // Restart rather than a bare `running = true`: a read that is still
            // in flight would be silently skipped by the assignment, and the
            // poll would then drift for as long as the fork takes.
            pickerDesktopProbe.running = false;
            pickerDesktopProbe.running = true;
        }
    }

    Process {
        id: pickerDesktopProbe
        command: ["hyprctl", "activeworkspace", "-j"]
        stdout: StdioCollector {
            onStreamFinished: root.pickerSawDesktop(String(this.text ?? ""))
        }
    }

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
        // ── Where it opens ───────────────────────────────────────────────
        // The folder the APPLICATION named wins when it named one: a save
        // dialog for a document belongs beside that document, not wherever the
        // last unrelated upload went. Almost nobody names one, though -- a
        // browser's "Add file" passes no current_folder -- so in that (the
        // common) case the dialog reopens where the last one ANSWERED, from
        // Persistent.states.pickerDir. That is the request: pick a file in
        // a shared folder once, and the next "add file" starts there instead of
        // home.
        if (root.pickerStartDir.length > 0)
            content.pickerNavigate(root.pickerStartDir);
        else {
            root.pickerWantsRemembered = true;
            root.openRememberedFolder();
        }
    }

    // ── The remembered folder, checked before it is used ───────────────
    //
    // A remembered path can be gone -- the project folder was renamed, the
    // drive was unplugged -- and navigating to a folder that does not exist
    // leaves an empty list with no explanation, which reads as "the dialog is
    // broken". So the path is TESTED first and simply ignored when it is not
    // there, which falls back to the file manager's own default (home) and to
    // a dialog that still works.
    //
    // `Persistent.ready` gates it: the dialog is its own process and beats the
    // state file's load often enough to matter. When it is not ready yet the
    // probe waits for the adapter (Connections below) instead of reading an
    // empty `states` and silently opening at home.
    property bool pickerWantsRemembered: false

    function openRememberedFolder() {
        if (!root.pickerWantsRemembered || !Persistent.ready) return;
        root.pickerWantsRemembered = false;
        const remembered = String(Persistent.states?.pickerDir ?? "");
        if (remembered.length === 0) return;
        // `$1`, not string interpolation: the path is handed over as an
        // argument, so a quote or a space in a folder name is not syntax.
        pickerRememberedProbe.command = ["sh", "-c",
            'test -d "$1" && printf yes || printf no', "sh", remembered];
        pickerRememberedProbe.running = true;
    }

    Process {
        id: pickerRememberedProbe
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                if (String(this.text ?? "").trim() !== "yes") return;
                content.pickerNavigate(String(Persistent.states?.pickerDir ?? ""));
            }
        }
    }

    Connections {
        target: Persistent
        function onReadyChanged() { root.openRememberedFolder(); }
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
        // The desktop the switch-away rule is reading, and how many reads have
        // answered: `openedOn=0` with a growing `reads` is a rule that armed, and
        // `reads=0` is a compositor that never answered at all.
        // Writes the card to a PNG. The compositor is not the only way to look
        // at a layer surface, and it is not the reliable one: a surface this
        // dialog can report as `visible=true` can still be missing from a
        // screenshot (a fullscreen window above it, a layer rule below it), and
        // then a layout question has no evidence either way. `grabToImage`
        // photographs the item itself, so what comes out is what the dialog
        // draws regardless of what is on top of it.
        function probeGrab(path: string): string {
            card.grabToImage(function (result) {
                console.log("[picker] card grab ->", path, result.saveToFile(path));
            }, Qt.size(1100, 760));
            return "grabbing:" + path;
        }
        function probeDesktop(): string {
            // `visible` is reported because "the dialog did not appear" has two
            // completely different causes that read the same from a screenshot:
            // a surface that is not mapped, and one that is mapped but sitting
            // under something. The compositor's own answer for the layer is
            // `hyprctl layers` (a `a: 0` there is this flag being false).
            return `openedOn=${root.pickerDesktop} reads=${root.pickerDesktopReads}`
                + ` visible=${root.visible}`
                + ` surface=${Math.round(root.width)}x${Math.round(root.height)}`
                + ` card=${Math.round(card.width)}x${Math.round(card.height)}`;
        }
        function probeScrollBars(): string { return content.probeScrollBars(); }
        function probeList(limit: string): string { return content.probeList(Number(limit)); }
        // The dialog draws the same rows, so a folder's Size cell is read here
        // too: the two roots answer one `files` target and a caller that has a
        // pid for the dialog must not get "function not found" for a question
        // the window answers.
        function probeSizes(): string { return content.probeSizes(); }
        function forgetSize(path: string): void { FolderSizes.forget(path); }
        function probeVolumes(): string { return content.probeVolumes(); }
        function probeMenu(): string { return content.probeMenu(); }
        // Where each details row's blank (folder-background) tail begins.
        function probeNameBlank(): string { return content.probeNameBlank(); }
        // The tile cell the grid chose for the pane's width.
        function probeTileCell(): string { return content.probeTileCell(); }
        // The dialog's view controls: list/grid, tile size, hidden files. This
        // is the surface the request was about ("in the file open screen ...
        // see invisible files or change the size"), so the check reads it here
        // and not only in the window.
        function probeViewControls(): string { return content.probeViewControls(); }
        function probeTileSize(step: string): string { return String(content.probeTileSize(Number(step))); }
        function probePath(): string { return content.currentFolderPath(); }
        function probeGo(path: string): void { root.visible = true; content.navigateTo(path); }
        // The dialog draws the same content, so the label treatment has to be
        // read on this root too, not only on the window's (probeView above is
        // the same setter the window's root calls probeViewMode).
        function probeTextOverlap(tolerance: string): string { return content.probeTextOverlap(Number(tolerance)); }
        function probeBack(): void { content.goBack(); }
        function probeForward(): void { content.goForward(); }
        function probeUp(): void { content.goUp(); }
        function probeSelect(name: string): void { content.selectName(name); }
        function probeActivate(index: string): void { content.activate(Number(index)); }
        function probeView(mode: string): void { content.viewMode = mode === "tiles" ? "tiles" : "details"; }
        // The keyboard's route through the dialog, the same four hooks the
        // window answers: since 2026-10-24 the toolbar is a Tab stop here too
        // (it carries the view controls), and "Tab cannot reach it" is a claim
        // worth being able to check without a pair of hands.
        function probeFocusArea(): string { return content.focusArea; }
        function probeFocusLabel(): string { return content.focusLabel(); }
        function probeFocusStep(delta: string): void {
            content.stepFocusArea(Number(delta) < 0 ? -1 : 1);
        }
        function probeFocusActivate(): void { content.activateFocus(); }
        function probeHidden(flag: string): void { content.showHidden = flag === "1" || flag === "true"; }
        function probeExtensions(flag: string): void { content.showExtensions = flag === "1" || flag === "true"; }
        function probeFilter(text: string): void { content.filter = text; }
        function probeSort(field: string, reversed: string): void {
            content.sortField = Number(field);
            content.sortReversed = reversed === "1" || reversed === "true";
        }
        function probeRename(name: string): void { content.beginRename(content.currentFolderPath() + "/" + name); }
        function probeRenameDialog(): string { return content.probeRenameDialog(); }
        // Name box only, then commit -- same contract as the window's.
        function probeRenameStem(stem: string): void { content.renameDraft = stem; content.commitRename(); }
        // Same contract as the window's: a NAME in, split into the prompt's two
        // boxes, committed as that name.
        function probeRenameCommit(name: string): void { content.probeSetPromptName(name); content.commitRename(); }
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
        function probeOpenPlan(mime: string): string { return content.probeOpenPlan(mime); }
        // Menu control: a menu is a pointer gesture, and this stack can be
        // driven end-to-end without one.
        function menuAt(x: string, y: string, target: string): void {
            content.openMenu(Number(x), Number(y), target ?? "");
        }
        // The toolbar's New drop-down; in a dialog it is hidden, so this is the
        // same two rows the app's word opens (the suite drives one path for
        // both forms).
        function probeCreateMenu(): void { content.openCreateMenu(); }
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
        // ── The save prompt's two boxes ──────────────────────────────────
        // The extension box only becomes a field on a double click, and a
        // synthetic pointer cannot click a layer surface on this box (see
        // TodoWidget.qml for the same finding), so the dialog exposes the same
        // functions its handlers call. `probeSaveExtOpen` is the double click.
        function probeSavePrompt(): string { return content.probeSavePrompt(); }
        function probeSaveStem(stem: string): string { return content.probeSaveStem(stem); }
        function probeSaveExtOpen(): string { return content.probeSaveExtOpen(); }
        function probeSaveExt(ext: string): string { return content.probeSaveExt(ext); }
        function probeSaveExtClose(): string { return content.probeSaveExtClose(); }
        // The replace prompt: Save on a name that is already taken asks first,
        // and these are the two answers. Readable without a pointer for the
        // same reason the two boxes are -- a layer surface takes no synthetic
        // click -- and because "it asked" is exactly the claim worth checking.
        function probeSaveReplace(): string { return content.probeSaveReplace(); }
        function probeSaveReplaceAccept(): void { content.acceptSaveReplace(); }
        function probeSaveReplaceCancel(): void { content.cancelSaveReplace(); }
        function probePickerMode2(kind: string, directory: string): void {
            content.pickerOp = kind;
            content.pickerDirectory = directory === "1" || directory === "true";
        }
    }

    // ── The dialog ──────────────────────────────────────────────────────
    // The card is the dialog: 1100x760 (or the screen's size minus the house
    // gap), centred on it, over the catcher that answers a press outside.
    // Everything outside this rectangle belongs to `pickerBackdrop` above, so a
    // press there is the dismissal rather than a click on the app behind -- and
    // a press INSIDE it is a press on the dialog.
    Rectangle {
        id: card
        width: root.dialogWidth
        height: root.dialogHeight
        anchors.centerIn: parent
        radius: Appearance.rounding.windowRounding
        // The app's own surface colour with 18% taken out: the dialog reads as a
        // dialog floating over the application that asked for the file, and the
        // page behind it is a hint, not a second copy of itself. What this
        // replaces was 0.28 of a DIFFERENT colour (the m3 background) over a
        // screen-sized scrim, and that is where the file rows were fighting the
        // browser's own text for legibility.
        //
        // WHAT the transparency shows is not this file's decision, and it used
        // to be the wrong thing: this window is a layer surface, the base
        // Hyprland config blurs every `quickshell:*` layer, and a blurred layer
        // samples the WALLPAPER unless its rule says otherwise. So the desktop's
        // artwork -- at the wallpaper's own screen position, over any app -- is
        // what showed through the file rows, which is the report: "the
        // invisibility should be through the app the file manager file selection
        // popup is, not look through it to display the wallpaper".
        // custom/rules.lua now gives `quickshell:files` the bar popups' trio
        // (blur, ignore_alpha 0, xray off), so what the card frosts is the
        // requesting application.
        //
        // 0.06, not the 0.18 it was. The transparency was asked down
        // ("not invisible so much"): at 0.18 the page behind was legible THROUGH
        // the file rows -- a browser's own text sitting on top of the names you
        // are trying to read, with the rows losing every fight over legibility.
        // What the see-through part is FOR is a hint of where the dialog came
        // from, so it can be faint: 6% leaves the app's colour and layout as a
        // tint under the card, and nothing legible from behind reaches the file
        // list.
        //
        // The backdrop is the APPLICATION, not the wallpaper: this window is a
        // layer surface, and custom/rules.lua gives `quickshell:files`
        // `xray = false` (the base config turns xray on for every layer, which
        // is what made a transparent layer sample the desktop's artwork instead
        // of the window underneath it). With that off, what shows faintly here
        // is the app that asked for the file -- and the wallpaper only where
        // there is genuinely no window behind the dialog.
        color: CF.ColorUtils.transparentize(Appearance.colors.colTerminalSurfaceSolid, 0.06)
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
        clip: true

        // A press on the card is a press on the DIALOG, including the parts of
        // it that draw nothing (the 6px inset around the content, and the empty
        // bottom of a folder with no rows). Without this, those pixels are
        // transparent to `pickerBackdrop` underneath and a press on the card's
        // own edge would dismiss the dialog the same way a press on the desktop
        // does. It accepts and does nothing, which is exactly right: the press
        // was aimed at the dialog, and the dialog has nothing to answer it with.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
        }

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
