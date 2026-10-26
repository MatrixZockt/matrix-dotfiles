#!/usr/bin/env python3
"""Multi-finger TAP detection, checked against the real detector.

The question this answers: which touchpad contacts are allowed to make up a
tap. A tap is a HAND gesture -- its fingers arrive together. A finger that is
already resting on the pad is not part of the tap the user then makes with the
others, and until 2026-10-14 the tracker counted it anyway, because it counts
CONTACTS:

    rest one finger down (count 1 -- below the tracked set, so nothing is
    tracked), then tap twice with two more fingers. The count goes
    1 -> 3 -> 1, `begin()` fires on the 3, the gesture was short and still, and
    `peak` routed it to the shell as a THREE-finger tap: the music paused, and
    tapping again resumed it. One resting finger plus three tapping fingers
    opened the desktops overview the same way.

So the tap gate has three parts now -- short, still, and LANDED TOGETHER -- and
this file is the one that proves the third, in both directions: a resting
finger must not fake a tap, and a real tap (a sloppy one included) must still
be a tap.

HOW IT DRIVES THE CODE. This does NOT go through the kernel or the pad's own
event node: it imports the detector, builds a real Trackpad on the real device
(so the pad's own ranges and travel scale are used, not invented numbers), and
feeds it a synthetic MT-protocol-B event stream through exactly the handlers the
device reader calls -- handle() and report() via SYN_REPORT. Nothing here writes
to the touchpad, and the user's fingers are not involved.

    python3 touchpad-tap-test.py            # from any directory
    python3 touchpad-tap-test.py -v         # also print each emitted event
"""

import argparse
import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DETECTOR = os.path.join(HERE, "touchpad-swipe.py")


def load_detector(path=None):
    """Load a detector from disk.

    `--detector` points at a COPY of the detector, which is how the same cases
    were run against the version in git before the landing-coincidence gate
    existed: the resting-finger cases are taps there and not here, so the gate
    is what changed the behaviour rather than something else in the pad's
    timing.
    """
    spec = importlib.util.spec_from_file_location("touchpad_swipe", path or DETECTOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Pad:
    """A Trackpad fed by hand, with everything it emits collected."""

    def __init__(self, module, verbose=False):
        self.m = module
        path = module.find_touchpad()
        if not path:
            raise SystemExit("no multi-touch device found (a test needs real ranges)")
        self.path = path
        self.tracker = module.Trackpad(path, {2, 3, 4})
        self.lines = []
        self.verbose = verbose
        # Capture instead of writing to stdout: the tracker's own _write is the
        # single door every event goes through (see its comment), so replacing
        # it captures the real payload with no fake formatting.
        self.tracker._write = self.lines.append
        self.next_tid = 100

    # -- the event stream, spelled the way the device speaks it -----------
    def _syn(self):
        self.tracker.handle(self.m.EV_SYN, self.m.SYN_REPORT, 0)

    def land(self, slot, x=None, y=None):
        """Put a contact down.

        Default positions are SPREAD ACROSS the pad, one finger per slot,
        rather than all on the same pixel. That is what a hand does -- and it
        matters: a finger that lands away from the others moves the MEAN
        position, so a tracker that charged travel for the landing itself would
        fail these cases (see the re-baseline in report()). Landing everything
        on one point would hide exactly that bug.
        """
        self.next_tid += 1
        self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_SLOT, slot)
        self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_TRACKING_ID, self.next_tid)
        self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_POSITION_X,
                            self.mid_x + (slot - 1) * 120 if x is None else x)
        self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_POSITION_Y,
                            self.mid_y + (slot % 2) * 60 if y is None else y)
        self._syn()

    def lift(self, slot):
        self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_SLOT, slot)
        self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_TRACKING_ID, -1)
        self._syn()

    def slide(self, dx, dy, slots):
        """Move the named contacts together, in device units."""
        for slot in slots:
            self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_SLOT, slot)
            self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_POSITION_X,
                                int(self.tracker.xpos.get(slot, self.mid_x) + dx))
            self.tracker.handle(self.m.EV_ABS, self.m.ABS_MT_POSITION_Y,
                                int(self.tracker.positions.get(slot, self.mid_y) + dy))
        self._syn()

    @property
    def mid_x(self):
        t = self.tracker
        return int(t.x_min + t.x_span / 2)

    @property
    def mid_y(self):
        t = self.tracker
        return int(t.y_min + t.y_span / 2)

    # -- reading what came out -------------------------------------------
    def reset(self):
        # Start every case from an empty pad: contacts left down by a previous
        # case would be exactly the resting finger this file is about.
        for slot in list(self.tracker.slots):
            self.lift(slot)
        # CLEARED, not rebound: the tracker's _write holds a bound method of
        # THIS list, so `self.lines = []` would silently orphan the capture and
        # every case would read as "no events at all" -- which is how an
        # earlier version of this file reported nine failures against working
        # code.
        self.lines.clear()
        # And then WAIT OUT THE RE-JOIN GRACE, which is 150ms of deliberately
        # merged gesture: a case started immediately after the last one is
        # treated as the SAME gesture continuing (that is what the grace is
        # for -- a finger micro-lifting must not split a swipe), so its
        # landings would be judged together with the previous case's. Real
        # taps by real hands are further apart than this.
        time.sleep(self.m.REJOIN_GRACE_S + 0.05)
        self.lines.clear()

    def events(self):
        import json
        out = []
        for line in self.lines:
            line = line.strip()
            if not line or line.startswith('{"hb"'):
                continue
            out.append(json.loads(line))
        return out

    def verdict(self):
        """The phase the shell routes on: the LAST tap, or the last end."""
        taps = [e for e in self.events() if e["phase"] == "tap"]
        ends = [e for e in self.events() if e["phase"] == "end"]
        if taps:
            return taps[-1]
        return ends[-1] if ends else None


class Results:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def check(self, label, ok, detail=""):
        if ok:
            self.passed += 1
            print(f"  PASS  {label}")
        else:
            self.failed += 1
            print(f"  FAIL  {label}{(' — ' + detail) if detail else ''}")
        return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="print every event the detector emits")
    parser.add_argument("--detector", default=None,
                        help="run the cases against a copy of the detector "
                             "(default: the one next to this file)")
    args = parser.parse_args()

    m = load_detector(args.detector)
    pad = Pad(m, verbose=args.verbose)
    r = Results()
    # A version without the gate is a legitimate thing to run these cases
    # against (that is the before/after comparison), so read it defensively
    # rather than crashing on the banner.
    coincidence = getattr(m, "TAP_COINCIDENCE_MS", None)
    print(f"pad: {pad.path} ({m.device_name(pad.path)})")
    print(f"tap gates: <= {m.TAP_MAX_MS:.0f}ms, moved <= {m.TAP_MAX_TRAVEL}, "
          + (f"contacts landed within {coincidence:.0f}ms" if coincidence
             else "NO landing-coincidence gate in this version") + "\n")

    def show():
        if not args.verbose:
            return
        for e in pad.events():
            print(f"        {e['phase']:6} fingers={e['fingers']} start={e['start']} "
                  f"peak={e['peak']} dur={e['dur_ms']}ms moved={e['moved']} "
                  f"spread={e['spread_ms']}ms")

    # ── 1. a true three-finger tap, landed together ──────────────────────
    pad.reset()
    for i, slot in enumerate((0, 1, 2)):
        pad.land(slot)
        if i < 2:
            time.sleep(0.008)          # a hand lands within a few ms per finger
    time.sleep(0.03)
    for slot in (0, 1, 2):
        pad.lift(slot)
    v = pad.verdict()
    show()
    r.check("a real 3-finger tap is a tap, routed as 3",
            v is not None and v["phase"] == "tap" and v["start"] == 3,
            f"got {v and v['phase']} start={v and v['start']}")
    spread = v.get("spread_ms") if v else None
    r.check("  ...and its contacts did land together",
            spread is not None and coincidence is not None and spread <= coincidence,
            f"spread={spread}ms")

    # ── 2. a finger RESTING on the pad, then two fingers tapping ─────────
    pad.reset()
    pad.land(0)                        # the resting finger
    time.sleep(0.32)                   # it has been there a while
    pad.land(1); time.sleep(0.008); pad.land(2)
    time.sleep(0.03)
    pad.lift(1); pad.lift(2)           # the tappers lift; the resting one stays
    v = pad.verdict()
    show()
    r.check("a resting finger + 2 tapping fingers is NOT a 3-finger tap",
            v is not None and v["phase"] != "tap",
            f"got {v and v['phase']} start={v and v['start']}")
    spread = v.get("spread_ms") if v else None
    r.check("  ...and the reason is on the event (the landings are not coincident)",
            spread is not None and coincidence is not None and spread > coincidence,
            f"spread={spread}ms")
    pad.lift(0)

    # ── 2b. the same, but the RESTING finger lifts FIRST ────────────────
    # A hand does not always lift in the order it landed, and the gate must
    # not depend on that: the resting finger is in the tap log from the moment
    # the gesture began, so it is judged whenever it leaves.
    pad.reset()
    pad.land(0)
    time.sleep(0.32)
    pad.land(1); time.sleep(0.008); pad.land(2)
    time.sleep(0.03)
    pad.lift(0)                        # the resting finger goes first
    pad.lift(1); pad.lift(2)
    v = pad.verdict()
    show()
    r.check("a resting finger that lifts FIRST still cannot fake a tap",
            v is not None and v["phase"] != "tap",
            f"got {v and v['phase']} start={v and v['start']}")

    # ── 3. a true four-finger tap ───────────────────────────────────────
    pad.reset()
    for i, slot in enumerate((0, 1, 2, 3)):
        pad.land(slot)
        if i < 3:
            time.sleep(0.008)
    time.sleep(0.03)
    for slot in (0, 1, 2, 3):
        pad.lift(slot)
    v = pad.verdict()
    show()
    r.check("a real 4-finger tap is a tap, routed as 4",
            v is not None and v["phase"] == "tap" and v["start"] == 4,
            f"got {v and v['phase']} start={v and v['start']}")

    # ── 4. a resting finger, then three fingers tapping ─────────────────
    pad.reset()
    pad.land(0)
    time.sleep(0.32)
    for i, slot in enumerate((1, 2, 3)):
        pad.land(slot)
        if i < 2:
            time.sleep(0.008)
    time.sleep(0.03)
    pad.lift(1); pad.lift(2); pad.lift(3)
    v = pad.verdict()
    show()
    r.check("a resting finger + 3 tapping fingers is NOT a 4-finger tap",
            v is not None and v["phase"] != "tap",
            f"got {v and v['phase']} start={v and v['start']}")
    pad.lift(0)

    # ── 5. a genuine but SLOPPY tap: fingers 90ms apart ─────────────────
    pad.reset()
    pad.land(0)
    time.sleep(0.09)
    pad.land(1)
    time.sleep(0.09)
    pad.land(2)
    time.sleep(0.03)
    for slot in (0, 1, 2):
        pad.lift(slot)
    v = pad.verdict()
    show()
    r.check("a sloppy real tap (90ms per finger) is still a tap",
            v is not None and v["phase"] == "tap",
            f"got {v and v['phase']} spread={(v or {}).get('spread_ms')}ms")

    # ── 6. three fingers that SLIDE: not a tap, still a swipe ───────────
    pad.reset()
    for slot in (0, 1, 2):
        pad.land(slot)
    for _ in range(6):
        pad.slide(0, int(pad.tracker.y_span * 0.05), (0, 1, 2))
    for slot in (0, 1, 2):
        pad.lift(slot)
    v = pad.verdict()
    show()
    r.check("three fingers that travel are a swipe, not a tap",
            v is not None and v["phase"] == "end",
            f"got {v and v['phase']} moved={v and v['moved']}")

    # ── 7. after a rejected tap, a clean tap still works ────────────────
    pad.reset()
    pad.land(0)
    time.sleep(0.32)
    pad.land(1); time.sleep(0.008); pad.land(2)
    time.sleep(0.03)
    pad.lift(1); pad.lift(2)
    pad.lift(0)                        # this time the resting finger goes too
    # Long enough to be a NEW gesture rather than a continuation of the
    # rejected one (the grace is 150ms; a hand takes longer than that).
    time.sleep(pad.m.REJOIN_GRACE_S + 0.05)
    for i, slot in enumerate((0, 1, 2)):
        pad.land(slot)
        if i < 2:
            time.sleep(0.008)
    time.sleep(0.03)
    for slot in (0, 1, 2):
        pad.lift(slot)
    taps = [e for e in pad.events() if e["phase"] == "tap"]
    show()
    r.check("a rejected tap leaves nothing behind: the next real tap fires",
            len(taps) == 1 and taps[-1]["start"] == 3,
            f"taps={[(e['phase'], e['start']) for e in pad.events()]}")

    print(f"\npassed {r.passed}, failed {r.failed}")
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
