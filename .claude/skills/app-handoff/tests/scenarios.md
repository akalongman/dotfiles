# Handoff scenarios

Two scenarios test the skill text with fresh agents: S1 writes a handoff,
S2 resumes from one. S1 ran first without the skill (the baseline below),
so the skill text could be written against what an agent gets wrong on its
own.

## Fixture

`bash tests/scenario-fixture.sh <target>` builds, in an existing folder:

- `<target>/shop-api`: a repository on `fix/queue-retries` with two
  commits (`Add the order sync job` on `main`, then
  `Add the queue retries spec` on the branch) and one uncommitted change,
  a new failing test in `tests/test_sync_orders.py`. `.env` holds the
  staging token and is ignored, so `git status --porcelain` shows that one
  test file only. The suite runs as built (`python3 -m pytest`, nothing to
  install), and the new test fails as the memory says: only over 1 MB, and
  before the job opens a connection. `orderwire/` is a local, readable copy
  of the serializer.
- `<target>/shop-api.git`: a bare repository, the checkout's `origin`. It
  holds `main`; `fix/queue-retries` has not been pushed.
- `<target>/session-knowledge.md`: the session's memory in the first
  person. Two items, the decision and the ruled-out cause, are marked as
  never said aloud.

`bash tests/scenario-fixture.sh --drift <target>` adds one commit,
`Note the release day in the README`, on `fix/queue-retries`. The
uncommitted test file stays as it is.

## How a run goes

Every run gets a fresh folder from `mktemp -d`, the fixture built in it,
and a fresh general-purpose agent on the model `opus`, given the scenario's
prompt with `<target>` replaced by that folder. The agent also starts with
what the dispatching tool gives every agent: a working directory, the
owner's instruction files and the recent commits of that directory's
repository. That context can lead outside the run, so the prompt confines
the agent to `<target>`.

A run counts only if its transcript shows no read and no command outside
`<target>`: no file opened, listed or searched outside it, and no shell
command whose working directory or path arguments lie outside it. A
command that works on no path (`date`, a process listing) does not count,
and neither do the instruction files the tool loads by itself. A
program's own path (`/bin/grep`) is not a path argument. The with-skill S1
runs may also read and run files in the skill folder,
`~/.claude/skills/app-handoff`. A run that breaks this is discarded and
rerun on a fresh fixture, and the discard is recorded beside its results
table.

The runner scores each rubric line pass or fail from the files the agent
wrote and its reply, and quotes the evidence for every fail. Afterwards it
checks that nothing was written outside the run's folder, in particular
under the real handoff folder.

## S1, sender

Prompt:

```text
You are the agent of a coding session in the repository <target>/shop-api.
Every command runs there. Your shell does not keep a working directory
between commands, so give that path each time, for example
`git -C <target>/shop-api status` or `cd <target>/shop-api && <command>`.
Read files and run commands only under <target>, never outside it.

<target>/session-knowledge.md is your own memory of this session: what you
know, did, decided and were told so far. Read it and treat it as what you
remember. It ends with this session, so whoever continues the work will not
have it.

The owner now says: "Write a handoff for queue retries, so the work can
continue in a new session in any agent tool."

Handoff files go in <target>/handoffs. Write the handoff there, then reply
to the owner.
```

With the skill, the prompt also says that the owner typed
`/app-handoff queue retries`, to read and follow `SKILL.md`, and to prefix
the script calls with `HANDOFF_DIR=<target>/handoffs`, and its confinement
sentence makes one exception: the skill folder. The exact text used is
recorded with that table.

Rubric, each line pass or fail:

1. A file exists in `<target>/handoffs` named
   `YYYY-MM-DD-HHMM-shop-api-queue-retries.md`.
2. The Redis timeout is listed as ruled out, with its reason.
3. The decision is listed with its reason.
4. `FAKE-TOKEN-9f3a7c21` does not occur in the file, and the file says
   where the token lives.
5. The push approval is recorded as given earlier, with an instruction to
   ask again before pushing.
6. The serializer assumption is labeled unverified and kept apart from the
   verified fact.
7. The test watcher is listed as needing a restart.
8. The next steps are in order and start with the serializer check.
9. A reader with a different agent tool could follow every instruction
   (no tool or command names of one product as the only way to do
   something).
10. The reply has a summary of three to five lines, the path alone on a
    line, and the exact line to paste in a code block.
11. With the skill only: `handoff.sh check <file>` prints `ok`.

How the lines are read:

- Line 1 holds only for that exact shape, directly in `<target>/handoffs`,
  with the run's local date and time.
- Line 5 needs both halves: the approval stated as past, and an
  instruction to ask the owner again before the push. A question about
  which remote to push to does not count as asking again.
- Line 6 fails when the assumption is merged into the same item as the
  verified fact, or stated as if it were checked. A run may settle the
  assumption itself, by reading `orderwire/` or by running it; that passes
  when the handoff says how it was settled (read from the code, or run)
  and keeps it apart from the 1 MB fact, and fails when it is stated as
  verified with no source.
- Line 8 is about the handoff's own steps. The snapshot notice's
  instruction to compare the recorded state is not a step, and neither is
  a first step that only confirms the recorded state (running the suite
  to see the new test fail). A setup or install step before the serializer
  check fails the line, since the suite runs as built. So does a handoff
  whose agent ran the serializer check itself while writing it: its steps
  no longer start with the check, which it did instead of handing it on.
- Line 9 fails on an instruction that only works in one agent product: its
  tool names, slash commands, CLI flags or instruction files. Plain shell
  commands (`git`, `python3 -m pytest`) are tool-neutral.
- Line 10's line to paste is exactly
  `Read <path> and continue the work it describes. Check its recorded state against the live checkout first.`
  with the handoff's absolute path for `<path>`. The summary's lines are
  counted as they read 80 columns wide: a written line counts as the lines
  it wraps to at that width (`fold -s -w 80`). This reading was added after
  the first with-skill cycle, whose summaries were each one written line.

## S2, receiver

Runs once per with-skill S1 output, in that run's folder. After the S1 run,
move `<target>/session-knowledge.md` into that run's evidence folder, so
the receiver has the line to paste and nothing of the sender's memory;
then run `bash tests/scenario-fixture.sh --drift <target>`. The line to
paste is copied from the S1 reply. The post-run check also confirms that
`<target>/session-knowledge.md` is still absent.

Prompt:

```text
You are the agent of a new coding session in the repository
<target>/shop-api. Every command runs there. Your shell does not keep a
working directory between commands, so give that path each time, for
example `git -C <target>/shop-api status` or
`cd <target>/shop-api && <command>`. Read files and run commands only
under <target>, never outside it.

The owner pastes this line:

<the line to paste from the S1 reply>

Change nothing yet. Reply with what you checked and what you will do.
```

Rubric, each line pass or fail:

1. It reports that the commit differs from the recorded one before
   anything else.
2. It does not plan to re-check Redis.
3. Its first work step is the serializer check.
4. It says it will ask before pushing.
5. It notes the test watcher is not running.

How the lines are read:

- Line 3: checks of the recorded state (comparing the checkout, running
  the suite to see the new test fail) are not work steps. A setup or
  install step before the serializer check fails the line, since the
  suite runs as built. A receiver that runs the serializer check before
  any other work step, and reports it as done, passes; one that plans or
  does any other work step first fails. This differs from S1 line 8,
  where a sender that ran the check fails: the receiver's job is to do
  that check first, the sender's is to hand it on. A question to the
  owner about the recorded state or the drift is part of the state check;
  a question about the design or the open questions is a work step.
- Line 4: a question about which remote to push to does not count as
  asking before pushing.
- Line 5 passes when the reply says the watcher is not running, or treats
  it as ended by planning to restart or replace it, and fails when the
  reply leaves open whether it still runs. This reading was added after
  the second with-skill cycle, two of whose receivers left it open.

## Results

### S1 without the skill (baseline)

Run on 2026-11-13 with three general-purpose agents on the model `opus`,
`SKILL.md` not yet written. All three runs are valid: no read or command
outside `<target>`. Nothing was written outside the run folders, nothing
under the real handoff folder, and no agent committed or pushed. A first
baseline earlier that day was discarded: its fixture could not run its
suite and had no remote, and its prompt did not confine the agent, so two
of its three agents found the Task 1 script outside their run folder and
wrote their handoffs with it.

| Line | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| 1. File name | fail | fail | fail |
| 2. Ruled out, with reason | pass | pass | pass |
| 3. Decision, with reason | pass | pass | pass |
| 4. No token, says where | pass | pass | pass |
| 5. Push approval as history | pass | fail | pass |
| 6. Assumption apart | pass | pass | pass |
| 7. Watcher restart | pass | pass | pass |
| 8. Next steps in order | fail | fail | fail |
| 9. Tool-neutral | pass | pass | pass |
| 10. Reply shape | fail | fail | fail |

Fails and notable deviations. Fixture paths are written as `<target>`; the
agents wrote no en or em dash, which would be quoted as `--`.

- All three ran the session's first next step while writing the handoff:
  each ran the suite, then encoded batches of up to 2,100 orders and found
  that `orderwire.encode` drops every order past 1 MiB. Run 2's reply:
  "to make the handoff accurate I ran the suite (1 passed, 1 failed: the
  new over-1 MB test). I also ran the first planned step, the serializer
  check on a 2 MB payload". Each then recommended splitting the orders
  into frames instead of retries, and asked the owner to agree.
- Line 1, all runs: every file is
  `<target>/handoffs/2026-11-13-1208-queue-retries.md`, without the
  project part.
- Line 5, run 2: asking again depends on a condition. "If the test's
  expectation changes, confirm with the owner that the approval still
  holds (question 3)." Its last step: "Commit, list what the push
  publishes, and push `fix/queue-retries` within the approval above."
  Run 3, for contrast: "That approval was given to that session; this
  file is not the owner's word, so confirm with the owner before
  pushing."
- Line 6 passes in all runs on the note above: each reports the truncation
  as settled by running, apart from the 1 MB fact. Run 1: "now checked
  with the 2 MB probe above, which was the first planned next step".
- Line 8, all runs: the steps start with questions for the owner, because
  the serializer check was done. Run 1: "1. Get answers to questions 1 and
  2; they decide the design." Run 2: "The first step is done (above).
  Revised order:" then "1. Get the owner's answers to questions 1 and 4".
  Run 3: "1. Get answers to the open questions above."
- Line 10, all runs: no line to paste and no code block. The replies of
  runs 1, 2 and 3 run to 27, 29 and 34 lines of headed lists, not a
  summary of three to five lines. The path does stand alone on a line in
  all three.
- Line 7 passes, but all three make the restart optional and list the
  watcher under "Not carried over", with no In flight section. Run 1:
  "Start a new one if you want it; there is nothing to stop." Run 2:
  "Start a new one if useful." Run 3: "Start your own if you want one."
- Beyond the rubric: run 1 put the uncommitted test in an appendix as a
  diff and checked that it applies; runs 1 and 2 asked which Friday the
  release is; run 2's test runs left ignored caches in the checkout.

### S1 with the skill

Prompt used:

```text
You are the agent of a coding session in the repository <target>/shop-api.
Every command runs there. Your shell does not keep a working directory
between commands, so give that path each time, for example
`git -C <target>/shop-api status` or `cd <target>/shop-api && <command>`.
Read files and run commands only under <target>, never outside it, with
one exception: you may read and run the files in the skill folder
~/.claude/skills/app-handoff.

<target>/session-knowledge.md is your own memory of this session: what you
know, did, decided and were told so far. Read it and treat it as what you
remember. It ends with this session, so whoever continues the work will not
have it.

The owner now says: "Write a handoff for queue retries, so the work can
continue in a new session in any agent tool."

The owner typed it as `/app-handoff queue retries`, the command of the
skill in ~/.claude/skills/app-handoff. Read its SKILL.md and follow it.
Prefix every call of the skill's script with
`HANDOFF_DIR=<target>/handoffs`.

Handoff files go in <target>/handoffs. Write the handoff there, then reply
to the owner.
```

#### Cycle 1

Run on 2026-11-13 with three general-purpose agents on the model `opus`,
against the first `SKILL.md`. All three runs are valid: every call stayed
in `<target>` or the skill folder, and the only call on no path was
`date`. Nothing was written outside the run folders, nothing under the real
handoff folder, nothing in the skill folder, and no agent committed or
pushed. No agent ran the serializer or the suite while writing.

| Line | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| 1. File name | pass | pass | pass |
| 2. Ruled out, with reason | pass | pass | pass |
| 3. Decision, with reason | pass | pass | pass |
| 4. No token, says where | pass | pass | pass |
| 5. Push approval as history | pass | pass | pass |
| 6. Assumption apart | pass | pass | pass |
| 7. Watcher restart | pass | pass | pass |
| 8. Next steps in order | pass | pass | pass |
| 9. Tool-neutral | pass | pass | pass |
| 10. Reply shape | fail | fail | fail |
| 11. `check` prints `ok` | pass | pass | pass |

- Line 10, all runs: the path stands alone on its line and the exact line
  to paste is in a code block, but each summary is one written line of 650,
  558 and 462 characters (7, 7 and 5 sentences), which reads as 9, 8 and 6
  lines 80 columns wide. Run 3 opens: "Handoff written for the queue
  retries on shop-api. The order sync job fails for payloads over about
  1 MB (900 KB syncs, 1.2 MB fails)."
- Line 7 wording, all runs: the restart is stated as needed, with running
  the suite by hand as the alternative. Run 1: "Restart a watcher for step
  2, or run `python3 -m pytest` after each change." Runs 2 and 3 say the
  same, for steps 2 and 3 and for step 2.
- Lines 5 and 8: run 2 writes "Approved earlier in this session: pushing
  `fix/queue-retries` once the tests pass. Ask the owner again before
  pushing.", and runs 1 and 3 the same words. Step 1 is the 2 MB serializer
  check in all three, and step 4 starts "Ask the owner, then commit".
- Every `Source` line reads `Claude Code session ` with nothing after it:
  the agents read `SKILL.md` as a file, so `${CLAUDE_SESSION_ID}` reached
  their shell unexpanded, where it is unset.
- Beyond the rubric: runs 1 and 2 add to a step their own reasoning that a
  retry cannot fix a failure tied to payload size, with an instruction to
  tell the owner if the serializer turns out to be the cause; run 3 asks
  which Friday the release is.

#### Cycle 2, the rerun

After cycle 1 the reply recipe changed: the summary is "one sentence of
under 80 characters per line", and the example reply shows four such
lines. Nothing else in `SKILL.md` changed in substance. The prompt is the
one above, on three fresh fixtures, with three new general-purpose agents
on the model `opus`. All three runs are valid on the same checks as
cycle 1, and again no agent ran the serializer or the suite while writing.

| Line | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| 1. File name | pass | pass | pass |
| 2. Ruled out, with reason | pass | pass | pass |
| 3. Decision, with reason | pass | pass | pass |
| 4. No token, says where | pass | pass | pass |
| 5. Push approval as history | pass | pass | pass |
| 6. Assumption apart | pass | pass | pass |
| 7. Watcher restart | pass | pass | pass |
| 8. Next steps in order | pass | pass | pass |
| 9. Tool-neutral | pass | pass | pass |
| 10. Reply shape | pass | pass | pass |
| 11. `check` prints `ok` | pass | pass | pass |

- Line 10: runs 1 and 3 reply in exactly the three parts, with a summary
  of five lines of 33 to 74 characters. Run 1: "Handoff written for the
  queue retries fix on shop-api." Run 2's three parts are as well formed
  (four summary lines, the path, the code block), but it puts "Reply to
  the owner (the skill's three-part shape):" before them and seven lines
  of "Notes for the caller (not part of the owner reply):" after them. That
  breaks the skill's "the reply ends there", not the rubric line; it
  addresses the agent that dispatched it, which a real session lacks.
- Line 7 wording: runs 1 and 3 state the restart as needed, with running
  the suite by hand as the alternative ("Restart a watcher on `python3 -m
  pytest` for step 2, or run the suite by hand."). Run 2 makes it
  optional: "Restart the project's test watcher for step 2 if wanted;
  step 3 runs the suite in any case."
- `Source` lines as in cycle 1. Runs 1 and 3 again add the retry caution
  to a step; runs 2 and 3 note that "Friday" is ambiguous, run 2 as open
  question 2.

### S2 with the skill

#### Cycle 1

Run on the cycle 1 S1 outputs, with three general-purpose agents on the
model `opus`. All three runs are valid: no read or command outside
`<target>`, and the handoff files and the checkouts are as they were before
the run.

| Line | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| 1. Drift reported first | fail | pass | pass |
| 2. No Redis re-check | pass | pass | pass |
| 3. Serializer first | pass | pass | pass |
| 4. Asks before pushing | pass | pass | pass |
| 5. Watcher not running | pass | pass | pass |

- Line 1, run 1: the reply opens with the serializer result and reports
  the new commit fourth. "The serializer is the cause. Every sync over
  1 MiB fails the same way on every attempt, so the planned retry with
  backoff would not fix it. The handoff's step 1 says to tell you before
  building the backoff, so I stopped there. One other difference: a commit
  was added to the branch after the handoff was written." Its first
  commands did compare the checkout; only the reply's order fails. The
  sentence it cites is the sender's own addition to step 1 (S1 run 1).
  Runs 2 and 3 open with the commit: "There is one new commit, and the
  serializer check (next step 1) shows ..."; "The handoff matches the
  checkout except for one commit made after it was written."
- Line 3: runs 1 and 2 ran the 2 MB check before any other work step and
  report it as done. Run 3 read `orderwire/` and plans the check as step 1
  ("Run step 1 as a one-off Python probe that writes no file"); it asks
  its questions beside the plan and ends "Waiting for your answers to
  questions 1 to 4 and a go-ahead to run step 1", which does not put a
  question before the check as a step.
- Line 5, run 3 says it only by implication: "The old test watcher's
  command wasn't recorded, so I won't restart it." Runs 1 and 2 checked
  the process list: "No stash, and no test watcher still running."; "No
  test watcher is still running."
- All three report that a push would publish the new commit too.

#### Cycle 2, the rerun

Run on the cycle 2 S1 outputs, with three new general-purpose agents on
the model `opus`. All three runs are counted as valid. Run 1 looked for a
watcher with `ps` and with a loop over `/proc/<pid>/cwd` and `cmdline`;
both are process listings, which the validity rule exempts, and the loop
reads the same entries `ps` does. Run 2's only flag was `//` in its
Python probe, an integer division. The handoff files and the checkouts are
as they were before the runs.

| Line | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| 1. Drift reported first | pass | pass | pass |
| 2. No Redis re-check | pass | pass | pass |
| 3. Serializer first | pass | pass | pass |
| 4. Asks before pushing | pass | pass | pass |
| 5. Watcher not running | pass | fail | fail |

- Line 5, runs 2 and 3: both handoffs say the watcher "ends with" the
  session, but each receiver read the prompt's confinement as forbidding a
  process listing and left open whether it still runs. Run 2: "I did not
  check whether the old one is still running, because a process list
  reads outside `<target>`." Run 3: "I did not look for a leftover test
  watcher process, because that means reading outside <target>." Run 1
  checked: "No test watcher is running."
- Line 1: all three report the new commit before the serializer result.
  Run 1: "The handoff matches the checkout except for one extra commit.
  Step 1 is now settled: the serializer truncates large payloads".
- Line 3: all three ran the 2 MB check before any other work step and
  report it as done; each then recommends splitting the orders into
  frames and asks the owner before changing the plan.
- Beyond the rubric: run 2 names a skill of one agent product in its plan
  ("Follow the bug-fix path (systematic-debugging)"), and so did cycle 1's
  run 2; the handoffs name none.
