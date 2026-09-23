---
name: app-subagent-apply
description: Use when implementation work should be dispatched to subagents from the current session, whether the source is an apply-ready OpenSpec change, a superpowers plan file, or a PRD or spec that has no task list yet; also when the user says "apply via subagents", "subagent apply", or "dispatch the change".
user-invocable: true
---

# Implementing through subagents

**REQUIRED SUB-SKILL:** superpowers:subagent-driven-development runs the loop: dispatch, task review, fix rounds, ledger, final review. Invoke it with the Skill tool on every invocation of this skill (after a `/clear` nothing is loaded), unless its full text is already in this transcript. This skill adds only the source adapter, this machine's constraints, and five overrides that each fix a failure measured in real runs.

**Input:** `$ARGUMENTS` is an OpenSpec change name, a plan file path, a PRD or spec path, or empty (infer from the conversation; several candidates: AskUserQuestion). Announce "Using source: <name>".

## Sources

| Source | Detect | Unit, brief, mark |
|---|---|---|
| OpenSpec change | `openspec/changes/<name>/tasks.md` exists | one `## N.` section (`2b` is its own); `scripts/openspec-section-brief <name> <N> <ws>/section-N-brief.md`; after the review passes, `scripts/openspec-section-tick <name> <N> '<ledger line>' [ids]` writes the ledger line and then the ticks, never by hand |
| Superpowers plan | a `Task N` heading at any level | one task per the sub-skill; `scripts/task-brief <plan> <N> <ws>/task-N-brief.md` (this copy keeps trailing sections and `Task Nb` out of the brief) |
| PRD, spec, issue | anything else | superpowers:writing-plans first, then continue as a plan |

`<ws>` is `.superpowers/sdd/<name>/` for OpenSpec (every change's file is `tasks.md`, so never run `sdd-workspace`; give every sub-skill script this OUTFILE) and the sub-skill's default for plans. Ledger lines say `Section N:` or `Task N:`. Dispatch prompts carry paths (brief, report, `<ws>/decisions.md` for rulings and interfaces settled by earlier units); design, spec and prior-unit context never travel inline.

**OpenSpec.** Load with `openspec instructions apply --change <name> --json | jq '{state, progress, tasks, instruction}'`, never raw. `blocked`: print the instruction, stop. `all_done`: render the table, suggest `/opsx:archive`, stop. `ready`: read `tasks.md` and the spec deltas once for the pre-flight scan; proposal and design reach implementers as paths. The instruction's "mark complete as you go" is superseded: the controller ticks after review. Command-only items run in the controller and tick when they pass; prose-only edits are the controller's and the final review covers them; anything executable or declarative goes to an implementer; an external side effect (push, merge request, ticket) stops for the user. A code-to-source mismatch stops the loop: amend the source with the user, `openspec validate <name> --strict`, regenerate the brief. At the end, render what `instruction` asks, suggest `/opsx:archive`, and delete `<ws>` only after the archive.

## This machine

1. **Clear gate.** If this session drafted or discussed the source: write every decision or open question that is not yet in the source's documents into them (OpenSpec: the design's decisions; a plan: the plan file), then print exactly `/clear` and, on the next line, `/app-subagent-apply <name>`; tell the user to run both, or to start a fresh session with the second line, and stop. The apply needs only what is on disk.
2. **Resume.** If `<ws>/progress.md` exists: `head -n 3`, `grep -nE '^(Run base|Commit mode|Model policy|Model fallback|Checkpoint|Gates|Ruling|Open before merge):|: (complete|parked)'`, `tail -n 20`; never the whole file. Keep its units, rulings and answers; re-dispatch nothing marked complete.
3. **Consent, not worktrees.** Ask once through AskUserQuestion: implementers commit on `<branch>` as they go, path-limited per `~/.claude/rules/git.md`; continue, or stop to create a branch first? Never create or switch a branch yourself. Stop on uncommitted changes in the units' files. Ledger `Run base: <sha7>` and `Commit mode: commit on <branch>`.
4. **Models.** Aliases `sonnet`, `opus`, `fable`; the sub-skill's Model Selection picks the tier. Before the first dispatch, ledger `Model policy: <unit>: implementer <tier>, reviewer <tier>` for every unit, with the reason wherever a tier is below the mid-tier floor. `fable` is capped on this account: the final review and rounds 4 and 5 only. On `rate_limit`, `429` or `reached your <tier> limit`: ledger `Model fallback: <role> <from> -> <to>`, run that role one tier down for the rest of the session, never re-probe.
5. **Gates.** superpowers:verification-before-completion with the project's own lint, analysis and test commands (OpenSpec: `openspec validate <name> --strict` first); none defined: say so. Ledger `Gates: <commands> passed`.
6. **Subagent types.** Implementers dispatch as `app-sdd-implementer`; task reviewers, re-reviewers and the final reviewer as `app-sdd-reviewer` (definitions in `~/.claude/agents/`; their `model` line is a fallthrough only, item 4 still names the model on every dispatch).

## Overrides of the sub-skill

1. **Reviews go to files.** Every reviewer dispatch appends the matching file under this skill's `prompts/` by path (`reviewer-overrides.md`, `re-review-overrides.md`, `final-review-overrides.md`; implementers get `implementer-overrides.md`): the report is written to `<ws>/section-N-review.md` (`-rR` for re-reviews, `final-review.md`) and the final message is a verdict block. Fix messages name that file and the open ids; Minor findings never enter a round.
2. **Fresh implementer above 300,000 tokens** (the last task-notification's figure), on the same tier as the implementer it replaces, and always for rounds 4 and 5 on the tier above, with the brief, report and review paths and "A prior implementer attempted this unit R-1 times; you own it now." A round is any message asking for code; after the fifth re-review, rule and ledger, never a sixth.
3. **One implementer at a time.** Unit N+1 starts after unit N's `complete` line; two writers share one index.
4. **Checkpoint.** After the third `complete` line since the last `Checkpoint:` line (sources of four or more units) and again before the final review, with no implementer live: ledger every ruling and user answer since the last checkpoint that is not yet a ledger line, then ledger `Checkpoint: N/M, next <unit>`, print exactly `/clear` and, on the next line, `/app-subagent-apply <name>`, tell the user to run both, stop. Step 2 resumes from the ledger; a compaction summary carries nothing the ledger and `<ws>` do not and costs a read of the whole context.
5. **Final review** over `Run base`..HEAD (never `git merge-base`, which is HEAD on `main`), on `fable` or its fallback, requirements as paths plus the ledger's deferred and parked lines; then ONE fix dispatch with the whole Critical and Important list, ONE scoped re-review, the gates again. Leftovers are ledgered `Open before merge: <finding>. Ruling: <decision>. Cost if wrong: <what>`; no second wave. The final message lists every `Ruling:` and `Open before merge:` line. Skip finishing-a-development-branch; commit or push only when asked.
