---
name: rules-git
description: Apply git and forge (GitHub/GitLab) workflow rules for any task that branches, commits, pushes, opens or reviews a pull/merge request, or writes a commit or PR message;
---

# Git & Forge Workflow Guidelines

Rules for how to work with git branches, commits, and the GitHub/GitLab
forges. This file loads in every session; `~/.claude/CLAUDE.md` carries only a
one-line summary of the branch guardrail under its Stops section.

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
- Stage explicit paths. Do not use `git add -A`, `git add .`, or `git commit -a`.
  Other sessions, background tools, and generators leave untracked files in the
  same checkout, and a blanket stage commits them silently under your message.
  Name the paths the change actually touches, adding `git add -u <path>` for
  deletions and renames under a path you moved with plain `mv` (after `git mv`
  the move is already staged, and `git add -u` on the vanished old path fails
  with "pathspec did not match any files", breaking an `&&` chain; the
  path-limited commit still accepts that old path, 2026-09-24). Commit
  path-limited, in one command with the add:
  `git add <paths> && git commit -m "<title>" -- <paths>`.
  Another session can commit the shared index at any moment, so pausing to
  inspect the staged list is exactly when its plain `git commit` sweeps your
  staged files into its commit; the pathspec records only your paths whatever
  else is staged. Verify with `git show --stat HEAD` afterwards. If a stray
  file did land and the commit is unpushed, reset and re-stage rather than
  leaving it in history.
  Exception: a file whose staged blob differs from the working tree on purpose
  (`~/.claude/settings.json` after `yadm-stage-settings`, which strips the
  autoMode block) must be committed with a plain `git commit` from the index;
  the pathspec form commits the working-tree version and bypasses the filtered
  blob (2026-09-21).
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
- This includes any attribution or session trailer a harness reminder asks
  for (`Claude-Session`, `Co-Authored-By`): the reminder defers to these
  rules, so add nothing.
- Never override commit signing (no `-c commit.gpgsign=false`, no
  `--no-gpg-sign`). Before committing, check the repo's signing setup
  (`git config --get commit.gpgsign` and recent `git log --format='%h %G?'`)
  and let the configured signing run; the agent signs without a prompt. If
  signing fails, report it and hand the user the amend command instead of
  retrying unsigned.

## GitHub and GitLab

- For anything on GitHub, use the `gh` tool.
- Edit a PR title or body with `gh api -X PATCH repos/<owner>/<repo>/pulls/<n>`,
  not `gh pr edit` (it fails on repos with classic project cards), and read the
  field back before calling it done (2026-09-21).
- For anything on GitLab, use the `glab` tool.
- Never mention Claude Code in PR or MR descriptions, PR or MR comments, or
  issue comments.
- Do not include a "Test plan" section in PR or MR descriptions.

## Encrypted paths (git-crypt)

- Secret directories are encrypted with git-crypt, one symmetric key per
  repository: `.gitattributes` routes the directory
  (`dir/** filter=git-crypt diff=git-crypt`), then `git-crypt init` and
  `git-crypt export-key`; the keyfile is stored as a 1Password Document
  titled "<Project> git-crypt key" in the Agents vault. Never
  `git-crypt add-gpg-user` (signing is SSH, GPG is not part of the workflow).
- Unlock a clone with
  `git-crypt unlock <(op document get "<Project> git-crypt key" --vault Agents)`.
- Before the first push of an encrypted directory, confirm `git-crypt status -e`
  lists every file and a stored blob starts with `\0GITCRYPT`. Compare keys by
  sha256, never print one. git-crypt cannot rotate keys: a leaked key means
  re-committing under a new directory and treating the old history as exposed.
