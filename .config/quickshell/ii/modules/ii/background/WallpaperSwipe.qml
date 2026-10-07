pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import QtQuick
import qs
import qs.services

/**
 * The 4-finger swipe-UP open of the wallpaper carousel.
 *
 * The compositor owns the swipe: this fork's Hyprland gestures expose begin
 * and end only (custom/general.lua's 4f-up gesture fires the
 * `quickshell:wallpaperSwipeOpen` global shortcut at the swipe's START and
 * `quickshell:wallpaperSwipeFinish` at its END), and the touchpad tracker
 * (TouchpadSwipe.qml) supplies the in-between frames. The theatre's host
 * (WallpaperModal.qml) maps the stage ON receipt of the start shortcut, then
 * lets the stage's y follow `swipeFraction` -- so the strip is physically
 * under your fingers on the way in, the same feel the popup cards already
 * have on the way out. On finish, a real swipe commits (the stage settles
 * into place), a tiny one aborts (it slides back away).
 *
 * Guards, all in one place:
 *   - the empty-desktop rule lives in the COMPOSITOR's gesture (the same
 *     predicate the 3-finger and pinch paths use) -- an empty desktop cannot
 *     be stolen after the fact, it is decided before the stage ever maps;
 *   - a popup app (settings, task manager) being close-dragged by the same
 *     four fingers keeps this open from firing at all: `swipeFraction`
 *     refuses to leave 0 while a popup presence file exists.
 */
Singleton {
    id: root

    /// 0..1: how far the 4-finger up-swipe has travelled, as a fraction of a
    /// full pad sweep (the tracker's own unit). The modal turns this into
    /// pixels against its own height; 0 = resting.
    property real swipeFraction: 0
    /// True while the open is in progress: the shortcut has fired, the stage
    /// may be visible, but the swipe has not ended yet.
    property bool opening: false
    /// Set when the swipe ENDS but the stage never committed (tiny swipe, or
    /// a popup stole the gesture). The modal reads it to snap the stage away
    /// with its normal exit animation instead of easing open.
    property bool aborted: false

    /// How long the commit settle takes, after the fingers let go. The modal
    /// animates the follow->rest handoff over exactly this.
    readonly property int settleMs: 260

    // The empty-desktop check the swipe must pass before the stage moves at
    // all. The compositor already gates its own gesture on this; a re-check
    // in the shell costs one window-list read and keeps the shortcut honest
    // if it is ever fired by anything else (scripting, a future keybind).
    function desktopEmptyNow(): bool {
        const wid = HyprlandData.activeWorkspace?.id;
        if (wid === undefined || wid < 1) return false;
        return !HyprlandData.windowList.some(w => (w.workspace?.id ?? -1) === wid
            && w.mapped !== false && w.hidden !== true);
    }

    // The compositor gesture's START callback fired: arm the open. The stage
    // deliberately does NOT open here: a 4-finger TAP (the desktops overview
    // gesture) also passes through this start, and only the tracker can tell
    // a tap (no travel, a `tap` phase within 350ms) from a swipe (travel).
    // The stage opens on the first frame with real travel -- one tracker
    // frame later -- so taps fall through to the overview untouched.
    function requestOpen() {
        // A popup app is up: four fingers there are THAT app's close-drag.
        // Refuse the open entirely -- the frame handler refuses too (anyPresent
        // stays live the whole time the presence file exists), so a mis-timed
        // pair of gestures can never fight.
        if (PopupApps.anyPresent) return;
        if (GlobalStates.wallpaperStageOpen) return;
        if (!desktopEmptyNow()) return;
        root.aborted = false;
        root.opening = true;
        root.swipeFraction = 0;
        // Open the stage immediately on an empty desktop: the compositor's
        // start has already verified the desktop is empty, so just show it.
        // The tracker frames that follow drive the follow-finger position.
        GlobalStates.wallpaperStageOpen = true;
    }

    // The swipe ENDED (the compositor's finish trigger, or the tracker's own
    // session end arriving first). A real swipe commits; a tiny one aborts.
    function endSwipe() {
        if (!root.opening) return;
        root.opening = false;
        if (!GlobalStates.wallpaperStageOpen)
            return;                  // armed but never started: a tap, or a
                                     // swipe too small to open the stage at all
        if (root.swipeFraction <= 0.04) {
            // The stage opened but nothing meaningful was dragged. `aborted`
            // is what the modal reads: it slides the stage the rest of the
            // way off and closes it afterwards (the open state deliberately
            // stays true until then, so the exit is a motion, not a fade).
            root.aborted = true;
            root.swipeFraction = 0;
            return;
        }
        // Commit: the stage's own settle animation takes over from the
        // follow-finger position (driven by swipeFraction -> 0 with
        // `opening` false).
        root.swipeFraction = 0;
    }

    // A second 4-finger swipe DOWN while the stage is up (following or
    // settled): close it, the mirror of the open.
    function requestClose() {
        if (GlobalStates.wallpaperStageOpen) {
            root.opening = false;
            root.swipeFraction = 0;
            root.aborted = false;
            GlobalStates.wallpaperStageOpen = false;
        }
    }

    function reset() {
        root.opening = false;
        root.swipeFraction = 0;
        // The tracker has not followed this (abandoned) swipe, so the
        // fallback must not fire for it. See `trackerBegan`.
        root.trackerBegan = false;
    }

    // Workspace changes close the theatre already (WallpaperModal watches
    // them); make sure the swipe state does not survive one either.
    Connections {
        target: HyprlandData
        function onActiveWorkspaceChanged() {
            root.reset();
        }
    }

    // (The compositor handoff lives in WallpaperModal.qml: GlobalShortcut
    // needs a ShellRoot context, and the modal is the same process -- its
    // shortcuts call straight into requestOpen/endSwipe/requestClose here.)

    // ── In-between frames from the touchpad tracker ───────────────────────
    // The tracker fires for EVERY multi-finger gesture on the pad and the
    // dismiss-drag consumers listen to the same stream, so consumption is
    // gated on `opening` (true only between the compositor's start and end
    // triggers). Read through the tracker's own `total`, not a drag signal's
    // offset: the drag offsets are clamped to >= 0 -- the popups' DOWNWARD
    // dismiss direction -- and this gesture moves UP, i.e. negative.
    // One travel frame. Called from the tracker's Connections below, and
    // from the modal's IPC test hook (`wallpaperStage swipeFrame`) so the
    // whole state machine is drivable without the touchpad. `total` is the
    // tracker's own measure: up is negative, a full pad sweep is 1.0.
    function consumeFrame(total) {
        if (!root.opening) return;
        if (PopupApps.anyPresent) return;
        const frac = Math.min(1, Math.max(0, -total));
        root.swipeFraction = frac;
        // Deferred open (see requestOpen): the first frame with real travel
        // maps the stage. 0.04 is the same "did anything move" bar the
        // commit path uses.
        if (!GlobalStates.wallpaperStageOpen && frac > 0.04)
            GlobalStates.wallpaperStageOpen = true;
    }

    Connections {
        target: TouchpadSwipe
        function onTotalChanged() {
            // The tracker's first travel frame for THIS gesture. Its arrival
            // is what proves the tracker is really following the compositor's
            // start, so it is where the fallback becomes armed -- see
            // `trackerBegan`. Armed here rather than on `dragSession` alone so
            // a stray dragSession left over from an earlier gesture cannot
            // stand in for this one.
            if (root.opening)
                root.trackerBegan = true;
            root.consumeFrame(TouchpadSwipe.total);
        }
        function onDragCancelled() {
            // A palm landed: no commit, but the stage has already mapped --
            // resolve it as a tiny swipe (aborts with the slide-away).
            if (root.opening) {
                root.swipeFraction = 0;
                root.endSwipe();
            }
        }
    }

    // Fallback end: the compositor normally fires the finish trigger before
    // the tracker's session ends, but if that order ever flips (or the finish
    // is lost), the tracker's session ending resolves the open anyway.
    //
    // THE TRACKER'S BEGIN MUST HAVE LANDED FIRST. `dragSession` is false until
    // the tracker's own 4-finger `begin` frame arrives, and that frame is NOT
    // ordered against the compositor's gesture `start` -- the two come from
    // different producers (the evdev reader vs. Hyprland's gesture), and the
    // compositor's start routinely wins. So on the very first evaluation,
    // `opening` is true while `dragSession` is still false, this reads
    // `true && false` = false, and `onTrackerSessionLiveChanged` calls
    // `endSwipe()` before a single finger frame has been consumed. That is the
    // whole reason a 4-finger swipe-up on an empty desktop did nothing: the
    // swipe was armed and torn down in the same tick, so `swipeFraction` never
    // left 0, the stage never mapped, and `requestOpen`'s guard (which is
    // correct) was never even reached.
    //
    // `trackerBegan` gates the fallback on the tracker actually being in a
    // gesture, so the end can only fire once there was a session to end. It
    // is cleared by `reset()` and by the workspace reset, and it never
    // re-arms mid-swipe -- so a gesture that the compositor started and the
    // tracker never followed is still resolved by the compositor's own finish
    // trigger, exactly as before.
    property bool trackerBegan: false
    readonly property bool trackerSessionLive: root.opening && root.trackerBegan
        && TouchpadSwipe.dragSession
    onTrackerSessionLiveChanged: {
        if (trackerSessionLive === false && root.trackerBegan)
            endSwipe();
    }
}
