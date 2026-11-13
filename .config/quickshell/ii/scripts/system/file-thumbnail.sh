#!/usr/bin/env bash
# First-page thumbnail for the file kinds the shared thumbnailer cannot decode.
#
#   file-thumbnail.sh <pdf|document> <source> <out.png> <maxEdge>
#
# The thumbnail cache (modules/common/widgets/ThumbnailImage.qml) turns an image
# or a video frame into a PNG with magick/ffmpeg. A PDF and a .docx have no such
# decoder on this machine -- there is no LibreOffice here -- so:
#
#   * a PDF is drawn from its FIRST PAGE through Poppler's pdftoppm, which is
#     what the preview pane already uses for the same file;
#   * a document is drawn from its TEXT, extracted by the same helper the pane
#     uses (file-preview.py), laid out on a paper-coloured page. It is not a
#     pixel-perfect render of the layout -- nothing on this machine can make one
#     -- but it shows what the document SAYS, which is the part a tile can
#     usefully answer.
#
# Silent on success: the exit status is the answer (0 = a non-empty PNG is at
# <out.png>). The QML side tests the FILE, because a helper that prints its own
# success can still leave a 0-byte file behind.
set -u
kind=${1:-}
src=${2:-}
out=${3:-}
edge=${4:-256}
[ -n "$kind" ] && [ -n "$src" ] && [ -n "$out" ] || exit 2
mkdir -p "$(dirname "$out")" 2>/dev/null || exit 1
# Already there and NOT empty: nothing to do (the caller's `have` guard has the
# same rule; this one keeps the script safe when run by hand).
[ -s "$out" ] && exit 0
[ -r "$src" ] || exit 3
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

paper='#fbfbf6'   # the shell's document card, not a photograph
ink='#1f1f1c'
suffix=$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')

if [ "$kind" = "pdf" ]; then
    command -v pdftoppm >/dev/null 2>&1 || exit 4
    # DPI from the requested width: -r 72 is 72 dpi, and a Letter page is 612 pt
    # wide, so this lands the rendered page at about `edge` pixels across.
    dpi=$(( ${edge} * 72 / 612 ))
    [ "$dpi" -lt 24 ] && dpi=24
    pdftoppm -png -f 1 -l 1 -singlefile -r "$dpi" "$src" "$tmp/page" >/dev/null 2>&1
    [ -s "$tmp/page.png" ] || exit 5
    magick "$tmp/page.png" -background "$paper" -resize "${edge}x${edge}" "$out" >/dev/null 2>&1
    [ -s "$out" ] || exit 6
    exit 0
fi

# ── A document: its opening text, on a page ─────────────────────────────
text="$tmp/text"
case "$suffix" in
    docx|docm|odt|ott|rtf|epub)
        # The pane's own extractor, so a document reads the same in a tile as it
        # does in the preview pane.
        python3 "$(dirname "$0")/file-preview.py" office "$src" 2>/dev/null \
            | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("text", ""))
except Exception:
    pass' > "$text" 2>/dev/null
        ;;
    *)
        head -c 2000 -- "$src" > "$text" 2>/dev/null
        ;;
esac
[ -s "$text" ] || exit 7

# 26 lines is a page at this size: more is unreadable at tile scale, fewer
# leaves the page looking blank. 72 columns is the line a page holds.
#
# Lines with fewer than three letters are dropped: Word writes its tab stops and
# text-box offsets into the extracted text as bare numbers ("-2519172121188500"),
# and a page whose first line is a coordinate is a page that reads as broken.
awk 'NF { t = $0; gsub(/[^A-Za-z]/, "", t); if (length(t) < 3) next; n++; if (n <= 26) print }' \
    "$text" | cut -c1-72 > "$tmp/lines" 2>/dev/null
[ -s "$tmp/lines" ] || exit 7

# Point size follows the bucket, so the text stays legible at 128 px and does not
# overflow at 512.
pt=$(( ${edge} / 20 ))
[ "$pt" -lt 7 ] && pt=7
magick -background "$paper" -fill "$ink" -pointsize "$pt" \
    "label:@$tmp/lines" \
    -bordercolor "$paper" -border "$pt" \
    -resize "${edge}x" -gravity north -background "$paper" \
    -extent "${edge}x$(( ${edge} * 4 / 3 ))" \
    "$out" >/dev/null 2>&1
[ -s "$out" ] || exit 8
exit 0
