"""Throwaway git repositories for the tests.

Each repository carries its own identity and turns signing off, so a fixture
commit never reaches the machine's signing agent or its global identity.
"""

import os
import subprocess

EMAIL = "owner@example.test"
NAME = "Fixture Owner"


def git(repo: str, *args: str) -> str:
    """Run `git -C <repo> <args>` and return stdout; raise with stderr on failure."""
    completed = subprocess.run(
        ["git", "-C", repo, *args],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(
            "git " + " ".join(args) + " failed with " + str(completed.returncode) + ": " + completed.stderr.strip()
        )
    return completed.stdout


def make_repo(tmp: str, *, with_origin: bool = True, with_upstream: bool = False) -> dict[str, str]:
    """Create a checkout at <tmp>/work with one commit on main.

    with_origin adds a bare <tmp>/origin.git as origin, pushes main with
    tracking and sets origin/HEAD with `git remote set-head origin -a`.
    with_upstream adds a bare <tmp>/upstream.git as upstream, pushes main and
    sets upstream/HEAD the same way; main keeps tracking origin. A remote not
    created is "" in the result.
    """
    work = os.path.join(tmp, "work")
    os.makedirs(work)
    git(work, "init", "-q", "-b", "main")
    git(work, "config", "user.name", NAME)
    git(work, "config", "user.email", EMAIL)
    git(work, "config", "commit.gpgsign", "false")
    git(work, "config", "tag.gpgsign", "false")
    commit(work, "README.md", "fixture\n", "Add the readme")
    result = {"work": work, "origin": "", "upstream": ""}
    if with_origin:
        result["origin"] = _bare_remote(work, tmp, "origin", track=True)
    if with_upstream:
        result["upstream"] = _bare_remote(work, tmp, "upstream", track=False)
    return result


def commit(work: str, path: str, text: str, msg: str) -> str:
    """Write text to <work>/<path>, commit it with msg, return the new SHA."""
    target = os.path.join(work, path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(text)
    git(work, "add", "--", path)
    git(work, "commit", "-q", "-m", msg)
    return git(work, "rev-parse", "HEAD").strip()


def _bare_remote(work: str, tmp: str, name: str, *, track: bool) -> str:
    bare = os.path.join(tmp, name + ".git")
    # -b main keeps the remote's HEAD off the machine's init.defaultBranch.
    git(tmp, "init", "-q", "--bare", "-b", "main", bare)
    git(work, "remote", "add", name, bare)
    if track:
        git(work, "push", "-q", "-u", name, "main")
    else:
        git(work, "push", "-q", name, "main")
    git(work, "remote", "set-head", name, "-a")
    return bare
