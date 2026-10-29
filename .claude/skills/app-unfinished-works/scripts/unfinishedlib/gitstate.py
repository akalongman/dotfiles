"""Repository discovery: git calls, checkouts, remotes and the integration base."""

import sys

from scripts.unfinishedlib import model
from scripts.unfinishedlib.model import Base, Checkout, Remotes, Run, Runner

# Remotes the inventory covers, in report order.
INCLUDED_REMOTES = ("origin", "upstream")

# Branch names probed for a base when the remote has no HEAD, in order.
BASE_NAMES = ("main", "master", "dev")


def try_git(repo: str, *args: str, runner: Runner = model.default_runner) -> tuple[int, str, str]:
    """Run `git -C <repo> <args>` and return its exit code and output.

    Records nothing: for probes and yes/no commands whose non-zero exit is an
    answer, not a failure.
    """
    return runner(["git", "-C", repo, *args], None)


def run_git(repo: str, *args: str, run: Run, runner: Runner = model.default_runner) -> str:
    """Run `git -C <repo> <args>` and return its stdout.

    A non-zero exit appends `git <args>: <stderr first line>` to run.errors,
    marks the run incomplete and returns "", so the caller carries on.
    """
    code, out, err = try_git(repo, *args, runner=runner)
    if code != 0:
        run.errors.append("git " + " ".join(args) + ": " + _first_line(err, code))
        run.complete = False
        return ""
    return out


def common_dir(path: str, runner: Runner = model.default_runner) -> str:
    """Return the absolute git common dir of the repository holding path.

    Not being inside a repository is the one fatal condition: a one-line
    message goes to stderr and the process exits with status 2.
    """
    code, out, err = try_git(path, "rev-parse", "--path-format=absolute", "--git-common-dir", runner=runner)
    found = out.strip()
    if code != 0 or not found:
        print("unfinished: no git repository at " + path + ": " + _first_line(err, code), file=sys.stderr)
        raise SystemExit(2)
    return found


def worktrees(repo: str, run: Run, runner: Runner = model.default_runner) -> list[Checkout]:
    """List the main checkout and every registered worktree, main first.

    Reads `git worktree list --porcelain -z` (NUL-separated, so a path may
    hold any character). A `detached` or `bare` entry has branch None; a
    `prunable` entry, whose directory is gone, has present False and
    records `worktree <path>: directory is gone` as an error.
    """
    out = run_git(repo, "worktree", "list", "--porcelain", "-z", run=run, runner=runner)
    checkouts: list[Checkout] = []
    fields: dict[str, str] = {}
    for line in out.split("\0"):
        if line:
            key, _, value = line.partition(" ")
            fields[key] = value
            continue
        if "worktree" in fields:
            checkouts.append(_checkout(fields, is_main=not checkouts))
        fields = {}
    if "worktree" in fields:
        checkouts.append(_checkout(fields, is_main=not checkouts))
    for checkout in checkouts:
        if not checkout.present:
            run.errors.append("worktree " + checkout.path + ": directory is gone")
            run.complete = False
    return checkouts


def remotes(repo: str, run: Run, runner: Runner = model.default_runner) -> Remotes:
    """Return the included remotes and the canonical one (None without any)."""
    names = run_git(repo, "remote", run=run, runner=runner).split()
    included = [name for name in INCLUDED_REMOTES if name in names]
    canonical: str | None = None
    if "upstream" in included:
        canonical = "upstream"
    elif "origin" in included:
        canonical = "origin"
    return Remotes(included, canonical)


def resolve_base(
    repo: str,
    remotes: Remotes,
    override: str | None,
    run: Run,
    runner: Runner = model.default_runner,
) -> Base:
    """Choose the integration base that "merged" is judged against.

    An override is the base when it resolves; when it does not, the base is
    unknown and the run records the error (no automatic fallback). With an
    included remote, the canonical remote's HEAD, else the first of its main,
    master, dev; with no included remote, the first local main, master, dev.
    Nothing else resolving leaves the base unknown, which is not an error.
    """
    if override is not None:
        if _resolves(repo, override, runner):
            return Base(override, "override")
        run.errors.append("--base " + override + ": does not resolve to a commit")
        run.complete = False
        return Base(None, "unknown")
    canonical = remotes.canonical
    if canonical is not None:
        code, out, _ = try_git(repo, "symbolic-ref", "refs/remotes/" + canonical + "/HEAD", runner=runner)
        target = out.strip()
        prefix = "refs/remotes/"
        if code == 0 and target.startswith(prefix):
            ref = target[len(prefix):]
            if _resolves(repo, ref, runner):
                return Base(ref, "remote-head")
        for name in BASE_NAMES:
            ref = canonical + "/" + name
            if _resolves(repo, ref, runner):
                return Base(ref, "remote-name")
        return Base(None, "unknown")
    for name in BASE_NAMES:
        if _resolves(repo, name, runner):
            return Base(name, "local-name")
    return Base(None, "unknown")


def _resolves(repo: str, ref: str, runner: Runner) -> bool:
    # A leading dash would reach rev-parse as an option, so it never names a ref.
    if ref.startswith("-"):
        return False
    code, _, _ = try_git(repo, "rev-parse", "--verify", "--quiet", ref, runner=runner)
    return code == 0


def _checkout(fields: dict[str, str], *, is_main: bool) -> Checkout:
    branch: str | None = None
    if "branch" in fields:
        branch = fields["branch"].removeprefix("refs/heads/")
    return Checkout(
        path=fields["worktree"],
        branch=branch,
        head=fields.get("HEAD", ""),
        is_main=is_main,
        present="prunable" not in fields,
    )


def _first_line(text: str, code: int) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return "exit " + str(code)
