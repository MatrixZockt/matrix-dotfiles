#!/usr/bin/env python3
"""Was the dictation actually typed into the focused window?

Three screenshots of the same window: two taken just BEFORE the text is sent,
one after. Anything that differs between the two "before" frames is animation --
a streaming chat reply, a spinner, a blinking caret -- and is ignored. A pixel
that was perfectly still before and changed afterwards is the text arriving.

The changed area then has to look like a line of text: WIDE (a caret or a clock
digit is not) and a small part of the window (a video or a theme change is not a
paste). If it does, the delivery landed and no transcript card is needed.

TWO PLACES ARE LOOKED AT, IN ORDER. The bottom band of the window is where every
chat app on this desktop puts its composer, and the frames used to be cropped to
it for that reason. But a text box is not always down there: a browser's address
bar, a search field at the top of a page, a form in a dialog -- a dictation that
landed in one of those changed nothing in the band, so the check said
"nothing-new" and a card was raised over a sentence that was right there. So the
whole window is captured now and the band is checked first; only when the band
has not changed AT ALL is the rest of the window examined, with the same rules
plus a one-line height, because the shape of "text went into a field up there"
is a single lit row of glyphs, not a paragraph.

Frames are PPM, not PNG: at full window size grim writes PPM in ~60ms where PNG
takes ~350ms to compress, and these are read once and thrown away.

Prints one line: "landed" or "not-landed <reason>", which the caller logs.
"landed-upper" means it was found above the band; the caller's glob matches it
the same way.

Downscaled to half before comparing: text at half size is still a wide band, and
millions of pixels per frame three times over would make a dictation feel
sluggish for no gain.
"""
import subprocess
import sys

THRESHOLD = 18          # 0-255, per channel: "this pixel changed"
STABLE = 10             # a pixel that moves less than this in the before pair
MIN_WIDTH = 45          # half-res px, so 90 logical: a phrase, plainly
# A ONE-WORD DICTATION IS STILL A DICTATION. A single word inks far less than 90
# logical px, so "yes" and "thanks" used to raise a card over text that was
# sitting right there in the box. A narrow change is accepted only when it is
# dense enough to be a word and not a light: a caret or one clock digit inks one
# or two pixels per row, a word inks a solid run of them.
# Measured on a synthesised composer band at 20px: "yes" 16x7 with a 12px densest
# row, "thanks" 32x7 at 26, one clock digit 6x7 at 5, two digits 20x7 at 12 (and
# that one still fails the ink test below). A composer band has no clock in it
# anyway; what it does have is a caret, 2px wide, caught by all of these floors.
MIN_WIDTH_NARROW = 14
MIN_ROW_NARROW = 9      # densest row, half-res px of ink
MIN_CHANGED_NARROW = 40
MIN_HEIGHT = 2
MIN_CHANGED = 40        # pixels: a few scattered specks are noise, not a line
MIN_ROW = 6             # the busiest single row: real text inks a row heavily,
                        # while a stray antialiasing flicker leaves one dot per row
MAX_INK_FRAC = 0.5      # text inks part of its box, not all of it
# NOT a limit on how much of the BAND may change. That was the rule here, at
# 40%, and it was measured rejecting real dictations: a prompt box that already
# held a line reflows and repaints most of the band when a sentence is pasted
# into it (measured: 69% of the band, one wide dense row band -- a paste that
# landed, read as a miss, and a card shown over a sentence that was right there).
# Whether a change is text is a question about its DENSITY, not its extent: a
# line of text inks a fraction of the box it spans, while a theme switch, a dark
# overlay or a video frame fills its box almost solid.
BAND_TALL_MAX = 90      # half-res px: a composer can be tall, a paragraph is not
ABOVE_TALL_MAX = 30     # half-res px: above the band, only ONE line of text
                        # counts -- a message list streaming a reply must not be
                        # read as the paste arriving somewhere else


def load(path):
    """Half-size RGB bytes of one frame, plus its size."""
    dims = subprocess.run(["identify", "-format", "%w %h", path],
                          capture_output=True, text=True).stdout.split()
    if len(dims) != 2:
        raise SystemExit("not-landed unreadable-frame")
    w, h = int(dims[0]), int(dims[1])
    raw = subprocess.run(["magick", path, "-filter", "point", "-resize", "50%",
                          "-depth", "8", "rgb:-"], capture_output=True).stdout
    iw, ih = (w + 1) // 2, (h + 1) // 2
    if len(raw) != iw * ih * 3:
        raise SystemExit("not-landed unreadable-frame")
    return raw, iw, ih


def scan(frames, y_from, y_to):
    """Compare one horizontal slice of the three frames."""
    before_a, before_b, after, iw, ih = frames
    changed = 0
    animated = 0
    rows = {}
    min_x, min_y, max_x, max_y = iw, ih, -1, -1
    for y in range(y_from, y_to):
        base = y * iw * 3
        for x in range(iw):
            o = base + x * 3
            a0, a1, a2 = before_a[o], before_a[o + 1], before_a[o + 2]
            b0, b1, b2 = before_b[o], before_b[o + 1], before_b[o + 2]
            if (abs(a0 - b0) > STABLE or abs(a1 - b1) > STABLE or abs(a2 - b2) > STABLE):
                animated += 1      # this pixel moves on its own; it proves nothing
                continue
            c0, c1, c2 = after[o], after[o + 1], after[o + 2]
            if (abs(b0 - c0) > THRESHOLD or abs(b1 - c1) > THRESHOLD
                    or abs(b2 - c2) > THRESHOLD):
                changed += 1
                rows[y] = rows.get(y, 0) + 1
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y
    return {
        "changed": changed,
        "animated": animated,
        "densest": max(rows.values()) if rows else 0,
        "w": max_x - min_x + 1,
        "h": max_y - min_y + 1,
        "area": (max_x - min_x + 1) * (max_y - min_y + 1),
        "region": iw * max(1, y_to - y_from),
        "region_w": iw,
        "region_h": max(1, y_to - y_from),
    }


def judge(st, tall_max):
    """Does this change look like a line of text arriving?"""
    if st["changed"] == 0:
        return False
    wide = st["w"] >= MIN_WIDTH
    wordlike = (st["w"] >= MIN_WIDTH_NARROW and st["densest"] >= MIN_ROW_NARROW
                and st["changed"] >= MIN_CHANGED_NARROW)
    return (st["changed"] >= MIN_CHANGED and st["densest"] >= MIN_ROW
            and (wide or wordlike) and MIN_HEIGHT <= st["h"] <= tall_max
            and st["changed"] <= MAX_INK_FRAC * st["area"])


def verdict(prefix, st):
    print("%s changed=%d densest=%d box=%dx%d area=%d%% region=%dx%d animated=%d"
          % (prefix, st["changed"], st["densest"], st["w"], st["h"],
             100 * st["area"] // max(1, st["region"]),
             st["region_w"], st["region_h"], st["animated"]))


def main():
    if len(sys.argv) < 4:
        raise SystemExit("not-landed usage")
    # The band as a fraction of the window comes from the caller, which owns the
    # rule (band = 16% of the height, at least 120px). One source of truth.
    band_frac = float(sys.argv[4]) if len(sys.argv) > 4 else 0.16

    before_a, iw, ih = load(sys.argv[1])
    before_b, iw_b, ih_b = load(sys.argv[2])
    after, iw_c, ih_c = load(sys.argv[3])
    if (iw, ih) != (iw_b, ih_b) or (iw, ih) != (iw_c, ih_c):
        raise SystemExit("not-landed window-resized")
    frames = (before_a, before_b, after, iw, ih)

    band_h = max(1, min(ih, int(round(ih * band_frac))))
    band_top = ih - band_h

    band = scan(frames, band_top, ih)
    if band["changed"] > 0:
        verdict("landed" if judge(band, BAND_TALL_MAX) else "not-landed", band)
        return 0

    # Nothing at all moved in the composer band. Either the dictation went
    # nowhere, or it went into a field somewhere else in the window -- which is
    # the case the band alone could never see.
    if band_top > 0:
        above = scan(frames, 0, band_top)
        if above["changed"] > 0:
            verdict("landed-upper" if judge(above, ABOVE_TALL_MAX) else "not-landed-above",
                    above)
            return 0
        if above["animated"] == 0:
            print("not-landed nothing-new")
            return 0
    print("not-landed nothing-new")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        print("not-landed helper-error")
