import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
pragma Singleton
pragma ComponentBehavior: Bound

Singleton {
    id: root

    // ═══ Sidebar open state, for the compositor's 3-finger gestures ═══════
    //
    // The compositor owns libinput and therefore every multi-finger gesture,
    // but it cannot see a Quickshell layer surface: there is no way for it to
    // ask "is a sidebar open right now". So the shell publishes the one bit it
    // knows and the gesture reads it, exactly like the island's hover
    // handshake (see NowBar.qml -> ii-nowbar-hover.json):
    //
    //   $XDG_RUNTIME_DIR/ii-sidebar-state.json
    //     {"left":true,"right":false,"ts":1756...}
    //
    // A three-finger swipe TOWARDS an open sidebar closes it (left sidebar
    // closes on a swipe left, right sidebar on a swipe right) instead of
    // reaching the window underneath -- see custom/general.lua, where the
    // sidebar branch returns before FIELD_SWIPE can act on a window that is
    // behind a sidebar the user cannot see.
    //
    // The reader treats the file as stale after 10s, so a crashed shell can
    // never leave a dead "left":true pinning the gesture: with no fresh file
    // the sidebars read as closed and the swipes fall through to the window
    // actions, which is the correct default.
    readonly property string sidebarStatePath:
        `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/ii-sidebar-state.json`
    property real sidebarStateTs: 0

    function publishSidebarState() {
        root.sidebarStateTs = Date.now() / 1000;
        sidebarStateWriter.running = false;
        sidebarStateWriter.running = true;
    }

    Process {
        id: sidebarStateWriter
        // One shot per publish; the file is two booleans and a timestamp, and
        // `>` truncate+write is atomic enough for a reader that wants one line.
        command: ["sh", "-c",
            `printf '{"left":${root.sidebarLeftOpen},"right":${root.sidebarRightOpen},"ts":${root.sidebarStateTs}}' > '${root.sidebarStatePath}'`]
    }

    //
    // A Quickshell singleton is constructed lazily, the first time something
    // reads it, and `Component.onCompleted` fires from inside that
    // construction -- before the rest of this object is live. A `Process`
    // told to run there is dropped without a word: the spawn is silently
    // skipped and the file never appears. (Proved both halves: shell.qml DOES
    // create this singleton at startup, and the identical
    // `publishSidebarState()` called later from an IPC handler writes the file
    // every single time. The island's hover publisher gets away with running
    // inline because its component is built as part of a visible panel, not on
    // demand from a function.)
    // The heartbeat. Always running for as long as this singleton exists, at
    // an interval comfortably inside the reader's 10s staleness window.
    //
    // It replaces a one-shot "publish once at startup" timer, which was wrong
    // in a way worth recording: a Quickshell singleton is created lazily, and
    // on a hot reload of THIS file the whole object is rebuilt -- the new
    // instance's `Component.onCompleted` fires, but the shell that originally
    // asked for the first publish (shell.qml) is not reloaded, so nothing ever
    // re-armed it and the file silently stopped existing. A repeating timer
    // cannot be left behind that way: whatever creates the singleton, or
    // rebuilds it, it is publishing again within one interval.
    //
    // Cost is one `sh` doing a printf every 3s, and the singleton only exists
    // at all once something reads it (a sidebar opening, or a desktop-edit
    // request) -- so this is not a cost the shell pays at login.
    Timer {
        interval: 3000
        repeat: true
        running: true
        onTriggered: root.publishSidebarState()
    }

    // Both open flags publish, and they are the ONLY two places this value can
    // change -- so the file cannot drift from what the sidebars are doing.
    // (QML allows exactly ONE handler per property, hence the merge: the
    // right sidebar's notification bookkeeping lives in the same block as its
    // publish, not in a second `onSidebarRightOpenChanged` beside it.)
    onSidebarLeftOpenChanged: root.publishSidebarState()
    onSidebarRightOpenChanged: {
        if (root.sidebarRightOpen) {
            Notifications.timeoutAll();
            Notifications.markAllRead();
        }
        root.publishSidebarState();
    }

    property bool barOpen: true

    // Whether the system tray's dropdown card is open. Owned here rather than
    // on the tray itself so it can be driven over IPC -- the tray is a plain
    // Item deep inside the bar's layout, and "click the arrow to see if it
    // works" is not a test.
    property bool trayOverflowOpen: false
    // The liquid top bar: which status widget's pocket is pulled down, and how
    // far. `barPocketT` is the pull progress (0 = bar at rest, 1 = fully
    // extended) driven by a spring, so letting go overshoots and bounces back
    // -- the rubber feel. See Bar.qml's Pocket and BarContent's wiring.
    property string barPocketId: ""
    property real barPocketT: 0.0
    // DORMANT since 2026-10-14, deliberately left callable: "the compositor
    // says a window is covering this screen". The Hyprland config used to send
    // it on every cover toggle (custom/cover.lua) and it no longer does -- the
    // request spawned a `qs` process per toggle (measured 89ms, 78% of a core,
    // twice per cycle) and had stopped changing anything, because the bar
    // derives the same answer from its own window list. See Bar.qml's
    // `wsLiveHidden`: the flag is one of three ways in, and the other two
    // (fullscreenOnMonitor, coverByGeometry) are what actually decide now.
    //
    // Kept rather than deleted because it is the only way to reach this state
    // from outside the shell (a script, a test, a future compositor), and the
    // handler is proven: `qs -c ii ipc call barCover onCover true <addr>`.
    //
    // It lives here, not on the bar's own Scope, because of
    // `pragma ComponentBehavior: Bound`: a property on the bar's Scope is not
    // reachable from inside the per-monitor component that draws the bar, so a
    // flag set there silently did nothing. GlobalStates is the shell's
    // cross-component channel, and every other cross-cutting bar flag
    // (barOpen, barPocketId) already lives here.
    property bool barCoverRequested: false
    // The window that request was made for, so the bar can notice it vanishing
    // while the bar is still yielded. Empty whenever the flag above is false,
    // which since the request's retirement is always -- a manual caller sets
    // the two in the same breath (Bar.qml's onCover).
    property string barCoverAddress: ""
    // Whether the top bar is currently hidden (a real fullscreen window, or a
    // covering maximize it gave its strip to). Written by the bar itself, so
    // the notification popups can clear the bar's height only while there IS
    // a bar to clear -- otherwise notifications were parked 40px down for a
    // bar that was not on screen.
    property bool barHidden: false

    property bool crosshairOpen: false
    // The dock is up because the pointer is resting on the very bottom edge of the
    // screen. EdgeReveal owns it, exactly like the strips that bring the sidebars
    // in, so the dock can only be raised by touching that edge.
    property bool dockRevealed: false
    // Published by the dock itself: true while the pointer is over the dock's own
    // surface. EdgeReveal watches this instead of polling Hyprland for the cursor,
    // so knowing "did the pointer leave the dock" costs nothing at all.
    property bool dockPointerInside: false
    // ── "The edge just sent this panel away" ────────────────────────────────
    //
    // The sidebars and the edge strips share the outermost sliver of the
    // screen: hovering it opens a sidebar (EdgeReveal), clicking it while one
    // is open closes it again (the sliver handler in SidebarLeft/SidebarRight,
    // because the open card owns those pixels and the strip underneath sees
    // nothing).
    //
    // This flag is what stops the two halves from fighting: the hover that
    // opened the panel is still armed while the pointer rests on the edge, so
    // without it a dismissal would be undone 450ms later, over and over -- the
    // panel would flicker on every click and "the click does nothing" would be
    // half true anyway. Set by whichever half closed the panel, cleared the
    // moment a strip sees the pointer leave its own edge, so the next visit
    // hovers as usual.
    //
    // ONE FLAG PER EDGE, deliberately: each is read and written only by the
    // strip that owns that edge (and by that panel's own sliver), and a shared
    // flag would let a dismissal on the left mute the right until the pointer
    // happened to leave the left strip -- which, after a close from the panel
    // side, it may never do: the strip underneath never received the pointer in
    // the first place, so it has no leave to report.
    property bool sidebarLeftEdgeLatch: false
    property bool sidebarRightEdgeLatch: false
    property bool sidebarLeftOpen: false
    // One-shot tab request for the left sidebar ("Music"), consumed on arrival
    property string sidebarLeftTargetTab: ""
    /**
     * Relative tab movement for the left sidebar, as a RUNNING COUNTER
     * rather than a target name or an absolute index.
     *
     * The compositor owns the two-finger tab swipe, and a touchpad gesture
     * has no idea which tab it wants -- only which way it went -- so the
     * only thing it can hand the shell is "+1" or "-1". A counter is what
     * makes that a message rather than a state: two swipes in the same
     * direction are two increments, whereas assigning an absolute index
     * twice in a row would collapse into one.
     *
     * Deliberately NOT reset by whoever applies it. It grows without bound
     * (it is a float in practice after enough swipes, and never wraps in any
     * session that matters) precisely so no consumer can race the writer by
     * clearing it: the delta is read and applied, and the next swipe is
     * simply the next value.
     */
    property int sidebarLeftTabDelta: 0

    /**
     * True while the pointer is over something in the sidebar that wants
     * horizontal wheel events for ITSELF -- the music playlist shelf is the
     * one thing that scrolls sideways.
     *
     * Published to the compositor, because the compositor is what owns the
     * swipe: a bound touchpad gesture never reaches the client at all, so
     * once the shell stops receiving the wheel there is no way for it to
     * veto anything. Without this the shelf could not be scrolled by
     * touchpad at all, since every sideways gesture over it would be spent
     * switching tabs instead.
     */
    property bool sidebarLeftSwipeSuppressed: false
    readonly property string sidebarSwipeSuppressPath:
        `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/ii-sidebar-swipe.json`

    function publishSidebarSwipeSuppressed() {
        swipeSuppressWriter.running = false;
        swipeSuppressWriter.running = true;
    }

    Process {
        id: swipeSuppressWriter
        command: ["sh", "-c",
            `printf '{"suppressed":${root.sidebarLeftSwipeSuppressed},"ts":${Date.now() / 1000}}'`
            + ` > '${root.sidebarSwipeSuppressPath}'`]
    }

    property bool sidebarRightOpen: false
    // The wallpaper picker's full-screen theatre: true while the desktop
    // wallpaper should be dimmed and softly blurred behind the coverflow.
    // Lives here because the effect is drawn by Background.qml (the only thing
    // that can blur the wallpaper) while the trigger is the wallpaper pill's
    // hover state -- two different files, one shared flag.
    property bool wallpaperStageOpen: false
    // Screen-space rect of the theatre's card strip, published by the widget
    // so the modal companion (a TOP-layer window) can host the interactive
    // carousel exactly where the widget would have drawn it.
    property rect wallpaperStripRect: Qt.rect(0, 0, 0, 0)
    // Screen-space rect of the wallpaper pill itself, published so the pill
    // proxy (a TOP-layer input window) can mask over exactly that spot.
    property rect wallpaperPillRect: Qt.rect(0, 0, 0, 0)
    // True while the pointer rests on the pill (driven by the proxy): the
    // pill's droplet/lean hover animation reads this.
    property bool wallpaperPillHovered: false
    // Screen-space rect of the desktop volume rail's interaction area,
    // published by the widget so the Top-layer sound proxy can mask over it
    // (The desktop volume rail is gone -- SoundBar deleted; the proxy that
    // consumed this rect went with it.)
    property rect soundRailRect: Qt.rect(0, 0, 0, 0)
    // Emitted when the theatre's "add wallpaper" button is pressed; the
    // widget owns the picker machinery and answers this signal.
    signal requestWallpaperAdd()
    // The old 440x160 media card is GONE -- the island, the sidebar's music
    // card and the bar's media widgets all open `musicPlayerOpen` below, the
    // full player popup. Nothing reads a separate media-card flag any more.
    // The FULL music player popup (the sidebar's Music tab in its own window --
    // see modules/ii/mediaControls/MusicPlayerPanel.qml for why it cannot just
    // be the sidebar). One flag, opened from the island's media view, the
    // sidebar's music card, the bar's media widgets or a script.
    property bool musicPlayerOpen: false
    // The middle island's current view, so the bar's pocket content can follow
    // it: 0 = pomodoro, 1 = media, 2 = AI usage, 3 = performance.
    property int nowBarMode: 0          // System (ring index 0, see NowBar)
    // Razer Command Center: the island/panel have a 5th "Lighting" view
    // (mode 4) whose profile chips + brightness slider are fed by a Process
    // that reads the JSON store (see NowBarPanel LightingView).
    property int razerProfileCount: 0
    property int razerProfileActive: 0
    property string razerProfileNames: ""
    // One-shot reveal flag for the view tick rows (the island's bottom edge
    // and the card's header): any mode change shows "where did it land" for
    // the hint window, then the rows fade away again. One flag serves every
    // surface that draws ticks.
    property bool nowBarTickHint: false
    Timer {
        id: nowBarTickHintTimer
        interval: 1600
        onTriggered: root.nowBarTickHint = false
    }
    onNowBarModeChanged: {
        root.nowBarTickHint = true;
        nowBarTickHintTimer.restart();
    }
    // True while the pointer is on the middle island. The bar watches this and
    // arms its own pocket, because only BarContent can map the island into the
    // bar's coordinate frame (the pocket places itself from there).
    property bool nowBarExpanded: false
    // The island popped out into its floating card (NowBarPanel): opened by the
    // three-finger swipe down, closed by pressing outside it. It is a separate
    // state from nowBarExpanded on purpose -- the hover extension is a glance,
    // this one stays until you dismiss it.
    property bool nowBarPanelOpen: false
    // Where the island's center is, in bar coordinates. Only BarContent can
    // compute it (the island does not know the bar's frame), so it publishes it
    // here for the panel to anchor under.
    property real nowBarCenterX: 0
    // The island's own width/height in bar coordinates, so the panel can start
    // as the island's shape and grow out of it.
    property real nowBarWidth: 0
    property real nowBarHeight: 0
    property bool osdBrightnessOpen: false
    property bool osdVolumeOpen: false
    property bool oskOpen: false
    property bool overlayOpen: false
    property bool overviewOpen: false
    // The SUPER-tap app search overlay (design/search-overlay-preview.html):
    // a 379px card hanging from the bar's centre island -- tabs, app grid,
    // match list, advanced groups. Separate from overviewOpen on purpose:
    // this is the launcher, the overview is the desktop grid, and they must
    // never close each other by accident through a shared flag.
    property bool appSearchOverlayOpen: false
    // The desktop overview the bar's empty stretches open (design A in
    // design/desktop-view/index.html): one blurred wallpaper, the desktops
    // as frosted cards with their windows drawn live inside. Separate from
    // overviewOpen -- that one drags and closes windows, this one only looks
    // and jumps, and a casual bar tap must never be able to rearrange the
    // desktop.
    property bool desktopOverviewOpen: false
    // ── "Open the grid with a desktop already IN HAND" (NO WAY IN, 2026-10-16) ──
    //
    // Two entry points are POINTER actions, so the desktop under the cursor at
    // that moment is a fact and not a guess at intent:
    //
    //   SUPER + four-finger swipe down   REMOVED (2026-10-16, requested)
    //   SUPER + Space                    REMOVED -- the chord no longer asks
    //
    // Both went through this one request, and both are gone: the gesture is
    // deleted from custom/general.lua and the chord raises nothing (see
    // `superPressEdge` below). NOTHING EMITS THIS SIGNAL ANY MORE, and that is
    // the finished state rather than a half-deletion -- the signal, the flag
    // and the global are the capability, and the IPC `desktopOverview lift`
    // still drives them, so a new entry point can bind to them unchanged.
    //
    // HOW IT HAS TO BE EMITTED, kept because that constraint is what a future
    // entry point has to satisfy: it goes IMMEDIATELY BEFORE
    // `desktopOverviewOpen` is raised, never after: the grid's open handler
    // runs synchronously inside that write and reads the flag it sets, so a
    // request announced afterwards is read a beat too late and the lift is
    // lost with no error anywhere. That ordering is the whole mechanism.
    //
    // A SIGNAL, not a bool, for the same reason `desktopPillFlash` is: it is an
    // event with a moment, and a sticky flag would be read by an unrelated open
    // (SUPER+Tab, the bar's empty stretches) and lift a card nobody asked for.
    // DesktopOverview.qml holds the request itself and spends it on the first
    // cursor read, whatever that read answers.
    signal desktopOverviewLiftRequest()
    // Which of the two SUPER panels is up. They are deliberately separate things:
    //
    //   "search"   the search field with the recently-used row -- what a plain
    //              SUPER tap opens, for finding and launching something
    //   "desktops" the live desktop grid, no search field at all -- what
    //              SUPER+Tab opens, for looking at where your windows are
    //   "windows"  the same grid, collapsed to the desktop you are on -- ALT+Tab
    //
    // Before this, both keys opened the same panel: the search bar with the
    // desktop grid sitting under it and appearing whenever the field was empty.
    // Splitting them is why pressing SUPER no longer throws a page of desktops
    // at you, and why SUPER+Tab no longer drags a search bar along with it.
    property string overviewMode: "search"
    // True only while the overview was opened by the touchpad tap (search
    // tapWorkspaces): it runs MODAL-LESS -- no compositor focus grab, since
    // there is no held key to end it. The grab's own lifecycle (it clears
    // itself a couple of seconds after opening without a held key) used to
    // close the grid under the user. SUPER+Tab's held peek keeps the grab.
    property bool overviewTapMode: false
    // True when the overview was opened as a switcher for THIS desktop's windows
    // (ALT+Tab) rather than as the multi-desktop grid (SUPER+Tab). The overview
    // normally sizes itself from overview.rows x overview.columns, which is a
    // desktop grid -- this forces it down to the single desktop you are on.
    property bool overviewSingleWorkspace: false
    // How many desktops existed when the SUPER+Tab grid was opened, or 0 when it
    // has never been opened (or is closed) and the count should be read live.
    //
    // The grid draws the existing desktops plus one empty "make another" tile,
    // and Tab steps between exactly those. Freezing the number at open time is
    // what keeps those two views of "how many desktops are there" in step: step
    // onto the empty tile and a real desktop is created underneath you, so a live
    // count would grow a new tile every press and Tab could wander off down the
    // strip for as long as you held it.
    property int overviewDesktopCount: 0
    property bool regionSelectorOpen: false
    // The colour picker (SUPER + C): a frozen grab of each screen with a
    // crosshair and a live hex/rgba pill. Alt+X (or click) copies the hex,
    // Esc closes. Every entry point -- the GlobalShortcut, the bar utility
    // button, the sidebar quick toggle, the waffle snip panel -- just sets
    // this flag; ColorPicker.qml drives the surfaces from it.
    property bool colorPickerOpen: false
    property bool searchOpen: false
    property bool screenLocked: false
    // A popup menu opened FROM the right sidebar is currently open.
    //
    // The sidebar closes itself when the pointer leaves it, and it must not do
    // that while one of its own menus is up: the menus are separate popup
    // windows, so travelling from the button down to the menu takes the pointer
    // off the sidebar panel, the 200ms grace expired, and the sidebar closed
    // out from under the menu the user was reaching for. Because the sidebar
    // closing also tears the menus down, the result was a menu you could see
    // but could not put the cursor on.
    //
    // Set by the menus, read by SidebarRight.qml's pointer-out timer -- the
    // same arrangement as Todo.dragInFlight, which guards the same timer for
    // the same reason: an interaction that legitimately has to leave the panel
    // while it is in progress.
    property bool sidebarRightPopupOpen: false
    property bool screenLockContainsCharacters: false
    property bool screenUnlockFailed: false
    property bool screenTranslatorOpen: false
    property bool sessionOpen: false
    property bool superDown: false
    // Which key armed the hold. The bare SUPER key arms it to call off its own
    // tap (a slow look at the numbers is not a tap); the SUPER+Space chord does
    // not use the hold at all any more -- it toggles the grid on the press
    // edge (see superPressEdge), so this stays false for it.
    property bool superHoldFromChord: false
    // A press edge just DISMISSED something (the desktop grid, or the app
    // search card). One physical chord fires TWO shortcuts -- the bare SUPER
    // press and the chord's own -- and both arrive at superPressEdge: the bare
    // one closes the grid, and without this the chord's press would open it
    // straight back up, so a tap on an open grid did nothing at all (measured
    // 2026-10-15, the same tap that was supposed to toggle). The flag is set by
    // whichever branch closed something, read and cleared by the chord, and
    // cleared again on the release edge: one press sequence, one action.
    property bool superDismissedOnPress: false
    property bool superReleaseMightTrigger: true
    property bool wallpaperSelectorOpen: false
    property bool workspaceShowNumbers: false

    // ═══ The temporary popups, as ONE list ═══════════════════════════════════
    //
    // Everything here is a popup that was opened to do one small thing and has
    // no business outliving the desktop it was opened over: the launcher, both
    // desktop grids, the island's popped-out card, the music player, the
    // session menu, the wallpaper picker and its theatre, a menu opened from
    // the right sidebar.
    //
    // Two things need to ask that question, and until now neither could:
    //
    //   * the DESKTOP CHANGED -- by a bar pill, SUPER+<n>, another gesture --
    //     and a popup left floating over a desktop it was not opened on reads
    //     as stuck; and
    //   * a FOUR-FINGER HORIZONTAL SWIPE ended. That swipe is a desktop
    //     switch, so the popup it covered has to go -- and it has to go
    //     WITHOUT swallowing the swipe (see the gesture case in shell.qml).
    //
    // One list, one closer, so neither path has to re-invent "which popups are
    // temporary": a popup added later is covered by adding its flag here. The
    // popups that hold a compositor-level grab instead of a flag -- the bar's
    // icon cards (VPN, wifi, bluetooth, battery, background apps, the clock),
    // the sidebars, the cheatsheet, the clipboard, the on-screen keyboard --
    // are the other half, and GlobalFocusGrab.dismiss() below is exactly what
    // that registry exists for.
    //
    // NOTE: `transientPopupOpen` below names the same flags property by
    // property, in the same order. That is not duplication for its own sake: a
    // QML binding does NOT track a dependency it reaches through a dynamic
    // lookup, so a `some()` over this array would be evaluated once and then
    // never again -- a popup would open and the flag would still read false.
    readonly property var transientPopupFlags: [
        "appSearchOverlayOpen",     // the SUPER-tap launcher
        "desktopOverviewOpen",      // the desktop grid
        "overviewOpen",             // SUPER+Tab / ALT+Tab
        "searchOpen",
        "nowBarPanelOpen",          // the island popped out into its card
        "musicPlayerOpen",
        "sessionOpen",
        "wallpaperSelectorOpen",
        "wallpaperStageOpen",       // the wallpaper theatre
        "sidebarRightPopupOpen",    // a menu opened from the right sidebar
        "screenTranslatorOpen",
        "regionSelectorOpen",
        "crosshairOpen",
        "trayOverflowOpen",
        "overlayOpen"
    ]

    /// True while any temporary popup is on screen, right now.
    ///
    /// The second half is the GRAB, and it is not a convenience: the bar's
    /// icon cards -- the user's own example -- keep no flag here at all. They
    /// are `BarAnchoredPanel`s, and their only record of being open is their
    /// registration with GlobalFocusGrab (that file explains why: the panel is
    /// a layer surface, so the compositor-level grab IS its open state). Asking
    /// the flags alone therefore answered "no popup" while the VPN card filled
    /// the screen, and the swipe that closed it switched nothing -- measured,
    /// with `closed=false` in the gesture log for exactly those cases.
    /// `liveDismissable` is that same list with the entries that are no longer
    /// on screen filtered out, so a stale registration cannot pin this true.
    readonly property bool transientPopupOpen:
        root.appSearchOverlayOpen || root.desktopOverviewOpen || root.overviewOpen
        || root.searchOpen || root.nowBarPanelOpen || root.musicPlayerOpen
        || root.sessionOpen || root.wallpaperSelectorOpen || root.wallpaperStageOpen
        || root.sidebarRightPopupOpen || root.screenTranslatorOpen
        || root.regionSelectorOpen || root.crosshairOpen || root.trayOverflowOpen
        || root.overlayOpen
        || GlobalFocusGrab.liveDismissable.length > 0

    /// Put every temporary popup away; true when one was actually up.
    ///
    /// The return value is what lets a caller ask "did this have to close
    /// something?" without keeping a second copy of the list. `except` is the
    /// one flag a caller knows better than this function does (the desktop
    /// grid, on a desktop change -- see below).
    function closeTransientPopups(except: string): bool {
        let closed = false;
        for (const flag of root.transientPopupFlags) {
            if (flag === except)
                continue;
            if (root[flag]) {
                root[flag] = false;
                closed = true;
            }
        }
        // The grab half: every popup that registered itself as dismissable is
        // closed by its own `onDismissed`, in one call. This is also what puts
        // the bar's icon cards away, and they have no flag of their own to
        // reach -- so a grab with anything on screen counts as closed too, or
        // this would report "nothing was open" about a card the user was
        // looking at (measured: the VPN panel closed through here while the
        // flag list had nothing left to clear).
        const hadGrabbed = GlobalFocusGrab.liveDismissable.length > 0;
        GlobalFocusGrab.dismiss();
        return closed || hadGrabbed;
    }

    // A desktop change closes them, whichever way it happened -- a bar pill, a
    // card in the desktop grid, SUPER+<n>, a script, another gesture.
    //
    // The ID is compared, never the object: HyprlandData reassigns
    // `activeWorkspace` to a freshly parsed object on every poll, so the change
    // signal fires constantly with the same desktop in it -- closing on the
    // signal alone would slam popups shut a fraction of a second after they
    // open. This is the same guard the launcher and the desktop grid already
    // use for themselves.
    //
    // The desktop grid is deliberately NOT closed from here: it has its own
    // version, because it is the one popup that can tell a desktop SWITCH from
    // a desktop REORDER (arranging desktops renumbers the desktop you are
    // standing on as a side effect, and the grid must survive that -- it is
    // mid-arrangement). Everything else has no such case.
    property int lastWorkspaceForPopups: 0
    Connections {
        target: HyprlandData
        function onActiveWorkspaceChanged() {
            const id = Number(HyprlandData.activeWorkspace?.id ?? 0);
            if (id === root.lastWorkspaceForPopups)
                return;
            root.lastWorkspaceForPopups = id;
            if (id <= 0)
                return; // a special workspace is not a desktop to be closed for
            root.closeTransientPopups("desktopOverviewOpen");
        }
    }

    // ── "Nothing that way" ─────────────────────────────────────────────
    // A four-finger swipe that lands on no desktop publishes NO workspace
    // event, so the desktop pill -- which flashes on every real switch --
    // would never hear about the one gesture where an answer matters most.
    // shell.qml owns that decision (only it sees both the gesture and the
    // workspace list) and raises this instead.
    //
    // A SIGNAL rather than a flag, and that is the point: the flash is an
    // EVENT with its own 1.4s lifetime owned by the pill. A sticky bool
    // would leave the pill up until some later code remembered to clear it.
    // See shell.qml's "Nothing that way" block and DesktopIndicator.qml.
    signal desktopPillFlash()

    // ── Desktop edit mode ──────────────────────────────────────────────
    // A temporary state, entered by the 4-finger tap gesture ONLY when the
    // active desktop has no app windows: the desktop widgets become draggable
    // and the left sidebar opens automatically. The 4-finger tap again (or
    // clicking empty desktop, or opening an app, or locking) leaves it, and
    // the sidebar is restored to exactly the state it was in before.
    // Enter/exit logic lives here so the gesture, the IPC and the exit
    // watchers can never disagree about what the mode is.
    property bool desktopEditMode: false
    // What the sidebar was doing before edit mode opened it, so exit restores
    // it instead of force-closing a sidebar the user had pinned open.
    property bool editModeSidebarWasOpen: false

    // Is the active desktop free of app windows? The same predicate the
    // wallpaper pill's gesture layer uses, so every part of the shell agrees
    // on what "empty" means.
    readonly property bool activeDesktopEmpty: {
        const wid = HyprlandData.activeWorkspace?.id;
        if (wid === undefined || wid < 1) return false;
        return !HyprlandData.windowList.some(w => (w.workspace?.id ?? -1) === wid
            && w.mapped !== false && w.hidden !== true);
    }

    // The gesture jumps to an empty desktop and immediately asks for the
    // mode; the shell's view of "which desktop is active" can lag that jump
    // by a frame. A busy reading gets one short retry window (4 × 250ms)
    // before the enter is refused for good -- which is what a plain IPC call
    // on a genuinely busy desktop deserves.
    property int editModeGuardAttempts: 0
    Timer {
        id: editModeGuard
        interval: 250
        repeat: true
        onTriggered: {
            if (root.editModeGuardAttempts < 4) {
                root.editModeGuardAttempts++;
                root.enterDesktopEditMode();
            } else {
                root.editModeGuardAttempts = 0;
                stop();
            }
        }
    }

    function enterDesktopEditMode() {
        if (desktopEditMode) return;
        if (!activeDesktopEmpty) {
            editModeGuard.restart();
            return;
        }
        editModeGuard.stop();
        editModeGuardAttempts = 0;
        desktopEditMode = true;
        editModeSidebarWasOpen = sidebarLeftOpen;
        sidebarLeftOpen = true;
    }
    function exitDesktopEditMode() {
        if (!desktopEditMode) return;
        desktopEditMode = false;
        sidebarLeftOpen = editModeSidebarWasOpen;
    }
    function toggleDesktopEditMode() {
        if (desktopEditMode) exitDesktopEditMode();
        else enterDesktopEditMode();
    }

    // ── "Something is starting" indicator ───────────────────────────────────────
    // A program being launched does not get an indicator straight away. Most of
    // them are on screen in well under a second, and a card that appears and
    // vanishes in that time is noise, not information. So a launch is *pending*
    // first: nothing is drawn, and only if the program has still not turned up
    // after `loadingGraceMs` does the card appear -- at which point it is actually
    // telling you something. The moment a new window appears (which is what "it
    // opened" means on this desktop) the card is taken away again, whether or not
    // it had ever been shown.
    //
    // There is deliberately NO timeout on the wait. A card that gives up after
    // fifteen seconds is worse than no card: something slow but alive gets
    // announced as broken, and something broken gets announced as merely slow.
    // The wait ends when one of two things actually happens -- the window turns
    // up, or the program dies and says so (see openApp() and `error` below) --
    // and until then the card is telling the truth.
    property string loadingText: ""
    property bool loadingVisible: false
    // ── A failed launch is carried by the BAR, not the corner card ───────
    //
    // Asked for 2026-10-19: "I want the couldn't open message in the top right
    // bar where it also shows opening... label only red and the simple thin
    // border". So a launch failure now lives in the bar's status row (red,
    // steady) for the same 12s the card used to sit there, and the screen's
    // hairline is HELD flat red with it instead of double-blinking. The card
    // keeps the messages that are genuinely cards -- the "already open"
    // notice and the power failsafe's alert -- which is why this is a flag of
    // its own and not a change to `loadingFailed`.
    property bool loadingFailureInBar: false
    // The screen hairline's second mode: held lit (see ScreenFlash) while a
    // launch failure is on the bar. Separate from screenFlashTick on purpose:
    // the tick is a one-shot pulse and this one has a duration that belongs
    // to the failure's own clock.
    property bool screenFailureHold: false
    // Download progress on the bar's status line: when >= 0, the line's
    // fill shows the REAL fraction instead of the launch-charge crawl, and
    // the tell label reads "Downloading <name>". Set by the `loading`
    // IPC's progress() from Razer Command Center's downloader.
    property real downloadProgress: -1   // 0..1, or -1 = no download
    property string downloadName: ""
    // A program is starting and waiting to appear. Set by showLoading().
    property bool loadingPending: false
    // The card is reporting a failure rather than a wait: a different glyph, the
    // error colour, and it clears itself after a while -- a real error message is
    // worth reading but not worth keeping on screen for the rest of the session.
    property bool loadingFailed: false
    // The windows that were already there when the launch began; anything that
    // shows up afterwards is the thing we were waiting for.
    property var loadingWindowBaseline: []
    readonly property int loadingGraceMs: 3000
    // How long a failure stays up. Long enough to read twice, short enough that
    // walking away from a failed app does not leave a red card on the desktop.
    readonly property int loadingErrorMs: 12000
    // An "already open" card is not a wait: it is a notice. It hides itself on
    // this much shorter clock and the indicator shows no spinner for it.
    readonly property int loadingInfoMs: 2200
    property bool loadingInfo: false

    // ── The launch failsafe ────────────────────────────────────────────────
    //
    // The wait itself is deliberately timeout-free (see showLoading), because
    // a timeout cannot tell a slow app from a broken one. The window watcher
    // ends it the moment the app turns up, and `open.sh` ends it when the
    // program dies outright. What neither of those covers is the launch that
    // is neither: the command exists, the wrapper is happy, and no window ever
    // appears -- a desktop entry pointing at a binary that hangs, an app that
    // opens straight onto another workspace, a session bus that swallows the
    // activation. The wait then never ends, and the desktop says "Opening X"
    // for the rest of the session, which is worse than a wrong "couldn't
    // open": the user cannot tell whether to click again.
    //
    // So this is a backstop and not a verdict, and it is built like one: it is
    // LONG (the same ten seconds TrayApps waits for, which is the slowest real
    // cold launch on this machine), it withdraws itself if the window arrives
    // inside a grace window afterwards, and it reports the failure through the
    // SAME face as every other failed launch -- the red double blink on the
    // bar line and in the extended top tab, and the corner card with the
    // sentence -- so there is one thing to look at, not two.
    //
    // Zero means "never arm this". Scripts that own the card themselves (the
    // `loading display` IPC) set it to 0 so their wait is not cut short.
    readonly property int launchFailsafeMs: 10000
    // How long AFTER the failsafe fires the window is still watched. A cold
    // app on a cold page cache can take fifteen, and the failure card lives
    // twelve, so without this the desktop can say "Couldn't open X" while X
    // is in the middle of opening. A window inside this window withdraws the
    // verdict rather than leaving a lie on screen.
    readonly property int launchLateGraceMs: 20000
    // When the wait now on screen STARTED. The failsafe's interval is ten
    // seconds, but a launch that came through `open.sh` RENEWS that clock while
    // the app is still alive (see the `renew` IPC below), so when a verdict is
    // finally reached the honest number is the elapsed one, not the ten.
    property real loadingWaitStartedAt: 0
    // Ticks left on the failsafe, 0 = disarmed. A count rather than a running
    // flag so `display`'s zero really does disarm a timer armed by an earlier
    // launch.
    property int launchFailsafeTicks: 0
    // The name the wait was announced under, captured when it was armed.
    property string launchFailsafeName: ""
    // True only while a verdict the FAILSAFE produced is on screen (not one
    // `open.sh` reported, which is a fact about a dead process and is never
    // withdrawn). This is what tells the address watcher that a window
    // arriving now should retract the card immediately, rather than at the
    // end of the grace window.
    property bool launchFailsafeVerdict: false
    readonly property real launchFailsafeTickMs: 250
    readonly property int launchFailsafeTicksMax: Math.max(1,
        Math.round(root.launchFailsafeMs / root.launchFailsafeTickMs))

    // ── The wait's ABSOLUTE ceiling ───────────────────────────────────────
    //
    // Everything above is a decision about whether the launch succeeded. This
    // is not: it is the guarantee that the bar cannot get STUCK saying a launch
    // is in flight. The failsafe alone was not enough, and the hole was exactly
    // the case that reads as a bug rather than as a wait --
    //
    //   * `display` disarms the failsafe on purpose (the caller owns the
    //     wait), so a caller that forgets `dismiss` left "Opening <name>" and
    //     the full-width line under the bar up for the rest of the session.
    //     That is the reported "permanent bar": a file opened from Files whose
    //     guarded dismiss never fired left the row and the line on screen
    //     indefinitely (2026-10-19).
    //   * `renew` deliberately keeps a live process's clock fresh, so a process
    //     that stays alive without ever mapping a window kept the wait alive
    //     with it, however long that was.
    //
    // Neither can be trusted to end, so this one cannot be renewed at all. When
    // it fires the wait is retired QUIETLY -- no failure claim, because nothing
    // here knows the app failed, only that the desktop has been saying
    // "Opening" for far longer than any real launch needs. `finishLoading`
    // clears the row and the line with it, which is the whole point: the most a
    // stale wait may cost is half a minute of optimism, never a permanent strip
    // across the bar.
    readonly property int loadingMaxMs: 30000

    // ── The island's loading line ───────────────────────────────────────────
    // The same "something is starting" fact, drawn where the user is actually
    // looking: a small sweeping line under the middle island in the bar. The
    // bottom-left card is still the right shape for anything that has to be
    // READ -- "X is already open", "Couldn't open X" -- but a plain wait has
    // nothing to read, and a corner is the one part of the screen no one is
    // watching while they wait for a window. The launcher sits under the
    // island, so the island is where the answer belongs.
    //
    // Notable: this is NOT the same as `loadingVisible`, which was the card's
    // own grace (3s -- long enough to be a decision, and stale by the time it
    // fired). A line costs nothing to show, takes no room and carries no text,
    // so the grace only has to outlast the apps that are genuinely instant.
    property bool loadingLine: false
    readonly property int loadingLineGraceMs: 600
    // The line's failure face: a dead launch turns the bar's under-line red
    // for this long, then the whole thing fades away. The corner card still
    // carries the sentence ("Couldn't open X") -- the red line is the glance,
    // the card is the read.
property bool loadingFailFlash: false
    // How many times the failure face blinks. Two is the specified behaviour
    // and the same count the low-battery alert uses: enough to catch the eye
    // of someone who was not looking straight at it, few enough that it does
    // not become a distress beacon on a desktop where a launch failed once.
    readonly property int loadingFailBlinks: 2
    // Long enough for the blinks to finish plus a beat to be read: two at
    // 450ms on / 350ms off is 1.6s, so 2.1s covers it with room to spare.
    // The card that carries the sentence lives much longer (loadingErrorMs).
    readonly property int loadingFailFlashMs: 2100

    // Does the corner card have anything to say? Anything that has to be READ
    // belongs to it: a failure, an "already open" notice, the release-to-close
    // hint. A plain wait no longer does -- the island's line is the wait -- so
    // this deliberately does NOT include the `loadingVisible` grace state,
    // which was the "Opening X" card the line replaces.
    readonly property bool loadingCardVisible: root.loadingInfo
        || (root.loadingFailed && !root.loadingFailureInBar)
        || root.loadingText === root.closeDragHintText

    // ── The duplicate-launch guard ────────────────────────────────────────
    // The exec lines of the launches currently in flight. Set by showLoading,
    // removed when a launch resolves in ANY way -- a window arrives, the
    // wrapper reports failure, or the (timeout-free by design) wait is reset
    // -- and also swept by the safety timer below. An array, not one mark:
    // Freebuff can be mid-launch while Firefox is clicked, and resolving one
    // must not unguard the other.
    property var launchPendingCommands: []
    // openApp needs to hand showLoading the command without showLoading's
    // signature growing a parameter the rest of its callers do not care
    // about; this one-shot carries it there.
    property string launchPendingCommandDraft: ""
    readonly property int launchPendingResetMs: 12000
    Timer {
        id: launchPendingReset
        interval: root.launchPendingResetMs
        repeat: false
        running: false
        onTriggered: {
            root.launchPendingCommands = [];
            root.launchPendingCommandDraft = "";
        }
    }

    function showLoading(text) {
        root.loadingText = text ?? "";
        root.loadingFailed = false;
        // A fresh wait is never a failure that is still on the bar.
        root.loadingFailureInBar = false;
        root.screenFailureHold = false;
        root.loadingInfo = false;
        root.loadingFailFlash = false;   // a fresh wait is never a failure
        loadingFailFlashTimer.stop();
        // Arm the backstop for this wait (see launchFailsafeMs). The name is
        // captured HERE, while the wait still has one: the report is built from
        // it, and by the time the failsafe fires `loadingText` may have been
        // rewritten by anything that touched the card in between.
        root.launchFailsafeName = root.loadingText;
        root.loadingWaitStartedAt = Date.now();
        root.launchFailsafeTicks = root.launchFailsafeTicksMax;
        root.launchFailsafeVerdict = false;   // no verdict on screen yet
        launchLateGraceTimer.stop();
        root.loadingWindowBaseline = HyprlandData.addresses.slice();
        root.loadingPending = true;
        root.loadingVisible = false;
        root.loadingLine = false;
        loadingErrorTimer.stop();
        loadingGraceTimer.restart();
        loadingLineTimer.restart();
        // And the ceiling that no `renew` can push out (see loadingMaxMs).
        loadingWatchdogTimer.restart();
        // Mark the launch as pending (see openApp's duplicate-guard).
        if (root.launchPendingCommandDraft.length > 0
            && root.launchPendingCommands.indexOf(root.launchPendingCommandDraft) === -1)
            root.launchPendingCommands.push(root.launchPendingCommandDraft);
        root.launchPendingCommandDraft = "";
        launchPendingReset.restart();
    }

    // ── The tray permission, taken here instead of by a process ──────────
    //
    // open.sh asks for this through `qs -c ii ipc call trayapps allow`, which
    // starts a whole Qt client to run the same code this shell can call
    // directly. Measured: 34-43ms of wall time, on EVERY launch, serialized
    // before the app is exec'd (spawn -> window 186ms through open.sh against
    // 126ms for the same binary started directly). The shell is holding the
    // command at click time, so it takes the permission itself (microseconds,
    // same registry, same thread) and hands open.sh the third argument that
    // says so.
    //
    // Returns the stamp to pass, or "" when the permission could not be taken
    // here -- in which case open.sh's own call still runs and nothing is lost.
    function allowTrayLaunch(command) {
        try {
            TrayApps.allowLaunch(String(command ?? ""));
            return "tray-allowed";
        } catch (e) {
            // Named, not swallowed: a failure here must not leave the launch with
            // no permission at all without saying why.
            console.warn("allowTrayLaunch failed, falling back to open.sh's own"
                + " call:", e);
            return "";
        }
    }

    // ── Tray apps: "open it from the tray, not again" ────────────────────
    //
    // A tray app parked in the vault HAS a window -- it is just not on any
    // workspace -- so findRunningApp (which only considers mapped windows) does
    // not see it and the launcher fell through to a fresh launch. For WhatsApp
    // that is worse than a duplicate window: a second whatsapp-linux-desktop
    // binary is a new browser context and loses the login. The tray icon's own
    // path is the right one (TrayApps.show moves the parked window back to the
    // active workspace, focused and attached), so the launcher asks the tray
    // first, and only falls through to launching when there is nothing to
    // bring back.
    //
    // Which registry app a click is aimed at. Three signals, because the three
    // call sites do not hand over the same thing: the start menu has the
    // DesktopEntry (startupClass is exact -- "WhatsApp Desktop"), the recent
    // tiles hand over the exec line and the display name (the exec names the
    // WRAPPER, ~/.local/bin/whatsapp-desktop, not the registry's binary), and
    // the search bar can pass either. Matching is deliberately narrow: no
    // substring test on the whole command, which would let a URL argument pick
    // an app.
    function trayClassForApp(command, label, entry) {
        const norm = s => String(s ?? "").trim().toLowerCase();
        const stem = s => norm(s).replace(/[^a-z0-9]/g, "");
        const startup = norm(entry?.startupClass);
        const names = [norm(label), norm(entry?.name)].filter(s => s.length > 0);
        const head = norm(command).split(/\s+/)[0];
        const headName = head.split("/").pop();
        for (const e of TrayApps.registry) {
            const cls = String(e.cls ?? "").trim();
            const clsNorm = norm(cls);
            const regName = norm(e.name);
            const regBin = norm(e.launch).split("/").pop();
            if (startup.length > 0 && startup === clsNorm)
                return cls;
            if (headName.length > 0 && regBin.length > 0 && stem(headName) === stem(regBin))
                return cls;
            for (const n of names) {
                if (n === clsNorm || (regName.length > 0 && n === regName))
                    return cls;
                // The desktop entry says "WhatsApp Desktop", the registry
                // says "WhatsApp": the entry carries the product suffix, the
                // registry the brand. Only a whole-word prefix counts.
                if (regName.length > 0 && (n.startsWith(regName + " ") || regName.startsWith(n + " ")))
                    return cls;
            }
        }
        return "";
    }

    // True when this click was answered by the tray instead of by starting the
    // program again. The three outcomes mirror the tray icon's own toggle(),
    // which is the behaviour the user is asking for:
    //   window on a workspace   -> declined here; the ordinary already-open
    //                              redirect above has already focused it
    //   parked in the vault     -> TrayApps.show() moves it back, focused
    //   process alive, no window-> show() (a no-op) and NOT a second binary:
    //                              a fresh WhatsApp is a new browser context and
    //                              loses the login, which is exactly what the
    //                              tray icon refuses to do as well
    function showFromTray(command, label, entry) {
        const cls = root.trayClassForApp(command, label, entry);
        if (cls.length === 0)
            return false;
        if (TrayApps.isRunning(cls) && !TrayApps.isHidden(cls))
            return false; // visible: not the tray's business
        if (!TrayApps.isRunning(cls) && !TrayApps.processAlive(cls))
            return false; // not running at all: a real launch, with the
                          // entry's own wrapper and flags
        console.log(`[launcher] ${cls} is answered by the tray (parked=${TrayApps.isHidden(cls)})`);
        TrayApps.show(cls);
        return true;
    }

    // Launch `command`, and be able to say whether it made it.
    //
    // `showLoading` above is for the caller that runs the program itself (the
    // overlay cards, a script): it only announces the wait. This one takes the
    // command, runs it through scripts/launch/open.sh, and so gets told as well --
    // the wrapper reports back if the program dies without ever opening a window,
    // which is what "couldn't open it" actually looks like. A program that opens
    // its window and quits with an error an hour later is NOT a failed launch, and
    // the wrapper's report is ignored in that case because `loadingPending` was
    // already cleared when the window appeared.
    //
    // Detached on purpose: the launched program must outlive a shell reload, and a
    // tracked child process is killed when the configuration reloads.
    function openApp(command, label) {
        // ── Already open, and meant to be only once? Go to it instead. ──────
        // Every window-carrying launch goes through here, so one check covers
        // the search bar, the recent tiles and the launcher alike. Matching is
        // by Hyprland class first (a desktop entry's exec resolves to a class
        // once the window exists) and by app name second ("Firefox" matches a
        // window titled "Firefox — blah"). One the match is found, the
        // compositor is asked to move the view there: switch its workspace,
        // then focus it.
        //
        // The match alone is NOT enough to redirect -- the app also has to be
        // on the single-instance allowlist (see singleInstanceList). A match
        // for anything else is discarded and the launch goes ahead as normal,
        // which is what lets "open Brave" open a new normal window while a
        // private one is already up.
        const hit = root.findRunningApp(command, label ?? "");
        const running = hit && root.isSingleInstance(hit.class) ? hit : null;
        if (running) {
            root.focusRunningApp(running, label ?? "");
            return;
        }

        // ── Running, but only in the tray? Open it FROM the tray. ──────────
        // Parked windows are not on a workspace, so the check above cannot see
        // them; without this the launcher started a second binary (WhatsApp:
        // a new session, login lost). Handles the tray icon's own show().
        if (root.showFromTray(command, label ?? "", null))
            return;

        // ── The same launch already in flight? Fold into it, don't stack. ──
        // A slow app (an AppImage that first mounts itself, then unpacks, then
        // draws) leaves a multi-second gap in which the window is not yet in
        // the list -- so an impatient second click saw "not running" and
        // started a SECOND copy, which then competed with the first for disk
        // and CPU and made the original even slower. Freebuff was the regular
        // offender: three clicks, three instances, none of them up. The wait
        // has no timeout by design, so the pending mark is what a repeated
        // click now finds: one launch, one instance, and the island line
        // already showing for it.
        const wanted = String(command ?? "").trim();
        if (root.launchPendingCommands.indexOf(wanted) !== -1) {
            root.loadingText = label ?? "";
            loadingLineTimer.restart();
            return;
        }

        root.launchPendingCommandDraft = wanted;
        root.showLoading(label);
        // Taken BEFORE the window exists, which is what the tray guard reads --
        // and taken here so the Qt spawn stays off the launch path.
        const allowed = root.allowTrayLaunch(command);
        Quickshell.execDetached(["bash", `${Directories.scriptPath}/launch/open.sh`, label ?? "", command, allowed]);
    }

    // ── Launch choke point for DesktopEntry objects ──────────────────────
    // The start menu grids, the dock, the taskbar and the search results all
    // hold Quickshell DesktopEntry objects and used to call entry.execute()
    // directly -- which bypassed the already-open redirect entirely: a second
    // copy of the app opened instead of jumping to the running one. Every
    // such site now goes through here, so the redirect is one decision in
    // one place. Desktop actions ("New window", "Open in private browsing")
    // deliberately stay direct: they ask for a NEW session, not "the app".
    function launchEntry(entry) {
        if (!entry)
            return;
        const label = entry.name ?? entry.id ?? "";
        // Same allowlist gate as openApp: a found window only redirects when
        // the app is one of the single-instance ones.
        const hit = root.findRunningEntry(entry);
        const running = hit && root.isSingleInstance(hit.class) ? hit : null;
        if (running) {
            root.focusRunningApp(running, label);
            return;
        }
        // Same tray rule as openApp (see showFromTray): a start-menu entry for
        // an app parked in the vault is answered by the tray, not by starting
        // the program again.
        if (root.showFromTray("", label, entry))
            return;
        // Launch and wait like openApp does: the card hides when the new
        // window arrives (showLoading snapshots the current window list as
        // the baseline), and times out quietly if the app never shows one.
        //
        // Through open.sh, NOT entry.execute(). The two look equivalent and
        // are not: open.sh records the pid it started in the compositor's
        // launcher registry, and that record is the ONLY thing that tells
        // "Bitwarden opened from the SUPER menu" (attach to the layout) from
        // "Bitwarden opened by the Brave extension" (a utility popup that
        // floats) -- same class, same title, same geometry either way.
        // DesktopEntry.execute() spawns the binary itself, records nothing,
        // and the window therefore stayed a popup for every desktop entry in
        // the launcher: this was the last path that bypassed open.sh, which
        // is why the fix looked complete (a manual open.sh run attached) and
        // the SUPER menu did not.
        const cmd = root.entryCommand(entry);
        if (cmd.length > 0) {
            root.launchPendingCommandDraft = cmd;
            root.showLoading(label);
            const allowed = root.allowTrayLaunch(cmd);
            Quickshell.execDetached(["bash", `${Directories.scriptPath}/launch/open.sh`, label, cmd, allowed]);
            return;
        }
        root.showLoading(label);
        entry.execute();
    }

    // A shell line equivalent to entry.execute(), or "" when the entry has no
    // usable command and Quickshell's own execute() has to do it.
    //
    // DesktopEntry.command is a PARSED argv list, not a string (the field
    // codes are already gone -- execute() is documented as ignoring them
    // anyway), so it is quoted back into a line here rather than pasted:
    // open.sh wants a shell line because launcher commands are shell lines,
    // and `kitty -e htop` style arguments have to survive the trip intact.
    // runInTerminal is deliberately NOT special-cased: execute() ignores it
    // on this Quickshell too, so routing through open.sh keeps today's
    // behaviour instead of silently changing which apps get a terminal.
    function entryCommand(entry) {
        if (!entry)
            return "";
        const argv = Array.from(entry.command ?? []);
        if (argv.length === 0)
            return "";
        const line = argv.map(root.shellQuote).join(" ");
        const dir = String(entry.workingDirectory ?? "").trim();
        if (dir.length > 0)
            return `cd ${root.shellQuote(dir)} && ${line}`;
        return line;
    }

    // One shell word, quoted the only way that is safe for every input:
    // single quotes, with embedded quotes spliced out and back in.
    function shellQuote(word) {
        return `'${String(word).replace(/'/g, `'\\''`)}'`;
    }

    // Find the window of an app whose DesktopEntry we are about to launch.
    // The reliable signals are on the entry itself: its id (a desktop file's
    // name, which Wayland windows echo as their class on this setup) and its
    // startupClass (what the entry ASKS to be matched by). The display name
    // is the segment-equality fallback, same rule as findRunningApp.
    function findRunningEntry(entry) {
        if (!entry)
            return null;
        const id = String(entry.id ?? "").trim().toLowerCase();
        const start = String(entry.startupClass ?? "").trim().toLowerCase();
        const name = String(entry.name ?? "").trim();
        if (id.length === 0 && start.length === 0 && name.length === 0)
            return null;

        const windows = HyprlandData.windowList ?? [];
        let nameHit = null;
        let floatHit = null;
        for (let i = 0; i < windows.length; i++) {
            const w = windows[i];
            if (w.mapped === false)
                continue;
            const cls = String(w.class ?? "").toLowerCase();
            const exact = (id.length > 0 && cls === id) || (start.length > 0 && cls === start);
            if (exact) {
                // Same class, several windows: a dialog of the app sits
                // beside its main window, and both answer this match. The
                // tiled one is the app; the floating one is whatever it is
                // currently asking the user about. Returning the first match
                // in list order meant "open Firefox" could land on an open
                // Save dialog.
                if (w.floating !== true)
                    return w;
                if (!floatHit)
                    floatHit = w;
                continue;
            }
            if (!nameHit && name.length > 0 && root.classSegmentMatch(String(w.class ?? ""), name))
                nameHit = w;
        }
        return floatHit ?? nameHit;
    }

    // Search-result objects (LauncherSearchResult) launch through here: app
    // results redirect like everything else, non-app results (calculator,
    // settings pages, commands) execute as they always did.
    function launchSearchEntry(result) {
        if (!result)
            return;
        const isApp = result.type === Translation.tr("App");
        if (!isApp) {
            result.execute();
            return;
        }
        const appId = String(result.id ?? "").trim();
        const entry = appId.length > 0 ? DesktopEntries.byId(appId) : null;
        if (entry) {
            root.launchEntry(entry);
            return;
        }
        result.execute();
    }

    // The window class an app search result launches as. Exact strings when
    // known (checked against the live client list); a `type:...` entry bypasses
    // the check entirely (scripts, settings pages: nothing to match on).
    readonly property var knownClasses: ({
        "kitty": "kitty",
        "foot": "foot",
        "alacritty": "Alacritty",
        "firefox": "firefox",
        "chromium": "chromium",
        "thunar": "thunar",
        "dolphin": "dolphin",
        "code": "Code",
        "spotify": "spotify",
        "discord": "discord",
        "telegram": "telegramdesktop",
        "steam": "steam",
        "obs": "com.obsproject.Studio",
        "freebuff": "@codebuff/freebuff-desktop",
        "freebuff-desktop": "@codebuff/freebuff-desktop",
        "thunderbird": "org.mozilla.Thunderbird",
        "thunderbird-desktop": "org.mozilla.Thunderbird",
        "whatsapp": "WhatsApp Desktop",
        "whatsapp-desktop": "WhatsApp Desktop",
        // The shell's own apps. Without these, "show Music" from the
        // background-apps panel went out as a bare execDetached and found no
        // running window to redirect to, because the name path could not match
        // a reverse-DNS class by segment ("music" is not a segment of
        // "io.github.matrix.IiMusic"). Listed here so the panel's launch is
        // indistinguishable from launching Music from the menu.
        "ii-music-app": "io.github.matrix.IiMusic"
    })

    // Find a window that belongs to the app about to be launched, or null.
    // `command` is the desktop entry's exec line or a raw command; `label` is
    // the human name shown in the UI. Class match wins over name match, and a
    // class match never fires for a command that carries arguments it could
    // re-open with (a `kitty -e htop` is a new kitty session, not "kitty").
    function findRunningApp(command, label) {
        const cmd = String(command ?? "").trim();
        if (cmd.length === 0)
            return null;
        const head = cmd.split(/\s+/)[0].toLowerCase().replace(/.*\//, "");
        // Arguments present: the user is asking for a specific session, not
        // "the app" -- always launch fresh.
        if (cmd.split(/\s+/).length > 1 && !/\.desktop$/i.test(cmd))
            return null;
        const cls = root.knownClasses[head];
        const name = String(label ?? "").trim().toLowerCase();
        if (!cls && name.length === 0)
            return null;

        const windows = HyprlandData.windowList ?? [];
        let nameHit = null;
        let floatHit = null;
        for (let i = 0; i < windows.length; i++) {
            const w = windows[i];
            if (w.mapped === false)
                continue;
            if (cls && String(w.class ?? "").toLowerCase() === cls.toLowerCase()) {
                // Tiled window of the same class wins over a floating one:
                // a dialog shares the app's class, and the app is what the
                // launcher entry means. See findRunningEntry.
                if (w.floating !== true)
                    return w;
                if (!floatHit)
                    floatHit = w;
                continue;
            }
            // Name path uses SEGMENT equality, not substring: a label matches
            // a class only if it equals the whole class or one of its parts
            // ("brave" matches "brave-browser"; "code" must NOT match
            // "@codebuff/freebuff-desktop" -- a plain substring test did
            // exactly that in testing).
            if (!nameHit && name.length > 0 && root.classSegmentMatch(String(w.class ?? ""), name))
                nameHit = w;
        }
        return floatHit ?? nameHit;
    }

    function classSegmentMatch(windowClass, name) {
        const w = windowClass.toLowerCase();
        const n = name.toLowerCase();
        if (w === n)
            return true;
        return w.split(/[@\/\-_ .]/).indexOf(n) >= 0;
    }

    // ── The single-instance allowlist ──────────────────────────────────────
    // Everything above is not a launch guard but a single-instance POLICY:
    // "this app is open, so clicking it again means go to that window". That
    // is right for Discord and wrong for almost everything else, and the
    // browser case is the one that made it obvious -- with a private window
    // up, clicking Brave answered "Brave is already open" and never opened a
    // normal window at all. The redirect is now opt-in, per app, in the
    // shell's config (`apps.singleInstance`); every other launch starts
    // fresh, always.
    readonly property var singleInstanceList: Config.ready
        ? (Config.options?.apps?.singleInstance ?? [])
        : []

    // ── The apps this shell SHIPS, which are single-instance by construction ──
    //
    // The config list above is for THIRD-PARTY apps, and it has to stay an
    // allowlist (applying the redirect to everything is what stopped "open
    // Brave" from ever giving a normal window). But the shell's own apps are
    // a different animal: `ii-music-app` is a Gio.Application with a stable
    // application_id, so the session bus makes it single-instance BY DESIGN
    // and a second `ii-music-app` only re-presents the window that is already
    // there -- it can never produce a second window.
    //
    // Which is exactly what made this bug: clicking Music in the launcher
    // while it was open found the running window (its class matches the
    // entry's StartupWMClass), was told by the policy that the app was not
    // single-instance, launched anyway, and then waited for a window that
    // could not exist. The bar said "Opening Music…" for the rest of the
    // session, over an app that was open and visible the whole time.
    //
    // So this list is a property of what those apps ARE, not a user setting,
    // and it is unioned into the policy rather than left to the config.
    readonly property var shellSingleInstance: ["io.github.matrix.iimusic", "WhatsApp Desktop"]

    // Is this window's class one of the single-instance apps? Matched whole
    // against the class and by class segment otherwise -- the same rule
    // findRunningApp/findRunningEntry use, so the entry the user clicked and
    // the window it is compared against can never disagree.
    function isSingleInstance(cls) {
        const c0 = String(cls ?? "").toLowerCase();
        // Tray-apps registry entries are always single-instance: they are the
        // shell's own tray icons (WhatsApp, Thunderbird), and a second binary
        // of either is a new session / a new profile -- the user did not ask
        // for that by clicking the already-open app again. This covers the
        // case the config list misses: a class that is in the tray registry
        // but not yet in apps.singleInstance (newly added tray app, or an app
        // whose class was only added to the registry). Belt-and-suspenders on
        // top of shellSingleInstance, which already contains WhatsApp.
        for (const e of TrayApps.registry) {
            const k = String(e.cls ?? "").toLowerCase();
            if (k.length > 0 && (c0 === k || c0.split("/").pop() === k.split("/").pop()))
                return true;
        }
        // The shell's own apps first: a reverse-DNS class is also matched by
        // its LAST segment ("iimusic"), because a window's class and a
        // desktop file's StartupWMClass do not always agree on the dots.
        for (const own of root.shellSingleInstance) {
            const o = String(own).toLowerCase();
            if (c0 === o || c0.split(".").pop() === o.split(".").pop())
                return true;
        }
        const list = root.singleInstanceList;
        if (!list || list.length === 0)
            return false;
        const c = c0;
        if (c.length === 0)
            return false;
        for (let i = 0; i < list.length; i++) {
            // ".desktop" tolerated so an id can be pasted straight out of the
            // launcher, and a dotted entry is then matched WHOLE: split into
            // segments, "com.tradingview.tradingview" would answer to a bare
            // "tradingview" and pull unrelated apps into the policy.
            const item = String(list[i] ?? "").toLowerCase().replace(/\.desktop$/, "").trim();
            if (item.length === 0)
                continue;
            if (c === item)
                return true;
            if (item.indexOf(".") >= 0)
                continue;
            if (root.classSegmentMatch(c, item))
                return true;
        }
        return false;
    }

    // Bring an already-running window to the user: switch to its workspace
    // (only when it is on another one), then focus it. A window that is
    // VISIBLE gets the "already open" notice card, which takes itself down;
    // a window that is PARKED in the tray vault is revealed instead, with no
    // card at all -- minimized is not open, and the reveal is its own feedback
    // (see the vault branch at the top of the body). Nothing is waited for
    // either way.
    function focusRunningApp(win, label) {
        // ── Parked in the tray vault? Reveal it, say nothing. ─────────────────
        // A minimized close-to-tray app is NOT "already open" -- it is parked,
        // and the launcher must behave like the tray icon here, which brings
        // the window out with no "%1 is already open" card at all: the window
        // appearing on the workspace, focused and attached, IS the feedback.
        // So this check runs FIRST and returns before a single loading-card
        // property below is touched. (It also fixes the pre-guard bug: a
        // vaulted window sits on a special workspace whose id is negative, so
        // the workspace switch further down was skipped and the focus after it
        // was this file's own documented silent no-op -- the card spoke, and
        // nothing came out.) The vault is special:tray exactly -- that is
        // where park()/smartClose put windows and what isHidden matches -- so
        // a window on any OTHER special workspace still takes the ordinary
        // path below instead of being swallowed by a show() that would find
        // nothing to reveal.
        if (win.workspace?.name === "special:tray") {
            const trayEntry = TrayApps.registry.find(e => e.cls === win.class);
            if (trayEntry) {
                TrayApps.show(trayEntry.cls);
                return;
            }
        }

        const name = String(label ?? "").trim();
        const what = name.length > 0 ? name : (win.class || Translation.tr("App"));
        root.loadingText = Translation.tr("%1 is already open").arg(what);
        root.loadingFailed = false;
        root.loadingPending = false;          // nothing to wait for
        root.launchFailsafeTicks = 0;         // and nothing to time out
        root.launchFailsafeVerdict = false;   // and no verdict to withdraw
        launchLateGraceTimer.stop();
        root.loadingInfo = true;              // notice, not a wait: no spinner
        root.loadingVisible = true;           // say it now, skip the grace delay
        root.loadingLine = false;             // nothing is loading: already there
        root.loadingFailFlash = false;
        loadingFailFlashTimer.stop();
        loadingGraceTimer.stop();
        loadingLineTimer.stop();
        loadingInfoTimer.restart();           // auto-hide quickly

        const addr = win.address?.startsWith("0x") ? win.address : `0x${win.address ?? ""}`;
        // This Hyprland build runs a Lua config: dispatch arguments are
        // evaluated as Lua expressions, and the classic string dispatchers
        // ("focuswindow address:…") do not exist -- hyprctl answers them
        // with "')' expected near 'address'". The working forms, verified
        // against the live compositor (and used by the config's own binds):
        //   hl.dsp.focus({ workspace = N })                 -- switch view
        //   hl.dsp.focus({ window = hl.get_window(…) })     -- focus window
        // The switch must come first: focusing a window that is not on the
        // active workspace is a silent no-op.
        if (win.workspace?.id >= 0)
            Hyprland.dispatch(`hl.dsp.focus({ workspace = ${win.workspace.id} })`);
        Hyprland.dispatch(`hl.dsp.focus({ window = hl.get_window("address:${addr}") })`);
        // Picked from the launcher, so it belongs in the layout -- including
        // when it is ALREADY open and already floating, which is the case
        // this whole branch exists for. open.sh never runs in that branch,
        // so the compositor's launcher sweep (which attaches freshly launched
        // windows by pid) never hears about this one; without this dispatch
        // "open Bitwarden from SUPER" just re-focused the floating window the
        // Brave extension had left behind.
        //
        // Ordering is the whole trick: the float dispatcher on this build is
        // focus-scoped, so the unset has to follow the focus of the target
        // window in the same dispatch queue, and it must not name an address
        // (`float({ action = ..., address = ... })` moved the wrong window).
        // Tiny windows are left alone: at that size it is a dialog or a
        // notification, and those float because they are supposed to. An
        // UNKNOWN size is not tiny -- the unset is the whole point of this
        // branch, and silently skipping it is how the bug survived.
        const sw = win.size?.width ?? 0;
        const sh = win.size?.height ?? 0;
        const tiny = sw > 0 && sh > 0 && (sw < 300 || sh < 200);
        if (win.floating === true && !tiny)
            Hyprland.dispatch(`hl.dsp.window.float({ action = "unset" })`);
    }

    // The program is up, or we have stopped waiting. Either way the card goes now
    // -- if the grace period had not run out yet, it never appears at all.
    function finishLoading() {        loadingGraceTimer.stop();
        loadingErrorTimer.stop();
        loadingLineTimer.stop();
        loadingFailFlashTimer.stop();
        // The window arrived (or the wait was called off): the backstop has
        // nothing left to judge, and a stale arming would fire a failure
        // verdict over an app that is demonstrably up.
        root.launchFailsafeTicks = 0;
        root.launchFailsafeVerdict = false;
        launchLateGraceTimer.stop();
        root.loadingPending = false;
        root.loadingFailed = false;
        root.loadingInfo = false;
        root.loadingVisible = false;
        root.loadingLine = false;
        root.loadingFailFlash = false;
        // The ceiling has nothing left to end.
        loadingWatchdogTimer.stop();
        // The bar's failure row and the held screen hairline end with it.
        root.loadingFailureInBar = false;
        root.screenFailureHold = false;
        // The sentence goes with the card. `loadingText` used to survive every
        // resolution, so the last app opened stayed in it for the rest of the
        // session -- and the bar's status row, whose value falls back to this
        // string, kept showing it ("Opening Discord" forever, reported
        // 2026-10-19). A finished wait has no sentence; the next launch puts
        // its own name back.
        root.loadingText = "";
        // The launch has resolved (window arrived or the failure was shown):
        // the duplicate-guard marks have no business outliving it.
        root.launchPendingCommands = [];
        launchPendingReset.stop();
    }


    // "That did not work" -- said in three places at once: the card carries
    // the sentence, the bar's under-line blinks the WHOLE width red (the
    // glance), and the thin whole-screen border flares once (ScreenFlash,
    // through pulseScreenFlash) so a failed launch also reaches eyes that
    // are nowhere near the small top bar -- requested 2026-10-18, after the
    // red had been reported as living "only in the status bar".
    function showLoadingError(text) {
        // The border is HELD, not flashed: one flat red edge for as long as
        // the bar carries the sentence (asked for 2026-10-19 -- the double
        // blink read as a second, louder event for a message already on the
        // bar). It keys on its own flag, so the one-shot pulse below still
        // belongs to the power failsafe and nothing else.
        root.screenFailureHold = true;
        root.loadingFailureInBar = true;
        loadingGraceTimer.stop();
        loadingLineTimer.stop();
        // The verdict is in: stop the clock that was going to produce it, or
        // the same failure is reported twice on two different schedules.
        root.launchFailsafeTicks = 0;
        launchLateGraceTimer.stop();
        root.loadingPending = false;
        root.loadingFailed = true;
        root.loadingInfo = false;
        root.loadingText = text ?? "";
        root.loadingVisible = true;
        // The launch failed outright: the duplicate-guard mark goes with it,
        // so the user's very next click is a fresh attempt.
        root.launchPendingCommands = [];
        launchPendingReset.stop();
        // The line stays up but switches to its failure face (see
        // loadingFailFlash) -- it stops charging, glows red briefly, and
        // takes itself down with the card.
        // The row is the whole surface for a launch failure now (see
        // loadingFailureInBar): no under-bar line, no blink, no card. The row
        // itself stays up until loadingErrorTimer retires the lifecycle.
        root.loadingLine = false;
        root.loadingFailFlash = false;
        loadingFailFlashTimer.stop();
        loadingErrorTimer.restart();
    }

    // Kept as the name callers use when they just want it gone.
    function hideLoading() {
        root.finishLoading();
    }

    Timer {
        id: loadingGraceTimer
        // Without this the timer would run at QML's one-second default and the
        // card would appear almost at once, which is the opposite of the point.
        interval: root.loadingGraceMs
        repeat: false
        running: false
        onTriggered: {
            // Still waiting? Then it is taking long enough to be worth saying so.
            if (root.loadingPending)
                root.loadingVisible = true;
        }
    }

    Timer {
        id: loadingErrorTimer
        interval: root.loadingErrorMs
        repeat: false
        running: false
        onTriggered: root.finishLoading()
    }

    // The island line's own (much shorter) grace: only a launch that is still
    // coming up after this is slow enough to be worth a sign.
    Timer {
        id: loadingLineTimer
        interval: root.loadingLineGraceMs
        repeat: false
        running: false
        onTriggered: {
            if (root.loadingPending && !root.loadingFailed && !root.loadingInfo)
                root.loadingLine = true;
        }
    }

    // The wait's ceiling (see loadingMaxMs). A download is the one thing that
    // may legitimately run for minutes -- it renews nothing and has its own
    // ending -- so it is exempt, and an expired ceiling does not touch it.
    Timer {
        id: loadingWatchdogTimer
        interval: root.loadingMaxMs
        repeat: false
        running: false
        onTriggered: {
            if (!root.loadingPending || root.loadingFailed || root.loadingInfo)
                return;
            if (root.downloadProgress >= 0)
                return;
            root.finishLoading();
        }
    }

    // The "already open" notice's own short clock.
    Timer {
        id: loadingInfoTimer
        interval: root.loadingInfoMs
        repeat: false
        running: false
        onTriggered: root.finishLoading()
    }

    // How long the red failure face holds before the line takes itself down.
    // Only the LINE ends here -- the corner card keeps its own, much longer
    // clock (loadingErrorTimer): the glance fades, the read stays.
    Timer {
        id: loadingFailFlashTimer
        interval: root.loadingFailFlashMs
        repeat: false
        running: false
        onTriggered: {
            root.loadingLine = false;
            root.loadingFailFlash = false;
        }
    }

    // A window that was not in the baseline is the program arriving.
    Connections {
        target: HyprlandData
        function onAddressesChanged() {
            // Two cases, and the ORDER matters. A wait still running ends the
            // ordinary way; a FAILSAFE VERDICT already on screen is WITHDRAWN
            // by the same observation, which is what makes the withdrawal feel
            // immediate instead of arriving up to `launchLateGraceMs` later
            // (the timer is the backstop for the case where the window's own
            // address never changes -- an app that maps a window it already
            // had, for instance -- and it re-checks the same list).
            //
            // Only a verdict the failsafe produced is withdrawn. A failure
            // `open.sh` reported is a fact about a process that died without
            // opening anything, and some unrelated window appearing later must
            // not retract it.
            if (!root.loadingPending && !root.launchFailsafeVerdict)
                return;
            for (const address of HyprlandData.addresses) {
                if (root.loadingWindowBaseline.indexOf(address) === -1) {
                    root.finishLoading();
                    return;
                }
            }
        }
    }

    // ── The failsafe's clock ───────────────────────────────────────────────
    // One shared tick for the whole thing rather than a single long Timer:
    // a tick can be CANCELLED (the app turned up) between two firings without
    // the timer object knowing, and the tick count is the same thing the
    // `display` IPC disarms with. 250ms is fine enough that the failsafe
    // fires within a quarter second of its deadline and coarse enough to be
    // invisible (it does nothing at all on every healthy launch).
    Timer {
        id: launchFailsafeTimer
        interval: root.launchFailsafeTickMs
        repeat: true
        running: root.launchFailsafeTicks > 0
        onTriggered: {
            if (!root.loadingPending || root.loadingFailed || root.loadingInfo) {
                root.launchFailsafeTicks = 0;
                return;
            }
            if (--root.launchFailsafeTicks > 0)
                return;
            // Out of time and still nothing. Report it exactly the way a dead
            // command is reported -- one failure face for the whole desktop --
            // and then KEEP WATCHING (see launchLateGraceMs), because ten
            // seconds is a line drawn in the sand rather than a fact about the
            // app. A window that turns up inside the grace withdraws it.
            root.launchFailsafeTicks = 0;
            const name = root.launchFailsafeName || root.loadingText || "";
            // HOW LONG it waited, measured: a launch on the open.sh path has
            // had its clock renewed for as long as the app was alive, so a
            // verdict reached now can be a minute after the click. Printing the
            // interval (ten) would be printing the rule, not the fact.
            const waited = Math.max(1, Math.round(
                (root.loadingWaitStartedAt > 0
                    ? Date.now() - root.loadingWaitStartedAt
                    : root.launchFailsafeMs) / 1000));
            // Marked BEFORE the report, because showLoadingError is also the
            // path open.sh's own verdict takes and only THIS one may be
            // withdrawn later (see the address watcher).
            root.launchFailsafeVerdict = true;
            // And the reason, because "Couldn't open X" alone cannot be acted
            // on. This verdict is the DESKTOP's rather than the app's -- no
            // window ever appeared, and the clock is the only thing saying so.
            root.showLoadingError(
                `${Translation.tr("Couldn't open")}${name.length > 0 ? " " + name : ""}`
                + ` (${Translation.tr("no window after")} ${waited}s)`);
            launchLateGraceTimer.restart();
        }
    }

    // Withdraws a timeout verdict that turned out to be wrong. This is the
    // BACKSTOP half of the withdrawal: the address watcher (onAddressesChanged)
    // normally retracts the card the instant a new window appears, and this
    // re-checks the same list once more at the end of the grace window, for
    // the case the watcher cannot see -- an app that maps a window it already
    // had, so no address ever changes. Long enough to outlast the failure card
    // it is cancelling (loadingErrorMs is 12s), so an app that arrives at
    // second 13 is still caught, and bounded so the check cannot outlive the
    // session.
    Timer {
        id: launchLateGraceTimer
        interval: root.launchLateGraceMs
        repeat: false
        onTriggered: {
            // Only OUR verdict is withdrawn: a failure that arrived in the
            // meantime from somewhere else is not this timer's to retract.
            if (!root.loadingFailed)
                return;
            for (const address of HyprlandData.addresses) {
                if (root.loadingWindowBaseline.indexOf(address) === -1) {
                    // It opened after all. Take the failure face down rather
                    // than leaving the desktop claiming otherwise.
                    root.hideLoading();
                    return;
                }
            }
        }
    }

    // Anything can raise it: the launcher, the bar's buttons, or a script.
    //
    //   qs -c ii ipc call loading display "Opening the printer settings"
    //   qs -c ii ipc call loading dismiss
    //   qs -c ii ipc call loading error "Couldn't open the printer settings"
    //
    // `display` is the forced form -- used by scripts, and for work that has no
    // window of its own to wait for -- so it skips the grace period. Whoever
    // calls it owns the card from then on: it ends with `dismiss`, with `error`,
    // or with a window appearing, and there is no timer waiting to take it away
    // behind their back.
    //
    // `error` is the counterpart and reports a launch that failed. It only shows
    // if something is actually still being waited for: a program that opened its
    // window and exited non-zero an hour later is a program closing, not a launch
    // failing.
    //
    // `fail` is the same message without that check, for a caller that knows the
    // launch failed and has no window to be judged against -- the task manager,
    // which opens a card inside the overlay rather than a window, can fail when
    // nothing was ever "waiting" for it in this process (a hardware tile in the
    // settings app asks for it from over there). The check cannot help in that
    // case and would only suppress the message.
    //
    // All of it lives here rather than on the indicator's own window: this is a
    // singleton, so there is exactly one of it no matter how many copies of the
    // indicator exist.
    IpcHandler {
        target: "desktopEdit"

        function toggle(): void {
            root.toggleDesktopEditMode();
        }
        function enter(): void {
            root.enterDesktopEditMode();
        }
        function exit(): void {
            root.exitDesktopEditMode();
        }
        function state(): string {
            // Diagnostics beyond the booleans: the shell's own belief about
            // the active workspace and what lives there, next to which the
            // compositor's truth can be compared (an 'emptyDesktop=false'
            // that contradicts hyprctl is now decidable in one call).
            const wid = HyprlandData.activeWorkspace?.id;
            const onShellWs = HyprlandData.windowList.filter(
                w => (w.workspace?.id ?? -1) === wid).length;
            return `mode=${root.desktopEditMode} emptyDesktop=${root.activeDesktopEmpty}`
                + ` sidebarWasOpen=${root.editModeSidebarWasOpen} attempts=${root.editModeGuardAttempts}`
                + ` shellWs=${wid ?? "null"} winsOnShellWs=${onShellWs}`;
        }
    }

    IpcHandler {
        target: "loading"

        function display(text: string): void {
            root.loadingText = text ?? "";
            root.loadingFailed = false;
            root.loadingInfo = false;
            root.loadingFailFlash = false;  // a new wait is never a failure
            loadingFailFlashTimer.stop();
            // The baseline of "which windows already exist", so the
            // address watcher can tell the window we are WAITING FOR from the
            // ones that were already on screen. Without it the baseline is
            // whatever the last launch left behind -- empty, if nothing has
            // launched yet -- and then EVERY address looks new, so the watcher
            // called finishLoading() on the next address change and tore the
            // line down a frame after it was raised. A scripted launch (which
            // is exactly what uses `display`) therefore never got to show its
            // charge at all. showLoading() has always done this; this path did
            // not, and the two have to agree or one of them lies.
            root.loadingWindowBaseline = HyprlandData.addresses.slice();
            root.loadingPending = true;
            root.loadingVisible = true;
            // The forced form skips the grace period on purpose, so the line
            // comes up with it -- otherwise `display` would ask for a wait
            // indicator and get nothing on the island for 600ms.
            root.loadingLine = true;
            loadingGraceTimer.stop();
            loadingErrorTimer.stop();
            loadingLineTimer.stop();
            // A scripted wait has no failsafe, so the ceiling below is the ONLY
            // thing that can promise it ends (see loadingMaxMs).
            loadingWatchdogTimer.restart();
            // ...and it skips the failsafe for the same reason in reverse: the
            // caller OWNS this card (see the doc comment above -- it ends with
            // `dismiss` or `error`, and there is no timer waiting to take it
            // away behind their back). Arming one here would put exactly that
            // timer back, and would judge a script's wait by a rule meant for
            // a program that was supposed to open a window.
            root.launchFailsafeTicks = 0;
            root.launchFailsafeVerdict = false;
            launchLateGraceTimer.stop();
        }
        function dismiss(): void {
            root.finishLoading();
        }
        // The guarded ending: retire the wait only while it is still OURS.
        // A caller that raised a wait and then hands the launch to something
        // it cannot watch (the Files window hands a file to `gio open`, whose
        // process exits in milliseconds) ends it with this, so a wait raised
        // afterwards by someone else -- a real app launch, a download -- is
        // never taken down by a late timer belonging to an older announce.
        function dismissIf(text: string): void {
            const wanted = String(text ?? "");
            if (wanted.length === 0)
                return;
            if (root.loadingPending && root.loadingText === wanted)
                root.finishLoading();
        }
        function error(text: string): void {
            if (!root.loadingPending)
                return;
            root.showLoadingError(text);
        }
        // Arm the launch failsafe without launching anything: the same wait
        // showLoading raises, with no window coming and no program to report
        // one. This is how the backstop is exercised --
        //   qs -c ii ipc call loading arm "Music"
        // -- and it is also what a caller with work that has no window of its
        // own but DOES want a deadline uses, instead of `display` (which never
        // arms it).
        function arm(text: string): void {
            root.showLoading(text ?? "");
            // No grace: the point of this form is that the line is up now and
            // the verdict is `launchFailsafeMs` away.
            root.loadingVisible = true;
            root.loadingLine = true;
            loadingGraceTimer.stop();
            loadingLineTimer.stop();
        }
        // Read the backstop's own state, for the same reason.
        function state(): string {
            return `pending=${root.loadingPending} text="${root.loadingText}"`
                + ` ticks=${root.launchFailsafeTicks}/${root.launchFailsafeTicksMax}`
                + ` armedName="${root.launchFailsafeName}"`
                + ` verdict=${root.launchFailsafeVerdict}`
                + ` failed=${root.loadingFailed} failFlash=${root.loadingFailFlash}`
                + ` inBar=${root.loadingFailureInBar} hold=${root.screenFailureHold}`
                + ` cap=${root.loadingMaxMs}`;
        }
        function fail(text: string): void {
            root.showLoadingError(text);
        }

        // ── A launch that is still alive is still a launch ────────────────
        //
        // `open.sh` -- the app's own parent -- calls this every few seconds
        // while the process it started is still running. It is the answer to
        // the failsafe's one blind spot: this shell can only see WINDOWS, so
        // "no window after ten seconds" cannot tell a slow cold launch from a
        // dead one, and it has called slow apps broken. The process that knows
        // the difference is the parent; the clock is renewed from there, the
        // verdict stays open, and if the app then exits without a window the
        // parent reports the real reason -- its exit status and its own last
        // line of output.
        //
        // It cannot un-say a failure the user is already reading: a renewal
        // that arrives after a verdict is ignored.
        function renew(text: string): void {
            if (!root.loadingPending || root.loadingFailed || root.loadingInfo)
                return;
            if (text && text.length > 0)
                root.launchFailsafeName = text;
            root.launchFailsafeTicks = root.launchFailsafeTicksMax;
        }
        // Download progress: name + 0..1 fraction. frac >= 1 or a negative
        // frac finishes the download face and clears the line.
        function progress(name: string, frac: real): void {
            if (frac < 0 || frac >= 1) {
                // Capture BEFORE clearing: an app-launch line that happens to
                // be live must survive a download ending (and vice versa the
                // download face only ever ends its own line).
                const hadDownload = root.downloadName !== "";
                root.downloadProgress = -1;
                root.downloadName = "";
                if (hadDownload && root.loadingLine)
                    root.finishLoading();
                return;
            }
            root.downloadName = name;
            root.downloadProgress = Math.max(0, Math.min(1, frac));
            root.loadingText = `Downloading ${name}`;
            root.loadingFailed = false;
            root.loadingInfo = false;
            root.loadingFailFlash = false;
            // Same reason as `display`: without a fresh baseline the window
            // watcher fires on an unrelated address change and ends the wait
            // the download just started.
            root.loadingWindowBaseline = HyprlandData.addresses.slice();
            root.loadingPending = true;
            root.loadingVisible = false;
            root.loadingLine = true;
            loadingGraceTimer.stop();
            loadingErrorTimer.stop();
            loadingLineTimer.stop();
            // A download is not a launch and has no window coming, so the
            // launch failsafe must never judge it (see `display` above).
            root.launchFailsafeTicks = 0;
            root.launchFailsafeVerdict = false;
            launchLateGraceTimer.stop();
        }
    }

    // ── "Release to close" chip for the four-finger close drag ─────────────────
    // The 1:1 close gesture (four fingers down) carries the window past the
    // bottom edge of the screen before it commits. Normal window drags are
    // SUPER+mouse and normal drags can park a window off-screen, so the drag in
    // progress is recognised by movement, not position: while the focused window
    // is past the edge AND still moving (and SUPER is NOT held, which would mean
    // an ordinary drag), the little loading card says what letting go will do --
    // a two-word hint, nothing bigger. The moment the fingers stop, the window is
    // gone, or it snaps back, the chip goes away.
    readonly property string closeDragHintText: Translation.tr("Release to close")
    // Position check: focused window whose body extends past the screen edge,
    // top or bottom, without SUPER held (SUPER means an ordinary drag).
    readonly property bool closeDragCandidate: {
        if (root.superDown) return false;
        const addr = Hyprland.activeToplevel?.HyprlandToplevel?.address;
        if (!addr) return false;
        const win = HyprlandData.windowByAddress?.[`0x${addr}`];
        if (!win || !win.at || !win.size) return false;
        const mon = HyprlandData.monitors.find(m => m.id === win.monitor || m.name === win.monitor);
        const screenBottom = mon ? mon.y + mon.height : 1080;
        return (win.at[1] + win.size[1]) > screenBottom - 40 || win.at[1] < -40;
    }
    // Movement check: a parked window is not a drag. Sampled on a short timer;
    // anything that has moved since the last sample counts as being dragged.
    property bool closeDragInProgress: false
    property real closeDragLastY: 0
    onCloseDragCandidateChanged: {
        if (!closeDragCandidate) {
            closeDragInProgress = false;
        } else {
            const addr = Hyprland.activeToplevel?.HyprlandToplevel?.address;
            const win = addr ? HyprlandData.windowByAddress?.[`0x${addr}`] : null;
            closeDragLastY = win?.at?.[1] ?? 0;
            closeDragSampler.restart();
        }
    }
    Timer {
        id: closeDragSampler
        interval: 80
        repeat: true
        running: root.closeDragCandidate
        onTriggered: {
            const addr = Hyprland.activeToplevel?.HyprlandToplevel?.address;
            const win = addr ? HyprlandData.windowByAddress?.[`0x${addr}`] : null;
            const y = win?.at?.[1];
            if (y === undefined) {
                root.closeDragInProgress = false;
                return;
            }
            // Latch on the first movement: fingers can pause mid-drag without
            // the chip blinking off. Only the candidate check (window back
            // on-screen / gone) clears it.
            if (!root.closeDragInProgress && Math.abs(y - root.closeDragLastY) > 2)
                root.closeDragInProgress = true;
            root.closeDragLastY = y;
        }
    }
    onCloseDragInProgressChanged: {
        if (closeDragInProgress) {
            loadingText = closeDragHintText;
            loadingFailed = false;
            loadingPending = false;
            loadingVisible = true;
            // The hint is not a launch, so the launch failsafe has nothing to
            // say about it; disarmed explicitly rather than left to expire.
            launchFailsafeTicks = 0;
            launchFailsafeVerdict = false;
            launchLateGraceTimer.stop();
            // A launch that was sweeping when the drag started is not what the
            // hint is about; the line would also be wrong to leave running.
            loadingLine = false;
            loadingGraceTimer.stop();
            loadingErrorTimer.stop();
            loadingLineTimer.stop();
        } else if (loadingText === closeDragHintText) {
            // Only clear it if it is still ours -- a real "Opening..." message
            // that raced in mid-drag must survive.
            finishLoading();
        }
    }

    // The bare SUPER key: the numbers hint while it is held, and the ARMING that
    // makes a quick tap open the app search. It no longer arms the desktop-grid
    // hold (2026-10-14): that belongs to SUPER+Space, below.
    GlobalShortcut {
        name: "workspaceNumber"
        description: "Hold to show workspace numbers, release to show icons"

        onPressed: {
            root.superDown = true
            root.superPressEdge(false)
        }
        onReleased: {
            root.superDown = false
            root.superReleaseEdge()
        }
    }

    // ── SUPER + SPACE: the desktops, on its own key (2026-10-14, retuned
    //    2026-10-15 -- see the press edge below) ──────────────────────────
    //
    // The one command that used to be reachable only by holding the bare
    // modifier: press it and the desktop grid comes up; press it again and it
    // goes away. The numbers hint shows while the chord is down, exactly as it
    // does on a bare-SUPER hold.
    //
    // IT TOGGLES ON THE PRESS, like the four-finger swipe it stands in for. It
    // was a 300 ms hold until 2026-10-15, and a quick tap did nothing at all --
    // which is the one thing a key that opens a view must not do, and it made
    // the key and the swipe behave differently for no reason. A hold still
    // works, trivially: the press has already done it.
    //
    // A shortcut of its OWN, not a second bind of `workspaceNumber`, and that is
    // the point of it: a GlobalShortcut reports which NAME fired, so this is how
    // the shell can tell a SUPER+Space press from a bare SUPER press -- which is
    // what keeps the numbers hint and the search card on the bare key and the
    // grid on this one.
    GlobalShortcut {
        name: "superHold"
        description: "Toggle the desktops"

        onPressed: {
            root.superDown = true
            root.superPressEdge(true)
        }
        onReleased: {
            root.superDown = false
            root.superReleaseEdge()
        }
    }

    // ═══ Re-arm the SUPER-tap candidate on the PRESS edge ═════════════════════
    //
    // The launcher opens on the RELEASE of a SUPER tap: `searchToggleRelease`
    // (Overview.qml) toggles it only while `superReleaseMightTrigger` is still
    // true, and the release-interrupt -- which every SUPER chord in
    // custom/keybinds.lua trips -- clears that flag so no chord can open the
    // search panel on the way up. The flag therefore has to be ARMED at the
    // start of each SUPER hold, and arming it from `searchToggleRelease`'s own
    // `onPressed`, which is where it looks like it belongs, does not work on
    // this build:
    //
    //   * `SUPER + SUPER_L` is registered with modmask SUPER, and the tap that
    //     RAISES SUPER is the very event that creates that modifier -- so the
    //     press bind never matches. Read off the running shell, a tap logs a
    //     `searchToggleRelease` RELEASE and never a PRESS.
    //   * With nothing arming the flag, the only writer left that ever cleared
    //     it was the close path in AppSearchOverlay.qml (which clears it so a
    //     stale in-flight release cannot re-open the menu). The next tap was
    //     then spent re-arming instead of opening, and one tap in three did
    //     nothing at all -- measured with real input on the wire: open, close,
    //     *nothing*, open, close, *nothing*.
    //
    // `superDown` IS reliable on that same tap: it is set from the bare
    // `SUPER_L`/`SUPER_R` bind, which is registered with `ignore_mods` and so
    // matches the press whatever modifiers are held. That is the edge to arm
    // from -- the same edge the bar already trusts to show workspace numbers
    // while SUPER is held.
    //
    // The ordering is the part that makes it work, so it is worth stating: a
    // tap delivers the press first, then the shortcut's RELEASE, and only then
    // `superDown = false`. Arming on the press edge therefore always lands before
    // the release that reads it. Nothing happens on the falling edge -- a chord
    // must be free to clear the flag and keep it cleared.
    //
    // The edges are called BY the two shortcuts above rather than derived from
    // `superDown` changing, because the two have to be told apart: a bare-SUPER
    // press arms the tap and stops there, while a SUPER+Space press silences the
    // tap and toggles the grid.
    function superPressEdge(fromHoldChord: bool) {
        // ── A press while something the SUPER tap opened is still up ──────
        // "Press SUPER again and you are back where you were": that closes the
        // desktop grid, or the app search card, ON THE PRESS and silences the
        // release in the same breath. Doing it on the release instead (which
        // is what the card does on its own) would leave a press-and-HOLD to
        // start the grid on top of the card, and either way the release would
        // then toggle the card open a beat after the grid went down.
        //
        // `superDismissedOnPress` is what makes that move a TOGGLE on a chord
        // like SUPER+Space: the bare SUPER press gets here first and closes the
        // grid, and the chord's press -- the other half of the same tap -- would
        // otherwise open it again, which reads as the key doing nothing.
        if (root.desktopOverviewOpen) {
            root.desktopOverviewOpen = false;
            root.superReleaseMightTrigger = false;
            root.superDismissedOnPress = true;
            superHoldTimer.stop();
            return;
        }
        if (root.appSearchOverlayOpen) {
            root.appSearchOverlayOpen = false;
            root.superReleaseMightTrigger = false;
            root.superDismissedOnPress = true;
            superHoldTimer.stop();
            return;
        }
        if (fromHoldChord) {
            // ── The toggle half, on the PRESS edge ─────────────────────────
            //
            // The chord raised the grid only after a 300 ms hold until
            // 2026-10-15, and a tap did nothing -- so it did not do what the
            // four-finger swipe does (one action, grid up) and felt broken to
            // anyone who did not know to keep holding. The press edge now
            // toggles it outright.
            //
            // The CLOSE half is done above, by the `desktopOverviewOpen`
            // branch at the top of this function (which is also where the
            // app-search card is closed the same way). It is the BARE SUPER
            // press that reaches it, because one tap fires both shortcuts --
            // so this branch only fires the open half when that dismissal did
            // not just happen. Without the check the close was undone in the
            // same instant, which is what made SUPER+Space look dead on an open
            // grid.
            //
            // The release still must not open the app search card: the SUPER
            // release that ends this chord is not a tap. The chord-list bind in
            // custom/keybinds.lua trips the same interrupt, so dropping the
            // candidate here as well keeps the outcome identical whichever of
            // the two the compositor reports first. No timer is armed: there is
            // no hold left to measure.
            root.superReleaseMightTrigger = false;
            root.superHoldFromChord = true;
            superHoldTimer.stop();
            // This press sequence already put something away: the tap was a
            // dismissal, and opening the grid here would be the second half of
            // a toggle nobody asked for.
            if (root.superDismissedOnPress) {
                root.superDismissedOnPress = false;
                return;
            }
            // ── The grid opens PLAIN: no desktop in hand (2026-10-16) ──
            //
            // This key used to come up HOLDING the desktop under the pointer
            // (2026-10-15), exactly as the SUPER + four-finger swipe down did.
            // That is asked away now, on both sides -- the gesture is deleted
            // from custom/general.lua, and this press no longer raises a lift
            // -- so the grid arrives empty-of-hand: click a card to switch
            // desktop, click-hold one to reorder it, and nothing is carried
            // because nothing was picked up.
            //
            // The lift MACHINERY stays whole (the signal above, the flag it
            // sets, the `desktopOverviewGrab` global the gesture used to
            // dispatch). It is the capability, the IPC `desktopOverview lift`
            // still drives it, and re-binding it is one line here -- which is
            // the reason this is a removed CALL and not a removed mechanism.
            root.desktopOverviewOpen = true;
            return;
        }
        root.superReleaseMightTrigger = true;
        root.superHoldFromChord = false;
        root.superDismissedOnPress = false;
        superHoldTimer.restart();
    }

    // The falling edge is either the tap or the end of the hold. If the hold
    // never fired, this is where the app search card is about to open (the
    // bare-SUPER release does that), so the hold has nothing left to do.
    function superReleaseEdge() {
        root.superHoldFromChord = false;
        // The press sequence is over however it ended, so the dismissal mark
        // goes with it: the next chord press is a fresh action, not the second
        // half of this one.
        root.superDismissedOnPress = false;
        superHoldTimer.stop();
    }

    // ═══ The bare SUPER hold: it only calls off its own tap ══════════════════
    //
    // One timer, and one thing it does: a bare SUPER press that outlives the
    // interval is someone looking at the workspace numbers, so the release that
    // follows opens nothing. The app search card belongs to the tap alone.
    //
    // It used to have a SECOND arming source: SUPER+Space armed it to raise the
    // desktop grid 300 ms in. That is gone (2026-10-15) -- the chord toggles the
    // grid on its press edge now, in superPressEdge above, so there is no hold
    // left for this timer to measure. The grid was never the bare key's job:
    // the bare SUPER key keeps the numbers hint and its tap keeps the search
    // card, and a slow bare press raises the grid no longer.
    //
    // WHY A TIMER AND NOT A KEYBIND. Nothing in either layer can be asked "is
    // something else down while SUPER is held". Hyprland's Lua config exposes
    // no key event to hook (only actions to bind), and this singleton only ever
    // hears the two edges of the bare-SUPER bind -- the same edges a chord
    // produces. So a press that is meant to be read as a hold is measured from
    // the press edge.
    //   * it fires only while the key is still DOWN. Every SUPER chord in
    //     custom/keybinds.lua trips the release-interrupt, which clears
    //     `superReleaseMightTrigger` and so stops the timer -- which is what a
    //     hold that is really a shortcut (SUPER+A, SUPER+arrow, a SUPER-drag)
    //     deserves: it is not a look at the numbers.
    //   * firing clears the flag itself, so the release that follows does not
    //     ALSO toggle the app search card open behind it.
    //   * a release before the timer stops it. That is the tap, and the card
    //     stays the tap's.
    //
    // 300 ms is long enough that a deliberate tap (measured over real input:
    // ~90-160 ms) can never reach it, and short enough to feel like the key
    // did it rather than like a delay.
    readonly property int superHoldMs: 300

    Timer {
        id: superHoldTimer
        interval: root.superHoldMs
        repeat: false
        onTriggered: {
            // Re-checked rather than trusted: the key can have been let go
            // inside the interval, and another SUPER chord can have cancelled it.
            if (!root.superDown)
                return;
            if (!root.superReleaseMightTrigger)
                return;
            // The press outlived the tap, so the release that follows opens
            // nothing. Nothing else happens -- the grid is the chord's, and the
            // chord has already opened it by the time anyone holds this long.
            root.superReleaseMightTrigger = false;
        }
    }

    // Every chord trips the interrupt (see the SUPER-chord block in
    // custom/keybinds.lua). A bare-SUPER hold that has not fired yet has to go
    // with it, or holding SUPER+A for a third of a second would look like a
    // deliberate hold of the bare key.
    //
    // The chord is no longer an exemption here (`superHoldChordHeld` is gone
    // with the hold it belonged to): the chord's press clears the tap flag
    // because its release must not open the search card, and stopping a timer
    // the chord never armed costs nothing.
    onSuperReleaseMightTriggerChanged: {
        if (!root.superReleaseMightTrigger)
            superHoldTimer.stop();
    }

    // ── The power failsafe's alert channel ──────────────────────────────
    // scripts: ~/.local/bin/power-failsafe watches the kernel's PSI (pressure
    // stall information) and, when the machine has been genuinely stalling
    // for several consecutive samples, flips the power profile to performance
    // so the lag cannot persist. When it does, it calls in here so the user
    // SEES it: the corner card carries the sentence, the bar's under-island
    // line flashes red -- the same "something needs reading" pair the launch
    // failure uses.
    //
    // Deliberately NOT showLoadingError(): that also clears
    // launchPendingCommands, and a failsafe alert firing mid-launch would
    // silently unguard an in-flight duplicate-guard. This is the same visual
    // state without touching launch bookkeeping.
    // ── The whole-screen border flash ───────────────────────────────────
    // ScreenFlash.qml watches `screenFlashTick` and blinks a thin border
    // around the entire screen once per change. Anything that must be seen
    // even when the eye is in the middle of the screen (not on the bar)
    // pulses this; the failsafe's alerts below are the callers.
    property int screenFlashTick: 0
    // What the border says, not just that it blinks: fire orange = the
    // machine was pushed into performance, green = it came home on its own.
    // "error" keeps the theme's error red for launch failures and the like.
    readonly property string screenFlashError: "error"
    readonly property string screenFireOrange: "fire"
    readonly property string screenFlashGreen: "green"
    property string screenFlashKind: "error"
    // The three colours the border can wear. Green and fire have no theme
    // slots (Material here defines error but no success), so they are picked
    // to read at a glance: a saturated GO and a hot warning amber.
    readonly property color screenFlashColorError: Appearance.colors.colError
    readonly property color screenFlashColorFire: "#ff6d1f"
    readonly property color screenFlashColorGreen: "#43d17c"
    function pulseScreenFlash(kind) {
        screenFlashKind = kind ?? "error";
        screenFlashTick++;
    }

    function failsafeAlert(text) {
        root.pulseScreenFlash(root.screenFireOrange);
        root.loadingText = Translation.tr(text ?? "");
        // The failsafe's alert is a card and an orange pulse, not the bar row.
        root.loadingFailureInBar = false;
        root.screenFailureHold = false;
        root.loadingPending = false;
        root.loadingFailed = true;
        root.loadingInfo = false;
        root.loadingVisible = true;
        root.loadingLine = true;
        root.loadingFailFlash = true;
        loadingFailFlashTimer.restart();
        failsafeCardTimer.restart();
    }

    // The mirror image of failsafeAlert: the machine has been quiet long
    // enough that the failsafe backed OUT of performance on its own. A calm
    // event, said calmly: green border blink, no red card, no alarm colour
    // anywhere -- a short neutral notice with its own modest clock.
    function failsafeRestore(text) {
        root.pulseScreenFlash(root.screenFlashGreen);
        root.loadingText = Translation.tr(text ?? "");
        root.loadingPending = false;
        root.loadingFailed = false;
        root.loadingInfo = true;
        root.loadingVisible = true;
        root.loadingLine = false;
        root.loadingFailFlash = false;
        loadingInfoTimer.restart();
    }

    // The failsafe card's own clock. Launch-failure cards keep the shared
    // 12 s (loadingErrorMs) -- a failed click has no second chance, so the
    // sentence lingers. The failsafe's card repeats by design (300 s
    // cooldown) and the notification carries the same sentence, so it gets
    // 1.5 s less on screen before it takes itself down.
    readonly property int failsafeCardMs: 10500
    Timer {
        id: failsafeCardTimer
        interval: root.failsafeCardMs
        repeat: false
        running: false
        onTriggered: root.finishLoading()
    }

    // ── The top-right signal card ─────────────────────────────────────────
    // One short label ("Copied", "Image copied", "Cursor reclaimed") and the
    // bare glyph that names its kind. The state lives here because the callers
    // are not one widget: Cliphist copies, fix-mouse.sh reclaims the pointer,
    // and a script may say something of its own. SignalToast.qml draws it; this
    // is the only place that decides what is on it and for how long.
    //
    // REPLACED, not queued: a second say() rewrites the label and restarts the
    // clock. `seq` is what the card watches, so even the SAME label said twice
    // plays its entrance again instead of looking stuck.
    //
    // 1200ms is the copy toast's tuned hold; callers that need longer (the
    // cursor notice is a two-word sentence, not a glance) pass their own.
    property string signalToastText: ""
    property string signalToastIcon: "info"
    property int signalToastDurationMs: 1200
    property int signalToastSeq: 0
    property bool signalToastVisible: false

    function showSignalToast(text, icon, ms) {
        const label = String(text ?? "").trim();
        if (label.length === 0)
            return;
        root.signalToastText = label;
        root.signalToastIcon = (icon && String(icon).length > 0) ? String(icon) : "info";
        root.signalToastDurationMs = (ms > 0) ? ms : 1200;
        root.signalToastVisible = true;
        root.signalToastSeq++;
    }

    function hideSignalToast() {
        root.signalToastVisible = false;
    }

    IpcHandler {
        target: "signalToast"

        // Default icon, for a caller with nothing more specific to say:
        //   qs -c ii ipc call signalToast say "Saved"
        function say(text: string): void {
            root.showSignalToast(text, "check_circle", 1500);
        }

        // Named glyph, for a caller that knows its kind:
        //   qs -c ii ipc call signalToast sayIcon "Cursor reclaimed" mouse
        function sayIcon(text: string, icon: string): void {
            root.showSignalToast(text, icon, 1500);
        }

        function state(): string {
            return `visible=${root.signalToastVisible} seq=${root.signalToastSeq}`
                + ` text=${JSON.stringify(root.signalToastText)}`
                + ` icon=${JSON.stringify(root.signalToastIcon)}`
                + ` ms=${root.signalToastDurationMs}`;
        }
    }

    IpcHandler {
        target: "failsafe"

        function alert(text: string): void {
            root.failsafeAlert(text);
        }

        // The "stood down" side: performance is no longer needed, the
        // failsafe switched back to power-saver on its own.
        function restore(text: string): void {
            root.failsafeRestore(text);
        }

        // Test the border alone, in any colour, without touching the corner
        // card: `qs -c ii ipc call failsafe flash fire`.
        function flash(kind: string): void {
            root.pulseScreenFlash(kind);
        }
    }
}
