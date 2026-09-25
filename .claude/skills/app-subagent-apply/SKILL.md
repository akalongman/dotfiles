---
name: app-subagent-apply
description: Use when implementation work should be dispatched to subagents from the current session, whether the source is an apply-ready OpenSpec change, a superpowers plan file, or a PRD or spec that has no task list yet; also when the user says "apply via subagents", "subagent apply", or "dispatch the change".
user-invocable: true
---

# Implementing through subagents

**REQUIRED SUB-SKILL:** superpowers:subagent-driven-development defines the loop (dispatch, task review, fix rounds, ledger, final review); tested against superpowers 6.4.1. This session is the driver and never runs the loop itself: each unit runs inside one `app-sdd-unit-controller` subagent (definition in `~/.claude/agents/`, the loop preloaded), which dispatches the implementer and reviewers one layer down under `prompts/unit-controller-overrides.md`, passed by path. This skill adds the source adapter, this machine's constraints, the driver loop and the hands-off ending.

**Input:** `$ARGUMENTS` is an OpenSpec change name, a plan file path, a PRD or spec path, or empty (infer from the conversation; several candidates: AskUserQuestion), optionally followed by `step` or `hands-off`, `isolated`, and `tier=<alias>`. Announce "Using source: <name>" and the options given.

## Sources

| Source | Detect | Unit, brief, mark |
|---|---|---|
| OpenSpec change | `openspec/changes/<name>/tasks.md` exists | one `## N.` section (`2b` is its own); `scripts/openspec-section-brief <name> <N> <ws>/section-N-brief.md`; completion marked only by `scripts/openspec-section-tick <name> <N> '<ledger line>' [ids]`, which writes the ledger line and then the ticks |
| Superpowers plan | a `Task N` heading at any level | one task per the sub-skill; `scripts/task-brief <plan> <N> <ws>/task-N-brief.md` (this copy keeps trailing sections and `Task Nb` out of the brief) |
| PRD, spec, issue | anything else | superpowers:writing-plans first, then continue as a plan |

`<ws>` is `.superpowers/sdd/<name>/` for OpenSpec (every change's file is `tasks.md`, so never run `sdd-workspace`; give every sub-skill script this OUTFILE) and the sub-skill's default for plans. Ledger lines say `Section N:` or `Task N:`. Dispatch prompts carry paths only; design, spec and prior-unit context never travel inline.

**OpenSpec.** Load with `openspec instructions apply --change <name> --json | jq '{state, progress, tasks, instruction}'`, never raw. `blocked`: print the instruction, stop. `all_done`: render the table, suggest `/opsx:archive`, stop. `ready`: read `tasks.md` and the spec deltas once for the pre-flight scan; proposal and design reach implementers as paths. "Mark complete as you go" is superseded: the unit controller ticks after review. Command-only items run in the driver; prose-only edits are the driver's, covered by the final review; anything executable or declarative goes to a unit; an external side effect stops for the user unless hands-off. A task that can only run after merge is a source defect: the pre-flight scan flags it and it is amended with the user into a pre-merge task that writes it to the merge request's `### Post-merge checks` list, never parked, because the change archives before the request merges. A mismatch between code and source returns as `needs-ruling`: amend the source with the user, `openspec validate <name> --strict`, regenerate the brief, resume the controller. At the end, render what `instruction` asks, suggest `/opsx:archive`, delete `<ws>` only after the archive.

## This machine

1. **Resume.** If `<ws>/progress.md` exists: `head -n 3`, `grep -nE '^(Run base|Commit mode|Model policy|Model fallback|Gates|Ruling|Open before merge|Hands-off):|: (complete|parked)'`, `tail -n 20`; never the whole file. Keep its units, rulings and answers; re-dispatch nothing marked complete or parked.
2. **Branch.** The run commits on the current branch, path-limited per `~/.claude/rules/git.md`, the default branch included; never create or switch a branch unless `isolated` was given. Stop on uncommitted changes in the units' files. Ledger `Run base: <sha7>` and `Commit mode: commit on <branch>`.
   **Isolated.** With `isolated`: `git worktree add .worktrees/<name> -b <name>` from HEAD, then the project's bootstrap, the first that exists: `composer worktree:setup`, `npm run worktree:setup`, `make worktree:setup`; none: stop before any dispatch and say so. Run from the worktree; ledger `Commit mode: commit on <name> in .worktrees/<name>`. The worktree stays until the user runs the project's teardown.
3. **Models.** Aliases `sonnet`, `opus`, `fable`. Unit controllers, implementers and reviewers dispatch on `opus`, or on `tier=<alias>` when given; the final review and fix rounds 4 and 5 on `fable`, which is capped on this account; `sonnet` only for a unit the user names. Ledger `Model policy: <tier per role>` before the first dispatch. On `rate_limit`, `429` or `reached your <tier> limit`: ledger `Model fallback: <role> <from> -> <to>`, run that role one tier down for the rest of the run, never re-probe; a unit controller that hits it writes the same line, and every later dispatch reads the marker lines first.
4. **Gates.** superpowers:verification-before-completion with the project's own lint, analysis and test commands (OpenSpec: `openspec validate <name> --strict` first); none defined: say so. The unit controller runs them per unit and in the final phase; ledger `Gates: <commands> passed`.

## Driver loop

Pre-flight once: read the installed sub-skill's version directory under the plugin cache, ledger `Sub-skill: <version>`, print one warning line if it is not 6.4.1; then the sub-skill's scan of the whole source, rulings into `<ws>/decisions.md`. Then for each unit in order:

1. Write the brief with the source's script. Ledger `Section N: handed to controller`.
2. Dispatch `app-sdd-unit-controller` on the tier of item 3 with paths only: the brief, `<ws>/section-N-report.md`, `<ws>/section-N-review.md`, `<ws>/progress.md`, `<ws>/decisions.md`, this skill's `prompts/unit-controller-overrides.md`, the source's tick command, and the line `Mode: hands-off` when given. Wait for its return block.
3. `complete` or `parked`: next unit; with `step`, first show the block and ask continue or stop (AskUserQuestion), and on stop ledger `Stopped by user after <unit>` and end. `needs-ruling`: ask the user (AskUserQuestion), ledger `Ruling: <answer>`, append it to `decisions.md`, resume the same controller by message with the ruling. `failed`, or an error on the dispatch: dispatch once more with "A prior controller attempted this unit; read the ledger tail, the report and `git diff --stat` on the unit's paths first"; a second failure stops the run, or under hands-off ledgers `Section N: parked (controller failed twice)` and moves on.
4. Never edit source, the task file or a unit's ledger lines yourself. A message from the user during a unit is forwarded to the live controller by message.

After the last unit, write `<ws>/final-brief.md` (Run base, HEAD, the gate commands, and the ledger's deferred, parked and ruling lines as a path), dispatch `app-sdd-unit-controller` for the final phase with the same paths plus `<ws>/final-review.md`, and wait. The final message lists every `Ruling:` and `Open before merge:` line and ends with the record repository's three `tools/transcript-*.py` commands filled in with this session's transcript path when the harness exposes the session id, else the project directory and the run's start time. Skip finishing-a-development-branch; commit or push only when asked, unless hands-off.

## Hands-off

With `hands-off` nothing stops after the launch: unit controllers rule on their own reading and ledger `Ruling: <decision>. Cost if wrong: <what>`; mismatches are parked. After the final phase: `git push -u origin <branch>`. Off the default branch, open the request with the run summary and every `Ruling:`, parked and `Open before merge:` line as its description: `glab mr create` when the remote's fetch URL host is a GitLab instance (self-hosted included), `gh pr create` when it is `github.com`, otherwise stop and say the branch is pushed. On the default branch, push and open nothing. Ledger `Hands-off: pushed <sha7>, <request URL or none>`.
