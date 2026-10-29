"""Which sessions worked on an item, the --mine filter, and the question sessions.

The matcher finds an item's names and paths in a transcript; this module
turns that evidence into at most three associated sessions per item, ranked
by evidence class (work, request, mention, lookup) and then by the matching
event's time, newest first. Timestamps are compared as timezone-aware
instants, never as text: transcripts stamp UTC with a Z, git the local offset.
"""

import os
from collections import Counter
from datetime import datetime
from typing import TYPE_CHECKING

from scripts.unfinishedlib import live
from scripts.unfinishedlib.model import Association, Checkout, Evidence, Item, Session

if TYPE_CHECKING:
    from scripts.unfinishedlib.inventory import Inventory

# Evidence classes in rank order, strongest first.
CLASS_RANK = {"work": 0, "request": 1, "mention": 2, "lookup": 3}
MAX_SESSIONS = 3
# The kinds whose names are branch names, so a unique last segment names them too.
BRANCH_KINDS = frozenset({"tip", "unpublished", "removed-worktree"})
# What a session that ran this skill does not contribute: its report names everything.
_REPORT_CLASSES = frozenset({"mention", "lookup"})

# (class rank, 0 for a dated event else 1, minus the event's epoch seconds).
_Key = tuple[int, int, float]
# One countable event: its rank key, its instant, its normalised checkout, the evidence.
_Event = tuple[_Key, datetime | None, str | None, Evidence]


def instant(stamp: str | None) -> datetime | None:
    """A timezone-aware instant, or None for a missing, unparsable or naive stamp."""
    if not stamp:
        return None
    try:
        at = datetime.fromisoformat(stamp)
    except ValueError:
        return None
    return at if at.tzinfo is not None else None


def build_names(items: list[Item], all_branch_names: list[str]) -> tuple[list[str], list[str]]:
    """Add unique last segments to branch items' names; return every name and path.

    all_branch_names are the remote-stripped branch names of the inventory,
    de-duplicated by the caller. For each tip, unpublished and
    removed-worktree item, every name of it that is one of those branches
    and holds a / gains its last path segment, when no other branch's last
    segment (a branch without a / is its own last segment) is the same.
    Returns the union of every item's names and of every item's paths, each
    in order of first appearance, for the NameMatcher.
    """
    branches = set(all_branch_names)
    segments = Counter(name.rsplit("/", 1)[-1] for name in branches)
    for item in items:
        if item.kind not in BRANCH_KINDS:
            continue
        for name in list(item.names):
            if name not in branches or "/" not in name:
                continue
            segment = name.rsplit("/", 1)[-1]
            if segment and segments[segment] == 1 and segment not in item.names:
                item.names.append(segment)
    names = list(dict.fromkeys(name for item in items for name in item.names))
    paths = list(dict.fromkeys(path for item in items for path in item.paths))
    return names, paths


def associate(
    items: list[Item],
    sessions: list[Session],
    *,
    checkouts: list[Checkout] | None = None,
    main_path: str = "",
) -> None:
    """Fill each item's sessions with up to MAX_SESSIONS associations.

    A session's evidence counts for an item when its token is one of the
    item's names or paths; a session that ran this skill contributes no
    mention and no lookup. A dirty item counts only evidence whose checkout
    is its own (attrs["checkout"]), and a stash only evidence whose checkout
    is main_path, under which its paths are rendered; checkouts compare
    normalised, so evidence without one (a name match) never counts for
    either, and neither admits any when its checkout is unknown. For a
    stash, only evidence before the stash's date counts, and none when that
    date does not parse. Each session gives one association, from its best
    evidence (class rank, then the newest event); sessions are ranked the
    same way, ties by session id. live is the session's, checkout that of
    its most frequent cwd (session_checkout).
    """
    indexed = [(session, _evidence_by_token(session)) for session in sessions]
    for item in items:
        tokens = list(dict.fromkeys([*item.names, *item.paths]))
        cutoff = instant(item.date) if item.kind == "stash" else None
        own = _own_checkout(item, main_path)
        ranked: list[tuple[_Key, str, Session, Evidence]] = []
        if tokens and (item.kind != "stash" or cutoff is not None):
            for session, by_token in indexed:
                best = _best(by_token, tokens, cutoff, own)
                if best is not None:
                    ranked.append((best[0], session.id, session, best[1]))
        ranked.sort(key=lambda entry: (entry[0], entry[1]))
        item.sessions = [
            Association(
                session_id=session.id,
                evidence=evidence.cls,
                token=evidence.token,
                ts=evidence.ts,
                slot=session.slot,
                checkout=session_checkout(session, checkouts or [], main_path),
                last_request=session.last_request,
                live=session.live,
            )
            for _, _, session, evidence in ranked[:MAX_SESSIONS]
        ]


def session_checkout(session: Session, checkouts: list[Checkout], main_path: str) -> str:
    """The checkout of the session's most frequent cwd, else that cwd itself.

    The most frequent cwd is the one with the most records on the active
    chain, the first seen on a tie (cwds' first key when no count exists);
    it maps to a checkout by live's rule: the longest present checkout root
    it lies in, <main>/.worktrees/<name> competing by length. "" when the
    session records no cwd.
    """
    cwd = ""
    most = 0
    for candidate, count in session.cwd_counts.items():
        if count > most:
            cwd, most = candidate, count
    if not cwd and session.cwds:
        cwd = next(iter(session.cwds))
    if not cwd:
        return ""
    return live._checkout_of(cwd, checkouts, main_path) or cwd


def mine_filter(inv: "Inventory", user_email: str, local_names: set[str]) -> None:
    """Narrow the tip items to the owner's, in place; every other kind is untouched.

    A tip item stays when its last commit's author email equals user_email
    (never when user_email is empty), when one of its names is a local
    branch name, when a checkout holds it, or when one of its associations
    is work evidence. A mention or a lookup never qualifies. The
    merge-request arm comes with the forge reader.
    """
    kept: list[Item] = []
    for item in inv.items_by_kind.get("tip", []):
        author = item.attrs.get("author_email", "")
        if (
            (user_email and author == user_email)
            or any(name in local_names for name in item.names)
            or item.attrs.get("worktree")
            or any(association.evidence == "work" for association in item.sessions)
        ):
            kept.append(item)
    inv.items_by_kind["tip"] = kept


def question_sessions(sessions: list[Session], since_days: int, now: float) -> list[Session]:
    """The offline sessions that ended on a question within since_days of now, oldest first.

    A session qualifies when it is neither live nor possibly live, its last
    assistant turn asked with no genuine request after it, it holds at least
    one genuine request, and its last timestamp parses and falls no earlier
    than since_days days before now.
    """
    cutoff = now - since_days * 86400
    found: list[tuple[datetime, str, Session]] = []
    for session in sessions:
        if session.live is not None or not session.ended_on_question or session.user_turns < 1:
            continue
        at = instant(session.last_ts)
        if at is not None and at.timestamp() >= cutoff:
            found.append((at, session.id, session))
    found.sort(key=lambda entry: (entry[0], entry[1]))
    return [session for _, _, session in found]


def _key(cls: str, at: datetime | None) -> _Key:
    if at is None:
        return CLASS_RANK[cls], 1, 0.0
    return CLASS_RANK[cls], 0, -at.timestamp()


def _own_checkout(item: Item, main_path: str) -> str | None:
    """The checkout an item's evidence must come from: None for any, "" for none at all.

    A dirty item's own checkout and, for a stash, the main checkout, both
    normalised; every other kind takes evidence from any checkout.
    """
    if item.kind == "dirty":
        root = item.attrs.get("checkout", "")
    elif item.kind == "stash":
        root = main_path
    else:
        return None
    return os.path.normpath(root) if root else ""


def _evidence_by_token(session: Session) -> dict[str, list[_Event]]:
    """The session's countable evidence per token, each with its rank key, instant and normalised checkout."""
    found: dict[str, list[_Event]] = {}
    for evidence in session.evidence:
        if evidence.cls not in CLASS_RANK:
            continue
        if session.ran_skill and evidence.cls in _REPORT_CLASSES:
            continue
        at = instant(evidence.ts)
        checkout = os.path.normpath(evidence.checkout) if evidence.checkout else None
        found.setdefault(evidence.token, []).append((_key(evidence.cls, at), at, checkout, evidence))
    return found


def _best(
    by_token: dict[str, list[_Event]],
    tokens: list[str],
    cutoff: datetime | None,
    own: str | None = None,
) -> tuple[_Key, Evidence] | None:
    """The best evidence among tokens.

    With a cutoff, only events strictly before it; with own, only events
    from that checkout ("" admits none).
    """
    best: tuple[_Key, Evidence] | None = None
    for token in tokens:
        for key, at, checkout, evidence in by_token.get(token, ()):
            if cutoff is not None and (at is None or at >= cutoff):
                continue
            if own is not None and checkout != own:
                continue
            if best is None or key < best[0]:
                best = (key, evidence)
    return best
