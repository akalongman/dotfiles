
## Overrides from app-subagent-apply

These lines take precedence over the superpowers:subagent-driven-development
template your dispatch was composed from, wherever they differ.

- Unit naming: `section-N-*` files and `Section N:` for an OpenSpec source,
  `task-N-*` and `Task N:` for a plan.
- Write the full report to REVIEW_FILE (the dispatch names the path).
  Writing that one file is the only write you make; the read-only rule
  still binds the checkout.
- Number every Critical and Important finding in the order you list them:
  C1, C2 for Critical, I1, I2 for Important, M1, M2 for Minor, CV1, CV2
  for items you could not verify.
- Your final message is the verdict block only, nothing before or after
  it: `Spec: OK | FAIL`; `Quality: Approved | Needs fixes`; one line per
  Critical and Important finding as `C1 <one-liner> file:line`; one line
  per Minor as `M1 <one-liner>`; one line per cannot-verify item as
  `CV1 <what the controller must check>`; then the report path. No
  praise, no list of checks run, no rationale: those live in the file.
