"""Tests for the repository discovery in scripts/unfinishedlib/gitstate.py.

Every case builds throwaway repositories under its own temporary directory
through tests/repo_fixture.py; no case reads this machine's repositories.
"""

import contextlib
import importlib
import io
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.unfinishedlib import cli, gitstate, model
from tests import repo_fixture


class GitstateTest(unittest.TestCase):
    def setUp(self) -> None:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        # git reports real paths, so the fixture root is resolved up front.
        self.tmp = os.path.realpath(holder.name)

    def test_worktrees_lists_main_and_added_worktree(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        work = repo["work"]
        added = os.path.join(self.tmp, "wt")
        repo_fixture.git(work, "worktree", "add", added, "-b", "feature/x")
        head = repo_fixture.git(work, "rev-parse", "HEAD").strip()
        run = model.Run()

        checkouts = gitstate.worktrees(work, run)

        self.assertEqual(
            checkouts,
            [
                model.Checkout(work, "main", head, True, True),
                model.Checkout(added, "feature/x", head, False, True),
            ],
        )
        self.assertEqual(run.errors, [])
        self.assertIs(run.complete, True)

    def test_prunable_worktree_is_not_present(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        work = repo["work"]
        added = os.path.join(self.tmp, "wt")
        repo_fixture.git(work, "worktree", "add", added, "-b", "feature/x")
        shutil.rmtree(added)
        run = model.Run()

        checkouts = gitstate.worktrees(work, run)

        self.assertEqual(len(checkouts), 2)
        self.assertTrue(checkouts[0].present)
        self.assertEqual(checkouts[1].path, added)
        self.assertEqual(checkouts[1].branch, "feature/x")
        self.assertIs(checkouts[1].present, False)
        self.assertEqual(run.errors, ["worktree " + added + ": directory is gone"])
        self.assertIs(run.complete, False)

    def test_detached_worktree_has_no_branch(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        work = repo["work"]
        added = os.path.join(self.tmp, "det")
        repo_fixture.git(work, "worktree", "add", "--detach", added)
        head = repo_fixture.git(work, "rev-parse", "HEAD").strip()
        run = model.Run()

        checkouts = gitstate.worktrees(work, run)

        self.assertEqual(checkouts[1], model.Checkout(added, None, head, False, True))
        self.assertEqual(run.errors, [])
        self.assertIs(run.complete, True)

    def test_remotes_prefers_upstream_as_canonical(self) -> None:
        repo = repo_fixture.make_repo(self.tmp, with_upstream=True)
        run = model.Run()

        found = gitstate.remotes(repo["work"], run)

        self.assertEqual(found.canonical, "upstream")
        self.assertEqual(found.included, ["origin", "upstream"])
        self.assertEqual(run.errors, [])

    def test_remotes_empty_without_any_remote(self) -> None:
        repo = repo_fixture.make_repo(self.tmp, with_origin=False)
        run = model.Run()

        found = gitstate.remotes(repo["work"], run)

        self.assertEqual(found, model.Remotes([], None))
        self.assertEqual(run.errors, [])

    def test_base_from_origin_head(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        run = model.Run()
        found = gitstate.remotes(repo["work"], run)

        base = gitstate.resolve_base(repo["work"], found, None, run)

        self.assertEqual(base.ref, "origin/main")
        self.assertEqual(base.source, "remote-head")
        self.assertEqual(run.errors, [])

    def test_base_from_remote_name_without_remote_head(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        repo_fixture.git(repo["work"], "remote", "set-head", "origin", "-d")
        run = model.Run()

        base = gitstate.resolve_base(repo["work"], gitstate.remotes(repo["work"], run), None, run)

        self.assertEqual(base, model.Base("origin/main", "remote-name"))
        self.assertEqual(run.errors, [])

    def test_base_with_a_remote_never_falls_back_to_local_names(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        work = repo["work"]
        repo_fixture.git(work, "remote", "set-head", "origin", "-d")
        repo_fixture.git(work, "update-ref", "-d", "refs/remotes/origin/main")
        run = model.Run()

        base = gitstate.resolve_base(work, gitstate.remotes(work, run), None, run)

        self.assertEqual(base, model.Base(None, "unknown"))
        self.assertEqual(run.errors, [])
        self.assertIs(run.complete, True)

    def test_base_without_remote_uses_local_main(self) -> None:
        repo = repo_fixture.make_repo(self.tmp, with_origin=False)
        run = model.Run()

        base = gitstate.resolve_base(repo["work"], gitstate.remotes(repo["work"], run), None, run)

        self.assertEqual(base.ref, "main")
        self.assertEqual(base.source, "local-name")
        self.assertEqual(run.errors, [])

    def test_base_unknown_when_nothing_resolves(self) -> None:
        repo = repo_fixture.make_repo(self.tmp, with_origin=False)
        repo_fixture.git(repo["work"], "branch", "-m", "main", "topic")
        run = model.Run()

        base = gitstate.resolve_base(repo["work"], gitstate.remotes(repo["work"], run), None, run)

        self.assertIsNone(base.ref)
        self.assertEqual(base.source, "unknown")
        self.assertEqual(run.errors, [])

    def test_base_override_that_resolves_wins(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        repo_fixture.git(repo["work"], "branch", "release")
        run = model.Run()

        base = gitstate.resolve_base(repo["work"], gitstate.remotes(repo["work"], run), "release", run)

        self.assertEqual(base, model.Base("release", "override"))
        self.assertEqual(run.errors, [])

    def test_base_override_that_does_not_resolve_is_unknown(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        run = model.Run()

        base = gitstate.resolve_base(repo["work"], gitstate.remotes(repo["work"], run), "no-such", run)

        self.assertEqual(base, model.Base(None, "unknown"))
        self.assertEqual(run.errors, ["--base no-such: does not resolve to a commit"])
        self.assertIs(run.complete, False)

    def test_try_git_reports_exit_code_without_error(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)

        result = gitstate.try_git(repo["work"], "rev-parse", "--verify", "--quiet", "nope")

        self.assertEqual(result, (1, "", ""))

    def test_run_git_records_error_and_continues(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        run = model.Run()

        out = gitstate.run_git(repo["work"], "rev-parse", "no-such-ref", run=run)
        after = gitstate.run_git(repo["work"], "rev-parse", "HEAD", run=run)

        self.assertEqual(out, "")
        self.assertIs(run.complete, False)
        self.assertEqual(len(run.errors), 1)
        self.assertTrue(run.errors[0].startswith("git rev-parse"), run.errors[0])
        self.assertRegex(after, r"^[0-9a-f]{40}\n$")

    def test_common_dir_is_absolute(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        work = repo["work"]
        added = os.path.join(self.tmp, "wt")
        repo_fixture.git(work, "worktree", "add", added, "-b", "feature/x")

        found = gitstate.common_dir(added)

        self.assertTrue(os.path.isabs(found), found)
        self.assertEqual(found, os.path.join(work, ".git"))

    def test_common_dir_outside_a_repository_exits_two(self) -> None:
        def runner(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            return 128, "", "fatal: not a git repository (or any of the parent directories): .git\n"

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
            gitstate.common_dir("/elsewhere", runner=runner)

        self.assertEqual(raised.exception.code, 2)
        message = stderr.getvalue()
        self.assertEqual(message.count("\n"), 1, message)
        self.assertIn("/elsewhere", message)

    def test_default_runner_reports_missing_binary(self) -> None:
        result = model.default_runner(["unfinished-no-such-binary"], None)

        self.assertEqual(result, (127, "", "unfinished-no-such-binary: command not found"))

    def test_fixture_import_scrubs_git_local_env_vars(self) -> None:
        names = subprocess.run(
            ["git", "rev-parse", "--local-env-vars"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split()
        self.assertIn("GIT_DIR", names)
        # Values under this case's own temp root; nothing ever runs git on them.
        decoy = {name: os.path.join(self.tmp, "decoy", name) for name in names}
        decoy["UNFINISHED_HOME"] = os.path.join(self.tmp, "decoy-home")

        with mock.patch.dict(os.environ, decoy):
            importlib.reload(repo_fixture)
            left = sorted(name for name in decoy if name in os.environ)

        self.assertEqual(left, [])
        self.assertEqual(sorted(name for name in decoy if name in os.environ), [])

    def test_cli_help_exits_zero(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), self.assertRaises(SystemExit) as raised:
            cli.main(["--help"])

        self.assertEqual(raised.exception.code, 0)
        for flag in ("--json", "--forge", "--mine", "--fetch", "--base", "--since", "--no-questions", "--root"):
            self.assertIn(flag, stdout.getvalue())
