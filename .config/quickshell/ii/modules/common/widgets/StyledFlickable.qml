import QtQuick
import QtQuick.Controls
import qs.modules.common
import "scrollfling.js" as Fling

Flickable {
    id: root
    maximumFlickVelocity: 8000
    // Scrolling stops where the content stops -- no rubber-band stretching
    // past the ends. (The coast is NOT rubber-band; see the fling below.)
    boundsBehavior: Flickable.StopAtBounds

    property real touchpadScrollFactor: Config?.options.interactions.scrolling.touchpadScrollFactor ?? 100
    property real mouseScrollFactor: Config?.options.interactions.scrolling.mouseScrollFactor ?? 50
    property real mouseScrollDeltaThreshold: Config?.options.interactions.scrolling.mouseScrollDeltaThreshold ?? 120
    property bool fasterTouchpadScroll: Config?.options.interactions.scrolling.fasterTouchpadScroll ?? false
    // Cancels the COMPOSITOR's scroll_factor, which custom/general.lua sets
    // to 0.5 -- every touchpad delta arrives at the shell already halved.
    // The shell was applying what arrived 1:1, so a swipe that moved a
    // browser's page 400px moved a list here 200px: the "too insensitive"
    // half of the report. (Brave does not share the problem: Chromium
    // re-amplifies internally, so it lands at full speed regardless. The
    // fix is applied HERE rather than by raising the compositor's factor,
    // which would make every other app overshoot instead.)
    //
    // The number is the shell's ONE gain (scrollfling.js TOUCHPAD_GAIN), the
    // same one every StyledListView uses. It was 2.0 here against the list's
    // 3.2, which meant the shell had two scroll speeds and the faster one
    // happened to be the list: the same finger movement covered a third less
    // ground on a Flickable than on a list, and that reads as feel, not as a
    // difference between components. `touchpadGainOverride` is here for the
    // rare surface that genuinely needs its own weight; nothing uses it.
    readonly property real touchpadGain: root.touchpadGainOverride > 0
        ? root.touchpadGainOverride
        : (fasterTouchpadScroll ? Fling.TOUCHPAD_GAIN * 1.5 : Fling.TOUCHPAD_GAIN)
    property real touchpadGainOverride: 0
    // Accumulated scroll destination so wheel deltas stack while animating
    property real scrollTargetY: 0
    // False while a touchpad gesture or its coast is driving contentY, so the
    // Behavior below passes those writes through raw (1:1 with the fingers,
    // and a smooth exponential coast) instead of animating each one.
    property bool wheelAnimEnabled: true
    // The touchpad gesture's own state, handed to the shared fling model.
    property var fling: Fling.create({ velocity: 0, lastEventMs: 0, distance: 0, samples: [] })
    property bool coasting: false

    ScrollBar.vertical: StyledScrollBar {}

    function maxScrollY() {
        return Math.max(0, root.contentHeight - root.height);
    }

    // One tick of the coast. Runs on a frame timer rather than a Behavior,
    // because the position must follow an exponential curve exactly; a
    // NumberAnimation would ease it into a different shape and reintroduce
    // the "not natural" feel.
    function flingTick() {
        if (!root.coasting) {
            flingTimer.stop();
            return;
        }
        const now = Date.now();
        // While events are still arriving the timer is only counting out the
        // lift-off delay, so keep it alive and move nothing. The timer being
        // restarted on each event (see onWheel) is what leaves it running
        // through the gap, and so still ticking when the fingers lift.
        if (now - root.fling.state.lastEventMs < Fling.FLING_START_MS)
            return;
        // Quiet now. A gesture too slow or too short to be a flick gets no
        // coast rather than a slow creep.
        if (!root.fling.shouldFling(now)) {
            root.coasting = false;
            root.fling.reset();
            flingTimer.stop();
            return;
        }
        const dt = Math.max(1, flingTimer.lastMeasure || 16);
        const r = root.fling.step(now, dt);
        const maxY = root.maxScrollY();
        if (r.delta !== 0) {
            const next = Math.max(0, Math.min(root.contentY + r.delta, maxY));
            // Hitting a bound ends the coast at once -- the same rule as
            // StopAtBounds for a finger drag.
            if (next <= 0 || next >= maxY) {
                root.contentY = next;
                root.scrollTargetY = next;
                root.coasting = false;
                root.fling.reset();
                flingTimer.stop();
                return;
            }
            root.wheelAnimEnabled = false;
            root.contentY = next;
            root.scrollTargetY = next;
            root.wheelAnimEnabled = true;
        }
        if (r.stop) {
            root.coasting = false;
            root.fling.reset();
            flingTimer.stop();
        }
    }

    Timer {
        id: flingTimer
        interval: 16
        repeat: true
        onTriggered: root.flingTick()
    }

    // The one door into this surface's scrolling.
    //
    // scrollfling.js spells the rule out ("ONE DOOR"): a surface must never
    // write contentY from a wheel delta itself, it hands the event to the
    // scroller underneath, which owns the gain, the coast and the bounds.
    // `handleWheel` is that handoff for a Flickable -- StyledListView has had
    // the same entry point for longer. It matters whenever the wheel does NOT
    // arrive at the MouseArea below on its own: the now-bar card's swipe
    // overlay covers every view in the card and is the only item that sees a
    // wheel over it, so without this a caller holding the event could route it
    // nowhere and the surface under the pointer would sit still.
    function handleWheel(wheelEvent) {
        const maxY = root.maxScrollY();
        const now = Date.now();
        // ── Touchpad: pixel deltas, 1:1 while the fingers are down ──
        // The delta's sign already carries the user's natural-scroll
        // preference (Qt/libinput encode it), so it is applied directly.
        const pd = wheelEvent.pixelDelta;
        if (pd && (pd.x !== 0 || pd.y !== 0)) {
            wheelEvent.accepted = true;
            // Direct write: the Behavior must not turn 1:1 tracking into
            // an animation, nor the coast into an eased one.
            scrollAnim.stop();
            root.wheelAnimEnabled = false;
            // The gain scales the DELTA, not the resulting position, so
            // tracking stays proportional to the finger -- just at the
            // speed a browser actually scrolls at.
            const dy = root.fling.feed(-pd.y * root.touchpadGain, now);
            const next = Math.max(0, Math.min(root.contentY + dy, maxY));
            root.contentY = next;
            root.scrollTargetY = next;
            root.wheelAnimEnabled = true;
            // Arm the coast on every event; flingTick decides when it
            // actually starts. Asking `shouldFling(now)` here could never
            // be true -- `feed()` has just set `lastEventMs = now`, so the
            // 70ms quiet test compares now with itself -- which left the
            // timer never started and nothing running to notice the
            // fingers lifting. See StyledListView.handleWheel.
            root.coasting = true;
            flingTimer.restart();
            return;
        }
        // A frame with NO delta in either field is what libinput emits as
        // the fingers leave the pad, not a mouse notch. Falling through to
        // the mouse branch below cancelled the coast on the very frame
        // that begins the fling, so the surface stopped dead the instant
        // the hand lifted. Leave the coast armed instead; flingTick owns
        // the 70ms quiet test. See StyledListView.handleWheel.
        if (!wheelEvent.angleDelta || (wheelEvent.angleDelta.x === 0 && wheelEvent.angleDelta.y === 0)) {
            wheelEvent.accepted = true;
            return;
        }
        // ── Mouse wheel: instant notches ────────────────────────────
        const delta = wheelEvent.angleDelta.y / root.mouseScrollDeltaThreshold;
        // The angleDelta.y of a touchpad is usually small and continuous,
        // while that of a mouse wheel is typically in multiples of ±120.
        const scrollFactor = Math.abs(wheelEvent.angleDelta.y) >= root.mouseScrollDeltaThreshold ? root.mouseScrollFactor : root.touchpadScrollFactor;
        const base = scrollAnim.running ? root.scrollTargetY : root.contentY;
        root.scrollTargetY = Math.max(0, Math.min(base - delta * scrollFactor, maxY));
        root.contentY = root.scrollTargetY;
        // A real wheel notch means the hand is on a mouse: cancel any
        // coast rather than fighting it.
        root.coasting = false;
        flingTimer.stop();
        root.fling.reset();
        wheelEvent.accepted = true;
    }

    MouseArea {
        id: scrollMouse
        visible: true
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: function(wheelEvent) {
            root.handleWheel(wheelEvent);
        }
    }

    Behavior on contentY {
        // Eases the mouse-wheel steps (and programmatic jumps). Suspended for
        // the touchpad path and its coast (wheelAnimEnabled above) and for
        // finger drags/flicks, which must track the hand directly.
        enabled: root.wheelAnimEnabled && !root.dragging && !root.flicking
        NumberAnimation {
            id: scrollAnim
            duration: Appearance.animation.scroll.duration
            easing.type: Appearance.animation.scroll.type
            easing.bezierCurve: Appearance.animation.scroll.bezierCurve
        }
    }

    // Keep target synced when not animating (e.g., drag/flick or programmatic changes)
    onContentYChanged: {
        if (!scrollAnim.running) {
            root.scrollTargetY = root.contentY;
        }
    }

    // Content shrinking (a filtered list, a closed section) must not leave a
    // coast running against a bound that no longer exists.
    onContentHeightChanged: {
        if (root.coasting && root.contentY >= root.maxScrollY())
            root.fling.reset();
    }

}
