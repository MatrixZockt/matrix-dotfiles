// Files -- the popup app of the popup-window group ("files" in
// services/PopupApps.qml and custom/popup.lua's POPUPS).
//
// The scaffolding (veil, card, live close-drag, presence, morph) is the
// settings app's, with the file manager in place of the settings pages. The
// manager itself is QML: Qt.labs.folderlistmodel for listings,
// FolderListModelWithHistory for back/forward, and gio for the mutating
// operations (trash/rename/mkdir) so deleted files go to the Trash, never to
// /dev/null.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import qs.modules.common.models
import qs.modules.filemanager

PanelWindow {
    id: root

    exclusiveZone: -1
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "quickshell:files"
    // Yield to layer-shell siblings (wallpaper explorer, portal dialogs): see
    // PopupApps.yieldLayer. Top is below Overlay, so the picker rises above
    // the veil while it is open.
    WlrLayershell.layer: root.pickerMode
        ? WlrLayer.Overlay // the dialog is always the topmost surface
        : (PopupApps.yieldLayer ? WlrLayer.Top : WlrLayer.Overlay)
    WlrLayershell.keyboardFocus: root.pickerMode ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

    // ── Anchored, not floating ─────────────────────────────────────────────
    // These apps used to sit as a centered card floating in the middle of a
    // veil. The house rule now is "attached or fullscreen, nothing in
    // between", so the card is an EDGE-ANCHORED panel: it fills the screen
    // minus a thin margin (which keeps a strip of veil clickable to dismiss
    // it), keeps only a small rounding, and stays slightly transparent so the
    // blurred desktop shows through it.
    readonly property real anchorMargin: Appearance.sizes.hyprlandGapsOut
    // ── Panel geometry ────────────────────────────────────────────────────
    // The picker shares the popup's anchored geometry now. It used to keep a
    // compact centered dialog shape -- but the house rule is "attached or
    // fullscreen, nothing in between", and a floating card in the middle of
    // the screen is exactly the in-between the owner banned. A dialog by
    // contract, yes; still an edge-anchored panel on screen.
    readonly property real cardWidth: root.width - root.anchorMargin * 2
    readonly property real cardHeight: root.height - root.anchorMargin * 2

    // ── Close/morph timing (same contract as settings.qml) ────────────────
    readonly property int closeAnimMs: 340
    property bool veilFading: false
    readonly property int veilFadeMs: 160
    readonly property int throwMs: 230
    property bool thrown: false
    property var morphTarget: null
    property bool morphed: false
    property bool morphFading: false
    property bool handedOver: false
    readonly property real morphGrowScale: 1.22
    property bool closing: false

    // ── Picker mode (portal FileChooser) ─────────────────────────────────
    // A dedicated small instance launched by ii-portal (the desktop's own
    // xdg-desktop-portal backend): no veil, compact card, no morph, no
    // presence. Job in $XDG_RUNTIME_DIR/ii-portal/<token>.json, result
    // written next to it, then the process quits.
    readonly property bool pickerMode: (Quickshell.env("II_FILES_PICKER") ?? "").length > 0
    readonly property string pickerToken: root.pickerMode ? Quickshell.env("II_FILES_PICKER") : ""
    readonly property string pickerDir: `${Quickshell.env("XDG_RUNTIME_DIR")}/ii-portal`

    // ── Presence (registry row: services/PopupApps.qml) ───────────────────
    function present() {
        if (root.pickerMode) return; // a portal dialog is not the Files popup
        const how = TouchpadSwipe.available ? "live" : "plain";
        PopupApps.present("files", Quickshell.processId, how);
    }
    function unpresent() {
        PopupApps.unpresent("files");
    }
    Connections {
        target: TouchpadSwipe
        function onAvailableChanged() {
            if (!root.morphed && !root.pickerMode) root.present();
        }
    }
    Binding {
        target: TouchpadSwipe
        property: "travelScale"
        value: root.height
    }
    // The picker is a portal dialog, not the Files popup: it must not claim
    // the popup's presence file, but it DOES have to sit above an open popup
    // -- it publishes the yield flag so popups drop from Overlay to Top while
    // the dialog is up (same mechanism the wallpaper explorer uses).
    Component.onCompleted: {
        if (root.pickerMode) PopupApps.setYield(true);
        else root.present();
    }
    Component.onDestruction: {
        if (root.pickerMode) PopupApps.setYield(false);
        else root.unpresent();
    }

    // ── Close: the window-style shrink, then the facade fade, then cleanup ─
    function quitApp(mode) {
        if (root.pickerMode) { // closing a dialog means cancelling it
            root.pickerCancel();
            return;
        }
        if (root.closing) return;
        root.closing = true;
        if (root.morphed) {
            filesHost.closeWindow();
            return;
        }
        if (mode === "live") {
            const draggedOpacity = card.opacity;
            root.thrown = true;
            cardFlyY.duration = root.throwMs;
            cardFlyY.easing.type = Easing.OutCubic;
            cardFlyY.from = card.y;
            cardFlyY.to = root.height + card.height;
            cardFlyY.start();
            cardFlyO.duration = root.throwMs;
            cardFlyO.from = draggedOpacity;
            cardFlyO.to = 0;
            cardFlyO.start();
            flyOutTimer.start();
            return;
        }
        closeTimer.start();
    }

    Timer {
        id: closeTimer
        interval: root.closeAnimMs
        onTriggered: {
            root.veilFading = true;
            veilFadeTimer.start();
        }
    }
    Timer {
        id: flyOutTimer
        interval: 300
        onTriggered: {
            root.veilFading = true;
            veilFadeTimer.start();
        }
    }
    Timer {
        id: veilFadeTimer
        interval: root.veilFadeMs
        onTriggered: {
            root.unpresent();
            // Same teardown as the other two hosts: the network watcher this
            // process mounted must go with it.
            Network.stopStrayProcesses();
            childReaper.running = true;
        }
    }
    Process {
        id: childReaper
        property string pid: `${Quickshell.processId}`
        command: ["sh", "-c", `me=$$; kids=$(pgrep -P ${pid} 2>/dev/null | grep -vw "$me"); [ -n "$kids" ] && kill $kids 2>/dev/null; exit 0`]
        onExited: Qt.quit()
    }

    // ── Popup → real desktop window (the morph; identical to settings.qml) ─
    Timer {
        id: morphTimer
        interval: 25
        onTriggered: root.becomeWindow()
    }
    function morphToWindow() {
        if (root.morphed || root.closing || root.pickerMode) return;
        root.morphTarget = { x: 0, y: 0, width: root.width, height: root.height };
        root.morphFading = true;
        morphTimer.restart();
    }
    function becomeWindow() {
        if (root.morphed) return;
        root.morphed = true;
        filesHost.spawn(root.morphTarget.x, root.morphTarget.y,
            root.morphTarget.width, root.morphTarget.height);
    }

    // The real window, watched the same way settings.qml watches its host:
    // HyprlandData re-reads clients on every compositor event, so the moment
    // the window is mapped AND fullscreen the layer unmapped in one step.
    readonly property var morphWindow: {
        const want = PopupApps.self("files").title;
        const list = HyprlandData.windowList ?? [];
        for (let i = 0; i < list.length; i++)
            if (list[i].title === want && list[i].pid === Quickshell.processId)
                return list[i];
        return null;
    }
    readonly property bool morphWindowReady: root.morphWindow !== null
        && (root.morphWindow.fullscreen ?? 0) > 0
    onMorphWindowReadyChanged: if (root.morphWindowReady) root.handOver()

    function handOver() {
        if (!root.morphed || root.handedOver) return;
        root.handedOver = true;
        root.visible = false;
        root.unpresent();
    }
    // Fallback if the compositor event is lost.
    Timer {
        id: settleTimer
        interval: 450
        running: root.morphed && !root.handedOver
        onTriggered: root.handOver()
    }

    // ── Live close-drag (the card follows the fingers; settings.qml's) ─────
    property real liveBaseX: 0
    property real liveBaseY: 0
    property bool liveDragging: false
    Connections {
        target: TouchpadSwipe
        function onDragStarted() {
            if (root.morphed || root.closing || root.pickerMode) return;
            cardCloseX.stop(); cardCloseY.stop();
            cardBackX.stop(); cardBackY.stop(); cardBackO.stop();
            cardFlyY.stop(); cardFlyO.stop();
            root.liveBaseX = card.x;
            root.liveBaseY = card.y;
            root.liveDragging = true;
        }
        function onDragMoved(offset) {
            if (!root.liveDragging) return;
            card.y = root.liveBaseY + offset;
            card.rotation = 0;
            card.opacity = Math.max(0.4, 1 - offset / (root.height * 1.4));
        }
        function onDragEnded(offset, dismissed) {
            if (!root.liveDragging) return;
            root.liveDragging = false;
            if (dismissed) {
                root.quitApp("live");
                return;
            }
            cardBackX.from = card.x; cardBackX.to = root.liveBaseX; cardBackX.start();
            cardBackY.from = card.y; cardBackY.to = root.liveBaseY; cardBackY.start();
            cardBackO.from = card.opacity; cardBackO.to = 1; cardBackO.start();
        }
        function onDragCancelled() {
            if (!root.liveDragging) return;
            root.liveDragging = false;
            cardBackX.from = card.x; cardBackX.to = root.liveBaseX; cardBackX.start();
            cardBackY.from = card.y; cardBackY.to = root.liveBaseY; cardBackY.start();
            cardBackO.from = card.opacity; cardBackO.to = 1; cardBackO.start();
        }
    }

    // ── IPC: `qs ipc --pid <pid> call files open|quit|morphToWindow` ───────
    IpcHandler {
        target: "files"
        function ping(): string { return "files"; }
        function open(): void {
            root.visible = true;
        }
        function quit(mode: string): void {
            root.quitApp(mode === "live" ? "live" : "in");
        }
        function morphToWindow(): void {
            root.morphToWindow();
        }
        // Context-menu control, for the same reason the picker has its own
        // hooks: a menu is a pointer gesture, and this stack can be driven
        // end-to-end without one. `menuAt x y [target]` opens it as if the
        // right-click had landed there (empty target == the folder menu).
        function menuAt(x: string, y: string, target: string): void {
            content.openMenu(Number(x), Number(y), target ?? "");
        }
        function menuCount(): int { return content.menuItems.length; }
        function menuRun(index: string): void {
            if (!root.visible) root.visible = true;
            const i = Number(index);
            if (i >= 0 && i < content.menuItems.length) content.runMenu(content.menuItems[i]);
        }
        function menuClose(): void {
            content.closeMenu();
        }
        // Tab control. Same rationale as the menu hooks above: swapping tabs
        // is a pointer/keyboard gesture, and this stack can be driven
        // end-to-end without either.
        function tabCount(): int { return content.tabs.length; }
        function tabActive(): int { return content.activeTab; }
        function tabNames(): string { return content.tabs.map(t => content.tabLabel(t)).join("|"); }
        function tabPath(): string { return content.currentFolderPath(); }
        function tabNew(path: string): void { content.newTab(path && path.length > 0 ? path : undefined); }
        function tabSelect(index: string): void { content.selectTab(Number(index)); }
        // `index` is required by the IPC transport; -1 means "the active tab".
        function tabClose(index: string): void { content.closeTab(Number(index)); }
        // Picker dialog control. The portal path never needs it (the dialog
        // drives itself from II_FILES_PICKER); it exists so the picker can be
        // driven end-to-end without a pointer.
        function pickerAcceptWith(urisJson: string): void {
            if (!root.pickerMode) return;
            let uris = urisJson;
            try { uris = JSON.parse(urisJson); } catch (e) { /* bare path */ }
            root.pickerAccept(Array.isArray(uris) ? uris : [uris]);
        }
        function pickerCancelNow(): void {
            if (root.pickerMode) root.pickerCancel();
        }
    }

    // ── Picker mode plumbing ─════════════════════════════════════════════
    // Job/result exchange with the ii-portal daemon (pure files, the proven
    // cross-process pattern in this shell).
    // Mode/state came from II_FILES_PICKER at the top of the file; the job
    // file adds what the dialog needs and the result writer closes the loop.
    property string pickerOp: "open"
    property string pickerStartDir: ""
    property string pickerName: ""
    property bool pickerDirectory: false
    property bool pickerWritten: false

    FileView {
        id: pickerJob
        path: root.pickerMode ? `${root.pickerDir}/${root.pickerToken}.json` : ""
        watchChanges: false
        onLoaded: root.pickerJobLoaded()
        onLoadFailed: if (root.pickerMode) root.pickerCancel()
    }

    function pickerJobLoaded() {
        let job = {};
        try { job = JSON.parse(pickerJob.text()); } catch (e) {
            root.pickerCancel();
            return;
        }
        root.pickerOp = job.op ?? "open";
        root.pickerStartDir = job.dir ?? "";
        root.pickerName = job.name ?? "";
        root.pickerDirectory = job.directory ?? false;
        if (root.pickerStartDir.length > 0)
            content.pickerNavigate(root.pickerStartDir);
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
        running: root.pickerMode && !root.pickerWritten
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

    // ── The veil ────────────────────────────────────────────────────────────
    Rectangle {
        id: backdrop
        anchors.fill: parent
        // Matches settings.qml: frost via the compositor's layer rule
        // (namespace quickshell:files -- created automatically from the
        // registry), plus a scrim for contrast. Fades only after the card
        // has finished leaving.
        // Same facade as settings.qml / taskmanager.qml: `opacity` is the fade
        // channel (a number), the veil is the `color`. It used to be the other
        // way round here -- a COLOR assigned to `opacity` -- which is a silent
        // type error: the backdrop never got a veil at all, so the desktop
        // stayed razor sharp behind the Files popup while the other two popups
        // frosted it. That alone is most of "it doesn't look anchored".
        opacity: root.veilFading ? 0.0 : 1.0
        Behavior on opacity {
            NumberAnimation { duration: root.veilFadeMs; easing.type: Easing.OutQuad }
        }
        // 0.78 == the wide, thin frost the other two popups use, so the desktop
        // stays readable around the card. The picker is a modal dialog over an
        // app the user is still working in, so it keeps a denser scrim.
        color: CF.ColorUtils.transparentize(Appearance.m3colors.m3background,
            root.pickerMode ? 0.42 : 0.90)
        TapHandler {
            // Clicking the scrim means "no thank you": a dialog cancels, the
            // Files popup closes. ONLY when the tap landed outside the card,
            // though: this handler is passive, so it observes every tap in
            // the surface -- including the taps the folder tiles handle.
            // Without the bounds check, clicking any folder also dismissed
            // the app mid-navigation ("Files closes when I click a folder").
            onTapped: (event) => {
                const p = event.point.position;
                const inside = p.x >= card.x && p.x <= card.x + card.width
                    && p.y >= card.y && p.y <= card.y + card.height;
                if (inside) return;
                root.pickerMode ? root.pickerCancel() : root.quitApp("in");
            }
        }
    }

    // ── The card ────────────────────────────────────────────────────────────
    Rectangle {
        id: card

        x: (root.width - width) / 2
        y: (root.height - height) / 2
        width: root.cardWidth
        height: root.cardHeight
        radius: root.pickerMode ? Appearance.rounding.windowRounding : Appearance.rounding.normal
        // 0.42 over the veil is the popup group's card density (the same number
        // settings.qml and taskmanager.qml use). It was 0.12 here -- a slab so
        // near-opaque that the card read as a black hole rather than as the
        // frosted panel the other two popups show.
        color: root.morphFading
            ? Appearance.m3colors.m3background
            : CF.ColorUtils.transparentize(Appearance.m3colors.m3background, 0.28)
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
        clip: true

        scale: (root.closing && !root.thrown) ? 0.9 : (root.morphFading ? root.morphGrowScale : 1.0)
        opacity: (root.closing && !root.thrown) ? 0.0 : 1.0
        Behavior on scale {
            NumberAnimation {
                duration: root.morphFading ? 280 : root.closeAnimMs
                easing.type: Easing.OutQuart
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: root.morphFading ? 210 : root.closeAnimMs
                easing.type: Easing.OutCubic
            }
        }

        // Drag/spring/throw animation X; started by the live-drag handlers.
        NumberAnimation {
            id: cardBackX; target: card; property: "x"; duration: 260; easing.type: Easing.OutBack
        }
        NumberAnimation {
            id: cardBackY; target: card; property: "y"; duration: 260; easing.type: Easing.OutBack
        }
        NumberAnimation {
            id: cardBackO; target: card; property: "opacity"; duration: 260; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: cardFlyY; target: card; property: "y"; duration: root.throwMs; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: cardFlyO; target: card; property: "opacity"; duration: root.throwMs; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: cardCloseY; target: card; property: "y"; duration: root.closeAnimMs; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: cardCloseX; target: card; property: "x"; duration: root.closeAnimMs; easing.type: Easing.OutCubic
        }

        // ── The manager ─────────────────────────────────────────────────────
        FileManagerContent {
            id: content
            anchors.fill: parent
            anchors.margins: 6
            onQuitRequested: root.quitApp("in")
            pickerMode: root.pickerMode
            pickerOp: root.pickerOp
            pickerName: root.pickerName
            pickerDirectory: root.pickerDirectory
            onPickerAccepted: (uris) => root.pickerAccept(uris)
            onPickerCancelled: root.pickerCancel()
        }

        // NOTE: the old "drag the card by its header" MouseArea lived here. It
        // is gone on purpose, twice over: popup cards are anchored, not
        // draggable (the same rule the attached desktop windows follow), and
        // sitting above the content it silently swallowed every click on the
        // top 44px of the app -- which is the whole toolbar.
    }

    // ── The real-window host (a copy of SettingsWindowHost's contract) ──────
    FilesWindowHost {
        id: filesHost
    }

    // Keyboard: Escape closes (popup form) or cancels (picker form).
    Shortcut {
        sequence: "Escape"
        context: Qt.ApplicationShortcut
        enabled: !root.morphed
        onActivated: root.pickerMode ? root.pickerCancel() : root.quitApp("in")
    }
}
