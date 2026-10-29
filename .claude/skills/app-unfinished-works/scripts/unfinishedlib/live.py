"""Live Claude Code sessions: which are running now, and where.

Three sources are read, always all three and in this order: the rows of
`claude-sessions --json --all` (the private dotfiles' lister, which reads
every slot's registry and checks each entry against /proc itself), the
registry files <slot>/sessions/<pid>.json read here with the same pid plus
procStart check (for a machine without the command, or an older one that
prints no pid), and every process named claude under /proc (a session runs
for a while before its registry entry appears). The union is de-duplicated
by pid. A session id is matched against the transcripts globally; only a
process that names no session is placed in a checkout by its cwd, where it
marks that checkout's recent transcripts possibly live. Files are only ever
opened for reading.
"""

import json
import os
import re
from typing import Any, TypeGuard

from scripts.unfinishedlib import model
from scripts.unfinishedlib.model import Checkout, LiveSession, Run, Runner, Session

CLAUDE_SESSIONS = ["claude-sessions", "--json", "--all"]
# The comm of a Claude Code session; the tray indicator runs as
# claude-sessions, which is another name.
PROCESS_NAME = "claude"
# A transcript in a checkout that holds an unregistered process is possibly
# live when it was modified at most this many seconds ago.
POSSIBLY_LIVE_SECONDS = 600
# claude-sessions' state for a registry status; any other status is idle.
_STATES = {"busy": "working", "waiting": "waiting"}
_SLOT_DIR = re.compile(r"\.claude([0-9]*)")
_CONFIG_DIR = b"CLAUDE_CONFIG_DIR="
# What the kernel appends to the cwd link of a process whose directory was removed.
_DELETED = " (deleted)"


def proc_start(stat_text: str) -> str:
    """Field 22 of /proc/<pid>/stat (the start time), the rule claude-sessions uses.

    The comm in field 2 is parenthesised and may hold spaces and
    parentheses, so the fields are counted from the last ")".
    """
    return stat_text[stat_text.rfind(")") + 2 :].split()[19]


def from_claude_sessions(runner: Runner = model.default_runner, *, run: Run | None = None) -> list[LiveSession] | None:
    """The rows of `claude-sessions --json --all`, or None when it gives none.

    None on any non-zero exit (127 when the command is absent) or a stdout
    that is not a JSON array. Neither is an error, as the registry read
    covers the same files; given a run, the reason is one footer note. A
    row that is not an object, or has no integer pid or no string cwd (an
    older claude-sessions prints no pid), is skipped; a row without a
    string sessionId gives session_id None.
    """
    returncode, stdout, stderr = runner(CLAUDE_SESSIONS, None)
    command = " ".join(CLAUDE_SESSIONS)
    if returncode == 127:
        _note_fallback(run, CLAUDE_SESSIONS[0] + ": not found")
        return None
    if returncode != 0:
        line = _first_line(stderr)
        _note_fallback(run, command + ": exit " + str(returncode) + (": " + line if line else ""))
        return None
    try:
        rows = json.loads(stdout)
    except ValueError:
        rows = None
    if not isinstance(rows, list):
        _note_fallback(run, command + ": output is not a JSON array")
        return None
    found: list[LiveSession] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        pid, cwd = row.get("pid"), row.get("cwd")
        if not _is_pid(pid) or not isinstance(cwd, str):
            continue
        slot = row.get("slot")
        found.append(
            LiveSession(
                session_id=_string(row.get("sessionId")),
                pid=pid,
                cwd=cwd,
                slot="unknown" if slot is None else str(slot),
                name=_string(row.get("name")) or "",
                state=_string(row.get("state")) or "",
                source="claude-sessions",
            )
        )
    return found


def from_registry(slot_roots: list[str], proc_root: str, run: Run) -> list[LiveSession]:
    """The registry entries <root>/sessions/*.json whose process still runs.

    Roots are read in the order given, each one's files sorted by name. An
    entry is kept only when <proc_root>/<pid>/stat reads and its start time
    equals the entry's procStart, so an entry left behind after pid reuse is
    dropped; a missing or unreadable stat means the process is gone. The
    harness rewrites a file in place, so a read can land between the
    truncation and the write: a file that does not parse is read once more,
    and is an error only when the second read does not parse either. A file
    that cannot be read is an error; one that vanished (on either read), and
    a root without a sessions directory, are not. An entry that is not an
    object, or has no integer pid, no procStart or no string cwd, is
    skipped, as claude-sessions skips it.
    """
    found: list[LiveSession] = []
    for root in slot_roots:
        slot = _slot(root)
        folder = os.path.join(root, "sessions")
        try:
            names = sorted(name for name in os.listdir(folder) if name.endswith(".json") and not name.startswith("."))
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError as exc:
            _record_unreadable(run, folder, exc)
            continue
        for name in names:
            entry = _load_entry(os.path.join(folder, name), run)
            if not isinstance(entry, dict):
                continue
            pid, start, cwd = entry.get("pid"), entry.get("procStart"), entry.get("cwd")
            if not _is_pid(pid) or start is None or not isinstance(cwd, str):
                continue
            if _start_time(proc_root, pid) != str(start):
                continue
            status = entry.get("status")
            found.append(
                LiveSession(
                    session_id=_string(entry.get("sessionId")),
                    pid=pid,
                    cwd=cwd,
                    slot=slot,
                    name=_string(entry.get("name")) or "",
                    state=_STATES.get(status, "idle") if isinstance(status, str) else "idle",
                    source="registry",
                )
            )
    return found


def from_processes(proc_root: str, run: Run, *, uid: int | None = None) -> list[LiveSession]:
    """Every process named claude under proc_root that uid owns, in ascending pid order.

    comm is read first, and an entry whose comm is not exactly claude, or
    cannot be read, is skipped silently: most of /proc belongs to other
    programs and users, whose files may be unreadable, and an entry can exit
    before it is read. A claude process whose <proc_root>/<pid> directory
    another user owns is not one of this user's sessions and is skipped
    silently too, before any of its files is read (its cwd link and environ
    are closed to this user); uid is the user, os.getuid() when None. Of
    this user's claude process, stat, the cwd link and environ are read; a
    failure on any of them, or on the owner's stat (the process exited
    mid-read), is one error naming that path, and the process gives no row.
    One trailing " (deleted)", the kernel's marker for a removed directory,
    is stripped from the cwd, so a process left in a removed worktree still
    names it. The slot comes from CLAUDE_CONFIG_DIR in environ.
    """
    if uid is None:
        uid = os.getuid()
    try:
        names = os.listdir(proc_root)
    except OSError as exc:
        _record_unreadable(run, proc_root, exc)
        return []
    found: list[LiveSession] = []
    for name in sorted((name for name in names if name.isascii() and name.isdigit()), key=int):
        folder = os.path.join(proc_root, name)
        try:
            with open(os.path.join(folder, "comm"), encoding="utf-8", errors="replace") as handle:
                comm = handle.read()
        except OSError:
            continue
        if comm.removesuffix("\n") != PROCESS_NAME:
            continue
        # path names the file being read, for the error when one fails.
        path = folder
        try:
            if os.stat(path).st_uid != uid:
                continue
            path = os.path.join(folder, "stat")
            with open(path, "rb") as handle:
                handle.read()
            path = os.path.join(folder, "cwd")
            cwd = os.readlink(path).removesuffix(_DELETED)
            path = os.path.join(folder, "environ")
            with open(path, "rb") as handle:
                environ = handle.read()
        except OSError as exc:
            _record_unreadable(run, path, exc)
            continue
        found.append(LiveSession(None, int(name), cwd, _config_slot(environ), "", "unknown", "process"))
    return found


def live_sessions(slot_roots: list[str], proc_root: str, runner: Runner, run: Run) -> list[LiveSession]:
    """Every live session, one row per pid, in order of first appearance.

    The rows of claude-sessions come first, then the registry's, then the
    processes'. The first row for a pid is kept; when it names no session,
    the first later row for that pid that names one lends it its id. When
    claude-sessions gives no rows, run gets a note saying why.
    """
    rows = (from_claude_sessions(runner, run=run) or []) + from_registry(slot_roots, proc_root, run)
    rows += from_processes(proc_root, run)
    kept: dict[int, LiveSession] = {}
    for row in rows:
        first = kept.setdefault(row.pid, row)
        if first.session_id is None and row.session_id is not None:
            first.session_id = row.session_id
    return list(kept.values())


def in_repository(live: list[LiveSession], checkouts: list[Checkout], main_path: str) -> list[LiveSession]:
    """The rows whose cwd lies in a present checkout or under <main_path>/.worktrees/."""
    return [row for row in live if _checkout_of(row.cwd, checkouts, main_path) is not None]


def mark_live(
    sessions: list[Session],
    live: list[LiveSession],
    checkouts: list[Checkout],
    main_path: str,
    now: float,
) -> list[str]:
    """Mark sessions live or possibly live; return one note per checkout holding an unregistered process.

    live holds every live row, before any checkout filter: a session whose
    id a row names is live wherever that process runs now. A row in this
    repository that names no session (a claude process without a registry
    entry yet) leaves its checkout ambiguous: every session of that
    checkout (one of its cwds lies there) that is not live and whose
    transcript was modified within POSSIBLY_LIVE_SECONDS of now is possibly
    live. Notes come in the order the checkouts are first seen.
    """
    ids = {row.session_id for row in live if row.session_id is not None}
    for session in sessions:
        if session.id in ids:
            session.live = "live"
    ambiguous: list[str] = []
    for row in live:
        checkout = _checkout_of(row.cwd, checkouts, main_path) if row.session_id is None else None
        if checkout is not None and checkout not in ambiguous:
            ambiguous.append(checkout)
    notes: list[str] = []
    for checkout in ambiguous:
        for session in sessions:
            if session.live is not None or now - session.mtime > POSSIBLY_LIVE_SECONDS:
                continue
            if any(_checkout_of(cwd, checkouts, main_path) == checkout for cwd in session.cwds):
                session.live = "possibly live"
        notes.append("unregistered claude process in " + checkout + "; its recent transcripts are marked possibly live")
    return notes


def _checkout_of(cwd: str, checkouts: list[Checkout], main_path: str) -> str | None:
    """The checkout root a cwd lies in, or None when it lies in none.

    The roots are the present checkouts plus, for a cwd under
    <main_path>/.worktrees/<name>, that worktree directory whether or not
    it is still present, so a removed worktree is its own checkout and
    never the main one's; the longest root the cwd equals or lies under
    wins. Whole path components only: /r/main-2 is not under /r/main.
    """
    path = os.path.normpath(cwd)
    roots = [os.path.normpath(checkout.path) for checkout in checkouts if checkout.present]
    worktrees = os.path.join(os.path.normpath(main_path), ".worktrees")
    if path != worktrees and _under(path, worktrees):
        roots.append(os.path.join(worktrees, path[len(worktrees) + 1 :].split("/", 1)[0]))
    best: str | None = None
    for root in roots:
        if _under(path, root) and (best is None or len(root) > len(best)):
            best = root
    return best


def _slot(config_dir: str) -> str:
    """The slot a config directory names: .claude is 1, .claudeN is N, any other name unknown."""
    match = _SLOT_DIR.fullmatch(os.path.basename(config_dir.rstrip("/")))
    if match is None:
        return "unknown"
    return match.group(1) or "1"


def _config_slot(environ: bytes) -> str:
    """The slot of a process from its NUL-separated environ; no or an empty CLAUDE_CONFIG_DIR is slot 1."""
    for entry in environ.split(b"\0"):
        if entry.startswith(_CONFIG_DIR):
            value = os.fsdecode(entry[len(_CONFIG_DIR) :])
            return _slot(value) if value else "1"
    return "1"


def _load_entry(path: str, run: Run) -> Any:
    """The parsed JSON of one registry file, or None when it is skipped or recorded.

    A file that does not parse is read once more before it counts as not
    JSON (see from_registry); a vanished file is None with no record.
    """
    for _ in range(2):
        try:
            data = _read_registry_file(path)
        except FileNotFoundError:
            return None
        except OSError as exc:
            _record_unreadable(run, path, exc)
            return None
        try:
            return json.loads(data)
        except ValueError:
            continue
    _record_error(run, path + ": not JSON")
    return None


def _read_registry_file(path: str) -> bytes:
    """The bytes of one registry file; json.loads decodes them, so bad UTF-8 is a parse failure."""
    with open(path, "rb") as handle:
        return handle.read()


def _start_time(proc_root: str, pid: int) -> str | None:
    """The start time of a running pid, or None when its stat is missing, unreadable or malformed."""
    try:
        with open(os.path.join(proc_root, str(pid), "stat"), encoding="utf-8", errors="replace") as handle:
            return proc_start(handle.read())
    except (OSError, IndexError):
        return None


def _is_pid(value: Any) -> TypeGuard[int]:
    # A bool is an int to Python, never a pid.
    return isinstance(value, int) and not isinstance(value, bool)


def _under(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _first_line(text: str) -> str:
    """The first non-blank line of text, stripped; "" when there is none."""
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def _note_fallback(run: Run | None, reason: str) -> None:
    if run is not None:
        run.notes.append(reason + "; registry read directly")


def _record_unreadable(run: Run, path: str, exc: OSError) -> None:
    _record_error(run, "read " + path + ": " + (exc.strerror or str(exc)))


def _record_error(run: Run, line: str) -> None:
    run.errors.append(line)
    run.complete = False
