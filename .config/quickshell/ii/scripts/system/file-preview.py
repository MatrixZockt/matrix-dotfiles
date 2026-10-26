#!/usr/bin/env python3
"""Turn a file into something the Files app's preview pane can DRAW.

    python3 file-preview.py <kind> <path>

…and one JSON object comes back on stdout:

    {"view": "text"|"table"|"list", "text": "...", "table": {...},
     "entries": [...], "note": "..."}

WHY ONE SCRIPT AND NOT ONE PROCESS PER FORMAT IN THE QML.
The pane asks "what is in this file?" and the answer is always the same
shape, however the file is read: some text, or a grid of cells, or a list
of names. Doing that in QML means a Python dependency at every call site;
doing it here means the pane has three views and no format knowledge at
all, and a new format is a branch in one file.

EVERYTHING USED HERE IS ALREADY ON THE SYSTEM: python3's own stdlib
(json, csv, zipfile, tarfile, gzip/bz2/lzma, html.parser), plus `file` for
naming an unknown binary. Nothing is installed, so nothing here can fail
on a machine that has not been prepared for it -- and where a format
genuinely needs a tool that is missing (.doc, .xls), the answer says so in
words instead of showing a blank panel.

Output is bounded on purpose: a 2 GB log is not a preview. Text is capped,
tables are capped at MAX_ROWS x MAX_COLS, archive listings at MAX_ENTRIES.
`note` carries the count that was cut, so "showing the first 300" is
something the user is told rather than something they discover.
"""

import bz2
import csv
import gzip
import io
import json
import lzma
import os
import re
import subprocess
import sys
import tarfile
import zipfile
from html.parser import HTMLParser

TEXT_CAP = 20000          # characters of text handed to the pane
READ_CAP = 8 * 1024 * 1024
MAX_ROWS = 300
MAX_COLS = 30
MAX_ENTRIES = 400
HEX_BYTES = 256


# ── small helpers ───────────────────────────────────────────────────────────

def suffix(path):
    name = os.path.basename(path)
    i = name.rfind(".")
    return name[i + 1:].lower() if i > 0 else ""


def size_text(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return ""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (round(n), unit)) if (n >= 10 or unit == "B") \
                else ("%.1f %s" % (n, unit))
        n /= 1024.0
    return ""


def read_text(path, limit=READ_CAP):
    with open(path, "rb") as fh:
        raw = fh.read(limit)
    return raw.decode("utf-8", "replace")


def clip(text, limit=TEXT_CAP):
    text = text or ""
    if len(text) <= limit:
        return text
    return text[:limit] + "\n\n… (truncated)"


def tidy(lines, keep_blank=False):
    """Collapse the runs of blank lines every markup conversion produces."""
    out = []
    for line in lines:
        line = re.sub(r"[ \t]+", " ", line).strip()
        if not line:
            if keep_blank and out and out[-1] != "":
                out.append("")
            continue
        out.append(line)
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out)


def file_type(path):
    try:
        return subprocess.run(["file", "-b", path], capture_output=True,
                              text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def text_view(text, note=""):
    return {"view": "text", "text": clip(text), "note": note}


def table_view(header, rows, note="", total_rows=None, total_cols=None):
    return {
        "view": "table",
        "table": {
            "header": header,
            "rows": rows,
            "totalRows": total_rows if total_rows is not None else len(rows),
            "totalCols": total_cols if total_cols is not None else max(
                [len(header)] + [len(r) for r in rows] or [0]),
        },
        "note": note,
    }


# ── JSON ────────────────────────────────────────────────────────────────────

def describe_json(value):
    if isinstance(value, dict):
        return "object · %d %s" % (len(value), "key" if len(value) == 1 else "keys")
    if isinstance(value, list):
        return "array · %d %s" % (len(value), "item" if len(value) == 1 else "items")
    if isinstance(value, bool):
        return "boolean"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return "number"
    return "string"


def do_json(path):
    raw = read_text(path, READ_CAP)
    try:
        value = json.loads(raw)
    except ValueError as error:
        # Half-written JSON is common (a log, a partial download) and is still
        # worth reading: the text is the answer, the note is the apology.
        return text_view(raw[:8000], note="not valid JSON (%s) — shown as text"
                         % str(error).split(":")[0])
    pretty = json.dumps(value, indent=2, ensure_ascii=False)
    note = describe_json(value)
    if len(pretty) > TEXT_CAP:
        note += " · first %d of %d characters" % (TEXT_CAP, len(pretty))
    return text_view(pretty, note=note)


# ── CSV / TSV, and every spreadsheet that is really one ─────────────────────

def sniff_delimiter(sample, fallback):
    try:
        return csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
    except Exception:
        return fallback


def do_table(path, delimiter=None):
    raw = read_text(path)
    if not raw.strip():
        return table_view([], [], note="empty file")
    fallback = "\t" if suffix(path) in ("tsv", "tab") else ","
    delim = delimiter or sniff_delimiter(raw[:8192], fallback)
    reader = csv.reader(io.StringIO(raw), delimiter=delim)
    rows, total = [], 0
    header = None
    for row in reader:
        total += 1
        if total > 200000:               # a counting guard, not a preview cap
            break
        cells = [(c or "").strip() for c in row][:MAX_COLS]
        if header is None:
            header = cells
            continue
        if len(rows) < MAX_ROWS:
            rows.append(cells)
    header = header or []
    width = max([len(header)] + [len(r) for r in rows] or [0])
    data_rows = max(total - 1, 0)                  # the first line is the header
    note = "%d data %s × %d %s" % (
        data_rows, "row" if data_rows == 1 else "rows",
        width, "column" if width == 1 else "columns")
    if data_rows > MAX_ROWS:
        note += " · showing the first %d rows" % MAX_ROWS
    return table_view(header, rows, note=note, total_rows=max(total - 1, 0),
                      total_cols=width)


# ── HTML / XML: the words inside the tags ───────────────────────────────────

BLOCK_TAGS = {
    "p", "div", "br", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
    "section", "article", "header", "footer", "table", "pre", "blockquote",
    "ul", "ol", "dl", "dt", "dd", "hr", "title", "body", "head",
}
# `li` is deliberately NOT a block tag: it is a line break PLUS a bullet, and
# flushing on the tag would emit the bullet on a line of its own. It is handled
# by hand in the parser below.


class _TextExtractor(HTMLParser):
    """HTML → its readable text.

    Script and style content is dropped (a page that previews as 400 lines of
    CSS has not been previewed), block elements become line breaks so the
    result keeps the shape of the document, and character references are
    decoded by the parser itself.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines = []
        self.buffer = []
        self.skip = 0
        self.title = ""
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "noscript", "template"):
            self.skip += 1
            return
        if tag == "title":
            self._in_title = True
        if tag == "li":
            self._flush()
            self.buffer.append("• ")
        if tag in BLOCK_TAGS:
            self._flush()

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript", "template"):
            self.skip = max(0, self.skip - 1)
            return
        if tag == "title":
            self._in_title = False
            self.title = self.title.strip()
        if tag in BLOCK_TAGS:
            self._flush()

    def handle_data(self, data):
        if self.skip:
            return
        if self._in_title:
            self.title += data
            return
        self.buffer.append(data)

    def _flush(self):
        line = "".join(self.buffer)
        self.buffer = []
        line = re.sub(r"\s+", " ", line).strip()
        if line:
            self.lines.append(line)

    def text(self):
        self._flush()
        return tidy(self.lines, keep_blank=False)


def do_markup(path):
    raw = read_text(path)
    parser = _TextExtractor()
    try:
        parser.feed(raw)
        parser.close()
    except Exception:
        pass
    body = parser.text()
    if not body:
        # A page that is nothing but scripts, or a stray fragment: the source
        # is still the honest answer.
        return text_view(re.sub(r"<[^>]+>", "", raw)[:8000],
                         note="no readable text in this document")
    note = "text of the document"
    if parser.title:
        note = parser.title
    return text_view(body, note=note)


# ── Markdown: read it, do not show its punctuation ──────────────────────────

def do_markdown(path):
    raw = read_text(path)
    raw = re.sub(r"\A---\n.*?\n---\n", "", raw, flags=re.S)     # front matter
    out = []
    in_code = False
    for line in raw.splitlines():
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            out.append("    " + line)
            continue
        line = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", line)         # images
        line = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", line)   # links
        line = re.sub(r"^\s{0,3}#{1,6}\s*", "", line)                 # headings
        line = re.sub(r"^\s{0,3}>\s?", "", line)                      # quotes
        line = re.sub(r"^\s*[-*+]\s+", "• ", line)                    # bullets
        line = re.sub(r"[\*_`]{1,3}", "", line)                       # emphasis
        line = re.sub(r"^\s*([-*_]\s*){3,}$", "", line)               # rules
        out.append(line)
    body = tidy(out, keep_blank=True)
    words = len(body.split())
    return text_view(body, note="%d %s" % (words, "word" if words == 1 else "words"))


# ── Archives: what is inside, not what it is ────────────────────────────────

def _entry(name, size, is_dir, modified=""):
    return {"name": name, "size": size_text(size) if not is_dir else "",
            "dir": is_dir, "modified": modified}


def do_archive(path):
    entries, total = [], 0
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as zf:
                for info in zf.infolist():
                    total += 1
                    if len(entries) < MAX_ENTRIES:
                        entries.append(_entry(info.filename, info.file_size,
                                              info.is_dir()))
        elif tarfile.is_tarfile(path):
            with tarfile.open(path) as tf:
                for m in tf:
                    total += 1
                    if len(entries) < MAX_ENTRIES:
                        entries.append(_entry(m.name, m.size, m.isdir()))
        elif suffix(path) in ("gz", "bz2", "xz"):
            opener = {"gz": gzip.open, "bz2": bz2.open, "xz": lzma.open}[
                suffix(path)]
            with opener(path, "rb") as fh:
                head = fh.read(20000)
            inner = os.path.basename(path).rsplit(".", 1)[0]
            total = 1
            entries = [_entry(inner, len(head), False)]
            try:
                text = head.decode("utf-8")
            except UnicodeDecodeError:
                text = ""
            if text and "\x00" not in text:
                return text_view(text, note="compressed single file · shown "
                                            "decompressed")
        else:
            raise ValueError("unsupported")
    except Exception:
        return {"view": "list", "entries": [], "note":
                "no reader for this archive — " + (file_type(path) or "unknown type")}

    dirs = sum(1 for e in entries if e["dir"])
    note = "%d %s" % (total, "item" if total == 1 else "items")
    if dirs:
        note += " · %d %s" % (dirs, "folder" if dirs == 1 else "folders")
    if total > len(entries):
        note += " · showing the first %d" % len(entries)
    return {"view": "list", "entries": entries, "note": note}


# ── Office documents, unpacked the way any other zip is ─────────────────────

def _zip_read(zf, name):
    try:
        return zf.read(name).decode("utf-8", "replace")
    except KeyError:
        return ""


def _xml_text(xml, block_tags):
    """Text of an OOXML/ODF fragment: one line per block element."""
    for tag in block_tags:
        xml = xml.replace("</%s>" % tag, "</%s>\n" % tag)
    xml = re.sub(r"<[^>]+>", "", xml)
    xml = xml.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    xml = xml.replace("&quot;", '"').replace("&apos;", "'")
    return tidy(xml.splitlines())


def do_docx(path):
    with zipfile.ZipFile(path) as zf:
        xml = _zip_read(zf, "word/document.xml")
    if not xml:
        return text_view("", note="this .docx has no readable document part")
    body = _xml_text(xml, ["w:p"])
    paragraphs = len([l for l in body.splitlines() if l])
    return text_view(body, note="Word document · %d %s"
                     % (paragraphs, "paragraph" if paragraphs == 1 else "paragraphs"))


def do_odt(path):
    with zipfile.ZipFile(path) as zf:
        xml = _zip_read(zf, "content.xml")
    if not xml:
        return text_view("", note="this .odt has no readable content part")
    body = _xml_text(xml, ["text:p", "text:h"])
    paragraphs = len([l for l in body.splitlines() if l])
    return text_view(body, note="OpenDocument text · %d %s"
                     % (paragraphs, "paragraph" if paragraphs == 1 else "paragraphs"))


def do_pptx(path):
    with zipfile.ZipFile(path) as zf:
        slides = [n for n in zf.namelist()
                  if re.match(r"ppt/slides/slide\d+\.xml$", n)]
        slides.sort(key=lambda n: int(re.search(r"(\d+)\.xml$", n).group(1)))
        out = []
        for index, name in enumerate(slides, 1):
            body = _xml_text(_zip_read(zf, name), ["a:p"])
            out.append("— Slide %d —" % index)
            out.append(body)
        body = tidy("\n".join(out).splitlines(), keep_blank=True)
    return text_view(body, note="%d %s" % (len(slides),
                                           "slide" if len(slides) == 1 else "slides"))


def do_epub(path):
    with zipfile.ZipFile(path) as zf:
        names = sorted(n for n in zf.namelist()
                       if re.search(r"\.x?html?$", n, re.I))
        parts = []
        for name in names[:3]:
            parser = _TextExtractor()
            try:
                parser.feed(_zip_read(zf, name))
                parser.close()
            except Exception:
                continue
            text = parser.text()
            if text:
                parts.append(text)
        body = "\n\n".join(parts)
    note = "EPUB · first %d %s" % (len(parts), "chapter" if len(parts) == 1
                                   else "chapters")
    return text_view(body, note=note)


def _column_index(ref):
    letters = re.match(r"([A-Z]+)", ref or "")
    if not letters:
        return 0
    n = 0
    for ch in letters.group(1):
        n = n * 26 + (ord(ch) - 64)
    return max(n - 1, 0)


def do_xlsx(path):
    with zipfile.ZipFile(path) as zf:
        shared = []
        shared_xml = _zip_read(zf, "xl/sharedStrings.xml")
        for si in re.findall(r"<si>(.*?)</si>", shared_xml, re.S):
            shared.append("".join(re.findall(r"<t[^>]*>(.*?)</t>", si, re.S)))
        sheets = sorted(n for n in zf.namelist()
                        if re.match(r"xl/worksheets/sheet\d+\.xml$", n))
        if not sheets:
            return text_view("", note="this workbook has no readable sheet")
        sheet_xml = _zip_read(zf, sheets[0])
        grid = []
        for row_xml in re.findall(r"<row[^>]*>(.*?)</row>", sheet_xml, re.S):
            cells = {}
            for attrs, body in re.findall(r"<c([^>]*)>(.*?)</c>", row_xml, re.S):
                ref = re.search(r'r="([A-Z]+)\d+"', attrs)
                kind = re.search(r't="([^"]+)"', attrs)
                value = ""
                if kind and kind.group(1) == "inlineStr":
                    value = "".join(re.findall(r"<t[^>]*>(.*?)</t>", body, re.S))
                else:
                    found = re.search(r"<v>(.*?)</v>", body, re.S)
                    if found:
                        value = found.group(1)
                        if kind and kind.group(1) == "s":
                            try:
                                value = shared[int(value)]
                            except (ValueError, IndexError):
                                pass
                cells[_column_index(ref.group(1) if ref else "A")] = value
            if cells:
                width = min(max(cells) + 1, MAX_COLS)
                grid.append([cells.get(i, "") for i in range(width)])
            if len(grid) > MAX_ROWS:
                break
    if not grid:
        return table_view([], [], note="empty sheet")
    header, rows = grid[0], grid[1:]
    width = max([len(header)] + [len(r) for r in rows] or [0])
    note = "sheet 1 of %d · %d %s × %d %s" % (
        len(sheets), len(rows), "row" if len(rows) == 1 else "rows",
        width, "column" if width == 1 else "columns")
    return table_view(header, rows, note=note)


def do_ods(path):
    with zipfile.ZipFile(path) as zf:
        xml = _zip_read(zf, "content.xml")
    grid = []
    for row_xml in re.findall(r"<table:table-row[^>]*>(.*?)</table:table-row>",
                              xml, re.S):
        cells = []
        for cell in re.findall(r"<table:table-cell(.*?)(?:/>|>(.*?)</table:table-cell>)",
                               row_xml, re.S):
            attrs, body = cell
            text = " ".join(re.findall(r"<text:p[^>]*>(.*?)</text:p>", body or "", re.S))
            text = re.sub(r"<[^>]+>", "", text).strip()
            cells.append(text)
            if len(cells) >= MAX_COLS:
                break
        if cells:
            grid.append(cells)
        if len(grid) > MAX_ROWS:
            break
    if not grid:
        return table_view([], [], note="empty sheet")
    header, rows = grid[0], grid[1:]
    width = max([len(header)] + [len(r) for r in rows] or [0])
    return table_view(header, rows, note="sheet 1 · %d %s × %d %s" % (
        len(rows), "row" if len(rows) == 1 else "rows",
        width, "column" if width == 1 else "columns"))


def do_rtf(path):
    raw = read_text(path)
    text = re.sub(r"\\'([0-9a-f]{2})", lambda m: bytes([int(m.group(1), 16)])
                  .decode("latin-1"), raw)
    # Groups that are settings rather than text: the font table, the colour
    # table, embedded objects. Dropped whole, or every preview of a .rtf opens
    # with a line of typeface names.
    text = re.sub(r"\{\\(?:\*|fonttbl|colortbl|stylesheet|info|pict)[^{}]*\}", "",
                  text, flags=re.S)
    text = re.sub(r"\\par[d]?\b", "\n", text)               # paragraphs
    text = re.sub(r"\\line\b", "\n", text)
    text = re.sub(r"\\tab\b", "\t", text)
    text = re.sub(r"\\[a-z]+-?\d* ?", "", text)              # control words
    text = text.replace("\\{", "{").replace("\\}", "}").replace("\\\n", "\n")
    text = re.sub(r"[{}]", "", text)
    return text_view(tidy(text.splitlines(), keep_blank=True), note="rich text")


def do_office(path):
    ext = suffix(path)
    reader = {
        "docx": do_docx, "docm": do_docx,
        "odt": do_odt, "ott": do_odt,
        "pptx": do_pptx, "odp": do_pptx,
        "epub": do_epub,
        "xlsx": do_xlsx, "xlsm": do_xlsx,
        "ods": do_ods, "ots": do_ods,
        "rtf": do_rtf,
    }.get(ext)
    if reader is None:
        # The 1990s binaries: zip cannot open them and no converter is
        # installed, so the honest answer is the type and nothing invented.
        return text_view("", note="no reader for .%s on this system (%s) — "
                                  "install libreoffice or antiword"
                         % (ext, file_type(path) or "binary file"))
    try:
        return reader(path)
    except Exception as error:
        return text_view("", note="could not read this .%s (%s)"
                                 % (ext, type(error).__name__))


# ── Anything else: looked at, then named and shown as bytes ─────────────────

def hexdump(path):
    try:
        with open(path, "rb") as fh:
            raw = fh.read(HEX_BYTES)
    except Exception:
        return ""
    lines = []
    for offset in range(0, len(raw), 16):
        chunk = raw[offset:offset + 16]
        hexed = " ".join("%02x" % b for b in chunk)
        hexed = hexed.ljust(47)
        printable = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append("%08x  %s  |%s|" % (offset, hexed, printable))
    return "\n".join(lines)


def do_binary(path):
    kind = file_type(path) or "binary file"
    body = hexdump(path)
    try:
        total = os.path.getsize(path)
    except OSError:
        total = 0
    note = "%s · first %d of %s" % (kind, min(total, HEX_BYTES), size_text(total))
    return text_view(body, note=note)


def looks_like_text(path):
    """Is this file text wearing an unknown extension?"""
    try:
        with open(path, "rb") as fh:
            sample = fh.read(8192)
    except Exception:
        return False
    if not sample:
        return True
    if b"\x00" in sample:
        return False
    try:
        sample.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def do_auto(path):
    """No extension we know: look at the bytes rather than refuse the file."""
    if looks_like_text(path):
        body = read_text(path, 4000)
        return text_view(body, note="text · not a known extension")
    return do_binary(path)


READERS = {
    "json": do_json,
    "table": do_table,
    "markup": do_markup,
    "markdown": do_markdown,
    "archive": do_archive,
    "office": do_office,
    "binary": do_binary,
    "auto": do_auto,
}


def main(argv):
    if len(argv) < 3:
        print(json.dumps({"view": "text", "text": "",
                          "note": "usage: file-preview.py KIND PATH"}))
        return 0
    kind, path = argv[1], argv[2]
    if not os.path.exists(path):
        print(json.dumps({"view": "text", "text": "",
                          "note": "this file is gone"}))
        return 0
    if os.path.isdir(path):
        print(json.dumps({"view": "text", "text": "",
                          "note": "that is a folder"}))
        return 0
    reader = READERS.get(kind, do_auto)
    try:
        result = reader(path)
    except Exception as error:
        result = text_view("", note="could not read this file (%s)"
                                  % type(error).__name__)
    result.setdefault("view", "text")
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
