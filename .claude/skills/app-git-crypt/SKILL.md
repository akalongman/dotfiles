---
name: app-git-crypt
description: Use when a repository encrypts a directory with git-crypt or should start to - setting up the filter and key, storing or fetching the keyfile in 1Password, unlocking a clone, checking an encrypted path before its first push, or handling a leaked key. Triggers include "git-crypt", "encrypted directory", "unlock the repo", "<Project> git-crypt key".
---

# git-crypt encrypted paths

One symmetric key per repository, no GPG users. The convention is the same
in every repo that carries secrets (the list of repos and their encrypted
directories is in agent memory `git-crypt-convention`).

## Setup

- `.gitattributes` routes the directory:
  `dir/** filter=git-crypt diff=git-crypt`, then `git-crypt init` and
  `git-crypt export-key <file>`.
- Store the keyfile as a 1Password Document titled "<Project> git-crypt key"
  in the Agents vault, then delete the local export.
- Never `git-crypt add-gpg-user`: signing is SSH, GPG is not part of the
  workflow.

## Unlock a clone

```bash
git-crypt unlock <(op document get "<Project> git-crypt key" --vault Agents)
```

## Before the first push of an encrypted directory

- Confirm `git-crypt status -e` lists every file under the directory.
- Confirm a stored blob starts with `\0GITCRYPT`
  (`git show HEAD:<path> | head -c 9 | od -c`).
- Compare keys by sha256, never print one.

## Leaked key

git-crypt cannot rotate keys. A leaked key means re-committing the secrets
under a new directory with a new key and treating the old history as exposed.
