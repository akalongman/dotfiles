---
name: rules-openspec
description: Apply these rules when a project has an `openspec/` directory.
---

# OpenSpec Project Conventions

Apply these rules when a project has an `openspec/` directory.

## The constitution lives in CLAUDE.md

The project's `CLAUDE.md` is the OpenSpec constitution. It is the single source of truth for:

- Tech stack and infrastructure
- Architectural patterns and request lifecycle
- Coding conventions and naming rules
- Authentication tiers, routing conventions, module boundaries
- Commands for development, testing, and tooling

Do not re-derive or contradict the constitution inside `openspec/` files.

## CLAUDE.md uses Progressive Disclosure

CLAUDE.md is a thin orientation layer, not a rule encyclopedia. Most rule detail belongs in capability specs under `openspec/specs/<capability>/spec.md`. CLAUDE.md points to those specs from a single capability-spec table; the detail lives in the spec.

**Stays inline in CLAUDE.md:**

- Tech stack and infrastructure list (one short section).
- Layered architecture overview (the diagram + 1-2 lines per layer).
- Coarse "when to use" decisions (e.g. Service vs Action) that orient a reader.
- Operational essentials a developer types or pastes: command list (`composer test`, `composer phpcs`, etc.), test auth-helper code blocks, response-assertion enumerations.
- Domain Concepts intros: 1-2 lines per entity, NOT the detailed behavior.
- Code Style + Commands block.
- The capability-spec table itself (the index that points to every spec).

**Moves to a capability spec:**

- Rule narratives with their own enforcement story (CI gate, runtime error, code review focus).
- Multi-rule clusters with worked examples (e.g. "API resources" covering attributes-vs-relationships, includeXxx pattern, threading context, named-arg gotcha — all in one spec).
- Gotchas with WHY explanations (YAML colon-space mapping error, lodash named-arg dispatch, silent failure modes).
- Verification protocols (e.g. "run `composer docs` and treat as blocking").
- Anything that needs WHEN/THEN scenarios to fully describe the contract.

**Capability-spec table format** in CLAUDE.md:

```markdown
## Capability specs (Progressive Disclosure)

For canonical detail, read the cited capability spec under `openspec/specs/<name>/spec.md`. Rules below are summaries; the spec is the source of truth.

| Topic | Spec | Rule summary |
|---|---|---|
| <Topic name> | `<spec-name>` | <one-line summary capturing the most-cited rule and any gotcha keyword> |
```

The summary should be self-contained enough that a reader who never opens the spec still grasps the headline rule. The spec carries the detail, scenarios, and rationale.

**Extracting existing inline convention is fine.** The "do not stub empty specs" rule (in Bootstrapping below) is specifically about empty stubs that force artificial `ADDED Requirements` deltas. Extracting an existing body of inline CLAUDE.md convention into a born-populated spec is a real change with real content — run a normal `/opsx:propose` → `/opsx:apply` → `/opsx:archive` cycle for the extraction. If you find yourself about to add 5+ lines of rule detail to CLAUDE.md, that's a signal to extract instead: add a row to the capability-spec table and put the detail in a new (or existing) spec.

## What belongs in `openspec/config.yaml`

Keep the file minimal and OpenSpec-native. Include only:

- A one-paragraph project summary (so a proposal reader knows which project this is).
- A pointer stating that `CLAUDE.md` is the constitution.
- A **capability map**: kebab-case capability names with one-line descriptions. This map is the taxonomy for `openspec/specs/<capability>/spec.md` entries. Group capabilities under short headings (Customer, Commerce, Integrations, Platform, etc.).
- OpenSpec workflow conventions specific to this project (for example, "scenarios must be testable against Pest feature tests", or "changes touching integration X must also update docs/http/").
- A `rules:` block with per-artifact rules (proposal / design / tasks).

Example shape:

```yaml
schema: spec-driven

context: |
  # Constitution
  The project constitution is CLAUDE.md. Treat it as the source of truth
  for tech stack, architecture, and conventions.

  # Project summary
  <one paragraph>

  # Capability map
  <grouped, kebab-case capability list>

  # OpenSpec workflow conventions
  <project-specific rules>

rules:
  proposal:
    - <rule>
  tasks:
    - <rule>
```

## What does NOT belong in `openspec/config.yaml`

Do not copy from the constitution:

- Tech stack details (language, framework, runtime, queues, storage)
- Architectural patterns already described in CLAUDE.md
- Coding standards
- Commands
- Infrastructure notes

If `config.yaml` and `CLAUDE.md` would say the same thing, delete it from `config.yaml`.

## Bootstrapping a project for OpenSpec

When setting up OpenSpec in a new or existing project:

1. Confirm `CLAUDE.md` exists and contains the constitution. If missing, build it first; OpenSpec on top of a blank CLAUDE.md gives poor proposals.
2. Derive the capability map by scanning the codebase (models, controllers, integrations, admin resources). Consolidate into coarse-grained capabilities (kebab-case, typically 10 to 20 per project). Do not over-fragment.
3. Write `openspec/config.yaml` following the shape above. Reference CLAUDE.md as the constitution. Do not duplicate its content.
4. Add a "Spec-driven development" section to `CLAUDE.md` with this structure:

   ```markdown
   ## Spec-driven development

   This project uses OpenSpec for non-trivial changes. This file (CLAUDE.md) is the project constitution, the source of truth for tech stack, architecture, and conventions. The capability map and OpenSpec-native conventions live in `openspec/config.yaml`.

   Workflow: `/opsx:propose` → `/opsx:apply` → `/opsx:archive`. For exploratory thinking without committing to a change, use `/opsx:explore`.
   ```

5. Do not stub empty `openspec/specs/<capability>/spec.md` files. Let specs emerge from real changes; empty stubs fail validation and force artificial `ADDED Requirements` deltas.

## Working inside an OpenSpec project

- Prefer placing new requirements under an existing capability from the map. Justify in the proposal when creating a new capability.
- Scenarios use `#### Scenario:` (exactly four hashtags) with `WHEN`/`THEN` lines. Three hashtags fail silently.
- Use `SHALL` / `MUST` for normative requirements. Avoid `should` / `may`.
- When a change touches an external integration, pair the wrapper task with a matching `.http` request file under `docs/http/` if the project uses that pattern.
- When spec implemented, suggest a commit message.

## Precedent is not a waiver for the OpenSpec cycle

A behavior or contract change goes through `/opsx:propose`, and that INCLUDES a
bugfix that tightens the contract (turning a previously-succeeding request into a
rejection, or fixing a 500 into a new 422 while also newly requiring a field). The
absence of an existing spec line for the area is not an exemption; the cycle is what
creates the spec home. Only genuinely mechanical work (typo, dependency bump,
contract-neutral rename) is exempt.

A prior commit that shipped a similar change WITHOUT running the cycle is
descriptive of past practice, not a waiver. Do NOT cite it as precedent to skip the
cycle again. When genuinely unsure whether a change is mechanical or a contract
change, put propose-vs-direct to the user as an explicit choice rather than resolving
it to "skip" yourself.

## OpenSpec phases are user-gated

The `/opsx:*` and `/openspec-*` commands are discrete, user-invoked checkpoints, not a single pipeline to run end to end. After completing one phase, STOP and wait for the user to invoke the next.

- **Starting implementation must be initiated by the user.** Unless the user has explicitly mandated otherwise, do not begin writing or editing implementation code until the user explicitly invokes `/opsx:apply` (or otherwise clearly tells you to start implementing). Generating proposal artifacts is never, by itself, permission to implement them.
- After `/opsx:propose` completes, hand control back to the user (the propose flow itself ends by telling the user to run `/opsx:apply`). Do NOT self-invoke `/opsx:apply` or `/opsx:archive`, and do NOT start coding, on your own initiative.
- "Use the OpenSpec flow" (and equivalents like "follow the openspec process", "do this via openspec") means follow the gated workflow **including its stops**. It is NOT authorization to run `propose → apply → archive` autonomously in one turn.
- The only ways past a gate are: the user explicitly invokes that phase's command, or the user explicitly mandates autonomous continuation in the same instruction (e.g. "propose then apply without stopping"). Inferring "they probably want me to continue" from context is a violation.

### Why

Each gate is a review point the user relies on. The propose→apply gate lets them adjust scope, capability placement, and design before any code is written; the apply→archive gate lets them verify the implementation before it is folded into the specs. Self-advancing past a gate skips that review and can bake the wrong scope, or an unwanted change, into both the codebase and the permanent spec history.

## Warn before merging an MR while its change is unarchived

Merging (or arming merge-when-pipeline-succeeds / auto-merge on) an MR that implements an OpenSpec change WITHOUT first archiving that change is a process defect. `openspec/specs/<capability>/spec.md` is only updated when the change is archived, so a merge-without-archive lands the implementation on the target branch while the spec deltas stay stranded in `openspec/changes/<name>/`. The canonical specs then silently fall behind the merged code, and the change lingers as "active" on the trunk.

Before merging an MR (or arming auto-merge) that corresponds to an OpenSpec change, verify the change has been archived: its directory has moved to `openspec/changes/archive/<date>-<name>/` and its spec deltas are folded into `openspec/specs/`. If the change is still active in `openspec/changes/`, STOP and warn the user before proceeding, recommending that `/opsx:archive` run and the archive be committed into the MR first, so the merged branch's specs match its code. The user MAY waive this and merge anyway (for example when archiving is deliberately deferred to a follow-up), but the warning is mandatory whenever the gap exists — do not merge silently.

## /opsx:propose and /openspec-propose: always interview first

When the user invokes `/opsx:propose` or `/openspec-propose`, you MUST run a clarification interview before generating any proposal artifacts (proposal.md, design.md, tasks.md, specs/). No exceptions. "The request seems clear" is not a valid reason to skip; clarity is what the interview proves, not what you assume.

### Protocol

1. Pause before touching any files.
2. Ask the user clarifying questions. Where a question maps to a small set of discrete options, present them as a multiple-choice list so the user can pick rather than write open prose. Group related questions into a single round of roughly 4 at a time to minimize back and forth; append genuinely open-ended questions as plain prose alongside the multiple-choice block.
3. Cover, at minimum, all four of these dimensions:
   - **Scope**: what is explicitly in, what is explicitly out.
   - **Capability placement**: which existing capability from the project's capability map owns the new requirements, or a justification for adding a new capability.
   - **Acceptance criteria**: what observable behavior or test outcome proves the change is complete.
   - **Constraints and non-functionals**: performance budgets, backward-compatibility requirements, security implications, migration concerns.
4. After the user answers, proceed with proposal artifact generation. If the answers reveal new ambiguity, run a follow-up round using the same multiple-choice-where-possible discipline.
5. The only way to bypass this rule is for the user to explicitly say "skip the interview" in the same message that invokes propose. Inferring "the user probably wants me to skip" from context is a violation.

### Why

`/opsx:propose` generates multiple coupled artifacts in one step. Drafting them on incomplete or assumed requirements produces a proposal that looks finished but encodes the wrong scope, lands in the wrong capability, or lacks acceptance criteria. Catching these in the interview takes minutes; catching them after the fact requires unwinding the proposal and any implementation that followed.

## After /opsx:propose completes: show the tasks list

When `/opsx:propose` or `/openspec-propose` finishes generating the artifacts and the change validates, always display the generated `tasks.md` (the numbered, checkbox implementation steps) to the user before handing control back at the propose to apply gate. Show the steps verbatim or near verbatim, not merely a task count or a one line summary.

### Why

The propose to apply gate is a review point. The tasks list is the most concrete preview of what `/opsx:apply` will actually do, so surfacing it lets the user catch a mis-scoped or mis-ordered step before any code is written, without having to open the file themselves.