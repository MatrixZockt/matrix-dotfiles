#!/usr/bin/env python3
"""Print the microphone's loudness, one number per line, 0.000 to 1.000.

The sound panel draws this as a bar under the microphone heading so the user
can see that the mic hears them. Pipewire exposes no peak value to Quickshell,
so the level is measured here: `parec` records the source as raw 16-bit mono
and every 100ms chunk is reduced to an RMS value. Two things matter for the
bar to feel alive rather than twitchy:

  - the curve, not the raw RMS. Speech sits around 0.01-0.05 RMS, which on a
    linear bar would only ever fill the first tenth; the exponent lifts quiet
    speech into the middle of the bar while a loud "pop" still reaches the top.
  - a fresh line every 100ms, flushed. QML reads stdout line by line and a
    buffered pipe would arrive in bursts.
"""
import struct
import subprocess
import sys

RATE = 16000
CHUNK_SAMPLES = RATE // 10  # 100ms

# What "loud" means for the bar. Speech RMS sits around 0.02-0.08; room noise
# (a fan, a laptop mic's self-noise) around 0.002-0.01. The floor drops that
# noise to nothing instead of letting it paint a permanent bar, and the span is
# wide enough that normal talking lands mid-bar rather than slamming into the
# end -- the previous 0.12 span made every syllable hit 100%, which read as
# glitching rather than as loudness.
NOISE_FLOOR = 0.022
LOUD_RMS = 0.30
CURVE = 0.85

# One value per 100ms still jumps: a chunk that ends mid-syllable reads far
# louder than the one before it. The displayed value follows the loudness with
# a fast attack and a slow release, which is how a physical meter behaves --
# it catches the start of a word and then eases down instead of flickering.
ATTACK = 0.55
RELEASE = 0.18

def main() -> int:
    # --latency-msec is not optional here. Without it parec's own default
    # buffering swallowed the first seconds, so the bar stayed dead while the
    # user was already talking.
    command = ["parec", "--format=s16le", f"--rate={RATE}", "--channels=1",
               "--raw", "--latency-msec=20"]
    if len(sys.argv) > 1 and sys.argv[1]:
        command.append(f"--device={sys.argv[1]}")
    record = subprocess.Popen(command, stdout=subprocess.PIPE, bufsize=0)
    smoothed = 0.0
    try:
        while True:
            # Read a WHOLE chunk before measuring. A pipe read can return half a
            # chunk, and computing the level from those few milliseconds made it
            # jump around for reasons that had nothing to do with the voice --
            # that was the glitch.
            buffer = b""
            while len(buffer) < CHUNK_SAMPLES * 2:
                piece = record.stdout.read(CHUNK_SAMPLES * 2 - len(buffer))
                if not piece:
                    return 0
                buffer += piece
            samples = struct.unpack(f"<{CHUNK_SAMPLES}h", buffer)
            rms = (sum(sample * sample for sample in samples) / CHUNK_SAMPLES) ** 0.5 / 32768.0
            loudness = max(0.0, rms - NOISE_FLOOR) / LOUD_RMS
            target = min(1.0, loudness ** CURVE)
            factor = ATTACK if target > smoothed else RELEASE
            smoothed += (target - smoothed) * factor
            level = smoothed
            try:
                sys.stdout.write(f"{level:.3f}\n")
                sys.stdout.flush()
            except (BrokenPipeError, OSError):
                # The panel closed and the reader went away; that is the normal
                # way this ends, not an error worth a traceback.
                return 0
    finally:
        record.terminate()

if __name__ == "__main__":
    raise SystemExit(main())
