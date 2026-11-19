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
import os
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
    "application.icon_name",
    "node.name",
)

# Where a run leaves its evidence. The app's identity in a notification and the
# identity it puts on its audio stream are two different strings, and when they
# do not meet nothing is muted and nothing is reported -- which is exactly the
# report this log exists to end (2026-11-19: "WhatsApp is marked sound off and I
# still hear its sound"). One line per run, no audio data, no secrets.
LOG_NAME = "ii-notification-silence.log"
LOG_MAX_BYTES = 256 * 1024


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


def proc_words(stream):
    """Words from the process that owns the stream, not from its own labels.

    Measured 2026-11-19 on this machine: a Chromium-family stream carries
    `application.process.id` alongside `application.name`, and Electron apps do
    NOT always put their own name in `application.name` -- WhatsApp reports
    itself as "Chromium" there. Matching only the text properties therefore
    missed it entirely. /proc is authoritative: the executable it points at is
    the app, whatever the stream decided to call itself.
    """
    props = stream.get("properties") or {}
    pid = props.get("application.process.id")
    out = set()
    if not pid:
        return out
    for path in (f"/proc/{pid}/comm", f"/proc/{pid}/cmdline"):
        try:
            with open(path, "rb") as handle:
                raw = handle.read(4096)
        except OSError:
            continue
        out.update(words(raw.replace(b"\0", b" ").decode("utf-8", "replace")))
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        exe = ""
    if exe:
        out.update(words(os.path.basename(exe)))
        out.update(words(os.path.dirname(exe)))
    return out


def owned_words(stream):
    props = stream.get("properties") or {}
    blob = " ".join(str(props.get(key, "")) for key in STREAM_KEYS)
    return set(words(blob)) | proc_words(stream)


def note(message):
    """Append one line to the run log; never fail the caller over it."""
    try:
        base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
        path = os.path.join(base, LOG_NAME)
        try:
            if os.path.getsize(path) > LOG_MAX_BYTES:
                os.replace(path, path + ".1")
        except OSError:
            pass
        with open(path, "a") as handle:
            handle.write(time.strftime("%H:%M:%S ") + message + "\n")
    except OSError:
        pass


def describe(stream):
    props = stream.get("properties") or {}
    return "#%s name=%r bin=%r pid=%s" % (
        stream.get("index"),
        props.get("application.name"),
        props.get("application.process.binary"),
        props.get("application.process.id"),
    )


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
        note("skip: no usable words in %r" % (sys.argv[2:],))
        return 1
    note("run window=%ss want=%s ids=%s" % (window, sorted(want), sys.argv[2:]))

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
        note("muted %s" % sorted(ours))
        return 0
    seen = [describe(stream) for stream in sink_inputs()]
    note("no match; streams seen: %s" % ("; ".join(seen) if seen else "none"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
