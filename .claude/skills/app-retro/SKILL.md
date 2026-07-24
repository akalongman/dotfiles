---
name: app-retro
description: Use when the user asks for a retro of recent Claude Code sessions, wants to know what went wrong lately or which mistakes keep repeating across sessions, or wants CLAUDE.md, rule files, skills, or memories reviewed against actual past-session behavior. Also after a stretch of heavy usage when recurring friction is suspected.
argument-hint: [days back, default 7]
---

# Session Retro

## Overview

Mine recent session transcripts across all projects for correction signals,
cluster them into recurring patterns, and propose edits to `~/.claude/CLAUDE.md`,
`~/.claude/rules/*.md`, skills, hooks, or memories. Read-only until the final
phase; nothing is written without explicit user approval.

Not for in-session reflection (the Self-improvement section of CLAUDE.md handles
the current session at the moment of correction) and not for project-docs
learnings (that is `/learn`).

## Ground facts about transcripts

- Location: `~/.claude/projects/<dash-encoded-cwd>/<session-uuid>.jsonl`, one
  file per session. A week of activity is commonly 200+ files; grep for signals,
  never read files whole.
- Project directory names start with `-`, so a relative path passed to `jq` or
  `grep` is parsed as a CLI option and fails (jq prints its usage help). Always
  use absolute paths. `find ~/.claude/projects ...` already emits absolute paths.
- Record `.type` values include `user`, `assistant`, and many noise types
  (`attachment`, `queue-operation`, `ai-title`, `last-prompt`, `mode`,
  `permission-mode`, `bridge-session`, `system`, `file-history-snapshot`).
- Tool results arrive as `user`-type records. A human-typed prompt is a `user`
  record whose `.message.content` is a **string**; array content is tool_result
  blocks. Filter with `.isSidechain == false` to drop subagent traffic.
- String content is still not always human: Stop-hook feedback
  (`Stop hook feedback:`), compact/continuation session summaries (multi-KB
  blobs), and slash-command wrappers (`<command-name>`, `local-command-stdout`)
  also arrive as string-content user records. Exclude them before treating a
  match as the user's voice.
- Subagent transcripts live under `<project>/<session-uuid>/subagents/` and
  duplicate signals; exclude that path in the find.

## Phase 1: Scope

`DAYS` = argument or 7. `SCRATCHPAD` = your session scratchpad directory (named
in the system prompt). Exclude files still being written (the live session) and
subagent transcripts:

```bash
DAYS=7
SCRATCHPAD=<your scratchpad dir>
find ~/.claude/projects -name '*.jsonl' -mtime -"$DAYS" -mmin +10 \
  -not -path '*/subagents/*' > "$SCRATCHPAD/retro-files.txt"
wc -l "$SCRATCHPAD/retro-files.txt"
```

Per-file commands below assume this loop shape:

```bash
while read -r f; do <command> "$f"; done < "$SCRATCHPAD/retro-files.txt"
```

## Phase 2: Extract signals

Strongest first. Track per-file counts; the per-project directory name and file
mtime label each finding.

1. **Rejected tool calls with stated reasons.** When the user types a reason,
   the rejection message embeds it after "the user said:", the highest-quality
   signal available. A bare denial reads "(No answer provided)"; the reason, if
   any, is then the next typed prompt.

```bash
xargs -d '\n' grep -l "doesn't want to proceed" < "$SCRATCHPAD/retro-files.txt"
# per matching file, print the full rejection strings (reason included):
jq -r '.. | strings | select(test("user doesn.t want to proceed"))' "$f"
```

   `.. | strings` also matches text that merely quotes the rejection phrase
   (docs, skill discussions); confirm a hit is an actual tool_result before
   counting it.

2. **Interruptions.** `[Request interrupted by user]` and
   `[Request interrupted by user for tool use]` mean the user stopped a turn
   mid-flight. Count per file, then inspect what was being attempted.

3. **Corrective language in typed prompts.** Extract only real human text, then
   flag candidates:

```bash
jq -r 'select(.type=="user" and .isSidechain==false and (.message.content|type)=="string") | .message.content' "$f" \
  | grep -vE 'Stop hook feedback:|<command-name>|local-command-stdout' \
  | grep -inE '\b(no[,.]|wrong|not what|don.t|stop|instead|again|why (did|are) you|i (told|said|asked))\b'
```

   Read every match in context. Most matches are innocent, and hits inside
   multi-KB continuation summaries are not the user speaking; counts are not
   findings. Expect a high false-positive rate (roughly 9 in 10).

4. **Repeated tool errors.** `grep -c '"is_error":true' "$f"` is a weak,
   high-volume signal. Pursue only when the same error text recurs across
   sessions.

## Phase 3: Context around a hit

Noise records cluster thickly around real ones, so use a wide window and keep
only conversation records:

```bash
grep -n 'PATTERN' "$f" | cut -d: -f1        # record line number N
sed -n "$((N-15)),$((N+15))p" "$f" | jq -r 'select(.type=="user" or .type=="assistant") | "\(.type): \((.message.content // "") | if type=="string" then . else ([.[]? | .text? // (.content | if type=="string" then . else "" end)? // ""] | join(" ")) end | gsub("\\s+"; " ") | .[0:200])"'
```

## Phase 4: Cluster

A pattern is the same underlying cause in 2+ distinct sessions. One-offs qualify
only when severe (destructive action, data loss, visible frustration). For each
pattern record: root cause, evidence (project, session file, date), and which
rule or knowledge was missing or ignored.

## Phase 5: Route each pattern

Use the decision tree from the Self-improvement section of CLAUDE.md: user- or
project-specific goes to a memory file; a cross-project rule goes to CLAUDE.md or
the matching `~/.claude/rules/*.md`; a repeatable workflow becomes a skill or
hook. Read the target file first. If the rule already exists and was violated
anyway, propose rewording, relocation, or enforcement (a hook), never a
duplicate.

## Phase 6: Prune the files you touch

For every file you propose to edit, also flag: dated facts gone stale, rules
duplicated elsewhere, rules superseded by newer ones. Propose deletions
alongside additions. A retro that only ever adds text degrades the config it is
trying to improve.

## Phase 7: Report and approval (BLOCKING)

Present, in one message:

1. A table: pattern, occurrences, sessions, proposed target file, add/change/remove.
2. The exact proposed edits, diff-style.
3. Observations judged not actionable, one line each.

Wait for explicit approval per edit before writing anything.

## Common mistakes

| Mistake | Fix |
|---|---|
| Relative transcript paths | Directory names start with `-` and parse as options. Absolute paths only. |
| Treating tool_result text as user speech | Human prompts are string-content `user` records with `isSidechain==false`. |
| Scoring by grep counts | Read every flagged match; corrective-word hits are mostly innocent. |
| Proposing a duplicate rule | Existing-but-violated rules need rewording, relocation, or enforcement. |
| Additions only | Run the prune phase on every file you touch. |
| Mining the live session | Keep the `-mmin +10` filter in the find command. |
| Counting subagent transcripts | `<session>/subagents/*.jsonl` duplicates signals; keep the `-not -path` filter. |
