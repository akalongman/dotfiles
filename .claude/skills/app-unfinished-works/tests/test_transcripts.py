"""Tests for scripts/unfinishedlib/transcripts.py: candidate folders, the
active chain, user-record classes, whole-name matching and evidence.

Every case writes its own transcripts under a temporary directory through
tests/transcript_fixture.py. Checkout paths are fixed strings that no case
reads from disk, so no case reads this machine's slots, transcripts or
projects.
"""

import json
import os
import tempfile
import unittest
from typing import Any

from scripts.unfinishedlib import model, transcripts
from tests import transcript_fixture as tf
from tests.transcript_fixture import assistant, bridge, system, tool_result, user

MAIN = tf.MAIN
NAMES = ["feature/x", "my-change"]
PATHS = ["openspec/changes/my-change"]
SKILL_INVOCATION = "<command-message>app-unfinished-works</command-message>\n<command-name>/app-unfinished-works</command-name>"


class TranscriptsTest(unittest.TestCase):
    def setUp(self) -> None:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        self.tmp = os.path.realpath(holder.name)
        self.folder = os.path.join(self.tmp, "projects", transcripts.encode_path(MAIN))
        self.matcher = transcripts.NameMatcher(NAMES, PATHS)
        self.written = 0

    # Fixtures.

    def _write(self, records: list[dict[str, Any] | str]) -> str:
        """Write records to a fresh transcript in the candidate folder; return its path."""
        self.written += 1
        return tf.write_transcript(self.folder, "session-" + str(self.written), records)

    def _parse(
        self,
        records: list[dict[str, Any] | str],
        *,
        checkouts: list[str] | None = None,
        accounts: dict[str, str] | None = None,
        run: model.Run | None = None,
    ) -> model.Session | None:
        path = self._write(records)
        return transcripts.parse_transcript(
            path,
            self.matcher,
            [MAIN] if checkouts is None else checkouts,
            MAIN,
            {} if accounts is None else accounts,
            model.Run() if run is None else run,
        )

    def _session(self, records: list[dict[str, Any] | str], **kw: Any) -> model.Session:
        session = self._parse(records, **kw)
        assert session is not None
        return session

    def _tool_session(
        self, name: str, tool_input: dict[str, Any], ok: bool = True, **kw: Any
    ) -> tuple[model.Session, list[dict[str, Any] | str]]:
        """A session that asks, makes one tool call, and gets its result."""
        records: list[dict[str, Any] | str] = [
            user("go", **kw),
            assistant(tool_use={"id": "t1", "name": name, "input": tool_input}, **kw),
            tool_result("t1", ok, **kw),
        ]
        return self._session(records), records

    def _evidence(self, session: model.Session) -> list[tuple[str, str]]:
        return [(item.cls, item.token) for item in session.evidence]

    # Paths and candidate folders.

    def test_encode_path(self) -> None:
        self.assertEqual(transcripts.encode_path("/home/u/p/.worktrees/feature-x"), "-home-u-p--worktrees-feature-x")
        self.assertEqual(transcripts.encode_path("/a_b.c/d-e"), "-a-b-c-d-e")

    def test_candidate_folders_include_checkouts_and_exclude_siblings(self) -> None:
        root = os.path.join(self.tmp, "slot1", "projects")
        for name in ("-home-u-p", "-home-u-p--worktrees-a", "-home-u-p-frontend", "-tmp-wt"):
            os.makedirs(os.path.join(root, name))
        # A file is never a candidate, whatever its name.
        with open(os.path.join(root, "-home-u-p--notes"), "w", encoding="utf-8") as handle:
            handle.write("not a folder\n")
        # A second slot whose projects is a link to the first, and a slot without one.
        linked = os.path.join(self.tmp, "slot2-projects")
        os.symlink(root, linked)
        missing = os.path.join(self.tmp, "slot3", "projects")
        checkouts = [
            model.Checkout(MAIN, "main", "1" * 40, True, True),
            model.Checkout("/tmp/wt", "topic", "2" * 40, False, True),
        ]

        found = transcripts.candidate_folders([root, linked, missing], MAIN, checkouts)

        self.assertEqual(found, [os.path.join(root, name) for name in ("-home-u-p", "-home-u-p--worktrees-a", "-tmp-wt")])

    def test_find_path_strips_checkout_roots(self) -> None:
        matcher = transcripts.NameMatcher([], ["openspec/changes/my-change", "src/app.py"])
        worktree = MAIN + "/.worktrees/a"

        # A gone worktree under the main checkout still maps.
        self.assertEqual(matcher.find_path(MAIN + "/.worktrees/gone/src/app.py", [MAIN]), "src/app.py")
        # The longest present root wins over the main checkout.
        self.assertEqual(
            matcher.find_path(worktree + "/openspec/changes/my-change/tasks.md", [MAIN, worktree]),
            "openspec/changes/my-change",
        )
        self.assertEqual(matcher.find_path("/tmp/wt/src/app.py", [MAIN, "/tmp/wt"]), "src/app.py")
        # Whole path segments only, and nothing outside every root.
        self.assertIsNone(matcher.find_path(MAIN + "/src/app.pyc", [MAIN]))
        self.assertIsNone(matcher.find_path(MAIN + "-frontend/src/app.py", [MAIN]))
        self.assertIsNone(matcher.find_path("src/app.py", [MAIN]))

    # Membership and the headless filter.

    def test_membership_by_cwd_not_folder_name(self) -> None:
        self.assertIsNone(self._parse([user("go", cwd="/elsewhere"), assistant("ok", cwd="/elsewhere")]))
        # A sibling project whose path only shares the prefix is not a member.
        self.assertIsNone(self._parse([user("go", cwd=MAIN + "-frontend"), assistant("ok", cwd=MAIN + "-frontend")]))

        gone = MAIN + "/.worktrees/gone/src"
        records: list[dict[str, Any] | str] = [user("go", cwd=gone), assistant("ok", cwd=gone)]
        session = self._session(records)

        self.assertIn(gone, session.cwds)
        self.assertEqual(session.cwds, {gone: "main"})
        self.assertEqual(session.cwd_counts, {gone: 2})
        # Under <main>/.worktrees/ is enough even when no checkout holds the cwd.
        self.assertIsNotNone(self._parse(records, checkouts=[]))

    def test_headless_sdk_py_is_skipped(self) -> None:
        self.assertIsNone(self._parse([user("go", entrypoint="sdk-py"), assistant("ok")]))

        # A missing entrypoint is unknown and kept.
        first = user("go")
        del first["entrypoint"]
        session = self._session([first, assistant("ok")])
        self.assertIsNone(session.entrypoint)

    # User records.

    def test_classify_user_variants(self) -> None:
        clear = user("<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>")
        self.assertNotIn("isMeta", clear)
        self.assertEqual(transcripts.classify_user(clear), "local")
        self.assertEqual(transcripts.classify_user(user("<local-command-stdout></local-command-stdout>")), "local")
        self.assertEqual(transcripts.classify_user(tool_result("t1")), "tool_result")
        self.assertEqual(transcripts.classify_user(user("Fix the login bug")), "request")
        self.assertEqual(
            transcripts.classify_user(user(["<system-reminder>Today is Thursday.</system-reminder>", "Fix the login bug"])),
            "request",
        )
        self.assertEqual(transcripts.classify_user(user(["<system-reminder>Today is Thursday.</system-reminder>"])), "local")
        self.assertEqual(transcripts.classify_user(user("Caveat: the messages below", isMeta=True)), "meta")
        # A skill invocation leads with <command-message>, which is no harness tag.
        self.assertEqual(transcripts.classify_user(user(SKILL_INVOCATION)), "request")

    def test_compaction_summary_is_not_a_request(self) -> None:
        summary = user(
            "This session is being continued from a previous conversation. my-change was in progress.",
            isCompactSummary=True,
            isVisibleInTranscriptOnly=True,
        )
        self.assertEqual(transcripts.classify_user(summary), "meta")

        before = assistant("Planned")
        boundary = system(subtype="compact_boundary", parentUuid=None, logicalParentUuid=before["uuid"])
        session = self._session([user("go"), before, boundary, summary, assistant("Resumed")])

        self.assertEqual(session.user_turns, 1)
        self.assertEqual(session.last_request, "go")
        self.assertEqual(self._evidence(session), [])

    # The active chain.

    def test_malformed_line_keeps_the_chain(self) -> None:
        records: list[dict[str, Any] | str] = [
            user("go"),
            assistant("Working on feature/x"),
            '{"type": "user", "uuid": "ghost-uuid", "parentUuid": ',
            # Its parent exists only on the malformed line.
            user("next", parentUuid="ghost-uuid"),
            assistant("Then my-change"),
        ]
        run = model.Run()

        session = self._session(records, run=run)

        self.assertEqual(session.user_turns, 2)
        self.assertEqual(self._evidence(session), [("mention", "feature/x"), ("mention", "my-change")])
        first = records[0]
        assert isinstance(first, dict)
        self.assertEqual(session.first_ts, first["timestamp"])
        self.assertEqual(run.errors, [os.path.join(self.folder, "session-1.jsonl") + ":3: not JSON"])
        self.assertIs(run.complete, False)

    def test_json_line_that_is_not_an_object_is_recorded(self) -> None:
        run = model.Run()

        session = self._session([user("go"), "[1, 2]", assistant("ok")], run=run)

        self.assertEqual(session.last_assistant, "ok")
        self.assertEqual(run.errors, [os.path.join(self.folder, "session-1.jsonl") + ":2: not a JSON object"])

    def test_unreadable_transcript_is_recorded(self) -> None:
        missing = os.path.join(self.tmp, "gone.jsonl")
        run = model.Run()

        self.assertIsNone(transcripts.parse_transcript(missing, self.matcher, [MAIN], MAIN, {}, run))
        self.assertEqual(run.errors, ["read " + missing + ": No such file or directory"])
        self.assertIs(run.complete, False)

    def test_system_records_do_not_break_the_chain(self) -> None:
        session = self._session([user("one"), system(), assistant("a"), user("two"), assistant("b")])

        self.assertEqual(session.user_turns, 2)
        self.assertEqual(session.last_request, "two")

    def test_compaction_boundary_keeps_earlier_history(self) -> None:
        first = user("Start my-change")
        before = assistant("Planned")
        boundary = system(subtype="compact_boundary", parentUuid=None, logicalParentUuid=before["uuid"])

        session = self._session([first, before, boundary, user("Continue"), assistant("Done")])

        self.assertEqual(session.user_turns, 2)
        self.assertEqual(session.first_ts, first["timestamp"])
        self.assertIn(("request", "my-change"), self._evidence(session))

    def test_active_chain_ignores_abandoned_fork(self) -> None:
        root = user("go")
        abandoned = assistant("Abandoned plan for feature/x")
        kept = assistant("Kept plan", parentUuid=root["uuid"])

        session = self._session([root, abandoned, kept, user("continue")])

        self.assertEqual(session.last_assistant, "Kept plan")
        self.assertNotIn("Abandoned", session.last_assistant)
        self.assertEqual(self._evidence(session), [])
        self.assertEqual(session.user_turns, 2)

    def test_last_record_with_a_uuid_starts_the_chain(self) -> None:
        # The bridge record comes last and has no uuid.
        session = self._session([user("go"), assistant("ok"), bridge("acc-1")])

        self.assertEqual(session.last_assistant, "ok")
        self.assertEqual(session.user_turns, 1)

    def test_parallel_tool_calls_off_the_walked_chain_still_count(self) -> None:
        # As the CLI writes parallel calls: each block of one API message is
        # its own record, and the walk from the last record passes through
        # only one of them; the other and its result hang off the side.
        looked = assistant(tool_use={"id": "t1", "name": "Bash", "input": {"command": "git log feature/x"}}, message_id="msg-1")
        pushed = assistant(tool_use={"id": "t2", "name": "Bash", "input": {"command": "git push origin feature/x"}}, message_id="msg-1")
        first_result = tool_result("t1", parentUuid=looked["uuid"])
        second_result = tool_result("t2", parentUuid=pushed["uuid"])
        done = assistant("Pushed", parentUuid=first_result["uuid"])

        session = self._session([user("go"), looked, pushed, first_result, second_result, done])

        self.assertEqual(self._evidence(session), [("lookup", "feature/x"), ("work", "feature/x")])
        self.assertEqual(session.evidence[1].ts, pushed["timestamp"])

    # Evidence.

    def test_evidence_classes(self) -> None:
        work, records = self._tool_session("Bash", {"command": "git switch feature/x", "description": "Switch branches"})
        self.assertEqual(self._evidence(work), [("work", "feature/x")])
        call = records[1]
        assert isinstance(call, dict)
        self.assertEqual(work.evidence[0].ts, call["timestamp"])

        failed, _ = self._tool_session("Bash", {"command": "git switch feature/x"}, ok=False)
        self.assertEqual(failed.evidence, [])
        unanswered = self._session(
            [user("go"), assistant(tool_use={"id": "t1", "name": "Bash", "input": {"command": "git switch feature/x"}})]
        )
        self.assertEqual(unanswered.evidence, [])

        asked = self._session([user("Please finish my-change"), assistant("On it")])
        self.assertEqual(self._evidence(asked), [("request", "my-change")])
        mentioned = self._session([user("go"), assistant("my-change has two open tasks")])
        self.assertEqual(self._evidence(mentioned), [("mention", "my-change")])

    def test_read_only_commands_are_lookups(self) -> None:
        for command, expected in (
            ("grep -rn feature/x .", [("lookup", "feature/x")]),
            ("git log origin/feature/x 2>/dev/null", [("lookup", "feature/x")]),
            ("git log origin/feature/x > /dev/null", [("lookup", "feature/x")]),
            ("git branch -a", []),
            ("git stash list", []),
        ):
            with self.subTest(command=command):
                session, _ = self._tool_session("Bash", {"command": command})
                self.assertEqual(self._evidence(session), expected)

        grep, _ = self._tool_session("Grep", {"pattern": "feature/x", "path": MAIN, "output_mode": "content"})
        self.assertEqual(self._evidence(grep), [("lookup", "feature/x")])

        for command in ("git commit -m 'feature/x done'", "echo feature/x > notes.md"):
            with self.subTest(command=command):
                session, _ = self._tool_session("Bash", {"command": command})
                self.assertEqual(self._evidence(session), [("work", "feature/x")])

        edit, _ = self._tool_session(
            "Edit",
            {"file_path": MAIN + "/openspec/changes/my-change/tasks.md", "old_string": "- [ ] a", "new_string": "- [x] a"},
        )
        self.assertEqual(self._evidence(edit), [("work", "openspec/changes/my-change")])

    def test_relative_edit_path_joins_the_record_cwd(self) -> None:
        session, _ = self._tool_session(
            "Write", {"file_path": "changes/my-change/proposal.md", "content": "# proposal\n"}, cwd=MAIN + "/openspec"
        )

        self.assertEqual(self._evidence(session), [("work", "openspec/changes/my-change")])

    def test_tool_result_content_is_not_searched(self) -> None:
        records: list[dict[str, Any] | str] = [
            user("go"),
            assistant(tool_use={"id": "t1", "name": "Bash", "input": {"command": "ls"}}),
            tool_result("t1", content="feature/x\nopenspec/changes/my-change/tasks.md\n"),
        ]

        self.assertEqual(self._session(records).evidence, [])

    # Commands.

    def test_strip_fd_redirects(self) -> None:
        self.assertEqual(transcripts.strip_fd_redirects("git log x 2>/dev/null </dev/null >&2").split(), ["git", "log", "x"])
        self.assertEqual(transcripts.strip_fd_redirects("a 2>&1 | b 1>&2 >/dev/null").split(), ["a", "|", "b"])
        self.assertEqual(transcripts.strip_fd_redirects("$(a 2>/dev/null)"), "$(a )")
        # Only whole tokens: a redirect glued to a word stays.
        self.assertEqual(transcripts.strip_fd_redirects("a2>/dev/null"), "a2>/dev/null")

    def test_is_state_changing(self) -> None:
        for command, expected in (
            ("git commit -m 'done'", True),
            ("git -C /p push origin feature/x", True),
            ("gh pr merge 12", True),
            ("rm -rf openspec/changes/x", True),
            ("tee notes.md", True),
            ("openspec list", True),
            ("git log feature/x > out.txt", True),
            ("echo a>>b", True),
            ("cat <<'EOF' > notes.md\nit's feature/x\nEOF", True),
            ("git log feature/x > /dev/null", False),
            ("git log feature/x 2> /dev/null", False),
            ("git log feature/x >/dev/null 2>&1", False),
            ("git log feature/x 3>&1", False),
            ("grep -rn 'git push' .", False),
            ("echo 'a > b'", False),
            ("git status --short", False),
            ("git -C /p branch -D feature/x", True),
            ("git branch feature/y", True),
            ("git branch -dr origin/feature/x", True),
            ("git branch", False),
            ("git branch --show-current", False),
            ("git branch -vv", False),
            ("git branch --list 'feature/*'", False),
            ("git branch -r --contains=abc1234", False),
            ("git branch -a | grep -c x", False),
            # A newline ends a command: the -a of the second line is not the first one's.
            ("git branch -D feature/x\ngit branch -a", True),
            ("git stash", True),
            ("git stash pop", True),
            ("git stash show -p", False),
            ("git worktree list --porcelain", False),
            ("git worktree remove .worktrees/x", True),
            ("sed -i 's/a/b/' f", True),
            ("sed -i.bak 's/a/b/' f", True),
            ("sed -n 1p f | grep -i x", False),
            ("sed -n 1p f\ngrep -i x f", False),
        ):
            with self.subTest(command=command):
                self.assertIs(transcripts.is_state_changing(command), expected)

    def test_whole_name_matching(self) -> None:
        matcher = transcripts.NameMatcher(["dev", "dev-2", "fix/a.b", "feature/x", "my-change"], [])

        for text, expected in (
            ("on dev-2 now", ["dev-2"]),
            ("fix/aXb", []),
            ("see fix/a.b.", ["fix/a.b"]),
            ("git log origin/feature/x", ["feature/x"]),
            ("openspec/changes/my-change/tasks.md", ["my-change"]),
            ("2>/dev/null", []),
            ("dev.local", []),
            ("push origin dev", ["dev"]),
            ("devops and my-changes and dev_x", []),
            ("dev, then dev again", ["dev"]),
        ):
            with self.subTest(text=text):
                self.assertEqual(matcher.find(text), expected)

    # Session fields.

    def test_session_fields(self) -> None:
        worktree = MAIN + "/.worktrees/a"
        records: list[dict[str, Any] | str] = [
            user("Start"),
            assistant("Looking"),
            user("Now the worktree", cwd=worktree, gitBranch="feature/x"),
            assistant("Done there", cwd=worktree, gitBranch="feature/x"),
        ]
        path = self._write(records)

        session = transcripts.parse_transcript(path, self.matcher, [MAIN], MAIN, {}, model.Run())

        assert session is not None
        last = records[3]
        assert isinstance(last, dict)
        self.assertEqual(session.id, "session-1")
        self.assertEqual(session.path, path)
        self.assertEqual(session.mtime, os.stat(path).st_mtime)
        self.assertEqual((session.first_ts, session.last_ts), (tf.timestamp(0), last["timestamp"]))
        self.assertEqual(session.cwds, {MAIN: "main", worktree: "feature/x"})
        self.assertEqual(session.cwd_counts, {MAIN: 2, worktree: 2})
        self.assertEqual((session.user_turns, session.last_request, session.last_assistant), (2, "Now the worktree", "Done there"))
        self.assertEqual((session.entrypoint, session.account_uuid, session.slot, session.live), ("cli", None, "unknown", None))
        self.assertIs(session.ended_on_question, False)
        self.assertIs(session.ran_skill, False)

    def test_timestamps_compare_as_instants(self) -> None:
        # As strings "...05.500Z" sorts before "...05Z"; as instants it is later.
        session = self._session(
            [user("go", timestamp="2026-10-01T10:00:05Z"), assistant("ok", timestamp="2026-10-01T10:00:05.500Z")]
        )

        self.assertEqual((session.first_ts, session.last_ts), ("2026-10-01T10:00:05Z", "2026-10-01T10:00:05.500Z"))

    def test_ended_on_question(self) -> None:
        self.assertIs(self._session([user("go"), assistant("Shall I merge?  \n")]).ended_on_question, True)
        self.assertIs(self._session([user("go"), assistant("Shall I merge?"), user("yes")]).ended_on_question, False)
        self.assertIs(self._session([user("go"), assistant("Merged.")]).ended_on_question, False)
        ask = assistant(tool_use={"id": "q1", "name": "AskUserQuestion", "input": {"questions": []}})
        self.assertIs(self._session([user("go"), ask]).ended_on_question, True)
        # A local command after the question is no answer.
        local = user("<local-command-stdout></local-command-stdout>")
        self.assertIs(self._session([user("go"), assistant("Shall I merge?"), local]).ended_on_question, True)
        # The question is the last text of the last message, split over records.
        split = [
            user("go"),
            assistant("Shall I merge?", message_id="msg-q"),
            assistant(tool_use={"id": "t1", "name": "Bash", "input": {"command": "ls"}}, message_id="msg-q"),
        ]
        self.assertIs(self._session(split).ended_on_question, True)

    def test_bridge_account_maps_to_slot(self) -> None:
        mapped = self._session([user("go"), assistant("ok"), bridge("acc-2")], accounts={"acc-2": "2"})
        self.assertEqual((mapped.account_uuid, mapped.slot), ("acc-2", "2"))

        without = self._session([user("go"), assistant("ok")], accounts={"acc-2": "2"})
        self.assertEqual((without.account_uuid, without.slot), (None, "unknown"))

        unmapped = self._session([bridge("acc-9"), user("go"), assistant("ok")], accounts={"acc-2": "2"})
        self.assertEqual((unmapped.account_uuid, unmapped.slot), ("acc-9", "unknown"))

    def test_slot_accounts_reads_each_slot_state_file(self) -> None:
        home = os.path.join(self.tmp, "home")
        slots = [os.path.join(home, name) for name in (".claude", ".claude2", ".claude3", ".claude4")]
        for slot in slots:
            os.makedirs(slot)
        # The default slot keeps its state beside the directory, in the home.
        with open(os.path.join(home, ".claude.json"), "w", encoding="utf-8") as handle:
            json.dump({"oauthAccount": {"accountUuid": "acc-1"}}, handle)
        with open(os.path.join(slots[1], ".claude.json"), "w", encoding="utf-8") as handle:
            json.dump({"oauthAccount": {"accountUuid": "acc-2"}}, handle)
        with open(os.path.join(slots[2], ".claude.json"), "w", encoding="utf-8") as handle:
            handle.write("{not json")
        # .claude4 has no state file at all.

        self.assertEqual(transcripts.slot_accounts(slots), {"acc-1": "1", "acc-2": "2"})

    def test_ran_skill_flag(self) -> None:
        ran, _ = self._tool_session(
            "Bash", {"command": "python3 -I ~/.claude/skills/app-unfinished-works/scripts/unfinished.py --json"}
        )
        self.assertIs(ran.ran_skill, True)
        invoked = self._session([user(SKILL_INVOCATION), assistant("Report follows")])
        self.assertIs(invoked.ran_skill, True)
        plain = self._session([user("go"), assistant("ok")])
        self.assertIs(plain.ran_skill, False)
