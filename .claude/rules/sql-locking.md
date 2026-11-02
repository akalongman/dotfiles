---
name: rules-sql-locking
description: Apply when writing, reviewing or specifying code that takes row locks or relies on transaction isolation (SELECT ... FOR UPDATE, lockForUpdate, sharedLock, foreign keys inside a transaction); covers what a lock actually covers, gap and next-key locks, deadlocks and how to verify a race.
paths:
  - "**/*.php"
  - "**/*.rs"
  - "**/*.ts"
  - "**/*.js"
  - "**/*.sql"
  - "**/migrations/**"
  - "**/openspec/**"
---

# Row Locking and Concurrency

Companion to `sql.md`, which carries the always-loaded rules for ad hoc queries.
This file loads with code that can take a row lock, because the guarantees here
are about what a statement serialises against, not about how to type a query.

## Concurrency and row locking

Before claiming a locking read (`SELECT ... FOR UPDATE`, `lockForUpdate()`,
`sharedLock()`) makes something safe, establish what it actually locks. In InnoDB
the lock follows the **query plan**, not the `WHERE` clause. Run `EXPLAIN` on the
exact statement and read the chosen `key`. The planner picks whichever index it
judges most selective, so a lock you believe is scoped to one column can land on
another and change as the table fills.

Consequences to check for, each of which is a real defect and not a theoretical one:

- **A range or index scan takes gap and next-key locks**, so it can block unrelated
  rows. Two operations that share nothing but a neighbouring index entry will
  serialise against each other.
- **Gap locks do not conflict with other gap locks**, so a lock that degenerates
  into one serialises nothing while still looking like protection.
- **A point lock on the primary key (`WHERE id = ?`, `EXPLAIN` shows
  `type=const`, `key=PRIMARY`) takes no gap locks.** Prefer it. When the thing to
  serialise is "repeated operations on this record", lock that record's own row.
- **Lock waits and deadlocks surface as exceptions** (`1205`, `1213`). Decide what
  the user sees. An uncaught one is a 500, not a refusal message.
- **A foreign key locks its parent row.** Before claiming what can wait on a row
  lock, list the foreign keys out of every table the transaction inserts into or
  updates a key of: each such write takes `FOR KEY SHARE` on the referenced parent
  row (InnoDB a shared lock), so a "create-only" transaction can lock existing
  rows (2026-10-19, a `submissions` insert closed a cycle with the publish
  transaction).

Verify at realistic scale, not at whatever the dev database happens to hold. A
handful of rows makes the planner full-scan and lock everything, which looks like
correct serialisation and disappears the moment the table grows. Prove the negative
too: run the same race with the lock removed and confirm it fails, otherwise the
test proves nothing.

Read stale data as stale. Values loaded before the transaction opened may already
be wrong by the time it runs; re-read from the locked row whatever the logic
branches on.

Do not write a `SHALL` into a spec about which index is used. That is the planner's
choice, not the code's, so no implementation can enforce it. Specify the guarantee
(what is serialised against what), not the mechanism.

When a check cannot be made atomic, say so plainly in the code comment and the
spec. "Narrows the window" is an honest and useful claim; "closes the race" when it
does not is worse than no claim, because it stops the next reader looking.
