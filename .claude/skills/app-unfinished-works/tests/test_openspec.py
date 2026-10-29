"""Tests for scripts/unfinishedlib/openspec.py: pending and stale OpenSpec
changes across checkouts and branch tips.

Every case builds throwaway repositories under its own temporary directory
through tests/repo_fixture.py; no case reads this machine's repositories.
"""

import os
import subprocess
import tempfile
import unittest

from scripts.unfinishedlib import gitstate, model, openspec
from tests import repo_fixture

# Committed on main and pushed in every _repo() fixture: foo is archived.
ARCHIVED_FOO = "openspec/changes/archive/2026-10-01-foo/proposal.md"


class OpenspecTest(unittest.TestCase):
    def setUp(self) -> None:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        # git reports real paths, so the fixture root is resolved up front.
        self.tmp = os.path.realpath(holder.name)

    # Fixtures.

    def _repo(self) -> str:
        """A checkout whose main, pushed to origin (the base), archives foo."""
        work = repo_fixture.make_repo(self.tmp)["work"]
        repo_fixture.commit(work, ARCHIVED_FOO, "# foo\n", "Archive foo")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        return work

    def _commit_on(self, work: str, branch: str, path: str, text: str) -> str:
        """Commit path on a new branch cut from HEAD, switch back to main, return the SHA."""
        repo_fixture.git(work, "switch", "-q", "-c", branch)
        sha = repo_fixture.commit(work, path, text, "Add " + path)
        repo_fixture.git(work, "switch", "-q", "main")
        return sha

    def _commit_at(self, work: str, path: str, committed_at: str) -> str:
        """Commit a new file at path with the committer date committed_at, return the SHA."""
        self._write(work, path, path + "\n")
        repo_fixture.git(work, "add", "--", path)
        subprocess.run(
            ["git", "-C", work, "commit", "-q", "-m", "Add " + path],
            env=dict(os.environ, GIT_COMMITTER_DATE=committed_at),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=True,
        )
        return repo_fixture.git(work, "rev-parse", "HEAD").strip()

    def _write(self, work: str, path: str, text: str) -> None:
        """Write text to <work>/<path> without staging it."""
        target = os.path.join(work, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _date(self, work: str, sha: str) -> str:
        return repo_fixture.git(work, "show", "-s", "--format=%cI", sha).strip()

    def _state(self, work: str, run: model.Run) -> tuple[list[model.Checkout], list[model.Tip], model.Base]:
        found = gitstate.remotes(work, run)
        checkouts = gitstate.worktrees(work, run)
        base = gitstate.resolve_base(work, found, None, run)
        return checkouts, gitstate.branch_tips(work, found, checkouts, base, run), base

    def _items(self, work: str, run: model.Run | None = None) -> tuple[list[model.Item], list[model.Item], model.Run]:
        if run is None:
            run = model.Run()
        checkouts, tips, base = self._state(work, run)
        pending, stale = openspec.openspec_items(work, checkouts, tips, base, run)
        return pending, stale, run

    def _main_checkout(self, work: str, run: model.Run) -> model.Checkout:
        return gitstate.worktrees(work, run)[0]

    # Task counts and the archive.

    def test_task_counts(self) -> None:
        self.assertEqual(openspec.task_counts("- [x] a\n- [ ] b\n- [X] c\n"), (2, 1))

    def test_archive_prefix_is_stripped_whole_name(self) -> None:
        work = self._repo()
        repo_fixture.commit(work, "openspec/changes/archive/2026-10-02-big-foo/proposal.md", "# big-foo\n", "Archive big-foo")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        self._write(work, "openspec/changes/foo-2/proposal.md", "# foo-2\n")
        run = model.Run()
        _, _, base = self._state(work, run)

        self.assertEqual(openspec.archived_names(work, base, run), {"foo", "big-foo"})
        pending, stale, run = self._items(work, run)
        self.assertEqual([item.title for item in pending], ["foo-2"])
        self.assertEqual(stale, [])
        self.assertEqual(run.errors, [])

    def test_undated_archive_directory_archives_nothing(self) -> None:
        work = self._repo()
        repo_fixture.commit(work, "openspec/changes/archive/notes/readme.md", "notes\n", "Add archive notes")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        self._write(work, "openspec/changes/notes/proposal.md", "# notes\n")
        run = model.Run()
        _, _, base = self._state(work, run)

        self.assertEqual(openspec.archived_names(work, base, run), {"foo"})
        pending, stale, run = self._items(work, run)
        self.assertEqual([item.title for item in pending], ["notes"])
        self.assertEqual(stale, [])

    def test_archived_names_empty_without_base(self) -> None:
        work = self._repo()
        run = model.Run()

        self.assertEqual(openspec.archived_names(work, model.Base(None, "unknown"), run), set())
        self.assertEqual(run.errors, [])

    # Changes in a checkout's filesystem.

    def test_untracked_change_in_checkout_is_pending(self) -> None:
        work = self._repo()
        self._write(work, "openspec/changes/bar/tasks.md", "- [ ] one\n")
        run = model.Run()

        rows = openspec.change_dirs_in_checkout(self._main_checkout(work, run), run)
        pending, stale, run = self._items(work, run)

        self.assertEqual(rows, [("bar", "untracked", 0, 1)])
        self.assertEqual(
            pending,
            [
                model.Item(
                    kind="openspec-pending",
                    title="bar",
                    certainty="certain",
                    lines=[work + "  untracked  tasks 0/1"],
                    paths=["openspec/changes/bar"],
                    names=["bar"],
                    date=None,
                    sha=None,
                    sessions=[],
                )
            ],
        )
        self.assertEqual(stale, [])
        self.assertEqual(run.errors, [])
        self.assertIs(run.complete, True)

    def test_change_without_tasks_counts_zero(self) -> None:
        work = self._repo()
        sha = repo_fixture.commit(work, "openspec/changes/qux/proposal.md", "# qux\n", "Propose qux")
        run = model.Run()

        rows = openspec.change_dirs_in_checkout(self._main_checkout(work, run), run)
        pending, _, run = self._items(work, run)

        self.assertEqual(rows, [("qux", "tracked", 0, 0)])
        # Local main is ahead of the base, so its tree is scanned as well.
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0].lines, [work + "  tracked  tasks 0/0", "ref main"])
        self.assertEqual(pending[0].date, self._date(work, sha))
        self.assertEqual(run.errors, [])

    def test_checkout_status_tracked_modified_untracked(self) -> None:
        work = self._repo()
        repo_fixture.commit(work, "openspec/changes/kept/tasks.md", "- [x] a\n", "Propose kept")
        repo_fixture.commit(work, "openspec/changes/edited/tasks.md", "- [x] a\n", "Propose edited")
        self._write(work, "openspec/changes/edited/tasks.md", "- [x] a\n- [ ] b\n")
        self._write(work, "openspec/changes/fresh/tasks.md", "- [ ] c\n- [ ] d\n")
        run = model.Run()

        rows = openspec.change_dirs_in_checkout(self._main_checkout(work, run), run)

        self.assertEqual(rows, [("edited", "modified", 1, 1), ("fresh", "untracked", 0, 2), ("kept", "tracked", 1, 0)])
        self.assertEqual(run.errors, [])

    def test_checkout_status_reads_the_change_name_literally(self) -> None:
        work = self._repo()
        # A glob pathspec "a*" would also match the untracked sibling "ab".
        repo_fixture.commit(work, "openspec/changes/a*/proposal.md", "# a*\n", "Propose a*")
        self._write(work, "openspec/changes/ab/proposal.md", "# ab\n")
        run = model.Run()

        rows = openspec.change_dirs_in_checkout(self._main_checkout(work, run), run)

        self.assertEqual(rows, [("a*", "tracked", 0, 0), ("ab", "untracked", 0, 0)])
        self.assertEqual(run.errors, [])

    def test_unborn_checkout_change_has_no_date_and_no_error(self) -> None:
        work = os.path.join(self.tmp, "unborn")
        repo_fixture.git(self.tmp, "init", "-q", "-b", "main", work)
        self._write(work, "openspec/changes/bar/tasks.md", "- [ ] one\n")
        run = model.Run()
        checkouts = gitstate.worktrees(work, run)

        pending, stale = openspec.openspec_items(work, checkouts, [], model.Base(None, "unknown"), run)

        self.assertEqual([(item.title, item.lines, item.date) for item in pending], [("bar", [work + "  untracked  tasks 0/1"], None)])
        self.assertEqual(stale, [])
        self.assertEqual(run.errors, [])

    def test_checkout_without_openspec_or_gone_lists_nothing(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        run = model.Run()
        main = self._main_checkout(work, run)
        gone = model.Checkout(os.path.join(self.tmp, "gone"), "feature/x", main.head, False, False)

        self.assertEqual(openspec.change_dirs_in_checkout(main, run), [])
        self.assertEqual(openspec.change_dirs_in_checkout(gone, run), [])
        self.assertEqual(run.errors, [])

    # Changes in the trees of branch tips.

    def test_change_on_other_branch_is_pending(self) -> None:
        work = self._repo()
        sha = self._commit_on(work, "topic", "openspec/changes/baz/proposal.md", "# baz\n")
        repo_fixture.git(work, "push", "-q", "origin", "topic")

        pending, stale, run = self._items(work)

        self.assertEqual([item.title for item in pending], ["baz"])
        # One tip, read once by its SHA; one line per ref naming it.
        self.assertEqual(pending[0].lines, ["ref topic", "ref origin/topic"])
        self.assertEqual(pending[0].paths, ["openspec/changes/baz"])
        self.assertEqual(pending[0].date, self._date(work, sha))
        self.assertEqual(stale, [])
        self.assertEqual(run.errors, [])

    def test_archived_change_present_elsewhere_is_stale(self) -> None:
        work = self._repo()
        sha = self._commit_on(work, "topic", "openspec/changes/foo/proposal.md", "# foo\n")

        pending, stale, run = self._items(work)

        self.assertEqual(pending, [])
        self.assertEqual(
            stale,
            [
                model.Item(
                    kind="openspec-stale",
                    title="foo",
                    certainty="certain",
                    lines=["archived on origin/main", "ref topic"],
                    paths=["openspec/changes/foo"],
                    names=["foo"],
                    date=self._date(work, sha),
                    sha=None,
                    sessions=[],
                )
            ],
        )
        self.assertEqual(run.errors, [])

    def test_merged_branch_is_not_scanned_for_stale_copies(self) -> None:
        work = self._repo()
        self._commit_on(work, "old", "openspec/changes/foo/proposal.md", "# foo\n")
        repo_fixture.git(work, "merge", "-q", "--no-ff", "-m", "Merge old", "old")
        repo_fixture.git(work, "rm", "-q", "-r", "openspec/changes/foo")
        repo_fixture.git(work, "commit", "-q", "-m", "Drop the merged copy of foo")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        run = model.Run()
        _, tips, _ = self._state(work, run)
        # old still holds foo in its tree, but it is merged into the base.
        self.assertEqual([tip.integration for tip in tips if "old" in tip.refs], ["merged"])

        pending, stale, run = self._items(work, run)

        self.assertEqual((pending, stale), ([], []))
        self.assertEqual(run.errors, [])

    def test_same_change_in_two_places_is_one_item(self) -> None:
        work = self._repo()
        sha = self._commit_on(work, "topic", "openspec/changes/bar/tasks.md", "- [x] one\n")
        self._write(work, "openspec/changes/bar/tasks.md", "- [ ] one\n")

        pending, stale, run = self._items(work)

        self.assertEqual([item.title for item in pending], ["bar"])
        # Checkouts first, then tips; the untracked copy has no commit, so the
        # date comes from the next place that has one.
        self.assertEqual(pending[0].lines, [work + "  untracked  tasks 0/1", "ref topic"])
        self.assertEqual(pending[0].date, self._date(work, sha))
        self.assertEqual(stale, [])
        self.assertEqual(run.errors, [])

    def test_detached_tip_is_named_by_its_sha(self) -> None:
        work = self._repo()
        # A commit no branch or remote ref points at once its branch is gone.
        sha = self._commit_on(work, "scratch", "openspec/changes/det/proposal.md", "# det\n")
        repo_fixture.git(work, "branch", "-q", "-D", "scratch")
        detached = os.path.join(self.tmp, "d")
        repo_fixture.git(work, "worktree", "add", "-q", "--detach", detached, sha)

        pending, _, run = self._items(work)

        self.assertEqual([item.title for item in pending], ["det"])
        self.assertEqual(pending[0].lines, [detached + "  tracked  tasks 0/0", "ref " + sha])
        self.assertEqual(pending[0].date, self._date(work, sha))
        self.assertEqual(run.errors, [])

    def test_date_is_oldest_commit_compared_as_datetimes(self) -> None:
        work = self._repo()
        repo_fixture.git(work, "switch", "-q", "-c", "topic")
        # Linear history listed newest first: z, y, x. y is the oldest instant
        # (06:00Z) but neither the first line, the last line nor the smallest
        # string ("...T07:00:00+00:00", x).
        self._commit_at(work, "openspec/changes/baz/x.md", "2026-10-01T07:00:00+00:00")
        self._commit_at(work, "openspec/changes/baz/y.md", "2026-10-01T10:00:00+04:00")
        self._commit_at(work, "openspec/changes/baz/z.md", "2026-10-01T08:00:00+00:00")
        repo_fixture.git(work, "switch", "-q", "main")

        pending, _, run = self._items(work)

        self.assertEqual([(item.title, item.date) for item in pending], [("baz", "2026-10-01T10:00:00+04:00")])
        self.assertEqual(run.errors, [])

    def test_non_ascii_change_name_is_read_unquoted(self) -> None:
        work = self._repo()
        name = "\N{GEORGIAN LETTER CAN}\N{GEORGIAN LETTER VIN}\N{GEORGIAN LETTER LAS}"
        self._commit_on(work, "topic", "openspec/changes/" + name + "/proposal.md", "# change\n")
        run = model.Run()

        self.assertEqual(openspec.change_dirs_in_tree(work, "topic", run), [name])
        pending, _, run = self._items(work, run)
        self.assertEqual([item.title for item in pending], [name])
        self.assertIsNotNone(pending[0].date)
        self.assertEqual(run.errors, [])

    def test_ref_reads_do_not_depend_on_the_directory_given(self) -> None:
        work = self._repo()
        repo_fixture.commit(work, "sub/keep.txt", "keep\n", "Add sub")
        repo_fixture.git(work, "push", "-q", "origin", "main")
        sha = self._commit_on(work, "topic", "openspec/changes/baz/proposal.md", "# baz\n")
        sub = os.path.join(work, "sub")
        run = model.Run()
        checkouts, tips, base = self._state(work, run)

        self.assertEqual(openspec.archived_names(sub, base, run), {"foo"})
        self.assertEqual(openspec.change_dirs_in_tree(sub, "topic", run), ["baz"])
        pending, _ = openspec.openspec_items(sub, checkouts, tips, base, run)
        self.assertEqual([(item.title, item.date) for item in pending], [("baz", self._date(work, sha))])
        self.assertEqual(run.errors, [])

    def test_repo_without_openspec_has_no_items(self) -> None:
        work = repo_fixture.make_repo(self.tmp)["work"]
        repo_fixture.git(work, "switch", "-q", "-c", "topic")
        repo_fixture.commit(work, "topic.txt", "topic\n", "Add topic")
        repo_fixture.git(work, "switch", "-q", "main")
        repo_fixture.git(work, "worktree", "add", "-q", os.path.join(self.tmp, "wt"), "topic")

        pending, stale, run = self._items(work)

        self.assertEqual((pending, stale), ([], []))
        self.assertEqual(run.errors, [])
        self.assertIs(run.complete, True)

    # Sources that cannot be read: recorded, and the run continues.

    def test_failing_ref_reads_are_recorded_and_the_run_continues(self) -> None:
        work = self._repo()
        self._write(work, "openspec/changes/bar/tasks.md", "- [ ] one\n")
        run = model.Run()
        checkouts, _, _ = self._state(work, run)
        missing = "0" * 40
        ghost = model.Tip(missing, ["ghost"], "not", 1, "", "", None)

        pending, stale = openspec.openspec_items(work, checkouts, [ghost], model.Base("origin/gone", "override"), run)

        self.assertEqual([item.title for item in pending], ["bar"])
        self.assertEqual(stale, [])
        self.assertEqual(len(run.errors), 2)
        prefixes = [
            "git ls-tree -d --name-only -z --full-tree " + missing + " openspec/changes/: ",
            "git ls-tree -d --name-only -z --full-tree origin/gone openspec/changes/archive/: ",
        ]
        for error, prefix in zip(run.errors, prefixes, strict=True):
            self.assertTrue(error.startswith(prefix), error)
            self.assertGreater(len(error), len(prefix))
        self.assertIs(run.complete, False)

    def test_failing_status_reads_unknown_and_is_recorded(self) -> None:
        work = self._repo()
        self._write(work, "openspec/changes/bar/tasks.md", "- [ ] one\n")
        run = model.Run()
        checkout = self._main_checkout(work, run)

        def failing_status(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            if "status" in argv:
                return 128, "", "fatal: index file corrupt\n"
            return model.default_runner(argv, cwd)

        rows = openspec.change_dirs_in_checkout(checkout, run, failing_status)

        self.assertEqual(rows, [("bar", "unknown", 0, 1)])
        self.assertEqual(
            run.errors,
            ["git --no-optional-locks status --porcelain=v1 -z -- :(top,literal)openspec/changes/bar: fatal: index file corrupt"],
        )
        self.assertIs(run.complete, False)

    def test_failing_date_read_is_recorded(self) -> None:
        work = self._repo()
        sha = self._commit_on(work, "topic", "openspec/changes/baz/proposal.md", "# baz\n")
        run = model.Run()
        checkouts, tips, base = self._state(work, run)

        def failing_rev_list(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            if "rev-list" in argv:
                return 128, "", "fatal: bad object\n"
            return model.default_runner(argv, cwd)

        pending, _ = openspec.openspec_items(work, checkouts, tips, base, run, failing_rev_list)

        self.assertEqual([(item.title, item.lines, item.date) for item in pending], [("baz", ["ref topic"], None)])
        self.assertEqual(
            run.errors,
            ["git rev-list --no-commit-header --format=%cI " + sha + " -- :(top,literal)openspec/changes/baz: fatal: bad object"],
        )
        self.assertIs(run.complete, False)

    @unittest.skipIf(os.geteuid() == 0, "root reads a file whatever its mode")
    def test_unreadable_tasks_file_is_recorded(self) -> None:
        work = self._repo()
        path = os.path.join(work, "openspec/changes/bar/tasks.md")
        self._write(work, "openspec/changes/bar/tasks.md", "- [ ] one\n")
        os.chmod(path, 0)
        self.addCleanup(os.chmod, path, 0o644)
        run = model.Run()

        rows = openspec.change_dirs_in_checkout(self._main_checkout(work, run), run)

        self.assertEqual(rows, [("bar", "untracked", 0, 0)])
        self.assertEqual(run.errors, ["read " + path + ": Permission denied"])
        self.assertIs(run.complete, False)

    @unittest.skipIf(os.geteuid() == 0, "root reads a directory whatever its mode")
    def test_unreadable_changes_directory_is_recorded(self) -> None:
        work = self._repo()
        changes = os.path.join(work, "openspec/changes")
        os.chmod(changes, 0)
        self.addCleanup(os.chmod, changes, 0o755)
        run = model.Run()

        rows = openspec.change_dirs_in_checkout(self._main_checkout(work, run), run)

        self.assertEqual(rows, [])
        self.assertEqual(run.errors, ["read " + changes + ": Permission denied"])
        self.assertIs(run.complete, False)

