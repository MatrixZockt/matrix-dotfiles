#!/usr/bin/env python3
"""Derive the desktop's device sounds from a recording of a single click.

WHY THIS EXISTS.  The two sounds this desktop plays when a drive goes in or out
used to be synthesised (scripts/system/make-device-sounds.py). They are now cut
from a recording instead, because the sound wanted was a specific one: the
momentary click a console makes, which no synthesiser here reproduced to taste.

WHERE THE SOURCE COMES FROM.  A file supplied by whoever runs this -- it is NOT
in the repository and is not downloaded by this script.  Point it at a recording
and it finds the click, trims the room tail off the end, normalises the level,
and writes the pair.  The remove sound is the SAME samples played backwards, so
the two are guaranteed to be the same gesture in opposite directions.

WHAT IT HAS TO DECIDE, AND HOW:

  where the click starts   the global peak is the impact; step back from it
                           until the signal falls below 5% of that peak -- on a
                           1 ms PEAK ENVELOPE, not on the samples themselves,
                           because a waveform crosses zero every fraction of a
                           millisecond and stepping back through raw samples
                           stops at the first crossing inside the click.
  how much tail to keep    `--length` (default 200 ms). The recording's own tail
                           runs on for roughly half a second at -30 dB and
                           lower, which is room, not click: kept in full it
                           makes a device event sound like it is being played
                           in a hall. A quarter of a second keeps the character
                           and drops the hall.
  how loud                 `--peak` (default -1 dBFS). REQUESTED 2026-10-11:
                           the click should be heard, and heard ABOVE the music
                           playing at the same moment. It was -6 dBFS, and two
                           things stacked on top of that: a click is 200 ms of
                           transient rather than a sustained tone, and it was
                           being spawned into the mixer at the sink's volume a
                           second time (see playSystemSoundFile in
                           services/Audio.qml -- since fixed). At -1 it peaks
                           just under full scale, which leaves 1 dB of headroom
                           for PipeWire's resampler and reads clearly above
                           music and the other chimes. `--peak 0` is the most
                           this can be pushed without clipping samples.

Usage:  scripts/system/import-device-sound.py <source-audio> [options]
        --out DIR      where to write (default <config>/assets/sounds)
        --length MS    how much of the sound to keep after the attack (200)
        --peak DBFS    peak level to normalise to (-1)
        --dry-run      report what it found, write nothing
"""

import array
import math
import os
import subprocess
import sys
import wave

SAMPLE_RATE = 44100
FADE_IN_MS = 2.0
FADE_OUT_MS = 20.0


def decode(path):
    """Any format ffmpeg reads -> mono float samples at SAMPLE_RATE."""
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SAMPLE_RATE),
         "-f", "s16le", "-"],
        capture_output=True)
    if proc.returncode != 0:
        raise SystemExit("ffmpeg could not read %s:\n%s"
                         % (path, proc.stderr.decode(errors="replace").strip()))
    pcm = array.array("h")
    pcm.frombytes(proc.stdout)
    return pcm


def find_click(samples):
    """Index of the impact: walk back from the loudest 1 ms to the noise floor."""
    win = int(0.001 * SAMPLE_RATE)
    buckets = max(1, len(samples) // win)
    env = [max(abs(v) for v in samples[i * win:(i + 1) * win]) for i in range(buckets)]
    peak_bucket = max(range(buckets), key=lambda i: env[i])
    floor = env[peak_bucket] * 0.05
    start_bucket = peak_bucket
    while start_bucket > 0 and env[start_bucket] > floor:
        start_bucket -= 1
    # One bucket of margin: the envelope's own 1 ms resolution, so the start
    # lands just before the rise rather than on it.
    peak_i = peak_bucket * win
    return max(0, (start_bucket - 1) * win), peak_i, env[peak_bucket]


def cut(samples, start, peak, length_ms, peak_dbfs):
    """Take `length_ms` from the attack, fade both ends, normalise."""
    total = int(length_ms / 1000.0 * SAMPLE_RATE)
    seg = [float(v) for v in samples[start:start + total]]
    if len(seg) < total:                     # ran off the end of the recording
        seg += [0.0] * (total - len(seg))

    fade_in = max(1, int(FADE_IN_MS / 1000.0 * SAMPLE_RATE))
    fade_out = min(max(1, int(FADE_OUT_MS / 1000.0 * SAMPLE_RATE)), total // 2)
    for i in range(min(fade_in, total)):
        seg[i] *= i / fade_in
    for i in range(fade_out):
        seg[total - 1 - i] *= i / fade_out

    scale = (10 ** (peak_dbfs / 20.0)) * 32768.0 / peak
    return array.array("h", [int(max(-32768, min(32767, v * scale))) for v in seg])


def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(samples.tobytes())


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__.strip())
        raise SystemExit(2 if args else 0)
    source = args[0]
    opts = {"--out": os.path.join(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))), "assets", "sounds"),
        "--length": "200", "--peak": "-1"}
    dry_run = "--dry-run" in args
    for i, a in enumerate(args):
        if a in opts and i + 1 < len(args):
            opts[a] = args[i + 1]
    if not os.path.isfile(source):
        raise SystemExit("no such source file: %s" % source)

    samples = decode(source)
    start, peak_i, peak = find_click(samples)
    print("source      %s" % source)
    print("            %d frames, %.3f s" % (len(samples), len(samples) / SAMPLE_RATE))
    print("attack      %.1f ms  (peak at %.1f ms, %.1f dBFS)"
          % (start / SAMPLE_RATE * 1000, peak_i / SAMPLE_RATE * 1000,
             20 * math.log10(peak / 32768.0)))
    if dry_run:
        return

    length = float(opts["--length"])
    level = float(opts["--peak"])
    inserts = cut(samples, start, peak, length, level)
    removes = array.array("h", list(reversed(inserts)))

    out = opts["--out"]
    os.makedirs(out, exist_ok=True)
    for name, data in (("device-insert.wav", inserts), ("device-remove.wav", removes)):
        path = os.path.join(out, name)
        write_wav(path, data)
        print("wrote       %s  %d frames  %.0f ms  peak %.1f dBFS  (synthesised "
              "click: 150 ms, -1 dBFS)"
              % (path, len(data), 1000 * len(data) / SAMPLE_RATE, level))


if __name__ == "__main__":
    main()
