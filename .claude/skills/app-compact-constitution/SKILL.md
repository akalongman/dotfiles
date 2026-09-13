---
name: app-compact-constitution
description: Use when the user asks to compact, shrink, audit, review, or restructure a project's CLAUDE.md or "constitution", asks whether CLAUDE.md is too long, or wants it to become the index that OpenSpec specs, rules, and skills hang off.
argument-hint: [audit | apply <finding IDs>]
---

# Compact the project CLAUDE.md

Two gated phases. `audit` (the default) is read-only and ends with a report. `apply` runs only after the user names the findings to apply, and never on the same turn as the audit.

## What the audit is about

CLAUDE.md is loaded into every session of the project, so every line is paid on every turn. The audit answers two questions: is anything in it wrong, and does anything in it belong somewhere that loads on demand instead.

Loads at launch, every session (moving text between these saves nothing):

- `./CLAUDE.md`, `./.claude/CLAUDE.md`, `CLAUDE.local.md`, and the same files in every parent directory
- `@path` imports inside those files (up to four hops deep)
- `.claude/rules/*.md` and the user-level `rules/*.md` files that have no `paths:` frontmatter
- the user-level `CLAUDE.md` (the config directory is `$CLAUDE_CONFIG_DIR`, default `~/.claude`)

Loads on demand (extraction targets that do save context):

- `.claude/rules/*.md` with `paths:` frontmatter (loads when a matching file is read)
- Skills under `.claude/skills/` (multi-step procedures)
- `CLAUDE.md` in a subdirectory (loads when files there are read)
- OpenSpec capability specs under `openspec/specs/<name>/spec.md`
- Any file named in backticks (a plain path mention is not an import)

Block-level HTML comments are stripped before injection, so maintainer notes in `<!-- -->` cost nothing.

Size guidance: under 200 lines per file. Basis: https://code.claude.com/docs/en/memory, section "Write effective instructions" (size, structure, specificity, consistency). Fetch that page at the start of every audit; it is cheap, and the numbers move.

## Target shape

Every project converges on the same constitution, with these headings in this order. Anything else is either wrong, derivable, or belongs on demand. Omit a heading whose slot is empty rather than leaving a placeholder.

1. `## Overview`: what the project is, the stack, the audiences. Three to five lines.
2. `## Spec-driven development`: OpenSpec projects only; the paragraph from the user-level `rules/openspec.md` bootstrapping section, verbatim.
3. `## Commands`: only the ones that differ from the manifest defaults or carry a gotcha, with the gotcha on the same line.
4. `## Architecture`: the layers, one or two lines each, and coarse "when to use" decisions. Omit it when the dictionary already covers every layer.
5. `## Dictionary`: one table that is the index for progressive disclosure. A row exists because there is a rule, not because there is a file: a row whose rule column only says what a file contains is derivable (A5) and is deleted. Every domain term with a rule and every topic whose detail lives elsewhere gets a row; when a row is added for a topic that has an inline paragraph, the paragraph goes.

   | Term or topic | Where | One-line rule |
   |---|---|---|
   | Parcel | `parcels` | Central entity; lifecycle is a sequence of logistic events. |
   | Form requests | `api-infrastructure` | Every action with input injects a `FormRequest` subclass. |
   | Sub-user linking | `customer-accounts` (no spec yet) | Verified PN is the only lookup key; phone is a sanity check. |

   "Where" is the capability name from the map in `openspec/config.yaml`, marked "no spec yet" when `openspec/specs/<name>/spec.md` does not exist; on other projects it is the path of a path-scoped rule file, a skill directory, or a source file. The rule column stands alone, under about 40 words: a reader who never opens the target still grasps the headline, and a multi-rule cluster is summarised by its class name and threshold keywords, not restated. This table replaces any separate "domain concepts" list and the capability-spec table from the user-level `rules/openspec.md`; that rule's template should be updated to this heading and these columns in the same commit that installs this skill.
6. `## Project-specific rules`: high-consequence rules that nothing else enforces (a migration discipline, a refactor discipline), each in a few lines.

Then the generated block, if the project has one.

## Global constitution mode

Use this mode when the target is the user-level file, `$CLAUDE_CONFIG_DIR/CLAUDE.md` (default `~/.claude/CLAUDE.md`): the user names it, or the audit runs from the home directory. Everything below overrides the project mode; what is not mentioned applies as written.

- **Scope is the always-loaded set**, not one file: the global `CLAUDE.md` plus every user-level rule without `paths:`. Findings against a rule file carry its path in the Lines column, and Phase 5 edits it where it lives (a symlinked rule is edited in its source repository).
- **Measure in words, not lines.** House limits, not documented ones: the always-loaded set under about 3,000 words; a bullet under 60 words; a prose section under 120 words unless it is a workflow. Replace the Phase 1 script with:

  ```bash
  cfg="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"; f="$cfg/CLAUDE.md"
  echo "$f: $(wc -l < "$f") lines, $(wc -w < "$f") words"
  for r in "$cfg"/rules/*.md; do [ -f "$r" ] && printf '%-48s %-13s %5s words\n' "$r" "$(command grep -q '^paths:' "$r" && echo path-scoped || echo always-loaded)" "$(wc -w < "$r")"; done
  awk '/^- / && NF > 60 { printf "%4d words  L%d  %s...\n", NF, NR, substr($0, 3, 60) }' "$f"
  awk '/^## /{ if (h) printf "%5d words  %s\n", w, h; h=$0; w=0; next } { w+=NF } END { printf "%5d words  %s\n", w, h }' "$f"
  ```

- **Target shape** for the global file, headings in this order:
  1. `## Working agreements`: how the user wants the agent to think, decide, and communicate, cross-cutting, one line each.
  2. `## Stops`: actions that need confirmation regardless of autonomy (branching, parked notes, editing this file).
  3. `## Style`: writing and formatting conventions.
  4. `## Index`: one table, `Topic | Where | Loads when`, with a row per user-level rule file and per command. Skills get no rows: the harness lists every skill with its description in each session, so a row would be an A4 copy. Always-loaded rules keep a row ("always") for discoverability.
  5. `## Workflows`: cross-cutting procedures that must stay global (self-improvement, memory versus constitution, parking lot), each in a few lines.
- **On-demand homes.** A rule whose first sentence names a language, framework, file type, or tool belongs in the user-level rule with `paths:` for it (A7); a procedure belongs in a user-level skill; a fact about one project belongs in memory. Create a new path-scoped rule file when none fits, and add its Index row. Exception: a rule that fires when a file is created (a new Dockerfile, a new command file) reads no matching file first, so a path-scoped home misses it; keep a one-line pointer under Working agreements and put the detail in the rule.
- **Incident-derived bullets.** The rule stays in one or two sentences; the incident shrinks to a trailing parenthesis of the date plus a few words, so the growth pattern stays visible.
- **Rubric adjustments.** A3 is for instructions that differ; an identical copy is A4. A5 means derivable from files under the config directory (commands, scripts, hooks). Phase 2 checks only statements that name a file, command, or tool; behavioural preferences are not listed under "Not checked". Not applicable: rubric B, A6 unless a tool writes the file, the `/doctor` pointer, Phase 5 steps 3 and 4.
- **Report and closing check.** Use the Phase 4 template with word counts in place of line counts and the global target shape in "Proposed shape". Resolve Index rows with `cd "$cfg"` and `[ -e "$w" ]`, no OpenSpec branch.
- **Recommend the routing rule** in the report when the file grew by incident bullets: new rules go to the matching path-scoped file by default, and only cross-cutting agreements stay global. Changing that is the user's decision.

## Phase 1: measure

From the project root:

```bash
f=CLAUDE.md; [ -f "$f" ] || f=.claude/CLAUDE.md
[ -f "$f" ] || { echo "no CLAUDE.md here"; exit 0; }
total=$(wc -l < "$f")
open=$(command grep -n -m1 -E '^<[a-z-]+-guidelines>|<!-- *(BEGIN|START)' "$f" | cut -d: -f1)
if [ -n "$open" ]; then
  echo "$f: $total lines total, $((open - 1)) hand-written, $((total - open + 1)) generated (block starts at line $open)"
else
  echo "$f: $total lines, all hand-written"
fi
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
for r in .claude/rules/*.md "$cfg"/rules/*.md; do
  [ -f "$r" ] && printf '%s: %s\n' "$r" "$(command grep -q '^paths:' "$r" && echo path-scoped || echo always-loaded)"
done
ls .claude/skills .claude/commands 2>/dev/null
if [ -f openspec/config.yaml ]; then
  echo "OpenSpec: yes"; ls -d openspec/specs/*/ 2>/dev/null
  echo "capability map:"
  awk 'tolower($0) ~ /capability map/ {f=1; next} f && (/^ *# / || /^[a-z_]+:/) {exit} f && /^ *- [a-z0-9-]+:/ {print}' openspec/config.yaml
else
  echo "OpenSpec: no"
fi
```

The hand-written count is the number the user controls and the one the 200-line target applies to. Report both counts.

## Phase 2: verify before judging

Read the file in full. Judge it against the working tree as it is now, since that is what the agent sees each session; if a claim is false only because of uncommitted changes, or because it describes a gitignored per-machine file such as `.env`, say so in the finding.

Check every concrete claim with cheap read-only commands:

- versions and package manager (lock files, `packageManager` field)
- counts ("45+ enums")
- paths, route files, guard and driver names (config, `bootstrap/app.php`)
- commands (do the scripts exist, do they do what the file says)
- every "always" and "never" statement: verify that each named class, method, column, and command exists, and search the code for violations where a search can settle it. Do not read method bodies to prove behavioural invariants; list those under "Not checked".

A false claim outranks a long file: the agent acts on it every session.

Then check the file against its neighbours: project rule files, the user-level `CLAUDE.md` and `rules/`, skills under `.claude/skills/`, OpenSpec specs, and any generated block. Two instructions for one action is a defect even when both are individually correct.

## Phase 3: rubric

Every finding carries one rubric ID (the closest fit), a line range, a severity, a one-sentence problem, and a concrete suggestion naming the destination file.

Severity: `high` = false, or two instructions for one action; `medium` = derivable, duplicated, or extractable; `low` = polish. A stale count is `medium` under A5 unless a decision depends on the number. A generated block is graded on the contradictions it creates, not on its length.

**A. Every project**

| ID | Check | Suggest |
|---|---|---|
| A1 | Hand-written part over 200 lines | Name the sections that leave and where each goes. |
| A2 | Claim contradicted by the codebase or by itself | Correct it, or delete it and point at the source of truth. |
| A3 | Two instructions for one action (inside the file, or versus a rule file, a skill, a spec, or a generated block) | Keep one and say which wins. If the generated block is the odd one out, see A6. |
| A4 | Verbatim copy of something that already loads (user-level files, always-loaded rules, generated block) | Delete the copy. A copy of a path-scoped rule or a skill is a trade-off, not a pure win: say so. |
| A5 | Derivable from the repo: directory layouts, dependency lists, counts, current-state inventories, scripts already listed in the package manifest | Delete, or leave one pointer line. The user can also run `/doctor`, which proposes these trims (Claude Code 2.1.206 or later). |
| A6 | Generated block (marker tags, or installed by a tool) | Never hand-delete. Name the generator and its switch from the table below. Report its line count separately. |
| A7 | Always-loaded content that belongs on demand: multi-step procedure, rules for one area of the code, behaviour contract with rationale, narrative history | Procedure: skill. Area rule: `.claude/rules/<topic>.md` with `paths:`. Contract: capability spec (OpenSpec) or a path-scoped rule. History: `git log`; delete. |
| A8 | Vague rule ("keep files organized") | Rewrite as something verifiable, or delete. |
| A9 | Same concept under two names, or a heading that disagrees with the body | Pick one. |

Known generators for A6:

| Marker | Generator | Switch |
|---|---|---|
| `<laravel-boost-guidelines>` | `php artisan boost:update` (usually in composer `post-update-cmd`) | `"guidelines": false` in `boost.json`. Per-section exclusion reads `config('boost.guidelines.exclude')`; `config/boost.php` is not published by default, so that route needs `vendor:publish` first and the section keys verified. |

For any other marker, find the generator in `composer.json` and `package.json` scripts before suggesting anything.

**B. OpenSpec projects only**

| ID | Check | Suggest |
|---|---|---|
| B1 | Capability table present, with a row for every `openspec/specs/*/` and for every inline rule that has a spec | Add the missing rows. |
| B2 | Each row is a self-contained one-line rule, not a topic name | Rewrite the row. |
| B3 | Inline cluster of related rules with rationale, examples, or gotchas | Extract to a spec. Take the capability from the map in `openspec/config.yaml`; a mapped capability with no spec yet is an existing capability, and extracting existing convention into it is a normal propose, apply, archive cycle. Leave one table row behind. |
| B4 | Inline text that re-derives or contradicts a spec | Delete; the spec is authoritative. |
| B5 | Spec-driven workflow pointer present | Add it if missing. |
| B6 | `openspec/config.yaml` restates the constitution (stack, routes, guards, architecture), including inside its summary paragraph | Cut it to the OpenSpec-native minimum: a summary paragraph that names the project and its audiences without restating stack or architecture, the constitution pointer, the capability map, and workflow conventions. A false claim in the config is A2 with the config file as the location. |
| B7 | Dictionary table missing rows: a spec directory, a mapped capability that CLAUDE.md discusses, or a domain term with no row | Add the row; "no spec yet" is a valid Where. |

**Stays inline** (do not flag, or flag `low` with the trade-off): the tech stack in one short section, the layered architecture in a few lines, one or two lines per domain entity, commands that differ from the manifest defaults or carry a gotcha, project-specific high-consequence rules that nothing else enforces, and the capability table. On an OpenSpec project the "Stays inline" list in the project's `.claude/rules/openspec.md` (or the user-level one) wins if it differs; on other projects this list applies.

## Phase 4: report

Emit to chat, not to a file, unless asked.

```markdown
# CLAUDE.md audit

**Size:** <total> lines (hand-written <n>, generated <n>). OpenSpec: <yes|no>. Target: under 200 hand-written lines.

## Verdict
One paragraph: is it too long, is anything in it wrong, what is the single highest-impact change.

## Findings
| ID | Sev | Lines | Problem | Suggestion |
|---|---|---|---|---|
ordered high, medium, low; end with the IDs that pass

## Verified true
Grouped by section of CLAUDE.md, one line per claim that holds. Mark claims that are true today but will drift (current-state inventories).

## Not checked
Claims you could not settle with a search, one line each.

## Proposed shape
The target shape applied to this file: which existing sections map to which slot, which sections leave and where each goes (CLAUDE.md edit, path-scoped rule, skill, OpenSpec change), and the expected hand-written line count.

## Next step
Which findings to apply. Nothing is changed until you choose.
```

Then stop. Do not edit CLAUDE.md, rule files, specs, or the OpenSpec config until the user names the findings to apply.

## Phase 5: apply (only with named findings)

Input: the finding IDs the user chose. Sort them by destination, because the write rules differ. Findings that land on one destination may be applied as a single rewrite of the affected sections; show one diff per destination. Never touch a generated block.

1. **CLAUDE.md edits** (A2, A3, A4, A5, A8, A9, B1, B2, B5, B7, and A7 deletions of history): edit in place. Corrected facts come from the Phase 2 evidence, not from memory. Rules for the cases that recur:
   - A per-machine file (`.env`, local config) is never quoted as a fact. Point at its committed template (`.env.example`) and say the live file is per machine.
   - A3 where the loser is a generated block: delete the hand-written copy and add one line under `## Project-specific rules` saying the block wins on that topic. A3 between two hand-written places: delete one, write nothing about precedence.
   - A3 outranks a command gotcha: keep the gotcha only if it can be stated without naming a second command for the same action.
   - Add dictionary rows for specs that already exist, and delete the inline paragraph each row replaces.
2. **Non-spec extractions** (A7 to a path-scoped rule, a skill, or a subdirectory `CLAUDE.md`): create the target file with the text moved verbatim, then replace the source with one dictionary row. A rule file gets `paths:` frontmatter covering the code it governs; a skill gets a `description` that names its triggers only.
3. **Spec extractions** (B3, A7 to a spec): never write `openspec/specs/**` directly. Draft one OpenSpec change per extraction, named `extract-<topic>-into-<capability>`, through the project's propose command. That command interviews before drafting; if the accepted finding already states the scope (verbatim move, no behaviour change, one row left behind), pass those as the answers, otherwise let the interview run. Shape of the delta, which the tooling treats as a new spec even for a mapped capability:
   - `## Purpose` plus `## ADDED Requirements`.
   - One requirement per inline rule. Each opens with a one-sentence SHALL statement (strict validation needs it on the first body line) followed by the inline text verbatim; class and method names are accepted in an extracted convention.
   - Scenarios come from the thresholds and outcomes the prose states. Reading the named class to confirm them is allowed here, unlike Phase 2.
   - The historical note becomes `## Rationale`.
   - A minimal `design.md` when the schema requires one, saying no trade-offs exist.
   - `tasks.md`: delete the source section, add the dictionary row (rule column under 40 words), validate, hand back for archive.
   Stop at the propose gate; apply and archive are the user's calls.
4. **OpenSpec config** (B6): apply the cut described in the rubric.

After the last edit, rerun Phase 1 and report: hand-written line count before, after, and projected after pending spec extractions are applied; findings still open at the propose gate; and every dictionary row checked to resolve, with this loop from the project root:

```bash
command grep -E '^\| [^|]+ \| `[^`]+`' CLAUDE.md | sed -E 's/^\| [^|]+ \| `([^`]+)`.*/\1/' | while read -r w; do
  if [ -e "$w" ] || [ -e "openspec/specs/$w/spec.md" ]; then echo "ok  $w"
  elif [ -f openspec/config.yaml ] && command grep -q -E "^ *- $w:" openspec/config.yaml; then echo "map $w (no spec yet)"
  else echo "MISSING $w"; fi
done
```
