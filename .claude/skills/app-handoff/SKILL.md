---
name: app-handoff
description: 'Use when the user asks for a handoff of the current work so it can continue in another session, another account slot or another agent tool: "/app-handoff", "write a handoff", "hand this off", "prepare a handoff", "handoff for a new session". Only on request, never on your own initiative.'
argument-hint: '[topic]'
user-invocable: true
---

# Handoff

A handoff lets a session in any agent tool continue this work without the
conversation. Write it while this session still knows all it concluded.

## Steps

1. Choose the topic: the argument, else two to four words naming the work.
2. In the working directory of the work being handed off, run this, with
   each `'` in the topic written as `'\''`:
   ```bash
   bash ~/.claude/skills/app-handoff/scripts/handoff.sh new --source "Claude Code session ${CLAUDE_SESSION_ID}" '<topic>'
   ```

   It creates the file, fills the header and prints the file's absolute path.
   That file is the handoff: never create, rename or move one yourself.
3. Replace every `<!-- FILL -->` marker with its section's content (table
   below). Leave the header and the snapshot notice as the script wrote them.
4. Run `bash ~/.claude/skills/app-handoff/scripts/handoff.sh check '<path>'`
   (each `'` in the path as `'\''`) until it prints `ok`, fixing what it reports.
5. Reply in the shape under "The reply".
6. Stop: do not start the next steps, compact the session or delete handoffs.

Fill the file from what the session already knows. A check or next step is
written down, not run: an unchecked assumption stays `Unverified:` and its
check stays the step it was. "I will run it first so the handoff is
accurate" does the next session's work without the owner. Write the step.

## What each section holds

| Section | Holds |
|---|---|
| Goal | What the owner wants, and why. |
| State | What is done and what is half done, by file. |
| Decisions | Each decision, with its reason. |
| Ruled out | Each cause or option ruled out, with its reason. |
| Facts established | Each fact with how it was verified (run, read, measured). Then, as separate items, each assumption marked `Unverified:`, with the check that would settle it. |
| Owner's instructions from this session | Instructions no instruction file holds, such as "stay on this branch". Each approval of an outward or irreversible action (push, deploy, delete, send), as history: `Approved earlier in this session: <action>. Ask the owner again before <action>.` |
| Open questions | Questions for the owner, numbered. |
| Next steps | Numbered, in the order the session planned, starting with the step it would have taken next. A step that needs an open question's answer names that question. A push, deploy or delete step starts with asking the owner. |
| In flight | Each background command, watcher, delegated agent or scheduled wakeup that ends with this session: what it was doing, and how the next session restarts it. |
| Pointers | Files, specs, plans, tickets, URLs. |

A section with nothing to report holds `None.`

## Rules for the text

- Self-contained: a reader who never saw this conversation can act on it.
- Conclusions, not a history of the session.
- Tool-neutral: describe a workflow by what it does and add its name as a
  hint. No instruction depends on one agent tool's commands, tool names,
  slash commands or instruction files; plain shell commands are fine.
- No secret values. Name where the secret lives: the file and the variable.
- It draws on everything the session knows, including reasoning never
  written in a reply: decisions, ruled-out causes, assumptions.
- Approvals for outward or irreversible actions are history. The next
  session asks the owner again.

## The reply

Three parts, in this order, and the reply ends there:

1. A summary of three to five lines, one sentence of under 80 characters
   per line: the work, where it stands, the next step, and how many open
   questions the file holds.
2. The file's absolute path, alone on its line.
3. The line to paste, in a code block, with the absolute path for `<path>`:

   ```text
   Read <path> and continue the work it describes. Check its recorded state against the live checkout first.
   ```

## Example

After `/app-handoff invoice export` in `~/projects/shop-api`, part of the file:

```markdown
## Facts established

- Exports over 10,000 invoices time out at 60 s. Verified: ran 9,000 and 11,000.
- Unverified: the timeout is the proxy's, not the app's. Next step 1 checks it.

## Owner's instructions from this session

- Approved earlier in this session: deploying to staging once the tests
  pass. Ask the owner again before deploying.

## Next steps

1. Read the proxy's timeout in `deploy/proxy.conf`.
2. Stream the export instead of building it in memory.
3. Ask the owner, then deploy to staging.

## In flight

- Template watcher, `make watch`: ends with this session. Restart it for step 2.
```

The reply:

````text
Handoff written for the invoice export timeout on shop-api.
Exports over 10,000 invoices time out, and nothing is committed yet.
The next step is checking the proxy's timeout.
The file holds one open question.

/home/dev/.agents/app/handoffs/2026-11-13-1630-shop-api-invoice-export.md

```text
Read /home/dev/.agents/app/handoffs/2026-11-13-1630-shop-api-invoice-export.md and continue the work it describes. Check its recorded state against the live checkout first.
```
````
