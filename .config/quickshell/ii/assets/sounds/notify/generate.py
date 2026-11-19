#!/usr/bin/env python3
"""Generates the notification sounds in .config/quickshell/ii/assets/sounds/notify/.

The reference these are written against is the Switch's "Enter & Back" blip:
76.5 ms for two events, each a percussive pitched tick (1.09 kHz, then 1.55 kHz),
peak -4.6 dBFS, -20 dB within 4.5 ms of the attack, spectral centroid 3.8 kHz,
no reverb and no tail. What makes that style work, and what every sound here
keeps, is:

  * it is SHORT -- the whole gesture is over before the eye has moved;
  * it is PITCHED -- a clean tone, not a chime smear, so it reads as "a system
    said something" rather than as music;
  * the attack is CONTROLLED -- a raised-cosine ramp of about a millisecond, so
    it starts decisively and still does not click;
  * the body is a fast exponential, 8-18 ms -- enough to have a note, not
    enough to have an echo;
  * it is BRIGHT and sits high (0.6-1.6 kHz fundamentals), where a laptop
    speaker is intelligible and where it does not compete with music;
  * nothing decays slowly, nothing is wide, nothing is loud: peak -3 dBFS, mono
    content, and no reverb at all. Room would turn a tick into a chime.

Each sound below is a different design in that language, not a variation of the
reference's two notes. Run `python3 generate.py` to rewrite them (numpy only,
48 kHz / 16-bit stereo, a few KB each).
"""

import base64
import io
import os
import wave

import numpy as np

SR = 48000
OUT = os.path.dirname(os.path.abspath(__file__))

# The take the desktop actually plays. It is written to the assets folder as
# notification.wav -- the file services/Notifications.qml loads for a chime and
# PolkitService.qml loads for an auth prompt -- so `python3 generate.py` and
# the shipped sound can never drift apart.
CHOSEN = "notify-tone-warm-a"

# What the preview page offers: the main voices, one per character, plus the warm
# take's two register neighbours and the two low-arch takes that were liked.
# Every other design above is still in SOUNDS -- main() skips it and deletes its
# wav -- so bringing one back on another day is adding its slug here, not
# rewriting the design.
KEEP = (
    "notify-wood-g3-clear",
    "notify-wood-g3-muffled",
    "notify-wood-g3-wide",
    "notify-wood-g3-soft-landing",
    "notify-wood-f3",
    "notify-wood-d3",
    "notify-wood-c4",
    "notify-tone-warm-a",
    "notify-tone-warm-g",
    "notify-tone-warm-c",
    "notify-tone-marimba",
    "notify-tone-bell",
    "notify-tone-pluck",
    "notify-tone-deep-wood",
    "notify-low-a5",
    "notify-low-c5",
)


# ── Building blocks ──────────────────────────────────────────────────────


def envelope(n, attack_ms, tau_ms):
    """Raised-cosine attack, exponential body: decisive, then gone."""
    t = np.arange(n) / SR
    attack = np.clip(t / max(attack_ms / 1000.0, 1e-5), 0.0, 1.0)
    attack = 0.5 - 0.5 * np.cos(np.pi * attack)
    return attack * np.exp(-t / (tau_ms / 1000.0))


def tone(freq, dur_ms, tau_ms, attack_ms=0.8, glide_to=None,
         partials=((1.0, 1.0),)):
    """A pitched tick. `glide_to` bends the pitch exponentially over the note."""
    n = int(SR * dur_ms / 1000.0)
    t = np.arange(n) / SR
    if glide_to:
        f = freq * (glide_to / freq) ** (t / (dur_ms / 1000.0))
        phase = 2 * np.pi * np.cumsum(f) / SR
    else:
        phase = 2 * np.pi * freq * t
    out = np.zeros(n)
    for ratio, amp in partials:
        out += amp * np.sin(ratio * phase)
    return out * envelope(n, attack_ms, tau_ms)


def click(dur_ms=2.0, center=3400.0, tau_ms=0.55, amp=0.4, seed=7):
    """The tiny high transient that makes a tick feel like contact, not a beep.

    Band-limited noise rather than a raw burst: a raw one is a click of static,
    which is the one thing that makes a UI sound cheap.
    """
    n = int(SR * dur_ms / 1000.0)
    t = np.arange(n) / SR
    noise = np.random.default_rng(seed).normal(0, 1, n)
    size = 4096
    spectrum = np.fft.rfft(noise, size)
    freq = np.fft.rfftfreq(size, 1 / SR)
    bell = np.exp(-0.5 * ((freq - center) / (center * 0.55)) ** 2)
    shaped = np.fft.irfft(spectrum * bell, size)[:n]
    shaped /= max(np.abs(shaped).max(), 1e-9)
    return amp * shaped * np.exp(-t / (tau_ms / 1000.0))


def declick(signal, ms=0.5):
    """Half a millisecond of ramp at each end.

    The noise transient of a tick is at full level on its first sample, which is
    a step from silence -- inaudible as noise, unmistakable as a click. The ramp
    is far shorter than the attack it is protecting, so the tick still starts
    decisively; it just does not start with a discontinuity.
    """
    n = max(2, int(SR * ms / 1000.0))
    ramp = 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / n)
    out = signal.copy()
    out[:n] *= ramp
    out[-n:] *= ramp[::-1]
    return out


def place(total_ms, *events):
    """Sum (offset_ms, signal) pairs into one buffer."""
    total = int(SR * total_ms / 1000.0)
    out = np.zeros(total)
    for offset_ms, sig in events:
        start = int(SR * offset_ms / 1000.0)
        end = min(total, start + len(sig))
        out[start:end] += sig[:end - start]
    return out


# ── The five designs ─────────────────────────────────────────────────────


def design_tick():
    """One dry wooden tock: contact plus a short C6 body. The most minimal."""
    body = tone(1046.5, 58, tau_ms=9, glide_to=1010,
                partials=((1.0, 1.0), (2.0, 0.22), (3.0, 0.10), (5.4, 0.05)))
    return place(62, (0, click(2.0, 3200, 0.45, 0.42)), (0, body))


def design_pair():
    """Two steps up, G5 then D6: reads as "done", still under 90 ms."""
    first = tone(784.0, 30, tau_ms=7,
                 partials=((1.0, 1.0), (2.0, 0.18), (3.0, 0.07)))
    second = tone(1174.7, 48, tau_ms=10,
                  partials=((1.0, 1.0), (2.0, 0.20), (3.0, 0.08)))
    return place(92,
                 (0, click(1.8, 3000, 0.4, 0.30)),
                 (0, first),
                 (23, click(1.6, 3600, 0.35, 0.26, seed=11)),
                 (23, second * 0.9))


def design_glass():
    """An FM ping, G6 with a 2:1 modulator: glass, not wood."""
    dur = 70
    n = int(SR * dur / 1000.0)
    t = np.arange(n) / SR
    carrier = 2 * np.pi * 1568.0 * t
    modulator = np.sin(2 * np.pi * 3136.0 * t) * 2.2 * np.exp(-t / 0.008)
    body = np.sin(carrier + modulator)
    # A whisper of the twelfth above, so it rings rather than buzzes.
    body += 0.12 * np.sin(2 * np.pi * 4698.0 * t) * np.exp(-t / 0.010)
    body *= envelope(n, 0.6, 16)
    return place(74, (0, click(1.6, 5200, 0.3, 0.22, seed=3)), (0, body))


def design_bubble():
    """A small upward glide, A4 to A5 in 12 ms: the friendliest of the five."""
    body = tone(587.3, 64, tau_ms=13, attack_ms=1.2, glide_to=880.0,
                partials=((1.0, 1.0), (2.0, 0.14), (3.0, 0.05)))
    return place(70, (0, click(2.2, 2600, 0.6, 0.28, seed=5)), (2, body))


def design_drip():
    """A downward glide, E6 to A5: a closing sound, and the softest attack."""
    body = tone(1318.5, 66, tau_ms=12, attack_ms=1.4, glide_to=880.0,
                partials=((1.0, 1.0), (2.0, 0.16), (3.0, 0.06)))
    second = tone(659.3, 26, tau_ms=8, attack_ms=1.0) * 0.35
    return place(76,
                 (0, click(2.0, 3000, 0.5, 0.22, seed=9)),
                 (0, body),
                 (14, second))


def design_pair_long():
    """The 92 ms two-step, given room: same G5 - D6, longer bodies, bigger gap.

    Only the decay and the spacing grow -- the pitch, the balance and the dry
    character are the ones that were picked. 112 ms rather than 92.
    """
    first = tone(784.0, 40, tau_ms=9,
                 partials=((1.0, 1.0), (2.0, 0.18), (3.0, 0.07)))
    second = tone(1174.7, 62, tau_ms=14,
                  partials=((1.0, 1.0), (2.0, 0.20), (3.0, 0.08)))
    return place(112,
                 (0, click(1.8, 3000, 0.4, 0.30)),
                 (0, first),
                 (30, click(1.6, 3600, 0.35, 0.26, seed=11)),
                 (30, second * 0.9))


def design_pair_high():
    """The same two steps, a fourth higher: A5 - E6. Brighter, more alert.

    104 ms, and the higher notes want slightly shorter bodies or the second one
    starts to ring, which is the one thing this style never does.
    """
    first = tone(880.0, 34, tau_ms=7.5,
                 partials=((1.0, 1.0), (2.0, 0.16), (3.0, 0.06)))
    second = tone(1318.5, 56, tau_ms=11.5,
                  partials=((1.0, 1.0), (2.0, 0.18), (3.0, 0.07)))
    return place(104,
                 (0, click(1.6, 3600, 0.35, 0.26, seed=13)),
                 (0, first),
                 (26, click(1.5, 4200, 0.3, 0.22, seed=17)),
                 (26, second * 0.9))


def design_triad():
    """Three steps instead of two: G5 - B5 - D6, 31 ms apart. 120 ms.

    Still an interval-shaped gesture rather than a melody -- the third note is
    the only one that is allowed to have a body, which is what keeps it a UI
    sound and not a jingle.
    """
    first = tone(784.0, 28, tau_ms=7,
                 partials=((1.0, 1.0), (2.0, 0.16), (3.0, 0.06)))
    second = tone(987.8, 30, tau_ms=8,
                  partials=((1.0, 1.0), (2.0, 0.17), (3.0, 0.06)))
    third = tone(1174.7, 56, tau_ms=12,
                 partials=((1.0, 1.0), (2.0, 0.20), (3.0, 0.08)))
    return place(120,
                 (0, click(1.7, 3000, 0.4, 0.24, seed=19)),
                 (0, first),
                 (31, click(1.6, 3300, 0.35, 0.22, seed=23)),
                 (31, second),
                 (62, click(1.5, 3700, 0.32, 0.24, seed=29)),
                 (62, third * 0.95))


def design_triad_shaped(amps):
    """The three-step with a level shape across its notes.

    Notes, spacing and decays are exactly `design_triad`'s; only each note's
    level -- and its contact transient, so the tick does not get louder than the
    note it belongs to -- changes. Level is a second dimension on one gesture,
    not a second melody: that is what keeps these reading as one family.
    """
    a1, a2, a3 = amps
    first = tone(784.0, 28, tau_ms=7,
                 partials=((1.0, 1.0), (2.0, 0.16), (3.0, 0.06))) * a1
    second = tone(987.8, 30, tau_ms=8,
                  partials=((1.0, 1.0), (2.0, 0.17), (3.0, 0.06))) * a2
    third = tone(1174.7, 56, tau_ms=12,
                 partials=((1.0, 1.0), (2.0, 0.20), (3.0, 0.08))) * a3
    return place(120,
                 (0, click(1.7, 3000, 0.4, 0.24 * a1, seed=19)),
                 (0, first),
                 (31, click(1.6, 3300, 0.35, 0.22 * a2, seed=23)),
                 (31, second),
                 (62, click(1.5, 3700, 0.32, 0.24 * a3, seed=29)),
                 (62, third))


def design_steps(levels_db, total_ms=155, offsets=(0, 40, 80),
                 durs=(40, 44, 72), freqs=(784.0, 987.8, 1174.7),
                 taus=(9, 10, 13)):
    """The three steps with an unmistakable level direction.

    Two things were wrong with the first version of this idea: 3-6 dB between
    notes is inside the range where a listener hears "roughly the same", and 31
    ms of spacing is short enough that three ticks fuse into one gesture. So the
    spread here is 10-13 dB between ADJACENT notes (20-26 dB end to end) and the
    notes sit 40 ms apart in a 155 ms file -- each one arrives separately, and
    the direction is the thing you notice first.

    Notes, partials and contact transients are the same as `design_triad`; the
    per-note transient tracks its note's level, so a quiet note is a quiet tick
    rather than a lone click.
    """
    events = []
    for index, (level_db, offset, dur, freq, tau) in enumerate(
            zip(levels_db, offsets, durs, freqs, taus)):
        amp = 10 ** (level_db / 20.0)
        events.append((offset, tone(
            freq, dur, tau_ms=tau,
            partials=((1.0, 1.0), (2.0, 0.18), (3.0, 0.07))) * amp))
        events.append((offset, click(1.6, 3200, 0.35, 0.22 * amp,
                                     seed=31 + index * 7)))
    return place(total_ms, *events)


def lowpass(signal, cutoff_hz, poles=2):
    """Gentle one-pole low-pass, applied `poles` times.

    A UI tick is "clear" because of its top end: the contact transient and the
    2nd/3rd partials are what make it read as crisp. Rolling those off is what
    makes the same gesture feel soft and a little muffled instead -- the notes
    and their timing do not move.
    """
    a = np.exp(-2 * np.pi * cutoff_hz / SR)
    out = signal.astype(float).copy()
    for _ in range(poles):
        acc = out[0]
        for n in range(len(out)):
            acc = a * acc + (1 - a) * out[n]
            out[n] = acc
    return out


def design_arch_damped(freqs, levels_db=(-6.0, 0.0, -4.0), spacing=48,
                       damp=0.35, cutoff_hz=5500.0):
    """The soft arch, damped: slower attack, darker tick, rolled-off top.

    `damp` 0 is the crisp version; at 0.35 the attack is a couple of
    milliseconds rather than a fraction of one, the contact tick sits 55 %
    quieter and lower, and the upper partials are mostly gone before the
    two-pole roll-off at `cutoff_hz` finishes with them. Notes, levels, spacing
    and length are identical to `design_arch_pitch` -- only the edges soften.
    """
    offsets = (0.0, float(spacing), 2.0 * float(spacing))
    durs = (40, 44, 72)
    taus = (9, 10, 13)
    total_ms = int(2 * spacing + 76)
    events = []
    for index, (level_db, offset, dur, freq, tau) in enumerate(
            zip(levels_db, offsets, durs, freqs, taus)):
        amp = 10 ** (level_db / 20.0)
        partials = ((1.0, 1.0),
                    (2.0, 0.18 * (1 - 0.65 * damp)),
                    (3.0, 0.07 * (1 - 0.85 * damp)))
        events.append((offset, tone(freq, dur, tau_ms=tau,
                                    attack_ms=0.8 + 2.0 * damp,
                                    partials=partials) * amp))
        events.append((offset, click(1.6, 3200.0 * (1 - 0.30 * damp), 0.35,
                                     0.22 * amp * (1 - 0.55 * damp),
                                     seed=31 + index * 7)))
    return lowpass(place(total_ms, *events), cutoff_hz)


def design_arch_pitch(freqs, levels_db=(-16.0, 0.0, -12.0), spacing=40):
    """The arch, with the notes climbing instead of stepping a third.

    Nothing about the sound changes except which notes are played: same three
    ticks, same partials, same contact transients, same arch across the levels.
    Only `freqs` and `spacing` move: the notes climb, so the gesture starts low
    and its last note is the highest one, and the gap between notes can be
    widened a little so each arrival is heard as its own event.

    `total_ms` follows the spacing (last note plus its body, plus a short tail),
    so widening the gaps makes the file longer instead of clipping the tail off.
    """
    offsets = (0.0, float(spacing), 2.0 * float(spacing))
    return design_steps(levels_db, total_ms=int(2 * spacing + 76),
                        offsets=offsets, freqs=freqs)


def design_tone(freqs, partials, attack_ms, taus, tick_amp=0.0,
                tick_center=2600.0, spacing=80, levels_db=(-6.0, 0.0, -4.0),
                cutoff_hz=5500.0, durs=(44, 48, 76)):
    """The three-step gesture with the CHARACTER left as a parameter.

    `design_arch_damped` fixes the woodblock character: a hard-ish toast of a
    contact tick and a sine body with two weak upper partials. This keeps its
    timing, its level arch and its spacing and lets three things move:

      * `freqs` -- the register;
      * `partials` -- what the note is made of, so a sine, a marimba bar, a
        bell and a string stop being the same instrument;
      * `tick_amp` -- whether there is a contact transient at all. A warm
        sine reads as a soft confirmation precisely because it has none.

    Notes are placed on the same offsets and shaped by the same envelope
    family, so every take is the same gesture in a different voice.
    """
    offsets = (0.0, float(spacing), 2.0 * float(spacing))
    total_ms = int(2 * spacing + max(durs) + 24)
    events = []
    for index, (level_db, offset, dur, freq, tau) in enumerate(
            zip(levels_db, offsets, durs, freqs, taus)):
        amp = 10 ** (level_db / 20.0)
        events.append((offset, tone(freq, dur, tau_ms=tau,
                                    attack_ms=attack_ms,
                                    partials=partials) * amp))
        if tick_amp > 0:
            events.append((offset, click(1.6, tick_center, 0.35,
                                         tick_amp * amp,
                                         seed=41 + index * 7)))
    return lowpass(place(total_ms, *events), cutoff_hz)


def ks_pluck(freq, dur_ms, decay=0.9955, seed=0):
    """A plucked string: Karplus-Strong, so the note has a body that dies.

    A sine with an exponential envelope is a beep that fades; a string is many
    partials that fade at different rates. This is the cheapest way to get the
    second out of the same three-step timing, and it is why the take sounds
    "heard" rather than "generated".
    """
    n = int(SR * dur_ms / 1000.0)
    size = max(2, int(round(SR / freq)))
    rng = np.random.default_rng(seed)
    line = rng.uniform(-1.0, 1.0, size)
    out = np.zeros(n)
    index = 0
    for i in range(n):
        out[i] = line[index]
        nxt = (index + 1) % size
        line[index] = decay * 0.5 * (line[index] + line[nxt])
        index = nxt
    peak = max(np.abs(out).max(), 1e-9)
    return out / peak


def design_tone_pluck(freqs, spacing=80, levels_db=(-6.0, 0.0, -4.0),
                      durs=(90, 90, 130)):
    """Three plucked steps, no contact tick: the gesture in a string voice."""
    offsets = (0.0, float(spacing), 2.0 * float(spacing))
    total_ms = int(2 * spacing + max(durs) + 20)
    events = []
    for index, (level_db, offset, dur, freq) in enumerate(
            zip(levels_db, offsets, durs, freqs)):
        amp = 10 ** (level_db / 20.0)
        events.append((offset, ks_pluck(freq, dur, seed=53 + index * 11) * amp))
    return lowpass(place(total_ms, *events), 5200.0)


SOUNDS = [
    ("notify-arch-low", "Arch, low start",
     "G4 - D5 - A5: starts an octave and a half down, lands on top",
     lambda: design_arch_pitch((392.0, 587.3, 880.0))),
    ("notify-arch-octave", "Arch, octave rise",
     "A4 - E5 - A5: exactly an octave, tidy climb",
     lambda: design_arch_pitch((440.0, 659.3, 880.0))),
    ("notify-arch-fifth", "Arch, fifth rise",
     "C5 - G5 - D6: stays bright, still climbs",
     lambda: design_arch_pitch((523.3, 784.0, 1174.7))),
    ("notify-arch-wide", "Arch, wide rise",
     "D5 - A5 - E6: the biggest climb (587 - 1318 Hz)",
     lambda: design_arch_pitch((587.3, 880.0, 1318.5))),
    ("notify-arch-land", "Arch, wide rise, firm landing",
     "D5 - A5 - E6, but the top note stays up at -4 dB",
     lambda: design_arch_pitch((587.3, 880.0, 1318.5), (-16.0, 0.0, -4.0))),
    # ── Linear in pitch, not in Hz ──
    # The two-note-to-top takes above jumped a fifth and then a whole octave:
    # 587 - 880 - 1976 is +7 then +14 semitones, so the ramp accelerates and
    # the last step swallows the gesture. These put equal intervals between the
    # steps instead (a geometric climb, which is what the ear hears as even):
    #   B6  587 - 1077 - 1976  = +10.5 st, +10.5 st
    #   D7  587 - 1175 - 2349  = +12 st, +12 st  (D5, D6, D7 -- pure octaves)
    #   E7  659 - 1319 - 2637  = +12 st, +12 st, an octave brighter throughout
    ("notify-arch3-b6-damped", "B6 even steps, damped",
     "same climb, softened edges: softer attack, duller tick, top rolled off",
     lambda: design_arch_damped((587.3, 1077.0, 1975.5),
                                damp=0.35, cutoff_hz=5500.0)),
    # ── Low arch: the damped design, a register down and opened up ──
    # The shipped take climbs 587 - 1077 - 1976 Hz with its steps 48 ms
    # apart. Two things follow from that: the top two steps land close enough
    # to fuse into one gesture, and the top note is high enough to read as a
    # signal rather than as news. These keep the design exactly -- 2-3 ms
    # attack, 55 % quieter contact tick, upper partials pulled back, the
    # two-pole roll-off -- and move only the notes and the spacing.
    ("notify-low-a5", "Low arch &mdash; A4 / E5 / B5",
     "the damped design a register down: 440 - 659 - 988 Hz, steps 80 ms apart",
     lambda: design_arch_damped((440.0, 659.3, 987.8), spacing=80)),
    ("notify-low-g5", "Low arch &mdash; G4 / D5 / A5",
     "a whole tone lower again: 392 - 587 - 880 Hz, still climbing",
     lambda: design_arch_damped((392.0, 587.3, 880.0), spacing=80)),
    ("notify-low-f5", "Low arch &mdash; F4 / C5 / G5",
     "349 - 523 - 784 Hz: the calmest of the set",
     lambda: design_arch_damped((349.2, 523.3, 784.0), spacing=80)),
    ("notify-low-c5", "Low arch &mdash; C4 / G4 / D5",
     "262 - 392 - 587 Hz: the deepest, closest to a soft knock",
     lambda: design_arch_damped((261.6, 392.0, 587.3), spacing=80)),
    ("notify-low-a5-64", "Low arch, A4 / E5 / B5 &mdash; steps 64 ms",
     "the same low notes, closer: still three arrivals, less air between",
     lambda: design_arch_damped((440.0, 659.3, 987.8), spacing=64)),
    ("notify-low-a5-96", "Low arch, A4 / E5 / B5 &mdash; steps 96 ms",
     "the same low notes, widest: each step lands on its own",
     lambda: design_arch_damped((440.0, 659.3, 987.8), spacing=96)),
    ("notify-low-g5-soft", "Low arch, G4 / D5 / A5 &mdash; softer edges",
     "the low G climb with the damping taken further: 3.8 kHz roll-off",
     lambda: design_arch_damped((392.0, 587.3, 880.0), damp=0.65,
                                cutoff_hz=3800.0, spacing=80)),
    ("notify-arch3-b6-damped-80", "Control &mdash; B6 take, steps 80 ms",
     "the shipped notes and damping, only the spacing opened up",
     lambda: design_arch_damped((587.3, 1077.0, 1975.5),
                                damp=0.35, spacing=80)),
    # ── Tone: the same gesture, changing what the notes are made of ──
    # The three-step timing and the -6 / 0 / -4 dB arch are held; only the
    # register and the voice move. `warm` has no contact tick at all, which is
    # what makes it read as confirmation rather than as an alert; `marimba`
    # has odd partials and a short body; `bell` is inharmonic; `pluck` is a
    # string. The last one is the woodblock a register below anything tried.
    ("notify-tone-warm-a", "Warm &mdash; A4 / E5 / B5",
     "soft sine, no contact tick: a confirmation, not an alert",
     lambda: design_tone((440.0, 659.3, 987.8),
                         ((1.0, 1.0), (2.0, 0.22), (3.0, 0.08)),
                         attack_ms=3.5, taus=(16, 16, 20), cutoff_hz=4200.0)),
    ("notify-tone-warm-g", "Warm &mdash; G4 / D5 / A5",
     "the same soft sine a tone lower",
     lambda: design_tone((392.0, 587.3, 880.0),
                         ((1.0, 1.0), (2.0, 0.22), (3.0, 0.08)),
                         attack_ms=3.5, taus=(16, 16, 20), cutoff_hz=4200.0)),
    ("notify-tone-warm-c", "Warm &mdash; C4 / G4 / D5 (deepest)",
     "the same soft sine down at the bottom of the useful range",
     lambda: design_tone((261.6, 392.0, 587.3),
                         ((1.0, 1.0), (2.0, 0.20), (3.0, 0.07)),
                         attack_ms=4.0, taus=(18, 18, 22), cutoff_hz=3600.0)),
    ("notify-tone-marimba", "Marimba &mdash; D4 / A4 / E5",
     "odd partials and a short body: wooden, but a struck bar not a beep",
     lambda: design_tone((293.7, 440.0, 659.3),
                         ((1.0, 1.0), (3.0, 0.35), (5.0, 0.10)),
                         attack_ms=1.2, taus=(10, 10, 13),
                         tick_amp=0.10, tick_center=2400.0,
                         cutoff_hz=6000.0)),
    ("notify-tone-bell", "Bell &mdash; A4 / E5 / B5",
     "inharmonic partials, no tick: quieter than a chime, still soft",
     lambda: design_tone((440.0, 659.3, 987.8),
                         ((1.0, 1.0), (2.76, 0.30), (5.4, 0.10)),
                         attack_ms=2.5, taus=(18, 18, 24),
                         cutoff_hz=7000.0)),
    ("notify-tone-pluck", "Plucked string &mdash; A4 / E5 / B5",
     "Karplus-Strong: many partials dying at different rates",
     lambda: design_tone_pluck((440.0, 659.3, 987.8))),
    ("notify-tone-deep-wood", "Deeper wood &mdash; G3 / D4 / A4",
     "the shipped character taken a full register below the low arch",
     lambda: design_arch_damped((196.0, 293.7, 440.0), damp=0.35,
                                cutoff_hz=4000.0, spacing=80)),
    # ── Deeper wood, changed one axis at a time ──
    # The deep wood is the damped woodblock at G3 / D4 / A4 with a 4 kHz
    # roll-off. These keep its gesture and move one thing each: the register
    # (down to D3, up to C4), how muffled the edges are, how far apart the
    # steps sit, and whether the top note lands soft.
    ("notify-wood-f3", "Wood, F3 / C4 / G4 &mdash; a step lower",
     "the same wood a tone down: 175 - 262 - 392 Hz",
     lambda: design_arch_damped((174.6, 261.6, 392.0), damp=0.35,
                                cutoff_hz=3600.0, spacing=80)),
    ("notify-wood-d3", "Wood, D3 / A3 / E4 &mdash; the deepest",
     "147 - 220 - 330 Hz: as low as the range stays audible on a laptop",
     lambda: design_arch_damped((146.8, 220.0, 329.6), damp=0.35,
                                cutoff_hz=3400.0, spacing=80)),
    ("notify-wood-c4", "Wood, C4 / G4 / D5 &mdash; a step up",
     "262 - 392 - 587 Hz: the same voice for comparison against the warm take",
     lambda: design_arch_damped((261.6, 392.0, 587.3), damp=0.35,
                                cutoff_hz=4400.0, spacing=80)),
    ("notify-wood-g3-clear", "Wood, G3 &mdash; clearer edges",
     "damping down to 0.15 and a 5.2 kHz roll-off: the same notes, defined",
     lambda: design_arch_damped((196.0, 293.7, 440.0), damp=0.15,
                                cutoff_hz=5200.0, spacing=80)),
    ("notify-wood-g3-muffled", "Wood, G3 &mdash; muffled edges",
     "damping up to 0.6 and a 3 kHz roll-off: softer, almost felt",
     lambda: design_arch_damped((196.0, 293.7, 440.0), damp=0.60,
                                cutoff_hz=3000.0, spacing=80)),
    ("notify-wood-g3-wide", "Wood, G3 &mdash; steps 96 ms apart",
     "the same notes and edges, each step given more air (268 ms)",
     lambda: design_arch_damped((196.0, 293.7, 440.0), damp=0.35,
                                cutoff_hz=4000.0, spacing=96)),
    ("notify-wood-g3-soft-landing", "Wood, G3 &mdash; soft landing",
     "the top note at &minus;9 dB instead of &minus;4: it settles rather than lands",
     lambda: design_arch_damped((196.0, 293.7, 440.0),
                                levels_db=(-6.0, 0.0, -9.0),
                                damp=0.35, cutoff_hz=4000.0, spacing=80)),
    ("notify-arch3-d7-damped", "D7 even steps, damped",
     "587 / 1175 / 2349 Hz with the same soft edges",
     lambda: design_arch_damped((587.3, 1174.7, 2349.3),
                                damp=0.35, cutoff_hz=5500.0)),
    ("notify-arch3-d7-softer", "D7 even steps, more damped",
     "the same notes with the clarity taken further down",
     lambda: design_arch_damped((587.3, 1174.7, 2349.3),
                                damp=0.65, cutoff_hz=3800.0)),
    ("notify-arch3-top-b6-linear", "Arch soft, B6 &mdash; even steps",
     "587 / 1077 / 1976 Hz: equal pitch steps, no acceleration at the top",
     lambda: design_arch_pitch((587.3, 1077.0, 1975.5),
                               (-6.0, 0.0, -4.0), spacing=48)),
    ("notify-arch3-top-d7-linear", "Arch soft, D7 &mdash; even steps",
     "587 / 1175 / 2349 Hz: D5, D6, D7 -- two equal octave steps",
     lambda: design_arch_pitch((587.3, 1174.7, 2349.3),
                               (-6.0, 0.0, -4.0), spacing=48)),
    ("notify-arch3-top-e7-linear", "Arch soft, E7 &mdash; even steps",
     "659 / 1319 / 2637 Hz: same even climb, an octave higher throughout",
     lambda: design_arch_pitch((659.3, 1318.5, 2637.0),
                               (-6.0, 0.0, -4.0), spacing=48)),
    ("notify-arch3-soft-top-a6", "Arch soft, top note A6",
     "587 / 880 / 1760 Hz: the last step a fourth above the old one",
     lambda: design_arch_pitch((587.3, 880.0, 1760.0),
                               (-6.0, 0.0, -4.0), spacing=48)),
    ("notify-arch3-soft-top-b6", "Arch soft, top note B6",
     "587 / 880 / 1976 Hz: the last step a fifth above the old one",
     lambda: design_arch_pitch((587.3, 880.0, 1975.5),
                               (-6.0, 0.0, -4.0), spacing=48)),
    ("notify-arch3-soft-top-d7", "Arch soft, top note D7",
     "587 / 880 / 2349 Hz: the biggest lift, a top octave above the middle",
     lambda: design_arch_pitch((587.3, 880.0, 2349.3),
                               (-6.0, 0.0, -4.0), spacing=48)),
    ("notify-arch3-soft", "Three steps, arch &mdash; soft",
     "-6 / 0 / -4 dB at 48 ms: three arrivals, all plainly audible",
     lambda: design_arch_pitch((587.3, 880.0, 1318.5),
                               (-6.0, 0.0, -4.0), spacing=48)),
    ("notify-arch3-mid", "Three steps, arch &mdash; medium",
     "-9 / 0 / -6 dB: the arch reads, and the first step still counts",
     lambda: design_arch_pitch((587.3, 880.0, 1318.5),
                               (-9.0, 0.0, -6.0), spacing=48)),
    ("notify-arch3-deep", "Three steps, arch &mdash; deep",
     "-12 / 0 / -9 dB: a fuller swell, first note kept above a whisper",
     lambda: design_arch_pitch((587.3, 880.0, 1318.5),
                               (-12.0, 0.0, -9.0), spacing=48)),
    ("notify-steps-up", "Steps, rising",
     "-20 dB, -10 dB, 0 dB: quiet to loud",
     lambda: design_steps((-20.0, -10.0, 0.0))),
    ("notify-steps-down", "Steps, falling",
     "0 dB, -10 dB, -20 dB: loud to quiet",
     lambda: design_steps((0.0, -10.0, -20.0))),
    ("notify-steps-arch", "Steps, arch",
     "-16 dB, 0 dB, -12 dB: swells in the middle",
     lambda: design_steps((-16.0, 0.0, -12.0))),
    ("notify-steps-valley", "Steps, valley",
     "0 dB, -26 dB, 0 dB: loud, almost gone, loud",
     lambda: design_steps((0.0, -26.0, 0.0))),
    ("notify-triad-rise", "Three-step, rising",
     "same steps, each louder: crescendo", lambda: design_triad_shaped((0.55, 0.78, 1.0))),
    ("notify-triad-fall", "Three-step, falling",
     "each note softer, settles downward", lambda: design_triad_shaped((1.0, 0.78, 0.58))),
    ("notify-triad-arch", "Three-step, arch",
     "middle note strongest, last one eases off", lambda: design_triad_shaped((0.60, 1.0, 0.72))),
    ("notify-triad-dip", "Three-step, dip",
     "opens strong, dips, returns on the last note", lambda: design_triad_shaped((0.95, 0.55, 1.0))),
    ("notify-pair-long", "Two-step, longer",
     "the pick, with room: G5 - D6, longer bodies", design_pair_long),
    ("notify-pair-high", "Two-step, higher",
     "same shape a fourth up (A5 - E6), brighter", design_pair_high),
    ("notify-triad", "Three-step",
     "G5 - B5 - D6, 31 ms apart, the fullest", design_triad),
    ("notify-pair", "Two-step", "two quiet steps up (G5 - D6)", design_pair),
    ("notify-tick", "Tick", "wooden tock, one note (C6)", design_tick),
    ("notify-glass", "Glass", "FM ping (G6), the brightest", design_glass),
    ("notify-bubble", "Bubble", "upward glide (A4 - A5), softest", design_bubble),
    ("notify-drip", "Drip", "downward glide (E6 - A5), a closing sound", design_drip),
]

GROUPS = [
    ("Deeper wood &mdash; one axis moved at a time (the original first)",
     ("notify-tone-deep-wood", "notify-wood-g3-clear", "notify-wood-g3-muffled",
      "notify-wood-g3-wide", "notify-wood-g3-soft-landing")),
    ("Deeper wood &mdash; the same voice a register down, and one up",
     ("notify-wood-f3", "notify-wood-d3", "notify-wood-c4")),
    ("The chime in use &mdash; warm, and its register neighbours",
     ("notify-tone-warm-a", "notify-tone-warm-g", "notify-tone-warm-c")),
    ("The other voices &mdash; same three steps, different instrument",
     ("notify-tone-marimba", "notify-tone-bell", "notify-tone-pluck")),
    ("Low arch &mdash; the damped woodblock, lower, steps 80 ms apart",
     ("notify-low-a5", "notify-low-c5")),
]


# ── Measuring and writing ────────────────────────────────────────────────


def measure(signal):
    peak = float(np.abs(signal).max())
    rms = float(np.sqrt((signal ** 2).mean()))
    # Pad to the next power of two, never truncate: rfft(x, 8192) CUTS a longer
    # signal to its first 8192 samples, and cutting a windowed signal leaves a
    # step that splatters energy across the spectrum -- which read a low take
    # as brighter than a higher one, depending on where the cut landed.
    size = 1 << int(np.ceil(np.log2(max(len(signal), 2))))
    spectrum = np.abs(np.fft.rfft(signal * np.hanning(len(signal)), size))
    freq = np.fft.rfftfreq(size, 1 / SR)
    centroid = float((freq * spectrum).sum() / max(spectrum.sum(), 1e-9))
    return {
        "duration_ms": round(1000.0 * len(signal) / SR, 1),
        "peak_dbfs": round(20 * np.log10(max(peak, 1e-9)), 1),
        "rms_dbfs": round(20 * np.log10(max(rms, 1e-9)), 1),
        "centroid_hz": round(centroid),
    }


def write_wav(path, signal):
    """48 kHz, 16-bit, very slightly decorrelated stereo (mono-safe)."""
    data = np.clip(signal, -1.0, 1.0)
    left = data
    right = np.concatenate(([0.0], data[:-1])) * 0.999 + data * 0.001
    frames = np.empty((len(data), 2), dtype=np.int16)
    frames[:, 0] = np.round(left * 32767).astype(np.int16)
    frames[:, 1] = np.round(right * 32767).astype(np.int16)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(frames.tobytes())


def svg_wave(signal, width=520, height=64):
    """The waveform as an inline SVG: what the file looks like, at a glance."""
    steps = 160
    chunk = max(1, len(signal) // steps)
    points = []
    for i in range(steps):
        part = signal[i * chunk:(i + 1) * chunk]
        peak = float(np.abs(part).max()) if len(part) else 0.0
        x = width * i / (steps - 1.0)
        points.append("%.1f,%.1f" % (x, height / 2 - peak * (height / 2 - 2)))
    mirrored = ["%.1f,%.1f" % (width - float(p.split(",")[0]), height - float(p.split(",")[1]))
                for p in reversed(points)]
    return ('<svg viewBox="0 0 %d %d" class="wave" role="img" aria-label="waveform">'
            '<polygon points="%s" /></svg>' % (width, height, " ".join(points + mirrored)))


def main():
    rows = []
    for slug, name, blurb, design in [e for e in SOUNDS if e[0] in KEEP]:
        signal = design()
        # Peak-normalise to -3 dBFS: loud enough to survive a busy mix, with
        # headroom so nothing clips on a phone speaker or a cheap DAC.
        signal = declick(signal)
        signal = signal / max(np.abs(signal).max(), 1e-9) * (10 ** (-3.0 / 20))
        path = os.path.join(OUT, slug + ".wav")
        write_wav(path, signal)
        if slug == CHOSEN:
            write_wav(os.path.join(OUT, "..", "notification.wav"), signal)
        info = measure(signal)
        info.update({"slug": slug, "name": name, "blurb": blurb,
                     "bytes": os.path.getsize(path), "wave": svg_wave(signal)})
        with open(path, "rb") as handle:
            info["data"] = base64.b64encode(handle.read()).decode("ascii")
        rows.append(info)
        print("%-14s %-11s %5.1f ms  peak %5.1f dBFS  centroid %4d Hz  %5.1f kB"
              % (slug, name, info["duration_ms"], info["peak_dbfs"],
                 info["centroid_hz"], info["bytes"] / 1024))

    # Archived takes keep their design but not their file: the folder is what
    # the preview page is, so anything outside KEEP is removed rather than left
    # behind as an orphan nobody remembers choosing.
    for entry in SOUNDS:
        if entry[0] not in KEEP:
            stale = os.path.join(OUT, entry[0] + ".wav")
            if os.path.exists(stale):
                os.remove(stale)
                print("archived %s (design kept in generate.py)" % entry[0])

    with open(os.path.join(OUT, "preview.html"), "w", encoding="utf-8") as handle:
        handle.write(preview_html(rows))
    print("\nwrote %d sounds and preview.html" % len(rows))


def preview_html(rows):
    by_slug = {row["slug"]: row for row in rows}
    sections = []
    for title, slugs in GROUPS:
        cards = []
        for slug in slugs:
            row = by_slug[slug]
            cards.append(
                '\n  <article class="card" data-slug="{slug}">'
                '\n    <div class="head">'
                '\n      <h2>{name}</h2>'
                '\n      <span class="ms">{duration_ms} ms</span>'
                '\n    </div>'
                '\n    <p class="blurb">{blurb}</p>'
                '\n    {wave}'
                '\n    <div class="row">'
                '\n      <button class="play">Play</button>'
                '\n      <span class="meta">peak {peak_dbfs} dBFS &middot; '
                'centroid {centroid_hz} Hz &middot; {kb:.1f} kB</span>'
                '\n    </div>'
                '\n    <audio id="audio-{slug}" preload="auto" '
                'src="data:audio/wav;base64,{data}"></audio>'
                '\n  </article>'.format(kb=row["bytes"] / 1024, **row))
        sections.append('  <h3 class="group">%s</h3>\n%s' % (title, "".join(cards)))

    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Notification sounds — arch in pitch</title>
<style>
  :root { --bg:#0e1014; --card:#161a21; --line:#242a34; --ink:#e8ecf2;
          --dim:#8b95a5; --accent:#7ad1c4; }
  * { box-sizing:border-box; }
  body { margin:0; padding:32px 24px 56px; background:var(--bg); color:var(--ink);
         font:15px/1.55 "Inter","DejaVu Sans",system-ui,sans-serif; }
  main { max-width:760px; margin:0 auto; }
  h1 { font-size:22px; margin:0 0 4px; font-weight:600; letter-spacing:-.01em; }
  .sub { color:var(--dim); margin:0 0 26px; font-size:13.5px; }
  .spec { border:1px solid var(--line); border-radius:12px; padding:14px 16px;
          background:var(--card); color:var(--dim); font-size:12.8px; margin-bottom:22px; }
  .spec b { color:var(--ink); font-weight:550; }
  .card { border:1px solid var(--line); border-radius:14px; padding:16px 18px;
          background:var(--card); margin-bottom:14px; }
  .head { display:flex; align-items:baseline; justify-content:space-between; gap:12px; }
  h2 { font-size:16px; margin:0; font-weight:560; letter-spacing:.01em; }
  .ms { color:var(--accent); font-size:12.5px; font-variant-numeric:tabular-nums; }
  .group { font-size:11.5px; text-transform:uppercase; letter-spacing:.09em;
           color:var(--dim); margin:28px 0 10px; font-weight:600; }
  .blurb { color:var(--dim); margin:3px 0 10px; font-size:13px; }
  .wave { display:block; width:100%; height:56px; }
  .wave polygon { fill:var(--accent); opacity:.55; }
  .row { display:flex; align-items:center; gap:14px; margin-top:10px; }
  button { font:inherit; font-size:13px; padding:7px 18px; border-radius:9px;
           border:1px solid var(--line); background:#1d232c; color:var(--ink);
           cursor:pointer; transition:background .12s, border-color .12s; }
  button:hover { background:#232b35; border-color:#31394a; }
  button:active { transform:translateY(1px); }
  .meta { color:var(--dim); font-size:12px; font-variant-numeric:tabular-nums; }
  .all { margin:0 0 18px; }
  .hint { color:var(--dim); font-size:12px; margin:26px 0 0; }
</style>
</head>
<body>
<main>
  <h1>Notification sounds</h1>
  <p class="sub">Sixteen takes, one gesture: three notes, &minus;6 / 0 / &minus;4 dB, the steps given room. The
  desktop plays <b>warm, A4 / E5 / B5</b>; the deeper wood is the same damped character a register lower,
  with each variant below it changing one thing only.</p>

  <div class="spec">
    <b>Tone, not timing:</b> the gesture is fixed at three notes, 80 ms apart, &minus;6 / 0 / &minus;4 dB, peak
    &minus;3 dBFS. What moves is the voice: the warm takes are a soft sine with the contact tick removed
    entirely (3.5&ndash;4 ms attack, roll-off at 4.2 or 3.6 kHz), the marimba keeps odd partials (1, 3, 5) on a
    short body, the bell uses inharmonic ones (2.76, 5.4), the pluck is a Karplus-Strong string, and the
    deep wood is the shipped character at G3&ndash;A4 &mdash; a register below every low take tried so far.
  </div>

  <div class="spec">
    <b>Low arch:</b> the shipped take climbs 587 / 1077 / 1976 Hz, 48 ms apart, which is why its top
    two steps fuse and why it reads as a signal rather than as news. The two below keep every part of
    that design &mdash; 2&ndash;3 ms attack, contact tick 55 % quieter and lower, upper partials pulled
    back, two-pole roll-off at 5.5 kHz, &minus;6 / 0 / &minus;4 dB arch, peak &minus;3 dBFS &mdash; and move
    only the notes (A4&ndash;B5 down to C4&ndash;D5) and the spacing (80 ms, so each note has room).
  </div>

  <div class="spec">
    <b>Damping is the edges, not the gesture:</b> the three takes below are the even-step B6 and D7
    with a 2&ndash;3 ms attack instead of 0.8, a contact tick 55 % quieter and lower, the 2nd and
    3rd partials pulled back, and a two-pole roll-off above 5.5 kHz (3.8 kHz on the last one).
    Notes, levels, 48 ms spacing and 172 ms length are untouched.
  </div>

  <div class="spec">
    <b>Even steps:</b> the ramp was +7 semitones and then +14 &mdash; it accelerated, which is
    what makes the last step feel like a jump rather than the top of a climb. The top three put
    an equal interval between every pair (10.5, 12, 12 semitones), so the gesture rises at one
    rate, and the level arch and spacing are still `notify-arch3-soft`'s.
  </div>

  <div class="spec">
    <b>Only the last note moved:</b> the three below are `notify-arch3-soft` exactly &mdash; same
    three ticks, same &minus;6 / 0 / &minus;4 dB arch, same 48 ms spacing &mdash; with the third note
    raised from 1318 Hz to 1760, 1976 or 2349 Hz. A fourth, a fifth, or the whole top octave.
  </div>

  <div class="spec">
    <b>Three steps, not two:</b> the arch used to put its first note at &minus;16 dB, which is
    quiet enough that only the loud middle and the top arrived &mdash; two steps. In the three
    takes below it the spread is 6, 9 or 12 dB instead, so the first note is a real step, while
    the level still swells in the middle and eases at the top.
  </div>

  <div class="spec">
    <b>Only the notes moved:</b> the five arch takes are the same ticks as before &mdash; same
    partials, same contact transients, same 40 ms spacing, same 155 ms, peak &minus;3 dBFS,
    same &minus;16 / 0 / &minus;12 dB arch across the levels. The only difference between them
    is which three notes are played, so the gesture starts low and finishes on its highest
    note. The level-shaped steps below are untouched for comparison.
  </div>

  <p class="all"><button id="play-all">Play all in order</button></p>
__SECTIONS__

  <p class="hint">Files: <code>~/.config/quickshell/ii/assets/sounds/notify/&lt;name&gt;.wav</code>
  &mdash; 48 kHz, 16-bit, peak &minus;3 dBFS. Rebuild with <code>generate.py</code>.</p>
</main>
<script>
  const players = {};
  document.querySelectorAll('.card').forEach(card => {
    const audio = card.querySelector('audio');
    players[card.dataset.slug] = audio;
    card.querySelector('.play').addEventListener('click', () => {
      Object.values(players).forEach(a => { a.pause(); a.currentTime = 0; });
      audio.play();
    });
  });
  document.getElementById('play-all').addEventListener('click', async () => {
    for (const slug of Object.keys(players)) {
      const audio = players[slug];
      audio.currentTime = 0;
      try { await audio.play(); } catch (e) {}
      await new Promise(r => setTimeout(r, __DELAY__));
    }
  });
</script>
</body>
</html>
""".replace("__SECTIONS__", "\n".join(sections)).replace("__DELAY__", "1100")

if __name__ == "__main__":
    main()
