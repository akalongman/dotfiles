"""Command line of unfinished.py."""

import argparse


def main(argv: list[str]) -> int:
    """Parse the flags; the inventory itself is not implemented yet."""
    _parser().parse_args(argv)
    print("not implemented")
    return 0


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
