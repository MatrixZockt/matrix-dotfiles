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
// For `TrayService` in the trayOverflow IPC below, which reports how many
// tray items exist -- the number that decides whether the dropdown has
// anything to show at all.
import Quickshell.Services.SystemTray
import Quickshell.Services.Mpris

ShellRoot {
    id: root

    // Whole-screen alert border: blinks once when GlobalStates raises a
    // screen-wide alert (the power failsafe, and its return). Deliberately NOT
    // for a failed app launch -- that is the bar's indication line and its
    // card. See ScreenFlash.qml.
    ScreenFlash {}

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

    // The system tray's dropdown card, drivable without a physical click.
    // The chevron is a 24px target inside the bar's layout, and "ask someone
    // to hover it and report" is not a verification step.
    IpcHandler {
        target: "trayOverflow"

        function open(): void {
            GlobalStates.trayOverflowOpen = true;
        }

        function close(): void {
            GlobalStates.trayOverflowOpen = false;
        }

        function toggle(): void {
            GlobalStates.trayOverflowOpen = !GlobalStates.trayOverflowOpen;
        }

        function state(): string {
            const n = TrayService ? (TrayService.pinnedItems.length + TrayService.unpinnedItems.length) : -1;
            return `open=${GlobalStates.trayOverflowOpen} items=${n}`;
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

    Connections {
        target: TouchpadSwipe
        // The same four fingers Hyprland turns into a workspace switch.
        // TouchpadSwipe reports that the gesture finished and which way it
        // went (positive is rightward); the direction is no longer used for
        // anything, because a rightward swipe creates its desktop and so
        // publishes an event like any other landing.
        function onHorizontalSwipeEnded(travel) {
            edgeTimer.travel = travel;
            edgeTimer.restart();
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

    // Debug / verification hook for the liquid bar: drive the pocket spring
    // without needing a physical pointer (agent-side testing).
    IpcHandler {
        target: "liquidbar"

        function set(id: string): void {
            LiquidBar.setPocket(id === "none" ? "" : id)
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
    //   3 fingers -> PLAY/PAUSE of whatever MPRIS player is active. With no
    //     player at all it falls back to the wallpaper carousel, which is what
    //     it used to do unconditionally. Plain navigation: no tap path flips
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
                // Three fingers is PLAY/PAUSE whenever there is anything to
                // play or pause. MPRIS is the right level for this: it is
                // whatever the active player is -- mpv, Spotify, a browser,
                // a video -- so one gesture covers "song or video or whatever"
                // without this shell knowing what any of them are.
                //
                // `togglePlaying` rather than reading isPlaying and picking a
                // verb: the player owns that state, and a paused player still
                // has to be resumable, so both directions go through it.
                const player = MprisController.activePlayer;
                if (player) {
                    try {
                        player.togglePlaying();
                    } catch (error) {
                        // A player object can die under us (the daemon
                        // restarted, the bus name went away). Calling into a
                        // destroyed QObject throws here, and swallowing it
                        // would put the gesture back to doing nothing at all
                        // -- with the music stopped and no way back from the
                        // gesture. Say what happened and leave the shell
                        // alive; the media keys still work regardless.
                        console.warn(`[tap] play/pause failed: ${error}`);
                    }
                    return;
                }
                // No player at all. Fall through to the old behaviour rather
                // than making the gesture do nothing, since a desktop with no
                // media running has no play/pause to perform.
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
