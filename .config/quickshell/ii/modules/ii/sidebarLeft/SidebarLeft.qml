import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell.Io
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Scope { // Scope
    id: root
    property bool detach: false
    property bool pin: false
    property Component contentComponent: SidebarLeftContent {}
    property Item sidebarContent
    // The attached panel window (set by the Loader's sourceComponent when it
    // is created). IPC and shortcut closes route through its hide() so the
    // exit animation plays no matter who asked for the close.
    property var attachedWindow: null

    function toggleDetach() {
        root.detach = !root.detach;
    }

    Process { // Dodge cursor away, pin, move cursor back
        id: pinWithFunnyHyprlandWorkaroundProc
        property var hook: null
        property int cursorX;
        property int cursorY;
        function doIt() {
            command = ["hyprctl", "cursorpos"]
            hook = (output) => {
                cursorX = parseInt(output.split(",")[0]);
                cursorY = parseInt(output.split(",")[1]);
                doIt2();
            }
            running = true;
        }
        function doIt2(output) {
            command = ["bash", "-c", "hyprctl dispatch 'hl.dsp.cursor.move({x=9999,y=9999})'"];
            hook = () => {
                doIt3();
            }
            running = true;
        }
        function doIt3(output) {
            root.pin = !root.pin;
            command = ["bash", "-c", `sleep 0.01; hyprctl dispatch 'hl.dsp.cursor.move({x=${cursorX},y=${cursorY}})'`];
            hook = null
            running = true;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                pinWithFunnyHyprlandWorkaroundProc.hook(text);
            }
        }
    }

    function togglePin() {
        if (!root.pin) pinWithFunnyHyprlandWorkaroundProc.doIt()
        else root.pin = !root.pin;
    }

    Component.onCompleted: {
        root.sidebarContent = contentComponent.createObject(null, {
            "scopeRoot": root,
        });
        sidebarLoader.item.contentParent.children = [root.sidebarContent];
    }

    onDetachChanged: {
        if (root.detach) {
            GlobalFocusGrab.removeDismissable(sidebarLoader.item) // Remove sidebar from the focus grab system
            sidebarContent.parent = null; // Detach content from sidebar
            sidebarLoader.active = false; // Unload sidebar
            detachedSidebarLoader.active = true; // Load detached window
            detachedSidebarLoader.item.contentParent.children = [sidebarContent];
        } else {
            sidebarContent.parent = null; // Detach content from window
            detachedSidebarLoader.active = false; // Unload detached window
            sidebarLoader.active = true; // Load sidebar
            sidebarLoader.item.contentParent.children = [sidebarContent];
        }
    }

    Loader {
        id: sidebarLoader
        active: true
        
        sourceComponent: PanelWindow { // Window
            id: panelWindow
            Component.onCompleted: {
                root.attachedWindow = panelWindow;
                // The open state can already be true when the surface is
                // built (a keybind that opened it during startup), and
                // `onOpenChanged` only fires on a CHANGE. Arm the dismissable
                // here so the first open is not the one that cannot be
                // dismissed by clicking away. Folded into this ONE
                // `Component.onCompleted` on purpose: a second one on the same
                // object is a hard load failure in Quickshell 0.3.1
                // ("Property value set multiple times"), which takes the whole
                // config out with it.
                if (GlobalStates.sidebarLeftOpen)
                    GlobalFocusGrab.addDismissable(panelWindow);
            }
            Component.onDestruction: if (root.attachedWindow === panelWindow) root.attachedWindow = null
            // ALWAYS mapped, exactly like SidebarRight.qml. This used to be
            // `visible: GlobalStates.sidebarLeftOpen`, which remapped the
            // layer surface on every open. The right sidebar was rebuilt off
            // that model for the reason recorded there: "Remapping played only
            // the compositor's popin -- this way the sidebar genuinely
            // stretches out of the edge and back." The left was never
            // converted, so the two ran different open paths and the left
            // could not be made to behave like the right at all.
            visible: true
            
            property bool extend: false
            property real sidebarWidth: panelWindow.extend ? Appearance.sizes.sidebarWidthExtended : Appearance.sizes.sidebarWidth
            property var contentParent: sidebarLeftBackground

            // ── The stretch driver ────────────────────────────────────────
            // A plain 0..1 value with a Behavior, so BOTH directions actually
            // move -- the right sidebar's `t`, under the same name, with the
            // same animation, for the same reason.
            //
            // This one stays a plain writable property with a BINDING and nothing
            // ever assigns to it -- that is the whole point. The previous
            // version was assigned (`onVisibleChanged` did `stretch = 1`),
            // and an assignment to a bound property DESTROYS the binding, so
            // from the second open onward the value was driven only by those
            // handlers: two sources of truth, of which only one could be
            // right, and on a reopen the "rest at 0" the enter animates out of
            // depended entirely on the close path having run first.
            //
            // It cannot be `readonly`: `Behavior` has to write the property it
            // animates, and attaching one to a readonly property is a hard
            // load error ("Invalid property assignment"). SidebarRight.qml's
            // `t` is writable for the same reason.
            property bool open: GlobalStates.sidebarLeftOpen
            property real t: open ? 1 : 0
            Behavior on t {
                // Asymmetric, and chosen by DIRECTION rather than by which
                // element happens to be on top: a panel arriving should
                // decelerate into place, a panel leaving should accelerate
                // out of it. One curve for both reads as sluggish on the way
                // out, which is the half of the motion people actually notice
                // because they are waiting for it to be gone. These are the
                // dedicated sidebar durations (200/150ms), not the general
                // 400ms elementMove the bar and dialogs use -- see
                // Appearance.animation.
                //
                // ONE inline NumberAnimation whose duration and curve are bound,
                // rather than `animation:` picking between two Components. A
                // Behavior accepts its animation exactly once -- re-assigning it
                // is a runtime error ("Cannot change the animation assigned to a
                // Behavior") -- so the direction has to be expressed INSIDE the
                // animation. Qualifying `open` with the window's id is also
                // required: an attached Behavior does not see the target object's
                // bare property names.
                NumberAnimation {
                    alwaysRunToEnd: true
                    duration: panelWindow.open
                        ? Appearance.animation.sidebarRevealEnter.duration
                        : Appearance.animation.sidebarRevealExit.duration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: panelWindow.open
                        ? Appearance.animationCurves.emphasizedDecel
                        : Appearance.animationCurves.emphasizedAccel
                }
            }

            // One close, from every caller: hover-out, focus-grab dismissal,
            // Esc, the IPC close, the shortcut. The spring does the rest --
            // there is nothing left to unmap, so there is nothing to wait for
            // and no timer whose beat has to be guessed.
            function hide() {
                GlobalStates.sidebarLeftOpen = false;
            }

            exclusionMode: ExclusionMode.Normal
            exclusiveZone: root.pin ? sidebarWidth : 0
            implicitWidth: Appearance.sizes.sidebarWidthExtended + Appearance.sizes.elevationMargin
            // Overlay for the same reason as the right sidebar: a Top-layer
            // surface sits under a fullscreen window, so the sidebar would be
            // open but invisible. Settings > Sidebars can put it back in Top.
            WlrLayershell.layer: (Config?.options.sidebar?.showInFullscreen ?? true) ? WlrLayer.Overlay : WlrLayer.Top
            WlrLayershell.namespace: "quickshell:sidebarLeft"
            // Hyprland 0.49: OnDemand is Exclusive, Exclusive just breaks click-outside-to-close.
            // Only while open: this surface is ALWAYS mapped now, so an
            // unconditional OnDemand would leave a permanently mapped
            // panel holding a keyboard-focus claim while it is invisible.
            // This mirrors SidebarRight.qml exactly.
            WlrLayershell.keyboardFocus: GlobalStates.sidebarLeftOpen
                ? WlrKeyboardFocus.OnDemand
                : WlrKeyboardFocus.None
            color: "transparent"

            anchors {
                top: true
                left: true
                bottom: true
            }

            // Explicit geometry, not `item:`. A region tracking the card would keep
            // tracking it while the card is scaled to nothing and fully
            // transparent -- an invisible strip of click-blocker sitting over
            // the desktop. Gated on the same `t > 0.1` the right sidebar uses.
            //
            // The WIDTH is the CARD's width, not the window's, and that is not a
            // cosmetic detail. The window is always as wide as the EXTENDED
            // sidebar (Ctrl+O) so the card has room to grow into, but the card
            // itself is `sidebarWidth` (480) until it is told otherwise. Using
            // panelWindow.width therefore declared ~245 logical px of empty
            // surface to the right of the visible card as part of the sidebar:
            // clicks there went to the panel instead of the desktop, so they did
            // not read as "outside" and did not dismiss, and the pointer
            // hovering there kept the window's HoverHandler happy, so the
            // mouse-out close never armed either. That is the whole of "tapping
            // beside the sidebar doesn't close it" -- the dead strip is exactly
            // where a hand goes to dismiss a panel. Mirrors the card's own
            // anchor arithmetic below so the region and the rectangle cannot
            // drift apart.
            mask: Region {
                x: 0
                y: 0
                width: panelWindow.t > 0.1
                    ? panelWindow.sidebarWidth - Appearance.sizes.elevationMargin
                    : 0
                height: panelWindow.t > 0.1 ? panelWindow.height : 0
            }

            // ── Close when the pointer leaves ─────────────────────────────
            // The right sidebar closed on mouse-out; this one didn't, because
            // its close came from EdgeReveal's cursor-position heuristic: a
            // poller asked Hyprland where the pointer was and guessed "still
            // on the panel" from a fixed 700px-wide band on the left edge --
            // so the pointer was practically never "out of the way". This is
            // the direct version the dock already uses: a passive HoverHandler
            // on the window (it does not block hover for the controls inside,
            // unlike a stacked MouseArea), and a short-grace timer that fires
            // only after the pointer has been here and then left.
            //
            // pointerWasInside guards the keyboard-open case: opening with a
            // shortcut while the mouse rests over the desktop must not have
            // the panel instantly swallow itself -- the auto-close arms only
            // once the panel has actually been hovered.
            property bool pointerWasInside: false

            HoverHandler {
                id: windowHover
                onHoveredChanged: {
                    if (hovered)
                        panelWindow.pointerWasInside = true;
                }
            }

            Timer {
                id: mouseOutTimer
                interval: 200
                repeat: false
                running: panelWindow.open && panelWindow.pointerWasInside
                    && !windowHover.hovered && !root.pin
                onTriggered: {
                    if (!windowHover.hovered && !root.pin)
                        panelWindow.hide();
                }
            }

            // Keyed on the STATE, once per transition -- deliberately not on
            // `t`. `onTChanged` fires on every frame of the animation (a 200ms
            // enter is a dozen-odd of them), and it was doing two pieces of
            // bookkeeping per frame that are only correct once per open:
            //
            //   * re-adding the focus-grab entry on every frame of the way OUT,
            //     because `t > 0` stays true for the whole exit. The grab was
            //     therefore live again on a panel that was already invisible
            //     and retracting, and it swallowed the next click aimed at the
            //     desktop for the length of the animation.
            //   * resetting pointerWasInside on every frame, which is what the
            //     flag exists to prevent (see above). Opened from the screen
            //     edge, the pointer is ALREADY over the panel, so no new hover
            //     transition ever arrives to set it true again, and the
            //     mouse-out close stayed disarmed for the rest of the session.
            //
            // Both are now one-shot, on the same boolean the right sidebar
            // uses, and the two sidebars cannot drift apart again.
            onOpenChanged: {
                if (open) {
                    GlobalFocusGrab.addDismissable(panelWindow);
                    // Armed from the live hover state rather than forced to
                    // false: opening from the edge puts the pointer on the
                    // panel before this runs, and the auto-close has to know
                    // that or it never arms. Off the edge (a keybind) the
                    // hover is false and the panel correctly stays put.
                    panelWindow.pointerWasInside = windowHover.hovered;
                } else {
                    GlobalFocusGrab.removeDismissable(panelWindow);
                }
            }
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    panelWindow.hide();
                }
            }

            // Content
            // The shadow has to be gated like the card is, and it did not used to need
            // to be: while this surface was unmapped when the sidebar was
            // closed, a shadow painted at full strength over nothing was
            // invisible because the whole layer was gone. Always mapped, it
            // is not -- the shadow kept painting a dark blurred rectangle
            // exactly where the card would be, and with the card scaled to
            // 0.82 and fully transparent, that read as a black smear down the
            // left edge of the desktop. The "ghost of the sidebar".
            // `opacity` rather than `visible` alone so the shadow fades with
            // the card instead of popping; `visible` on top of it stops the
            // effect compositing at all once it is fully closed. At rest
            // (t = 1) the multiplier is 1 and the shadow is byte-for-byte
            // what it was.
            StyledRectangularShadow {
                target: sidebarLeftBackground
                radius: sidebarLeftBackground.radius
                opacity: panelWindow.t
                visible: panelWindow.t > 0.001
            }
            Rectangle {
                id: sidebarLeftBackground
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.topMargin: Appearance.sizes.hyprlandGapsOut
                anchors.leftMargin: Appearance.sizes.hyprlandGapsOut
                width: panelWindow.sidebarWidth - Appearance.sizes.hyprlandGapsOut - Appearance.sizes.elevationMargin
                height: parent.height - Appearance.sizes.hyprlandGapsOut * 2
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: Appearance.colors.colLayer0Border
                radius: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

                // ── Open/close: the stretch-from-the-edge ────────────────────
                // The same motion language as the top bar's hover tabs and the
                // right sidebar: the card GROWS OUT of its screen edge (scale
                // anchored at the left edge, slight vertical breathe) while
                // fading, and reverses on the way home. The layer unmaps only
                // after the exit has landed, so nothing snaps mid-flight.
                // Driven by the one stretch value, so the scale and the fade
                // ride the same curve in both directions (see the driver).
                // Enter/exit split lives on the driver: growing OUT of the
                // edge is an emphasized-spring (sidebarRevealEnter), retracting
                // is the faster exit curve -- asymmetric on purpose, the way
                // every native panel in this shell moves.
                opacity: panelWindow.t
                // Gated on `visible` as well, and this is the difference that
                // actually costs something. The surface is always mapped, so
                // with opacity alone this whole tree stays in the scene graph
                // for as long as the sidebar is closed: every tab page (music,
                // to-do, translator, anime -- all built eagerly, see
                // SidebarLeftContent's contentChildren), the SwipeView, and its
                // `layer.enabled: true` OpacityMask, which is an offscreen
                // render pass that opacity alone does not switch off. A hidden
                // item drops the subtree from the graph outright, which is what
                // SidebarRight.qml's contentStage has always done. Without this
                // the left sidebar was paying its full render cost forever to
                // draw nothing, and the only reason the right one ever felt
                // cheaper was that it had been paying it correctly all along.
                visible: panelWindow.t > 0.001
                transform: [
                    Scale {
                        id: popScale
                        xScale: 0.82 + 0.18 * panelWindow.t
                        yScale: 0.965 + 0.035 * panelWindow.t
                        origin.x: 0
                        origin.y: sidebarLeftBackground.height / 2
                    }
                ]

                Behavior on width {
                    animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                }

                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Escape) {
                        panelWindow.hide();
                    }
                    if (event.modifiers === Qt.ControlModifier) {
                        if (event.key === Qt.Key_O) {
                            panelWindow.extend = !panelWindow.extend;
                        } else if (event.key === Qt.Key_D) {
                            root.toggleDetach();
                        } else if (event.key === Qt.Key_P) {
                            root.togglePin();
                        }
                        event.accepted = true;
                    }
                }
            }
        }
    }

    Loader {
        id: detachedSidebarLoader
        active: false

        sourceComponent: FloatingWindow {
            id: detachedSidebarRoot
            property var contentParent: detachedSidebarBackground
            color: "transparent"

            visible: GlobalStates.sidebarLeftOpen
            onVisibleChanged: {
                if (!visible) GlobalStates.sidebarLeftOpen = false;
            }
            
            Rectangle {
                id: detachedSidebarBackground
                anchors.fill: parent
                color: Appearance.colors.colLayer0

                Keys.onPressed: (event) => {
                    if (event.modifiers === Qt.ControlModifier) {
                        if (event.key === Qt.Key_D) {
                            root.toggleDetach();
                        }
                        event.accepted = true;
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "sidebarLeft"

        function toggle(): void {
            GlobalStates.sidebarLeftOpen = !GlobalStates.sidebarLeftOpen
        }

        function close(): void {
            if (attachedWindow && attachedWindow.visible) attachedWindow.hide();
            else GlobalStates.sidebarLeftOpen = false;
        }

        function open(): void {
            GlobalStates.sidebarLeftOpen = true
        }

        // The same relative step the two-finger swipe dispatches, reachable
        // from a keybind or `qs ipc`. The body is deliberately identical to
        // the GlobalShortcuts below: anything that can call one can call the
        // other, so the swipe and the script can never drift apart.
        function tabNext(): void {
            GlobalStates.sidebarLeftTabDelta += 1;
        }

        function tabPrev(): void {
            GlobalStates.sidebarLeftTabDelta -= 1;
        }

        // Feed the sidebar's wheel handler a synthetic event and report what
        // it did. A touchpad gesture cannot be synthesised from a script, so
        // without this every change to the swipe could only be asserted, not
        // measured. See wheelTest/scrollProbe in SidebarLeftContent.qml.
        function wheelTest(dx: real, dy: real): string {
            return sidebarContent.wheelTest(dx, dy);
        }

        function scrollProbe(): string {
            return sidebarContent.scrollProbe();
        }

        function testResult(): string {
            return sidebarContent.testResult();
        }

        // A whole gesture in one call. The coast cannot be measured by
        // calling wheelTest repeatedly from a script: those land ~1s apart,
        // so the fling model never sees a gesture. See burstTest.
        function burstTest(n: int, dy: real, gapMs: int, zeros: int): string {
            return sidebarContent.burstTest(n, dy, gapMs, zeros);
        }

        function burstResult(): string {
            return sidebarContent.burstResult();
        }

        function barProbe(): string {
            return sidebarContent.barProbe();
        }

        function railProbe(): string {
            return sidebarContent.railProbe();
        }

        function setIndex(i: int): string {
            return sidebarContent.setIndex(i);
        }

    }

    GlobalShortcut {
        name: "sidebarLeftToggle"
        description: "Toggles left sidebar on press"

        onPressed: {
            GlobalStates.sidebarLeftOpen = !GlobalStates.sidebarLeftOpen;
        }
    }

    GlobalShortcut {
        name: "sidebarLeftOpen"
        description: "Opens left sidebar on press"

        onPressed: {
            GlobalStates.sidebarLeftOpen = true;
        }
    }

    GlobalShortcut {
        name: "sidebarLeftClose"
        description: "Closes left sidebar on press"

        onPressed: {
            if (attachedWindow && attachedWindow.visible) attachedWindow.hide();
            else GlobalStates.sidebarLeftOpen = false;
        }
    }

    GlobalShortcut {
        name: "sidebarLeftToggleDetach"
        description: "Detach left sidebar into a window/Attach it back"

        onPressed: {
            root.detach = !root.detach;
        }
    }

    // ── The two-finger tab swipe ───────────────────────────────────────────
    //
    // Fired by the COMPOSITOR, not by anything in this file. The swipe used
    // to be a wheel event read inside the sidebar's own QML, and that could
    // only ever work over the tab strip: the body of every tab is a list or
    // a flickable, and whatever is topmost there eats the wheel before it
    // can reach a gesture handler anywhere below it. A compositor touchpad
    // bind has no such problem -- it is offered the gesture before any
    // client sees it -- so it works over the whole sidebar, and a light
    // flick clears it easily, which a wheel threshold never managed.
    //
    // A gesture knows a DIRECTION and nothing else, so the message it can
    // carry is a relative step. See GlobalStates.sidebarLeftTabDelta for why
    // that is a running counter rather than an index.
    GlobalShortcut {
        name: "sidebarLeftTabNext"
        description: "Next tab in the left sidebar (two-finger swipe RIGHT)"

        onPressed: {
            GlobalStates.sidebarLeftTabDelta += 1;
        }
    }

    GlobalShortcut {
        name: "sidebarLeftTabPrev"
        description: "Previous tab in the left sidebar (two-finger swipe LEFT)"

        onPressed: {
            GlobalStates.sidebarLeftTabDelta -= 1;
        }
    }

}






