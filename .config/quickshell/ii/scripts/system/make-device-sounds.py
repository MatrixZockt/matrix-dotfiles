#!/usr/bin/env python3
"""Synthesize the two sounds this desktop makes when a drive goes in or out.

WHY SYNTHESIZED, AND WHY HERE.  The only sound a freedesktop theme has for
hardware arriving is `device-added` / `device-removed`, and the notification
that announces a stick uses the session's notification sound -- which is a
soft, low "drop".  A device going into a port is not a drop: it is a crisp,
mechanical, satisfying CLICK, the way a controller snaps onto its console.
That sound does not exist in any theme shipped with the system, so it is
built here, and it is built from code rather than checked in as an opaque
binary: the recipe IS the documentation, and tuning it later is editing
numbers instead of reaching for an audio editor.

WHAT ACTUALLY PLAYS.  Not this, any more.  The shipped pair is cut from a
recording instead (scripts/system/import-device-sound.py), because the sound
wanted was one specific recording that this recipe did not reproduce to taste.
This script stays as the fallback -- a click from nothing, on any machine -- and
it REFUSES to overwrite the shipped files unless told to, so running it cannot
quietly throw the recording away. `--force` to write over them anyway.

HOW THE CLICK IS MADE.  Three layers, all decaying, none longer than a
person's sense of "instant" (~150 ms total):

  the tick     a few milliseconds of broadband noise, high-passed by a first
               difference. This is the contact itself -- the edge that makes
               the ear read "plastic hit plastic" rather than "beep".
  the body     four sine partials between 1.5 and 6 kHz with 8-26 ms decays.
               Those give the snap its shape and its sense of a small, solid
               object; the frequencies are the plastic-housing resonance
               range, and the highest one is deliberately short so the sound
               stays dry instead of ringing.
  the seat     one very short low partial, so the click has weight. Without
               it the sound reads as a UI blip; with a big one it turns into
               the thud this is meant to replace. It is 12 ms.

  remove       the same recipe, lowered and softened: a duller tick, partials
               an octave-ish down, and a longer, quieter seat. Pulling a
               connector out is the same gesture going the other way, so the
               pair is recognisable -- and distinguishable.

Peak-normalised to -1 dBFS with a 1.5 ms fade in and a 15 ms fade out, because
a raw clipped edge is what makes a short sound harsh rather than satisfying.
(The shipped pair was later cut from a recording instead -- see
import-device-sound.py -- and carries the same -1 dBFS target, so regenerating
from either recipe gives the level the desktop actually wants.)

Usage:  scripts/system/make-device-sounds.py [output-directory] [--force]
        (default: <config>/assets/sounds)
"""

import array
import math
import os
import random
import struct
import sys
import wave

SAMPLE_RATE = 44100
# A fixed seed: the noise layers must be identical on every regeneration, or
# "the sound changed" would be indistinguishable from "the recipe changed".
random.seed(20261009)


def envelope(t, tau):
    return math.exp(-t / tau)


def render(layers, duration):
    """layers: list of callables (t) -> float. Sum, fade, normalise."""
    total = int(duration * SAMPLE_RATE)
    samples = [0.0] * total
    for i in range(total):
        t = i / SAMPLE_RATE
        samples[i] = sum(layer(t) for layer in layers)

    fade_in = int(0.0015 * SAMPLE_RATE)
    fade_out = int(0.015 * SAMPLE_RATE)
    for i in range(min(fade_in, total)):
        samples[i] *= i / fade_in
    for i in range(min(fade_out, total)):
        samples[total - 1 - i] *= i / fade_out

    peak = max(abs(s) for s in samples) or 1.0
    scale = 0.891 / peak        # -1 dBFS, the level the desktop asks for
    return array.array("h", [int(max(-1.0, min(1.0, s * scale)) * 32767) for s in samples])


def tone_layer(freq, tau, amount, start=0.0, phase=0.0):
    def layer(t):
        if t < start:
            return 0.0
        return math.sin(2 * math.pi * freq * (t - start) + phase) * amount * envelope(t - start, tau)

    return layer


def insert_sound():
    """The click: bright, dry, ~150 ms."""
    prev = {"v": 0.0}

    def tick(t):
        raw = random.uniform(-1.0, 1.0)
        # First difference: +6 dB/octave, which is what turns noise into a
        # contact tick instead of a white hiss.
        diff = raw - prev["v"]
        prev["v"] = raw
        return diff * 0.55 * envelope(t, 0.0022)

    return render([
        tick,
        tone_layer(1560, 0.026, 0.55),
        tone_layer(2680, 0.020, 0.40),
        tone_layer(3900, 0.015, 0.22),
        tone_layer(6300, 0.008, 0.10),
        tone_layer(320, 0.012, 0.16),
    ], 0.150)


def remove_sound():
    """The softer, lower half of the pair: the connector letting go."""
    prev = {"v": 0.0}

    def tick(t):
        raw = random.uniform(-1.0, 1.0)
        # Lightly smoothed (a two-tap average) rather than differenced: a
        # duller contact, which is what a release sounds like.
        n = 0.5 * (raw + prev["v"])
        prev["v"] = raw
        return n * 0.42 * envelope(t, 0.0035)

    return render([
        tick,
        tone_layer(1050, 0.030, 0.50),
        tone_layer(1830, 0.022, 0.30),
        tone_layer(2600, 0.014, 0.12),
        tone_layer(180, 0.025, 0.20),
    ], 0.220)


def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(samples.tobytes())


def main():
    default_out = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "assets", "sounds")
    force = "--force" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != "--force"]
    out = args[0] if args else default_out

    names = ("device-insert.wav", "device-remove.wav")
    existing = [n for n in names if os.path.exists(os.path.join(out, n))]
    if existing and not force:
        print("refusing to overwrite the shipped sound%s in %s:\n  %s\n"
              "Those are cut from a recording (scripts/system/import-device-sound.py),"
              "\nnot from this recipe. Re-run with --force to replace them with the"
              "\nsynthesised click anyway."
              % ("s" if len(existing) > 1 else "", out, "\n  ".join(existing)))
        return 1

    os.makedirs(out, exist_ok=True)
    for name, data in (("device-insert.wav", insert_sound()),
                       ("device-remove.wav", remove_sound())):
        path = os.path.join(out, name)
        write_wav(path, data)
        print("%s  %d frames  %.0f ms" % (path, len(data), 1000 * len(data) / SAMPLE_RATE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
