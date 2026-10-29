"""Claude Code transcripts: which belong to the repository, and what each one did.

A transcript is a JSON-lines file at <slot>/projects/<encoded cwd>/<session>.jsonl.
Folder names only select candidates: a transcript belongs to the repository
when one of its records' cwd lies inside a checkout or under
<main>/.worktrees/. Each file is read once, line by line, into slim nodes
(tool results keep only their outcome), and the active conversation chain is
walked back from the last record that has a uuid, so an abandoned fork is
ignored. Every session field but the account and the modification time is
read from that chain. Files are only ever opened for reading.
"""

import json
import os
import re
import shlex
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from scripts.unfinishedlib.model import Checkout, Evidence, Run, Session

# A user text block, or a whole string content, starting with one of these
# is written by the harness, not typed by the user: local commands and their
# output, reminders, notifications, the ! shell mode, and the marker the CLI
# writes when the user interrupts a turn.
HARNESS_TAGS = (
    "<command-name>",
    "<local-command-stdout>",
    "<local-command-caveat>",
    "<system-reminder>",
    "<task-notification>",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
)
INTERRUPTION_MARKER = "[Request interrupted by user"
_LOCAL_PREFIXES = (*HARNESS_TAGS, INTERRUPTION_MARKER)

EDIT_TOOLS = ("Edit", "Write", "NotebookEdit")
QUESTION_TOOL = "AskUserQuestion"

# How a session shows that it ran this skill: the script in a shell command,
# the slash command in a request, or the report's header (render prints it
# before the main checkout's path) in a request or an assistant text.
SKILL_SCRIPT = "app-unfinished-works/scripts/unfinished.py"
SKILL_COMMAND = "/app-unfinished-works"
REPORT_HEADER = "Unfinished work report for "

# A command that writes files, counted as the command word of a simple
# command (sed only with an in-place option).
FILE_COMMANDS = frozenset({"mv", "cp", "rm", "mkdir", "tee", "openspec"})
# The spec's closed list of state-changing git verbs, counted as git's
# subcommand; branch, stash and worktree have read-only forms.
GIT_VERBS = frozenset(
    {"commit", "switch", "checkout", "branch", "push", "merge", "rebase", "cherry-pick", "stash", "worktree"}
)
# Words after which the next word is still in command position: the shell's
# reserved words that precede a command, these prefixes (and a prefix's
# options), NAME=value assignments. timeout also takes a duration, and its -s
# and -k a value, before the command.
_COMMAND_KEYWORDS = frozenset({"then", "do", "else", "if", "elif", "while", "until", "!", "{"})
_COMMAND_PREFIXES = frozenset({"sudo", "env", "xargs", "time", "nohup", "command", "exec", "timeout"})
_TIMEOUT_VALUE_OPTIONS = frozenset({"-s", "-k", "--signal", "--kill-after"})
_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# git branch: a short option clustering any of these letters, or one of
# these long options, changes refs.
_BRANCH_MUTATING_LETTERS = frozenset("dDmMcCfut")
_BRANCH_MUTATING_OPTIONS = frozenset(
    {
        "--delete",
        "--move",
        "--copy",
        "--force",
        "--set-upstream-to",
        "--unset-upstream",
        "--edit-description",
        "--track",
        "--no-track",
    }
)
# git branch list mode: a short cluster of only these letters, or one of
# these long options; the last group takes the next word as its value.
_BRANCH_LIST_LETTERS = frozenset("arlv")
_BRANCH_LIST_OPTIONS = frozenset(
    {
        "--list",
        "--all",
        "--remotes",
        "--verbose",
        "--format",
        "--sort",
        "--points-at",
        "--contains",
        "--no-contains",
        "--merged",
        "--no-merged",
        "--show-current",
    }
)
_BRANCH_VALUE_OPTIONS = frozenset({"--format", "--sort", "--points-at", "--contains", "--no-contains", "--merged", "--no-merged"})
# git options that take their value as the next word.
_GIT_VALUE_OPTIONS = frozenset({"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"})

# File-descriptor plumbing that changes nothing, as whole shell tokens.
_FD_REDIRECT = re.compile(r"(?<![^\s;&|()])(?:2>/dev/null|>/dev/null|2>&1|1>&2|>&2|</dev/null)(?![^\s;&|()])")

# Shell operators; a newline separates commands as ; does.
_OPERATOR_CHARS = "();<>|&\n"
_SEPARATOR_CHARS = frozenset("();|&\n")
# The splitter for a command shlex cannot read (an apostrophe in a heredoc).
_FALLBACK_TOKEN = re.compile(r"[();<>|&\n]+|[^\s();<>|&]+")
# sed in place: -i, -i.bak, a cluster such as -Ei, or --in-place.
_IN_PLACE = re.compile(r"-[A-Za-z]*i|--in-place")

_NOT_ALNUM = re.compile(r"[^A-Za-z0-9]")


def encode_path(path: str) -> str:
    """The projects folder name for a cwd: every character outside [A-Za-z0-9] becomes -."""
    return _NOT_ALNUM.sub("-", path)


def candidate_folders(projects_roots: list[str], main_path: str, checkouts: list[Checkout]) -> list[str]:
    """Return the projects folders that may hold this repository's transcripts.

    A folder is a candidate when it is named encode_path(main_path) or
    encode_path(c.path) for any checkout (a gone one included), or starts
    with encode_path(main_path) + "--" (a worktree under .worktrees/,
    removed or not). Folders are returned by real path, each once, roots in
    the order given and names sorted within a root; a missing or unreadable
    root lists nothing. The encoding is lossy, so the cwd check in
    parse_transcript decides membership.
    """
    main_name = encode_path(main_path)
    exact = {main_name, *(encode_path(checkout.path) for checkout in checkouts)}
    found: list[str] = []
    seen: set[str] = set()
    for root in projects_roots:
        try:
            with os.scandir(root) as entries:
                names = sorted(entry.name for entry in entries if entry.is_dir())
        except OSError:
            continue
        for name in names:
            if name not in exact and not name.startswith(main_name + "--"):
                continue
            real = os.path.realpath(os.path.join(root, name))
            if real not in seen:
                seen.add(real)
                found.append(real)
    return found


def classify_user(record: dict[str, Any]) -> str:
    """Classify a user record: tool_result, meta, local or request.

    tool_result when any block is a tool result; meta when isMeta is true or
    the record is the summary the CLI writes after a compaction
    (isCompactSummary); otherwise every text block (or the whole string)
    starting with a harness tag or the interruption marker is dropped, and
    the record is local when nothing remains, else a genuine request.
    """
    return _classify(record)[0]


def strip_fd_redirects(command: str) -> str:
    """Remove the tokens 2>/dev/null, >/dev/null, 2>&1, >&2, 1>&2 and </dev/null.

    Only whole shell tokens go: a redirect glued to a word stays.
    """
    return _FD_REDIRECT.sub("", command)


def is_state_changing(command: str) -> bool:
    """Whether a shell command may change a repository or a file.

    Read on the command with strip_fd_redirects applied. True when:
    - a > or >> redirection anywhere writes a file (one to /dev/null, or
      onto another descriptor, writes nothing);
    - the command word of a simple command is one of FILE_COMMANDS, or is
      sed with an in-place option. The command word is the first word
      after the start, a separator (; && || | & ( or a newline) or a
      reserved word that precedes a command (then, do, else, if, elif,
      while, until, !, {), past NAME=value assignments and the
      prefixes sudo, env, xargs, time, nohup, command, exec and timeout
      (with its duration);
    - a git command word's subcommand, past git's global options, is one of
      GIT_VERBS and not a read-only form: branch in list mode or with no
      argument, stash list, stash show, worktree list.

    A command name as an argument or a search term (grep -rn x openspec,
    git log --grep merge) changes nothing, and quoted text is one word.
    """
    tokens = _shell_tokens(strip_fd_redirects(command))
    if any(_is_redirect(token) and _writes_a_file(tokens, index) for index, token in enumerate(tokens)):
        return True
    for index in _command_words(tokens):
        word = tokens[index]
        if word in FILE_COMMANDS:
            return True
        if word == "sed" and any(_IN_PLACE.match(argument) for argument in _arguments(tokens, index + 1)):
            return True
        if word == "git":
            subcommand, arguments = _git_invocation(tokens, index + 1)
            if subcommand in GIT_VERBS and not _git_reads_only(subcommand, arguments):
                return True
    return False


class NameMatcher:
    """Whole-name matching of an inventory's names, and path matching of its paths."""

    def __init__(self, names: list[str], paths: list[str]) -> None:
        self.paths = list(dict.fromkeys(path.rstrip("/") for path in paths if path.strip("/")))
        ordered = sorted({name for name in names if name}, key=lambda name: (-len(name), name))
        self._pattern: re.Pattern[str] | None = None
        if ordered:
            # Before: no name character, so / may precede and dev-2 holds no
            # dev. After: no name character and no dot followed by one, so a
            # sentence period may follow but dev.local holds no dev; and not
            # a match ending in the dev of a literal /dev/, which refuses
            # 2>/dev/null while origin/dev/feature still finds dev/feature.
            self._pattern = re.compile(
                r"(?<![A-Za-z0-9_.-])(?:"
                + "|".join(re.escape(name) for name in ordered)
                + r")(?![A-Za-z0-9_-])(?!\.[A-Za-z0-9_])(?!(?<=/dev)/)"
            )

    def find(self, text: str) -> list[str]:
        """Return the names text contains whole, each once, in order of first appearance."""
        if self._pattern is None:
            return []
        found: list[str] = []
        for match in self._pattern.finditer(text):
            if match.group(0) not in found:
                found.append(match.group(0))
        return found

    def find_path(self, file_path: str, checkouts: list[str]) -> str | None:
        """Return the first paths entry an absolute file path lies under, else None."""
        found = self.find_paths(file_path, checkouts)
        return found[0] if found else None

    def find_paths(self, file_path: str, checkouts: list[str]) -> list[str]:
        """Return every paths entry an absolute file path lies under, in paths order.

        The longest checkout root containing the path is stripped, then a
        leading .worktrees/<name>/ too, so a file in a gone worktree under
        the main checkout still maps. An entry p matches a relative path rel
        when rel == p or rel starts with p + "/", so nested entries (a change
        directory and a dirty file inside it) all match.
        """
        return self.find_paths_with_checkout(file_path, checkouts)[1]

    def find_paths_with_checkout(self, file_path: str, checkouts: list[str]) -> tuple[str | None, list[str]]:
        """find_paths's entries with the checkout they are relative to: (checkout, entries).

        The checkout is the normalised root find_paths strips, extended by
        .worktrees/<name> when that prefix is stripped too, so a file in a
        gone worktree belongs to that worktree, not to the main checkout.
        (None, []) when no root contains the path; the checkout is set even
        when no entry matches.
        """
        path = os.path.normpath(file_path)
        root: str | None = None
        for candidate in checkouts:
            candidate = os.path.normpath(candidate)
            if _under(path, candidate) and (root is None or len(candidate) > len(root)):
                root = candidate
        if root is None:
            return None, []
        relative = "" if path == root else path[len(root.rstrip("/")) + 1 :]
        parts = relative.split("/", 2)
        if len(parts) == 3 and parts[0] == ".worktrees" and parts[1]:
            root = os.path.join(root, parts[0], parts[1])
            relative = parts[2]
        entries = [candidate for candidate in self.paths if relative == candidate or relative.startswith(candidate + "/")]
        return root, entries


def parse_transcript(
    path: str,
    matcher: NameMatcher,
    checkouts: list[str],
    main_path: str,
    accounts: dict[str, str],
    run: Run,
) -> Session | None:
    """Read one transcript into a Session, or None when it is not this repository's.

    checkouts are the checkout roots. None when no record's cwd lies inside
    one of them or under <main_path>/.worktrees/, when the first user record
    in the file has entrypoint sdk-py (a headless run), or when the file
    cannot be read (recorded). A line that is not a JSON object is recorded
    as <path>:<lineno> and skipped; the rest of the file is still read.

    The chain is walked by parentUuid from the last record with a uuid,
    across a compaction boundary through its logicalParentUuid; a parent
    that resolves to nothing (it was on a malformed line) falls back to the
    nearest earlier record. The chain also holds every record of an
    assistant message it passes through, because the CLI writes each block
    of a message (parallel tool calls) as its own record and the walk passes
    only some of them. A tool call counts as evidence only when its result
    exists and is not an error; the results' content is never searched.
    """
    roots = [os.path.normpath(root) for root in checkouts]
    worktrees = os.path.normpath(main_path).rstrip("/") + "/.worktrees/"
    nodes: list[_Node] = []
    by_uuid: dict[str, int] = {}
    results: dict[str, bool] = {}
    account_uuid: str | None = None
    member = False
    seen_user = False
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            mtime = os.fstat(handle.fileno()).st_mtime
            for lineno, line in enumerate(handle, start=1):
                try:
                    record = json.loads(line)
                except ValueError:
                    _record_error(run, path + ":" + str(lineno) + ": not JSON")
                    continue
                if not isinstance(record, dict):
                    _record_error(run, path + ":" + str(lineno) + ": not a JSON object")
                    continue
                kind = record.get("type")
                if kind == "bridge-session":
                    owner = record.get("ownerAccountUuid")
                    if isinstance(owner, str) and owner:
                        account_uuid = owner
                elif kind == "user":
                    if not seen_user:
                        seen_user = True
                        if record.get("entrypoint") == "sdk-py":
                            return None
                    _collect_results(record, results)
                cwd = record.get("cwd")
                if not member and isinstance(cwd, str):
                    cwd = os.path.normpath(cwd)
                    member = any(_under(cwd, root) for root in roots) or cwd.startswith(worktrees)
                node = _node(record)
                if node is not None:
                    by_uuid[node.uuid] = len(nodes)
                    nodes.append(node)
    except OSError as exc:
        _record_error(run, "read " + path + ": " + (exc.strerror or str(exc)))
        return None
    if not member or not nodes:
        return None
    chain = _active_chain(nodes, by_uuid)
    return _session(path, mtime, chain, results, matcher, checkouts, account_uuid, accounts)


def slot_accounts(slot_roots: list[str]) -> dict[str, str]:
    """Map each slot's account uuid to its slot number.

    The account is oauthAccount.accountUuid of the slot's state file:
    <home>/.claude.json for <home>/.claude (slot 1), <root>/.claude.json for
    <home>/.claudeN (slot N). A missing or unreadable file, or one without
    the field, is skipped; when two slots hold one account the first wins.
    """
    accounts: dict[str, str] = {}
    for root in slot_roots:
        root = os.path.normpath(root)
        name = os.path.basename(root)
        if not name.startswith(".claude"):
            continue
        number = name[len(".claude") :]
        if number:
            state, slot = os.path.join(root, ".claude.json"), number
        else:
            state, slot = os.path.join(os.path.dirname(root), ".claude.json"), "1"
        try:
            with open(state, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            continue
        account = data.get("oauthAccount") if isinstance(data, dict) else None
        account_uuid = account.get("accountUuid") if isinstance(account, dict) else None
        if isinstance(account_uuid, str) and account_uuid:
            accounts.setdefault(account_uuid, slot)
    return accounts


@dataclass(slots=True)
class _Node:
    """What the chain walk and the session fields need from one record with a uuid.

    user_class and request are set for a user record (request holds the
    text of a genuine request); message_id, texts and tool_uses (id, name,
    input) for an assistant record.
    """

    uuid: str
    parent: str | None
    logical_parent: str | None
    kind: str
    ts: str
    cwd: str | None
    branch: str | None
    entrypoint: str | None
    user_class: str = ""
    request: str = ""
    message_id: str | None = None
    texts: list[str] = field(default_factory=list)
    tool_uses: list[tuple[str, str, dict[str, Any]]] = field(default_factory=list)


def _node(record: dict[str, Any]) -> _Node | None:
    uuid = _string(record.get("uuid"))
    if not uuid:
        return None
    node = _Node(
        uuid=uuid,
        parent=_string(record.get("parentUuid")),
        logical_parent=_string(record.get("logicalParentUuid")),
        kind=_string(record.get("type")) or "",
        ts=_string(record.get("timestamp")) or "",
        cwd=_string(record.get("cwd")),
        branch=_string(record.get("gitBranch")) or None,
        entrypoint=_string(record.get("entrypoint")),
    )
    if node.kind == "user":
        node.user_class, node.request = _classify(record)
    elif node.kind == "assistant":
        message = record.get("message")
        if isinstance(message, dict):
            node.message_id = _string(message.get("id")) or None
            for block in _blocks(message.get("content")):
                if block.get("type") == "text" and isinstance(block.get("text"), str):
                    node.texts.append(block["text"])
                elif block.get("type") == "tool_use":
                    use_id, name, tool_input = block.get("id"), block.get("name"), block.get("input")
                    if isinstance(use_id, str) and isinstance(name, str):
                        node.tool_uses.append((use_id, name, tool_input if isinstance(tool_input, dict) else {}))
    return node


def _classify(record: dict[str, Any]) -> tuple[str, str]:
    """classify_user's answer and, for a request, its remaining text."""
    message = record.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    blocks = _blocks(content)
    if any(block.get("type") == "tool_result" for block in blocks):
        return "tool_result", ""
    if record.get("isMeta") is True or record.get("isCompactSummary") is True:
        return "meta", ""
    kept = [block for block in blocks if not _harness_or_blank(block)]
    if not kept:
        return "local", ""
    texts = [block["text"] for block in kept if block.get("type") == "text"]
    return "request", "\n".join(texts).strip()


def _blocks(content: Any) -> list[dict[str, Any]]:
    """Content as a list of blocks: a string is one text block."""
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [block for block in content if isinstance(block, dict)]
    return []


def _harness_or_blank(block: dict[str, Any]) -> bool:
    if block.get("type") != "text":
        return False
    text = block.get("text")
    if not isinstance(text, str):
        return True
    stripped = text.lstrip()
    return not stripped or stripped.startswith(_LOCAL_PREFIXES)


def _collect_results(record: dict[str, Any], results: dict[str, bool]) -> None:
    """Note each tool result's outcome by tool_use_id: True unless is_error."""
    message = record.get("message")
    if not isinstance(message, dict):
        return
    for block in _blocks(message.get("content")):
        use_id = block.get("tool_use_id")
        if block.get("type") == "tool_result" and isinstance(use_id, str):
            results[use_id] = block.get("is_error") is not True


def _active_chain(nodes: list[_Node], by_uuid: dict[str, int]) -> list[_Node]:
    """The active chain in file order: the walk from the last node, plus its messages' other records."""
    walked: set[int] = set()
    position = len(nodes) - 1
    while position >= 0 and position not in walked:
        walked.add(position)
        node = nodes[position]
        parent = node.parent if node.parent is not None else node.logical_parent
        if parent is None:
            break
        found = by_uuid.get(parent)
        position = found if found is not None else position - 1
    messages = {nodes[index].message_id for index in walked if nodes[index].message_id is not None}
    siblings = {index for index, node in enumerate(nodes) if node.message_id is not None and node.message_id in messages}
    return [nodes[index] for index in sorted(walked | siblings)]


def _session(
    path: str,
    mtime: float,
    chain: list[_Node],
    results: dict[str, bool],
    matcher: NameMatcher,
    checkouts: list[str],
    account_uuid: str | None,
    accounts: dict[str, str],
) -> Session:
    cwds: dict[str, str | None] = {}
    cwd_counts: dict[str, int] = {}
    branch_counts: dict[str, dict[str, int]] = {}
    evidence: list[Evidence] = []
    first: tuple[datetime, str] | None = None
    last: tuple[datetime, str] | None = None
    user_turns = 0
    last_request = ""
    last_assistant = ""
    entrypoint: str | None = None
    seen_user = False
    ran_skill = False
    for node in chain:
        if node.cwd is not None:
            cwd_counts[node.cwd] = cwd_counts.get(node.cwd, 0) + 1
            if node.branch is not None or node.cwd not in cwds:
                cwds[node.cwd] = node.branch
            if node.branch is not None:
                branches = branch_counts.setdefault(node.cwd, {})
                branches[node.branch] = branches.get(node.branch, 0) + 1
        instant = _instant(node.ts)
        if instant is not None:
            if first is None or instant < first[0]:
                first = (instant, node.ts)
            if last is None or instant > last[0]:
                last = (instant, node.ts)
        if node.kind == "user":
            if not seen_user:
                seen_user = True
                entrypoint = node.entrypoint
            if node.user_class == "request":
                user_turns += 1
                last_request = node.request
                ran_skill = ran_skill or SKILL_COMMAND in node.request or REPORT_HEADER in node.request
                evidence.extend(Evidence("request", name, node.ts) for name in matcher.find(node.request))
        elif node.kind == "assistant":
            for text in node.texts:
                last_assistant = text
                ran_skill = ran_skill or REPORT_HEADER in text
                evidence.extend(Evidence("mention", name, node.ts) for name in matcher.find(text))
            for use_id, name, tool_input in node.tool_uses:
                command = tool_input.get("command")
                ran_skill = ran_skill or (isinstance(command, str) and SKILL_SCRIPT in command)
                if results.get(use_id) is True:
                    evidence.extend(_tool_evidence(name, tool_input, node, matcher, checkouts))
    return Session(
        id=os.path.splitext(os.path.basename(path))[0],
        path=path,
        mtime=mtime,
        cwds=cwds,
        first_ts=first[1] if first is not None else "",
        last_ts=last[1] if last is not None else "",
        user_turns=user_turns,
        last_request=last_request,
        last_assistant=last_assistant,
        ended_on_question=_ended_on_question(chain),
        entrypoint=entrypoint,
        account_uuid=account_uuid,
        slot=accounts.get(account_uuid, "unknown") if account_uuid is not None else "unknown",
        live=None,
        ran_skill=ran_skill,
        evidence=evidence,
        cwd_counts=cwd_counts,
        branch_counts=branch_counts,
    )


def _tool_evidence(
    name: str, tool_input: dict[str, Any], node: _Node, matcher: NameMatcher, checkouts: list[str]
) -> list[Evidence]:
    """Evidence from one successful tool call: work, else lookup, else none.

    An edit or write gives one work per paths entry its file lies under, so
    an edit inside a change directory that is also a dirty path counts for
    both items; each carries the checkout the path is relative to. A shell
    command matches names, never paths, so its evidence has no checkout.
    """
    if name in EDIT_TOOLS:
        target = tool_input.get("file_path") or tool_input.get("notebook_path")
        if isinstance(target, str) and target:
            if not os.path.isabs(target) and node.cwd:
                target = os.path.join(node.cwd, target)
            checkout, hits = matcher.find_paths_with_checkout(target, checkouts)
            if hits:
                return [Evidence("work", hit, node.ts, checkout) for hit in hits]
    searched = tool_input
    if name == "Bash" and isinstance(tool_input.get("command"), str):
        stripped = strip_fd_redirects(tool_input["command"])
        hits = matcher.find(stripped)
        if hits and is_state_changing(stripped):
            return [Evidence("work", hit, node.ts) for hit in hits]
        searched = {**tool_input, "command": stripped}
    found: list[str] = []
    for text in _strings(searched):
        for hit in matcher.find(text):
            if hit not in found:
                found.append(hit)
    return [Evidence("lookup", hit, node.ts) for hit in found]


def _ended_on_question(chain: list[_Node]) -> bool:
    """Whether the chain's last assistant message asks and no request follows it.

    The message is every chain record sharing the last assistant record's
    message id; it asks when its last text ends in ? or it calls
    AskUserQuestion.
    """
    last = None
    for position, node in enumerate(chain):
        if node.kind == "assistant":
            last = position
    if last is None:
        return False
    anchor = chain[last]
    message = [
        node
        for node in chain
        if node.kind == "assistant" and (node is anchor if anchor.message_id is None else node.message_id == anchor.message_id)
    ]
    texts = [text for node in message for text in node.texts]
    asks = bool(texts) and texts[-1].rstrip().endswith("?")
    asks = asks or any(name == QUESTION_TOOL for node in message for _, name, _ in node.tool_uses)
    return asks and not any(node.kind == "user" and node.user_class == "request" for node in chain[last + 1 :])


def _strings(value: Any) -> Iterator[str]:
    """Every string value at any depth of a tool input."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def _shell_tokens(command: str) -> list[str]:
    """Shell words and operators; quoted text is one word, a newline an operator.

    shlex drops a comment together with the newline that ends it, so every
    newline is doubled first and one survives as the separator. A doubled
    newline inside a quoted word changes no decision.
    """
    text = command.replace("\\\n", " ")
    lexer = shlex.shlex(text.replace("\n", "\n\n"), posix=True, punctuation_chars=_OPERATOR_CHARS)
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return [token.strip("'\"") for token in _FALLBACK_TOKEN.findall(text)]


def _is_operator(token: str) -> bool:
    return bool(token) and all(char in _OPERATOR_CHARS for char in token)


def _is_separator(token: str) -> bool:
    return bool(token) and all(char in _SEPARATOR_CHARS for char in token)


def _is_redirect(token: str) -> bool:
    # >( is a process substitution, not a file.
    return _is_operator(token) and ">" in token and "(" not in token


def _writes_a_file(tokens: list[str], index: int) -> bool:
    target = tokens[index + 1] if index + 1 < len(tokens) else ""
    if target == "/dev/null":
        return False
    # >&N and >&- move or close a descriptor.
    return not (tokens[index].endswith("&") and (target.isdigit() or target == "-"))


def _arguments(tokens: list[str], start: int) -> list[str]:
    """The words of one simple command from start: up to a separator, redirections and their targets left out."""
    arguments: list[str] = []
    index = start
    while index < len(tokens):
        token = tokens[index]
        if _is_separator(token):
            break
        if _is_operator(token):
            index += 2
            continue
        arguments.append(token)
        index += 1
    return arguments


def _command_words(tokens: list[str]) -> Iterator[int]:
    """Yield the index of the command word of every simple command in tokens."""
    expecting = True
    prefix: str | None = None
    skip_value = False
    awaiting_duration = False
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if _is_separator(token):
            expecting, prefix, skip_value, awaiting_duration = True, None, False, False
        elif expecting:
            if _is_operator(token):
                # A redirection before the command word, with its target.
                index += 1
            elif skip_value:
                skip_value = False
            elif prefix is not None and token.startswith("-"):
                skip_value = prefix == "timeout" and token in _TIMEOUT_VALUE_OPTIONS
            elif token in _COMMAND_KEYWORDS or _ASSIGNMENT.match(token):
                pass
            elif awaiting_duration:
                awaiting_duration = False
            elif token in _COMMAND_PREFIXES:
                prefix, awaiting_duration = token, token == "timeout"
            else:
                yield index
                expecting, prefix = False, None
        index += 1


def _git_invocation(tokens: list[str], start: int) -> tuple[str | None, list[str]]:
    """The subcommand and arguments of a git invocation whose words begin at start."""
    index = start
    while index < len(tokens) and tokens[index].startswith("-"):
        index += 2 if tokens[index] in _GIT_VALUE_OPTIONS else 1
    if index >= len(tokens) or _is_operator(tokens[index]):
        return None, []
    return tokens[index], _arguments(tokens, index + 1)


def _git_reads_only(subcommand: str, arguments: list[str]) -> bool:
    if subcommand == "branch":
        return not _branch_mutates(arguments)
    if subcommand == "stash":
        return bool(arguments) and arguments[0] in ("list", "show")
    if subcommand == "worktree":
        return bool(arguments) and arguments[0] == "list"
    return False


def _branch_mutates(arguments: list[str]) -> bool:
    """Whether git branch with these arguments changes refs.

    It does on a mutating option (alone or in a short cluster), or on a
    positional argument with no list-mode option. A list-mode option's own
    value (--contains abc, --sort -committerdate) is never a positional.
    """
    list_mode = False
    positional = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument.startswith("--"):
            name = argument.split("=", 1)[0]
            if name in _BRANCH_MUTATING_OPTIONS:
                return True
            if name in _BRANCH_LIST_OPTIONS:
                list_mode = True
            if name in _BRANCH_VALUE_OPTIONS and "=" not in argument:
                index += 1
        elif argument.startswith("-") and len(argument) > 1:
            letters = set(argument[1:])
            if letters & _BRANCH_MUTATING_LETTERS:
                return True
            if letters <= _BRANCH_LIST_LETTERS:
                list_mode = True
        else:
            positional = True
        index += 1
    return positional and not list_mode


def _under(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def _instant(stamp: str) -> datetime | None:
    """A timezone-aware instant, or None for an empty, unparsable or naive stamp."""
    if not stamp:
        return None
    try:
        at = datetime.fromisoformat(stamp)
    except ValueError:
        return None
    return at if at.tzinfo is not None else None


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _record_error(run: Run, line: str) -> None:
    run.errors.append(line)
    run.complete = False
