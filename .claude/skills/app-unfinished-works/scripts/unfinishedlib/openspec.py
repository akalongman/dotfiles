"""Pending and stale OpenSpec changes across checkouts and branch tips.

A change is a directory under openspec/changes/ outside archive/, seen in a
present checkout's filesystem or in the tree of a tip the base has not
merged. It is pending unless the base's openspec/changes/archive/ holds a
directory named <YYYY-MM-DD>-<change>, the full change name after the date
prefix; an archived change still present somewhere is a stale copy. A change
seen in several places is one item listing every place. Every git call reads
only, and every file is opened for reading.
"""

import os
import re
from dataclasses import dataclass
from datetime import datetime

from scripts.unfinishedlib import gitstate, model
from scripts.unfinishedlib.model import Base, Checkout, Item, Run, Runner, Tip

CHANGES_DIR = "openspec/changes"
ARCHIVE = "archive"

# Task lines of a tasks.md, at the start of a line.
_DONE = re.compile(r"^- \[[xX]\]", re.MULTILINE)
_OPEN = re.compile(r"^- \[ \]", re.MULTILINE)

# An archive entry: an ASCII date, a dash, then the full change name.
_ARCHIVED = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}-(.+)", re.DOTALL)


@dataclass
class _Place:
    """Where a change was seen: its report lines, and where its date is read.

    rev is "" when the place has no commit to read (an unborn HEAD).
    """

    lines: list[str]
    cwd: str
    rev: str


def task_counts(text: str) -> tuple[int, int]:
    """Count the done (`- [x]`, either case) and open (`- [ ]`) task lines: (done, open)."""
    return len(_DONE.findall(text)), len(_OPEN.findall(text))


def archived_names(repo: str, base: Base, run: Run, runner: Runner = model.default_runner) -> set[str]:
    """Return the change names the base's archive holds, date prefix stripped.

    Only a directory named <YYYY-MM-DD>-<name> archives a change; an entry
    without the prefix archives nothing. Empty when the base is unknown.
    """
    if base.ref is None:
        return set()
    names: set[str] = set()
    for entry in _tree_dirs(repo, base.ref, CHANGES_DIR + "/" + ARCHIVE + "/", run, runner):
        archived = _ARCHIVED.fullmatch(entry)
        if archived is not None:
            names.add(archived.group(1))
    return names


def change_dirs_in_tree(repo: str, ref: str, run: Run, runner: Runner = model.default_runner) -> list[str]:
    """Return the change directory names in ref's tree, archive excluded, in tree order."""
    return [name for name in _tree_dirs(repo, ref, CHANGES_DIR + "/", run, runner) if name != ARCHIVE]


def change_dirs_in_checkout(
    checkout: Checkout,
    run: Run,
    runner: Runner = model.default_runner,
) -> list[tuple[str, str, int, int]]:
    """List the changes in one checkout's filesystem: (name, status, done, open).

    status is tracked (git status names nothing under the directory),
    untracked (any `??` entry), modified (any other entry), or unknown when
    git status fails, which run_git records. Counts come from the change's
    tasks.md, (0, 0) when it is absent; an unreadable tasks.md or changes
    directory is recorded. A gone checkout, a bare entry, or a checkout
    without openspec/changes/ gives []. Names are sorted.
    """
    if not checkout.present or not checkout.head:
        return []
    changes = os.path.join(checkout.path, CHANGES_DIR)
    try:
        with os.scandir(changes) as entries:
            names = sorted(entry.name for entry in entries if entry.name != ARCHIVE and entry.is_dir())
    except (FileNotFoundError, NotADirectoryError):
        return []
    except OSError as exc:
        _record_unreadable(run, changes, exc)
        return []
    rows: list[tuple[str, str, int, int]] = []
    for name in names:
        status = _checkout_status(checkout.path, name, run, runner)
        done, open_ = _tasks_in(os.path.join(changes, name, "tasks.md"), run)
        rows.append((name, status, done, open_))
    return rows


def openspec_items(
    repo: str,
    checkouts: list[Checkout],
    tips: list[Tip],
    base: Base,
    run: Run,
    runner: Runner = model.default_runner,
) -> tuple[list[Item], list[Item]]:
    """Return (pending, stale): one item per change name seen anywhere.

    Places, in order: every present checkout in checkouts order
    (`<path>  <status>  tasks <done>/<total>`), then every tip the base has
    not merged, in tips order, read by its SHA (`ref <r>` for each of its
    refs, `ref <sha>` for a detached tip no ref names). date is the oldest
    committer date of the commits touching the change directory in the first
    place that has one, None when none has. A change the base's archive holds
    is stale, its lines led by `archived on <base>`; any other is pending.
    """
    places: dict[str, list[_Place]] = {}
    for checkout in checkouts:
        rev = "" if _unborn(checkout.head) else checkout.head
        for name, status, done, open_ in change_dirs_in_checkout(checkout, run, runner):
            line = checkout.path + "  " + status + "  tasks " + str(done) + "/" + str(done + open_)
            places.setdefault(name, []).append(_Place([line], checkout.path, rev))
    for tip in tips:
        if tip.integration == "merged":
            continue
        lines = ["ref " + ref for ref in tip.refs] or ["ref " + tip.sha]
        for name in change_dirs_in_tree(repo, tip.sha, run, runner):
            places.setdefault(name, []).append(_Place(lines, repo, tip.sha))
    archived = archived_names(repo, base, run, runner)
    pending: list[Item] = []
    stale: list[Item] = []
    for name, seen in places.items():
        lines = [line for place in seen for line in place.lines]
        date = _first_date(name, seen, run, runner)
        if name in archived:
            stale.append(_item("openspec-stale", name, ["archived on " + (base.ref or "")] + lines, date))
        else:
            pending.append(_item("openspec-pending", name, lines, date))
    return pending, stale


def _item(kind: str, name: str, lines: list[str], date: str | None) -> Item:
    return Item(
        kind=kind,
        title=name,
        certainty="certain",
        lines=lines,
        paths=[CHANGES_DIR + "/" + name],
        names=[name],
        date=date,
        sha=None,
        sessions=[],
    )


def _pathspec(name: str) -> str:
    # top: from the repository root whatever the cwd; literal: a name holding
    # a glob character (a*) never matches a sibling (ab).
    return ":(top,literal)" + CHANGES_DIR + "/" + name


def _tree_dirs(repo: str, ref: str, prefix: str, run: Run, runner: Runner) -> list[str]:
    """Basenames of the directories directly under prefix (ending in /) in ref's tree.

    -z keeps a non-ASCII name unquoted; --full-tree reads prefix from the
    repository root whatever directory repo names. A path the tree lacks
    lists nothing and exits 0; a failing read is recorded by run_git.
    """
    out = gitstate.run_git(repo, "ls-tree", "-d", "--name-only", "-z", "--full-tree", ref, prefix, run=run, runner=runner)
    return [path[len(prefix):] for path in out.split("\0") if path.startswith(prefix)]


def _checkout_status(path: str, name: str, run: Run, runner: Runner) -> str:
    before = len(run.errors)
    out = gitstate.run_git(
        path,
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "-z",
        "--",
        _pathspec(name),
        run=run,
        runner=runner,
    )
    if len(run.errors) > before:
        return "unknown"
    codes: list[str] = []
    records = iter(out.split("\0"))
    for record in records:
        # Each record is "XY <path>"; the final NUL leaves one empty string.
        if not record:
            continue
        code = record[:2]
        if "R" in code or "C" in code:
            next(records, None)
        codes.append(code)
    if not codes:
        return "tracked"
    if "??" in codes:
        return "untracked"
    return "modified"


def _tasks_in(path: str, run: Run) -> tuple[int, int]:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except FileNotFoundError:
        return 0, 0
    except OSError as exc:
        _record_unreadable(run, path, exc)
        return 0, 0
    return task_counts(text)


def _first_date(name: str, places: list[_Place], run: Run, runner: Runner) -> str | None:
    """The oldest committer date touching the change in the first place that has a commit.

    rev-list is plumbing, so log.showSignature and similar porcelain settings
    cannot add lines to the output.
    """
    for place in places:
        if not place.rev:
            continue
        out = gitstate.run_git(
            place.cwd,
            "rev-list",
            "--no-commit-header",
            "--format=%cI",
            place.rev,
            "--",
            _pathspec(name),
            run=run,
            runner=runner,
        )
        oldest = _oldest(out.split("\n"))
        if oldest is not None:
            return oldest
    return None


def _oldest(stamps: list[str]) -> str | None:
    """The stamp of the earliest instant, compared as aware datetimes, never as strings."""
    oldest: str | None = None
    oldest_at: datetime | None = None
    for stamp in stamps:
        if not stamp:
            continue
        try:
            at = datetime.fromisoformat(stamp)
        except ValueError:
            continue
        if at.tzinfo is None:
            continue
        if oldest_at is None or at < oldest_at:
            oldest, oldest_at = stamp, at
    return oldest


def _unborn(head: str) -> bool:
    # git worktree list prints an all-zero HEAD for a branch with no commit.
    return not head.strip("0")


def _record_unreadable(run: Run, path: str, exc: OSError) -> None:
    run.errors.append("read " + path + ": " + (exc.strerror or str(exc)))
    run.complete = False
