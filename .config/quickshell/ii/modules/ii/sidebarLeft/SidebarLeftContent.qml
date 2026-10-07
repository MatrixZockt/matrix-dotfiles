import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.sidebarRight.todo
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Qt.labs.synchronizer

Item {
    id: root
    required property var scopeRoot
    property int sidebarPadding: 10
    anchors.fill: parent
    // The AI chat tab is gone: it is not used here, and its panel was the source
    // of the TypeError spam in the shell log.
    //
    // Notifications used to be this sidebar's first tab as well; they are gone
    // again now -- the right sidebar owns them (its bottom half is the
    // notification panel, which is where they were before the left-sidebar
    // experiment). Keeping them in both places meant two lists rendering the
    // same items, and the left one started the tab bar crowding.
    property bool notificationsEnabled: false
    // The To Do list lives here now, as its own tab.
    //
    // In the right sidebar it was one tab of the BottomWidgetGroup, which is
    // 350px whatever the sidebar's height is -- a fixed box in the middle of the
    // screen's full height. As a tab here it fills the sidebar the way the
    // notifications, translator and anime pages do, which is the "extended"
    // shape a task list wants: room for the whole list, not a scrollbar.
    // The Widgets board is gone: deleted outright, tab and all. Its cards
    // duplicated what the desktop widgets, the right sidebar and the island
    // already owned.
    property bool widgetsEnabled: false
    property bool todoEnabled: true
    // Ports: every bound TCP/UDP port with start/stop/delete. Off by
    // default so the tab bar only grows when the user wants it.
    property bool portsEnabled: true
    // Music: the raw downloaded songs + playback control. The WHOLE music
    // interface — there is no music application window; the headless mpv
    // daemon (MusicPlayer) is the engine.
    property bool musicEnabled: true
    // The Timer tab is gone: the pomodoro lives in the widgets board (its own
    // card) and in the island's focus view, which is where a timer belongs --
    // a whole sidebar tab for it made the tab bar outlive its content.
    property bool timerEnabled: false
    property bool translatorEnabled: Config.options.sidebar.translator.enable
    property bool animeEnabled: Config.options.policies.weeb !== 0
    property bool animeCloset: Config.options.policies.weeb === 2
    property var tabButtonList: [
        ...(root.notificationsEnabled ? [{"icon": "notifications", "name": Translation.tr("Notifications")}] : []),
        ...(root.todoEnabled ? [{"icon": "checklist", "name": Translation.tr("To Do")}] : []),
        ...(root.portsEnabled ? [{"icon": "lan", "name": Translation.tr("Ports")}] : []),
        ...(root.musicEnabled ? [{"icon": "music_note", "name": Translation.tr("Music")}] : []),
        ...(root.timerEnabled ? [{"icon": "schedule", "name": Translation.tr("Timer")}] : []),
        ...(root.translatorEnabled ? [{"icon": "translate", "name": Translation.tr("Translator")}] : []),
        ...((root.animeEnabled && !root.animeCloset) ? [{"icon": "bookmark_heart", "name": Translation.tr("Anime")}] : [])
    ]
    property int tabCount: swipeView.count

    // External open requests (qs -c ii ipc call music show, a press on the
    // island's media view): switch to the named tab.
    //
    // The request is STICKY until it can be honoured. It normally arrives in
    // the same tick that opens the sidebar (open, then ask for Music), and at
    // that moment swipeView's pages are still being built -- applying it
    // then either threw on a null currentItem or was overwritten the moment
    // the view finished loading and reset to its first tab. That is why the
    // sidebar used to come up on To Do while the caller was told it had asked
    // for Music. The request is only cleared once the tab is really showing,
    // so a stale value can never trap the user on a tab they did not ask for.
    function applyPendingTab() {
        const wanted = GlobalStates.sidebarLeftTargetTab;
        if (!wanted || wanted.length === 0)
            return;
        const idx = root.tabButtonList.findIndex(t => t.name === wanted);
        if (idx < 0) {
            // No such tab (feature switched off): drop the request.
            GlobalStates.sidebarLeftTargetTab = "";
            pendingTabRetry.stop();
            return;
        }
        if (!swipeView || swipeView.count <= idx) {
            // Pages not built yet -- keep the request and try again shortly.
            // Waiting a tick is not cosmetic: applying it inside the same
            // tick that opened the sidebar threw on a null currentItem, and
            // that exception unwound through the property write and left the
            // window's `visible` binding half applied -- the sidebar then
            // never appeared at all, with the caller told it had asked for
            // Music.
            pendingTabRetry.restart();
            return;
        }
        try {
            swipeView.currentIndex = idx;
            if (swipeView.currentItem)
                swipeView.currentItem.forceActiveFocus();
        } catch (error) {
            console.warn("[SidebarLeft] tab request failed:", error);
        }
        GlobalStates.sidebarLeftTargetTab = "";
        pendingTabRetry.stop();
    }

    Timer {
        id: pendingTabRetry
        interval: 90
        repeat: true
        onTriggered: root.applyPendingTab()
    }

    Connections {
        target: GlobalStates
        function onSidebarLeftTargetTabChanged() {
            root.applyPendingTab();
        }
    }
    onTabCountChanged: root.applyPendingTab()
    Component.onCompleted: root.applyPendingTab()

    // Reopen on the tab you left it on.
    //
    // The content object is created once and re-parented between the docked
    // and detached windows, so it normally survives a close -- but anything
    // that rebuilds it (a reload, a detach) starts again at tab 0. Re-asserting
    // the stored tab on every open covers both cases with one line, and it
    // cannot fight the user: an explicit tab REQUEST (applyPendingTab above)
    // runs on its own and simply wins, because it is applied after.
    function restoreTab() {
        const want = Persistent.states.sidebarLeft.tabIndex;
        if (want > 0 && want < root.tabButtonList.length && swipeView.count > want)
            swipeView.currentIndex = want;
    }
    Connections {
        target: GlobalStates
        function onSidebarLeftOpenChanged() {
            if (GlobalStates.sidebarLeftOpen)
                Qt.callLater(root.restoreTab);
        }
    }

    function focusActiveItem() {
        swipeView.currentItem.forceActiveFocus()
    }

    // Desktop edit mode opens the sidebar for grooming the desktop widgets.
    // (It used to jump to the Widgets tab; that tab is gone, so the sidebar
    // simply opens on whatever tab it was on.)
    Connections {
        target: GlobalStates
        function onDesktopEditModeChanged() {
            if (GlobalStates.desktopEditMode) {
                root.focusActiveItem();
            }
        }
    }

    Keys.onPressed: (event) => {
        if (event.modifiers === Qt.ControlModifier) {
            if (event.key === Qt.Key_PageDown) {
                swipeView.incrementCurrentIndex()
                event.accepted = true;
            }
            else if (event.key === Qt.Key_PageUp) {
                swipeView.decrementCurrentIndex()
                event.accepted = true;
            }
        }
    }

    // ── The two-finger tab swipe ──────────────────────────────────────
    //
    // The gesture is OWNED BY THE COMPOSITOR: a two-finger Hyprland touchpad
    // bind in custom/general.lua, which is offered the swipe before any
    // client sees it and so works over the whole panel and fires on a flick.
    // It arrives here as a RELATIVE STEP through the GlobalShortcuts at the
    // bottom of SidebarLeft.qml. Everything below is the fallback for the
    // case where that bind is not active: a wheel handler on a surface that
    // is an ANCESTOR of the content (the only placement that sees events at
    // all -- see the long note on swipeSurface). The two cannot both fire
    // for one physical swipe, because a bound gesture is consumed by the
    // compositor and never reaches the client.
    property real swipeAccX: 0
    property real swipeAccY: 0
    property bool swipeHorizontal: false
    property bool swipeVertical: false
    property bool swipeFired: false

    /**
     * Apply a relative step from the compositor.
     *
     * Clamped, not wrapped: a wrap would make a swipe at either end jump to
     * the opposite end, which is a jarring thing for a gesture that is
     * otherwise a gentle nudge, and it is the same reason the old wheel
     * handler clamped and appeared to do nothing.
     */    function stepTab(delta) {
        const count = swipeView.count;
        const from = swipeView.currentIndex;
        if (count <= 1) return;
        // Music ⇄ To Do: the pair that actually gets flipped between, made
        // swipe-adjacent even though other tabs sit between them in the bar.
        // Swipe right on Music lands on To Do; swipe left on To Do lands on
        // Music. Just these two edges override the plain ±1 step below,
        // which still governs every other pair. Looked up by name so the
        // mapping survives tabs being enabled or disabled around them.
        const musicIdx = root.tabButtonList.findIndex(t => t.name === Translation.tr("Music"));
        const todoIdx = root.tabButtonList.findIndex(t => t.name === Translation.tr("To Do"));
        let next;
        if (delta > 0 && musicIdx >= 0 && todoIdx >= 0 && from === musicIdx)
            next = todoIdx;     // Music, swipe right -> To Do
        else if (delta < 0 && musicIdx >= 0 && todoIdx >= 0 && from === todoIdx)
            next = musicIdx;    // To Do, swipe left -> Music
        else
            next = Math.max(0, Math.min(count - 1, from + delta));
        if (next === from) return;
        // DEFERRED, and this is not a style choice. Measured, not guessed:
        // the identical assignment made from a signal handler (the
        // GlobalShortcut path) moves the tab, while the same assignment made
        // synchronously from inside onWheel is silently reverted and the
        // index is still the old one a full event loop later -- the view
        // re-derives its index from the page position while the wheel event
        // is still being delivered, so the write is thrown away. A wheel
        // event therefore cannot drive this property at all. Qt.callLater
        // moves the write past the delivery, which is exactly the difference
        // between the two paths.
        Qt.callLater(function() {
            if (swipeView)
                swipeView.currentIndex = next;
        });
    }

    Connections {
        target: GlobalStates
        function onSidebarLeftTabDeltaChanged() {
            const d = GlobalStates.sidebarLeftTabDelta - root._lastTabDelta;
            if (d === 0) return;
            root._lastTabDelta = GlobalStates.sidebarLeftTabDelta;
            root.stepTab(d > 0 ? 1 : -1);
        }
    }
    property int _lastTabDelta: 0

    // DELTAS. A wheel arrives with the motion split between pixelDelta and
    // angleDelta; pixelDelta is preferred and angleDelta is the fallback.
    // The now-bar popup documents the same trap in its wheelDx helpers, and
    // reading angleDelta alone is why an early version of this saw almost
    // nothing of a real swipe.


    /** Undo the natural-scroll inversion so dx > 0 always means "fingers right". */
    function swipeDeltas(w) {
        const pd = w.pixelDelta;
        const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
        return {
            dx: hasPixels ? (w.inverted ? -pd.x : pd.x) : w.angleDelta.x / 120 * 40,
            dy: hasPixels ? (w.inverted ? -pd.y : pd.y) : w.angleDelta.y / 120 * 40,
            px: pd ? pd.x : 0,
            py: pd ? pd.y : 0,
            hasPixels: !!hasPixels
        };
    }

    // (The old swipeFromWheel is gone: it was the ancestor-surface version,
    // which could only ever see wheel events no list had taken first. One
    // handler now owns every wheel event in the sidebar -- onSwipeWheel.)

    Timer {
        // A SIBLING of the things that drive it, never a child: a handler is
        // a QObject with no default property (a nested Timer is a hard load
        // failure), and the swipe surface must stay the topmost item in this
        // item to win delivery.
        id: swipeReset
        // 350ms was long enough to outlive a natural pause in the middle of a
        // scroll. The axis was then still locked, so the next tick after the
        // pause could not re-decide it -- and because a zero-delta lift-off
        // frame still restarted this timer, a scroll that ended and was then
        // continued within 350ms had its gesture split in two, which is the
        // other half of the stutter. 200ms is comfortably longer than the gap
        // between frames of one continuous gesture (6-10ms) and comfortably
        // shorter than a deliberate pause.
        interval: 200
        onTriggered: {
            root.swipeAccX = 0;
            root.swipeAccY = 0;
            root.swipeHorizontal = false;
            root.swipeVertical = false;
            root.swipeFired = false;
        }
    }

    // ── Finding the list under the pointer ───────────────────────────
    //
    // The swipe surface is TOPMOST, so it sees every wheel event in the
    // sidebar and nothing underneath it does. That is what finally makes the
    // swipe work over the full height, and it is also why this function has
    // to exist: a wheel event that is not accepted propagates to a PARENT,
    // never back down to a child, so a topmost handler that simply declines
    // a vertical event silently kills scrolling in every list in the sidebar.
    // The scrolling is therefore forwarded by hand.
    //
    // Depth-first through the CURRENT page, collecting EVERY vertical
    // flickable and keeping the one with the most content -- not the first
    // one found. A page can hold several: the Music tab has an empty 0px
    // list above the real one, whose content is 996px, and "first wins" sent
    // every vertical flick into the empty list, so the song list could not be
    // scrolled at all. Biggest wins, because that is the list a vertical
    // gesture anywhere on the page means.
    //
    // Every step is defensive: a QML type error here would take the whole
    // shell down, and the sidebar is not worth that risk for a nicety.
    function collectScrollers(item, out, depth) {
        if (!item || depth > 16 || out.length > 40)
            return out;
        let kids = null;
        try {
            kids = item.children;
        } catch (e) {
            return out;
        }
        if (!kids)
            return out;
        for (let i = kids.length - 1; i >= 0; i--) {
            const k = kids[i];
            try {
                // No `visible` filter here, and that is deliberate. It was
                // skipping whole subtrees: a page part-way through the
                // SwipeView transition reports invisible, so the walk found
                // NOTHING and vertical scrolling silently stopped working for
                // as long as the sidebar sat in that state -- which showed up
                // as an intermittent "sometimes it scrolls, sometimes it
                // doesn't". Scrolling an invisible list is harmless, and
                // picking the largest one is still the right answer, so the
                // check bought nothing and cost reliability.
                if (!k || k === swipeSurface)
                    continue;
                // A flickable, and NOT the horizontal page view itself: that
                // one scrolls between tabs, which is the job being replaced.
                if ("contentY" in k && "contentHeight" in k) {
                    const horizontal = ("orientation" in k) && (k.orientation === 1);
                    if (!horizontal && k !== swipeView)
                        out.push(k);
                }
                // A ScrollView keeps its flickable as contentItem.
                if ("contentItem" in k && k.contentItem && k.contentItem !== k) {
                    const inner = k.contentItem;
                    if ("contentY" in inner && "contentHeight" in inner)
                        out.push(inner);
                }
                root.collectScrollers(k, out, depth + 1);
            } catch (e) {
                // A dynamic property lookup can throw on some item types.
                // Skip it rather than let it escape into the wheel handler.
            }
        }
        return out;
    }

    function findScroller() {
        const cands = root.collectScrollers(swipeView.currentItem, [], 0);
        let best = null;
        let bestH = -1;
        for (let i = 0; i < cands.length; i++) {
            let h = 0;
            try {
                h = cands[i].contentHeight;
            } catch (e) {
            }
            if (h > bestH) {
                bestH = h;
                best = cands[i];
            }
        }
        root._diag = "currentItem=" + (swipeView.currentItem ? "ok" : "NULL")
            + " candidates=" + cands.length
            + " bestContentHeight=" + bestH;
        return best;
    }

    /** Move a scroller by a wheel delta, clamped to its own range. */
    function scrollBy(sc, delta) {
        if (!sc)
            return false;
        const max = Math.max(0, (sc.contentHeight || 0) - (sc.height || 0));
        const next = Math.max(0, Math.min(max, (sc.contentY || 0) + delta));
        if (next === sc.contentY)
            return false;
        sc.contentY = next;
        return true;
    }

    // Scroll feel, as ratios against what a terminal does rather than magic
    // numbers: see the gain note in onSwipeWheel.
    //
    // scrollGain 4.5 and coastDecay 0.93 together mean one realistic 8px
    // touchpad tick moves 36px directly and then coasts roughly 500px more.
    // That sounds enormous until you remember it self-regulates: the coast
    // length is built from the VELOCITY of the events, so a slow drag (tiny
    // per-event deltas) coasts a few pixels and a real flick coasts far. That
    // is the whole difference between a list that feels heavy and one that
    // feels disconnected from your fingers.
    readonly property real scrollGain: 4.5
    readonly property real wheelNotchPixels: 75
    // Friction per 16ms tick. 0.90 halved a flick in about seven ticks and
    // stopped dead; 0.93 keeps it travelling long enough to cross the music
    // list, while still coming to rest rather than sliding forever.
    readonly property real coastDecay: 0.93

    // ── Self-test, reachable over IPC ───────────────────────────────
    //
    // The whole point of this gesture is that a real touchpad cannot be
    // synthesised, so every "it should work now" in this file's history was
    // an assertion rather than a measurement. This feeds the handler a
    // synthetic wheel event and reports what it did, so the logic can be
    // checked for real:
    //
    //   qs -c ii ipc call sidebarLeft wheelTest 30 0     horizontal, one tick
    //   qs -c ii ipc call sidebarLeft wheelTest 0 60     vertical
    //   qs -c ii ipc call sidebarLeft scrollProbe         what is under the
    //                                                      cursor
    function wheelTest(dx, dy) {
        const before = swipeView.currentIndex;
        const sc = root.findScroller(swipeView.currentItem);
        const y0 = sc ? sc.contentY : -1;
        const fake = {
            pixelDelta: { x: dx, y: dy },
            angleDelta: { x: 0, y: 0 },
            inverted: true,
            x: 10,
            y: 400,
        };
        // A single tick is a synthetic touchpad event; without a fresh reset
        // the previous test's axis lock would decide the outcome instead of
        // this one.
        swipeReset.stop();
        root.stopCoast();
        root.swipeAccX = 0;
        root.swipeAccY = 0;
        root.swipeHorizontal = false;
        root.swipeVertical = false;
        root.swipeFired = false;
        root.onSwipeWheel(fake);
        const y1 = sc ? sc.contentY : -1;
        // The index is NOT read back here: SwipeView.currentIndex is derived
        // from the animated page position, so a synchronous read returns the
        // value from BEFORE the assignment and every test looks like a
        // failure. The result is parked and read on the NEXT call, by which
        // time the animation has run.
        root._pendingTest = `idx ${before} count=${swipeView.count}`
            + ` scroller=${sc ? sc.toString().split("(")[0] : "none"}`
            + ` contentY ${y0}->${y1} horizontal=${root.swipeHorizontal} fired=${root.swipeFired}`;
        return "sent; call again for the settled result";
    }

    // A whole gesture inside ONE IPC call, because the coast cannot be
    // measured any other way from a shell script.
    //
    // scrollfling only starts coasting after FLING_START_MS (70) of quiet,
    // and it measures velocity from the gaps BETWEEN events. Firing N calls
    // from a shell script spaces them ~1s apart, so the velocity always
    // measures as ~0 and the coast never begins -- which is why every earlier
    // "the list does not travel" reading from this harness was the harness,
    // not the list. This drives the same handler in-process with a realistic
    // 8ms frame gap, then reports the position at three moments: right after
    // the last event (the fingers still down), after the coast has started,
    // and after it has settled. Travel between those three IS the coast.
    function burstTest(n, dy, gapMs, zeros) {
        const count = Math.max(1, n | 0);
        const delta = dy !== undefined && dy !== 0 ? dy : -10;
        const gap = gapMs !== undefined && gapMs > 0 ? gapMs : 8;
        swipeReset.stop();
        root.stopCoast();
        root.swipeAccX = 0;
        root.swipeAccY = 0;
        root.swipeHorizontal = false;
        root.swipeVertical = false;
        root.swipeFired = false;
        const sc = root.findScroller(swipeView.currentItem);
        if (!sc)
            return "burst: no scroller";
        const y0 = sc.contentY;
        const t0 = Date.now();
        for (let i = 0; i < count; i++) {
            // A real touchpad frame: 7-10px, sign carrying the direction.
            const d = (i % 2 === 0) ? delta : delta;
            root.onSwipeWheel({
                pixelDelta: { x: 0, y: d },
                angleDelta: { x: 0, y: 0 },
                inverted: true,
                x: 10,
                y: 400,
            });
            // Burn the frame gap synchronously. Busy-waiting is deliberate
            // and confined to this test path: it is the only way to put real
            // milliseconds between two events inside a single JS call, and
            // the alternative (a Timer) would need a queued call per frame.
            const until = Date.now() + gap;
            while (Date.now() < until) {
            }
        }
        const yDown = sc.contentY;
        const elapsed = Date.now() - t0;
        // The lift-off frames a real touchpad sends AFTER the fingers have
        // gone: one or two events carrying no delta at all.
        //
        // These are not noise, they are the bug. `handleWheel` decides between
        // the touchpad and mouse paths by testing whether pixelDelta is
        // non-zero, so a zero frame took the MOUSE branch -- which cancels the
        // coast and resets the fling -- on the exact event that begins the
        // fling. Every synthetic gesture here used to stop dead at the
        // fingertips for that reason, and because the harness only ever sent
        // non-zero deltas, it never once exercised the frame that a real
        // touchpad always sends. Reproduced deliberately now.
        for (let i = 0; i < (zeros !== undefined ? zeros : 2); i++) {
            root.onSwipeWheel({
                pixelDelta: { x: 0, y: 0 },
                angleDelta: { x: 0, y: 0 },
                inverted: true,
                x: 10,
                y: 400,
            });
            const until = Date.now() + gap;
            while (Date.now() < until) {
            }
        }
        const yDown2 = sc.contentY;
        const vel = Math.round(sc.fling.state.velocity);
        const dist = Math.round(sc.fling.state.distance);
        root._pendingTest = "burst n=" + count + " gap=" + gap + "ms in=" + elapsed
            + "ms y " + Math.round(y0) + "->" + Math.round(yDown)
            + " fingerTravel=" + Math.round(yDown - y0)
            + " afterZeroFrames=" + Math.round(yDown2 - yDown)
            + " vel=" + vel + "px/s dist=" + dist
            + " coasting=" + (sc.coasting ? "yes" : "no");
        // Park the follow-up samples: a real gesture is a burst then silence.
        root._burstScroller = sc;
        return root._pendingTest;
    }

    property var _burstScroller: null

    // Called by the harness after a quiet gap, to see whether the coast ran
    // and then came to rest.
    function burstResult() {
        const sc = root._burstScroller;
        if (!sc)
            return "burstResult: nothing parked";
        root._settledTest = root._pendingTest
            + " || settledY=" + Math.round(sc.contentY)
            + " coastingNow=" + (sc.coasting ? "yes" : "no");
        root._burstScroller = null;
        return root._settledTest;
    }

    // Report the scroll bars actually attached to the current page, with
    // their real measured geometry.
    //
    // The music list's bar is configured in three separate places (the
    // AlwaysOn policy, the lane width, and the thumb width threaded through
    // StyledListView into StyledScrollBar), and "I set the property" is not
    // evidence that any of it reached the screen. This reads the live values
    // off the attached bars instead.
    /**
     * Measures the playlist rail and the song pane beside it.
     *
     * A separate probe from `barProbe` on purpose: that one walks a tree it
     * picks for itself, and when the music tab is the current page it reported
     * two unrelated default-width scroll bars and NOT ONE named item -- not the
     * rail, not the omnibar shelf, nothing. Its walk simply does not reliably
     * reach this page, so "the probe found nothing" was indistinguishable
     * from "the rail is not there". This one starts from the page the sidebar
     * is actually showing, which is the only place the answer can be.
     *
     * It reports the viewport AND the content height of both lists, because
     * the whole design rests on the rail scrolling: a rail whose content fits
     * would mean six playlists had stopped being reachable, and only the two
     * numbers together show that.
     */
    function railProbe() {
        const page = swipeView.currentItem;
        if (!page)
            return "no current page (index " + swipeView.currentIndex + "/" + swipeView.count + ")";
        const found = {};
        const walk = function (item, depth) {
            if (!item || depth > 20)
                return;
            try {
                if (item.objectName === "playlistRail")
                    found.rail = item;
                else if (item.objectName === "playlistRailList")
                    found.railList = item;
                else if (item.objectName === "playlistShelf")
                    found.shelf = item;
            } catch (e) {
            }
            const kids = item.children;
            if (!kids)
                return;
            for (let i = 0; i < kids.length; i++)
                walk(kids[i], depth + 1);
        };
        // From `contentHolder`, NOT from `currentItem`. The pages are the
        // SwipeView's `contentChildren`, and starting at the current page
        // walked straight past all of them and reported three MISSING items --
        // including the omnibar shelf, which is on screen at that moment.
        // `contentHolder` is the root `describeTree` uses, and that one does
        // reach the rail (it is how the list heights were read).
        walk(contentHolder, 0);

        const box = (item, label) => {
            if (!item)
                return label + ": MISSING";
            return label + ": " + Math.round(item.width) + "x" + Math.round(item.height)
                + " visible=" + item.visible
                + (item.contentHeight !== undefined
                    ? " content=" + Math.round(item.contentHeight)
                        + " scrolls=" + (item.contentHeight > item.height + 1)
                        + " gain=" + item.touchpadGain
                    : "");
        };

        return [
            "page " + swipeView.currentIndex + " of " + swipeView.count,
            box(found.rail, "rail"),
            box(found.railList, "railList"),
            box(found.shelf, "omnibarShelf"),
        ].join("\n");
    }

    function barProbe() {
        const bars = [];
        const named = [];
        const walk = function (item, depth) {
            if (!item || depth > 14)
                return;
            let kind = "";
            try {
                kind = String(item).split("(")[0].split("_QMLTYPE_")[0];
            } catch (e) {
            }
            // The music tab's playlist shelf. Its height is now implicit --
            // five rows plus whichever one is unfolded -- so it cannot be
            // checked by reading a number out of the source, and a shelf that
            // silently eats the song list would look like a styling bug rather
            // than a layout one. Measured here instead.
            try {
                if (item.objectName === "playlistShelf")
                    named.push("playlistShelf h=" + Math.round(item.height)
                        + " w=" + Math.round(item.width)
                        + " (was 116px before the Peek redesign)");
            } catch (e) {
            }
            // The playlist rail (design C) and its list. Both are measured
            // rather than read from the source: the rail's whole purpose is a
            // column of covers sized in QML, and a rail that silently came out
            // 0px wide, or a list that came out taller than its rail and never
            // scrolled, would look like a styling bug instead of a layout one.
            try {
                if (item.objectName === "playlistRail")
                    named.push("playlistRail h=" + Math.round(item.height)
                        + " w=" + Math.round(item.width)
                        + " visible=" + item.visible);
            } catch (e) {
            }
            try {
                if (item.objectName === "playlistRailList")
                    named.push("railList h=" + Math.round(item.height)
                        + " w=" + Math.round(item.width)
                        + " items=" + (item.count !== undefined ? item.count : "?")
                        + " contentH=" + Math.round(item.contentHeight)
                        + " scrolls=" + (item.contentHeight > item.height)
                        + " gain=" + item.touchpadGain);
            } catch (e) {
            }
            if (kind === "StyledScrollBar") {
                let ci = null;
                try {
                    ci = item.contentItem;
                } catch (e) {
                }
                bars.push("bar lane=" + Math.round(item.width) + "px"
                    + " thumb=" + (ci ? Math.round(ci.width) : "?") + "px"
                    + " thumbH=" + (ci ? Math.round(ci.height) : "?") + "px"
                    + " policy=" + item.policy + "(1=AsNeeded 2=AlwaysOn 0=AlwaysOff)"
                    + " active=" + item.active
                    + " opacity=" + (ci ? ci.opacity.toFixed(2) : "?")
                    + " size=" + item.size.toFixed(3)
                    + " visualSize=" + item.visualSize.toFixed(3)
                    + " position=" + item.position.toFixed(3)
                    + " y=" + Math.round(item.y));
                return; // its contentItem is not a page child
            }
            const kids = item.children;
            if (kids) {
                for (let i = 0; i < kids.length; i++)
                    walk(kids[i], depth + 1);
            }
        };
        walk(swipeView.currentItem, 0);
        return "bars on page " + swipeView.currentIndex + ": " + bars.length
            + (named.length ? "\n" + named.join("\n") : "")
            + "\n" + (bars.length ? bars.join("\n") : "  (none)");
    }

    property string _pendingTest: ""
    property string _settledTest: ""
    property string _diag: ""

    // Assign currentIndex directly, with no gesture logic in the way. This is
    // the control for the swipe test: if a bare assignment does not stick,
    // no threshold or handler can ever make the swipe work, because the write
    // itself is being reverted.
    function setIndex(i) {
        const before = swipeView.currentIndex;
        swipeView.currentIndex = i;
        root._pendingTest = "setIndex " + i + " from " + before
            + " moveEnabled=" + swipeView.moveEnabled
            + " animate=" + swipeView.animateCurrentIndex
            + " immediate=" + swipeView.immediate
            + " dragEnabled=" + swipeView.dragEnabled
            + " contentX=" + swipeView.contentX
            + " width=" + swipeView.width;
        return "sent";
    }

    function testResult() {
        const sc = root.findScroller(swipeView.currentItem);
        root._settledTest = root._pendingTest + " => idx now " + swipeView.currentIndex
            + " contentY now " + (sc ? Math.round(sc.contentY) : "n/a")
            + " coasting=" + (coastTimer.running ? "yes" : "no");
        return root._settledTest;
    }

    // Walk the current page and report what is actually in it. A guess about
    // where the list is has been wrong three times in this file's history, so
    // this prints the tree instead.
    function describeTree(item, depth, out) {
        if (!item || depth > 14 || out.length > 600)
            return out;
        let kind = "?";
        try {
            kind = String(item).split("(")[0].split("_QMLTYPE_")[0];
        } catch (e) {
        }
        let marks = "";
        try {
            if ("contentY" in item)
                marks += " [contentY]";
            if ("contentHeight" in item)
                marks += "[h=" + item.contentHeight + "]";
            if ("orientation" in item)
                marks += "(o=" + item.orientation + ")";
            if (item === swipeView)
                marks += " <SWIPEVIEW>";
        } catch (e) {
        }
        out.push("  ".repeat(depth) + kind + marks);
        const kids = item.children;
        if (kids) {
            for (let i = 0; i < kids.length; i++)
                root.describeTree(kids[i], depth + 1, out);
        }
        return out;
    }

    function scrollProbe() {
        const all = [];
        // From the content ROOT, not the current page: this has to be able to
        // see the tab strip as well as the page, because "the sidebar is
        // blank" is a failure of the whole column, not of one page.
        root.describeTree(contentHolder, 0, all);
        const keep = all.filter(l => l.indexOf("[contentY]") >= 0
            || l.indexOf("SwipeView") >= 0
            || l.indexOf("ListView") >= 0
            || l.indexOf("Scroll") >= 0
            || l.indexOf("Flickable") >= 0
            || l.indexOf("Loader") >= 0
            || l.indexOf("MusicTab") >= 0
            || l.indexOf("TodoWidget") >= 0
            || l.indexOf("ColumnLayout") >= 0);
        return "SIZES root=" + Math.round(root.width) + "x" + Math.round(root.height)
            + " holder=" + Math.round(contentHolder.width) + "x" + Math.round(contentHolder.height)
            + " swipeView=" + Math.round(swipeView.width) + "x" + Math.round(swipeView.height)
            + " currentIndex=" + swipeView.currentIndex + "/" + swipeView.count
            + " currentItem=" + (swipeView.currentItem
                ? Math.round(swipeView.currentItem.width) + "x" + Math.round(swipeView.currentItem.height)
                : "null")
            + "\ntotal nodes: " + all.length
            + "\nstructure:\n" + keep.join("\n")
            + "\nfindScroller -> " + String(root.findScroller(swipeView.currentItem))
            + "\n" + root._diag;
    }

    // ── The one wheel handler ───────────────────────────────────────
    //
    // Everything the sidebar does with a wheel event now happens here.
    function onSwipeWheel(w) {
        const d = root.swipeDeltas(w);

        // A frame with no movement at all is the pad reporting lift-off, not a
        // gesture. It must not touch the accumulators or restart the gesture
        // timer: doing so kept the old gesture "alive" for 200ms after the
        // fingers had gone, so the flick that should have been one gesture was
        // split, and the zero frames that follow a coast were counted as the
        // start of a new one. The list's own handler already ignores these
        // (StyledListView.handleWheel) for the same reason; this is the same
        // rule applied one level up, before the axis logic sees them.
        if (!d.hasPixels && d.dx === 0 && d.dy === 0) {
            w.accepted = true;
            return;
        }

        root.swipeAccX += Math.abs(d.dx);
        root.swipeAccY += Math.abs(d.dy);
        swipeReset.restart();

        // ONE AXIS PER GESTURE, decided once and then held.
        //
        // The previous version re-decided the axis on every single event, and
        // that is what made the swipe "work for a second": a real horizontal
        // swipe bleeds a little into y, so one tick where |dy| happened to
        // exceed |dx` sent the gesture down the scrolling branch, it returned
        // from there, and the tab never changed -- permanently, for the rest
        // of that session's gesture. A swipe is a gesture, not a stream of
        // independent votes.
        //
        // The horizontal lock is biased (|accX| > 0.6 * |accY|) so a real
        // sideways swipe is never thrown away, while the vertical lock is not
        // (|accY| > 1.2 * |accX|), so a scroll only commits once it is
        // unambiguously a scroll and there is no horizontal intent to steal.
        //
        // The dead zone below is what made scrolling feel GLITCHY rather than
        // merely imperfect: an event that has not yet committed to an axis used
        // to be dropped on the floor, so the first one or two frames of every
        // single scroll -- 8-20px of your finger movement -- went nowhere, and
        // the list then jumped. A small hesitation at the start of each scroll
        // reads as stutter, and stutter is what "not natural" mostly means.
        //
        // A touchpad's very first frame is already overwhelmingly one axis
        // (measured: roughly 10px on one and 0-1 on the other), so a scroll can
        // be committed on the FIRST event with a ratio that is decisive rather
        // than merely probable. Anything that is not clearly one axis or the
        // other is left undecided, exactly as before, and the accumulated
        // fallback below still catches it on the next tick.
        //
        // ANY movement at all commits, in whichever direction it leans, with no
        // minimum distance. The previous 3px floor is what made a light flick
        // do nothing whatsoever: measured, two events of 1px each -- a real,
        // deliberate, if small, flick -- moved the list 0px and never coasted at
        // all. The floor bought nothing, because a gesture that is genuinely
        // too small to mean anything cannot be told apart from a light one
        // that should move a little, and the cost of guessing wrong (a 1px
        // nudge) is far lower than the cost of ignoring the user (nothing
        // happens, which reads as broken). The RATIO is what protects the
        // horizontal swipe from vertical bleed, and it still does that job.
        if (!root.swipeHorizontal && !root.swipeVertical) {
            const ax = root.swipeAccX;
            const ay = root.swipeAccY;
            if (ay > 0 && ay >= ax * 2.0)
                root.swipeVertical = true;
            else if (ax > 0 && ax >= ay * 2.0)
                root.swipeHorizontal = true;
            else if (ax > ay * 1.05)
                root.swipeHorizontal = true;
            else if (ay > 0)
                root.swipeVertical = true;
        }

        if (root.swipeHorizontal) {
            w.accepted = true;
            root.stopCoast();
            if (root.swipeFired)
                return;
            // Fingers right = NEXT tab, the convention the now-bar card and
            // the island share (`mode + (dx > 0 ? 1 : -1)` there).
            root.stepTab(d.dx > 0 ? 1 : -1);
            root.swipeFired = true;
            return;
        }

        if (root.swipeVertical) {
            const sc = root.findScroller(swipeView.currentItem);
            root._diag = "vertical: accX=" + Math.round(root.swipeAccX)
                + " accY=" + Math.round(root.swipeAccY)
                + " scroller=" + (sc ? String(sc).split("(")[0] : "NULL");
            if (!sc)
                return; // nothing to scroll: let the event go
            // A horizontal scroller under the pointer -- the music playlist
            // shelf is the one in this sidebar -- keeps its own sideways
            // scrolling, and a sideways gesture over it must not also change
            // tabs.
            if (("orientation" in sc) && (sc.orientation === 1))
                return;
            // GAIN. These events used to be forwarded 1:1 -- one pixel of
            // finger travel moved the list one pixel -- which is why the music
            // list felt almost frozen: this touchpad reports 7-10px per event,
            // so a flick across 120px of pad moved the list about one row. A
            // terminal multiplies that by roughly three, and it is the RATIO,
            // not the absolute number, that gives a flick its weight.
            //
            // A mouse wheel is a different unit: 120 angleDelta per notch. Qt's
            // own default turns that into 40px, while a terminal shows about
            // three 20px lines, so 60 is the matching figure; `dy` already
            // carries the /120*40 scaling from swipeDeltas, so the wheel path
            // divides it back out rather than double-scaling.
            //
            // The two signs differ, which is why this is spelled out: `dy` is
            // natural-scroll corrected, so on a touchpad `dy > 0` means the
            // fingers moved DOWN and the content must move UP (hence the
            // minus), while a wheel's angleDelta is already in "scroll down"
            // terms and wants the plain plus.
            // Hand the event to the list's OWN wheel handler where it has
            // one. This is the whole reason the song list felt un-fluid:
            // StyledListView already has a tuned touchpad path (its own gain,
            // a fling model, a coast timer, and a `Behavior on contentY`
            // that it correctly SUSPENDS while a hand is on the pad), and
            // writing `contentY` from out here went straight through that
            // Behavior instead -- so every event retargeted an easing that
            // never finished, and the list drifted rather than moved.
            //
            // Anything without a handler of its own (a plain ListView, say)
            // still gets the fallback below, so nothing is left unsriven.
            if (typeof sc.handleWheel === "function") {
                sc.handleWheel(w);
                return;
            }
            // The sign convention here matches the list's own handler on
            // purpose: `-pd.y`, raw and un-inverted, because the delta's sign
            // already carries the user's natural-scroll preference. Using the
            // corrected `d.dy` instead sent the two paths opposite ways.
            const move = d.hasPixels
                ? -d.py * root.scrollGain
                : (w.angleDelta.y / 120) * root.wheelNotchPixels;
            root.scrollBy(sc, move);
            root.noteScroll(sc, move);
            w.accepted = true;
            return;
        }
        // Still undecided: do nothing with this tick and let the next one
        // decide. Accepting it here would rob the gesture of its own input.
        root._diag = "undecided: accX=" + Math.round(root.swipeAccX)
            + " accY=" + Math.round(root.swipeAccY)
            + " dx=" + d.dx.toFixed(1) + " dy=" + d.dy.toFixed(1)
            + " hasPixels=" + d.hasPixels;
    }

    // ── Momentum ──────────────────────────────────────────────────────
    //
    // Gain alone was not enough, and this is why: a bigger per-event step is
    // not a faster scroll, it is a COARSER one. A terminal moves a line or
    // two per event and then keeps going after your fingers have left the
    // pad -- the flick is the fast part, and the coast is what makes it feel
    // like weight. Without this, raising the gain just made the list jump.
    //
    // Velocity is measured from the events themselves rather than guessed:
    // the last movement, over the tick interval the compositor is actually
    // delivering. A new event always wins, so touching the pad again picks
    // the coast up seamlessly instead of fighting it.
    property var coastTarget: null
    property real coastVelocity: 0 // px per second
    property int coastTicks: 0

    function noteScroll(sc, move) {
        root.coastTarget = sc;
        // px per SECOND: the distance this event covered, over the 16ms tick
        // interval it is calibrated for. There is deliberately no *1000 here
        // -- there was one, and it made the coast a thousand times too fast:
        // a single tick overshot the whole list, hit the clamp, and stopped,
        // so momentum silently contributed nothing at all while looking
        // switched on. `step` below multiplies by 0.016 to get back to
        // pixels-per-tick, which is the one place the conversion belongs.
        root.coastVelocity = move / 0.016;
        root.coastTicks = 0;
        if (!coastTimer.running)
            coastTimer.restart();
    }

    function stopCoast() {
        coastTimer.stop();
        root.coastTarget = null;
        root.coastVelocity = 0;
    }

    Timer {
        // A SIBLING of the functions that drive it, never a child: a Timer
        // nested in a function body is fine, but one nested inside a pointer
        // handler is a hard load failure.
        id: coastTimer
        interval: 16
        repeat: true
        onTriggered: {
            const sc = root.coastTarget;
            if (!sc) {
                coastTimer.stop();
                return;
            }
            const step = (root.coastVelocity * 0.016);
            const max = Math.max(0, (sc.contentHeight || 0) - (sc.height || 0));
            const next = Math.max(0, Math.min(max, (sc.contentY || 0) + step));
            // Hitting either end stops it dead rather than grinding against
            // the clamp for the rest of the session.
            if (next === sc.contentY || next === 0 || next === max) {
                root.stopCoast();
                return;
            }
            sc.contentY = next;
            // Friction, per tick. See coastDecay above: the coast length is
            // what makes a flick feel like a flick rather than a jump.
            root.coastVelocity *= root.coastDecay;
            root.coastTicks++;
            if (root.coastTicks > 200 || Math.abs(root.coastVelocity) < 20)
                root.stopCoast();
        }
    }

    // The sidebar's real content. Wrapped in a plain Item only so the
    // topmost swipe surface declared above is a SIBLING of the content
    // instead of its parent -- see the note on that surface for why being
    // the parent could never see a swipe over the body of a tab.
    Item {
        id: contentHolder
        // anchors.fill is LOAD-BEARING, not decoration. This wrapper exists
        // only so the topmost swipe surface can be a SIBLING of the content
        // rather than its parent, and a plain Item is 0x0 by default -- so
        // without this the ColumnLayout below filled a zero-sized box and the
        // whole sidebar rendered as an empty panel. The panel background
        // lives in SidebarLeft.qml and kept drawing regardless, which is what
        // made it read as "the sidebar is broken" rather than "a container
        // lost its size".
        anchors.fill: parent

    ColumnLayout {
        anchors {
            fill: parent
            margins: sidebarPadding
        }
        spacing: sidebarPadding

        // ── Tab bar: underlined tabs ───────────────────────────────────
        // Chosen from design/sidebar-music-previews.html (option B).
        //
        // This USED to be the top bar's desktop language turned sideways: a
        // centred pill of 16px dots where only the ACTIVE tab was labelled.
        // That grammar is fine for four desktop indicators, which are
        // always in the same order and already memorised, but the sidebar
        // has four DIFFERENT tools whose order changes with the config
        // (notifications and the widget board are both switchable, and the
        // timer was removed outright). Dots with no label and no icon meant
        // the inactive tabs were identified purely by position, so a tab
        // appearing or disappearing silently renumbered every tab after it.
        //
        // Underlined text tabs: every tab is permanently labelled, so the
        // control reads without looking twice, and nothing depends on
        // position. The underline is one shared bar that SLIDES between
        // tabs rather than four bars fading -- that motion is what makes
        // the relationship between the strip and the page below obvious.
        Item {
            id: hyprTabBar
            visible: root.tabButtonList.length > 1
            Layout.fillWidth: true
            implicitHeight: 34

            // The sliding indicator. Driven from the active tab's geometry
            // so it cannot drift out of sync with the label above it.
            Rectangle {
                id: tabUnderline
                height: 2
                radius: 1
                color: Appearance.colors.colPrimary
                x: hyprTabBar.activeX
                width: hyprTabBar.activeW
                y: hyprTabBar.height - height
                visible: hyprTabBar.activeW > 0
                Behavior on x {
                    animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
                }
                Behavior on width {
                    animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
                }
            }

            // Where the active tab is, in the bar's own coordinates.
            //
            // Looked up through the Repeater rather than tracked by each tab
            // announcing itself. The count is read into a local FIRST, and
            // that is load-bearing rather than defensive: `itemAt()` is a
            // function call, so a binding containing only
            // `itemAt(swipeView.currentIndex)` depends on currentIndex alone.
            // If it happens to evaluate before the Repeater has created its
            // items it returns null, and nothing that binding READ will ever
            // change afterwards -- currentIndex sits at 0 until the user
            // clicks something -- so the underline would stay invisible for
            // the tab's whole life. Reading `count` puts it in the dependency
            // set, and count goes 0 -> N at exactly the moment the items
            // appear, which forces the re-evaluation that makes this work.
            readonly property Item activeTab: {
                const n = tabRepeater.count;
                if (n <= 0)
                    return null;
                return tabRepeater.itemAt(Math.max(0, Math.min(swipeView.currentIndex, n - 1)));
            }
            readonly property real activeX: {
                const t = activeTab;
                if (!t) return 0;
                return t.x + t.width / 2 - t.labelWidth / 2;
            }
            readonly property real activeW: activeTab ? activeTab.labelWidth : 0

            Row {
                id: tabRow
                anchors.fill: parent
                spacing: 0

                Repeater {
                    id: tabRepeater
                    model: root.tabButtonList

                    Item {
                        id: hyprTab
                        required property var modelData
                        required property int index
                        readonly property bool active: swipeView.currentIndex === index
                        // The underline is as wide as the LABEL, not the tab
                        // cell: an underline spanning the full cell reads as
                        // a selection border rather than as a pointer at the
                        // word.
                        readonly property real labelWidth: tabLabel.implicitWidth
                        // Even cells across the full width, so the labels sit
                        // on a predictable grid and adding or removing a tab
                        // (the config can switch notifications and the widget
                        // board off) redistributes the row instead of
                        // renumbering positions. This is the whole reason the
                        // old dot strip was dropped: it packed the tabs
                        // centre-first and left the active one to swell, so a
                        // tab appearing shifted every dot to its right.
                        width: hyprTabBar.width / Math.max(1, root.tabButtonList.length)
                        height: hyprTabBar.height

                        HoverHandler {
                            id: hyprTabHover
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            onTapped: {
                                swipeView.currentIndex = index;
                                root.focusActiveItem();
                            }
                        }

                        Row {
                            id: tabInner
                            anchors.centerIn: parent
                            spacing: 7

                            MaterialSymbol {
                                id: tabIcon
                                anchors.verticalCenter: parent.verticalCenter
                                text: hyprTab.modelData.icon
                                iconSize: 15
                                color: hyprTab.active
                                    ? Appearance.colors.colPrimary
                                    : hyprTabHover.hovered
                                        ? Appearance.colors.colOnLayer2
                                        : Appearance.colors.colSubtext
                                Behavior on color {
                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                }
                            }
                            StyledText {
                                id: tabLabel
                                anchors.verticalCenter: parent.verticalCenter
                                text: hyprTab.modelData.name
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                font.weight: hyprTab.active ? Font.DemiBold : Font.Normal
                                color: hyprTab.active
                                    ? Appearance.colors.colPrimary
                                    : hyprTabHover.hovered
                                        ? Appearance.colors.colOnLayer2
                                        : Appearance.colors.colSubtext
                                Behavior on color {
                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                }
                            }
                        }
                    }
                }
            }

            // Hairline under the whole strip, so the tabs read as sitting on
            // the page rather than floating above it.
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: Appearance.colors.colLayer0Border
                z: -1
            }

            // The swipe's SECOND delivery path, laid over the tab strip and
            // declared last so it is the topmost item there. Nothing under
            // it competes for the wheel -- the strip has no flickable -- so
            // this gets the event by ordinary delivery, which is the one
            // mechanism known to work on this layer surface (it is what the
            // now-bar card uses).
            //
            // acceptedButtons: NoButton is what makes this safe to put on
            // top: it takes no presses, so the tabs underneath keep every
            // click and hover exactly as they were. It only ever swallows a
            // WHEEL event, and only once the gesture has committed to the
            // horizontal axis.
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitWidth: swipeView.implicitWidth
            implicitHeight: swipeView.implicitHeight
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1

            SwipeView { // Content pages
                id: swipeView

                // No MOUSE-drag paging. Two-finger swipe only.
                //
                // The pager pages on a plain mouse drag as well as on a
                // two-finger swipe, and on a tab full of lists that mouse drag
                // is almost always something else: press a row's action button,
                // move sideways without lifting, and the sidebar slid a tab.
                // Buttons do not grab the pointer on press, so the drag fell
                // straight through to the pager underneath.
                //
                // The two-finger swipe is NOT affected, because it never used
                // this pager: `swipeSurface` below is topmost, catches the
                // wheel event the touchpad produces, and `onSwipeWheel` locks
                // onto the horizontal axis and calls `stepTab`, which assigns
                // `currentIndex` directly. The pager's drag handling was a
                // second, unwanted route to the same place.
                //
                // NOT a `DragHandler { target: null }`, which is the obvious way
                // to eat a drag and is a trap here: a handler on the pager is
                // an ANCESTOR of every row, so it takes the grab before the
                // row's own `MouseArea` can claim it, and the to-do rows stop
                // being grabbable at all. That is exactly what happened.
                //
                // NOT `dragEnabled`, on the SwipeView or on its `contentItem`:
                // Qt 6.11's SwipeView has no such property and its contentItem
                // is not a Flickable either. Both are load errors ("Cannot
                // assign to non-existent property") that kill the whole shell.
                interactive: false

                // Remember the tab across closes.
                //
                // Two details are load-bearing rather than tidy. The index is
                // clamped, because the set of tabs depends on which features
                // are enabled -- a stored 3 with only two pages would put
                // currentItem at null and the sidebar would come up blank.
                // And it is written on every change, including the very first
                // one, so the value on disk always reflects where the user
                // actually is rather than where they started.
                onCurrentIndexChanged: {
                    if (swipeView.currentIndex >= 0 && swipeView.currentIndex < root.tabButtonList.length)
                        Persistent.states.sidebarLeft.tabIndex = swipeView.currentIndex;
                }
                Component.onCompleted: {
                    // Restore, but only once the pages exist. Assigning while
                    // the Repeater is still building lands on a null
                    // currentItem and is then silently overwritten when the
                    // view finishes loading -- the same trap applyPendingTab
                    // documents, which is why that one retries.
                    const want = Persistent.states.sidebarLeft.tabIndex;
                    if (want > 0 && want < root.tabButtonList.length && swipeView.count > 0)
                        swipeView.currentIndex = want;
                }
                anchors.fill: parent
                spacing: 10

                clip: true
                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: swipeView.width
                        height: swipeView.height
                        radius: Appearance.rounding.small
                    }
                }

                contentChildren: [
                    ...(root.todoEnabled ? [todo.createObject()] : []),
                    ...(root.portsEnabled ? [ports.createObject()] : []),
                    ...(root.musicEnabled ? [musicTab.createObject()] : []),
                    ...(root.timerEnabled ? [timer.createObject()] : []),
                    ...(root.translatorEnabled ? [translator.createObject()] : []),
                    ...((root.tabButtonList.length === 0 || (!root.notificationsEnabled && !root.translatorEnabled && root.animeCloset)) ? [placeholder.createObject()] : []),
                    ...(root.animeEnabled ? [anime.createObject()] : []),
                ]
            }
        }

        // Notifications no longer have a page here (see notificationsEnabled
        // above); the component is gone with them.
        // The Widgets board is gone (widgetsEnabled: false above): the tab,
        // the page and the WidgetsBoard component were all deleted. The
        // pomodoro card it carried lives in the island's focus view; the
        // volume/battery/media states live in the right sidebar and the
        // bar's own indicators.
        // Music: the sidebar's own music GUI over the headless mpv daemon.
        Component {
            id: musicTab
            MusicTab {}
        }
        // To Do, given the sidebar's full height rather than the right
        // sidebar's fixed 350px group.
        Component {
            id: todo
            Rectangle {
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer1
                TodoWidget {
                    anchors.fill: parent
                    anchors.margins: 5
                }
            }
        }
        // Ports: the port manager's tab (same shape as To Do's page).
        Component {
            id: ports
            PortsTab {}
        }
        // The Timer page is gone (timerEnabled: false above): the pomodoro
        // lives in the widgets board and in the island's focus view. The
        // component was removed with it -- keeping it would keep the
        // PomodoroWidget import alive for nothing.
        Component {
            id: translator
            Translator {}
        }
        Component {
            id: anime
            Anime {}
        }
        Component {
            id: placeholder
            Item {
                StyledText {
                    anchors.centerIn: parent
                    text: root.animeCloset ? Translation.tr("Nothing") : Translation.tr("Enjoy your empty sidebar...")
                    color: Appearance.colors.colSubtext
                }
            }
        }
    }
    }

    // ── The swipe surface, LAST ─────────────────────────────────
    // ── The swipe surface ────────────────────────────────────────────
    //
    // TOPMOST, and that is the whole reason this works at last. Every
    // earlier placement was structurally incapable of it, and no threshold
    // could have fixed any of them:
    //
    //   * as a SIBLING behind the content, it only ever saw wheel events
    //     nothing above it had already taken -- which is why it worked on the
    //     tab strip and nowhere else, the strip being the one region with no
    //     list under it;
    //   * as an ANCESTOR, the children are offered the wheel first, and a
    //     list in the body of every tab accepts it, so the handler was still
    //     never reached. The events the probe captured were all from the top;
    //   * as a WheelHandler -- offered events before ordinary delivery, and so
    //     the ideal tool -- it was instrumented twice on this layer surface,
    //     including a deliberate swipe over the body, and received nothing.
    //
    // A compositor touchpad bind was the other candidate and is GONE: on this
    // machine Hyprland never delivered a two-finger horizontal gesture to it
    // at all (the trace written before every gate in custom/general.lua
    // recorded zero lines across every swipe, while the three- and four-finger
    // binds in the same file work fine). Two data points, one conclusion:
    // the gesture does not come from the compositor here.
    //
    // So: topmost, and the cost of being topmost -- that a declined event
    // never reaches the lists below -- is paid back by onSwipeWheel, which
    // forwards vertical scrolling to the list it finds by hand.
    //
    // acceptedButtons: NoButton means it takes no presses at all, so every
    // click, hover and drag in the sidebar behaves exactly as before. It is
    // last in this item's child list, which is what makes it topmost.
    MouseArea {
        id: swipeSurface
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: w => root.onSwipeWheel(w)
    }
}