---
name: app-compact-constitution
description: Use when the user asks to "compact CLAUDE.md", "audit the constitution", "is CLAUDE.md too long", "shrink CLAUDE.md", "check progressive disclosure in CLAUDE.md", or otherwise wants a project's root CLAUDE.md reviewed against Anthropic's skill-authoring best practices and (if the project uses OpenSpec) the Progressive Disclosure pattern. Read-only; produces a structured report of findings and concrete refactoring suggestions, modifies nothing.
---

# Compact Constitution: Audit ./CLAUDE.md

Audit the root `./CLAUDE.md` of the current project and report whether it is concise, well-structured, and (when the project uses OpenSpec) follows the Progressive Disclosure pattern. The skill is suggest-only: it produces a structured report with line-anchored findings and concrete refactoring suggestions. It MUST NOT edit any file.

## When to invoke

Trigger phrases:
- "compact CLAUDE.md" / "shrink CLAUDE.md" / "is CLAUDE.md too long"
- "audit the constitution" / "review the constitution"
- "check progressive disclosure in CLAUDE.md"
- "is CLAUDE.md following Anthropic best practices"

Run from the project root (the directory containing `CLAUDE.md`).

## Core principle

CLAUDE.md is loaded into the system prompt of every session in this project. Every line in it taxes every future turn. The job of CLAUDE.md is to be a thin orientation layer that points to deeper material, not to be a rule encyclopedia. The deeper material lives in:

- Capability specs under `openspec/specs/<capability>/spec.md` (OpenSpec projects)
- Rule files under `.claude/rules/*.md` (referenced via `@.claude/rules/...`)
- Code, migrations, factories (anything derivable by reading the project)

If a fact is derivable from the codebase, or already documented in a rule/spec file, it does NOT belong inline in CLAUDE.md.

## Execution

Work in three phases: pre-flight, audit, report. Do not modify any file in any phase. After the report is delivered, ask the user which findings to apply before touching CLAUDE.md.

### Phase 1: Pre-flight

```bash
set -euo pipefail

if [ ! -f CLAUDE.md ]; then
    echo "No CLAUDE.md in $(pwd). Run this skill from the project root."
    exit 0
fi

LINES=$(wc -l < CLAUDE.md)
WORDS=$(wc -w < CLAUDE.md)
CHARS=$(wc -c < CLAUDE.md)
echo "CLAUDE.md: ${LINES} lines, ${WORDS} words, ${CHARS} chars"

USES_OPENSPEC=false
if [ -d openspec ] && [ -f openspec/config.yaml ]; then
    USES_OPENSPEC=true
    echo "OpenSpec detected: openspec/config.yaml present."
fi

if [ "$USES_OPENSPEC" = true ]; then
    ls openspec/specs/*/spec.md 2>/dev/null | sed 's|^openspec/specs/||;s|/spec\.md$||' | sort
fi
```

Use the line / word / char counts as the headline metric in the report (no hard limit, but flag anything over ~400 lines or ~3500 words as worth investigating). Capture the capability-spec list for cross-referencing in Phase 2.

### Phase 2: Audit

Read `CLAUDE.md` in full. Then apply two rubrics:

**Rubric A — Always applies (derived from Anthropic's skill-authoring guidance, adapted for CLAUDE.md as a system-prompt artifact):**

| # | Check | What to look for | Suggested fix |
|---|---|---|---|
| A1 | Concise | Paragraphs that explain general programming concepts, framework basics, or things any agent already knows | Delete. Trust the model. |
| A2 | Self-documenting code wins | Setup steps, install commands, or file-path listings derivable from `composer.json`, `package.json`, `.env.example`, or directory structure | Replace with a one-line pointer ("see `composer.json` scripts" or "run `composer dev`"). |
| A3 | No time-sensitive content | Phrases like "as of October 2025", "we recently migrated", "the new way is" | Either delete or move into a collapsed "Old patterns" section. |
| A4 | No narrative history | "We used to do X, then we tried Y, now we do Z", "added in MR !42", "after the Q3 incident" | Delete. History belongs in `git log` / MR descriptions. |
| A5 | Consistent terminology | Same concept named two or three ways ("API endpoint" vs "route" vs "URL", "spec" vs "capability spec" vs "openspec spec") | Pick one. Use it everywhere. |
| A6 | One-level references | Pointers like `@.claude/rules/php.md` that themselves load another file, or "see X.md which references Y.md" | Either inline the relevant rule summary or flatten the reference so CLAUDE.md links directly to the leaf doc. |
| A7 | Forward-slash paths only | Backslashes in paths (`scripts\foo.php`) | Replace with `/`. |
| A8 | No duplicated rule files | The same rule appears verbatim in CLAUDE.md AND in `.claude/rules/<topic>.md` | Keep one canonical source. CLAUDE.md should reference, not copy. |
| A9 | No duplication of the user's global CLAUDE.md | Sections in `./CLAUDE.md` that restate content already in `~/.claude/CLAUDE.md` (Documentation conventions, Git commits, Coding-Standards rule-file pointers, etc.) | Delete from project CLAUDE.md. The global file is already loaded into every session. Re-include only the lines that genuinely differ from the global. |
| A10 | Loads efficiently | Multi-page MCP-server / Boost / framework guideline blocks pasted inline | Move to a separate `.md` file under `docs/` or `.claude/rules/` and link from CLAUDE.md with one line — UNLESS the block is auto-regenerated by tooling (see "Auto-managed blocks" below). |
| A11 | Auto-managed blocks | Sections wrapped in marker tags like `<laravel-boost-guidelines>...</laravel-boost-guidelines>` or generated by an installer (Boost, IDE plugins, framework scaffolders) | Do NOT silently recommend deletion — the next install/upgrade will regenerate it. Either (a) leave it and note the cost in the verdict, or (b) recommend disabling the generator in its config first, then deleting. Cite the regenerator command if known. |
| A12 | Headline metric | Total lines, words, chars exceed a reasonable budget | Flag as an aggregate finding; aim for under ~400 lines / ~3500 words on a mature project. |

**Rubric B — Applies when `USES_OPENSPEC=true`:**

| # | Check | What to look for | Suggested fix |
|---|---|---|---|
| B1 | Capability-spec table exists | A Markdown table that maps each capability to its `openspec/specs/<name>/spec.md` file | If missing, propose adding it. If present, verify each capability listed in `openspec/specs/` has a row. |
| B2 | Stays-inline content only | Inline content matches the "Stays inline" allowlist: tech-stack list, layered-architecture diagram, coarse Service-vs-Action decisions, command list, capability-spec table, 1-2-line domain-concept intros, code-style block | Anything outside this list is a candidate for extraction. |
| B3 | No multi-rule clusters inline | Sections that bundle 3+ related rules with worked examples, gotchas with WHY explanations, or WHEN/THEN scenarios | Extract to a capability spec. Replace with a one-line summary plus a link in the capability-spec table. |
| B4 | 5-line extraction trigger | Any single rule narrative inline that runs more than ~5 lines of detail | Strong signal to extract. Recommend the target capability from the existing capability-spec list. |
| B5 | Capability summaries are self-contained | Each row of the capability-spec table is a complete one-line headline (a reader who never opens the spec still grasps the rule) | If a row is just a topic name without a rule headline, flag it. |
| B6 | No spec-derivable detail | Inline blocks that re-derive or contradict content already in `openspec/specs/<name>/spec.md` | Delete the inline version. The spec is authoritative. |
| B7 | Workflow pointer | A "Spec-driven development" section that points to the OpenSpec workflow (`/opsx:propose` → `/opsx:apply` → `/opsx:archive`) | If missing, propose adding it (per the OpenSpec bootstrapping convention). |

For each finding, capture:

- Severity (`high` = wastes context every turn / contradicts a spec, `medium` = extractable but not dangerous, `low` = polish)
- Line range in `CLAUDE.md` (e.g. `L120-L145`)
- Rubric ID (A1, A8, B3, etc.)
- One-sentence problem statement
- Concrete suggestion (which spec to extract to, which file to delete, what one-line summary to leave behind)

### Phase 3: Report

Emit a single Markdown report to the chat (do not write it to a file unless the user asks). Use this template:

```markdown
# CLAUDE.md audit

**Headline:** ${LINES} lines / ${WORDS} words / ${CHARS} chars. OpenSpec: ${yes|no}.

## Verdict
[One paragraph: is the file concise, does it follow Progressive Disclosure (if applicable), what is the single highest-impact change.]

## High-severity findings
| Rubric | Lines | Problem | Suggestion |
|---|---|---|---|
| Bx | Lyyy-Lzzz | ... | ... |

## Medium-severity findings
[same table]

## Low-severity findings
[same table]

## Proposed structure (if reorg recommended)
[A short outline of what CLAUDE.md would look like after extractions, showing which sections stay, which collapse to one line, and where each extracted block lands (which existing capability spec, or a new one with a justification).]

## Next step
Ask which findings to apply. Apply only with explicit user approval, one section at a time.
```

After delivering the report, STOP. Wait for the user to pick which findings to apply. Do not pre-emptively edit `CLAUDE.md`.

## When to skip a finding

Some content looks redundant but is load-bearing — keep it inline:

- The tech-stack list (one short section). Even though `composer.json` carries it, having it inline gives the model immediate orientation without a tool call.
- The layered-architecture diagram and 1-2 lines per layer. Cheap, high-signal.
- The command list (`composer test`, `composer phpcs`, ...). Developers paste these; agents run them.
- The capability-spec table itself.
- Auth-helper test code snippets and response-assertion enumerations (operational essentials).

If a finding would gut one of these, mark it `low` and explain the trade-off rather than recommending deletion.

## Red flags — STOP and reconsider

- "Just delete the whole `<huge block>` section" → too aggressive. Propose extraction with a specific target spec instead.
- "Move this to a new capability" → only justified if no existing capability fits. Reuse before creating.
- "Inline more here so the agent doesn't have to read the spec" → wrong direction. CLAUDE.md gets thinner, not fatter.
- "Apply the fixes now" without the user having seen the report → never. Read-only by default.

## Common rationalizations

| Excuse | Reality |
|---|---|
| "The file looks fine, it's organized" | Organized ≠ concise. Count lines and words first, then check the rubric. |
| "Removing X breaks the agent's understanding" | If X is in a spec or derivable from code, the agent can fetch it on demand. Inline ≠ accessible; on-demand reads are cheap. |
| "The user will know what to extract" | The user invoked this skill BECAUSE they want a checked rubric. Be specific about extraction targets and line ranges. |
| "It uses OpenSpec, so the OpenSpec rubric is enough" | Rubric A still applies. Anthropic-style conciseness is independent of Progressive Disclosure. |
| "There's no openspec/ folder, so I can skip Rubric B" | Correct — but still recommend the user document where rule detail lives (rule files, README sections, ADRs). |

## Cross-references

- Anthropic skill-authoring best practices (conciseness, progressive disclosure, terminology, time-sensitive content) — fetch the current version with the `search-docs` Boost tool or via `WebFetch` against the Anthropic docs site if the agent needs to re-derive the rubric.
- For OpenSpec projects, the project's own `.claude/rules/openspec.md` (or the user's global `~/.claude/rules/openspec.md`) defines the "Stays inline" vs "Moves to a capability spec" split this skill audits against. Treat that file as the authoritative source if it differs from this skill.
