pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
// For PanelWindow, WlrLayershell, WlrLayer, WlrKeyboardFocus and
// ExclusionMode. This file was a toplevel `Window` and had no reason to have
// it; making it a layer surface again needs all five, and without the import
// the whole component fails to load with
//
//     WallpaperModal.qml[291:9]: Non-existent attached object
//
// which takes IllogicalImpulseFamily -- and therefore the entire shell -- with
// it. qmllint does not catch this one: it reports the file clean.
import Quickshell.Wayland
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import qs.services

// The wallpaper theatre's interactive host.
//
// WHY the carousel lives HERE and not in the widget: the widget and its
// coverflow render on the BOTTOM layer, and a bottom-layer surface loses
// every pointer event to whatever focused window sits above it -- which is
// why clicks, arrows and swipes could never actually move the carousel.
// While the theatre is open this window owns the interaction: it hosts the
// real WallpaperCarousel, closes on any press outside the strip, and takes
// keyboard focus so Escape and the arrow keys always arrive.
//
// It is a LAYER-SHELL SURFACE on WlrLayer.Overlay, configured exactly the way
// the login screen is: fullscreen, `color: "transparent"`, no exclusive zone,
// and `WlrKeyboardFocus.Exclusive` while it is up. That is the whole reason for
// this file's shape -- a picker that covers the whole output should BE a
// whole-output overlay, not a normal window that happens to be large.
//
// It spent a while as an ordinary toplevel, on the argument that a real window
// is listable, raisable and reachable by a window rule. That was solving a
// problem nobody had: nothing here needs alt-tab, and a floating toplevel sized
// to a strip leaves the desktop visible around a picker that was supposed to be
// modal. Going back to a layer surface means:
//
//   * the surface always covers the output, so the entrance gesture can slide
//     the stage by exactly one screen height (`modal.height * progress`) and
//     a full upward drag still carries it from offscreen to rest;
//   * the compositor no longer needs a rule to make it behave, so the
//     `^(Wallpapers)$` window rules in hypr/custom/rules.lua are gone;
//   * keyboard focus is the layer-shell kind, which needs no scene-to-focus-in
//     dance -- the surface has one the moment it maps.
//
// Geometry: the strip is centred in the surface and self-sized from the
// carousel's own implicit metrics, so its internal layout is unchanged.
ShellRoot {
    id: root
    // `root` MUST be declared on this ShellRoot: the Connections handler
    // below calls root.openAddPicker(), and with no local id the name
    // resolved through the context chain to shell.qml's root -- an object
    // with no such function ("Property 'openAddPicker' ... is not a
    // function"), which silently killed the add-wallpaper button the day
    // the picker machinery moved here from the (retired) widget that DID
    // declare its own id: root.

    // ── "Add wallpaper": this modal owns the picker now ─────────────────
    // It used to live in the (now retired) pill widget, so the carousel's
    // add button emitted GlobalStates.requestWallpaperAdd into the void
    // whenever the widget was not instantiated -- the dead add button. The
    // machinery is unchanged, just relocated: a job file asks the desktop's
    // file manager to open its picker, the widget-free modal polls for the
    // result and applies it.
    //
    // The picker is the SHELL's own file manager (filemanager.sh picker), the
    // same dialog every other app gets from the portal. This used to name the
    // retired GTK Explorer directly, which is how "Add wallpaper" ended up
    // opening a different file manager from the one every other Open dialog
    // opens.
    readonly property string pickerDir: `${Quickshell.env("XDG_RUNTIME_DIR")}/ii-portal`
    property string addToken: ""

    function openAddPicker() {
        const token = `wp${Date.now()}`;
        root.addToken = token;
        const startDir = FileUtils.parentDirectory(String(WallpaperHistory.currentWallpaper)) || Directories.pictures;
        const payload = JSON.stringify({
            op: "open",
            title: "Add wallpaper",
            dir: startDir,
            name: "",
            directory: false,
            multiple: false,
            token: token,
        }).replace(/'/g, `'\\''`);
        // Resolved through the shell, so it is the same dialog the keyboard
        // shortcut and the desktop entry belong to, whatever the shell's
        // directory is called.
        const launcher = Quickshell.shellPath("scripts/launch/filemanager.sh");
        addLauncher.command = ["bash", "-c",
            `mkdir -p '${root.pickerDir}' && printf '%s' '${payload}' > '${root.pickerDir}/${token}.json'`
            + ` && setsid '${launcher}' picker '${token}' >/dev/null 2>&1 &`];
        addLauncher.running = false;
        addLauncher.running = true;
        // Close the theatre while the picker is up: the modal holds an
        // EXCLUSIVE keyboard grab, which fought the picker window for
        // keystrokes (typing/Enter/clicks could land nowhere). The user
        // reopens the carousel the same way they opened it.
        GlobalStates.wallpaperStageOpen = false;
    }

    Process {
        id: addLauncher
        command: []
    }

    // Sweep stale job files once per shell start.
    Process {
        id: addStaleSweep
        command: ["sh", "-c",
            `find '${root.pickerDir}' -maxdepth 1 -name '*.json' -mmin +1 -delete 2>/dev/null || true`]
        Component.onCompleted: running = true
    }

    // Poll (not watch): the result file is created by another process, which
    // FileView's inotify watch can miss entirely.
    Timer {
        interval: 400
        repeat: true
        running: root.addToken !== ""
        onTriggered: addResultPoll.running = true
    }
    Process {
        id: addResultPoll
        command: ["sh", "-c",
            `cat '${root.pickerDir}/${root.addToken}.result.json' 2>/dev/null || true`]
        stdout: StdioCollector {
            onStreamFinished: {
                const text = String(this.text ?? "").trim();
                if (text.length === 0) return;
                root.consumeAddResult(text);
            }
        }
    }

    function consumeAddResult(json) {
        const token = root.addToken;
        root.addToken = "";
        let result = {};
        try { result = JSON.parse(json); } catch (e) { return; }
        addCleanup.command = ["sh", "-c",
            `rm -f '${root.pickerDir}/${token}.json' '${root.pickerDir}/${token}.result.json'`];
        addCleanup.running = false;
        addCleanup.running = true;
        if (result.cancelled) return;
        const uris = Array.isArray(result.uris) ? result.uris : (result.uris ? [result.uris] : []);
        if (uris.length === 0) return;
        Wallpapers.apply(FileUtils.trimFileProtocol(String(uris[0])));
    }

    Process {
        id: addCleanup
        command: []
    }

    // ── Stage-open keepalive, for the compositor ─────────────────────────
    // While the theatre is open its carousel OWNS the three-finger gesture
    // (the shell's evdev tracker feeds it 1:1), so Hyprland's own 3-finger
    // binds (field-move, the island panel) must stand down for the duration
    // or one swipe would both scroll the ring AND drag a window to another
    // desktop. custom/general.lua reads this keepalive file -- same pattern
    // as ii-nowbar-hover.json -- and the 10s staleness rule means a crashed
    // shell can never pin the gestures down.
    FileView {
        id: stageKeepalive
        path: `${Quickshell.env("XDG_RUNTIME_DIR")}/ii-wallpaper-stage.json`
        watchChanges: false
        printErrors: false
    }
    function writeStageKeepalive(open: bool) {
        stageKeepalive.setText(JSON.stringify({ open: open, ts: Math.floor(Date.now() / 1000) }));
    }

    // Who asks for the picker: the carousel's add row (via the shared
    // signal), the sidebar's Wallpaper card and the Settings page (both
    // dispatching the same request). Answering here means the add button
    // works even though the pill widget that used to answer is retired.
    Connections {
        target: GlobalStates
        function onRequestWallpaperAdd() { root.openAddPicker() }
    }

    PanelWindow {
        id: modal

        // During a 4-finger swipe-up the stage maps as soon as the fingers
        // actually MOVE (WallpaperSwipe defers the open past the first travel
        // frame, so a 4-finger tap still falls through to the overview) and
        // then follows them 1:1 until release commits it.
        readonly property bool open: GlobalStates.wallpaperStageOpen

        // ── Follow-finger entrance ────────────────────────────────────────
        // While the 4-finger swipe drives the open, the stage's y follows
        // `progress` (0 = resting place, 1 = a screen height below, i.e.
        // fully offscreen). While the fingers are down the value tracks them
        // 1:1 (Behavior disabled); on release it settles back to 0 with the
        // commit animation; on an abort it runs to 1 (the slide-away) before
        // the stage closes.
        property bool aborting: false
        property real progress: 0
        readonly property bool progressLive: WallpaperSwipe.opening || modal.aborting || modal.progress > 0.001
        Behavior on progress {
            enabled: !WallpaperSwipe.opening
            NumberAnimation {
                duration: modal.aborting ? modal.stageOutDuration : WallpaperSwipe.settleMs
                easing.type: Easing.OutCubic
            }
        }
        Connections {
            target: WallpaperSwipe
            function onSwipeFractionChanged() {
                if (WallpaperSwipe.opening && !modal.aborting)
                    modal.progress = WallpaperSwipe.swipeFraction;
            }
            function onOpeningChanged() {
                // The fingers let go and the swipe was real (not aborted --
                // that is onAbortedChanged's job): settle the stage from
                // wherever the drag left it into its resting place. The
                // Behavior on progress is live again now that the fingers
                // are up, so this assignment IS the settle animation.
                if (WallpaperSwipe.opening || WallpaperSwipe.aborted || modal.aborting) return;
                if (!GlobalStates.wallpaperStageOpen) return;
                modal.progress = 0;
            }
            function onAbortedChanged() {
                if (!WallpaperSwipe.aborted || modal.aborting) return;
                // The swipe ended too small to commit: slide the stage the
                // rest of the way off, then really close.
                modal.aborting = true;
                modal.progress = 1;
                abortTimer.restart();
            }
        }
        Timer {
            id: abortTimer
            interval: modal.stageOutDuration + 40
            onTriggered: {
                GlobalStates.wallpaperStageOpen = false;
                WallpaperSwipe.aborted = false;
                modal.aborting = false;
                modal.progress = 0;
            }
        }
        // Desktop swap closes the theatre: it belongs to one desktop's
        // moment, not to whatever you land on next. Any reactive change of
        // the active workspace while open (keybind, bar click, 4-finger
        // swipe) drops the stage with the normal exit animation.
        property int lastWorkspace: HyprlandData.activeWorkspace?.id ?? -1
        onLastWorkspaceChanged: {
            if (modal.open)
                GlobalStates.wallpaperStageOpen = false;
        }
        // Exit hold: with only `open` driving visibility, the window unmaps
        // the same frame the close begins, which CUT the stage's fade-out
        // dead. The window now stays mapped for the exit animation's
        // duration, then unmaps. `visible` is assigned exactly once, here.
        property bool holdingExit: false
        visible: open || holdingExit
        onOpenChanged: {
            if (open) {
                holdingExit = false;
                exitHold.stop();
                // A fresh open starts from rest -- including a second swipe
                // arriving while a previous settle was still animating.
                if (!modal.aborting) modal.progress = 0;
            } else {
                exitHold.restart();
                // Closing by any other road (Escape, backdrop, workspace
                // change) leaves the swipe state behind: clear it, or the
                // next open would inherit a stale fraction.
                modal.aborting = false;
                modal.progress = 0;
                WallpaperSwipe.reset();
            }
        }
        // The open/close motion. Both were trimmed: 420/200 read as a soft, cinematic
        // rise over a full screen height, which is a long way to travel when
        // the gesture that triggered it was a quick pinch. 320/140 keeps the
        // same OutCubic shape -- the strip still decelerates into place rather
        // than arriving linearly -- but takes ~120ms off the way in and ~60ms
        // off the way out, which is about the difference between "watched it
        // happen" and "it was just there".
        //
        // Nothing else keys off these numbers. The old comment claimed 420 was
        // "the pill's theaterDuration", but the pill is retired and
        // `theaterDuration` no longer exists anywhere in the tree, so the
        // claim had been a coincidence for a while.
        readonly property real stageInDuration: 320
        readonly property real stageOutDuration: 140
        // Keeps the window mapped while the exit animation plays.
        Timer {
            id: exitHold
            interval: modal.stageOutDuration + 30
            onTriggered: modal.holdingExit = false
        }
        readonly property real stripPadding: 14
        // The colour the border shading fades in from, and the colour the
        // card reflections fade into so they keep their no-bottom-edge
        // finish. Same tone as the login screen's fill (LockScreen.qml paints
        // `Appearance.colors.colLayer0` at 0.94 over `m3background`), so the
        // theatre's edges belong to the same palette as the lock screen.
        readonly property color edgeColor: Appearance.m3colors.m3background

        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        // ── Layer-shell configuration, copied from the login screen ───────
        //
        // LockScreen.qml / lockscreen.qml both do exactly this: an Overlay
        // surface, transparent, ignoring exclusion, anchored to all four
        // edges, with Exclusive keyboard focus only while it is up. Matching
        // it is the point -- the theatre should come up the same way the
        // lock screen does, not as a window that happens to be big.
        screen: modal.theatreScreen
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:wallpaperStage"
        WlrLayershell.keyboardFocus: visible
            ? WlrKeyboardFocus.Exclusive
            : WlrKeyboardFocus.None

        // FULLSCREEN. Anchored to all four edges of `screen`, exactly like the
        // lock screen, so `modal.width`/`modal.height` are the output size and
        // the stage's entrance slide is a true screen height.
        // Written one-per-line, not as `anchors { top: true; left: true }`:
        // the single-line grouped form fails to load here with
        //
        //     WallpaperModal.qml[468:57]: Invalid property assignment:
        //     unsupported type "QQuickAnchorLine"
        //
        // and it is the kind of thing qmllint calls clean. LockScreen.qml has
        // the multi-line form for every anchors block in the file.
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // FULLSCREEN again, and the surface is the OUTPUT, not the strip.
        //
        // It was briefly a toplevel sized to the strip, with a glass plate
        // behind it and the desktop left visible around the whole thing. That
        // was a different ask. This one is the login screen's ask: the surface
        // covers the monitor, paints no background at all, and only darkens the
        // BORDERS -- so the wallpaper is seen through the middle of the picker
        // rather than around it.
        //
        // `theatreScreen` only exists to pick the output to cover: a
        // layer-shell surface follows the focused monitor, which is what the
        // lock screen relies on too. There is no size to compute here -- the
        // four anchors above do it, and `modal.width`/`modal.height` are the
        // output's size, which is exactly what the stage's slide needs.
        readonly property var theatreScreen: Quickshell.screens.find(
            s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]

        // The compositor focus grab: while visible, Hyprland routes keyboard
        // (and clicks outside other surfaces) here -- this is what makes
        // Escape work where a bare layer-surface grab did not. Clicking
        // outside the grabbed window dismisses it, which closes the theatre.
        onVisibleChanged: {
            if (visible) {
                // The key item's `focus: open` binding evaluates the instant
                // `open` flips -- before this surface has a scene to focus in,
                // and Qt DROPS it when the window maps. Re-asserting here (the
                // item now exists) is what makes the arrows/Escape actually
                // fire; without it the theatre is born keyboard-dead.
                //
                // No requestActivate() call: that is a toplevel-only API, and a
                // layer surface takes the keyboard from
                // `WlrLayershell.keyboardFocus` above instead -- the same way
                // the lock screen gets its password field focused.
                keyCatcher.forceActiveFocus();
                // ── 3-finger drag: the tracker lives with the theatre ──
                // The 3-finger compositor gestures belong to the island/field
                // (custom general.lua), so the carousel's third finger comes
                // from the shell's own evdev tracker (WallpaperSwipe3 →
                // touchpad-swipe.py --fingers 3), launched only while the
                // theatre is open. Its frames feed car.feedDrag below.
                WallpaperSwipe3.start();
            } else {
                WallpaperSwipe3.stop();
            }
            root.writeStageKeepalive(visible);
            if (visible)
                GlobalFocusGrab.addDismissable(modal);
            else
                GlobalFocusGrab.removeDismissable(modal);
        }

        Connections {
            target: WallpaperSwipe3
            function onCarFrame() {
                car.feedDrag(WallpaperSwipe3.frameDx, WallpaperSwipe3.frameDy);
            }
            function onSessionEnded() {
                // Fingers up: the carousel's own gesture-end timer settles or
                // spins from the velocity feedDrag already handed it.
            }
        }
        Connections {
            target: GlobalFocusGrab
            function onDismissed() {
                if (modal.open)
                    GlobalStates.wallpaperStageOpen = false;
            }
        }

        // Backdrop: a press anywhere outside the strip closes the theatre.
        // The stage Item below is stacked ON TOP of this area, so presses on
        // the cards, the edge arrows and the add row reach the carousel, and
        // only genuinely empty screen closes.
        MouseArea {
            id: backdrop
            enabled: modal.open
            anchors.fill: parent
            cursorShape: Qt.ArrowCursor
            onPressed: mouse => {
                mouse.accepted = true;
                GlobalStates.wallpaperStageOpen = false;
            }

            // A two-finger swipe (or the wheel) ANYWHERE in the picker turns
            // the ring -- not only when the pointer happens to be over the
            // cards.
            //
            // This is the difference between the gesture feeling alive and it
            // feeling broken: the strip is bottom-anchored ABOVE the pill, so
            // when the picker opens the pointer is almost always BELOW it --
            // that is where the pill you hovered sits. Every swipe there hit
            // this backdrop and was swallowed, and the carousel never saw an
            // event, which is precisely "swiping does not move the carousel".
            // When the pointer IS over the cards the carousel's own handler
            // runs instead (the stage is the upper sibling), so nothing is
            // forwarded twice: whatever sits under the pointer owns the event.
            // Wheel/scroll anywhere in the picker turns the ring -- via
            // MouseArea.onWheel, because this Qt build never delivers wheel
            // events to WheelHandler on layer surfaces. A two-finger swipe
            // with the pointer below the strip hits THIS area (the strip sits
            // above the pill the user hovered), and previously died here.
            onWheel: event => {
                    const pd = event.pixelDelta;
                    const consumed = car.feedWheel(event.angleDelta.x, event.angleDelta.y,
                        pd ? pd.x : 0, pd ? pd.y : 0, car.eventIsTouchpad(event));
                    event.accepted = true;
            }
        }

// ── Border shading ─────────────────────────────────────────────
        //
        // No background colour, and no plate. The surface itself is
        // `color: "transparent"`, so the wallpaper is seen THROUGH the
        // picker: the middle of the screen is untouched, and the only thing
        // this paints is a soft darkening that fades inward from the four
        // edges of the monitor.
        //
        // Why the edges and not the middle: a full-screen wash turns the
        // wallpaper into something the picker is showing you, which is the
        // one thing this surface must not do -- it exists to let you judge a
        // wallpaper against the desktop it will live on. Darkening the rim
        // instead gives the strip contrast to sit against (the cards need an
        // edge to read against whatever happens to be behind them) while
        // leaving the part of the screen you are actually looking at clear.
        //
        // Colour: `modal.edgeColor`, the same `m3background` the login screen
        // fills its surface with, so the theatre's edges and the lock
        // screen's edges are visibly the same material.
        //
        // The depth is a fraction of the SHORTER edge, not a constant. A
        // fixed pixel depth that looks right on a 16:10 laptop eats a fifth
        // of a taller monitor, and the shading stops reading as an edge and
        // starts reading as a second, accidental panel.
        Item {
Item {
            id: edgeShade
            anchors.fill: parent
            readonly property real depth: Math.min(width, height) * 0.16

            // The three strengths every gradient below is built from. Keeping
            // them here means the four edges cannot drift apart, and it means
            // there is exactly one place to retune the whole vignette.
            //
            // `edgeAlpha` is the opacity at the very rim, `innerAlpha` the
            // opacity where the shading has died away to nothing in between.
            // `innerAlpha` is deliberately low: the falloff has to reach zero
            // BEFORE the strip, or the wallpaper ends up dimmed exactly where
            // the user is trying to judge it.
            readonly property real edgeAlpha: 0.78
            readonly property real innerAlpha: 0.20

            // How far along the entrance the shading is, as 0 = gone and
            // 1 = full. INVERTED from the stage's own `progress`, which runs
            // 0 at rest and 1 one screen-height below -- the shading is
            // strongest exactly where the strip is at rest, and disappears
            // with the strip as it slides off. One property, read by both
            // stops, so the edges can never fall out of step with each other.
            //
            // (Getting this backwards is invisible in the code and total on
            // screen: `progress` is 0 at rest, so following it directly draws
            // nothing exactly when the theatre is fully open.)
            readonly property real follow: 1 - (modal.progressLive ? modal.progress : 0)

            // CF.ColorUtils.transparentize(color, percentage) sets alpha to
            // `c.a * (1 - percentage)` -- it is the fraction to REMOVE, not
            // the alpha you want. So these read as `1 - wantedAlpha`, and
            // writing the alpha straight in is the silent bug that made this
            // vignette invisible at 0.78 intended.
            readonly property color atEdge:
                CF.ColorUtils.transparentize(modal.edgeColor, 1 - edgeAlpha * follow)
            readonly property color atInner:
                CF.ColorUtils.transparentize(modal.edgeColor, 1 - innerAlpha * follow)
            readonly property color atClear: "transparent"

            // Faded as a whole so closing the theatre does not pop the edges
            // out from under a strip that is still animating away.
            //
            // Duration follows the DIRECTION rather than always using the exit
            // time: the shading has to be fully up before the strip finishes
            // arriving, and while the timings were 420/200 the edges were
            // still fading in for the last 220ms of the entrance. It is only
            // visible now because the two numbers are much closer, but it is
            // the same rule the strip's own opacity uses.
            opacity: (modal.open || modal.aborting) ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: modal.open || modal.aborting
                        ? modal.stageInDuration
                        : modal.stageOutDuration
                    easing.type: Easing.OutCubic
                }
            }

            // Drawn as four edge gradients rather than one full-screen radial:
            // a radial from the centre would darken the middle too, and the
            // middle is the one region that has to stay clean.
            Rectangle {
                anchors.fill: parent
                anchors.bottomMargin: parent.height - edgeShade.depth
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: edgeShade.atEdge }
                    GradientStop { position: 0.45; color: edgeShade.atInner }
                    GradientStop { position: 1.0; color: edgeShade.atClear }
                }
            }
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: parent.height - edgeShade.depth
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: edgeShade.atClear }
                    GradientStop { position: 0.55; color: edgeShade.atInner }
                    GradientStop { position: 1.0; color: edgeShade.atEdge }
                }
            }
            Rectangle {
                anchors.fill: parent
                anchors.rightMargin: parent.width - edgeShade.depth
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: edgeShade.atEdge }
                    GradientStop { position: 0.45; color: edgeShade.atInner }
                    GradientStop { position: 1.0; color: edgeShade.atClear }
                }
            }
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: parent.width - edgeShade.depth
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: edgeShade.atClear }
                    GradientStop { position: 0.55; color: edgeShade.atInner }
                    GradientStop { position: 1.0; color: edgeShade.atEdge }
                }
            }
        }

        // Escape / arrows / Enter close and steer. A single focused Item
        // owns ALL keyboard for the window (the carousel's own key handling
        // is disabled to avoid a two-focus-owner fight): it routes to the
        // carousel and swallows no mouse input.
        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: modal.open
            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_Escape:
                    GlobalStates.wallpaperStageOpen = false;
                    event.accepted = true;
                    break;
                case Qt.Key_Left:
                    car.step(-1);
                    event.accepted = true;
                    break;
                case Qt.Key_Right:
                    car.step(1);
                    event.accepted = true;
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    car.activateCurrent();
                    event.accepted = true;
                    break;
                }
            }
        }

        // The interactive strip, anchored bottom-centre above the pill and
        // self-sized from the carousel's own implicit metrics -- the same
        // way the old in-widget popover was built, so the look is identical.
        Item {
            id: stage
            readonly property real cw: car.width > 0 ? car.width : 1000
            readonly property real ch: car.height > 0 ? car.height : 560
            readonly property real w: cw + 2 * modal.stripPadding
            readonly property real h: ch + 2 * modal.stripPadding
            x: (modal.width - w) / 2
            // Centred on the screen, not lower: the ask was an equal gap
            // above and below, not a bottom-weighted strip. (It was
            // bottom-anchored above the pill stack.)
            //
            // `+ modal.height * progress` is the follow-finger entrance: the
            // strip sits exactly one screen-height down when progress hits 1,
            // so a full upward drag carries it from offscreen to rest.
            readonly property real restY: (modal.height - h) / 2
            y: restY + (modal.progressLive ? modal.height * modal.progress : 0)
            width: w
            height: h
            // While following (or aborting) the fade/scale track the drag too
            // -- dimming and shrinking slightly as it sits lower -- so the
            // entrance reads as the same motion the exit plays, reversed.
            readonly property real follow: modal.progressLive ? modal.progress : 0
            opacity: (modal.open || modal.aborting) ? 1 - 0.2 * follow : 0
            scale: (modal.open || modal.aborting) ? 1 - 0.06 * follow : 0.94
            transformOrigin: Item.Bottom
            Behavior on opacity {
                NumberAnimation { duration: modal.open || modal.aborting ? modal.stageInDuration : modal.stageOutDuration; easing.type: Easing.OutCubic }
            }
            Behavior on scale {
                NumberAnimation { duration: modal.open || modal.aborting ? modal.stageInDuration : modal.stageOutDuration; easing.type: Easing.OutCubic }
            }

            WallpaperCarousel {
                id: car
                anchors.fill: parent
                anchors.margins: modal.stripPadding
                sizeMode: "stage"
                showReflections: false
                items: WallpaperHistory.images
                currentPath: WallpaperHistory.currentWallpaper
                allowRemove: true
                // Nothing to fade the card mirrors INTO: the surface behind them is the
                // wallpaper now, so the mirror's bottom edge has to reach
                // full transparency rather than a scrim colour. The carousel
                // draws it as the card fading out, which over a real
                // background is exactly what a reflection does.
                backdrop: "transparent"
                keyboardEnabled: false // the key item above routes keys
                // Auto-switch follows the Settings → Look switches; while the
                // theatre is open it applies in place, never closing it.
                autoSwitchEnabled: Config.options.background.autoSwitch.enable
                autoSwitchIntervalS: Config.options.background.autoSwitch.intervalS

                // Apply, then get out of the way.
                //
                // Choosing a wallpaper is a decision, not a browsing step, so
                // the theatre closes on it. This went the other way once: it
                // STAYED open after a pick, so you could sit in the picker and
                // compare the next candidate against the one just applied --
                // which is also exactly why picking felt like nothing happened,
                // because the strip stayed put over the desktop you were
                // trying to look at.
                //
                // `activateIndex` fires this synchronously right after it sets
                // `posTarget`, so the ring is still gliding to the chosen card
                // as the close begins. That reads fine: the card flies to the
                // centre while the stage fades out over `stageOutDuration`,
                // which is 140ms -- long enough to cover the last of the
                // glide rather than snapping it off mid-flight.
                onActivated: path => {
                    Wallpapers.apply(String(path));
                    GlobalStates.wallpaperStageOpen = false;
                }
                // Auto-switch deliberately does NOT close. It fires on a timer
                // while you are browsing (or with the theatre shut), and
                // yanking the picker shut on a background cycle would be
                // indistinguishable from the picker crashing.
                onAutoSwitched: path => Wallpapers.apply(String(path))
                onAddRequested: GlobalStates.requestWallpaperAdd()
                onRemoveRequested: path => {
                    removeTimer.mp = String(path);
                    removeTimer.restart();
                }
                // Two/three-finger swipe down anywhere over the picker closes
                // it (the carousel detects the flick; the stage decides what
                // closing means).
                onCloseRequested: GlobalStates.wallpaperStageOpen = false
            }
        }

        // Let the focused card's exit animation finish before the history
        // entry is dropped.
        Timer {
            id: removeTimer
            property string mp: ""
            interval: 160
            onTriggered: WallpaperHistory.remove(removeTimer.mp)
        }
    }

    // IPC: `qs -c ii ipc call wallpaperStage toggle|open|close` -- scriptable
    // control of the theatre (and a deterministic path for automated tests,
    // independent of pointer choreography).
    // The compositor's pinch gestures land here (custom/general.lua):
    // pinch out opens the carousel (the gesture itself has already checked
    // that the active desktop is empty), pinch in closes it. The empty-desktop
    // rule lives in the gesture, the open/close choreography lives here.
    GlobalShortcut {
        name: "wallpaperStageOpen"
        description: "Opens the wallpaper carousel (pinch out on an empty desktop)"
        onPressed: GlobalStates.wallpaperStageOpen = true
    }
    // The 4-finger swipe-up handoff (WallpaperSwipe.qml owns the state):
    // start arms the open, finish resolves it, close is the down-swipe.
    // Registered here because GlobalShortcut needs a ShellRoot context.
    GlobalShortcut {
        name: "wallpaperSwipeOpen"
        description: "Begins the 4-finger swipe-up open of the wallpaper carousel (empty desktop)"
        onPressed: WallpaperSwipe.requestOpen()
    }
    GlobalShortcut {
        name: "wallpaperSwipeFinish"
        description: "Ends the 4-finger swipe (commit or abort the carousel open)"
        onPressed: WallpaperSwipe.endSwipe()
    }
    GlobalShortcut {
        name: "wallpaperSwipeClose"
        description: "Closes the wallpaper carousel (4-finger swipe down over it)"
        onPressed: WallpaperSwipe.requestClose()
    }
    GlobalShortcut {
        name: "wallpaperStageClose"
        description: "Closes the wallpaper carousel (pinch in)"
        onPressed: GlobalStates.wallpaperStageOpen = false
    }

    IpcHandler {
        function toggle(): void { GlobalStates.wallpaperStageOpen = !GlobalStates.wallpaperStageOpen }
        function open(): void { GlobalStates.wallpaperStageOpen = true }
        function close(): void { GlobalStates.wallpaperStageOpen = false }
        // Scriptable/test hook: drives exactly the path the carousel's add
        // row takes (requestWallpaperAdd -> Connections -> openAddPicker)
        // without needing the pointer.
        function add(): void { root.openAddPicker() }
        // Test/diagnostic hook: drive the carousel's wheel logic directly,
        // bypassing event delivery entirely. Isolates "input never arrives"
        // from "logic broken".
        function nudge(dx: int): void {
            car.feedWheel(dx * 120, 0, 0, 0, false);
        }
        // Touchpad-branch probe: simulate a pixel-delta stream (the exact call
        // shape a real two-finger swipe produces), split into per-frame chunks
        // so the gesture accumulator sees realistic travel. Pass a second arg
        // to synthesize a VERTICAL down-swipe (the close-the-picker flick).
        function tpnudge(totalPx: int, vertical: bool): void {
            const step = totalPx < 0 ? -24 : 24;
            const n = Math.max(1, Math.round(Math.abs(totalPx) / 24));
            for (let i = 0; i < n; i++)
                car.feedWheel(0, 0, vertical ? 0 : step, vertical ? step : 0, true);
        }
        function ring(): string {
            const cur = car.items && car.items.length > 0 ? String(car.items[car.currentIndex % car.items.length]).split("/").pop() : "-";
            return `open=${modal.open} pos=${car.pos.toFixed(3)} posTarget=${car.posTarget.toFixed(3)} vel=${car.posVel.toFixed(2)} spinning=${car.spinning} idx=${car.currentIndex} cur=${cur} items=${car.items ? car.items.length : 0} pxPerCard=${car.pxPerCard.toFixed(0)} auto=${Config.options.background.autoSwitch.enable}/${Config.options.background.autoSwitch.intervalS}s stageY=${stage.y.toFixed(0)}`;
        }
        // Test hooks for the two card ACTIONS, so "the click never arrives"
        // can be told apart from "the action is broken". Both drive exactly
        // the call the card's own MouseArea makes, nothing else:
        //   pick(i)  -> activateIndex(i) -> activated -> Wallpapers.apply
        //   drop(i)  -> removeRequested -> the same removeTimer the X uses
        // Without these, a dead delete/apply is indistinguishable from a dead
        // pointer, and the only way to find out is to click with a mouse.
        function pick(i: int): void {
            car.activateIndex(i);
        }
        function drop(i: int): void {
            const p = car.items && car.items.length > 0 ? String(car.items[i]) : "";
            if (p.length === 0) return;
            car.removeRequested(p);
        }
        // What the library holds, and what the shell thinks is current. The
        // delete/apply reports are only meaningful next to these: a `drop`
        // that shrinks neither of these did not reach the service, and a
        // `pick` that leaves `cur` unchanged did not reach switchwall.sh.
        function lib(): string {
            const imgs = (car.items || []).map(p => String(p).split("/").pop());
            return `n=${imgs.length} cur=${String(WallpaperHistory.currentWallpaper).split("/").pop()} first=${imgs[0] ?? "-"}`;
        }
        // Test hook: one frame of the 3-finger drag, without the touchpad --
        // the exact call shape WallpaperSwipe3 delivers. The carousel's own
        // 150ms gesture-end timer resolves the release (snap or spin).
        function dragFrame(dx: real, dy: real): void {
            car.feedDrag(dx, dy);
        }
        // Swipe-open diagnostics: what the 4-finger handoff is doing right
        // now, from the compositor's start trigger to the follow-finger
        // progress to the settle/abort.
        function swipe(): string {
            return `opening=${WallpaperSwipe.opening} frac=${WallpaperSwipe.swipeFraction.toFixed(3)} progress=${modal.progress.toFixed(3)} aborting=${modal.aborting} aborted=${WallpaperSwipe.aborted} open=${modal.open}`;
        }
        // Test hook: one travel frame of the 4-finger swipe, without the
        // touchpad. Positive = upward travel (a fraction of a pad sweep).
        // Pair with `hyprctl eval 'hl.dispatch(hl.dsp.global(
        // "quickshell:wallpaperSwipeOpen"))'` for the start and ...Finish"
        // for the release, and the whole state machine runs scripted.
        function swipeFrame(frac: real): void {
            WallpaperSwipe.consumeFrame(-frac);
        }
        target: "wallpaperStage"
    }
}
}

