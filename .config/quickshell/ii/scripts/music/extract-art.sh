#!/usr/bin/env bash
# Extract the cover embedded in every track of the music library.
#
# WHY A SCRIPT AND NOT AN INLINE COMMAND
# --------------------------------------
# The QML side used to build one giant `ffmpeg ...; ffmpeg ...; ffmpeg ...`
# string with every library path interpolated into it. That is a quoting
# minefield: one path with a character the shell cares about and the whole
# batch dies with "syntax error near unexpected token", and because the batch
# is all-or-nothing, 124 good extractions go with it.
#
# Here the script does its OWN `find`, so no path is ever spliced into a
# command line by the caller. Quoting is the shell's problem, not the caller's,
# and one bad file cannot take the rest down with it.
#
# The cache key MUST match MusicPlayer.qml's cachedArtName():
#   path with every non [A-Za-z0-9] byte -> "_", truncated to 80 chars, + ".jpg"
# Both sides derive it the same way, which is how the scan finds these files
# again on the next pass.
set -u

MUSIC_DIR="${1:-$HOME/Music/Spotify}"
CACHE="${2:-$HOME/.cache/ii-music-art}"
mkdir -p "$CACHE"

[ -d "$MUSIC_DIR" ] || exit 0
command -v ffmpeg >/dev/null 2>&1 || exit 0

done_n=0
while IFS= read -r f; do
    [ -n "$f" ] || continue

    # A deliberate cover dropped in the folder always wins over whatever is
    # embedded in the file.
    art=""
    d="$(dirname "$f")"
    for n in cover folder album front; do
        for e in jpg jpeg png webp; do
            if [ -f "$d/$n.$e" ]; then art="$d/$n.$e"; break 2; fi
        done
    done
    [ -n "$art" ] && continue

    # tr with a character class that EXCLUDES newline, so the key never picks
    # up a trailing one; cut caps the length to match the QML side exactly.
    key="$(printf '%s' "$f" | tr -c 'A-Za-z0-9' '_' | cut -c1-80)"
    out="$CACHE/$key.jpg"
    [ -f "$out" ] && continue

    # -map 0:v picks the attached picture stream; most of these files have no
    # real video, and a file without one just fails harmlessly here.
    ffmpeg -loglevel quiet -y -i "$f" -an -map 0:v -frames:v 1 "$out" 2>/dev/null || true
    [ -f "$out" ] && done_n=$((done_n + 1))
done < <(find "$MUSIC_DIR" -name '*.mp3' | sort)

echo "extracted $done_n"

# ── Durations ──────────────────────────────────────────────────────────
# The tracklist wants a time column, and the only cheap source of a length is
# the container itself. ffprobe per file is ~15ms, so the whole library costs
# about two seconds -- but the scan re-runs every minute, and paying that
# every minute for data that never changes is how a background task becomes
# the reason a machine feels slow.
#
# So the results are cached in a TSV keyed by the full path and only computed
# for files that are not in it yet. The cache is keyed on PATH, not on the art
# slug: the slug is truncated to 80 characters, so two long files in different
# folders can collide, and a collision here would show the wrong time next to
# the wrong song.
DURFILE="$CACHE/durations.tsv"
: > "$DURFILE.tmp"
dur_n=0

have_dur() {
    # A file counts as known once it has a row, even if that row is 0: a track
    # that genuinely has no readable length should not be re-probed forever.
    [ -f "$DURFILE" ] && grep -qF "$1"$'\t' "$DURFILE"
}

while IFS= read -r f; do
    [ -n "$f" ] || continue
    if have_dur "$f"; then
        grep -F "$f"$'\t' "$DURFILE" >> "$DURFILE.tmp"
        continue
    fi
    secs=""
    if command -v ffprobe >/dev/null 2>&1; then
        # The value is already in seconds; truncating happens here so the
        # cache stays a raw number rather than a pre-formatted string.
        secs=$(ffprobe -v quiet -show_entries format=duration \
                          -of default=nk=1:nw=1 "$f" 2>/dev/null | head -1)
        case "$secs" in
            ''|*[!0-9.]*) secs="" ;;
        esac
    fi
    secs="${secs%%.*}"
    [ -z "$secs" ] && secs=0
    printf '%s\t%s\n' "$f" "$secs" >> "$DURFILE.tmp"
    dur_n=$((dur_n + 1))
done < <(find "$MUSIC_DIR" -name '*.mp3' | sort)

mv "$DURFILE.tmp" "$DURFILE"
echo "durations $dur_n"
