.pragma library

// ══ Touchpad fling physics, shared by every scrolling surface ═══════════
//
// Why this file exists instead of a Flickable property tweak: Qt's Flickable
// has NO momentum for wheel events. A touchpad scroll arrives as a stream of
// wheel events, and Flickable treats each one as a discrete position change,
// so the content stops dead the instant the last event of a gesture arrives.
// A mouse gets a Flickable flick (there is a press involved); a touchpad does
// not, because its "flick" is really "the last 80ms of finger velocity,
// continued" -- and nothing in Qt models that.
//
// That missing continuation is the whole complaint. A real browser (Brave /
// Chromium) tracks finger velocity and, on lift-off, keeps coasting with a
// decaying velocity until it either reaches the end of the content or decays
// below a threshold. That coast IS the "natural" feel; a scroll that stops the
// instant you lift your fingers reads as dead, unsmoothed, and cheap
// regardless of how correct the 1:1 tracking is.
//
// So: this models the fling explicitly. It is deliberately a plain-JS module
// (not a QML item) so BOTH StyledFlickable and StyledListView can share ONE
// implementation instead of the physics drifting apart between them -- which
// is exactly how the two came to disagree before.
//
// The model, and why each constant is what it is:
//
//   velocity         px/s, from an exponentially-weighted mean of recent
//                    per-event deltas. Weighting (not a plain last-delta)
//                    matters because libinput frame times jitter; a single
//                    frame can be 8ms or 20ms and a raw delta/dt from one
//                    frame is mostly noise.
//   FLING_START_MS   the gap of silence after which we believe the fingers
//                    are off. libinput keeps emitting a frame or two of
//                    near-zero delta during lift-off; starting the coast
//                    immediately would double-count that and fling too hard.
//   FRICTION         velocity retained per second. This sets the SHAPE of the
//                    coast, and it is the number that decides whether the
//                    scroll reads as "gliding to a stop" or "drifting". At
//                    0.06 the time constant is ~355ms and a hard flick glided
//                    for nearly TWO seconds, which feels like ice. 0.0025
//                    gives a ~167ms constant, which turned out to be the
//                    other failure: the motion is correct but it is over
//                    almost before it registers, so a flick reads as a nudge
//                    that stops. 0.0012 (~275ms) is the measured middle --
//                    long enough that the list visibly carries on, short
//                    enough that it is still settling rather than sliding.
//   MIN_VELOCITY     px/s below which we stop. Without it the decay is
//                    asymptotic and the last few pixels crawl for a long,
//                    visible tail.
//   MAX_FLING_MS     hard cap on one coast. The exponential alone is
//                    asymptotic, so a very hard flick would still be moving
//                    visibly long afterwards; a browser's never is. This is
//                    the difference between "thrown" and "on a wheel". Raised
//                    alongside FRICTION, because a longer glide needs a cap
//                    long enough not to truncate it mid-curve.
//   MAX_VELOCITY     clamp so one pathological frame (a fling after a stutter
//                    or a resumed trackpad) cannot launch the content across
//                    the whole page.
//   MIN_DISTANCE     a flick shorter than this is treated as a stop rather
//                    than a coast. Prevents a jittery final frame from
//                    triggering a visible 2px creep.
//
// Bounds are enforced by the CALLER (it owns contentY and knows its
// contentHeight), because a JS module cannot touch a QML property.

var FLING_START_MS = 70;
var FRICTION = 0.0012; // fraction of velocity surviving one second
var MIN_VELOCITY = 40.0; // px/s
var MAX_FLING_MS = 1100.0; // hard cap on one coast
var MAX_VELOCITY = 6000.0; // px/s
// How far a gesture must travel before it counts as a flick worth coasting.
//
// This was 6, chosen to stop a jittery final frame from triggering a visible
// 2px creep. At 6 it also threw away every LIGHT flick: measured, a gesture of
// two 1px events moved the list and then stopped dead instead of coasting, and
// a single 1px event did nothing at all. On a touchpad that reports in small
// increments, 6px is a real movement, not a rounding error -- so the floor was
// rejecting deliberate input, which is far more noticeable than the 1-2px
// creep it was meant to prevent. 1.5 keeps the original intent (a genuinely
// motionless frame is not a flick) without rejecting a small one.
var MIN_DISTANCE = 1.5; // px
var SAMPLE_WINDOW_MS = 90.0; // how far back the velocity average looks

// ══ THE SHELL-WIDE SCROLL RULE ═════════════════════════════════════════
//
// One gain, one momentum model, one door into them. Everything that scrolls
// in this shell obeys all three, and the constants below are where you change
// it -- permanently, for every surface, instead of once per component.
//
//   1. GAIN. A touchpad reports small increments (7-10px per event on this
//      machine), and a terminal multiplies them by roughly three before the
//      list moves. TOUCHPAD_GAIN is that multiplier. It scales the DELTA, not
//      the resulting position, so tracking stays proportional to the finger --
//      just at the speed a browser actually scrolls at. It is deliberately NOT
//      fixed in the compositor's scroll_factor: that would make every other
//      application overshoot, and Chromium (which re-amplifies internally)
//      would not even notice the change.
//
//      This number used to live in two places at two values -- 3.2 in
//      StyledListView, 2.0 in StyledFlickable -- so the shell had a "fast"
//      scroll and a "slow" scroll and the difference read as feel rather than
//      as a bug. One number now.
//
//   2. MOMENTUM. `create()` below, on every surface. Qt has no momentum for
//      wheel events, so without it a touchpad scroll is a dead stop at
//      lift-off no matter how good the tracking is.
//
//   3. ONE DOOR. A surface must never write `contentY` from a wheel delta
//      itself. It hands the event to the scroller underneath, which owns the
//      gain, the fling and the bounds. `route()` below is that handoff, and it
//      is the only way a surface is allowed to move a list -- an overlay that
//      writes `contentY` by hand loses the gain (so the list crawls) and the
//      coast (so it stops dead), which is precisely the "slow and not natural"
//      report, and it does it on the one surface nobody tested.
var TOUCHPAD_GAIN = 3.2;

// Is this thing a scroller that could actually scroll right now? Visibility
// is checked as `=== false` rather than truthy so a scroller inside a Loader
// that has not resolved is still eligible, rather than being skipped forever.
function isScrollable(s) {
    if (!s) return false;
    if (s.visible === false) return false;
    if (s.contentHeight === undefined || s.height === undefined) return false;
    return s.contentHeight > s.height;
}

// First scrollable of `list` that can move. The list is in visual order, so
// the caller controls which one wins (the music tracklist before the category
// pane, and so on).
function pickScrollable(list) {
    if (!list) return null;
    for (let i = 0; i < list.length; i++) {
        if (isScrollable(list[i])) return list[i];
    }
    return null;
}

// Hand a wheel event to the scroller that owns it. Returns true if it took
// it, false if the caller must deal with the event itself (no scroller under
// the pointer, or a plain ListView with no handler -- better to do something
// approximate than to swallow the gesture).
function route(wheel, scroller) {
    if (!scroller) return false;
    if (typeof scroller.handleWheel === "function") {
        scroller.handleWheel(wheel);
        return true;
    }
    return false;
}

// Create a fling driver bound to a caller-supplied state object.
//
// `state` is a plain object the caller owns and persists across gestures:
//   { velocity, lastEventMs, distance, samples: [{t, d}] }
//
// The driver is a factory rather than a QML object on purpose: these are
// per-surface values (two lists can be scrolled at once in different
// windows), and a shared singleton would make them fight.
function create(state) {
    if (!state) {
        state = { velocity: 0, lastEventMs: 0, distance: 0, samples: [] };
    }
    if (!state.samples)
        state.samples = [];
    if (state.flingStartMs === undefined)
        state.flingStartMs = 0;

    function reset() {
        state.velocity = 0;
        state.lastEventMs = 0;
        state.flingStartMs = 0;
        state.distance = 0;
        state.samples = [];
    }

    // Feed one touchpad wheel event. Returns the delta the caller should
    // apply right now (which is the raw event, so tracking stays 1:1 while
    // the fingers are down -- the fling only starts AFTER they lift).
    function feed(dy, nowMs) {
        const s = state.samples;
        s.push({ t: nowMs, d: dy });

        // Drop samples older than the averaging window, so the velocity
        // reflects how the gesture is ENDING, not how it began. This is
        // what makes a "flick and stop" produce almost no coast while a
        // "flick and keep going" produces a long one.
        while (s.length > 2 && nowMs - s[0].t > SAMPLE_WINDOW_MS)
            s.shift();

        // Exponentially weighted mean of dy/dt. Newer frames dominate, which
        // is what "the hand was moving fastest just before lift-off" means
        // physically.
        let v = 0;
        let w = 0;
        let weight = 1;
        for (let i = s.length - 1; i >= 0; i--) {
            const dt = (i === s.length - 1 ? nowMs - s[i].t : s[i + 1].t - s[i].t);
            if (dt <= 0)
                continue;
            v += (s[i].d / dt) * 1000.0 * weight;
            w += weight;
            weight *= 0.55; // older frames decay fast
        }
        state.velocity = w > 0 ? v / w : 0;

        if (state.velocity > MAX_VELOCITY)
            state.velocity = MAX_VELOCITY;
        else if (state.velocity < -MAX_VELOCITY)
            state.velocity = -MAX_VELOCITY;

        state.lastEventMs = nowMs;
        state.distance += Math.abs(dy);
        return dy;
    }

    // Has the gesture gone quiet long enough to start coasting?
    function shouldFling(nowMs) {
        if (state.lastEventMs === 0)
            return false;
        if (nowMs - state.lastEventMs < FLING_START_MS)
            return false;
        if (state.distance < MIN_DISTANCE)
            return false; // a tap, not a flick
        if (Math.abs(state.velocity) < MIN_VELOCITY)
            return false;
        // Stamp the coast's start the FIRST time this passes, so MAX_FLING_MS
        // is measured from the lift-off rather than from whenever the caller
        // happened to ask. Asking again mid-coast must not extend it.
        if (state.flingStartMs === 0)
            state.flingStartMs = nowMs;
        return true;
    }

    // Advance the coast by dtMs. Returns { delta, stop }.
    function step(nowMs, dtMs) {
        if (state.lastEventMs === 0 || nowMs - state.lastEventMs < FLING_START_MS)
            return { delta: 0, stop: false };

        // The hard cap. Checked before the decay maths so the last frame
        // cannot overshoot past it.
        if (nowMs - state.flingStartMs >= MAX_FLING_MS) {
            state.velocity = 0;
            return { delta: 0, stop: true };
        }

        // Exponential decay: v(t) = v0 * FRICTION^(t/1000). FRICTION is the
        // fraction surviving one second, so this is a straight lerp in log
        // space -- the reason the coast feels like a smooth hand-off rather
        // than a curve that visibly bends.
        const secs = dtMs / 1000.0;
        const decay = Math.pow(FRICTION, secs);
        // `let`, not `const`: the sub-threshold branch below adds the tail to
        // it. With const that assignment throws, and it throws on the LAST
        // frame of every coast -- i.e. exactly as the scroll is settling, so
        // the tail either never renders or kills the surface.
        let step_px = state.velocity * secs;
        state.velocity *= decay;

        let stop = false;
        if (Math.abs(state.velocity) < MIN_VELOCITY) {
            // Snap the remainder to zero rather than crawling the last
            // fraction of a pixel for another second.
            step_px += state.velocity * 0.15;
            state.velocity = 0;
            stop = true;
        }
        return { delta: step_px, stop: stop };
    }

    return {
        state: state,
        reset: reset,
        feed: feed,
        shouldFling: shouldFling,
        step: step,
    };
}
