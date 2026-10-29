"""Tests for scripts/unfinishedlib/live.py: claude-sessions rows, registry
files, the process scan, de-duplication by pid, and the marking of sessions
as live or possibly live.

Every case builds its own /proc tree through tests/proc_fixture.py and its
own slot roots under a temporary directory, and passes a fake runner, so no
case reads this machine's /proc, slots or registry. Checkout paths and cwds
are fixed strings that no case reads from disk.
"""

import errno
import io
import json
import os
import tempfile
import unittest
from stat import ST_UID
from typing import Any
from unittest import mock

from scripts.unfinishedlib import live, model
from scripts.unfinishedlib.model import LiveSession
from tests import proc_fixture

MAIN = "/r/main"
WORKTREE = MAIN + "/.worktrees/a"
OUTSIDE = "/tmp/wt"
CHECKOUTS = [
    model.Checkout(MAIN, "main", "1" * 40, True, True),
    model.Checkout(WORKTREE, "a", "2" * 40, False, True),
    model.Checkout(OUTSIDE, "b", "3" * 40, False, True),
    model.Checkout("/tmp/gone", "c", "4" * 40, False, False),
]
START = 2849239
NOW = 1_800_000_000.0
CLAUDE_SESSIONS = ["claude-sessions", "--json", "--all"]


def _runner(
    returncode: int,
    stdout: str,
    calls: list[tuple[list[str], str | None]] | None = None,
    *,
    stderr: str = "",
) -> model.Runner:
    """A runner that answers every command with returncode, stdout and stderr, recording each call."""

    def run(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
        if calls is not None:
            calls.append((argv, cwd))
        return returncode, stdout, stderr

    return run


def _row(number: int, cwd: str, **fields: Any) -> dict[str, Any]:
    """A claude-sessions --json row for pid number, in the shape the command prints; fields override keys."""
    row: dict[str, Any] = {
        "state": "idle",
        "project": "p",
        "root": cwd,
        "name": "n-" + str(number),
        "kind": "interactive",
        "slot": "1",
        "tmux": "-",
        "pane": "",
        "since": 3,
        "detail": "",
        "cwd": cwd,
        "sessionId": "s-" + str(number),
        "pid": number,
    }
    row.update(fields)
    return row


def _process(pid: int, cwd: str, slot: str = "1") -> LiveSession:
    return LiveSession(None, pid, cwd, slot, "", "unknown", "process")


def _session(session_id: str, cwd: str, mtime: float) -> model.Session:
    return model.Session(
        id=session_id,
        path="/t/" + session_id + ".jsonl",
        mtime=mtime,
        cwds={cwd: "main"},
        first_ts="",
        last_ts="",
        user_turns=1,
        last_request="",
        last_assistant="",
        ended_on_question=False,
        entrypoint="cli",
        account_uuid=None,
        slot="1",
        live=None,
        ran_skill=False,
        evidence=[],
    )


def _note(checkout: str) -> str:
    return "unregistered claude process in " + checkout + "; its recent transcripts are marked possibly live"


class LiveTest(unittest.TestCase):
    def setUp(self) -> None:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        self.tmp = os.path.realpath(holder.name)
        self.proc = os.path.join(self.tmp, "proc")
        os.makedirs(self.proc)
        self.slot1 = os.path.join(self.tmp, "home", ".claude")
        self.slot2 = os.path.join(self.tmp, "home", ".claude2")
        self.state = model.Run()

    # Fixtures.

    def _register(self, slot_root: str, pid: int, start: int, **fields: Any) -> str:
        """Write a registry entry for pid to <slot_root>/sessions/<pid>.json; return its path."""
        entry: dict[str, Any] = {
            "pid": pid,
            "procStart": str(start),
            "sessionId": "s-" + str(pid),
            "cwd": MAIN,
            "kind": "interactive",
            "name": "n-" + str(pid),
            "status": "idle",
        }
        entry.update(fields)
        return self._write_registry(slot_root, str(pid) + ".json", json.dumps(entry))

    def _write_status(self, pid: int, *lines: str) -> str:
        """Replace <proc>/<pid>/status with a Name line followed by lines; return its path."""
        path = os.path.join(self.proc, str(pid), "status")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("".join(line + "\n" for line in ("Name:\tclaude", *lines)))
        return path

    def _write_registry(self, slot_root: str, name: str, text: str) -> str:
        folder = os.path.join(slot_root, "sessions")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    # Start time.

    def test_proc_start_reads_field_22(self) -> None:
        proc_fixture.make_proc(self.proc, 4242, "claude code", MAIN, None, START)
        with open(os.path.join(self.proc, "4242", "stat"), encoding="utf-8") as handle:
            stat = handle.read()

        self.assertTrue(stat.startswith("4242 (claude code) S "))
        self.assertEqual(live.proc_start(stat), str(START))
        # A comm holding parentheses: the fields start after the last one.
        self.assertEqual(live.proc_start(stat.replace("(claude code)", "(a) b (c)")), str(START))

    # claude-sessions.

    def test_claude_sessions_rows_are_consumed(self) -> None:
        rows = [
            _row(101, MAIN, state="working"),
            _row(102, WORKTREE, slot="2", state="waiting"),
        ]
        calls: list[tuple[list[str], str | None]] = []

        found = live.from_claude_sessions(_runner(0, json.dumps(rows), calls))

        self.assertEqual(calls, [(CLAUDE_SESSIONS, None)])
        self.assertEqual(
            found,
            [
                LiveSession("s-101", 101, MAIN, "1", "n-101", "working", "claude-sessions"),
                LiveSession("s-102", 102, WORKTREE, "2", "n-102", "waiting", "claude-sessions"),
            ],
        )

    def test_claude_sessions_rows_without_a_usable_pid_or_id(self) -> None:
        old = _row(103, MAIN)
        del old["pid"], old["sessionId"]
        rows: list[Any] = [
            old,  # an older claude-sessions: no pid to de-duplicate on
            _row(104, MAIN, pid=True),
            _row(105, MAIN, pid="105"),
            _row(106, MAIN, sessionId=None),
            "not a row",
        ]
        no_cwd = _row(107, MAIN)
        del no_cwd["cwd"]
        rows.append(no_cwd)

        found = live.from_claude_sessions(_runner(0, json.dumps(rows)))

        self.assertEqual(found, [LiveSession(None, 106, MAIN, "1", "n-106", "idle", "claude-sessions")])

    def test_claude_sessions_missing_returns_none(self) -> None:
        self.assertIsNone(live.from_claude_sessions(_runner(127, "")))
        self.assertIsNone(live.from_claude_sessions(_runner(1, "[]")))
        self.assertIsNone(live.from_claude_sessions(_runner(0, "{}")))
        self.assertIsNone(live.from_claude_sessions(_runner(0, "jq: error")))

    def test_claude_sessions_failure_is_a_note(self) -> None:
        command = "claude-sessions --json --all: "
        fallback = "; registry read directly"
        not_array = command + "output is not a JSON array" + fallback
        cases = [
            (127, "", "claude-sessions: command not found", "claude-sessions: not found" + fallback),
            # The first non-blank line of stderr, stripped.
            (1, "", "\n  jq: error: syntax error\nmore\n", command + "exit 1: jq: error: syntax error" + fallback),
            (2, "", "", command + "exit 2" + fallback),
            (0, "{}", "", not_array),
            (0, "jq: error", "", not_array),
        ]
        for returncode, stdout, stderr, note in cases:
            with self.subTest(returncode=returncode, stdout=stdout):
                state = model.Run()

                found = live.from_claude_sessions(_runner(returncode, stdout, stderr=stderr), run=state)

                self.assertIsNone(found)
                self.assertEqual(state.notes, [note])
                self.assertEqual(state.errors, [])
                self.assertTrue(state.complete)
        state = model.Run()

        self.assertEqual(live.from_claude_sessions(_runner(0, "[]"), run=state), [])
        self.assertEqual(state.notes, [])

    # Registry files.

    def test_registry_requires_matching_start_time(self) -> None:
        proc_fixture.make_proc(self.proc, 201, "claude", MAIN, None, START)
        proc_fixture.make_proc(self.proc, 202, "claude", MAIN, None, START)
        self._register(self.slot1, 201, START, status="busy")
        # A stale row: pid 202 was reused by a process started later.
        self._register(self.slot1, 202, START - 1)
        # A row whose process is gone.
        self._register(self.slot2, 203, START)

        found = live.from_registry([self.slot1, self.slot2], self.proc, self.state)

        self.assertEqual(found, [LiveSession("s-201", 201, MAIN, "1", "n-201", "working", "registry")])
        self.assertEqual(self.state.errors, [])

    def test_registry_malformed_file_is_an_error_and_unusable_rows_are_skipped(self) -> None:
        other = os.path.join(self.tmp, "home", "custom")
        empty = os.path.join(self.tmp, "home", ".claude3")
        os.makedirs(empty)
        for pid in (301, 302, 303):
            proc_fixture.make_proc(self.proc, pid, "claude", MAIN, None, START)
        self._register(self.slot2, 301, START, status="waiting")
        broken = self._write_registry(self.slot2, "302.json", '{"pid": 302, "procStart"')
        self._write_registry(self.slot2, "303.json", json.dumps([303]))
        self._write_registry(self.slot2, "no-pid.json", json.dumps({"procStart": str(START), "cwd": MAIN}))
        self._write_registry(self.slot2, "bool-pid.json", json.dumps({"pid": True, "procStart": str(START), "cwd": MAIN}))
        self._write_registry(self.slot2, "no-start.json", json.dumps({"pid": 301, "cwd": MAIN}))
        self._write_registry(self.slot2, "no-cwd.json", json.dumps({"pid": 301, "procStart": str(START)}))
        # The registry also holds key files, which are not entries.
        self._write_registry(self.slot2, "301.0123abcd.key", "not json")
        # A root of another name, and an entry with no session id, name or status.
        self._write_registry(other, "303.json", json.dumps({"pid": 303, "procStart": START, "cwd": MAIN, "sessionId": 7}))

        found = live.from_registry([self.slot2, empty, other], self.proc, self.state)

        self.assertEqual(
            found,
            [
                LiveSession("s-301", 301, MAIN, "2", "n-301", "waiting", "registry"),
                LiveSession(None, 303, MAIN, "unknown", "", "idle", "registry"),
            ],
        )
        self.assertEqual(self.state.errors, [broken + ": not JSON"])
        self.assertFalse(self.state.complete)

    def test_registry_rereads_a_file_caught_mid_write(self) -> None:
        for pid in (901, 902, 903, 904):
            proc_fixture.make_proc(self.proc, pid, "claude", MAIN, None, START)
        whole = self._register(self.slot1, 901, START)
        broken = self._write_registry(self.slot1, "902.json", '{"pid": 902, "procStart"')
        vanishing = self._register(self.slot1, 903, START)
        locked = self._register(self.slot1, 904, START)
        real_read = live._read_registry_file
        reads: list[str] = []

        def read(path: str) -> bytes:
            """The first read of every file but the broken one is cut short, as mid-write."""
            reads.append(path)
            data = real_read(path)
            if path != broken and reads.count(path) == 1:
                return data[: len(data) // 2]
            if path == vanishing:
                raise FileNotFoundError(2, "No such file or directory", path)
            if path == locked:
                raise PermissionError(13, "Permission denied", path)
            return data

        with mock.patch.object(live, "_read_registry_file", read):
            found = live.from_registry([self.slot1], self.proc, self.state)

        self.assertEqual(found, [LiveSession("s-901", 901, MAIN, "1", "n-901", "idle", "registry")])
        self.assertEqual(reads, [path for path in (whole, broken, vanishing, locked) for _ in (1, 2)])
        self.assertEqual(self.state.errors, [broken + ": not JSON", "read " + locked + ": Permission denied"])

    # The process scan.

    def test_process_scan_reads_cwd_and_slot(self) -> None:
        proc_fixture.make_proc(self.proc, 1000, "claude", MAIN, "/h/.claude/", START)
        proc_fixture.make_proc(self.proc, 401, "claude", WORKTREE, "/h/.claude2", START)
        proc_fixture.make_proc(self.proc, 402, "claude", "/elsewhere", None, START)
        proc_fixture.make_proc(self.proc, 403, "claude", MAIN, "", START)
        proc_fixture.make_proc(self.proc, 404, "claude", MAIN, "/h/custom", START)
        # The tray indicator's own process is not a session.
        proc_fixture.make_proc(self.proc, 405, "claude-sessions", MAIN, None, START)

        found = live.from_processes(self.proc, self.state)

        self.assertEqual(
            found,
            [
                _process(401, WORKTREE, "2"),
                _process(402, "/elsewhere", "1"),
                _process(403, MAIN, "1"),
                _process(404, MAIN, "unknown"),
                _process(1000, MAIN, "1"),
            ],
        )
        self.assertEqual(self.state.errors, [])

    def test_non_claude_process_with_unreadable_cwd_is_ignored(self) -> None:
        proc_fixture.make_proc(self.proc, 501, "bash", "/root", None, START)
        os.remove(os.path.join(self.proc, "501", "cwd"))
        # An entry that exited before its comm was read, and the entries
        # /proc holds that are not processes.
        os.makedirs(os.path.join(self.proc, "502"))
        os.makedirs(os.path.join(self.proc, "sys"))
        with open(os.path.join(self.proc, "uptime"), "w", encoding="utf-8") as handle:
            handle.write("1.0 2.0\n")

        found = live.from_processes(self.proc, self.state)

        self.assertEqual(found, [])
        self.assertEqual(self.state.errors, [])
        self.assertTrue(self.state.complete)

    def test_claude_process_vanishing_is_an_error(self) -> None:
        proc_fixture.make_proc(self.proc, 601, "claude", MAIN, None, START, with_stat=False)
        proc_fixture.make_proc(self.proc, 602, "claude", MAIN, None, START)
        proc_fixture.make_proc(self.proc, 603, "claude", MAIN, None, START)
        os.remove(os.path.join(self.proc, "603", "environ"))

        found = live.from_processes(self.proc, self.state)

        self.assertEqual(found, [_process(602, MAIN)])
        self.assertEqual(
            self.state.errors,
            [
                "read " + os.path.join(self.proc, "601", "stat") + ": No such file or directory",
                "read " + os.path.join(self.proc, "603", "environ") + ": No such file or directory",
            ],
        )
        self.assertFalse(self.state.complete)

    def test_another_users_claude_process_is_skipped_silently(self) -> None:
        other = os.getuid() + 1
        proc_fixture.make_proc(self.proc, 801, "claude", MAIN, None, START, with_stat=False, uid=other)
        proc_fixture.make_proc(self.proc, 802, "claude", WORKTREE, "/h/.claude2", START)
        proc_fixture.make_proc(self.proc, 803, "claude", MAIN, None, START)
        # Nothing past status is read for another user's process: its stat,
        # cwd and environ are gone, so a read of any of them would be an error.
        for name in ("cwd", "environ"):
            os.remove(os.path.join(self.proc, "801", name))
        # A setuid process: the real uid, the first field after Uid:, decides.
        mine = str(os.getuid())
        self._write_status(803, "Uid:\t" + str(other) + "\t" + mine + "\t" + mine + "\t" + mine)

        found = live.from_processes(self.proc, self.state)

        self.assertEqual(found, [_process(802, WORKTREE, "2")])
        self.assertEqual(self.state.errors, [])
        self.assertTrue(self.state.complete)

    def test_this_users_claude_process_with_an_unreadable_environ_is_an_error(self) -> None:
        proc_fixture.make_proc(self.proc, 811, "claude", MAIN, None, START)
        proc_fixture.make_proc(self.proc, 812, "claude", MAIN, None, START)
        folder = os.path.join(self.proc, "811")
        environ = os.path.join(folder, "environ")
        # A process that is not dumpable: the kernel gives its /proc directory
        # and environ to root, while its status stays readable and names this user.
        os.chmod(environ, 0)
        if os.access(environ, os.R_OK):
            self.skipTest("this user can read a file of mode 0")
        real_stat = os.stat

        def owned_by_root(path: Any, *args: Any, **kwargs: Any) -> os.stat_result:
            result = real_stat(path, *args, **kwargs)
            if path != folder:
                return result
            fields = list(result)
            fields[ST_UID] = 0
            return os.stat_result(fields)

        with mock.patch.object(live.os, "stat", owned_by_root):
            found = live.from_processes(self.proc, self.state)

        self.assertEqual(found, [_process(812, MAIN)])
        self.assertEqual(self.state.errors, ["read " + environ + ": Permission denied"])
        self.assertFalse(self.state.complete)

    def test_claude_process_whose_status_vanishes_is_skipped_silently(self) -> None:
        for pid in (821, 822, 823):
            proc_fixture.make_proc(self.proc, pid, "claude", MAIN, None, START)
        # The process exits after its comm is read: its status is gone at the
        # open (ENOENT), or opens and then fails at the read (ESRCH).
        os.remove(os.path.join(self.proc, "821", "status"))
        exited = os.path.join(self.proc, "823", "status")
        real_open = open

        class Exited(io.StringIO):
            def read(self, size: int | None = -1) -> str:
                raise ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH))

        def exiting_open(file: Any, *args: Any, **kwargs: Any) -> Any:
            if file == exited:
                return Exited()
            return real_open(file, *args, **kwargs)

        with mock.patch.object(live, "open", exiting_open, create=True):
            found = live.from_processes(self.proc, self.state)

        self.assertEqual(found, [_process(822, MAIN)])
        self.assertEqual(self.state.errors, [])
        self.assertTrue(self.state.complete)

    def test_claude_process_whose_status_cannot_be_read_is_an_error(self) -> None:
        proc_fixture.make_proc(self.proc, 831, "claude", MAIN, None, START)
        proc_fixture.make_proc(self.proc, 832, "claude", MAIN, None, START)
        status = os.path.join(self.proc, "831", "status")
        os.chmod(status, 0)
        if os.access(status, os.R_OK):
            self.skipTest("this user can read a file of mode 0")

        found = live.from_processes(self.proc, self.state)

        self.assertEqual(found, [_process(832, MAIN)])
        self.assertEqual(self.state.errors, ["read " + status + ": Permission denied"])
        self.assertFalse(self.state.complete)

    def test_claude_process_whose_status_names_no_real_uid_is_an_error(self) -> None:
        for pid in (841, 842, 843, 844):
            proc_fixture.make_proc(self.proc, pid, "claude", MAIN, None, START)
        mine = str(os.getuid())
        no_line = self._write_status(841, "Gid:\t0\t0\t0\t0")
        # A lenient parse would read this user's uid from the field's digits.
        not_integer = self._write_status(842, "Uid:\t" + mine + "x\t" + mine + "\t" + mine + "\t" + mine)
        empty = self._write_status(843, "Uid:")

        found = live.from_processes(self.proc, self.state)

        self.assertEqual(found, [_process(844, MAIN)])
        self.assertEqual(
            self.state.errors,
            [path + ": no real uid" for path in (no_line, not_integer, empty)],
        )
        self.assertFalse(self.state.complete)

    # The union.

    def test_dedupe_backfills_session_id(self) -> None:
        proc_fixture.make_proc(self.proc, 701, "claude", MAIN, None, START)
        proc_fixture.make_proc(self.proc, 702, "claude", MAIN, "/h/.claude2", START)
        self._register(self.slot1, 701, START)
        rows = [_row(701, MAIN, sessionId=None, state="working")]

        found = live.live_sessions([self.slot1], self.proc, _runner(0, json.dumps(rows)), self.state)

        self.assertEqual(
            found,
            [
                LiveSession("s-701", 701, MAIN, "1", "n-701", "working", "claude-sessions"),
                _process(702, MAIN, "2"),
            ],
        )
        # Without the command the registry row comes first; neither is an error.
        found = live.live_sessions([self.slot1], self.proc, _runner(127, ""), self.state)

        self.assertEqual(
            found,
            [LiveSession("s-701", 701, MAIN, "1", "n-701", "idle", "registry"), _process(702, MAIN, "2")],
        )
        self.assertEqual(self.state.errors, [])
        self.assertEqual(self.state.notes, ["claude-sessions: not found; registry read directly"])

    # The repository and the marks.

    def test_in_repository_filters_other_cwds(self) -> None:
        cwds = [
            MAIN,
            MAIN + "/src",
            WORKTREE + "/src",
            MAIN + "/.worktrees/gone/src",
            OUTSIDE + "/src",
            "/elsewhere",
            "/r/main-2",
            "/tmp/gone/src",
        ]
        rows = [_process(pid, cwd) for pid, cwd in enumerate(cwds, start=1)]

        found = live.in_repository(rows, CHECKOUTS, MAIN)

        self.assertEqual([row.cwd for row in found], cwds[:5])

    def test_mark_live_by_id_and_possibly_live_by_recent_mtime(self) -> None:
        named = _session("s-named", MAIN, NOW - 5000)
        both = _session("s-both", MAIN, NOW)
        recent = _session("s-recent", MAIN + "/src", NOW)
        edge = _session("s-edge", MAIN, NOW - 600)
        old = _session("s-old", MAIN, NOW - 1200)
        worktree = _session("s-worktree", WORKTREE, NOW)
        rows = [
            # Matched by id although the process runs outside the repository.
            LiveSession("s-named", 1, "/elsewhere", "1", "n", "idle", "registry"),
            LiveSession("s-both", 2, MAIN, "1", "n", "idle", "registry"),
            _process(3, MAIN),
            _process(4, MAIN + "/docs"),
            _process(5, "/elsewhere"),
        ]

        notes = live.mark_live([named, both, recent, edge, old, worktree], rows, CHECKOUTS, MAIN, NOW)

        self.assertEqual(named.live, "live")
        self.assertEqual(both.live, "live")
        self.assertEqual(recent.live, "possibly live")
        self.assertEqual(edge.live, "possibly live")
        self.assertIsNone(old.live)
        self.assertIsNone(worktree.live)
        self.assertEqual(notes, [_note(MAIN)])

    def test_unregistered_process_marks_its_own_checkout(self) -> None:
        gone = MAIN + "/.worktrees/gone"
        in_gone = _session("s-gone", gone, NOW)
        in_main = _session("s-main", MAIN, NOW)
        in_outside = _session("s-outside", OUTSIDE + "/src", NOW)
        rows = [_process(1, gone + "/src"), _process(2, OUTSIDE)]

        notes = live.mark_live([in_gone, in_main, in_outside], rows, CHECKOUTS, MAIN, NOW)

        # A removed worktree under the main checkout is its own checkout, not main's.
        self.assertEqual(in_gone.live, "possibly live")
        self.assertIsNone(in_main.live)
        self.assertEqual(in_outside.live, "possibly live")
        self.assertEqual(notes, [_note(gone), _note(OUTSIDE)])


    def test_process_in_a_removed_worktree_marks_it_possibly_live(self) -> None:
        gone = MAIN + "/.worktrees/gone"
        # The kernel marks a removed cwd with " (deleted)"; only one marker is stripped.
        proc_fixture.make_proc(self.proc, 801, "claude", gone + " (deleted)", None, START)
        proc_fixture.make_proc(self.proc, 802, "claude", "/w/x (deleted) (deleted)", None, START)
        in_gone = _session("s-gone", gone, NOW)
        in_main = _session("s-main", MAIN, NOW)

        found = live.live_sessions([self.slot1], self.proc, _runner(0, "[]"), self.state)
        notes = live.mark_live([in_gone, in_main], found, CHECKOUTS, MAIN, NOW)

        self.assertEqual(found, [_process(801, gone), _process(802, "/w/x (deleted)")])
        self.assertEqual(in_gone.live, "possibly live")
        self.assertIsNone(in_main.live)
        self.assertEqual(notes, [_note(gone)])
