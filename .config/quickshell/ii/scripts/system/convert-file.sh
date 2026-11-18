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

# ── Documents, offered only when this machine can actually do them ───────
#
# The rows are added to the table above by ASKING, not by assuming: a "Convert
# to PDF" under every text file on a machine with no renderer is a promise the
# conversion cannot keep, and the menu is built from this list. So the PDF
# rows exist only if a headless browser is here, and the text back out of a PDF
# only if poppler is.
have_bin() { command -v "$1" >/dev/null 2>&1; }

# What a helper said when it refused. Nothing reads it -- the reason reaches the
# window through fail() -- but a person debugging a render wants the browser's
# own words, and they are here.
LOG="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/convert-file.log"

# The renderer: Chrome or Chromium, whichever this machine has. Not Brave
# first, even though it is installed: its print-to-pdf path goes through the
# same Chromium engine but the launcher is a wrapper here, and the two stocks
# print identically anyway.
PDF_BROWSER=""
for candidate in google-chrome-stable chromium chromium-browser google-chrome brave; do
    if have_bin "$candidate"; then
        PDF_BROWSER="$candidate"
        break
    fi
done

if [ -n "$PDF_BROWSER" ]; then
    for ext in txt log md markdown html htm; do
        MATRIX="$MATRIX
$ext:pdf"
    done
fi
have_bin pdftotext && MATRIX="$MATRIX
pdf:txt"

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
is_document() {
    case "$1" in txt|log|md|markdown|html|htm) return 0 ;; esac
    return 1
}

# ── What the browser is handed ──────────────────────────────────────────
#
# An HTML file on stdout. HTML goes through untouched -- it already says how it
# wants to look. Markdown and plain text get a document around them, because a
# browser printing a bare .md shows one long line: the markdown is converted
# here (this machine has no pandoc, and pulling one in for this would be a
# dependency the conversion cannot justify), and plain text is put in a <pre>
# so its line breaks and alignment survive.
#
# The ANSI escapes are dropped on the way for text and logs: a colour code in a
# PDF is not a colour, it is "[0;32m" in the middle of a sentence.
document_html() {   # $1 = source suffix, $2 = file; HTML on stdout
    case "$1" in
        html|htm) cat -- "$2" ;;
        *) python3 - "$1" "$2" <<'PY'
import html, re, sys

kind, path = sys.argv[1], sys.argv[2]
try:
    raw = open(path, encoding="utf-8", errors="replace").read()
except OSError as problem:
    print("unreadable: %s" % problem, file=sys.stderr)
    raise SystemExit(1)
raw = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw).replace("\r\n", "\n")


def inline(text):
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<i>\1</i>", out)
    out = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', out)
    return out


def markdown(src):
    """Headings, paragraphs, lists, quotes, rules, fences, tables, inline.

    Not a Markdown implementation -- the 95% a note or a README is made of.
    Anything it does not know is left as the paragraph it was written in, so
    nothing disappears.
    """
    lines = src.splitlines()
    out, para, i, list_tag = [], [], 0, None

    def flush_para():
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()

    def close_list():
        nonlocal list_tag
        if list_tag:
            out.append("</%s>" % list_tag)
            list_tag = None

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("```"):
            flush_para(); close_list()
            i += 1
            block = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                block.append(lines[i]); i += 1
            i += 1
            out.append("<pre><code>" + html.escape("\n".join(block)) + "</code></pre>")
            continue
        if not stripped:
            flush_para(); close_list(); i += 1; continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading:
            flush_para(); close_list()
            level = len(heading.group(1))
            out.append("<h%d>%s</h%d>" % (level, inline(heading.group(2)), level))
            i += 1; continue
        if re.match(r"^(-{3,}|\*{3,}|_{3,})$", stripped):
            flush_para(); close_list()
            out.append("<hr/>"); i += 1; continue
        if stripped.startswith(">"):
            flush_para(); close_list()
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip()[1:].strip()); i += 1
            out.append("<blockquote>" + inline(" ".join(quote)) + "</blockquote>")
            continue
        if ("|" in stripped and i + 1 < len(lines)
                and "-" in lines[i + 1]
                and re.match(r"^\|?[\s:|-]+\|?$", lines[i + 1].strip())):
            flush_para(); close_list()

            def cells(row):
                return [c.strip() for c in row.strip().strip("|").split("|")]

            head = cells(lines[i]); i += 2
            rows = []
            while i < len(lines) and lines[i].strip() and "|" in lines[i]:
                rows.append(cells(lines[i])); i += 1
            table = ["<table><thead><tr>",
                     "".join("<th>%s</th>" % inline(c) for c in head),
                     "</tr></thead><tbody>"]
            for row in rows:
                table.append("<tr>" + "".join("<td>%s</td>" % inline(c) for c in row) + "</tr>")
            table.append("</tbody></table>")
            out.append("".join(table)); continue
        item = re.match(r"^\s*([-*+]|(\d+)\.)\s+(.*)$", line)
        if item:
            flush_para()
            wanted = "ol" if item.group(2) else "ul"
            if list_tag != wanted:
                close_list()
                out.append("<%s>" % wanted)
                list_tag = wanted
            out.append("<li>" + inline(item.group(3)) + "</li>")
            i += 1; continue
        para.append(stripped); i += 1
    flush_para(); close_list()
    return "\n".join(out)


STYLE = """
@page { size: A4; margin: 18mm 16mm; }
body { font-family: "Inter", "DejaVu Sans", "Liberation Sans", sans-serif;
       font-size: 10.5pt; line-height: 1.55; color: #14161a; }
h1, h2, h3, h4 { line-height: 1.25; margin: 1.3em 0 .45em; }
h1 { font-size: 20pt; } h2 { font-size: 15pt; } h3 { font-size: 12.5pt; }
p { margin: .55em 0; }
pre, code { font-family: "JetBrains Mono", "DejaVu Sans Mono", monospace; font-size: 9pt; }
pre { background: #f4f4f5; padding: 9px 11px; border-radius: 4px; white-space: pre-wrap; }
code { background: #f4f4f5; padding: 0 3px; border-radius: 3px; }
blockquote { border-left: 3px solid #c9c9cf; margin: .8em 0; padding: 0 12px; color: #44474d; }
table { border-collapse: collapse; margin: .7em 0; }
th, td { border: 1px solid #c2c2c8; padding: 4px 9px; text-align: left; vertical-align: top; }
hr { border: 0; border-top: 1px solid #cfcfd4; margin: 1.2em 0; }
pre.plain { white-space: pre-wrap; word-wrap: break-word; background: none; padding: 0; }
"""

if kind in ("md", "markdown"):
    body = markdown(raw)
    title = path.rsplit("/", 1)[-1]
else:
    body = '<pre class="plain">' + html.escape(raw) + "</pre>"
    title = path.rsplit("/", 1)[-1]

document = ("<!doctype html>\n<html><head><meta charset=\"utf-8\">"
            + "<title>" + html.escape(title) + "</title>"
            + "<style>" + STYLE + "</style></head><body>\n"
            + body + "\n</body></html>\n")
sys.stdout.buffer.write(document.encode("utf-8"))
PY
    esac
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
elif [ "$TO" = "pdf" ] && is_document "$SRC"; then
    have_bin "$PDF_BROWSER" || fail "no headless browser to render a PDF with"
    HTML_FILE="$(mktemp "${TMPDIR:-/tmp}/convert-doc.XXXXXX.html")" || fail "could not make a temporary file"
    PROFILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/convert-profile.XXXXXX")"
    # Everything is cleaned up however this ends, cancelled included.
    trap 'rm -rf "${HTML_FILE:-}" "${PROFILE_DIR:-}"; pkill -TERM -P $$ 2>/dev/null; rm -f "$OUT" "${PROGRESS_FILE:-}"; echo "cancelled" >&2; exit 130' TERM INT HUP
    document_html "$SRC" "$IN" > "$HTML_FILE" || fail "could not read $NAME as text"
    # -print-to-pdf writes the file and --headless (the OLD headless, not
    # --headless=new) EXITS when it is done. Measured here: 0.49 s and rc=0,
    # while --headless=new printed the same PDF and then sat there until it was
    # killed, which would have left a browser running per conversion.
    #
    # The PDF is written to a temporary name and moved into place, so a cancel
    # or a crash never leaves a half-written PDF wearing the real name.
    PRINTER="$(mktemp "${TMPDIR:-/tmp}/convert-out.XXXXXX.pdf")"
    timeout 120 "$PDF_BROWSER" --headless --disable-gpu --no-first-run \
        --no-default-browser-check --disable-extensions --disable-sync \
        --user-data-dir="$PROFILE_DIR" --no-pdf-header-footer \
        --print-to-pdf="$PRINTER" "file://$HTML_FILE" >>"$LOG" 2>&1
    [ -s "$PRINTER" ] || fail "the browser could not render $NAME to PDF"
    mv -f "$PRINTER" "$OUT" || fail "could not write $OUT"
    # mktemp makes its files 0600. A document that lands next to the original
    # should be an ordinary file, readable like the one it came from -- a PDF
    # only its creator can open is a bug that shows up much later.
    chmod 644 "$OUT"
    rm -rf "$HTML_FILE" "$PROFILE_DIR"
elif [ "$SRC" = "pdf" ] && [ "$TO" = "txt" ]; then
    have_bin pdftotext || fail "pdftotext is not installed"
    pdftotext -enc UTF-8 -nopgbrk "$IN" "$OUT" || fail "pdftotext could not read $NAME"
    # A scan is a PDF full of pictures of words. Saying so is the difference
    # between "it does not work" and "this file has no text in it".
    [ -s "$OUT" ] || fail "$NAME has no text layer — a scanned PDF needs OCR"
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
