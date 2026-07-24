---
name: app-openspec-drift
description: Detect byte-for-byte drift between a project's custom OpenSpec schema overlay (openspec/schemas/<name>/schema.yaml) and the upstream @fission-ai/openspec npm package's spec-driven schema. Read-only; reports drift, modifies nothing. Use when the user asks to "check openspec drift", "is our openspec schema still in sync", "compare our openspec schema with upstream", or "openspec upstream drift".
---

# OpenSpec Schema Drift Detection

Detect whether this project's custom OpenSpec schema overlay still matches its upstream lineage in the locally-installed `@fission-ai/openspec` npm package. The skill is detect-only: it reports drift, modifies nothing, never installs hooks.

## When to invoke

User phrases:
- "check openspec drift"
- "is our openspec schema still in sync"
- "compare our openspec schema with upstream"
- "openspec upstream drift"

## Execution

All logic lives in the bundled script `scripts/drift-check.sh` (relative to this skill's base directory). Do NOT inline, reconstruct, or modify the script; run it as-is in a single Bash invocation from the project root (the directory containing `openspec/config.yaml`):

```
bash <skill-base-dir>/scripts/drift-check.sh
```

Substitute `<skill-base-dir>` with the base directory announced when this skill was loaded.

The script always exits 0. Interpret its stdout:

- A single status line (for example "not an OpenSpec project ...", "no overlay declared ...", "OpenSpec is not installed globally ...") means the check could not run or there is nothing to compare; report that line as the final answer.
- Otherwise it prints a full drift report: a schema-block table, a templates table, and (only when something diverged) per-block unified diffs plus instructions for absorbing upstream changes. Relay the report to the user, distinguishing intentional overlay additions from genuine upstream drift.

## Why the logic is a script, not inline code blocks

When a skill is invoked as a slash command, the harness substitutes argument placeholders (a dollar sign followed by a digit 1-9, or by the word ARGUMENTS) inside the rendered SKILL.md body with the command's arguments. Inline shell that uses positional parameters or awk column references gets silently corrupted; each placeholder becomes empty when the skill is invoked without arguments. Keeping the shell in a bundled script file avoids the substitution entirely. If you ever see mangled shell in this file's rendered form, the file on disk is still authoritative.
