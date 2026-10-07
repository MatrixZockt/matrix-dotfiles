#!/usr/bin/env python3
"""Read the icon names a Material Symbols font actually supports.

The shell asks the font for icons by the *name* of the glyph -- `text: "memory"`,
`text: "progress_activity"` -- which works because the font carries those names
as ligatures: the letter sequence is substituted for one glyph by the shaper.

That also means a name the font does not have is not an error anywhere. Qt draws
the letters, so a button ends up with the word "ram" where an icon was meant, and
the only way to notice is to look at that button. This is what makes it findable
without looking: it reads the GSUB ligature table (features liga/rlig/clig/dlig/
rclt, reached through extension lookups) straight out of the TTF and hands back
the real list.

No dependencies, deliberately: fontTools is not installed here, and a diagnostic
that needs a package installed before it can tell you what is broken is a
diagnostic that never runs.
"""

import struct
from pathlib import Path

# The variable font the shell's MaterialSymbol widget asks for. Rounded, because
# that is what Appearance.font.family.icon resolves to on this machine -- and the
# three axes (FILL, GRAD, opsz) do not change which names exist.
FONT = Path("/usr/share/fonts/ttf-material-symbols-variable/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf")

# Features that carry name-to-glyph substitutions. `rclt` is the one Material
# Symbols actually uses for its ligatures.
LIGATURE_FEATURES = {"liga", "rlig", "clig", "dlig", "rclt"}


def _u16(data, offset):
    return struct.unpack_from(">H", data, offset)[0]


def _u32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def _tables(data):
    out = {}
    for i in range(_u16(data, 4)):
        offset = 12 + i * 16
        tag = data[offset:offset + 4].decode("latin1")
        out[tag] = (_u32(data, offset + 8), _u32(data, offset + 12))
    return out


def _cmap_subtable(data, sub, mapping):
    fmt = _u16(data, sub)
    if fmt == 4:
        segx2 = _u16(data, sub + 6)
        seg = segx2 // 2
        ends, starts = sub + 14, sub + 14 + segx2 + 2
        deltas, ranges = starts + segx2, starts + segx2 + segx2
        for s in range(seg):
            end = _u16(data, ends + s * 2)
            start = _u16(data, starts + s * 2)
            if start == 0xFFFF:
                continue
            delta = struct.unpack_from(">h", data, deltas + s * 2)[0]
            ro = _u16(data, ranges + s * 2)
            for c in range(start, min(end, 0xFFFF) + 1):
                if ro == 0:
                    gid = (c + delta) & 0xFFFF
                else:
                    gid = _u16(data, ranges + s * 2 + ro + (c - start) * 2)
                    gid = (gid + delta) & 0xFFFF if gid else 0
                if gid:
                    mapping.setdefault(gid, chr(c))
    elif fmt == 12:
        for g in range(_u32(data, sub + 12)):
            o = sub + 16 + g * 12
            start, end, gid = _u32(data, o), _u32(data, o + 4), _u32(data, o + 8)
            for c in range(start, min(end, start + 8192) + 1):
                mapping.setdefault(gid + (c - start), chr(c))
    elif fmt == 6:
        first, count = _u16(data, sub + 6), _u16(data, sub + 8)
        for i in range(count):
            gid = _u16(data, sub + 10 + i * 2)
            if gid:
                mapping.setdefault(gid, chr(first + i))


def _cmap(data, offset):
    """glyph id -> character, the union of every Unicode subtable."""
    mapping = {}
    for i in range(_u16(data, offset + 2)):
        record = offset + 4 + i * 8
        platform = _u16(data, record)
        if platform not in (0, 3):
            continue
        _cmap_subtable(data, offset + _u32(data, record + 4), mapping)
    return mapping


def _feature_lookups(data, offset):
    out = set()
    flist = offset + _u16(data, offset + 6)
    for i in range(_u16(data, flist)):
        record = flist + 2 + i * 6
        if data[record:record + 4].decode("latin1") in LIGATURE_FEATURES:
            feature = flist + _u16(data, record + 4)
            for j in range(_u16(data, feature + 2)):
                out.add(_u16(data, feature + 4 + j * 2))
    return out


def _coverage_glyphs(data, coverage):
    fmt = _u16(data, coverage)
    if fmt == 1:
        return [_u16(data, coverage + 4 + i * 2) for i in range(_u16(data, coverage + 2))]
    if fmt == 2:
        out = []
        for i in range(_u16(data, coverage + 2)):
            o = coverage + 4 + i * 6
            out.extend(range(_u16(data, o), _u16(data, o + 2) + 1))
        return out
    return []


def _ligature_sequences(data, sub):
    if _u16(data, sub) != 1:
        return []
    coverage = sub + _u16(data, sub + 2)
    glyphs = _coverage_glyphs(data, coverage)
    out = []
    count = _u16(data, sub + 4)
    for i in range(min(count, len(glyphs))):
        # Offsets are from the start of the subtable, not from the set list.
        lset = sub + _u16(data, sub + 6 + i * 2)
        for k in range(_u16(data, lset)):
            ligature = lset + _u16(data, lset + 2 + k * 2)
            components = _u16(data, ligature + 2)
            # The number of glyphs in the sequence is one more than the number of
            # components, and icon names are long: `signal_wifi_statusbar_not_
            # connected` is a 36 glyph sequence. Capping this at a "sane" 16 (as
            # this did) silently loses every name longer than fifteen characters,
            # which is exactly the bug this file exists to find -- it reported
            # `progress_activity` as missing and a whole class of long names with
            # it, all of which the font renders perfectly well. The cap is only
            # there to reject nonsense values from a misread table.
            if not 1 <= components <= 64:
                continue
            out.append(tuple([glyphs[i]] + [_u16(data, ligature + 4 + j * 2) for j in range(components - 1)]))
    return out


def ligature_names(path=FONT):
    """Every name the font maps to a single glyph, spelled the way QML spells it.

    Lower case: the font stores the names in upper case (ADD_COLUMN_RIGHT) and
    the shaper matches case-insensitively, so the shell writes them lower case.
    """
    try:
        data = path.read_bytes()
    except OSError:
        return set()

    tables = _tables(data)
    if "cmap" not in tables or "GSUB" not in tables:
        return set()
    cmap = _cmap(data, tables["cmap"][0])

    offset = tables["GSUB"][0]
    lookups_off = offset + _u16(data, offset + 8)
    sequences = []
    for index in sorted(_feature_lookups(data, offset)):
        if index >= _u16(data, lookups_off):
            continue
        lookup = lookups_off + _u16(data, lookups_off + 2 + index * 2)
        subtables = []
        for i in range(_u16(data, lookup + 4)):
            sub = lookup + _u16(data, lookup + 6 + i * 2)
            if _u16(data, lookup) == 7:            # extension: unwrap the real lookup
                if _u16(data, sub + 2) == 4:
                    subtables.append(sub + _u32(data, sub + 4))
            elif _u16(data, lookup) == 4:
                subtables.append(sub)
        for sub in subtables:
            sequences.extend(_ligature_sequences(data, sub))

    names = set()
    for sequence in sequences:
        text = "".join(cmap.get(glyph, "\ufffd") for glyph in sequence)
        if "\ufffd" not in text:
            names.add(text.lower())
    return names


if __name__ == "__main__":
    names = ligature_names()
    print(f"{len(names)} icon names")
    for name in sorted(names)[:20]:
        print(" ", name)
