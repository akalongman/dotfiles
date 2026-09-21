
## Overrides from app-subagent-apply

These lines take precedence over the superpowers:subagent-driven-development
template your dispatch was composed from, wherever they differ.

- Unit naming: for an OpenSpec source the unit is one `## N.` section of
  `tasks.md` (N may carry a letter suffix, `2b`); its files are
  `section-N-brief.md` and `section-N-report.md`. Plan sources keep
  `task-N-*`.
- Never tick `tasks.md`. The controller marks progress after the review.
- Commit as you go on the current branch, path-limited: stage explicit
  paths and commit with `git add <paths> && git commit -m "<title>" -- <paths>`,
  per `~/.claude/rules/git.md`. Never `git add -A`, `git add .` or
  `git commit -a`; never create, switch or rename a branch or worktree;
  never push.
- Run the tests that cover the files you changed, not the whole suite,
  unless the constraints file names the suite command as the gate.
