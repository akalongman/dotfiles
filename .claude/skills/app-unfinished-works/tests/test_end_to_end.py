"""End-to-end tests of cli.main over a fixture repository, and the inventory's
own rules (removed worktrees, the parked-note count).

Every case builds its repositories with tests/repo_fixture.py, its
transcripts with tests/transcript_fixture.py under a temporary home, and a
temporary /proc tree with tests/proc_fixture.py, and passes them in; a
runner answers claude-sessions with exit 127 and hands every other command
to the default runner, except that the forge case answers its glab call
itself and refuses any other glab or gh call. No case reads this machine's
slots, transcripts, registry or /proc, runs a forge CLI or reaches the
network.
"""

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from datetime import datetime
from typing import Any
from unittest import mock

from scripts.unfinishedlib import cli, inventory, live, model, transcripts
from tests import proc_fixture, repo_fixture
from tests import transcript_fixture as tf

# Two days after the transcript fixture's first timestamp, so the question
# window holds its sessions whatever the date of the run.
NOW = datetime.fromisoformat("2026-10-03T10:00:00+00:00").timestamp()


class EndToEndTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="unfinished-e2e-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.calls: list[list[str]] = []
        # One flag per git command after the environment query: whether a
        # repository variable was still set when it ran. Only booleans are
        # kept, so a failing case never prints the environment.
        self.inherited: list[bool] = []

    # Fixture builders.

    def _runner(self) -> model.Runner:
        def run(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            if argv and argv[0] == "claude-sessions":
                self.calls.append(argv)
                return 127, "", "claude-sessions: command not found"
            if argv[:1] == ["git"] and argv != ["git", "rev-parse", "--local-env-vars"]:
                self.inherited.append("GIT_DIR" in os.environ or "GIT_WORK_TREE" in os.environ)
            return model.default_runner(argv, cwd)

        return run

    def _home(self, name: str = "home") -> str:
        """A home whose .claude holds only projects/ (R13): no state file, no registry."""
        home = os.path.join(self.tmp, name)
        os.makedirs(os.path.join(home, ".claude", "projects"))
        return home

    def _proc(self) -> str:
        """A /proc tree with one process that is not claude."""
        proc = os.path.join(self.tmp, "proc")
        os.makedirs(proc)
        proc_fixture.make_proc(proc, 4242, "bash", "/", None, 100)
        return proc

    def _folder(self, home: str, cwd: str) -> str:
        return os.path.join(home, ".claude", "projects", transcripts.encode_path(cwd))

    def _repository(self, base: str) -> dict[str, str]:
        """make_repo plus a stash, an untracked change bar, and feature/x checked out in a worktree.

        The worktree sits outside the main checkout, so the main checkout's
        status names the change and nothing of the worktree.
        """
        os.makedirs(base)
        repo = repo_fixture.make_repo(base)
        work = repo["work"]
        with open(os.path.join(work, "README.md"), "a", encoding="utf-8") as handle:
            handle.write("more\n")
        repo_fixture.git(work, "stash", "push", "-q", "-m", "wip readme")
        change = os.path.join(work, "openspec", "changes", "bar")
        os.makedirs(change)
        with open(os.path.join(change, "tasks.md"), "w", encoding="utf-8") as handle:
            handle.write("- [x] one\n- [ ] two\n")
        worktree = os.path.join(base, "wt-x")
        repo_fixture.git(work, "worktree", "add", "-q", "-b", "feature/x", worktree)
        repo_fixture.commit(worktree, "x.txt", "x\n", "Add x")
        repo["worktree"] = worktree
        return repo

    def _transcripts(self, home: str, work: str) -> None:
        """One interactive session that switched to feature/x, and one headless run naming it too."""
        folder = self._folder(home, work)
        switch = {"name": "Bash", "input": {"command": "git switch feature/x"}, "id": "toolu_switch"}
        tf.write_transcript(
            folder,
            "11111111-1111-4111-8111-111111111111",
            [
                tf.user("switch to the feature branch", cwd=work),
                tf.assistant("Switching.", tool_use=switch, cwd=work),
                tf.tool_result("toolu_switch", cwd=work),
                tf.assistant("Done. Shall I merge feature/x into main?", cwd=work),
            ],
        )
        headless = {"name": "Bash", "input": {"command": "git switch feature/x"}, "id": "toolu_headless"}
        tf.write_transcript(
            folder,
            "22222222-2222-4222-8222-222222222222",
            [
                tf.user("headless run on feature/x", cwd=work, entrypoint="sdk-py"),
                tf.assistant("On it.", tool_use=headless, cwd=work, entrypoint="sdk-py"),
                tf.tool_result("toolu_headless", cwd=work, entrypoint="sdk-py"),
            ],
        )

    def _main(
        self, home: str, *args: str, now: float = NOW, runner: model.Runner | None = None
    ) -> tuple[int, dict[str, Any]]:
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"UNFINISHED_HOME": home}), contextlib.redirect_stdout(out):
            code = cli.main(["--json", *args], proc_root=self._proc_root, runner=runner or self._runner(), now=now)
        return code, json.loads(out.getvalue())

    def _gone_worktrees(self) -> tuple[str, str, str]:
        """make_repo plus two registered worktrees whose directories were deleted: (work, outside, inside).

        outside sits beside the main checkout on feature/outside, inside under
        <work>/.worktrees/ on feature/inside; each branch holds one commit
        main lacks, and git lists both worktrees as prunable.
        """
        base = os.path.join(self.tmp, "gone")
        os.makedirs(base)
        work = repo_fixture.make_repo(base)["work"]
        outside = os.path.join(base, "wt-outside")
        inside = os.path.join(work, ".worktrees", "inside")
        for path, branch in ((outside, "feature/outside"), (inside, "feature/inside")):
            repo_fixture.git(work, "worktree", "add", "-q", "-b", branch, path)
            repo_fixture.commit(path, os.path.basename(path) + ".txt", "x\n", "Add " + branch)
            shutil.rmtree(path)
        return work, outside, inside

    def _scenario(self) -> tuple[dict[str, str], str]:
        repo = self._repository(os.path.join(self.tmp, "repo"))
        home = self._home()
        self._transcripts(home, repo["work"])
        self._proc_root = self._proc()
        return repo, home

    @staticmethod
    def _by_name(items: list[dict[str, Any]], name: str) -> list[dict[str, Any]]:
        return [item for item in items if name in item["names"]]

    # The cases.

    def test_end_to_end_on_fixture_repo(self) -> None:
        repo, home = self._scenario()

        code, data = self._main(home, "--root", repo["work"])

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertEqual([item["title"] for item in data["openspec_pending"]], ["bar"])
        tips = self._by_name(data["tips"], "feature/x")
        self.assertEqual(len(tips), 1)
        self.assertEqual(tips[0]["attrs"]["worktree"], repo["worktree"])
        self.assertEqual(len(tips[0]["sessions"]), 1)
        association = tips[0]["sessions"][0]
        self.assertEqual(association["evidence"], "work")
        self.assertEqual(association["session_id"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(association["checkout"], repo["work"])
        self.assertEqual(len(data["stashes"]), 1)
        self.assertEqual(data["stashes"][0]["paths"], ["README.md"])
        self.assertEqual([item["attrs"]["checkout"] for item in data["dirty"]], [repo["work"]])
        self.assertIn("openspec/changes/bar/tasks.md", data["dirty"][0]["paths"])
        self.assertEqual(data["live_sessions"], [])
        self.assertEqual([session["id"] for session in data["questions"]], ["11111111-1111-4111-8111-111111111111"])
        meta = data["meta"]
        self.assertIs(meta["complete"], True)
        self.assertEqual(meta["errors"], [])
        self.assertIn(inventory.OUT_OF_REACH_NOTE, meta["notes"])
        self.assertTrue(any(note.startswith("claude-sessions") and "registry read directly" in note for note in meta["notes"]))
        self.assertEqual(self.calls, [["claude-sessions", "--json", "--all"]])
        self.assertEqual((meta["remote"], meta["base"], meta["base_source"]), ("origin", "origin/main", "remote-head"))
        self.assertEqual(meta["question_window_days"], 30)
        self.assertEqual(meta["transcripts"]["count"], 2)
        self.assertGreater(meta["transcripts"]["bytes"], 0)
        self.assertEqual(meta["transcripts"]["oldest"], tf.timestamp(0))
        self.assertEqual(meta["transcripts"]["newest"], tf.timestamp(3))
        self.assertIsNone(data["parked"])

    def test_end_to_end_text_report(self) -> None:
        repo, home = self._scenario()
        out = io.StringIO()

        with mock.patch.dict(os.environ, {"UNFINISHED_HOME": home}), contextlib.redirect_stdout(out):
            code = cli.main(["--root", repo["work"]], proc_root=self._proc_root, runner=self._runner(), now=NOW)

        text = out.getvalue()
        self.assertEqual(code, 0)
        self.assertTrue(text.startswith("Unfinished work report for " + repo["work"] + "\n"))
        self.assertIn("tip (certain): feature/x\n", text)
        self.assertIn("11111111-1111-4111-8111-111111111111  unknown slot  work  ", text)
        self.assertIn("\n  " + repo["work"] + "/README.md\n", text)
        self.assertIn("claude-sessions: not found; registry read directly", text)

    def test_no_questions_turns_the_window_off(self) -> None:
        repo, home = self._scenario()

        code, data = self._main(home, "--root", repo["work"], "--no-questions")

        self.assertEqual(code, 0)
        self.assertEqual(data["questions"], [])
        self.assertIsNone(data["meta"]["question_window_days"])

    def test_end_to_end_incomplete_on_error(self) -> None:
        repo, home = self._scenario()
        folder = self._folder(home, repo["work"])
        with open(os.path.join(folder, "broken.jsonl"), "w", encoding="utf-8") as handle:
            handle.write("{not json\n")

        code, data = self._main(home, "--root", repo["work"])

        self.assertEqual(code, 1)
        self.assertIs(data["meta"]["complete"], False)
        self.assertEqual(data["meta"]["errors"], [os.path.join(folder, "broken.jsonl") + ":1: not JSON"])
        self.assertEqual([item["title"] for item in data["openspec_pending"]], ["bar"])
        self.assertEqual(len(self._by_name(data["tips"], "feature/x")[0]["sessions"]), 1)
        self.assertEqual(len(data["stashes"]), 1)
        self.assertEqual(data["meta"]["transcripts"]["count"], 3)

    def test_mr_attaches_to_tip_by_sha_else_standalone(self) -> None:
        repo, home = self._scenario()
        work = repo["work"]
        # Pointed at gitlab.com after the fixture is built: the remote-tracking refs stay, nothing fetches.
        repo_fixture.git(work, "remote", "set-url", "origin", "git@gitlab.com:g/sub/r.git")
        tip_sha = repo_fixture.git(work, "rev-parse", "feature/x").strip()
        rows = [
            {
                "iid": 8,
                "title": "Fork  change",
                "draft": True,
                "source_project_id": 99,
                "source_branch": "fork/y",
                "sha": "f" * 40,
                "target_branch": "main",
                "author": {"username": "someone"},
                "web_url": "https://gitlab.com/g/sub/r/-/merge_requests/8",
            },
            {
                "iid": 7,
                "title": "Add x",
                "draft": False,
                "source_project_id": 42,
                "source_branch": "feature/x",
                "sha": tip_sha,
                "target_branch": "main",
                "author": {"username": "owner"},
                "web_url": "https://gitlab.com/g/sub/r/-/merge_requests/7",
            },
        ]
        page = ["glab", "api", "--hostname", "gitlab.com", "projects/g%2Fsub%2Fr/merge_requests?state=opened&per_page=100&page=1"]
        forge_calls: list[list[str]] = []
        plain = self._runner()

        def answering(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            if argv[:1] in (["glab"], ["gh"]):
                # Never handed to the default runner: an unanswered forge call is refused.
                forge_calls.append(list(argv))
                return (0, json.dumps(rows), "") if argv == page else (127, "", argv[0] + ": refused by the test runner")
            return plain(argv, cwd)

        code, data = self._main(home, "--root", work, "--forge", runner=answering)

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertEqual(forge_calls, [page])
        tips = self._by_name(data["tips"], "feature/x")
        self.assertEqual(len(tips), 1)
        self.assertEqual(tips[0]["sha"], tip_sha)
        self.assertIn("MR !7 open Add x -> main", tips[0]["lines"])
        self.assertEqual(len(data["merge_requests"]), 1)
        request = data["merge_requests"][0]
        self.assertEqual(
            (request["kind"], request["title"], request["certainty"], request["names"], request["date"], request["sha"]),
            ("merge-request", "!8 Fork change", "certain", ["fork/y"], None, "f" * 40),
        )
        self.assertEqual(
            request["lines"],
            ["draft, 99:fork/y -> main", "head " + "f" * 40, "https://gitlab.com/g/sub/r/-/merge_requests/8"],
        )
        self.assertEqual(request["attrs"], {"number": "8", "source_project": "99", "author": "someone"})
        self.assertFalse(any("MR !8" in line for tip in data["tips"] for line in tip["lines"]))

    def test_inherited_git_dir_is_ignored(self) -> None:
        repo, home = self._scenario()
        other_base = os.path.join(self.tmp, "other-base")
        os.makedirs(other_base)
        other = repo_fixture.make_repo(other_base)
        repo_fixture.git(other["work"], "switch", "-q", "-c", "other/y")
        repo_fixture.commit(other["work"], "y.txt", "y\n", "Add y")
        os.makedirs(os.path.join(other["work"], "openspec", "changes", "elsewhere"))
        git_dir = os.path.join(other["work"], ".git")

        with mock.patch.dict(os.environ, {"GIT_DIR": git_dir, "GIT_WORK_TREE": other["work"]}):
            code, data = self._main(home, "--root", repo["work"])

        self.assertTrue(self.inherited)
        self.assertFalse(any(self.inherited), "a git command ran with GIT_DIR or GIT_WORK_TREE set")
        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertEqual(len(self._by_name(data["tips"], "feature/x")), 1)
        self.assertEqual(self._by_name(data["tips"], "other/y"), [])
        self.assertEqual([item["title"] for item in data["openspec_pending"]], ["bar"])

    def test_divergence_is_shown_and_a_failing_count_recorded(self) -> None:
        base = os.path.join(self.tmp, "diverged")
        os.makedirs(base)
        work = repo_fixture.make_repo(base)["work"]
        # Local staging one commit ahead of and one behind origin/staging.
        repo_fixture.git(work, "branch", "staging")
        repo_fixture.git(work, "push", "-q", "-u", "origin", "staging")
        repo_fixture.git(work, "switch", "-q", "-c", "elsewhere")
        repo_fixture.commit(work, "remote.txt", "remote\n", "Add the remote side")
        repo_fixture.git(work, "push", "-q", "origin", "elsewhere:staging")
        repo_fixture.git(work, "switch", "-q", "staging")
        repo_fixture.git(work, "branch", "-q", "-D", "elsewhere")
        repo_fixture.commit(work, "local.txt", "local\n", "Add the local side")
        repo_fixture.git(work, "switch", "-q", "main")
        home = self._home()
        self._proc_root = self._proc()

        code, data = self._main(home, "--root", work)

        self.assertEqual(code, 0, data["meta"]["errors"])
        lines = [line for tip in self._by_name(data["tips"], "staging") for line in tip["lines"]]
        self.assertIn("local 1 ahead, 1 behind origin/staging", lines)

        plain = self._runner()

        def failing(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            if "--left-right" in argv:
                return 128, "", "fatal: injected failure"
            return plain(argv, cwd)

        out = io.StringIO()
        with mock.patch.dict(os.environ, {"UNFINISHED_HOME": home}), contextlib.redirect_stdout(out):
            code = cli.main(["--json", "--root", work], proc_root=self._proc_root, runner=failing, now=NOW)
        data = json.loads(out.getvalue())

        self.assertEqual(code, 1)
        self.assertIs(data["meta"]["complete"], False)
        self.assertEqual(
            data["meta"]["errors"],
            ["git rev-list --left-right --count refs/heads/staging...refs/remotes/origin/staging: fatal: injected failure"],
        )

    def test_removed_worktree_with_unmerged_branch_is_an_item(self) -> None:
        self._proc_root = self._proc()
        for merged in (False, True):
            with self.subTest(merged=merged):
                base = os.path.join(self.tmp, "merged" if merged else "unmerged")
                os.makedirs(base)
                work = repo_fixture.make_repo(base)["work"]
                if merged:
                    repo_fixture.git(work, "push", "-q", "origin", "main:feature/old")
                else:
                    repo_fixture.git(work, "switch", "-q", "-c", "feature/old")
                    repo_fixture.commit(work, "old.txt", "old\n", "Add old")
                    repo_fixture.git(work, "push", "-q", "origin", "feature/old")
                    repo_fixture.git(work, "switch", "-q", "main")
                    repo_fixture.git(work, "branch", "-q", "-D", "feature/old")
                home = self._home("home-" + ("merged" if merged else "unmerged"))
                gone = os.path.join(work, ".worktrees", "old")
                tf.write_transcript(
                    self._folder(home, gone),
                    "33333333-3333-4333-8333-333333333333",
                    [
                        tf.user("carry on", cwd=gone + "/src", gitBranch="feature/old"),
                        tf.assistant("Carrying on.", cwd=gone + "/src", gitBranch="feature/old"),
                    ],
                )

                code, data = self._main(home, "--root", work)

                self.assertEqual(code, 0, data["meta"]["errors"])
                removed = data["removed_worktrees"]
                if merged:
                    self.assertEqual(removed, [])
                    continue
                self.assertEqual(len(removed), 1)
                self.assertIn("feature/old", removed[0]["names"])
                self.assertEqual(removed[0]["attrs"]["worktree"], gone)
                self.assertEqual(removed[0]["certainty"], "certain")
                self.assertIn("33333333-3333-4333-8333-333333333333", "\n".join(removed[0]["lines"]))
                self.assertEqual([tip["title"] for tip in data["tips"]], ["origin/feature/old"])

    def test_removed_worktree_names_its_last_session_with_the_live_tag(self) -> None:
        self._proc_root = self._proc()
        base = os.path.join(self.tmp, "live")
        os.makedirs(base)
        work = repo_fixture.make_repo(base)["work"]
        repo_fixture.git(work, "switch", "-q", "-c", "feature/old")
        repo_fixture.commit(work, "old.txt", "old\n", "Add old")
        repo_fixture.git(work, "switch", "-q", "main")
        home = self._home()
        gone = os.path.join(work, ".worktrees", "old")
        session_id = "33333333-3333-4333-8333-333333333333"
        tf.write_transcript(
            self._folder(home, gone),
            session_id,
            [
                tf.user("carry on", cwd=gone, gitBranch="feature/old"),
                tf.assistant("Carrying on.", cwd=gone, gitBranch="feature/old"),
            ],
        )
        # claude-sessions names the session as running elsewhere, so it is live.
        row = {"pid": 4343, "cwd": "/elsewhere", "sessionId": session_id, "slot": 1, "name": "old", "state": "idle"}
        plain = self._runner()

        def listing(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            if argv == live.CLAUDE_SESSIONS:
                return 0, json.dumps([row]), ""
            return plain(argv, cwd)

        code, data = self._main(home, "--root", work, runner=listing)

        self.assertEqual(code, 0, data["meta"]["errors"])
        removed = data["removed_worktrees"]
        self.assertEqual(len(removed), 1)
        named = [line for line in removed[0]["lines"] if line.startswith("last session there: " + session_id + ", ")]
        self.assertEqual(len(named), 1, removed[0]["lines"])
        self.assertTrue(named[0].endswith(", live"), named[0])

    def test_removed_worktree_skips_the_branch_a_present_checkout_holds(self) -> None:
        self._proc_root = self._proc()
        base = os.path.join(self.tmp, "held")
        os.makedirs(base)
        work = repo_fixture.make_repo(base)["work"]
        repo_fixture.git(work, "switch", "-q", "-c", "feature/old")
        repo_fixture.commit(work, "old.txt", "old\n", "Add old")
        repo_fixture.git(work, "switch", "-q", "main")
        # Local main one commit ahead of origin/main, so its tip is not integrated either.
        repo_fixture.commit(work, "main.txt", "main\n", "Add main")
        home = self._home()
        old = os.path.join(work, ".worktrees", "old")
        plain = os.path.join(work, ".worktrees", "plain")
        # The session at old ends on main, the branch the main checkout holds.
        tf.write_transcript(
            self._folder(home, old),
            "77777777-7777-4777-8777-777777777777",
            [
                tf.user("carry on", cwd=old, gitBranch="feature/old"),
                tf.assistant("Carrying on.", cwd=old, gitBranch="feature/old"),
                tf.user("now look at main", cwd=old, gitBranch="main"),
                tf.assistant("Looking.", cwd=old, gitBranch="main"),
                tf.assistant("Still looking.", cwd=old, gitBranch="main"),
            ],
        )
        tf.write_transcript(
            self._folder(home, plain),
            "88888888-8888-4888-8888-888888888888",
            [tf.user("look around", cwd=plain, gitBranch="main"), tf.assistant("Looking.", cwd=plain, gitBranch="main")],
        )

        code, data = self._main(home, "--root", work)

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertEqual(
            [(item["title"], item["attrs"]["worktree"]) for item in data["removed_worktrees"]], [("feature/old", old)]
        )
        self.assertIn("not integrated: feature/old", data["removed_worktrees"][0]["lines"])

    def test_local_base_keeps_the_unpublished_row_of_its_own_branch(self) -> None:
        base = os.path.join(self.tmp, "local-base")
        os.makedirs(base)
        work = repo_fixture.make_repo(base)["work"]
        # Local main two commits ahead of origin/main, which it tracks.
        repo_fixture.commit(work, "one.txt", "one\n", "Add one")
        repo_fixture.commit(work, "two.txt", "two\n", "Add two")
        home = self._home()
        self._proc_root = self._proc()

        code, data = self._main(home, "--root", work, "--base", "main")

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertEqual((data["meta"]["base"], data["meta"]["base_source"]), ("main", "override"))
        self.assertEqual(
            [(item["title"], item["lines"]) for item in data["unpublished"]],
            [("main", ["2 commits not on its upstream"])],
        )

    def test_a_gone_worktree_outside_worktrees_is_not_a_transcript_root(self) -> None:
        work, outside, inside = self._gone_worktrees()
        home = self._home()
        self._proc_root = self._proc()
        # Each session asks about its own branch from inside its gone worktree, and ends on a question.
        for path, branch, session_id in (
            (outside, "feature/outside", "44444444-4444-4444-8444-444444444444"),
            (inside, "feature/inside", "55555555-5555-4555-8555-555555555555"),
        ):
            tf.write_transcript(
                self._folder(home, path),
                session_id,
                [
                    tf.user("carry on with " + branch, cwd=path, gitBranch=branch),
                    tf.assistant("Shall I push " + branch + "?", cwd=path, gitBranch=branch),
                ],
            )

        code, data = self._main(home, "--root", work)

        self.assertEqual(code, 1)
        self.assertEqual(
            sorted(data["meta"]["errors"]),
            sorted(["worktree " + outside + ": directory is gone", "worktree " + inside + ": directory is gone"]),
        )
        self.assertEqual([session["id"] for session in data["questions"]], ["55555555-5555-4555-8555-555555555555"])
        outside_tips = self._by_name(data["tips"], "feature/outside")
        inside_tips = self._by_name(data["tips"], "feature/inside")
        self.assertEqual((len(outside_tips), len(inside_tips)), (1, 1))
        self.assertEqual(outside_tips[0]["sessions"], [])
        self.assertEqual(
            [association["session_id"] for association in inside_tips[0]["sessions"]],
            ["55555555-5555-4555-8555-555555555555"],
        )

    def test_an_edit_in_a_gone_worktree_outside_worktrees_matches_no_path(self) -> None:
        work, outside, _ = self._gone_worktrees()
        with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as handle:
            handle.write("notes\n")
        home = self._home()
        self._proc_root = self._proc()
        # A session in the main checkout edits notes.txt in the gone worktree beside it.
        edit = {
            "name": "Edit",
            "input": {"file_path": os.path.join(outside, "notes.txt"), "old_string": "a", "new_string": "b"},
            "id": "toolu_edit",
        }
        session_id = "66666666-6666-4666-8666-666666666666"
        tf.write_transcript(
            self._folder(home, work),
            session_id,
            [
                tf.user("tidy the notes", cwd=work),
                tf.assistant("Editing.", tool_use=edit, cwd=work),
                tf.tool_result("toolu_edit", cwd=work),
                tf.assistant("Done. Anything else?", cwd=work),
            ],
        )

        code, data = self._main(home, "--root", work)

        self.assertEqual(code, 1)
        # The session was read: it is the one question session.
        self.assertEqual([session["id"] for session in data["questions"]], [session_id])
        dirty = [item for item in data["dirty"] if item["attrs"]["checkout"] == work]
        self.assertEqual(len(dirty), 1)
        self.assertEqual(dirty[0]["paths"], ["notes.txt"])
        self.assertEqual(dirty[0]["sessions"], [])


class ItemBuildersTest(unittest.TestCase):
    """The item builders over model values: no repository, no transcript."""

    REMOTES = model.Remotes(["origin", "upstream"], "upstream")
    BASE = model.Base("upstream/main", "remote-head")

    def test_tip_items_map_integration_names_lines_and_dates(self) -> None:
        tips = [
            model.Tip("1" * 40, ["main", "upstream/main"], "merged", 0, "2026-10-01T10:00:00+04:00", "a@b", None),
            model.Tip("2" * 40, ["staging"], "not", 2, "2026-10-02T10:00:00+04:00", "a@b", "/r/main"),
            model.Tip("3" * 40, ["origin/staging"], "likely", 1, "", "", None),
            model.Tip("4" * 40, ["origin/feature/m"], "merges-only", 1, "2026-10-03T10:00:00+04:00", "c@d", None),
            model.Tip("5" * 40, [], "unknown", 0, "2026-10-04T10:00:00+04:00", "c@d", "/r/main/.worktrees/d"),
        ]
        divergences = [("staging", 1, 2707, "origin/staging")]

        items = inventory.tip_items(tips, self.REMOTES, self.BASE, divergences)

        self.assertEqual([item.title for item in items], ["staging", "origin/staging", "origin/feature/m", "detached HEAD in /r/main/.worktrees/d"])
        self.assertEqual([item.certainty for item in items], ["certain", "likely", "likely", "unknown"])
        self.assertEqual(items[0].names, ["staging", "origin/staging", "upstream/staging"])
        self.assertEqual(items[1].names, ["staging", "origin/staging", "upstream/staging"])
        self.assertEqual(items[3].names, [])
        self.assertIn("local 1 ahead, 2707 behind origin/staging", items[0].lines)
        self.assertIn("local 1 ahead, 2707 behind origin/staging", items[1].lines)
        self.assertEqual(items[0].lines[0], "not integrated: 2 commits ahead of upstream/main")
        self.assertIn("/r/main  (checked out)", items[0].lines)
        self.assertEqual(items[0].attrs, {"author_email": "a@b", "integration": "not", "worktree": "/r/main"})
        self.assertIsNone(items[1].date)
        self.assertEqual(items[1].lines[1], "last commit unknown date by unknown author")
        self.assertEqual((items[0].sha, items[0].date), ("2" * 40, "2026-10-02T10:00:00+04:00"))

    def test_tip_without_a_base_says_so(self) -> None:
        tips = [model.Tip("2" * 40, ["feature/x"], "unknown", 0, "", "a@b", None)]

        items = inventory.tip_items(tips, model.Remotes([], None), model.Base(None, "unknown"), [])

        self.assertEqual(items[0].lines[0], "merged: unknown (no base)")
        self.assertEqual(items[0].names, ["feature/x"])

    def test_unpublished_items_list_every_row_merged_or_not(self) -> None:
        tips = [
            model.Tip("1" * 40, ["done"], "merged", 0, "2026-10-01T10:00:00+04:00", "a@b", None),
            model.Tip("2" * 40, ["open"], "not", 1, "2026-10-02T10:00:00+04:00", "a@b", None),
            model.Tip("3" * 40, ["ahead", "origin/ahead"], "unknown", 0, "", "a@b", None),
        ]
        rows = [("done", "upstream-gone", 0), ("open", "no-upstream", 0), ("ahead", "ahead", 1)]

        items = inventory.unpublished_items(rows, tips)

        self.assertEqual(
            [(item.title, item.lines) for item in items],
            [
                ("done", ["upstream gone: its remote branch no longer exists"]),
                ("open", ["no upstream: never pushed"]),
                ("ahead", ["1 commit not on its upstream"]),
            ],
        )
        self.assertEqual(
            [(item.names, item.date, item.sha) for item in items],
            [
                (["done"], "2026-10-01T10:00:00+04:00", "1" * 40),
                (["open"], "2026-10-02T10:00:00+04:00", "2" * 40),
                (["ahead"], None, "3" * 40),
            ],
        )

    def test_merge_request_items_attach_by_sha_in_ascending_number(self) -> None:
        tips = inventory.tip_items(
            [
                model.Tip("1" * 40, ["feature/a"], "not", 1, "2026-10-01T10:00:00+04:00", "a@b", None),
                model.Tip("2" * 40, ["feature/b"], "not", 1, "2026-10-02T10:00:00+04:00", "a@b", None),
            ],
            self.REMOTES,
            self.BASE,
            [],
        )
        before = list(tips[1].lines)

        def request(number: int, sha: str, title: str, state: str = "open") -> model.MergeRequest:
            return model.MergeRequest(number, title, state, "42", "feature/" + str(number), sha, "main", "u", "https://f/" + str(number))

        # The forges list newest first.
        requests = [
            request(12, "9" * 40, "Later\nstandalone"),
            request(11, "1" * 40, "Second   on a"),
            request(10, "8" * 40, "Earlier standalone", "draft"),
            request(9, "1" * 40, "First on a", "draft"),
        ]

        standalone = inventory.merge_request_items(requests, tips)

        self.assertEqual(tips[0].lines[-2:], ["MR !9 draft First on a -> main", "MR !11 open Second on a -> main"])
        self.assertEqual(tips[1].lines, before)
        self.assertEqual([item.title for item in standalone], ["!10 Earlier standalone", "!12 Later standalone"])
        self.assertEqual(
            [(item.kind, item.certainty, item.names, item.paths, item.date, item.sha, item.sessions) for item in standalone],
            [
                ("merge-request", "certain", ["feature/10"], [], None, "8" * 40, []),
                ("merge-request", "certain", ["feature/12"], [], None, "9" * 40, []),
            ],
        )
        self.assertEqual(standalone[0].lines, ["draft, 42:feature/10 -> main", "head " + "8" * 40, "https://f/10"])
        self.assertEqual(standalone[0].attrs, {"number": "10", "source_project": "42", "author": "u"})

    def test_dirty_item_counts_and_keeps_every_path(self) -> None:
        checkout = model.Checkout("/r/main", "main", "1" * 40, True, True)
        entries = [("M ", "a"), (" M", "b"), ("MM", "c"), ("??", "d"), ("UU", "e")]

        item = inventory.dirty_item(checkout, entries)

        assert item is not None
        self.assertEqual(item.lines, ["5 changed paths: 2 staged, 2 modified, 1 conflicted, 1 untracked"])
        self.assertEqual(item.paths, ["a", "b", "c", "d", "e"])
        self.assertEqual((item.title, item.attrs, item.date), ("/r/main", {"checkout": "/r/main"}, None))
        self.assertIsNone(inventory.dirty_item(checkout, []))


class RemovedWorktreesTest(unittest.TestCase):
    MAIN = "/r/main"
    REMOTES = model.Remotes(["origin"], "origin")

    def _session(
        self,
        branch_counts: dict[str, dict[str, int]],
        *,
        session_id: str = "s",
        first_ts: str = "2026-10-01T10:00:00.000Z",
        last_ts: str = "2026-10-01T11:00:00.000Z",
    ) -> model.Session:
        """A session at each cwd of branch_counts; an empty count is a cwd seen without a branch."""
        return model.Session(
            id=session_id,
            path="/t/" + session_id + ".jsonl",
            mtime=0.0,
            cwds={cwd: (list(counts)[-1] if counts else None) for cwd, counts in branch_counts.items()},
            first_ts=first_ts,
            last_ts=last_ts,
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
            cwd_counts={cwd: max(1, sum(counts.values())) for cwd, counts in branch_counts.items()},
            branch_counts={cwd: dict(counts) for cwd, counts in branch_counts.items() if counts},
        )

    def _place(self, name: str) -> str:
        return self.MAIN + "/.worktrees/" + name

    def test_one_item_per_place_from_its_most_recorded_branch(self) -> None:
        checkouts = [
            model.Checkout(self.MAIN, "main", "1" * 40, True, True),
            model.Checkout(self._place("here"), "feature/here", "2" * 40, False, True),
        ]
        tips = [
            model.Tip("3" * 40, ["feature/old", "origin/feature/old"], "likely", 2, "", "a@b", None),
            model.Tip("4" * 40, ["feature/here"], "not", 1, "", "a@b", None),
            # main is not integrated either, so only the checkout rule keeps it out.
            model.Tip("5" * 40, ["main"], "not", 1, "", "a@b", self.MAIN),
        ]
        sessions = [
            self._session(
                {
                    # main is recorded most at old, but the main checkout holds it.
                    self._place("old") + "/src": {"main": 5, "feature/old": 1},
                    self._place("old"): {"feature/old": 2},
                    # A place that saw only the checked-out branch gives no item.
                    self._place("onlymain"): {"main": 3},
                    self._place("here") + "/src": {"feature/here": 4},
                    self._place("nobranch"): {},
                    self._place("deleted"): {"feature/deleted": 1},
                    self.MAIN + "/src": {"feature/old": 9},
                }
            )
        ]

        items = inventory.removed_worktrees(sessions, checkouts, tips, self.REMOTES, self.MAIN)

        self.assertEqual([(item.title, item.names, item.certainty) for item in items], [("feature/old", ["feature/old"], "likely")])
        self.assertEqual(
            items[0].lines,
            [
                self._place("old") + "  (no longer a checkout)",
                "not integrated: feature/old, origin/feature/old",
                "last session there: s, " + inventory.local_minute("2026-10-01T11:00:00.000Z"),
            ],
        )
        self.assertIsNone(items[0].date)
        self.assertEqual(items[0].sha, "3" * 40)
        self.assertEqual(items[0].attrs, {"worktree": self._place("old")})

    def test_counts_add_up_across_sessions_and_the_chosen_branch_alone_decides(self) -> None:
        checkouts = [model.Checkout(self.MAIN, "main", "1" * 40, True, True)]
        tips = [
            model.Tip("3" * 40, ["feature/one"], "not", 1, "", "a@b", None),
            model.Tip("4" * 40, ["feature/two", "origin/feature/two"], "not", 1, "2026-10-02T10:00:00+04:00", "a@b", None),
            model.Tip("5" * 40, ["feature/open"], "not", 1, "", "a@b", None),
            model.Tip("6" * 40, ["feature/merged"], "merged", 0, "", "a@b", None),
        ]
        sessions = [
            self._session(
                {
                    self._place("a"): {"feature/one": 2},
                    # The branch with the most records is deleted, so the place gives no item.
                    self._place("b"): {"feature/gone": 4, "feature/open": 1},
                    # And so is one whose branch the base has merged.
                    self._place("c"): {"feature/merged": 3, "feature/open": 1},
                },
                session_id="newest",
                last_ts="2026-10-01T15:00:00.000Z",
            ),
            self._session({self._place("a") + "/src": {"feature/two": 1}}, session_id="second"),
            # A session at the place without a branch there still counts as being there.
            self._session(
                {self._place("a"): {"feature/two": 2}, self._place("a") + "/docs": {}},
                session_id="third",
                last_ts="2026-10-01T12:00:00.000Z",
            ),
        ]

        items = inventory.removed_worktrees(sessions, checkouts, tips, self.REMOTES, self.MAIN)

        self.assertEqual([(item.title, item.names) for item in items], [("feature/two", ["feature/two"])])
        self.assertEqual(items[0].attrs, {"worktree": self._place("a")})
        self.assertEqual(items[0].lines[1], "not integrated: feature/two, origin/feature/two")
        self.assertEqual(items[0].lines[2], "last session there: newest, " + inventory.local_minute("2026-10-01T15:00:00.000Z"))
        self.assertEqual((items[0].sha, items[0].date), ("4" * 40, "2026-10-02T10:00:00+04:00"))

    def test_a_tie_goes_to_the_branch_seen_first(self) -> None:
        checkouts = [model.Checkout(self.MAIN, "main", "1" * 40, True, True)]
        tips = [model.Tip(str(n) * 40, ["feature/" + name], "not", 1, "", "a@b", None) for n, name in enumerate("pqrs", start=2)]
        sessions = [
            # Listed first but started later, so feature/q is seen after feature/p.
            self._session({self._place("d"): {"feature/q": 1}}, session_id="later", first_ts="2026-10-01T10:30:00.000Z"),
            self._session({self._place("d"): {"feature/p": 1}}, session_id="earlier", first_ts="2026-10-01T10:10:00.000Z"),
            # Within one session, the order its records gave.
            self._session({self._place("e"): {"feature/s": 2, "feature/r": 2}}),
        ]

        items = inventory.removed_worktrees(sessions, checkouts, tips, self.REMOTES, self.MAIN)

        self.assertEqual(
            sorted((item.attrs["worktree"], item.title) for item in items),
            [(self._place("d"), "feature/p"), (self._place("e"), "feature/s")],
        )

    def test_last_session_line_carries_the_live_tag(self) -> None:
        checkouts = [model.Checkout(self.MAIN, "main", "1" * 40, True, True)]
        tips = [model.Tip("3" * 40, ["feature/old"], "not", 1, "", "a@b", None)]
        remotes = model.Remotes(["origin"], "origin")
        for tag, suffix in ((None, ""), ("live", ", live"), ("possibly live", ", possibly live")):
            with self.subTest(live=tag):
                session = self._session({self.MAIN + "/.worktrees/old": {"feature/old": 1}})
                session.live = tag

                items = inventory.removed_worktrees([session], checkouts, tips, remotes, self.MAIN)

                expected = "last session there: s, " + inventory.local_minute(session.last_ts) + suffix
                self.assertIn(expected, items[0].lines)


class ParkedCountTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="unfinished-parked-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = os.path.join(self.tmp, "home")
        self.main = os.path.join(self.tmp, "main")
        os.makedirs(os.path.join(self.home, ".claude"))
        os.makedirs(self.main)

    def _write(self, path: str, text: str) -> None:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _settings(self, text: str) -> None:
        self._write(os.path.join(self.home, ".claude", "settings.json"), text)

    def test_counts_open_lines_of_the_default_queue(self) -> None:
        self._write(os.path.join(self.main, "LATER.local.md"), "# Parked\n- [ ] one\n  - [ ] two\n- [x] done\n-[ ] not one\n")
        run = model.Run()

        self.assertEqual(inventory.parked_count(self.home, self.main, run), 2)
        self.assertEqual((run.errors, run.notes), ([], []))

    def test_absent_queue_is_none(self) -> None:
        self.assertIsNone(inventory.parked_count(self.home, self.main, model.Run()))

    def test_setting_names_the_queue_top_level_or_nested(self) -> None:
        self._write(os.path.join(self.main, "NOTES.md"), "- [ ] a\n")
        self._write(os.path.join(self.main, "LATER.local.md"), "- [ ] a\n- [ ] b\n")
        for settings in ('{"laterbox.file": "NOTES.md"}', '{"laterbox": {"file": "NOTES.md"}}'):
            with self.subTest(settings=settings):
                self._settings(settings)
                run = model.Run()
                self.assertEqual(inventory.parked_count(self.home, self.main, run), 1)
                self.assertEqual(run.notes, [])

    def test_unusable_setting_or_settings_file_falls_back_with_a_note(self) -> None:
        self._write(os.path.join(self.main, "LATER.local.md"), "- [ ] a\n")
        for settings in ('{"laterbox.file": "a/b"}', '{"laterbox.file": ".."}', '{"laterbox.file": ""}', '{"laterbox.file": 3}', "{oops"):
            with self.subTest(settings=settings):
                self._settings(settings)
                run = model.Run()
                self.assertEqual(inventory.parked_count(self.home, self.main, run), 1)
                self.assertEqual(len(run.notes), 1)
                self.assertIn("LATER.local.md", run.notes[0])
                self.assertEqual(run.errors, [])

    def test_unreadable_queue_is_an_error(self) -> None:
        os.makedirs(os.path.join(self.main, "LATER.local.md"))
        run = model.Run()

        self.assertIsNone(inventory.parked_count(self.home, self.main, run))
        self.assertFalse(run.complete)
        self.assertEqual(len(run.errors), 1)


if __name__ == "__main__":
    unittest.main()
