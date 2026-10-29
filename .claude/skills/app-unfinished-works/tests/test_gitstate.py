"""Tests for scripts/unfinishedlib/gitstate.py: repository discovery and the
git-state inventory (branch tips, publication, dirty trees, stashes).

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
import time
import unittest
from datetime import datetime
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

    # Branch tips and their integration against the base.

    def _base(self, work: str, run: model.Run) -> model.Base:
        return gitstate.resolve_base(work, gitstate.remotes(work, run), None, run)

    def _tips(self, work: str, run: model.Run) -> list[model.Tip]:
        found = gitstate.remotes(work, run)
        return gitstate.branch_tips(work, found, gitstate.worktrees(work, run), self._base(work, run), run)

    def _commit_on(self, work: str, branch: str, path: str, msg: str) -> str:
        """Commit path on a new branch cut from HEAD, switch back to main, return the SHA."""
        repo_fixture.git(work, "switch", "-q", "-c", branch)
        sha = repo_fixture.commit(work, path, msg + "\n", msg)
        repo_fixture.git(work, "switch", "-q", "main")
        return sha

    def _diverge_staging(self, work: str) -> None:
        """Leave local staging one commit ahead of and one behind origin/staging."""
        repo_fixture.git(work, "branch", "staging")
        repo_fixture.git(work, "push", "-q", "-u", "origin", "staging")
        self._commit_on(work, "elsewhere", "remote.txt", "Add the remote side")
        repo_fixture.git(work, "push", "-q", "origin", "elsewhere:staging")
        repo_fixture.git(work, "branch", "-q", "-D", "elsewhere")
        repo_fixture.git(work, "switch", "-q", "staging")
        repo_fixture.commit(work, "local.txt", "local\n", "Add the local side")
        repo_fixture.git(work, "switch", "-q", "main")

    def test_tip_merged_is_ancestor(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        sha = self._commit_on(work, "done", "done.txt", "Add done")
        repo_fixture.git(work, "merge", "-q", "--no-ff", "-m", "Merge done", "done")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        run = model.Run()

        result = gitstate.integration_of(work, sha, self._base(work, run), run=run)

        self.assertEqual(result, ("merged", 0))
        self.assertEqual(run.errors, [])

    def test_tip_not_integrated_records_no_error(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        sha = self._commit_on(work, "topic", "topic.txt", "Add topic")
        run = model.Run()

        result = gitstate.integration_of(work, sha, self._base(work, run), run=run)

        self.assertEqual(result, ("not", 1))
        self.assertEqual(run.errors, [])
        self.assertIs(run.complete, True)

    def test_tip_cherry_picked_is_likely(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        sha = self._commit_on(work, "cp", "cp.txt", "Add cp")
        # main moves first, so the picked commit gets a new parent and a new SHA.
        repo_fixture.commit(work, "other.txt", "other\n", "Add other")
        repo_fixture.git(work, "cherry-pick", sha)
        repo_fixture.git(work, "push", "-q", "origin", "main")
        run = model.Run()

        result = gitstate.integration_of(work, sha, self._base(work, run), run=run)

        self.assertEqual(result, ("likely", 1))
        self.assertEqual(run.errors, [])

    def test_tip_two_commit_squash_is_not(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        repo_fixture.git(work, "switch", "-q", "-c", "sq")
        repo_fixture.commit(work, "s1.txt", "one\n", "Add s1")
        sha = repo_fixture.commit(work, "s2.txt", "two\n", "Add s2")
        repo_fixture.git(work, "switch", "-q", "main")
        repo_fixture.git(work, "merge", "-q", "--squash", "sq")
        repo_fixture.git(work, "commit", "-q", "-m", "Squash sq")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        run = model.Run()

        result = gitstate.integration_of(work, sha, self._base(work, run), run=run)

        self.assertEqual(result, ("not", 2))
        self.assertEqual(run.errors, [])

    def test_tip_merges_only(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        repo_fixture.git(work, "branch", "promo")
        repo_fixture.commit(work, "later.txt", "later\n", "Add later")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        repo_fixture.git(work, "switch", "-q", "promo")
        repo_fixture.git(work, "merge", "-q", "--no-ff", "-m", "Merge main into promo", "main")
        sha = repo_fixture.git(work, "rev-parse", "HEAD").strip()
        repo_fixture.git(work, "switch", "-q", "main")
        run = model.Run()

        result = gitstate.integration_of(work, sha, self._base(work, run), run=run)

        self.assertEqual(result, ("merges-only", 1))
        self.assertEqual(run.errors, [])

    def test_tip_integration_unknown_without_base(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        sha = self._commit_on(work, "topic", "topic.txt", "Add topic")
        run = model.Run()

        result = gitstate.integration_of(work, sha, model.Base(None, "unknown"), run=run)

        self.assertEqual(result, ("unknown", 0))
        self.assertEqual(run.errors, [])

    def test_tip_is_ancestor_failure_is_recorded(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        missing = "0" * 40
        run = model.Run()

        result = gitstate.integration_of(work, missing, self._base(work, run), run=run)

        self.assertEqual(result, ("unknown", 0))
        self.assertEqual(len(run.errors), 1)
        prefix = "git merge-base --is-ancestor " + missing + " origin/main: "
        self.assertTrue(run.errors[0].startswith(prefix), run.errors[0])
        self.assertGreater(len(run.errors[0]), len(prefix))
        self.assertIs(run.complete, False)

    def test_same_sha_groups_refs(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        sha = self._commit_on(work, "feature/x", "x.txt", "Add x")
        repo_fixture.git(work, "push", "-q", "-u", "origin", "feature/x")
        main_sha = repo_fixture.git(work, "rev-parse", "main").strip()
        run = model.Run()

        tips = self._tips(work, run)

        # One Tip per SHA, local refs first; origin/HEAD is not a tip ref.
        self.assertEqual([(tip.sha, tip.refs) for tip in tips], [
            (sha, ["feature/x", "origin/feature/x"]),
            (main_sha, ["main", "origin/main"]),
        ])
        feature, main = tips
        self.assertEqual((feature.integration, feature.ahead, feature.worktree), ("not", 1, None))
        self.assertEqual((main.integration, main.ahead, main.worktree), ("merged", 0, work))
        self.assertIn("@", feature.author_email)
        self.assertIsNotNone(datetime.fromisoformat(feature.last_date).tzinfo)
        self.assertEqual(run.errors, [])

    def test_detached_worktree_head_is_a_tip(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        # A commit no branch or remote ref points at once its branch is gone.
        sha = self._commit_on(work, "scratch", "d.txt", "Add detached work")
        repo_fixture.git(work, "branch", "-q", "-D", "scratch")
        detached = os.path.join(self.tmp, "d")
        repo_fixture.git(work, "worktree", "add", "--detach", detached, sha)
        run = model.Run()

        tips = [tip for tip in self._tips(work, run) if tip.sha == sha]

        self.assertEqual(len(tips), 1)
        self.assertEqual(tips[0].refs, [])
        self.assertEqual(tips[0].worktree, detached)
        self.assertEqual((tips[0].integration, tips[0].ahead), ("not", 1))
        self.assertEqual(run.errors, [])

    def test_tip_worktree_prefers_a_linked_worktree(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        added = os.path.join(self.tmp, "wt")
        # The linked worktree and the main checkout both sit at main's tip.
        repo_fixture.git(work, "worktree", "add", added, "-b", "feature/x")
        run = model.Run()

        tips = self._tips(work, run)

        self.assertEqual([(tip.refs, tip.worktree) for tip in tips], [(["feature/x", "main", "origin/main"], added)])
        self.assertEqual(run.errors, [])

    def test_divergence_counts(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        self._diverge_staging(work)
        run = model.Run()
        tips = self._tips(work, run)

        self.assertEqual(gitstate.divergence(work, tips), [("staging", 1, 1, "origin/staging")])
        self.assertEqual(gitstate.divergence(work, tips, run=run), [("staging", 1, 1, "origin/staging")])
        self.assertEqual(run.errors, [])

    def test_namesake_tag_changes_neither_ref_names_nor_counts(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        self._diverge_staging(work)
        # A tag named like the branch: short names would read heads/staging,
        # and an unqualified staging...origin/staging would count from the tag.
        repo_fixture.git(work, "tag", "staging", "main")
        run = model.Run()

        tips = self._tips(work, run)

        self.assertIn(["staging"], [tip.refs for tip in tips])
        self.assertEqual(gitstate.divergence(work, tips, run=run), [("staging", 1, 1, "origin/staging")])
        self.assertIn(("staging", "ahead", 1), gitstate.unpublished(work, run))
        self.assertEqual(run.errors, [])

    def test_divergence_failure_is_recorded_only_with_a_run(self) -> None:
        tips = [
            model.Tip("1" * 40, ["staging"], "not", 1, "2026-10-29T10:00:00+04:00", "a@example.test", None),
            model.Tip("2" * 40, ["origin/staging"], "not", 1, "2026-10-29T10:00:00+04:00", "a@example.test", None),
        ]
        calls: list[list[str]] = []

        def runner(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            calls.append(argv)
            return 128, "", "fatal: bad revision\n"

        self.assertEqual(gitstate.divergence("/repo", tips, runner), [])
        run = model.Run()
        self.assertEqual(gitstate.divergence("/repo", tips, runner, run=run), [])

        operands = "refs/heads/staging...refs/remotes/origin/staging"
        self.assertEqual(calls, [["git", "-C", "/repo", "rev-list", "--left-right", "--count", operands]] * 2)
        self.assertEqual(run.errors, ["git rev-list --left-right --count " + operands + ": fatal: bad revision"])
        self.assertIs(run.complete, False)

    def test_strip_remote_strips_only_included_remotes(self) -> None:
        both = model.Remotes(["origin", "upstream"], "upstream")

        self.assertEqual(gitstate.strip_remote("origin/feature/x", both), "feature/x")
        self.assertEqual(gitstate.strip_remote("upstream/main", both), "main")
        self.assertEqual(gitstate.strip_remote("feature/x", both), "feature/x")
        self.assertEqual(gitstate.strip_remote("fork/x", both), "fork/x")
        self.assertEqual(gitstate.strip_remote("origin/x", model.Remotes([], None)), "origin/x")

    # Unpublished commits, dirty checkouts, stashes and the fetch age.

    def test_unpublished_states(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        repo_fixture.git(work, "branch", "topic")
        repo_fixture.git(work, "branch", "old")
        repo_fixture.git(work, "push", "-q", "-u", "origin", "old")
        repo_fixture.git(work, "push", "-q", "origin", "--delete", "old")
        repo_fixture.git(work, "branch", "synced")
        repo_fixture.git(work, "push", "-q", "-u", "origin", "synced")
        repo_fixture.git(work, "branch", "--track", "lagging", "origin/main")
        repo_fixture.commit(work, "pushed.txt", "pushed\n", "Add pushed")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        repo_fixture.commit(work, "local.txt", "local\n", "Add local")
        run = model.Run()

        rows = gitstate.unpublished(work, run)

        # synced is in sync and lagging only behind: neither has unpublished commits.
        self.assertEqual(rows, [("main", "ahead", 1), ("old", "upstream-gone", 0), ("topic", "no-upstream", 0)])
        self.assertEqual(run.errors, [])

    def test_dirty_lists_untracked_files_individually(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        os.makedirs(os.path.join(work, "newdir"))
        for name in ("one.txt", "two.txt"):
            with open(os.path.join(work, "newdir", name), "w", encoding="utf-8") as handle:
                handle.write(name + "\n")
        run = model.Run()

        entries = gitstate.dirty(gitstate.worktrees(work, run)[0], run)

        self.assertEqual(entries, [("??", "newdir/one.txt"), ("??", "newdir/two.txt")])
        self.assertEqual(run.errors, [])

    def test_dirty_rename_reports_new_path_once(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        repo_fixture.commit(work, "a", "alpha\n", "Add a")
        repo_fixture.git(work, "mv", "a", "b")
        run = model.Run()

        entries = gitstate.dirty(gitstate.worktrees(work, run)[0], run)

        self.assertEqual(entries, [("R ", "b")])
        self.assertEqual(run.errors, [])

    def test_dirty_skips_checkouts_without_a_work_tree(self) -> None:
        repo = repo_fixture.make_repo(self.tmp)
        work = repo["work"]
        gone = os.path.join(self.tmp, "gone")
        repo_fixture.git(work, "worktree", "add", gone, "-b", "gone")
        shutil.rmtree(gone)
        # A worktree of the bare origin makes `git worktree list` there start
        # with the bare entry, which has no work tree to read.
        repo_fixture.git(repo["origin"], "worktree", "add", os.path.join(self.tmp, "from-bare"), "main")
        removed = gitstate.worktrees(work, model.Run())[1]
        bare = gitstate.worktrees(repo["origin"], model.Run())[0]
        self.assertEqual((removed.present, bare.head, bare.branch), (False, "", None))
        run = model.Run()

        self.assertEqual(gitstate.dirty(removed, run), [])
        self.assertEqual(gitstate.dirty(bare, run), [])
        self.assertEqual(run.errors, [])

    def test_stash_paths_include_untracked_and_date_has_offset(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        with open(os.path.join(work, "README.md"), "a", encoding="utf-8") as handle:
            handle.write("more\n")
        with open(os.path.join(work, "new.txt"), "w", encoding="utf-8") as handle:
            handle.write("new\n")
        repo_fixture.git(work, "stash", "push", "-q", "-u", "-m", "wip")
        run = model.Run()

        entries = gitstate.stashes(work, run)

        self.assertEqual(len(entries), 1)
        ref, date_iso, message, paths = entries[0]
        self.assertEqual((ref, message), ("stash@{0}", "On main: wip"))
        self.assertEqual(sorted(paths), ["README.md", "new.txt"])
        self.assertIsNotNone(datetime.fromisoformat(date_iso).tzinfo)
        self.assertEqual(run.errors, [])

    def test_dirty_and_stash_paths_are_not_quoted(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        name = "\N{GEORGIAN LETTER AN}\N{GEORGIAN LETTER BAN} \"q\".txt"
        with open(os.path.join(work, name), "w", encoding="utf-8") as handle:
            handle.write("georgian\n")
        run = model.Run()

        self.assertEqual(gitstate.dirty(gitstate.worktrees(work, run)[0], run), [("??", name)])
        repo_fixture.git(work, "stash", "push", "-q", "-u", "-m", "georgian")
        self.assertEqual([entry[3] for entry in gitstate.stashes(work, run)], [[name]])
        self.assertEqual(run.errors, [])

    def test_fetch_age_is_none_without_fetch_head(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]

        self.assertIsNone(gitstate.fetch_age_seconds(work))

    def test_fetch_age_reads_the_newest_fetch_head_under_the_common_dir(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        added = os.path.join(self.tmp, "wt")
        repo_fixture.git(work, "worktree", "add", added, "-b", "feature/x")
        # A fetch from a linked worktree writes .git/worktrees/<name>/FETCH_HEAD.
        repo_fixture.git(work, "fetch", "-q", "origin")
        repo_fixture.git(added, "fetch", "-q", "origin")
        heads = [os.path.join(work, ".git", "FETCH_HEAD"), os.path.join(work, ".git", "worktrees", "wt", "FETCH_HEAD")]
        now = time.time()
        for path, age in zip(heads, (7200, 3600), strict=True):
            os.utime(path, (now - age, now - age))

        for checkout in (work, added):
            age = gitstate.fetch_age_seconds(checkout)
            self.assertIsNotNone(age, checkout)
            assert age is not None
            self.assertGreaterEqual(age, 3600, checkout)
            self.assertLess(age, 3660, checkout)
