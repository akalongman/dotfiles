---
description: Review a GitLab MR or GitHub PR by checking out the branch and reading full file contents. Can also post the review back inline (file:line discussions) when the user asks.
user-invocable: true
---

Review a merge request (GitLab) or pull request (GitHub) thoroughly by reading full file contents, not just the diff. After writing the review, optionally post it back as inline (line-anchored) discussions on the MR/PR.

**Input:** `$ARGUMENTS` — MR/PR number (e.g. `149`) or full GitLab/GitHub URL.

**Steps:**

1. Detect the platform and extract the MR/PR number:
   - If `$ARGUMENTS` contains `gitlab.com` or looks like a GitLab URL → GitLab
   - If `$ARGUMENTS` contains `github.com` or looks like a GitHub URL → GitHub
   - If only a number is given, infer the platform from the current repo's remote URL (`git remote get-url origin`)

2. Fetch MR/PR metadata and the source branch name:
   - **GitLab:** `glab mr view <number> --repo <namespace/repo>`
   - **GitHub:** `gh pr view <number> --repo <owner/repo>`

3. Fetch existing review comments so you are aware of what has already been flagged:
   - **GitLab:** `glab api "projects/<encoded-namespace>/merge_requests/<number>/notes"` — parse JSON, skip entries with `system: true`, print author + body
   - **GitHub:** `gh api repos/<owner/repo>/pulls/<number>/comments` and `gh api repos/<owner/repo>/issues/<number>/comments` — print author + body from both

4. Get the list of changed files:
   - **GitLab:** `glab mr diff <number> --repo <namespace/repo>` — extract file paths from `--- a/...` / `+++ b/...` diff headers
   - **GitHub:** `gh pr diff <number> --repo <owner/repo>` — same approach

5. Note the current branch (`git branch --show-current`), then stash any uncommitted changes with `git stash` if the working tree is dirty.

6. Fetch and check out the MR/PR branch locally:
   ```
   git fetch origin <branch>
   git checkout <branch>
   ```

7. Read every changed file in full using the Read tool. Do not skip any file.

8. For each changed file, also identify and read the related base classes, interfaces, and parent classes that are relevant to understanding the code (e.g. base Policy, base Service, base Repository, base Controller, model, contracts). Read these too.

9. Restore the original branch and unstash:
   ```
   git checkout <original-branch>
   git stash pop   # only if stashed
   ```

10. Write the review. Structure it as:

    **Already flagged** — issues already noted in existing comments (acknowledge but do not duplicate).

    **Additional issues** — new issues you found, each with:
    - File path and line reference
    - Clear description of the problem
    - Concrete suggestion for the fix

    **Positives** — what is done well.

    Be critical and specific. Do not praise generic things. Focus on correctness, architecture consistency with the rest of the codebase, adherence to project patterns, security, and test quality.

11. **Optional: post the review inline.** After presenting the review, ask the user once: _"Want me to post these inline on the MR/PR?"_ Only post if they confirm. Do not post automatically.

    When posting:
    - Convert each "Additional issue" into a `(path, line, body)` triple. The line must exist on the **new** side of the diff.
    - Post each one as a line-anchored discussion using the platform recipe in **Posting recipes** below.
    - Post a single summary note at the MR/PR level for the meta-points that don't anchor to a line: corrections to prior bot reviews, positives, suggested commit message.
    - **Verify every inline post.** Parse the API response and confirm the discussion's `position` (GitLab) or `path`+`line` (GitHub) is non-null. If verification fails on the first one, stop and surface the error — do not loop through 20 broken posts.
    - If you have previously posted notes on this MR that landed without a position (i.e. as orphan general comments), delete them before re-posting. See the deletion recipes below.

## Posting recipes

### GitLab inline note (line-anchored discussion)

**Endpoint:** `POST /projects/:id/merge_requests/:iid/discussions`

**Critical gotcha:** the body MUST be sent as JSON via `--input -` with `Content-Type: application/json`. Do NOT use `glab api -f position[base_sha]=X` — `glab` URL-encodes the brackets to `%5B`/`%5D`, GitLab's nested-form parser doesn't recognize them, and the `position` is silently dropped, creating an orphan general comment with no line anchor.

Get the SHAs once per session:

```bash
glab api "projects/<encoded-namespace>/merge_requests/<iid>" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); r=d['diff_refs']; \
    print(r['base_sha'], r['start_sha'], r['head_sha'])"
```

Post each note:

```bash
PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'body': '<your note text>',
    'position': {
        'base_sha':      '<base_sha>',
        'start_sha':     '<start_sha>',
        'head_sha':      '<head_sha>',
        'position_type': 'text',
        'new_path':      '<path>',
        'new_line':      <line>,
    },
}))")
echo "$PAYLOAD" | glab api --method POST \
  -H 'Content-Type: application/json' --input - \
  "projects/<encoded-namespace>/merge_requests/<iid>/discussions"
```

For purely-added lines (in new files OR added lines in modified files) only `new_path` + `new_line` are needed. For unchanged context lines or removed lines in a modified file, also include `old_path` and `old_line`.

**Verify** by reading the response: `notes[0].position` must be a non-null object whose `new_path` matches what you sent. If `position` is `None`, the post failed silently.

**Delete a stranded discussion** (one whose `position` is null):

```bash
glab api --method DELETE \
  "projects/<encoded-namespace>/merge_requests/<iid>/discussions/<disc_id>/notes/<note_id>"
```

Discussions with one note are effectively removed when their only note is deleted. Identify your own notes by `notes[0].author.username` matching `glab api user`.

### GitHub inline review comment

**Endpoint:** `POST /repos/:owner/:repo/pulls/:number/comments`

`gh api` handles JSON well — both `-F`/`-f` and `--input -` work. Use `--input -` with JSON for consistency with the GitLab recipe.

Get the head SHA once:

```bash
gh pr view <number> --repo <owner/repo> --json headRefOid -q .headRefOid
```

Post each note:

```bash
PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'body':      '<your note text>',
    'commit_id': '<head_sha>',
    'path':      '<path>',
    'line':      <line>,
    'side':      'RIGHT',
}))")
echo "$PAYLOAD" | gh api --method POST --input - \
  "repos/<owner>/<repo>/pulls/<number>/comments"
```

For multi-line comments add `start_line` and `start_side`. `side: "RIGHT"` is the new side; `"LEFT"` is the old side (use for comments on removed lines).

**Verify** by reading the response: `path` and `line` must match what you sent, and `position` (the diff hunk offset GitHub computes) must be non-null. A null `position` means the line is outside the diff hunk — pick a nearby changed line.

**Delete a comment:**

```bash
gh api --method DELETE "repos/<owner>/<repo>/pulls/comments/<comment_id>"
```

### MR/PR-level summary note (no line anchor)

For the meta-summary (bot-review corrections, positives, suggested commit message): post one regular note.

- **GitLab:** `POST /projects/:id/merge_requests/:iid/notes` with `{"body": "..."}`.
- **GitHub:** `gh pr comment <number> --repo <owner/repo> --body "..."` (uses the issue-comments endpoint under the hood).
