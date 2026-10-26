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
 * Over a FULLSCREEN window the hover half of that gesture is given up on
 * purpose, and the edge takes the top bar's model instead: hover arms the hint,
 * a CLICK opens. The panel is still drawn above the fullscreen client (see
 * sidebar.showInFullscreen), so what was wanted was never a dead edge but a
 * quiet one -- no panel dragged across a video because the pointer drifted, and
 * no sidebar with no door either.
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
    // Shared with the sidebars, whose input regions stop short of it so this
    // strip keeps the click even while one of them is open (see
    // Appearance.sizes.edgeRevealStripWidth).
    readonly property int stripWidth: Appearance.sizes.edgeRevealStripWidth

    // ── Whether the sidebars are allowed over a fullscreen window ────────
    //
    // Read from the setting that already means this, and read in the SAME
    // place the sidebars themselves read it: SidebarLeft/SidebarRight pick
    // their layer from it (Overlay when it is on, Top when it is off). That
    // coupling is the whole point -- a strip that opens a sidebar which is
    // drawing on Top sits UNDER the fullscreen client, so "it opened" and
    // "nothing is there" are the same picture, and the click that did it
    // leaves an invisible panel open to confuse the next gesture.
    //
    // ON  -> the sidebars live over fullscreen, so the edge behaves over
    //        fullscreen exactly as it does anywhere else: hover opens.
    // OFF -> fullscreen really means no sidebars, so the edge is dead there:
    //        no hover, no click, and no hint inviting either.
    readonly property bool sidebarsOverFullscreen:
        Config.options?.sidebar?.showInFullscreen ?? true

    component EdgePanelWindow: PanelWindow {
        id: edgeWindow
        required property var targetScreen
        required property bool isLeft
        // Set while a window on this monitor is fullscreen AND the sidebars are
        // not allowed over one (sidebar.showInFullscreen): a video or a game
        // must not have a sidebar slide in because the pointer drifted near the
        // edge. Fullscreen is detected from HyprlandData's client list (any
        // toplevel with fullscreen > 0 on this monitor's name) rather than the
        // workspace scan the dock uses -- a morphed popup window
        // (settings/taskmanager fullscreen) is a regular client, which the
        // workspace scan misses.
        //
        // WITH THE SETTING ON, this stays false and the edges behave over a
        // fullscreen window exactly as they do anywhere else. That is the only
        // honest meaning of "the sidebars are available over fullscreen": the
        // sidebars are drawn on Overlay there, so all that was left was for
        // something to OPEN them, and these strips are the only thing that can.
        // Keeping them dead would leave the setting decorative.
        property bool suppressed: false
        // ── Over a fullscreen window the edge is CLICK-ONLY, not dead ────
        //
        // Hover arms the hint, a click opens. This is the top bar's rule
        // applied here (Bar.qml: "the top edge opens on HOVER AND PRESS" --
        // hover arms the affordance, the press is the ask), and it is what
        // `suppressed` CANNOT express: suppressed means the edge is inert
        // altogether, which is what the setting-off case needs, and reusing it
        // here would have taken the click with the hover.
        //
        // Why hover alone must not open over a fullscreen window: the pointer
        // drifts near an edge constantly while watching something, and every
        // drift yanked a panel across the picture. Why it must not be dead
        // either: these strips are the only way to open a sidebar while a
        // fullscreen client is up, so a dead edge is a sidebar with no door.
        property bool clickOnly: false
        // Said out loud when it flips, in the same `[edge]` vocabulary the rest
        // of the shell logs in: "the edge strips do nothing" is otherwise
        // indistinguishable from "the strips are suppressed" without a pointer
        // in hand to try them with.
        onSuppressedChanged: console.log(
            `[edge] ${edgeWindow.isLeft ? "left" : "right"} strip suppressed=${edgeWindow.suppressed}`)
        onClickOnlyChanged: console.log(
            `[edge] ${edgeWindow.isLeft ? "left" : "right"} strip clickOnly=${edgeWindow.clickOnly}`)
        // True between "the edge opened this sidebar" and "the edge closed it".
        property bool revealed: false

        // Whether the edge just sent this panel away -- see
        // GlobalStates.sidebarEdgeLatch for why the two halves have to agree on
        // it. Read through GlobalStates because the close can come from the
        // panel's own edge sliver as well as from this strip, and the pointer
        // is on the same few pixels either way.
        //
        // One close while the pointer stays put is a decision, not an
        // invitation: without the latch the hover -- still armed, because the
        // pointer never left -- brings the panel straight back, and a
        // dismissal reads as a flicker (or, from the other chair, as the click
        // having done nothing at all).
        readonly property bool hoverLatched: edgeWindow.isLeft
            ? GlobalStates.sidebarLeftEdgeLatch
            : GlobalStates.sidebarRightEdgeLatch
        // Written through one place, per edge: the flag belongs to this strip's
        // side of the screen and nowhere else.
        function setLatch(on) {
            if (edgeWindow.isLeft)
                GlobalStates.sidebarLeftEdgeLatch = on;
            else
                GlobalStates.sidebarRightEdgeLatch = on;
        }
        // Every close while the pointer is still on the strip gets the latch,
        // not just the ones this file performs: Esc, the bar's toggle and a
        // click-through dismissal all land the same way, and all of them would
        // otherwise be undone by the hover that is already armed under the
        // pointer. (A close from the panel's own edge sliver is latched there,
        // because at that instant the card -- not this strip -- has the
        // pointer.)
        onSidebarAlreadyOpenChanged: {
            if (!edgeWindow.sidebarAlreadyOpen && edgeMouseArea.containsMouse)
                edgeWindow.setLatch(true);
        }

        // The one opener and the one closer, shared by the hover timer and the
        // click, so the gestures cannot drift apart -- and so the outcome is
        // readable from outside.
        //
        // The log lines are the same instrument the suppression note below
        // uses, for the same reason: "the edge did nothing" and "the edge
        // opened a panel that did not draw" look identical from a screenshot,
        // and the second one is what an invisible sidebar over a fullscreen
        // client used to be.
        function openSidebar(why) {
            edgeWindow.revealed = true;
            if (edgeWindow.isLeft)
                GlobalStates.sidebarLeftOpen = true;
            else
                GlobalStates.sidebarRightOpen = true;
            console.log(`[edge] ${edgeWindow.isLeft ? "left" : "right"} strip opened (${why})`);
        }

        function closeSidebar(why) {
            edgeWindow.revealed = false;
            edgeWindow.setLatch(true);
            if (edgeWindow.isLeft)
                GlobalStates.sidebarLeftOpen = false;
            else
                GlobalStates.sidebarRightOpen = false;
            console.log(`[edge] ${edgeWindow.isLeft ? "left" : "right"} strip closed (${why})`);
        }

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
            // HOVER opens, like the top bar's liquid drops: entering the strip
            // slides the sidebar out. Leaving the strip closes nothing by
            // itself: the pointer poller below owns the close, once the pointer
            // exits the sidebar's whole stay-band (so moving onto the panel
            // keeps it up).
            //
            // A left CLICK opens too -- the same opener, so the two gestures
            // cannot drift apart. It is redundant on a normal desktop (hover
            // has usually opened it 450ms in, and the already-open guard makes
            // the click a no-op), and it is the gesture that answers "I did not
            // want to wait / I am not sure hovering is allowed to do this".
            // Both are gated on the one thing that decides whether the panel
            // would be seen at all: sidebar.showInFullscreen. See `suppressed`
            // above for the fullscreen half of that.
            acceptedButtons: Qt.LeftButton
            onClicked: mouse => {
                // A CLICK OPENS -- it never sends the panel away. This is the
                // top edge's rule, verbatim (Bar.qml's fsEdgePress: "the press
                // only ever opens"), and it is the only rule that can work
                // here: the hover sharing this strip has usually opened the
                // panel 450ms into the approach, so a click that arrived after
                // that and toggled landed as "the click closed it" -- read from
                // the chair as "the click does not work, only hover does".
                //
                // Open-only is right in every case instead: closed -> it comes
                // out; already out -> the press is a no-op and the panel the
                // hover just revealed stays revealed. (The panel's own edge
                // sliver used to close it on exactly these pixels, which is the
                // other half of the same bug -- a real click there found the
                // card, not this strip, and dismissed what the hover had just
                // opened. That sliver is gone.)
                //
                // Leaving the edge still closes it, as do Esc, the bar's own
                // sidebar buttons and the SUPER shortcuts -- the edge is simply
                // not a close gesture any more, exactly like the top edge.
                //
                // The same gate the hover uses -- `suppressed`, not the raw
                // setting. The old `!sidebarsOverFullscreen` check refused the
                // click whenever sidebar.showInFullscreen was off, which meant a
                // click could not open a sidebar anywhere, not even on an
                // ordinary desktop where nothing is fullscreen and the setting
                // changes nothing. Suppression is the state that actually
                // decides whether the panel would be seen (fullscreen client)
                // or not (everything else), so the two gestures now agree.
                if (edgeWindow.suppressed)
                    return;
                if (GlobalStates.screenLocked)
                    return;
                if (edgeWindow.sidebarAlreadyOpen)
                    return;
                // The click decides; the hover on its heels must not fight it.
                openDelay.stop();
                edgeWindow.openSidebar("click");
                mouse.accepted = true;
            }

            onContainsMouseChanged: {
                // Leaving the strip ends the latch: the next visit hovers as
                // usual. Cleared on the way out, before anything reads it.
                if (!containsMouse)
                    edgeWindow.setLatch(false);
                // Hover opens ONLY where hover is allowed to open. Over a
                // fullscreen window (`clickOnly`) the strip is not dead -- the
                // click below still works -- but the dwell is never armed, so
                // resting the pointer on the border while a video or a
                // dashboard is up opens nothing.
                if (edgeWindow.suppressed || edgeWindow.clickOnly) {
                    if (!containsMouse)
                        openDelay.stop();
                    return;
                }
                if (containsMouse && !edgeWindow.hoverLatched)
                    openDelay.restart();
                else
                    openDelay.stop();
            }
            // If the pointer is already resting on the strip when the surface
            // maps (shell start/reload with the cursor parked at the edge),
            // containsMouse initialises true and the changed handler never
            // fires -- seed the delay here ONLY when an opening hover is
            // wanted at all: not suppressed, and not latched by a panel that
            // was just closed from this very spot.
            Component.onCompleted: Qt.callLater(() => {
                if (!edgeWindow.suppressed && !edgeWindow.clickOnly
                    && !edgeWindow.hoverLatched
                    && edgeMouseArea.containsMouse)
                    openDelay.restart();
            });

        // Small hover-intent delay: the panel should not snap out the instant
        // the pointer grazes the strip (a cursor brushing the edge on its way
        // elsewhere must not summon a sidebar). ~0.45s of sustained hover is
        // the intent signal (extended from 300ms on request -- accidental
        // edge parking still opened it); leaving the strip within it cancels.
        //
        // With the sidebars allowed over fullscreen it is armed by hover there
        // exactly as it is on a normal desktop. Suppressed (the setting off,
        // fullscreen up) it is never armed at all: both arming sites and this
        // fire are gated on suppression.
        Timer {
                id: openDelay
                interval: 450
                onTriggered: {
                    // Re-check at fire time: state may have changed during
                    // the wait (fullscreen started, sidebar opened by other
                    // means, screen locked).
                    //
                    // This timer IS the hover gesture: it was armed by
                    // onContainsMouseChanged (or by the mid-startup seed) and
                    // its fire is what opens the panel.
                    //
                    // This used to read `if (!suppressed) return;`, which is
                    // inverted -- suppressed is false on a normal desktop, so
                    // every fire bailed and the hover gesture was dead: the
                    // edge strips existed, armed and expired in silence and no
                    // sidebar ever came out. Suppressed (the setting off,
                    // fullscreen up) means the edge really is inert there, so
                    // the fire is refused rather than opening a panel over a
                    // video -- and neither arming site lets a fire get this far
                    // in that state anyway.
                    if (edgeWindow.suppressed)
                        return;
                    // Over a fullscreen window hover never opens -- the ask is
                    // the click. Re-checked at fire time like everything else
                    // here, because fullscreen can start during the wait.
                    if (edgeWindow.clickOnly)
                        return;
                    // A close from this strip, while the pointer stayed on it,
                    // is a decision -- see hoverLatched. The pointer has to
                    // leave and come back before a hover may open the panel
                    // again.
                    if (edgeWindow.hoverLatched)
                        return;
                    if (GlobalStates.screenLocked)
                        return;
                    if (edgeWindow.sidebarAlreadyOpen)
                        return;
                    edgeWindow.openSidebar("hover");
                }
            }
        }

        // ── When does the latch end ──────────────────────────────────────
        //
        // The moment the pointer is no longer on the edge -- and that CANNOT be
        // waited for as a leave event. A close from the panel's own edge sliver
        // means the CARD had the pointer, so this strip never received an enter;
        // with no enter there is no leave, and the latch would outlive the
        // gesture that set it: the edge would stay dead until the pointer
        // happened to cross the strip again.
        //
        // So it is asked for instead of assumed, and only while a latch exists
        // (a hand's exit from a ten-pixel strip, never in the steady state).
        // Same instrument, same interval, as the close poller below: this file
        // already reads the cursor when the question cannot be answered by an
        // event, and this is the same kind of question.
        Timer {
            id: latchPoller
            interval: root.pointerPollInterval
            repeat: true
            running: edgeWindow.hoverLatched
            onTriggered: latchProbe.running = true
        }

        Process {
            id: latchProbe
            command: ["hyprctl", "cursorpos"]
            stdout: StdioCollector {
                onStreamFinished: {
                    const parts = text.trim().split(",");
                    if (parts.length < 2)
                        return;
                    const x = Number(parts[0]);
                    const screenWidth = edgeWindow.targetScreen?.width ?? 0;
                    if (isNaN(x) || screenWidth <= 0)
                        return;
                    // Still on the edge: the dismissal stands. Off it: the next
                    // visit hovers as it always did.
                    const onEdge = edgeWindow.isLeft
                        ? x <= root.stripWidth
                        : x >= screenWidth - root.stripWidth;
                    if (!onEdge)
                        edgeWindow.setLatch(false);
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
            // Suppression now means the edge really is inert there, so the hint
            // goes with it: an affordance that invites a click which opens
            // nothing (or opens a panel that cannot be seen) is worse than a
            // quiet edge.
            readonly property bool armed: edgeMouseArea.containsMouse
                && !edgeWindow.suppressed
                && !GlobalStates.screenLocked && !edgeWindow.sidebarAlreadyOpen
            // `clickOnly` deliberately does NOT clear `armed`: over a fullscreen
            // window this line is the only signal that the edge is live at all,
            // since hover will not open the panel there and a click will. Quiet
            // edge + no hint is how "the sidebars are broken" gets read.

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

            // Suppression only means something when the sidebars are NOT
            // allowed over fullscreen: see sidebarsOverFullscreen above. With
            // the setting on, a fullscreen window does not make the edge
            // INERT -- but it does make it click-only, which is the other
            // half of this file's fullscreen story and the half the owner
            // asked for: hover must not drag a panel across a video, and a
            // click still has to be able to open one.
            EdgePanelWindow {
                targetScreen: monitorScope.modelData
                isLeft: true
                suppressed: monitorScope.fullscreenHere && !root.sidebarsOverFullscreen
                clickOnly: monitorScope.fullscreenHere
            }
            EdgePanelWindow {
                targetScreen: monitorScope.modelData
                isLeft: false
                suppressed: monitorScope.fullscreenHere && !root.sidebarsOverFullscreen
                clickOnly: monitorScope.fullscreenHere
            }
            BottomEdgePanelWindow {
                targetScreen: monitorScope.modelData
                suppressed: monitorScope.fullscreenHere
            }
        }
    }
}

