# Forge API recipes for app-review-mr

Every write sends its body from a JSON file under `$(git rev-parse --git-common-dir)/app-review-mr/<repo>-<iid>/` (never tracked, present in every checkout and worktree) with `--input <file>` and `Content-Type: application/json`. Not `/tmp` and not a hidden top-level home directory such as `~/.cache` (the snap-packaged `glab` can read neither; it fails with "permission denied" before any request), not `-f key[sub]=v` (`glab` percent-encodes the brackets and GitLab silently drops the nested `position`, leaving an orphan note), not `$VAR` or a heredoc (worktree guards refuse them). Every write is verified from its response before the next one.

`<id>` below is the URL-encoded namespace (`group%2Fproject`) for GitLab and `<owner>/<repo>` for GitHub.

## Read

### Metadata and head

```bash
glab api "projects/<id>/merge_requests/<iid>"       # .sha (head), .source_branch, .target_branch, .diff_refs{base_sha,start_sha,head_sha}, .labels
gh pr view <n> --repo <owner/repo> --json headRefName,headRefOid,baseRefName,labels
```

### Changed files

```bash
glab api "projects/<id>/merge_requests/<iid>/diffs" --paginate   # .[].new_path, .[].old_path
gh pr view <n> --repo <owner/repo> --json files -q '.files[].path'
```

### Previous reviews: notes and threads, paginated

```bash
glab api "projects/<id>/merge_requests/<iid>/discussions" --paginate
```
Each discussion: `id`, `notes[]` with `id`, `author.username`, `created_at`, `body`, `system`, `resolvable`, `resolved`, `position.new_path`, `position.new_line`. Drop discussions whose first note is `system: true`. A discussion whose first note has `position: null` and `resolvable: false` is an MR-level NOTE (a bot review round, a summary); the rest are THREADs, "open" meaning `notes[0].resolvable && !notes[0].resolved`. This one call carries every previous review; there is no second notes read.

```bash
gh api graphql -F owner=<owner> -F repo=<repo> -F n=<number> -f query='
query($owner:String!,$repo:String!,$n:Int!){ repository(owner:$owner,name:$repo){ pullRequest(number:$n){
  reviewThreads(first:100){ nodes{ id isResolved isOutdated path line
    comments(first:50){ nodes{ databaseId author{login} body } } } }
  comments(first:100){ nodes{ author{login} body } } } } }'
```
Plus, for the previous reviews, `gh api repos/<owner/repo>/pulls/<n>/reviews --paginate` (review bodies with `state`, the bot and human rounds) and `gh api repos/<owner/repo>/issues/<n>/comments --paginate` (PR-level notes). "Open" means `isResolved == false`.

## Reply to a thread

```bash
# body.json: {"body": "Fixed at <short sha>: <path>:<line> now <what changed>."}
glab api --method POST -H 'Content-Type: application/json' --input body.json \
  "projects/<id>/merge_requests/<iid>/discussions/<discussion_id>/notes"
# verify: response .id is set and .body matches

gh api --method POST --input body.json \
  "repos/<owner/repo>/pulls/<n>/comments/<comment_databaseId>/replies"
# verify: response .id is set and .in_reply_to_id == <comment_databaseId>
```

## Resolve a thread

```bash
# resolve.json: {"resolved": true}
glab api --method PUT -H 'Content-Type: application/json' --input resolve.json \
  "projects/<id>/merge_requests/<iid>/discussions/<discussion_id>"
# verify: every response .notes[].resolved is true

gh api graphql -F id=<thread node id> -f query='
mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ id isResolved } } }'
# verify: .data.resolveReviewThread.thread.isResolved == true
```

Resolve is a per-thread call; one failed verification stops the batch and is reported with the thread id.

## Post an inline discussion

### GitLab

```bash
# note.json
{
  "body": "<finding>",
  "position": {
    "base_sha": "<diff_refs.base_sha>", "start_sha": "<diff_refs.start_sha>", "head_sha": "<diff_refs.head_sha>",
    "position_type": "text", "new_path": "<path>", "new_line": <line>
  }
}
glab api --method POST -H 'Content-Type: application/json' --input note.json \
  "projects/<id>/merge_requests/<iid>/discussions"
```
For an added line `new_path` + `new_line` suffice; for an unchanged context line or a removed line also send `old_path` + `old_line`. **Verify:** `.notes[0].position` is a non-null object whose `new_path` matches. A null `position` is an orphan general comment: delete it (`DELETE .../discussions/<disc_id>/notes/<note_id>`) and stop.

### GitHub

```bash
# note.json: {"body": "<finding>", "commit_id": "<head sha>", "path": "<path>", "line": <line>, "side": "RIGHT"}
gh api --method POST --input note.json "repos/<owner/repo>/pulls/<n>/comments"
```
Multi-line: add `start_line` and `start_side`. `LEFT` is the old side. **Verify:** `.path` and `.line` match and `.position` is non-null (null means the line is outside every hunk; pick a changed line nearby). Delete with `DELETE repos/<owner/repo>/pulls/comments/<comment_id>`.

## Remove the review-request label

Take the exact label title from the metadata (`.labels` on GitLab, `labels[].name` on GitHub), matching `Ready for Review` case-insensitively, and skip an MR/PR that does not carry it.

```bash
# unlabel.json: {"remove_labels": "<exact label title>"}
glab api --method PUT -H 'Content-Type: application/json' --input unlabel.json \
  "projects/<id>/merge_requests/<iid>"
# verify: the response .labels no longer contains the title

gh api --method DELETE "repos/<owner/repo>/issues/<n>/labels/<url-encoded label name>"
# verify: the response list has no entry whose .name is the label
```
On GitHub do not use `gh pr edit --remove-label`; `gh pr edit` fails on repos with classic project cards.

## MR/PR-level summary note

One per MR for what has no line: corrections to an earlier bot review, positives, the suggested commit message.

```bash
glab api --method POST -H 'Content-Type: application/json' --input summary.json "projects/<id>/merge_requests/<iid>/notes"
gh pr comment <n> --repo <owner/repo> --body-file summary.md
```

## Own stale notes

Identify your notes by `author.username` equal to `glab api user | jq -r .username` (GitHub: `gh api user -q .login`). Before re-posting a round, delete your earlier orphan notes (null `position`) so the MR does not accumulate duplicates.
