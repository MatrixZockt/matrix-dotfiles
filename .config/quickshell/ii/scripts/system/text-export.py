#!/usr/bin/env python3
"""Turn the text editor's document into a real document file.

    text-export.py --format pdf  --output out.pdf  --title "notes.txt"  < doc
    text-export.py --format html --output out.html --title "notes.txt"  < doc

WHY THIS EXISTS. The text editor saves plain text, and plain text is what it
edits -- but "save this as a PDF" is a normal thing to want from a notepad, and
a file named .pdf that actually contains plain text is a broken file that looks
like a bug in whatever opens it next. So the conversion happens here, on the way
out, and the editor keeps editing text: an export never changes what the
document IS.

NO DEPENDENCIES, DELIBERATELY. This machine has no cupsfilter, no ps2pdf, no
ghostscript, no pandoc and no libreoffice, so every obvious converter is a
"works until it doesn't" -- an export that silently dies on a fresh install is
worse than one that never existed. The PDF is written here, directly: the
base-14 Courier font is built into every reader, so no font is embedded and no
library is needed. Verified by rendering the result with pdftoppm and looking at
it.

WHAT THE PDF LOOKS LIKE. A4, generous margins, Courier 9pt on a 12pt baseline,
the document wrapped at the printable width (a text file's own line breaks are
kept; only lines that are too long are folded). A header carries the document's
name and a footer carries "Page n of m" -- both need a second pass, which is why
the pages are paginated before anything is written.

WHAT IT CANNOT DO. The base-14 fonts are single-byte: characters outside
Windows-1252 (CJK, emoji) have no glyph, and become '?' rather than being
dropped or silently corrupting the rest of the line. That is stated in the
result instead of being hidden.
"""

import argparse
import datetime
import os
import sys
import tempfile

# ── Page geometry (points; A4) ─────────────────────────────────────────────
PAGE_W = 595
PAGE_H = 842
MARGIN_X = 46
MARGIN_TOP = 56
MARGIN_BOTTOM = 48
BODY_SIZE = 9
LEADING = 12
HEADER_SIZE = 7.5
FOOTER_SIZE = 7.5

# Courier is fixed-pitch at 0.6em, so a character count IS a width.
CHAR_W = BODY_SIZE * 0.6
COLUMNS = int((PAGE_W - 2 * MARGIN_X) / CHAR_W)          # ≈ 93
BODY_TOP = PAGE_H - MARGIN_TOP
BODY_BOTTOM = MARGIN_BOTTOM + 24                          # above the footer rule
LINES_PER_PAGE = int((BODY_TOP - BODY_BOTTOM) / LEADING)  # ≈ 59


# ── Text preparation ───────────────────────────────────────────────────────
def read_document():
    """The document as a list of lines, with tabs expanded.

    \\r\\n and bare \\r are normalised (a file from Windows or an old Mac is not
    a single long line), and tabs become spaces on 8-column stops so the PDF and
    the HTML agree with what the editor showed.
    """
    raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    if raw.endswith("\n"):
        raw = raw[:-1]
    out = []
    for line in raw.split("\n"):
        out.append(line.expandtabs(8))
    return out or [""]


def fold(lines):
    """Wrap long lines at the printable width.

    A hard fold, not a word wrap: in a text file a long line is usually code or
    a log entry, where a break in the middle of a token keeps the columns
    aligned and a break at a space does not.
    """
    folded = []
    for line in lines:
        if len(line) <= COLUMNS:
            folded.append(line)
            continue
        for start in range(0, len(line), COLUMNS):
            folded.append(line[start:start + COLUMNS])
    return folded


def pdf_string(text):
    """Escape one line for a PDF literal string.

    `(`, `)` and `\\` end or escape a string and must be backslashed; every
    non-ASCII byte goes out as octal, which keeps the content stream seven-bit
    so no reader can disagree about its encoding. Windows-1252 is the mapping
    the font is declared with, so umlauts and typographic quotes survive and
    anything outside it becomes '?' rather than corrupting the line.
    """
    out = []
    for byte in text.encode("cp1252", errors="replace"):
        if byte in (0x28, 0x29, 0x5C):            # ( ) \
            out.append("\\" + chr(byte))
        elif 32 <= byte <= 126:
            out.append(chr(byte))
        else:
            out.append("\\%03o" % byte)
    return "".join(out)


# ── Pagination ─────────────────────────────────────────────────────────────
def paginate(folded):
    pages = []
    for start in range(0, max(len(folded), 1), LINES_PER_PAGE):
        pages.append(folded[start:start + LINES_PER_PAGE])
    return pages or [[""]]


# ── PDF writing ────────────────────────────────────────────────────────────
def page_stream(lines, page_no, page_count, title):
    """One page's content stream.

    Text is positioned with `Td` rather than `TJ`: every line is placed
    absolutely, so a rounding difference in one line's advance cannot walk the
    rest of the page off the margin.
    """
    parts = ["BT"]

    # Header: the document's name on the left, the date on the right.
    parts.append("/F2 %.1f Tf" % HEADER_SIZE)
    parts.append("1 0 0 1 %d %d Tm" % (MARGIN_X, PAGE_H - 30))
    parts.append("(%s) Tj" % pdf_string(title))
    stamp = datetime.date.today().isoformat()
    parts.append("1 0 0 1 %d %d Tm" % (PAGE_W - MARGIN_X - int(len(stamp) * HEADER_SIZE * 0.6),
                                       PAGE_H - 30))
    parts.append("(%s) Tj" % pdf_string(stamp))

    # Hairline under the header, and one above the footer.
    parts.append("0.6 w 0.65 0.65 0.65 RG")
    parts.append("%d %d m %d %d l S" % (MARGIN_X, PAGE_H - 38, PAGE_W - MARGIN_X, PAGE_H - 38))
    parts.append("%d %d m %d %d l S" % (MARGIN_X, MARGIN_BOTTOM + 12,
                                        PAGE_W - MARGIN_X, MARGIN_BOTTOM + 12))

    # Body.
    parts.append("0 0 0 RG 0 0 0 rg")
    parts.append("/F1 %.1f Tf" % BODY_SIZE)
    y = BODY_TOP
    for line in lines:
        parts.append("1 0 0 1 %d %d Tm" % (MARGIN_X, y))
        if line.strip():
            parts.append("(%s) Tj" % pdf_string(line))
        y -= LEADING

    # Footer.
    parts.append("/F2 %.1f Tf 0.35 0.35 0.35 rg" % FOOTER_SIZE)
    label = "Page %d of %d" % (page_no, page_count)
    parts.append("1 0 0 1 %d %d Tm" % (PAGE_W - MARGIN_X - int(len(label) * FOOTER_SIZE * 0.6),
                                       MARGIN_BOTTOM - 2))
    parts.append("(%s) Tj" % pdf_string(label))

    parts.append("ET")
    return "\n".join(parts)


def write_pdf(path, lines, title):
    folded = fold(lines)
    pages = paginate(folded)
    page_count = len(pages)

    objects = []          # 1-based; objects[n-1] is object n

    def add(body):
        objects.append(body)
        return len(objects)

    # Reserved up front so the pages can refer to each other's numbers: the
    # catalog and the page tree are filled in last, and the two fonts are known
    # before any page mentions them.
    catalog_num = 1
    pages_num = 2
    font1_num = 3
    font2_num = 4
    objects.append(None)
    objects.append(None)
    objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Courier "
                   "/Encoding /WinAnsiEncoding >>")
    objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
                   "/Encoding /WinAnsiEncoding >>")

    page_nums = []
    for index, page_lines in enumerate(pages, start=1):
        stream = page_stream(page_lines, index, page_count, title)
        content_num = add("<< /Length %d >>\nstream\n%s\nendstream"
                          % (len(stream.encode("latin-1", errors="replace")), stream))
        page_num = add("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] "
                       "/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> "
                       "/Contents %d 0 R >>"
                       % (pages_num, PAGE_W, PAGE_H, font1_num, font2_num, content_num))
        page_nums.append(page_num)

    kids = " ".join("%d 0 R" % n for n in page_nums)
    objects[catalog_num - 1] = "<< /Type /Catalog /Pages %d 0 R >>" % pages_num
    objects[pages_num - 1] = "<< /Type /Pages /Count %d /Kids [%s] >>" % (page_count, kids)

    return emit_pdf(path, objects)


def emit_pdf(path, objects):
    """Serialise the object table with a correct xref, atomically onto path."""
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += ("%d 0 obj\n%s\nendobj\n" % (number, body)).encode("latin-1")
    xref_at = len(out)
    out += ("xref\n0 %d\n" % (len(objects) + 1)).encode("ascii")
    out += b"0000000000 65535 f \n"
    for offset in offsets[1:]:
        out += ("%010d 00000 n \n" % offset).encode("ascii")
    out += ("trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, 1, xref_at)).encode("ascii")

    write_atomic(path, out)
    return 0


def write_atomic(path, payload):
    """Write beside the target and rename over it.

    Same rule the editor's own save follows: a crash or a full disk must not
    leave a truncated file where a working document used to be.
    """
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, temp = tempfile.mkstemp(prefix=".ii-export-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


# ── HTML writing ───────────────────────────────────────────────────────────
def write_html(path, lines, title):
    import html

    body = html.escape("\n".join(lines))
    stamp = datetime.date.today().isoformat()
    document = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<style>
  :root { color-scheme: light; }
  html { background: #f4f4f2; }
  body {
    margin: 0;
    padding: 48px 24px 64px;
    font-family: "Iosevka", "JetBrains Mono", ui-monospace, "DejaVu Sans Mono", monospace;
    color: #16181d;
  }
  main {
    max-width: 78ch;
    margin: 0 auto;
    background: #fff;
    border: 1px solid #e2e2de;
    border-radius: 14px;
    padding: 40px 44px 44px;
    box-shadow: 0 1px 2px rgba(16, 18, 24, .04), 0 12px 32px -18px rgba(16, 18, 24, .18);
  }
  h1 {
    font: 600 14px/1.3 ui-sans-serif, system-ui, sans-serif;
    letter-spacing: .01em;
    color: #16181d;
    margin: 0 0 4px;
  }
  .meta {
    font: 12px/1.4 ui-sans-serif, system-ui, sans-serif;
    color: #6b7280;
    margin: 0 0 28px;
    padding-bottom: 16px;
    border-bottom: 1px solid #eeece7;
  }
  pre {
    margin: 0;
    font-size: 13px;
    line-height: 1.6;
    white-space: pre-wrap;
    word-break: break-word;
    tab-size: 8;
  }
</style>
</head>
<body>
<main>
<h1>%s</h1>
<p class="meta">Plain text · exported %s</p>
<pre>%s</pre>
</main>
</body>
</html>
""" % (html.escape(title), html.escape(title), stamp, body)
    write_atomic(path, document.encode("utf-8"))
    return 0


# ── Entry point ────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--format", required=True, choices=("pdf", "html"))
    parser.add_argument("--output", required=True)
    parser.add_argument("--title", default="document")
    args = parser.parse_args()

    lines = read_document()
    if args.format == "pdf":
        return write_pdf(args.output, lines, args.title)
    return write_html(args.output, lines, args.title)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
