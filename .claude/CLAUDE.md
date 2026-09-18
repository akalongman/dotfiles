## Working agreements

- Be critical, not validating. We are equals: look for edge cases, race conditions, and performance bottlenecks instead of agreeing with my ideas.
- For browser tasks prefer the `agent-browser` skill (or `claude-in-chrome`) over driving Playwright directly.
- For cloning or creating projects, use the matching `~/projects/<type>` subfolder (layout in `rules/environment.md`).
- Before writing inline shell in a hook or config file, check for an existing orchestration primitive (composer or npm scripts, Makefile, justfile) and put the logic there. The hook owns "when"; the project script owns "what". When in doubt, show the inline and extracted shapes with a recommendation.
- When a decision has a defensible best-practice answer (design, architecture, API shape), lead with a reasoned recommendation and its rationale, not a multiple-choice menu. Reserve multiple choice for genuinely open scoping or preference calls. Asking when genuinely uncertain is welcome.
- Do not silently rename an identifier that crosses a system boundary (environment variable, config key, database column, external API field, route name) because it looks misspelled. It is often the live contract. Surface it and ask; if a fix is wanted, prefer accepting both names over a hard rename.
- Before a design or task list names new methods on existing classes, read those classes and prefer extending their existing query surface. Never write concrete method signatures for code you have not read.
- Before introducing a new type, enum, or constant class for a concept, search for the concept by its domain name and synonyms across the type directories, not only for the storage column. A structurally identical sibling is weak evidence and often an abandoned pattern. Name the existing representation, or state that you searched and found none.
- Before recommending an action that rests on a factual claim from project docs (where data lives, which host owns what), verify it on the live system when a read-only check is cheap. Docs drift silently from the deployment (2026-09-11, LMS upload directories had moved to S3).
- When a conclusion depends on whether something is present or absent, read the command's full output. Do not pipe a status command through `tail`, `head`, or a narrow `grep` and then conclude something is missing; the hidden lines decide the answer.
- A query scoped to specific paths (`git ls-files <paths>`, `ls <dir>`) proves nothing about paths outside its arguments. Before asserting something is untracked or absent, run the query that would show it.
- Do not conclude a line is new from `grep '^+'` on a diff; whitespace changes re-emit unchanged lines as `-`/`+` pairs. Read the full hunk with context and check which enclosing block the change lands in.
- A failed auth or connectivity check proves only the credential source it exercised. Before saying a tool "does not work", enumerate the other sources it resolves (env vars, profiles, endpoint overrides, project config) and state which one failed (2026-09-12, AWS CLI called dead while env vars against Garage worked).
- Before creating a custom slash command, check `/help` for a built-in of the same name. Custom files cannot shadow true built-ins (`/btw` collided); only bundled skills can be shadowed by a same-name custom skill.
- Before starting any implementation step, check the `app-*` skills for one that covers it and invoke that first. This applies however the step was reached: a plugin hand-off (brainstorming to writing-plans to subagent-driven-development), `/opsx:apply`, or the word "apply" in my message. An apply-ready OpenSpec change, a plan file, or a spec goes through `app-subagent-apply` unless I say "in session" or "no subagents" in the same message. A custom skill wraps the plugin one, never the reverse.
- During schema or API design, when a new requirement dimension emerges mid-discussion (audience, tenancy, locale, time-validity), check orthogonality before folding it into an existing field. If the two concepts can vary independently, they get separate homes. Red flags: the second use case already needs a composite encoding, or a suggestion is absorbed as the minimal diff instead of re-deriving from the updated requirements.
- When recommending between design variants, weight simplicity and the codebase's existing idioms above expressiveness. Before adding a new axis, check whether an existing per-request context object can absorb it. Buy expressiveness only for a named present-day use case.
- Before writing a Dockerfile layer that installs packages on a third-party image, confirm the package manager exists in the pinned image; the check is in `rules/docker.md`.
- Before assessing whether an external tool, library, or service fits a workflow, fetch its current docs (especially MCP, plugin, or integration pages) and skim recent releases. Tools ship several modes that look identical from a tagline. If I have to say "go research it", you skipped this step.
- Prefer the latest LTS release of any software we run or depend on (operating systems, runtimes, databases, frameworks), and move to a new LTS deliberately when it ships rather than staying on the previous one until forced (2026-09-16, Ubuntu 24.04's OpenSSL could not offer post-quantum key exchange).
- Make every change reproducible and definition-first: Terraform for cloud resources, cloud-init or Ansible for server configuration, importable or exportable definitions (JSON container exports, API scripts, declarative config) for SaaS settings, instead of hand edits in consoles or over SSH. When a hand edit is unavoidable, mirror it into the definition the same day and say so.

## Stops

- Never create, switch, or rename a git branch on your own initiative. When a branching decision is in play (typically on `main`/`master`), ask whether to continue on the current branch or create one, and wait. Full conventions in `rules/git.md`.
- Never start a parked note from `NOTES.local.md` without explicit confirmation.
- Never edit this file, a rule file, or a skill silently; propose the change first.

## Style

- Do not use emojis excessively.
- Never use em or en dashes as punctuation in any text you produce (replies, docs, commit messages, comments, PR descriptions). Rephrase with periods, commas, or parentheses. The hyphen keeps its normal roles. Preserve dashes when reproducing data verbatim.
- Name temporary or working documents (reports, plans, drafts, scratch artifacts) `YYYY-MM-DD-HHMM-<name>.<ext>` in 24-hour local time, so they sort chronologically and versions do not overwrite. Not for source code, permanent docs, or tooling-dictated names.
- Prefer a numbered list over bullets when I have to choose or answer (questions, options, changes awaiting a yes), so I can reply by number ("1. yes 2. b"). Plain bullets or prose for everything else. Repo documents follow `rules/shared-artifacts.md`, not this line.
- Prose that lives inside a project repo is agent-neutral; see `rules/shared-artifacts.md`.

## Index

| Topic | Where | Loads when |
|---|---|---|
| This machine: `.test` sites, data stores, runtimes, shell gotchas | `rules/environment.md`, `rules/environment.local.md` | always |
| Git branches, commits, GitHub and GitLab | `rules/git.md` | always |
| PHP and Laravel | `rules/php.md` | PHP files |
| JavaScript | `rules/javascript.md` | JS files |
| Rust | `rules/rust.md` | Rust files |
| OpenSpec projects | `rules/openspec.md` | `openspec/` files |
| Test runs and regression tests | `rules/testing.md` | test files and configs |
| Dockerfiles and compose | `rules/docker.md` | container files |
| In-repo prose: README, docs, specs, rule files, comments | `rules/shared-artifacts.md` | those files |
| Parking-lot notes | `commands/later.md`, `scripts/later.sh` | `/later` |

## Workflows

- **Parking lot.** `NOTES.local.md` in a project is a checkbox queue of follow-ups, captured with `later "<note>"` from any terminal or `/later <note>` in a session; bare `later` lists it. A Stop hook surfaces pending notes once the queue has been quiet for a settle window. Present them and ask; tick a note to `[x]` when it is done. Engine: `~/.claude/scripts/later.sh`. Globally gitignored through `*.local.md`.
- **Self-improvement.** The moment I correct your approach, reject a tool call, express frustration, or you retry a tool call more than twice, reflect immediately, not at session end: (1) name what went wrong; (2) decide where the fix belongs: a `feedback` or `project` memory for a one-off user or project fact, the matching path-scoped rule file when the rule names a language, file type, or tool, this file only for a cross-cutting agreement, a skill or hook for a repeatable workflow; (3) surface the proposed change before writing it. Keep the incident as a date plus a few words, never a paragraph. Patterns across sessions belong to the user-invoked `app-retro` skill; never defer an in-session learning to it.
- **Memory versus constitution.** Before saving to agent memory, ask whether the fact belongs in durable project documentation instead. Conventions, architectural decisions, and gotchas the whole team should share go in the project constitution or, on OpenSpec projects, a capability spec; surface that and let me decide. Keep agent memory for how I want you to work across sessions, environment quirks, and external pointers.
