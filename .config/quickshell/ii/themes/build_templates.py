#!/usr/bin/env python3
"""
Build the shell's color design templates.

A "template" is a named seed color + Material scheme, run through the exact same
generator the shell uses for wallpaper theming
(`scripts/colors/generate_colors_material.py`). That means every template here
produces a palette byte-identical in shape to the live one the shell loads from
`$XDG_STATE_HOME/quickshell/user/generated/colors.json`, so a palette file from
here is a drop-in replacement for the shell's active colors.

Outputs (all inside this directory):

    templates/<slug>-dark.json    one palette, dark mode,  drop-in format
    templates/<slug>-light.json   one palette, light mode, drop-in format
    templates/manifest.json       index: names, seeds, schemes, descriptions

And, when run with `--publish DIR`, the standalone preview page (every palette
inlined, no fetching needed) is written to DIR/preview.html -- outside this tree
on purpose, so building it never churns files the running shell watches.

The palette JSON keys are the same camelCase names the generator prints, and the
shell's MaterialThemeLoader maps them onto `Appearance.m3colors` unchanged
(`onBackground` -> `m3onBackground`), which is why these files need no
translation step.

Usage:  ./build_templates.py            # regenerate everything
        ./build_templates.py --list     # just print the template table
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHELL_DIR = HERE.parent
TEMPLATES_DIR = HERE / "templates"

# The generator needs its venv (materialyoucolor + PIL). The shell exports this
# variable; fall back to the same default location when run by hand.
VENV = os.environ.get(
    "ILLOGICAL_IMPULSE_VIRTUAL_ENV",
    str(Path.home() / ".local/state/quickshell/.venv"),
)
GENERATOR = SHELL_DIR / "scripts/colors/generate_colors_material.py"

# ── The design templates ─────────────────────────────────────────────────────
# seed   : the accent the whole palette is derived from
# scheme : one of the generator's Material schemes (vibrant, fidelity,
#          expressive, content, tonal-spot, neutral, monochrome, rainbow,
#          fruit-salad)
TEMPLATES = [
    {
        "slug": "tokyo-night",
        "name": "Tokyo Night",
        "seed": "#7AA2F7",
        "scheme": "scheme-vibrant",
        "description": "Cool cobalt blue on deep navy. The everyday default.",
    },
    {
        "slug": "catppuccin",
        "name": "Catppuccin",
        "seed": "#CBA6F7",
        "scheme": "scheme-fidelity",
        "description": "Soft mauve pastels. Gentle contrast, easy on the eyes.",
    },
    {
        "slug": "dracula",
        "name": "Dracula",
        "seed": "#BD93F9",
        "scheme": "scheme-expressive",
        "description": "High-chroma violet with punchy containers.",
    },
    {
        "slug": "gruvbox",
        "name": "Gruvbox",
        "seed": "#D79921",
        "scheme": "scheme-vibrant",
        "description": "Warm amber and olive. Retro terminal warmth.",
    },
    {
        "slug": "everforest",
        "name": "Everforest",
        "seed": "#A7C080",
        "scheme": "scheme-tonal-spot",
        "description": "Muted forest green. Calm and low-energy.",
    },
    {
        "slug": "kanagawa",
        "name": "Kanagawa",
        "seed": "#7E9CD8",
        "scheme": "scheme-content",
        "description": "Indigo ink, faithful to the seed. Quiet and precise.",
    },
    {
        "slug": "nord",
        "name": "Nord Frost",
        "seed": "#88C0D0",
        "scheme": "scheme-content",
        "description": "Arctic cyan-grey. Cold, clean, low saturation.",
    },
    {
        "slug": "rose-pine",
        "name": "Rosé Pine",
        "seed": "#EBBCBA",
        "scheme": "scheme-tonal-spot",
        "description": "Dusty rose with soft neutrals. Warm and soft.",
    },
    {
        "slug": "ash",
        "name": "Ash",
        "seed": "#9A9A9A",
        "scheme": "scheme-monochrome",
        "description": "Pure greyscale, no hue at all. The quietest option.",
    },
    {
        "slug": "neon",
        "name": "Neon",
        "seed": "#FF2E97",
        "scheme": "scheme-fruit-salad",
        "description": "Hot magenta with playful multicolour accents.",
    },
    {
        "slug": "emerald",
        "name": "Emerald",
        "seed": "#10B981",
        "scheme": "scheme-vibrant",
        "description": "Deep teal emerald. Fresh and saturated.",
    },
    {
        "slug": "solar",
        "name": "Solar",
        "seed": "#F59E0B",
        "scheme": "scheme-expressive",
        "description": "Sunset orange. The warmest of the set.",
    },
]

MODES = ["dark", "light"]

# The generator prints `$key: #VALUE;` lines; `$darkmode: True;` is metadata.
LINE_RE = re.compile(r"^\$([A-Za-z0-9_]+):\s*(.+?);$")
M3_PROPERTY_RE = re.compile(r"property color (m3[A-Za-z]+)")
APPEARANCE_QML = SHELL_DIR / "modules/common/Appearance.qml"


def declared_palette_keys() -> set:
    """The palette keys the shell actually has a home for.

    MaterialThemeLoader assigns every key in a palette file onto the
    `Appearance.m3colors` object, so a key with no matching `property color
    m3...` in Appearance.qml is not merely ignored: assigning it throws, which
    aborts the rest of the load loop and leaves the palette half-applied.
    Filtering here is what makes these files drop-in replacements for
    `$XDG_STATE_HOME/quickshell/user/generated/colors.json`.
    """
    source = APPEARANCE_QML.read_text(encoding="utf-8")
    names = M3_PROPERTY_RE.findall(source)
    if not names:
        sys.exit(f"error: found no m3 color properties in {APPEARANCE_QML}")
    # m3surfaceContainerLow -> surfaceContainerLow
    return {name[2].lower() + name[3:] for name in names}


def generate(seed: str, scheme: str, mode: str) -> dict:
    """Run the shell's own generator and return the palette as a dict."""
    python = Path(VENV) / "bin/python"
    if not python.exists():
        sys.exit(
            f"error: no python in the shell venv at {VENV}\n"
            "       set ILLOGICAL_IMPULSE_VIRTUAL_ENV or run this from the shell."
        )

    result = subprocess.run(
        [str(python), "-E", str(GENERATOR),
         "--color", seed, "--mode", mode, "--scheme", scheme],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"error: generator failed for {seed}/{scheme}/{mode}\n{result.stderr}")

    palette = {}
    for line in result.stdout.splitlines():
        match = LINE_RE.match(line.strip())
        if not match:
            continue
        key, value = match.group(1), match.group(2)
        if key in ("darkmode", "transparent"):
            continue
        palette[key] = value

    if len(palette) < 40:
        sys.exit(f"error: generator returned only {len(palette)} colors for {seed}/{mode}")

    allowed = declared_palette_keys()
    dropped = sorted(set(palette) - allowed)
    palette = {key: value for key, value in palette.items() if key in allowed}
    if dropped:
        print(f"    (not in Appearance.m3colors, dropped: {', '.join(dropped)})")
    return palette


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="print the templates and exit")
    parser.add_argument("--publish", metavar="DIR", default=None,
                        help="where to write the preview page (and the manifest), e.g. the "
                             "folder the desktop app serves the preview from")
    args = parser.parse_args()

    if args.list:
        for template in TEMPLATES:
            print(f"{template['slug']:14} {template['name']:14} "
                  f"{template['seed']:9} {template['scheme']}")
        return

    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)

    manifest = {"generatedBy": "themes/build_templates.py", "templates": []}
    palettes = {}

    for template in TEMPLATES:
        entry = dict(template)
        entry["palettes"] = {}
        for mode in MODES:
            palette = generate(template["seed"], template["scheme"], mode)
            file_name = f"{template['slug']}-{mode}.json"
            (TEMPLATES_DIR / file_name).write_text(
                json.dumps(palette, indent=2) + "\n", encoding="utf-8"
            )
            entry["palettes"][mode] = file_name
            # Kept in the manifest too so the preview page needs no file access.
            palettes[f"{template['slug']}:{mode}"] = palette
            print(f"  {file_name:26} {len(palette)} colors")

        manifest["templates"].append(entry)

    (TEMPLATES_DIR / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote templates/manifest.json ({len(TEMPLATES)} templates)")

    # ── The preview page ─────────────────────────────────────────────────────
    # A standalone HTML file with every palette inlined, so it opens straight
    # from disk with no fetching (and no dev server) involved.
    #
    # It is deliberately NOT written into this directory: this tree lives under
    # the running shell's config, which Quickshell watches, and rewriting a
    # 130 KiB file in there on every build is churn the shell does not need.
    # The page is built straight into --publish instead.
    source = HERE / "preview.template.html"
    if not source.exists():
        return
    if not args.publish:
        print("note: no --publish DIR given, so the preview page was not written")
        return

    # `manifest["templates"]` (not the raw TEMPLATES list) so each entry carries
    # the file names for its two palettes.
    data = json.dumps({"templates": manifest["templates"], "palettes": palettes})
    page = source.read_text(encoding="utf-8").replace("/*__PALETTES__*/", data)

    target = Path(args.publish).expanduser()
    target.mkdir(parents=True, exist_ok=True)
    (target / "preview.html").write_text(page, encoding="utf-8")
    shutil.copyfile(TEMPLATES_DIR / "manifest.json", target / "manifest.json")
    print(f"published preview.html ({len(data) // 1024} KiB of palette data) to {target}")


if __name__ == "__main__":
    main()
