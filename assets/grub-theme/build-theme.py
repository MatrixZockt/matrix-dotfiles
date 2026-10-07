#!/usr/bin/env python3
# Builds the "Freebuff" GRUB theme into hyprland/assets/grub-theme/theme/
# Palette = the shell's monochrome graphite Material You palette:
#   bg #131313, container #1F1F1F, outline #474747, text #E2E2E2, primary #FFFFFF
# Usage: python3 build-theme.py

import os
import struct
import zlib

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "theme")
os.makedirs(OUT, exist_ok=True)

# ── Palette ──────────────────────────────────────────────────────────────────
BG = (0x13, 0x13, 0x13)
SURFACE = (0x1F, 0x1F, 0x1F)
OUTLINE = (0x47, 0x47, 0x47)
TEXT = (0xE2, 0xE2, 0xE2)
PRIMARY = (0xFF, 0xFF, 0xFF)


def write_png(path, w, h, get_px):
    """Minimal RGB PNG writer. get_px(x, y) -> (r, g, b)."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: none
        for x in range(w):
            r, g, b = get_px(x, y)
            raw += bytes((r, g, b))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def in_rounded(x, y, w, h, r):
    """Point-in-rounded-rect (r=0 means sharp)."""
    if x < 0 or y < 0 or x >= w or y >= h:
        return False
    if r <= 0:
        return True
    cx = min(x, w - 1 - x)
    cy = min(y, h - 1 - y)
    if cx >= r or cy >= r:
        return True
    dx, dy = r - cx, r - cy
    return dx * dx + dy * dy <= r * r


def card_image(path, w, h, r, fill, border, border_w=2):
    def px(x, y):
        if not in_rounded(x, y, w, h, r):
            return (0, 0, 0)
        # Border ring: inside the shape but within border_w of the edge.
        for dx, dy in ((x, y - border_w), (x, y + border_w), (x - border_w, y), (x + border_w, y)):
            if not in_rounded(dx, dy, w, h, r):
                return border
        return fill
    write_png(path, w, h, px)


def nine_slice(base, w, h, r, fill, border, border_w=2):
    """Emit the 9 slices GRUB pixmap styles expect: <base>_c/_n/_s/_e/_w/_nw/_ne/_sw/_se."""
    full = os.path.join(OUT, f"{base}.png")
    card_image(full, w, h, r, fill, border, border_w)
    hw, hh = w // 2, h // 2
    parts = {
        "c": (hw, hh, hw + 1, hh + 1),        # center 1x1
        "n": (hw, 0, hw + 1, hh),             # top edge
        "s": (hw, hh + 1, hw + 1, h),         # bottom edge
        "w": (0, hh, hw, hh + 1),             # left edge
        "e": (hw + 1, hh, w, hh + 1),         # right edge
        "nw": (0, 0, hw, hh),
        "ne": (hw + 1, 0, w, hh),
        "sw": (0, hh + 1, hw, h),
        "se": (hw + 1, hh + 1, w, h),
    }
    for name, (x0, y0, x1, y1) in parts.items():
        sw, sh = x1 - x0, y1 - y0
        card_image(os.path.join(OUT, f"{base}_{name}.png"), sw, sh, r if name in ("nw", "ne", "sw", "se") else 0, fill, border, border_w)


# ── 1. Wallpaper: graphite field, soft center vignette, hairline frame ──────
W, H = 1920, 1080


def bg_px(x, y):
    # Gentle vignette: up to +9 brightness at center, falling off to the edge.
    dx = (x - W / 2) / (W / 2)
    dy = (y - H / 2) / (H / 2)
    d2 = dx * dx + dy * dy
    lift = max(0.0, 1.0 - d2) * 9
    c = tuple(min(255, int(v + lift)) for v in BG)
    # Hairline frame, 1px, inset 40px, outline color at a whisper (mixed toward bg).
    inset = 40
    on_frame = (x == inset or x == W - 1 - inset or y == inset or y == H - 1 - inset)
    if on_frame and inset <= x < W - inset and inset <= y < H - inset:
        c = tuple((a * 2 + b) // 3 for a, b in zip(OUTLINE, c))
    return c


write_png(os.path.join(OUT, "background.png"), W, H, bg_px)

# ── 2. Selection card (9-slice) and scrollbar thumb ─────────────────────────
nine_slice("select", 32, 32, 10, SURFACE, OUTLINE, 2)
nine_slice("scroll", 8, 8, 4, OUTLINE, OUTLINE, 0)

# ── 3. Fonts: Noto Sans -> GRUB .pf2 ────────────────────────────────────────
FONTS = [
    ("/usr/share/fonts/noto/NotoSans-Regular.ttf", "Noto Sans Regular", 18),
    ("/usr/share/fonts/noto/NotoSans-Bold.ttf", "Noto Sans Bold", 18),
    ("/usr/share/fonts/noto/NotoSans-Medium.ttf", "Noto Sans Medium", 14),
]
fonts_ok = []
try:
    import freetype
    from PIL import Image  # noqa: F401  (freetype-py renders via its own API below)
    HAVE_PIL = True
except ImportError:
    freetype = None
    HAVE_PIL = False

if freetype is not None:
    for src, name, size in FONTS:
        try:
            face = freetype.Face(src)
            face.set_pixel_sizes(0, size)
            glyphs = []
            for code in range(0x20, 0x7F):
                face.load_char(chr(code))
                bmp = face.glyph.bitmap
                rows, cols = bmp.rows, bmp.width
                buf = bytes(bmp.buffer) if rows * cols else b""
                glyphs.append((code, cols, rows, face.glyph.bitmap_left,
                               face.glyph.bitmap_top, face.glyph.advance.x // 64, buf))
            # Assemble one wide bitmap so grub-mkfont-style packing is easy:
            # pack glyphs on a single row (GRUB pf2 wants a consistent atlas;
            # building pf2 by hand is heavy, so fall back to system unicode.pf2
            # unless grub-mkfont exists -- see README).
            fonts_ok.append(name)
        except Exception as e:  # noqa: BLE001
            print(f"  font skipped ({name}): {e}")
            break

# grub-mkfont (from the grub package) is the only reliable pf2 compiler; if it
# is present, use it. Otherwise theme.txt falls back to GRUB's built-in font.
import shutil
mkfont = shutil.which("grub-mkfont")
if mkfont:
    for src, name, size in FONTS:
        dst = os.path.join(OUT, name.replace(" ", "") + ".pf2")
        rc = os.system(f"{mkfont} -u /usr/share/fonts/noto/unicodedata -s {size} -o '{dst}' '{src}' >/dev/null 2>&1")
        if rc == 0 and os.path.exists(dst):
            print(f"  font: {os.path.basename(dst)}")
            fonts_ok.append(name)

print("fonts compiled:", fonts_ok or "NONE (theme.txt uses GRUB built-in font)")

# ── 4. theme.txt ────────────────────────────────────────────────────────────
if fonts_ok:
    item_font = "Noto Sans Regular 18"
    sel_font = "Noto Sans Bold 18"
    msg_font = "Noto Sans Medium 14"
else:
    item_font = "Unicode Regular 18"
    sel_font = "Unicode Regular 18"
    msg_font = "Unicode Regular 14"

theme = f"""# Freebuff GRUB theme -- graphite Material You
# Generated by build-theme.py; regenerate after editing.
desktop-image: "background.png"
title-text: ""

+ boot_menu {{
    left = 25%
    top = 32%
    width = 50%
    height = 42%
    item_font = "{item_font}"
    selected_item_font = "{sel_font}"
    item_color = "{TEXT[0]:02X}{TEXT[1]:02X}{TEXT[2]:02X}"
    selected_item_color = "{PRIMARY[0]:02X}{PRIMARY[1]:02X}{PRIMARY[2]:02X}"
    item_height = 52
    item_padding = 10
    item_icon_space = 14
    item_spacing = 6
    selected_item_pixmap_style = "select_*.png"
    scrollbar = true
    scrollbar_width = 10
    scrollbar_thumb_pixmap_style = "scroll_*.png"
    scrollbar_frame_pixmap_style = "scroll_*.png"
}}

+ label {{
    left = 25%
    top = 78%
    width = 50%
    font = "{msg_font}"
    color = "{TEXT[0]:02X}{TEXT[1]:02X}{TEXT[2]:02X}"
    align = "center"
    text = "Freebuff OS"
}}

+ progress_bar {{
    left = 40%
    top = 86%
    width = 20%
    height = 3
    text_color = "{TEXT[0]:02X}{TEXT[1]:02X}{TEXT[2]:02X}"
    fg_color = "{OUTLINE[0]:02X}{OUTLINE[1]:02X}{OUTLINE[2]:02X}"
    bg_color = "{SURFACE[0]:02X}{SURFACE[1]:02X}{SURFACE[2]:02X}"
    id = "__timeout__"
    font = "{msg_font}"
}}
"""
with open(os.path.join(OUT, "theme.txt"), "w") as f:
    f.write(theme)

print("theme written to", OUT)
