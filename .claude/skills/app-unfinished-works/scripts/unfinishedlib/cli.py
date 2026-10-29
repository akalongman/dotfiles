"""Command line of unfinished.py."""

import argparse
import os
import sys
import time

from scripts.unfinishedlib import inventory, model, render
from scripts.unfinishedlib.model import Runner

# git's own list of the variables that point it at a repository (GIT_DIR,
# GIT_WORK_TREE, GIT_INDEX_FILE and the rest), printed one per line.
LOCAL_ENV_VARS = ["git", "rev-parse", "--local-env-vars"]


def main(
    argv: list[str],
    *,
    home: str | None = None,
    proc_root: str = "/proc",
    runner: Runner = model.default_runner,
    now: float | None = None,
) -> int:
    """Gather the inventory and print it; 0 when every source was read, else 1.

    The report is printed either way. home defaults to UNFINISHED_HOME, else
    the user's home; now to the current time. Before anything else the git
    variables that name a repository are dropped from the environment, so
    the repository is always the one the cwd or --root names, never one an
    inherited GIT_DIR points at (yadm enter, a hook).
    """
    _drop_repository_variables(runner)
    args = _parser().parse_args(argv)
    if home is None:
        home = os.environ.get("UNFINISHED_HOME") or os.path.expanduser("~")
    if now is None:
        now = time.time()
    inv = inventory.gather(args, home=home, proc_root=proc_root, runner=runner, now=now)
    if args.json:
        sys.stdout.write(render.render_json(inv) + "\n")
    else:
        root = os.path.abspath(args.root) if args.root else os.getcwd()
        sys.stdout.write(render.render_text(inv, inventory.main_path_of(inv.checkouts, root)))
    return 0 if inv.meta.get("complete") else 1


def _drop_repository_variables(runner: Runner) -> None:
    """Remove from os.environ every name `git rev-parse --local-env-vars` lists.

    The query runs with no GIT_ variable set, so a malformed one the caller
    exported cannot break it; when it fails anyway, every GIT_ variable is
    dropped, the safe direction.
    """
    inherited = {name: value for name, value in os.environ.items() if name.startswith("GIT_")}
    for name in inherited:
        del os.environ[name]
    code, out, _ = runner(LOCAL_ENV_VARS, None)
    listed = set(out.split()) if code == 0 and "GIT_DIR" in out.split() else set(inherited)
    for name, value in inherited.items():
        if name not in listed:
            os.environ[name] = value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="unfinished.py",
        description=(
            "Inventory a repository's unfinished work: worktrees, branch tips, "
            "OpenSpec changes, and the sessions behind them. Read-only apart from --fetch."
        ),
    )
    parser.add_argument("--json", action="store_true", help="print the inventory as JSON instead of the rendered list")
    parser.add_argument("--forge", action="store_true", help="also list open and draft merge requests through glab or gh")
    parser.add_argument("--mine", action="store_true", help="only tips and merge requests that are yours")
    parser.add_argument("--fetch", action="store_true", help="git fetch --prune every included remote first")
    parser.add_argument("--base", metavar="REF", help="integration base to judge merged against")
    parser.add_argument(
        "--since",
        metavar="DAYS",
        type=_days,
        default=30,
        help="window of the unverified question section in days (default 30)",
    )
    parser.add_argument("--no-questions", action="store_true", help="drop the unverified question section")
    parser.add_argument("--root", metavar="PATH", help="inspect the repository at PATH instead of the current one")
    return parser


def _days(text: str) -> int:
    try:
        days = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("not a whole number of days: " + text) from None
    if days < 0:
        raise argparse.ArgumentTypeError("days cannot be negative: " + text)
    return days
