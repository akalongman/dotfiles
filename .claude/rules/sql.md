---
name: rules-sql
description: Apply when running ad hoc SQL against any database, writing or reviewing queries, or reasoning about locks, indexes and transactions;
---

# SQL and Database Guidelines

Rules for querying databases by hand and for reasoning about what a statement
locks. This file loads in every session, because an ad hoc query is typed in a
shell and touches no file a path-scoped rule could match.

## Ad hoc queries on a live database

A live database serves other people while you read it. On engines with table
locks (MyISAM) a slow `SELECT` holds a read lock for its whole run, every write
queues behind it, and every later read queues behind those writes, so one
careless statement stalls the application.

Worked example (2026-10-05): `SELECT COUNT(*) FROM studzefinan` on a legacy
MariaDB 5.5 looked like a one-table count. `studzefinan` was a view over a
four-table `DISTINCT` join, ran for more than two minutes, and 46 production
queries, logins among them, waited behind its table locks.

- **Know what the object is before reading it.** For any table you have not
  queried before, read `TABLE_TYPE`, `ENGINE` and `TABLE_ROWS` from
  `information_schema.TABLES` (filtered by schema and exact name) first. A name
  tells you nothing: a view hides joins.
- **Never query a view on a live server you do not own.** Read its definition
  (`SHOW CREATE VIEW`) and query the base tables it names.
- **Never run an unfiltered aggregate** (`COUNT(*)`, `SUM`, `GROUP BY` over a whole
  table) to size something up. `TABLE_ROWS` answers the size question for free.
- **One table per statement, no joins, on a server without the indexes to
  support them.** Pull the filtered rows and join locally.
- **Bound every statement.** Set a statement timeout where the engine has one
  (`max_statement_time`, `statement_timeout`), add `LIMIT` to exploratory reads,
  and wrap the client call in a short `timeout`. A client timeout does not stop
  the server: the statement keeps running after the client is gone.
- **Know how you will kill your own statement before you run it.** Check that the
  connection you use is allowed to issue `KILL` (an application-level read-only
  guard may refuse it) and have the alternative client ready.
- **After any timeout, look at the process list at once.** If your statement is
  still running, stop it or hand the owner the kill command in the same turn,
  and say what it blocked.
- **Do not print rows you do not need.** Select the columns the question needs
  and filter to the subject; a `SELECT *` dump of an unknown table pulls
  unrelated personal data into the session.

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
