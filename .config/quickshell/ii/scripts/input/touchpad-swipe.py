#!/usr/bin/env python3
"""Live four-finger swipe tracking, straight off the touchpad.

Why this exists
---------------
Hyprland's own gesture binding fires once, when the swipe is *over*, and it
carries no distance -- only a direction. A layer surface (the settings and
task-manager popups) can therefore never follow the fingers: the app only
learns "the swipe happened" after the fingers have already left the pad.

Reading the touchpad directly is the way out. The session user is in the
`input` group, and reading an evdev node does NOT grab it -- Hyprland keeps
receiving every event, so the normal gesture handling is untouched. We just
watch the same stream and report it.

Output: one JSON object per line on stdout, flushed immediately.

    {"phase": "begin",  "fingers": 4, "dy": 0.0,  "total": 0.0,  "dx": 0.0,  "htotal": 0.0}
    {"phase": "update", "fingers": 4, "dy": 0.12, "total": 0.12, "dx": 0.0,  "htotal": 0.0}
    {"phase": "end",    "fingers": 0, "dy": 0.0,  "total": 0.31, "dx": 0.0,  "htotal": 0.0}

`dy`/`total` are in fractions of the pad's height, `dx`/`htotal` in fractions
of the pad's width (so a full sweep is 1.0 on either axis), not device units:
the pad's resolution is not the screen's, and the consumer scales them to
whatever it is moving. Positive dy is downward; positive dx is rightward.
`htotal` is the horizontal travel of the whole gesture -- the shell reads it
on `end` to know a four-finger horizontal swipe happened (and which way),
which is how the desktop-edge shake learns a swipe tried to leave the last
desktop. The vertical pair keeps its original meaning; the extra keys are
additive and older consumers ignore them.

Nothing here is Hyprland-specific; it would work under any compositor.
"""

import argparse
import fcntl
import glob
import json
import math
import os
import select
import struct
import sys
import time

# evdev constants (linux/input-event-codes.h)
EV_SYN = 0x00
EV_ABS = 0x03
SYN_REPORT = 0x00
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39

# struct input_event { struct timeval time; __u16 type; __u16 code; __s32 value; }
# 64-bit: two 8-byte longs, then 2+2+4 -> 24 bytes.
EVENT = struct.Struct("llHHi")
EVENT_SIZE = EVENT.size

# Tap thresholds, shared by the shell (TouchpadSwipe.qml documents the same
# numbers). A TAP has three parts, all of them required: a rest shorter than
# 350ms, movement under 4% of the pad's travel (in BOTH axes), and contacts
# that LANDED TOGETHER (TAP_COINCIDENCE_MS below -- a finger that was already
# resting on the pad is not part of the tap made beside it). The shell reads
# HOW MANY fingers made the tap and acts accordingly:
#
#   3 fingers -> play/pause of the active MPRIS player, falling back to
#                the wallpaper carousel when no player exists
#   4 fingers -> the desktops overview
#
# The both-axes part is not pedantry. Travel used to be measured on Y alone,
# and a fast horizontal swipe barely drifts vertically: under 350ms with Y
# movement well inside the tap window, so a quick four-finger flick sideways
# was classified as a TAP -- firing the action in the middle of the
# workspace swipe and making the horizontal desktop switch feel possessed.
TAP_MAX_MS = 350.0
TAP_MAX_TRAVEL = 0.04
# How far apart the contacts of a tap may have LANDED and still be one tap.
#
# A tap is a hand gesture, so its fingers arrive together -- within a few
# dozen milliseconds of each other on a real pad. A finger that is ALREADY ON
# THE PAD is a different animal: it has been there for however long the user
# has been resting it, and it is not part of any tap they then make with the
# others.
#
# Without this gate the resting finger was counted anyway, because it is a
# contact like any other and the tracker reads COUNTS. Reproduced on this
# machine: rest one finger down (count 1 -- below the tracked set, so nothing
# is tracked), then tap twice with two more fingers. The count goes 1 -> 3 -> 1,
# `begin()` fires on the 3, `end()` sees a gesture that was short and still, and
# `peak` routes it as a THREE-finger tap: the music paused, and tapping again
# resumed it. Same with three tapping fingers and one resting: a four-finger
# tap opened the desktops overview. Neither was a tap anybody made.
#
# The window is deliberately generous, and it has to be: rejecting a real tap
# is a worse bug than counting an accidental one, because the user's only
# evidence would be a gesture that does nothing. Measured on this machine with
# scripts/input/touchpad-tap-test.py: a deliberate 3- or 4-finger tap lands its
# fingers within 10-40ms of each other, and a slow, sloppy one can roll them out
# to ~180ms -- and that sloppy one still has to fire, so the window cannot sit
# near the fast end. The other side of the comparison is not close: a finger
# being RESTED on the pad has been there for hundreds of milliseconds to
# seconds before the others tap. 200ms is comfortably above a deliberate
# roll and far below "it was already there".
#
# The gesture's own duration gate still bounds everything: a tap must finish
# within TAP_MAX_MS of it starting, so a long landing spread leaves less time
# for the tap itself rather than opening the door to slow gestures.
TAP_COINCIDENCE_MS = 200.0
# How long after an `end` a returning contact count continues the same
# gesture (accumulators kept, no total reset). A count DIP is not a release:
# the dip-and-return was resetting the travel accumulator mid-swipe, which
# the shell's absolute-control swipe read as a violent jump. 150ms covers a
# micro-lift with a wide margin; a real release-then-swipe is slower.
REJOIN_GRACE_S = 0.15

# The keepalive, in seconds, ON A CLOCK. It used to be written only when the
# poll timed out -- "two seconds with no events" -- and that is wrong on a real
# pad: a hand resting on it (or a finger left beside the keyboard) keeps
# SYN_REPORT frames arriving forever, so the poll never times out and a
# perfectly healthy reader writes NOTHING for as long as the hand rests there.
#
# The shell judges liveness by this heartbeat, so silence was read as death and
# the reader was killed and restarted roughly every 30 seconds (25 times in one
# session's log, each exit code 15 = the shell's own SIGTERM). Every restart
# zeroes the gesture accumulator mid-gesture, which the shell's absolute
# brightness/volume swipe reads as one enormous swipe: the "random jump to
# 100%" it was reported as. The beat is therefore due on the CLOCK, whatever
# the pad is doing.
HEARTBEAT_S = 2.0

# ABS_X/ABS_Y capabilities, used to tell a touchpad from a plain mouse.
CAP_MT_SLOT = 1 << ABS_MT_SLOT
CAP_MT_TRACKING_ID = 1 << ABS_MT_TRACKING_ID


def device_name(event_path):
    try:
        with open(f"/sys/class/input/{os.path.basename(event_path)}/device/name") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def device_caps(event_path):
    try:
        with open(f"/sys/class/input/{os.path.basename(event_path)}/device/capabilities/abs") as fh:
            return int(fh.read().strip(), 16)
    except (OSError, ValueError):
        return 0


def abs_range(fd, code):
    """min/max for one absolute axis, via EVIOCGABS.

    struct input_absinfo is { value, minimum, maximum, fuzz, flat, resolution };
    only the range matters here -- it is what turns device units into "how much
    of the pad did the finger travel".
    """
    buf = fcntl.ioctl(fd, 0x80184540 | code, b"\0" * 24)
    _value, minimum, maximum = struct.unpack("3i", buf[:12])
    return minimum, maximum


def find_touchpad(explicit=None):
    """Prefer a device named like a touchpad; fall back to MT-protocol-B caps.

    An explicit device (--device, or QS_TOUCHPAD_DEVICE) wins: that is how a
    second touchpad, an unusual one, or a test device gets picked.
    """
    candidates = sorted(glob.glob("/dev/input/event*"))
    explicit = explicit or os.environ.get("QS_TOUCHPAD_DEVICE")
    if explicit:
        return explicit
    named = [p for p in candidates if "touchpad" in device_name(p).lower()]
    for path in named:
        return path
    for path in candidates:
        caps = device_caps(path)
        if caps & CAP_MT_SLOT and caps & CAP_MT_TRACKING_ID:
            return path
    return None


class Trackpad:
    """Tracks MT-protocol-B slots and reports multi-finger travel."""

    def __init__(self, path, fingers):
        self.path = path
        # `--fingers` takes a SET ("4", or "2,3,4"). It used to be a single
        # number, and one number cannot express "track the 4-finger gestures
        # AND the 2-finger ones on the bar": at 4, a two-finger contact was
        # simply below the threshold and never reported.
        #
        # Membership in this set is not a hint, it is the whole gate: a count
        # that is not in it ends the session in `report()` before a gesture
        # can begin. So a count left out of the set is a gesture that cannot
        # happen at all, however the shell routes it. 3 is tracked because the
        # shell sends a three-finger TAP to play/pause; 5 still cancels as a
        # palm, which is the max_fingers check above.
        self.finger_set = set(fingers) if isinstance(fingers, (set, list, tuple)) else {int(fingers)}
        self.min_fingers = min(self.finger_set)
        self.max_fingers = max(self.finger_set)
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        ymin, ymax = abs_range(self.fd, ABS_MT_POSITION_Y)
        self.y_min = float(ymin)
        # The pad's own travel, so 1.0 means "swiped the whole pad".
        self.y_span = float(ymax - ymin) or 1.0
        xmin, xmax = abs_range(self.fd, ABS_MT_POSITION_X)
        self.x_min = float(xmin)
        self.x_span = float(xmax - xmin) or 1.0

        self.slot = 0
        self.slots = {}           # slot -> tracking id (None = lifted)
        self.positions = {}       # slot -> y in device units
        self.xpos = {}            # slot -> x in device units
        self.tracking = False
        self.last_y = 0.0
        self.last_x = 0.0
        self.total = 0.0
        self.htotal = 0.0         # signed horizontal travel, pad widths
        # Tap detection, for the multi-finger TAP gestures. A tap is the
        # whole gesture staying put: under ~4% of the pad's travel from
        # where the fingers landed -- measured as true 2D path length, both
        # axes -- and over in under 350ms. end() compares against these; the
        # shell turns a qualifying end into the action.
        self.begin_mono = 0.0     # time.monotonic() at begin
        self.moved = 0.0          # total absolute travel while tracking
        # The finger count of the previous report, so a frame that changes the
        # count can be told apart from a frame the hand moved in. See the
        # re-baseline in `report()`.
        self.prev_count = 0
        # The re-join grace: how long after `end` a returning finger count
        # continues the SAME gesture instead of starting a new one. Long
        # enough to ride out a count dip (a finger micro-lift), short enough
        # that a deliberate release-then-swipe is genuinely two gestures.
        self.rejoin_deadline = 0.0
        # Fingers at the START of the gesture. The count the action cares
        # about: when one of four fingers lifts early the slots drop to 3,
        # but the gesture the user meant is still the 4-finger one. Emitted
        # with the tap so the shell can route by count.
        self.start_count = 0
        # The HIGHEST finger count seen during this gesture. This, not
        # `start_count`, is what a tap is routed by.
        #
        # `begin()` fires on the FIRST count that is in --fingers, and fingers
        # do not land in the same millisecond: a three-finger tap arrives as
        # 1, 2, 3, and the 2 qualifies first. So `start_count` froze at 2 for
        # a gesture made with three fingers, and the shell -- which routes a
        # tap by exactly this number -- matched no branch and did nothing.
        # The symptom was "three-finger tap stops the music, tapping again
        # does not resume it": whichever tap landed all its fingers in one
        # report worked, the other was dropped. The four-finger tap was
        # broken identically. It was never a playback bug.
        #
        # Why the peak, and not a "hand is still" window: fingers land spread
        # across the pad, and the tracker reads the MEAN position, so every
        # finger that lands away from the others shifts the mean by a real
        # distance. A first attempt that allowed a late finger to raise the
        # count only while travel stayed under 1% of the pad therefore never
        # fired on a real touchpad -- the landing itself is more movement
        # than that -- and the tap stayed broken while passing a test whose
        # fingers all sat on the same pixel. The peak needs no such test: a
        # tap is over in TAP_MAX_MS, so every count change inside one is the
        # hand landing, which is precisely what the peak is meant to record.
        #
        # Swipes still report `start_count`, untouched: a two-finger swipe
        # that brushes a third finger down mid-gesture is still the two-finger
        # gesture, and the bar's brightness/volume swipe must not see it as
        # anything else.
        self.peak_count = 0
        # How long the gesture that just ended lasted, and its travel. Read
        # by emit() so a rejected tap says which gate rejected it.
        self.last_duration_ms = 0.0
        # When each LIVE contact landed, and the ones already counted into the
        # gesture being tracked. Keyed by the TRACKING ID rather than the slot:
        # a slot is reused the moment a finger lifts, so two different contacts
        # can share one -- and a tap that lifts and re-lands on the same slot
        # would otherwise be dated with the wrong finger's time.
        self.landed_at = {}       # slot -> (tracking id, monotonic landing)
        self.tap_log = []         # landing times of the contacts in this gesture
        self.logged_tids = set()  # tracking ids already in tap_log
        # The gap between the first and last of those landings, in ms. Emitted
        # with the verdict for the same reason as dur_ms and moved: a rejected
        # tap has to say which gate rejected it.
        self.last_spread_ms = 0.0
        self.dead = False         # stdout pipe lost its reader (shell gone)

    # -- helpers ---------------------------------------------------------
    def active_slots(self):
        return [s for s, tid in self.slots.items() if tid is not None]

    def mean_y(self):
        ys = [self.positions[s] for s in self.active_slots() if s in self.positions]
        return sum(ys) / len(ys) if ys else None

    def mean_x(self):
        xs = [self.xpos[s] for s in self.active_slots() if s in self.xpos]
        return sum(xs) / len(xs) if xs else None

    def _write(self, line):
        # Every line this process writes goes through here (the heartbeat in
        # run() is the one exception). A write to a dead pipe must never
        # escape as an exception: writes also happen from cancel() inside
        # run()'s error path, and an unguarded raise there kills the clean
        # shutdown. Flag it instead; run() checks and exits.
        if self.dead:
            return
        try:
            sys.stdout.write(line)
            sys.stdout.flush()
        except BrokenPipeError:
            self.dead = True

    def emit(self, phase):
        if self.dead:
            return
        self._write(json.dumps({
            "phase": phase,
            "fingers": len(self.active_slots()),
            "start": self.start_count,
            "dy": 0.0,
            "total": round(self.total, 4),
            "dx": 0.0,
            "htotal": round(self.htotal, 4),
            "x": self.norm_x(),
            "y": self.norm_y(),
            # Why a gesture ended as "end" rather than "tap". The two tap
            # gates are a duration and a travel budget, and a gesture that
            # misses one is indistinguishable from a swipe from the shell's
            # side -- so the numbers go out with the event and a failing tap
            # can be read straight off the log instead of guessed at.
            "dur_ms": round(self.last_duration_ms, 1),
            "moved": round(self.moved, 4),
            # How far apart the contacts landed: the tap gate that is not about
            # time or travel, and the one a resting finger fails.
            "spread_ms": round(self.last_spread_ms, 1),
            "peak": self.peak_count,
        }) + "\n")

    # Where the fingers are ON THE PAD, 0..1, top-left origin.
    #
    # A touchpad is an absolute device, so this is the only way the shell can
    # know a gesture happened *over the bar* rather than anywhere on the
    # screen -- the difference between "two-finger swipe changes the backlight"
    # and "two-finger swipe anywhere changes the backlight", which is not a
    # gesture anybody wants. -1 when no slot has reported a position yet.
    def norm_x(self):
        mx = self.mean_x()
        if mx is None:
            return -1.0
        return round(max(0.0, min(1.0, (mx - self.x_min) / self.x_span)), 4)

    def norm_y(self):
        my = self.mean_y()
        if my is None:
            return -1.0
        return round(max(0.0, min(1.0, (my - self.y_min) / self.y_span)), 4)

    def log_tap_contacts(self):
        """Add every contact of the tracked gesture to the tap log, once.

        Called from begin() and from every frame of a tracked gesture, so a
        finger that arrives LATE is in the log too -- three fingers do not
        land in the same millisecond, and the count enters the tracked set as
        soon as the first two are down.

        A contact whose landing was never seen (the tracker started while it
        was already down) is dated from the gesture's own start, which makes
        it coincident by definition: the gate should only fire on evidence
        this process actually has.
        """
        for slot, tid in self.slots.items():
            if tid is None or tid in self.logged_tids:
                continue
            entry = self.landed_at.get(slot)
            landed = entry[1] if (entry and entry[0] == tid) else self.begin_mono
            self.logged_tids.add(tid)
            self.tap_log.append(landed)

    def tap_spread_ms(self):
        """How far apart this gesture's contacts landed, in milliseconds.

        0.0 when there is nothing to compare (fewer than two contacts, which
        cannot be a multi-finger tap anyway).
        """
        if len(self.tap_log) < 2:
            return 0.0
        return (max(self.tap_log) - min(self.tap_log)) * 1000.0

    def begin(self):
        self.tracking = True
        # RE-JOIN HAND-OFF. A two-finger gesture whose contact count dips to
        # one and returns -- a finger lifted a millimetre, or pressed ever so
        # slightly harder changing the reported count -- used to emit
        # end-then-begin with `total` reset to 0. The shell's swipe anchors
        # on that total, so a bar swipe mid-gesture suddenly saw travel of
        # "the whole gesture so far" and JUMPED the value, then drifted back
        # as the new accumulator caught up: the violent up-down glitch on
        # minimal movements. A dip within the grace window is a wobble, not
        # a new gesture: the accumulators and the anchor survive it.
        continued = (self.rejoin_deadline > 0.0
                     and time.monotonic() <= self.rejoin_deadline)
        if continued:
            # Keep the ACCUMULATORS (total/htotal/moved -- the shell's anchor
            # depends on them surviving); refresh the position baseline to
            # the CURRENT means, because the surviving finger may have moved
            # during the dip while nothing was tracked -- without this, all
            # that untracked motion would land as one large first dy.
            self.prev_count = len(self.active_slots())
            self.begin_mono = time.monotonic()
            self.start_count = len(self.active_slots())
            # A PEAK is a high-water mark, and this line used to LOWER it.
            # That is how a four-finger desktop swipe stopped the music: the
            # four fingers lifted in sequence, the count fell below the
            # tracked set, `end` fired (the swipe itself was long, so it was
            # correctly not a tap), and then the three survivors were still
            # down inside the re-join grace -- so `begin` ran the CONTINUED
            # branch and overwrote peak_count 4 with the current 3. Those
            # three then barely moved and lifted inside TAP_MAX_MS, which is a
            # tap, and `end` reports a tap by `peak_count` -- so the shell was
            # told "3-finger tap" and paused the music, a few hundred
            # milliseconds after a swipe that had already switched desktops.
            #
            # Nothing about a continuation can reduce how many fingers the
            # gesture actually used, so the peak only ever goes UP.
            self.peak_count = max(self.peak_count, self.start_count)
            self.rejoin_deadline = 0.0
            # The log survives a re-join like the other accumulators: it is
            # the same gesture, and a contact that arrived during the dip
            # belongs to it.
            self.log_tap_contacts()
            cur = self.mean_y()
            mx2 = self.mean_x()
            if cur is not None: self.last_y = cur
            if mx2 is not None: self.last_x = mx2
            self.emit("begin")
            return
        self.total = 0.0
        self.htotal = 0.0
        self.moved = 0.0
        self.prev_count = len(self.active_slots())
        self.begin_mono = time.monotonic()
        self.start_count = len(self.active_slots())
        self.peak_count = self.start_count
        # A fresh gesture starts a fresh tap log, SEEDED with every contact
        # already down -- including the ones that were resting here before
        # this gesture began, which is the whole point: their landing time is
        # what tells a real tap from tapping beside a resting finger.
        self.tap_log = []
        self.logged_tids = set()
        self.log_tap_contacts()
        current = self.mean_y()
        self.last_y = current if current is not None else 0.0
        mx = self.mean_x()
        self.last_x = mx if mx is not None else 0.0
        self.emit("begin")

    def end(self):
        """Fingers dropped below the threshold: the swipe is over -- unless
        the contacts come back within the re-join grace, which continues the
        same gesture (see begin)."""
        if not self.tracking:
            return
        self.tracking = False
        self.rejoin_deadline = time.monotonic() + REJOIN_GRACE_S
        duration_ms = (time.monotonic() - self.begin_mono) * 1000.0
        self.last_duration_ms = duration_ms
        spread_ms = self.tap_spread_ms()
        self.last_spread_ms = spread_ms
        # A tap is short, still, AND made of contacts that landed together:
        # under TAP_MAX_MS, having moved less than TAP_MAX_TRAVEL of the pad's
        # travel, by fingers that all arrived within TAP_COINCIDENCE_MS of one
        # another. The third gate is what keeps a finger RESTING on the pad out
        # of the count -- see TAP_COINCIDENCE_MS for the reproduction.
        is_tap = (duration_ms <= TAP_MAX_MS
                  and self.moved <= TAP_MAX_TRAVEL
                  and spread_ms <= TAP_COINCIDENCE_MS)
        # A tap is routed by how many fingers the user actually used, which
        # is the peak -- not the count that happened to land first.
        if is_tap:
            self.start_count = self.peak_count
        self.emit("tap" if is_tap else "end")

    def cancel(self):
        """The pad went away, or the count climbed into palm territory."""
        if not self.tracking:
            return
        self.tracking = False
        self.total = 0.0
        self.htotal = 0.0
        # No gesture to judge: the tap log goes with it, so a cancel cannot
        # leave landings behind for the next gesture to be measured against.
        self.tap_log = []
        self.logged_tids = set()
        self.emit("cancel")

    # -- the event loop --------------------------------------------------
    def handle(self, etype, code, value):
        if etype == EV_ABS:
            if code == ABS_MT_SLOT:
                self.slot = value
            elif code == ABS_MT_TRACKING_ID:
                if value >= 0:
                    self.slots[self.slot] = value
                    # When this contact arrived, so a tap can tell a hand
                    # landing together from a finger that was already resting
                    # there. See TAP_COINCIDENCE_MS.
                    self.landed_at[self.slot] = (value, time.monotonic())
                else:
                    self.slots[self.slot] = None
                    self.positions.pop(self.slot, None)
                    self.xpos.pop(self.slot, None)
            elif code == ABS_MT_POSITION_X:
                self.xpos[self.slot] = value
            elif code == ABS_MT_POSITION_Y:
                self.positions[self.slot] = value
            return

        if etype == EV_SYN and code == SYN_REPORT:
            self.report()

    def report(self):
        count = len(self.active_slots())
        if count > self.max_fingers:
            # A palm plus the fingers: not the gesture, and never will be.
            self.cancel()
            return
        if count not in self.finger_set:
            # Between the tracked counts (three fingers, or one): the contact
            # is not a gesture we run, and the session ends the way it always
            # did rather than being left half-tracked.
            self.end()
            return
        if not self.tracking:
            # Position is known only once the slot reported its coordinates.
            if self.mean_y() is None or self.mean_x() is None:
                return
            self.begin()
            return

        # Every frame of a tracked gesture, so a late arrival lands in the log
        # too (three fingers do not arrive in the same millisecond).
        self.log_tap_contacts()

        current = self.mean_y()
        mx = self.mean_x()
        if current is None or mx is None:
            return
        # A finger joining or leaving moves the MEAN even when the hand is
        # perfectly still, and on a real touchpad that shift is several times
        # larger than the entire tap travel budget: three fingers landing
        # across the pad move the mean by a good fraction of its width. So
        # `moved` used to be charged for the landing itself, real taps came
        # out over TAP_MAX_TRAVEL, and the gesture was emitted as a swipe --
        # no tap, no action, in EITHER direction. That is the "three-finger
        # tap does nothing at all" this replaces.
        #
        # Travel is therefore measured only between frames that share a
        # finger count, which is the only case where the mean's movement is
        # unambiguously the hand's. A count change re-baselines the anchor
        # and contributes nothing: how much of that shift was a finger
        # arriving and how much was the hand is not knowable here, and for
        # tap detection neither matters -- a tap is short and still, and a
        # swipe is long and travels on the frames that do share a count.
        if count != self.prev_count:
            self.prev_count = count
            self.last_y = current
            self.last_x = mx
            # A finger that arrives late still belongs to the gesture already
            # being tracked. See `peak_count` for why this is the peak and not
            # a "hand is still" window.
            if count > self.peak_count:
                self.peak_count = count
            return
        dy = (current - self.last_y) / self.y_span
        dx = (mx - self.last_x) / self.x_span
        self.last_y = current
        self.last_x = mx
        # Absolute travel, for tap detection: true 2D path length -- jitter
        # counts, direction does not. Y-only was the bug that read fast
        # horizontal swipes as taps.
        self.moved += math.hypot(dx, dy)
        # A finger that arrives late still belongs to the gesture already
        # being tracked. See `peak_count` for why this is the peak and not a
        # "hand is still" window.
        if count > self.peak_count:
            self.peak_count = count
        delta = dy
        hdelta = dx
        # Emit when EITHER axis carries real motion: a horizontal swipe with
        # a still hand has a near-zero dy, and the old dy-only gate would
        # have swallowed its updates entirely.
        if abs(delta) < 0.0005 and abs(hdelta) < 0.0005:
            return
        self.total += delta
        self.htotal += hdelta
        self._write(json.dumps({
            "phase": "update",
            "fingers": count,
            "dy": round(delta, 5),
            "total": round(self.total, 4),
            "dx": round(hdelta, 5),
            "htotal": round(self.htotal, 4),
            "x": self.norm_x(),
            "y": self.norm_y(),
        }) + "\n")

    def beat(self):
        """Write the keepalive once. False means the pipe is gone."""
        try:
            sys.stdout.write('{"hb":1}\n')
            sys.stdout.flush()
            return True
        except BrokenPipeError:
            # Shell is gone. Flag + exit on the next loop pass; the flag also
            # short-circuits every other write.
            self.dead = True
            return False

    def run(self):
        poller = select.poll()
        poller.register(self.fd, select.POLLIN)
        last_beat = time.monotonic()
        while True:
            if self.dead:
                return
            # Heartbeat, and why it matters: this process's stdout is a pipe
            # to the shell, and a broken pipe is only detected ON WRITE. With
            # events as the only writes, a tracker whose shell died lingers
            # silently until the NEXT gesture -- observed as an orphaned
            # reader outliving its shell across a restart. A periodic write
            # turns idle time into a liveness proof: if the shell is gone, the
            # heartbeat fails within seconds and the tracker (and its bash
            # supervisor) exits; the shell ignores the lines.
            #
            # The beat is due on the CLOCK, not on the poll timing out. See
            # HEARTBEAT_S: a resting hand keeps frames arriving, so an
            # idle-only beat starved exactly when the pad was in use but still,
            # and the shell killed the reader it was meant to protect.
            if poller.poll(HEARTBEAT_S):
                try:
                    data = os.read(self.fd, EVENT_SIZE * 64)
                except BlockingIOError:
                    data = b""
                except OSError:
                    self.cancel()
                    return
                for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _sec, _usec, etype, code, value = EVENT.unpack_from(data, offset)
                    self.handle(etype, code, value)
                if self.dead:
                    return
            now = time.monotonic()
            if now - last_beat >= HEARTBEAT_S:
                last_beat = now
                if not self.beat():
                    return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="evdev node, e.g. /dev/input/event5 (or QS_TOUCHPAD_DEVICE)")
    parser.add_argument("--fingers", default="4",
                        help="finger counts to track, comma separated (e.g. 2,4)")
    args = parser.parse_args()

    path = find_touchpad(args.device)
    if not path:
        sys.stderr.write("no multi-touch device found\n")
        return 2

    # Say which device was chosen, once, on stderr -- it shows up in the shell
    # log and makes "why is nothing tracking" answerable.
    sys.stderr.write(f"tracking {path} ({device_name(path) or 'unnamed'})\n")
    sys.stderr.flush()

    try:
        counts = {int(p) for p in str(args.fingers).split(",") if p.strip().isdigit()}
        if not counts:
            counts = {4}
        Trackpad(path, counts).run()
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        sys.stderr.write(f"{path}: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
