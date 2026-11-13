#!/usr/bin/env bash
# ── A TEXT COPY IS PLAIN TEXT ───────────────────────────────────────────────
# Run by `wl-paste --type text --watch` (hyprland/execs.lua) for every new
# text clipboard content.
#
# WHAT THIS FIXES (2026-11-05, the user's rule)
#
#   Copying text out of a browser, an editor or a document puts SEVERAL
#   flavours of the same copy on the clipboard: `text/plain` next to
#   `text/html` (and sometimes RTF). Pasting into anything that understands
#   the rich one -- a browser, LibreOffice, an email composer, the shell's own
#   editor -- then brings the source's fonts, colours and layout along with the
#   words, which is never what was asked for. A text copy should carry text:
#   the words, and nothing about how they were drawn.
#
#   So every copy that still offers a rich flavour is REPLACED on the clipboard
#   with the plain one. The bytes are the same words; what disappears is the
#   mark-up around them.
#
# WHAT IS DELIBERATELY NOT TOUCHED
#
#   * Images and files. A screenshot copy (`wl-paste --type image`) and a file
#     copy (`text/uri-list` + `x-special/gnome-copied-files`) carry no rich
#     TEXT, so they fall out of the classification below and this script does
#     nothing at all. File pastes in the file manager keep working because of
#     that, not by special case.
#   * A copy that is already plain-only: nothing is re-owned, nothing is
#     re-copied, so there is no extra latency and no second history entry for
#     the ordinary case.
#
# WHY IT STORES THE HISTORY ITSELF
#
#   This replaces the old `wl-paste --type text --watch cliphist store` line
#   rather than sitting beside it. Two watchers on the same event store two
#   entries for one copy -- and because the rewrite below is itself a clipboard
#   change, it would fire a second time on the plain version we just made.
#   One watcher, one entry per copy (see the marker at the bottom).
#
# Exit codes are all 0: a watcher that dies on a surprise leaves the clipboard
# un-managed until the next login, and nothing here is worth that.

set -uo pipefail

# What this copy actually offers. "Nothing is copied" exits non-zero here.
types=$(wl-paste --list-types 2>/dev/null) || exit 0
[ -z "$types" ] && exit 0

plain=0
rich=0
while IFS= read -r t; do
    # Parameters (`;charset=utf-8`) are not part of the type's identity.
    case "${t%%;*}" in
        text/plain|UTF8_STRING|TEXT|STRING) plain=1 ;;
        text/html|application/xhtml+xml|text/rtf|application/rtf) rich=1 ;;
    esac
done <<< "$types"

# No text at all -- image, file copy, something exotic. Not ours.
if [ "$plain" -eq 0 ] && [ "$rich" -eq 0 ]; then
    exit 0
fi

work=$(mktemp) || exit 0
trap 'rm -f "$work"' EXIT
marker="${XDG_RUNTIME_DIR:-/tmp}/ii-clip-plain.marker"

# ── Already plain: just record it ───────────────────────────────────────────
if [ "$rich" -eq 0 ]; then
    cat > "$work"
    # ...unless this event IS our own rewrite, whose content is already in the
    # history. The marker is written before the rewrite for exactly this
    # reason: the watcher can fire on our copy before the next line runs.
    if [ -f "$marker" ] && cmp -s "$marker" "$work"; then
        rm -f "$marker"
        exit 0
    fi
    cliphist store < "$work" 2>/dev/null || true
    exit 0
fi

# ── Rich: take the words, drop the styling ─────────────────────────────────
if [ "$plain" -eq 1 ]; then
    # The source already told us what its text is; use its own answer rather
    # than trying to un-HTML it.
    wl-paste --no-newline --type text/plain > "$work" 2>/dev/null || exit 0
else
    # Only HTML (some apps publish nothing else). Strip it to text.
    wl-paste --no-newline --type text/html 2>/dev/null \
        | python3 -c "$HTML_TO_TEXT" > "$work" || exit 0
fi

# A conversion that produced nothing must never replace a real copy with an
# empty clipboard: leave the original alone and let the user paste it styled.
[ -s "$work" ] || exit 0

cp "$work" "$marker" 2>/dev/null || true
wl-copy --type text/plain < "$work" 2>/dev/null || exit 0

cliphist store < "$work" 2>/dev/null || true

exit 0

# ── HTML -> text ───────────────────────────────────────────────────────────
# Assigned with `read -d ''` instead of a here-doc on the python call so this
# stays one file: the strip path reads the HTML on STDIN, and a here-doc there
# would take stdin away from it.
#
# Block-level tags become line breaks, cells become tabs, <br> is a newline,
# script/style contents are dropped (they are not text anyone copied), entities
# are resolved by the parser, and whitespace inside a line is collapsed -- HTML
# source is full of indentation that has nothing to do with the text.
read -r -d '' HTML_TO_TEXT <<'PY' || true
import re
import sys
from html.parser import HTMLParser

BLOCK = {"p", "div", "section", "article", "header", "footer", "main", "nav",
         "li", "ul", "ol", "tr", "table", "blockquote", "pre",
         "h1", "h2", "h3", "h4", "h5", "h6", "hr"}


class ToText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.mute = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.mute += 1
        elif tag == "br":
            self.parts.append("\n")
        elif tag in ("td", "th"):
            self.parts.append("\t")
        elif tag in BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.mute = max(0, self.mute - 1)
        elif tag in BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.mute:
            self.parts.append(data)


parser = ToText()
parser.feed(sys.stdin.read())
text = "".join(parser.parts)
lines = [" ".join(line.split()) for line in text.split("\n")]
sys.stdout.write(re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip())
PY
