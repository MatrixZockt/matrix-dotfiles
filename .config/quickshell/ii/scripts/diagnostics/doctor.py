#!/usr/bin/env python3
"""Check this desktop for the mistakes that do not announce themselves.

Everything in this file exists because one of these checks would have caught a
real bug, and none of them was caught by anything else:

  * a keybind calling `overlay show`, when the shell's IPC function is called
    `reveal` -- exit code 109, no window, no message, and the button simply did
    nothing (`ipc` below);
  * an icon name the font does not have, which Qt renders as the literal word, so
    a button showed "RAM" where a chip was meant (`icons` below);
  * a program in `exec-once` that is not installed, so a piece of the desktop is
    quietly missing (`execs` below).

Run it after changing the shell or the Hyprland config:

    python3 ~/.config/quickshell/ii/scripts/diagnostics/doctor.py

Exit code is 0 when there are no errors, 1 when there are: it is usable as a
check in a script as well as something to read.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import material_symbols  # noqa: E402  (path has to be set up first)

SHELL_ROOT = Path(__file__).resolve().parents[2]
HYPR_ROOT = Path.home() / ".config" / "hypr"
SHELL_NAME = os.environ.get("II_SHELL_NAME", "ii")

# Quickshell writes one log per process it starts, named after the shell id.
QS_RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "quickshell"


class Report:
    """Collects findings so they can be printed grouped and counted."""

    def __init__(self):
        self.findings = []   # (level, check, message)

    def error(self, check, message):
        self.findings.append(("error", check, message))

    def warn(self, check, message):
        self.findings.append(("warn", check, message))

    def count(self, level):
        return sum(1 for entry in self.findings if entry[0] == level)

    def for_level(self, level):
        return [entry for entry in self.findings if entry[0] == level]


def run(args, **kwargs):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=20, **kwargs).stdout
    except Exception:
        return ""


def hypr_connection():
    """The running Hyprland's instance signature, or None when it is not running."""
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if signature:
        return signature
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "hypr"
    if not runtime.is_dir():
        return None
    entries = sorted((p for p in runtime.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime)
    return entries[-1].name if entries else None


def hyprctl(*args):
    signature = hypr_connection()
    if signature is None:
        return ""
    environment = dict(os.environ, HYPRLAND_INSTANCE_SIGNATURE=signature)
    return run(["hyprctl", *args], env=environment)


# ── checks ───────────────────────────────────────────────────────────────────
def check_config_errors(report):
    """What the compositor itself says about the config it just parsed."""
    if hypr_connection() is None:
        report.warn("hyprland", "Hyprland is not running, so its config could not be checked")
        return
    errors = hyprctl("configerrors").strip()
    if not errors:
        return
    for line in errors.splitlines():
        if line.strip():
            report.error("hyprland", line.strip())


def lua_sources():
    return sorted(HYPR_ROOT.rglob("*.lua"))


def check_execs(report):
    """Every program the config starts, checked against the machine.

    `exec-once` for something that is not installed is the quietest failure in a
    desktop: no error, no window, and the feature is simply not there. The same
    goes for a script path with a typo -- and for a `~`, which the `sh` that runs
    these commands does NOT expand, so the command looks right, reads right, and
    fails as "No such file or directory" with nothing on screen to say so.
    """
    pattern = re.compile(r"exec[a-z_]*\s*\(\s*\"([^\"]+)\"")
    checked = 0
    for path in lua_sources():
        where = str(path.relative_to(HYPR_ROOT))
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            # Commented-out examples are the config's own documentation; they are
            # not started by anything, so they are not missing.
            if line.strip().startswith("--"):
                continue
            for command in pattern.findall(line):
                if command.strip() == "":
                    continue
                # A shell snippet, not a program: its first word is whatever the
                # snippet needs (a builtin, a condition), not what must be
                # installed. Those are checked by reading them, not by `/which`.
                if any(token in command for token in ("&&", "||", "$(", "`", "command ", "sleep ")):
                    continue
                checked += 1
                at = f"{where}:{number}"
                if command.lstrip().startswith("~"):
                    report.error("execs", f"{at}: '{command.split()[0]}' starts with ~, which sh does not expand -- use $HOME")
                words = command.replace("$HOME", str(Path.home())).split()
                program, arguments = words[0], words[1:]
                # A script invoked through an interpreter: the script is the file
                # to check, and the interpreter is the one that has to be there.
                if program in ("bash", "sh", "python3", "env", "zsh") and arguments:
                    candidate = next((word for word in arguments if not word.startswith("-")), "")
                    if candidate.endswith((".sh", ".py")):
                        script = Path(candidate)
                        if not script.exists():
                            report.error("execs", f"{at}: {script} does not exist")
                    continue
                if program.startswith("/"):
                    if not Path(program).exists():
                        report.error("execs", f"{at}: {program} does not exist")
                    elif not os.access(program, os.X_OK):
                        report.error("execs", f"{at}: {program} is not executable")
                elif shutil.which(program) is None:
                    report.error("execs", f"{at}: {program} is not installed")
    print(f"    {checked} commands started by the config")


def available_ipc():
    """{target: {function, ...}} from the running shell."""
    if shutil.which("qs") is None:
        return None
    text = run(["qs", "-c", SHELL_NAME, "ipc", "show"])
    if "target " not in text:
        return None
    targets = {}
    current = None
    for line in text.splitlines():
        line = line.rstrip()
        if line.startswith("target "):
            current = line.split(" ", 1)[1].strip()
            targets[current] = set()
        elif line.strip().startswith("function ") and current is not None:
            name = line.strip().split(" ", 1)[1].split("(")[0].strip()
            targets[current].add(name)
    return targets


def check_ipc(report):
    """`qs ipc call <target> <function>` used anywhere in the configs.

    This is the check that matters most: the CLI reports a wrong verb as one line
    on stderr and exits 109, so a keybind calling a function that was renamed is
    indistinguishable from pressing nothing at all. It searches the shell as well
    as the Hyprland config, because the shell does most of the calling.
    """
    targets = available_ipc()
    if targets is None:
        report.warn("ipc", "the shell is not running, so its IPC surface could not be read")
        return
    # Two spellings, because the config uses both: the raw CLI form and the
    # `shellIpc("target function")` helper the keybinds wrap it in (which is how
    # most of the calls are made -- a release bind needs the socket, not a
    # `global` dispatch).
    pattern = re.compile(r"(?:ipc\s+call\s+|shellIpc\(\s*\")([A-Za-z0-9_]+)[ ]+([A-Za-z0-9_\- ]*)")
    checked = 0
    searched = 0
    roots = [HYPR_ROOT, SHELL_ROOT]
    for root in roots:
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix in (".png", ".svg", ".ttf", ".qslog"):
                continue
            # This file describes the pattern it searches for, so it matches
            # itself; that is a diagnostic reporting its own documentation.
            if path.parent.name == "diagnostics":
                continue
            try:
                text = path.read_text(errors="replace")
            except OSError:
                continue
            searched += 1
            for target, function in pattern.findall(text):
                function = function.strip().split(" ")[0]
                # `ipc call` with the target only is the CLI's own help form.
                if function == "" or function.startswith("-"):
                    continue
                checked += 1
                where = path.relative_to(root.parent)
                if target not in targets:
                    report.error("ipc", f"{where}: no such IPC target '{target}'")
                elif function not in targets[target]:
                    report.error("ipc", f"{where}: '{target}' has no function '{function}' (it has: {', '.join(sorted(targets[target]))})")
    print(f"    searched {searched} files, {checked} IPC calls, {len(targets)} targets available")


# Properties that hold an icon name. `symbol.text` is the bar's MaterialSymbol
# accessor. Everything else that takes a string is a label, a tooltip or a value,
# and checking those against the icon font is how this check becomes noise.
ICON_KEYS = re.compile(r"(?<![\w.])(?:icon|buttonIcon|iconText|materialSymbol)\s*:\s*")
TEXT_KEY = re.compile(r"(?<![\w.])text\s*:\s*")
OBJECT_DECL = re.compile(r"(?:component\s+\w+\s*:\s*)?(?:[a-z][\w.]*\s*:\s*)?([A-Z][A-Za-z0-9_.]*)\s*\{")
CALL_ARGUMENT = re.compile(r"(?:Translation\.tr|\.arg|\.toString|Math\.\w+|console\.\w+)\s*\((?:[^()]|\([^()]*\))*\)")
# Comparisons and string tests. `net.name.startsWith("wl")` sitting in the same
# expression as an icon name is a test on a string, not an icon called "wl".
COMPARISON = re.compile(
    r"[=!]==?\s*\"[^\"]*\"|\"[^\"]*\"\s*[=!]==?"
    r"|\.(?:startsWith|endsWith|includes|indexOf|match|test|replace|split)\(\s*\"[^\"]*\""
)
QUOTED = re.compile(r'"([a-z][a-z0-9_]{2,})"')


def enclosing_type(text, offset):
    """The type of the QML object that holds `offset`.

    Needed because `text:` is an icon on a MaterialSymbol and a line of prose on
    everything else; without this, every menu label in the shell gets checked
    against the icon font.
    """
    line_start = text.rfind("\n", 0, offset) + 1
    indent = len(text[line_start:offset]) - len(text[line_start:offset].lstrip(" "))
    position = line_start
    while position > 0:
        previous = text.rfind("\n", 0, position - 1) + 1
        line = text[previous:position]
        stripped = line.strip()
        if stripped and not stripped.startswith("//"):
            line_indent = len(line) - len(line.lstrip(" "))
            if line_indent < indent:
                match = OBJECT_DECL.match(stripped)
                if match:
                    return match.group(1)
        position = previous
    return ""


def balanced_expression(text, start):
    """The value of a property, from just after its colon to its end.

    Stops at the closing bracket or comma at the same nesting level, and at the
    next line that is not indented deeper -- which is what keeps a regex from
    reading an unrelated block's strings as this property's value.
    """
    line_start = text.rfind("\n", 0, start) + 1
    key_indent = len(text[line_start:start]) - len(text[line_start:start].lstrip(" "))
    depth = 0
    limit = min(len(text), start + 800)
    i = start
    while i < limit:
        char = text[i]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif char == "," and depth == 0:
            break
        elif char == "\n" and depth == 0:
            j = i + 1
            indent = 0
            while j < limit and text[j] == " ":
                indent += 1
                j += 1
            if text[j:j + 1] not in ("\n", "") and indent <= key_indent:
                break
        i += 1
    return text[start:i]


def icon_literals(expression):
    """The icon names a property expression can produce, and nothing else.

    Labels, format arguments and status values are removed before anything is
    looked up: `options: ["dim", "eco"]` next to an icon is not two icon names,
    and `wifiStatus === "connected"` is not one icon called "connected".
    """
    cleaned = CALL_ARGUMENT.sub(" ", expression)
    cleaned = COMPARISON.sub(" ", cleaned)
    return QUOTED.findall(cleaned)


def check_icons(report):
    """Icon names used in QML, checked against the font's own ligature table.

    A missing name is not an error: Qt draws the letters. It is a *wrong button*
    -- a Wi-Fi row that says "signal_wifi_4_bar" instead of drawing bars -- which
    is why this reads the font rather than trusting the source.
    """
    names = material_symbols.ligature_names()
    if not names:
        report.warn("icons", "the Material Symbols font could not be read, so icon names were not checked")
        return

    used = {}
    for path in SHELL_ROOT.rglob("*.qml"):
        where = str(path.relative_to(SHELL_ROOT))
        text = path.read_text(errors="replace")
        for pattern in (ICON_KEYS, TEXT_KEY):
            for match in pattern.finditer(text):
                # `text:` only means an icon on the icon widget. On a StyledText
                # it is the words on screen.
                if pattern is TEXT_KEY and enclosing_type(text, match.start()) != "MaterialSymbol":
                    continue
                for name in icon_literals(balanced_expression(text, match.end())):
                    used.setdefault(name, set()).add(where)

    missing = {name: places for name, places in used.items() if name not in names}
    for name, places in sorted(missing.items()):
        report.error("icons", f"'{name}' is not in the font ({', '.join(sorted(places))})")
    print(f"    {len(used)} names seen in QML, {len(missing)} not in the font")


def check_shell_logs(report):
    """Errors the shell printed at runtime, from the log of the running process.

    Only the newest log: the older ones are the history of processes that have
    been replaced, and reporting a bug that a restart already fixed is how a
    diagnostic teaches people to ignore it.

    The log is a binary stream, not text -- Quickshell writes structured records
    separated by control bytes -- so it is cut into messages on those bytes first.
    Reading it raw splices neighbouring records into one line and prints a
    half-line of someone else's message as part of this one.
    """
    logs = sorted(QS_RUNTIME.glob("by-id/*/log.qslog"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not logs:
        report.warn("logs", "no shell log found, so runtime errors were not checked")
        return
    patterns = (
        "Failed to load", "caused by", "TypeError", "ReferenceError",
        "Invalid property", "is not a type", "Unable to assign", "Cannot read property",
    )
    seen = set()
    raw = logs[0].read_bytes().decode("utf-8", "replace")
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]+", "\n", raw)
    for line in text.splitlines():
        line = line.strip()
        if any(pattern in line for pattern in patterns):
            # One report per distinct message, however often it repeated: a
            # binding error on a timer prints every tick.
            message = line[:220]
            if message in seen:
                continue
            seen.add(message)
            report.warn("logs", f"{logs[0].parent.name}: {message}")
    print(f"    {logs[0].parent.name}: {len(seen)} distinct error messages")


def check_keybinds(report):
    """Coverage only: duplicate binds cannot be judged from the source.

    This started as a duplicate check and was wrong: a press bind and its release
    counterpart are two `hl.bind` calls on the same key by design (that is how a
    hold-to-peek panel closes itself), and `hyprctl binds` reports them as two
    entries with the same key and different internal arguments. Reporting those as
    conflicts would have been 19 false alarms on a config with no conflict in it,
    which is worse than no check at all.

    So this counts instead, and the useful part of a keybind audit -- that the
    command a bind runs actually exists -- lives in `execs` above.
    """
    pattern = re.compile(r"hl\.(?:un)?bind\s*\(\s*\"([^\"]*)\"")
    seen = set()
    for path in lua_sources():
        for combo in pattern.findall(path.read_text(errors="replace")):
            seen.add(combo.upper().replace(" +", "+").replace("+ ", "+"))
    print(f"    {len(seen)} key combinations")


def main():
    report = Report()
    print("ii doctor — checking the shell and the Hyprland configuration\n")

    for check in (check_config_errors, check_keybinds, check_execs, check_ipc, check_icons, check_shell_logs):
        name = check.__name__.replace("check_", "")
        print(f"  {name}")
        try:
            check(report)
        except Exception as error:                      # a check must never be the thing that breaks
            report.warn(name, f"the check itself failed: {error}")

    print()
    for level in ("error", "warn"):
        for _, check, message in report.for_level(level):
            print(f"  {level.upper():5} [{check}] {message}")

    errors = report.count("error")
    warnings = report.count("warn")
    print(f"\n{errors} error(s), {warnings} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
