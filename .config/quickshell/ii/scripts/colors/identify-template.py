#!/usr/bin/env python3
"""Say which design template a Material colour palette came from.

    identify-template.py <colors.json> <templates-dir>

Prints "<slug> <dark|light>" and exits 0 when the palette matches a template
palette, or prints nothing and exits 1 when it does not (a wallpaper-generated
palette, or a hand-edited file).

Why a script and not QML: this used to be done with a blocking `FileView`
inside the loader's service singleton, and it never once succeeded -- the
singleton has no window context, so the read silently produced nothing, the
template was never identified, and every dark/light toggle fell through to the
wallpaper pipeline. A subprocess has no such constraint, and it can read the
manifest and every palette in one pass, which also removes the race where the
manifest had not finished loading when the colours were identified.

Matching is on the (primary, surface, onBackground) triple rather than a byte
compare: it is unique per template+mode, and it survives the file being
reformatted or hand-edited in a way that leaves the colours alone.
"""

import json
import os
import sys


def signature(palette):
    return (
        palette.get("primary", ""),
        palette.get("surface", ""),
        palette.get("onBackground", ""),
    )


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    colors_path, templates_dir = sys.argv[1], sys.argv[2]
    manifest_path = os.path.join(templates_dir, "manifest.json")

    try:
        with open(colors_path) as handle:
            target = signature(json.load(handle))
        with open(manifest_path) as handle:
            templates = json.load(handle).get("templates", [])
    except (OSError, ValueError) as error:
        print(f"identify-template: {error}", file=sys.stderr)
        return 1

    if target == ("", "", ""):
        return 1

    for template in templates:
        palettes = template.get("palettes") or {}
        for mode in ("dark", "light"):
            name = palettes.get(mode)
            if not name:
                continue
            try:
                with open(os.path.join(templates_dir, name)) as handle:
                    if signature(json.load(handle)) == target:
                        print(f"{template.get('slug', '')} {mode}")
                        return 0
            except (OSError, ValueError):
                continue

    return 1


if __name__ == "__main__":
    sys.exit(main())
