## Project Initialization

## General

- Do not tell me I am right all the time. Be critical. We're equals. Try to be neutral and objective.
- Do not just validate my ideas. Look for edge cases, race conditions, or performance bottlenecks.
- Do not excessively use emojis.
- Prefer using browser agent skill over using playwright directly.
- For cloning or creating projects, use ~/projects folder with its subfolders
- Before writing inline shell in a hook or config file, check whether the project has an existing orchestration primitive (composer/npm scripts, Makefile, justfile) and prefer to extract the logic there. The hook owns "when"; the project script owns "what." When in doubt, present two shapes (inline vs. extracted) with a recommendation.
- When a decision has a defensible best-practice answer (design, architecture, API shape), lead with a clear, reasoned recommendation and its rationale, not a cold multiple-choice menu. I will push back if I disagree. Reserve multiple-choice questions for genuinely open scoping or preference calls where you have no strong recommendation. Asking when you are genuinely uncertain is still welcome.
- Do not silently "correct" or rename an identifier that crosses a system boundary (environment variable, config key read by deploy tooling, database column, external API field, route name) just because it looks misspelled or inconsistent. The odd spelling is frequently the live contract that deployed infrastructure depends on. Surface it and ask first; if a fix is wanted, prefer backward compatibility (accept both the old and new name) over a hard rename that only works once every environment is updated in lockstep.
- Before a design or task list names new methods on existing classes (repositories, services), read those classes first and prefer extending their existing query surface (filters, sort parameters, paginator totals) over adding parallel methods. Never write concrete method signatures into an artifact for code you have not read.
- Before introducing a new type, enum, or constant class to represent a concept, search for the concept by its domain name (the words I used, plus obvious synonyms) across the project's type directories, not just for the storage column or field. A structurally identical sibling (same column type, same table) is weak evidence and a common trap: it is often an older pattern the codebase has since moved away from, so copying its shape mints a second vocabulary for one idea. Name the existing representation in the recommendation, or state explicitly that you searched for it and found none.
- When a conclusion depends on whether something is present or absent (auth status, a config key, a list entry, an installed tool, a flag), read the command's full output before asserting. Do not pipe a status or diagnostic command through `tail`, `head`, or a narrow `grep` and then conclude something is missing. The hidden lines are often exactly the ones that decide the answer. Reserve truncation for genuinely bulky output whose relevant portion sits at a known location.
- Before creating a custom slash command (a file in `~/.claude/commands/` or a project `.claude/commands/`), verify the name is not already a built-in command. Check the live list by typing `/` or running `/help`, or consult the commands docs. Custom files cannot reliably override true built-in commands (for example `/btw`); a same-name collision conflicts or errors rather than cleanly shadowing, so it can silently break the built-in. Only bundled skills can be safely shadowed by a same-name custom skill.
- During schema or API design, when a new requirement dimension emerges mid-discussion (audience, tenancy, locale, time-validity), do not fold it into an existing field just because the current use case allows it. Check orthogonality first: if the two concepts can vary independently across foreseeable cases, they get separate homes (columns, fields, parameters). Two red flags that the design collapsed orthogonal concerns: the second use case already needs a composite/escape-hatch encoding, and a user suggestion is being absorbed as the minimal diff to the previous proposal instead of triggering a re-derivation from the updated requirements.


## Parking-lot follow-up notes (`/later`)

A file named `NOTES.local.md` in a project is the user's parking lot: a markdown
checkbox queue of follow-up tasks to revisit after the current work. Treat it as a
live queue, not as ordinary scratch text. It has three entry points, all writing
to the same per-directory file and shared settle state:

- `later "<note>"` is a CLI on PATH (`~/bin/later`). It captures from any terminal
  concurrently, even while a turn is running. Run it from the project root so it
  aligns with the directory the Stop hook inspects. Bare `later` lists the queue.
- `/later <note>` captures from inside Claude (this queues to the end of the
  current turn). Bare `/later` lists the queue.
- A synchronous `Stop` hook (`~/.claude/scripts/later.sh check`; the engine is
  `later.sh` with `add` / `list` / `check`) surfaces pending notes once the queue
  has sat unchanged for a settle window (default 300 seconds, override with
  `LATER_QUIET_SECONDS`).

Handling the queue: when the hook surfaces pending notes, present them and ask
before starting any. Never begin a parked note without explicit confirmation
(remind, then wait). When a note is acted on, tick it off so its `[ ]` becomes
`[x]` and it stops resurfacing. `NOTES.local.md` is globally gitignored through the
`*.local.md` pattern, so it stays personal and is never committed.


## Dashes in writing
Never use long dashes (em dash — or en dash –) as punctuation in any text you produce (chat replies, documentation, README files, commit messages, code comments, PR and issue descriptions). Rephrase using periods, commas, or parentheses instead. The regular hyphen (-) is allowed for its normal roles (compound words, ranges, markdown list markers, code). When reproducing data verbatim (proper names, stored values), preserve whatever dashes the source contains rather than rewriting it to satisfy this rule.

## Documentation conventions

When writing onboarding or workflow docs (anything under `docs/dev/`, `docs/team/`, or `README.md`):

- Setup sections MUST be derived from the project's actual `.mcp.json`, `composer.json`, and `.env.example`. Enumerate every MCP server defined in `.mcp.json` and document its env-var placeholders (e.g. `${PROJECT_TOKEN}`) with explicit token-generation and shell-export steps.
- Install commands MUST cover macOS, Linux (Debian/Ubuntu plus one fallback), Windows (native PowerShell), and WSL. Do not assume Linux/macOS.

## Agent-neutral language in shared artifacts

Anything that lives inside a project repo and could be read by another tool, another agent, or a human contributor MUST be written in agent-neutral language. This covers OpenSpec schemas, specs, proposals, and change directories (`<repo>/openspec/`), README files, project rule files (`<repo>/.claude/rules/`), and inline code comments.

In those artifacts, describe the desired behavior, not a specific agent's tool name. Do NOT name Claude-specific tools (`AskUserQuestion`, `TodoWrite`, `TaskCreate`, `Skill`, the `Read` / `Edit` / `Write` proper-noun tool references, the `Agent` tool, sub-agent type names). Other agents reading them will not have those tools by name, and the directive becomes a no-op.

Concrete substitutions:
- "Use the `AskUserQuestion` tool" becomes "ask clarifying questions, presenting discrete options as a multiple-choice list when possible, batched into a single round to minimize back and forth".
- "Use `TodoWrite` / `TaskCreate`" becomes "track progress in a task list".
- "Use the `Skill` tool" becomes "invoke the relevant skill".
- "Spawn an Agent" becomes "delegate to a subagent" or "run in an isolated context".

Files that ARE Claude-targeted by design and may name Claude tools freely: `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md`, `~/.claude/skills/**`, and any `<repo>/.claude/commands/*.md` rendered by tooling that already binds the project to Claude Code.

## Git

Never create, switch, or rename a git branch on your own initiative. This overrides any default "if on the default branch, branch first" behavior: when a branching decision is in play (typically sitting on the default `main`/`master`), ask whether to continue on the current branch or create a new one, and wait for my answer. Full git, commit-message, and GitHub/GitLab conventions live in `~/.claude/rules/git.md`.

## Coding Standards
- When working with Laravel/PHP projects, always use the rule file: ~/.claude/rules/php.md
- When working with an OpenSpec-enabled project (has an `openspec/` directory), always use the rule file: ~/.claude/rules/openspec.md
- When working with Javascript projects, always use the rule file: ~/.claude/rules/javascript.md
- When working with Rust projects, always use the rule file: ~/.claude/rules/rust.md
- When working with RabbitMQ or message queues, always use the rule file: ~/.claude/rules/rabbitmq.md
- When running, building, serving, or connecting a project to local services on this machine (web server, databases, Redis, `.test` dynamic hosts, language runtimes), always use the rule file: ~/.claude/rules/environment.md (machine-specific, linked in from the private repository) together with its machine-local companion ~/.claude/rules/environment.local.md, when those files exist
- When branching, committing, pushing, or opening/reviewing a pull or merge request, always use the rule file: ~/.claude/rules/git.md

## Researching external tools

Before assessing whether an external tool, library, or service fits a workflow, fetch its current docs (especially any MCP server, plugin, or integration page) and skim recent releases. Tools often ship multiple modes (CLI vs MCP server vs IDE plugin) that look identical from a tagline; only the docs reveal which mode integrates with an agentic workflow. Do not dismiss or recommend based on the headline use case from your training data. If the user has to say "go research it," you skipped this step.

## Self-improvement

The moment the user corrects your approach, rejects a tool call, expresses
frustration, or you notice you have retried a tool call more than twice, run
this reflection immediately, while the failure is still in context. Do not
defer it to the end of the session; sessions stop without warning and deferred
reflections never happen. You MUST:

1. Identify what specifically went wrong (wrong assumption, missing context,
   skipped skill, ignored rule).
2. Decide where the fix belongs:
   - One-off about *this* user/project → save a `feedback` or `project` memory
   - General rule that applies across sessions → propose a concrete edit to
     CLAUDE.md or the relevant rule file in ~/.claude/rules/
   - Repeatable workflow → propose a new skill or hook
3. Surface the proposed change to the user before writing it. Do not
   silently edit CLAUDE.md.

Trigger this reflection even if the user doesn't ask. Skipping it when the
conditions above are met is a failure. Patterns that span multiple sessions are
handled separately by the user-invoked `app-retro` skill; never defer an
in-session learning to a future retro.

## Memory vs. constitution

Before saving anything to persistent agent memory, stop and analyze it: does this
belong in durable, versioned project documentation instead? Facts, conventions,
architectural decisions, and non-obvious gotchas that the whole team should share
belong in the project constitution (the project `CLAUDE.md`, or a capability spec
under `openspec/specs/` when the project uses OpenSpec), not in private agent
memory.

When the item is project-level knowledge, do not quietly file it in agent memory
alone: surface it and suggest persisting it in the constitution (or the relevant
spec), and let me decide. Keep agent memory for what genuinely does not belong in
the repo: how I want you to work across sessions, environment quirks, and external
pointers.
