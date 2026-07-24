---
name: rules-git
description: Apply git and forge (GitHub/GitLab) workflow rules for any task that branches, commits, pushes, opens or reviews a pull/merge request, or writes a commit or PR message;
---

# Git & Forge Workflow Guidelines

Rules for how to work with git branches, commits, and the GitHub/GitLab
forges. The single non-negotiable branch guardrail also lives inline in
`~/.claude/CLAUDE.md` so it stays in context even when this file has not been
loaded; the rest of the detail lives here.

## When to Activate

Use this file when:

- Creating, switching, renaming, or deleting a git branch.
- Committing or pushing, or being asked for a commit message.
- Opening, updating, or reviewing a pull request or merge request.
- Writing any PR, MR, issue, or commit description.

## Scope

- In scope: branch workflow, commit conventions, commit-message style, and
  GitHub/GitLab tooling and PR conventions.
- Out of scope: language-specific coding standards (see the matching rule file)
  and spec-workflow gates (see `openspec.md`).

## Branches

Never create, switch, or rename a git branch on your own initiative. This
overrides any default "commit or push only when the user asks; if on the default
branch, branch first" behavior.

- When you are about to commit or push and a branching decision is in play
  (typically when the current branch is the default `main`/`master`), ask
  whether to continue on the current branch or create a new one, and wait for
  the answer instead of deciding.
- Once the user has answered for the current piece of work, act on that choice
  and do not re-ask on every subsequent commit.
- Branch creation, switching, and renaming are actions the user initiates. Do
  not perform them silently to "protect" the user.

## Commits

- Commit or push only when the user asks.
- Before pushing, inspect what the push will publish (`git log @{u}..` or
  `git log origin/<branch>..HEAD`) and surface any commits beyond the one you
  intended. A push publishes the whole branch, so commits that were already
  local-ahead ride along.
- When the user is about to commit code, has finished a spec implementation, or
  asks for a commit message, suggest exactly one option, no alternatives.
- Use a short imperative title under 72 characters.
- Add a body only if the change is non-obvious from the title. Keep body lines
  under 72 characters and use plain prose, not section headers.
- Do not include `Co-Authored-By` trailers.
- Do not mention Claude Code or AI assistants.

## GitHub and GitLab

- For anything on GitHub, use the `gh` tool.
- For anything on GitLab, use the `glab` tool.
- Never mention Claude Code in PR or MR descriptions, PR or MR comments, or
  issue comments.
- Do not include a "Test plan" section in PR or MR descriptions.
