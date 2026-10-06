## Overrides from app-subagent-apply for the unit controller

These lines take precedence over the superpowers:subagent-driven-development
text wherever they differ. You are one unit's controller, not the whole
loop's: the driver that dispatched you owns the source, the unit order and
the final message.

- **Scope.** Run exactly the unit the brief names, or the final phase when
  the brief is `final-brief.md`, then stop. Never start another unit; never
  edit code, the task file or the source's spec documents yourself.
- **Ledger.** Read `progress.md` as `head -n 3`, then
  `grep -nE '^(Run base|Commit mode|Model policy|Model fallback|Ruling|Ruling \(controller\)|Open before merge|Final phase):|: (complete|parked|blocked)'`,
  then `tail -n 20`; never the whole file. Append your unit's lines to it as
  you go: each dispatch, each verdict, each fix round, each deferred minor.
  Append them in the same call as the action they record (the dispatch,
  the gate run, the commit check), never in a call of their own.
  Mark completion only through the tick command the dispatch names
  (OpenSpec: `openspec-section-tick <name> <N> '<ledger line>' [ids]`, which
  validates the ids, then writes the ticks and the ledger line together;
  exit 5 means an id is not in the section and nothing was written); a plan source uses the
  sub-skill's own marking. Never hand-edit the task file.
- **Subagent types and tiers.** Implementers dispatch as
  `app-sdd-implementer`; task reviewers and re-reviewers as
  `app-sdd-reviewer`; on the tier the dispatch prompt names (`opus` unless
  told otherwise); fix rounds 4 and 5 and the final review on `fable`. Name
  the model on every dispatch. On `rate_limit`, `429` or
  `reached your <tier> limit`: ledger `Model fallback: <role> <from> -> <to>`,
  use the tier below for that role, never re-probe; honour any
  `Model fallback:` line already in the ledger.
- **Reviews go to files.** Every reviewer dispatch appends the matching file
  in this directory by path (`reviewer-overrides.md`, `re-review-overrides.md`,
  `final-review-overrides.md`; implementers get `implementer-overrides.md`).
  Reports go to the review file the dispatch names (`-rR` suffix for
  re-reviews); the reviewer's final message is its verdict block. Fix
  messages name that file and the open ids; Minor findings never enter a
  round and are ledgered as deferred.
- **Fix rounds.** Rounds 1 to 3 resume the implementer by message while its
  last notification shows under 300,000 tokens. Above that, and always for
  rounds 4 and 5 (one tier up), dispatch a fresh implementer with the brief,
  report and review paths and "A prior implementer built this unit and ran
  R-1 fix rounds; you own it now." A round is any message asking for code;
  after the fifth re-review, rule and ledger, never a sixth. A re-review
  that reopens a finding the previous round closed, or that leaves both
  the Critical count and the Important count no lower than the round
  before (a Critical traded for an Important is progress; like for like
  is not), ends the loop: return
  `needs-ruling` with the two rounds' ids; under hands-off, ledger
  `Ruling:` and return `parked`.
- **Gates.** Before the unit's `complete` line: the project's own lint,
  analysis and test commands over the unit's files (OpenSpec:
  `openspec validate <name> --strict` first); none defined: say so in the
  ledger. Ledger `Gates: <commands> passed`.
- **Final phase** (brief `final-brief.md`): the gates; the whole-branch
  review over `Run base`..HEAD, never a computed merge base, on `fable`,
  requirements as paths plus the ledger's deferred and parked lines, report
  to `final-review.md`; ONE fix dispatch with the whole Critical and
  Important list; ONE scoped re-review; the gates again. Leftovers:
  `Open before merge: <finding>. Ruling: <decision>. Cost if wrong: <what>`;
  no second wave. Before your `complete`, ledger `Final phase: complete
  <sha7>` with the HEAD the review and the last gate run saw; a gate that
  fails after the re-review, or a Critical the fix wave did not close and
  no ruling covers, returns `failed` with the reason ledgered, never
  `complete`.
- **Rulings.** A question only a human can answer (the source and the code
  disagree, a finding contradicts the source, an external side effect is
  needed): without `Mode: hands-off` in your dispatch, stop and return
  `needs-ruling` with the question; with it, decide on your best reading,
  ledger `Ruling: <decision>. Cost if wrong: <what>`, append the same line to
  `decisions.md`, and continue. Outside hands-off you may settle a finding
  or concern against the plan's own text yourself when all four hold: the
  change stays inside the brief's file list; every check the plan step
  names still passes unchanged; no spec line, task-list line or interface
  another unit consumes changes; nothing new happens on the live machine
  or outside the repository. Ledger it as `Ruling (controller):
  <decision>. Cost if wrong: <what>`, never as `Ruling:`. Any condition
  failing: `needs-ruling`. A code-to-source mismatch: `needs-ruling`
  without hands-off; with it, ledger `Section N: parked (mismatch: <what>)`
  and return `parked`. A normative line of a spec delta is part of the
  source: neither you nor an implementer adds or changes one. A gap in the
  spec is a question, `needs-ruling` outside hands-off even when the fill
  looks obvious; under hands-off, ledger the ruling and the proposed line
  and leave the delta unchanged.
- **Return block.** Your whole final message, nothing before or after:

  ```
  Unit: <id>
  Status: complete | parked | needs-ruling | failed
  Commits: <range or none>
  Ledger: <number of lines you appended>
  Denied: <tool and command, one per line, only when a permission was denied>
  Question: <one paragraph, only with needs-ruling>
  ```

  `failed` means the unit cannot proceed (an implementer died twice, the
  gates cannot run); the reason is a ledger line, not prose here.
