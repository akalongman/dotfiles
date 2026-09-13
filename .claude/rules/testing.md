---
name: rules-testing
description: Apply when running, diagnosing, or designing automated tests in any language.
paths:
  - "**/tests/**"
  - "**/test/**"
  - "**/spec/**"
  - "**/*Test.php"
  - "**/*.test.*"
  - "**/*.spec.*"
  - "**/*_test.rs"
  - "**/*_test.go"
  - "**/phpunit.xml"
  - "**/phpunit.xml.dist"
  - "**/Pest.php"
  - "**/jest.config.*"
  - "**/vitest.config.*"
---

# Testing Discipline

Rules that apply to any test suite, in any language. Language-specific
testing conventions live in the matching language rule file (for example the
Testing section of `php.md`).

## Diagnosing a failing run

When a test run fails, establish whether the cause is the code or the test
environment before naming a cause, and prefer a cheap direct measurement over a
plausible story.

- The signature of polluted shared state is a scatter of failures across
  unrelated areas, typically list or count assertions on reference tables
  (degrees, currencies, statuses), with no connection to what changed. Measure
  it: query the committed row counts of those tables from a separate
  connection and compare against what a freshly migrated database should hold.
  Rows visible from another connection were committed, so a non-zero count is
  the proof.
- Assume every full-suite run leaves committed residue, whether it was killed
  or finished normally. Reset the test database before any run whose result
  you intend to act on, and reset and re-run before touching application code.
- Never truncate a failing run's output; the failure messages are the evidence.
- Read every failure before naming a cause. N failures are not automatically
  one cause, and generalising from the first stack trace produces a confident
  fix for a problem that was never there. After a fix, re-read the new
  failures instead of assuming the remaining ones are the old ones.
- Never edit source while a validation run is in flight; the runner loads code
  from the working tree as it goes, so tests before and after the edit run
  different code.
- Verify claimed shared state instead of recalling it; per-worktree or per-job
  database cloning may already isolate what a note says is shared.

## Designing a regression test

A regression test can only turn red on a decision made by the code it drives.
Before designing a reproduction, name the exact boundary where the wrong value
is chosen (the caller that hands over leaked state, the request that picks the
wrong tenant) and drive that unit. If the test supplies the disputed value
itself (a probe fed its target, a service fed its scope), the defect sits
outside the test's reach and the test is green on buggy code.

This also decides commit order: a red-then-green sequence needs the
reproduction against unchanged code first, never a behaviour-preserving
extraction that changes the tested constructor between red and green
(2026-09-12, sc-843: a probe-level test that chose its own target could never
fail).
