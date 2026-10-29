"""Tests for scripts/unfinishedlib/render.py: the text report's layout and
vocabulary, and the JSON object's keys.

Every case builds its Inventory from model values; checkout paths are fixed
strings that no case reads from disk.
"""

import json
import unittest
from datetime import datetime
from typing import Any

from scripts.unfinishedlib import associate, inventory, render
from scripts.unfinishedlib.model import Association, Checkout, Item, LiveSession, MergeRequest, Session

MAIN = "/r/main"
WORKTREE = MAIN + "/.worktrees/a"
CHECKOUTS = [
    Checkout(MAIN, "main", "1" * 40, True, True),
    Checkout(WORKTREE, "a", "2" * 40, False, True),
]
GEORGIAN = "გააკეთე ეს"


def _meta(**over: Any) -> dict[str, Any]:
    meta: dict[str, Any] = {
        "complete": True,
        "errors": [],
        "notes": [inventory.OUT_OF_REACH_NOTE],
        "remote": "origin",
        "base": "origin/main",
        "base_source": "remote-head",
        "fetch_age_seconds": 7200,
        "transcripts": {
            "count": 3,
            "bytes": 2048,
            "oldest": "2026-10-01T10:00:00.000Z",
            "newest": "2026-10-02T10:00:00.000Z",
        },
        "question_window_days": 30,
    }
    meta.update(over)
    return meta


def _item(kind: str, title: str, date: str | None, **kw: Any) -> Item:
    return Item(
        kind=kind,
        title=title,
        certainty=kw.get("certainty", "certain"),
        lines=kw.get("lines", ["a line of " + title]),
        paths=kw.get("paths", []),
        names=kw.get("names", []),
        date=date,
        sha=None,
        sessions=kw.get("sessions", []),
        attrs=kw.get("attrs", {}),
    )


def _session(session_id: str, **kw: Any) -> Session:
    return Session(
        id=session_id,
        path="/t/" + session_id + ".jsonl",
        mtime=0.0,
        cwds={MAIN: "main"},
        first_ts="2026-10-01T10:00:00.000Z",
        last_ts=kw.get("last_ts", "2026-10-01T11:00:00.000Z"),
        user_turns=kw.get("user_turns", 1),
        last_request=kw.get("last_request", "do the thing"),
        last_assistant=kw.get("last_assistant", "Shall I merge it?"),
        ended_on_question=kw.get("ended_on_question", True),
        entrypoint="cli",
        account_uuid=None,
        slot=kw.get("slot", "2"),
        live=kw.get("live"),
        ran_skill=False,
        evidence=[],
        cwd_counts={MAIN: 1},
    )


def _association(session_id: str, **kw: Any) -> Association:
    return Association(
        session_id=session_id,
        evidence=kw.get("evidence", "work"),
        token=kw.get("token", "feature/x"),
        ts=kw.get("ts", "2026-10-01T10:30:00.000Z"),
        slot=kw.get("slot", "2"),
        checkout=kw.get("checkout", WORKTREE),
        last_request=kw.get("last_request", "do the thing"),
        live=kw.get("live"),
    )


def _inventory(items_by_kind: dict[str, list[Item]], **kw: Any) -> inventory.Inventory:
    return inventory.Inventory(
        items_by_kind=items_by_kind,
        live=kw.get("live", []),
        questions=kw.get("questions", []),
        parked=kw.get("parked", 3),
        meta=kw.get("meta", _meta()),
        sessions=kw.get("sessions", []),
        checkouts=kw.get("checkouts", CHECKOUTS),
    )


def _every_kind() -> dict[str, list[Item]]:
    """Two items per kind, the newer one first, so the report must reorder them."""
    found: dict[str, list[Item]] = {}
    for kind in inventory.KINDS:
        found[kind] = [
            _item(kind, kind + "-newer-item", "2026-10-20T10:00:00+04:00"),
            _item(kind, kind + "-older-item", "2026-10-02T10:00:00+04:00"),
        ]
    return found


class RenderTextTest(unittest.TestCase):
    def test_no_session_evidence_line(self) -> None:
        item = _item("tip", "feature/x", "2026-10-02T10:00:00+04:00")

        out = render.render_text(_inventory({"tip": [item]}), MAIN)

        block = out[out.index("tip (certain): feature/x") :]
        self.assertIn("\n  no session evidence in the scanned transcripts\n", block)

    def test_association_line_carries_id_slot_checkout_date_live_and_request(self) -> None:
        session = _session("0b1c2d3e-0000-4000-8000-000000000001", last_ts="2026-10-03T10:00:00.000Z")
        item = _item(
            "tip",
            "feature/x",
            "2026-10-02T10:00:00+04:00",
            sessions=[
                _association(session.id, live="live", last_request="please\n  finish   it"),
                _association("unknown-session", slot="unknown", checkout=MAIN, last_request=""),
            ],
        )

        out = render.render_text(_inventory({"tip": [item]}, sessions=[session]), MAIN)

        stamp = inventory.local_minute(session.last_ts)
        self.assertIn("  " + session.id + "  slot 2  a  " + stamp + "  live  \"please finish it\"\n", out)
        self.assertIn("  unknown-session  unknown slot  main  ", out)
        self.assertNotIn("no session evidence", out)

    def test_question_window_and_flag(self) -> None:
        now = datetime.fromisoformat("2026-10-29T12:00:00+00:00").timestamp()
        old = _session("old-question", last_ts="2026-09-19T12:00:00.000Z")
        recent = _session("recent-question", last_ts="2026-10-25T12:00:00.000Z")

        questions = associate.question_sessions([old, recent], 30, now)

        self.assertEqual([session.id for session in questions], ["recent-question"])
        shown = render.render_text(_inventory({}, questions=questions), MAIN)
        self.assertIn(render.QUESTION_HEADING, shown)
        self.assertIn("unverified", render.QUESTION_HEADING)
        self.assertIn("recent-question", shown)
        self.assertIn("Shall I merge it?", shown)
        hidden = render.render_text(_inventory({}, questions=[], meta=_meta(question_window_days=None)), MAIN)
        self.assertNotIn("ended on a question", hidden)
        self.assertNotIn("unverified", hidden)
        self.assertIn("question window: off", hidden)

    def test_render_text_group_order_oldest_first_and_footer(self) -> None:
        live = [LiveSession("s-live", 4242, WORKTREE + "/src", "3", "review-pane", "working", "registry")]

        out = render.render_text(_inventory(_every_kind(), live=live), MAIN)

        self.assertTrue(out.startswith(render.REPORT_HEADER + MAIN + "\n"))
        headings = [out.index(render.GROUP_HEADINGS[kind]) for kind in inventory.KINDS]
        self.assertEqual(headings, sorted(headings))
        for kind in inventory.KINDS:
            self.assertLess(out.index(kind + "-older-item"), out.index(kind + "-newer-item"), kind)
            self.assertIn(kind + " (certain): " + kind + "-older-item", out)
        stale = out.index(render.GROUP_HEADINGS["openspec-stale"])
        questions = out.index(render.QUESTION_HEADING)
        live_at = out.index(render.LIVE_HEADING)
        parked = out.index("Parked notes: 3\n")
        footer = out.index("\n" + render.FOOTER_HEADING + "\n")
        self.assertLess(stale, questions)
        self.assertLess(questions, live_at)
        self.assertLess(live_at, parked)
        self.assertLess(parked, footer)
        self.assertIn("  review-pane  working  slot 3  a\n", out[live_at:parked])
        tail = out[footer:]
        for word in ("remote: origin", "base: origin/main", "last fetch of any remote: 2 hours ago", "transcripts scanned: 3 files", "question window: 30 days", "notes", inventory.OUT_OF_REACH_NOTE, "errors: none"):
            self.assertIn(word, tail)

    def test_undated_items_sort_last(self) -> None:
        items = [
            _item("tip", "undated-tip", None),
            _item("tip", "unparsable-tip", "yesterday"),
            _item("tip", "dated-tip", "2026-10-02T10:00:00+04:00"),
        ]

        out = render.render_text(_inventory({"tip": items}), MAIN)

        self.assertLess(out.index("dated-tip"), out.index("undated-tip"))
        self.assertLess(out.index("dated-tip"), out.index("unparsable-tip"))

    def test_empty_groups_say_none_and_merge_requests_stay_out(self) -> None:
        out = render.render_text(_inventory({}, parked=None), MAIN)

        self.assertIn(render.GROUP_HEADINGS["tip"] + ": none\n", out)
        self.assertNotIn(render.GROUP_HEADINGS["merge-request"], out)
        self.assertIn(render.LIVE_HEADING + ": none\n", out)
        self.assertIn("Parked notes: no queue file\n", out)

    def test_paths_print_absolute_capped_and_never_for_openspec(self) -> None:
        dirty = _item(
            "dirty",
            WORKTREE,
            None,
            lines=["12 changed paths: 12 untracked"],
            paths=["f" + format(n, "02d") + ".txt" for n in range(12)],
            attrs={"checkout": WORKTREE},
        )
        stash = _item("stash", "stash@{0}: wip", "2026-10-02T10:00:00+04:00", paths=["notes.txt"])
        change = _item("openspec-pending", "bar", None, lines=[MAIN + "  untracked  tasks 0/1"], paths=["openspec/changes/bar"])

        out = render.render_text(_inventory({"dirty": [dirty], "stash": [stash], "openspec-pending": [change]}), MAIN)

        for n in range(10):
            self.assertIn("\n  " + WORKTREE + "/f" + format(n, "02d") + ".txt\n", out)
        self.assertNotIn("f10.txt", out)
        self.assertIn("\n  and 2 more paths\n", out)
        self.assertIn("\n  " + MAIN + "/notes.txt\n", out)
        self.assertNotIn("openspec/changes/bar", out)

    def test_footer_without_remote_base_fetch_or_sessions(self) -> None:
        meta = _meta(
            complete=False,
            errors=["git status: boom"],
            remote=None,
            base=None,
            base_source="unknown",
            fetch_age_seconds=None,
            transcripts={"count": 0, "bytes": 0, "oldest": None, "newest": None},
        )

        out = render.render_text(_inventory({}, meta=meta), MAIN)

        tail = out[out.index("\n" + render.FOOTER_HEADING + "\n") :]
        self.assertIn("remote: none", tail)
        self.assertIn("base: unknown", tail)
        self.assertIn("last fetch of any remote: never", tail)
        self.assertIn("transcripts scanned: 0 files", tail)
        self.assertIn("errors (1):\n    git status: boom\n", tail)
        self.assertIn("incomplete", tail)

    def test_control_characters_print_as_question_marks(self) -> None:
        escape = "\x1b[31m"
        session = _session("s-esc", last_request="do " + escape + "it", last_assistant="Shall I " + escape + "merge?")
        tip = _item(
            "tip",
            "feature/x",
            "2026-10-02T10:00:00+04:00",
            sessions=[_association("s-esc", last_request="do " + escape + "it")],
        )
        request = MergeRequest(7, escape + "Red\x07 title\x9b", "open", "42", "feature/y", "", "main", "u", "https://f/7")
        requests = inventory.merge_request_items([request], [])
        # A LF inside one element is not a line break of the report.
        dirty = _item("dirty", WORKTREE, None, paths=["two\nlines.txt"], attrs={"checkout": WORKTREE})
        inv = _inventory(
            {"tip": [tip], "dirty": [dirty], "merge-request": requests}, questions=[session], sessions=[session]
        )

        out = render.render_text(inv, MAIN)

        controls = [char for char in out if (ord(char) < 0x20 and char != "\n") or 0x7F <= ord(char) <= 0x9F]
        self.assertEqual(controls, [])
        self.assertIn("  \"do ?[31mit\"\n", out)
        self.assertIn("\n    asked: \"Shall I ?[31mmerge?\"\n", out)
        self.assertIn("\nmerge-request (certain): !7 ?[31mRed? title?\n", out)
        self.assertIn("\n  " + WORKTREE + "/two?lines.txt\n", out)
        # The JSON escapes them itself and keeps the text as read.
        data = json.loads(render.render_json(inv))
        self.assertEqual(data["merge_requests"][0]["title"], "!7 " + escape + "Red\x07 title\x9b")

    def test_render_text_has_no_dashes_or_emoji(self) -> None:
        kinds = _every_kind()
        session = _session("s-ka", last_request=GEORGIAN, last_assistant=GEORGIAN + "?")
        kinds["tip"][0].sessions = [_association("s-ka", last_request=GEORGIAN, live="possibly live")]
        live = [LiveSession(None, 77, MAIN, "1", "", "unknown", "process")]
        meta = _meta(errors=["x: y"], complete=False, notes=["a note"])

        out = render.render_text(_inventory(kinds, live=live, questions=[session], sessions=[session], meta=meta), MAIN)

        self.assertIn(GEORGIAN, out)
        self.assertNotIn(chr(0x2014), out)
        self.assertNotIn(chr(0x2013), out)
        for char in out:
            self.assertTrue(ord(char) < 0x2000 or 0x10A0 <= ord(char) <= 0x10FF, repr(char))


class RequestLineTest(unittest.TestCase):
    def test_slash_command_request_prints_as_typed(self) -> None:
        raw = (
            "<command-message>opsx:apply</command-message>\n"
            "<command-name>/opsx:apply</command-name>\n"
            "<command-args>harden  the\ndatabase</command-args>"
        )

        self.assertEqual(render.one_line_request(raw), "/opsx:apply harden the database")
        self.assertEqual(
            render.one_line_request("<command-message>x</command-message> <command-name>x</command-name>"),
            "/x",
        )

    def test_long_request_is_cut_at_120_characters(self) -> None:
        text = "word " * 40

        line = render.one_line_request(text)

        self.assertEqual(line, ("word " * 24)[:120] + "...")
        self.assertEqual(render.one_line_request("  short\n\trequest  "), "short request")


class RenderJsonTest(unittest.TestCase):
    def test_render_json_has_exact_keys(self) -> None:
        kinds = _every_kind()
        kinds["tip"][0].sessions = [_association("s1")]
        live = [LiveSession("s-live", 4242, WORKTREE, "3", "review-pane", "working", "registry")]
        inv = _inventory(kinds, live=live, questions=[_session("q")], sessions=[_session("s1")])

        data = json.loads(render.render_json(inv))

        self.assertEqual(
            set(data),
            {
                "openspec_pending",
                "tips",
                "unpublished",
                "dirty",
                "stashes",
                "removed_worktrees",
                "merge_requests",
                "openspec_stale",
                "questions",
                "live_sessions",
                "parked",
                "meta",
            },
        )
        self.assertEqual(set(data["meta"]), set(_meta()))
        self.assertEqual(data["parked"], 3)
        self.assertEqual(data["tips"][1]["sessions"][0]["session_id"], "s1")
        self.assertEqual(data["live_sessions"][0]["pid"], 4242)
        self.assertEqual(data["questions"][0]["id"], "q")
        self.assertEqual([item["title"] for item in data["stashes"]], ["stash-older-item", "stash-newer-item"])


if __name__ == "__main__":
    unittest.main()
