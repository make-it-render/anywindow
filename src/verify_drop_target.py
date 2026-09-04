#!/usr/bin/env python3
"""A GTK 3 drop target for the drag-and-drop rig: a window that takes text and file lists, prints what lands on it, and quits when its stdin closes. Printed once mapped: `ready <xid>`; per drop: `text: ...` or `files: <path> <path>`.

The rig embeds this file and runs it through `python3 -c`, so it must stay self-contained.
"""
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402


def received(widget, context, x, y, data, info, time):
    uris = data.get_uris()
    if uris:
        paths = [GLib.filename_from_uri(uri)[0] for uri in uris]
        print("files: " + " ".join(paths))
    else:
        print("text: " + (data.get_text() or ""))
    sys.stdout.flush()


def quit_on_stdin(source, condition):
    Gtk.main_quit()
    return False


window = Gtk.Window(title="mir drop target")
window.set_default_size(300, 200)
window.move(700, 300)
label = Gtk.Label(label="drop text or files here")
window.add(label)
targets = [
    Gtk.TargetEntry.new("text/uri-list", 0, 1),
    Gtk.TargetEntry.new("text/plain;charset=utf-8", 0, 2),
    Gtk.TargetEntry.new("UTF8_STRING", 0, 3),
    Gtk.TargetEntry.new("text/plain", 0, 4),
]
window.drag_dest_set(Gtk.DestDefaults.ALL, targets, Gdk.DragAction.COPY)
window.connect("drag-data-received", received)
window.connect("destroy", Gtk.main_quit)
window.show_all()
print("ready %d" % window.get_window().get_xid())
sys.stdout.flush()
GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, quit_on_stdin)
Gtk.main()
