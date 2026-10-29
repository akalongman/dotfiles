"""The inventory: every source read once and turned into report items.

gather runs the stages in the spec's order: the repository (common dir,
remotes, an optional fetch, checkouts, the base), the git-state and OpenSpec
items, the names the transcripts are searched for, the live sessions, the
transcripts, the liveness marks, the removed worktrees, the associations,
the --mine filter, the question sessions and the parked-note count. The
item builders are pure functions over the readers' values. Apart from
--fetch, nothing here writes, and every file is opened for reading.
"""

import argparse
import glob
import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from scripts.unfinishedlib import associate, gitstate, live, openspec, transcripts
from scripts.unfinishedlib.model import (
    Base,
    Checkout,
    Item,
    LiveSession,
    Remotes,
    Run,
    Runner,
    Session,
    Tip,
)

# The item kinds, in report order.
KINDS = (
    "openspec-pending",
    "tip",
    "unpublished",
    "dirty",
    "stash",
    "removed-worktree",
    "merge-request",
    "openspec-stale",
)
OUT_OF_REACH_NOTE = "worktrees created outside .worktrees/ and since removed are out of reach"
# The laterbox queue file at the main checkout's root, unless laterbox.file names another.
DEFAULT_QUEUE_FILE = "LATER.local.md"
QUEUE_LINE = "- [ ]"
# A tip's certainty from its integration; anything else (unknown) is unknown.
_CERTAINTY = {"not": "certain", "likely": "likely", "merges-only": "likely"}
_CERTAINTY_ORDER = ("certain", "likely", "unknown")
# Characters a plain laterbox.file name never holds (the laterbox README).
_NOT_IN_A_FILE_NAME = frozenset("/\\*?[")


@dataclass
class Inventory:
    """Everything the report shows.

    items_by_kind maps each of KINDS to its items; live holds the live
    sessions in this repository; questions the offline sessions that ended
    on a question; parked the open parked notes (None without a queue file);
    meta the run's facts for the footer and the JSON. sessions (every
    session the transcripts yielded) and checkouts serve the text renderer
    and never reach the JSON.
    """

    items_by_kind: dict[str, list[Item]]
    live: list[LiveSession]
    questions: list[Session]
    parked: int | None
    meta: dict[str, Any]
    sessions: list[Session] = field(default_factory=list)
    checkouts: list[Checkout] = field(default_factory=list)

    def items(self) -> list[Item]:
        """Every item, kinds in report order."""
        return [item for kind in KINDS for item in self.items_by_kind.get(kind, [])]


def gather(args: argparse.Namespace, *, home: str, proc_root: str, runner: Runner, now: float) -> Inventory:
    """Read every source for the repository at args.root (else the cwd) into an Inventory.

    Only a path outside any repository is fatal (gitstate.common_dir exits
    with status 2); every other failure is one line in meta["errors"] and
    meta["complete"] False, and the run carries on.
    """
    run = Run()
    run.notes.append(OUT_OF_REACH_NOTE)
    root = os.path.abspath(args.root) if args.root else os.getcwd()
    gitstate.common_dir(root, runner=runner)
    found = gitstate.remotes(root, run, runner)
    if args.fetch:
        for name in found.included:
            gitstate.run_git(root, "fetch", "--prune", name, run=run, runner=runner)
    checkouts = gitstate.worktrees(root, run, runner)
    main_path = main_path_of(checkouts, root)
    repo = main_path
    base = gitstate.resolve_base(repo, found, args.base, run, runner)
    tips = gitstate.branch_tips(repo, found, checkouts, base, run, runner)
    divergences = gitstate.divergence(repo, tips, runner, run=run)
    pending, stale = openspec.openspec_items(repo, checkouts, tips, base, run, runner)
    items_by_kind: dict[str, list[Item]] = {kind: [] for kind in KINDS}
    items_by_kind["openspec-pending"] = pending
    items_by_kind["tip"] = tip_items(tips, found, base, divergences)
    items_by_kind["unpublished"] = unpublished_items(gitstate.unpublished(repo, run, runner), tips)
    for checkout in checkouts:
        item = dirty_item(checkout, gitstate.dirty(checkout, run, runner))
        if item is not None:
            items_by_kind["dirty"].append(item)
    items_by_kind["stash"] = stash_items(gitstate.stashes(repo, run, runner))
    items_by_kind["openspec-stale"] = stale
    branch_names = list(dict.fromkeys(gitstate.strip_remote(ref, found) for tip in tips for ref in tip.refs))
    every = [item for kind in KINDS for item in items_by_kind[kind]]
    names, paths = associate.build_names(every, branch_names)
    matcher = transcripts.NameMatcher(names, paths)

    roots = slot_roots(home)
    live_rows = live.live_sessions(roots, proc_root, runner, run)
    sessions, scanned = read_transcripts(roots, main_path, checkouts, matcher, run)
    run.notes.extend(live.mark_live(sessions, live_rows, checkouts, main_path, now))
    removed = removed_worktrees(sessions, checkouts, tips, found, main_path)
    associate.build_names(removed, branch_names)
    items_by_kind["removed-worktree"] = removed
    inv = Inventory(
        items_by_kind=items_by_kind,
        live=live.in_repository(live_rows, checkouts, main_path),
        questions=[] if args.no_questions else associate.question_sessions(sessions, args.since, now),
        parked=None,
        meta={},
        sessions=sessions,
        checkouts=checkouts,
    )
    associate.associate(inv.items(), sessions, checkouts=checkouts, main_path=main_path)
    if args.mine:
        associate.mine_filter(inv, _user_email(repo, runner), _local_branches(repo, run, runner))
    for kind in KINDS:
        items_by_kind[kind] = sort_items(items_by_kind[kind])
    inv.parked = parked_count(home, main_path, run)
    fetch_age = gitstate.fetch_age_seconds(repo, runner=runner)
    inv.meta = {
        "complete": run.complete,
        "errors": run.errors,
        "notes": run.notes,
        "remote": found.canonical,
        "base": base.ref,
        "base_source": base.source,
        "fetch_age_seconds": fetch_age,
        "transcripts": scanned,
        "question_window_days": None if args.no_questions else args.since,
    }
    return inv


def main_path_of(checkouts: list[Checkout], root: str) -> str:
    """The main checkout's path, or root when git listed no checkout."""
    for checkout in checkouts:
        if checkout.is_main:
            return checkout.path
    return root


def slot_roots(home: str) -> list[str]:
    """<home>/.claude, then every directory <home>/.claude<digit>..., sorted by name."""
    first = os.path.join(home, ".claude")
    others = sorted(path for path in glob.glob(glob.escape(first) + "[0-9]*") if os.path.isdir(path))
    return [first, *others]


def read_transcripts(
    slot_roots: list[str],
    main_path: str,
    checkouts: list[Checkout],
    matcher: transcripts.NameMatcher,
    run: Run,
) -> tuple[list[Session], dict[str, Any]]:
    """Parse every top-level .jsonl of the candidate folders: (sessions, scan facts).

    The folders are those of every slot's projects root that may hold this
    repository's transcripts; the present checkouts are the roots for
    membership and path matching (parse_transcript adds <main>/.worktrees/),
    so a gone worktree outside .worktrees/ is out of reach. The facts are
    count and bytes over every file read, oldest the earliest first
    timestamp and newest the latest last timestamp of the sessions found
    (None without any). A folder that cannot be listed is recorded.
    """
    accounts = transcripts.slot_accounts(slot_roots)
    projects = [os.path.join(root, "projects") for root in slot_roots]
    folders = transcripts.candidate_folders(projects, main_path, checkouts)
    roots = [checkout.path for checkout in checkouts if checkout.present] or [main_path]
    sessions: list[Session] = []
    count = 0
    size = 0
    for folder in folders:
        try:
            with os.scandir(folder) as entries:
                names = sorted(entry.name for entry in entries if entry.name.endswith(".jsonl") and entry.is_file())
        except OSError as exc:
            _record(run, "read " + folder + ": " + (exc.strerror or str(exc)))
            continue
        for name in names:
            path = os.path.join(folder, name)
            count += 1
            try:
                size += os.stat(path).st_size
            except OSError:
                # parse_transcript records the failed read.
                pass
            session = transcripts.parse_transcript(path, matcher, roots, main_path, accounts, run)
            if session is not None:
                sessions.append(session)
    oldest = _extreme([session.first_ts for session in sessions], latest=False)
    newest = _extreme([session.last_ts for session in sessions], latest=True)
    return sessions, {"count": count, "bytes": size, "oldest": oldest, "newest": newest}


def tip_items(tips: list[Tip], remotes: Remotes, base: Base, divergences: list[tuple[str, int, int, str]]) -> list[Item]:
    """One item per tip the base has not merged.

    certainty: certain for not, likely for likely and merges-only, unknown
    for unknown. names are every remote-stripped ref name n plus <r>/n for
    every included remote r. lines: the integration against the base, the
    last commit's date and author, `local <a> ahead, <b> behind <remote ref>`
    for each diverged name the tip carries, and the checkout holding it.
    attrs: author_email, integration, and worktree when a checkout holds it.
    """
    items: list[Item] = []
    for tip in tips:
        if tip.integration == "merged":
            continue
        branches = list(dict.fromkeys(gitstate.strip_remote(ref, remotes) for ref in tip.refs))
        names: list[str] = []
        for branch in branches:
            names.append(branch)
            names.extend(remote + "/" + branch for remote in remotes.included)
        lines = [_integration_line(tip, base), _last_commit_line(tip)]
        for name, ahead, behind, remote_ref in divergences:
            if name in branches:
                lines.append("local " + str(ahead) + " ahead, " + str(behind) + " behind " + remote_ref)
        attrs = {"author_email": tip.author_email, "integration": tip.integration}
        if tip.worktree:
            lines.append(tip.worktree + "  (checked out)")
            attrs["worktree"] = tip.worktree
        if tip.refs:
            title = ", ".join(tip.refs)
        else:
            title = "detached HEAD in " + (tip.worktree or tip.sha)
        items.append(
            Item(
                kind="tip",
                title=title,
                certainty=_CERTAINTY.get(tip.integration, "unknown"),
                lines=lines,
                paths=[],
                names=list(dict.fromkeys(names)),
                date=tip.last_date or None,
                sha=tip.sha,
                sessions=[],
                attrs=attrs,
            )
        )
    return items


def unpublished_items(rows: list[tuple[str, str, int]], tips: list[Tip]) -> list[Item]:
    """One item per row gitstate.unpublished gives, whether the base has merged the branch or not.

    date and sha are the branch tip's. A merged branch stays: when the base
    is a local ref, its commits may be on no remote.
    """
    tip_of = {ref: tip for tip in tips for ref in tip.refs}
    items: list[Item] = []
    for branch, state, count in rows:
        tip = tip_of.get(branch)
        if state == "ahead":
            line = _count(count, "commit") + " not on its upstream"
        elif state == "no-upstream":
            line = "no upstream: never pushed"
        else:
            line = "upstream gone: its remote branch no longer exists"
        items.append(
            Item(
                kind="unpublished",
                title=branch,
                certainty="certain",
                lines=[line],
                paths=[],
                names=[branch],
                date=(tip.last_date or None) if tip is not None else None,
                sha=tip.sha if tip is not None else None,
                sessions=[],
            )
        )
    return items


def dirty_item(checkout: Checkout, entries: list[tuple[str, str]]) -> Item | None:
    """The item for one checkout's changed paths, None when it has none.

    lines carry the counts only (staged, modified, conflicted, untracked);
    paths keep every path, relative to the checkout root, and attrs the
    checkout, which the renderer joins them to.
    """
    if not entries:
        return None
    staged = modified = conflicted = untracked = 0
    for code, _ in entries:
        index, work = code[:1], code[1:2]
        if code == "??":
            untracked += 1
        elif "U" in code or code in ("AA", "DD"):
            conflicted += 1
        else:
            staged += index not in (" ", "?", "!")
            modified += work not in (" ", "?", "!")
    parts = [
        str(number) + " " + label
        for number, label in ((staged, "staged"), (modified, "modified"), (conflicted, "conflicted"), (untracked, "untracked"))
        if number
    ]
    return Item(
        kind="dirty",
        title=checkout.path,
        certainty="certain",
        lines=[_count(len(entries), "changed path") + ": " + ", ".join(parts)],
        paths=[path for _, path in entries],
        names=[],
        date=None,
        sha=None,
        sessions=[],
        attrs={"checkout": checkout.path},
    )


def stash_items(entries: list[tuple[str, str, str, list[str]]]) -> list[Item]:
    """One item per stash entry; paths are its paths, relative to the main checkout."""
    items: list[Item] = []
    for ref, date_iso, message, paths in entries:
        items.append(
            Item(
                kind="stash",
                title=ref + ": " + message,
                certainty="certain",
                lines=[_count(len(paths), "path") + ", stashed " + local_minute(date_iso)],
                paths=list(paths),
                names=[],
                date=date_iso or None,
                sha=None,
                sessions=[],
            )
        )
    return items


def removed_worktrees(
    sessions: list[Session],
    checkouts: list[Checkout],
    tips: list[Tip],
    remotes: Remotes,
    main_path: str,
) -> list[Item]:
    """One item per removed worktree and branch whose tip the base has not merged.

    Each cwd of a session under <main>/.worktrees/<name>, normalised to
    <main>/.worktrees/<name>, that is not a present checkout and has a branch
    recorded is a trace. It becomes an item when some tip whose
    remote-stripped refs hold that branch is not merged; certainty is the
    strongest of those tips', date the newest of their last commit dates,
    names [branch]; the last session there carries its live or possibly live
    tag, so run it after live.mark_live. A merged or deleted branch gives nothing.
    """
    present = {os.path.normpath(checkout.path) for checkout in checkouts if checkout.present}
    worktrees = os.path.join(os.path.normpath(main_path), ".worktrees")
    traces: dict[tuple[str, str], list[Session]] = {}
    for session in sessions:
        for cwd, branch in session.cwds.items():
            path = os.path.normpath(cwd)
            if not branch or not path.startswith(worktrees + "/"):
                continue
            place = os.path.join(worktrees, path[len(worktrees) + 1 :].split("/", 1)[0])
            if place in present:
                continue
            seen = traces.setdefault((place, branch), [])
            if session not in seen:
                seen.append(session)
    items: list[Item] = []
    for (place, branch), seen in traces.items():
        open_tips = [
            tip
            for tip in tips
            if tip.integration != "merged" and branch in {gitstate.strip_remote(ref, remotes) for ref in tip.refs}
        ]
        if not open_tips:
            continue
        certainty = min((_CERTAINTY.get(tip.integration, "unknown") for tip in open_tips), key=_CERTAINTY_ORDER.index)
        last = max(seen, key=lambda session: (_epoch(session.last_ts), session.id))
        last_line = "last session there: " + last.id + ", " + local_minute(last.last_ts)
        if last.live:
            last_line += ", " + last.live
        refs = list(dict.fromkeys(ref for tip in open_tips for ref in tip.refs))
        items.append(
            Item(
                kind="removed-worktree",
                title=branch,
                certainty=certainty,
                lines=[
                    place + "  (no longer a checkout)",
                    "not integrated: " + ", ".join(refs),
                    last_line,
                ],
                paths=[],
                names=[branch],
                date=_extreme([tip.last_date for tip in open_tips], latest=True),
                sha=open_tips[0].sha,
                sessions=[],
                attrs={"worktree": place},
            )
        )
    return items


def parked_count(home: str, main_path: str, run: Run) -> int | None:
    """The open parked notes in the queue file at the main checkout's root.

    The file is laterbox.file from <home>/.claude/settings.json (top-level
    key "laterbox.file", else the nested laterbox.file) when it is one plain
    file name, else LATER.local.md; a setting or settings file that cannot
    be used adds a note. A line counts when its stripped text starts with
    `- [ ]`. None when the file is absent; an unreadable file is an error.
    """
    path = os.path.join(main_path, _queue_file(home, run))
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return sum(1 for line in handle if line.strip().startswith(QUEUE_LINE))
    except FileNotFoundError:
        return None
    except OSError as exc:
        _record(run, "read " + path + ": " + (exc.strerror or str(exc)))
        return None


def sort_items(items: list[Item]) -> list[Item]:
    """Items by date, oldest first; an absent or unparsable date sorts last, order kept on ties."""

    def key(item: Item) -> tuple[int, float]:
        at = associate.instant(item.date)
        return (1, 0.0) if at is None else (0, at.timestamp())

    return sorted(items, key=key)


def local_minute(stamp: str | None) -> str:
    """An ISO 8601 stamp as local time to the minute, `unknown date` when it does not parse."""
    at = associate.instant(stamp)
    if at is None:
        return "unknown date"
    return at.astimezone().strftime("%Y-%m-%d %H:%M")


def _integration_line(tip: Tip, base: Base) -> str:
    if base.ref is None:
        return "merged: unknown (no base)"
    ahead = _count(tip.ahead, "commit") + " ahead of " + base.ref
    if tip.integration == "not":
        return "not integrated: " + ahead
    if tip.integration == "likely":
        return "probably integrated, verify: every commit has a patch twin on " + base.ref + " (" + ahead + ")"
    if tip.integration == "merges-only":
        return "probably integrated, verify: only merge commits are missing from " + base.ref + " (" + ahead + ")"
    return "merged: unknown (git could not judge it against " + base.ref + ")"


def _last_commit_line(tip: Tip) -> str:
    when = local_minute(tip.last_date) if tip.last_date else "unknown date"
    return "last commit " + when + " by " + (tip.author_email or "unknown author")


def _queue_file(home: str, run: Run) -> str:
    settings = os.path.join(home, ".claude", "settings.json")
    try:
        with open(settings, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return DEFAULT_QUEUE_FILE
    except (OSError, ValueError) as exc:
        reason = exc.strerror if isinstance(exc, OSError) and exc.strerror else "not JSON"
        run.notes.append(settings + ": " + reason + ", so parked notes are read from " + DEFAULT_QUEUE_FILE)
        return DEFAULT_QUEUE_FILE
    if not isinstance(data, dict):
        run.notes.append(settings + ": not a JSON object, so parked notes are read from " + DEFAULT_QUEUE_FILE)
        return DEFAULT_QUEUE_FILE
    if "laterbox.file" in data:
        value = data["laterbox.file"]
    else:
        nested = data.get("laterbox")
        if not isinstance(nested, dict) or "file" not in nested:
            return DEFAULT_QUEUE_FILE
        value = nested["file"]
    if isinstance(value, str) and _plain_file_name(value):
        return value
    shown = "".join("?" if _control(char) else char for char in value) if isinstance(value, str) else json.dumps(value)
    run.notes.append(
        "laterbox.file is \"" + shown + "\", which is not a plain file name, so parked notes are read from "
        + DEFAULT_QUEUE_FILE
    )
    return DEFAULT_QUEUE_FILE


def _plain_file_name(name: str) -> bool:
    """laterbox's rule: not empty, not . or .., no / \\ * ? [, no control character, at most 255 bytes."""
    if name in ("", ".", ".."):
        return False
    if any(char in _NOT_IN_A_FILE_NAME or _control(char) for char in name):
        return False
    return len(name.encode("utf-8", errors="surrogatepass")) <= 255


def _control(char: str) -> bool:
    return ord(char) < 0x20 or ord(char) == 0x7F


def _user_email(repo: str, runner: Runner) -> str:
    """The repository's user.email, "" when none is set (a read-only probe)."""
    code, out, _ = gitstate.try_git(repo, "config", "--get", "user.email", runner=runner)
    return out.strip() if code == 0 else ""


def _local_branches(repo: str, run: Run, runner: Runner) -> set[str]:
    out = gitstate.run_git(repo, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads", run=run, runner=runner)
    return {line for line in out.split("\n") if line}


def _extreme(stamps: list[str], *, latest: bool) -> str | None:
    """The stamp of the earliest (or latest) instant among stamps, None when none parses."""
    best: tuple[datetime, str] | None = None
    for stamp in stamps:
        at = associate.instant(stamp)
        if at is None:
            continue
        if best is None or (at > best[0] if latest else at < best[0]):
            best = (at, stamp)
    return best[1] if best is not None else None


def _epoch(stamp: str) -> float:
    at = associate.instant(stamp)
    return at.timestamp() if at is not None else float("-inf")


def _count(number: int, word: str) -> str:
    return str(number) + " " + word + ("" if number == 1 else "s")


def _record(run: Run, line: str) -> None:
    run.errors.append(line)
    run.complete = False
