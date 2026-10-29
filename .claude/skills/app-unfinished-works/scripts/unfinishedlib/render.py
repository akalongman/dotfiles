"""The report: plain text for the owner, or one JSON object.

Text: the header line, the item groups in KINDS order (oldest first within a
group), the unverified question section, the live sessions, the parked-note
count and a footer naming the remote, the base, the last fetch, the scan's
scope, the question window, every note and every error. Paths are absolute
and on their own line; nothing here writes a dash other than the hyphen.
Every text line passes through _printable, so a control character read from
a transcript, git or the forge (a terminal escape among them) prints as ?.
"""

import dataclasses
import json
import os
import re
from typing import Any

from scripts.unfinishedlib import associate, inventory, live
from scripts.unfinishedlib.inventory import Inventory
from scripts.unfinishedlib.model import Association, Item, LiveSession, Session
# The report's first line is REPORT_HEADER and the main checkout's path. The
# constant lives in transcripts, which reads it to tell that a session ran the skill.
from scripts.unfinishedlib.transcripts import REPORT_HEADER

GROUP_HEADINGS = {
    "openspec-pending": "Pending OpenSpec changes",
    "tip": "Branch tips not integrated",
    "unpublished": "Unpublished commits",
    "dirty": "Dirty checkouts",
    "stash": "Stashes",
    "removed-worktree": "Removed worktrees with traces",
    "merge-request": "Merge requests",
    "openspec-stale": "Stale archived copies",
}
QUESTION_HEADING = (
    "Sessions that ended on a question "
    "(unverified: a later session may have answered; punctuation is the only evidence)"
)
LIVE_HEADING = "Live sessions"
FOOTER_HEADING = "Scope"
NO_EVIDENCE = "no session evidence in the scanned transcripts"
# The JSON key of each kind's array.
JSON_KEYS = {
    "openspec-pending": "openspec_pending",
    "tip": "tips",
    "unpublished": "unpublished",
    "dirty": "dirty",
    "stash": "stashes",
    "removed-worktree": "removed_worktrees",
    "merge-request": "merge_requests",
    "openspec-stale": "openspec_stale",
}
# An item prints at most this many of its paths.
MAX_PATHS = 10
# A request or question prints on one line of at most this many characters, then "...".
LINE_WIDTH = 120
# OpenSpec place lines already lead with each checkout path or ref.
_NO_PATH_KINDS = frozenset({"openspec-pending", "openspec-stale"})
_BASE_SOURCES = {
    "override": "given with --base",
    "remote-head": "the remote's HEAD",
    "remote-name": "first of main, master, dev on the remote",
    "local-name": "first local main, master, dev",
}
_WHITESPACE = re.compile(r"\s+")
# C0 controls, DEL and C1 controls: a terminal may act on any of them.
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_COMMAND_NAME = re.compile(r"<command-name>(.*?)</command-name>", re.DOTALL)
_COMMAND_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)


def render_text(inv: Inventory, main_path: str) -> str:
    """The plain-text report, ending in a newline."""
    sessions = {session.id: session for session in inv.sessions}
    out = [REPORT_HEADER + main_path, ""]
    for kind in inventory.KINDS:
        items = inventory.sort_items(inv.items_by_kind.get(kind, []))
        # Merge requests are read only with --forge, so an empty group says nothing.
        if kind == "merge-request" and not items:
            continue
        if not items:
            out += [GROUP_HEADINGS[kind] + ": none", ""]
            continue
        out += [GROUP_HEADINGS[kind] + " (" + str(len(items)) + ")", ""]
        for item in items:
            out += _item_block(item, main_path, sessions)
            out.append("")
    if inv.meta.get("question_window_days") is not None:
        out += _questions(inv, main_path)
    out += _live(inv.live, inv, main_path)
    parked = "no queue file" if inv.parked is None else str(inv.parked)
    out += ["Parked notes: " + parked, ""]
    out += _footer(inv.meta)
    return "\n".join(_printable(line) for line in out) + "\n"


def render_json(inv: Inventory) -> str:
    """One JSON object: an array per kind, questions, live_sessions, parked and meta."""
    data: dict[str, Any] = {
        JSON_KEYS[kind]: [dataclasses.asdict(item) for item in inventory.sort_items(inv.items_by_kind.get(kind, []))]
        for kind in inventory.KINDS
    }
    data["questions"] = [dataclasses.asdict(session) for session in inv.questions]
    data["live_sessions"] = [dataclasses.asdict(row) for row in inv.live]
    data["parked"] = inv.parked
    data["meta"] = inv.meta
    return json.dumps(data, sort_keys=True, indent=2)


def one_line_request(text: str) -> str:
    """A request on one line: whitespace runs collapsed, cut to LINE_WIDTH characters then `...`.

    A request led by <command-message> (a slash command the harness
    expanded) prints as typed, `/<name> <args>`, from its <command-name> and
    <command-args> tags.
    """
    stripped = text.strip()
    if stripped.startswith("<command-message>"):
        name = _COMMAND_NAME.search(stripped)
        if name is not None:
            command = name.group(1).strip()
            if not command.startswith("/"):
                command = "/" + command
            args = _COMMAND_ARGS.search(stripped)
            stripped = command + (" " + args.group(1) if args is not None else "")
    return _cut(_WHITESPACE.sub(" ", stripped).strip())


def _item_block(item: Item, main_path: str, sessions: dict[str, Session]) -> list[str]:
    lines = [item.kind + " (" + item.certainty + "): " + item.title]
    lines += ["  " + line for line in item.lines]
    if item.kind not in _NO_PATH_KINDS:
        root = item.attrs.get("checkout") or main_path
        lines += ["  " + os.path.join(root, path) for path in item.paths[:MAX_PATHS]]
        if len(item.paths) > MAX_PATHS:
            lines.append("  and " + str(len(item.paths) - MAX_PATHS) + " more paths")
    if item.sessions:
        lines += ["  " + _association_line(association, sessions) for association in item.sessions]
    else:
        lines.append("  " + NO_EVIDENCE)
    return lines


def _association_line(association: Association, sessions: dict[str, Session]) -> str:
    session = sessions.get(association.session_id)
    when = session.last_ts if session is not None else association.ts
    columns = [
        association.session_id,
        _slot(association.slot),
        _place(association.checkout),
        inventory.local_minute(when),
    ]
    if association.live:
        columns.append(association.live)
    columns.append(_quoted(association.last_request))
    return "  ".join(columns)


def _questions(inv: Inventory, main_path: str) -> list[str]:
    lines = [QUESTION_HEADING]
    if not inv.questions:
        return lines + ["  none", ""]
    for session in inv.questions:
        checkout = associate.session_checkout(session, inv.checkouts, main_path)
        lines.append(
            "  "
            + "  ".join(
                [
                    session.id,
                    _slot(session.slot),
                    _place(checkout),
                    inventory.local_minute(session.last_ts),
                    _quoted(session.last_request),
                ]
            )
        )
        lines.append("    asked: " + _quoted_tail(session.last_assistant))
    return lines + [""]


def _live(rows: list[LiveSession], inv: Inventory, main_path: str) -> list[str]:
    if not rows:
        return [LIVE_HEADING + ": none", ""]
    lines = [LIVE_HEADING + " (" + str(len(rows)) + ")"]
    for row in rows:
        checkout = live._checkout_of(row.cwd, inv.checkouts, main_path) or row.cwd
        name = row.name or "unregistered process " + str(row.pid)
        lines.append("  " + "  ".join([name, row.state, _slot(row.slot), _place(checkout)]))
    return lines + [""]


def _footer(meta: dict[str, Any]) -> list[str]:
    lines = [FOOTER_HEADING]
    lines.append("  remote: " + (meta.get("remote") or "none"))
    base = meta.get("base")
    if base:
        source = meta.get("base_source", "")
        lines.append("  base: " + base + " (" + _BASE_SOURCES.get(source, source) + ")")
    else:
        lines.append("  base: unknown (none resolved, so nothing is judged merged)")
    lines.append("  last fetch of any remote: " + _age(meta.get("fetch_age_seconds")))
    lines.append("  transcripts scanned: " + _scan(meta.get("transcripts") or {}))
    window = meta.get("question_window_days")
    lines.append("  question window: " + ("off" if window is None else _plural(window, "day")))
    lines += _listing("notes", meta.get("notes") or [])
    lines += _listing("errors", meta.get("errors") or [])
    if meta.get("complete", True):
        lines.append("  complete: every source was read")
    else:
        lines.append("  incomplete: a source failed, see errors; the list above may miss items")
    return lines


def _listing(label: str, entries: list[str]) -> list[str]:
    if not entries:
        return ["  " + label + ": none"]
    return ["  " + label + " (" + str(len(entries)) + "):"] + ["    " + entry for entry in entries]


def _scan(facts: dict[str, Any]) -> str:
    text = _plural(int(facts.get("count") or 0), "file") + ", " + _size(int(facts.get("bytes") or 0))
    oldest, newest = facts.get("oldest"), facts.get("newest")
    if oldest and newest:
        text += ", " + inventory.local_minute(oldest) + " to " + inventory.local_minute(newest)
    return text


def _slot(slot: str) -> str:
    return "unknown slot" if not slot or slot == "unknown" else "slot " + slot


def _place(checkout: str) -> str:
    """A checkout's basename (the main checkout's name, or a worktree's), else `unknown checkout`."""
    return os.path.basename(checkout.rstrip("/")) or "unknown checkout"


def _quoted(request: str) -> str:
    line = one_line_request(request)
    return "\"" + line + "\"" if line else "(no request)"


def _quoted_tail(text: str) -> str:
    """The end of a text on one line, where a question sits: `...` then its last LINE_WIDTH characters."""
    line = _WHITESPACE.sub(" ", text).strip()
    if not line:
        return "(no text)"
    if len(line) > LINE_WIDTH:
        line = "..." + line[-LINE_WIDTH:]
    return "\"" + line + "\""


def _cut(line: str) -> str:
    return line[:LINE_WIDTH] + "..." if len(line) > LINE_WIDTH else line


def _printable(line: str) -> str:
    """One report line with each C0 control, DEL and C1 control replaced by ?.

    The lines are joined by LF, so a LF inside one line is replaced too.
    Whitespace runs are collapsed earlier (one_line_request, _quoted_tail,
    inventory._one_line); the JSON escapes control characters itself.
    """
    return _CONTROL.sub("?", line)


def _age(seconds: Any) -> str:
    if seconds is None:
        return "never (no FETCH_HEAD)"
    seconds = int(seconds)
    if seconds < 120:
        return _plural(seconds, "second") + " ago"
    if seconds < 7200:
        return _plural(seconds // 60, "minute") + " ago"
    if seconds < 172800:
        return _plural(seconds // 3600, "hour") + " ago"
    return _plural(seconds // 86400, "day") + " ago"


def _size(size: int) -> str:
    if size < 1024:
        return _plural(size, "byte")
    value = size / 1024
    for unit in ("KB", "MB"):
        if value < 1024:
            return format(value, ".1f") + " " + unit
        value /= 1024
    return format(value, ".1f") + " GB"


def _plural(number: int, word: str) -> str:
    return str(number) + " " + word + ("" if number == 1 else "s")
