#!/usr/bin/env python3
"""Put one FILE on the Wayland clipboard, the way a file manager's Ctrl+C does.

WHY NOT wl-copy. `wl-copy --type text/uri-list` is what a stop used to do, and it
is close but not the same thing. wl-copy serves exactly ONE type, and adds its own
text/plain fallback on top, so:

  * a target that prefers text pastes the path as literal text instead of
    receiving a file, and
  * GTK apps looking specifically for `x-special/gnome-copied-files` -- the type
    Nautilus, Dolphin and Thunar all set on Ctrl+C -- see nothing at all.

That is the difference between "a path arrived" and "a file arrived". GTK4's
Gdk.ContentProvider can serve several formats from one selection, which is what
this is: the same target list a file manager sets, with the right bytes for each.

WHAT IT SERVES (copy semantics, no text fallback):

    x-special/gnome-copied-files   "copy\\nfile:///…"
    x-special/mate-copied-files    "copy\\nfile:///…"
    text/uri-list                  "file:///…"

NO text/plain ON PURPOSE: a file copy that also answers as text is a file copy
that sometimes pastes a path into a chat box instead of the video.

LIFETIME. It holds the selection until something else takes it, then exits --
exactly as long as a file manager's copy lasts. A one hour backstop covers a
session where nothing else is ever copied.

`--transient SECONDS` is for the temp clip directory: the file is a thing you
PASTE, not a folder you leaf through, so once its window has passed it is
deleted. Nothing can be deleted while it is still the selection (a paste that
arrives after the delete would silently do nothing), so the countdown only starts
being respected once the selection has moved on; the delete itself happens
SECONDS after the copy.

Usage: clip-file.py [--transient SECONDS] PATH   (blocks while the selection is held)
"""

import os
import sys
import time
import urllib.parse

# Decided before GTK initialises. GDK would pick Wayland anyway on this session,
# but XWayland is always running too (DISPLAY is set), and the selection has to
# live on the compositor's clipboard or only X11 clients would see the copy.
if os.environ.get("WAYLAND_DISPLAY"):
    os.environ.setdefault("GDK_BACKEND", "wayland")

BACKSTOP_SECONDS = 3600
DEFAULT_TRANSIENT = 600


def parse_args(argv):
    transient = 0
    path = None
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--transient":
            i += 1
            transient = int(argv[i]) if i < len(argv) else DEFAULT_TRANSIENT
        elif arg.startswith("--transient="):
            transient = int(arg.split("=", 1)[1])
        elif path is None:
            path = arg
        else:
            return None, 0
        i += 1
    return path, transient


def main(argv):
    path, transient = parse_args(argv)
    if not path:
        sys.stderr.write("usage: clip-file.py [--transient SECONDS] PATH\n")
        return 2
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        sys.stderr.write("no such file: %s\n" % path)
        return 1

    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, GLib, Gtk

    Gtk.init()
    display = Gdk.Display.get_default()
    if display is None:
        sys.stderr.write("no GDK display; cannot own the selection\n")
        return 1

    uri = "file://" + urllib.parse.quote(path)
    providers = [
        Gdk.ContentProvider.new_for_bytes(mime, GLib.Bytes.new(text.encode()))
        for mime, text in {
            "text/uri-list": uri + "\r\n",
            "x-special/gnome-copied-files": "copy\n" + uri,
            "x-special/mate-copied-files": "copy\n" + uri,
        }.items()
    ]
    provider = Gdk.ContentProvider.new_union(providers)

    clipboard = display.get_clipboard()
    clipboard.set_content(provider)

    started = time.monotonic()
    expires = started + transient if transient > 0 else None
    loop = GLib.MainLoop()
    state = {"saw_ours": False}

    def poll():
        """Leave when someone else's copy replaces ours, or the clip's time is up.

        Measured on this compositor (2026-10-22): while the selection is ours
        get_content() hands back this exact provider object, and the moment
        another client (wl-copy, a file manager, an editor) takes the selection it
        returns None instead. So the question is identity, not presence -- an
        earlier version tested `is not None` and therefore never noticed a
        takeover at all, and every copy leaked a parked process.
        """
        current = clipboard.get_content()
        if current is provider:
            state["saw_ours"] = True
        elif state["saw_ours"]:
            # Someone else owns the selection now, so there is nothing left to
            # serve. With a transient clip the process stays parked (asleep, no
            # Wayland connection) so the file can still be opened until its
            # window closes -- see below.
            loop.quit()
            return True
        if expires is not None and time.monotonic() >= expires:
            loop.quit()
        return True

    GLib.timeout_add(500, poll)
    GLib.timeout_add_seconds(BACKSTOP_SECONDS, loop.quit)
    loop.run()

    if transient > 0:
        # The window is over. A clip that is still the selection is left alone
        # only while it can still be pasted -- we have just released it, so it
        # cannot be, and it goes now.
        delay = expires - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        try:
            os.unlink(path)
        except OSError:
            pass
        else:
            # `latest.mp4` is record-region.sh's stable pointer at the newest
            # clip. Deleting the clip it names must take the pointer with it --
            # otherwise the one path a person is told to look at becomes a link
            # to nothing (seen: it survived the clip by hours until the next
            # recording recreated it).
            link = os.path.join(os.path.dirname(path), "latest.mp4")
            try:
                if os.path.islink(link) and os.path.realpath(link) == path:
                    os.unlink(link)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
