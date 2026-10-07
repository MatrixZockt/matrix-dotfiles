// WallpaperCarousel -- the coverflow.
//
// The FOCUSED wallpaper is the large card in the centre; the others fan out to
// BOTH sides as narrowing slivers with their own reflections underneath. The
// strip is circular: stepping past the last wallpaper wraps around to the
// first, so the cards connect into a ring and the carousel can be turned
// forever in one direction -- which is also why there are always wallpapers on
// both sides of the focus even when it is the newest entry in the history.
//
// Scrolling (wheel or two fingers, either axis) turns the ring; clicking a
// card applies it. Sizes come in two grades: "pill" (the desktop picker) and
// "stage" (the full-screen chooser the pill unfolds into), same component,
// same geometry rules, different metrics.
//
// Layout is arithmetic, not a PathView: every card's x/width/height/opacity is
// a pure function of its CIRCULAR distance from the centre, so only transform
// and geometry animate and nothing relayouts the shell. Cards further out than
// `sides` steps are not instantiated at all; reflections only for the nearest
// two steps -- a 40-entry history still costs a handful of fills.
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

Item {
    id: root

    // ── API ──────────────────────────────────────────────────────────────
    property var items: []              // wallpaper paths; index 0 is not special
    property string currentPath: ""     // the wallpaper in use: gets centred
    property int currentIndex: 0
    property string sizeMode: "pill"    // "pill" (compact) | "stage" (fullscreen)
    property bool showAdd: true
    property bool allowRemove: false
    // Reflections are OFF by default: the mirrored band under each card read
    // as a dark rectangle under every wallpaper (the gradient that fades the
    // mirror into the backdrop is itself a dark wash on a dark theatre), and
    // the user asked for them gone. Hosts may still opt back in explicitly.
    property bool showReflections: false
    // What the reflections fade INTO. The cards are drawn on top of whatever
    // the host puts behind the carousel, so the mirror has to fade to the same
    // colour or it ends in a hard edge. The host passes its own backdrop.
    property color backdrop: "transparent"
    // Keyboard nav is opt-in: taking focus by default would fight whatever the
    // host (the settings page) is doing with it, and the desktop picker never
    // has keyboard focus anyway.
    property bool keyboardEnabled: false

    signal activated(string path)       // user picked this wallpaper
    // The auto-switch timer applied the next wallpaper on its own. Deliberate
    // NOT `activated`: hosts treat that as "the user chose -- close the
    // picker", which an unattended rotation must never do.
    signal autoSwitched(string path)
    signal addRequested()
    signal removeRequested(string path)
    // A deliberate two/three-finger swipe DOWN anywhere over the picker:
    // the host (wallpaper theatre) closes on this.
    signal closeRequested()

    // ── Metrics ──────────────────────────────────────────────────────────
    readonly property bool stage: root.sizeMode === "stage"
    readonly property real centerW: root.stage ? 520 : 340
    readonly property real centerH: root.stage ? 340 : 264
    readonly property int sides: root.stage ? 3 : 3
    // How far out a card keeps its IMAGE DECODED. Deliberately WIDER than
    // `sides`, which is how far out a card stays DRAWN.
    //
    // The two must not be the same number. `sides` drives `inRange`, which
    // decides `visible`, the delegate's opacity and -- fatally -- whether the
    // card's Loader is `active`. A card that crossed that boundary had its
    // Loader torn down, destroying the ThumbnailImage with it, and
    // ThumbnailImage is `opacity: status === Image.Ready ? 1 : 0`: so every
    // re-entry came back BLANK until it finished decoding again.
    //
    // On a slow scroll that is a flicker. On a fast one it is the bug this
    // fixes: a card could be destroyed at distance 4 and then arrive at the
    // centre, so the single most important image in the strip -- the one you
    // are scrolling TOWARDS -- was the one most likely to be blank when it
    // got there.
    //
    // Loading two cards further out costs a few more resident thumbnails (they
    // are generated smalls, not the full wallpapers) and buys the property
    // that matters: by the time a card is visible its image is already
    // Ready. Cards are still torn down at `loadSides` rather than kept
    // forever, so a long history does not pin every thumbnail in memory.
    readonly property int loadSides: root.sides + 2
    readonly property real gap: root.stage ? 12 : 9
    // The mirror band: how tall the reflection strip is, and the hair of clear
    // space between a card and its own reflection.
    readonly property real reflectGap: 4
    readonly property real reflectH: root.showReflections ? root.centerH * 0.40 : 0
    // The add row UNDER the strip: a quiet pill, not a tile in the flow.
    readonly property real addRowH: root.stage ? 46 : 42
    readonly property real addRowGap: 14
    // Cards are centred in the CARD band; reflection and add rows hang below.
    readonly property real cardBand: root.centerH

    // Width of the sliver `d` steps out from the middle (d >= 1): a fraction of
    // the centre card, shrinking geometrically, floored so it never vanishes.
    function sliverWidth(d) {
        return Math.max(15, root.centerW * 0.17 * Math.pow(0.84, d - 1));
    }
    function sliverHeight(d) {
        return root.centerH * Math.max(0.52, 0.80 * Math.pow(0.94, d - 1));
    }
    // Distance from the middle of the strip to the LEFT edge of that sliver.
    function sliverLeft(d) {
        let x = root.centerW / 2 + root.gap;
        for (let j = 1; j < d; j++) x += root.sliverWidth(j) + root.gap;
        return x;
    }
    // Distance from the middle of the strip to the CENTRE of the card at d.
    function offsetForD(d) {
        const a = Math.abs(d);
        if (a === 0) return 0;
        const centre = root.sliverLeft(a) + root.sliverWidth(a) / 2;
        return d < 0 ? -centre : centre;
    }
    // CONTINUOUS version of offsetForD: interpolates the slot geometry for
    // fractional d, so a card's x can be bound to the spring's live `pos`
    // and glide between slots as ONE fluid motion. (The integer version
    // forced per-frame snapping to the next slot, whose Behavior then had
    // to restart over and over -- the source of the stuttery glide.)
    function offsetForCont(d) {
        if (Math.abs(d) < 0.0001) return 0;
        const s = d < 0 ? -1 : 1;
        const a = Math.abs(d);
        const f = Math.floor(a);
        const c = Math.ceil(a);
        if (f === c) return s * root.offsetForD(f);
        const o0 = root.offsetForD(f);
        const o1 = root.offsetForD(c);
        return s * (o0 + (o1 - o0) * (a - f));
    }
    // Distance from the middle of the strip to the LEFT edge of the card at
    // d -- the negative-d mirror of offsetForD's arithmetic: the track is
    // symmetric, so the edge of a d<0 card sits as far out as the centre of
    // its |d| counterpart.
    function leftEdgeForD(d) {
        if (d >= 0) return root.offsetForD(d) - root.sliverWidth(Math.max(1, d)) / 2;
        return -(root.offsetForD(-d) + root.sliverWidth(Math.abs(d)) / 2);
    }

    readonly property real stripHalf: root.sliverLeft(root.sides) + root.sliverWidth(root.sides)

    // CONTINUOUS card size, in fractional steps from the centre.
    //
    // These exist so the card's geometry needs no Behavior at all. The size
    // used to be a step function -- "centre card, or the sliver for my
    // integer distance" -- and the discrete jump was smoothed by a Behavior
    // on `width`. That is a per-frame relayout of every visible card on every
    // frame the ring moves (a width change re-aims the child's anchors), and
    // it is the carousel lag: the strip is small, the spring is short, and
    // seven relayouts per frame is more work than the compositor can retire
    // at 60 Hz. Evaluating the size directly from the fractional distance
    // gives the same motion -- it is still exactly the spring, just computed
    // instead of animated -- and it is smooth by construction.
    function cardWidthForCont(a) {
        if (a <= 0.0001) return root.centerW;
        if (a <= 1) return root.centerW + (root.sliverWidth(1) - root.centerW) * a;
        const f = Math.floor(a);
        const w0 = root.sliverWidth(f);
        const w1 = root.sliverWidth(f + 1);
        return w0 + (w1 - w0) * (a - f);
    }
    // Opacity by the same continuous argument: full at the centre, easing out
    // over the first slot, then decaying per step, floored so the outermost
    // sliver is still visible against the scrim.
    function opacityForCont(a) {
        if (a <= 0.0001) return 1;
        if (a >= root.sides) return 0;
        const first = Math.max(0.38, 0.92 * Math.pow(0.78, 0));
        if (a <= 1) return 1 + (first - 1) * a;
        return Math.max(0.38, 0.92 * Math.pow(0.78, a - 1));
    }
    function cardHeightForCont(a) {
        if (a <= 0.0001) return root.centerH;
        if (a <= 1) return root.centerH + (root.sliverHeight(1) - root.centerH) * a;
        const f = Math.floor(a);
        const h0 = root.sliverHeight(f);
        const h1 = root.sliverHeight(f + 1);
        return h0 + (h1 - h0) * (a - f);
    }

    implicitWidth: root.stripHalf * 2
    implicitHeight: root.cardBand + root.reflectGap + root.reflectH
        + (root.showAdd ? root.addRowGap + root.addRowH : 0)
        + 22 // the scrubber: its gap under the add row plus the line itself

    // ── The ring ─────────────────────────────────────────────────────────
    // Signed CIRCULAR distance from the focused card: 0 is the centre, +1 the
    // next card to the right, -1 the one to the left -- wrapping through the
    // ends of the list, so the last and first wallpapers are neighbours and
    // the ring has no seam. This is what puts wallpapers on BOTH sides of the
    // focus even when it is items[0]: the entries after it in the history are
    // positive steps, the ones before it (the oldest) wrap to negative steps.
    readonly property int count: root.items.length
    function circularD(i) {
        if (root.count === 0) return 0;
        let d = i - root.currentIndex;
        d = ((d % root.count) + root.count) % root.count;
        if (d > root.count / 2) d -= root.count;
        return d;
    }

    // ── Selection plumbing ───────────────────────────────────────────────
    function indexOf(path) {
        for (let i = 0; i < root.items.length; i++)
            if (String(root.items[i]) === String(path)) return i;
        return -1;
    }
    function centreOn(path) {
        const i = root.indexOf(path);
        if (i >= 0) root.currentIndex = i;
    }
    // Wraps: stepping off either end of the list comes back in the other side,
    // so the carousel turns around like a ring instead of hitting a wall.
    // Spring-driven: the target moves one card, pos chases it, and posVel
    // leans into the turn so the motion has momentum instead of snapping.
    function step(delta) {
        if (root.count === 0) return;
        root.spinning = false; // a deliberate step grabs the ring out of any roll
        root.posVel = 0;
        const target = Math.round(root.pos) + delta;
        root.posDriving = true;
        root.currentIndex = ((Math.round(target) % root.count) + root.count) % root.count;
        root.posDriving = false;
        root.posTarget = target;
        root.emitSteps();
    }
    function activateCurrent() {
        const p = root.items[root.currentIndex];
        if (p) root.activated(String(p));
    }
    function activateIndex(i) {
        const idx = ((i % root.count) + root.count) % root.count;
        root.spinning = false;
        root.posVel = 0;
        // A click is an instruction, not momentum: unlike a step (where the
        // spring's own velocity should carry across, so repeated input blends
        // into one move) this may cross the whole strip, and old momentum
        // would visibly overshoot the chosen card on the way.
        root.springVel = 0;
        root.posDriving = true;
        root.currentIndex = idx;
        root.posDriving = false;
        // Glide the ring to the chosen card the short way around, then apply.
        let t = idx;
        while (t - root.pos > root.count / 2) t -= root.count;
        while (t - root.pos < -root.count / 2) t += root.count;
        root.posTarget = t;
        root.posVel = 0;
        root.activateCurrent();
    }
    // Step WITHOUT applying: the arrows and keyboard turn the ring only.
    function nudge(delta) {
        if (root.count === 0) return;
        root.spinning = false;
        root.posVel = 0;
        const target = Math.round(root.pos) + delta;
        root.posDriving = true;
        root.currentIndex = ((Math.round(target) % root.count) + root.count) % root.count;
        root.posDriving = false;
        root.posTarget = target;
        root.emitSteps();
    }

    // Keep the ring centred on the current wallpaper through every change.
    onCurrentPathChanged: root.centreOn(root.currentPath)
    onItemsChanged: root.centreOn(root.currentPath)
    Component.onCompleted: root.centreOn(root.currentPath)

    // Moving the selection without applying it (arrows / scroll) only
    // re-centres; applying is Enter or a click.
    focus: root.keyboardEnabled
    activeFocusOnTab: root.keyboardEnabled
    Keys.onLeftPressed: root.step(-1)
    Keys.onRightPressed: root.step(1)
    Keys.onReturnPressed: root.activateCurrent()
    Keys.onEnterPressed: root.activateCurrent()

    // ── Arrow keys follow the POINTER, not the focus owner ──────────────
    // `focus: keyboardEnabled` alone is not enough: it only listens while this
    // item happens to hold focus, and in the settings page the pane AROUND the
    // carousel owns focus (a scroll view, a switch, the search field) -- so a
    // click anywhere else silently killed the arrow keys, which reads as "the
    // arrow keys do nothing". Pointing at the carousel now claims focus for it
    // while you are pointing at it, which is when you would press them.
    //
    // Guarded on `keyboardEnabled`, so it can never steal focus in the theatre,
    // where the window itself routes the keys (the carousel there is
    // deliberately not a focus owner -- two focus owners fight and the keys
    // arrive at neither).
    HoverHandler {
        id: focusHover
        onHoveredChanged: {
            if (hovered && root.keyboardEnabled)
                root.forceActiveFocus(Qt.MouseFocusReason);
        }
    }

    // ── Continuous ring position ─────────────────────────────────────
    // `pos` is the ring's scroll position in CARD UNITS (0 = focused card
    // centred, fractional = between cards). All input funnels into
    // `posTarget`; `pos` chases it through one damped spring, so every
    // motion -- pointer drift, wheel, flick, momentum -- is analog and
    // fluid, and nothing ever snaps. The focused card is whichever card is
    // nearest `pos`.
    property real pos: 0
    property real posTarget: 0
    property real posVel: 0
    // The spring's OWN velocity, separate from `posVel`. `posVel` belongs to
    // the free-spin branch and is deliberately zeroed when a spin ends; the
    // spring needs to keep its own momentum across target changes or every
    // nudge restarts the ease from a dead stop (see the ticker).
    property real springVel: 0
    property bool posDriving: false // guards the pos<->currentIndex sync loop

    // ── The two destinies of a release ───────────────────────────────────
    // Gentle input (wheel, arrows, a calm swipe) lands the ring on the NEAREST
    // card with a quick magnetic settle -- the touch-screen behaviour. A HARD
    // release becomes the wheel of fortune: the finger's velocity is handed to
    // the ring, which rolls FREE under exponential friction (no target to
    // chase, multi-card wraps included) until the speed drops below the
    // threshold -- then the remaining coast distance projects the landing card
    // and the ring snaps onto it like a magnet. No fake deceleration: the
    // landing is always where the real physics stops.
    // The spring's natural frequency (rad/s) for every gentle move: wheel
    // notches, arrow keys, a calm swipe's settle, and the magnet landing of a
    // finished spin. Critically damped, so it never overshoots; 18 settles to
    // ~2% in about a third of a second, which is slow enough to read as
    // deceleration and fast enough not to feel sticky. Lower this only if the
    // ring feels like it drifts; raise it if it feels like it arrives too
    // early. It is now a true spring rather than a fixed-fraction ease (see
    // the ticker), which is why the value reads as stiffness, not as a rate.
    readonly property real followRate: 18
    readonly property real spinTau: 0.5       // fortune-glide friction time constant (s)
    readonly property real spinThreshold: 3.0 // release speed (cards/s) that becomes a spin
    // Was 25 cards/s -- at that cap a hard flick rolled the ring for seconds
    // (the other half of the wobble). 8 is still a decisive fling but the
    // wheel-of-fortune ride is gone; the magnet landing takes over quickly.
    readonly property real maxSpinVel: 8      // flick sanity cap (cards/s)
    property bool spinning: false

    // ── Three-finger drag input (the theatre feeds it; see WallpaperModal) ─
    // The tracker reports horizontal travel in FRACTIONS of the pad's width;
    // a full sweep turns this many cards. The vertical axis keeps the
    // close-the-picker flick.
    readonly property real dragCardsPerSweep: 5
    property real dragVelEma: 0
    property real dragLastAt: 0
    // A 3-finger drag session is alive (fresh within 300ms). While it is,
    // touchpad axis events are ignored: the compositor may echo the same
    // physical swipe as pointer scroll, and one swipe must never scroll the
    // ring twice.
    property bool drag3fLive: false

    function cancelDrag() {
        // The pad vanished / a palm landed: stop everything, settle home.
        carouselGestureEnd.stop();
        root.spinning = false;
        root.springVel = 0;
        root.posVel = 0;
        root.flingVel = 0;
        root.dragVelEma = 0;
        root.posTarget = Math.round(root.pos);
        root.emitSteps();
    }

    // One frame of a 3-finger swipe, from the shell's evdev tracker
    // (touchpad-swipe.py --fingers 3, run only while the theatre is open).
    // dxFrac/dyFrac are fractions of the pad's width/height since the last
    // frame. Same gesture grammar as feedWheel: axis re-decided every frame,
    // horizontal turns the ring 1:1, a decisive downward travel closes.
    function feedDrag(dxFrac, dyFrac) {
        const now = Date.now();
        root.drag3fLive = true;
        drag3fDecay.restart();
        if (!carouselGestureEnd.running) {
            root.gestureAxis = 0;
            root.accX = 0;
            root.accY = 0;
            root.vDownPx = 0;
        }
        root.accX += Math.abs(dxFrac);
        root.accY += Math.abs(dyFrac);
        if (dyFrac < 0)
            root.vDownPx += -dyFrac * 800; // ≈px of finger for the close flick
        if (root.accX >= root.accY * 1.25 && root.accX >= 0.008)
            root.gestureAxis = 1;
        else if (root.accY >= root.accX * 1.25 && root.accY >= 0.008)
            root.gestureAxis = 2;
        carouselGestureEnd.restart();
        if (root.gestureAxis !== 1)
            return false;
        // Fingers down: the ring obeys, 1:1. Any roll is over.
        root.spinning = false;
        root.posVel = 0;
        const cards = dxFrac * root.dragCardsPerSweep;
        root.posTarget += cards;
        root.pos = root.posTarget;
        // `pos` is written DIRECTLY here (1:1 tracking), so any velocity the
        // spring still holds would fight the finger on the next frame and
        // then be released as a phantom flick at lift-off. Zero it for the
        // duration of the gesture.
        root.springVel = 0;
        const dt = now - root.dragLastAt;
        if (dt > 0 && dt < 120)
            root.dragVelEma = root.dragVelEma * 0.65 + (cards / (dt / 1000)) * 0.35;
        root.dragLastAt = now;
        root.lastWheelTime = now;
        root.flingVel = root.dragVelEma; // lift-off reads the same velocity
        root.emitSteps();
        return true;
    }

    Timer {
        id: drag3fDecay
        interval: 300
        onTriggered: root.drag3fLive = false
    }
    function emitSteps() {
        // Normalise the target to within a HALF TURN of the position: the ring
        // always turns the short way, and a long spin cannot drift.
        //
        // This used to hold the target within ONE CARD of the position
        // (`while (posTarget - pos >= 1) posTarget -= 1`), which silently
        // CANCELLED every whole-card step. With the ring settled -- the normal
        // state -- an arrow key or a wheel notch sets posTarget to pos + 1, and
        // that clamp immediately subtracted it straight back, so the arrows,
        // the wheel and the two edge buttons moved NOTHING while a swipe only
        // ever ate its own excess (one card per gesture, then a slow crawl).
        // Normalising modulo the ring keeps "turn the short way" without ever
        // touching a step that is already short.
        // Wrap within ONE FULL RING of the position -- NOT half a ring. A
        // fast multi-card swipe or a momentum burst legitimately opens a gap
        // bigger than half the ring mid-flight, and the old half-ring wrap
        // REVERSED the ring mid-gesture: the "suddenly stops / jumps back"
        // stall. The short-way choice for single steps is already made by
        // step()/nudge() (their delta is ±1), so this only needs to bound
        // long-run drift.
        if (root.count <= 0)
            return;
        while (root.posTarget - root.pos > root.count)
            root.posTarget -= root.count;
        while (root.posTarget - root.pos < -root.count)
            root.posTarget += root.count;
    }
    onPosChanged: {
        root.posDriving = true;
        const i = Math.round(root.pos);
        const idx = ((i % root.count) + root.count) % root.count;
        if (root.count > 0 && idx !== root.currentIndex) root.currentIndex = idx;
        root.posDriving = false;
    }
    onCurrentIndexChanged: {
        if (root.posDriving) return;
        root.pos = root.currentIndex;
        root.posTarget = root.currentIndex;
        // This path hard-sets both ends (an external selection change, e.g. the
        // wallpaper changing under the picker), so there is no motion to carry:
        // the spring's leftover velocity from a previous gesture would push
        // the ring straight back off the new card.
        root.springVel = 0;
    }
    Timer {
        id: posTicker
        interval: 16
        repeat: true
        running: root.spinning || Math.abs(root.posTarget - root.pos) > 0.001
            || Math.abs(root.posVel) > 0.05 || Math.abs(root.springVel) > 0.01
        onTriggered: {
            const dt = 0.016;
            if (root.spinning) {
                // THE WHEEL OF FORTUNE, in progress. `pos` is pure physics:
                // exponential friction is the only force, there is no target
                // to chase, and the ring wraps as freely as it likes. When
                // friction bleeds the speed below the threshold, the remaining
                // coast distance (v * tau, the exact integral of the same
                // decay) projects the landing card -- and the spring below
                // takes over as a magnet snap onto it.
                root.posVel *= Math.exp(-dt / root.spinTau);
                root.pos += root.posVel * dt;
                root.posTarget = root.pos;
                if (Math.abs(root.posVel) < root.spinThreshold) {
                    const landing = root.pos + root.posVel * root.spinTau;
                    root.spinning = false;
                    // Hand the spin's remaining momentum to the spring instead
                    // of dropping it: the magnet catches a rolling ring, it
                    // does not yank a stationary one. Without this the landing
                    // is a visible speed change (fast -> dead -> creep), which
                    // is a second snap at the end of every flick.
                    root.springVel = root.posVel;
                    root.posVel = 0;
                    root.posTarget = Math.round(landing);
                }
                root.emitSteps();
            } else {
            // Everything gentle rides a CRITICALLY DAMPED SPRING -- wheel
            // notches, arrow keys, a calm swipe's settle, and the magnet
            // landing of a finished spin.
            //
            // This used to be the one-liner `pos += (posTarget - pos) *
            // min(1, rate*dt)`. That expression is an exponential ease with
            // NO VELOCITY: it is an infinite sequence of fixed proportions, so
            // (a) every frame moves a constant FRACTION of the gap, meaning
            // the ring is always at maximum speed and only the gap shrinks --
            // a decelerate-shaped curve whose velocity is discontinuous at
            // BOTH ends (it jumps to full speed on the first frame and to zero
            // on the last), which is exactly what the eye reads as a snap; and
            // (b) any target change while moving restarts that ease from a
            // standstill, so a held key or a continuous swipe threw away the
            // motion it had already built.
            //
            // The closed-form critically damped spring keeps its velocity
            // across target changes (so continuous input blends into one
            // unbroken move instead of restarting), and both its velocity and
            // acceleration are continuous at the endpoints -- real inertia.
            // `omega` is the natural frequency: higher converges faster and
            // also feels stiffer. 18 is a settle of ~330ms with no overshoot.
            const omega = root.followRate;
            const x = root.pos - root.posTarget;      // gap (signed)
            const v = root.springVel;                 // carry velocity
            const e = Math.exp(-omega * dt);
            // Semi-implicit closed form of x'' = -2*omega*x' - omega^2*x
            const c = v + omega * x;
            root.pos = root.posTarget + (x + c * dt) * e;
            root.springVel = (v - c * omega * dt) * e;
            // MID-GESTURE SETTLE: fingers down but TRULY resting (no events
            // for ~250ms while the gesture timer still runs) => ease the
            // target to the nearest card. The threshold is deliberately long:
            // a shorter one chopped every hesitation into a single-card step,
            // which read as "one swipe = one wallpaper". Real rotation runs
            // free; only a genuine rest settles -- and lift-off always rounds
            // anyway, so nothing can ever rest at a half rotation.
            if (carouselGestureEnd.running
                && Date.now() - root.lastWheelTime > 190
                && Math.abs(root.posTarget - Math.round(root.posTarget)) > 0.001) {
                const snapped = Math.round(root.posTarget);
                root.posTarget += (snapped - root.posTarget) * Math.min(1, 10 * dt);
                if (Math.abs(root.posTarget - snapped) < 0.002)
                    root.posTarget = snapped;
                // A park also retires the stored finger velocity: the fingers
                // demonstrably stopped, so lifting now is a drag-release, not
                // a flick -- releasing the pre-pause velocity here would fling
                // the ring away for no reason.
                root.flingVel = 0;
                root.emitSteps();
            }
            // Landing: close enough that the remaining gap is sub-pixel, so
            // finish exactly on the card (no permanent 0.0008 offset that
            // would keep the ticker alive) and retire the spring's velocity so
            // the next nudge starts from rest rather than from this move's
            // leftover momentum.
            if (Math.abs(root.posTarget - root.pos) < 0.001 && root.posVel === 0) {
                root.pos = root.posTarget;
                root.springVel = 0;
            }
            }
        }
    }

    // ── Two-finger horizontal swipe & wheel ──────────────────────────────
    // The swipe is DISCRETE and SNAPPY, exactly like the arrow keys:
    // accumulated finger travel fires one full step() per threshold crossed,
    // so every card snaps in with the same spring an arrow press uses, and a
    // fast swipe fires several steps in quick succession instead of dragging
    // an analog target behind the spring (which felt laggy).
    //
    // The gesture axis is RE-DECIDED on every event from the accumulated
    // travel -- never locked in. The old one-time lock starved real swipes:
    // an early vertical wobble locked the axis to "vertical", and since the
    // unlock timer only fired after 300 ms of QUIET (which never comes while
    // fingers keep moving), every following horizontal event was dropped --
    // the swipe died mid-gesture and stayed dead. Continuous re-decision
    // cannot stick.
    // Vertical gestures are dropped whole. A mouse wheel notch is still
    // exactly one card.
    property int gestureAxis: 0 // 0 undecided | 1 horizontal | 2 vertical
    property real accX: 0 // accumulated travel per gesture, both axes
    property real accY: 0
    // Downward finger travel of the current gesture (px). natural_scroll is
    // ON, so fingers moving down arrive as NEGATIVE dy; a settled vertical
    // gesture with at least one slot-pitch of downward travel is the
    // close-the-picker flick.
    property real vDownPx: 0
    // Whole-cards of (sensitivity-scaled) travel accumulated in the current
    // gesture; every whole card fires one detented step (see feedWheel).
    property real gestureTravel: 0
    // Ring cards per slot-pitch of finger travel. >1 = the ring turns more
    // per pixel of finger = higher sensitivity. 2.2 => ~144px of finger per
    // card at stage size: a casual swipe turns 2 cards, a firm one 3-4 -- the
    // ring REALLY rotates. (At the old 1.35 a card cost 234px of finger, so a
    // normal swipe never even reached one card and rounded back to where it
    // started -- every swipe read as "one swipe = one wallpaper".) The snap
    // to whole cards is untouched: rotation is free, resting is exact.
    // 1:1 finger tracking, measured: at 3.4 the ring over-travelled every
    // gesture ~3.4x (a calm 600px two-finger swipe spun the ring ~20 cards
    // -- the user's "wobbly"), and the fling EMA amplified the same error
    // into runaway spins at lift-off. At 1.0 one full pad sweep ≈ one card,
    // which is what the direct-tracking branch's own comment promises.
    // Momentum and the magnet landing still give the glide its life.
    // (v2 marker: forced reload check 2026-10-01)
    property real swipeSensitivity: 1.0
    // Cards-per-second finger velocity (EMA over the gesture), handed to the
    // ring's momentum the moment the fingers lift.
    property real flingVel: 0
    property real lastWheelTime: 0
    // Quiet period that ENDS a gesture. A touchpad streams events every
    // ~10-16ms while fingers are down, so ~150ms of silence reliably means
    // lift-off -- and that is when the fling hands the finger velocity to
    // `posVel` (which posTicker already decays and lands on the nearest
    // card): the touchscreen behaviour where the strip keeps rolling after
    // the finger leaves, then eases to rest on a card.
    Timer {
        id: carouselGestureEnd
        interval: 150
        onTriggered: {
            if (root.gestureAxis === 1) {
                // Lift-off: the release speed decides the destiny. A hard
                // flick SPINS the ring -- wheel-of-fortune physics, free
                // rolling with a magnet landing (see the ticker's spinning
                // branch). A gentle release SNAPS onto the nearest card
                // immediately: no glide tail, the strip parks while your
                // hand is still near the pad.
                const fresh = Date.now() - root.lastWheelTime < carouselGestureEnd.interval + 60;
                const v = fresh ? Math.max(-root.maxSpinVel, Math.min(root.maxSpinVel, root.flingVel)) : 0;
                if (Math.abs(v) >= root.spinThreshold) {
                    root.spinning = true;
                    root.posVel = v;
                } else {
                    // Gentle lift-off. The target rounds to the nearest card
                    // and the SPRING glides into it -- but it must start with
                    // the velocity the finger still had. `feedDrag` zeroes the
                    // spring every frame (it has to: it writes `pos` directly
                    // for 1:1 tracking), so without this hand-off the ring
                    // always begins its final card of travel from a dead stop
                    // no matter how smoothly the fingers were moving. That is
                    // the visible hitch at the end of every swipe, and it got
                    // worse as the spring got faster.
                    root.posTarget = Math.round(root.posTarget);
                    root.springVel = Math.max(-root.spinThreshold,
                        Math.min(root.spinThreshold, v));
                }
            } else if (root.gestureAxis === 2
                       && root.vDownPx >= Math.max(160, root.pxPerCard)) {
                // Decisive swipe DOWN: dismiss the picker (the host decides
                // what closing means). A two/three-finger down-flick reads
                // as "push it away" -- this is that gesture.
                root.closeRequested();
            }
            root.gestureAxis = 0;
            root.accX = 0;
            root.accY = 0;
            root.flingVel = 0;
            root.gestureTravel = 0;
            root.vDownPx = 0;
        }
    }

    // ── Auto-switch: the carousel turns itself ───────────────────────────
    // An optional wall-clock rotation: every `autoSwitchIntervalS` seconds the
    // ring steps one card and APPLIES it (a preview nobody applies is just
    // noise). Off by default; the host exposes the interval setting.
    property bool autoSwitchEnabled: false
    property int autoSwitchIntervalS: 300
    Timer {
        id: autoSwitchTimer
        interval: Math.max(10, root.autoSwitchIntervalS) * 1000
        repeat: true
        running: root.autoSwitchEnabled && root.count > 1
        triggeredOnStart: false
        onTriggered: {
            if (root.spinning || carouselGestureEnd.running) return; // never fight the user
            const idx = (((root.currentIndex + 1) % root.count) + root.count) % root.count;
            root.spinning = false;
            root.posVel = 0;
            root.posDriving = true;
            root.currentIndex = idx;
            root.posDriving = false;
            // Glide the ring to the next card the short way around.
            let t = idx;
            while (t - root.pos > root.count / 2) t -= root.count;
            while (t - root.pos < -root.count / 2) t += root.count;
            root.posTarget = t;
            root.emitSteps();
            root.autoSwitched(String(root.items[idx] ?? ""));
        }
    }
    // One card per this many px of finger travel: the pitch between adjacent
    // slot centres. Binding the swipe to the real slot pitch is what makes
    // the ring track the finger 1:1, like dragging a touch screen.
    readonly property real pxPerCard: Math.max(120, Math.abs(root.offsetForD(1)))
    // ONE wheel / two-finger event, from EITHER this carousel's own handler or a
    // HOST that covers more of the screen than the strip does (see the theatre
    // window's forwarder). Extracted into a function because the theatre NEEDS
    // it: when the picker opens, the pointer is wherever it was -- hovering the
    // pill, which sits BELOW the strip -- so a two-finger swipe there landed on
    // the backdrop and the carousel never saw a single event. That is exactly
    // "swiping does not move the carousel", and it is why the gesture must not
    // depend on the pointer happening to be over the cards.
    //
    //   ax, ay ..... notch (angle) deltas
    //   px, py ..... pixel deltas (smooth touchpads; 0 when the stack has none)
    //   isTouchpad . the caller's device verdict (see eventIsTouchpad)
    // Returns TRUE when the gesture was consumed (the ring turned, or a
    // horizontal/undecided touchpad gesture this component owns), and FALSE for
    // a decided VERTICAL one -- which the caller must let through, so a two
    // finger vertical scroll over the carousel still scrolls the page it sits
    // in instead of being swallowed.
    property real lastWheelAt: 0 // diagnostic: timestamp of the last real wheel event (read via IPC)
    function feedWheel(ax, ay, px, py, isTouchpad) {
        root.lastWheelAt = Date.now();
        const hasPixels = px !== 0 || py !== 0;
        const now = Date.now();
        if (isTouchpad) {
            // Pixel deltas are the smooth case; a notch-only touchpad gets an
            // equivalent synthetic travel (one detent ~ 40px of finger), so the
            // same axis gate and gain apply either way.
            const dx = hasPixels ? px : ax / 120 * 40;
            const dy = hasPixels ? py : ay / 120 * 40;
            // NEW-GESTURE detection: the end timer is not running => the
            // fingers just landed. Reset the accumulators so the axis is
            // decided from THIS gesture's travel alone. (Without the reset
            // they summed across the shell's whole lifetime: any vertical
            // scrolling anywhere made every later horizontal swipe resolve
            // as "vertical" -- the ring went dead until a huge horizontal
            // gesture rebalanced the all-time totals. Real diagonal fingers
            // hit this constantly; straight-line synthetic swipes never did.)
            // NOTE: bare id, NOT `root.carouselGestureEnd` -- the Timer's id is
            // file-scoped, not a root property; `root.`-prefixed access is
            // undefined and threw a TypeError on every touchpad-classified
            // event, which silently ate every two-finger swipe.
            if (!carouselGestureEnd.running) {
                root.accX = 0;
                root.accY = 0;
                root.gestureAxis = 0;
                root.vDownPx = 0;
            }
            root.accX += Math.abs(dx);
            root.accY += Math.abs(dy);
            if (dy < 0)
                root.vDownPx += -dy; // fingers travelling DOWN (natural scroll)
            // RE-DECIDE the axis on every event from the accumulated travel.
            // No lock-in: if the dominant axis flips mid-gesture the carousel
            // follows, so a wobbly start can never starve the rest of the
            // swipe (the old one-time lock froze the ring until the fingers
            // rested 300 ms).
            if (root.accX >= root.accY * 1.25 && root.accX >= 12)
                root.gestureAxis = 1;
            else if (root.accY >= root.accX * 1.25 && root.accY >= 12)
                root.gestureAxis = 2;
            carouselGestureEnd.restart();
            // Horizontal wins once the axis is decided; before it is decided
            // nothing moves, so a vertical scroll never nudges the ring by
            // accident. Returns false for a decided VERTICAL gesture so the
            // host can still scroll the page it lives on.
            if (root.gestureAxis !== 1)
                return false;
            // While the ring is under the fingers it obeys them: any rolling
            // spin stops. A 3-finger drag session is LIVE right now -- ignore
            // touchpad echoes of the same physical swipe, or one gesture
            // would scroll the ring twice.
            if (root.drag3fLive) {
                root.lastWheelTime = now;
                return true;
            }
            root.spinning = false;
            // DIRECT TRACKING, browser model: the ring follows the finger
            // immediately (scaled by sensitivity) -- zero dead zone, zero
            // perceived latency. The SNAP lives in the rest points, not in
            // the motion: the ticker eases the target to the nearest card
            // whenever the fingers pause mid-gesture, and lift-off rounds
            // (after handing any flick to momentum), so the gallery always
            // comes to rest centred on a wallpaper while FEELING 1:1.
            const dt = now - root.lastWheelTime;
            if (dt > 0 && dt < 120) {
                const inst = (-dx * root.swipeSensitivity / root.pxPerCard) / (dt / 1000);
                root.flingVel = root.flingVel * 0.65 + inst * 0.35;
            }
            root.posVel = 0; // fingers down => the ring obeys, no coast
            root.springVel = 0; // same reason as feedDrag: `pos` is written
                                 // directly below, so the spring must not hold
                                 // momentum that would fight the finger
            root.posTarget += -dx * root.swipeSensitivity / root.pxPerCard;
            root.pos = root.posTarget; // the spring only eases RELEASES, never the finger: true 1:1
            root.emitSteps();
            root.lastWheelTime = now;
        } else {
            const uni = (ax !== 0) ? ax : -ay;
            if (uni === 0) return false;
            root.posTarget -= uni / 120; // one detent = one card
            root.posVel = 0; // a deliberate wheel click stops any coast
            root.lastWheelTime = now;
            root.emitSteps();
        }
        return true;
    }

    // Is this event a touchpad's? The device is authoritative when the stack
    // reports it; the pixel-delta heuristic is the fallback, because on this Qt
    // version pixel deltas only ever come from a touchpad. Without this a
    // touchpad that reports ONLY notch deltas fell into the mouse-wheel branch
    // and turned exactly one card per notch -- indistinguishable from "the
    // swipe does nothing" once the clamp in emitSteps was eating it.
    function eventIsTouchpad(event) {
        const pd = event.pixelDelta;
        const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
        const deviceType = event.device?.type;
        if (deviceType !== undefined)
            return deviceType === PointerDevice.TouchPad;
        return !!hasPixels;
    }

    // Wheel/scroll input: MouseArea.onWheel, NOT WheelHandler. This Qt build
    // never delivers wheel events to WheelHandler on layer surfaces (proven
    // with an on-screen probe: MouseArea.onWheel flashes, WheelHandler never
    // does). Declared BEFORE the strip, so the card areas above keep their
    // clicks/hovers while a wheel anywhere in the component turns the ring.
    MouseArea {
        anchors.fill: parent
        onWheel: event => {
            const pd = event.pixelDelta;
            // Accept only what we actually own. A decided VERTICAL gesture is
            // left unaccepted so it bubbles to whatever panel hosts this
            // carousel (the settings page's scroll view) instead of dying here.
            event.accepted = root.feedWheel(event.angleDelta.x, event.angleDelta.y,
                pd ? pd.x : 0, pd ? pd.y : 0, root.eventIsTouchpad(event));
        }
    }

    // ── The strip ────────────────────────────────────────────────────────────
    Item {
        id: strip
        anchors.left: parent.left
        anchors.top: parent.top
        width: root.stripHalf * 2
        height: root.cardBand + root.reflectGap + root.reflectH

        // Soft bloom behind the centre card: the reference reads as light
        // spilling out from the focused wallpaper.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: (root.cardBand - root.centerH * 0.72) / 2
            width: root.centerW * 0.86
            height: root.centerH * 0.72
            radius: height / 2
            color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.86)
            opacity: 0.75
        }

        Repeater {
            model: root.items
            delegate: Item {
                id: cardItem
                required property int index
                required property var modelData

                // CONTINUOUS position: the card's offset from the ring's
                // centre, in fractional card units. Between steps every card
                // glides -- geometry is a pure function of d, so the whole
                // coverflow animates as one fluid body under the spring.
                readonly property real d: cardItem.index - root.pos
                // Circular re-normalisation: wrap d into (-count/2, count/2]
                // each frame so the ring has no seam and glides the short way.
                readonly property real dNorm: {
                    if (root.count === 0) return 0;
                    let v = cardItem.d;
                    while (v > root.count / 2) v -= root.count;
                    while (v <= -root.count / 2) v += root.count;
                    return v;
                }
                readonly property int di: Math.round(cardItem.dNorm)
                readonly property int dist: Math.abs(cardItem.di)
                readonly property bool inRange: root.count > 0 && cardItem.dist <= root.sides
                readonly property bool isCentre: cardItem.di === 0
                readonly property real ad: Math.abs(cardItem.dNorm)
                readonly property real cardW: root.cardWidthForCont(cardItem.ad)
                readonly property real cardH: root.cardHeightForCont(cardItem.ad)
                readonly property bool showMirror: root.showReflections && cardItem.inRange && cardItem.dist <= 2

                // CONTINUOUS geometry: x follows the spring's live fractional
                // position (interpolated slot metrics), so the glide between
                // cards is the spring itself -- one fluid motion with nothing
                // restarting. Width still flips at slot crossings (integer
                // metrics), eased by its Behavior; opacity/scale likewise.
                x: strip.width / 2 + root.offsetForCont(cardItem.dNorm) - cardItem.cardW / 2
                width: cardItem.cardW
                height: strip.height
                visible: cardItem.inRange
                // Opacity from the FRACTIONAL distance, the same way width
                // is: the old stepped value plus a 190ms Behavior meant every
                // card ran its own animation alongside the spring, all seven
                // of them restarting as the ring crossed slot boundaries.
                opacity: cardItem.inRange ? root.opacityForCont(cardItem.ad) : 0
                z: 100 - cardItem.dist
                // Hover only. The ring moves, nothing is hovered, so this
                // animation is idle during a swipe instead of competing with
                // it.
                scale: cardArea.containsMouse && !cardItem.isCentre ? 1.06 : 1.0
                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                // ── The mirror ───────────────────────────────────────────
                // The card repeated under itself, flipped, cut to a short band
                // and faded out into the backdrop. This is the signature of the
                // reference: the strip reads as cards floating on a glossy
                // surface rather than pinned to a panel. Only the nearest two
                // steps each way get one -- beyond that they are under the
                // neighbouring cards anyway and would only cost fills.
                Item {
                    id: reflection
                    // Hidden until its own thumbnail has actually decoded:
                    // an unloaded image leaves the fade-out gradient standing
                    // alone as a dark rectangle -- the "black squares" under
                    // the strip.
                    visible: cardItem.showMirror && (reflThumb.status === Loader.Ready
                        || reflThumb.status === Loader.Error)
                    x: 0
                    y: root.cardBand + root.reflectGap
                    width: cardItem.cardW
                    height: root.reflectH
                    clip: true
                    opacity: cardItem.isCentre ? 0.42 : 0.22

                    // Same thumbnail source as the card itself: the base image
                    // is already decoded and cached, so the mirror costs one
                    // extra fill, not another decode.
                    //
                    // Behind a Loader, and that is the point. With reflections
                    // off (the default) reflectH is 0, so this Item has no
                    // height -- but the image inside it was still BUILT: one
                    // ThumbnailImage per history entry, each with its own file
                    // watcher, decode and texture, all decoded into a
                    // zero-height box nobody can see. With a long history that
                    // is a dozen invisible decodes on every open, competing
                    // with the seven visible cards for the same frame budget.
                    Loader {
                        id: reflThumb
                        width: reflection.width
                        height: cardItem.cardH
                        y: 0
                        active: reflection.visible
                        sourceComponent: Component {
                            ThumbnailImage {
                                sourcePath: String(cardItem.modelData ?? "")
                                fillMode: Image.PreserveAspectCrop
                                generateThumbnail: false
                                transform: Scale {
                                    origin.x: width / 2
                                    origin.y: height / 2
                                    yScale: -1
                                }
                            }
                        }
                    }

                    // Fade to the backdrop so the mirror has no bottom edge.
                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            GradientStop {
                                position: 0.0
                                color: CF.ColorUtils.transparentize(root.backdrop, 0.55)
                            }
                            GradientStop {
                                position: 1.0
                                color: root.backdrop
                            }
                        }
                    }
                }

                // ── Click/hover target: ONLY the picture itself ────────
                // A dedicated hit area exactly the size of the preview, not
                // the delegate: the delegate spans the whole strip height
                // (the mirror band hangs below the card), and handlers on
                // the delegate root made the empty band under each wallpaper
                // hoverable and clickable too. A MouseArea (not a TapHandler)
                // because gesture handlers on OVERLAPPING items all fire --
                // the edge arrows overlap the outer slivers, and one click
                // there would both step AND apply. MouseArea is z-exclusive:
                // the topmost handler wins.
                Item {
                    x: 0
                    y: (root.cardBand - cardItem.cardH) / 2
                    width: cardItem.cardW
                    height: cardItem.cardH
                    MouseArea {
                        id: cardArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activateIndex(cardItem.index)
                    }
                }

                // The picture. Square corners now (see the note below); the
                // rounded rim rectangle after it carries the card's shape.
                Loader {
                    id: picLoader
                    y: (root.cardBand - cardItem.cardH) / 2
                    width: cardItem.cardW
                    height: cardItem.cardH
                    active: root.count > 0 && cardItem.dist <= root.loadSides
                    // The rounded corners are an OpacityMask, and a mask can
                    // ONLY be done with a layer -- so this used to allocate an
                    // offscreen render target for EVERY live card. With
                    // `sides: 3` that is seven simultaneous FBOs, and
                    // `Behavior on width` below re-aims the width on every
                    // frame the spring is moving, so all seven masked layers
                    // were re-rendered on every frame of every swipe. That is
                    // the carousel lag: it is not the images (they are cached
                    // and magick is fast), it is seven masked layers fighting
                    // the compositor for the same GPU.
                    //
                    // Only the CENTRE card actually needs the mask. It is the
                    // only one with a visible corner radius (the slivers use
                    // `Appearance.rounding.small` at a fraction of the width,
                    // where the rounding is a couple of pixels against a dark
                    // backdrop), and it is the only one that changes shape
                    // dramatically as the ring turns. The slivers keep their
                    // Rim rectangle below either way, so they still read as
                    // cards -- they just have square corners.
                    // NO MASK, deliberately. A rounded-corner mask is an
                    // OpacityMask, and a mask requires a layer: this used to
                    // allocate an offscreen render target for the focused
                    // card and re-render it every single frame of the motion,
                    // because the card's geometry changes every frame. That
                    // one FBO cost more than the whole rest of the strip. The
                    // rim rectangle below still draws the rounded outline, so
                    // the card keeps its shape and its edge; only the corner
                    // pixels of the picture are square, which at this radius is
                    // not worth a per-frame render target.
                    sourceComponent: Component {
                        ThumbnailImage {
                            sourcePath: String(cardItem.modelData ?? "")
                            fillMode: Image.PreserveAspectCrop
                            generateThumbnail: true
                        }
                    }
                }

                // Rim. The centre card gets the light edge the reference has;
                // the slivers settle for a hairline.
                Rectangle {
                    y: (root.cardBand - cardItem.cardH) / 2
                    width: cardItem.cardW
                    height: cardItem.cardH
                    radius: cardItem.isCentre ? Appearance.rounding.normal + 6 : Appearance.rounding.small
                    color: "transparent"
                    border.width: cardItem.isCentre ? 2 : 1
                    border.color: cardItem.isCentre
                        ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.35)
                        : CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
                }

                // Drop a history entry. Never offered for the current
                // wallpaper, and never deletes the file itself.
                Rectangle {
                    visible: root.allowRemove && cardItem.isCentre
                        && String(cardItem.modelData) !== String(root.currentPath)
                    x: parent.width - width - 8
                    y: (root.cardBand - cardItem.cardH) / 2 + 8
                    width: 26; height: 26
                    radius: Appearance.rounding.full
                    color: removeM.containsMouse
                        ? Appearance.colors.colError
                        : CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.2)
                    opacity: removeM.containsMouse || cardArea.containsMouse ? 1 : 0.55
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    MouseArea {
                        id: removeM
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.removeRequested(String(cardItem.modelData))
                    }
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "close"
                        iconSize: 16
                        color: removeM.containsMouse ? Appearance.colors.colOnError : Appearance.colors.colOnLayer0
                    }
                }
            }
        }
    }

    // ── Carousel indication ──────────────────────────────────────────
    // A FIXED-width track with one gliding thumb -- not one dash per
    // wallpaper. A per-item pager grows without bound (with many wallpapers
    // the dash row ran far past the strip); this track is always the same
    // short length no matter how many wallpapers the ring holds, and the
    // thumb's position inside it shows where in the ring we are. The thumb
    // follows `pos` directly, so it glides with the same spring as the
    // cards -- no separate animation of its own.
    Item {
        id: scrubber
        visible: root.count > 1
        anchors.horizontalCenter: parent.horizontalCenter
        y: strip.height + root.addRowGap + root.addRowH + 12
        readonly property real trackW: 140
        width: trackW
        height: 12

        readonly property real thumbW: Math.max(20, Math.min(56,
            trackW / Math.max(2, root.count) * 2))
        // pos is unwrapped while moving; ring position is pos mod count.
        readonly property real ringPos: ((root.pos % root.count) + root.count) % root.count

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.horizontalCenter: parent.horizontalCenter
            width: scrubber.trackW
            height: 3
            radius: 1.5
            color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.55)
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: scrubber.thumbW
            height: 3
            radius: 1.5
            x: (scrubber.width - scrubber.thumbW)
                * (root.count > 1 ? scrubber.ringPos / (root.count - 1) : 0)
            color: Appearance.colors.colPrimary
        }
    }

    // ── Edge arrows: small, pressable, always visible ────────────────────
    // Flanking the strip at mid-card height. A press turns the ring one
    // card with the same snappy spring a swipe settle uses; holding does
    // nothing special -- this is a deliberate tap control, matching the
    // touch-first design.
    Rectangle {
        id: arrowLeft
        visible: root.count > 1
        x: strip.x + 2
        z: 20
        y: strip.y + (root.cardBand - height) / 2
        width: 34
        height: 34
        radius: Appearance.rounding.full
        color: arrowLeftM.containsMouse
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.72)
            : CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.14)
        border.width: 1
        border.color: arrowLeftM.containsMouse
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.35)
            : CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.55)
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
        scale: arrowLeftM.pressed ? 0.9 : (arrowLeftM.containsMouse ? 1.08 : 1.0)
        Behavior on scale {
            NumberAnimation { duration: 160; easing.type: Easing.OutBack }
        }
        MaterialSymbol {
            anchors.centerIn: parent
            text: "chevron_left"
            iconSize: 20
            color: arrowLeftM.containsMouse ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
        }
        MouseArea {
            id: arrowLeftM
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.nudge(-1)
        }
    }

    Rectangle {
        id: arrowRight
        visible: root.count > 1
        x: strip.x + strip.width - width - 2
        z: 20
        y: strip.y + (root.cardBand - height) / 2
        width: 34
        height: 34
        radius: Appearance.rounding.full
        color: arrowRightM.containsMouse
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.72)
            : CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.14)
        border.width: 1
        border.color: arrowRightM.containsMouse
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.35)
            : CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.55)
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
        scale: arrowRightM.pressed ? 0.9 : (arrowRightM.containsMouse ? 1.08 : 1.0)
        Behavior on scale {
            NumberAnimation { duration: 160; easing.type: Easing.OutBack }
        }
        MaterialSymbol {
            anchors.centerIn: parent
            text: "chevron_right"
            iconSize: 20
            color: arrowRightM.containsMouse ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
        }
        MouseArea {
            id: arrowRightM
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.nudge(1)
        }
    }

    // ── The "add wallpaper" row, UNDER the strip ─────────────────────────
    // A quiet accent pill centred beneath the reflections: it is an action,
    // not a wallpaper, so it does not sit in the card flow -- but it keeps the
    // cards' rim language (accent hairline, accent glyph) so it reads as part
    // of the same design. Opens the image picker.
    Rectangle {
        id: addBtn
        visible: root.showAdd
        anchors.horizontalCenter: parent.horizontalCenter
        y: strip.height + root.addRowGap
        width: addRow.implicitWidth + 28
        height: root.addRowH
        radius: height / 2
        // Hover attributes: the pill lifts slightly, its rim sharpens and the
        // fill warms -- the three together make it read as a button, not a
        // label.
        scale: addHover.hovered ? 1.05 : 1.0
        Behavior on scale {
            NumberAnimation { duration: 160; easing.type: Easing.OutBack }
        }
        color: addHover.hovered
            ? CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.70)
            : CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.86)
        border.width: addHover.hovered ? 1.6 : 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, addHover.hovered ? 0.35 : 0.6)
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
        Behavior on border.width { NumberAnimation { duration: 140 } }

        Row {
            id: addRow
            anchors.centerIn: parent
            spacing: 7
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: "add"
                iconSize: root.stage ? 21 : 19
                color: Appearance.colors.colPrimary
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: Translation.tr("Add wallpaper")
                color: Appearance.colors.colPrimary
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.Medium
            }
        }

        HoverHandler {
            id: addHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: root.addRequested()
        }
    }
}
