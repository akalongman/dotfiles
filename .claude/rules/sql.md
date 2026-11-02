---
name: rules-sql
description: Apply when running ad hoc SQL against any live database by hand, or writing and reviewing queries typed in a shell;
---

# SQL and Database Guidelines

Rules for querying databases by hand. This file loads in every session, because
an ad hoc query is typed in a shell and touches no file a path-scoped rule could
match. What a statement locks, and how to design code around row locks, is in
`sql-locking.md`, which loads with the code files that take locks.

## Designing with locks

Before claiming that a lock, a transaction or a constraint makes a design
safe, read `sql-locking.md`; it does not load on its own in a conversation
that has opened no code or spec file. Two of its rules bind at design time:
specify the guarantee (what is serialised against what), never the mechanism
(which index the planner picks), and when a check cannot be made atomic say
"narrows the window", never "closes the race".

## Ad hoc queries on a live database

A live database serves other people while you read it. On engines with table
locks (MyISAM) a slow `SELECT` holds a read lock for its whole run, every write
queues behind it, and every later read queues behind those writes, so one
careless statement stalls the application.

Worked example (2026-10-05): `SELECT COUNT(*) FROM student_finances` on a
legacy MariaDB 5.5 looked like a one-table count. The name was a view over a
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
- **When a multi-statement batch fails, rerun each statement alone before
  attributing the error.** A compile-time error, such as a collation conflict,
  fails the whole batch before its first statement runs, and the message's
  "statement column N" names a column of the failing statement, not its
  position in the batch (2026-10-23, a probe's own metadata concatenation was
  blamed on the query beside it).
