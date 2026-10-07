---
name: app-external-agents
description: 'Use when the user asks to run Codex, Antigravity (agy, Gemini) or OpenCode with DeepSeek, Kimi or Qwen from this session: a second opinion or review from another model, a question put to it, or a task handed to it. Triggers: "ask codex", "ask agy", "ask gemini", "ask deepseek", "ask kimi", "ask qwen", "ask the chinese models", "ask everyone", "second opinion", "what does codex think", "let codex do it", "run this through agy". Only on request, never on your own initiative.'
argument-hint: '[codex|agy|deepseek|kimi|qwen|all] <what to ask or do>'
user-invocable: true
---

# External agents: Codex, agy and OpenCode

Run the Codex CLI, the Antigravity CLI (`agy`) and OpenCode headlessly on
the user's behalf and relay what they answer. All three CLIs are trusted
and run with the user's own configuration, environment and allow-rules.

OpenCode carries three fixed model aliases. Any other OpenCode model id
works when the user names it in full (`provider/model`).

| Alias | `--model` | Plan behind it |
|---|---|---|
| `deepseek` | `alibaba-token-plan/deepseek-v4-pro-0813` | Alibaba Model Studio Token Plan |
| `kimi` | `kimi-code-plan-global/k3` | Kimi membership, the lowest tier whose benefits list the 1M-context `k3` |
| `qwen` | `alibaba-token-plan/qwen3.8-max` | Alibaba Model Studio Token Plan |

## Levels

| Level | When | Codex flag | agy flag | OpenCode agent |
|---|---|---|---|---|
| Read | default | `-s read-only` | none | `ext-read` from `<skill>/opencode/read-agent.json` |
| Edit | the user asked for changes to files | `-s workspace-write` | `--mode accept-edits` | `ext-edit` from `<skill>/opencode/edit-agent.json` |

`<skill>` is this skill's directory. OpenCode has no sandbox flag: its
permissions are per-agent config, so each run injects one of the two
agent files through the `OPENCODE_CONFIG_CONTENT` environment variable,
which merges with the user's own OpenCode config. The read agent denies
edits, writes outside the project, web access and every shell command
except a short read-only list that its system prompt states, and within
that list it denies output redirection and the `find`, `git` and `rg`
options that write files or run programs. A write shaped to get past
these patterns (a redirection after a pipeline or a `{ }` group) is
stopped only by its instructions. The edit agent allows edits and shell
commands inside the project. Its rule denies the direct `git commit` and
`git push` commands only; a wrapped or scripted commit or push
(`git -c ... commit`, `sh -c '...'`, a script the agent wrote) is
stopped only by its instructions. Neither agent may start OpenCode
subagents (the `task` tool is denied at both levels).

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

Platform: every command below is bash. On Windows it runs in Git Bash,
the shell Claude Code uses there; none of the three CLIs needs WSL.
Coreutils `timeout` and `jq` must be on PATH, and on Windows
`command -v timeout` must resolve to Git Bash's copy, not
`C:\Windows\System32\timeout.exe`, which is a different program. The
`.time` files come from bash's own `time` keyword, so no GNU `time` is
needed. The two OpenCode agent files list POSIX commands (`ls`, `cat`,
`grep`, ...), so on Windows OpenCode's bash tool has to run Git Bash;
set `OPENCODE_GIT_BASH_PATH` when OpenCode does not find it.

## Steps

1. **Choose the CLIs.** The ones the user named: `codex`, `agy`, an
   OpenCode alias (`deepseek`, `kimi`, `qwen`) or a full OpenCode model
   id. "All" or "everyone" means all five. When the user names none, ask
   which to run, as a numbered list (1 codex, 2 agy, 3 deepseek, 4 kimi,
   5 qwen, 6 all), and wait for the answer.
2. **Create a run directory** in the session's scratchpad:
   `<scratchpad>/YYYY-MM-DD-HHMM-<slug>/` (24-hour local time). Below,
   `<run>` is its absolute path. At the edit level each run gets its own
   run directory, with the CLI name or alias in the slug. Each OpenCode
   run's files use its alias as the prefix (`<run>/deepseek.ndjson`); a
   full model id becomes the prefix with `/` replaced by `-`.
3. **Write `<run>/prompt.md`**, one copy in each edit-level run directory.
   The CLI knows nothing about this session, so the prompt stands alone:

   ```
   # Task
   <the goal, in the user's terms>

   # Where to look
   <absolute project path; files, directories or a git range>

   # What to return
   <the shape of the answer: findings with file and line, a decision, a summary of changes>
   ```

   Name files by path, never paste their contents or a diff. At the read
   level, end the prompt with the line
   `Do not modify any files and do not run experiments.`

   agy gets its own copy, `<run>/agy-prompt.md`, which adds the shell
   commands its settings allow. In headless mode agy ends the whole run
   with no answer at the first command outside that list, so it has to
   know the list up front:

   ```
   { cat <run>/prompt.md; printf '\n# Shell commands\nYou may run only these shell commands (matched by word prefix):\n'; jq -r '.permissions.allow[]' ~/.gemini/antigravity-cli/settings.json | sed 's/^/- /'; printf '\nAny other shell command is denied and ends this run with no answer. When a command would have settled a question, say which command and what you expected instead of running it.\n'; } > <run>/agy-prompt.md
   ```
4. **Edit level only:** before each edit-level run, save the starting
   state with `git status --short -uall > <run>/before.txt` and
   `git diff HEAD > <run>/before.diff`. One snapshot per run: when both
   CLIs edit, each run gets its own run directory and its own snapshot.
   When the project directory is not a git repository, say so in the
   report and skip the snapshot.
5. **Start each CLI as its own background shell call**, from the project
   directory. Before each Codex run, at either level, run
   `timeout 1m codex sandbox true 2> <run>/probe.err` from the project
   directory. On exit 0 the run proceeds. On exit 127, do not start Codex
   and report it as missing (the 127 row of the step 6 table). On any
   other non-zero exit, do not start Codex and report the sandbox
   prerequisite (see Prerequisite) together with the contents of
   `<run>/probe.err`. Read level:

   ```
   TIMEFORMAT=%R; { time timeout 30m codex exec --skip-git-repo-check -s read-only - < <run>/prompt.md > <run>/codex.out 2> <run>/codex.err; } 2> <run>/codex.time
   ```

   ```
   TIMEFORMAT=%R; { time timeout 30m agy -p "$(cat <run>/agy-prompt.md)" --output-format stream-json < /dev/null > <run>/agy.ndjson 2> <run>/agy.err; } 2> <run>/agy.time; jq -r 'select(.event=="result") | .result.response // ""' <run>/agy.ndjson > <run>/agy.out
   ```

   agy answers in stream-json mode so its trace is on disk: one JSON
   object per line in `agy.ndjson`. The `result` event holds `response`,
   `status`, `usage`, `duration_seconds`, `num_turns`, `conversation_id`
   and, after a denial, `denied_actions`; the `step_update` events hold
   every tool call, including each shell command as
   `tool_info.parameters.CommandLine`. The `jq` step puts the answer
   alone into `agy.out`, so the rest of this skill reads `agy.out` like
   `codex.out`. When `jq` fails (a line that is not JSON), `agy.out` may
   be empty: read `agy.ndjson` by hand and `agy.err` for the reason. The
   `.time` file holds the wall time in seconds; the braces keep the
   CLI's exit status as the call's exit status.

   OpenCode, read level, one call per alias (all may run at once), with
   `<alias>` and `<model>` from the alias table and `<skill>` this skill's
   directory:

   ```
   TIMEFORMAT=%R; { time OPENCODE_CONFIG_CONTENT="$(cat <skill>/opencode/read-agent.json)" timeout 30m opencode run --agent ext-read --model <model> --format json "$(cat <run>/prompt.md)" < /dev/null > <run>/<alias>.ndjson 2> <run>/<alias>.err; } 2> <run>/<alias>.time; rc=$?; jq -r 'select(.type=="text") | .part.text' <run>/<alias>.ndjson > <run>/<alias>.out; (exit $rc)
   ```

   OpenCode gets the plain `<run>/prompt.md`: its injected agent carries
   the allow list in its own system prompt, so no agy-style copy is
   needed. The prompt is an argv argument, as for agy. `--format json`
   writes one JSON object per line to `<alias>.ndjson`, each with `type`,
   `sessionID` and `part`: `tool_use` events carry the tool, its input
   (`state.input.command` for bash) and `state.status` (`completed` or
   `error`), `text` events carry the answer, `step_finish` events carry
   `tokens` and `cost` for one model turn, and an `error` event means the
   run failed. The `jq` step puts the answer alone into `<alias>.out`.
   The line saves OpenCode's exit status before `jq` and ends with it, so
   the shell call's exit is OpenCode's (or 124 from `timeout`, 127 for a
   missing binary) and step 6 classifies by it.

   Edit level: for Codex, replace `-s read-only` with `-s workspace-write`;
   for agy, add `--mode accept-edits` after the prompt argument; for
   OpenCode, use `<skill>/opencode/edit-agent.json` and `--agent ext-edit`.

   Add `--model <name>` (Codex, agy) or `-c model_reasoning_effort="<value>"`
   (Codex) only when the user names a value; otherwise those two CLIs use
   their own configuration. OpenCode always gets `--model` from the alias
   table or the user's full id, and `--variant <value>` only when the user
   names a reasoning effort. agy has no separate effort flag for this
   purpose: its model ids carry the effort (`gemini-3.1-pro-high`,
   `gemini-3.8-flash-low`; `agy models` lists them), and `--effort`
   conflicts with such an id, so never pass it.
6. **When a run ends, read its `.out` file** and classify the outcome:

   | Exit | stdout | Meaning | Report |
   |---|---|---|---|
   | 0 | an answer | success | the answer |
   | 0 | a refusal or an error text | the task needed more than the level allows | the text, and that the edit level or an allow-rule is needed |
   | 0 | empty or whitespace only | the CLI was denied an action (agy does this) | what it tried, the denied actions, and the last lines of `.err` verbatim, including where it says an allow-rule goes and the rule's shape |

   For agy, "what it tried" is the list of shell commands from the trace,
   and on a denial the last one is the command that was refused:

   ```
   jq -r 'select(.event=="step_update") | .step_update | select(.tool_name=="run_command" and .state=="ACTIVE") | .tool_info.parameters.CommandLine' <run>/agy.ndjson
   jq -c 'select(.event=="result") | .result.denied_actions' <run>/agy.ndjson
   ```

   For OpenCode, a denial does not end the run: the model gets the rule
   text as a tool error and usually still answers. So an answer with one
   or more denied tool calls is reported as the answer plus the denied
   calls, verbatim, and the note that the edit level is needed if the
   task required them; an empty `<alias>.out` means the model stopped
   after a denial without answering. A missing or rejected key and an
   unknown model id end the run with an `error` event and a non-zero
   exit (the "other" row). When the event's message is the generic
   `Unexpected server error` and the trace has no `tool_use` event (the
   run failed before any tool ran), re-run once with
   `--print-logs --log-level ERROR` before `--agent` and quote the reason
   from `<alias>.err`. After a `tool_use` event, report the generic
   message and the last lines of `<alias>.err` instead and let the user
   decide, because a re-run would repeat the task. Denied calls and the
   error:

   ```
   jq -r 'select(.type=="tool_use") | .part | select(.state.status=="error") | "\(.tool): \(.state.input.command // .state.input.filePath // "?") -> \((.state.error // .state.output // "")[0:200])"' <run>/<alias>.ndjson
   jq -r 'select(.type=="error") | .error.name + ": " + .error.data.message' <run>/<alias>.ndjson
   ```
   | 124 | any | timed out after 30 minutes | that it timed out, plus any partial output |
   | 127 | empty | the CLI is not installed or not on PATH | which CLI is missing |
   | other | any | the CLI failed | the last lines of `.err` verbatim |

7. **Report.** One section per run, under the CLI name, or for OpenCode
   under the alias or the full model id. The first line of
   each section is this template, every field filled in, on every run
   including failed ones. A section without it is incomplete:

   ```
   Codex: <model>, effort <effort>. <tokens> tokens, <wall> s. Session <id> (codex exec resume <id>).
   agy: <model> (<--model id | configured default>, requested, not reported). <total> tokens (<in> in, <out> out, <thinking> thinking), <duration> s, <turns> turn(s). Conversation <id> (agy --conversation <id>).
   <alias>: <model id> via opencode (requested, not reported). <total> tokens (<in> in, <out> out, <reasoning> reasoning, <cached> cached), $<cost>, <wall> s, <steps> step(s). Session <id> (opencode run -s <id>).
   ```

   Where each value comes from:

   | Field | Codex | agy | OpenCode |
   |---|---|---|---|
   | model, effort | `grep -m1 '^model: ' <run>/codex.err` and `grep -m1 '^reasoning effort: ' <run>/codex.err` | the `--model` id when one was passed, otherwise `jq -r .model ~/.gemini/antigravity-cli/settings.json`; the effort is part of the name | the `--model` id that was passed |
   | tokens | the last line of `codex.err` when the line before it is `tokens used` | `jq -c 'select(.event=="result") | .result.usage' <run>/agy.ndjson` | the sums below over every `step_finish` event |
   | cost | not reported, omit | not reported, omit | the `cost` sum below; the three aliases always report 0, written as `$0 (plan)` |
   | time | `<run>/codex.time` (wall) | `duration_seconds` from the result event; `<run>/agy.time` when it is missing | `<run>/<alias>.time` (wall) |
   | turns | not reported, omit | `num_turns` from the result event | the count of `step_finish` events, reported as steps |
   | handle | `grep -m1 '^session id: ' <run>/codex.err` | `conversation_id` from the result event | `sessionID` from any event |

   OpenCode sums over turns, and the handle:

   ```
   jq -s '[.[] | select(.type=="step_finish") | .part] | {steps: length, total: (map(.tokens.total)|add), input: (map(.tokens.input)|add), output: (map(.tokens.output)|add), reasoning: (map(.tokens.reasoning)|add), cached: (map(.tokens.cache.read)|add), cost: (map(.cost)|add)}' <run>/<alias>.ndjson
   jq -r '.sessionID' <run>/<alias>.ndjson | head -1
   ```

   A value the files do not contain is written as `unknown`, never left
   out. Filled example:

   ```
   Codex: gpt-6-astra, effort max. 8,834 tokens, 16 s. Session 01a0f65b-... (codex exec resume <id>).
   agy: Gemini 3.1 Pro (High) (configured default, requested, not reported). 12,779 tokens (12,534 in, 245 out, 243 thinking), 5.8 s, 1 turn. Conversation d529e0b1-... (agy --conversation <id>).
   qwen: alibaba-token-plan/qwen3.8-max via opencode (requested, not reported). 18,353 tokens (10,669 in, 112 out, 148 reasoning, 7,424 cached), $0 (plan), 8.5 s, 1 step. Session ses_f07e4e09... (opencode run -s <id>).
   ```

   When more than one answered, compare them all: where they agree, where
   they differ, and your own position on each point.
   Read the code before agreeing with a claim
   about it, because an answer from another model is a claim, not
   evidence. In a git repository, after each edit-level run, show
   `git status --short -uall` and compare it with that run's
   `<run>/before.txt`: mark which entries are new, flag every path present
   in both as possibly touched by the agent and mixed with earlier changes
   (for tracked paths, their earlier diff is in `<run>/before.diff`;
   untracked paths have no saved content, and in a repository without a
   commit `before.diff` stays empty), and summarize the diff.

## Prerequisite

Codex runs model commands in a platform sandbox, and step 5 checks it
with `timeout 1m codex sandbox true` before each Codex run. Exit 127
means Codex itself is missing and is reported as such. On any other
non-zero exit, Codex is not started, the user is pointed to this
section, and the probe's stderr from `<run>/probe.err` is quoted with
it. What the sandbox needs:

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

OpenCode needs no sandbox and no probe; a missing binary is exit 127 from
the run command. The three aliases need two subscriptions, each entered
once with `opencode auth login`: the Alibaba Model Studio Token Plan
(provider "Alibaba Token Plan", key `ALIBABA_TOKEN_PLAN_API_KEY`) for
`deepseek` and `qwen`, and a Kimi membership (provider "Kimi For Coding
(kimi.ai)", key `KIMI_API_KEY`) on the lowest tier whose benefits list
the 1M-context `k3` for `kimi`. A run without its key fails with an
`error` event; report it and point the user to this section. Never
enter, read or print a key.
