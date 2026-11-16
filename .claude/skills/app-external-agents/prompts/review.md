# Review prompt parts

Read this file when the task is a review: a plan, a spec, a design, a diff
or code. Parts 1 to 6 are the parts of a review prompt that the
skeleton in `SKILL.md` does not supply, in the order they go into it;
each says where it goes in `prompt.md`. The text in a fenced block is
written into the prompt with its bracketed parts filled in; the rest of
each part is for whoever writes the prompt. Parts 7 and 8 bind every
review prompt.

## 1. Stance

Under `# Task`, after the goal:

```
You are an independent reviewer. Find what is wrong, missing or ambiguous in the material. Do not praise it, and do not restate it.
```

## 2. Check areas

Under `# Task`, after the stance. Write a numbered list of what to check,
specific to the material (for a plan: whether each task can be built as
written, whether the tests prove what they claim, whether the plan
matches the spec). The reviewer answers against this list.

```
Check these areas, and answer against this list by number:
1. <a check area specific to the material>
2. <another>
```

## 3. Decisions

Under `# Where to look`, cite each decision a document records by file
and line, with the reason the document gives, or with "reason not
recorded" when it gives none.

```
Decisions the material records:
- <the decision> (<file>:<line>; reason: <the reason the document gives>)
- <the decision> (<file>:<line>; reason not recorded)
```

A decision known only from conversation is never presented as recorded.
It goes under `# Context`, marked as said in conversation, with its
reason when one was given:

```
Said in conversation, not recorded in the material:
- <the decision> (reason: <the reason given>, or "no reason given")
```

## 4. The bar

Under `# What to return`:

```
Do not spend findings on preferring another choice. If you would reverse a decision, put it in a section of its own, "Decisions I would reopen", with either a concrete failing case (the state before, what happens, what should have happened) or a concrete cheaper alternative and what it saves. For example: for the decision "a session's switch always expires, 8 hours by default", a failing case is a run started at 22:00 that is still working at 06:00, loses its switch, and waits for its owner until morning; the alternative is to renew the switch on activity, with what that costs.
```

## 5. Severity

Under `# What to return`, after the bar. Use these three words, not
another scale.

```
Give each finding one severity:
- Critical: built as written, it fails in a way the task names, or it cannot be built.
- Important: wrong behaviour in a realistic case, or a test that proves the wrong thing.
- Minor: an ambiguity, a wording problem or a stale statement.
```

## 6. The shape of the answer

Under `# What to return`, after the severity, and before the closing
instruction and the read-level line that `SKILL.md` gives:

```
Answer in this shape:
1. Findings, most severe first. Each gives its severity; where it is (file and line); the concrete case; how you know (the file and line you read, or "unverified" with the reason); and the smallest fix.
2. The section of decisions you would reopen, as described above, or "none".
3. One line for each numbered check area, saying either that it was checked and nothing was found, or that it was checked and which findings belong to it (by number), or that it was not reached.
4. A verdict paragraph that names up to three findings to fix first.
```

## 7. A shape the user asked for

A shape the user asked for takes precedence over this template wherever
the two differ.

## 8. The rule for whoever writes the prompt

Never tell a reviewer not to question, argue with or reverse a decision.

The bar in part 4 is the only limit on reopening a decision. A review
prompt of 2026-11-13 carried a clause the skill never asked for, telling
the reviewers that the listed decisions were settled and not to argue
for reversing them; the owner wants decisions challenged, because a
decision can be wrong.
