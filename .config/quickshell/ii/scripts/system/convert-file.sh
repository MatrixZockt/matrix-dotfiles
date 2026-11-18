#!/usr/bin/env bash
# Convert a file to another format, beside the file it came from.
#
#   convert-file.sh FILE EXT        convert FILE; prints the NEW path on stdout
#   convert-file.sh --list-json     what can become what, for the Files menu
#
# ONE MATRIX, TWO READERS. The Files app builds its "Convert to" rows from
# --list-json and this script performs the conversion from the same table, so a
# row can never offer something the script would refuse, and the script can
# never accept something the menu did not offer.
#
# What a format can become is a question about the FORMAT, not about the file:
# a PNG can become JPG, WebP, AVIF, TIFF, BMP, GIF or PDF; an MP4 can become
# MKV, WebM, MOV, GIF or any of the audio formats (the picture is dropped); a
# ZIP can become a tar.gz. The list is deliberately per source suffix, because
# that is what the menu has when it is built -- the suffix in the name -- and a
# converter that promised more than the name said would be wrong about exactly
# the files where it matters.
#
# Everything below is already installed on this machine and is used for what it
# is good at: ImageMagick for stills (PNG/JPG/WebP/AVIF/HEIC/TIFF/BMP/GIF/PDF/
# SVG in one tool), ffmpeg for anything with a timeline, bsdtar for archives.
# A missing tool is a refusal with a reason, never a half-written file.
set -uo pipefail

MATRIX=$(cat <<'EOF'
png:jpg webp avif tif bmp gif pdf
jpg:png webp avif tif bmp gif pdf
jpeg:png webp avif tif bmp gif pdf
webp:png jpg avif tif bmp gif pdf
gif:png jpg webp avif tif bmp mp4 webm
bmp:png jpg webp avif tif gif pdf
tif:png jpg webp avif bmp gif pdf
tiff:png jpg webp avif bmp gif pdf
avif:png jpg webp tif bmp gif pdf
heic:png jpg webp avif tif bmp gif pdf
svg:png jpg webp pdf tif bmp
mp4:mkv webm mov gif avi mp3 wav flac m4a ogg opus
mkv:mp4 webm mov gif avi mp3 wav flac m4a ogg opus
webm:mp4 mkv mov gif avi mp3 wav flac m4a ogg opus
mov:mp4 mkv webm gif avi mp3 wav flac m4a ogg opus
avi:mp4 mkv webm mov gif mp3 wav flac m4a ogg opus
m4v:mp4 mkv webm mov gif avi mp3 wav flac m4a ogg opus
mp3:wav flac ogg opus m4a aac
flac:mp3 wav ogg opus m4a aac
wav:mp3 flac ogg opus m4a aac
ogg:mp3 wav flac opus m4a aac
opus:mp3 wav flac ogg m4a aac
m4a:mp3 wav flac ogg opus aac
aac:mp3 wav flac ogg opus m4a
zip:tar.gz
tgz:zip
tar:zip
gz:zip
EOF
)

# "jpg webp avif" -> "jpg","webp","avif" (the JSON the menu reads).
json_list() {
    local out="" item
    for item in $1; do
        out="${out}${out:+,}\"$item\""
    done
    printf '[%s]' "$out"
}

list_json() {
    local src outs first=1
    printf '{'
    while IFS=: read -r src outs; do
        [ -n "${src:-}" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '"%s":%s' "$src" "$(json_list "$outs")"
    done <<< "$MATRIX"
    printf '}\n'
}

targets_for() {
    local src outs
    while IFS=: read -r src outs; do
        if [ "$src" = "$1" ]; then
            printf '%s' "$outs"
            return 0
        fi
    done <<< "$MATRIX"
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

OUT=""
# THE TWO CHANNELS. stdout belongs to the app: PROGRESS lines while it works,
# and the finished path as the LAST line. stderr is for a person reading a
# terminal -- and a failure is written to BOTH, because the window reads stdout
# and a conversion that refused for a reason must not look like one that did
# nothing.
fail() {
    echo "$*" >&2
    printf 'ERROR %s\n' "$*"
    [ -n "$OUT" ] && rm -f "$OUT"
    exit 1
}

if [ "${1:-}" = "--list-json" ]; then
    list_json
    exit 0
fi

[ $# -ge 2 ] || { echo "usage: convert-file.sh FILE EXT | --list-json" >&2; exit 2; }

IN="${1}"
TO="$(printf '%s' "${2}" | tr '[:upper:]' '[:lower:]')"
TO="${TO#.}"

[ -f "$IN" ] || fail "no such file: $IN"
[ -n "$TO" ] || fail "no target format given"

case "$IN" in
    */*) DIR="${IN%/*}" ;;
    *)   DIR="." ;;
esac
# An ABSOLUTE folder, because the archive path below changes directory before
# it writes, and "./pack.tar.gz" after that cd is a file inside the temporary
# unpack -- bsdtar refused it, correctly, as "can't add archive to itself".
DIR="$(cd "$DIR" 2>/dev/null && pwd)" || fail "cannot read the folder of $IN"
NAME="${IN##*/}"
SRC="$(printf '%s' "${NAME##*.}" | tr '[:upper:]' '[:lower:]')"
# A file called "README" has no suffix, and `${NAME##*.}` is then the name
# itself -- which would claim the file IS a document of type "readme".
[ "$SRC" = "$NAME" ] && SRC=""

OUTS="$(targets_for "$SRC")" || fail "nothing to convert .$SRC to"
case " $OUTS " in
    *" $TO "*) ;;
    *) fail "a .$SRC file cannot become .$TO" ;;
esac

# The stem: the name without its format. A compound suffix keeps its own "tar"
# -- "backup.tar.gz" becomes "backup.zip", not "backup.tar.zip".
STEM="${NAME%.*}"
case "$NAME" in
    *.tar.gz|*.tar.bz2|*.tar.xz|*.tar.zst) STEM="${NAME%.*}"; STEM="${STEM%.*}" ;;
esac
[ -n "$STEM" ] || STEM="$NAME"

# Beside the original, and never on top of an existing file: "(2)" is how the
# rest of this app avoids the question, and an overwrite here would be silent.
OUT="$DIR/$STEM.$TO"
N=2
while [ -e "$OUT" ]; do
    OUT="$DIR/$STEM ($N).$TO"
    N=$((N + 1))
done

video_target() {
    case "$1" in mp4|mkv|webm|mov|gif|avi) return 0 ;; esac
    return 1
}
audio_target() {
    case "$1" in mp3|wav|flac|ogg|opus|m4a|aac) return 0 ;; esac
    return 1
}
is_image() {
    case " png jpg jpeg webp bmp gif tif tiff avif heic svg " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}
is_archive() {
    case "$1" in zip|tgz|tar|gz) return 0 ;; esac
    return 1
}

# The codec for an audio-only output. Values, not preferences: mp3 is the one
# format every player reads, flac and wav are lossless, m4a is what phones and
# Apple apps expect, opus is the smallest at a given quality.
audio_args() {
    case "$1" in
        mp3)  printf '%s' "-c:a libmp3lame -q:a 2" ;;
        wav)  printf '%s' "-c:a pcm_s16le" ;;
        flac) printf '%s' "-c:a flac -compression_level 8" ;;
        m4a)  printf '%s' "-c:a aac -b:a 192k" ;;
        aac)  printf '%s' "-c:a aac -b:a 192k" ;;
        ogg)  printf '%s' "-c:a libvorbis -q:a 5" ;;
        opus) printf '%s' "-c:a libopus -b:a 128k" ;;
    esac
}

PROGRESS_FILE=""
# How long the finished file should be, so the encode can be reported as a
# percentage of it. No answer means no percentage (an MKV with no duration in
# its header is a real thing) -- the window then shows the job without a number
# rather than a number that is wrong.
TOTAL_US=""
measure_input() {
    local seconds
    seconds="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null)"
    TOTAL_US="$(awk -v s="${seconds:-0}" 'BEGIN { if (s + 0 > 0) printf "%d", s * 1000000 }')"
}

# ── Running ffmpeg where it can be watched, and stopped ──────────────────
#
# In the BACKGROUND, being polled, rather than waited on in the foreground.
# Both halves are about the same thing: a 20-minute MP4 to WebM is minutes of
# work, and a window that cannot say how far along it is, or call it off, is a
# window that looks frozen.
#
# `-progress <file>` is ffmpeg's own machine-readable progress: it rewrites
# out_time_us every half second or so, which is exactly the number this needs
# (the alternative -- counting frames from the log -- needs to know the frame
# rate, and lies on a variable-rate file).
#
# The trap is why this is a background job and not a pipe: bash only runs a
# signal trap between commands, so a script blocked waiting on a foreground
# ffmpeg cannot answer a Cancel until the encode has finished anyway. Waiting
# in a loop of short sleeps means a TERM is answered within 0.2 s -- kill the
# encoder, take the half-written file with it, and say so.
run_ffmpeg() {
    have ffmpeg || fail "ffmpeg is not installed"
    PROGRESS_FILE="$(mktemp "${TMPDIR:-/tmp}/convert-progress.XXXXXX")" || PROGRESS_FILE=""
    # An array, not `${X:+-progress "$X"}`: quote removal does not reach inside
    # a `:+` expansion, so the quotes would arrive at ffmpeg as characters and
    # it would look for a file whose name starts with a quote.
    local -a prog=()
    [ -n "$PROGRESS_FILE" ] && prog=(-progress "$PROGRESS_FILE")
    ffmpeg -hide_banner -loglevel error -nostdin -y -nostats "${prog[@]}" "$@" "$OUT" &
    local pid=$! shown=0 pct now
    while kill -0 "$pid" 2>/dev/null; do
        if [ -n "$TOTAL_US" ] && [ -s "${PROGRESS_FILE:-/nonexistent}" ]; then
            now="$(tr '\r' '\n' < "$PROGRESS_FILE" | sed -n 's/^out_time_us=//p' | tail -1)"
            case "$now" in ''|*[!0-9]*) now=0 ;; esac
            pct=$(( now * 100 / TOTAL_US ))
            [ "$pct" -gt 99 ] && pct=99        # 100 means DONE, not nearly
            if [ "$pct" -gt "$shown" ]; then
                printf 'PROGRESS %s\n' "$pct"
                shown=$pct
            fi
        fi
        sleep 0.2
    done
    wait "$pid"
    local rc=$?
    rm -f "${PROGRESS_FILE:-}"
    PROGRESS_FILE=""
    [ "$rc" = 0 ] || fail "ffmpeg could not convert $NAME to .$TO"
}

# ── A Cancel that cancels ──────────────────────────────────────────────
#
# TERM (what the window's Cancel sends) stops the encoder mid-file and deletes
# what it had written: half an MP4 in the folder is not a converted file, and
# leaving it would make the next attempt look like a name collision. INT is
# here because the same script run by hand deserves the same behaviour.
# HUP is in the list because the window that started this can be CLOSED: the
# shell goes away, ffmpeg goes away with it, and without this the half-written
# file is the one thing left behind.
trap 'pkill -TERM -P $$ 2>/dev/null; rm -f "$OUT" "${PROGRESS_FILE:-}"; echo "cancelled" >&2; exit 130' TERM INT HUP

# Anything below that is not ffmpeg is quick (one ImageMagick pass, or an
# unpack and a repack): 0 now, 100 when it lands, so the window's line appears
# and then ends instead of sitting at nothing.
case "$TO" in
    mp4|mkv|webm|mov|gif|avi|mp3|wav|flac|m4a|ogg|opus|aac) measure_input ;;
    *) printf 'PROGRESS 0\n' ;;
esac

if audio_target "$TO"; then
    # From a video (the picture is dropped) or from another audio file -- one
    # command, because ffmpeg treats both as a stream with a duration.
    #
    # A video with NO soundtrack is a refusal with a reason, not an ffmpeg
    # message: without this it fails as "Output file does not contain any
    # stream", which reads like the converter is broken rather than like the
    # file simply has no audio to take out.
    if ! ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | grep -q .; then
        fail "$NAME has no audio track to take out"
    fi
    # shellcheck disable=SC2046
    run_ffmpeg -i "$IN" -vn -map 0:a:0 $(audio_args "$TO") "$OUT"
elif [ "$TO" = "gif" ]; then
    # A palette is not decoration: ffmpeg's default 256 colours band badly on
    # gradients, and the two-pass palette is the difference between a clip that
    # looks like the recording and one that looks like a compression accident.
    # 15 fps and a 960px ceiling are the size a GIF is still worth sharing at.
    run_ffmpeg -i "$IN" \
        -vf "fps=15,scale='min(960,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
        -loop 0 "$OUT"
elif video_target "$TO"; then
    case "$TO" in
        webm)
            # VP9 at cpu-used 4: the default is ~4x slower for a quality
            # difference nobody watching a converted clip will find.
            run_ffmpeg -i "$IN" -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -cpu-used 4 \
                -c:a libopus -b:a 128k "$OUT" ;;
        mp4|m4v)
            run_ffmpeg -i "$IN" -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
                -c:a aac -b:a 192k -movflags +faststart "$OUT" ;;
        mkv|mov)
            run_ffmpeg -i "$IN" -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
                -c:a aac -b:a 192k "$OUT" ;;
        avi)
            run_ffmpeg -i "$IN" -c:v mpeg4 -q:v 4 -c:a libmp3lame -q:a 2 "$OUT" ;;
    esac
elif is_image "$SRC"; then
    have magick || fail "ImageMagick is not installed"
    # Order matters in ImageMagick, and it is not cosmetic: a setting given
    # BEFORE the input is read is how the input is read (-background controls
    # what an SVG is rendered onto), and one given AFTER it applies to the
    # image already in hand. "-alpha remove" before the input is an operation
    # on an empty image list and fails outright -- measured, this is what made
    # the first PNG-to-JPG attempt produce nothing.
    PRE=()
    POST=()
    [ "$SRC" = "svg" ] && PRE+=(-background none)
    # JPG has no alpha channel. Left alone, ImageMagick writes the transparent
    # parts black, which is the worst possible answer for a logo on a dark app.
    case "$TO" in
        jpg) POST+=(-background white -alpha remove -alpha off -quality 92) ;;
        webp|avif|heic) POST+=(-quality 92) ;;
    esac
    magick -quiet "${PRE[@]}" "$IN" "${POST[@]}" "$OUT" \
        || fail "ImageMagick could not convert $NAME to .$TO"
elif is_archive "$SRC"; then
    have bsdtar || fail "bsdtar is not installed"
    TMP="$(mktemp -d)" || fail "could not make a temporary folder"
    trap 'rm -rf "$TMP"' EXIT
    # Unpack, then pack: an archive is not a stream that can be rewritten in
    # place, and this keeps every name, folder and mode exactly as it was.
    bsdtar -xf "$IN" -C "$TMP" || fail "could not unpack $NAME"
    ( cd "$TMP" && bsdtar -a -cf "$OUT" . ) || fail "could not write $OUT"
else
    fail "nothing here knows how to convert .$SRC"
fi

[ -s "$OUT" ] || fail "the conversion produced no file"

printf 'PROGRESS 100\n'
printf '%s\n' "$OUT"
