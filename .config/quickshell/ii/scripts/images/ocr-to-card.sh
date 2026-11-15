#!/usr/bin/env bash
# Text extraction for the snip: the words go to the shell's transcript card,
# never to the clipboard.
#
# It used to be `tesseract ... | wl-copy` written inline in the QML, so a snip in
# "text extractor" mode took the clipboard without being asked for -- and threw
# away whatever had been copied before it, usually the picture the snip came
# from. Asked for 2026-11-15: a transcription copies nothing by itself; the
# card's own Copy is the one way to keep the words.
#
# The card polls $XDG_RUNTIME_DIR/ii-dictate/transcript.json (see
# TranscriptCard.qml and the dictation script's show_transcript), so this writes
# that same shape -- {"text": ..., "ts": ...} -- atomically and mode 0600.
#
# Usage: ocr-to-card.sh <picture>
# Exit: 0 written, 2 no picture, 3 tesseract missing, 4 tesseract failed,
#       5 nothing readable, 6 could not write the card's file.
set -u

img="${1:-}"
[ -n "$img" ] && [ -f "$img" ] || { echo "ocr-to-card: no picture at '$img'" >&2; exit 2; }
command -v tesseract >/dev/null 2>&1 || { echo "ocr-to-card: tesseract is not installed" >&2; exit 3; }

# Every language tesseract has, so a screenshot of a non-English page reads.
langs="$(tesseract --list-langs 2>/dev/null | awk 'NR > 1 { print $1 }' | paste -sd+ -)"
text="$(tesseract "$img" stdout -l "${langs:-eng}" 2>/dev/null)" || exit 4
# Trailing whitespace is the page, not the words.
text="$(printf '%s' "$text" | sed -e 's/[[:space:]]*$//')"
[ -n "$text" ] || { echo "ocr-to-card: no text found" >&2; exit 5; }

dir="${XDG_RUNTIME_DIR:-/tmp}/ii-dictate"
mkdir -p "$dir" || exit 6

OCR_TEXT="$text" python3 - "$dir/transcript.json" <<'PY'
import json, os, sys, time

path = sys.argv[1]
tmp = path + ".tmp"
with open(tmp, "w") as handle:
    json.dump({"text": os.environ.get("OCR_TEXT", ""), "ts": time.time()}, handle)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
