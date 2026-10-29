"""Transcript files for the tests, in the shape Claude Code writes them.

Each helper builds one record and fills the fields every record of its kind
carries: a fresh uuid, cwd (MAIN unless given), gitBranch (BRANCH unless
given), entrypoint cli and isSidechain false. Keyword arguments override any
top-level field. bridge() carries no uuid, as the real bridge-session record
does not.

write_transcript fills the fields that depend on a record's place in the
file: sessionId on every record, and on every record with a uuid the
parentUuid of the previous record with a uuid and the timestamp of its line.
A parentUuid or timestamp already present is kept, so a case can give
parentUuid=None or a uuid that names nothing. It fills the given dicts in
place, so a case reads a record's timestamp after writing it.

MAIN and every cwd are fixed strings that no case reads from disk.
"""

import json
import os
import uuid as uuidlib
from datetime import UTC, datetime, timedelta
from typing import Any

MAIN = "/home/u/p"
BRANCH = "main"

_START = datetime(2026, 10, 1, 10, 0, 0, tzinfo=UTC)


def timestamp(index: int) -> str:
    """The timestamp write_transcript gives the record on line index (from 0)."""
    return (_START + timedelta(seconds=index)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def write_transcript(folder: str, session_id: str, records: list[dict[str, Any] | str]) -> str:
    """Write records as JSON lines to <folder>/<session_id>.jsonl and return the path.

    A string in records is written verbatim as one line (a malformed line)
    and is never a parent.
    """
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, session_id + ".jsonl")
    previous: str | None = None
    lines: list[str] = []
    for index, record in enumerate(records):
        if isinstance(record, str):
            lines.append(record)
            continue
        record["sessionId"] = session_id
        if "uuid" in record:
            record.setdefault("parentUuid", previous)
            record.setdefault("timestamp", timestamp(index))
            previous = record["uuid"]
        lines.append(json.dumps(record, ensure_ascii=False))
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("".join(line + "\n" for line in lines))
    return path


def user(text: str | list[str], **kw: Any) -> dict[str, Any]:
    """A user record; a list of strings becomes one text block each."""
    content: str | list[dict[str, Any]]
    if isinstance(text, str):
        content = text
    else:
        content = [{"type": "text", "text": piece} for piece in text]
    return _conversation("user", {"role": "user", "content": content}, kw)


def assistant(
    text: str | None = None,
    tool_use: dict[str, Any] | list[dict[str, Any]] | None = None,
    **kw: Any,
) -> dict[str, Any]:
    """An assistant record holding a text block, then tool_use blocks.

    tool_use is {"name": ..., "input": ..., "id": ...} (id generated when
    absent) or a list of them. message_id names the API message the record
    belongs to (fresh when absent); records sharing it are blocks of one
    message.
    """
    message_id = kw.pop("message_id", "msg_" + uuidlib.uuid4().hex)
    blocks: list[dict[str, Any]] = []
    if text is not None:
        blocks.append({"type": "text", "text": text})
    if tool_use is None:
        uses: list[dict[str, Any]] = []
    elif isinstance(tool_use, dict):
        uses = [tool_use]
    else:
        uses = list(tool_use)
    for use in uses:
        blocks.append(
            {
                "type": "tool_use",
                "id": use.get("id", "toolu_" + uuidlib.uuid4().hex),
                "name": use["name"],
                "input": use.get("input", {}),
            }
        )
    message = {"id": message_id, "type": "message", "role": "assistant", "content": blocks}
    return _conversation("assistant", message, kw)


def tool_result(tool_use_id: str, ok: bool = True, *, content: str = "done", **kw: Any) -> dict[str, Any]:
    """The user record carrying one call's result; is_error only on a failure, as the CLI writes it."""
    block: dict[str, Any] = {"type": "tool_result", "tool_use_id": tool_use_id, "content": content}
    if not ok:
        block["is_error"] = True
    return _conversation("user", {"role": "user", "content": [block]}, kw)


def system(**kw: Any) -> dict[str, Any]:
    """A system record (informational unless subtype is given)."""
    record = _base("system")
    record.update({"subtype": "informational", "content": "", "level": "info", "isMeta": False})
    record.update(kw)
    return record


def bridge(account_uuid: str) -> dict[str, Any]:
    """A bridge-session record naming the owning account; it has no uuid."""
    return {
        "type": "bridge-session",
        "bridgeSessionId": "bridge_fixture",
        "ownerAccountUuid": account_uuid,
        "ownerOrganizationUuid": "org-fixture",
        "lastSequenceNum": 0,
    }


def _conversation(kind: str, message: dict[str, Any], kw: dict[str, Any]) -> dict[str, Any]:
    record = _base(kind)
    record["message"] = message
    record.update(kw)
    return record


def _base(kind: str) -> dict[str, Any]:
    return {
        "type": kind,
        "uuid": str(uuidlib.uuid4()),
        "isSidechain": False,
        "userType": "external",
        "cwd": MAIN,
        "gitBranch": BRANCH,
        "entrypoint": "cli",
    }
