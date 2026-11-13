//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=1200
//
// 1200, not the 10000 this used to be. That value is a deceleration: bigger
// means wheel scrolling stops sooner, and 10000 stopped it almost immediately,
// which is exactly the "the scroll sticks" feeling -- you push the touchpad and
// the list lurches once and halts. 1200 lets it keep coasting while your fingers
// are still moving, and the default (2500) is closer to a mouse wheel than to a
// touchpad.

// Remove two slashes below and adjust the value to change the UI scale
////@ pragma Env QT_SCALE_FACTOR=1

import "modules/common"
import "services"
import "panelFamilies"

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import Quickshell.Services.Mpris

ShellRoot {
    id: root

    // Whole-screen alert border: blinks once when GlobalStates raises a
    // screen-wide alert -- the power failsafe and its return, and (since
    // 2026-10-18, requested) every failed launch, whose showLoadingError()
    // pulses the error colour here alongside the bar's line and its card.
    ScreenFlash {}

    // The bottom-right corner card: one short sentence, shown on request over
    // IPC, gone on its own. Family-independent like ScreenFlash because its
    // callers are desktop-level scripts rather than panels. The input failsafe
    // (SUPER+CTRL+M) used to speak here and now uses SignalToast instead, so
    // this stays mounted as the longer-sentence channel, not as the cursor's.
    CornerNotice {}

    // The top-right "that worked" card: a bare glyph and one short label,
    // sized to the sentence rather than to a panel width. It serves the
    // clipboard's copied feedback and the input failsafe's cursor messages
    // (see GlobalStates.showSignalToast and custom/scripts/fix-mouse.sh), so
    // those two no longer live in different corners of the desktop.
    SignalToast {}

    // The top-left transcript card: the sentence the last dictation produced,
    // held for a few seconds with a countdown and a Copy button, then deleted
    // (file and all). Nothing else in the stack keeps a transcript, so this is
    // the only chance to rescue one that never reached a text box.
    TranscriptCard {}

    // The fullscreen dictation tell: a small pill that drops out of the top edge
    // while a dictation is live and a fullscreen window covers the screen. The
    // bar's dictation pill sits in the bar, which a fullscreen app does not show,
    // so without this there is no way to see that the microphone is running.
    DictationIndicator {}

    // Stuff for every panel family

    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme()
        // The power mode touches the compositor, which a binding cannot do on its
        // own: the profile and the motion scale follow the config value, but
        // Hyprland's animation keyword has to be pushed once at startup.
        PowerMode.load()
        Hyprsunset.load()
        FirstRunExperience.load()
        ConflictKiller.load()
        Cliphist.refresh()
        Wallpapers.load()
        Updates.load()
        // The per-app popup-handling policy, for the same reason as the two
        // services above: it is a singleton nothing reads until the settings
        // page asks for it, and what it owns -- the file the compositor reads
        // to decide which apps may float a second window as a popup -- has to
        // be written at login, not the first time Settings happens to be
        // opened. A setting that only applies once you have visited the screen
        // that sets it is a setting that does not apply.
        PopupAppPolicy.load()
        // Two services that are otherwise created only when something looks at
        // them. Everything else in `services/` is pulled in by a widget that
        // needs it; these two sit behind the task manager, so on a fresh session
        // neither existed -- and neither did its IPC handler -- until the card
        // had been opened once. `qs -c ii ipc call systemFacts refresh` from a
        // script therefore failed, and `qs ipc show` disagreed with what the
        // shell could do. Reading the hardware once here costs a fraction of a
        // second at login and makes the first open of the Hardware page instant;
        // neither service samples anything until a card is actually on screen.
        SystemFacts.refresh()
        ProcessList.attach()
        // Same reason as SystemFacts above: reading the singleton CREATES it,
        // and this one is only useful once it is alive -- its `gpuPower` IPC
        // handler is what makes the dGPU power switch verifiable from a
        // script, and without this the first call would fail exactly like the
        // task manager's did on a fresh session.
        GpuPower.pciAddress
        // Same reason as the two above: reading the singleton CREATES it, so
        // without this touch the `llama` IPC handler does not exist until the
        // AI tab happens to be opened once, and `qs ipc call llama state`
        // fails on a fresh session -- which is exactly the verification path
        // this service is built to be checked through. Nothing is sampled
        // here; the scan of ~/Models is one `find`, and polling stays off
        // until a surface claims it (see LlamaService.tabOwner).
        LlamaService.models
        // Same reason again: reading the singleton CREATES it, and this one has
        // to be alive at login regardless of whether anything is on screen --
        // a stick plugged in before the first Files window is exactly the case
        // it exists for. The read is its 3s lsblk poll, which starts itself.
        Volumes.known
        // The census of what was already plugged in when the shell started.
        Volumes.poll()
        // Reading `GlobalStates` CREATES it (a Quickshell singleton exists from
        // the first read). Nothing here needs the values -- the touch is the
        // point: it makes the singleton, and with it the sidebar-state
        // heartbeat that custom/general.lua reads to tell whether a
        // three-finger swipe should close a sidebar or reach the window
        // underneath. The heartbeat republishes every 3s on its own, so this
        // line is only about WHEN the singleton first comes into being, not
        // about keeping the file fresh.
        GlobalStates.sidebarLeftOpen
    }


    // Panel families
    property list<string> families: ["ii", "waffle"]
    function cyclePanelFamily() {
        const currentIndex = families.indexOf(Config.options.panelFamily)
        const nextIndex = (currentIndex + 1) % families.length
        Config.options.panelFamily = families[nextIndex]
    }

    component PanelFamilyLoader: LazyLoader {
        required property string identifier
        property bool extraCondition: true
        active: Config.ready && Config.options.panelFamily === identifier && extraCondition
    }
    
    PanelFamilyLoader {
        identifier: "ii"
        component: IllogicalImpulseFamily {}
    }

    PanelFamilyLoader {
        identifier: "waffle"
        component: WaffleFamily {}
    }


    // Shortcuts
    IpcHandler {
        target: "panelFamily"

        function cycle(): void {
            root.cyclePanelFamily()
        }
    }

    // The SUPER-tap app search overlay: the 379px card under the bar's centre
    // island (design/search-overlay-preview.html). Its own IPC target lives in
    // AppSearchOverlay.qml (not here) because `type` and `state` need direct
    // access to the overlay instance's fields; a handler in shell.qml could
    // only see the GlobalStates flag.

    // ═══ "Nothing that way": the desktop glance ═════════════════════════
    //
    // A four-finger horizontal swipe that lands on no desktop used to be
    // answered with force. Three separate jolts fired for one gesture: the
    // wallpaper slid sideways on a damped spring, the whole screen went
    // through a shader shake, and the compositor pulsed
    // general.gaps_workspaces so every app window lurched with it. None of
    // them said anything a glance could not, and none of them agreed about
    // how big the "no" was.
    //
    // There is no jolt now. A swipe into a wall is a NON-EVENT, so it gets
    // the event's own answer: the desktop pill at the bottom edge flashes,
    // on the same 1.4s timer, with the same appearance it has after landing
    // on a real desktop. Nothing else on screen moves, which is exactly what
    // "you are still on this desktop" looks like.
    //
    // WHY THE DECISION LIVES HERE AND NOT IN THE COMPOSITOR: this was tried
    // as a second fingers=4 horizontal gesture in custom/general.lua and it
    // was dead on arrival -- the base config (hyprland/general.lua) already
    // registers that direction as the workspace swipe, and the FIRST binding
    // for a direction shadows every later one, so the pair only ever filled
    // the config-error toast on reload. The compositor does not publish
    // gesture outcomes either, so "did this swipe land?" can only be
    // answered by the shell, which sees both the swipe and the workspace
    // events.
    //
    // WHY THERE IS NO "DID IT LAND?" TEST HERE. There were two, one after the
    // other, and both were wrong in the same direction: they read a wall as a
    // landing, and a wall read as a landing means the bar never appears --
    // which is the one failure this block exists to prevent.
    //
    // The first compared workspace ids, snapshotted at gesture begin against
    // the id after. The second dropped that and looked for a `workspace`
    // event inside a settle window instead, on the theory that a switch
    // publishes one. It does -- but a REFUSED swipe publishes one too,
    // because Hyprland processes the request, finds it clamped at the floor
    // and reports it, about 60ms after the fingers lift. That is well inside
    // any usable window, so every swipe into a wall was answered with silence.
    // The log line it wrote is quoted at the decision itself.
    //
    // Neither test is needed, because both answers are the same answer. A
    // landing flashes the pill from the workspace event it genuinely produced;
    // a wall has no event, so it needs this. Flashing unconditionally costs a
    // timer restart on the landing path -- the bar is already up, it just
    // stays up its usual 1.4s -- and is the entire fix on the wall path.
    // Guessing which case it is was never worth a silent wrong answer.
    readonly property int edgeDecisionMs: 45
    property double lastWorkspaceEventAt: 0

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            // The same prefix-match the desktop pill uses to flash on a
            // switch: "workspace" and "workspacev2" are the two events. This
            // one timestamp is what both the tap guard below and the dead-edge
            // timer read, and it is deliberately the pill's own trigger rather
            // than a second, independent notion of "the desktop changed" --
            // the two can then never disagree about whether a switch landed.
            if (event.name.startsWith("workspace"))
                root.lastWorkspaceEventAt = Date.now();
        }
    }

    // ═══ A swipe over a popup owes BOTH halves ═══════════════════════════════
    //
    // The four-finger horizontal swipe is the compositor's own gesture, and on
    // its own it is all-or-nothing: Hyprland commits the switch only past a
    // distance it decides, and it says nothing at all about the swipes it
    // refuses. Measured on this machine with an injected four-finger swipe:
    // 0.10 of the pad commits nothing, 0.20 commits.
    //
    // A temporary popup changes what that refusal means. The gesture still
    // reaches the popup -- the compositor drops its focus grab and the popup
    // puts itself away -- so the swipe LOOKS like it did something while the
    // desktop never moved. That is the report, exactly: "it blocks the four
    // finger swipe to another desktop and closes the menu instead". Reproduced
    // with the launcher open: popup closed, desktop unchanged.
    //
    // So a swipe that had a popup under it owes the user both halves, and the
    // shell is the only side that can promise the second one. The compositor's
    // gesture stays exactly as it is -- it is the good, live-drag version, and
    // a popup must not cost the user that -- and when it did NOT commit, the
    // switch is made from here instead. When it DID commit, the settle timer
    // finds the desktop already changed and does nothing, so one gesture is
    // never worth two desktops. That guard is the same shape, at the same
    // ~120ms, as the launcher's own wheel path (AppSearchOverlay.wheelSettle).
    //
    // `swipeHadPopup` is snapshotted at the gesture's BEGIN, not read at the
    // end, because by the end the popup may well have closed itself already --
    // that is precisely what it does when the gesture starts. It is taken on
    // EVERY gesture begin, whatever the finger count: a four-finger swipe's
    // `begin` can be reported as 2 or 3 fingers (they do not all land in the
    // same millisecond), so gating this on `start === 4` would quietly never
    // arm -- the same trap the tracker's own `peak` fix was about.
    //
    // There are TWO kinds of popup under a gesture, and they are gone at
    // different moments:
    //
    //   * a FLAG popup -- the launcher, the desktop grid, the island -- keeps
    //     no compositor grab, so nothing takes its input away and it is still
    //     up when the gesture ends. The begin snapshot is the record of it.
    //   * a GRAB popup -- a bar card (VPN, wifi, bluetooth, battery, the
    //     clock) -- holds the session's input through GlobalFocusGrab, and the
    //     compositor drops that grab AS THE SWIPE STARTS. The card is closed
    //     before this shell has parsed the gesture's own `begin`, so the
    //     snapshot above reads FALSE about the one popup the swipe just closed
    //     -- and the swipe owed a desktop move that then never came. Measured
    //     in the log: the flag popups produced "popup under the gesture"
    //     lines, the cards produced none at all, across a whole session of
    //     real swipes over real cards.
    //
    // So the second fact comes from the grab itself: when the COMPOSITOR last
    // cleared it, which is the only way a swipe can put a card away. If that
    // falls inside this gesture's own span, the swipe had a card under it.
    // That clock is deliberately not moved by our own dismissals (a backdrop
    // press, Escape, another popup opening), so "the card closed a moment ago"
    // cannot be manufactured by anything except something taking the input.
    //
    // The two halves of that are named in the log, so one real swipe over one
    // real card settles the question from the record instead of from argument:
    // `[focusGrab] compositor cleared the grab (had=quickshell:barPanel)` is
    // the compositor taking the card away, and the `[swipe] begin:` line right
    // behind it says what was still standing when the decision started.
    property bool swipeHadPopup: false
    property int swipeFromWorkspace: 0
    // When the gesture began, and how far back the grab's clear may be and
    // still belong to it. The gesture is 150-250ms long and its `begin` line
    // reaches the shell a few tens of ms after the fingers land, so a clear
    // that happened as the fingers landed sits a little BEFORE the begin.
    property double swipeStartedAt: 0
    readonly property int swipeGrabWindowMs: 400

    function settleSwipePopups(travel) {
        const clearedAgo = GlobalFocusGrab.clearedAt > 0
            ? Date.now() - GlobalFocusGrab.clearedAt : -1;
        const liveAgo = GlobalFocusGrab.lastLiveAt > 0
            ? Date.now() - GlobalFocusGrab.lastLiveAt : -1;
        // Two clocks, because a grab popup can stop being on screen by two
        // routes and only the first has a dismissal to its name:
        //
        //   `clearedAt`  the COMPOSITOR took the input away -- the swipe's own
        //                doing, and the exact event this exists for;
        //   `lastLiveAt` the grab list simply emptied -- a card whose loader is
        //                torn down mid-swipe removes itself and is gone with no
        //                dismissal called anywhere (a bar card keeps no flag,
        //                so the grab list IS its open state and this is the only
        //                trace of it having been there).
        //
        // Either one inside this gesture's span means the swipe had a popup
        // under it and owes the desktop move. The window is deliberately short
        // (400ms) so that a card closed by hand long before a swipe cannot arm
        // one -- see the 140ms guard below for why a wrong arm at a wall costs
        // nothing anyway.
        const underGrab = (GlobalFocusGrab.clearedAt > 0
                && GlobalFocusGrab.clearedAt >= root.swipeStartedAt - root.swipeGrabWindowMs)
            || (GlobalFocusGrab.lastLiveAt > 0
                && GlobalFocusGrab.lastLiveAt >= root.swipeStartedAt - root.swipeGrabWindowMs);
        if (!root.swipeHadPopup && !underGrab)
            return;
        const hadPopup = GlobalStates.closeTransientPopups();
        const from = root.swipeFromWorkspace;
        if (from <= 0)
            return;         // could not read the desktop: close, but do not guess
        swipeFallback.from = from;
        // Measured on this machine, both directions, four swipes: a RIGHTWARD
        // swipe (positive travel) goes to the desktop BEFORE, a leftward one to
        // the desktop after.
        swipeFallback.forward = travel < 0;
        swipeFallback.restart();
        console.log(`[swipe] popup under the gesture (closed=${hadPopup} flag=${root.swipeHadPopup}`
            + ` byGrab=${underGrab} clearedAgo=${clearedAgo}ms lastLiveAgo=${liveAgo}ms`
            + ` cleared=${GlobalFocusGrab.clearedNames || "-"})`
            + ` travel=${travel.toFixed(3)} from=${from} fallback=${swipeFallback.forward ? "+1" : "-1"}`);
    }

    Timer {
        id: swipeFallback
        property int from: 0
        property bool forward: false
        // The compositor's own switch lands ~20ms after the fingers lift; this
        // is that with room to spare, and still not felt as a delay.
        interval: 140
        onTriggered: {
            const now = Number(HyprlandData.activeWorkspace?.id ?? 0);
            if (now !== swipeFallback.from)
                return;     // the compositor switched; nothing left to do
            // The Lua dispatcher form, like every other dispatch in this shell:
            // this Hyprland runs the Lua config parser, where a bare
            // `workspace 3` string is not a dispatcher it recognises.
            Hyprland.dispatch(`hl.dsp.focus({ workspace = "${swipeFallback.forward ? "+1" : "-1"}" })`);
        }
    }

    Connections {
        target: TouchpadSwipe
        // The same four fingers Hyprland turns into a workspace switch.
        // TouchpadSwipe reports that the gesture finished and which way it
        // went (positive is rightward).
        //
        // The direction went unused for a while (the pill's flash is
        // unconditional), and it is needed again here: when the compositor
        // refuses a swipe, this is the only record of which way it was asking
        // to go.
        function onGestureStarted(start) {
            root.swipeHadPopup = GlobalStates.transientPopupOpen;
            root.swipeFromWorkspace = Number(HyprlandData.activeWorkspace?.id ?? 0);
            // The clock the grab half of the decision is measured against --
            // see the two-kinds-of-popup note above.
            root.swipeStartedAt = Date.now();
            // One line per gesture begin that had a popup in it, present or
            // very recent, because "why did the desktop not move?" and "why did
            // it move?" are both questions about what was true HERE -- and for
            // a grab popup, the answer is already "gone" by the time the end
            // of the gesture is being decided. Printed only when there is
            // something to say, so a day of swiping over an empty desktop
            // leaves the log exactly as it was.
            const clearedAgo = GlobalFocusGrab.clearedAt > 0
                ? Date.now() - GlobalFocusGrab.clearedAt : -1;
            const liveAgo = GlobalFocusGrab.lastLiveAt > 0
                ? Date.now() - GlobalFocusGrab.lastLiveAt : -1;
            if (GlobalStates.transientPopupOpen || GlobalFocusGrab.liveDismissable.length > 0
                || (clearedAgo >= 0 && clearedAgo <= root.swipeGrabWindowMs)
                || (liveAgo >= 0 && liveAgo <= root.swipeGrabWindowMs))
                console.log(`[swipe] begin: flag=${GlobalStates.transientPopupOpen}`
                    + ` grab=${GlobalFocusGrab.liveDismissable.length}`
                    + ` clearedAgo=${clearedAgo}ms lastLiveAgo=${liveAgo}ms`);
        }

        function onHorizontalSwipeEnded(travel) {
            edgeTimer.travel = travel;
            edgeTimer.restart();
            root.settleSwipePopups(travel);
        }
    }

    Timer {
        id: edgeTimer
        // How far the gesture went, kept only so the log line below can say
        // which way it went. Nothing branches on it.
        property real travel: 0
        // How long after the fingers lift the pill is told. Nothing is
        // DECIDED here any more -- the flash is unconditional -- so this is
        // pure latency between the gesture ending and the bar appearing.
        //
        // It was 220ms, chosen when this timer still had to wait for Hyprland
        // to commit a switch. That is gone, and keeping the wait made the bar
        // feel broken: 220ms of dead time plus the capsule's own 200ms fade is
        // ~420ms between the swipe and a fully drawn bar, which reads as "it
        // did nothing" rather than "it answered". 45ms is enough to let the
        // tracker's "end" event finish being parsed before the flash lands in
        // the same tick as the pill's own paint, and short enough that the bar
        // is simply already there when you look.
        interval: root.edgeDecisionMs
        onTriggered: {
            // Flash on EVERY horizontal desktop swipe, landed or not. There is
            // deliberately no "did it land?" test here, and that is the whole
            // fix.
            //
            // It used to be a workspace-event window: a switch publishes a
            // `workspace` event, so an event inside the settle window was read
            // as a landing and the dead edge was answered with silence. That
            // test is wrong, and the log line it wrote down is what proved it:
            //
            //   [edge] swipe travel=-0.084 dead edge -> flash pill (last event 284ms ago)
            //
            // A refused swipe publishes a workspace event TOO -- Hyprland
            // processes the request, finds it clamped at the floor, and reports
            // it -- and it arrives FAST: about 60ms after the fingers lift,
            // comfortably inside the 220ms window. So a swipe into the wall was
            // read as a landing and the bar never appeared, every time. The
            // single line above is the rare case where the event happened to
            // land outside the window and the heuristic happened to be right,
            // which is why this looked intermittent rather than broken.
            //
            // Guessing is not needed anyway. Both answers are the SAME ANSWER:
            // the pill flashes for a landing and it flashes for a wall. The
            // only difference is that a landing also gets an event-driven flash
            // from the pill's own handler, so on a landing this merely restarts
            // a timer that is already running -- the bar looks identical and
            // nothing is visible twice. On a wall it is the only flash there
            // is, which is exactly the "you are still on this desktop" tell.
            //
            // So: one gesture, one feedback, no judgement call. Nothing MOVES
            // either way -- a "no" that jolts the desktop reads as a switch
            // that lagged, which is the opposite of what happened.
            console.log(`[edge] swipe travel=${edgeTimer.travel.toFixed(3)} -> flash pill (last workspace event ${Date.now() - root.lastWorkspaceEventAt}ms ago)`);
            GlobalStates.desktopPillFlash();
        }
    }

    // ── The dead-edge answer, reachable by hand ─────────────────────────
    // The pill's flash is a 1.4s animation and the decision runs on a
    // 220ms timer after the gesture lifts, so neither can be checked by
    // making the gesture -- this machine has no synthesised touchpad. `flash`
    // fires the exact call the timer makes, which is what tells a working
    // hand-off from a dead signal name, and `state` reports what the
    // decision is looking at right now.
    IpcHandler {
        target: "desktopEdge"

        // Only the signal, deliberately. The argument is parsed purely so the
        // reply can show what it made of it, the way the old bump handler
        // did; `edgeTimer.travel` is left to the timer, so the two cannot
        // disagree about which gesture is being answered. The settle wait is
        // skipped too -- this is the manual trigger, not the gesture, and
        // waiting 220ms to light a bar nobody is waiting for helps nobody.
        function flash(direction: string): string {
            const parsed = parseInt(direction);
            GlobalStates.desktopPillFlash();
            return `dir=${direction} parsed=${isNaN(parsed) ? "unparsed" : parsed}`
                + ` ws=${Number(Hyprland.focusedMonitor?.activeWorkspace?.id ?? -1)}`;
        }

        function state(): string {
            const now = Number(Hyprland.focusedMonitor?.activeWorkspace?.id ?? -1);
            const age = root.lastWorkspaceEventAt > 0
                ? Date.now() - root.lastWorkspaceEventAt : -1;
            return `ws=${now} decisionMs=${root.edgeDecisionMs} eventAgeMs=${age}`;
        }
    }

    // The swipe decision, reachable by hand.
    //
    // Everything that decides this one is a fact about the gesture's START,
    // and a real four-finger swipe is the only thing that can supply it -- this
    // machine has no synthesised touchpad. `simulate` runs the REAL decision
    // with both facts a gesture would have supplied, read now: the desktop it
    // starts from and the moment it starts. What it answers is not "did a
    // desktop move" (the 140ms settle timer below owns that, under its own
    // guard) but "did the decision ARM", which is the half that was silently
    // failing for the bar cards.
    //
    //   qs -c ii ipc call swipe state
    //   qs -c ii ipc call swipe simulate -0.08
    IpcHandler {
        target: "swipe"

        function state(): string {
            return `ws=${Number(HyprlandData.activeWorkspace?.id ?? 0)}`
                + ` popup=${GlobalStates.transientPopupOpen}`
                + ` grab=${GlobalFocusGrab.liveDismissable.length}`
                + ` clearedAgo=${GlobalFocusGrab.clearedAt > 0 ? Date.now() - GlobalFocusGrab.clearedAt : -1}ms`
                + ` lastCleared=${GlobalFocusGrab.clearedNames || "-"}`;
        }

        function simulate(travel: string): string {
            const value = parseFloat(travel);
            if (isNaN(value))
                return "travel must be a number, e.g. -0.08 (negative = leftward)";
            root.swipeStartedAt = Date.now();
            root.swipeFromWorkspace = Number(HyprlandData.activeWorkspace?.id ?? 0);
            root.swipeHadPopup = GlobalStates.transientPopupOpen;
            root.settleSwipePopups(value);
            return `simulated travel=${value} from=${root.swipeFromWorkspace}`
                + ` popup=${root.swipeHadPopup}`
                + ` grabClearedAgo=${GlobalFocusGrab.clearedAt > 0 ? Date.now() - GlobalFocusGrab.clearedAt : -1}ms`;
        }
    }

    // Removable media. The announcements are the service's; these are how they
    // can be checked without a screwdriver -- there is no way to plug a device
    // in from a script, so `forget` removes one from the census and the next
    // poll fires the real "inserted" path for it. `usbForget`/`usbScan` are
    // the same pair for the USB census, which is what a phone or a pad appears
    // in: same notice and same click, a different question asked of a
    // different source.
    IpcHandler {
        target: "volumes"

        function state(): string {
            return Volumes.stateLine();
        }

        function poll(): string {
            Volumes.poll();
            return Volumes.stateLine();
        }

        function forget(path: string): string {
            return Volumes.forget(path);
        }

        function phantom(path: string, kind: string, label: string, size: string): string {
            return Volumes.phantom(path, kind, label, Number(size));
        }

        function usbForget(name: string): string {
            return Volumes.usbForget(name);
        }

        function usbPhantom(name: string, kind: string, product: string): string {
            return Volumes.usbPhantom(name, kind, product);
        }

        function usbScan(): string {
            Volumes.scanUsb();
            return "scanning (read `state` in a moment)";
        }

        // The automount pass, on demand: what "auto mounted when plugged in"
        // actually does, asked of the copy that would have done it.
        function automountNow(): string {
            return Volumes.automountNow();
        }

    }

    // Debug / verification hook for the liquid bar. The below-bar droplet is
    // RETIRED (BarContent.armPocket's note), so `set` is close-only now: any
    // id just closes whatever is open. `state` still reads the spring, which
    // is how a regression that re-arms a drop would be caught.
    IpcHandler {
        target: "liquidbar"

        function set(id: string): void {
            LiquidBar.setPocket("")
        }

        function state(): string {
            // Geometry included: the droplet sizes itself from the open
            // pocket's content, and these are the numbers to check that against
            // (shell-side testing without pixel forensics).
            return `id=${LiquidBar.pocketId} t=${LiquidBar.t.toFixed(3)}`
                + ` dropX=${LiquidBar.dropX.toFixed(1)} w=${LiquidBar.dropWidth.toFixed(0)}`
                + ` h=${LiquidBar.dropHeight.toFixed(0)}`;
        }
    }

    GlobalShortcut {
        name: "panelFamilyCycle"
        description: "Cycles panel family"

        onPressed: root.cyclePanelFamily()
    }

    // The multi-finger TAPs. The tracker (scripts/input/touchpad-swipe.py)
    // emits a `tap` phase when a gesture rests on the pad briefly and still;
    // TouchpadSwipe turns that into tapTriggered(count-at-start). The actions
    // themselves live once, in custom/popup.lua -- these calls reach them, so
    // every path obeys the same popup guard.
    //   4 fingers -> showDesktop (REVERSED, requested): jump to an empty
    //     desktop, a second tap comes back. The desktops overview that used
    //     to live here moved to SUPER+D (custom/keybinds.lua).
    //   3 fingers -> SILENCE EVERYTHING, then bring back the last. One tap
    //     stops every source that is making sound (a video, the local music,
    //     both); the next tap resumes only the one that was heard last and
    //     leaves the rest stopped. Toggling a single player -- whatever the
    //     island happened to follow -- was the old behaviour and it left the
    //     other source talking.
    //
    //     With nothing sounding and nothing silenced by the switch, the old
    //     chain still applies: what was heard last, then anything else played
    //     this session, then the music saved on this PC, and only with nothing
    //     anywhere the wallpaper carousel. Plain navigation: no tap path flips
    //     the desktop into its edit mode any more.
    // (The 4-finger SWIPE up on an empty desktop is a different gesture: it
    // opens this same carousel with follow-finger animation. Its begin/end
    // triggers and live frames are handled in WallpaperSwipe.qml; the split
    // between tap and swipe happens in the tracker, and the shell only ever
    // sees well-formed taps here.)
    Connections {
        target: TouchpadSwipe
        function onTapTriggered(fingers) {
            // Every tap, logged. Three- and four-finger taps both proved
            // themselves unfixable-by-inspection in one sitting: the tracker
            // was emitting perfect events to a file while the shell had no
            // tracker listening at all, and nothing anywhere said so. A
            // gesture that stops working must be visible in the log, or it is
            // indistinguishable from a gesture that was never wired up.
            console.log(`[tap] ${fingers}-finger tap`);
            // Two-finger taps do nothing: the user only wants play/pause
            // on three-finger taps, not two.
            if (fingers === 2) return;
            if (fingers === 4) {
                Quickshell.execDetached(["hyprctl", "eval", "require('custom.popup').showDesktop()"]);
                return;
            }
            if (fingers === 3) {
                // Nothing may pause the music in the middle of a desktop
                // switch. A four-finger swipe is Hyprland's, and it ends with
                // the fingers lifting out of order; whatever is still down in
                // the tracker's re-join grace can read as a fresh, tiny,
                // three-finger gesture. The tracker's peak-count fix stops
                // that gesture being MISCOUNTED, and this stops it being
                // HONOURED at all: a three-finger tap within the swap window
                // is the tail of a swipe, not a request to pause.
                //
                // 450ms is longer than the tracker's 150ms re-join grace and
                // than a 350ms tap can last, so it covers the whole tail of
                // the gesture without swallowing a deliberate tap made just
                // after landing on a new desktop.
                if (Date.now() - root.lastWorkspaceEventAt < 450) {
                    console.log(`[tap] 3-finger tap ignored: ${Date.now() - root.lastWorkspaceEventAt}ms after a desktop switch`);
                    return;
                }
                // Stop everything. The tap is a silence switch, not a
                // per-player toggle: with a video in Brave and music loaded,
                // the old path silenced one of them and the other kept
                // talking. EVERY source is stopped here -- browser tabs (both
                // of them), mpv, the shell's own player -- and the gesture
                // ends. The following press brings back only the one that was
                // heard last, decided by the switch's own memory (see
                // `tapSwitch`), never by a guess at what is playing.
                const handled = MprisController.tapSwitch();
                if (handled !== "") {
                    console.log(`[tap] 3-finger tap: ${handled}`);
                    return;
                }
                // Nothing to stop and nothing remembered: start something, the
                // way the tap always could. MPRIS is the right level for this:
                // it is whatever the active player is -- mpv, Spotify, a
                // browser, a video -- so one gesture covers "song or video or
                // whatever" without this shell knowing what any of them are.
                //
                // `togglePlaying` rather than reading isPlaying and picking a
                // verb: the player owns that state, and a paused player still
                // has to be resumable, so both directions go through it.
                const played = MprisController.toggleBest();
                if (played !== "") {
                    console.log(`[tap] 3-finger tap: ${played}`);
                    return;
                }
                // Nothing on the bus could play: the tab this was on is closed
                // and no other player is left. The music saved on this PC is
                // the last resort, in two steps.
                //
                // A track already loaded makes this a REAL play/pause -- the
                // gesture has to be able to stop the local player too, which
                // is the one thing a "start something" fallback must not
                // break. Only with nothing loaded is it a start, and then it
                // picks up where the library was left.
                if (MusicPlayer.hasTrack) {
                    MusicPlayer.playPause();
                    console.log("[tap] 3-finger tap: local music");
                    return;
                }
                if (MusicPlayer.startRemembered()) {
                    console.log("[tap] 3-finger tap: local music, where the library was left");
                    return;
                }
                // Nothing anywhere. Fall through to the old behaviour rather
                // than making the gesture do nothing, since a desktop with no
                // media running and no music on disk has no play/pause to
                // perform.
                Quickshell.execDetached(["hyprctl", "eval", "require('custom.popup').wallpaperCarousel()"]);
                return;
            }
            // A tap the shell has no action for. This branch exists because
            // the ABSENCE of one is how the three-finger play/pause spent
            // months of being "broken": the tracker's finger count came out
            // one under (a three-finger tap reported 2, because the fingers
            // do not land in the same millisecond and `begin()` froze the
            // count at the first one that qualified), no branch matched, and
            // the tap vanished with nothing on screen and nothing in the log.
            // The tracker now settles the count (touchpad-swipe.py,
            // LAND_SETTLE_S), but a count that is still unroutable gets
            // said out loud rather than swallowed -- an unroutable tap is a
            // bug in the routing, and this is where it will be seen.
            console.warn(`[tap] unrouted ${fingers}-finger tap -- no action for that count`);
        }
        // ── No dead-edge handler here any more ──────────────────────────
        // This block used to snapshot the workspace the gesture started from
        // and hand it to the dead-edge decision. Both halves are gone, and
        // the reason is worth keeping because it is the second time this
        // code has been wrong in the same direction.
        //
        // It USED to spawn a helper here that re-read the active workspace at
        // the END of the gesture, which shook the desktop on every successful
        // leftward switch: this signal fires after Hyprland has committed, so
        // the helper always saw the workspace the fingers had just moved TO. A
        // leftward swipe from 2 to 1 read active=1, found nothing below 1, and
        // concluded it had hit a wall.
        //
        // The fix for THAT was to snapshot the id at gesture begin, in
        // `onActiveChanged` right here -- and that snapshot was a second,
        // independent reading of "where are we", taken at a moment the
        // compositor is already moving the desktops live. It is gone with the
        // rest: the pill's flash only needs to know whether a workspace event
        // arrived, which the shell timestamps from the event stream itself.
        // One fact, read from the source, beats two reads that can disagree.
    }
}
