#!/usr/bin/env python3
"""Remove a dictation transcript file -- but only the one the card showed.

The transcript card polls transcript.json while it is up and deletes it when it
goes. That delete used to be a blind `rm -f`, which raced the next dictation:
dictation B writes its transcript, card A's countdown ends a moment later, and
the rm took B's sentence away before the 250 ms poll had ever read it -- a
dictation that went nowhere, with no card and nothing on screen to say so.

The timestamp decides: the file is removed only if it still holds the sentence
the card was showing. Anything newer belongs to a dictation that has not been
shown yet and is left for the poller.

Usage: transcript-wipe.py PATH STAMP
Exit codes: 0 in every normal case, 2 on a malformed call.
"""
import json
import os
import sys


def main(argv):
    if len(argv) < 3:
        return 2
    path = argv[1]
    try:
        want = float(argv[2])
    except ValueError:
        return 2
    try:
        with open(path) as f:
            stamp = float(json.load(f).get("ts", 0))
    except Exception:
        # Gone already, mid-rename, or not ours: nothing to do.
        return 0
    # A millisecond of slack covers JSON/QML float round-tripping and is far
    # shorter than the gap between two dictations.
    if abs(stamp - want) > 0.001:
        return 0
    try:
        os.remove(path)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
