---
name: app-openspec-drift
description: Compare a repository's vendored OpenSpec schema copy (openspec/schemas/spec-driven-longish/) with the canonical copy in the openspec-schemas clone, report fleet drift across every OpenSpec repository, or compare the canonical schema with the upstream @fission-ai/openspec spec-driven schema. Read-only; reports drift, modifies nothing. Use when the user asks to "check openspec drift", "is the schema in sync with the canonical", "compare with the canonical copy", "fleet drift", "is our openspec schema still in sync", "compare our openspec schema with upstream", or "openspec upstream drift".
---

# OpenSpec Schema Drift Detection

Repositories vendor the `spec-driven-longish` schema from the canonical clone (the target of `~/.local/share/openspec/schemas/spec-driven-longish`, normally `~/projects/akalongman/openspec-schemas/schemas/spec-driven-longish`), with a `SOURCE` file naming the canonical commit they were copied from. This skill reports whether a copy still matches the canonical, for one repository or the whole fleet, and whether the canonical itself has drifted from upstream `spec-driven`. It is detect-only: it reports drift, modifies nothing, never installs hooks.

## When to invoke

User phrases:
- "check openspec drift"
- "is the schema in sync with the canonical"
- "compare with the canonical copy"
- "fleet drift", "which repositories are behind the canonical"
- "is our openspec schema still in sync"
- "compare our openspec schema with upstream", "openspec upstream drift"

## Execution

All logic lives in the bundled script `scripts/drift-check.sh` (relative to this skill's base directory). Do NOT inline, reconstruct, or modify the script; run it as-is in a single Bash invocation, in one of three forms:

| Question | Command |
|---|---|
| Is this repository's copy in sync with the canonical? | `bash <skill-base-dir>/scripts/drift-check.sh [REPO]` (REPO defaults to the current directory) |
| Which repositories are out of sync? | `bash <skill-base-dir>/scripts/drift-check.sh --fleet` |
| Has the canonical drifted from upstream spec-driven? | `bash <skill-base-dir>/scripts/drift-check.sh --upstream` (from any directory) |

Substitute `<skill-base-dir>` with the base directory announced when this skill was loaded. The script always exits 0, whatever it finds. `-h`, an unknown option, `--fleet` with `--upstream`, either of them with a REPO, or more than one REPO prints the usage line instead.

## Reading the output

The default form prints one line, `<org>/<repo>  <status>`; when the copy is locally modified, its diff follows that line. `--fleet` first prints `canonical: <clone> @ <commit>`, or `canonical: none (run the machine playbook, tag openspec)` when there is no canonical, then one such line per repository with the statuses in one column, then each locally modified copy's diff under a `diff: <org>/<repo>` line; when it finds no repository, `no OpenSpec repository found under: <roots>` follows the header. A diff runs from the vendored commit to the copy and is capped at 40 lines. The statuses:

| Status | Meaning | Suggest |
|---|---|---|
| `in sync` | byte-identical to the schema tree of the clone's HEAD, whatever commit `SOURCE` names | nothing |
| `behind canonical (vendored X, canonical Y)` | identical to the tree of the commit `SOURCE` names, which differs from HEAD's | `openspec-fleet schema-sync <repo>` |
| `locally modified (differs from vendored X; diff below)` | edited after vendoring | move a schema change into the canonical clone and a project rule into the repository's `openspec/config.yaml`, then re-sync |
| `legacy copy (no SOURCE; ...)` | no `SOURCE`, or one whose `commit:` line is not 40 hex characters | `openspec-fleet schema-sync <repo>` |
| `upstream spec-driven (no copy; ...)` | uses the schema OpenSpec ships (also when `config.yaml` has no `schema:` line) | the per-repository recipe switches it |
| `missing copy` | declares a schema whose directory under `openspec/schemas/` is absent | check the declared name, then `openspec-fleet schema-sync <repo>` |
| `unknown commit (...)` | `SOURCE` names a commit the canonical clone does not hold | fetch in the canonical clone |
| `no canonical (run the machine playbook, tag openspec)` | the canonical link is missing or does not point into a git clone with a commit | run the machine playbook, tag `openspec` |
| `cannot read vendored X from the canonical clone` | git could not read that commit's tree (an error, not a state of the copy) | check the canonical clone |

`not an OpenSpec project (...)` means REPO has no `openspec/config.yaml`.

`--upstream` prints the two schema paths, a schema-block table and a templates table for the canonical against upstream `spec-driven` and, when something diverged, per-block diffs and how to absorb the change in the canonical clone. It reads the canonical's working tree, so uncommitted edits there count, and a key either schema lacks shows in its row as an empty value (`null` when yq is the reader). Relay it: `overlay` means the canonical contains upstream's text, and an upstream deletion reads the same way, so it is not evidence of an intentional addition. When it prints a short message instead of the tables, the comparison could not run; report the message as the answer. Such messages include `no canonical (...)`, `the canonical schema is missing at <path>`, `the canonical schema cannot be read at <path> (<reason>)` (for example a `schema.yaml` left half-edited), `the upstream schema cannot be read at <path> (<reason>)`, "OpenSpec is not installed globally", and the note that yq or python3 with PyYAML is required.

## Why the logic is a script, not inline code blocks

When a skill is invoked as a slash command, the harness substitutes argument placeholders (a dollar sign followed by a digit 1-9, or by the word ARGUMENTS) inside the rendered SKILL.md body with the command's arguments. Inline shell that uses positional parameters or awk column references gets silently corrupted; each placeholder becomes empty when the skill is invoked without arguments. Keeping the shell in a bundled script file avoids the substitution entirely. If you ever see mangled shell in this file's rendered form, the file on disk is still authoritative.
