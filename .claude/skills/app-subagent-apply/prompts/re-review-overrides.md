
## Overrides from app-subagent-apply

These lines take precedence over the superpowers:subagent-driven-development
template your dispatch was composed from, wherever they differ.

- `[FINDINGS]` is a review file path plus the ids of the findings under
  re-review; read those sections of the file. Findings not named are
  ledgered by the controller and are not yours to judge.
- Write the full report to REVIEW_FILE (the dispatch names the path).
  Writing that one file is the only write you make; the read-only rule
  still binds the checkout.
- Your final message is the verdict block only: one line per finding id as
  `C1 ADDRESSED | NOT ADDRESSED file:line`; one line per new Critical or
  Important breakage as `NEW1 <one-liner> file:line`; one line per
  out-of-scope observation as `OOS1 <one-liner>`; `Round: all addressed |
  open <ids>`; then the report path.
