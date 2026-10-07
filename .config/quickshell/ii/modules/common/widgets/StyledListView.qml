import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import "scrollfling.js" as Fling

/**
 * A ListView with animations.
 */
ListView {
    id: root
    spacing: 5
    property real removeOvershoot: 20 // Account for gaps and bouncy animations
    property int dragIndex: -1
    property real dragDistance: 0
    property bool popin: true
    // Where a newly added item's SCALE starts, 0 being "grow out of nothing".
    // Opacity has its own `from: 0` in the transition below and is deliberately
    // not shared with this: one `from` across "opacity,scale" would drag the
    // fade in from this value too, so a list that only wants a soft scale-in
    // would arrive already visible.
    property real addScaleFrom: 0
    property bool animateAppearance: true
    property bool animateMovement: false
    // Accumulated scroll destination so wheel deltas stack while animating
    property real scrollTargetY: 0
    // False while a touchpad gesture or its coast is driving contentY, so the
    // Behavior below passes those writes through raw.
    property bool wheelAnimEnabled: true
    // The touchpad gesture's own state, handed to the shared fling model.
    // The SAME module StyledFlickable uses: the two lists in this shell used
    // to disagree about scrolling, and a shared model is what stops that.
    property var fling: Fling.create({ velocity: 0, lastEventMs: 0, distance: 0, samples: [] })
    property bool coasting: false

    property real touchpadScrollFactor: Config?.options.interactions.scrolling.touchpadScrollFactor ?? 100
    property real mouseScrollFactor: Config?.options.interactions.scrolling.mouseScrollFactor ?? 50
    property real mouseScrollDeltaThreshold: Config?.options.interactions.scrolling.mouseScrollDeltaThreshold ?? 120
    property bool fasterTouchpadScroll: Config?.options.interactions.scrolling.fasterTouchpadScroll ?? false
    // Cancels the COMPOSITOR's scroll_factor (0.5 in custom/general.lua), so
    // every delta arrives halved and the shell no longer applies it raw.
    // See StyledFlickable for why this is not fixed in the compositor.
    //
    // 3.2 is the music sidebar's number, promoted to the shell default on
    // request. It used to be 2.0 here, with the song list overriding it to
    // 3.2 for itself -- so one list in the shell felt right and everything
    // else felt sluggish against it, and the only way to describe the good
    // feel was "the music list's settings". A default that one component has
    // to override is not a default; it is an accident with a workaround.
    //
    // The number itself now lives in scrollfling.js, next to the momentum
    // model it belongs with, because gain and coast are one decision about
    // how the shell scrolls and they were being made in two files. See THE
    // SHELL-WIDE SCROLL RULE there.
    // `fasterTouchpadScroll` still buys more, as a multiple rather than a
    // second hand-picked number, so the ratio between the two survives anyone
    // editing either.
    readonly property real touchpadGain: root.touchpadGainOverride > 0
        ? root.touchpadGainOverride
        : (fasterTouchpadScroll ? Fling.TOUCHPAD_GAIN * 1.5 : Fling.TOUCHPAD_GAIN)
    // Per-list override of the gain above, for a list that needs a different
    // weight from the shell default. 0 means "follow the config", which is
    // what almost every list should say.
    property real touchpadGainOverride: 0

    function resetDrag() {
        root.dragIndex = -1
        root.dragDistance = 0
    }

    // See StyledFlickable: no rubber band, and the coast is the fling below.
    maximumFlickVelocity: 8000
    boundsBehavior: Flickable.StopAtBounds

    // Scroll bar, opt-in per list. The default is unchanged (appears on
    // hover, 10px lane). A long list that is scrolled by gesture rather than
    // by dragging the bar gives no other hint of where you are in it, so
    // `scrollBarAlwaysOn` exists for exactly that case, with `scrollBarWidth`
    // to keep the lane out of the labels' way when it is always visible.
    property bool scrollBarAlwaysOn: false
    property int scrollBarWidth: 10
    // How thick the THUMB is, independent of the lane above. A bar that is
    // always visible in a long list wants to be a hairline; widening the lane
    // to make it more visible would instead take space from the labels, so
    // the two are tuned separately. 0 = the scroll bar's own default.
    property int scrollBarHandleWidth: 0
    ScrollBar.vertical: StyledScrollBar {
        policy: root.scrollBarAlwaysOn ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
        implicitWidth: root.scrollBarWidth
        handleWidth: root.scrollBarHandleWidth > 0 ? root.scrollBarHandleWidth : 4
    }

    // The wheel logic, callable from OUTSIDE the list as well as from the
    // MouseArea below.
    //
    // This exists because the left sidebar puts a topmost wheel surface over
    // its whole content, so the event never reaches scrollMouse -- and the
    // sidebar's own forwarding wrote `contentY` directly instead. That write
    // goes through the `Behavior on contentY` below, which is an EASING: with
    // a new event retargeting it every few milliseconds the list never
    // arrived anywhere, which is the "not fluid" feel. It also bypassed the
    // fling model, the coast timer and scrollTargetY entirely.
    //
    // So the sidebar calls this instead and gets the tuned, already-tested
    // path: touchpadGain, fling.feed, the coast timer, and the Behavior
    // correctly suspended while the hand is on the pad.
    function handleWheel(wheelEvent) {
        const maxY = Math.max(0, root.contentHeight - root.height);
        // ── Touchpad: pixel deltas, applied 1:1, no animation ────────
        // The delta's sign already carries the user's natural-scroll
        // preference (Qt/libinput encode it), so it is applied directly.
        const pd = wheelEvent.pixelDelta;
        if (pd && (pd.x !== 0 || pd.y !== 0)) {
            wheelEvent.accepted = true;
            // Direct write: the Behavior must not turn 1:1 tracking into
            // an animation, nor the coast into an eased one.
            scrollAnim.stop();
            root.wheelAnimEnabled = false;
            const now = Date.now();
            const dy = root.fling.feed(-pd.y * root.touchpadGain, now);
            const next = Math.max(0, Math.min(root.contentY + dy, maxY));
            root.contentY = next;
            root.scrollTargetY = next;
            root.wheelAnimEnabled = true;
            // ARM the coast on every event, and let flingTick decide whether
            // it actually starts.
            //
            // This used to ask `shouldFling(now)` right here, which can never
            // be true: `feed()` above has just set `lastEventMs = now`, so the
            // 70ms-of-quiet test the function performs is comparing now with
            // itself. The condition was therefore false on every single event,
            // the timer was never started, and nothing was left running to
            // notice the fingers lifting. The list tracked the pad 1:1 and
            // then stopped dead -- which is exactly the "not fluid" feel: the
            // motion is 1:1 but there is no continuation past the fingertips.
            // The quiet test only means anything once time has actually been
            // allowed to pass, so it belongs on the timer, not on the event.
            root.coasting = true;
            flingTimer.restart();
            return;
        }
        // A frame with NO delta in either field. This is not a mouse notch and
        // it is not a scroll: it is what libinput emits as the fingers leave
        // the pad.
        //
        // It used to fall through to the mouse branch below, which cancels the
        // coast outright (`coasting = false; flingTimer.stop(); fling.reset()`).
        // So the list threw away its own velocity on the one frame that marks
        // the START of the fling, and stopped dead the instant the fingers
        // came off -- the exact opposite of a natural flick. The synthetic
        // tests never caught this because they only ever sent non-zero
        // deltas, so this path had never been exercised.
        //
        // Treating it as "the hand is still here, just momentarily still"
        // keeps the coast armed: the timer is left running, and flingTick
        // applies the 70ms quiet test itself once real time has passed.
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
        // A real wheel notch means a mouse: cancel any coast.
        root.coasting = false;
        flingTimer.stop();
        root.fling.reset();
        wheelEvent.accepted = true;
    }

    function maxScrollY() {
        return Math.max(0, root.contentHeight - root.height);
    }

    // One tick of the coast, on a frame timer so the position follows the
    // exponential curve exactly.
    //
    // The timer does double duty: it is BOTH the thing that waits out the
    // lift-off and the thing that advances the coast. While events keep
    // arriving it returns without moving anything, and once they have been
    // quiet for FLING_START_MS it starts stepping. That is why arming it from
    // the wheel handler (above) is enough -- the timer keeps running through
    // the gap and is still there when the fingers come off the pad.
    function flingTick() {
        if (!root.coasting) {
            flingTimer.stop();
            return;
        }
        const now = Date.now();
        if (now - root.fling.state.lastEventMs < Fling.FLING_START_MS) {
            // Fingers still on the pad. Keep the timer alive so it is
            // running when they lift; do NOT stop it, and do not decay
            // anything yet.
            return;
        }
        // Quiet now. If the gesture was too slow or too short to be a flick,
        // this is where that gets noticed -- and the coast is abandoned
        // instead of creeping.
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
        // the touchpad path (wheelAnimEnabled above -- 1:1 with the fingers,
        // an animation layer there is the "laggy" feel) and for finger
        // drags/flicks, which must track the hand directly.
        enabled: root.wheelAnimEnabled && !root.dragging && !root.flicking
        NumberAnimation {
            id: scrollAnim
            // NOT alwaysRunToEnd: a new wheel event during an ease must
            // retarget from the CURRENT position. Always-running to the end
            // of the old animation is what made fast repeated scrolling feel
            // like it was fighting itself and lagging a frame behind.
            alwaysRunToEnd: false
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

    onContentHeightChanged: {
        if (root.coasting && root.contentY >= root.maxScrollY())
            root.fling.reset();
    }

    add: Transition {
        animations: animateAppearance ? [
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "opacity",
                from: 0,
                to: 1,
            }),
            // Split out from the opacity fade above rather than sharing its
            // `from`, so a list can scale in softly (the corner popup drops in
            // from above and only wants a 6% scale to sell the depth) while
            // every other list keeps popping from nothing exactly as before.
            ...(popin ? [Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "scale",
                from: root.addScaleFrom,
                to: 1,
            })] : []),
        ] : []
    }

    addDisplaced: Transition {
        animations: animateAppearance ? [
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "y",
            }),
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                properties: popin ? "opacity,scale" : "opacity",
                to: 1,
            }),
        ] : []
    }
    
    displaced: Transition {
        animations: root.animateMovement ? [
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "y",
            }),
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                properties: "opacity,scale",
                to: 1,
            }),
        ] : []
    }

    move: Transition {
        animations: root.animateMovement ? [
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "y",
            }),
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                properties: "opacity,scale",
                to: 1,
            }),
        ] : []
    }
    moveDisplaced: Transition {
        animations: root.animateMovement ? [
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "y",
            }),
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                properties: "opacity,scale",
                to: 1,
            }),
        ] : []
    }

    remove: Transition {
        animations: animateAppearance ? [
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "x",
                to: root.width + root.removeOvershoot,
            }),
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "opacity",
                to: 0,
            })
        ] : []
    }

    // This is movement when something is removed, not removing animation!
    removeDisplaced: Transition { 
        animations: animateAppearance ? [
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                property: "y",
            }),
            Appearance?.animation.elementMove.numberAnimation.createObject(this, {
                properties: "opacity,scale",
                to: 1,
            }),
        ] : []
    }
}
