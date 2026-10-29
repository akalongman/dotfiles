"""Repository discovery and the git-state inventory.

Discovery: git calls, checkouts, remotes and the integration base. Inventory:
branch tips and their integration, divergence, unpublished commits, dirty
checkouts, stashes and the age of the last fetch. Every git call reads only.
"""

import os
import re
import sys
import time

from scripts.unfinishedlib import model
from scripts.unfinishedlib.model import Base, Checkout, Remotes, Run, Runner, Tip

# Remotes the inventory covers, in report order.
INCLUDED_REMOTES = ("origin", "upstream")

# Branch names probed for a base when the remote has no HEAD, in order.
BASE_NAMES = ("main", "master", "dev")

# Short names of remote branches start with one of these.
_REMOTE_PREFIXES = tuple(name + "/" for name in INCLUDED_REMOTES)

# A for-each-ref %(upstream:track) value with commits to publish. Plumbing
# prints it untranslated: "[ahead N]" or "[ahead N, behind M]".
_AHEAD = re.compile(r"\[ahead (\d+)(?:, behind \d+)?\]")


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
        _record(run, args, err, code)
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


def branch_tips(
    repo: str,
    remotes: Remotes,
    checkouts: list[Checkout],
    base: Base,
    run: Run,
    runner: Runner = model.default_runner,
) -> list[Tip]:
    """List every distinct tip commit with its refs and its integration.

    Tips are the local branches, the included remotes' branches (each remote's
    symbolic HEAD excluded) and the HEAD of every present detached checkout;
    refs at one SHA form one Tip. Short names come from the full refname, so
    a tag of the same name never turns feature/x into heads/feature/x.
    """
    refs_by_sha = _tip_refs(repo, remotes, run, runner)
    for checkout in checkouts:
        # A gone checkout and a bare entry (head "") have no HEAD to report.
        if checkout.present and checkout.branch is None and checkout.head:
            refs_by_sha.setdefault(checkout.head, [])
    facts = _commit_facts(repo, list(refs_by_sha), run, runner)
    tips: list[Tip] = []
    for sha, refs in refs_by_sha.items():
        integration, ahead = integration_of(repo, sha, base, run=run, runner=runner)
        last_date, author_email = facts.get(sha, ("", ""))
        tips.append(Tip(sha, refs, integration, ahead, last_date, author_email, _holding_checkout(sha, checkouts)))
    return tips


def integration_of(
    repo: str,
    sha: str,
    base: Base,
    *,
    run: Run,
    runner: Runner = model.default_runner,
) -> tuple[str, int]:
    """Judge one tip against the base: (integration, commits the base lacks).

    merged: the tip is an ancestor of the base. merges-only: every commit the
    base lacks is a merge. likely: each non-merge commit has a patch-id twin
    in the base (git cherry, which catches a cherry-pick or a one-commit
    squash). not: anything else. unknown: no base, or git failed; a failing
    ancestor probe is recorded here, a failing count or cherry by run_git.
    """
    if base.ref is None:
        return "unknown", 0
    probe = ("merge-base", "--is-ancestor", sha, base.ref)
    code, _, err = try_git(repo, *probe, runner=runner)
    if code == 0:
        return "merged", 0
    if code != 1:
        _record(run, probe, err, code)
        return "unknown", 0
    span = base.ref + ".." + sha
    ahead = _count(run_git(repo, "rev-list", "--count", span, run=run, runner=runner))
    if ahead is None:
        return "unknown", 0
    non_merges = _count(run_git(repo, "rev-list", "--no-merges", "--count", span, run=run, runner=runner))
    if non_merges is None:
        return "unknown", ahead
    if non_merges == 0:
        return "merges-only", ahead
    # git cherry skips merges, so with a non-merge commit ahead it prints at
    # least one line: empty output means it failed and run_git recorded it.
    cherry = run_git(repo, "cherry", base.ref, sha, run=run, runner=runner)
    if not cherry:
        return "unknown", ahead
    if any(line.startswith("+") for line in cherry.split("\n")):
        return "not", ahead
    return "likely", ahead


def divergence(
    repo: str,
    tips: list[Tip],
    runner: Runner = model.default_runner,
    *,
    run: Run | None = None,
) -> list[tuple[str, int, int, str]]:
    """Count ahead and behind for each local branch whose remote namesake differs.

    For every local branch name that also exists as <remote>/<name> on an
    included remote at another SHA: (name, ahead, behind, remote_ref) from
    git rev-list --left-right --count, its operands qualified with refs/heads/
    and refs/remotes/ so a tag of the same name is never counted from. Given
    run, a failing count is recorded; without it the pair is skipped.
    """
    sha_of: dict[str, str] = {}
    for tip in tips:
        for ref in tip.refs:
            sha_of.setdefault(ref, tip.sha)
    found: list[tuple[str, int, int, str]] = []
    for name, sha in sha_of.items():
        if name.startswith(_REMOTE_PREFIXES):
            continue
        for remote in INCLUDED_REMOTES:
            remote_ref = remote + "/" + name
            if sha_of.get(remote_ref, sha) == sha:
                continue
            counts = _left_right(repo, name, remote_ref, run, runner)
            if counts is not None:
                found.append((name, counts[0], counts[1], remote_ref))
    return found


def strip_remote(ref: str, remotes: Remotes) -> str:
    """Drop an included remote's prefix: origin/feature/x becomes feature/x.

    A local name, or a name under a remote that is not included, is returned
    unchanged.
    """
    for name in remotes.included:
        prefix = name + "/"
        if ref.startswith(prefix):
            return ref[len(prefix):]
    return ref


def unpublished(repo: str, run: Run, runner: Runner = model.default_runner) -> list[tuple[str, str, int]]:
    """List the local branches holding commits their upstream lacks.

    (branch, state, count): ahead with the count, no-upstream (never pushed)
    or upstream-gone (the upstream ref no longer exists), both with count 0.
    A branch in sync with its upstream, or only behind it, is omitted.
    """
    out = run_git(
        repo,
        "for-each-ref",
        "--format=%(refname:lstrip=2)%00%(upstream:short)%00%(upstream:track)",
        "refs/heads",
        run=run,
        runner=runner,
    )
    rows: list[tuple[str, str, int]] = []
    for line in out.split("\n"):
        if not line:
            continue
        branch, _, rest = line.partition("\0")
        upstream, _, track = rest.partition("\0")
        if not upstream:
            rows.append((branch, "no-upstream", 0))
        elif track == "[gone]":
            rows.append((branch, "upstream-gone", 0))
        else:
            ahead = _AHEAD.fullmatch(track)
            if ahead is not None:
                rows.append((branch, "ahead", int(ahead.group(1))))
    return rows


def dirty(checkout: Checkout, run: Run, runner: Runner = model.default_runner) -> list[tuple[str, str]]:
    """List the modified, staged and untracked paths of one checkout.

    (status_code, path) from porcelain v1: -z leaves paths unquoted, -uall
    names every untracked file rather than its directory, and the top-level
    --no-optional-locks keeps git from refreshing the index. A rename or copy
    reports its new path only. A gone checkout, or a bare entry, gives [].
    """
    if not checkout.present or not checkout.head:
        return []
    out = run_git(
        checkout.path,
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "-z",
        "-uall",
        run=run,
        runner=runner,
    )
    entries: list[tuple[str, str]] = []
    records = iter(out.split("\0"))
    for record in records:
        # Each record is "XY <path>"; the final NUL leaves one empty string.
        if not record:
            continue
        code = record[:2]
        if "R" in code or "C" in code:
            next(records, None)
        entries.append((code, record[3:]))
    return entries


def stashes(repo: str, run: Run, runner: Runner = model.default_runner) -> list[tuple[str, str, str, list[str]]]:
    """List every stash entry: (ref, date_iso, message, paths).

    date_iso is the stash commit's committer date with its offset; paths are
    the tracked and untracked paths the entry holds, read NUL-separated so no
    path comes back C-quoted.
    """
    out = run_git(repo, "stash", "list", "--format=%gd%x00%cI%x00%gs", run=run, runner=runner)
    entries: list[tuple[str, str, str, list[str]]] = []
    for line in out.split("\n"):
        if not line:
            continue
        ref, _, rest = line.partition("\0")
        date_iso, _, message = rest.partition("\0")
        names = run_git(repo, "stash", "show", "--name-only", "-z", "--include-untracked", ref, run=run, runner=runner)
        entries.append((ref, date_iso, message, [path for path in names.split("\0") if path]))
    return entries


def fetch_age_seconds(repo: str, runner: Runner = model.default_runner) -> int | None:
    """Seconds since the last fetch of any remote, None when none is recorded.

    The newest mtime among the FETCH_HEAD files under the common dir: its own,
    and <common>/worktrees/<name>/FETCH_HEAD, which a fetch run from a linked
    worktree writes instead. A file that cannot be read counts as absent.
    """
    common = common_dir(repo, runner=runner)
    candidates = [os.path.join(common, "FETCH_HEAD")]
    linked = os.path.join(common, "worktrees")
    try:
        names = os.listdir(linked)
    except OSError:
        names = []
    candidates.extend(os.path.join(linked, name, "FETCH_HEAD") for name in names)
    newest: float | None = None
    for path in candidates:
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            continue
        if newest is None or mtime > newest:
            newest = mtime
    if newest is None:
        return None
    return max(0, int(time.time() - newest))


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


def _record(run: Run, args: tuple[str, ...], err: str, code: int) -> None:
    run.errors.append("git " + " ".join(args) + ": " + _first_line(err, code))
    run.complete = False


def _count(text: str) -> int | None:
    try:
        return int(text.strip())
    except ValueError:
        return None


def _short_name(refname: str) -> str:
    for prefix in ("refs/heads/", "refs/remotes/"):
        if refname.startswith(prefix):
            return refname[len(prefix):]
    return refname


def _tip_refs(repo: str, remotes: Remotes, run: Run, runner: Runner) -> dict[str, list[str]]:
    """Map each tip SHA to its short ref names, in for-each-ref (refname) order."""
    patterns = ["refs/heads", *("refs/remotes/" + name for name in remotes.included)]
    out = run_git(repo, "for-each-ref", "--format=%(objectname)%00%(refname)", *patterns, run=run, runner=runner)
    symbolic = {"refs/remotes/" + name + "/HEAD" for name in remotes.included}
    refs_by_sha: dict[str, list[str]] = {}
    for line in out.split("\n"):
        sha, _, refname = line.partition("\0")
        if not refname or refname in symbolic:
            continue
        refs_by_sha.setdefault(sha, []).append(_short_name(refname))
    return refs_by_sha


def _commit_facts(repo: str, shas: list[str], run: Run, runner: Runner) -> dict[str, tuple[str, str]]:
    """Map each SHA to its committer date (%cI) and author email (%ae) in one call.

    rev-list is plumbing, so log.showSignature and similar porcelain settings
    cannot add lines to the output.
    """
    if not shas:
        return {}
    out = run_git(
        repo,
        "rev-list",
        "--no-walk=unsorted",
        "--no-commit-header",
        "--format=%H%x00%cI%x00%ae",
        *shas,
        run=run,
        runner=runner,
    )
    facts: dict[str, tuple[str, str]] = {}
    for line in out.split("\n"):
        sha, _, rest = line.partition("\0")
        if rest:
            last_date, _, author_email = rest.partition("\0")
            facts[sha] = (last_date, author_email)
    return facts


def _holding_checkout(sha: str, checkouts: list[Checkout]) -> str | None:
    """The present checkout whose HEAD is sha: a linked worktree, else the main one."""
    main: str | None = None
    for checkout in checkouts:
        if not checkout.present or checkout.head != sha:
            continue
        if not checkout.is_main:
            return checkout.path
        main = checkout.path
    return main


def _left_right(
    repo: str,
    name: str,
    remote_ref: str,
    run: Run | None,
    runner: Runner,
) -> tuple[int, int] | None:
    args = ("rev-list", "--left-right", "--count", "refs/heads/" + name + "...refs/remotes/" + remote_ref)
    if run is None:
        code, out, _ = try_git(repo, *args, runner=runner)
        if code != 0:
            return None
    else:
        out = run_git(repo, *args, run=run, runner=runner)
    left, _, right = out.strip().partition("\t")
    ahead, behind = _count(left), _count(right)
    if ahead is None or behind is None:
        return None
    return ahead, behind
