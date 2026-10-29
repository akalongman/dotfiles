"""Throwaway git repositories for the tests.

Each repository carries its own identity and turns signing off, so a fixture
commit never reaches the machine's signing agent or its global identity.

Importing this module removes the git local environment variables from
os.environ, so a GIT_DIR exported by yadm enter or a hook can send neither
the fixture's git calls nor the gitstate calls under test into another
repository, however the suite is started. It removes the author and
committer identity and dates too, which a hook exports for its own commit
and which git prefers to the fixture's configured identity.
"""

import os
import subprocess

EMAIL = "owner@example.test"
NAME = "Fixture Owner"

# The knob of this suite; a value left set would change what a case sees.
SUITE_KNOBS = ("UNFINISHED_HOME",)
# A commit's identity and dates, which override the repository's user.name and user.email.
COMMIT_IDENTITY = (
    "GIT_AUTHOR_NAME",
    "GIT_AUTHOR_EMAIL",
    "GIT_AUTHOR_DATE",
    "GIT_COMMITTER_NAME",
    "GIT_COMMITTER_EMAIL",
    "GIT_COMMITTER_DATE",
)


def _scrub_git_environment() -> None:
    # The query runs without any GIT_ variable, so a malformed one the caller
    # exported (GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT) cannot break it.
    clean = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    completed = subprocess.run(
        ["git", "rev-parse", "--local-env-vars"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        env=clean,
        check=False,
    )
    names = completed.stdout.split()
    if completed.returncode != 0 or "GIT_DIR" not in names:
        raise RuntimeError(
            "git rev-parse --local-env-vars failed, refusing to run unisolated: " + completed.stderr.strip()
        )
    for name in (*names, *COMMIT_IDENTITY, *SUITE_KNOBS):
        os.environ.pop(name, None)


_scrub_git_environment()


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
