#!/usr/bin/env python3
"""Silence one app's own notification sound, briefly.

Why this exists
---------------
The desktop cannot reach into a running program to stop audio it plays
itself, and the freedesktop notification hints are not where that sound lives
either (this shell never plays a sender's `sound-file`, deliberately: one
chime, everywhere). What IS reachable is the app's AUDIO: PipeWire gives every
playing program a stream, and a stream can be muted and put back.

So when a notification arrives from an app whose own sound is switched off,
this mutes that app's streams for a moment and then restores them. The window
is short because the sound is: a notification chime is a fraction of a second,
and muting an app's audio for longer than that would take its music, call or
video with it.

Only the app's OWN streams are touched -- matched from its display name, its
desktop-file id and its icon name against the stream's application properties
-- and only streams that were not already muted, so a mute the user set in the
mixer is never undone here.

Usage: silence-app-notification-sound.py SECONDS IDENTITY [IDENTITY...]
Exit: 0 if at least one stream was muted, 1 if nothing matched.
"""

import json
import re
import select
import subprocess
import sys
import time

# Words that appear in half the streams on a desktop; matching on them would
# mute the wrong app the first time a program is called "... Desktop".
GENERIC = {
    "desktop", "linux", "app", "apps", "application", "client", "media",
    "core", "stable", "community", "com", "org", "net", "io", "the",
}

STREAM_KEYS = (
    "application.name",
    "application.process.binary",
    "application.process.name",
    "application.desktop",
    "application.id",
    "node.name",
)


def normalize(value):
    """The same reduction NotificationUtils.normalizeAppIdentity does."""
    text = str(value or "")
    if "/" in text:
        text = text.rsplit("/", 1)[-1]
    text = re.sub(r"\.desktop$", "", text, flags=re.I)
    text = re.sub(r"\.(png|svg|xpm|ico|jpe?g|gif)$", "", text, flags=re.I)
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def words(value):
    return [w for w in normalize(value).split() if len(w) >= 3 and w not in GENERIC]


def wanted(argv):
    out = set()
    for arg in argv:
        out.update(words(arg))
    return out


def sink_inputs():
    try:
        raw = subprocess.run(
            ["pactl", "-f", "json", "list", "sink-inputs"],
            capture_output=True, text=True,
        ).stdout
        return json.loads(raw) if raw.strip() else []
    except (OSError, ValueError):
        return []


def owned_words(stream):
    props = stream.get("properties") or {}
    return set(words(" ".join(str(props.get(key, "")) for key in STREAM_KEYS)))


def set_mute(index, muted):
    subprocess.run(
        ["pactl", "set-sink-input-mute", str(index), "1" if muted else "0"],
        capture_output=True,
    )


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    try:
        window = float(sys.argv[1])
    except ValueError:
        window = 2.0
    want = wanted(sys.argv[2:])
    if not want:
        return 1

    ours = set()
    # Streams that were already muted BEFORE we did anything: that is the user's
    # mute in the mixer, and it must survive this untouched.
    user_muted = {s.get("index") for s in sink_inputs() if s.get("mute")}

    def consider(stream):
        index = stream.get("index")
        if index is None or index in ours:
            return
        if index in user_muted:
            return
        if not (owned_words(stream) & want):
            return
        if stream.get("mute"):
            # Muted, but not by the user and not before this run: PipeWire's
            # stream-restore hands an app's next stream the mute state of the
            # one before it, so a stream born during our window inherits OUR
            # mute. It is ours to undo.
            ours.add(index)
            return
        set_mute(index, True)
        ours.add(index)

    events = subprocess.Popen(
        ["pactl", "subscribe"], stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    try:
        # Subscribe first, sweep second: a sound that starts while the sweep is
        # running is caught by the event stream rather than falling between the
        # two.
        for stream in sink_inputs():
            consider(stream)

        deadline = time.monotonic() + window
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            ready, _, _ = select.select([events.stdout], [], [], left)
            if not ready:
                continue
            line = events.stdout.readline()
            match = re.search(r"Event 'new' on sink-input #(\d+)", line)
            if not match:
                continue
            index = int(match.group(1))
            for stream in sink_inputs():
                if stream.get("index") == index:
                    consider(stream)
                    break
    finally:
        events.terminate()
        try:
            events.wait(timeout=1)
        except subprocess.TimeoutExpired:
            events.kill()
        for index in ours:
            set_mute(index, False)

    if ours:
        print(f"silenced app sound on {len(ours)} stream(s): {sorted(ours)}")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
