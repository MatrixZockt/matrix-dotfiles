pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets

Scope {
    id: bar
    property bool showBarBackground: Config.options.bar.showBackground
    // The per-monitor bar instance publishes its pocket proxy here so the
    // IPC test hook (outside the monitor scope) can reach into BarContent.
    property var pocketArmer: null
    // Same, for the input-region diagnostic (see `gapState` on the IPC
    // handler below and `gapProxy` inside the bar window).
    property var gapAsker: null

    // ── "Fills the screen" ──────────────────────────────────────────────
    // Set by the compositor config (custom/keybinds.lua) over the
    // `quickshell:barCover` target, below.
    //
    // TRUE fullscreen needs no help: the client renders over the bar, so the
    // bar is already invisible. But the state this desktop actually wants is
    // the window filling the monitor while KEEPING ITS OWN CHROME -- a browser
    // keeps its tabs -- and Hyprland can only do that as "maximized". A
    // maximized window stops at the bar's exclusive zone, so it could never
    // reach the top: the bar's strip stayed reserved, the window began at
    // y=51, and that gap stayed hoverable. Which is exactly what SUPER+F and
    // the four-finger swipe were reported as doing.
    //
    // The compositor cannot release that zone by itself -- the reservation is
    // the shell's own layer-shell surface -- so it says so and the bar gives
    // the strip up: exclusiveZone drops to 0, the maximized window expands
    // into it, the bar slides out the way it does under fullscreen, and the
    // app is never told it is fullscreen. Both halves of the request are in
    // this one flag, so the two can never disagree. The state itself lives in
    // GlobalStates (see there) -- `pragma ComponentBehavior: Bound` means a
    // property on this Scope is NOT reachable from inside the per-monitor
    // component that draws the bar.
    readonly property bool coverRequested: GlobalStates.barCoverRequested

    IpcHandler {
        target: "barCover"
        // Both arguments are declared as strings because that is all a
        // Quickshell IPC boundary can carry (a QVariant is refused outright),
        // and the compositor sends exactly that: `ipc call barCover cover
        // true 0x…`. The flag is read permissively anyway -- a bar stuck
        // yielded because a boolean did not coerce is the worst possible
        // failure for this feature.
        function onCover(on: string, address: string) {
            GlobalStates.barCoverRequested = on === "true" || on === "1"
            GlobalStates.barCoverAddress = GlobalStates.barCoverRequested ? String(address ?? "") : ""
            // The window half of the cover lands without any compositor
            // event (float/move/resize are silent on this build), so the
            // window list would keep describing the old tile until the next
            // unrelated event. Ask for the bounded follow-up re-reads now,
            // while there is a question to answer.
            if (GlobalStates.barCoverRequested)
                HyprlandData.recheckSilentGeometry();
        }
    }

    // The window this was requested FOR, so a bar that has given up its strip
    // can tell whether the window that asked still exists.
    // (Read through GlobalStates -- see the note on the flag itself.)
    readonly property string coverAddress: GlobalStates.barCoverAddress

    // NO shell-side watchdog on this flag, deliberately. Two were tried and
    // both broke the feature rather than protecting it:
    //
    //   * Matching the covered window's address across
    //     `Hyprland.monitors[].activeWorkspace.toplevels` -- `Hyprland.monitors`
    //     is not a plain array (no `.length`), so the "did I find any monitor?"
    //     guard never fired and the timer cleared the flag on its FIRST tick,
    //     700ms after every request.
    //   * Clearing when `Hyprland.activeToplevel` is null -- which is the
    //     normal state whenever focus is not on a window (a layer surface has
    //     it, the bar's own popups have it), so this cleared the flag while
    //     the window was very much still there and covered.
    //
    // The compositor is the only writer and it always pairs enter with exit
    // (custom/cover.lua), so the flag cannot drift while anything is under it.
    // The one unpaired case -- a covered window closed from its own titlebar --
    // is benign rather than broken: the strip stays free and the bar is still
    // summonable with SUPER (bar.autoHide.showWhenPressingSuper is on), and
    // the next cover toggle re-syncs it. Trading a cosmetic state for a timer
    // that breaks the feature every time is not a trade worth making.


    Variants {
        // For each monitor
        model: {
            const screens = Quickshell.screens;
            const list = Config.options.bar.screenList;
            if (!list || list.length === 0)
                return screens;
            return screens.filter(screen => list.includes(screen.name));
        }
        LazyLoader {
            id: barLoader
            active: GlobalStates.barOpen && !GlobalStates.screenLocked
            required property ShellScreen modelData
            component: PanelWindow { // Bar window
                id: barRoot
                screen: barLoader.modelData

                Timer {
                    id: showBarTimer
                    interval: (Config?.options.bar.autoHide.showWhenPressingSuper.delay ?? 100)
                    repeat: false
                    onTriggered: {
                        barRoot.superShow = true
                    }
                }
                Connections {
                    target: GlobalStates
                    function onSuperDownChanged() {
                        if (!Config?.options.bar.autoHide.showWhenPressingSuper.enable) return;
                        if (GlobalStates.superDown) showBarTimer.restart();
                        else {
                            showBarTimer.stop();
                            barRoot.superShow = false;
                        }
                    }
                }
                property bool superShow: false
                // The pin that can never be unpinned. `superShow` is set while
                // Super is held and cleared on its release, which is an event
                // like any other and can be missed -- a key-up eaten during a
                // compositor hiccup, a re-join, a workspace swipe. Nothing else
                // clears it: not the pointer leaving, not a window going
                // fullscreen, not the edge reveal ending. The bar then simply
                // stays down over everything, indefinitely, with nothing
                // holding it.
                //
                // So the release is not trusted on its own: while the flag is
                // set, the actual key state is polled, and the flag is dropped
                // the moment Super is demonstrably not down. Nothing to undo
                // when the release arrives normally -- the poll just finds the
                // flag already false.
                Timer {
                    interval: 400
                    repeat: true
                    running: barRoot.superShow
                    onTriggered: {
                        if (!GlobalStates.superDown)
                            barRoot.superShow = false;
                    }
                }

                // ── Fullscreen reachability ─────────────────────────────────
                // A fullscreen client renders above every Top-layer surface, so
                // the bar used to simply vanish with no way back. Now: the bar
                // sits in the Overlay layer, hides itself while a window on this
                // monitor is fullscreen, and the very top edge brings it back --
                // with the same little hint pill the sidebars' edge reveal shows.
                //
                // Under a fullscreen window the edge has to be *rested on*, not
                // merely crossed: the pointer must sit within `fsEdgeBand` pixels
                // of the border and stay there for `fsRevealDelay`. That is the
                // sidebars' behaviour turned a quarter turn, and it is what stops
                // the bar dropping over a fullscreen app every time the pointer
                // sweeps past the top of the screen.
                // Bumped by the compositor's own event stream so the binding
                // below is RE-EVALUATED on a fullscreen/workspace change.
                //
                // Reading `toplevels.values` in a binding only re-runs when the
                // JS engine sees a property it tracks change. Two things defeat
                // that here, and both were measured on this machine:
                //
                //   * The workspace's toplevel ARRAY is repopulated on a switch
                //     while the entries' `wayland.fullscreen` flags settle a
                //     beat later. The binding ran on the new array, read the
                //     stale flag, and nothing ever asked it to look again --
                //     which is exactly "I came back to my fullscreen app and
                //     the bar was showing, as if it weren't fullscreen".
                //   * The list does not always shrink back either: across four
                //     desktop switches the same toplevel read 1, 3, 4, 4
                //     entries, so a removed window can keep a stale fullscreen
                //     flag alive and pin the bar down on desktops that have
                //     nothing fullscreen on them.
                //
                // So the count is computed against an event-driven revision
                // rather than trusted to the model alone, and re-checked once
                // more after the switch settles (see fsSettle below). The
                // stale-entry case is handled by the settle pass reading the
                // list again; the array no longer shrinking is a compositor
                // model quirk this cannot fix, but the settle pass runs after
                // it has, so the steady state is correct either way.
                property int fsRevision: 0
                // A short re-check after a workspace/fullscreen event. The
                // compositor settles the toplevel flags within a frame or two
                // of the switch; 120ms is comfortably past that and short
                // enough that nobody sees the bar.
                Timer {
                    id: fsSettle
                    interval: 120
                    repeat: false
                    onTriggered: barRoot.fsRevision++
                }
                Connections {
                    target: Hyprland
                    function onRawEvent(event) {
                        const n = event?.name ?? "";
                        if (n.startsWith("fullscreen") || n.startsWith("workspace")
                            || n.startsWith("openwindow") || n.startsWith("closewindow")
                            || n.startsWith("movewindow") || n.startsWith("moveworkspacev2")
                            || n.startsWith("focuswindow")) {
                            barRoot.fsRevision++;
                            fsSettle.restart();
                        }
                    }
                }
                readonly property bool fullscreenOnMonitor: {
                    // The revision is read first so it is a tracked dependency:
                    // without it this is a pure function of the data and the
                    // event stream above would have nothing to act on.
                    const rev = barRoot.fsRevision;
                    // AUTHORITY: HyprlandData, not the Quickshell toplevel
                    // model. The model was measured going wrong in both
                    // directions on this machine -- its toplevel array for the
                    // active workspace read 0 entries while `hyprctl` reported
                    // a window there, and it grew 1,3,4,4 across four desktop
                    // switches (torn-down entries linger with their flags
                    // intact). Both faults land on this one line: an empty
                    // array says "nothing is fullscreen" and the bar drops
                    // over a fullscreen app, a lingering entry says
                    // "fullscreen" and pins the bar down on a desktop with
                    // nothing fullscreen on it. That second one is the same
                    // class of bug as the report.
                    //
                    // HyprlandData is `hyprctl clients -j` re-read on every
                    // window/workspace event, which is the compositor's own
                    // answer rather than a cached mirror of it, and it is what
                    // the rest of this shell already trusts for window state.
                    const mon = Hyprland.monitorFor(barLoader.modelData);
                    const activeWs = Number(mon?.activeWorkspace?.id);
                    const list = HyprlandData.windowList ?? [];
                    for (let i = 0; i < list.length; i++) {
                        const c = list[i];
                        // 1 = maximized, 2 = real fullscreen. Only 2 hides the
                        // bar; a maximized window keeps its own chrome and is
                        // handled by the cover path instead.
                        if (Number(c?.fullscreen) !== 2) continue;
                        if (c?.hidden) continue;
                        if (Number(c?.workspace?.id) !== activeWs) continue;
                        return true;
                    }
                    return false;
                }
                // ── The cover, recognised from GEOMETRY alone ──────────────────
                //
                // The `barCoverRequested` latch is the compositor's word for
                // "a window is covering the screen", and it can be late or
                // missing entirely: `qs ipc call` fails while the shell is
                // wedged or starting (measured 2026-10-06: every ipc call
                // timing out for the length of a shell restart), and
                // cover.enter sends it BEFORE the window is floated. When the
                // latch is lost, the bar used to sit on top of the covered
                // window for good -- the strip yielded (that half rides the
                // raw flag) while the bar itself stayed out, which is exactly
                // "the top bar does not disappear while in fullscreen".
                //
                // But the geometry IS the marker (the same rule custom/
                // cover.lua's isCoverState uses), so the bar can read the
                // state straight from the same window list fullscreenOnMonitor
                // scans -- no IPC needed, and it clears itself the moment the
                // window un-floats. Only fs == 0 floating windows qualify:
                // real fullscreen is fullscreenOnMonitor's job (fs == 2), and
                // a merely MAXIMIZED window (fs == 1) deliberately keeps the
                // bar, because it keeps its own chrome.
                readonly property bool coverByGeometry: {
                    // Revision read first so the event stream keeps this
                    // binding warm, the same way fullscreenOnMonitor does.
                    const rev = barRoot.fsRevision;
                    const scr = barRoot.screen;
                    if (!scr) return false;
                    const lw = Number(scr.width);
                    const lh = Number(scr.height);
                    if (!Number.isFinite(lw) || !Number.isFinite(lh) || lw <= 0 || lh <= 0)
                        return false;
                    const mon = Hyprland.monitorFor(barLoader.modelData);
                    const activeWs = Number(mon?.activeWorkspace?.id);
                    const list = HyprlandData.windowList ?? [];
                    const near = (a, b) => Math.abs(Number(a ?? 0) - b) <= 2;
                    for (let i = 0; i < list.length; i++) {
                        const c = list[i];
                        if (Number(c?.fullscreen ?? 0) !== 0) continue;
                        if (c?.hidden) continue;
                        if (c?.floating !== true) continue;
                        if (Number(c?.workspace?.id) !== activeWs) continue;
                        const at = c.at ?? [];
                        const sz = c.size ?? [];
                        if (near(at[0], Number(scr.x ?? 0))
                            && near(at[1], Number(scr.y ?? 0))
                            && near(sz[0], lw) && near(sz[1], lh))
                            return true;
                    }
                    return false;
                }
                // Is the window that asked for the bar's strip still here?
                //
                // The cover flag (custom/cover.lua -> barCover IPC) is only
                // ever cleared by its twin, so anything that ends the covering
                // WITHOUT going through cover.exit leaves it set: the window
                // closed from its own titlebar, the app quit while maximized,
                // the window was sent to another desktop. The bar then yields
                // its strip for a window that no longer exists, and since the
                // flag is global it hides on EVERY desktop afterwards -- which
                // is exactly "the bar is not shown on new desktops".
                //
                // This is derived, not a watchdog timer: the toplevel list is
                // reactive, so the bar comes back the moment the window is
                // gone or has left this workspace, and stays hidden exactly
                // as long as the window really is here. (Two earlier attempts
                // at this used a timer and the wrong data source -- see the
                // note above on the flag; `ws.toplevels.values` is the same
                // access path fullscreenOnMonitor above already uses.)
                readonly property bool coverAlive: {
                    // GlobalStates directly, NOT barRoot.coverRequested /
                    // .coverAddress: those two mirror properties are declared on
                    // the OUTER Scope (see `coverRequested` above), while this
                    // runs inside the per-monitor PanelWindow, whose id is
                    // barRoot. They are not the same object, so the barRoot.*
                    // reads were `undefined` on both terms -- `!undefined` is
                    // true, so coverAlive returned false unconditionally and
                    // the cover path could never hide the bar or drop its
                    // exclusive zone. That is the "maximize does not reach the
                    // top edge" bug, and it is why real fullscreen (which goes
                    // through fullscreenOnMonitor and never touches these two)
                    // behaved correctly while cover did not. Read the one
                    // source both paths already share, the same way
                    // hiddenByFullscreen below does.
                    if (!GlobalStates.barCoverRequested || !GlobalStates.barCoverAddress)
                        return false;
                    // Same revision read and the same authority as
                    // fullscreenOnMonitor above: the covering window's presence
                    // has to be re-checked when the compositor says something
                    // changed, against `hyprctl` rather than the toplevel model
                    // (which reported windows that were not there and omitted
                    // ones that were).
                    const rev = barRoot.fsRevision;
                    const win = HyprlandData.windowByAddress?.[String(GlobalStates.barCoverAddress)];
                    if (!win || win.hidden)
                        return false;
                    // THE COVER ITSELF, not merely a window that exists.
                    //
                    // "Alive" was the whole test until this, and it is wrong
                    // because the flag is a SINGLE GLOBAL SLOT written by a
                    // compositor module whose enter/exit pairs demonstrably
                    // do not balance. From /tmp/hypr-cover.log on this
                    // machine:
                    //
                    //   22:06:53 enter 0x55d3787dff10   (no exit follows)
                    //   22:08:54 enter 0x55d37a32c980   (a SECOND cover)
                    //   22:17:27 exit  0x55d3787dff10 (strip held: another cover)
                    //
                    // Two windows were covered, and the second enter OVERWROTE
                    // the slot. The first window's exit then found "another
                    // cover" and deliberately sent no IPC, so the slot is left
                    // naming whichever window entered LAST -- which may since
                    // have been restored, moved or closed. The flag stays set,
                    // and the old test ("is that window still on the
                    // compositor?") keeps answering yes for an app that is
                    // sitting in a normal tile.
                    //
                    // Which is the reported bug exactly: the bar hidden by a
                    // fullscreen window that is not fullscreen any more, and
                    // `bar.coverRequested` there is a latch nothing clears.
                    //
                    // So the window named by the flag is asked the same
                    // question custom/cover.lua asks itself in isCoverState --
                    // real fullscreen, OR a float that fills its monitor --
                    // and the flag only counts while the answer is yes. A
                    // stale slot naming a window that is merely ALIVE now
                    // reads as not-covering, the bar comes back, and a genuine
                    // cover still hides it because a genuine cover passes
                    // this test by construction.
                    if (!barRoot.windowIsCovering(win))
                        return false;
                    // A window on a SPECIAL workspace is parked, not covering.
                    //
                    // This is the shell-side twin of the same bug fixed in
                    // custom/cover.lua on 2026-09-30, and it has the same
                    // standing example: the hidden Thunderbird, which
                    // services/TrayApps.qml parks on `special:tray` (workspace
                    // id -98). Measured on this machine:
                    //
                    //     class=org.mozilla.Thunderbird  ws.id=-98
                    //     at=[-1,-1] size=[1600,1000]  hidden=False
                    //
                    // Note `hidden` is FALSE for it -- hyprctl does not set
                    // that field for a window on a special workspace, it just
                    // reports the workspace id. So `!win.hidden` alone called
                    // this parked window ALIVE, the bar kept its strip
                    // released (exclusiveZone 0, `hyprctl monitors` reserved
                    // [0,0,0,0]), and every tiled window started at y=6 and
                    // slid under the 190px-tall bar. That is the reported
                    // "it doesnt attach properply showin the top bar and
                    // everything anymore", and it is permanent: the window
                    // never leaves the vault, so the flag never clears.
                    //
                    // fullscreenOnMonitor above already gets this right -- it
                    // tests the workspace id as well as `hidden`. This now
                    // matches it, instead of the two paths disagreeing about
                    // what "on screen" means.
                    const wsId = Number(win.workspace?.id);
                    if (Number.isFinite(wsId) && wsId < 1)
                        return false;
                    return true;
                }
                // Settings > Bar > "Keep the bar over fullscreen windows". When
                // it is on, a fullscreen window no longer hides the bar and the
                // edge-reveal below stops being needed on this monitor.
                readonly property bool keepOverFullscreen: Config?.options.bar.showInFullscreen ?? false
                // ── Does this window COVER the monitor? ───────────────────────
                //
                // The shell-side twin of isCoverState() in custom/cover.lua,
                // deliberately the same predicate and the same 2px tolerance.
                //
                // A cover is NOT Hyprland fullscreen: SUPER+F floats the window
                // and pins it to the monitor (that module's `enter`), so
                // `fullscreen` reads 0 and the ONLY evidence is the geometry.
                // That is why the bar cannot simply test `fullscreen == 2` here
                // -- see coverAlive, which is exactly the bug this closes.
                //
                // The tolerance is load-bearing and mirrors the Lua's: this
                // compositor does not hand back the geometry that was
                // dispatched, because the float rules put one logical pixel
                // between a window and the screen edge. A covered window reads
                // back at (1,1), not (0,0), so an exact test would call every
                // genuine cover "not covering" and the bar would sit on top of
                // the app it is supposed to get out of the way of.
                function windowIsCovering(win): boolean {
                    if (!win)
                        return false;
                    // Same two exclusions as the Lua's canCoverScreen: a
                    // window on a special workspace is PARKED (TrayApps puts
                    // close-to-tray windows on `special:tray`), and hyprland
                    // does not set `hidden` for those -- the negative
                    // workspace id is the only signal. A parked window is
                    // exactly monitor-sized and floating, so without this it
                    // reads as a cover forever.
                    const wsId = Number(win.workspace?.id);
                    if (Number.isFinite(wsId) && wsId < 1)
                        return false;
                    if (win.hidden === true)
                        return false;
                    // ON THE WORKSPACE YOU ARE LOOKING AT. This is the half
                    // that was missing, and it is the reported bug: switch from
                    // a desktop where the bar shows to one with a fullscreen
                    // app and the bar stays visible; the mirror of it is
                    // switching AWAY and the bar never comes back.
                    //
                    // Reproduced on this machine with the cover sitting on ws3
                    // and the active workspace on ws4 -- a desktop with nothing
                    // fullscreen on it at all:
                    //
                    //   brave-browser    ws=1 fs=0 flt=False
                    //   kitty            ws=2 fs=0 flt=False
                    //   firefox          ws=1 fs=0 flt=False
                    //   freebuff         ws=3 fs=0 flt=True at=[-1,-1] 1600x1000  <== cover
                    //   Thunderbird      ws=4 fs=0 flt=False
                    //   -> fsHidden=true, slidOut=true   (bar hidden, wrongly)
                    //
                    // A cover on another desktop covers a screen nobody is
                    // looking at. The bar is per-monitor, not per-desktop, so
                    // without this the cover keeps the bar off-screen on every
                    // workspace, and the edge-reveal becomes the only way back
                    // -- which is the "it wont disappear" / "stuck open" pair.
                    //
                    // Read from the same authority as fullscreenOnMonitor
                    // above, and invalidated by the same `fsRevision`, so a
                    // workspace switch re-evaluates it. `Number()` on a
                    // missing id gives NaN, which fails the equality and so
                    // reads as "not here" -- the safe direction: the bar comes
                    // back rather than staying out of reach.
                    const activeWs = Number(
                        Hyprland.monitorFor(barLoader.modelData)?.activeWorkspace?.id);
                    if (Number.isFinite(activeWs) && wsId !== activeWs)
                        return false;
                    // A real fullscreen window covers by definition, and it
                    // cannot be un-floated, so the geometry test does not
                    // apply to it.
                    if (Number(win.fullscreen ?? 0) !== 0)
                        return true;
                    if (win.floating !== true)
                        return false;
                    const scr = barRoot.screen;
                    if (!scr)
                        return false;
                    // The screen is already in LOGICAL pixels (Quickshell
                    // scales it), and so is a client's at/size, so they are
                    // compared directly. No scale division here: doing it
                    // twice is how a 2560-wide monitor ends up tested against
                    // 1600-wide geometry and every cover reads as too small.
                    const lw = Number(scr.width);
                    const lh = Number(scr.height);
                    const at = win.at ?? [];
                    const sz = win.size ?? [];
                    if (!Number.isFinite(lw) || !Number.isFinite(lh) || lw <= 0 || lh <= 0)
                        return false;
                    const near = (a, b) => Math.abs(Number(a ?? 0) - b) <= 2;
                    return near(at[0], Number(scr.x ?? 0))
                        && near(at[1], Number(scr.y ?? 0))
                        && near(sz[0], lw) && near(sz[1], lh);
                }
                property bool fsShow: false
                // Pinned: while true the bar STAYS down over the fullscreen
                // app (no 300ms fade, no dwell needed to keep it). Set by the
                // pin button inside the bar itself, cleared by the same
                // button or by leaving fullscreen. Clean toggle model:
                // hover-dwell *summons* (transient), the pin *keeps*.
                property bool fsPinned: false
                // The strip that stays interactive while the bar is slid out --
                // the only thing that can bring it back, so it is wider than the
                // 2px hover band the rest of the time.
                readonly property int hiddenStripHeight: 4
                // How long the pointer has to rest on the border before the
                // edge is considered ARMED. Arming is NOT opening: see
                // `edgePressOpens` below. It exists so the hint has time to
                // appear before the press is expected, matching the sidebar's
                // hover-intent delay.
                readonly property int fsRevealDelay: 500
                // "Completely at the border": within the first couple of
                // pixels, not merely somewhere in the bar's band.
                readonly property int fsEdgeBand: 2
                // ── The top edge opens on HOVER **AND** PRESS ────────────────
                //
                // The same two-gesture model as the sidebars (EdgeReveal.qml):
                // hover arms the affordance, a press opens. Applied to the top
                // edge in BOTH contexts, not only under fullscreen.
                //
                // It used to open on hover alone, via `fsRevealTimer`: resting
                // the pointer on the border for `fsRevealDelay` dropped the bar
                // with nothing else asked for. That is wrong for the same
                // reason it is wrong for the sidebar edges -- a pointer
                // travelling to the top of the screen crosses that border
                // constantly, and every crossing summoned a bar that then had
                // to be dismissed again. The mouse has to ARRIVE at the top of
                // the screen constantly; it does not have to ask for the bar.
                //
                // The press is the ask. Deliberately still requiring the pointer
                // to be ON the edge when the press lands (`fsEdgeArmed`), so a
                // click that happens to pass over the strip on its way to
                // something else cannot summon the bar either.
                readonly property bool fsEdgeArmed: barRoot.pointerInBar
                    && hoverRegion.mouseY <= barRoot.fsEdgeBand
                // Set by the edge press, and cleared by every path that puts
                // the bar away. This is the "the user asked for it" half of the
                // gesture, and it is what `hoverReveals` reads in the
                // non-fullscreen case (see there).
                property bool edgePressOpened: false
                // ── The fullscreen rule, in one number ────────────────────────────────
                // While a window is fullscreen and the pointer is NOT on the
                // bar, the bar gets this long and no more. Then it goes,
                // whatever else it thinks it wants.
                //
                // This is the whole rule the bar had been failing to keep, and
                // it is deliberately a NUMBER rather than a set of flags. Every
                // earlier attempt expressed it as "hide unless something holds
                // the bar open" (hover, a SUPER tap, a pin, a swipe tail), and
                // every one of those holds was cleared by an EVENT -- a timer, a
                // key-up, a leave. An event that does not arrive leaves the bar
                // over the fullscreen app for good, which is exactly the
                // reported bug: the bar would not go away, and the only thing
                // that recovered it was toggling fullscreen.
                //
                // A duration cannot be missed. Nothing has to fire for it to
                // elapse; it simply runs out.
                // 2s of pointer-on-bar time before the bar retracts over a
                // fullscreen app.
                readonly property int fsOpenHoldMs: 2000
                // Is the bar allowed to be open right now? One predicate, and
                // the ONLY thing that decides: fullscreen plus a pointer on the
                // bar plus time still on the clock.
                //
                // `fsHoverSince` is stamped the moment the pointer arrives and
                // cleared the moment it leaves, so "time still on the clock" is
                // just "the pointer has been here for less than 2s". The
                // pointer leaving does not have to be observed by anything for
                // the countdown to end -- it ends because the stamp is stale,
                // which is checked on a plain interval below.
                property double fsHoverSince: -1
                // Was the pointer ALREADY over the bar at the instant
                // fullscreen began? If so it gets no say at all.
                //
                // This is what makes the bar leave the instant an app goes
                // fullscreen instead of sitting there for its 2s. The hold
                // exists for a pointer that ARRIVES on a bar which is already
                // hidden -- a deliberate reach for it. A pointer that happened
                // to be parked near the top when the app went fullscreen has
                // expressed no intent at all, and letting it spend the hold is
                // how "the bar covers my fullscreen app for two seconds, then
                // goes" happens: SUPER+F is pressed from the keyboard while
                // the cursor is wherever it was left, which is very often the
                // bar.
                //
                // Cleared the moment the pointer leaves the band, so the first
                // genuine reach afterwards is honoured normally. Both edges are
                // geometric (`pointerInBar`), so neither depends on a hover
                // event arriving.
                property bool fsPrewasInBar: false
                // ── The edge press is the only opener under fullscreen ─────
                //
                // While a desktop app is fullscreen the bar comes out when
                // the pointer is at the top edge AND that edge is pressed or
                // tapped -- and on nothing else. Hover alone must not open
                // it: the pointer reaches the top of the screen constantly
                // (tabs, window controls, the cursor resting there), and a
                // hover-open dropped the bar over videos and games every time.
                //
                // Off fullscreen this gates nothing -- autoHide is off, so
                // the bar is simply on screen there -- which is the required
                // split exactly: hover is a way to reveal things only while
                // no desktop app is fullscreen.
                //
                // Set by `requestFullscreenReveal` (the press, and the IPC)
                // and by nothing else. `noteFullscreenHover` is called from
                // the hover handler and from fsIdleWatch every 100ms, and it
                // now REFUSES to arm the hold clock unless this is already
                // set, so a pointer merely resting on the edge cannot open
                // the bar. Cleared by `clearFullscreenHover`, which every
                // path that puts the bar away goes through.
                property bool fsPressReveal: false
                readonly property bool fsBarAllowedOpen: barRoot.hiddenByFullscreen
                    && barRoot.fsPressReveal
                    && !barRoot.fsPrewasInBar
                    && barRoot.fsHoverSince > 0
                    && (Date.now() - barRoot.fsHoverSince) < barRoot.fsOpenHoldMs
                // Note the pointer arriving on the bar. Called from the hover
                // handler rather than derived from `containsMouse`, because that
                // latch is exactly what used to strand the bar (see
                // `pointerInBar` below).
                function noteFullscreenHover() {
                    if (!barRoot.hiddenByFullscreen)
                        return;
                    // Hover is not a request. Until the edge has actually
                    // been pressed there is no hold to refresh, so a pointer
                    // that drifts onto the top edge of a fullscreen app arms
                    // nothing and the bar stays away.
                    if (!barRoot.fsPressReveal)
                        return;
                    // A pointer that was already here when fullscreen started
                    // is not asking for the bar. See `fsPrewasInBar`.
                    if (barRoot.fsPrewasInBar)
                        return;
                    if (barRoot.fsHoverSince <= 0)
                        barRoot.fsHoverSince = Date.now();
                }
                function clearFullscreenHover() {
                    barRoot.fsHoverSince = -1;
                    // The press belongs to this one reveal: once the hold is
                    // dropped, the next arrival at the edge has to press
                    // again rather than inherit the old one.
                    barRoot.fsPressReveal = false;
                }
                // The reveal. With the rule above there is nothing separate to
                // request: the bar is open exactly while the pointer is on it
                // and the 2s has not run out. Kept as a named function
                // because the edge press, the hover handler and the IPC all
                // need to express the same intent, and the intent is "the bar
                // may be open", not "set this flag".
                function requestFullscreenReveal() {
                    if (!barRoot.hiddenByFullscreen)
                        return;
                    barRoot.fsPinned = false;
                    // A press IS intent, whatever the pointer was doing at the
                    // instant fullscreen began: the pre-was-in-the-bar veto
                    // does not apply to it, and the hold clock starts NOW
                    // rather than inheriting a stale stamp.
                    barRoot.fsPrewasInBar = false;
                    barRoot.fsPressReveal = true;
                    barRoot.fsHoverSince = Date.now();
                }
                function clearFullscreenReveal() {
                    barRoot.clearFullscreenHover();
                    barRoot.fsShow = false;
                }
                // Every path that puts the bar away also spends the edge press,
                // so the next hover cannot be mistaken for the press still
                // being held. Without this, `edgePressOpened` would latch and
                // the bar would come back on hover forever after one press.
                function clearEdgePress() {
                    barRoot.edgePressOpened = false;
                }
                // The non-fullscreen half of the edge press. Split out because
                // the fullscreen half has to go through `requestFullscreenReveal`
                // (which stamps the hover clock and is a no-op off fullscreen)
                // while this one must not: off fullscreen there is no hover
                // clock to spend, the request IS the flag.
                //
                // Refuses when the bar is already out, so a second press cannot
                // be read as "toggle it away" -- the press only ever opens.
                function requestEdgePressReveal() {
                    if (barRoot.hiddenByFullscreen) {
                        barRoot.requestFullscreenReveal();
                        return;
                    }
                    if (barRoot.edgePressOpened)
                        return;
                    barRoot.edgePressOpened = true;
                    barRoot.clearFullscreenReveal();
                }
                // The rule, enforced on a plain interval. This is the only
                // thing that decides whether the bar is allowed to be open, and
                // it cannot be outvoted: every other flag in the file
                // (`fsShow`, `fsPinned`, `gapHolding`, `superShow`,
                // `postSwipe`) is cleared here rather than consulted, so a stale
                // one cannot keep the bar on screen. If the timer itself is
                // starved the bar stays open -- a slow frame, not a stuck bar --
                // and the next tick puts it away.
                Timer {
                    id: fsIdleWatch
                    interval: 100
                    repeat: true
                    running: barRoot.hiddenByFullscreen
                    onTriggered: {
                        // The pointer is on the bar: restart its 2s.
                        if (barRoot.pointerInBar) {
                            barRoot.noteFullscreenHover();
                            return;
                        }
                        // A PRESS BOUGHT THIS REVEAL, AND THE PRESS IS WORTH
                        // THE WHOLE 2s. Losing the pointer must not cut it
                        // short -- the reveal is exactly what the user asked
                        // for, and the hold exists to give them time to reach
                        // something on the bar.
                        //
                        // Without this the bar closed INSTANTLY on hover+click
                        // instead of holding: the pointer reads as "not on the
                        // bar" for a beat straight after the reveal, because
                        // the surface's input region is recast from the 4px
                        // strip to the full bar at that moment, and this else
                        // branch then spent the hold before it had run.
                        //
                        // This does NOT weaken the duration backstop: it only
                        // defers the teardown until the 2s is up, and once it
                        // is up `fsBarAllowedOpen` goes false and the bar goes
                        // regardless of what the pointer claims. Nor does it
                        // outlive a deliberate dismissal -- `clearFullscreenReveal`
                        // clears `fsPressReveal`, which is what this reads.
                        if (barRoot.fsPressReveal
                            && barRoot.fsHoverSince > 0
                            && (Date.now() - barRoot.fsHoverSince) < barRoot.fsOpenHoldMs)
                            return;
                        // Pointer elsewhere: the bar's time is up, and the
                        // "it was already here when fullscreen began" veto is
                        // spent -- the pointer has now genuinely left, so a
                        // later reach onto the bar counts as intent again.
                        barRoot.fsPrewasInBar = false;
                        barRoot.clearFullscreenHover();
                        barRoot.clearEdgePress();
                        barRoot.fsShow = false;
                        barRoot.fsPinned = false;
                        barRoot.gapHolding = false;
                        barRoot.gapSpent = false;
                        barRoot.postSwipe = false;
                        gapHold.stop();
                    }
                }
                // "The pointer is genuinely over the bar", answered WITHOUT
                // trusting `containsMouse`.
                //
                // `containsMouse` is an event-driven latch: it is cleared by a
                // leave event, and nothing sends one when the bar's own window
                // slides out from under a stationary pointer. The surface moves
                // away; the pointer never moves, so the compositor has no reason
                // to report a change and the latch simply stays true. Every
                // "is the pointer on the bar" test downstream then believes the
                // pointer is hovering a bar that is not on screen -- including
                // the fullscreen enforcer, which yields to exactly that test and
                // so can never force the bar back down. That is the "the bar
                // stays over my fullscreen app until I toggle fullscreen" bug,
                // and it explains why moving the mouse or leaving and re-entering
                // fullscreen appears to fix it: those are the only things that
                // produce the event the latch was waiting for.
                //
                // The fix is to ask about the POINTER rather than about the
                // latch: `mouseX/mouseY` are the last reported coordinates, so
                // they are only meaningful while the pointer is inside -- but
                // combined with `containsMouse` (which says "inside") and a
                // geometric bound (which says "still within the bar's band"),
                // a stale latch cannot survive: once the bar has slid away, the
                // last known Y is outside the band it is being tested against,
                // so this reads false and the enforcer is free to act.
                //
                // Deliberately generous about the band (the full window height
                // plus the pocket) rather than the painted strip: the question
                // is "could the pointer be over the bar", and being wrong in the
                // permissive direction costs one extra frame of animation, while
                // being wrong in the strict direction is the bug above.
                readonly property bool pointerInBar: hoverRegion.containsMouse
                    && hoverRegion.mouseY >= 0
                    && hoverRegion.mouseY <= barRoot.height
                // Hovering anywhere in the bar wakes it normally; under a
                // fullscreen window only the rested-on edge does.
                //
                // The non-fullscreen case reads `edgePressOpened`, NOT
                // `pointerInBar`. That is the whole of "hover AND press": the
                // pointer being on the bar is not enough on its own any more,
                // the press on the top edge is what brings it back. Once it is
                // back the pointer is over it anyway, so this reads as the bar
                // staying up for as long as the pointer rests on it.
                readonly property bool hoverReveals: barRoot.hiddenByFullscreen
                    ? (barRoot.fsShow || barRoot.fsPinned)
                    : barRoot.edgePressOpened
                // ── A press sends the bar away ────────────────────────────────
                //
                // Everything that can hold the bar open over a fullscreen
                // window is cleared HERE, in one place, rather than by each
                // holder noticing. Holding flags are latches by nature: each
                // one is cleared by the thing that set it going away, and any
                // one whose clearing condition is itself gated on "the bar is
                // still up" never gets it. Clearing them all together is what
                // makes "press and it goes" true regardless of which latch
                // happened to be set.
                //
                // The pin is NOT cleared. Pinning is a deliberate statement --
                // "keep this down over my game" -- and a click that lands in a
                // gap is not a request to unpin, it is not even a press the
                // bar sees. A pinned bar stays put, which is the whole promise
                // of the pin.
                function dismissForPress() {
                    if (!barRoot.hiddenByFullscreen)
                        return;
                    barRoot.clearFullscreenReveal();
                    barRoot.clearEdgePress();
                    barRoot.gapHolding = false;
                    barRoot.gapSpent = false;
                    barRoot.postSwipe = false;
                    gapHold.stop();
                    postSwipeTimer.stop();
                    // The slide is re-aimed and restarted rather than left to
                    // `slideSettle`: `hideBySlide` is now false, and a slide
                    // that was already running toward `slideDistance` would
                    // otherwise carry on hiding a bar that is supposed to be
                    // coming back.
                    if (slideAnim.running) {
                        slideAnim.stop();
                        slideAnim.to = 0;
                        slideAnim.start();
                    } else if (barRoot.slideShift !== 0) {
                        barRoot.slideShift = 0;
                    }
                }
                property bool mustShow: hoverReveals || superShow
                    || barRoot.holdingForPointer
                // ═══ Per-desktop bar state (asked for 2026-10-02) ═════════
                //
                // "Every desktop has its own top bar status": a desktop with a
                // fullscreen app has the bar CLOSED, a desktop without one has
                // it OPEN, and which is which does not depend on where you
                // were a moment ago.
                //
                // The live computation (`wsLiveHidden` below) already answers
                // that per active workspace, and it owns the bar's steady
                // state on each desktop. What it cannot do is answer it for
                // the desktop you are ARRIVING at, at the instant you arrive:
                // `HyprlandData.windowList` is a `hyprctl clients -j` re-read,
                // so for a frame or two after a switch it can still be
                // describing the desktop you just left. The bar reads that
                // stale list, decides it is on the wrong kind of desktop, and
                // slides -- which is the dropdown animation on every switch,
                // and (via the strip gate in onHideBySlideChanged) a workarea
                // change under a moving bar, which is the neighbour window
                // enlarging for a second and bouncing back.
                //
                // So the settled answer is remembered per workspace and
                // applied INSTANTLY on arrival. This is a transition shortcut,
                // not a second source of truth: the live value takes back over
                // as soon as the real data catches up (wsSettleHold below).
                readonly property int wsIdNow:
                    Number(Hyprland.monitorFor(barLoader.modelData)?.activeWorkspace?.id ?? -1)
                // Reassigned wholesale on every write, never mutated in place:
                // a `property var` holding an object notifies on reassignment,
                // and wsMemoryWs is a binding that has to re-read it.
                property var wsHiddenMemory: ({})
                // The remembered answer for the desktop being entered, and the
                // desktop it belongs to. -1 = "nothing remembered, use live".
                property int wsMemoryWs: -1
                property bool wsMemoryHidden: false
                // True only across a switch. It is what silences the slide and
                // the strip gate (see onHideBySlideChanged).
                property bool wsSwitching: false
                // Budget for wsReturnCheck, so it cannot poll indefinitely.
                property int wsReturnTicks: 0
                // The live per-desktop answer. This is the real predicate; the
                // memory above shadows it only mid-switch.
                readonly property bool wsLiveHidden:
                    (barRoot.fullscreenOnMonitor
                        || barRoot.coverByGeometry
                        || (GlobalStates.barCoverRequested && barRoot.coverAlive))
                    && !barRoot.keepOverFullscreen
                // A fullscreen window only gets to hide the bar when the setting
                // says so (see keepOverFullscreen above).
                //
                // `bar.coverRequested` is the OTHER way in: the compositor
                // asking for the strip so a "maximized" window can reach the
                // top edge (see the flag on the Scope). It rides the exact same
                // property, so the bar's slide, its exclusive-zone release and
                // its edge-reveal are the fullscreen behaviour in every
                // respect -- there is no second code path that could drift.
                readonly property bool hiddenByFullscreen:
                    (barRoot.wsMemoryWs === barRoot.wsIdNow && barRoot.wsIdNow >= 1)
                        ? barRoot.wsMemoryHidden
                        : barRoot.wsLiveHidden
                // How long a switch stays silent. Long enough for the
                // compositor to settle the toplevel flags AND for
                // `hyprctl clients -j` to come back describing the NEW desktop
                // (fsSettle re-checks at 120ms), so the live value owns the
                // bar again before this releases.
                //
                // Shortened from 260ms down to 120ms: that is the long clock
                // that gets the bar to leave a fullscreen desktop and the delay
                // you notice when you switch away from it. When the bar is
                // visible there is nothing to chase, so the switch is fast
                // regardless and the expensive re-read path
                // (updateWindowList + updateMonitors burning a `hyprctl clients
                // -j`) is not fired. When this fires, it releases the switch
                // hold early so the destination desktop's real state can own
                // the bar and wsReturnCheck can chase it down.
                Timer {
                    id: wsSettleHold
                    interval: 120
                    repeat: false
                    onTriggered: {
                        barRoot.wsSwitching = false;
                        barRoot.wsMemoryWs = -1;
                        // Bare id, NOT `barRoot.wsReturnCheck`. `wsReturnCheck`
                        // is the id of a sibling Timer BELOW; ids are resolved
                        // lexically and are not properties of the root, so
                        // `barRoot.wsReturnCheck` was `undefined` and this line
                        // threw
                        //     TypeError: Cannot read property 'restart' of undefined
                        // on EVERY workspace switch -- aborting the handler, so
                        // the return-from-fullscreen re-check never started and
                        // the bar stayed hidden at the fullscreen desktop's
                        // height until an unrelated event fixed it. The throw
                        // is also why the log carried one such warning per
                        // switch. Same mistake the TouchpadSwipe tracker made
                        // with `root.restartDelay`.
                        wsReturnCheck.restart();
                    }
                }
                // ── Coming back from fullscreen, fast ────────────────────────
                //
                // The reported symptom: switch from a desktop with a fullscreen
                // app to one without, and the bar sits there for noticeably
                // longer than it should before it reappears.
                //
                // Why it is not already instant. Leaving a fullscreen desktop
                // for a plain one, `hiddenByFullscreen` is answered from ONE of
                // two sources, and both can be wrong in the same direction --
                // "still fullscreen", so the bar stays down:
                //
                //   * the remembered state, when this desktop HAS a sample. The
                //     500ms poll below writes it, so a desktop you have been
                //     sitting on has one -- and that one is correct.
                //
                //   * the live value otherwise, i.e. a desktop never sampled.
                //     `fullscreenOnMonitor` compares each window's workspace
                //     against `monitor.activeWorkspace.id`. If the monitor
                //     object has not caught up with the switch yet, that is
                //     still the FULLSCREEN desktop's id, so the fullscreen
                //     window sitting on it matches -- and the bar is told the
                //     new desktop is fullscreen when nothing on it is. Nothing
                //     corrects that until the compositor model catches up,
                //     which is what "takes way too long to realize" is.
                //
                // `fsSettle` already re-reads at 120ms, but it only bumps a
                // revision: if the model still has not caught up, it faithfully
                // re-reads the same wrong answer. Time alone is not the missing
                // ingredient; a fresh READ is.
                //
                // So this drops the shadow and forces the re-read, repeatedly,
                // for a short bounded window -- and ONLY while the bar is
                // actually down. That asymmetry is deliberate and is what makes
                // it safe: the one thing this can do is make a hidden bar
                // reappear sooner. It can never delay a hide, so the
                // "switching TO a fullscreen desktop briefly shows the bar"
                // risk that a symmetric version would carry does not exist.
                //
                // The shadow is deliberately left alone. Clearing it is what
                // would let a transitional value get filed, and it is also what
                // protects arriving at a fullscreen desktop from a flash of
                // bar; dropping it here would trade that for nothing.
                Timer {
                    id: wsReturnCheck
                    interval: 60
                    repeat: true
                    running: false
                    onTriggered: {
                        // Force a fresh read of the compositor's own answer.
                        // `updateWindowList()` re-forks `hyprctl clients -j`
                        // AND `updateMonitors()` re-reads the monitor objects --
                        // both are needed, because the bug is a STALE PAIR: the
                        // window list and the monitor's activeWorkspace have to
                        // describe the same desktop for the test below to mean
                        // anything, and the revision bump on its own would only
                        // re-evaluate the same two stale values against each
                        // other. The revision is still bumped so the bindings
                        // re-run once the new data lands.
                        HyprlandData.updateWindowList();
                        HyprlandData.updateMonitors();
                        barRoot.fsRevision++;
                        if (!barRoot.hiddenByFullscreen) {
                            // The bar is back. This has done its job.
                            barRoot.wsReturnTicks = 0;
                            wsReturnCheck.stop();
                            return;
                        }
                        // Bounded, because "the bar is still down" is also the
                        // correct steady state when you switch from one
                        // fullscreen desktop to ANOTHER fullscreen desktop,
                        // and a timer that only stops on success would then
                        // poll for the rest of the session.
                        barRoot.wsReturnTicks++;
                        if (barRoot.wsReturnTicks >= 8) {
                            barRoot.wsReturnTicks = 0;
                            wsReturnCheck.stop();
                        }
                    }
                }
                // Records the settled truth for the desktop in front of you. A
                // slow poll, not a handler: what it stores is the value that
                // was still true a beat later, which is exactly what "what
                // this desktop looks like" has to mean. Suspended during a
                // switch so a transitional value can never be filed as a
                // desktop's resting state.
                // Records the settled truth for the desktop in front of you.
                // Shortened from 500ms. That was the slow clock that got the
                // bar to leave a fullscreen desktop and reappear on the next
                // one, and it was the reason the bar took longer to react than
                // the minimize path did. On each desktop the poll once per half
                // second records the live answer, so a desktop you are sitting
                // on has a stored one; a desktop you are ARRIVING at does not,
                // which is exactly why leaving fullscreen looked slow -- the
                // destination had no memory, fell through to the live value,
                // and the live value still described the old desktop for a frame
                // or two after the switch.
                //
                // 120ms is the floor the file already calls short enough that
                // nobody sees the bar (fsSettle uses it too), and 120ms is the
                // gap between the switch and when the new desktop's memory
                // EXISTS, not when it is correct. The destination's memory
                // appears at worst a frame after the switch; before that the
                // live value is authoritative for the destination and the bar
                // should react immediately. So the poll no longer gates the
                // destination behind a wait: when there is no memory the
                // destination falls through to the live value and the hold
                // (wsSettleHold) releases early, in 120ms rather than 260.
                Timer {
                    interval: 120
                    repeat: true
                    running: !barRoot.wsSwitching
                    onTriggered: {
                        const ws = barRoot.wsIdNow;
                        if (ws < 1)
                            return;
                        barRoot.wsHiddenMemory = Object.assign(
                            {}, barRoot.wsHiddenMemory, { [ws]: barRoot.wsLiveHidden });
                    }
                }
                onWsIdNowChanged: {
                    // Special workspaces (the tray vault, id < 1) are not
                    // desktops and get no memory.
                    if (barRoot.wsIdNow < 1)
                        return;
                    barRoot.wsSwitching = true;
                    // Adopt this desktop's remembered state if it has one. A
                    // desktop never visited falls through to the live value,
                    // which is right -- there is nothing to remember yet.
                    const mem = barRoot.wsHiddenMemory?.[barRoot.wsIdNow];
                    if (mem === undefined) {
                        barRoot.wsMemoryWs = -1;
                    } else {
                        barRoot.wsMemoryWs = barRoot.wsIdNow;
                        barRoot.wsMemoryHidden = mem === true;
                    }
                    wsSettleHold.restart();
                }
                // ── The gaps let the press through ─────────────────────────
                // While the bar is DOWN over a fullscreen app, only the
                // islands may take the pointer; the spacing between them is
                // given back to the app underneath, so a click in a gap is a
                // click on the app.
                //
                // The bar is not drawn there (that is the whole point of the
                // islands) yet the window's input region used to span the
                // full width, so the bar was quietly eating the top strip of
                // a fullscreen window -- the one place the pointer is most
                // often aimed at the app rather than at the bar.
                //
                // Gated on BOTH halves deliberately:
                //
                //   * `hiddenByFullscreen` -- only when a fullscreen app (or
                //     the compositor's "cover" request, which the bar treats
                //     as the same thing) is the reason the bar is in the
                //     way. On an ordinary desktop the gap stays solid, so
                //     moving the pointer through a gap still counts as
                //     hovering the bar and the bar still slides away.
                //   * `!hideBySlide` -- only while the bar is actually DOWN.
                //     Slid out, the strip is the reveal band: it has to stay
                //     whole width or resting on the border would not summon
                //     the bar at all, and the gap would eat the hint's own
                //     hover.
                //
                //   * `!barContent.padGestureLive` -- NOT while a touchpad
                //     gesture is on the pad. This is the one hole that has to
                //     be shut, and it is not about clicks at all.
                //
                //     The brightness/volume swipe (BarContent.handleBarSwipe)
                //     only fires when the pointer is in one of these gaps --
                //     and a touchpad scroll is delivered by the COMPOSITOR to
                //     the surface owning the pointer's pixel, so with the gap
                //     cut out, the same two fingers that the shell is turning
                //     into volume were ALSO scrolling the app underneath: on a
                //     fullscreen browser under the bar, swiping for the volume
                //     switched its tabs. Nothing on the shell side can take
                //     that event back; the input region is the only place that
                //     decides who receives it, so while the fingers are down
                //     the strip is whole and the scroll lands on the bar
                //     (which ignores it -- `padScrollBlocked` -- and writes the
                //     device from the gesture itself).
                //
                //     A gesture is a few hundred milliseconds, and the gaps
                //     come back the moment the fingers lift, so click-through
                //     is untouched for every click. `padGestureLive` is timed
                //     from TOUCH-DOWN (the tracker reports the finger count
                //     before any motion, which is what beats the compositor to
                //     the first notch) and carries a four-second bound, so a
                //     lost end frame cannot leave this shut either.
                // ── OFF. The strip is the bar's, always. ─────────────────
                //
                // The condition that used to be here -- `hiddenByFullscreen &&
                // !hideBySlide` -- cut those stretches out of the bar's input
                // region so clicks could reach the app underneath while the
                // bar was over a fullscreen window. That is right for a click
                // and WRONG for a scroll, and the difference is not something
                // the input region can express: a touchpad scroll is delivered
                // by the COMPOSITOR to the surface that owns the pointer's
                // pixel, so the same two fingers the bar turns into brightness
                // or volume also scrolled the app under the gap -- measured on
                // this machine as "swiping for the volume switches Brave's
                // tabs", with the gate's own log showing the pointer in a gap
                // (`GATE gap ... -> volume`) while the tabs moved.
                //
                // Tried first and rejected: cut the gaps on the gesture only,
                // timed from touch-down (`padGestureLive`). It is a race -- the
                // compositor has already handed out the first notch by the time
                // any signal reaches QML -- and toggling the region makes the
                // bar's hover bounce (the pointer is delivered during the
                // gesture and not before), which is exactly the enter/leave
                // pair the bar's "pointer never left" hold exists to survive.
                // The bar visibly dropped during the swipe.
                //
                // A region cannot hold both properties at once: to stop the app
                // receiving the scroll, the pixel has to be the bar's, and a
                // pixel that is the bar's cannot deliver a click to the app.
                // The swipe was asked for and the click-through was not, so the
                // strip is whole and the app gets nothing. What is given up is
                // clicks in the bar's empty stretches WHILE the bar is over a
                // covering window -- the browser-tab/title strip case this cut
                // was written for.
                //
                // Restoring it is this one expression; everything downstream
                // (`GapCut`, the runs above) is untouched and inert at zero
                // width, so the two states cannot drift.
                readonly property bool gapPassthrough: false
                // ── The click-through runs ─────────────────────────────────
                // The SPACING between the islands, in bar x: before the first
                // island, the two runs between the three, and after the last.
                // Four pairs, and the arithmetic is spelled out rather than
                // looped because a `var` property holding an array is what Qt
                // in this build answers with "should be coerced to void
                // because the function called is insufficiently annotated",
                // once per island edge, per frame (see the note on the runs in
                // BarContent). Numbers are fine.
                //
                // min/max on each pair, so a run that is empty or out of order
                // -- two islands abutting, or one that has grown into its
                // neighbour -- yields from == to, which cuts nothing. A gap
                // that is genuinely negative is not a gap.
                readonly property real gap0From: 0
                readonly property real gap0To: Math.max(0, barContent.leftRunX)
                readonly property real gap1From: Math.min(barContent.leftRunEnd, barContent.centerRunX)
                readonly property real gap1To: Math.max(barContent.leftRunEnd, barContent.centerRunX)
                readonly property real gap2From: Math.min(barContent.centerRunEnd, barContent.rightRunX)
                readonly property real gap2To: Math.max(barContent.centerRunEnd, barContent.rightRunX)
                readonly property real gap3From: barContent.rightRunEnd
                readonly property real gap3To: barRoot.width
                // ── Holding the bar open for a cursor that never left ─────
                // The bar hides the moment the pointer stops hovering it,
                // which is right when the pointer has gone and wrong when it
                // has not gone ANYWHERE. In fullscreen that is exactly what
                // happens in the empty space between the islands, because
                // `gapPassthrough` hands those stretches back to the app
                // underneath: there is no input region left to deliver the
                // pointer, so the bar's own hover goes false and the bar
                // drops out from under a cursor that never moved.
                //
                // NOTE, with the pass-through OFF (see the note on
                // `gapPassthrough` above): the strip is whole, so the pointer
                // IS delivered everywhere on the bar and the case this whole
                // mechanism exists for can no longer arise -- which is also
                // why a swipe over the bar can no longer take the bar down
                // with it. Kept as belt-and-braces: it costs a fork every 90ms
                // only while a cursor is loitering near the strip, and it is
                // the thing that would have to be right again if the
                // pass-through were ever turned back on. That is
                // the same disappearance the swipe hint just had to be taught
                // to ignore, one layer up.
                //
                // The one thing the bar cannot see for itself is therefore
                // asked for directly -- `hyprctl cursorpos -j`, the same
                // probe the swipe gate already forks. It runs ONLY in the
                // ambiguous window (bar showing, pointer not over it) and
                // never while the bar is idle, so the whole thing costs a
                // fork every 90ms for as long as a cursor is loitering near
                // the top strip.
                //
                // Only the two BETWEEN-island runs are tested. gap0 and gap3
                // sit under `barLeftSideMouseArea` / `barRightSideMouseArea`,
                // which are not cut out, so the bar keeps seeing the pointer
                // there and never needs rescuing.
                //
                // Screen x against the gap runs is one axis: the bar's window
                // spans the screen from 0, which is why the swipe gate
                // compares `hyprctl`'s x against `centerIslandRight` directly.
                readonly property bool probeInGap:
                    probeY >= 0 && probeY <= Appearance.sizes.barHeight + 2
                    && ((barRoot.gap1To - barRoot.gap1From > 4
                            && probeX >= barRoot.gap1From
                            && probeX <= barRoot.gap1To)
                        || (barRoot.gap2To - barRoot.gap2From > 4
                            && probeX >= barRoot.gap2From
                            && probeX <= barRoot.gap2To))
                property real probeX: -1
                property real probeY: -1
                // A swipe owns the bar outright: the fingers are on the
                // control, the line is moving, and the bar that shows it
                // cannot slide away underneath. Latched from BarContent's own
                // gesture state, so it starts and stops with the gesture
                // rather than with a timer that has to guess.
                readonly property bool swipeLive: barContent.swipeLiveZone !== ""
                property bool gapHolding: false
                // The tail of a swipe. `swipeLive` is true only while the
                // fingers are down, and the instant they lift the bar would
                // go with them -- which is wrong in the one case the whole
                // hold exists for: the window is still coming up, and the
                // value is still moving. So the last `gapHoldMs` of the swipe
                // is kept as a separate, bounded tail.
                //
                // Bounded is the whole point. An unbounded "keep it open
                // until something else stops it" is what made the bar sit
                // there after a swipe with nothing left holding it, and the
                // two exits are the two the behaviour is actually specified
                // in: this timer, or the pointer leaving the bar.
                property bool postSwipe: false
                // The previous value of `swipeLive`, so the falling edge can
                // be told from the initial undefined -> false at startup.
                property bool swipeWas: false
                onSwipeLiveChanged: {
                    if (barRoot.swipeLive) {
                        // A new gesture: whatever tail the last one left is
                        // not this one's to inherit.
                        barRoot.postSwipe = false;
                        postSwipeTimer.stop();
                        // ...and it consumes the gap window outright. Both
                        // clocks were running at once here -- the cursor sits
                        // in the empty space while the fingers are on the
                        // control, so the probe opened its 700ms window, and
                        // the falling edge then opened a second 700ms one on
                        // top of whatever was left of the first. That is why
                        // a volume change in fullscreen left the bar sitting
                        // there for well over a second: not one window that
                        // ran long, two windows that overlapped.
                        //
                        // One owner at a time. `gapSpent` goes with it so the
                        // poll, which keeps running while the bar is up, cannot
                        // open the window again behind the gesture's back;
                        // only the cursor actually leaving the gap clears it.
                        gapHold.stop();
                        barRoot.gapHolding = false;
                        barRoot.gapSpent = true;
                    } else if (barRoot.swipeWas) {
                        // The one clock that may be running from here.
                        gapHold.stop();
                        barRoot.gapHolding = false;
                        barRoot.postSwipe = true;
                        postSwipeTimer.restart();
                    }
                    barRoot.swipeWas = barRoot.swipeLive;
                }
                // "This visit to the spacing has already had its window."
                // Cleared only by the cursor actually leaving the gap, or by
                // coming back over the bar proper.
                property bool gapSpent: false
                // One clock, for one case. Below the bar the pointer is gone and the bar
                // goes with it, immediately -- there is deliberately no grace
                // on that path, because a cursor that has left is not
                // hovering anything and holding the bar up for it is just
                // lag. The empty space between the islands is the opposite:
                // there the bar cannot see the pointer at all (its input
                // region is given away to the app underneath), so losing the
                // hover there says nothing about where the pointer went. That
                // case gets this window -- long enough to cross a gap and
                // start a swipe without the bar having already gone -- and
                // then closes, unless a swipe took over in the meantime.
                readonly property int gapHoldMs: 200
                readonly property bool holdingForPointer:
                    barRoot.gapHolding || barRoot.swipeLive || barRoot.postSwipe
                // Published so anything that has to clear the bar's strip --
                // the notification popups -- asks the bar instead of guessing
                // at its height, and a hidden bar means there is no strip to
                // clear. One writer, one reader, no drift.
                Binding {
                    target: GlobalStates
                    property: "barHidden"
                    value: barRoot.hiddenByFullscreen
                }
                // Fullscreen went away: the pin and the edge-reveal both die
                // together. Clearing ONLY the pin left `fsShow` true behind, so
                // the next fullscreen session started with the bar already
                // revealed -- stuck open with no pin, closing only when the
                // pointer happened to cross the hidden strip (fsHideTimer's
                // guard kept it alive the rest of the time). Both flags reset
                // together, which makes "pin -> unfullscreen -> fullscreen"
                // behave exactly like a fresh session.
                onHiddenByFullscreenChanged: {
                    // ── Falling edge: fullscreen went away ──────────────────
                    // The pin and the edge-reveal both die together. Clearing
                    // ONLY the pin left `fsShow` true behind, so the next
                    // fullscreen session started with the bar already
                    // revealed -- stuck open with no pin, closing only when the
                    // pointer happened to cross the hidden strip (fsHideTimer's
                    // guard kept it alive the rest of the time). Both flags
                    // reset together, which makes "pin -> unfullscreen ->
                    // fullscreen" behave exactly like a fresh session.
                    if (!barRoot.hiddenByFullscreen) {
                        barRoot.fsPinned = false;
                        barRoot.clearFullscreenHover();
                        barRoot.fsShow = false;
                        // Nothing to veto now that the bar is not being held
                        // out of the way.
                        barRoot.fsPrewasInBar = false;
                        // And the edge press is spent: a fullscreen session
                        // ending must not leave the bar held open by a press
                        // that belonged to the session before it.
                        barRoot.clearEdgePress();
                        return;
                    }
                    // ── Rising edge: the bar leaves NOW ─────────────────────
                    // The 2s hold is for a pointer that REACHES for a bar
                    // which is already hidden. A pointer that was already
                    // resting on the bar when the app went fullscreen has
                    // expressed no intent, and letting it spend the hold is how
                    // "the bar covers my fullscreen app for two seconds, then
                    // goes" happens: SUPER+F is pressed from the keyboard while
                    // the cursor is wherever it was left, which is very often
                    // the bar.
                    //
                    // Latched on the rising edge only, and paired with the
                    // geometric test rather than a hover event, so the bar
                    // leaves on the same frame the app does. See
                    // `fsPrewasInBar`.
                    barRoot.fsPrewasInBar = barRoot.pointerInBar;
                    // Drop any countdown inherited from before, so the veto is
                    // the only thing in force rather than the veto plus a
                    // half-spent hold.
                    barRoot.fsHoverSince = -1;
                }
                // ═══ The fullscreen enforcer (requested 2026-10-02) ══════════
                //
                // A SAFETY NET over `hiddenByFullscreen`, not a replacement for
                // it. The bar is sometimes left sitting permanently over a
                // fullscreen app, and the predicate above -- even with
                // HyprlandData as its authority -- is not reliable enough to
                // be the only thing standing between a fullscreen app and a bar
                // that never gets out of the way.
                //
                // So: a 2s timer that checks the same condition and, when it
                // holds, forces the bar down regardless of anything else holding
                // it open. The pointer is the one thing it yields to, because
                // "while the mouse is not hovering the top bar" is the whole
                // condition -- if the pointer is on the bar, the bar is wanted.
                //
                // WHY 2s AND NOT A BINDING. Every reactive route to this has
                // already been tried and is what produced the bug being fixed:
                // the failure mode is precisely that some event is missed, so
                // the state never updates. A timer cannot miss a state, only be
                // late to notice it, and 2s is far below the point where a bar
                // left up over a fullscreen app reads as broken.
                // `forcedHidden` and the old 2s `fullscreenEnforcer` are GONE.
                //
                // They were a second, parallel mechanism for the same decision,
                // and having two is why the bar's timing was unpredictable: the
                // enforcer ran on its own 2s clock and set a flag that
                // `hideBySlide` OR'd in, so under fullscreen the bar could be
                // held by EITHER the hold rule or the 2s flag, and the earlier
                // one won often enough to look like a random delay. One rule,
                // one clock, one place that decides -- `fsBarAllowedOpen`.

                // FULLSCREEN IS ABSOLUTE, with one narrow exception:
                // `fsBarAllowedOpen` -- the pointer is on the bar AND its
                // 2s has not run out. See the rule at fsOpenHoldMs.
                //
                // This used to read `... && !mustShow`, which meant fullscreen
                // only hid the bar while nothing wanted it visible. Every hold
                // (`fsShow`, `fsPinned`, `superShow`) was meant to be temporary
                // but was cleared by an EVENT, so a missed event left the bar
                // over the fullscreen app for good. A duration cannot be missed.
                readonly property bool hideBySlide: (barRoot.hiddenByFullscreen && !barRoot.fsBarAllowedOpen)
                    || (Config?.options.bar.autoHide.enable && !mustShow)
                // ── The slide itself ────────────────────────────────────────
                // How far the bar has travelled out of view, in logical px.
                //
                // This used to be an `anchors.topMargin` fed by a `Behavior on
                // anchors.topMargin`. That reads correctly but Qt never runs it:
                // anchor-margin writes are applied as raw geometry, so the bar
                // *snapped* the instant a fullscreen window appeared -- verified
                // frame-by-frame (hidden -> fully gone, zero intermediate
                // frames). The offset is a plain number instead, so the Behavior
                // below actually drives it, and the painting rides the result.
                //
                // The exit/enter pair is the shell's own asymmetric language
                // (the same one the sidebars and the edge hints use): a quick
                // accelerating whip out, a slower decelerating settle back in.
                readonly property real slideDistance: Appearance.sizes.barHeight
                // Deliberately NOT a binding: the animation below owns this
                // value (a Behavior cannot write to a bound property), and the
                // starting value is set in Component.onCompleted.
                // The drop's settled geometry, captured ONCE per pull, a beat
                // after the card has finished settling. The input mask reads
                // only these, so a card costs two region changes (open, close)
                // instead of one per animation frame -- a Region change is a
                // layer-surface commit, and committing it ~60 times a second
                // is what made the whole bar flicker.
                //
                // The capture is DELAYED on purpose. Capturing the moment the
                // pull passes halfway latched the half-settled size, so a
                // card wider than the one before it presented an input region
                // that did not cover it: the pointer could not travel into the
                // card, the card closed under the pointer, and the bar looked
                // like it refused to extend. Waiting for the spring to settle
                // means the region is right for the card that is actually
                // sitting there.
                property real latchedDropX: LiquidBar.dropX
                property real latchedDropW: LiquidBar.dropWidth
                property real latchedDropH: LiquidBar.dropHeight
                property bool latchPending: false
                function captureDropGeometry() {
                    latchedDropX = LiquidBar.dropX;
                    latchedDropW = LiquidBar.dropWidth;
                    latchedDropH = LiquidBar.dropHeight;
                }
                Timer {
                    id: dropLatchTimer
                    interval: 140
                    onTriggered: {
                        if (!barRoot.latchPending)
                            return;
                        barRoot.latchPending = false;
                        barRoot.captureDropGeometry();
                    }
                }
                Connections {
                    target: LiquidBar
                    function onTChanged() {
                        if (LiquidBar.t <= 0.001) {
                            // Closed: this is the geometry to reuse next time.
                            dropLatchTimer.stop();
                            barRoot.latchPending = false;
                            barRoot.captureDropGeometry();
                        } else if (!barRoot.latchPending) {
                            barRoot.latchPending = true;
                            dropLatchTimer.restart();
                        }
                    }
                }

                property real slideShift: 0
                // Animated imperatively rather than with a Behavior, because Qt
                // refuses to *change* a Behavior's animation at runtime --
                // "Cannot change the animation assigned to a Behavior": it warns
                // and silently keeps the first one, so a `hideBySlide ? exit :
                // enter` binding can only ever produce a single curve for BOTH
                // directions. Picking the pair here is what actually preserves
                // the asymmetry. `from` is left unset so the animation always
                // starts from wherever the bar is -- a quick fullscreen on/off
                // reverses mid-flight instead of jumping.
                NumberAnimation {
                    id: slideAnim
                    target: barRoot
                    property: "slideShift"
                    alwaysRunToEnd: false
                }
                onHideBySlideChanged: {
                    // ── A WORKSPACE SWITCH IS NOT A SLIDE ──────────────────
                    //
                    // "No animations when switching desktops; only when an app
                    // goes fullscreen." On a switch the bar's destination is
                    // already known (the remembered per-desktop state above),
                    // so the slide has nothing to say -- it only draws the
                    // dropdown on every desktop change.
                    //
                    // (This paragraph used to explain why a switch had to skip
                    // the strip gate as well as the slide: the gate zeroed the
                    // exclusive zone for the slide's duration, so the arriving
                    // desktop's window was laid out against a workarea with no
                    // top band and then squeezed back when the zone returned.
                    // Nothing zeroes the zone for a slide any more -- see
                    // `exclusiveZone` below -- so snapping the position is the
                    // whole of what is left to do here.)
                    //
                    // Snapped, not animated. The bar is already at one extreme
                    // or the other for the whole of a switch, so there is
                    // nothing in between to render.
                    if (barRoot.wsSwitching) {
                        slideAnim.stop();
                        barRoot.slideShift = barRoot.hideBySlide
                            ? barRoot.slideDistance
                            : 0;
                        return;
                    }
                    const spec = barRoot.hideBySlide
                        ? Appearance.animation.elementMoveExit
                        : Appearance.animation.elementMoveEnter;
                    slideAnim.stop();
                    slideAnim.duration = spec.duration;
                    slideAnim.easing.type = spec.type;
                    slideAnim.easing.bezierCurve = spec.bezierCurve;
                    slideAnim.to = barRoot.hideBySlide ? barRoot.slideDistance : 0;
                    slideAnim.start();
                    // (Nothing is withheld from the compositor here any more.
                    // This used to arm `stripPending` -- withholding the strip
                    // while the bar slid back in, and only for the cover
                    // request, so the tiler did not re-lay a window out from
                    // under a bar still on its way down. The strip no longer
                    // moves for a cover at all (see `exclusiveZone` below), so
                    // there is nothing to withhold, and its own side effect is
                    // gone with it: the strip coming back is what re-tiled
                    // every window 45px down.)
                }
                // ── The slide must FINISH ────────────────────────────────────
                //
                // The reported symptom: open an app, and the bar is left a few
                // pixels proud of the screen edge instead of gone -- a sliver
                // along the top that neither slides away nor comes back on
                // its own.
                //
                // `onHideBySlideChanged` is the only thing that drives
                // `slideShift`, and it fires on a CHANGE. So the value is
                // correct whenever that handler ran last, and wrong whenever
                // something moved the goalposts under a slide already in
                // flight -- which is exactly what launching an app does: the
                // window list changes, `fullscreenOnMonitor` and `coverAlive`
                // are re-evaluated, and `hideBySlide` can be recomputed around
                // the animation rather than after it. The animation restarts
                // from wherever it had got to, and if it is then re-aimed at a
                // `slideDistance` that no longer matches, it settles short.
                // Nothing ever goes back and finishes the job, because the
                // state it is stuck in is not a state any handler is watching.
                //
                // So the end of the slide is watched directly, and it is the
                // same self-arming repeating check `fsHideTimer` already uses
                // for the same class of problem: a one-shot cannot come back
                // for a state it did not observe, but a repeating tick can.
                //
                // Guarded on `!slideAnim.running`, so it never fights a slide
                // that is doing its job -- it only ever acts once nothing is
                // animating and the bar is nevertheless short of where it
                // should be. Both directions, because the mirror image (a bar
                // left partly out when it should be fully in) has the same
                // cause and the same cure.
                Timer {
                    id: slideSettle
                    interval: 120
                    repeat: true
                    running: !slideAnim.running
                        && (barRoot.hideBySlide
                            ? barRoot.slideShift < barRoot.slideDistance - 0.5
                            : barRoot.slideShift > 0.5)
                    onTriggered: {
                        barRoot.slideShift = barRoot.hideBySlide
                            ? barRoot.slideDistance
                            : 0;
                    }
                }

                // The cursor probe, and the one clock it drives.
                //
                // There is NO provisional grace any more, and that is the
                // shape the behaviour was asked for: below the bar means gone,
                // immediately. So the hold is not started on a short clock
                // that a probe may upgrade -- it is started only by a probe
                // that positively finds the cursor inside the empty space,
                // and any probe that does not clears it at once. The cost is
                // the fork's own latency (~10-20ms for a socket call), which
                // is what stands between "instant" and "instant"; the slide
                // it interrupts is far longer, and `slideAnim` reverses
                // mid-flight rather than jumping, so it is not visible.
                Process {
                    id: gapCursorProbe
                    running: false
                    command: ["bash", "-c", "hyprctl cursorpos -j"]
                    stdout: StdioCollector {
                        onStreamFinished: {
                            try {
                                const p = JSON.parse(text.trim());
                                barRoot.probeX = p.x;
                                barRoot.probeY = p.y;
                            } catch (error) {
                                return;
                            }
                            if (!barRoot.probeInGap) {
                                // Out of the empty space: below the bar, or
                                // back over something. Either way the bar goes
                                // now -- and going now is the whole behaviour
                                // when the cursor is not in the spacing.
                                barRoot.gapHolding = false;
                                barRoot.gapSpent = false;
                                gapHold.stop();
                                // ...and the REVEAL goes with it, when the
                                // cursor is genuinely below the strip.
                                //
                                // `fsShow` had exactly one clearer, `fsHideTimer`,
                                // and that is gated on `!hoverRegion.containsMouse`
                                // -- which under a fullscreen window is not an
                                // observation but an absence of one. A cursor
                                // resting in a cut-out gap is already outside the
                                // bar's input region, so leaving it for the app
                                // below produces NO change event: there is no
                                // "left" to report, because the bar never had
                                // it. The press the user made on the app is
                                // likewise never delivered here -- that is what
                                // `gapPassthrough` means.
                                //
                                // So the press that is supposed to dismiss the
                                // bar arrives as silence, and the bar sits there
                                // over the fullscreen app with nothing holding
                                // it but a flag nobody can clear from that
                                // direction. This probe is already running in
                                // exactly this state (see gapPoll) and already
                                // knows the answer: the cursor is not in the
                                // gap. Trusting it is what makes "click the app,
                                // the bar goes" true.
                                //
                                // Not while PINNED: the pin is a deliberate
                                // "keep this down", and no cursor position
                                // overrides it.
                                if (!barRoot.fsPinned
                                    && barRoot.probeY > Appearance.sizes.barHeight + 2) {
                                    barRoot.fsShow = false;
                                    fsHideTimer.stop();
                                }
                                return;
                            }
                            // In the spacing. Arm the ONE window -- and the
                            // one-shot latch is what makes it one window.
                            //
                            // Guarding on `gapHolding` alone looks right and
                            // is not: the poll keeps running while the bar is
                            // up, so the instant the window expired the very
                            // next probe found the cursor still in the gap and
                            // started a fresh one. While a cursor rested in the
                            // spacing that re-armed forever, and after a swipe
                            // -- whose `swipeLive` hold is what kept the bar up
                            // past the first expiry -- the bar simply never
                            // came back. `gapSpent` is the difference between
                            // "a window is open" and "this visit has had its
                            // window", and only the cursor actually LEAVING
                            // the gap clears it.
                            if (barRoot.swipeLive || barRoot.postSwipe) {
                                // The gesture owns the bar right now, tail
                                // included. Arming a second window here is
                                // what added the two halves together and made
                                // "gone 700ms after I let go" into "gone
                                // somewhere north of a second".
                                barRoot.gapSpent = true;
                                return;
                            }
                            if (!barRoot.gapSpent) {
                                barRoot.gapSpent = true;
                                barRoot.gapHolding = true;
                                gapHold.restart();
                            }
                        }
                    }
                }// Only runs while the bar is up without the pointer on it:
                    // that is the gap window plus the fork latency either side of
                    // it, and nothing at all when the bar is idle.
                    Timer {
                        id: gapPoll
                        interval: 90
                        repeat: true
                        // The fullscreen clause is the fix, and it is the whole
                        // "press the app and the bar stays" report.
                        //
                        // `hoverReveals` is `fsShow || fsPinned` under a
                        // fullscreen window -- so while the bar is DOWN over one,
                        // `!hoverReveals` is false and this poll was switched
                        // OFF. The probe whose entire job is to notice that the
                        // cursor has left the bar was disabled for precisely the
                        // state in which the bar needs to be told the cursor has
                        // left. Nothing else watches: `hoverRegion` cannot
                        // report it, because under a fullscreen window the
                        // cursor reaching the app passes straight through the
                        // bar's cut-out gaps and out of its input region
                        // without the bar ever seeing a pointer event.
                        //
                        // So it runs anyway. The cost is one `hyprctl cursorpos`
                        // every 90ms while the bar is up over a fullscreen
                        // window, and only then; on an ordinary desktop the
                        // original condition still applies and the poll is idle
                        // whenever the pointer is on the bar.
                        running: barRoot.mustShow
                            && (!barRoot.hoverReveals || barRoot.hiddenByFullscreen)
                        onTriggered: gapCursorProbe.running = true
                    }
                // The window itself. On expiry the bar closes unless a swipe
                // has taken over in the meantime, which `holdingForPointer`
                // covers independently of this timer.
                Timer {
                    id: gapHold
                    interval: barRoot.gapHoldMs
                    repeat: false
                    onTriggered: barRoot.gapHolding = false
                }
                // The swipe's tail. Same clock as the gap window on purpose:
                // one number, so "how long does the bar stay after you stop
                // touching it" has one answer rather than two that drift.
                Timer {
                    id: postSwipeTimer
                    interval: barRoot.gapHoldMs
                    repeat: false
                    onTriggered: barRoot.postSwipe = false
                }
                Timer {
                    id: fsHideTimer
                    // Repeating, and self-arming, rather than a one-shot the
                    // pointer's departure starts.
                    //
                    // This was the "bar is open over a fullscreen window and
                    // nothing is holding it" case, and it was the guard below
                    // that caused it. The timer fired 300ms after the pointer
                    // left the bar, found `gapHolding` true -- a gap window
                    // opened by a cursor resting in the empty space, or by the
                    // tail of a swipe -- declined to clear `fsShow`, and then
                    // never ran again: the only thing that used to restart it
                    // was the pointer crossing the bar, which under a
                    // fullscreen window it may well never do. So `fsShow`
                    // stayed true with nothing behind it, and `mustShow` kept
                    // the bar down over the fullscreen app indefinitely,
                    // pointer nowhere near it.
                    //
                    // A repeating check cannot get stuck in that state: the
                    // moment the gap window closes, the next tick clears it.
                    interval: 200
                    repeat: true
                    running: barRoot.hiddenByFullscreen && barRoot.fsShow
                        && !barRoot.pointerInBar && !barRoot.fsPinned
                    onTriggered: {
                        // `gapHolding` still holds the reveal off, but only
                        // for as long as the window is actually open: this
                        // timer is what comes back for it afterwards.
                        if (!barRoot.pointerInBar && !barRoot.fsPinned
                            && !barRoot.gapHolding)
                            barRoot.fsShow = false;
                    }
                }
                // ── The press is spent when the pointer leaves ────────────────
                //
                // The fullscreen half of this is `fsHideTimer` above, which
                // clears `fsShow` once the pointer is off the bar. The
                // non-fullscreen half is `edgePressOpened`, and it needs the
                // same treatment or the bar latches: one press on the top edge
                // would set a flag that nothing ever cleared, so the bar came
                // back on every subsequent hover and never went away again.
                //
                // A repeating check, for the same reason `fsHideTimer` is one:
                // it cannot be stranded by a missed event. It only runs while
                // the press is actually outstanding, so an idle bar costs
                // nothing.
                Timer {
                    id: edgePressHold
                    interval: 200
                    repeat: true
                    running: barRoot.edgePressOpened
                        && !barRoot.pointerInBar
                        && !barRoot.superShow
                    onTriggered: {
                        if (!barRoot.pointerInBar && !barRoot.superShow)
                            barRoot.clearEdgePress();
                    }
                }
                // The dwell: the edge only counts once the pointer has stopped
                // there. Cancelled the moment it moves off the border.
                //
                // HOVER IS NOT ENOUGH ANY MORE, IN EITHER CONTEXT. The sidebars
                // already made this call (see EdgeReveal.qml), and the reason is
                // the same one that applies to the top edge: a pointer
                // travelling to the top of the screen crosses that border
                // constantly, and every crossing used to summon a bar that then
                // had to be dismissed again. The bar and the sidebars moving on
                // different rules is worse than either rule alone -- the
                // same gesture at the left edge and the top edge did different
                // things.
                //
                // So under fullscreen the bar is summoned by a PRESS on the
                // edge strip, and by nothing else.
                //
                // The dwell used to summon it in the non-fullscreen case too,
                // which is the hover-alone behaviour this no longer has: the
                // top edge now matches the sidebar edges exactly (hover arms,
                // press opens). So the timer no longer OPENS anything -- it is
                // kept solely as the hover-intent delay, the same role
                // `openDelay` plays in EdgeReveal.qml, and `fsEdgeArmed` is
                // what the hint reads to know the edge is live.
                //
                // Deliberately empty of side effects. Deleting it outright would
                // also be correct, but the delay is what stops the hint
                // flickering on a pointer that merely grazes the border, and
                // that is worth keeping in one place.
                Timer {
                    id: fsRevealTimer
                    interval: barRoot.fsRevealDelay
                    repeat: false
                    onTriggered: {
                        // Intentionally does not open the bar. The press is
                        // the only opener; see the note above.
                    }
                }
                // A press on the edge summons the bar under fullscreen. This is
                // the top-edge twin of EdgeReveal's side strips, and it is the
                // ONLY thing that opens it there.
                //
                // It rides on the existing hoverRegion rather than a new
                // MouseArea so it cannot compete with the strip's own input:
                // the strip is already the whole window's input region, and
                // `hiddenStripHeight` keeps it mapped and whole-width while
                // the bar is out (see gapPassthrough), which is what makes a
                // press on it land here at all.
                MouseArea {
                    id: fsEdgePress
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: barRoot.hiddenStripHeight
                    z: 200
                    // Above the islands, but ONLY while the bar is out: with
                    // the bar down this strip sits over the bar's own content
                    // and would eat the first click on every widget.
                    //
                    // Both contexts, not just fullscreen. This is the top-edge
                    // twin of EdgeReveal's side strips, and those work in both
                    // too -- the top edge now opens on hover AND press for the
                    // same reason and in the same way.
                    visible: barRoot.hideBySlide
                    acceptedButtons: Qt.LeftButton
                    onClicked: mouse => {
                        if (!barRoot.fsEdgeArmed)
                            return;  // not actually resting on the border
                        if (GlobalStates.screenLocked)
                            return;
                        if (barRoot.hiddenByFullscreen) {
                            if (barRoot.fsBarAllowedOpen)
                                return;  // already open; a press does not toggle
                        } else if (barRoot.edgePressOpened) {
                            return;  // already open; a press does not toggle
                        }
                        barRoot.requestEdgePressReveal();
                        mouse.accepted = true;
                    }
                }
                // A LEFT CLICK ON THE FULLSCREEN APP PUTS THE BAR AWAY.
                //
                // This is the requested behaviour and it is deliberately blunt:
                // whatever summoned the bar -- an edge press, a SUPER tap, a
                // pin -- clicking the app underneath ends it. The reveal is a
                // convenience for reading the clock; the app is what the user
                // is actually looking at, and a click on it is an unambiguous
                // "I want the app, not the bar".
                //
                // It covers the whole strip the bar occupies rather than only
                // the cut-out gaps, because the whole reason this is needed is
                // that a click in a GAP is passed through by `gapPassthrough`
                // and never reaches the bar at all -- the bar cannot hear the
                // click that dismisses it. It is active ONLY while the bar is
                // slid out over a fullscreen window (`hideBySlide` is true only
                // then under fullscreen, since it is now unconditional there),
                // so it never intercepts a click meant for a bar widget on an
                // ordinary desktop, and it never covers the app when the bar is
                // not in the way.
                //
                // `acceptedButtons` is Left only, and the press is not marked
                // accepted: the click still belongs to the application, which is
                // the point -- the bar goes away AND the click lands.
                MouseArea {
                    id: fsDismissOnClick
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    // Tall enough to cover the revealed bar, plus the pocket it
                    // can hang into, so a click anywhere on the thing the user
                    // can see is a click on the bar as far as they are
                    // concerned.
                    height: barRoot.hideBySlide ? barRoot.height : 0
                    z: 199
                    visible: barRoot.hiddenByFullscreen && barRoot.hideBySlide
                    acceptedButtons: Qt.LeftButton
                    // Hovering is deliberately NOT enabled: this area exists to
                    // hear a click, and enabling hover would make the pointer
                    // appear to be "on the bar" over the whole strip, which is
                    // the exact confusion `pointerInBar` above exists to avoid.
                    hoverEnabled: false
                    onClicked: mouse => {
                        if (!barRoot.hiddenByFullscreen)
                            return;
                        barRoot.clearFullscreenReveal();
                        barRoot.fsPinned = false;
                        barRoot.gapHolding = false;
                        barRoot.gapSpent = false;
                        barRoot.postSwipe = false;
                        gapHold.stop();
                        // NOT accepted: the click belongs to the app underneath.
                        // The bar simply stops being in the way.
                    }
                }
                Connections {
                    target: hoverRegion
                    function onContainsMouseChanged() {
                        if (hoverRegion.containsMouse) {
                            // Start (or restart) the bar's 2s: the pointer
                            // is on it, so it is allowed to stay open that long.
                            barRoot.noteFullscreenHover();
                            fsHideTimer.stop();
                            // Only arm the dwell when the bar is NOT being
                            // hidden by a fullscreen window. Under fullscreen
                            // the press above is the gesture, and arming a
                            // 500ms timer that will fire anyway is exactly the
                            // hover-opens behaviour being removed.
                            if (!barRoot.hiddenByFullscreen)
                                fsRevealTimer.restart();
                            // The pointer is back over the bar proper, so
                            // whatever was holding it open for the pointer is
                            // no longer needed.
                            gapHold.stop();
                            barRoot.gapHolding = false;
                            barRoot.gapSpent = false;
                        } else {
                            fsRevealTimer.stop();
                            // The pointer has left the bar, so the swipe's
                            // tail is over immediately rather than waiting
                            // out its clock: there is nothing left to read
                            // up there. No probe, no grace -- this is the
                            // "retract at once when the mouse moves away"
                            // half of the rule.
                            postSwipeTimer.stop();
                            barRoot.postSwipe = false;
                            if (barRoot.fsShow)
                                fsHideTimer.restart();
                            // Losing the hover is ambiguous: the pointer may
                            // have dropped below the bar, or it may have moved
                            // sideways into a gap that was cut out from under
                            // it. Nothing is held on a guess -- ask now, at
                            // once, and let the answer decide.
                            barRoot.gapHolding = false;
                            gapCursorProbe.running = true;
                        }
                    }
                    function onPositionChanged() {
                        // Still on the border: keep waiting out the dwell. Moved
                        // off it: forget it (unless the bar is already down).
                        //
                        // The fullscreen guard is the other half of removing
                        // hover-to-open: moving ALONG the border must not
                        // re-arm the timer under fullscreen either, or a
                        // pointer sweeping across the top of the screen would
                        // park on the edge for the dwell and drop the bar.
                        if (barRoot.hiddenByFullscreen) {
                            if (!barRoot.fsShow)
                                fsRevealTimer.stop();
                            return;
                        }
                        // Off fullscreen the dwell arms nothing (see
                        // `fsRevealTimer`), so it is only kept running where it
                        // still has meaning: the bar actually being hidden. Arming
                        // it while the bar is plainly on screen would leave a
                        // timer cycling against a gesture that cannot fire.
                        if (barRoot.hideBySlide && barRoot.fsEdgeArmed) {
                            if (!fsRevealTimer.running && !barRoot.fsShow)
                                fsRevealTimer.restart();
                        } else if (!barRoot.fsShow) {
                            fsRevealTimer.stop();
                        }
                    }
                }

                exclusionMode: ExclusionMode.Ignore
                // ── NOTHING here moves the workarea for a window any more ──
                //
                // Two gates used to sit on the `exclusiveZone` below, and both
                // are gone: `stripPending` (the zone held through the bar's
                // slide) and `coverYielding` (the cover's own request, spelled
                // out further down).
                //
                // They existed for covers that MAXIMIZED their way to the top
                // of the screen: a maximized window is laid out inside the
                // workarea, so the strip genuinely had to be released for it.
                // custom/cover.lua floats the window instead now, and a float
                // ignores exclusive zones outright -- measured, handing the
                // zone back WHILE a cover was still up: the covering window did
                // not move a pixel, and every OTHER window moved 45px. So the
                // zone was buying the cover nothing and charging the whole
                // desktop a re-layout of every window, twice.
                //
                // What is left on that line is the one rule that predates all
                // of it: auto-hide yields the zone, nothing else does.
                //
                // The trail, kept because it is why the zone moved at all. This
                // was once a straight `hiddenByFullscreen ? 0 : 45`, and that is
                // the "the whole desktop app shifts for a second" report. The
                // two halves of "leaving fullscreen" run on different clocks:
                // the bar SLIDES back in over `elementMoveEnter`, and the
                // workarea changed the INSTANT `hiddenByFullscreen` went false.
                // Measured on this machine, sampling every 100ms while a cover
                // was released:
                //
                //   ms  reserved        window at/size
                //    20 [0, 45, 0, 0]  [-1, -1]/[1600, 1000]  f=1
                //  1044 [0, 45, 0, 0]  [-1, -1]/[1600, 1000]  f=1
                //  1852 [0, 45, 0, 0]  [803, 51]/[791, 943]  f=0
                //
                // So the strip was re-reserved while the bar was still off the
                // top of the screen, and the tiler re-laid the window out from a
                // full-monitor float to its tile UNDERNEATH it: the app jumps up
                // under a bar that is still descending. Holding the strip until
                // the slide finished inverted that order, and was right while
                // the zone still moved. With the cover no longer moving it, the
                // hold has nothing left to hold -- and its own cost was the
                // other half of the same report: the strip coming back is what
                // re-tiled every window 45px down again.
                // ── Why real fullscreen does NOT give the strip up ──────────────
                //
                // Measured on leaving real fullscreen, sampling `hyprctl
                // monitors` and the window together:
                //
                //    ms  reserved      window at/size
                //     5  [0, 88, 0, 0]  [0, 0] 2560x1600  fs=2
                //   426  [0, 88, 0, 0]  [6, 94] 1269x1500  fs=0
                //   864  [0, 88, 0, 0]  [6, 94] 1269x1500  fs=0
                //  1010  [0, 133, 0, 0] [6, 139] 1269x1455 fs=0
                //
                // Two things fall out of that, and neither is what this file
                // assumed for weeks.
                //
                // ONE: `reserved` is [0, 88, 0, 0] under a fullscreen window,
                // NOT [0, 0, 0, 0]. Something else on this desktop holds 88px
                // (133 - 45), so the strip going 45 -> 0 changes reserved only
                // between 133 and 88, never to nothing. The window therefore
                // re-tiles at y=94 and then has to be moved a SECOND time to
                // y=139 when the strip comes back. That second 45px move, one
                // second after the bar has already landed, is the reported
                // "the whole window shifts for about a second".
                //
                // TWO: a real fullscreen window does not care about the band
                // at all. It is at [0, 0] sized to the whole monitor WHILE
                // reserved is 88 -- it already covers the strip. So yielding
                // the exclusive zone for real fullscreen buys nothing
                // visible, and its only effect is to change the tiler's
                // reflow arithmetic. Which is the shift.
                //
                // AND THE COVER DOES NOT EITHER -- the case those measurements
                // were one step short of. The cover request was the last thing
                // here that moved the zone (`coverYielding`, plus `stripPending`
                // holding it through the slide), and it was written for a cover
                // that MAXIMIZED its way to the top edge. custom/cover.lua
                // floats instead, and a float ignores exclusive zones outright.
                // Measured on this machine, covering a window and then handing
                // the strip back WHILE it stayed covered:
                //
                //   cover win: [0, 0] 1707x1067 flt=True      reserved=0
                //   qs -c ii ipc call barCover onCover false <addr>
                //   cover win: [0, 0] 1707x1067 flt=True      reserved=45
                //   other windows: [6, 6] -> [6, 51]
                //
                // The covering window did not move a pixel when the strip came
                // back; every other window moved 45px when it went away. That
                // is the whole cost of the yield: dropping the zone re-tiles
                // EVERY window on the monitor 45px up (animated by
                // `windowsMove`), and giving it back re-tiles them all down
                // again -- four clients repainting twice, which is the
                // "resizing and everything feels laggy" report. Out of a
                // cover, it is also the second 45px move: the window re-tiles
                // into a strip-less tile first and is then pushed down into
                // the real one, "the whole window shifts for about a second".
                //
                // With the zone left where it is, the covering window is the
                // only thing that moves, in one step, in each direction.
                //
                // The cover still hides the bar: `hiddenByFullscreen` reads the
                // flag and the geometry, and never the zone.
                // ── Bar-visibility publisher (the gesture handshake) ───────
                // A SECOND file, deliberately, not another field in
                // ii-nowbar-hover.json: that one is written by the island
                // (NowBar.qml) and this is written here, and two writers
                // rewriting one file would race -- the loser's field would be
                // replaced wholesale by a `printf` that knows nothing about
                // it. The wallpaper stage already runs its own keepalive file
                // for the same reason.
                //
                // WHY IT EXISTS (requested 2026-10-03): the bar's swipe-down
                // gestures were gated on the CURSOR hovering the island, which
                // is the wrong instrument for a touchpad -- you swipe with your
                // fingers and the mouse never moves, so the gate was false and
                // the two-finger swipe did nothing at all. What the compositor
                // actually needs to know is "is the bar on screen", because a
                // touchpad swipe has no position: it cannot mean "over the bar"
                // in the way a click can. So the rule is positional in the only
                // sense that is true for a gesture -- while the bar is up, the
                // bar's gestures are live; when it is hidden they are not.
                //
                //   $XDG_RUNTIME_DIR/ii-bar-visible.json
                //   {"visible":true,"stripH":50,"midL":669,"midR":1039,"ts":...}
                //
                // The bar's own geometry, published so the compositor can
                // answer "is the pointer on the MIDDLE bar" WITHOUT asking the
                // shell whether it saw a hover. Those are two different
                // questions and only one of them works: the island's
                // `islandHovered` rides on layer-shell hover delivery, which
                // is exactly the thing that goes missing when a fullscreen
                // window is up, when a gap is cut out of the input region, or
                // when the pointer is warped rather than walked -- and a
                // gesture gate that quietly reads `false` is worse than no
                // gate at all. Geometry plus hl.get_cursor_pos() is a
                // straight arithmetic answer with no event in the middle.
                //
                // stripH is the bar's PAINTED height, not the window's: the
                // window is 190px deep so the liquid pocket has somewhere to
                // drop, and a pointer in that empty pocket is over the
                // WINDOW and not over the BAR.
                // midL/midR are the middle island's screen-x run, live from
                // BarContent, so this cannot drift from where the bar
                // actually is.
                //
                // Written on change and refreshed every 2s while visible; the
                // reader treats it as stale after 10s, so a crashed or wedged
                // shell can never leave a dead "visible" pinning the gestures on
                // with no bar to aim at.
                readonly property string visibleFilePath:
                    `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/ii-bar-visible.json`
                property real visibleTs: 0
                readonly property bool barOnScreen: !barRoot.hideBySlide
                Process {
                    id: visibleWriter
                    command: ["sh", "-c",
                        `printf '{"visible":${barRoot.barOnScreen},"stripH":${barContent.implicitHeight},"midL":${barContent.centerIslandLeft},"midR":${barContent.centerIslandRight},"ts":${barRoot.visibleTs}}' > '${barRoot.visibleFilePath}'`]
                }
                function publishVisibility() {
                    barRoot.visibleTs = Date.now() / 1000;
                    visibleWriter.running = false;
                    visibleWriter.running = true;
                }
                // No Component.onCompleted here: this component already has
                // one (see "Include in focus grab" below) and QML takes only
                // one. The initial publish rides along in that handler.
                onBarOnScreenChanged: publishVisibility()
                Timer {
                    // The keepalive: while the bar is on screen, keep the geometry
                    // file fresher than the reader's 10s staleness window, so a
                    // crashed or wedged shell can never leave a dead "visible" pinning
                    // the gestures on with no bar to aim at. Mirrors NowBar.qml's
                    // hover keepalive.
                    interval: 2000
                    repeat: true
                    running: barRoot.barOnScreen
                    onTriggered: publishVisibility()
                }

                exclusiveZone: (Config?.options.bar.autoHide.enable && (!mustShow || !Config?.options.bar.autoHide.pushWindows)) ? 0 :
                    Appearance.sizes.baseBarHeight + (Config.options.bar.cornerStyle === 1 ? Appearance.sizes.hyprlandGapsOut : 0)
                // Overlay, not top: a fullscreen client renders above every
                // Top-layer surface. That was the real reason clicks on the bar
                // did nothing -- with a fullscreen window on the active
                // workspace (which is most of the time on this machine) the bar
                // sat underneath it and never received the press. Overlay keeps
                // the bar, its edge-reveal strip and its popup apps above
                // fullscreen clients.
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "quickshell:bar"
                // Liquid bar: the window is a FIXED size -- tall enough for
                // the tallest possible pocket plus headroom -- and never
                // resizes. Two earlier bindings made it grow with the pull:
                // t × dropHeight, then the content-driven dropHeight that
                // publishDropGeometry() writes back. Either way the layer
                // surface re-rasterized on every spring tick, which wiggled
                // the bar and blurred it for the duration of the pull. With a
                // constant size the pocket motion is pure QML painting inside
                // a stable surface; the input mask below keeps the unused
                // lower band click-through, and LiquidBar.dropHeight keeps
                // carrying the ACTUAL drop depth for the mask and the skin.
                readonly property int pocketCeiling: 130
                implicitHeight: Appearance.sizes.barHeight + Appearance.rounding.screenRounding
                    + pocketCeiling
                // Interactive only where the bar actually is: the bar strip, or
                // the thin band at the screen edge while the bar is slid out
                // (auto-hide, or hidden behind a fullscreen window). Without a
                // mask the whole 65px window swallows clicks meant for the
                // window underneath -- and in fullscreen it would eat the top
                // 65px of the application.
                //
                // The geometry is spelled out rather than `Region { item: ... }`:
                // the item-based form depends on that Item's resolved geometry,
                // and an Item that has not been laid out yields an empty input
                // region -- a bar that is visible but deaf to every click, which
                // is exactly the bug this replaces.
                mask: Region {
                    id: barMask
                    // Tall enough to include the top of the round decorators, and
                    // only a sliver while hidden so the strip is still hittable.
                    readonly property int maskHeight: barRoot.hideBySlide ? barRoot.hiddenStripHeight
                        : Appearance.sizes.barHeight + 4
                    // The droplet's own footprint, unioned in below. The pulled
                    // band is NOT input away from the drop: since the liquid
                    // bar only hangs a small curved section, making the whole
                    // extended band swallow clicks would eat presses meant for
                    // whatever is behind the bar.
                    // Its top edge is the bar's painted bottom edge -- the same
                    // line the droplet is drawn from (see BarContent).
                    readonly property int barBottom: Appearance.sizes.barHeight
                        - (Config.options.bar.cornerStyle === 1 ? Appearance.sizes.hyprlandGapsOut : 0)
                    // The drop's depth is measured from the bar's painted bottom
                    // edge (barBottom) and is exactly the pull: the content is
                    // anchored the same way, so the input region and the drawn
                    // silhouette end on the same line.
                    // TWO states, not a per-frame follow.
                    //
                    // An input region is part of the layer surface: every
                    // change to it is a commit to the compositor, and the
                    // compositor redraws that layer when it commits. Tracking
                    // the pull frame by frame therefore committed ~60 times a
                    // second for as long as a pocket was open -- every time
                    // the pointer crossed a bar icon -- and the symptom was
                    // the whole bar flickering, not the drop misbehaving.
                    //
                    // The region only has to be RIGHT while the drop is
                    // usable, so it is open once the pull is past halfway and
                    // shut the moment it closes. Nothing can be clicked in the
                    // first half of the pull (it is still on its way out from
                    // under the bar) or in the closing half.
                    // Interactive from the moment the card is out (the latch
                    // already holds its settled size), so moving the pointer
                    // off the icon and onto the card is one continuous hover.
                    readonly property bool dropInteractive: LiquidBar.t > 0.02
                    readonly property int dropDepth: dropInteractive ? latchedDropH : 0
                    // Latched, not live. LiquidBar.dropWidth/dropCenter are
                    // published every frame the drop is settling (the skin and
                    // the content both animate their size), and a Region that
                    // follows them is a layer-surface commit every frame --
                    // which is what made the WHOLE bar flicker, not the drop
                    // look wrong. The region is captured once while the pull is
                    // closed and reused for the whole of the next open, so the
                    // pointer lands on the card that is on screen.
                    readonly property int dropW: Math.max(latchedDropW, 170)
                    x: 0
                    // A bottom bar lives at the bottom of its window.
                    y: Config.options.bar.bottom ? barRoot.height - maskHeight : 0
                    width: barRoot.width
                    height: maskHeight

                    // ── The gaps, subtracted ─────────────────────────────────
                    // The strip above is the whole width of the screen; these
                    // four children cut the SPACING out of it, so what is
                    // left is the islands and nothing else. Each pair is one
                    // run of bar x measured on barRoot (gap0From/gap0To, and
                    // so on).
                    //
                    // The strip is full width on every other state: with the
                    // pass-through off each slot is zero-wide, and a slot that
                    // measures zero cuts nothing.
                    component GapCut: Region {
                        required property real from
                        required property real to
                        required property bool cut
                        x: cut ? from : 0
                        width: cut ? Math.max(0, to - from) : 0
                        y: 0
                        height: barMask.height
                        // Subtracted, not combined: these are holes in the
                        // strip, which is the one operation a union cannot do.
                        intersection: Intersection.Subtract
                    }
                    GapCut {
                        from: barRoot.gap0From; to: barRoot.gap0To
                        cut: barRoot.gapPassthrough
                    }
                    GapCut {
                        from: barRoot.gap1From; to: barRoot.gap1To
                        cut: barRoot.gapPassthrough
                    }
                    GapCut {
                        from: barRoot.gap2From; to: barRoot.gap2To
                        cut: barRoot.gapPassthrough
                    }
                    GapCut {
                        from: barRoot.gap3From; to: barRoot.gap3To
                        cut: barRoot.gapPassthrough
                    }

                    Region {
                        // Child regions are combined (unioned) by default.
                        width: barMask.dropW
                        height: barMask.dropDepth + 2
                        x: barRoot.latchedDropX - barMask.dropW / 2
                        y: Config.options.bar.bottom
                            ? barRoot.height - barMask.barBottom - barMask.dropDepth
                            : barMask.barBottom
                    }
                }
                color: "transparent"

                // Positioning
                anchors {
                    top: !Config.options.bar.bottom
                    bottom: Config.options.bar.bottom
                    left: true
                    right: true
                }

                margins {
                    right: (Config.options.interactions.deadPixelWorkaround.enable && barRoot.anchors.right) * -1
                    bottom: (Config.options.interactions.deadPixelWorkaround.enable && barRoot.anchors.bottom) * -1
                }

                // Include in focus grab
                Component.onCompleted: {
                    // Publish the handshake file first: the compositor's
                    // two-finger gesture gate reads it, and a first swipe in
                    // the first frames of a shell start must not land in the
                    // "cannot know -> fail closed" window.
                    publishVisibility();
                    GlobalFocusGrab.addPersistent(barRoot);
                    // The window can be mapped already-hidden (the bar opened
                    // while a fullscreen window is up): start at the far end of
                    // the slide rather than dropping into place.
                    barRoot.slideShift = barRoot.hideBySlide ? barRoot.slideDistance : 0;
                }
                Component.onDestruction: {
                    GlobalFocusGrab.removePersistent(barRoot);
                }

                MouseArea  {
                    id: hoverRegion
                    hoverEnabled: true
                    anchors {
                        fill: parent
                        rightMargin: (Config.options.interactions.deadPixelWorkaround.enable && barRoot.anchors.right) * 1
                        bottomMargin: (Config.options.interactions.deadPixelWorkaround.enable && barRoot.anchors.bottom) * 1
                    }

                    // ── The liquid pocket ────────────────────────────────────
                    // The bar's background stretching down under the hovered
                    // widget: the background rect grows by t × pocket height,
                    // and the pocket's own surface fades in inside it. A spring
                    // drives t, so on hover the bar "drops" the content into
                    // view and on release it snaps back with a visible rubber
                    // overshoot. Content is rendered behind the bar content
                    // (declared first), so nothing of the bar itself moves --
                    // the bar's shape is what changes.
                    Item {
                        id: liquidPocket
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: barContent.implicitHeight + Math.max(0, LiquidBar.t) * LiquidBar.dropHeight
                        visible: LiquidBar.t > 0.001

                        // The DROPLET, not a stretched bar: a small curved
                        // section only as wide as the hovered icon's content,
                        // hanging under it like a raindrop that merges back
                        // into the bar with concave fillets on each side.
                        // Painted here (behind BarContent, above the bar
                        // background) from the drop's geometry published by
                        // BarContent when a widget arms the pocket.
                        // The droplet's SKIN is not painted here: it lives in
                        // BarContent, right after the bar's shadow, because the
                        // shadow's blur spills below the bar and would darken
                        // the drop's head -- see the note there.
                        // The pocket's CONTENT lives inside BarContent (it
                        // renders below the bar row, out of its bounds); this
                        // painter only draws the droplet skin behind it.
                    }

                    Item { // proxy so the IPC hook can reach BarContent
                        id: pocketProxy
                        function arm(id: string, centerX: int): void {
                            barContent.armPocket(id, centerX);
                        }
                        Component.onCompleted: {
                            bar.pocketArmer = pocketProxy;
                        }
                    }

                    // The same trick for the input-region diagnostic: it reads
                    // the mask and the islands, both of which are panel-local.
                    // With several monitors the LAST bar to finish creating
                    // wins, which is the one the pointer is on anyway.
                    Item {
                        id: gapProxy
                        function vpnPanel(on: string): string {
                            return barContent.vpnPanelToggle(on === "true" || on === "1");
                        }
                        // Test hooks for the two connectivity menus: see
                        // `vpnPanelToggle` in BarContent for why a script needs
                        // them (a layer surface takes no synthetic click here).
                        function wifiPanel(on: string): string {
                            return barContent.wifiPanelToggle(on === "true" || on === "1");
                        }
                        function bluetoothPanel(on: string): string {
                            return barContent.bluetoothPanelToggle(on === "true" || on === "1");
                        }
                        function ask(): string {
                            const span = (a, b) => (b > a ? Math.round(a) + ".." + Math.round(b) : "off");
                            const runs = "[" + Math.round(barContent.leftRunX) + ".."
                                + Math.round(barContent.leftRunEnd) + " "
                                + Math.round(barContent.centerRunX) + ".."
                                + Math.round(barContent.centerRunEnd) + " "
                                + Math.round(barContent.rightRunX) + ".."
                                + Math.round(barContent.rightRunEnd) + "]";
                            const gaps = [span(barRoot.gap0From, barRoot.gap0To),
                                span(barRoot.gap1From, barRoot.gap1To),
                                span(barRoot.gap2From, barRoot.gap2To),
                                span(barRoot.gap3From, barRoot.gap3To)].join(" ");
                            // `hover` is the measurement that actually proves
                            // the input region: a pointer over a cut-out gap
                            // is never delivered to the bar at all, so the
                            // hover state is false there and true over an
                            // island. Region has no readback, and this is the
                            // same thing the compositor answers with.
                            // `padLive` is the third input to `through`, and it
                            // is reported with the two halves it is made of so
                            // a gesture can be seen shutting the gaps from
                            // outside the shell (the bench drives both):
                            //   qs -c ii ipc call bar swipeBench volume 20
                            //   qs -c ii ipc call bar gapState
                            return "through=" + String(barRoot.gapPassthrough)
                                + " padLive=" + String(barContent.padGestureLive)
                                + " padActive=" + String(TouchpadSwipe.active)
                                + " padFresh=" + String(barContent.swipeFresh)
                                + " fsHidden=" + String(barRoot.hiddenByFullscreen)
                                + " slidOut=" + String(barRoot.hideBySlide)
                                + " allowed=" + String(barRoot.fsBarAllowedOpen)
                                + " prewas=" + String(barRoot.fsPrewasInBar)
                                + " ptrInBar=" + String(barRoot.pointerInBar)
                                + " edgePress=" + String(barRoot.edgePressOpened)
                                + " edgeArmed=" + String(barRoot.fsEdgeArmed)
                                + " hoverRev=" + String(barRoot.hoverReveals)
                                + " pinned=" + String(barRoot.fsPinned)
                                + " barH=" + barRoot.height
                                + " win=" + barRoot.width + "x" + barRoot.height
                                + " scr=" + String(barRoot.screen?.name ?? "?")
                                + " shift=" + barRoot.slideShift
                                + " painted=" + String(barContent.islandsPainted)
                                + " swipeZone=" + String(barContent.swipeZone)
                                + " swipeLive=" + String(barRoot.swipeLive)
                                + " hold=" + String(barRoot.gapHolding)
                                // Every latch that can keep the bar DOWN over a
                                // fullscreen window, named. A bar that will not
                                // dismiss is always one of these being true, and
                                // which one is the whole diagnosis -- `mustShow`
                                // is their OR, so with all of them false the bar
                                // cannot be up at all.
                                + " latches[fsShow=" + String(barRoot.fsShow)
                                + " pinned=" + String(barRoot.fsPinned)
                                + " super=" + String(barRoot.superShow)
                                + " hold=" + String(barRoot.gapHolding)
                                + " spent=" + String(barRoot.gapSpent)
                                + " swipe=" + String(barRoot.swipeLive)
                                + " post=" + String(barRoot.postSwipe)
                                + " mustShow=" + String(barRoot.mustShow)
                                + " hideBySlide=" + String(barRoot.hideBySlide) + "]"
                                // The reveal path. `edgeArmed` is the dwell's
                                // precondition and `revealRunning` whether that
                                // dwell is in progress, so "the bar did not come
                                // back when I hovered" is distinguishable from
                                // "the dwell never started" -- which is the
                                // difference between the bar being broken and the
                                // pointer not being on the border yet.
                                + " reveal[edgeArmed=" + String(barRoot.fsEdgeArmed)
                                + " dwell=" + String(fsRevealTimer.running)
                                + " fsShow=" + String(barRoot.fsShow)
                                + " stripH=" + barRoot.hiddenStripHeight
                                + " band=" + barRoot.fsEdgeBand + "]"
                                // The compositor's strip: `zone` is what the
                                // workarea reserves and `sliding` says whether
                                // the bar is mid-travel. Nothing here toggles
                                // the zone for a window any more (see
                                // `exclusiveZone` below), so zone=0 now means
                                // exactly "auto-hide is yielding it".
                                + " strip[zone=" + barRoot.exclusiveZone
                                + " sliding=" + String(slideAnim.running) + "]"
                                + " islands=" + runs
                                + " gaps=[" + gaps + "]"
                                + " hover=" + String(hoverRegion.containsMouse)
                                + " at=" + hoverRegion.mouseX + "," + hoverRegion.mouseY
                                // What the two-finger swipe's gate actually
                                // decides on: where the pointer is, and which
                                // of the bar's empty stretches it is in --
                                // asked of the SAME function the gate asks, so
                                // this cannot report a zone the gate would
                                // refuse. A blank `zone` with the pointer on
                                // the bar means "on an island"; a blank with
                                // the pointer low on the screen means "off the
                                // bar". Both are the difference between "the
                                // swipe is broken" and "the pointer is not
                                // where the gesture lives", which used to be
                                // indistinguishable from the outside.
                                + " ptr=" + (barContent.pointerKnown
                                    ? Math.round(barContent.pointerX) + ","
                                        + Math.round(barContent.pointerY)
                                    : "?")
                                + " zone=" + (barContent.pointerSpacing() === "left"
                                    ? "brightness"
                                    : (barContent.pointerSpacing() === "right"
                                        ? "volume" : "-"));
                        }
                        // Test hook, same family as `pocket` below: the bar's
                        // own fullscreen pin, without needing a pointer on a
                        // button that only exists while the bar is down.
                        function pin(on: bool): void {
                            barRoot.fsPinned = on === true;
                        }
                        // The top-edge press itself, reachable from the IPC
                        // handler above. Under a fullscreen window this is the
                        // ONLY thing that may bring the bar out (hover no
                        // longer does), which makes it the half of the gesture
                        // a script can prove: a pointer cannot be driven at a
                        // 4px strip reliably, but the press runs the same
                        // requestEdgePressReveal() fsEdgePress's onClicked
                        // calls.
                        function edgePress(): string {
                            const before = barRoot.fsBarAllowedOpen;
                            barRoot.requestEdgePressReveal();
                            return "hiddenFs=" + String(barRoot.hiddenByFullscreen)
                                + " press=" + String(barRoot.fsPressReveal)
                                + " prewas=" + String(barRoot.fsPrewasInBar)
                                + " allowedBefore=" + String(before)
                                + " allowed=" + String(barRoot.fsBarAllowedOpen)
                                + " slidOut=" + String(barRoot.hideBySlide);
                        }
                        // The swipe gaps' joystick line: rail, travel, the two
                        // values and where each arrow's fade stands. Same
                        // reason as `ask` -- a layer surface can be neither
                        // screenshotted nor hovered from a script.
                        function askHint(): string {
                            return barContent.gapHintState;
                        }
                        // The status row's fit arithmetic, live: the measured
                        // text width next to the cap it must fit, and where the
                        // row actually went. Answers "why did the Opening line
                        // elide" in one call --
                        //   qs -c ii ipc call bar statusFit
                        function statusFit(): string {
                            return barContent.statusFitDiag();
                        }
                        // The swipe's frame diagnostics: arrival gaps,
                        // handler cost, and the event loop's own lateness.
                        // Read after a real gesture to see where it stalled.
                        function swipeDiag(): string {
                            return barContent.swipeDiag();
                        }
                        function swipeDiagReset(): void {
                            barContent.swipeDiagReset();
                        }
                        // A synthetic gesture through the real handler, on
                        // the shell's own clock: the one measurement that
                        // does not need a hand on the touchpad.
                        function swipeBench(zone: string, frames: int): string {
                            return barContent.swipeBench(zone, frames);
                        }
                        // The bisect switches: take the gesture's device
                        // writes, or its hint-rail displacement, out of a
                        // measurement run without touching the code.
                        function swipeOpt(name: string, on: string): string {
                            return barContent.swipeOpt(name, on);
                        }
                        // The sound icon's two-finger tap. Same hover gate as
                        // the gesture, so a probe run says whether the pointer
                        // is on the icon before it decides anything:
                        //   qs -c ii ipc call bar soundTap
                        function soundTapProbe(): string {
                            return barContent.soundTapProbe();
                        }
                        // The press-outside-the-bar dismissal, reachable from
                        // the IPC handler above, which is outside the window's
                        // scope and so cannot name `barRoot` itself.
                        function dismiss(): void {
                            barRoot.dismissForPress();
                        }
                        Component.onCompleted: {
                            bar.gapAsker = gapProxy;
                        }
                    }

                    // ── A press on the bar that is not on a control ────────────
                    //
                    // Declared BEFORE BarContent on purpose, which is what makes
                    // it safe: a MouseArea further down the list takes the
                    // press first, so this one is only reached where BarContent
                    // does not want it -- the empty stretches either side of
                    // the islands and the gaps. Every button, slider, tray icon
                    // and scroll area inside BarContent is above this and keeps
                    // its own press, untouched.
                    //
                    // And it cannot eat a click meant for the app underneath:
                    // under a fullscreen window the gaps are holes in the bar's
                    // input region (`gapPassthrough` -> the `GapCut` regions),
                    // so a press there is never delivered to the bar at all. It
                    // lands on the fullscreen app, and the app gets it. This
                    // catches only presses on bar that the bar is actually
                    // covering.
                    MouseArea {
                        anchors.fill: parent
                        // Hover belongs to the trackers above; taking presses is
                        // all this is for.
                        hoverEnabled: false
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // Nothing to show for it, and no cursor change: it is
                        // not an affordance, it is a dismissal.
                        onPressed: barRoot.dismissForPress()
                    }

                    BarContent {
                        id: barContent
                        // The fullscreen pin: BarContent's pin button flips
                        // this through the two aliases below.
                        property bool fsPinned: barRoot.fsPinned

                        property bool overFullscreen: barRoot.hiddenByFullscreen
                        function togglePin() { barRoot.fsPinned = !barRoot.fsPinned; }
                        
                        implicitHeight: Appearance.sizes.barHeight
                        anchors {
                            right: parent.right
                            left: parent.left
                            top: parent.top
                            bottom: undefined
                            topMargin: 0
                            bottomMargin: (Config.options.interactions.deadPixelWorkaround.enable && barRoot.anchors.bottom) * -1
                            rightMargin: (Config.options.interactions.deadPixelWorkaround.enable && barRoot.anchors.right) * -1
                        }
                        // The slide-out. A transform, not an anchor margin: the
                        // bar's whole skin (islands, shadows, droplet) is painted
                        // inside BarContent, so one translate carries all of it
                        // without re-laying anything out on every animation tick.
                        // The surface clips at the screen edge, so the bar
                        // genuinely rides up and off rather than being cut off
                        // somewhere inside its own bounds.
                        transform: Translate {
                            y: (barRoot.anchors.bottom ? 1 : -1) * barRoot.slideShift
                        }

                        states: State {
                            name: "bottom"
                            when: Config.options.bar.bottom
                            AnchorChanges {
                                target: barContent
                                anchors {
                                    right: parent.right
                                    left: parent.left
                                    top: undefined
                                    bottom: parent.bottom
                                }
                            }
                            PropertyChanges {
                                target: barContent
                                anchors.topMargin: 0
                                anchors.bottomMargin: 0
                            }
                        }
                    }

                    // The fullscreen reveal hint: a small pill on the very top
                    // edge, shown only while a fullscreen window hides the bar
                    // AND the pointer is actually resting on the border -- the
                    // sidebars' edge hints behave the same way, and for the same
                    // reason: a line that sits there permanently reads as part of
                    // the fullscreen app's chrome. Armed the moment the strip has
                    // the pointer (no delay: the pointer is already there), gone
                    // again the instant the bar itself comes down.
                    // Drawn in the Overlay layer, so it stays visible over the
                    // fullscreen client; the mask does not limit rendering.
                    // Floating a few pixels off the border and EXTENDING along
                    // its length to appear (a scale transform -- no relayout, no
                    // fade), matching the sidebars' edge hints exactly.
                    Rectangle {
                        id: barHint
                        // Gated on the bar actually being HIDDEN as well as on
                        // the edge being armed. `fsEdgeArmed` used to imply
                        // fullscreen, so the fullscreen half was redundant; now
                        // that it is a pure pointer-position test it is the whole
                        // point, because the hint is an affordance for
                        // something that can be revealed. Without it, merely
                        // passing the pointer across the top two pixels of an
                        // ordinary desktop -- with the bar sitting right there,
                        // fully visible -- would flash this pill, which is
                        // noise on the one surface where nothing is hidden.
                        readonly property bool armed: barRoot.hideBySlide
                            && barRoot.fsEdgeArmed && !barRoot.mustShow
                        width: 28
                        height: 2
                        radius: height / 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 5
                        color: Appearance.colors.colOnLayer0
                        opacity: 0.45
                        transform: Scale {
                            id: barHintScale
                            // Driven imperatively from barHint below, NOT via
                            // a Behavior whose animation is picked by a binding.
                            // Qt refuses to change a Behavior's animation at
                            // runtime -- "Cannot change the animation assigned
                            // to a Behavior" -- so the old
                            //   animation: (armed ? enter : exit).createObject()
                            // warned on every flip and then silently kept the
                            // FIRST curve it had ever created: the exit ran on
                            // the enter curve, and the log filled with spam.
                            // Mutating properties of one animation is allowed;
                            // reassigning the Behavior's animation is not.
                            xScale: 0.0
                            origin.x: barHint.width / 2
                            origin.y: barHint.height / 2
                        }

                        NumberAnimation {
                            id: barHintAnim
                            target: barHintScale
                            property: "xScale"
                        }

                        onArmedChanged: {
                            // The reveal wipe: emphasized exit going away,
                            // enter coming back -- the same asymmetric pair
                            // the sidebars use, so the whole shell speaks one
                            // motion language. Picked here, per change, the
                            // way a Behavior cannot be.
                            const spec = barHint.armed
                                ? Appearance.animation.elementMoveEnter
                                : Appearance.animation.elementMoveExit;
                            barHintAnim.stop();
                            barHintAnim.duration = spec.duration;
                            barHintAnim.easing.type = spec.type;
                            barHintAnim.easing.bezierCurve = spec.bezierCurve;
                            barHintAnim.to = barHint.armed ? 1.0 : 0.0;
                            barHintAnim.start();
                        }
                    }

                    // Round decorators
                    Loader {
                        id: roundDecorators
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: barContent.bottom
                            bottom: undefined
                        }
                        // The round decorators hug the content's painted bottom
                        // edge but are anchored to it rather than being its
                        // children -- an anchor doesn't follow a transform, so
                        // they carry the same slide by hand or the bar's corners
                        // would be left behind mid-animation.
                        transform: Translate {
                            y: (barRoot.anchors.bottom ? 1 : -1) * barRoot.slideShift
                        }
                        height: Appearance.rounding.screenRounding
                        active: showBarBackground && Config.options.bar.cornerStyle === 0 // Hug

                        states: State {
                            name: "bottom"
                            when: Config.options.bar.bottom
                            AnchorChanges {
                                target: roundDecorators
                                anchors {
                                    right: parent.right
                                    left: parent.left
                                    top: undefined
                                    bottom: barContent.top
                                }
                            }
                        }

                        sourceComponent: Item {
                            implicitHeight: Appearance.rounding.screenRounding
                            RoundCorner {
                                id: leftCorner
                                anchors {
                                    top: parent.top
                                    bottom: parent.bottom
                                    left: parent.left
                                }

                                implicitSize: Appearance.rounding.screenRounding
                                color: showBarBackground ? Appearance.colors.colBarBackground : "transparent"

                                corner: RoundCorner.CornerEnum.TopLeft
                                states: State {
                                    name: "bottom"
                                    when: Config.options.bar.bottom
                                    PropertyChanges {
                                        leftCorner.corner: RoundCorner.CornerEnum.BottomLeft
                                    }
                                }
                            }
                            RoundCorner {
                                id: rightCorner
                                anchors {
                                    right: parent.right
                                    top: !Config.options.bar.bottom ? parent.top : undefined
                                    bottom: Config.options.bar.bottom ? parent.bottom : undefined
                                }
                                implicitSize: Appearance.rounding.screenRounding
                                color: showBarBackground ? Appearance.colors.colBarBackground : "transparent"

                                corner: RoundCorner.CornerEnum.TopRight
                                states: State {
                                    name: "bottom"
                                    when: Config.options.bar.bottom
                                    PropertyChanges {
                                        rightCorner.corner: RoundCorner.CornerEnum.BottomRight
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "bar"

        function toggle(): void {
            GlobalStates.barOpen = !GlobalStates.barOpen
        }

        function close(): void {
            GlobalStates.barOpen = false
        }

        function open(): void {
            GlobalStates.barOpen = true
        }

        

        // Diagnostic: what the bar itself believes about fullscreen on each
        // monitor. `fullscreenOnMonitor` is a binding over the reactive
        // Hyprland model, so when it disagrees with the compositor the only
        // way to tell WHICH side is stale is to read the shell's own value
        // next to `hyprctl`'s. Reports the toplevel count the bar sees, how
        // many of those are fullscreen, and the resulting hide decision.
        function fullscreenState(): string {
            const screens = Quickshell.screens;
            const out = [];
            for (let i = 0; i < screens.length; i++) {
                const mon = Hyprland.monitorFor(screens[i]);
                const activeWs = Number(mon?.activeWorkspace?.id);
                const list = HyprlandData.windowList ?? [];
                let fsHere = 0;
                let who = "";
                for (let k = 0; k < list.length; k++) {
                    const c = list[k];
                    if (Number(c?.fullscreen) !== 2) continue;
                    if (Number(c?.workspace?.id) !== activeWs) continue;
                    fsHere++;
                    who = String(c?.class ?? "?");
                }
                out.push(screens[i].name
                    + " ws=" + activeWs
                    + " fsHere=" + fsHere
                    + " fs=" + who
                    + " barHidden=" + String(GlobalStates.barHidden));
            }
            return out.join(" | ");
        }

        // Diagnostic: what the input region is doing about the gaps. Goes
        // through the per-monitor proxy below, because this handler is
        // declared on the OUTER Scope while the bar window -- and with it
        // barRoot, barMask and barContent -- lives inside the per-monitor
        // component, where those ids are not in scope here.
        function gapState(): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.ask();
            } catch (e) {
                return "threw: " + e;
            }
        }

        // Diagnostic: the status row's fit arithmetic, live. The "Opening
        // <app>…" row eliding inside the island was invisible from the
        // outside -- this reports the three numbers that decide where the
        // row goes (measured text width, the empty-run cap, and the inline
        // decision), so the fit test can be verified from a script without
        // screenshots:
        //   qs -c ii ipc call bar statusFit
        function statusFit(): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.statusFit();
            } catch (e) {
                return "threw: " + e;
            }
        }

        // Test/diagnostic hook: the fullscreen pin, so the down-over-fullscreen
        // state can be held open from a script. Goes through the same proxy as
        // the diagnostic above -- barRoot is panel-local.
        function pin(on: string): void {
            const proxy = bar.gapAsker;
            if (proxy) proxy.pin(on === "true" || on === "1");
        }
        // The top-edge press, through the same proxy (barRoot is panel-local).
        //   qs -c ii ipc call bar edgePress
        // Under fullscreen: expect press=true allowed=true slidOut=false --
        // and, with the pointer off the bar, the fullscreen enforcer taking it
        // back down within ~200ms.
        function edgePress(): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.edgePress();
            } catch (e) {
                return "threw: " + e;
            }
        }

        // Diagnostic: where the two-finger swipe's frames actually go. Reset
        // it, have a real swipe, read it back: arrival gaps say whether the
        // shell came back to the pipe, the tick says whether the event loop
        // was blocked while it did not, and the cost says what the handler
        // itself took. All three, because "it freezes" has more than one
        // cause and they do not share a fix.
        function swipeDiag(): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.swipeDiag();
            } catch (e) {
                return "threw: " + e;
            }
        }

        function swipeDiagReset(): void {
            const proxy = bar.gapAsker;
            if (proxy)
                proxy.swipeDiagReset();
        }

        // The sound icon's two-finger tap, from outside the shell: it silences,
        // or puts the previous level back, exactly as the gesture does -- the
        // pointer has to be over the icon either way, which is reported rather
        // than assumed.
        //   qs -c ii ipc call bar soundTap
        function soundTap(): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.soundTapProbe();
            } catch (e) {
                return "threw: " + e;
            }
        }

        // A synthetic swipe (default 300 frames at 8ms) through the real
        // handler path -- mirror writes, island reflows, hint rail, rendering
        // -- so the shell's side of the gesture can be measured on demand.
        function swipeBench(zone: string, frames: int): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.swipeBench(zone, frames);
            } catch (e) {
                return "threw: " + e;
            }
        }

        // Bisect switches for the gesture's downstream cost (see
        // `swipeWritesEnabled` / `swipePushEnabled` in BarContent):
        //   qs -c ii ipc call bar swipeOpt writes off
        //   qs -c ii ipc call bar swipeOpt push off
        function swipeOpt(name: string, on: string): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.swipeOpt(name, on);
            } catch (e) {
                return "threw: " + e;
            }
        }

        // Diagnostic: the swipe gaps' value line. Readable without a pointer
        // and without locking anything, which is the point -- the line is on a
        // layer surface, so there is no other way to see where it is.
        // The same dismissal a press outside the bar performs, without a
        // pointer. A layer surface can be neither screenshotted nor clicked
        // from a script, so this is how the path is exercised at all; it is
        // also the quickest way to tell whether the bar is wedged in a hold.
        function dismiss(): void {
            const proxy = bar.gapAsker;
            if (proxy) proxy.dismiss();
        }

        // Which rows the output mixer is showing, as one line.
        //
        // A diagnostic, and the only way to check that the shell's own
        // notification chimes are being kept OUT of that list: the mixer is a
        // layer surface, so it cannot be screenshotted, and the streams it
        // must hide are the short-lived ones -- a chime is over long before
        // anything polling from outside the shell could catch it. Asking the
        // shell that owns the list is the only way to see it while it
        // matters.
        //
        // It lives on this handler rather than on one of its own in Audio
        // because an IpcHandler declared inside that Singleton takes the
        // whole configuration down on this build: the module fails to
        // resolve and Quickshell reports it as a cascade of unrelated "Type
        // unavailable" errors starting at shell.qml.
        // Diagnostic: what the shell's Tailscale service believes.
        //
        // The sidebar switch and the bar popup both draw from that one
        // service, so when the switch disagrees with `tailscale status` this
        // is what says which half is stale -- and it is the only way to read
        // the parsed peer list back out of the shell, since a layer surface
        // can be neither screenshotted nor clicked from a script.
        //   qs -c ii ipc call bar vpnState
        function vpnState(): string {
            try {
                const names = [];
                for (const peer of Tailscale.peers)
                    names.push(peer.name + "@" + peer.ip + (peer.online ? " online" : " offline"));
                return "installed=" + Tailscale.installed
                    + " state=" + Tailscale.backendState
                    + " connected=" + Tailscale.connected
                    + " self=" + Tailscale.selfName + "@" + Tailscale.selfIp
                    + " peers=[" + names.join(", ") + "]";
            } catch (error) {
                return "threw: " + error;
            }
        }

        // Test hook: flip the VPN through the very service the switch calls.
        // A pointer cannot reach a layer surface from a script, and the
        // command path alone would not prove the shell half works -- this
        // runs the real `setEnabled`, so the state read back by `vpnState`
        // above is the shell's own doing.
        //   qs -c ii ipc call bar vpnSet false
        function vpnSet(on: string): string {
            const wanted = on === "true" || on === "1";
            Tailscale.setEnabled(wanted);
            return "requested=" + wanted;
        }

        // Test hook: open or close the bar's VPN popup, through the same flag
        // the icon itself writes (see BarContent.vpnPanelToggle). barRoot is
        // panel-local, so this goes through the same proxy as the rest.
        //   qs -c ii ipc call bar vpnPanel true
        function vpnPanel(on: string): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.vpnPanel(on);
            } catch (e) {
                return "threw: " + e;
            }
        }

        // The same test hooks for the Wi-Fi and Bluetooth menus.
        //   qs -c ii ipc call bar wifiPanel true
        //   qs -c ii ipc call bar bluetoothPanel true
        function wifiPanel(on: string): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.wifiPanel(on);
            } catch (e) {
                return "threw: " + e;
            }
        }

        function bluetoothPanel(on: string): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.bluetoothPanel(on);
            } catch (e) {
                return "threw: " + e;
            }
        }

        function mixerRows(): string {
            try {
                const parts = [];
                for (const r of Audio.mixerApps) {
                    let row = String(r.key) + "=" + String(r.name);
                    if (r.music === true)
                        row += " [music" + (String(r.title ?? "") !== "" ? ":" + String(r.title) : "") + "]";
                    if (r.symbol !== undefined && r.symbol !== "")
                        row += " [" + String(r.symbol) + "]";
                    if (r.node)
                        row += " [live]";
                    parts.push(row);
                }
                return parts.join("  ");
            } catch (error) {
                return "threw: " + error;
            }
        }

        function gapHint(): string {
            const proxy = bar.gapAsker;
            if (!proxy)
                return "no bar window (barOpen off?)";
            try {
                return proxy.askHint();
            } catch (e) {
                return "threw: " + e;
            }
        }

        // Test/diagnostic hook for the below-bar droplet. RETIRED with the
        // drop (BarContent.armPocket's note): the droplet no longer exists,
        // so this is close-only -- any id just closes whatever is open.
        function pocket(id: string): void {
            LiquidBar.setPocket("")
        }

        // Same, with an explicit centre x (bar coordinates) -- test hook for
        // verifying edge clamping without a pointer. Goes through the real
        // arming path: the older version wrote dropCenter and armed the pocket
        // directly, skipping publishDropGeometry -- the state dump then showed
        // dropX = 0 and looked exactly like the clamp was broken.
        function pocketAt(id: string, centerX: int): void {
            const armer = bar.pocketArmer;
            if (armer) armer.arm(id, centerX);
        }
    }

    GlobalShortcut {
        name: "barToggle"
        description: "Toggles bar on press"

        onPressed: {
            GlobalStates.barOpen = !GlobalStates.barOpen;
        }
    }

    GlobalShortcut {
        name: "barOpen"
        description: "Opens bar on press"

        onPressed: {
            GlobalStates.barOpen = true;
        }
    }

    GlobalShortcut {
        name: "barClose"
        description: "Closes bar on press"

        onPressed: {
            GlobalStates.barOpen = false;
        }
    }
}



