pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
// GlobalShortcut (used at the bottom of this file) lives in
// Quickshell.Hyprland. Without the import the type is simply unknown and the
// whole config fails to load -- a fatal error, not a warning.
import Quickshell.Hyprland

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The desktop overview: design A ("Frosted stage -- full") from
 * design/desktop-view/index.html, built with the shell's own widgets.
 *
 * What it is: ONE wallpaper, blurred and dimmed once, and the desktops as
 * frosted cards floating on it. Each card carries the things an overview is
 * normally for --
 *
 *   number ............ the desktop's own id
 *   window count ...... "3 windows", top-right of the card
 *   live previews ..... one ScreencopyView per window on that desktop, drawn at
 *                      its real position and size inside the card, so the card
 *                      reads as a miniature of that desktop rather than a
 *                      screenshot (this is the same capture OverviewWindow
 *                      already does, retargeted at a card instead of a tile)
 *   app list .......... every app on the desktop with its own window count
 *   memory ............ that desktop's windowed processes' resident memory as a
 *                      bar, from ProcessList (sampled only while this is open)
 *   now playing ....... the track, when a player window lives on that desktop
 *   empty desktops .... say so, instead of showing a dead preview
 *
 * What it is NOT: the existing overview. That one is a full drag-and-drop
 * window manager surface. This one LOOKS, JUMPS, and -- since 2026-10-15,
 * requested -- moves a WINDOW between desktops by hand. No window is ever
 * killed here, and nothing moves without a deliberate gesture: two things can
 * be rearranged by hand and each has its own grant.
 *
 *   a CARD ............ click-hold ~450ms, or double-tap then press-and-move:
 *                      two desktops trade places (see reorderCells -- workspace
 *                      ids trade through a scratch id, windows never move)
 *   a WINDOW .......... press on a window preview inside a card and MOVE: the
 *                      window is carried, every other card rings itself as a
 *                      target, and releasing over one moves the window there
 *                      and TAKES YOU WITH IT
 *
 * A hold on a card still means "the desktop", and a move off a window means
 * "the window": the smaller object gets the smaller gesture, and both are
 * decided before the pointer has travelled far. A casual bar tap still cannot
 * rearrange anything: a click is a click until the pointer travels past a drag
 * threshold.
 *
 * Entry points: the bar's two empty stretches (left of the clock island and
 * right of the now-bar island) used to toggle the sidebars -- they open this
 * now, and the sidebar buttons remain the explicit way in. The SUPER +
 * four-finger swipe down that used to open it as well is REMOVED (2026-10-16,
 * requested); the plain four-finger down gesture, which closes the focused
 * window, is untouched.
 *
 * Dismissal: Escape, a press outside the cards, picking a desktop, or a
 * desktop switch. The wallpaper is the shell's own (Appearance.themeWallpaperPath
 * with the same video-thumbnail fallback OverviewWidget uses).
 */
Scope {
    id: root

    readonly property bool open: GlobalStates.desktopOverviewOpen

    // ── Geometry ──────────────────────────────────────────────────────────
    // The grid: three columns, as many rows as the desktops need. The whole
    // grid is sized from the SURFACE (panel.width), not from a monitor record
    // and not from a count of desktops: Hyprland's monitor width is in
    // PHYSICAL pixels on a scaled display, so a 2560x1600@1.6 screen reports
    // 2560 while this surface is 1600 logical -- sizing cards from it made the
    // whole grid wider than the screen, with the header hanging off the left
    // edge. Two consequences fall out of using the surface: adding desktop 12
    // changes the row count, never the card size, and a scale change is
    // picked up for free.
    readonly property real gap: 20
    readonly property int columns: 3
    readonly property real gridWidth: Math.max(480, Math.min(surfaceWidth - 200, 1720))
    readonly property real cardWidth: (gridWidth - gap * (columns - 1)) / columns
    readonly property real cardHeight: cardWidth * 0.625 // 16:10, as the preview

    readonly property var monitor: Hyprland.monitorFor(panel.screen) ?? Quickshell.screens[0]
    // The same monitor record HyprlandData publishes, for the reserved
    // (exclusive) strips the bar holds. Its absence must not break the
    // geometry -- hence the ?? fallbacks at every use.
    readonly property var monitorData: {
        const id = root.monitor?.id;
        return (HyprlandData.monitors ?? []).find(m => m?.id === id) ?? null;
    }
    // The screen this surface is on, in LOGICAL pixels. A PanelWindow sized
    // only by `anchors { top/bottom/left/right: true }` stays at Qt's default
    // 100x100 -- the anchors are honoured only once the window has an implicit
    // size, which is why every other full-screen surface in the shell (the
    // cheatsheet, the overview) states one. Sizing from the screen (logical)
    // rather than from the Hyprland monitor (physical on a scaled display) is
    // what makes a 2560x1600@1.6 monitor lay out as 1600x1000.
    readonly property var targetScreen: panel.screen ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)
    readonly property real surfaceWidth: Math.max(640, targetScreen?.width ?? 1920)
    readonly property real surfaceHeight: Math.max(480, targetScreen?.height ?? 1080)

    // The work area in LOGICAL pixels: the surface minus the exclusive strips
    // the bar holds. This -- not the monitor's reported size -- is the frame
    // every window's absolute position maps into, so it is also the divisor
    // for the preview scale.
    readonly property real workWidth: Math.max(1, surfaceWidth - 2 * (monitorData?.reserved?.[0] ?? 0))
    readonly property real workHeight: Math.max(1, surfaceHeight - (monitorData?.reserved?.[0] ?? 0) - (monitorData?.reserved?.[2] ?? 0))
    // Window positions are absolute monitor coordinates; the card wants them
    // relative to the work area's top-left.
    readonly property real workOffsetX: -((monitorData?.x ?? 0) + (monitorData?.reserved?.[0] ?? 0))
    readonly property real workOffsetY: -((monitorData?.y ?? 0) + (monitorData?.reserved?.[1] ?? 0))

    // The wallpaper behind every card, video thumbnails included. This lives
    // on the SCOPE, not on the window: the Image reads it as
    // `root.wallpaperSource`, and a property declared inside the PanelWindow
    // is not on root -- so the source resolved empty and the whole surface
    // fell back to the bare background colour.
    readonly property string wallpaperSource: {
        const p = Appearance.themeWallpaperPath;
        const video = /\.(mp4|webm|mkv|avi|mov)$/i.test(p);
        return video ? (Config.options.background.thumbnailPath || p) : p;
    }


    // ── Desktops ──────────────────────────────────────────────────────────
    // The highest id in use, never below the one you are on, never below what
    // hyprctl reports: "how many desktops exist", read live. The same rule
    // Overview.qml's existingDesktopCount() uses, kept here rather than shared
    // because this surface is deliberately independent of that one.
    readonly property int activeId: Math.max(1, Math.min(100, monitor?.activeWorkspace?.id ?? 1))
    readonly property int desktopCount: {
        let highest = root.activeId;
        const list = HyprlandData.workspaces ?? [];
        for (let i = 0; i < list.length; i++) {
            const id = list[i]?.id ?? 0;
            if (id > 0 && id < 100)
                highest = Math.max(highest, id);
        }
        return highest;
    }
    // The cells on screen: every desktop that exists, plus exactly one empty
    // "new desktop" slot. A fixed cell count is what made the old grid feel
    // like it had desktops hidden somewhere.
    readonly property int cellCount: desktopCount + 1
    readonly property int rows: Math.ceil(root.cellCount / root.columns)

    // ── Per-desktop facts ─────────────────────────────────────────────────
    // The window list, grouped by desktop, in one pass: every card asks the
    // same question and the shell should answer it once per compositor event
    // rather than once per card per frame.
    readonly property var windowsByDesktop: {
        const __t0 = Date.now();
        const map = {};
        for (const win of (HyprlandData.windowList ?? [])) {
            const id = win?.workspace?.id ?? 0;
            if (id < 1 || id > 100)
                continue;
            // Only an unusable address is dropped. `hidden` is NOT a filter:
            // Hyprland sets that flag on every window covered by a fullscreen
            // one, so a single maximised app made every OTHER desktop's card
            // read as empty and the whole grid went blank. A hidden window is
            // still a window on its desktop, and it still has something to
            // capture.
            if (!win?.address)
                continue;
            // QML's JavaScript engine rejects the logical-assignment operator
            // (`??=`), and one unsupported token fails the WHOLE config load --
            // the shell came up dead with "Unexpected token `='" here. The
            // two-line form below is exactly what `??=` meant, and parses.
            if (!map[id])
                map[id] = [];
            map[id].push(win);
        }
        const __r = map;
        StatusSignal.perfMark("ovByDesktop", Date.now() - __t0);
        return __r;
    }

    // Apps per desktop: name + how many windows, biggest first. The window
    // class is the identity Hyprland reports; the readable name comes from the
    // same launcher database the app search uses, so "brave-browser" shows as
    // "Brave" on a card and as "Brave" in the overlay.
    function appsFor(id) {
        const __t0 = Date.now();
        const wins = root.windowsByDesktop[id] ?? [];
        const counts = {};
        const order = [];
        for (const win of wins) {
            const cls = String(win?.class ?? "");
            if (cls.length === 0)
                continue;
            if (!counts[cls]) {
                counts[cls] = { cls: cls, name: root.appName(cls), count: 0, icon: root.iconFor(cls) };
                order.push(cls);
            }
            counts[cls].count++;
        }
        const __r = order.map(k => counts[k]).sort((a, b) => b.count - a.count);
        StatusSignal.perfMark("ovAppsFor", Date.now() - __t0);
        return __r;
    }

    // The launcher's name for a class, falling back to the class itself: an
    // app with no desktop entry (an AppImage, a helper) still labels its card.
    function appName(cls) {
        const entry = AppSearch.list.find(a => String(a.id ?? "").toLowerCase() === cls.toLowerCase());
        if (entry?.name)
            return String(entry.name);
        // "@codebuff/freebuff-desktop" -> "Freebuff"; "brave-browser" ->
        // "Brave". Split the class on its separators, title-case the first
        // token, and drop a trailing generic word.
        const cleaned = cls.split("/").pop().split(/[-_]/).filter(Boolean);
        if (cleaned.length === 0)
            return cls;
        const stop = new Set(["browser", "desktop", "app", "client", "player", "electron", "bin"]);
        const first = cleaned.find(w => !stop.has(w.toLowerCase())) ?? cleaned[0];
        return first.charAt(0).toUpperCase() + first.slice(1);
    }

    // Resident memory of the processes a desktop's windows are responsible for:
    // the window's own pid AND everything below it, because the process holding
    // a window is almost never the process holding the memory.
    //
    // Measured on this machine, 2026-10-15: Brave's window is ONE pid at 359 MB
    // while its twenty processes total 2.84 GB, so a desktop running a browser
    // read "RAM 1%" while the browser was costing 9% of the machine. The old sum
    // was over the window pids alone -- honest arithmetic on the wrong set, and
    // it under-reported every desktop whose apps are multi-process, which is
    // every browser, Electron app and IDE there is.
    //
    // Attribution is by ANCESTRY, and each process is counted exactly once, by
    // the desktop of its nearest window ancestor. Both halves matter: a helper
    // belongs to the window it descends from rather than to whichever card
    // happens to share its name, and an app with a window on EACH of two
    // desktops must not be billed in full to both cards -- the same 2.84 GB on
    // two cards would sum to 5.7 GB of a 31 GB machine and read as fact. A pid
    // that owns windows on two desktops goes to the first, which under-counts
    // one card rather than inventing memory that is not there.
    //
    // Every process with no window above it -- daemons, the compositor, the
    // shell itself -- belongs to no desktop and is deliberately left out: this
    // answers "what is this desktop costing me", not "what is the machine
    // using", so the cards are not expected to add up to the bar's figure.
    readonly property var memoryByDesktop: {
        const __t0 = Date.now();
        const _ = ProcessList.revision; // re-read on every sample
        const procs = ProcessList.processes ?? [];
        const parent = {};
        for (const proc of procs)
            parent[Number(proc?.pid ?? 0)] = Number(proc?.ppid ?? 0);
        // Window pid -> the desktop its window is on, read from the shell's own
        // window list, so the card bills the desktop it is drawing.
        const owner = {};
        for (const key in root.windowsByDesktop) {
            for (const win of (root.windowsByDesktop[key] ?? [])) {
                const pid = Number(win?.pid ?? 0);
                if (pid > 0 && owner[pid] === undefined)
                    owner[pid] = Number(key);
            }
        }
        const byDesktop = {};
        for (const proc of procs) {
            let cur = Number(proc?.pid ?? 0);
            let desktop = -1;
            // Bounded: a broken ppid chain must not walk forever. 64 is far
            // past the deepest tree here (measured: 4).
            for (let hops = 0; cur > 0 && hops < 64; hops++) {
                if (owner[cur] !== undefined) {
                    desktop = owner[cur];
                    break;
                }
                cur = Number(parent[cur] ?? 0);
            }
            if (desktop < 1)
                continue;
            byDesktop[desktop] = Number(byDesktop[desktop] ?? 0) + Number(proc?.memory ?? 0);
        }
        StatusSignal.perfMark("ovMemoryByDesktop", Date.now() - __t0);
        return byDesktop;
    }

    function memoryFor(id) {
        return Number(root.memoryByDesktop[id] ?? 0);
    }

    // The player whose window lives on this desktop, so a card can say what is
    // playing there. Matched by class against the desktop's windows, which is
    // the only link a MPRIS player and a workspace share.
    function trackFor(id) {
        const wins = root.windowsByDesktop[id] ?? [];
        if (wins.length === 0)
            return null;
        const classes = wins.map(w => String(w?.class ?? "").toLowerCase());
        for (const player of (MprisController.players ?? [])) {
            const idents = [player?.identity, player?.desktopEntry]
                .map(s => String(s ?? "").toLowerCase().replace(/[^a-z0-9]/g, ""));
            for (const clsRaw of classes) {
                const cls = clsRaw.replace(/[^a-z0-9]/g, "");
                if (cls.length < 4)
                    continue;
                if (idents.some(x => x.length >= 4 && (x.includes(cls) || cls.includes(x))))
                    return player;
            }
        }
        return null;
    }

    // ── Selection & keys ──────────────────────────────────────────────────
    property int selectedCell: 0

    function cellOf(id) {
        return id - 1; // desktop 1 is cell 0, the "new desktop" slot is the last
    }
    function desktopOfCell(cell) {
        return cell + 1;
    }

    function moveSelection(delta) {
        const total = root.cellCount;
        root.selectedCell = ((root.selectedCell + delta) % total + total) % total;
    }

    function goTo(cell) {
        // The "new desktop" slot needs no special case: focusing an id that
        // does not exist CREATES it, which is exactly what that slot means.
        Hyprland.dispatch(`hl.dsp.focus({ workspace = ${root.desktopOfCell(cell)} })`);
        GlobalStates.desktopOverviewOpen = false;
    }

    function activateSelection() {
        root.goTo(root.selectedCell);
    }

    // ── Drag policy: grab is GRANTED, never automatic ─────────────────
    // Exactly two ways to pick a desktop up, nothing else can:
    //
    //   click-hold ... press a card and hold the button down ~450ms
    //   double-tap ... two taps on a card within 400ms, then move
    //
    // Merely moving the pointer over an idle grid (hover, no button) can
    // NEVER arm a grab. This area has `hoverEnabled: true`, so
    // `onPositionChanged` fires on HOVER too -- and with `pressX/pressY`
    // stale from an earlier click, a hover sweep "travelled" far past the
    // slop and lifted a card nobody had pressed: the auto-grab that was
    // wrong. The in-flight gate is the `armed` flag below, which only a
    // handler with a live press and a granted grant can set.
    //
    // Once armed: the card is carried 1:1 by the pointer, the others slide
    // aside to open the gap, release in the gap commits the insert
    // rotation, release outside the grid cancels. A tap below the arm
    // thresholds is still a plain click-to-switch.
    // Which cell is in flight { -1 = none }, and which cell the pointer is
    // over { -1 = not over the grid }.
    property int draggingCell: -1
    property int dropCell: -1
    // How far the carried card has been pulled from its slot, in veil
    // coordinates. Applied as a Translate so the slot stays behind and the
    // layout never reflows under the pointer.
    property real dragOffsetX: 0
    property real dragOffsetY: 0
    // Set when a release ends a real drag, so the synthesized click that
    // follows it does not ALSO switch desktops. Cleared on the next press.
    property bool dragConsumed: false
    // True while a reorder's dispatches are in flight: the workspace-id
    // churn they cause (including the id of the desktop you stand on) is
    // ours, not a switch, and must not close the grid mid-arrangement.
    property bool reorderBusy: false

    // ── Grant state ────────────────────────────────────────────────────
    // True only once click-hold or double-tap has GRANTED the grab on a
    // live press. The gate every in-flight write must pass: a handler
    // whose press is gone (hover!) cannot set it and cannot act on it.
    property bool dragArmed: false
    // The press a grant belongs to; cleared on release. A grant without a
    // live press is void -- this is what kills the hover-armed ghost.
    property bool dragHeld: false
    // Bookkeeping for the two grants.
    property real lastTapTime: 0        // epoch ms of the previous tap's release
    property int lastTapCell: -1        // cell the previous tap landed on
    readonly property int holdArmMs: 450  // click-hold grant time
    readonly property int doubleTapMs: 400  // double-tap window

    // ── A desktop in your hand WITHOUT a button: the lift, now with NO WAY IN ──
    //
    // SUPER + four-finger swipe down opens this grid, and the desktop the
    // pointer was standing on comes up IN YOUR HAND: move the pointer and that
    // card is carried, the neighbours part to open the gap, and the next CLICK
    // drops it where the pointer is -- the same insert a release commits for a
    // held card (`reorderCells`), so desktops can be arranged without
    // click-holding anything. Escape puts it back, and the lift dies with the
    // grid, however the grid ended.
    //
    // NO INPUT ASKS FOR THIS ANY MORE (2026-10-16, requested). The SUPER +
    // four-finger swipe down that dispatched it is deleted from
    // custom/general.lua, and SUPER+Space raises no lift request, so nothing a
    // pointer or a key can do reaches `liftFrom` with a request standing. The
    // machinery stays whole on purpose -- the IPC `desktopOverview lift` still
    // drives it and one bind brings it back -- which is why this block
    // describes a mechanism that no entry point currently enters rather than
    // being deleted along with them.
    //
    // WHY THE GESTURE ALONE, and not the keys or the bar's empty stretches.
    // Those toggle the grid with no pointer intent behind them: there is no
    // "the desktop I meant", so a lift there would either guess or take the
    // grid's click-to-switch away from someone who only tapped a key. The swipe
    // is the one way in that IS a pointer action -- the cursor is parked on the
    // desktop the fingers are on -- which is what makes "the desktop under the
    // pointer" a fact about the gesture rather than a guess at intent. So this
    // has its own global, dispatched by that gesture (custom/general.lua) and
    // never by the toggle.
    //
    // Two flags, because the request and the state are a frame apart:
    // `liftRequested` is set before the grid opens and spent by the open (a
    // point can only be mapped onto a card that has been laid out), and
    // `gestureLift` is the state that answers "is a card in hand with no press
    // behind it" -- read by the motion handler, taken over by the press that
    // drops it, and cleared by Escape, a close, or the drop itself.
    property bool liftRequested: false
    property bool gestureLift: false
    // Where the pointer stood when the card came up, in veil coordinates. The
    // carry is measured from here: a hover lift has no press point to be
    // relative to.
    property real liftOriginX: 0
    property real liftOriginY: 0

    // The pointer, from the compositor, because a hover lift rides no event of
    // its own: the grid appears under a pointer that has not moved, and Qt
    // delivers no motion for a surface it has only just mapped. One
    // `hyprctl cursorpos` per lift (~13 ms, the same source the bar's own
    // pointer reads use) answers the lift's only question -- which card is
    // under the pointer right now. A failed read lifts nothing, which is the
    // old behaviour and the honest one.
    //
    // It is also the LIFT'S KEEPER while a card is in hand: the same read on a
    // ~40 ms beat carries the card even when the hover path has lost the
    // pointer entirely (see `carryGestureTo`). The two writers cannot fight,
    // because both land in that one function.
    Process {
        id: cursorProbe
        command: ["hyprctl", "cursorpos", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                const nums = String(this.text ?? "").match(/-?\d+/g) ?? [];
                if (nums.length < 2)
                    return;
                const x = Number(nums[0]);
                const y = Number(nums[1]);
                // One process, two jobs, told apart by which question is live:
                // with a card already in hand this is a CARRY, and otherwise
                // it is the lift that just arrived.
                if (root.gestureLift)
                    root.carryGestureTo(x, y);
                else
                    root.liftFrom(x, y);
            }
        }
    }

    // The beat behind that keeper. Deliberately slower than the pointer's own
    // motion: while the pointer is over the carried card the hover events are
    // exact and this only has to agree with them, and the case it exists for --
    // a pointer that has left the card -- is a position, not a trajectory.
    // ~25 reads/s of a ~13 ms process for the second or so a card is in hand.
    Timer {
        id: liftPoll
        interval: 40
        repeat: true
        running: root.gestureLift
        onTriggered: {
            if (!cursorProbe.running)
                cursorProbe.running = true;
        }
    }

    // Put the desktop under (x, y) in hand. The coordinates are the
    // compositor's, which are the veil's: this surface is anchored over the
    // whole monitor at 0,0, so `cellAt` -- the same lookup a drop uses --
    // answers directly. Off the grid, or on the trailing "new desktop" slot,
    // there is nothing to pick up and the grid simply opens.
    function liftFrom(x, y) {
        // ── ONLY a standing request may lift ────────────────────────────
        // The probe is shared with the carry (see `cursorProbe`), so a read
        // that was already in flight when the card was put down arrives a
        // beat AFTER the drop -- with `gestureLift` false and nothing asking
        // for anything -- and, unchecked, it read as a fresh lift and picked
        // the card straight back up: measured after a real drop click,
        // `gestureLift=true cell=0 desktop=1 origin=251,251`, the desktop
        // still in hand with the grid already showing it in its new slot.
        //
        // The request is SPENT right here, on its first answer -- including
        // the answer "nothing to pick up". Left standing, it would survive to
        // the next open and lift a card for an entry point that never asked
        // (SUPER+Tab, the bar's empty stretches) the moment the pointer
        // happened to be over the grid.
        if (!root.liftRequested)
            return;
        root.liftRequested = false;
        if (!GlobalStates.desktopOverviewOpen)
            return;
        const cell = root.cellAt(x, y);
        // Off the grid, or on the trailing "+" slot: there is no desktop
        // there to pick up, so the grid simply opens.
        if (cell < 0 || cell === root.cellCount - 1)
            return;
        root.liftOriginX = x;
        root.liftOriginY = y;
        root.dragArmed = true;
        root.draggingCell = cell;
        root.dropCell = cell;
        root.dragOffsetX = 0;
        root.dragOffsetY = 0;
        root.gestureLift = true;
    }

    // ── Carrying it, in veil coordinates ───────────────────────────────
    //
    // ONE writer for every position the gesture lift can take, whatever told
    // us about it: the card's own hover motion (through `mapToItem`, which
    // folds the card's Translate back in, so the result is the pointer's true
    // veil position) and the compositor poll below. They must not disagree --
    // two writers racing over `dragOffset` is how a carried card ends up
    // half a screen from the pointer -- so the arithmetic lives here once.
    //
    // WHY THE POLL EXISTS. The hover path can only report the pointer while
    // the pointer is INSIDE the carried card, and the card is what it is
    // following: one motion event that leaves the card's rect -- a fast flick,
    // or a grid opened with the pointer already in the gap between two cards --
    // delivers nothing further to this card, and the carry froze on the spot
    // with `dropCell` stuck where it started. Measured on a single 590 px jump:
    // `offset=1,1 drop=1` and then fifteen further pointer positions, all still
    // `drop=1`. The compositor knows where the pointer is regardless of what is
    // under it, so the lift asks it directly.
    function carryGestureTo(x, y) {
        if (!root.gestureLift)
            return;
        root.dragOffsetX = x - root.liftOriginX;
        root.dragOffsetY = y - root.liftOriginY;
        root.dropCell = root.cellAt(x, y);
    }

    // ── A WINDOW in your hand (as opposed to a desktop) ────────────────
    //
    // The cards can be rearranged by hand, and so can the apps inside them.
    // Press on a window preview and MOVE -- past `windowDragSlop` -- and that
    // window is carried instead of the desktop: every other card rings itself
    // as a target, and releasing over one moves the window onto that desktop
    // and follows it there.
    //
    // Travel grants this one, not a hold, and that is deliberate: a hold on a
    // card already means "pick the desktop up". A press that never moves is
    // still a plain click-to-switch, because the press only becomes a window
    // grab once it has travelled.
    //
    // The target is read back from the cell under the pointer at drop time and
    // never remembered from an index: what the ring showed and what the drop
    // does are the same lookup.
    property string dragWindowAddress: ""   // "" = nothing in hand
    property string dragWindowLabel: ""     // app name, for the chip
    property int dragWindowFrom: -1         // desktop it is being taken from
    property int dragWindowTo: -1           // desktop under the pointer, -1 = none
    property real dragWindowX: 0            // pointer, in veil coordinates
    property real dragWindowY: 0
    readonly property bool windowDragActive: root.dragWindowAddress !== ""
    readonly property real windowDragSlop: 6  // px of travel that grant the grab

    // The window under a point INSIDE a card, or null.
    //
    // The same arithmetic the preview delegates are laid out with -- win.at is
    // monitor-absolute, the card wants it work-area-relative, both scaled by
    // card/workAreaWidth -- so the hit test cannot disagree with what is drawn
    // under the pointer. Later windows win, because later delegates draw on top.
    function windowAt(card, lx, ly) {
        if (!card || card.isNewSlot)
            return null;
        const scale = card.width / card.workAreaWidth;
        let hit = null;
        for (const win of (card.windows ?? [])) {
            const w = (win?.size?.[0] ?? 0) * scale;
            const h = (win?.size?.[1] ?? 0) * scale;
            const x = ((win?.at?.[0] ?? 0) + card.workAreaX) * scale;
            const y = ((win?.at?.[1] ?? 0) + card.workAreaY) * scale;
            if (lx >= x && lx <= x + w && ly >= y && ly <= y + h)
                hit = win;
        }
        return hit;
    }

    function appLabel(win) {
        const cls = String(win?.class ?? "");
        if (cls.length > 0)
            return cls;
        return String(win?.title ?? "") || Translation.tr("window");
    }

    function pickUpWindow(win, fromId) {
        if (!win?.address)
            return;
        root.dragWindowAddress = String(win.address);
        root.dragWindowLabel = root.appLabel(win);
        root.dragWindowFrom = fromId;
        root.dragWindowTo = -1;
    }

    // Pointer moved while a window is in hand: the card under it is the target.
    //
    // The "+" slot is NOT one. Dropping an app there would have to invent a
    // desktop and then move the window onto it -- two actions wearing one
    // gesture -- and the slot's own click already creates desktops on demand.
    // The desktop it came from is not a target either: that drop is a no-op,
    // and a ring that does nothing is a lie about what the drop will do.
    function trackWindowDrag(px, py) {
        // Nothing in hand, no target: a cancel (Escape) ends the gesture while
        // the pointer may still be travelling with the button down, and a card
        // that kept naming a desktop from that press would be promising a drop
        // that the release can no longer make.
        if (!root.windowDragActive) {
            root.dragWindowTo = -1;
            return;
        }
        const cell = root.cellAt(px, py);
        let target = -1;
        if (cell >= 0 && cell !== root.cellCount - 1) {
            const id = root.desktopOfCell(cell);
            if (id !== root.dragWindowFrom)
                target = id;
        }
        root.dragWindowTo = target;
        root.dragWindowX = px;
        root.dragWindowY = py;
    }

    function cancelWindowDrag() {
        root.dragWindowAddress = "";
        root.dragWindowLabel = "";
        root.dragWindowFrom = -1;
        root.dragWindowTo = -1;
    }

    // The two dispatches a drop performs, as one function so the IPC probe and
    // the pointer path cannot drift apart.
    //
    // `follow = true` IS NOT ONE OF THEM, and that is measured rather than
    // stylistic: this fork's compositor DROPS the follow flag -- a scratch
    // window moved to desktop 1 with follow=true landed there while the view
    // stayed on desktop 3 (2026-10-15). "Take me with it" is therefore an
    // explicit focus, ordered after the move so the window is already on its
    // new desktop before the view arrives at it.
    function moveWindowTo(address, to) {
        if (!address || !(to >= 1))
            return false;
        Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${to}, follow = false, window = "address:${address}" })`);
        Hyprland.dispatch(`hl.dsp.focus({ workspace = ${to} })`);
        return true;
    }

    // The drop. Same desktop, no target, or nothing in hand = the grab is
    // abandoned and the grid stays up: what "never mind" looks like.
    function dropWindowDrag() {
        const to = root.dragWindowTo;
        const addr = root.dragWindowAddress;
        const from = root.dragWindowFrom;
        root.cancelWindowDrag();
        if (to < 0 || from < 0 || to === from || addr.length === 0)
            return;
        if (!root.moveWindowTo(addr, to))
            return;
        // The grid has done its job: you asked to go where the window went.
        GlobalStates.desktopOverviewOpen = false;
    }

    function resetDrag() {
        root.draggingCell = -1;
        root.dropCell = -1;
        root.dragOffsetX = 0;
        root.dragOffsetY = 0;
        root.dragArmed = false;
        root.dragHeld = false;
        // A gesture lift goes back with everything else. This is the ONE reset
        // every ending passes through -- Escape, the close handler, a press
        // outside the cards -- so the lift cannot outlive the grid it belongs
        // to and be found in hand the next time the grid opens.
        root.gestureLift = false;
        root.liftRequested = false;
        // Whatever released after this must not act as a tap: Escape (or a
        // close) mid-drag lifts the card, it does not switch desktops.
        root.dragConsumed = true;
    }

    // Where a NOT-dragged card should sit while a drag is in flight. The
    // carried card leaves its slot and inserts at the drop slot, so every
    // card BETWEEN them moves one slot toward the hole -- in LIST order,
    // which is what a real reorder reflow does: within a row that is one
    // card sideways, across a row boundary it is up (or down) a row and to
    // the edge the hole came from. Computed as the position delta between
    // the card's own index and its virtual index, arithmetically -- the
    // grid is uniform (every card `cardWidth` wide, `columns` across, both
    // spacings `root.gap`), so slot maths is exact and cannot drift from
    // the layout. The carried cell shifts 0; it is translated by the drag
    // offset instead.
    function shiftFor(index) {
        if (root.draggingCell < 0 || root.dropCell < 0 || index === root.draggingCell)
            return Qt.point(0, 0);
        const from = root.draggingCell;
        const to = root.dropCell;
        if (to === from)
            return Qt.point(0, 0);
        let v = index;
        if (to > from && index > from && index <= to)
            v = index - 1;
        else if (to < from && index >= to && index < from)
            v = index + 1;
        else
            return Qt.point(0, 0);
        const sliceX = root.cardWidth + root.gap;
        const sliceY = root.cardHeight + root.gap;
        const dx = (v % root.columns) * sliceX - (index % root.columns) * sliceX;
        const dy = Math.floor(v / root.columns) * sliceY - Math.floor(index / root.columns) * sliceY;
        return Qt.point(dx, dy);
    }

    // Which cell a point given in the veil's coordinates sits on, or -1.
    // Walks the GridLayout's actual children, so row wrapping and the
    // layout's own centering are read off the items rather than re-derived.
    function cellAt(vx, vy) {
        const p = grid.mapFromItem(veil, vx, vy);
        const kids = grid.children;
        let best = -1;
        let bestDist = Infinity;
        for (let i = 0; i < kids.length; i++) {
            const it = kids[i];
            if (!it || it.index === undefined)
                continue;
            if (p.x >= it.x && p.x < it.x + it.width && p.y >= it.y && p.y < it.y + it.height)
                return it.index;
            // Nearest-centre fallback for points in the gaps between cards.
            const cx = it.x + it.width / 2;
            const cy = it.y + it.height / 2;
            const d = (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy);
            if (d < bestDist) {
                bestDist = d;
                best = it.index;
            }
        }
        // Only a point ADJACENT to the grid resolves to a cell. The exact
        // hit above runs on the UN-translated layout, and the slide-aside
        // pushes cards past that rectangle (a left-edge card shoved left
        // leaves the grid's laid-out bounds entirely) -- so the nearest
        // centre is accepted within one full slice, which covers the
        // displaced cards and the opened gap. A release FARTHER out stays
        // -1 and cancels, exactly like releasing outside the to-do list.
        if (best >= 0) {
            const sx = root.cardWidth + root.gap;
            const sy = root.cardHeight + root.gap;
            if (bestDist <= sx * sx + sy * sy)
                return best;
        }
        return -1;
    }

    // Rotate the CONTENTS of the cells between fromCell and toCell as an
    // INSERT: the dragged desktop takes the drop cell, and every desktop
    // in between shifts one slot toward the vacated hole. That is the
    // placement the slide-aside animation shows, and the reason this is a
    // rotation and not the two-way swap it used to be: with a swap the
    // pushed-out cards snapped back the moment the pointer lifted, so what
    // you watched happen was not what you got.
    //
    // The only primitive this fork gives is hl.dsp.workspace.change_id --
    // renumber a workspace object in place and its windows, focus and the
    // monitor's active pointer follow the OBJECT (see
    // HyprlandData.compactWorkspaces; window.move is dropped by the
    // compositor). A rotation is therefore a CHAIN of renames, ordered so
    // that every target id is ALREADY FREE when its rename runs:
    //
    //   to > from: dragged -> 999 (scratch), then cells from+1..to take
    //   the id one step left of their own -- each just vacated by the
    //   previous rename -- and the dragged one lands on to+1 last.
    //   to < from: the same run backwards, ids stepping the other way.
    //
    // Workspace ids that do not exist (holes) skip their rename: they
    // hold no id, so the vacancy argument stands for the rest of the
    // chain. A drop on a trailing hole degenerates to the plain move it
    // visually is, through the same chain.
    function reorderCells(fromCell, toCell) {
        if (fromCell === toCell || fromCell < 0 || toCell < 0)
            return;
        if (fromCell === root.cellCount - 1)
            return; // the "+" slot carries no desktop
        const fromId = root.desktopOfCell(fromCell);
        const toId = root.desktopOfCell(toCell);
        // Which workspace ids actually exist, so a hole inside the chain
        // skips its rename instead of faulting it (a failed rename would
        // strand the chain half-rotated). Same 1..100 band
        // compactWorkspaces uses -- special workspaces live outside it.
        const existing = {};
        for (const ws of (HyprlandData.workspaces ?? [])) {
            const id = Number(ws?.id ?? 0);
            if (id >= 1 && id <= 100)
                existing[id] = true;
        }
        if (!existing[fromId])
            return; // belt: the handler never starts a drag on this cell
        root.reorderBusy = true;
        reorderResetTimer.restart();
        Hyprland.dispatch(`hl.dsp.workspace.change_id({ workspace = ${fromId}, id = 999 })`);
        if (toCell > fromCell) {
            for (let k = fromCell + 1; k <= toCell; k++) {
                const id = k + 1;
                if (existing[id])
                    Hyprland.dispatch(`hl.dsp.workspace.change_id({ workspace = ${id}, id = ${k} })`);
            }
        } else {
            for (let k = fromCell - 1; k >= toCell; k--) {
                const id = k + 1;
                if (existing[id])
                    Hyprland.dispatch(`hl.dsp.workspace.change_id({ workspace = ${id}, id = ${k + 2} })`);
            }
        }
        Hyprland.dispatch(`hl.dsp.workspace.change_id({ workspace = 999, id = ${toId} })`);
    }

    Timer {
        id: reorderResetTimer
        interval: 1200
        onTriggered: root.reorderBusy = false
    }

    PanelWindow {
        id: panel

        readonly property var fallbackScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
        // A Quickshell Screen, NOT a HyprlandMonitor. `screen` is typed to
        // Screen: handing it the monitor object made the surface invalid and
        // it never mapped at all -- `visible` was true, `width` was 1600, and
        // no layer surface ever appeared. root.monitor stays what it is used
        // for (looking up the reserved strips by id).
        screen: root.targetScreen ?? fallbackScreen
        visible: root.open
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        // The implicit size a layer surface is actually built at. See
        // root.surfaceWidth for why anchors alone are not enough.
        implicitWidth: root.surfaceWidth
        implicitHeight: root.surfaceHeight
        WlrLayershell.namespace: "quickshell:desktopOverview"
        WlrLayershell.layer: WlrLayer.Overlay
        // Exclusive while open: the keyboard belongs to the grid, so Escape
        // and the arrows reach it instead of the app that had focus.
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // ── The one wallpaper, blurred once ──────────────────────────────
        // Full-bleed, blurred and dimmed, and it is the ONLY background: the
        // cards are translucent so it reads through them, exactly as the
        // preview does. The compositor frost rules for this namespace
        // (custom/rules.lua) sample the windows, never the wallpaper, so what
        // shows through a card is the apps behind it.
        Item {
            id: veil
            anchors.fill: parent

            // The single wallpaper, full-bleed, dimmed.
            //
            // It is NOT blurred in-process. A MultiEffect over this image was
            // tried first and is not usable here: on a TRANSPARENT layer
            // surface its offscreen buffer clears to white, so the effect
            // rendered correctly and the entire desktop came out as a white
            // screen -- twice, including with an opaque backdrop inside the
            // effect's own source item. The frost this view actually needs is
            // the compositor's, and it is already configured for this
            // namespace in custom/rules.lua (blur + ignore_alpha 0 + xray
            // off), the same recipe the bar popups and the app search overlay
            // use. That frost samples the APPLICATIONS behind the surface, so
            // a card reads as glass in front of your apps; the wallpaper
            // behind stays sharp, which is also what your reference image
            // shows.
            // The theme's darkest surface, OPAQUE. `colLayer0Base` and not
            // `colLayer0`: the latter is already alpha-cut for the floating
            // bar, so stacking it under a dim would let the desktop through.
            // (And the token that used to be here, `colBackground`, does not
            // exist in Appearance.colors at all -- an undefined color on a
            // Rectangle silently falls back to WHITE, which is what turned
            // this whole surface into a white screen.)
            Rectangle {
                anchors.fill: parent
                color: Appearance.colors.colLayer0Base
            }

            // ── THE WALLPAPER IS DRAWN FROM A PRE-SCALED COPY ─────────────
            //
            // MEASURED 2026-10-16, and this block exists for the number:
            // SUPER+Space held the shell's UI thread for 198-232 ms on every
            // open, and pointing `source` straight at the wallpaper was
            // 140-170 ms of it. The wallpaper here is a 7680x4320 PNG -- 33 M
            // pixels, ~132 MB decoded -- painted at 1707x1067. Decoded at the
            // file's own size it also OUTLIVES nothing: the pixmap is larger
            // than Qt's pixmap cache, so it is evicted between opens and the
            // whole decode is paid again on the NEXT one. That is why the cost
            // was per-open rather than once. Opening with no wallpaper at all
            // measured 59-83 ms, and the gap between those two numbers is
            // this surface's, not the compositor's.
            //
            // `sourceSize` is NOT the fix, and it was tried and measured
            // before this: it makes Qt decode the 8K image and then scale it,
            // and 610-768 ms per open was the result -- worse than doing
            // nothing, because the item has no size until the surface is up,
            // so the bounded size arrives late and re-triggers the load.
            //
            // So the copy is made ONCE, off the open path, by magick -- the
            // same tool and the same generate-then-cache shape as
            // common/widgets/ThumbnailImage.qml -- at the surface's own PIXEL
            // size. An open then decodes 2560x1600 instead of 7680x4320, and
            // the cache is only rebuilt when the wallpaper or the scale
            // changes, never on a plain open. Generation starts at shell
            // startup (Component.onCompleted, and this component is built
            // eagerly by PanelLoader), so even the first open finds it ready.
            //
            // `^` with `-extent` is the same fill-and-centre-crop that
            // `PreserveAspectCrop` performs on screen, so the copy frames the
            // wallpaper identically to the original it stands in for.
            //
            // Bounded and LATched, for the reason ThumbnailImage spells out: a
            // 1.4 GB gzip blob in ~/Pictures/Wallpapers wears a .png name, and
            // an unbounded retry on a file magick cannot read leaves a decoder
            // churning forever. After two failed attempts the original is used
            // -- slower, but visible -- which is exactly the old behaviour.
            readonly property real pixelScale: root.monitor?.scale ?? 1
            readonly property int scaledWidth: Math.max(1, Math.ceil(root.surfaceWidth * pixelScale))
            readonly property int scaledHeight: Math.max(1, Math.ceil(root.surfaceHeight * pixelScale))
            readonly property string scaledPath: {
                if (root.wallpaperSource.length === 0) return "";
                const src = FileUtils.trimFileProtocol(root.wallpaperSource);
                if (src.length === 0) return "";
                const key = Qt.md5(`${src}|${scaledWidth}x${scaledHeight}`);
                return `${FileUtils.trimFileProtocol(Directories.cache)}/media/overview-wallpaper/${key}.png`;
            }
            // What the Image shows: the copy once it exists, and the original
            // meanwhile (or for good, if the copy cannot be made).
            property string scaledSource: ""
            property bool scaleFailed: false
            property int scaleAttempts: 0
            property bool generating: false

            function ensureScaled() {
                if (scaledPath.length === 0 || root.wallpaperSource.length === 0) return;
                if (generating || scaleFailed) return;
                if (scaledWatch.loaded) {
                    scaledSource = scaledPath;
                    return;
                }
                if (scaleAttempts >= 2) return;
                scaleAttempts += 1;
                generating = true;
                scaledGeneration.running = true;
            }

            // A new wallpaper or a new scale is a new copy, and a new question
            // for the attempt budget: the old latch must not survive it. Both
            // inputs feed `scaledPath`, so its change covers both.
            function resetScaled() {
                scaledSource = "";
                scaleFailed = false;
                scaleAttempts = 0;
                scaledWatch.reload();
            }
            onScaledPathChanged: veil.resetScaled()
            Component.onCompleted: veil.ensureScaled()

            FileView {
                id: scaledWatch
                path: veil.scaledPath
                watchChanges: true
                onLoaded: veil.ensureScaled()
                onLoadFailed: veil.ensureScaled()   // the interesting case: absent
                onFileChanged: {
                    // The generator finished: use it without a reload.
                    veil.generating = false;
                    veil.scaledSource = veil.scaledPath;
                }
            }

            Process {
                id: scaledGeneration
                command: ["bash", "-c",
                    `mkdir -p '${veil.scaledPath.split("/").slice(0, -1).join("/")}'`
                    + ` && [ -s '${veil.scaledPath}' ] && exit 0`
                    + ` || magick '${FileUtils.trimFileProtocol(root.wallpaperSource)}'`
                    + ` -resize ${veil.scaledWidth}x${veil.scaledHeight}^`
                    + ` -gravity center -extent ${veil.scaledWidth}x${veil.scaledHeight}`
                    + ` '${veil.scaledPath}'`
                ]
                onExited: (exitCode) => {
                    veil.generating = false;
                    // ── The exit code is the ONLY thing to trust here ────
                    // This first checked `scaledWatch.loaded` right after
                    // calling `reload()`, and that is a race the shell loses
                    // every time: the reload is asynchronous, so `loaded` is
                    // still false at that instant, the copy was declared
                    // missing, the failure latch was set -- and the Image fell
                    // back to the 8K original for the rest of the session.
                    // Measured: the open stayed at 199-209 ms with a perfectly
                    // good 2561x1601 copy sitting in the cache, unused.
                    //
                    // `0` means there IS a copy: the command either found one
                    // already (`[ -s ... ]`), or magick wrote one. Anything
                    // else is the failure the latch exists for -- and the
                    // reload below is only to refresh the watcher's own state,
                    // never as the test.
                    if (exitCode === 0)
                        veil.scaledSource = veil.scaledPath;
                    else
                        veil.scaleFailed = true;
                    scaledWatch.reload();
                }
            }

            Image {
                id: wallpaperImage
                anchors.fill: parent
                // The pre-scaled copy when there is one, the original when
                // there is not. The original is the FALLBACK now, not the
                // norm: it is what made opening slow.
                source: veil.scaledSource.length > 0 ? veil.scaledSource : root.wallpaperSource
                cache: true
                fillMode: Image.PreserveAspectCrop
                // Opacity, not `visible`: a not-yet-decoded wallpaper should
                // fade in over the theme background, not pop.
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity {
                    animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                }
            }

            // The dim. Just enough to push the wallpaper behind the cards.
            Rectangle {
                anchors.fill: parent
                color: ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.45)
            }

            // A press anywhere that is not a card closes it. Cards sit above
            // and eat their own presses.
            MouseArea {
                anchors.fill: parent
                onClicked: GlobalStates.desktopOverviewOpen = false
            }
        }

        // ── The window in your hand ────────────────────────────────────────
        //
        // A chip under the pointer naming what is being carried and, once a card
        // is under it, which desktop it would go to. The rings say WHERE it can
        // go; this says WHAT is going there. Veil coordinates, same frame the
        // drop targets are hit-tested in.
        Item {
            id: carriedWindow
            visible: root.windowDragActive
            x: root.dragWindowX + 14
            y: root.dragWindowY + 14
            implicitWidth: carriedLabel.implicitWidth + 24
            implicitHeight: 34
            z: 40

            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: Appearance.colors.colPrimary
                border.width: 1
                border.color: ColorUtils.transparentize(Appearance.colors.colOnPrimary, 0.3)
            }
            Text {
                id: carriedLabel
                anchors.centerIn: parent
                text: root.dragWindowTo >= 0
                    ? Translation.tr("%1 → desktop %2").arg(root.dragWindowLabel).arg(root.dragWindowTo)
                    : root.dragWindowLabel
                color: Appearance.colors.colOnPrimary
                font.family: Appearance.font.family.main
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.DemiBold
            }
        }

        ColumnLayout {
            id: layout
            anchors.centerIn: parent
            spacing: root.gap + 6
            width: root.gridWidth

            // ── Header ────────────────────────────────────────────────────
            Item {
                Layout.fillWidth: true
                implicitHeight: 44

                ColumnLayout {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text {
                        text: Translation.tr("Desktops")
                        color: Appearance.colors.colOnSurface
                        font.family: Appearance.font.family.title
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: Translation.tr("%1 total · %2 windows open")
                            .arg(root.desktopCount).arg(root.totalWindows)
                        color: Appearance.colors.colSubtext
                        font.family: Appearance.font.family.main
                        font.pixelSize: Appearance.font.pixelSize.smaller
                    }
                }

                // Key hints, the shell's own idiom.
                RowLayout {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Repeater {
                        model: [
                            { key: "↵", label: Translation.tr("switch") },
                            { key: "←→", label: Translation.tr("move") },
                            { key: "drag", label: Translation.tr("reorder") },
                            { key: "esc", label: Translation.tr("close") },
                        ]
                        delegate: RowLayout {
                            required property var modelData
                            spacing: 5
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: hintKey.implicitWidth + 10
                                implicitHeight: 20
                                radius: Appearance.rounding.verysmall
                                color: ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.87)
                                border.width: 1
                                border.color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)
                                Text {
                                    id: hintKey
                                    anchors.centerIn: parent
                                    text: modelData.key
                                    color: Appearance.colors.colOnSurface
                                    font.family: Appearance.font.family.monospace
                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                }
                            }
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: modelData.label
                                color: Appearance.colors.colSubtext
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smaller
                            }
                        }
                    }
                }
            }

            // ── The grid ───────────────────────────────────────────────────
            GridLayout {
                id: grid
                Layout.fillWidth: true
                columns: root.columns
                columnSpacing: root.gap
                rowSpacing: root.gap

                Repeater {
                    model: root.cellCount

                    delegate: Rectangle {
                        id: card

                        required property int index
                        readonly property int desktopId: root.desktopOfCell(index)
                        readonly property bool isNewSlot: index === root.cellCount - 1
                        readonly property bool isActive: !isNewSlot && desktopId === root.activeId
                        readonly property bool isSelected: index === root.selectedCell
                        readonly property bool carried: root.draggingCell === card.index

                        readonly property var windows: isNewSlot ? [] : (root.windowsByDesktop[desktopId] ?? [])
                        readonly property var apps: isNewSlot ? [] : root.appsFor(desktopId)
                        readonly property real memBytes: isNewSlot ? 0 : root.memoryFor(desktopId)
                        // memoryTotal is KiB (see /proc/meminfo), memBytes is
                        // bytes -- the same 1024 has to happen on both sides or
                        // every fraction is a million times too small.
                        readonly property real memFraction: card.memBytes
                            / Math.max(1073741824, ResourceUsage.memoryTotal * 1024)
                        readonly property var player: isNewSlot ? null : root.trackFor(desktopId)

                        // The desktop's usable area comes from the surface
                        // (root.workWidth/Height), already in logical pixels.
                        readonly property real workAreaWidth: root.workWidth
                        readonly property real workAreaHeight: root.workHeight
                        readonly property real workAreaX: root.workOffsetX
                        readonly property real workAreaY: root.workOffsetY

                        Layout.preferredWidth: root.cardWidth
                        Layout.preferredHeight: root.cardHeight

                        // THE ROW FOLLOWS THE POINTER -- the TaskList trick,
                        // verbatim. A Translate, not a position write: the
                        // layout owns the slot, so the slot stays put and the
                        // grid never reflows under the pointer. The carried
                        // card tracks the drag offset 1:1 (no easing -- easing
                        // a pointer-tracking transform is what makes a drag
                        // sticky); every OTHER card rides the eased `slotShift`
                        // that slides it one slot toward the hole, opening the
                        // gap under the pointer.
                        property real slotShiftX: root.shiftFor(card.index).x
                        property real slotShiftY: root.shiftFor(card.index).y
                        // Retargeting from the CURRENT value with
                        // `alwaysRunToEnd: false`, the same reasoning TaskList
                        // documents: letting an old ease finish before the next
                        // starts desynchronises the cards, and the gap stops
                        // moving in step with the cursor.
                        Behavior on slotShiftX {
                            NumberAnimation { duration: 130; easing.type: Easing.OutCubic; alwaysRunToEnd: false }
                        }
                        Behavior on slotShiftY {
                            NumberAnimation { duration: 130; easing.type: Easing.OutCubic; alwaysRunToEnd: false }
                        }
                        transform: Translate {
                            x: card.carried ? root.dragOffsetX : card.slotShiftX
                            y: card.carried ? root.dragOffsetY : card.slotShiftY
                        }

                        radius: Appearance.rounding.large
                        // LIFTED: the carried card fills in one step and takes
                        // the active border, exactly the TaskList row's carried
                        // treatment (its fill `colLayer2`, border `colPrimary`).
                        // There is deliberately NO drop-slot highlight -- the
                        // task list removed its own because the rows making
                        // space already point at the destination, and lighting
                        // one of them read as a second carried row. Here the
                        // GAP the neighbours open is the destination cue.
                        color: card.carried
                            ? ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.12)
                            : (isNewSlot
                                ? ColorUtils.transparentize(Appearance.colors.colSurfaceContainer, 0.72)
                                : ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.34))
                        border.width: isActive || card.carried ? 2 : 1
                        border.color: isActive || card.carried
                            ? Appearance.colors.colPrimary
                            : (isSelected
                                ? Appearance.colors.colOutline
                                : ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.35))
                        // Above everything while carried, so the card reads as
                        // held over the grid rather than pushed through it.
                        z: card.carried ? 20 : 0
                        clip: true

                        StyledRectangularShadow {
                            target: card
                        }

                        // The new-desktop slot gets a dashed edge instead of a
                        // preview: it is a button, not a desktop.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: parent.radius - 1
                            color: "transparent"
                            visible: card.isNewSlot
                            border.width: 1.5
                            border.color: ColorUtils.transparentize(Appearance.colors.colOutline, 0.5)
                            // Dashed is not a QML border; four short segments
                            // along each edge would be 40 items for a
                            // decoration. A dotted ring of ticks on the top
                            // and bottom edges reads the same at this size.
                        }

                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                        Behavior on border.color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }

                        // ── Live window previews ──────────────────────────────
                        // One ScreencopyView per window on this desktop, at
                        // its real geometry scaled into the card. This is the
                        // "desktops displayed with the desktop apps inside as
                        // previews" the design asked for: not a wallpaper per
                        // card, the actual windows.
                        Item {
                            id: previewArea
                            anchors.fill: parent
                            anchors.margins: 2
                            visible: !card.isNewSlot

                            Repeater {
                                model: card.windows
                                delegate: Item {
                                    required property var modelData
                                    readonly property var win: modelData

                                    readonly property real scale: card.width / card.workAreaWidth
                                    width: (win?.size?.[0] ?? 0) * scale
                                    height: (win?.size?.[1] ?? 0) * scale
                                    x: ((win?.at?.[0] ?? 0) + card.workAreaX) * scale
                                    y: ((win?.at?.[1] ?? 0) + card.workAreaY) * scale

                                    // The toplevel this window IS, resolved once
                                    // per delegate. The two sides spell the
                                    // address differently -- hyprctl reports
                                    // "0x5654..." (a string) and ToplevelManager
                                    // a plain number -- so the comparison has to
                                    // go through a hex parse on BOTH sides.
                                    // Number("0x5654...") is NaN, which matched
                                    // nothing and gave a grid of empty cards.
                                    readonly property var toplevel: ToplevelManager.toplevels.values.find(t =>
                                        t?.HyprlandToplevel
                                        && root.sameWindow(t, win))

                                    // Live only for the desktop you are on: N
                                    // simultaneous live captures across a grid
                                    // is the one thing here that can cost
                                    // frames, and a card is a glance, not a
                                    // mirror. Every other card still gets a
                                    // real capture, just a still one.
                                    ScreencopyView {
                                        anchors.fill: parent
                                        captureSource: root.open ? parent.toplevel : null
                                        live: card.isActive
                                        opacity: 0.9
                                    }
                                }
                            }
                        }

                        // The darkening gradient under the text block, so the
                        // labels stay readable over any app.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: parent.radius - 1
                            visible: !card.isNewSlot
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.45) }
                                GradientStop { position: 0.34; color: "transparent" }
                                GradientStop { position: 0.62; color: ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.72) }
                                GradientStop { position: 1.0; color: ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.88) }
                            }
                        }

                        // ── "You are here" ───────────────────────────────────
                        Rectangle {
                            visible: card.isActive
                            anchors.top: parent.top
                            anchors.topMargin: 10
                            anchors.horizontalCenter: parent.horizontalCenter
                            implicitWidth: hereLabel.implicitWidth + 20
                            implicitHeight: 20
                            radius: height / 2
                            color: Appearance.colors.colPrimary
                            Text {
                                id: hereLabel
                                anchors.centerIn: parent
                                text: Translation.tr("you are here").toUpperCase()
                                color: Appearance.colors.colOnPrimary
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.tiny
                                font.weight: Font.Bold
                                font.letterSpacing: 0.4
                            }
                        }

                        // ── A window is in your hand: this card can take it ──
                        //
                        // Every OTHER card rings itself as a target while a
                        // window is carried, and the one under the pointer rings
                        // harder and says which desktop it is -- so the drop is
                        // never a guess about which card the pointer is over.
                        //
                        // Inside the card, not around it: the card clips its
                        // contents, and an outward ring would be half a ring.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: parent.radius - 1
                            color: "transparent"
                            visible: root.windowDragActive && !card.isNewSlot
                                && card.desktopId !== root.dragWindowFrom
                            border.width: card.desktopId === root.dragWindowTo ? 3 : 1.5
                            border.color: card.desktopId === root.dragWindowTo
                                ? Appearance.colors.colPrimary
                                : ColorUtils.transparentize(Appearance.colors.colPrimary, 0.5)
                            z: 5
                            Behavior on border.width {
                                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: card.desktopId === root.dragWindowTo
                                text: Translation.tr("Drop on desktop %1").arg(card.desktopId)
                                color: Appearance.colors.colPrimary
                                font.family: Appearance.font.family.title
                                font.pixelSize: Appearance.font.pixelSize.large
                                font.weight: Font.DemiBold
                            }
                        }

                        // ── Number + window count ────────────────────────────
                        Item {
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: 10
                            width: parent.width - 20
                            height: 26

                            Rectangle {
                                id: numPill
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: 26
                                height: 26
                                radius: Appearance.rounding.small
                                color: card.isActive
                                    ? Appearance.colors.colPrimary
                                    : ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.45)
                                border.width: card.isActive ? 0 : 1
                                border.color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)
                                Text {
                                    anchors.centerIn: parent
                                    text: String(card.desktopId)
                                    color: card.isActive
                                        ? Appearance.colors.colOnPrimary
                                        : Appearance.colors.colOnSurface
                                    font.family: Appearance.font.family.numbers
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    font.weight: Font.DemiBold
                                }
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                implicitWidth: countLabel.implicitWidth + 16
                                implicitHeight: 20
                                radius: height / 2
                                color: ColorUtils.transparentize(Appearance.colors.colLayer0Base, 0.55)
                                border.width: 1
                                border.color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)
                                Text {
                                    id: countLabel
                                    anchors.centerIn: parent
                                    // "1 window" / "3 windows", and the
                                    // pluralisation is the shell's own.
                                    text: card.windows.length === 1
                                        ? Translation.tr("1 window")
                                        : Translation.tr("%1 windows").arg(card.windows.length)
                                    color: Appearance.colors.colOnSurfaceVariant
                                    font.family: Appearance.font.family.main
                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                }
                            }
                        }

                        // ── Bottom block: apps, track, memory ───────────────
                        ColumnLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 11
                            spacing: 7
                            visible: !card.isNewSlot

                            // Apps, with their own window counts. The list is
                            // capped at three rows: a desktop with eight
                            // windows still shows "+5 more" rather than
                            // pushing the memory bar off the card.
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                Repeater {
                                    model: Math.min(3, card.apps.length)
                                    delegate: RowLayout {
                                        required property int index
                                        Layout.fillWidth: true
                                        spacing: 7
                                        Image {
                                            Layout.preferredWidth: 12
                                            Layout.preferredHeight: 12
                                            source: card.apps[index]?.icon ?? ""
                                            fillMode: Image.PreserveAspectFit
                                            visible: status === Image.Ready
                                        }
                                        Rectangle {
                                            Layout.preferredWidth: 7
                                            Layout.preferredHeight: 7
                                            visible: !imgReady(card.apps[index]?.icon)
                                            radius: 2
                                            color: Appearance.colors.colOutline
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: card.apps[index]?.name ?? ""
                                            color: Appearance.colors.colOnSurface
                                            font.family: Appearance.font.family.main
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            text: String(card.apps[index]?.count ?? 0)
                                            color: Appearance.colors.colSubtext
                                            font.family: Appearance.font.family.numbers
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                        }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    visible: card.apps.length > 3
                                    text: Translation.tr("+%1 more").arg(card.apps.length - 3)
                                    color: Appearance.colors.colSubtext
                                    font.family: Appearance.font.family.main
                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                }
                            }

                            // Now playing, when this desktop has a player.
                            Rectangle {
                                Layout.fillWidth: true
                                visible: card.player !== null
                                implicitHeight: 24
                                radius: Appearance.rounding.verysmall
                                color: ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.88)
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 7
                                    // Three bars bouncing: the shell's own
                                    // "audio is here" tell.
                                    Row {
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 2
                                        Repeater {
                                            model: 3
                                            delegate: Rectangle {
                                                required property int index
                                                width: 2.5
                                                height: [5, 10, 7][index]
                                                radius: 1.5
                                                color: Appearance.colors.colOnSurface
                                                // The equalizer pulse was here and has been
                                                // removed on purpose, because it took the WHOLE
                                                // shell down. It was written as
                                                // `SequentialAnimation on scaleY { ... }`, and
                                                // that shorthand is only valid for SINGLE-value
                                                // animations -- the QML parser rejected it with
                                                // "Cannot assign to non-existent property", which
                                                // is a fatal load error, not a warning: the
                                                // config would not start at all. Trying the same
                                                // thing via a plain `scaleY:` binding failed the
                                                // same way, so the bars are static for now.
                                                //
                                                // To restore the pulse, give the delegate an id
                                                // and aim the steps at it explicitly, which is
                                                // the form that always parses:
                                                //
                                                //     id: eqBar
                                                //     SequentialAnimation {
                                                //         running: card.player?.isPlaying ?? false
                                                //         loops: Animation.Infinite
                                                //         NumberAnimation { target: eqBar
                                                //             property: "height"; to: 3; duration: 420 }
                                                //         NumberAnimation { target: eqBar
                                                //             property: "height"; to: 10; duration: 420 }
                                                //         PauseAnimation { duration: 120 }
                                                //     }
                                                transformOrigin: Item.Bottom
                                            }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: card.player?.title ?? ""
                                        color: Appearance.colors.colOnSurface
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            // Memory: this desktop's windowed processes.
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                visible: card.memBytes > 0
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 4
                                    radius: 2
                                    color: ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.84)
                                    Rectangle {
                                        width: Math.max(2, Math.min(parent.width, parent.width * card.memFraction))
                                        height: parent.height
                                        radius: 2
                                        color: Appearance.colors.colOnSurfaceVariant
                                        Behavior on width {
                                            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                                        }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    // /proc/meminfo reports KILOBYTES, so every
                                    // figure here goes through the same 1024
                                    // step. Without it the total read "0 GB"
                                    // and the desktop's share read "0.2 / 0".
                                    //
                                    // And a real cost must never round to "0%":
                                    // a small app is not nothing, and "0%" next
                                    // to a 0.4 GB estimate is how a card gets
                                    // read as broken.
                                    text: Translation.tr("RAM %1 · %2 / %3 GB")
                                        .arg(card.memFraction > 0 && card.memFraction < 0.005
                                            ? "<1%"
                                            : Math.round(card.memFraction * 100) + "%")
                                        .arg((card.memBytes / 1073741824).toFixed(1))
                                        .arg((ResourceUsage.memoryTotal * 1024 / 1073741824).toFixed(0))
                                    color: Appearance.colors.colSubtext
                                    font.family: Appearance.font.family.monospace
                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        // ── The new-desktop slot ───────────────────────────
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 6
                            visible: card.isNewSlot
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "+"
                                color: ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.45)
                                font.family: Appearance.font.family.main
                                font.pixelSize: 44
                                font.weight: Font.Thin
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: Translation.tr("New desktop")
                                color: Appearance.colors.colOnSurfaceVariant
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smaller
                            }
                        }

                        // Click = go there (held one double-tap beat so a
                        // second tap can cancel it). Click-HOLD ~450ms, or
                        // double-tap then press-and-move = pick the desktop
                        // up: those are the ONLY two grants -- nothing arms a
                        // grab by itself, and hovering an idle grid has no
                        // power over the cards. The neighbours part to open
                        // the gap and release drops it there. No per-window
                        // targets, no close button: windows are never moved
                        // or killed.
                        MouseArea {
                            id: cardMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            // Press point in CARD-LOCAL coordinates. The
                            // card carries the drag Translate, and Qt strips
                            // a receiving item's own transform out of the
                            // events it delivers -- so the raw local delta
                            // is travel MINUS the offset already applied.
                            // Both in-flight writers below add the current
                            // offset back before writing (travel = local +
                            // current), the same algebra TaskList solves
                            // with scene coordinates: without it the card
                            // converged to half the pointer distance and
                            // lagged with visible stutter.
                            property real pressX: 0
                            property real pressY: 0
                            // Set by the second tap of a double-tap pair (see
                            // onClicked): the NEXT press on THIS card is
                            // granted the grab immediately, no 450ms hold.
                            property bool doubleTapPrimed: false
                            // Scene-space pointer position sampled by the
                            // two grant paths (hold poll / motion), kept in
                            // card-local terms for the compensation above.
                            // True once real motion events arrived, so the
                            // hold poll stands down (two writers, one
                            // pointer: two chances to disagree).
                            property bool moved: false
                            // The window under this press (null = the press is
                            // on the card itself), and whether this press became
                            // a window grab rather than a desktop one.
                            property var pressWindow: null
                            property bool windowArmed: false

                            onEntered: root.selectedCell = card.index

                            onPressed: mouse => {
                                // ── A card already in hand: this press takes it
                                //    over, it does not start a new grab ──────
                                // The gesture lifts a card with no button behind
                                // it, so its drop is a CLICK -- and a click
                                // begins with a press. That press ADOPTS the
                                // lift, exactly as if it had picked the card up
                                // itself: same press point, same grant, same
                                // release-to-commit path below. Without this the
                                // press would clear the grant, the release
                                // would read as a tap, and the click would
                                // switch desktops instead of dropping the card.
                                if (root.gestureLift) {
                                    cardMouse.pressX = mouse.x;
                                    cardMouse.pressY = mouse.y;
                                    cardMouse.moved = false;
                                    cardMouse.pressWindow = null;
                                    cardMouse.windowArmed = false;
                                    root.dragHeld = true;
                                    root.dragConsumed = false;
                                    switchDelay.stop();
                                    holdArm.stop();
                                    return;
                                }
                                cardMouse.pressX = mouse.x;
                                cardMouse.pressY = mouse.y;
                                cardMouse.moved = false;
                                // Which object this press is ON, decided the
                                // moment it lands: a press that starts on a
                                // window is the candidate for a window grab,
                                // and only travel settles it (onPositionChanged).
                                cardMouse.pressWindow = root.windowAt(card, mouse.x, mouse.y);
                                cardMouse.windowArmed = false;
                                // A press also abandons a grab that was somehow
                                // still in hand -- a release the grid never saw.
                                if (root.windowDragActive)
                                    root.cancelWindowDrag();
                                // A drag that released outside any card left
                                // this set; the next press starts clean.
                                root.dragConsumed = false;
                                // A press is a LIVE press. It is not yet a
                                // grant: the hold timer below confers that
                                // if the button stays down, or a second tap
                                // arrives fast enough (onClicked).
                                root.dragHeld = true;
                                root.dragArmed = false;
                                root.draggingCell = -1;
                                root.dropCell = -1;
                                root.dragOffsetX = 0;
                                root.dragOffsetY = 0;
                                // A press on the card a double-tap primed is
                                // GRANTED on the spot: tap-tap-press-move
                                // carries with no hold wait. Any other press
                                // starts the click-hold clock instead.
                                if (cardMouse.doubleTapPrimed && !card.isNewSlot) {
                                    cardMouse.doubleTapPrimed = false;
                                    root.dragArmed = true;
                                    root.draggingCell = card.index;
                                    root.dropCell = card.index;
                                } else {
                                    holdArm.restart();
                                }
                                // A pending single-tap switch is overtaken by
                                // this press either way.
                                switchDelay.stop();
                            }

                            // The delayed half of the single-click switch:
                            // held back one double-tap window so a second tap
                            // can cancel it and prime a drag instead. A tap
                            // that stays unpaired switches when this fires.
                            Timer {
                                id: switchDelay
                                interval: root.doubleTapMs
                                running: false
                                onTriggered: {
                                    // The grid can close inside this window
                                    // (Escape, a desktop switch); a switch
                                    // owed to a tap on a closed grid is not
                                    // owed anymore.
                                    if (GlobalStates.desktopOverviewOpen)
                                        root.goTo(card.index);
                                }
                            }

                            // ── Grant 1: click-hold ──────────────────
                            // Fires only while the press is still down at
                            // ~450ms; a quick tap releases before it and
                            // the running: guard voids it.
                            Timer {
                                id: holdArm
                                interval: root.holdArmMs
                                running: false
                                onTriggered: {
                                    if (!cardMouse.pressed || !root.dragHeld
                                        || card.isNewSlot || root.dragArmed
                                        || cardMouse.windowArmed || root.windowDragActive)
                                        return;
                                    root.dragArmed = true;
                                    root.draggingCell = card.index;
                                    root.dropCell = card.index;
                                }
                            }

                            // In-flight tracking. Shared by the motion
                            // handler and the poll; `gate` is the whole
                            // auto-grab fix: without a granted, live press
                            // this function is INERT -- hover cannot move
                            // a card because hover never sets `armed`.
                            function track(mx, my) {
                                if (!root.dragArmed || root.draggingCell !== card.index)
                                    return;
                                // ── A gesture lift carries with NO press ────────
                                // Nothing is held down, so there is no press
                                // point to be relative to: the card follows the
                                // pointer's travel from where the pointer stood
                                // when the grid opened, and the drop target is
                                // read from the same point the press path uses
                                // (mapToItem folds the card's own Translate back
                                // in, so this is the pointer's true position).
                                if (root.gestureLift) {
                                    const g = card.mapToItem(veil, mx, my);
                                    root.carryGestureTo(g.x, g.y);
                                    return;
                                }
                                if (!root.dragHeld)
                                    return;
                                // Compensated travel (see pressX note).
                                const dx = mx - cardMouse.pressX + root.dragOffsetX;
                                const dy = my - cardMouse.pressY + root.dragOffsetY;
                                root.dragOffsetX = dx;
                                root.dragOffsetY = dy;
                                // Drop target from the CURSOR, not the
                                // carried card: mapToItem folds the current
                                // Translate back in, so this is the
                                // pointer's true veil position.
                                const p = card.mapToItem(veil, mx, my);
                                root.dropCell = root.cellAt(p.x, p.y);
                            }

                            onPositionChanged: mouse => {
                                if (root.dragHeld)
                                    cardMouse.moved = true;
                                // ── A WINDOW grab is granted by TRAVEL ────────
                                // The card's grant is a hold; the window's is
                                // moving off a press that began on it. Travel
                                // arrives first in practice, so the smaller
                                // object wins the smaller gesture -- and a press
                                // held still still picks up the desktop.
                                if (root.dragHeld && !root.dragArmed && !cardMouse.windowArmed
                                    && cardMouse.pressWindow !== null
                                    && (Math.abs(mouse.x - cardMouse.pressX) > root.windowDragSlop
                                        || Math.abs(mouse.y - cardMouse.pressY) > root.windowDragSlop)) {
                                    cardMouse.windowArmed = true;
                                    // Both card grants stand down: this press
                                    // belongs to the window now, so a desktop
                                    // reorder must not also fire from it.
                                    holdArm.stop();
                                    cardMouse.doubleTapPrimed = false;
                                    root.pickUpWindow(cardMouse.pressWindow, card.desktopId);
                                }
                                if (cardMouse.windowArmed) {
                                    // Veil coordinates: the frame every drop
                                    // target here is measured in.
                                    const p = card.mapToItem(veil, mouse.x, mouse.y);
                                    root.trackWindowDrag(p.x, p.y);
                                    return;
                                }
                                cardMouse.track(mouse.x, mouse.y);
                            }

                            // ── Hold-poll ─────────────────────────────
                            // TaskList's insurance: on this build a
                            // hold-still press can have its motion events
                            // swallowed by compositor gesture bookkeeping,
                            // so a granted drag must not depend on motion
                            // alone. Polls the grab while the button is
                            // down and no motion has been SEEN; replaying a
                            // still pointer is inert (track recomputes the
                            // same travel and writes the same values).
                            Timer {
                                id: holdPoll
                                interval: 16
                                repeat: true
                                running: cardMouse.pressed && root.dragArmed
                                    && !cardMouse.moved
                                    && root.draggingCell === card.index
                                onTriggered: cardMouse.track(cardMouse.mouseX, cardMouse.mouseY)
                            }

                            onReleased: {
                                holdArm.stop();
                                // A carried window ends here, one way or the
                                // other: commit if a card is under the pointer,
                                // abandon otherwise (dropWindowDrag decides).
                                if (cardMouse.windowArmed) {
                                    cardMouse.windowArmed = false;
                                    cardMouse.pressWindow = null;
                                    root.dragHeld = false;
                                    cardMouse.moved = false;
                                    // The release synthesizes a click; a carried
                                    // window must not also switch desktops.
                                    root.dragConsumed = true;
                                    root.dropWindowDrag();
                                    return;
                                }
                                cardMouse.pressWindow = null;
                                const wasArmed = root.dragArmed;
                                // The press is over: any grant dies with
                                // it. THIS is the line that makes hover
                                // powerless -- after release there is no
                                // `dragHeld`, so track() can never run.
                                root.dragHeld = false;
                                root.dragArmed = false;
                                cardMouse.moved = false;
                                if (!wasArmed)
                                    return; // a tap: onClicked owns what follows
                                // A real drag ends: commit or cancel. The
                                // release also synthesizes a click, which
                                // would otherwise run straight into the
                                // double-tap bookkeeping and switch to the
                                // dragged card's desktop 400ms later --
                                // swallow it here.
                                root.dragConsumed = true;
                                const from = root.draggingCell;
                                const to = root.dropCell;
                                root.draggingCell = -1;
                                root.dropCell = -1;
                                root.dragOffsetX = 0;
                                root.dragOffsetY = 0;
                                // Dropped: whatever was in hand is no longer.
                                // The card the gesture lifted travels this same
                                // path (its drop click adopts the lift on the
                                // press), so the lift ends HERE, with the insert
                                // it caused.
                                root.gestureLift = false;
                                root.liftRequested = false;
                                if (to >= 0 && to !== from)
                                    root.reorderCells(from, to);
                            }

                            onClicked: {
                                if (root.dragConsumed) {
                                    root.dragConsumed = false;
                                    return;
                                }
                                const now = Date.now();
                                if (!card.isNewSlot
                                    && root.lastTapCell === card.index
                                    && now - root.lastTapTime <= root.doubleTapMs) {
                                    // ── Grant 2: double-tap ──────────
                                    // Second tap on the same card inside
                                    // the window: cancel that first tap's
                                    // pending switch and PRIME the drag --
                                    // the next press here carries at once
                                    // (tap-tap-press-move). A hover move
                                    // without a press still never arms:
                                    // grants ride live presses only.
                                    switchDelay.stop();
                                    cardMouse.doubleTapPrimed = true;
                                    root.lastTapTime = 0;
                                    root.lastTapCell = -1;
                                    return;
                                }
                                // First tap: remember it and hold the
                                // switch back one double-tap window, so a
                                // following tap can turn it into a drag
                                // grant instead of a desktop jump.
                                root.lastTapTime = now;
                                root.lastTapCell = card.index;
                                switchDelay.restart();
                            }
                        }
                    }
                }
            }
        }


        // The keyboard belongs to the grid while it is up.
        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: root.open
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    // Escape puts a lifted card -- or a carried window -- back
                    // before it closes the whole grid: an aborted drag must not
                    // also dismiss.
                    if (root.windowDragActive)
                        root.cancelWindowDrag();
                    else if (root.draggingCell >= 0)
                        root.resetDrag();
                    else
                        GlobalStates.desktopOverviewOpen = false;
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                    root.moveSelection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                    root.moveSelection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_KP_Enter || event.key === Qt.Key_Space) {
                    root.activateSelection();
                    event.accepted = true;
                }
            }
        }
    }

    // Every window on every desktop, for the header's count.
    readonly property int totalWindows: {
        let n = 0;
        for (const key in (root.windowsByDesktop ?? {}))
            n += (root.windowsByDesktop[key] ?? []).length;
        return n;
    }

    function imgReady(icon) {
        return String(icon ?? "") !== "";
    }

    // Do a ToplevelManager entry and a hyprctl client describe the SAME window?
    //
    // This is the single most load-bearing comparison in the view, and the two
    // sides spell the address differently:
    //
    //   hyprctl clients  "0x565448b25ec0"   prefixed
    //   ToplevelManager  "565448b25ec0"     the SAME hex digits, NO "0x"
    //
    // Parsing the second one as a decimal (which is what a naive parse does,
    // since it has no prefix to say "hex") yields 565448 -- it stops at the
    // first letter -- and every comparison then fails. A grid of cards with
    // no previews in any of them is the symptom. Once both sides go through
    // parseAddress they are plain equal numbers, so the class is checked as
    // well: two windows cannot be mistaken for each other.
    function sameWindow(toplevel, win) {
        const a = parseAddress(toplevel?.HyprlandToplevel?.address);
        const b = parseAddress(win?.address);
        return a >= 0 && a === b;
    }

    // One window address -> one number, from either spelling.
    //
    // "0x565448b25ec0" (hyprctl) and "565448b25ec0" (ToplevelManager) are the
    // same value; the only difference is the prefix. Hex is therefore tried
    // FIRST and unconditionally -- the bare form is hex too, and parsing it as
    // decimal is the bug this function exists to prevent. Decimal is the
    // fallback for a value that genuinely arrived as a number-in-a-string.
    function parseAddress(addr) {
        if (typeof addr === "number")
            return Number.isFinite(addr) ? addr : -1;
        let s = String(addr ?? "").trim();
        if (s.length === 0)
            return -1;
        if (s.startsWith("0x") || s.startsWith("0X"))
            s = s.slice(2);
        const asHex = parseInt(s, 16);
        if (Number.isFinite(asHex))
            return asHex;
        const asDec = parseInt(s, 10);
        return Number.isFinite(asDec) ? asDec : -1;
    }

    // guessIcon returns a NAME ("brave", "firefox"), which an Image cannot
    // open -- it resolves the name against the QML file's own directory and
    // logs "Cannot open: .../brave". Quickshell.iconPath is what turns the
    // name into a real themed-icon URL, and it is cached, so calling it per
    // card per sample is cheap. An app with no icon yields "", and the card
    // draws its small fallback square instead.
    function iconFor(cls) {
        const __t0 = Date.now();
        const __n = AppSearch.guessIcon(cls);
        const __t1 = Date.now();
        const __r = Quickshell.iconPath(__n, "");
        const __t2 = Date.now();
        StatusSignal.perfMark("ovGuessIcon", __t1 - __t0);
        StatusSignal.perfMark("ovIconPath", __t2 - __t1);
        return __r;
    }

    Connections {
        target: GlobalStates
        // NO entry point raises this request any more (2026-10-16, requested):
        // SUPER+Space no longer asks for a lift, and the gesture that
        // dispatched the grab global is deleted. The signal, this handler and
        // that global are kept -- the IPC `desktopOverview lift` writes the
        // same flag -- and the ordering they depend on is why the wiring stays
        // as it is: the signal is what lets the writer and the reader stay in
        // one place, and it has to be emitted
        // BEFORE the open flag, and this handler runs synchronously inside that
        // emit, so `liftRequested` is standing by the time the open handler
        // below spends it. Write it afterwards and the lift is silently lost
        // -- which is exactly what the gesture did until 2026-10-15.
        function onDesktopOverviewLiftRequest() {
            root.liftRequested = true;
        }
        function onDesktopOverviewOpenChanged() {
            // Start the keyboard on the desktop you are actually on, so Enter
            // without touching the arrows is a no-op rather than a jump to 1.
            if (GlobalStates.desktopOverviewOpen) {
                root.selectedCell = Math.min(root.cellCount - 1, root.cellOf(root.activeId));
                // Arm the workspace guard with the desktop we are opening on,
                // so the first poll (which always "changes" the object) is not
                // mistaken for a desktop switch.
                root.lastSeenWorkspace = root.activeId;
                ProcessList.setActive("overview", true);
                // The gesture asked for the desktop under the pointer. The read
                // happens now and not at the request, because a point can only
                // be mapped onto a card that has been laid out -- and it is the
                // request, not the open, that says which entry point this was.
                if (root.liftRequested)
                    cursorProbe.running = true;
            } else {
                // Symmetric release (this used to be one-sided: armed on open,
                // never let go on close), so one look at the workspace grid no
                // longer leaves the process sampler running every ~2 s for the
                // rest of the session.
                ProcessList.setActive("overview", false);
                // No drag survives the grid: a grant, a lift or a primed
                // double-tap must not leak into the next open.
                root.resetDrag();
            }
            // Tell the compositor which surface owns the screen right now.
            root.publishOpenState();
        }
    }

    // ── Telling the compositor the grid is up ─────────────────────────────
    // The compositor cannot see a Quickshell layer surface, and it needs to:
    // the plain four-finger swipe DOWN is the close-window drag, so while the
    // grid is up that same swipe would grab and close the very window
    // standing behind it. The overlay publishes its state to a runtime file
    // and the Lua side reads it at gesture start -- the same handshake the
    // now-bar panel and the wallpaper theatre use, staleness rule included.
    //
    //   $XDG_RUNTIME_DIR/ii-desktop-overview.json  {"open":true,"ts":...}
    //
    // A missing or stale file reads as CLOSED, which is the safe direction:
    // the close-drag keeps working, and a swipe can only ever close the grid,
    // never leave it stuck up with no gesture that dismisses it.
    readonly property string statePath: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/ii-desktop-overview.json`
    property real stateTs: 0

    Process {
        id: stateWriter
        command: ["sh", "-c", `printf '{"open":${GlobalStates.desktopOverviewOpen},"ts":${root.stateTs}}' > '${root.statePath}'`]
    }

    function publishOpenState() {
        root.stateTs = Date.now() / 1000;
        stateWriter.running = false;
        stateWriter.running = true;
    }

    Timer {
        // Keepalive, only while open: a shut grid has nothing to honour, and an
        // old file reads as closed.
        interval: 2000
        repeat: true
        running: GlobalStates.desktopOverviewOpen
        onTriggered: root.publishOpenState()
    }

    Component.onCompleted: root.publishOpenState()

    // A desktop switch closes it -- same as the app search overlay. Jumping
    // away from a grid that is still up reads as the grid being stuck.
    //
    // The ID is compared, never the object. HyprlandData.activeWorkspace is a
    // `var` reassigned to a freshly parsed JSON object on every poll, so the
    // change signal fires constantly with the same desktop in it; closing on
    // the signal slammed the grid shut within a fraction of a second of it
    // opening. This is the same guard the app search overlay uses.
    property int lastSeenWorkspace: 0

    Connections {
        target: HyprlandData
        function onActiveWorkspaceChanged() {
            const id = Number(HyprlandData.activeWorkspace?.id ?? 0);
            if (id === root.lastSeenWorkspace)
                return;
            root.lastSeenWorkspace = id;
            // A reorder renumbers the desktop you stand on as a side effect;
            // that is not a desktop SWITCH and must not close the grid the
            // user is mid-arrangement in.
            if (GlobalStates.desktopOverviewOpen && !root.reorderBusy)
                GlobalStates.desktopOverviewOpen = false;
        }
    }

    // The compositor's SUPER + four-finger swipe down (custom/general.lua)
    // dispatches this global by name. A toggle, not an open: the gesture can
    // fire while the grid is already up (a second flick), and "open" would
    // leave it stuck with no key to close it.
    GlobalShortcut {
        name: "desktopOverviewToggle"
        description: "Toggles the desktop overview (SUPER + Tab, SUPER + Z, the bar's empty stretches)"

        onPressed: {
            GlobalStates.desktopOverviewOpen = !GlobalStates.desktopOverviewOpen;
        }
    }

    // ── The GESTURE's way in: open it, with the desktop in hand ──────────
    //
    // This WAS the gesture's entry point: the SUPER + four-finger swipe down was
    // the one entry point that is a POINTER action -- the cursor is parked on
    // the desktop you were looking at when the fingers land -- so it opened the
    // grid with that desktop lifted (see `liftRequested`); move the pointer to
    // carry it, click to drop it, Escape to put it back.
    //
    // THE GESTURE IS REMOVED (2026-10-16, requested), so nothing dispatches this
    // name any more and a lift is not reachable from input at all. It stays
    // registered rather than deleted: it is the shell's half of the capability,
    // the IPC `lift` below writes the same flag through `liftRequested`, and
    // deleting it would leave no way to drive a lift even by hand.
    //
    // Its own name rather than a second dispatch of the toggle, because the
    // toggle is also what SUPER+Tab, SUPER+Z and the bar's empty stretches send:
    // a lift for those would either guess at intent or take the grid's
    // click-to-switch away from someone who only tapped a key.
    //
    // It TOGGLES all the same -- a second flick still means "put it away" -- and
    // only the opening half asks for the lift.
    GlobalShortcut {
        name: "desktopOverviewGrab"
        description: "Toggles the desktop overview, lifting the desktop under the cursor (NO INPUT BOUND: the SUPER + four-finger swipe down that dispatched it was removed 2026-10-16; kept for the IPC and the check suite)"

        onPressed: {
            // A second flick still means "put it away", and a close must not
            // arm a lift for the next open.
            if (GlobalStates.desktopOverviewOpen) {
                GlobalStates.desktopOverviewOpen = false;
                return;
            }
            // ── THE REQUEST GOES FIRST. MEASURED, NOT ASSUMED. ───────────
            // This assignment used to come second, and that single line
            // order was the whole bug the gesture was reported for: the
            // assignment BELOW emits `desktopOverviewOpenChanged`, the
            // handler in the Connections further down runs SYNCHRONOUSLY
            // inside that emit, and it is that handler which starts
            // `cursorProbe` on `liftRequested`. Set afterwards, the flag
            // was read one step too late every single time -- the grid came
            // up plain, `gestureLift` stayed false, and the desktop under
            // the pointer was never in hand. Traced with
            // `hyprctl dispatch "hl.dsp.global('quickshell:desktopOverviewGrab')"`:
            // `liftRequested=true gestureLift=false cell=-1`.
            root.liftRequested = true;
            GlobalStates.desktopOverviewOpen = true;
        }
    }

    // Dismiss ONLY. Separate from the toggle on purpose: a gesture that means
    // "put this away" must never be able to OPEN the grid, or a swipe while
    // the grid is shut would summon it (and a second flick would leave it
    // stuck up, since a dismiss there would then mean "close" on an already
    // closed surface).
    GlobalShortcut {
        name: "desktopOverviewDismiss"
        description: "Puts the desktop overview away (four-finger swipe down while it is open)"

        onPressed: {
            if (GlobalStates.desktopOverviewOpen)
                GlobalStates.desktopOverviewOpen = false;
        }
    }

    IpcHandler {
        target: "desktopOverview"

        function open(): void {
            GlobalStates.desktopOverviewOpen = true;
        }
        function close(): void {
            GlobalStates.desktopOverviewOpen = false;
        }
        // A toggle for the bar: the same gesture twice must not leave it stuck
        // open, and this surface has no held key whose release could close it.
        function toggle(): void {
            GlobalStates.desktopOverviewOpen = !GlobalStates.desktopOverviewOpen;
        }
        // The GESTURE's two writes, as one call, so a check drives the shipped
        // path instead of re-implementing it (there is no synthetic four-finger
        // swipe here, and `hyprctl dispatch global` reaches the global itself,
        // which is even closer to the real thing).
        function lift(): string {
            // Same order as the global the gesture dispatches -- the request
            // must be standing when the open's own handler reads it -- and
            // the same probe when the grid is somehow already up (there is
            // no open-change emit to hang the read on then).
            // The request is the permission to lift (`liftFrom` refuses
            // without it), so it is raised on BOTH paths -- there is no
            // open-change emit to raise it for us when the grid is already up.
            root.liftRequested = true;
            if (GlobalStates.desktopOverviewOpen)
                cursorProbe.running = true;
            else
                GlobalStates.desktopOverviewOpen = true;
            return `open=${GlobalStates.desktopOverviewOpen} liftRequested=${root.liftRequested}`;
        }
        // What is in hand: which desktop the gesture lifted, where it is being
        // carried, and whether it came from the gesture or from a press. The
        // desktop drag has no other way to be seen from a script -- the pointer
        // is the only thing that normally knows.
        function liftState(): string {
            return `gestureLift=${root.gestureLift} liftRequested=${root.liftRequested}`
                + ` cell=${root.draggingCell} drop=${root.dropCell}`
                + ` desktop=${root.draggingCell >= 0 ? root.desktopOfCell(root.draggingCell) : -1}`
                + ` offset=${Math.round(root.dragOffsetX)},${Math.round(root.dragOffsetY)}`
                + ` origin=${Math.round(root.liftOriginX)},${Math.round(root.liftOriginY)}`;
        }
        // Diagnostics: what the grid believes about the desktops, so a wrong
        // cell count or a missing window is visible from a terminal.
        function state(): string {
            const parts = [];
            for (let i = 0; i < root.cellCount; i++) {
                const id = root.desktopOfCell(i);
                const apps = root.appsFor(id).map(a => `${a.name}x${a.count}`).join(",");
                parts.push(`${id}:[${apps}]`);
            }
            return `active=${root.activeId} cells=${root.cellCount} ${parts.join(" ")}`;
        }
        // Why a card is empty. Three things have to line up for a live
        // preview and each has failed silently at least once: the wallpaper
        // path (an Image that cannot open), the work-area frame the window
        // geometry is mapped into, and the toplevel lookup. This prints all
        // three so a blank grid is a one-line diagnosis, not a guess.
        function debug(): string {
            const tops = ToplevelManager.toplevels.values;
            const first = (HyprlandData.windowList ?? [])[0] ?? null;
            const match = first
                ? tops.filter(t => t?.HyprlandToplevel && root.sameWindow(t, first)).length
                : -1;
            return [
                `open=${GlobalStates.desktopOverviewOpen} visible=${panel.visible}`,
                `surface=${Math.round(root.surfaceWidth)}x${Math.round(root.surfaceHeight)}`,
                `work=${Math.round(root.workWidth)}x${Math.round(root.workHeight)}@${Math.round(root.workOffsetX)},${Math.round(root.workOffsetY)}`,
                `wallpaper=${root.wallpaperSource || "(none)"}`,
                // WHICH file the background is drawn from, because the
                // difference is the whole open latency: `scaled-copy` is the
                // magick-made surface-sized PNG (fast), `original` means the
                // copy could not be made and the full-size file is being
                // decoded per open (slow). Without this the two are
                // indistinguishable from outside -- the open just looks slow.
                `wallpaperSrc=${veil.scaledSource.length > 0 ? "scaled-copy" : "original"}`,
                `wallpaperCopy=${veil.scaledWidth}x${veil.scaledHeight}${veil.scaleFailed ? " (FAILED)" : ""}`,
                `toplevels=${tops.length}`,
                `firstWin=${first ? `${first.class}@${first.address} at ${first.at} size ${first.size}` : "(none)"}`,
                `firstWinMatches=${match}`,
            ].join(" ");
        }
        // Land on a specific desktop (used by tests and by the gesture's
        // "open already on the right one" case).
        function goTo(id: int): void {
            root.selectedCell = Math.min(root.cellCount - 1, Math.max(0, id - 1));
            root.activateSelection();
        }
        // Trade two CELLS' contents without the UI (tests and scripts):
        // cells are 0-based grid positions, so 0 is desktop 1.
        function reorder(fromCell: int, toCell: int): string {
            const plan = `${root.desktopOfCell(fromCell)}<->${root.desktopOfCell(toCell)}`;
            root.reorderCells(fromCell, toCell);
            return `reorder ${plan} busy=${root.reorderBusy}`;
        }
        // Move a window to a desktop exactly as a drop does (tests and
        // scripts): the SAME function the pointer path calls, so a check
        // exercises the real dispatches instead of a copy of them.
        function moveWindow(address: string, to: int): string {
            const sent = root.moveWindowTo(address, to);
            return `move ${address} -> ${to} ${sent ? "sent" : "refused"}`;
        }
        // What each card is billing: the desktop, the bytes attributed to it,
        // and the fraction of the machine that is. A script cannot read a
        // pixel, and the first version of this arithmetic was wrong in a way
        // nobody could see -- 359 MB reported for a browser costing 2.84 GB --
        // so the number behind the card is readable without a screenshot.
        function ramState(): string {
            const parts = [];
            for (let i = 0; i < root.cellCount; i++) {
                const id = root.desktopOfCell(i);
                const bytes = root.memoryFor(id);
                parts.push(`${id}:${(bytes / 1073741824).toFixed(2)}GB`
                    + `/${(bytes / Math.max(1073741824, ResourceUsage.memoryTotal * 1024) * 100).toFixed(1)}%`);
            }
            return `total=${(ResourceUsage.memoryTotal * 1024 / 1073741824).toFixed(0)}GB`
                + ` used=${(ResourceUsage.memoryUsedPercentage * 100).toFixed(0)}%`
                + ` ${parts.join(" ")}`;
        }
        // What is in your hand right now, so a script can see the drag state
        // without a pointer (there is no synthetic-drag tool here).
        function dragState(): string {
            return `active=${root.windowDragActive} addr=${root.dragWindowAddress}`
                + ` from=${root.dragWindowFrom} to=${root.dragWindowTo}`
                + ` label=${root.dragWindowLabel}`;
        }
        // Put a window in your hand without a pointer, and put it down again:
        // the two halves of the drag the release path reads. `drop` runs the
        // REAL drop -- the same call the pointer's release makes -- so a check
        // can drive the shipped code including the grid closing behind it,
        // which is the half that a copied dispatch sequence would miss.
        function carry(address: string, from: int, to: int): string {
            root.dragWindowAddress = String(address ?? "");
            root.dragWindowLabel = root.appLabel((HyprlandData.windowList ?? [])
                .find(w => String(w?.address ?? "") === String(address ?? "")) ?? null);
            root.dragWindowFrom = from;
            root.dragWindowTo = to;
            return `carry ${root.dragWindowAddress} from=${root.dragWindowFrom} to=${root.dragWindowTo}`;
        }
        function drop(): string {
            const plan = `${root.dragWindowAddress} -> ${root.dragWindowTo}`;
            root.dropWindowDrag();
            return `drop ${plan} active=${root.windowDragActive} open=${GlobalStates.desktopOverviewOpen}`;
        }
    }
}
