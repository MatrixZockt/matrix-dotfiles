#!/usr/bin/env python3
"""Own the Wayland clipboard as a FILE clipboard -- a copy or a cut, not text.

Why this is not `wl-copy`
-------------------------
A file copy is not one string. Each desktop reads it under a different name,
and they do not agree on it:

    text/uri-list                  Qt, Chromium/Electron, LibreOffice, most toolkits
    x-special/gnome-copied-files   GTK: first line is "copy" or "cut", then URIs
    application/x-kde-cutselection KDE: "1" for cut, "0" for copy

`wl-copy` serves exactly ONE MIME type per invocation -- and, for a type that
starts with `text/`, it ALSO offers `text/plain` carrying the same bytes. That
is the whole bug this file answers: a copy made in the file manager arrived in
a text field as `file:///home/...` (a path, not a file), because every app that
prefers plain text was handed the URI list as text. A copy that only offers
`text/uri-list` is a *text* paste with file:// in it to every GTK app, and a
copy that offers `text/plain` is a path paste to everything.

An owner that advertises all three -- and no text flavour at all -- is what
"copy the file" means. Gtk can do that (`Gdk.ContentProvider.new_union`), and
this process stays alive while it owns the selection; that is the clipboard
protocol, not a leak.

Why there is a WINDOW
---------------------
Gtk's Wayland backend refuses to set the selection without an input serial --
it stores the content and applies it "later", which on a process that has never
had focus is never. Measured: `is_local()` True, `get_formats()` listing the
three types, and the compositor holding nothing at all (`wl-paste --list-types`
said "Nothing is copied"). A background helper therefore cannot own the
clipboard, however correct its content is.

So this opens a 1x1 undecorated window, waits for it to be ACTIVE (that is the
serial arriving from the compositor), sets the content, and hides it again --
~60ms later, by measurement. The selection outlives the hidden window: it is
served by this process's main loop until something else takes the clipboard.
custom/rules.lua floats and suppresses that window's effects so it never enters
the tiling layout.

When the window never gets focus (no compositor, a lock screen, a session that
denies activation), there is no serial to be had -- so the fallback is
`wl-copy --type text/uri-list`: one flavour instead of three, text flavours
included, but a FILE rather than nothing.

usage:
    file-clipboard.py copy  PATH [PATH...]
    file-clipboard.py cut   PATH [PATH...]
    file-clipboard.py clear
"""

import os
import signal
import subprocess
import sys
import urllib.parse

URI_MIME = "text/uri-list"
GNOME_MIME = "x-special/gnome-copied-files"
KDE_MIME = "application/x-kde-cutselection"

APP_ID = "org.ii.ClipboardHelper"


def uri_for(path):
    """A file:// URI that survives spaces, hashes and umlauts.

    Percent-encoded per SEGMENT, like the file manager's own uriFor: encoding
    the separators too would produce `file:%2Fhome%2F...`, which is a URI no
    receiver recognises.
    """
    full = os.path.abspath(path)
    return "file://" + urllib.parse.quote(full, safe="/")


def wl_copy_fallback(paths, cut):
    """One flavour, through wl-clipboard: what can be done without a serial."""
    body = "\r\n".join(uri_for(p) for p in paths) + "\r\n"
    try:
        subprocess.run(["wl-copy", "--type", URI_MIME], input=body.encode(),
                       start_new_session=True, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return 1
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] not in ("copy", "cut", "clear"):
        sys.stderr.write(__doc__.split("usage:")[1].strip() + "\n")
        return 2

    verb = argv[1]
    paths = [p for p in argv[2:] if p]
    if verb in ("copy", "cut") and not paths:
        return 2

    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: F401  (Gtk initialises Gdk)

    # The window's app id IS the program name -- Gtk takes it from prgname, not
    # from the GApplication id, and left alone it is "python3": the compositor
    # would see a window belonging to python and the rule that keeps this 1x1
    # helper out of the tiling layout (custom/rules.lua) would never match it.
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("ii clipboard")

    if Gdk.Display.get_default() is None:
        # No display at all: nothing to own a selection with.
        return wl_copy_fallback(paths, verb == "cut") if verb != "clear" else 0

    clipboard = Gdk.Display.get_default().get_clipboard()

    if verb == "clear":
        # Only clear what is OURS: taking the clipboard away from another app
        # because this one emptied its own list would be a rude surprise.
        if hasattr(clipboard, "is_local") and not clipboard.is_local():
            return 0
        clipboard.set_content(None)
        return 0

    cut = verb == "cut"
    uris = [uri_for(p) for p in paths]
    # text/uri-list is CRLF-terminated, one URI per line.
    uri_list = "\r\n".join(uris) + "\r\n"
    # The GTK flavour carries the ACTION first, and its lines are LF -- the two
    # formats differ by more than the header line.
    gnome = verb + "\n" + "\n".join(uris) + "\n"
    kde = "1" if cut else "0"

    def provider(mime, text):
        return Gdk.ContentProvider.new_for_bytes(mime, GLib.Bytes.new(text.encode()))

    content = Gdk.ContentProvider.new_union([
        provider(URI_MIME, uri_list),
        provider(GNOME_MIME, gnome),
        provider(KDE_MIME, kde),
    ])

    app = Gtk.Application(application_id=APP_ID)
    # NOT unique: a second copy is a second owner replacing this one, and a
    # single-instance application would instead forward the request to the
    # running copy and exit -- i.e. the second Copy would do nothing.
    app.set_flags(Gio.ApplicationFlags.NON_UNIQUE)

    state = {"set": False, "active": False}

    def finish(code):
        GLib.idle_add(lambda: (app.quit(), False)[1])
        return code


    def on_activate(application):
        window = Gtk.Window(application=application)
        window.set_default_size(1, 1)
        window.set_decorated(False)
        window.set_title("ii clipboard")
        window.present()

        def take():
            if state["set"]:
                return False
            state["set"] = True
            clipboard.set_content(content)

            def hide():
                window.set_visible(False)
                return False

            # Hidden, not closed: the selection lives as long as this process
            # serves it, and the window's only job was the serial.
            GLib.timeout_add(60, hide)

            # Ownership is the whole lifetime of this process. The moment any
            # other client copies something, `is_local` goes false and there is
            # nothing left to serve; exiting on that is what keeps this from
            # becoming a stray process per copy.
            GLib.timeout_add(1000, watch)
            return False

        def watch():
            if not clipboard.is_local():
                finish(0)
                return False
            return True

        def activated(*_args):
            if window.get_property("is-active"):
                state["active"] = True
                take()

        window.connect("notify::is-active", activated)
        # No focus within this window means the compositor never handed us a
        # serial, so Gtk would store the content and never publish it. Fall back
        # to what wl-clipboard can do instead of leaving the clipboard empty.
        def give_up():
            if state["set"]:
                return False
            if not state["active"]:
                finish(wl_copy_fallback(paths, cut))
            return False

        GLib.timeout_add(1200, give_up)

    app.connect("activate", on_activate)

    # SIGTERM ends it cleanly when the caller replaces a clipboard it has just
    # made (file-clipboard.py has no state to flush -- releasing the selection
    # is the whole cleanup). `GLibUnix` is the modern home for this; the older
    # `GLib.unix_signal_add` still works but warns on every copy.
    try:
        from gi.repository import GLibUnix
        handler = GLibUnix.signal_add
    except (ImportError, AttributeError):
        handler = GLib.unix_signal_add
    for sig in (signal.SIGTERM, signal.SIGINT):
        handler(GLib.PRIORITY_DEFAULT, sig, lambda *_: (app.quit(), False)[1])

    return app.run([])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
