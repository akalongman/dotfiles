"""Files extras: small additions to Nautilus (GNOME Files).

Context menu
  Copy Full Path   on selected files and folders, and on the folder
                   background. Paths are put on the clipboard through GDK,
                   so it works under X11 and Wayland with no external tool.
                   Multiple selections are joined with newlines. Locations
                   without a local path (SMB, SFTP, trash) fall back to
                   their URI.
  Open In          submenu on a single selected folder and on the folder
                   background: Zed, Sublime Text, PhpStorm. An entry is
                   shown only when its launcher exists on this machine.
  Quick Open       submenu on the folder background for files edited often:
                   hosts (through admin:// in GNOME Text Editor), SSH config
                   and shell exports (default editor). Missing files are
                   hidden.

Properties window
  Checksums        a page on a single regular file with MD5, SHA-1, SHA-256
                   and SHA-512. Hashing runs in a child process, reading the
                   file once, and is killed when the window is closed.

Loaded from ~/.local/share/nautilus-python/extensions (package
python3-nautilus); reload with `nautilus -q`.
"""

import hashlib
import os
from pathlib import Path
from urllib.parse import unquote, urlparse

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Gio", "2.0")
gi.require_version("Nautilus", "4.0")

from gi.repository import Gdk, Gio, GLib, GObject, Nautilus  # noqa: E402

HOME = Path.home()

# label, launcher path. Order is the menu order.
EDITORS = [
    ("Zed", HOME / ".local/bin/zed"),
    ("Sublime Text", Path("/usr/bin/subl")),
    ("PhpStorm", HOME / ".local/share/JetBrains/Toolbox/scripts/phpstorm"),
]

# label, file, opener. "admin" opens the file through the GVFS admin backend
# in GNOME Text Editor (PolicyKit asks for the password on save); "default"
# opens it with the desktop's default handler for its type.
ADMIN_EDITOR = Path("/usr/bin/gnome-text-editor")
QUICK_OPEN = [
    ("hosts", Path("/etc/hosts"), "admin"),
    ("SSH config", HOME / ".ssh/config", "default"),
    ("Shell exports", HOME / ".exports", "default"),
]

HASHES = [("MD5", "md5"), ("SHA-1", "sha1"), ("SHA-256", "sha256"), ("SHA-512", "sha512")]
CHUNK = 4 * 1024 * 1024


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


def _copy(text):
    display = Gdk.Display.get_default()
    if display is None:
        return
    # gdk_clipboard_set_text is hidden from bindings; go through a provider.
    display.get_clipboard().set_content(Gdk.ContentProvider.new_for_value(text))


def _launch(argv):
    try:
        Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE)
    except GLib.Error as error:
        print(f"files-extras: cannot launch {argv[0]}: {error.message}")


def _available_editors():
    return [(label, str(path)) for label, path in EDITORS if os.access(path, os.X_OK)]


def _available_quick_open():
    entries = []
    for label, path, opener in QUICK_OPEN:
        if not path.is_file():
            continue
        if opener == "admin" and not os.access(ADMIN_EDITOR, os.X_OK):
            continue
        entries.append((label, str(path), opener))
    return entries


def _quick_open(path, opener):
    if opener == "admin":
        _launch([str(ADMIN_EDITOR), f"admin://{path}"])
        return
    try:
        Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None)
    except GLib.Error as error:
        print(f"files-extras: cannot open {path}: {error.message}")


class ContextMenu(GObject.GObject, Nautilus.MenuProvider):
    def _copy_item(self, name, files):
        item = Nautilus.MenuItem(
            name=name,
            label="Copy Full Path",
            tip="Copy the absolute path of the selection to the clipboard",
        )
        item.connect("activate", lambda _i: _copy("\n".join(_path_of(f) for f in files)))
        return item

    def _open_in_item(self, name, folder):
        editors = _available_editors()
        if not editors:
            return None
        parent = Nautilus.MenuItem(name=name, label="Open In")
        submenu = Nautilus.Menu()
        path = _path_of(folder)
        for label, launcher in editors:
            entry = Nautilus.MenuItem(name=f"{name}::{label}", label=label)
            entry.connect("activate", lambda _i, l=launcher: _launch([l, path]))
            submenu.append_item(entry)
        parent.set_submenu(submenu)
        return parent

    def _quick_open_item(self, name):
        entries = _available_quick_open()
        if not entries:
            return None
        parent = Nautilus.MenuItem(name=name, label="Quick Open")
        submenu = Nautilus.Menu()
        for label, path, opener in entries:
            entry = Nautilus.MenuItem(name=f"{name}::{label}", label=label, tip=path)
            entry.connect("activate", lambda _i, p=path, o=opener: _quick_open(p, o))
            submenu.append_item(entry)
        parent.set_submenu(submenu)
        return parent

    def get_file_items(self, files):
        if not files:
            return []
        items = [self._copy_item("FilesExtras::copy", files)]
        if len(files) == 1 and files[0].is_directory():
            item = self._open_in_item("FilesExtras::open-in", files[0])
            if item:
                items.append(item)
        return items

    def get_background_items(self, folder):
        items = [self._copy_item("FilesExtras::copy-bg", [folder])]
        for item in (self._open_in_item("FilesExtras::open-in-bg", folder), self._quick_open_item("FilesExtras::quick-open")):
            if item:
                items.append(item)
        return items


# Runs in a separate interpreter: nautilus-python keeps the GIL on the main
# thread between calls, so an in-process worker thread would starve.
HASH_SCRIPT = """
import hashlib, sys
digests = [hashlib.new(name) for name in sys.argv[2:]]
try:
    with open(sys.argv[1], "rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            for digest in digests:
                digest.update(chunk)
except OSError as error:
    sys.exit(error.strerror)
print("\\n".join(digest.hexdigest() for digest in digests))
"""


def _hash_file(path, store, model):
    """Hash `path` in a child process and replace the rows when it exits.

    The child is killed when Nautilus finalizes the Properties model, which
    happens on window close. The weak-reference handle must stay alive for
    the hook to stay installed, so it rides along as callback data.
    """
    argv = ["/usr/bin/python3", "-c", HASH_SCRIPT, path, *(alg for _label, alg in HASHES)]
    try:
        proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE)
    except GLib.Error as error:
        _set_rows(store, [(i, f"Failed: {error.message}") for i in range(len(HASHES))])
        return
    keepalive = model.weak_ref(proc.force_exit)
    proc.communicate_utf8_async(None, None, _on_hashed, (store, keepalive))


def _on_hashed(proc, result, data):
    store, _keepalive = data
    try:
        _ok, out, err = proc.communicate_utf8_finish(result)
    except GLib.Error as error:
        _set_rows(store, [(i, f"Failed: {error.message}") for i in range(len(HASHES))])
        return
    if proc.get_if_exited() and proc.get_exit_status() == 0:
        values = out.split()
        if len(values) == len(HASHES):
            _set_rows(store, list(enumerate(values)))
            return
    reason = (err.strip().splitlines() or ["killed"])[-1]
    _set_rows(store, [(i, f"Failed: {reason}") for i in range(len(HASHES))])


def _set_rows(store, rows):
    for index, value in rows:
        store.splice(index, 1, [Nautilus.PropertiesItem(name=HASHES[index][0], value=value)])


class ChecksumsPage(GObject.GObject, Nautilus.PropertiesModelProvider):
    def get_models(self, files):
        if len(files) != 1 or files[0].get_file_type() != Gio.FileType.REGULAR:
            return []
        location = files[0].get_location()
        path = location.get_path() if location else None
        if not path:
            return []
        store = Gio.ListStore.new(Nautilus.PropertiesItem)
        for label, _alg in HASHES:
            store.append(Nautilus.PropertiesItem(name=label, value="Computing…"))
        model = Nautilus.PropertiesModel(title="Checksums", model=store)
        _hash_file(path, store, model)
        return [model]
