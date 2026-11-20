---
name: app-external-agents
description: 'Use when the user asks to run Codex, Antigravity (agy, Gemini) or OpenCode with DeepSeek, Kimi or Qwen from this session: a second opinion or review from another model, a question put to it, or a task handed to it. Also before any Bash command that runs the codex, agy or opencode CLI. Triggers: "ask codex", "ask agy", "ask gemini", "ask deepseek", "ask kimi", "ask qwen", "ask the chinese models", "ask everyone", "second opinion", "what does codex think", "let codex do it", "run this through agy", "run agy", "run codex", "run opencode". Only on request, never on your own initiative.'
argument-hint: '[codex|agy|deepseek|kimi|qwen|all] <what to ask or do>'
user-invocable: true
---

# External agents: Codex, agy and OpenCode

Run the Codex CLI, the Antigravity CLI (`agy`) and OpenCode headlessly on
the user's behalf and relay what they answer. All three CLIs are trusted
and run with the user's own configuration, environment and allow-rules.

Every run goes through the runner, `scripts/ext-run` in this skill's
directory. One invocation runs one CLI to exactly one named outcome: it
checks the ground, builds the command line, keeps the time limit, resumes
the session once when it ends without an answer, continues it after a
usage limit when asked, and writes a status file from which the session
reports. The session keeps the judgement: which CLIs, what to ask, how to
weigh the answers. It never starts a task on `codex`, `agy` or `opencode`
itself.

## Aliases

OpenCode carries three fixed model aliases. Any other OpenCode model id
works when the user names it in full (`provider/model`).

| Alias | `--model` | Plan behind it |
|---|---|---|
| `deepseek` | `alibaba-token-plan/deepseek-v4-pro-0813` | Alibaba Model Studio Token Plan |
| `kimi` | `kimi-code-plan-global/k3` | Kimi membership, the lowest tier whose benefits list the 1M-context `k3` |
| `qwen` | `alibaba-token-plan/qwen3.8-max` | Alibaba Model Studio Token Plan |

No `kimi` run has answered through the runner yet. Both runs of the
acceptance run of 2026-11-16 ended `cli_failure` on OpenCode's
`UnknownError: Unexpected server error` before any model step. A
read-only check on 2026-11-20 (OpenCode 1.19.0, the runner of
public-dotfiles commit 14f78bd) found that `opencode models --pure`
lists no provider `kimi-code-plan-global`, and so not the alias's model
`kimi-code-plan-global/k3`; it lists `alibaba-token-plan`,
`github-copilot`, `google`, `opencode` and `vllm`. OpenCode's log holds
2026-11-16 but no line of either failed run, so it names no cause.
`KIMI_API_KEY` was unset or empty in the environment of the session
that made the check on 2026-11-20, and so was
`ALIBABA_TOKEN_PLAN_API_KEY`. That test exercises the environment only,
not a key entered with `opencode auth login`, which is how a key for
the Alibaba Token Plan, the plan of `deepseek` and `qwen`, was entered
on 2026-10-02, so an empty variable alone does not show a missing key.
Whether the provider was missing on 2026-11-16 too was not established.
`kimi` was not run again, because OpenCode does not list its model. Run
it when the user asks, and report a failure as the `cli_failure` row of
"Outcomes" says.

## Levels

A run is at the read level unless the user asked for changes to files;
then it is at the edit level. The runner passes each CLI's own flag for
the level.

What stops a write at the read level is stated in one of three words.
Enforced: a boundary outside the model stops the write, whatever the
model tries. Fenced: rules stop the forms of a write they recognise, and
other forms get through. Instructed: the model is told not to write, and
nothing else stops it.

| CLI | Read level | Edit level | What the read level rests on |
|---|---|---|---|
| Codex | `-s read-only` | `-s workspace-write` | enforced: its OS sandbox; a write under `read-only` was seen refused |
| agy | no flag | `--mode accept-edits` | instructed only: it can write files |
| OpenCode | agent `ext-read`, from `opencode/read-agent.json` | agent `ext-edit`, from `opencode/edit-agent.json` | fenced |

Codex's word rests on `CODEX_WRITE_REFUSED=yes` in `scripts/ext-run.conf`:
a probe of 2026-11-15 saw `touch` refused with "Read-only file system"
under the read-only policy. Were that setting `no`, the read level would
only be configured: the sandbox is selected, a refused write was not
observed.

agy has no read-only setting. Its allow-rules gate shell commands, not
its file-writing tool, and `--mode plan` is not a boundary, so it is not
used. At the read level the prompt's read-level line (step 5 of
"Steps") is all that stops a write. In a git repository the runner
therefore takes the before snapshot for every agy run, unless the
repository ignores the working directory (see step 7), and the report
compares the working tree with it.

OpenCode has no sandbox flag: its permissions are per-agent config, so
each run injects one of the two agent files through the
`OPENCODE_CONFIG_CONTENT` environment variable, which merges with the
user's own OpenCode config. The read agent denies edits, writes outside
the project, web access and every shell command except a short read-only
list that its system prompt states, and within that list it denies
output redirection and the `find`, `git` and `rg` options that write
files or run programs. Four ways through that fence are known. A write
shaped to get past the patterns (a redirection after a pipeline or a
`{ }` group) is stopped only by its instructions. An allowed command
that runs a helper program runs that program, for example `git diff`
with an external diff or text-conversion driver set in git config; only
the owner's own configuration can name such a helper, because a cloned
repository cannot set one. Outside paths leak: OpenCode infers the
directory of a shell command from its text on a best-effort basis, so on
a file outside the project and every granted directory the read tool and
`cat` were denied while `grep -n`, `head -1` and `ls` completed. And a
symbolic link leads out: in the acceptance run of 2026-11-16 the read
tool of two models (`deepseek`, `qwen`) read a file through a link
inside the project whose target lay outside the project and every
granted directory, so a project that holds such a link exposes its
target. The edit agent's write and edit tools follow such a link too:
in the acceptance rerun of 2026-11-18 (OpenCode 1.19.0, `qwen`, edit
level), the write tool created a file and the edit tool changed one
through a link inside the project whose target lay outside the project
and every granted directory; both calls completed without a permission
being asked, and both files changed on disk. The
runner does not look for such links; step 3 says how the session finds
one that leads into a protected directory, and a bundle built by step
3's rules holds none, because its copies follow links. Before an
edit-level OpenCode run, the session lists the links under the project
that lead outside it to something the owner can write, names each to the
owner by its path and target, and asks before starting the run. Step 3
("Links out of the project at the edit level") has the command and says
what counts. OpenCode's
own tool-output directory (`~/.local/share/opencode/tool-output/`) stays
readable in every run. The edit agent allows edits and shell commands
inside the project. Its rule denies the direct `git commit` and
`git push` commands only; a wrapped or scripted commit or push
(`git -c ... commit`, `sh -c '...'`, a script the agent wrote) is
stopped only by its instructions. Neither agent may start OpenCode
subagents or use OpenCode's skill tool.

A resume always runs at the read level, whatever the level of the first
attempt; for agy that, too, is an instruction only.

Hard rules:

- Never pass `--dangerously-skip-permissions`,
  `--dangerously-bypass-approvals-and-sandbox`, `-s danger-full-access`
  or OpenCode's `--auto`. This includes the bypass flag that agy's stderr
  may suggest after a denial: when relaying that text, say that this
  skill never uses it.
- Never edit the settings, allow-rules or credential store of any of the
  three CLIs, including everything under `~/.config/opencode`,
  `~/.local/share/opencode` (where OpenCode keeps `auth.json`) and
  `~/.opencode`; on Windows the same paths under the user profile. When
  a run is denied something, report it and let the user decide.
- Edit level runs one CLI at a time, across all three. Two agents editing
  one working tree collide.

## What each CLI is given

The five reviewers do not start equal. "Loaded" below means that the CLI
puts the item in front of the model without the prompt asking for it.

| | Codex | agy | OpenCode |
|---|---|---|---|
| Owner's global `~/.claude/CLAUDE.md` | no | no sign of it | not loaded (`OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1`) |
| Project `CLAUDE.md` | no | not checked | not loaded |
| Project `AGENTS.md` | loaded (seen in an older session) | not checked | the first one found of `AGENTS.md` and `CONTEXT.md`, OpenCode's own instruction files, which the switches do not touch (the order is a reading of the 1.19.0 binary, not rechecked) |
| Skills | kept out by `-c skills.include_instructions=false`: asked for its skills on 2026-11-15, Codex named none with it and 33 without it | `--disable-slash-commands`, which its help describes as turning off slash command and skill expansion in print mode; what agy loads from the superpowers plugin in its config directory was not established | the skill tool is denied, so OpenCode does not offer it (`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` as well); that skill descriptions do not reach the model rests on the model's own account |
| Plugins | its own | not checked | none (`--pure`) |

The runner passes all of these on every attempt, first, resume and
continue, from `scripts/ext-run.conf` and the agent files. The owner's
CLI configuration is not edited: the switches are environment variables
and flags of the run.

What stays unequal:

- Codex and OpenCode load a project's `AGENTS.md` by themselves; a
  project's `CLAUDE.md` reaches a reviewer only when the prompt names it.
  So the prompt names the project's instruction files by path for every
  reviewer, whatever each CLI also loads.
- Codex's skills are kept out by a configuration override that one probe
  showed working. Asked for its tools in the acceptance run of
  2026-11-16, Codex under the override listed 79 names, none of them
  mentioning skills, among them 51 of its apps (`mcp__codex_apps__`) and
  3 of `node_repl`: the tools of its apps and plugins seem to be still
  offered, which rests on the model's own list, not on a resolved tool
  set. Whether skills can still be found on demand through its
  `skill_search` feature, which is on, was not checked.
- agy's `--disable-slash-commands` rests on one short run on
  `gemini-3.8-flash-low`, because the default model was over its quota on
  2026-11-15, and again in the acceptance run of 2026-11-16. A run on the
  default model with the flag, and a resume with it, were not seen to
  answer.

## Steps

Command lines below begin with the runner's path. `<name>` stands for
any CLI: `codex`, `agy`, an alias or a full OpenCode model id. A line
that holds for one CLI only names it: `codex`, `agy`, or `qwen` for any
OpenCode alias or full model id. `<run>` is the run directory's absolute
path, `<dir>` an absolute directory, `<dur>` a duration in `timeout`'s
syntax (a number greater than zero, then `s`, `m`, `h` or `d` if wanted),
`<id>` a model id and `<value>` a reasoning effort.

### 1. Choose the CLIs

The ones the user named: `codex`, `agy`, an OpenCode alias (`deepseek`,
`kimi`, `qwen`) or a full OpenCode model id. "All" or "everyone" means
all five. When the user names none, ask which to run, as a numbered list
(1 codex, 2 agy, 3 deepseek, 4 kimi, 5 qwen, 6 all), and wait for the
answer.

### 2. Create the run directory

Create it under `~/.cache/external-agents/<YYYY-MM-DD-HHMM>-<slug>/`
(24-hour local time), on disk, because the session scratchpad is on a
tmpfs that a reboot empties; a reboot on 2026-11-14 took a running
review's trace with it. Below, `<run>` is its absolute path. Read-level
runs of several CLIs share one run directory and one `prompt.md`; each
writes its files under its own prefix, `<p>` below: `codex`, `agy`, the
alias, or a full model id with every `/` replaced by `-`. At the edit
level each run
gets a run directory of its own, with the CLI name or alias in the slug.
The before snapshot (`before.txt` and `before.diff`, see step 7) belongs
to the run directory, not to a prefix: a run that takes one, at the edit
level or agy at either level, refuses a run directory that already holds
either file, and a new run directory is the remedy.
The skill never deletes a run directory; the owner does.

### 3. Build a bundle when the material calls for one

A bundle is a directory inside the run directory, `<run>/bundle` for
example, that holds copies of everything the task needs: the material
under review, the files it is checked against, and the evidence. Make it
a git work tree of its own (`git init`, nothing committed) and start the
runs from it, so that the bundle is the project boundary wherever the
run directory lies. One bundle serves all five reviewers, which also puts
them on the same files.

Use one when the material lives in the dotfiles work tree (its top is the
home directory, so an OpenCode run started anywhere in it is refused) or
inside a protected directory (see step 6), when one file is needed from a
directory that must not be opened as a whole, for OpenCode when the
project or an outside directory holds a symbolic link that leads into a
protected directory (below), and for agy when a path falls outside its
file-reading rules. Worked example: a review of this skill. Its directory
lies in the dotfiles work tree, so the session copies `SKILL.md`,
`scripts/`, `prompts/`, the design and the rule file it is checked
against into `<run>/bundle`, runs `git init` there, and starts every
reviewer from `<run>/bundle`.

Links into a protected directory. The runner checks the project boundary
and each outside directory by their own paths (step 6), not the links
inside them, and OpenCode's read tool follows a link out of its fence
(see "Levels"). So before an OpenCode run the session lists the links on
disk under the boundary and under each outside directory, and resolves
each. This prints every link under `<dir>`, then where it leads:

```
find -H <dir> -type l -exec sh -c 'for l do printf "%s -> %s\n" "$l" "$(realpath -- "$l")"; done' sh {} +
```

`-H` makes `find` descend also when `<dir>` is itself a link, as an
outside directory may be; the runner grants such a directory by the
path it leads to. The command does not descend into the directories the
links it prints lead to, while a path through them goes on through the
links met there, for a copy that follows links as for a file OpenCode's
read tool opens: with `proj/a` a link to `other` and `other/b` a link
to a protected directory, it prints `proj/a` only, and a copy of `proj`
holds `a/b` with the protected directory's files. On 2026-11-20
(OpenCode 1.19.0, `qwen`, read level, the runner of public-dotfiles
commit e453297, whose runner code is that of 14f78bd) OpenCode's read
tool was seen to go on through two links in a row: in a bundle whose
link `chain` leads to a scratch directory outside the project and every
granted directory, in which a link `next` leads to a second such
directory, it completed a read of `chain/next/deep.txt` with no
permission asked, and the answer gave that file's line; the listing
command of step 3 printed `chain` on the bundle, and `next` only when
run again on the directory `chain` leads to. So run it again on
each target it prints that is a directory outside `<dir>`, then on each
such directory those runs print, and so on, each directory once, until
no new one appears; a target that already calls for a bundle (below)
needs no listing of its own. `find -L` would list every depth in one command,
but it walks a linked directory again for every path of links that
leads to it: from a link to the first of 23 directories, each holding
links to the next two, it lists tens of thousands of lines, where the
command above lists one. Compare each target with the
protected directories by their canonical paths, as the runner does,
because a protected directory may itself be a link into another
directory: `realpath -m -- ~/.ssh` gives the path to compare with for
`~/.ssh`, and so on for each. A
target that is, lies inside or contains a protected directory (the home
directory, for example) calls for a bundle. At the edit level, which
never runs from a bundle, the session names the link to the owner
before the run, by its path and target, and asks before starting the
run, whether or not the owner can write its target (see "Links out of
the project at the edit level" below).
Worked example: the private dotfiles checkout, `~/.dotfiles-private`,
is a git work tree of its own whose top overlaps no protected directory,
so an OpenCode run started in it passes the boundary check, and its
`home/.exports` is a link to `~/.secrets/.exports`. A `qwen` review of a
plan under `home/.claude/docs` therefore runs from a bundle that holds
the plan and the files it is checked against, never a copy of `home/`
as a whole, which would carry the file the link leads to. That link is
ignored by git, which is why the list comes from the disk and not from
`git ls-files`.

Rules for building it:

- copy files and directories following symbolic links, so that no link
  leads out of the bundle;
- before copying a directory whole, list its links with the command
  above, in turn under each directory outside it that they lead to as
  well, and leave out each link whose target is, lies inside or
  contains a protected directory, or is a credential file, at any
  depth: the copy follows links at every depth and would carry what
  they lead to into the bundle. A link met in a linked directory is left
  out by copying that directory, without it, in place of the link that
  leads there;
- never copy a credential file, and never a whole protected directory;
- never copy a `.git` directory or file, which would lead back to the
  original repository. A review of a git range or of uncommitted changes
  gets the diff written into the bundle as a file, beside the full text
  of the files it touches;
- the prompt names the copies, says that they are copies and where each
  came from, and says that paths inside the material which point at the
  originals need not be opened;
- findings come back with paths into the bundle; map them to the
  originals before relaying them.

A bundle is a snapshot, not isolation. A reviewer cannot see what changed
after the copy. Codex and agy can still open the originals by their
paths, and agy writes files of its own outside the working directory. The
bundle decides what OpenCode is granted and what every reviewer is
pointed at, nothing more. An edit-level task is never run from a bundle.

Links out of the project at the edit level. OpenCode's write and edit
tools follow a link inside the project out of it, with no permission
asked (see "Levels"), and the runner does not look for links. Before an
edit-level OpenCode run, the session lists the links under the project
that lead outside it to something the owner can write, names each to the
owner by its path and target, and asks before starting the run. An
edit-level run has no granted directory, because the runner refuses
`--allow-dir` at the edit level, so such a link also leads outside every
granted directory. Something the owner can write is a target writable by
the owner, a directory holding something writable by the owner, or a
missing target whose nearest existing directory above it is writable by
the owner, because the write tool can create the missing target through
the link. A link to a file the owner cannot write, such as a
virtualenv's link to the system python, is not such a link. A
virtualenv's link to an interpreter that uv manages, under
`~/.local/share/uv/python`, which the owner can write, is such a link.
This prints each such link under `<boundary>`, the project boundary of
step 6, as `<link path> -> <target>`:

```
top=<boundary>
T=$(realpath -- "$top")
find -H "$top" -type l -print0 | while IFS= read -r -d '' l; do
  t=$(realpath -m -- "$l") || continue
  case "$t/" in "$T"/*) continue ;; esac
  if [ -e "$t" ]; then
    w=$(find "$t" -writable -print -quit 2>/dev/null)
  else
    a=$t; until [ -e "${a:-/}" ]; do a=${a%/*}; done
    w=''; if [ -d "${a:-/}" ] && [ -w "${a:-/}" ]; then w=${a:-/}; fi
  fi
  if [ -n "$w" ]; then printf '%s -> %s\n' "$l" "$t"; fi
done
```

It prints nothing for a link whose target lies inside the project or
holds nothing writable by the owner. Inside a linked directory the
search stops at the first entry writable by the owner, so a large tree
the owner cannot write (a link to `/usr`, for example) is searched
whole. The search does not follow the links it meets inside a linked
directory: one of them counts only when its own target is writable by
the owner, so a writable directory below an unwritable directory it
leads to, or a missing target it names, is missed. A link that cannot be
resolved, a loop for example, is named by
`realpath` on standard error and skipped, since nothing can be written
through it. When the command prints nothing, the run starts without the
question; otherwise it starts only when the owner says so, and what the
run writes through such a link does not show in the snapshot comparison
(see "Report"). Worked example: in the acceptance rerun of 2026-11-18
the project `edit-proj` held `link`, a link to the scratch directory
`edit-outside`, which the owner can write, and the command prints
`.../edit-proj/link -> .../edit-outside`. A virtualenv's `bin/python`
that links to the system python, `/usr/bin/python3`, resolves on this
machine to `/usr/bin/python3.14`, which the owner cannot write, and
prints nothing. One that uv made with an interpreter it manages links to
`~/.local/share/uv/python/...`, which the owner can write, so the
command prints it and the other interpreter links beside it (`python3`,
`python3.14`), and the session asks before every edit-level OpenCode run
in that project: on 2026-11-18, 10 of the 16 virtualenvs under
`~/projects` were of that kind.

### 4. Write `<run>/prompt.md`

One copy in each edit-level run directory. The CLI knows nothing about
this session, so the prompt stands alone:

```
# Task
<the goal, in the user's terms>

# Context
<what the CLI cannot get from the files, or "Nothing to add.">

# Where to look
<the project directory or the bundle; the files, directories or git range to read>
<the project's instruction files that bear on the task, by path>
Outside the project:
<one absolute directory per line: exactly the list passed with --allow-dir>

# What to return
<the shape of the answer: findings with file and line, a decision, a summary of changes>
Write your complete answer as your final message, after your last tool call. Text written before a tool call is treated as working notes.
```

- `# Context` holds what the CLI cannot get from the files: what the
  thing is for, constraints that live outside the repository, and what
  was tried or ruled out and why, each with the place it is recorded
  when it is recorded. It never holds the session's own verdict on the
  material ("the plan looks sound"), because a reviewer handed a
  conclusion tends to return it. When there is nothing to add, it says
  so.
- `# Where to look` lists outside-project directories in a group of
  their own, and the session passes exactly that group to the runner as
  `--allow-dir` (step 6). It names by path the project's instruction
  files that bear on the task (`CLAUDE.md`, `AGENTS.md`, a rules
  directory, the capability specs), for every reviewer. The owner's
  global instruction files address an interactive session, not a
  reviewer: they are listed only when they are the material under
  review, and then marked as material to review, not as instructions to
  follow.
- Name files by path; never paste their contents or a diff into the
  prompt (a diff goes into a bundle as a file).
- `# What to return` ends with the closing instruction shown above, word
  for word: OpenCode's answer is the text of its final step, and earlier
  text is kept apart.
- A shape the user asked for takes precedence over any template.
- For a review (a plan, a spec, a design, a diff, code), read
  `prompts/review.md` and add its parts. No sentence of a review prompt
  tells the reviewer not to question, argue with or reverse a decision.

### 5. The read-level line

At the read level the prompt's last line is this one, after the closing
instruction:

```
Do not modify any files and do not run experiments.
```

For agy this line is all that stands between a read-level run and a
write. It is never left out of a read-level prompt.

### 6. Start the runs

Start one invocation per CLI, each as its own background shell call, so
that the session is notified as each run ends. Start a `run` from the
project directory, or from the bundle. Read level, any CLI:

```
~/.claude/skills/app-external-agents/scripts/ext-run run --cli <name> --run-dir <run>
```

With outside directories, one `--allow-dir` for each directory listed
under "Outside the project" in the prompt, the same list for every CLI
of the run:

```
~/.claude/skills/app-external-agents/scripts/ext-run run --cli <name> --run-dir <run> --allow-dir <dir>
```

Edit level, one CLI at a time, each in a run directory of its own and
never from a bundle; for OpenCode, only after step 3's "Links out of the
project at the edit level":

```
~/.claude/skills/app-external-agents/scripts/ext-run run --cli <name> --run-dir <run> --level edit
```

The first attempt's limit is 90 minutes and the resume's 30 minutes.
Set others only when the user asks:

```
~/.claude/skills/app-external-agents/scripts/ext-run run --cli <name> --run-dir <run> --limit <dur> --resume-limit <dur>
```

A model and a reasoning effort are passed only when the user names a
value; otherwise Codex and agy use their own configuration. Codex takes
both:

```
~/.claude/skills/app-external-agents/scripts/ext-run run --cli codex --run-dir <run> --model <id> --effort <value>
```

agy takes a model only. Its model ids carry the effort
(`gemini-3.1-pro-high`, `gemini-3.8-flash-low`; `agy models` lists them),
and the runner refuses `--effort` for agy:

```
~/.claude/skills/app-external-agents/scripts/ext-run run --cli agy --run-dir <run> --model <id>
```

An OpenCode alias or full model id names the model itself, so the runner
refuses `--model` with it; an effort the user names is passed as
OpenCode's `--variant`:

```
~/.claude/skills/app-external-agents/scripts/ext-run run --cli qwen --run-dir <run> --effort <value>
```

Options combine on one line, within the refusals below; the lines above
show each on its own.

Outside directories. They must be absolute directories: a single file
cannot be granted, so name the directory that holds it, or copy the file
into a bundle. OpenCode is granted them for reading at the read level
only; an edit-level OpenCode run given one is refused before it starts.
For OpenCode the runner also refuses the root and every directory
directly under it (`/tmp`, `/etc`, `/home`), `/var/tmp`, the home
directory or an ancestor of it, a canonical name that holds `*` or `?`
(pattern characters in OpenCode's rules), and any directory that
is, lies inside or contains a protected directory. Protected are the
settings and credential directories of the three CLIs (`~/.codex`,
`~/.gemini`, `~/.config/opencode`, `~/.local/share/opencode`,
`~/.opencode`), the Claude config directories (`~/.claude` and its
numbered copies such as `~/.claude2`), and the owner's key stores
(`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.secrets`, `~/.config/gh`). Where
`CODEX_HOME`, `XDG_CONFIG_HOME` or `XDG_DATA_HOME` moves one of them, the
moved location is protected as well as the default one, and so are
`GH_CONFIG_DIR`, `CLAUDE_CONFIG_DIR` and `GNUPGHOME` (which moves
`~/.gnupg`) when they are set. For agy the runner names in its prompt
copy, by their real paths, those of the directories that its
file-reading tool cannot open, to be read with shell commands. Codex
reads anywhere and ignores them. Never
pass a protected directory as `--allow-dir` to any CLI: the runner
refuses one for OpenCode only, and for agy and Codex nothing but the
session enforces it. Material that lives inside a protected directory, a
skill under `~/.claude/skills` for example, goes through a bundle.

The project boundary. An OpenCode run is also refused when its project
boundary (the top of the git work tree that holds the working directory,
or the directory itself outside a work tree) is the home directory or an
ancestor of it, or is, contains or lies inside a protected directory,
because the credential directories would then be part of the project.
The refusal names the remedy: a bundle. Both checks, of the outside
directories and of the boundary, compare their own paths, not the links
inside them, so a project or an outside directory that holds a link into
a protected directory is not refused; step 3 says how the session finds
one. Codex and agy are not refused;
they already read anywhere, on the owner's own subscriptions.

Start OpenCode runs a few seconds apart. Two started within a second once
failed with `database is locked`; whether the gap prevents it is not
established.

agy's prompt copy. For agy the runner writes `<run>/agy-prompt.md` once:
`prompt.md` followed by the shell commands agy's settings allow, the
directories where its file-reading tool works, and the instruction to use
`cat`, `head` or `grep` for every other path. In a headless run agy ends
the whole run with no answer at the first refused command or file read,
so it has to know the lists up front. The runner reads agy's settings
once, before it claims the prefix, for these lists and for the default
model it records as `configured_model`, and never changes them; a change
to the file after that read does not reach the run.

Stopping a run. Send the runner the termination signal (TERM); its
process id is in `<run>/<p>.lock/pid` while it runs. An interrupt (INT)
is ignored by a runner that a shell started in the background, because
such a command starts with the interrupt ignored. The runner passes the
signal to the CLI's process group, then to every process still alive in
the session that group leads, which reaches a worker that moved to a
process group of its own (Codex's `node_repl` and `codex-code-mode` did
in the acceptance run of 2026-11-16), and records the outcome; the same
stop, without the signal, follows every command it starts. A worker that
starts a session of its own escapes both. A signal that
arrives before or while the CLI runs ends the run as `cancelled`. One
that arrives after the CLI has exited leaves that attempt's verdict
standing: a run whose CLI answered ends under that answer, `answered`,
or `answered_after_resume` when the answer came from the resume or a
continue of it, and keeps it, and a run whose attempt failed ends under
that failure; a resume that would have followed is not started, and the
run then ends `cancelled`. A kill signal (KILL) or a power loss cannot
be caught: the status file then still says `running`, and the report
says that the run did not finish. After a KILL the CLI, in a session of
its own, runs on until its time limit ends it, at the edit level
possibly still writing, and the claim stays, so a later run or continue
of the prefix is refused with `pid <n> is not running` and the command
that removes the claim. So stop a run with TERM only, and after any
other stop look before reporting: `<run>/<p>.lock/gid` holds the id of
the session of the last command the runner started (the CLI, once an
attempt has begun), `ps -s <id>` lists what is left of it, and the
report names what still runs; the owner decides whether to stop it.

### 7. When a run ends

Read the summary line, the only line the runner prints on standard
output:

```
<p>: <outcome> (<message>); status: <path of the status file, or none>
```

The message and its parentheses are left out when there is nothing to
say, and the line begins with `ext-run` when the CLI name was not valid.
Open the status file only when the line names one, and report from it
(see "Report"). When the line ends `status: none`, no status file on disk
is this invocation's record (see "Outcomes"). The runner's other
messages are on standard error.

Files in the run directory, under the prefix `<p>`:

- `<p>.status`: the status object, one JSON object; `<p>.status.tmp` is
  the temporary name it is written through.
- `<p>.out`: the final answer, present when an attempt answered;
  `<p>.out.tmp` is the temporary name it is published through.
- `<p>.<phase><n>.stdout`, `.stderr`, `.time` and `.exit`: one attempt's
  raw output (for agy and OpenCode the standard output is the JSON
  trace), wall seconds and exit status. The phase is `first`, `resume`
  or `continue`, and `<n>` counts from 1 within a phase, so `qwen.first1`
  and `qwen.resume1`. No attempt file is overwritten.
- `<p>.<phase><n>.earlier.txt` (OpenCode): the text that attempt wrote
  in steps before its final one, absent when there is none.
- `<p>.<phase><n>.config.json` (OpenCode): the config injected into that
  attempt.
- `codex.probe.err`: the standard error of the last Codex sandbox probe.
- `agy-prompt.md`: agy's prompt copy.
- `before.txt` and `before.diff`: the before snapshot, written by an
  edit-level run and by every agy run, in a git work tree. Outside one
  (no `.git` on the way up from the working directory) the run writes
  neither and notes it; where a `.git` lies above and git fails there (a
  `.git` file it cannot read, a repository it refuses to trust), the run
  ends `prerequisite_failed` before the CLI starts. In a working
  directory that its work tree ignores the run also writes neither and
  notes why, because `git status` shows nothing a CLI writes there.
  Worked example: on a machine whose home directory is a git work tree
  that ignores every top-level entry but a few (the dotfiles, whose
  ignore file has `/*` followed by `!/.claude` and the like),
  `~/Downloads/proj` has no repository of its own, so git places it in
  the home directory's work tree, which ignores `Downloads`. An
  edit-level Codex run, or an agy run at either level, started there
  takes no snapshot, records the note
  `the working directory is ignored by its git work tree: no before snapshot`,
  and starts the CLI; a snapshot there would have held only the other
  edits to the dotfiles. Such a run in `~/.claude/skills/x`, which the
  ignore file lets in, keeps its snapshot of the home directory's work
  tree. An OpenCode run is refused in both directories before any
  snapshot, because its project boundary is the home directory (see
  step 6).
  git's answer comes from `git check-ignore`; one that fails ends the
  run `prerequisite_failed`, as above.
- `<p>.lock/`: the claim on the prefix, present while the runner runs.

The claim. Each invocation claims its prefix in the run directory before
it writes anything: it makes `<p>.lock` and then creates `<p>.lock/pid`
exclusively, and the invocation that creates the pid file holds the
claim. A second invocation with the same prefix, a second continue of one
run included, is refused. A run also refuses to start when files of its
prefix already exist, and a run that takes the before snapshot when
`before.txt` or `before.diff` already exists. That second check narrows
the overlap of two such runs started together in one run directory and
does not close it, since both can pass it before either writes; one run
directory per edit-level run avoids it.

## Outcomes

Every invocation ends in exactly one outcome. The summary line names it,
the runner exits with its number, and the status file records it with
the phase in which it was decided (`preflight`, `first`, `resume` or
`continue`). Two outcomes carry an answer: `answered`, from the first
attempt (or a continue of it), and `answered_after_resume`, from the one
resume that follows an attempt which reached its limit or ended empty
(or from a continue of that resume). Five end a run in which the CLI ran
and gave no answer: `limit`, the time limit was reached without an
answer (in the resume, when one ran); `empty`, the CLI ended normally
with no answer (in the resume, when one ran); `denied`, agy ended
because an action was
denied; `usage_limit`, the provider refused further work until a stated
time; `cli_failure`, the CLI exited with an error not named here. Three
concern the trace and the session: `trace_unreadable`, the CLI's output
could not be parsed; `no_handle`, a resume or a continue was due and the
attempt that created the session left no session handle;
`handle_conflict`, that attempt's files held more than one handle, or a
later attempt reported another handle than the one it was passed. Six
are decided around the CLI: `prerequisite_failed`, something the runner
needs is missing or failed (among them a helper program, bash 5, jq
1.7, a `ps` that lists the processes, its settings file, its follow-up
texts, agy's settings file, the Codex sandbox probe, git; the table
below names each);
`unsupported_version`, the OpenCode version guard refused (a major
version other than the tested one, or a version command that failed,
did not answer or printed no version); `cancelled`,
a signal stopped the runner before or
while the CLI ran, or before a resume; `runner_failure`, the runner could
not write or read one of its own files or could not confirm that the CLI's
processes had ended, or exited in a way nobody planned; `usage_error`,
bad input (an argument, a refused outside directory or project boundary,
a claimed prefix, files of the prefix that already exist, a before
snapshot already in the run directory of a run that takes one, a saved record
that a continue cannot continue, a prompt changed before a start-again),
or, for OpenCode, a git that ran and failed while the project boundary
was checked, before the invocation owned a status file (its
`git rev-parse --local-env-vars` call, or the boundary query where a
`.git` lies above the directory);
`missing_cli`, the CLI is not on PATH. The runner prints the same list
with `outcomes`:

```
~/.claude/skills/app-external-agents/scripts/ext-run outcomes
```

| Outcome | Exit | What to report |
|---|---|---|
| `answered` | 0 | the answer from `<p>.out`, with the report's first line |
| `answered_after_resume` | 0 | the answer, that it came from the resume, the resume's reason (`resume_reason`: `limit` or `empty`) and both wall times |
| `limit` | 10 | that the limit was reached without an answer (the message names which limit), the attempts' wall times, and any earlier text |
| `empty` | 11 | that the CLI ended without an answer, also after the resume, and any earlier text |
| `denied` | 12 | the denied actions from `denied`, and the last lines of the attempt's standard error verbatim, including where agy says an allow-rule goes; for a refused file read, the rule shape agy's message gives. The skill never adds the rule: the owner decides, and a bundle is the way that needs none |
| `usage_limit` | 13 | the message, the reset time (`reset_at`) and the continue command. For Codex the limit is its `hit your usage limit` error and `reset_at` the time it states; for agy it is its quota error (`Individual quota reached` in the result's error, or `RESOURCE_EXHAUSTED (code 429)` on standard error) and `reset_at` the attempt's end plus the `Resets in` duration it states, as a local time. `continue` waits for the owner's word: the runner never waits for a reset, and the session continues only when the owner says so. Before continuing an edit-level run whose status says `fresh_start: true`, compare the working tree with the before snapshot |
| `cli_failure` | 14 | the message, which carries the CLI's own error, and the last lines of the attempt's standard error verbatim. When that standard error cannot be read, the outcome still rests on the CLI's exit status, and the message says that the reason could not be read and names the file. After an OpenCode start-up failure nothing is started again by itself: a read-level run may be started again under a new prefix (the full model id in place of the alias, or a new run directory); before an edit-level run is started again, compare the working tree with the before snapshot. A missing or rejected key ends here too: point the user to "Prerequisite" |
| `trace_unreadable` | 15 | the message and the attempt's standard output file, which holds the trace |
| `no_handle` | 16 | that the run could not be resumed or continued, and the attempt files |
| `handle_conflict` | 17 | the handles the message names; nothing further is resumed |
| `prerequisite_failed` | 18 | what the message names, one of these: bash older than 5; a missing helper program; a jq older than 1.7 (one that does not take `--raw-output0`); a `ps` that does not list the processes (its `ps -A -o pid=,pgid=,sid=,stat=` fails or does not show the runner's own process, checked once before anything starts, in a run and a continue alike, because every stop of a started command reads that table); the settings file `scripts/ext-run.conf` missing or unreadable (or the runner's own directory, where it is looked for, not found), and for OpenCode an empty `OC_SKILL_DENY_KEY` or an `OC_TESTED_VERSION` in it that is not a version, or a `HOME` that is not an absolute path; a test setting of the runner (`EXT_RUN_GRACE`, `EXT_RUN_KILL_WAIT`, `EXT_RUN_PREFLIGHT_LIMIT`, `EXT_RUN_POLL`, `EXT_RUN_START_WAIT`) set in the environment to a value it refuses, or an `awk` that cannot convert one; the follow-up texts (`prompts/followup.md` missing, or one of its four sections missing or empty, found before any CLI starts, in a run and a continue alike); agy's settings file that cannot be read or is not one JSON object (an agy run, refused before it writes anything); the OpenCode agent files, when the config to inject cannot be built from them; git that did not answer or cannot be run, or whose `git rev-parse --local-env-vars` answered (status 0) with what is not a list of variable names or without `GIT_DIR`; git that failed in the before snapshot where a `.git` lies above the working directory, and, for Codex and agy, which ask git only there, a `git rev-parse --local-env-vars` call that failed, whether or not a `.git` lies above the working directory (git's reason is in the message, and the CLI was not started; for OpenCode, which asks git first for the project boundary, such a call that failed is a `usage_error`); or the Codex sandbox probe (then "Prerequisite", quoting `<run>/codex.probe.err`) |
| `unsupported_version` | 19 | the OpenCode version found and the tested one; when `opencode --version` failed, did not answer within the preflight limit or printed what is not a version, the message says so instead, and when it failed and its standard error could not be read, the message says that too and names the file |
| `cancelled` | 20 | that the run was stopped, and what the attempt files hold |
| `runner_failure` | 21 | the message and standard error. When the summary line names a status file, that file records the failure; when it ends `status: none`, see below |
| `usage_error` | 64 | the fault the message names. A refused outside directory or project boundary needs a bundle; a git that ran and failed while OpenCode's project boundary was checked (its `git rev-parse --local-env-vars` call, or the boundary query where a `.git` lies above the directory) is reported with git's own reason, which the message quotes, rather than with a bundle as the remedy, and the repair, of git or of that repository, is the owner's; a before snapshot already in the run directory needs a new run directory; a claimed prefix comes with the runner's verdict on the claim's owner and, when that owner is not running or unknown, the command that removes the claim, which the owner decides on |
| `missing_cli` | 127 | which CLI is not on PATH |

A summary line that ends `status: none`. A `runner_failure` that no
status file records, and every outcome of an invocation that ended
before it owned a status file, end that way: then the report comes from
the summary line and standard error, and no status file on disk is this
invocation's record. Such a `runner_failure` puts the status object, as
far as it is known, on the last line of standard error as one line of
JSON; a status file of this prefix that still says `running` was left by
this invocation and is not its record either. A `continue` that ended in
its checks of the saved record or in its preflight, before its attempt,
writes no status: the saved status file stays byte for byte as it was.
When such a continue ends `runner_failure`, its JSON line on standard
error carries outcome `runner_failure` and phase `preflight`, or phase
`continue` when the failure came while it prepared its first write of
the status file, which is not expected in practice; once the
runner has found the saved record to be a usage limit, the line also
carries the earlier run's fields, while the file on disk still says
`usage_limit`. That line describes this invocation, not the saved
record. Whether the run can be continued later depends on where the
fault the message names lies:

- Outside the run's files: the command line (a run directory or `--cli`
  that names no status file, or a `--cli` other than the one the status
  file was written for), a claimed prefix, a missing CLI, a prerequisite
  (any the `prerequisite_failed` row names, apart from agy's settings
  file and the before snapshot, which a continue neither reads nor
  takes), for OpenCode a `git rev-parse --local-env-vars` call that
  failed (a `usage_error`), an OpenCode
  version the guard refused, a process group or session that outlived
  the kill, or a signal. A record that could be continued before still can be: once
  the fault is cleared, the same continue command is checked afresh.
- In the files and directories around the record: the recorded working
  directory is gone or not a directory; files of the attempts the
  continue would write already exist; the prompt changed since the
  first attempt, when the continue starts afresh; for OpenCode, a
  recorded outside directory, or the project boundary of the recorded
  working directory, is now refused. Every retry is refused the same
  way until that is fixed, for example the directory or the prompt
  restored or the files moved aside, which the owner decides on.
- In the record or the session it names: a status file that cannot be
  read as one JSON object, is incomplete, contradicts itself or does not
  match the CLI's kind or prefix; an outcome other than `usage_limit` (a
  run that ended otherwise, or one that still says `running` because a
  kill signal or a power loss stopped it); files of the attempt that
  created the session that hold no session handle or more than one
  (`no_handle`, `handle_conflict`). The runner never changes a saved
  record, so such a run cannot be continued at all.

The continue. It repeats the phase that the usage limit cut off. A cut
off first attempt is continued in the same session at its original
level, with the continue text and the full first-attempt limit, and may
be followed by the one resume. A cut off resume is continued at the read
level with the same write-now text and the resume limit, and no further
resume. When the limit refused the first attempt before its first model
turn (`fresh_start` is true), there is no session to continue, so the
continue starts the first attempt again with the original prompt, which
must not have changed since (`prompt_sha256`). A continue takes the
working directory, level, limits, outside directories, model and effort
from the status file, so it can be started from anywhere:

```
~/.claude/skills/app-external-agents/scripts/ext-run continue --cli <name> --run-dir <run>
```

A continue that ends in a usage limit again can be continued again.

## Report

One section per run, under the CLI name, or for OpenCode under the alias
or the full model id. The first line of each section is this template,
every field filled in from the status file, on every run including
failed ones; a value the status file does not hold is written `unknown`.
A section without it is incomplete:

```
Codex: <model>, effort <effort>. <tokens> tokens, <wall> s. Session <handle> (ext-run continue --cli codex --run-dir <run>).
agy: <model>. <total> tokens (<input> in, <output> out, <thinking> thinking), <wall> s, <turns> turn(s). Conversation <handle> (ext-run continue --cli agy --run-dir <run>).
<name>: <model> via opencode <version>, variant <effort>. <total> tokens (<input> in, <output> out, <reasoning> reasoning, <cached> cached), $<cost>, <wall> s, <steps> step(s). Session <handle> (ext-run continue --cli <name> --run-dir <run>).
```

The continue command stands in the parentheses in place of the CLI's
bare command, which would run without the runner's follow-up texts,
limits, classification and status file; it is written only when the
outcome is `usage_limit`, the one outcome a continue accepts, and
otherwise left out with its parentheses. In the OpenCode line,
`, variant <effort>` is written only when the user named an effort, and
otherwise left out.

| Field | Codex | agy | OpenCode |
|---|---|---|---|
| model | `reported.model`; else `requested.model` followed by "(requested, not reported)" | `reported.model`, which agy reports only when `--model` was passed; else `requested.model` followed by "(requested, not reported)"; without `--model`, `configured_model` followed by "(configured default, not reported)" | `oc_model` followed by "(requested, not reported)" |
| effort | `reported.effort`; else `requested.effort` followed by "(requested, not reported)" | none: the model id carries it | `requested.effort` as ", variant <value>" after the version, only when it was named |
| tokens | `tokens.reported`, one value per attempt as Codex printed it, never added up, because whether Codex counts across a resume is not established | `tokens`: `total`, `input`, `output`, `thinking` and `turns`, from the last result event (agy reports a conversation's running total) | `tokens`: `total`, `input`, `output`, `reasoning`, `cached`, `cost` and `steps`, summed over the attempts; the three aliases always report cost 0, written `$0 (plan)` |
| wall | `attempts[].wall`, one value per attempt with its phase when there is more than one | the same | the same |
| handle | `handle` | the same | the same |
| version | none | none | `versions.preflight`, followed by "untested" when `version_untested` is true |
| outside directories (after the first line) | `allow_dirs` is `[]`: Codex is given none and reads anywhere | `allow_dirs`: exactly the directories its prompt copy names to be read with shell commands, by their real paths; one inside the working directory or under a file-reading directory is not named and not listed | `allow_dirs`: the directories it was granted, by their canonical paths |
| snapshot notes (after the first line) | `notes`: the before snapshot's notes, `not a git repository: no before snapshot`, `the working directory is ignored by its git work tree: no before snapshot` or `no commit yet: before.diff is empty`, also joined after the message; a continue keeps them and repeats them after its own message; empty when there are none | the same | the same |

After the first line, as they apply:

- the outcome and its message (`outcome`, `message`), as the
  "Outcomes" table says;
- when a resume ran, its reason (`resume_reason`) and both wall times;
- an OpenCode version other than the tested one: the versions in
  `versions` (`preflight` and `later`) and that it is untested;
- earlier text, per attempt (`attempts[].earlier_text`, a file in the
  run directory, and `earlier_text_bytes`): say that it exists and where.
  Read it before relaying the answer, because a model may have written
  findings in a step before its final one;
- denied calls, verbatim from `denied` (the attempt, the tool, its input
  and the error), and that the edit level or an outside directory is
  needed if the task required them;
- skipped trace lines (`attempts[].skipped_lines` above 0): lines of the
  trace that did not begin with `{`, such as a warning, which the runner
  skipped;
- for agy and for edit-level runs, in a git repository: show
  `git status --short -uall` and compare it with that run's
  `<run>/before.txt`. Mark which entries are new, flag every path present
  in both as possibly touched by the agent and mixed with earlier
  changes (for tracked paths the earlier diff is in `<run>/before.diff`;
  untracked paths have no saved content, and in a repository without a
  commit `before.diff` stays empty), and summarize the diff. An unchanged
  status does not show that nothing was written: a change to a file that
  was already changed or untracked, to an ignored file, or outside the
  repository does not show in it. When `notes` says there was no git
  repository (no `.git` above the working directory), or that the work
  tree ignores the working directory, say that there is no snapshot and
  why, also after a continue; in an ignored working directory
  `git status` shows nothing the CLI wrote there, so it is not compared;
- paths into a bundle, mapped back to the originals.

When more than one answered, compare them all: where they agree, where
they differ, and your own position on each point. List every decision a
reviewer would reopen, with how many reviewers reopened it and your own
position after reading the code or document; put each one to the owner,
and dismiss none because it had been decided. Read the code before
agreeing with a claim about it, because an answer from another model is a
claim, not evidence, and check a reviewer's statement about evidence
against the evidence before repeating it.

## Platform

The runner and every command here are bash. The runner needs bash 5 or
later (its clock is `EPOCHREALTIME`), `jq` 1.7 or later (it reads lists
ended by NUL bytes with jq's `--raw-output0`, which jq 1.6, still shipped
by Ubuntu 22.04 and Debian 12, lacks), and `timeout` (with `-k`),
`setsid`, `realpath`, `ps`, `sha256sum` and `awk` on PATH, with a `ps`
that lists the processes with their group and session (procps's does);
when bash is older, jq does not take `--raw-output0`,
`ps -A -o pid=,pgid=,sid=,stat=` does not show the runner's own process,
or a program is missing, it ends `prerequisite_failed` before anything
starts and names what is missing. `timeout` and `realpath` may be GNU's or the Rust coreutils
(uutils). git is asked for OpenCode's project boundary and the before
snapshot; a git that cannot be run, that does not answer within the
preflight limit of one minute, or whose `git rev-parse --local-env-vars`
exits 0 without a list of variable names that includes `GIT_DIR`
(every git lists it), is `prerequisite_failed` as well, and so is a git
that fails in the before snapshot where a `.git` lies above the working
directory. A `git rev-parse --local-env-vars` call that runs and fails
is `prerequisite_failed` for Codex and agy, which ask git only in the
before snapshot, and `usage_error` for OpenCode, which asks git first
for the project boundary, before the run or the continue owns its status
file. The
runner was built and tested on Linux. macOS ships bash 3.2 and no
`setsid`, so it needs bash 5, coreutils and util-linux installed. On
Windows the runner would run in Git Bash, where the `timeout` on PATH
must be Git Bash's copy, not `C:\Windows\System32\timeout.exe`, which is
a different program. Neither macOS nor Git Bash on Windows was checked.
The two OpenCode agent files list POSIX commands (`ls`, `cat`, `grep`,
...), so on Windows OpenCode's bash tool has to run Git Bash; set
`OPENCODE_GIT_BASH_PATH` when OpenCode does not find it.

## Prerequisite

Codex runs model commands in a platform sandbox. Before a Codex run
starts, and before a continue of one, the runner probes it (Codex's
`sandbox` subcommand, running `true`) under the preflight limit. A
missing Codex is found by the runner's own lookup on PATH and ends
`missing_cli`; it is never read off the probe's exit status. When the
probe fails, Codex is not started and the run ends `prerequisite_failed`
with the probe's exit status and the last line of its standard error,
which is in `<run>/codex.probe.err`; when that file cannot be read, the
message says so and names it. Point the user to this section and quote
that file. What the sandbox needs:

- macOS: nothing; Codex uses the built-in Seatbelt framework.
- Windows, native: Codex uses the Windows sandbox. Its preferred
  `elevated` mode needs a one-time administrator-approved setup
  (`/setup-default-sandbox` in interactive Codex); `unelevated` is the
  weaker fallback. Under WSL2 the Linux rules apply.
- Linux and WSL2: `bubblewrap` (`bwrap`) from the distribution. Ubuntu
  24.04 also restricts unprivileged user namespaces through AppArmor,
  so the sandbox fails with
  `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted` until
  the `bwrap-userns-restrict` profile from `apparmor-profiles` is
  installed into `/etc/apparmor.d` and loaded, as the Codex sandbox
  documentation describes.

OpenCode needs no sandbox; the runner checks its version instead and
refuses a major version other than the tested one
(`unsupported_version`). The three aliases need two subscriptions, each
entered once with `opencode auth login`: the Alibaba Model Studio Token
Plan (provider "Alibaba Token Plan", key `ALIBABA_TOKEN_PLAN_API_KEY`)
for `deepseek` and `qwen`, and a Kimi membership (provider "Kimi For
Coding (kimi.ai)", key `KIMI_API_KEY`) on the lowest tier whose benefits
list the 1M-context `k3` for `kimi`. A run without its key ends
`cli_failure` with OpenCode's own error; report it and point the user to
this section. Never enter, read or print a key.
