
## Overrides from app-subagent-apply

These lines take precedence over the superpowers requesting-code-review
code-reviewer.md template your dispatch was composed from. Ignore that
template's "Git Range to Review" and "Read-Only Review" sections; this
block replaces them:

## Diff Under Review

**Base:** [BASE_SHA]
**Head:** [HEAD_SHA]
**Diff file:** [DIFF_FILE]

Read the diff file once. It contains the commit list, a stat summary
and the full diff with surrounding context, and it is your view of the
change. The diff's context lines ARE the changed files: do not Read a
changed file separately unless a hunk you must judge is cut off
mid-function, and say so in your report. Do not re-run git commands.
If the diff file is missing, fetch the diff yourself:
`git diff --stat [BASE_SHA]..[HEAD_SHA]` and `git diff [BASE_SHA]..[HEAD_SHA]`.
When the dispatch names excluded paths, spot-check those it asks you
to with `git show [HEAD_SHA]:<path>`, nothing more.
Do not crawl the broader codebase. Inspect code outside the diff only
to evaluate a concrete risk you can name, one focused check per named
risk, and name both the risk and what you checked in your report.
Cross-cutting changes are legitimate named risks: if the diff changes
lock ordering, a function or API contract, or shared mutable state,
checking the call sites is the right method.

Your review is read-only on this checkout. Do not mutate the working
tree, the index, HEAD, or branch state in any way. Do not add a
worktree.


- `[PLAN_OR_REQUIREMENTS]` is paths only, followed by the ledger lines the
  dispatch quotes: `minor (deferred)`, `parked` and `controller-side`
  lines. The controller-side lines name commits no task review saw: read
  those commits with the same care as the rest of the diff.
- Write the full report to REVIEW_FILE (the dispatch names the path).
  Writing that one file is the only write you make; the read-only rule
  still binds the checkout.
- Number every finding in the order you list it: C1, C2 for Critical, I1,
  I2 for Important, M1, M2 for Minor.
- Your final message is the verdict block only: `Ready to merge: Yes | No
  | With fixes`; one line per Critical and Important finding as
  `C1 <one-liner> file:line`; one line per Minor as `M1 <one-liner>`;
  then the report path. No strengths section in the message: it belongs
  in the file.
