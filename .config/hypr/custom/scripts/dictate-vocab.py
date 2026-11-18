#!/usr/bin/env python3
"""
Spell the names this desktop actually uses, whatever whisper heard.

WHY THIS EXISTS
    words.txt is handed to whisper as its initial prompt, and whisper treats a
    prompt as a HINT: it follows it when the audio is ambiguous and ignores it
    when it is clear. Measured here 2026-11-18 against ggml-large-v3-turbo: the
    540-character prompt (56 terms, 233 tokens, of which whisper keeps the last
    223) IS being applied -- "prompt time" appears in its timings and there is
    no truncation warning -- and "Higgsfield" still came back as "a pig's
    field". A prompt cannot promise a spelling.

    fixes.txt can promise one, but only for the manglings somebody thought of.
    That is why a name added to words.txt kept coming out wrong: nothing turned
    the promise into a correction.

    So this reads BOTH files on every dictation and rewrites the finished
    sentence:

      1. fixes.txt, exactly as written (heard => meant), applied first. It wins
         over everything below, including for ordinary words -- if a pair says
         "cloud => Claude" then that is what happens.
      2. every term in words.txt, matched by SOUND rather than by spelling, so
         "Higsfield", "Higgs Field", "Hicks field" and "Higgsfelt" all become
         "Higgsfield" without anybody listing them.

    No model, no GPU, no network, ~45ms for a sentence, and it cannot lose a
    word: the audio is not touched and anything that does not match is left
    exactly as it was written.

HOW A MATCH IS JUDGED
    Each vocabulary term becomes a phonetic skeleton: lower case, accent-free,
    doubled letters collapsed, then the consonant frame that survives common
    misspellings (ph->f, ck->k, qu->k, vowels and h dropped, z->s, v->f,
    c->k). A window of one to three adjacent words in the sentence becomes the
    same kind of skeleton and is compared with a small edit distance.

    The guards are what keep this from eating real words:

      * the skeleton must be at least 4 letters long, so short names (Claude,
        GGUF) are only ever corrected by fixes.txt -- "claud" and "cloud" have
        the same skeleton, and "cloud" is a word people say;
      * the window's letters must be at least 5;
      * the window must be within a letter (two for a long name) of the term's
        own LENGTH as well as its sound, so "higgs field" matches "Higgsfield"
        but "higgsfield with" does not;
      * an article in front of a matched name is left where it is ("a pull
        request" keeps its "a");
      * a word that already matches a term exactly is only re-capitalised when
        the term carries an inner capital, a digit or a dot (ChatGPT, GitHub,
        whisper.cpp). "terminal" stays lower case mid-sentence rather than
        becoming "Terminal".

    Applied to the whole sentence once, after the chunks have been joined (see
    finish_raw in dictate.sh), so a fix also matches across a chunk seam.

Reads: stdin text -> stdout text. Config files sit in ~/.config/ii-dictate/,
read per run so an edit is live on the next hold of SUPER.
"""

import os
import re
import sys
import unicodedata

CONFIG = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
    os.path.expanduser("~"), ".config")
WORDS = os.path.join(CONFIG, "ii-dictate", "words.txt")
FIXES = os.path.join(CONFIG, "ii-dictate", "fixes.txt")

# A word as the sentence spells it. An apostrophe stays inside the token so
# "pig's" is one word; the phonetic skeleton strips it anyway.
TOKEN = re.compile(r"[0-9A-Za-z\u00c0-\u024f]+(?:['\u2019][0-9A-Za-z\u00c0-\u024f]+)*")

# Words may be joined by spaces only for a multi-word term: "chat gpt" is two
# words in a row, "chat, gpt" is a list of two things.
GAP = re.compile(r"^[ \t]+$")

# Words that may sit in front of a name without being part of it.
ARTICLES = {"a", "an", "the", "der", "die", "das", "ein", "eine"}


def read_lines(path):
    """Non-comment, non-blank lines, trimmed. Missing file = no terms."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


def read_fixes(path):
    """(heard, meant) pairs, longest heard first so "a pig's field" wins over
    "pig's field"."""
    pairs = []
    for line in read_lines(path):
        if "=>" not in line:
            continue
        heard, meant = line.split("=>", 1)
        heard, meant = heard.strip(), meant.strip()
        if heard and meant:
            pairs.append((heard, meant))
    pairs.sort(key=lambda p: len(p[0]), reverse=True)
    return pairs


def strip_accents(word):
    word = unicodedata.normalize("NFKD", word)
    return "".join(c for c in word if not unicodedata.combining(c))


def letters(word):
    """Only letters and digits, lower case: "Higgs Field" -> "higgsfield"."""
    return re.sub(r"[^a-z0-9]", "", strip_accents(word).lower())


def skeleton(word):
    """The consonant frame, so spellings that sound alike look alike."""
    word = letters(word)
    if not word:
        return ""
    word = word.replace("ph", "f").replace("ck", "k").replace("qu", "k")
    collapsed = []
    for char in word:
        if not collapsed or collapsed[-1] != char:
            collapsed.append(char)
    word = "".join(collapsed)
    first, rest = word[0], word[1:]
    rest = "".join(c for c in rest if c not in "aeiouhy")
    rest = (rest.replace("x", "ks").replace("z", "s").replace("v", "f")
                .replace("c", "k").replace("q", "k").replace("w", ""))
    return first + rest


def edit_distance(a, b, limit):
    """Levenshtein. A length difference already over the limit is not a match,
    and these strings are a handful of letters, so the table is cheap."""
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def allowed_distance(skeleton_len, letters_len):
    """How far a spelling may be off. Nothing for short terms (see the guards
    in the module docstring), one letter for a normal name, two for a long one.
    -1 means "only fixes.txt may correct this term"."""
    if skeleton_len < 4 or letters_len < 5:
        return -1
    if skeleton_len >= 9:
        return 2
    return 1


def inner_capital(term):
    """True for names whose capitals are part of the name: ChatGPT, GitHub,
    whisper.cpp, XWayland. A plain "Terminal" is not one of them -- capitalising
    it mid-sentence would be wrong."""
    return any(c.isupper() for c in term[1:]) or any(
        c.isdigit() or c in ".-+_/" for c in term)


def build_vocab():
    """[(term, joined_letters, skeleton, allowance)] from words.txt."""
    vocab = []
    for term in read_lines(WORDS):
        joined = letters(term)
        if not joined:
            continue
        key = skeleton(joined)
        vocab.append((term, joined, key, allowed_distance(len(key), len(joined))))
    return vocab


def apply_fixes(text, pairs):
    """The explicit pairs, literally, whole words, any case.

    re.escape, not the raw left side: a pair like "chat gpt (new)" or "c++" must
    stay text, and one bad line in this file must never take the whole sentence
    with it the way a broken sed program would.
    """
    for heard, meant in pairs:
        pattern = re.compile(
            r"(?<![0-9A-Za-z_\u00c0-\u024f])"
            + re.escape(heard)
            + r"(?![0-9A-Za-z_\u00c0-\u024f])",
            re.IGNORECASE)
        text = pattern.sub(lambda _m, m=meant: m, text)
    return text


def apply_vocab(text, vocab):
    """The sound-alike pass. Walks the words once, left to right, replacing the
    longest window that matches a term."""
    terms = [t for t in vocab if t[3] >= 0]
    if not terms:
        return text

    tokens = list(TOKEN.finditer(text))
    pieces = []
    i = 0
    while i < len(tokens):
        chosen = None
        for size in (3, 2, 1):
            if i + size > len(tokens):
                continue
            window = tokens[i:i + size]
            if any(not GAP.match(text[a.end():b.start()])
                   for a, b in zip(window, window[1:])):
                continue
            surface = " ".join(t.group(0) for t in window)
            joined = letters(surface)
            if len(joined) < 5:
                continue
            key = skeleton(joined)
            if len(key) < 4:
                continue
            best = None
            for term, term_joined, term_key, limit in terms:
                # The window has to BE the name, not the name plus the word
                # after it: "higgsfield with" is three letters longer than
                # "Higgsfield" and is not a spelling of it. This is what keeps
                # "the terminal" from turning into "Terminal".
                gap = abs(len(joined) - len(term_joined))
                if gap > limit:
                    continue
                distance = edit_distance(key, term_key, limit)
                if distance > limit:
                    continue
                score = (distance, gap)
                if best is None or score < best[0]:
                    best = (score, term, term_joined, distance)
            if best is not None:
                chosen = (size, window, surface, best[1], best[2], best[3])
                break          # the longest window that matches wins

        if chosen is None:
            i += 1
            continue

        size, window, surface, term, term_joined, distance = chosen
        start, end = window[0].start(), window[-1].end()
        replacement = term
        if distance == 0 and letters(surface) == term_joined and surface != term:
            # The same letters, different capitals. Only a name whose capitals
            # are part of it earns a rewrite; a plain "Terminal" does not.
            if not inner_capital(term):
                replacement = surface
        # Never eat the article in front of a name.
        if (size > 1 and window[0].group(0).lower() in ARTICLES
                and not term_joined.startswith(letters(window[0].group(0)))):
            start = window[1].start()
        # Keep a possessive or plural the speaker actually said.
        lowered = surface.lower()
        if lowered.endswith("'s") or lowered.endswith("\u2019s"):
            replacement = term + ("'" if term.endswith("s") else "'s")
        elif joined == term_joined + "s" and lowered.endswith("s"):
            replacement = term + "s"
        pieces.append((start, end, replacement))
        i += size

    if not pieces:
        return text
    out = []
    cursor = 0
    for start, end, replacement in pieces:
        out.append(text[cursor:start])
        out.append(replacement)
        cursor = end
    out.append(text[cursor:])
    return "".join(out)


def main():
    text = sys.stdin.read()
    if not text.strip():
        sys.stdout.write(text)
        return 0
    text = apply_fixes(text, read_fixes(FIXES))
    text = apply_vocab(text, build_vocab())
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
