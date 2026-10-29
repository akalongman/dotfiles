"""Shared types: the run record, the command runner, and the inventory items."""

import subprocess
from collections.abc import Callable
from dataclasses import dataclass, field

# Every external command goes through a runner: (argv, cwd) to
# (returncode, stdout, stderr). Tests inject fakes of this type.
Runner = Callable[[list[str], str | None], tuple[int, str, str]]


def default_runner(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
    """Run argv in cwd and capture its output; never raises for a failed start.

    A missing binary returns (127, "", "<name>: command not found"). Any other
    failure to start (an unusable cwd, a file that is not executable) returns
    126 with the operating system's reason. Output is decoded as UTF-8 with
    replacement, so a stray byte in a file name or commit message never aborts
    the run. Standard input is closed, so no command can wait for an answer.
    """
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except FileNotFoundError as exc:
        if exc.filename == argv[0]:
            return 127, "", argv[0] + ": command not found"
        return 126, "", str(exc.filename) + ": " + str(exc.strerror)
    except OSError as exc:
        return 126, "", str(exc.filename) + ": " + str(exc.strerror)
    return completed.returncode, completed.stdout, completed.stderr


@dataclass
class Run:
    """State every gatherer shares: errors, completeness, and footer notes.

    A source that cannot be read appends one line to errors and sets complete
    to False; notes are footer lines that are not errors.
    """

    errors: list[str] = field(default_factory=list)
    complete: bool = True
    notes: list[str] = field(default_factory=list)


@dataclass
class Checkout:
    """One entry of `git worktree list`: the main checkout or a worktree.

    branch is the short name (no refs/heads/), None when detached or bare;
    present is False when git reports the worktree prunable (its directory
    is gone).
    """

    path: str
    branch: str | None
    head: str
    is_main: bool
    present: bool


@dataclass
class Remotes:
    """The included remotes (origin, then upstream) and the canonical one."""

    included: list[str]
    canonical: str | None


@dataclass
class Base:
    """The integration base and how it was chosen.

    source is one of override, remote-head, remote-name, local-name, unknown;
    ref is None exactly when source is unknown.
    """

    ref: str | None
    source: str


@dataclass
class Tip:
    """One distinct commit at the tip of a branch, a remote branch or a detached HEAD.

    refs are short names (feature/x, origin/feature/x) in ref order, local
    first, and empty for a detached HEAD that no ref points at. integration is
    merged, likely, not, merges-only or unknown (no base, or git failed);
    ahead counts the tip's commits the base lacks. last_date is the tip
    commit's committer date (ISO 8601 with offset) and author_email its author
    email, both "" when git could not read them. worktree is the present
    checkout whose HEAD is the tip, a linked worktree before the main checkout.
    """

    sha: str
    refs: list[str]
    integration: str
    ahead: int
    last_date: str
    author_email: str
    worktree: str | None


@dataclass
class Association:
    """One session tied to an item, with the evidence that ties it."""

    session_id: str
    evidence: str
    token: str
    ts: str
    slot: str
    checkout: str
    last_request: str
    live: str | None


@dataclass
class Item:
    """One unit of unfinished work in the inventory.

    paths are relative to a checkout root; date is ISO 8601 with an offset;
    attrs holds kind-specific facts that later stages read instead of
    parsing lines.
    """

    kind: str
    title: str
    certainty: str
    lines: list[str]
    paths: list[str]
    names: list[str]
    date: str | None
    sha: str | None
    sessions: list["Association"]
    attrs: dict[str, str] = field(default_factory=dict)


@dataclass
class Evidence:
    """One event of a session naming an item.

    cls is work, request, mention or lookup, ranked in that order; token is
    the name or item path that matched; ts is the matching record's
    timestamp as the transcript gives it (UTC with a Z).
    """

    cls: str
    token: str
    ts: str


@dataclass
class Session:
    """One transcript that belongs to the repository, read from its active chain.

    id is the transcript's file stem, path its file, mtime its modification
    time. cwds maps each cwd seen to the gitBranch last seen with it (None
    when none was), and cwd_counts counts the chain's records per cwd.
    branch_counts counts the chain's records per cwd and gitBranch, each
    cwd's branches in the order first seen; a record without a branch adds
    nothing, so a cwd seen only without one is absent. first_ts and last_ts are the earliest and latest timestamps, compared as
    instants. last_request is the last genuine user request and
    last_assistant the last assistant text, both "" when there is none.
    account_uuid comes from the bridge-session record and slot is the slot
    it maps to, else "unknown"; live is set by the liveness stage. Every
    field but account_uuid and mtime is read from the active chain.
    """

    id: str
    path: str
    mtime: float
    cwds: dict[str, str | None]
    first_ts: str
    last_ts: str
    user_turns: int
    last_request: str
    last_assistant: str
    ended_on_question: bool
    entrypoint: str | None
    account_uuid: str | None
    slot: str
    live: str | None
    ran_skill: bool
    evidence: list[Evidence]
    cwd_counts: dict[str, int] = field(default_factory=dict)
    branch_counts: dict[str, dict[str, int]] = field(default_factory=dict)


@dataclass
class LiveSession:
    """One Claude Code session running now, as one source reports it.

    source is claude-sessions, registry or process. session_id is None when
    the source does not name it (a process with no registry row yet, or an
    older claude-sessions); cwd is where the process runs, which need not
    be a cwd its transcript records. slot is the slot number as a string,
    else "unknown"; state is working, waiting or idle from the registry
    status, unknown for a process row, whose name is "" too.
    """

    session_id: str | None
    pid: int
    cwd: str
    slot: str
    name: str
    state: str
    source: str


@dataclass
class MergeRequest:
    """One open or draft merge request (a GitLab MR or a GitHub pull request).

    number is the forge's per-project number (GitLab iid); state is open or
    draft. source_project is the source project's id on GitLab (as a
    string) and its owner/name on GitHub, "" when the forge no longer names
    it (a deleted fork). head_sha is the source branch's head commit, ""
    when the forge has not computed it yet.
    """

    number: int
    title: str
    state: str
    source_project: str
    source_branch: str
    head_sha: str
    target_branch: str
    author: str
    url: str
