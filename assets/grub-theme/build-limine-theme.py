#!/usr/bin/env python3
"""Builds the Freebuff Limine boot-menu theme.

This machine boots with Limine 12.x (not GRUB), so the boot menu is themed in
limine.conf. Limine can also take its own font via `term_font`: a raw bitmap
font of 256 glyphs, 8 pixels wide, one byte per row, 16 bytes per glyph. Linux
console fonts are exactly that data behind a small header, which is why this
script reads one (default: LatArCyrHeb-16 -- a clean, slightly rounded 8x16).

Outputs, into ./theme/:
  limine-background.png   the boot wallpaper (near-black graphite field)
  limine-font.f16         the term_font file
  limine-theme.conf       the option block the installer merges into limine.conf
  limine-preview.png      a faithful render of the resulting menu

Palette: a single black-to-grey ramp. Nothing is tinted -- on a boot screen,
one accent colour is what makes a theme look cheap, and a pure grey ramp is
what reads as expensive.

Usage: python3 build-limine-theme.py [console-font.psf[.gz]]
"""
import gzip
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "theme")
os.makedirs(OUT, exist_ok=True)

FONT_SRC = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/kbd/consolefonts/LatArCyrHeb-16.psfu.gz"

# ── Palette ──────────────────────────────────────────────────────────────────
FIELD = (0x09, 0x09, 0x09)      # deepest field
LIFT = (0x13, 0x13, 0x13)       # the soft centre bloom
FRAME = (0x2b, 0x2b, 0x2b)      # hairline inset frame
TEXT = (0xE6, 0xE6, 0xE6)       # menu text
TEXT_DIM = (0xB4, 0xB4, 0xB4)   # unselected text
SEL_BG = (0x26, 0x26, 0x26)     # selected row bar
BRAND = (0xC9, 0xC9, 0xC9)      # branding
HELP = (0x8A, 0x8A, 0x8A)       # key hints
HELP_HI = (0xE8, 0xE8, 0xE8)    # countdown digit

FONT_W, FONT_H = 8, 16
SCALE = 2  # matches term_font_scale: 2x2 -- glyphs are 8x16 dots, drawn 16x32
W, H = 1920, 1080


# ── PNG writer (no dependencies) ─────────────────────────────────────────────
def write_png(path, w, h, get_px):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            r, g, b = get_px(x, y)
            raw += bytes((r, g, b))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def blend(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


# ── Console font -> Limine term_font ─────────────────────────────────────────
def read_console_font(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    if raw[:2] == b"\x36\x04":                      # PSF1
        mode, charsize = raw[2], raw[3]
        count, start = (512 if mode & 0x01 else 256), 4
        width, height = 8, charsize
    elif raw[:4] == b"\x72\xb5\x4a\x86":            # PSF2
        _, headersize, _, count, charsize, height, width = (
            int.from_bytes(raw[i:i + 4], "little") for i in range(4, 32, 4)
        )
        start = headersize
    else:
        raise SystemExit(f"{path}: not a PSF console font")
    if width != FONT_W:
        raise SystemExit(f"{path}: font is {width}px wide; Limine requires 8")
    glyphs = []
    for i in range(min(count, 256)):
        g = raw[start + i * charsize: start + (i + 1) * charsize]
        glyphs.append([g[r] if r < len(g) else 0 for r in range(height)])
    while len(glyphs) < 256:
        glyphs.append([0] * height)
    return glyphs, height, count


# ── 1. Wallpaper ─────────────────────────────────────────────────────────────
def bg_px(x, y):
    # A very quiet centre bloom -- enough to stop 1080p of pure black reading
    # as a dead panel, not enough to look like a gradient.
    dx = (x - W / 2) / (W / 2)
    dy = (y - H / 2) / (H / 2)
    d2 = min(1.0, dx * dx + dy * dy)
    t = (1.0 - d2) ** 1.6
    c = blend(FIELD, LIFT, t)
    # Ordered dither: 8-bit PNGs of near-black gradients band badly otherwise.
    bayer = ((x & 1) * 2 + (y & 1) + ((x >> 1) & 1) * 4 + ((y >> 1) & 1) * 8) / 16.0
    c = tuple(min(255, v + (1 if bayer > 0.5 else 0)) for v in c)
    # Hairline inset frame, 48px in -- a printed-page margin, nothing more.
    inset = 48
    if (x == inset or x == W - 1 - inset or y == inset or y == H - 1 - inset) and \
       inset <= x <= W - 1 - inset and inset <= y <= H - 1 - inset:
        c = FRAME
    return c


write_png(os.path.join(OUT, "limine-background.png"), W, H, bg_px)

# ── 2. Font ──────────────────────────────────────────────────────────────────
glyphs, fh, fcount = read_console_font(FONT_SRC)
font_bytes = bytearray()
for g in glyphs:
    font_bytes += bytes(g)
with open(os.path.join(OUT, "limine-font.f16"), "wb") as f:
    f.write(bytes(font_bytes))
print(f"font: {FONT_SRC} ({fcount} glyphs) -> theme/limine-font.f16")

# ── 3. Option block for limine.conf ──────────────────────────────────────────
HEX = lambda c: "%02X%02X%02X" % c
OPTIONS = f"""# ── Freebuff theme (managed by install-limine-theme.sh -- edit build-limine-theme.py) ──
wallpaper: boot():@REL@
wallpaper_style: stretched
backdrop: {HEX(FIELD)}
interface_branding: Freebuff OS
interface_branding_colour: {HEX(BRAND)}
interface_help_colour: {HEX(HELP)}
interface_help_colour_bright: {HEX(HELP_HI)}
term_font: boot():@FONT@
term_font_size: {FONT_W}x{FONT_H}
term_font_scale: {SCALE}x{SCALE}
term_font_spacing: 1
term_background: 00000000
term_background_bright: {HEX(SEL_BG)}
term_foreground: {HEX(TEXT)}
term_foreground_bright: FFFFFF
term_palette: {HEX(FIELD)};5F5F5F;7D7D7D;C9C9C9;383838;9E9E9E;BCBCBC;B4B4B4
term_palette_bright: 707070;DADADA;E6E6E6;FFFFFF;9A9A9A;F4F4F4;FAFAFA;FFFFFF
"""
with open(os.path.join(OUT, "limine-theme.conf"), "w") as f:
    f.write(OPTIONS)


# ── 4. Preview: the real wallpaper, the real font, the real palette ──────────
# Limine menu entries are `/` prefixed, one per level of nesting, and `+` marks
# a directory that starts expanded. The preview walks that tree exactly one
# level past the expanded roots -- anything deeper lives inside a collapsed
# directory on the real menu and would be a lie in the mock.
def boot_entries():
    for p in ("/boot/limine/limine.conf", "/boot/limine.conf", "/boot/EFI/limine/limine.conf",
              "/boot/EFI/LIMINE/limine.conf", "/boot/EFI/BOOT/limine.conf",
              "/tmp/limine.conf"):  # /boot is root-only; a copy here keeps the preview honest
        try:
            text = open(p).read()
        except OSError:
            continue
        rows = []
        for line in text.splitlines():
            # Entries are indented by depth, so the slashes only ever run at
            # the start of the *stripped* line, and their count is the depth.
            stripped = line.strip()
            if not stripped.startswith("/"):
                continue
            depth = len(stripped) - len(stripped.lstrip("/"))
            body = stripped[depth:]
            expanded = body.startswith("+")
            if expanded:
                body = body[1:]
            name = body.strip()
            if not name or name.startswith("#"):
                continue
            rows.append((depth, name, expanded))
        if not rows:
            continue
        out = []
        inside_expanded_dir = False
        for depth, name, expanded in rows:
            if depth == 1:
                out.append((depth, name, expanded))
                inside_expanded_dir = expanded
            elif depth == 2 and inside_expanded_dir:
                out.append((depth, name, expanded))
        if out:
            return out, p
    return [(1, "CachyOS", True), (2, "linux-cachyos", False), (2, "linux-cachyos-lts", False),
            (1, "EFI fallback", False)], None


entries, src = boot_entries()
print("preview entries:", [e[1] for e in entries], f"(from {src})" if src else "(no readable limine.conf; using defaults)")


def draw_text(px, cx, cy, text, color, bg=None, cell_w=FONT_W * SCALE, cell_h=FONT_H * SCALE):
    """Stamp a string with the boot font at SCALE, one cell per character."""
    for i, ch in enumerate(text):
        code = ord(ch)
        bits = glyphs[code] if code < 256 else glyphs[0x3F]
        for row in range(FONT_H):
            b = bits[row]
            for col in range(FONT_W):
                on = b & (0x80 >> col)
                for sy in range(SCALE):
                    for sx in range(SCALE):
                        x = cx + i * cell_w + col * SCALE + sx
                        y = cy + row * SCALE + sy
                        if 0 <= x < W and 0 <= y < H:
                            px[y][x] = color if on else (bg if bg is not None else px[y][x])


px = [[bg_px(x, y) for x in range(W)] for y in range(H)]
cell_h = FONT_H * SCALE
row_h = cell_h + 12
rows = []
for depth, name, expanded in entries:
    if depth == 1:
        # Limine draws its own triangle glyph next to a directory; the font we
        # supply has no such glyph, and the arrow code points differ between
        # console fonts, so the mock uses the plain ASCII pair a reader cannot
        # misread.
        marker = "- " if expanded else "+ "
        rows.append((marker + name, depth == 1))
    else:
        rows.append(("   " + name, False))
block_h = len(rows) * row_h
top = (H - block_h) // 2 - 40

# Branding, then key hints, both quiet.
draw_text(px, 48 + 12, 48 + 16, "Freebuff OS", BRAND)
draw_text(px, 48 + 12, 48 + 16 + cell_h + 14,
          "Up/Down Select  Enter Boot  E Edit  S Setup  F Firmware", HELP)

for i, (s, is_dir) in enumerate(rows):
    y = top + i * row_h
    sel = (i == 0)
    if sel:
        for yy in range(y - 6, y + cell_h + 6):
            for xx in range(W // 2 - 420, W // 2 + 420):
                if 0 <= yy < H:
                    px[yy][xx] = SEL_BG
    draw_text(px, W // 2 - 400, y, s, TEXT if sel else (TEXT_DIM if not is_dir else TEXT))

# Countdown, the way Limine prints it under the list.
count = "Default entry will boot in 10 seconds"
draw_text(px, (W - len(count) * FONT_W * SCALE) // 2, top + block_h + 46, count, HELP_HI)

write_png(os.path.join(OUT, "limine-preview.png"), W, H, lambda x, y: px[y][x])
print("wrote theme/limine-preview.png, theme/limine-theme.conf")
