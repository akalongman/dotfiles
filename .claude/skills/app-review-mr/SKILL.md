---
name: app-review-mr
description: Use when asked to review one or more GitLab merge requests or GitHub pull requests (numbers, `!123`/`#123`, or URLs, possibly several at once), to check whether open review threads are already fixed, to resolve fixed threads, or to post review findings back as inline discussions.
user-invocable: true
---

# Reviewing merge requests

Review every requested MR/PR from a full read of the changed files at the MR head (never only the diff), one subagent per MR in parallel, each in its own throwaway detached worktree. The main session alone touches the forge for anything outward (replies, resolving, posting), and only when a flag or an explicit yes allows it.

## Input

`$ARGUMENTS` is a whitespace- or comma-separated list of MR/PR references plus optional flags:

| Token | Meaning |
|---|---|
| `123`, `!123`, `#123` | MR/PR number in the repo of `git remote get-url origin` |
| `https://gitlab.com/<ns>/<repo>/-/merge_requests/<iid>` | GitLab MR, repo from the URL |
| `https://github.com/<owner>/<repo>/pull/<n>` | GitHub PR, repo from the URL |
| `--resolve` | After the review, resolve every open thread judged FIXED (reply with evidence first) |
| `--post` | After the review, post new findings as inline discussions |

Without a flag, nothing outward happens until the user answers the closing question (a numbered list, so they can reply "1. yes 2. no"). A flag is that answer given in advance.

## Workflow

0. **Check the session is fresh.** A fork copies the whole conversation per MR. If this conversation already holds work beyond this skill's invocation (an earlier task, a planning discussion, another review), stop before fetching anything and say: "Each review fork would copy this session's context; run `/clear` and then `/app-review-mr <same arguments>`." Continue in the current session only when the user answers that they accept the cost.
1. **Resolve references.** For each token build `{platform, repo, iid}`. Dedupe. Mixed repos are fine.
2. **Fetch metadata per MR** (main session, serially): title, source branch, head SHA, `diff_refs` (GitLab), the changed-file list, and **every previous review**: MR-level notes (bot rounds included), GitHub review bodies, and every discussion thread, resolved or open, **with pagination** (`--paginate`; unpaginated reads stop at 20 and hide threads). Keep system notes out. GitLab: `bash <skill dir>/scripts/fetch-gitlab-mr.sh <encoded ns/repo> <scratch>/mr <iid>...` does all of it and writes `<iid>.reviews.txt`, the digest the brief points at. GitHub: the recipes in `api-recipes.md`, by hand.
3. **Make one detached worktree per MR** under the scratchpad (else `mktemp -d`), from the forge's own head ref so fork MRs work and the user's working tree is never touched:
   ```bash
   git worktree prune
   git fetch origin refs/merge-requests/<iid>/head    # GitHub: refs/pull/<n>/head
   git worktree add --detach "<scratch>/review-mr/<iid>" FETCH_HEAD
   git -C "<scratch>/review-mr/<iid>" rev-parse HEAD   # must equal the API head SHA, else stop
   ```
   Never `git checkout`, never `git stash`, never create a branch.
4. **Dispatch one subagent per MR with `subagent_type: "fork"`**, at most 4 at a time, all in one message, no `model` and no `effort` argument: a fork is the only agent type that runs on the main session's model at the main session's effort (`general-purpose` keeps the model but runs at its own effort). A fork carries the session context, so invoke this skill early in a session, not after a long one. The prompt is `review-brief.md` with the placeholders filled: worktree path, head SHA, changed files, every previous review (MR-level notes, review bodies, resolved and open threads with id, author, path:line, body, replies), and the base-branch diff command. Subagents read; they never post, resolve, check out, run tests or install dependencies. They return the report as text.
5. **Remove the worktrees** once every report is in: `git worktree remove --force <dir>`.
6. **Present** one report per MR, in request order, each with: thread verdicts (FIXED / NOT FIXED / DISPUTED / UNCLEAR, with the evidence line), already flagged (what an earlier review raised and still stands, acknowledged, not repeated), new findings (`path:line`, problem, fix), positives. A finding that restates a previous review goes under that review's entry, not under findings.
7. **Close with the numbered question** unless the flags already answered it:
   1. Resolve the N FIXED threads on !A, !B (reply with the fixing SHA, then resolve)?
   2. Post the M new findings inline on !A, !B?
8. **Act, then verify every call** per `api-recipes.md`: a reply note that landed, `resolved: true` on the discussion (GitLab) or `isResolved` (GitHub), a non-null `position` on each posted discussion. Stop at the first failed verification and report it; do not loop through a broken batch.

## Thread verdicts

A thread is judged on the file at the MR head, not on the diff and not on the author's reply:

| Verdict | Evidence required |
|---|---|
| FIXED | The change the thread asked for is present at the named location, or the code it objected to is gone; cite `path:line` at head |
| FIXED, DO NOT RESOLVE | The requested change is present, but a finding shows the thread's concern still stands; resolving it would hide the defect |
| NOT FIXED | The objected code is still there; cite it |
| DISPUTED | The author's last reply declines or argues; leave it to humans |
| UNCLEAR | The thread is a question, a style preference, or anchors to a line that no longer exists |

Only plain FIXED threads are ever resolved. Threads already `resolved` are listed in one line and skipped. A finding marked `(unchanged file)` cannot anchor inline and goes into the MR-level summary note.

## Common mistakes

- Reading discussions without `--paginate` and concluding "no open threads".
- Judging a thread fixed because the author replied "done"; read the file.
- Posting a finding that an open thread already raises.
- Checking out the branch in the user's working tree (an earlier version of this skill did; it broke every parallel review and used a shared `git stash`).
- Sending an API body through `$VAR` or a heredoc: write the JSON to a file under `$(git rev-parse --git-common-dir)/app-review-mr/` and pass `--input <file>`. Not `/tmp` and not `~/.cache` or any other hidden top-level home directory: the snap-packaged `glab` cannot read them.
- Running the post batch without a per-call check that stops on the first failure; a stop before the first request is what made the wrong body directory harmless.
- Dispatching forks from a long session because the user said "now"; the check in step 0 is the answer to "now".
