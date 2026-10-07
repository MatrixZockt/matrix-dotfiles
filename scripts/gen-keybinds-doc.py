#!/usr/bin/env python3
"""Generate docs/KEYBINDS.md from the running Hyprland instance.

Usage:  python3 scripts/gen-keybinds-doc.py [--output docs/KEYBINDS.md]

Reads `hyprctl binds -j` so the doc always reflects what is ACTUALLY bound,
not what the config files look like they should do.
"""

import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

MOD_BITS = [
    (1, "SHIFT"),
    (2, "CAPS"),
    (4, "CTRL"),
    (8, "ALT"),
    (16, "MOD2"),
    (32, "MOD3"),
    (64, "SUPER"),
    (128, "MOD5"),
]

MOUSE_BUTTONS = {
    "mouse:272": "LMB",
    "mouse:273": "RMB",
    "mouse:274": "MMB",
    "mouse:275": "Side1",
    "mouse:276": "Side2",
}


def decode_mods(mask: int) -> str:
    if not mask:
        return ""
    return " + ".join(name for bit, name in MOD_BITS if mask & bit)


def describe(bind: dict) -> str:
    key = str(bind.get("key", ""))
    key = MOUSE_BUTTONS.get(key, key)
    mods = decode_mods(int(bind.get("modmask", 0) or 0))
    combo = f"{mods} + {key}" if mods else key

    tags = []
    if bind.get("submap"):
        tags.append(f"submap `{bind['submap']}`")
    if bind.get("catch_all"):
        tags.append("catch-all")
    if tags:
        combo += f"  _({', '.join(tags)})_"
    return combo


def get_binds() -> list[dict]:
    raw = subprocess.run(
        ["hyprctl", "binds", "-j"], capture_output=True, text=True, check=True
    ).stdout
    return json.loads(raw)


def main() -> int:
    out_path = REPO / "docs" / "KEYBINDS.md"
    args = sys.argv[1:]
    if "--output" in args:
        out_path = Path(args[args.index("--output") + 1]).resolve()

    binds = get_binds()

    groups: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for bind in binds:
        combo = describe(bind)
        dispatcher = bind.get("dispatcher") or ""
        arg = bind.get("arg") or ""
        if dispatcher == "__lua":
            action = "(lua action)"
        else:
            action = f"`{dispatcher}`" + (f" `{arg}`" if arg else "")

        raw_desc = (bind.get("description") or "").strip()
        if raw_desc:
            group = raw_desc.split(":", 1)[0].strip() or "Other"
            description = raw_desc.split(":", 1)[1].strip() if ":" in raw_desc else raw_desc
        else:
            group = "Unlabelled"
            description = ""

        detail = action if not description else f"{description} — {action}"
        groups[group].append((combo, detail))

    lines = [
        "# Keybinds",
        "",
        "Auto-generated from the **running** Hyprland instance (`hyprctl binds -j`),",
        "so this is what your keys actually do right now.",
        "",
        f"Total binds: **{len(binds)}**",
        "",
        "Regenerate with:",
        "",
        "```bash",
        "make keybinds",
        "```",
        "",
        "> Modifiers: `SUPER` = Windows/Super key, `LMB/RMB/MMB` = left/right/middle mouse button.",
        "",
    ]

    for group in sorted(groups, key=lambda g: (g == "Unlabelled", g)):
        lines.append(f"## {group}")
        lines.append("")
        lines.append("| Keys | Action |")
        lines.append("| --- | --- |")
        for combo, detail in sorted(groups[group]):
            lines.append(f"| `{combo}` | {detail} |")
        lines.append("")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n")
    print(f"wrote {out_path} ({len(binds)} binds, {len(groups)} groups)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
