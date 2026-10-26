#!/usr/bin/env python3
"""Check light mode's grey ladder -- the thing `MaterialThemeLoader` applies to
every light palette -- against every template, and against the running shell.

    check-light-ladder.py            check and print the report
    check-light-ladder.py --quiet    only print failures and the verdict

Exit status: 0 if everything holds, 1 otherwise. Uses the standard library
only, so it runs on the system python (`python3`), not the shell's venv.

WHAT IT IS CHECKING, AND WHY EACH ONE IS A REAL RISK

Light mode's palette is rewritten on the way in (services/MaterialThemeLoader
.qml, `applyLightGreyLadder`) because the light half of a monochrome template
was washing its contrast roles out to 1.05-1.28:1 against their own
background -- a toggled chip, a selected row and the RAM meter's accent all
drawn in a grey nobody could see. The ladder fixes that, and this file is what
stops the fix from quietly breaking something else:

  * The tables, the ink pairs and the grey/chroma line are READ OUT OF THE QML.
    A second copy here would be a second thing to keep in step, and the copy
    that drifted would be the one nobody runs.
  * GREY-ONLY. Eleven of the twelve templates are tinted, and their containers
    are not washed-out greys: catppuccin's `tertiary` is olive #7A7814 with
    white ink. An unconditional grey ladder does not fix those, it deletes the
    palette -- measured, the olive came out #666666 and its ink dropped to
    1.6:1. So a contrast role may only be touched when its chroma is at or
    below the line (0.05), and this asserts that the truly tinted ones were
    left exactly as the template author wrote them.
  * DARKER-NEVER-LIGHTER. Some templates are already darker than a ladder
    target (catppuccin's tertiaryContainer is 4.4:1 on its page; the raw target
    would have LIGHTENED it to 1.9:1, i.e. made the reported problem worse on a
    palette that did not have it).
  * INK STILL READS. Each contrast role carries somebody's ink -- the chip's
    label, the meter's number. Every pair must clear 4.5:1 after the move. The
    QML clamps to guarantee it; this is the independent measurement of the same
    claim, in different code.
  * THE LADDER IS ORDERED. Rungs that stop being ordered stop being a ladder:
    a "brightest surface" darker than the panel below it is a bug in the table,
    not a style.
  * THE TOGGLE STILL KNOWS WHERE IT IS. `identify-template.py` recognises the
    active template by the (primary, surface, onBackground) triple, and the
    dark/light toggle routes on that identification. Any ladder that moved one
    of those keys would make the toggle forget which template it is on, so
    this asserts none of them is in either table.
  * IT CANNOT DOUBLE-APPLY. Each entry is an absolute target and every move is
    `min(current, target)`, so the result of a second application must equal
    the first.

Finally, if the shell is running and currently in light mode, the values it
reports for itself (`qs -c ii ipc call theme state`) are compared against the
tables -- the live path, not a re-implementation of it. One level of slack per
channel, because Qt's HSV and this file's `colorsys` rounding disagree by one
on a few values.
"""

import argparse
import colorsys
import glob
import json
import os
import re
import subprocess
import sys

SHELL = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QML = os.path.join(SHELL, "services/MaterialThemeLoader.qml")
TEMPLATES = os.path.join(SHELL, "themes/templates")
CHROMA_LINE = 0.05   # must match isGrey() in the QML
INK_FLOOR = 4.5      # must match the clamp in the QML
LIVE_SLACK = 1       # Qt vs colorsys rounding, per channel


def table_from_qml(name):
    """One `readonly property var <name>: ({ ... })` out of the QML."""
    source = open(QML).read()
    match = re.search(rf"readonly property var {name}: \({{([^}}]*)\}}\)", source)
    if not match:
        sys.exit(f"check-light-ladder: could not find {name} in {QML}")
    entries = re.findall(r"(\w+):\s*(\"[^\"]*\"|[0-9.]+)", match.group(1))
    if not entries:
        sys.exit(f"check-light-ladder: {name} in the QML is empty")
    return {key: (value.strip('"') if value.startswith('"') else float(value))
            for key, value in entries}


# ── the same arithmetic the QML does, in different code ─────────────────────
def to_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def to_hex(rgb):
    return "#" + "".join(f"{max(0, min(255, round(c))):02X}" for c in rgb)


def chroma(value):
    r, g, b = to_rgb(value)
    return (max(r, g, b) - min(r, g, b)) / 255


def value_of(value):
    return max(to_rgb(value)) / 255


def shade(value, wanted):
    """Hue and saturation kept, value moved -- and never upwards.

    HSV and not HSL: HSL saturation is 1.0 for a near-white tint, so
    preserving it while darkening a surface AMPLIFIES the tint (catppuccin's
    #FFF7FE came out #FFF1FD), which is the opposite of cleaning it up.
    """
    r, g, b = [c / 255 for c in to_rgb(value)]
    h, s, current = colorsys.rgb_to_hsv(r, g, b)
    return to_hex(tuple(c * 255 for c in colorsys.hsv_to_rgb(h, s, min(current, wanted))))


def luminance(value):
    def channel(x):
        x /= 255
        return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
    r, g, b = to_rgb(value)
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def apply_ladder(palette, surface, contrast, inks):
    """Mirrors `applyLightGreyLadder`: greys only, darker only, ink-clamped."""
    out, touched = dict(palette), set()
    for role, target in surface.items():
        if role not in palette:
            continue
        out[role] = shade(palette[role], min(value_of(palette[role]), target))
        if out[role] != palette[role]:
            touched.add(role)
    for role, target in contrast.items():
        if role not in palette or chroma(palette[role]) > CHROMA_LINE:
            continue
        start = value_of(palette[role])
        wanted = min(start, target)
        ink = inks.get(role)
        value = wanted
        if ink and ink in palette:
            ink_rgb = to_rgb(palette[ink])
            for step in range(21):
                candidate = min(start, wanted + step * (start - wanted) / 20)
                if ratio(shade(palette[role], candidate), palette[ink]) >= INK_FLOOR:
                    value = candidate
                    break
        out[role] = shade(palette[role], value)
        if out[role] != palette[role]:
            touched.add(role)
    return out, touched


def check_templates(surface, contrast, inks, report):
    failures = []
    checked = 0
    ash = None
    for path in sorted(glob.glob(os.path.join(TEMPLATES, "*-light.json"))):
        name = os.path.basename(path)
        palette = json.load(open(path))
        checked += 1
        missing = [r for r in list(surface) + list(contrast) if r not in palette]
        if missing:
            failures.append(f"{name}: ladder roles absent from the palette: {missing}")
            continue
        if to_rgb(palette["background"])[0] < 128:
            failures.append(f"{name}: not a light palette (background {palette['background']})")
            continue
        after, touched = apply_ladder(palette, surface, contrast, inks)
        page = palette["background"]

        for role in touched:
            if value_of(after[role]) > value_of(palette[role]) + 1e-9:
                failures.append(f"{name}: {role} got LIGHTER ({palette[role]} -> {after[role]})")
        for role in contrast:
            if role in touched and chroma(palette[role]) > CHROMA_LINE:
                failures.append(f"{name}: touched the tinted {role} ({palette[role]}, "
                                f"chroma {chroma(palette[role]):.2f})")

        order = [r for r in ("surfaceBright", "surfaceContainerLowest", "surfaceContainerLow",
                             "surfaceContainer", "surfaceContainerHigh", "surfaceContainerHighest")
                 if r in touched]
        values = [value_of(after[r]) for r in order]
        if values != sorted(values, reverse=True):
            failures.append(f"{name}: surface ladder out of order by value: "
                            + " ".join(f"{r}={after[r]}" for r in order))
        for a, b in zip(order, order[1:]):
            # Only where the rungs are a real step apart: two rungs level with
            # each other cannot be ordered by relative luminance once one is
            # tinted (luminance weights green, so a neutral #F6F6F6 outranks a
            # pinkish #FFF1FD of the same value).
            if value_of(after[a]) - value_of(after[b]) <= 0.02:
                continue
            if luminance(after[b]) > luminance(after[a]):
                failures.append(f"{name}: {b} ({after[b]}) is brighter than {a} ({after[a]})")

        for role, floor in [("secondaryContainer", 2.0), ("tertiaryContainer", 1.5),
                            ("primaryContainer", 1.5), ("tertiary", 3.0), ("secondary", 3.0)]:
            if role in touched and ratio(after[role], page) < floor:
                failures.append(f"{name}: {role} {after[role]} is {ratio(after[role], page):.2f}:1 "
                                f"on the page (want >= {floor})")

        for fill, ink in inks.items():
            if ink not in palette:
                continue
            got = ratio(palette[ink], after[fill])
            if got < INK_FLOOR:
                if fill in touched:
                    failures.append(f"{name}: {ink} {palette[ink]} on the ladder's "
                                    f"{after[fill]} is {got:.2f}:1")
                else:
                    report(f"  note  {name}: {ink} on {fill} was already {got:.2f}:1; "
                           f"the ladder left it alone")
        for ink in ("onSurface", "onSurfaceVariant"):
            if ink in palette:
                deepest = after["surfaceContainerHighest"]
                if ratio(palette[ink], deepest) < INK_FLOOR:
                    failures.append(f"{name}: {ink} on the deepest container {deepest} "
                                    f"is {ratio(palette[ink], deepest):.2f}:1")
        if ratio(after["outline"], page) < 4.0:
            failures.append(f"{name}: outline {after['outline']} is "
                            f"{ratio(after['outline'], page):.2f}:1 on the page")
        if not luminance(after["outlineVariant"]) > luminance(after["outline"]):
            failures.append(f"{name}: outline ({after['outline']}) is not darker than "
                            f"outlineVariant ({after['outlineVariant']})")
        for key in ("primary", "surface", "onBackground"):
            if key in surface or key in contrast:
                failures.append(f"{name}: the ladder moves {key}, which identifies the template")
        if apply_ladder(after, surface, contrast, inks)[0] != after:
            failures.append(f"{name}: the ladder is not idempotent")
        if name == "ash-light.json":
            ash = (palette, after)
    if ash:
        before, after = ash
        report("")
        report("ash-light -- the template on this machine. before -> after, vs the page:")
        for role in list(surface) + list(contrast):
            mark = "  *" if before[role] != after[role] else ""
            report(f"  {role:23s} {before[role]} -> {after[role]}   "
                   f"{ratio(before[role], before['background']):5.2f}:1 -> "
                   f"{ratio(after[role], before['background']):5.2f}:1{mark}")
    return failures, checked


def check_live(surface, contrast, inks):
    """Compare the running shell's own report against the tables.

    The palette the shell is showing must be the ladder applied to whatever
    colors.json holds -- a template light palette, or a wallpaper-generated one
    -- which is the whole claim of the feature, measured through the shell's
    own report rather than through this file's copy of the arithmetic.
    """
    try:
        out = subprocess.run(["qs", "-c", "ii", "ipc", "call", "theme", "state"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None, "the shell is not answering, so the live palette was not compared"
    if "mode=" not in out:
        return None, "the shell's theme target does not report a palette"
    fields = dict(part.split("=", 1) for part in out.split() if "=" in part)
    if fields.get("mode") != "light":
        return None, (f"the shell is in {fields.get('mode')} mode, so there is no live "
                      f"light palette to compare (toggle to light and rerun)")
    colors_path = os.path.expanduser("~/.local/state/quickshell/user/generated/colors.json")
    try:
        base = json.load(open(colors_path))
    except (OSError, ValueError) as error:
        return None, f"could not read {colors_path}: {error}"
    expected, _ = apply_ladder(base, surface, contrast, inks)
    failures = []
    for role in list(surface) + list(contrast):
        live = fields.get(role)
        if live is None:
            failures.append(f"live: the shell does not report {role}")
            continue
        if not close_enough(live, expected[role], LIVE_SLACK):
            failures.append(f"live: {role} is {live} in the shell but the table gives "
                            f"{expected[role]} for {os.path.basename(colors_path)}")
    return failures, ""


def close_enough(a, b, slack):
    return all(abs(x - y) <= slack for x, y in zip(to_rgb(a), to_rgb(b)))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--quiet", action="store_true", help="only failures and the verdict")
    args = parser.parse_args()

    def report(line=""):
        if not args.quiet:
            print(line)

    surface = table_from_qml("lightSurfaceLadder")
    contrast = table_from_qml("lightContrastLadder")
    inks = table_from_qml("lightLadderInks")
    report(f"tables read from the QML: {len(surface)} structural roles, "
           f"{len(contrast)} contrast roles, {len(inks)} ink pairs; "
           f"chroma line {CHROMA_LINE}, ink floor {INK_FLOOR}:1")

    failures, checked = check_templates(surface, contrast, inks, report)
    report(f"\n{checked} light palettes checked")

    live_failures, note = check_live(surface, contrast, inks)
    if live_failures is None:
        report(f"live palette: not compared -- {note}")
    else:
        failures += live_failures
        report("live palette: the shell's own report matches the tables" if not live_failures
               else f"live palette: {len(live_failures)} mismatch(es)")

    if failures:
        print(f"\n{len(failures)} FAILURE(S):")
        for line in failures:
            print("  FAIL " + line)
        return 1
    print("check-light-ladder: all light palettes hold -- grey-only, darker-never-lighter, "
          "ink >= 4.5:1, ordered rungs, identification signature untouched, idempotent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
