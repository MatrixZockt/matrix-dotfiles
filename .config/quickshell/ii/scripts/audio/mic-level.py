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

def main() -> int:
    # --latency-msec is not optional here. Without it parec's own default
    # buffering swallowed the first seconds, so the bar stayed dead while the
    # user was already talking.
    command = ["parec", "--format=s16le", f"--rate={RATE}", "--channels=1",
               "--raw", "--latency-msec=20"]
    if len(sys.argv) > 1 and sys.argv[1]:
        command.append(f"--device={sys.argv[1]}")
    record = subprocess.Popen(command, stdout=subprocess.PIPE, bufsize=0)
    try:
        while True:
            data = record.stdout.read(CHUNK_SAMPLES * 2)
            if not data:
                return 0
            if len(data) % 2:
                data = data[:-1]
            samples = struct.unpack(f"<{len(data) // 2}h", data)
            if not samples:
                continue
            rms = (sum(sample * sample for sample in samples) / len(samples)) ** 0.5 / 32768.0
            level = min(1.0, (rms / 0.12) ** 0.6)
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
