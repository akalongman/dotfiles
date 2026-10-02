"""Copy Full Path: a Nautilus (GNOME Files) context-menu extension.

Adds "Copy Full Path" to the context menu of selected files and folders and
to the background menu of the current folder. Paths are put on the clipboard
through GDK, so it works under X11 and Wayland with no external tool.
Multiple selections are joined with newlines. Locations without a local path
(SMB, SFTP, trash) fall back to their URI.

Loaded from ~/.local/share/nautilus-python/extensions (package
python3-nautilus); reload with `nautilus -q`.
"""

from urllib.parse import unquote, urlparse

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Nautilus", "4.0")

from gi.repository import Gdk, GObject, Nautilus  # noqa: E402


def _path_of(file_info):
    """Return the local filesystem path of a Nautilus file, or its URI."""
    location = file_info.get_location()
    path = location.get_path() if location else None
    if path:
        return path
    uri = file_info.get_uri()
    parsed = urlparse(uri)
    if parsed.scheme == "file":
        return unquote(parsed.path)
    return uri


def _copy(paths):
    display = Gdk.Display.get_default()
    if display is None:
        return
    # gdk_clipboard_set_text is hidden from bindings; go through a provider.
    provider = Gdk.ContentProvider.new_for_value("\n".join(paths))
    display.get_clipboard().set_content(provider)


class CopyPathExtension(GObject.GObject, Nautilus.MenuProvider):
    def _item(self, name, files):
        item = Nautilus.MenuItem(
            name=name,
            label="Copy Full Path",
            tip="Copy the absolute path of the selection to the clipboard",
        )
        item.connect("activate", lambda _item: _copy([_path_of(f) for f in files]))
        return item

    def get_file_items(self, files):
        if not files:
            return []
        return [self._item("CopyPath::selection", files)]

    def get_background_items(self, current_folder):
        return [self._item("CopyPath::folder", [current_folder])]
