import qs.modules.common
import "scrollfling.js" as Fling
import QtQuick

/**
 * A GridView with the shell's scroll contract.
 *
 * WHY THIS EXISTS
 * ---------------
 * The file manager's tiles view was a bare GridView, while the details list
 * beside it was a StyledListView -- so the two views of the SAME folder
 * scrolled through completely different code. The list had the shell rule
 * (one gain, one momentum model, one door: see scrollfling.js); the grid had
 * Qt's defaults: no config scroll factors, no touchpad gain, no coast at
 * lift-off, no eased wheel steps, bouncy bounds and the default velocity cap.
 * Reported as "scrolling up and down in the file manager is very difficult"
 * when the view is set to big icons -- which is exactly what scrolling a
 * surface without any of that feels like.
 *
 * StyledFlickable and StyledListView already told this story once: each keeps
 * its own wiring, both over the ONE fling model in scrollfling.js, because
 * two surfaces that each hand-roll the physics drift apart. This is the third
 * surface, following the same pattern. Only the scroll contract is copied --
 * nothing else (no drag machinery, no appearance transitions, no position
 * bookmark): the tiles asked for parity in scrolling, not a second copy of
 * the list.
 *
 * The wheel MouseArea, the Behavior and the bounds settings are the same
 * arrangement as StyledListView's, in the same places, so a gesture over the
 * tiles resolves exactly as it does over a row.
 */
GridView {
    id: root

    // ── One door into the gain and the fling (THE SHELL-WIDE SCROLL RULE) ──
    // See StyledListView for the long form of every line here; the values and
    // their defaults are deliberately identical so the two views of one
    // folder cannot disagree.
    property real touchpadScrollFactor: Config?.options.interactions.scrolling.touchpadScrollFactor ?? 100
    property real mouseScrollFactor: Config?.options.interactions.scrolling.mouseScrollFactor ?? 50
    property real mouseScrollDeltaThreshold: Config?.options.interactions.scrolling.mouseScrollDeltaThreshold ?? 120
    property bool fasterTouchpadScroll: Config?.options.interactions.scrolling.fasterTouchpadScroll ?? false
    // Cancels the compositor's scroll_factor the same way StyledListView does;
    // see that file and scrollfling.js for why it is not fixed there.
    readonly property real touchpadGain: root.touchpadGainOverride > 0
        ? root.touchpadGainOverride
        : (fasterTouchpadScroll ? Fling.TOUCHPAD_GAIN * 1.5 : Fling.TOUCHPAD_GAIN)
    // Per-grid override of the gain above. 0 = follow the config.
    property real touchpadGainOverride: 0

    // Accumulated scroll destination so wheel deltas stack while animating.
    property real scrollTargetY: 0
    // False while a touchpad gesture or its coast is driving contentY, so the
    // Behavior below passes those writes through raw.
    property bool wheelAnimEnabled: true
    // The touchpad gesture's own state, handed to the shared fling model.
    property var fling: Fling.create({ velocity: 0, lastEventMs: 0, distance: 0, samples: [] })
    property bool coasting: false

    // The same hard edges as the list: no rubber band, capped flick velocity.
    maximumFlickVelocity: 8000
    boundsBehavior: Flickable.StopAtBounds

    function maxScrollY() {
        return Math.max(0, root.contentHeight - root.height);
    }

    // Touchpad: pixel deltas applied 1:1 with the shared gain, mouse: instant
    // notches through the config factors. Identical to StyledListView's
    // handleWheel, because parity is the entire point -- see that function's
    // comments for why each branch is shaped the way it is (the arm-the-coast
    // rule, the zero-delta lift-off frame, the retargeting ease).
    function handleWheel(wheelEvent) {
        const maxY = root.maxScrollY();
        const pd = wheelEvent.pixelDelta;
        if (pd && (pd.x !== 0 || pd.y !== 0)) {
            wheelEvent.accepted = true;
            scrollAnim.stop();
            root.wheelAnimEnabled = false;
            const now = Date.now();
            const dy = root.fling.feed(-pd.y * root.touchpadGain, now);
            const next = Math.max(0, Math.min(root.contentY + dy, maxY));
            root.contentY = next;
            root.scrollTargetY = next;
            root.wheelAnimEnabled = true;
            // Arm the coast on every event; flingTick applies the quiet test.
            root.coasting = true;
            flingTimer.restart();
            return;
        }
        // The fingers-lifting frame (no delta in either field): keep the
        // coast armed rather than cancelling it -- see StyledListView.
        if (!wheelEvent.angleDelta || (wheelEvent.angleDelta.x === 0 && wheelEvent.angleDelta.y === 0)) {
            wheelEvent.accepted = true;
            return;
        }
        const delta = wheelEvent.angleDelta.y / root.mouseScrollDeltaThreshold;
        const scrollFactor = Math.abs(wheelEvent.angleDelta.y) >= root.mouseScrollDeltaThreshold ? root.mouseScrollFactor : root.touchpadScrollFactor;
        const base = scrollAnim.running ? root.scrollTargetY : root.contentY;
        root.scrollTargetY = Math.max(0, Math.min(base - delta * scrollFactor, maxY));
        root.contentY = root.scrollTargetY;
        root.coasting = false;
        flingTimer.stop();
        root.fling.reset();
        wheelEvent.accepted = true;
    }

    // One tick of the coast. Same double duty as StyledListView's: waits out
    // the lift-off while events keep arriving, then advances the curve.
    function flingTick() {
        if (!root.coasting) {
            flingTimer.stop();
            return;
        }
        const now = Date.now();
        if (now - root.fling.state.lastEventMs < Fling.FLING_START_MS)
            return;
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

    // Declared as a child of the view, so it lands in the CONTENT item the
    // same way the empty-space menus do -- it scrolls with the tiles and sits
    // under the wheel wherever the pointer is over the grid.
    MouseArea {
        id: scrollMouse
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: function(wheelEvent) {
            root.handleWheel(wheelEvent);
        }
    }

    Behavior on contentY {
        // Eases the mouse-wheel steps; suspended for the touchpad (1:1 with
        // the fingers), drags and flicks -- identical rule to StyledListView.
        enabled: root.wheelAnimEnabled && !root.dragging && !root.flicking
        NumberAnimation {
            id: scrollAnim
            // A new wheel event during an ease retargets from the CURRENT
            // position rather than finishing the old jump first.
            alwaysRunToEnd: false
            duration: Appearance.animation.scroll.duration
            easing.type: Appearance.animation.scroll.type
            easing.bezierCurve: Appearance.animation.scroll.bezierCurve
        }
    }

    // Keep the target synced when nothing is easing (drag, flick, programmatic
    // writes), so the next notch starts from where the content actually is.
    onContentYChanged: {
        if (!scrollAnim.running)
            root.scrollTargetY = root.contentY;
    }

    onContentHeightChanged: {
        if (root.coasting && root.contentY >= root.maxScrollY())
            root.fling.reset();
    }
}
