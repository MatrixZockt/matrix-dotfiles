import qs
import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * Screen-edge reveal for the sidebars.
 *
 * Each monitor gets one invisible strip on its very left edge and one on its very
 * right edge. HOVERING the pointer on a strip slides the matching sidebar in --
 * the same gesture language as the top bar's liquid drops: enter the strip and
 * the panel comes out, leave its band and it retracts. The strips are only a few
 * pixels wide and grab nothing else, so they stay out of the way of normal
 * window edges.
 *
 * The bottom edge gets the same treatment for the dock, so the bottom bar comes up
 * exactly like the side bars do -- same click, same pointer-leave close, same
 * compositor slide -- and only from the edge itself.
 */
Scope {
    id: root

    // How often we ask Hyprland where the pointer is while a revealed sidebar is
    // up. Comfortably finer than a hand's exit from the edge.
    readonly property int pointerPollInterval: 300
    // Width of the invisible strip that listens for the pointer. Has to be wide
    // enough that landing on "the very edge" reliably enters the surface, but
    // narrow enough not to steal clicks from the windows underneath.
    readonly property int stripWidth: 10

    component EdgePanelWindow: PanelWindow {
        id: edgeWindow
        required property var targetScreen
        required property bool isLeft
        // Set while a window on this monitor is fullscreen: a video or a game
        // must not have a sidebar slide in because the pointer drifted near the
        // edge. Detected from HyprlandData's client list (any toplevel with
        // fullscreen > 0 on this monitor's name) rather than the workspace
        // scan the dock uses -- a morphed popup window (settings/taskmanager
        // fullscreen) is a regular client, which the workspace scan misses.
        // The sidebars themselves also sit on Overlay while
        // sidebar.showInFullscreen is on, so they would still DRAW over the
        // fullscreen client -- the strip staying dead is what makes "no
        // sidebars in fullscreen" actual behaviour instead of a lighting
        // trick: nothing opens them, so nothing appears.
        property bool suppressed: false
        // Said out loud when it flips, in the same `[edge]` vocabulary the rest
        // of the shell logs in: "the edge strips do nothing" is otherwise
        // indistinguishable from "the strips are suppressed" without a pointer
        // in hand to try them with.
        onSuppressedChanged: console.log(
            `[edge] ${edgeWindow.isLeft ? "left" : "right"} strip suppressed=${edgeWindow.suppressed}`)
        // True between "the edge opened this sidebar" and "the edge closed it".
        property bool revealed: false

        // How far the pointer may sit from this edge before the revealed sidebar
        // closes. Tracks the width each sidebar actually occupies, so moving onto
        // the sidebar's own controls never closes it.
        readonly property real stayBand: (edgeWindow.isLeft
            ? Appearance.sizes.sidebarWidthExtended
            : Appearance.sizes.sidebarWidth) + Appearance.sizes.hyprlandGapsOut

        screen: edgeWindow.targetScreen
        // Always mapped: setting visible=false while a window is fullscreen
        // permanently unmapped the strip in Quickshell -- it never came back
        // after leaving fullscreen, leaving the edge dead. Suppression is
        // enforced in BEHAVIOUR instead (the hover handler and the hint), so
        // the surface stays alive and resumes working the moment fullscreen
        // ends.
        visible: true

        // Nothing to hint at once the panel it would open is already up.
        readonly property bool sidebarAlreadyOpen: edgeWindow.isLeft
            ? GlobalStates.sidebarLeftOpen
            : GlobalStates.sidebarRightOpen

        color: "transparent"
        exclusiveZone: 0
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:edgeReveal"
        // Overlay, not Top: a fullscreen client renders above every Top-layer
        // surface, which made the edge dead while watching a video or playing a
        // game -- exactly when the sidebars are configured to be available
        // (sidebar.showInFullscreen). On Overlay the strip sits above the
        // fullscreen client like the sidebars themselves do, so resting the
        // pointer on the border still opens them. The strip is a few pixels
        // wide and hover-only, so nothing underneath loses input to it.
        WlrLayershell.layer: WlrLayer.Overlay
        // Purely a hover target: it must never take keyboard focus.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: edgeWindow.isLeft
            right: !edgeWindow.isLeft
        }
        implicitWidth: root.stripWidth

        mask: Region {
            item: edgeMouseArea
        }

        MouseArea {
            id: edgeMouseArea
            anchors.fill: parent
            hoverEnabled: true
            // Two opening gestures, one per context:
            //
            //   * Normal desktop -- HOVER opens, like the top bar's liquid
            //     drops: entering the strip slides the sidebar out. Leaving the
            //     strip closes nothing by itself: the pointer poller below owns
            //     the close, once the pointer exits the sidebar's whole
            //     stay-band (so moving onto the panel keeps it up).
            //   * Fullscreen window -- a CLICK opens. A video or a game means
            //     the pointer drifts to the edges constantly, and a hover strip
            //     there kept yanking a sidebar over the picture; the edge still
            //     shows its hint (so the affordance is findable) but the panel
            //     only comes out when it is actually asked for.
            acceptedButtons: Qt.LeftButton
            onClicked: mouse => {
                if (!edgeWindow.suppressed)
                    return; // hover path handles the normal desktop
                if (GlobalStates.screenLocked)
                    return;
                if (edgeWindow.sidebarAlreadyOpen)
                    return;
                edgeWindow.revealed = true;
                if (edgeWindow.isLeft)
                    GlobalStates.sidebarLeftOpen = true;
                else
                    GlobalStates.sidebarRightOpen = true;
                mouse.accepted = true;
            }

            onContainsMouseChanged: {
                if (edgeWindow.suppressed) {
                    if (!containsMouse)
                        openDelay.stop();
                    return;
                }
                if (containsMouse)
                    openDelay.restart();
                else
                    openDelay.stop();
            }
            // If the pointer is already resting on the strip when the surface
            // maps (shell start/reload with the cursor parked at the edge),
            // containsMouse initialises true and the changed handler never
            // fires -- seed the delay here ONLY when not suppressed: under
            // fullscreen the edge should never open from hover, so an already-
            // present cursor at the edge at startup does not count as a gesture.
            Component.onCompleted: Qt.callLater(() => {
                if (!edgeWindow.suppressed && edgeMouseArea.containsMouse)
                    openDelay.restart();
            });

        // Small hover-intent delay: the panel should not snap out the instant
        // the pointer grazes the strip (a cursor brushing the edge on its way
        // elsewhere must not summon a sidebar). ~0.45s of sustained hover is
        // the intent signal (extended from 300ms on request -- accidental
        // edge parking still opened it); leaving the strip within it cancels.
        //
        // Under fullscreen this delay is only ever armed by the single click
        // (see onClicked), never by hover: hover arms the hint only, so a
        // sustained hover at the edge under fullscreen does not turn into a
        // click-equivalent open.
        Timer {
                id: openDelay
                interval: 450
                onTriggered: {
                    // Re-check at fire time: state may have changed during
                    // the wait (fullscreen started, sidebar opened by other
                    // means, screen locked).
                    //
                    // On the NORMAL desktop this timer is the hover gesture
                    // itself: it was armed by onContainsMouseChanged (or by the
                    // mid-startup seed) and its fire is what opens the panel.
                    // This used to read `if (!suppressed) return;`, which is
                    // inverted -- suppressed is false on a normal desktop, so
                    // every fire bailed and the hover gesture was dead: the
                    // edge strips existed, armed and expired in silence and no
                    // sidebar ever came out. A fire under fullscreen cannot
                    // happen (both arming sites are gated on !suppressed), and
                    // is refused here rather than opening a panel over a video.
                    if (edgeWindow.suppressed)
                        return;
                    if (GlobalStates.screenLocked)
                        return;
                    if (edgeWindow.sidebarAlreadyOpen)
                        return;
                    edgeWindow.revealed = true;
                    if (edgeWindow.isLeft)
                        GlobalStates.sidebarLeftOpen = true;
                    else
                        GlobalStates.sidebarRightOpen = true;
                }
            }
        }

        // While a revealed sidebar is up, watch where the pointer goes and close
        // what the edge opened the moment it leaves the band.
        Timer {
            id: pointerPoller
            interval: root.pointerPollInterval
            repeat: true
            running: edgeWindow.revealed && edgeWindow.sidebarAlreadyOpen
            onTriggered: cursorProc.running = true
        }

        Process {
            id: cursorProc
            command: ["hyprctl", "cursorpos"]
            stdout: StdioCollector {
                onStreamFinished: {
                    const parts = text.trim().split(",");
                    if (parts.length < 2)
                        return;
                    // Hyprland reports the pointer in logical coordinates -- the
                    // same space the panel widths are expressed in.
                    const x = Number(parts[0]);
                    if (isNaN(x))
                        return;
                    const screenWidth = edgeWindow.targetScreen?.width ?? 0;
                    if (screenWidth <= 0)
                        return;
                    const inside = edgeWindow.isLeft
                        ? x <= edgeWindow.stayBand
                        : x >= screenWidth - edgeWindow.stayBand;
                    if (inside)
                        return;
                    edgeWindow.revealed = false;
                    if (edgeWindow.isLeft)
                        GlobalStates.sidebarLeftOpen = false;
                    else
                        GlobalStates.sidebarRightOpen = false;
                }
            }
        }

        // A small hint so the wait does not feel like nothing is happening:
        // it EXTENDS out of the edge the moment the pointer touches it -- the
        // line grows along its own length from its middle outward, instead of
        // fading in or sliding. This is drawn *outside* the input region -- the
        // mask only governs input, not rendering -- so the strip itself stays
        // narrow and keeps stealing nothing.
        //
        // Floating: it sits a few pixels off the border rather than glued to
        // it, which is what makes it read as an affordance instead of a crack
        // in the screen. The growth is done with a transform (yScale), not
        // geometry: animating height would relayout every frame, animating a
        // scale costs the compositor nothing but a matrix.
        Rectangle {
            id: edgeHint
            // The hint arms on hover in BOTH contexts -- it is the affordance
            // that tells you the edge is alive. In fullscreen it is the only
            // signal (hover will not open the panel there, a click will), so
            // suppressing it too would make the edge look dead with no way to
            // discover the click. Screen lock still hides it: nothing should
            // invite interaction over the lock screen.
            readonly property bool armed: edgeMouseArea.containsMouse
                && !GlobalStates.screenLocked && !edgeWindow.sidebarAlreadyOpen

            // Plain positioning rather than anchors: conditional anchors (setting
            // this one to `undefined` for the opposite edge) silently produced no
            // item at all on the right-hand strip.
            x: edgeWindow.isLeft ? 6 : Math.max(1, parent.width - width - 6)
            width: 2
            height: 56
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: Appearance.colors.colOnLayer0
            // Presence is owned entirely by the extension: at yScale 0 the line
            // has no extent and nothing renders, so there is no fade to pair
            // with it -- the show IS the growth.
            opacity: 0.45
            transform: Scale {
                yScale: edgeHint.armed ? 1.0 : 0.0
                origin.x: edgeHint.width / 2
                origin.y: edgeHint.height / 2
                Behavior on yScale {
                    NumberAnimation {
                        duration: 200
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }

    /**
     * The same idea, rotated a quarter turn: one thin strip along the very bottom
     * edge that brings the dock up on a click and lets it go again once
     * the pointer leaves the dock's band.
     *
     * This is what makes the dock behave like the sidebars -- and it is also why
     * the dock cannot be raised by hovering the bottom band of the screen any more:
     * only this few-pixel strip at the very edge listens, and everything else in
     * that strip stays click-through to the window underneath.
     */
    component BottomEdgePanelWindow: PanelWindow {
        id: bottomEdgeWindow
        required property var targetScreen
        // Set while a window on this monitor is fullscreen, so watching a video
        // or playing a game doesn't get interrupted by the dock sliding up.
        property bool suppressed: false
        // True between "the edge raised this dock" and "the edge lowered it".
        property bool revealed: false

        screen: bottomEdgeWindow.targetScreen
        // Always mapped (same reasoning as the side strips): gating by visible
        // permanently unmapped the surface once it was hidden. Config and
        // fullscreen gating happen in the hover handler and hint below.
        visible: true

        color: "transparent"
        exclusiveZone: 0
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:edgeReveal"
        // Same Overlay reasoning as the side-edge strips above.
        WlrLayershell.layer: WlrLayer.Overlay
        // Purely a hover target: it must never take keyboard focus.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            left: true
            right: true
            bottom: true
        }
        implicitHeight: root.stripWidth

        mask: Region {
            item: bottomMouseArea
        }

        readonly property bool dockAvailable: (Config.options?.dock.enable ?? true)
            && !(Config.options?.dock.pinnedOnStartup ?? false)

        MouseArea {
            id: bottomMouseArea
            anchors.fill: parent
            hoverEnabled: true
            // Same as the side strips: a click raises the dock, hover only
            // arms its hint. Inert while a fullscreen window covers the
            // monitor, the screen is locked, or the dock is disabled.
            acceptedButtons: Qt.LeftButton
            onClicked: {
                // Same rule as the side strips: while a fullscreen or covering
                // window is up the click is the ONLY opener, and on an
                // ordinary desktop hover already owns it (a second opener
                // there would make one gesture do two different things).
                if (!bottomEdgeWindow.suppressed)
                    return;
                if (GlobalStates.screenLocked || !bottomEdgeWindow.dockAvailable)
                    return;
                bottomEdgeWindow.revealed = true;
                GlobalStates.dockRevealed = true;
            }
            // The dock is hover-only now: touching the bottom edge summons it
            // exactly like the sidebars, and it lowers again when neither the
            // edge nor the dock itself has the pointer (maybeLowerDock).
            onContainsMouseChanged: {
                if (containsMouse && bottomEdgeWindow.dockAvailable
                    && !bottomEdgeWindow.suppressed && !GlobalStates.screenLocked) {
                    bottomEdgeWindow.revealed = true;
                    GlobalStates.dockRevealed = true;
                }
            }
        }

        // While the dock is up, the pointer is tracked with hover events alone: the
        // dock surface reports itself (GlobalStates.dockPointerInside) and this strip
        // reports the very bottom edge that raised it. When neither has the pointer,
        // the dock goes back down. Both are Wayland enter/leave events, so this costs
        // nothing in between -- it used to be a timer spawning `hyprctl cursorpos`
        // about three times a second for as long as the dock was open.
        function maybeLowerDock() {
            if (!bottomEdgeWindow.revealed || !GlobalStates.dockRevealed)
                return;
            if (GlobalStates.dockPointerInside || bottomMouseArea.containsMouse) {
                dockCloseDebounce.stop();
                return;
            }
            dockCloseDebounce.restart();
        }

        // Short grace, so a pointer crossing the gap between the edge and the pill --
        // or a compositor slide that is still in flight -- is not read as leaving.
        Timer {
            id: dockCloseDebounce
            interval: 250
            repeat: false
            onTriggered: {
                if (GlobalStates.dockPointerInside || bottomMouseArea.containsMouse)
                    return;
                bottomEdgeWindow.revealed = false;
                GlobalStates.dockRevealed = false;
            }
        }

        Connections {
            target: GlobalStates
            function onDockPointerInsideChanged() {
                maybeLowerDock();
            }
            function onDockRevealedChanged() {
                maybeLowerDock();
            }
        }

        Connections {
            target: bottomEdgeWindow
            function onRevealedChanged() {
                maybeLowerDock();
            }
        }

        Connections {
            target: bottomMouseArea
            function onContainsMouseChanged() {
                maybeLowerDock();
            }
        }

        // The little handle the sidebars get, lying down in the middle of the
        // bottom edge. Drawn outside the input region, so the strip itself stays
        // a few pixels narrow and keeps stealing nothing. Floating a few pixels
        // off the border like the side hints, and it extends along its length
        // (a transform, not a fade) when the edge is touched.
        Rectangle {
            id: dockHint
            readonly property bool armed: bottomMouseArea.containsMouse && !GlobalStates.dockRevealed
                && !bottomEdgeWindow.suppressed && !GlobalStates.screenLocked
                && bottomEdgeWindow.dockAvailable
            width: 32
            height: 2
            radius: height / 2
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            color: Appearance.colors.colOnLayer0
            opacity: 0.45
            transform: Scale {
                xScale: dockHint.armed ? 1.0 : 0.0
                origin.x: dockHint.width / 2
                origin.y: dockHint.height / 2
                Behavior on xScale {
                    NumberAnimation {
                        duration: 200
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }

    Variants {
        model: Quickshell.screens

        Scope {
            id: monitorScope
            required property var modelData
            property HyprlandMonitor monitor: Hyprland.monitorFor(monitorScope.modelData)

            property list<HyprlandWorkspace> workspacesForMonitor: Hyprland.workspaces.values.filter(workspace =>
                workspace.monitor && workspace.monitor.name == monitorScope.monitor?.name)
            property var activeWorkspaceWithFullscreen: workspacesForMonitor.filter(workspace =>
                (workspace.toplevels.values.filter(window => window.wayland?.fullscreen)[0] != undefined)
                && workspace.active)[0]
            property bool fullscreen: monitorScope.activeWorkspaceWithFullscreen != undefined

            // Any fullscreen client on THIS monitor, straight from the client
            // list: fullscreen-mode (1), maximized (2) or tiled-fullscreen (3)
            // all count -- the popup morph's SUPER+F fullscreen reports 1, a
            // SUPER+D maximized window 2. This is what kills the hover strips
            // while something is fullscreen (no sidebar auto-open over a video,
            // a game or a fullscreened popup).
            // `win.monitor` from `hyprctl clients -j` is the monitor's numeric
            // ID, not its name -- compare against the HyprlandMonitor's id.
            // Fullscreen DOES suppress the AUTO-open: a hover strip over a
            // video kept yanking a sidebar across the picture as the pointer
            // drifted. Suppressed means the strip's HOVER is dead and the edge
            // opens on CLICK instead (the hint still arms, so the affordance
            // stays discoverable); it does not mean the edge is unusable.
            //
            // RESTORED 2026-10-02. This was hard-wired to `false` on 2026-09-28: the
            // dashboard apps run fullscreen as their normal state and the
            // click-only fallback read as "the sidebars are broken". The fix
            // was to remove the suppression entirely, which also took away
            // hover-open everywhere.
            //
            // What is wanted is narrower than either of those: hover-open on a
            // normal desktop, and in fullscreen the same answer the top bar
            // gives there -- the panel comes out when you ASK for it, not
            // because the pointer drifted past the border while you were
            // watching something. That is exactly what `suppressed` already
            // does: the strip's hover stops opening, the hint still arms so the
            // affordance stays discoverable, and a click opens. Nothing else in
            // this file had to change to get it.
            //
            // Read the same way Bar.qml reads it -- `hyprctl clients -j`, the
            // compositor's own answer rather than a cached mirror -- but with a
            // WIDER net than the bar uses. The bar only counts 2 (real
            // fullscreen), because a maximized window keeps its own chrome and
            // the bar can sit over it. A maximized or tiled-fullscreen window
            // covers the desktop just as thoroughly from the point of view of
            // somebody using the pointer near the left edge, so 1, 2 and 3 all
            // count here.
            readonly property bool fullscreenClient: {
                const mon = monitorScope.monitor;
                if (!mon)
                    return false;
                const activeWs = Number(mon?.activeWorkspace?.id);
                if (!Number.isFinite(activeWs))
                    return false;
                const list = HyprlandData.windowList ?? [];
                for (let i = 0; i < list.length; i++) {
                    const c = list[i];
                    if (c?.hidden) continue;
                    if (Number(c?.fullscreen ?? 0) === 0) continue;
                    // Same monitor only: a fullscreen window on the second
                    // monitor must not suppress the edge on this one.
                    if (Number(c?.workspace?.id) !== activeWs) continue;
                    return true;
                }
                return false;
            }
            // ── A window COVERING this monitor counts as fullscreen too ────
            //
            // custom/cover.lua's SUPER+F pins a FLOATING window to the
            // monitor's full geometry -- `fullscreen` stays 0, so the check
            // above cannot see it. The top bar treats exactly this state as
            // fullscreen (Bar.qml's `coverByGeometry`, geometry only, no IPC
            // needed), and the sidebars have to agree with it: otherwise the
            // bar is gone over a covered screen while the edges still hover-
            // open a sidebar across it.
            //
            // Same rule and the same tolerance as the bar's: fs == 0,
            // floating, on this monitor's active workspace, and within 2px of
            // the monitor's origin and size.
            readonly property bool coverHere: {
                const scr = monitorScope.modelData;
                if (!scr)
                    return false;
                const lw = Number(scr.width);
                const lh = Number(scr.height);
                if (!Number.isFinite(lw) || !Number.isFinite(lh) || lw <= 0 || lh <= 0)
                    return false;
                const mon = monitorScope.monitor;
                const activeWs = Number(mon?.activeWorkspace?.id);
                if (!Number.isFinite(activeWs))
                    return false;
                const list = HyprlandData.windowList ?? [];
                const near = (a, b) => Math.abs(Number(a ?? 0) - b) <= 2;
                const ox = Number(scr.x ?? 0);
                const oy = Number(scr.y ?? 0);
                for (let i = 0; i < list.length; i++) {
                    const c = list[i];
                    if (Number(c?.fullscreen ?? 0) !== 0) continue;
                    if (c?.hidden) continue;
                    if (c?.floating !== true) continue;
                    if (Number(c?.workspace?.id) !== activeWs) continue;
                    const at = c.at ?? [];
                    const sz = c.size ?? [];
                    if (near(at[0], ox) && near(at[1], oy)
                        && near(sz[0], lw) && near(sz[1], lh))
                        return true;
                }
                return false;
            }
            // What the strips read: fullscreen OR covering, on THIS monitor.
            readonly property bool fullscreenHere:
                monitorScope.fullscreenClient || monitorScope.coverHere

            EdgePanelWindow {
                targetScreen: monitorScope.modelData
                isLeft: true
                suppressed: monitorScope.fullscreenHere
            }
            EdgePanelWindow {
                targetScreen: monitorScope.modelData
                isLeft: false
                suppressed: monitorScope.fullscreenHere
            }
            BottomEdgePanelWindow {
                targetScreen: monitorScope.modelData
                suppressed: monitorScope.fullscreenHere
            }
        }
    }
}

