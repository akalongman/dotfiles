## Overrides from app-subagent-apply for the unit controller

These lines take precedence over the superpowers:subagent-driven-development
text wherever they differ. You are one unit's controller, not the whole
loop's: the driver that dispatched you owns the source, the unit order and
the final message.

- **Scope.** Run exactly the unit the brief names, or the final phase when
  the brief is `final-brief.md`, then stop. Never start another unit; never
  edit code, the task file or the source's spec documents yourself.
- **Ledger.** Read `progress.md` as `head -n 3`, then
  `grep -nE '^(Run base|Commit mode|Model policy|Model fallback|Ruling|Ruling \(controller\)|Open before merge|Final phase):|: (complete|parked|blocked|paused|pause requested|pause released|resumed)|stopped by hand'`,
  then `tail -n 20`; never the whole file. Append your unit's lines to it as
  you go: each dispatch, each verdict, each fix round, each deferred minor.
  Append them in the same call as the action they record (the dispatch,
  the gate run, the commit check), never in a call of their own.
  Mark completion only through the tick command the dispatch names
  (OpenSpec: `openspec-section-tick <name> <N> '<ledger line>' [ids]`, which
  validates the ids, then writes the ticks and the ledger line together;
  exit 5 means an id is not in the section and nothing was written); a plan source uses the
  sub-skill's own marking. Never hand-edit the task file.
- **Workspace.** Pass every sub-skill script (`review-package` included) an
  output path inside the dispatch's own workspace directory; a call without
  one falls back to `.superpowers/sdd/tasks*/` and is a defect.
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
- **Pause.** A pause reaches you through the ledger, never by message.
  Before every dispatch, every resume of a child and every `needs-ruling`
  return, run this with your unit's own prefix (`Section 3`, `Task 2`)
  in place of `Section N`:
  `grep -nE '^(Section N|Final phase): (pause (requested|released)|owner note)' <ws>/progress.md`.
  Requested or released, the unit's latest pause line wins. Read owner
  notes by count, not position: with k `owner note applied` lines for
  the unit, its first k `owner note:` lines are applied and the rest, in
  order, are not. Carry every owner note of the unit in every later
  dispatch and every resume of a child, ledgering one
  `Section N: owner note applied` per note at its first carry, in the
  same call. A note asking to change work already done is applied as a
  fix round (a message asking for code, so it counts toward the cap).
  A latest pause line
  of `pause requested` is a pause in force: ledger what just ended as
  usual (the report, or the failure and the fallback or retry you would
  make, `Model fallback:` included), run
  `~/.claude/skills/app-subagent-apply/scripts/sdd-checkpoint` on the
  brief's file list, ledger `Section N: paused (<point>; <script output>)`,
  the output being its stdout line, or `checkpoint failed (exit <n>)`,
  which a resume treats as drift; dispatch nothing and return `paused`;
  the retry or fallback runs on continue. Never stop a child to pause.
  A notification for the child in flight (dispatched, or resumed by
  message) with status killed and no result (`<status>killed</status>`,
  no `<result>`), and nothing else, means the owner stopped it by hand:
  a pause, under hands-off too. Ledger
  `Section N: <role> stopped by hand (<state of its work>)`, take the
  checkpoint, ledger the `paused` line, dispatch nothing, return
  `paused`. A notification for any other child id is ledgered and
  consumed, as is any that reaches you after you returned `complete`,
  `parked` or `failed`: return that status again. Any other end without
  a report keeps its usual handling (fallback or retry, then `failed`).
  On continue, after the resume check below, replace a stopped role:
  the same role and stage, the same paths and ids (review file, open
  finding ids, brief, report), framed "the prior <role> was
  stopped mid-work; read `git diff --stat` on the unit's paths
  (implementer) or the partial review file (reviewer) before anything
  else, and adopt what you find". It retries the interrupted stage: the
  fix-round count does not advance (a stopped round 5 is retried as
  round 5), and nothing is discarded.
  While the unit's latest `paused` line has no `drift on resume` or
  `resumed` line after it (on a resume, or as a fresh controller after a
  lost session), first rerun the script: if its line differs from the
  `paused` line's, ledger `Section N: drift on resume: <old> -> <new>`
  and return `needs-ruling` asking "the tree changed while paused;
  continue on it, or stop?"; on a ruling to continue, take a new
  checkpoint, ledger `Ruling:` and `Section N: resumed`, and go on, the
  unit's next review covering the changed files. If equal, ledger
  `Section N: resumed` and go on. Only you write `resumed`, and only
  after the check.
  A unit-ending outcome beats `paused`: return `needs-ruling`, `failed`
  or `parked` as it comes, and the driver holds what follows. With a
  pause in force, take the checkpoint before returning `needs-ruling`
  and ledger it as the `paused` line (point `before needs-ruling`), so
  the resume runs the drift check. The tick is not a dispatch: with a
  clean review and passing gates, tick and return `complete` whatever the
  pause lines say. Before the tick, rerun the grep for owner notes
  alone (the pause lines still do not stop the tick): an unapplied note
  becomes a fix round, since no dispatch is left to carry it.
  In the final phase these rules use
  `Final phase:` as the ledger prefix in place of `Section N:`, and the
  checkpoint takes the union of the units' briefs' file lists.
- **Waiting.** A dispatch returns at once and the harness re-invokes you
  when the child reports, so after a dispatch end your turn. Never start
  a background shell to wait, poll or sleep; this replaces the
  sub-skill's bounded stretches. A shell still running at your hand-back
  makes the harness report you unfinished and may re-invoke you after
  the driver has moved on. Before the return block, stop any background
  shell you did start (TaskStop with its id) and ledger
  `Section N: background shell stopped before return`, only when one was.
  Deliver the block through the hand-back tool, never as plain text:
  a plain-text final message is withheld while a background shell lives.
  A child notification saying the child is waiting on its own background
  work is interim, not the child's end: end your turn; the same task id
  notifies again.
  A forced hand-back (the harness's `[handback-send-enforce]` message) while a child of yours is still in flight is answered with `Status: waiting` and
  `Child: <id> <role> <report path>`; never `paused`, which is the
  owner's word alone. A pause in force is honoured after the relay, as
  for any child in flight. A resume message that relays that child's
  hand-back or notification (its status, its report path) continues the
  unit from there, as if the notification had reached you.
- **Return block.** Your whole final message, nothing before or after:

  ```
  Unit: <id>
  Status: complete | parked | needs-ruling | failed | paused | waiting
  Commits: <range or none>
  Ledger: <number of lines you appended>
  Denied: <tool and command, one per line, only when a permission was denied>
  Question: <one paragraph, only with needs-ruling>
  Point: <one line, only with paused>
  Child: <id> <role> <report path>, only with waiting
  ```

  `failed` means the unit cannot proceed (an implementer died twice, the
  gates cannot run); the reason is a ledger line, not prose here.
