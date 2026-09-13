---
name: rules-shared-artifacts
description: Apply when writing prose that lives inside a project repository and may be read by other tools, agents, or people: README files, docs, OpenSpec artifacts, project rule files, and code comments.
paths:
  - "**/README.md"
  - "**/README"
  - "**/docs/**"
  - "**/openspec/**"
  - "**/.claude/rules/**"
  - "**/CLAUDE.md"
  - "**/AGENTS.md"
---

# Shared Artifacts

Prose that lives inside a project repo is read by other tools, other agents,
and human contributors. It must not assume Claude Code.

## Agent-neutral language

Describe the desired behavior, not a specific agent's tool name. Do not name
Claude-specific tools (`AskUserQuestion`, `TodoWrite`, `TaskCreate`, `Skill`,
the `Read` / `Edit` / `Write` proper-noun tool references, the `Agent` tool,
sub-agent type names). Other agents reading the file will not have those tools
by name, and the directive becomes a no-op.

Concrete substitutions:

- "Use the `AskUserQuestion` tool" becomes "ask clarifying questions,
  presenting discrete options as a multiple-choice list when possible, batched
  into a single round to minimize back and forth".
- "Use `TodoWrite` / `TaskCreate`" becomes "track progress in a task list".
- "Use the `Skill` tool" becomes "invoke the relevant skill".
- "Spawn an Agent" becomes "delegate to a subagent" or "run in an isolated
  context".

Files that are Claude-targeted by design and may name Claude tools freely:
`~/.claude/CLAUDE.md`, `~/.claude/rules/*.md`, `~/.claude/skills/**`, and any
`<repo>/.claude/commands/*.md` rendered by tooling that already binds the
project to Claude Code.

## Onboarding and workflow docs

For anything under `docs/dev/`, `docs/team/`, or `README.md`:

- Setup sections must be derived from the project's actual `.mcp.json`,
  `composer.json`, and `.env.example`. Enumerate every MCP server defined in
  `.mcp.json` and document its env-var placeholders (for example
  `${PROJECT_TOKEN}`) with explicit token-generation and shell-export steps.
- Install commands must cover macOS, Linux (Debian/Ubuntu plus one fallback),
  Windows (native PowerShell), and WSL. Do not assume Linux/macOS.
