---
name: app-subagent-apply
description: Use when implementation work should be dispatched to subagents from the current session, whether the source is an apply-ready OpenSpec change, a superpowers plan file, or a PRD or spec that has no task list yet; also when the user says "apply via subagents", "subagent apply", or "dispatch the change".
user-invocable: true
---

# Implementing through subagents

## Overview

The source document knows what the work is. The
subagent-driven-development skill knows how to dispatch, review and fix.
This skill owns only the glue neither side knows about: the compact gate,
the commit question, the source adapter, the model policy, progress marks,
and the project gates.

**REQUIRED SUB-SKILL:** superpowers:subagent-driven-development. Read it
in full; this skill overrides only the points named below. Its
implementer, reviewer and re-review prompt templates apply as written,
with `section-N` in place of `task-N` for OpenSpec sources.

**Input:** `$ARGUMENTS` is an OpenSpec change name, a plan file path, a
PRD or spec path, or empty. When empty, infer the source from the
conversation; if more than one candidate exists, list them through
AskUserQuestion. Announce "Using source: <name>".

## Sources

| Source | Detect | Dispatch unit | Brief | Progress mark |
|---|---|---|---|---|
| OpenSpec change | `openspec/changes/<name>/tasks.md` exists | the unticked file-editing items of one `## N. Title` section of `tasks.md` | `scripts/openspec-section-brief <name> <N>` | the sub-skill's ledger, then tick the unit's items `- [ ]` to `- [x]` |
| Superpowers plan | markdown file with `## Task N` headings | one task, batched per the sub-skill's same-shape rule | the sub-skill's `scripts/task-brief PLAN N` | the sub-skill's ledger |
| PRD, spec, issue text | anything else | none yet | run superpowers:writing-plans first, then continue as a superpowers plan | as above |

**OpenSpec load.** Run `openspec status --change <name> --json` and
`openspec instructions apply --change <name> --json`. Read `state`,
`progress`, every file under `contextFiles`, and follow the `instruction`
field for what to render at start and at finish (task table, "What
shipped", commit-message suggestion). Do not restate those here.

**OpenSpec workspace.** Briefs, reports, review packages and the ledger
live in `.superpowers/sdd/<change>/`. The sub-skill's `sdd-workspace`
derives its directory from the plan basename, which is `tasks` for every
change, so pass an explicit output path under the change directory to
every sub-skill script that accepts one. Once `/opsx:archive` has run,
delete the change directory.

**Merged units.** The sub-skill's pre-flight scan may merge or reorder
sections for dependency reasons. A merged unit's brief is the
concatenation of its section briefs, and the ordering ruling goes in
the ledger.

**Items that are not dispatched.** Command-only items (validate, lint,
test) run in the controller; when they are the same commands as the
gates in step 8, one controller run serves both and ticks them. A
single-file doc or config edit with no test is done by the controller.
Items with an external side effect (push, merge request, ticket comment)
stop for the user.

## Steps

1. **Compact gate.** If this session drafted or discussed the source
   (brainstorm, proposal, design, grilling, plan writing), print exactly
   this line, tell the user to re-invoke the skill afterwards, and stop:

   ```
   /compact Keep the source name <name>, its decisions, and open questions. Drop the brainstorming, grilling and planning transcript; the documents are on disk.
   ```

   A fresh or already compacted session continues.

2. **Load and resume check.** Load the source per the table. If the
   workspace already holds a `progress.md` ledger, this is a resume:
   read it, keep its units, rulings and recorded answers, and continue
   from its last line. Do not re-cut units, re-dispatch a unit the
   ledger marks complete, or re-ask a question the ledger answers. Show
   progress `N/M` with the remaining units.

3. **Commit question.** On a fresh run, ask once through
   AskUserQuestion: commit each reviewed unit on the current branch
   `<branch>`, or leave all changes in the working tree. Never create or
   switch a branch or worktree on your own initiative; do so only when
   the user asks explicitly, and then before the first dispatch. This
   replaces the sub-skill's worktree setup: work happens in the current
   checkout. Implementers commit only under the first answer,
   path-limited per `~/.claude/rules/git.md`. Record the answer as a
   `Commit mode:` line in the ledger.

   Then run `git status --short`. If the tree holds uncommitted changes
   in files the pending units touch, stop and ask whether they are to
   keep, commit or discard. Nothing is dispatched onto a dirty tree.

4. **Dispatch** per the table. The dispatch prompt carries the brief
   path, the interfaces settled by earlier units, the report path, and
   the sentence "Do not tick `tasks.md`; the controller marks progress".
   Design, spec and PRD text travel as paths, never pasted.

5. **Model policy.** Pass `model` on every Agent call. A model
   instruction from the user, spoken or recorded in the ledger, outranks
   this table for the roles it names.

   | Role | Model |
   |---|---|
   | Implementer | `opus` |
   | Implementer, fix rounds 4 and 5 | `fable` |
   | Task reviewer (spec compliance, code quality) | `fable` |
   | Scoped re-review of a small fix diff | `opus` |
   | Final whole-branch review, one dispatch | `fable` |

   A unit that needs a decision the source does not settle is not
   dispatched: stop and ask the user. The two-stage task review and the
   fix-loop shape are unchanged from the sub-skill.

6. **Drift.** An implementer or reviewer that reports a mismatch between
   code and the source stops the loop. Surface it, amend the source
   document with the user (OpenSpec artifacts, the plan file, or the plan
   derived from the PRD), regenerate the affected brief, then continue.
   Never diverge silently.

7. **Mark progress** only after the unit's task review passes, per the
   table. Not on the implementer's report. Ledger first, ticks second.
   Implementers never tick; if one did, verify the tick against the
   review before keeping it.

8. **Gates.** Run the project's quality gates in the controller under
   superpowers:verification-before-completion: the lint, static analysis
   and test commands the project's `CLAUDE.md` or task runner (composer,
   npm, Makefile, justfile, cargo, gradle) defines, plus the tests
   targeted at the touched areas. If the project defines none, say so
   instead of inventing one. Paste the real output. A failing gate goes
   back to an implementer dispatch.

9. **Finish.** Dispatch the `fable` whole-branch review, pointed at the
   ledger's deferred and parked lines. Fix findings through implementer
   dispatches. The final message lists every `Ruling:` line from the
   ledger, then units completed and overall progress. For an OpenSpec
   change, render what the `instruction` field asks for and suggest
   `/opsx:archive`; keep the workspace until the archive is done. Do not
   invoke the sub-skill's finishing-a-development-branch step: merge and
   merge request are the user's. Commit or push only when asked.

## Common mistakes

- Re-dispatching a unit the ledger already marks complete because
  `tasks.md` ticks were the only progress read.
- One dispatch per checkbox item of an OpenSpec section: three subagents
  for same-shape edits the section already groups.
- Dispatching a PRD directly: no unit boundaries, no review surface.
- Omitting `model`: the subagent inherits the controller's model.
- Pasting the design or PRD into the prompt: it stays resident in the
  controller's context for the rest of the session.
- Reading the diff in the controller instead of dispatching reviewers.
- Marking progress on the implementer's report, before review.
- Letting `review-package` write to `.superpowers/sdd/tasks/`.
- Editing `.claude/commands/opsx/apply.md` instead: `openspec update`
  regenerates it.
