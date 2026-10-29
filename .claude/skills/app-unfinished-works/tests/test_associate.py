"""Tests for scripts/unfinishedlib/associate.py: the names the matcher gets,
the ranking of sessions per item, the --mine filter and the question
sessions.

Every case builds its items, tips and sessions from model values, so no case
reads a fixture commit's author or date, nor this machine's transcripts.
Checkout paths and cwds are fixed strings that no case reads from disk.
"""

import unittest
from datetime import datetime

from scripts.unfinishedlib import associate, inventory
from scripts.unfinishedlib.model import Base, Checkout, Evidence, Item, Remotes, Session, Tip

MAIN = "/r/main"
WORKTREE = MAIN + "/.worktrees/a"
CHECKOUTS = [
    Checkout(MAIN, "main", "1" * 40, True, True),
    Checkout(WORKTREE, "a", "2" * 40, False, True),
]
OWNER = "owner@example.test"
OTHER = "other@example.test"


def _ts(minute: int) -> str:
    """A transcript timestamp (UTC, with a Z) minute minutes after 10:00 on 2026-10-01."""
    return "2026-10-01T10:" + format(minute, "02d") + ":00.000Z"


def _item(
    kind: str,
    title: str,
    *,
    names: list[str] | None = None,
    paths: list[str] | None = None,
    date: str | None = None,
    attrs: dict[str, str] | None = None,
) -> Item:
    return Item(kind, title, "certain", [], list(paths or []), list(names or []), date, None, [], dict(attrs or {}))


def _session(
    session_id: str,
    evidence: list[Evidence],
    *,
    ran_skill: bool = False,
    live: str | None = None,
    cwd_counts: dict[str, int] | None = None,
    last_ts: str = "2026-10-01T11:00:00.000Z",
    ended_on_question: bool = False,
    user_turns: int = 1,
) -> Session:
    counts = dict(cwd_counts or {MAIN: 1})
    return Session(
        id=session_id,
        path="/t/" + session_id + ".jsonl",
        mtime=0.0,
        cwds={cwd: "main" for cwd in counts},
        first_ts="2026-10-01T10:00:00.000Z",
        last_ts=last_ts,
        user_turns=user_turns,
        last_request="request of " + session_id,
        last_assistant="",
        ended_on_question=ended_on_question,
        entrypoint="cli",
        account_uuid=None,
        slot="2",
        live=live,
        ran_skill=ran_skill,
        evidence=evidence,
        cwd_counts=counts,
    )


class BuildNamesTest(unittest.TestCase):
    def test_build_names_adds_unique_last_segment_to_items(self) -> None:
        items = [_item("tip", name, names=[name, "origin/" + name]) for name in ("feature/x", "fix/x", "topic/y")]
        dirty = _item("dirty", MAIN, paths=["src/a.py"])

        names, paths = associate.build_names([*items, dirty], ["feature/x", "fix/x", "topic/y"])

        self.assertEqual(items[2].names, ["topic/y", "origin/topic/y", "y"])
        for item in items:
            self.assertNotIn("x", item.names)
        self.assertIn("y", names)
        self.assertNotIn("x", names)
        self.assertEqual(paths, ["src/a.py"])
        self.assertEqual(dirty.names, [])

    def test_a_full_branch_name_makes_the_segment_ambiguous(self) -> None:
        unpublished = _item("unpublished", "topic/y", names=["topic/y"])
        removed = _item("removed-worktree", "old/z", names=["old/z"])
        change = _item("openspec-pending", "a-b", names=["a-b"])

        associate.build_names([unpublished, removed, change], ["topic/y", "y", "old/z"])

        self.assertEqual(unpublished.names, ["topic/y"])
        self.assertEqual(removed.names, ["old/z", "z"])
        self.assertEqual(change.names, ["a-b"])


class AssociateTest(unittest.TestCase):
    def test_association_ranks_work_over_request_over_mention_over_lookup(self) -> None:
        item = _item("tip", "feature/x", names=["feature/x"])
        sessions = [
            _session("lookup-newest", [Evidence("lookup", "feature/x", _ts(40))]),
            _session("mention", [Evidence("mention", "feature/x", _ts(30))]),
            _session("request", [Evidence("request", "feature/x", _ts(20))]),
            _session("work-oldest", [Evidence("work", "feature/x", _ts(10))]),
        ]

        associate.associate([item], sessions)

        self.assertEqual([a.session_id for a in item.sessions], ["work-oldest", "request", "mention"])
        self.assertEqual([a.evidence for a in item.sessions], ["work", "request", "mention"])

        pair = _item("tip", "feature/x", names=["feature/x"])
        associate.associate([pair], [sessions[0], sessions[3]])
        self.assertEqual([a.session_id for a in pair.sessions], ["work-oldest", "lookup-newest"])

    def test_association_caps_at_three(self) -> None:
        item = _item("tip", "feature/x", names=["feature/x"])
        sessions = [_session("s" + str(n), [Evidence("work", "feature/x", _ts(n))]) for n in range(1, 6)]

        associate.associate([item], sessions)

        self.assertEqual([a.session_id for a in item.sessions], ["s5", "s4", "s3"])

    def test_a_session_counts_once_with_its_best_evidence(self) -> None:
        item = _item("tip", "feature/x", names=["feature/x", "origin/feature/x"])
        session = _session(
            "s",
            [
                Evidence("mention", "feature/x", _ts(50)),
                Evidence("work", "feature/x", _ts(5)),
                Evidence("work", "origin/feature/x", _ts(9)),
            ],
        )

        associate.associate([item], [session])

        self.assertEqual(len(item.sessions), 1)
        found = item.sessions[0]
        self.assertEqual((found.evidence, found.token, found.ts), ("work", "origin/feature/x", _ts(9)))
        self.assertEqual((found.slot, found.last_request, found.live), ("2", "request of s", None))

    def test_association_matches_short_and_remote_forms(self) -> None:
        item = _item("tip", "topic/y", names=["topic/y", "origin/topic/y"])
        other = _item("tip", "feature/x", names=["feature/x", "origin/feature/x"])
        associate.build_names([item, other], ["topic/y", "feature/x"])
        sessions = [
            _session("short", [Evidence("request", "y", _ts(1))]),
            _session("remote", [Evidence("lookup", "origin/topic/y", _ts(2))]),
        ]

        associate.associate([item, other], sessions)

        self.assertEqual([a.session_id for a in item.sessions], ["short", "remote"])
        self.assertEqual([a.token for a in item.sessions], ["y", "origin/topic/y"])
        self.assertEqual(other.sessions, [])

    def test_ran_skill_session_contributes_no_mentions_or_lookups(self) -> None:
        item = _item("tip", "feature/x", names=["feature/x"])
        sessions = [
            _session(
                "report-only",
                [Evidence("mention", "feature/x", _ts(9)), Evidence("lookup", "feature/x", _ts(8))],
                ran_skill=True,
            ),
            _session(
                "report-and-work",
                [Evidence("mention", "feature/x", _ts(7)), Evidence("work", "feature/x", _ts(1))],
                ran_skill=True,
            ),
            # As built, a request still counts: whether a request holding a
            # pasted report should is the owner's open question.
            _session(
                "report-and-request",
                [Evidence("mention", "feature/x", _ts(6)), Evidence("request", "feature/x", _ts(2))],
                ran_skill=True,
            ),
            _session("plain-mention", [Evidence("mention", "feature/x", _ts(3))]),
        ]

        associate.associate([item], sessions)

        self.assertEqual([a.session_id for a in item.sessions], ["report-and-work", "report-and-request", "plain-mention"])
        self.assertEqual([(a.evidence, a.ts) for a in item.sessions[:2]], [("work", _ts(1)), ("request", _ts(2))])

    def test_stash_association_compares_zoned_timestamps(self) -> None:
        # 12:15 at +04:00 is 08:15 UTC: 08:30Z is after it although "08:30" < "12:15" as text.
        stash = _item("stash", "stash@{0}: wip", paths=["notes.txt"], date="2026-10-29T12:15:00+04:00")
        sessions = [
            _session("after", [Evidence("work", "notes.txt", "2026-10-29T08:30:00.000Z", MAIN)]),
            _session("before", [Evidence("work", "notes.txt", "2026-10-29T08:00:00.000Z", MAIN)]),
        ]

        associate.associate([stash], sessions, checkouts=CHECKOUTS, main_path=MAIN)

        self.assertEqual([a.session_id for a in stash.sessions], ["before"])

    def test_stash_with_an_unreadable_date_admits_no_evidence(self) -> None:
        stash = _item("stash", "stash@{0}: wip", paths=["notes.txt"], date="")
        sessions = [_session("before", [Evidence("work", "notes.txt", "2026-10-29T08:00:00.000Z", MAIN)])]

        associate.associate([stash], sessions, checkouts=CHECKOUTS, main_path=MAIN)

        self.assertEqual(stash.sessions, [])

    def test_stash_counts_edits_from_the_main_checkout_only(self) -> None:
        stash = _item("stash", "stash@{0}: wip", paths=["notes.txt"], date="2026-10-29T12:15:00+04:00")
        before = "2026-10-29T08:00:00.000Z"
        sessions = [
            _session("in-main", [Evidence("work", "notes.txt", before, MAIN)]),
            _session("in-worktree", [Evidence("work", "notes.txt", before, WORKTREE)]),
            _session("no-checkout", [Evidence("work", "notes.txt", before)]),
        ]

        associate.associate([stash], sessions, checkouts=CHECKOUTS, main_path=MAIN + "/")

        self.assertEqual([a.session_id for a in stash.sessions], ["in-main"])

    def test_dirty_counts_edits_from_its_own_checkout_only(self) -> None:
        main_dirty = _item("dirty", MAIN, paths=["CLAUDE.md"], attrs={"checkout": MAIN})
        worktree_dirty = _item("dirty", WORKTREE, paths=["CLAUDE.md"], attrs={"checkout": WORKTREE + "/"})
        unbound = _item("dirty", "/r/elsewhere", paths=["CLAUDE.md"])
        # Path evidence of any other kind counts from every checkout.
        change = _item("openspec-pending", "c", names=["c"], paths=["CLAUDE.md"])
        sessions = [
            _session("in-main", [Evidence("work", "CLAUDE.md", _ts(1), MAIN + "/")]),
            _session("in-worktree", [Evidence("work", "CLAUDE.md", _ts(2), WORKTREE)]),
            _session("no-checkout", [Evidence("mention", "CLAUDE.md", _ts(3))]),
        ]

        associate.associate([main_dirty, worktree_dirty, unbound, change], sessions, checkouts=CHECKOUTS, main_path=MAIN)

        self.assertEqual([a.session_id for a in main_dirty.sessions], ["in-main"])
        self.assertEqual([a.session_id for a in worktree_dirty.sessions], ["in-worktree"])
        # A dirty item that names no checkout admits no evidence.
        self.assertEqual(unbound.sessions, [])
        self.assertEqual([a.session_id for a in change.sessions], ["in-worktree", "in-main", "no-checkout"])

    def test_live_is_copied_from_the_session(self) -> None:
        item = _item("dirty", MAIN, paths=["src/a.py"], attrs={"checkout": MAIN})
        sessions = [_session("busy", [Evidence("work", "src/a.py", _ts(1), MAIN)], live="possibly live")]

        associate.associate([item], sessions)

        self.assertEqual(item.sessions[0].live, "possibly live")

    def test_association_checkout_is_the_most_frequent_cwds_checkout(self) -> None:
        item = _item("tip", "feature/x", names=["feature/x"])
        sessions = [
            _session(
                "in-worktree",
                [Evidence("work", "feature/x", _ts(1))],
                cwd_counts={MAIN: 2, WORKTREE + "/src": 5, "/elsewhere": 1},
            ),
            _session("tie", [Evidence("work", "feature/x", _ts(2))], cwd_counts={"/elsewhere": 3, MAIN + "/docs": 3}),
            _session("gone", [Evidence("work", "feature/x", _ts(3))], cwd_counts={MAIN + "/.worktrees/old/src": 1}),
        ]

        associate.associate([item], sessions, checkouts=CHECKOUTS, main_path=MAIN)

        found = {a.session_id: a.checkout for a in item.sessions}
        self.assertEqual(found["in-worktree"], WORKTREE)
        # On a tie the first cwd seen wins; a cwd in no checkout is kept as it is.
        self.assertEqual(found["tie"], "/elsewhere")
        self.assertEqual(found["gone"], MAIN + "/.worktrees/old")


class MineFilterTest(unittest.TestCase):
    def test_mine_filter(self) -> None:
        stamp = "2026-10-01T10:00:00+04:00"
        tips = [
            Tip("1" * 40, ["feature/mine"], "not", 1, stamp, OWNER, None),
            Tip("2" * 40, ["feature/local", "origin/feature/local"], "not", 1, stamp, OTHER, None),
            Tip("3" * 40, [], "not", 1, stamp, OTHER, WORKTREE),
            Tip("4" * 40, ["origin/feature/remote"], "not", 1, stamp, OTHER, None),
            Tip("5" * 40, ["origin/feature/worked"], "not", 1, stamp, OTHER, None),
            Tip("6" * 40, ["origin/feature/talked"], "not", 1, stamp, OTHER, None),
            Tip("7" * 40, ["origin/feature/blank"], "not", 1, stamp, "", None),
        ]
        remotes = Remotes(["origin"], "origin")
        items = inventory.tip_items(tips, remotes, Base("origin/main", "remote-head"), [])
        sessions = [
            _session("worker", [Evidence("work", "origin/feature/worked", _ts(1))]),
            _session("talker", [Evidence("mention", "feature/talked", _ts(2))]),
        ]
        associate.associate(items, sessions)
        dirty = _item("dirty", MAIN, paths=["src/a.py"])
        inv = inventory.Inventory({"tip": items, "dirty": [dirty]}, [], [], None, {})

        associate.mine_filter(inv, OWNER, {"feature/local", "main"})

        self.assertEqual(
            [item.title for item in inv.items_by_kind["tip"]],
            ["feature/mine", "feature/local, origin/feature/local", "detached HEAD in " + WORKTREE, "origin/feature/worked"],
        )
        self.assertEqual(inv.items_by_kind["dirty"], [dirty])

    def test_mine_filter_without_a_user_email_matches_no_blank_author(self) -> None:
        tips = [Tip("7" * 40, ["origin/feature/blank"], "not", 1, "", "", None)]
        items = inventory.tip_items(tips, Remotes(["origin"], "origin"), Base("origin/main", "remote-head"), [])
        inv = inventory.Inventory({"tip": items}, [], [], None, {})

        associate.mine_filter(inv, "", set())

        self.assertEqual(inv.items_by_kind["tip"], [])


class QuestionSessionsTest(unittest.TestCase):
    def test_question_sessions_are_offline_recent_and_asked(self) -> None:
        now = datetime.fromisoformat("2026-10-29T12:00:00+00:00").timestamp()
        sessions = [
            _session("old", [], ended_on_question=True, last_ts="2026-09-19T12:00:00.000Z"),
            _session("recent", [], ended_on_question=True, last_ts="2026-10-20T12:00:00.000Z"),
            _session("earlier", [], ended_on_question=True, last_ts="2026-10-10T12:00:00.000Z"),
            _session("live", [], ended_on_question=True, live="live", last_ts="2026-10-28T12:00:00.000Z"),
            _session("possibly", [], ended_on_question=True, live="possibly live", last_ts="2026-10-28T12:00:00.000Z"),
            _session("answered", [], ended_on_question=False, last_ts="2026-10-28T12:00:00.000Z"),
            _session("no-turns", [], ended_on_question=True, user_turns=0, last_ts="2026-10-28T12:00:00.000Z"),
            _session("no-stamp", [], ended_on_question=True, last_ts=""),
        ]

        found = associate.question_sessions(sessions, 30, now)

        self.assertEqual([session.id for session in found], ["earlier", "recent"])
        self.assertEqual([session.id for session in associate.question_sessions(sessions, 50, now)], ["old", "earlier", "recent"])


if __name__ == "__main__":
    unittest.main()
