#!/usr/bin/env python3
"""End-to-end test of the ii FileChooser portal chain.

Asks the portal FRONTEND (org.freedesktop.portal.Desktop) exactly the way a
real app -- Brave, firefox, anything -- asks for a save dialog, then prints
the response it got. Healthy chain: the Explorer picker window maps, and the
script exits when someone answers it. Broken chain: the script hangs until
its timeout -- which is exactly what the Brave freeze felt like.

Usage: test-portal-e2e.py [save|open] [timeout-seconds]
"""
import os
import sys

import gi

gi.require_version("GLib", "2.0")
gi.require_version("Gio", "2.0")

from gi.repository import GLib, Gio  # noqa: E402

loop = GLib.MainLoop()
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def on_response(_conn, _sender, _path, _iface, _signal, params):
    unpacked = params.unpack()
    response = unpacked[0]
    results = unpacked[1] if len(unpacked) > 1 else {}
    print(f"RESPONSE={response} results={results}", flush=True)
    loop.quit()


bus.signal_subscribe(
    "org.freedesktop.portal.Desktop",
    "org.freedesktop.portal.Request", "Response",
    None, None, Gio.DBusSignalFlags.NONE, on_response)

method = "SaveFile" if (len(sys.argv) < 2 or sys.argv[1] == "save") else "OpenFile"
timeout_s = int(sys.argv[2]) if len(sys.argv) > 2 else 40

opts = {
    "handle_token": GLib.Variant("s", "e2etest"),
    "title": GLib.Variant("s", f"Portal {method} test"),
    "accept_label": GLib.Variant("s", "Save" if method == "SaveFile" else "Open"),
}
if method == "SaveFile":
    opts["current_name"] = GLib.Variant("s", "test-download.png")
    opts["current_folder"] = GLib.Variant("ay", os.path.expanduser("~/Downloads").encode() + b"\0")

r = bus.call_sync(
    "org.freedesktop.portal.Desktop",
    "/org/freedesktop/portal/desktop",
    "org.freedesktop.portal.FileChooser", method,
    GLib.Variant("(ssa{sv})", ("", f"Portal {method} test", opts)),
    GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, 5000, None)
print("request handle:", r.unpack()[0], flush=True)

GLib.timeout_add_seconds(timeout_s, lambda: (print("TIMEOUT: no response", flush=True), loop.quit())[1] or False)
loop.run()
