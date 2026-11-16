#!/usr/bin/env bash
# Tests of scripts/ext-run. Every CLI the runner meets here is tests/fake-cli;
# the real codex, agy and opencode are kept out three ways: the suite's PATH
# holds only linked utilities and sentinels, every run checks its PATH first,
# and a sentinel that is reached ends the suite with status 3.
#
# Run: bash tests/ext-run.test.sh   (the last line reads "N run, 0 failed")
# Status 2: the frame could not be built safely, so no case ran.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL="$(cd "$HERE/.." && pwd -P)"
SUITE_T0="$(date +%s)"

# ---------------------------------------------------------------------------
# Frame functions: used while the frame is built and at teardown.

alive() { # pid: true when ps shows a state that does not begin with Z
    local s
    case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
    s="$(ps -o stat= -p "$1" 2>/dev/null)"
    s="${s//[[:space:]]/}"
    [ -n "$s" ] && [ "${s#Z}" = "$s" ]
}

ours() { # pid age: alive and started within the suite's age, so not a reused pid
    local e
    [ "$1" != "$$" ] || return 1
    alive "$1" || return 1
    e="$(ps -o etimes= -p "$1" 2>/dev/null)"
    e="${e//[[:space:]]/}"
    [ -n "$e" ] && [ "$e" -le "$2" ]
}

group_ours() { # pgid age own-pgid: a live group, not the suite's, whose members all started within the suite's age
    case "$1" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
    [ "$1" != "$3" ] || return 1
    ps -e -o pgid=,etimes= | awk -v g="$1" -v a="$2" \
        '$1 == g { n++; if ($2 > a) old++ } END { exit !(n > 0 && old == 0) }'
}

teardown() { # the suite's one EXIT trap; runs whatever failed
    local st=$? f p g age own live=() n any
    trap - EXIT
    chmod -R u+w "$ROOT" 2>/dev/null
    age=$(($(date +%s) - SUITE_T0 + 1))
    own="$(ps -o pgid= -p "$$" 2>/dev/null)"
    own="${own//[[:space:]]/}"
    for p in "${ALL_BG[@]}"; do
        if ours "$p" "$age"; then
            kill -TERM "$p" 2>/dev/null
            live+=("$p")
        fi
    done
    n=0
    while [ "${#live[@]}" -gt 0 ] && [ "$n" -lt 20 ]; do
        any=0
        for p in "${live[@]}"; do if alive "$p"; then any=1; fi; done
        [ "$any" = 1 ] || break
        sleep 0.1
        n=$((n + 1))
    done
    for p in "${live[@]}"; do if ours "$p" "$age"; then kill -KILL "$p" 2>/dev/null; fi; done
    for f in "$ROOT"/cases/*/calls/*/pgid "$ROOT"/cases/*/calls/sandbox.pgid "$ROOT"/cases/*/calls/version.pgid; do
        [ -f "$f" ] || continue
        g="$(< "$f")"
        g="${g//[[:space:]]/}"
        if group_ours "$g" "$age" "$own"; then kill -KILL -- "-$g" 2>/dev/null; fi
    done
    for f in "$ROOT"/cases/*/calls/*/pid "$ROOT"/cases/*/calls/*/child \
        "$ROOT"/cases/*/calls/sandbox.pid "$ROOT"/cases/*/calls/version.pid; do
        [ -f "$f" ] || continue
        p="$(< "$f")"
        p="${p//[[:space:]]/}"
        if ours "$p" "$age"; then kill -KILL "$p" 2>/dev/null; fi
    done
    if [ -s "$SENTINEL_LOG" ]; then
        printf 'SENTINEL REACHED\n' >&2
        cat "$SENTINEL_LOG" >&2
        st=3
    fi
    # assert.sh's own directory; finish removes it too, but a stop before finish would leave it.
    # It goes first: removing ROOT removes the linked rm.
    if [ -n "${TMPROOT:-}" ]; then rm -rf "$TMPROOT"; fi
    rm -rf "$ROOT"
    exit "$st"
}

clean_env() { # drops what could point git or the runner at the owner's setup
    local v vars
    unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_TEMPLATE_DIR \
        GIT_CEILING_DIRECTORIES XDG_CONFIG_HOME XDG_DATA_HOME CODEX_HOME OPENCODE_CONFIG_CONTENT \
        OPENCODE_DISABLE_CLAUDE_CODE_PROMPT OPENCODE_DISABLE_CLAUDE_CODE_SKILLS \
        EXT_RUN_GRACE EXT_RUN_KILL_WAIT EXT_RUN_PREFLIGHT_LIMIT EXT_RUN_POLL EXT_RUN_START_WAIT \
        EXT_PATH EXT_CWD PRE_LIMIT
    if ! vars="$(git rev-parse --local-env-vars)"; then
        printf 'ext-run.test: git rev-parse --local-env-vars failed\n' >&2
        exit 2
    fi
    for v in $vars; do unset "$v"; done
    EXT_VARS=()
}

# ---------------------------------------------------------------------------
# Step 1: the root, a physical path under a fixed parent, and a throwaway HOME.

ROOT="$(cd "$(mktemp -d /tmp/ext-run-test.XXXXXX)" && pwd -P)"
case "${ROOT##*/}" in
    ext-run-test.??????) ;;
    *)
        printf 'ext-run.test: could not make the suite root under /tmp\n' >&2
        exit 2
        ;;
esac
BIN_ROOT="$ROOT/bin"
SENTINEL_LOG="$ROOT/sentinel.log"
TROUBLE_LOG="$ROOT/trouble.log"
export ROOT BIN_ROOT SKILL SENTINEL_LOG TROUBLE_LOG
ALL_BG=()
# The teardown (step 6) is installed as soon as the root exists, so that a
# stop in steps 1 to 5 removes the root too.
trap teardown EXIT
if ! mkdir "$ROOT/home" "$ROOT/tpl" "$ROOT/cases"; then exit 2; fi
export HOME="$ROOT/home"

# Step 2: no git command has run yet; the first one runs inside clean_env.
clean_env
# shellcheck source=/dev/null
source "$HERE/../../../scripts/tests/assert.sh" || exit 2

# Failures recorded in a subshell, such as $(argv ...), are also written to a
# file so that the count reaches finish.
CASE_NAME=frame
_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: [%s] %s\n' "$CASE_NAME" "$1" >&2
    if [ "$BASH_SUBSHELL" -gt 0 ]; then printf '%s\n' "$1" >> "$ROOT/subshell-fails"; fi
}

# Step 3: every program the runner, the fake and the suite call, linked by its
# own name; and the sentinels.
UTILS=(bash jq git timeout setsid realpath mktemp date cat rm rmdir mv cp mkdir sleep sed awk
    grep sort wc head tail tr dirname basename env ln chmod touch ps id cmp sha256sum cut ls script)
if ! mkdir "$BIN_ROOT" "$BIN_ROOT/utils" "$BIN_ROOT/sentinels"; then exit 2; fi
for u in "${UTILS[@]}"; do
    p="$(type -P "$u")"
    if [ -z "$p" ] || ! ln -s "$p" "$BIN_ROOT/utils/$u"; then
        printf 'ext-run.test: cannot link %s\n' "$u" >&2
        exit 2
    fi
done
for n in codex agy opencode; do
    if ! printf '#!%s\nprintf "%%s\\n" %s >> %q\nexit 97\n' "$(type -P bash)" "$n" "$SENTINEL_LOG" \
        > "$BIN_ROOT/sentinels/$n" || ! chmod +x "$BIN_ROOT/sentinels/$n"; then
        printf 'ext-run.test: cannot write the sentinel %s\n' "$n" >&2
        exit 2
    fi
done

# Step 4: from here on the suite itself cannot find a real CLI either.
export PATH="$BIN_ROOT/utils:$BIN_ROOT/sentinels"
hash -r

# Step 5: the guard.
if (cd "$ROOT" && git rev-parse --is-inside-work-tree) > /dev/null 2>&1; then
    printf 'ext-run.test: the suite root %s lies in a git repository\n' "$ROOT" >&2
    exit 2
fi
if [ "$(cd "$ROOT" && git config --type=bool --get commit.gpgsign)" = true ]; then
    printf 'ext-run.test: a system-wide commit.gpgsign is set; the suite will not override it\n' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Helpers used by every case.

assert_ne() { # actual unexpected msg
    if [ "$1" != "$2" ]; then _pass; else _fail "$3 (got '$1')"; fi
}

assert_ends() { # haystack suffix msg
    case "$1" in
        *"$2") _pass ;;
        *) _fail "$3 (expected to end with '$2', got '$1')" ;;
    esac
}

assert_begins() { # haystack prefix msg
    case "$1" in
        "$2"*) _pass ;;
        *) _fail "$3 (expected to begin with '$2', got '$1')" ;;
    esac
}

fixture_repo() { # dir: a repository with one commit of README.md
    local d="$1"
    if ! { mkdir -p "$d" &&
        git init -q --template="$ROOT/tpl" "$d" &&
        git -C "$d" config user.name Fixture &&
        git -C "$d" config user.email fixture@example.invalid &&
        git -C "$d" config core.hooksPath "$ROOT/tpl" &&
        printf 'fixture\n' > "$d/README.md" &&
        git -C "$d" add README.md &&
        git -C "$d" commit -q -m fixture; }; then
        printf 'ext-run.test: fixture_repo %s failed\n' "$d" >&2
        exit 2
    fi
}

make_run() { # dir: a run directory as new_case makes it
    mkdir "$1" && printf 'PROMPT' > "$1/prompt.md"
}

which_on() { # path name: prints the file the name resolves to (its directory canonical); 1 when none, 2 on a bad PATH
    local IFS=: d c dirs
    read -r -a dirs <<< "$1"
    for d in "${dirs[@]}"; do
        case "$d" in
            /*) ;;
            *)
                printf 'ext-run.test: PATH %s has an empty or relative element\n' "$1" >&2
                return 2
                ;;
        esac
        if [ -f "$d/$2" ] && [ -x "$d/$2" ]; then
            c="$(cd "$d" && pwd -P)" || return 2
            printf '%s\n' "$c/$2"
            return 0
        fi
    done
    return 1
}

check_path() { # path: stops the suite when a CLI name resolves outside the fakes and the sentinels
    local n p r
    case "$1" in
        '' | *:) printf 'ext-run.test: PATH %s has an empty element\n' "$1" >&2; exit 2 ;;
    esac
    for n in codex agy opencode; do
        p="$(which_on "$1" "$n")"
        r=$?
        [ "$r" != 2 ] || exit 2
        [ "$r" = 0 ] || continue
        case "${p%/*}" in
            "$CASE/bin" | "$BIN_ROOT/sentinels") ;;
            *)
                printf 'ext-run.test: on PATH %s, %s resolves to %s\n' "$1" "$n" "$p" >&2
                exit 2
                ;;
        esac
    done
}

check_fakes() { # stops the suite unless the three names resolve to the fakes on the default PATH
    local n p
    for n in codex agy opencode; do
        p="$(which_on "$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels" "$n")"
        if [ "${p%/*}" != "$CASE/bin" ]; then
            printf 'ext-run.test: %s does not resolve to its fake (%s)\n' "$n" "${p:-nowhere}" >&2
            exit 2
        fi
    done
}

new_case() { # name
    unset EXT_PATH EXT_CWD PRE_LIMIT
    EXT_VARS=()
    BGN=0 BG=''
    BG_PID=() BG_PREFIX=()
    CASE_N=$((${CASE_N:-0} + 1))
    CASE_NAME="$1"
    CASE="$ROOT/cases/$(printf '%03d' "$CASE_N")-$1"
    export CASE HOME="$CASE/home" SCN="$CASE/scn" CALLS="$CASE/calls"
    WORK="$CASE/work"
    RUN="$CASE/run"
    if ! mkdir "$CASE" "$HOME" "$SCN" "$CALLS" "$CASE/bin" "$CASE/kept" "$CASE/skill" "$CASE/ok"; then
        printf 'ext-run.test: cannot make the case %s\n' "$1" >&2
        exit 2
    fi
    fixture_repo "$WORK"
    make_run "$RUN" || exit 2
    for n in codex agy opencode; do
        cp "$SKILL/tests/fake-cli" "$CASE/bin/$n" || exit 2
        chmod +x "$CASE/bin/$n" || exit 2
    done
    for d in scripts opencode prompts; do
        if [ -d "$SKILL/$d" ]; then cp -R "$SKILL/$d" "$CASE/skill/" || exit 2; fi
    done
    printf '%s\n' "OC_ASK_REJECT_TEXT='ASK-REFUSED'" 'AGY_EXTRA_ARGS=(--agy-x)' 'CODEX_EXTRA_ARGS=(--codex-x)' \
        >> "$CASE/skill/scripts/ext-run.conf" || exit 2
    mkdir -p "$HOME/.gemini/antigravity-cli" || exit 2
    jq -cn --arg ok "$CASE/ok" \
        '{model: "Fixture Default", permissions: {allow: ["command(cat)", "command(grep)", "read_file(\($ok))"]}}' \
        > "$HOME/.gemini/antigravity-cli/settings.json" || exit 2
    if [ -n "${EXT_TEST_BREAK:-}" ]; then rm -f "$CASE/bin/$EXT_TEST_BREAK"; fi
    check_fakes
}

conf_set() { # assignment: one more line in the case's ext-run.conf
    printf '%s\n' "$1" >> "$CASE/skill/scripts/ext-run.conf"
}

text_line() { # text: the text and a newline, nothing when empty
    if [ -n "$1" ]; then printf '%s\n' "$1"; fi
}

play() { # key k [options]: writes the scenario $SCN/<key>.<k>/ that fake-cli plays
    local d="$SCN/$1.$2" opt
    shift 2
    mkdir -p "$d" || return 1
    while [ $# -gt 0 ]; do
        opt="$1"
        case "$opt" in
            --stdout | --stdout-file | --stdout-early | --stderr | --stderr-file | --exit | --sleep | --child | --then-version)
                if [ $# -lt 2 ]; then
                    _fail "play: $opt needs a value"
                    return 1
                fi
                ;;
        esac
        case "$opt" in
            --stdout) text_line "$2" > "$d/stdout" ;;
            --stdout-file) cp "$2" "$d/stdout" ;;
            --stdout-early) text_line "$2" > "$d/stdout-early" ;;
            --stderr) text_line "$2" > "$d/stderr" ;;
            --stderr-file) cp "$2" "$d/stderr" ;;
            --exit) printf '%s\n' "$2" > "$d/exit" ;;
            --sleep) printf '%s\n' "$2" > "$d/sleep" ;;
            --child) printf '%s\n' "$2" > "$d/child" ;;
            --then-version) printf '%s\n' "$2" > "$d/then-version" ;;
            --stderr-held) : > "$d/stderr-held" ;;
            --hold) : > "$d/hold" ;;
            --ignore-term) : > "$d/ignore-term" ;;
            *)
                _fail "play: unknown option $opt"
                return 1
                ;;
        esac
        case "$opt" in --stderr-held | --hold | --ignore-term) shift ;; *) shift 2 ;; esac
    done
}

release() { # key k
    if [ -d "$SCN/$1.$2" ]; then : > "$SCN/$1.$2/release"; else _fail "release: no scenario $1.$2"; fi
}

release_stderr() { # key k
    if [ -d "$SCN/$1.$2" ]; then : > "$SCN/$1.$2/release-stderr"; else _fail "release_stderr: no scenario $1.$2"; fi
}

ext_prefix() { # args...: PREFIX from the --cli value, derived as the runner derives it
    local cli=""
    while [ $# -gt 0 ]; do
        if [ "$1" = --cli ] && [ $# -ge 2 ]; then
            cli="$2"
            break
        fi
        shift
    done
    case "$cli" in
        codex | agy | deepseek | kimi | qwen) PREFIX="$cli" ;;
        */*) PREFIX="${cli//\//-}" ;;
        *) PREFIX="" ;;
    esac
}

ext_env() { # path: the runner's environment, exported in the current (sub)shell
    local kv
    export PATH="$1" EXT_RUN_GRACE=1s EXT_RUN_KILL_WAIT=2s EXT_RUN_POLL=0.1 EXT_RUN_START_WAIT=5 \
        EXT_RUN_PREFLIGHT_LIMIT="${PRE_LIMIT:-10s}"
    for kv in "${EXT_VARS[@]}"; do export "${kv?}"; done
}

ext() { # args...: runs the case's runner in the foreground; sets rc, OUT, ERR and PREFIX
    local path="${EXT_PATH:-$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels}"
    check_path "$path"
    ext_prefix "$@"
    OUT="$({ cd "${EXT_CWD:-$WORK}" && ext_env "$path" &&
        exec "$BIN_ROOT/utils/timeout" -k 2s 60s "$CASE/skill/scripts/ext-run" "$@"; } \
        < /dev/null 2> "$CASE/ext.err")"
    rc=$?
    ERR="$(< "$CASE/ext.err")"
    case "$rc" in 124 | 137) _fail "the runner did not end within 60 s: ext $*" ;; esac
}

ext_bg() { # args...: the runner in the background, its pid the job's; sets BG, BGN and PREFIX
    local path="${EXT_PATH:-$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels}"
    check_path "$path"
    ext_prefix "$@"
    BGN=$((BGN + 1))
    (
        cd "${EXT_CWD:-$WORK}" || exit 125
        ext_env "$path"
        exec "$CASE/skill/scripts/ext-run" "$@"
    ) < /dev/null > "$CASE/bg.$BGN.out" 2> "$CASE/bg.$BGN.err" &
    BG=$!
    BG_PID[BGN]="$BG"
    BG_PREFIX[BGN]="$PREFIX"
    ALL_BG+=("$BG")
}

ext_wait() { # [n]: waits at most 60 s for job n (the last by default); sets rc, OUT, ERR and PREFIX
    local n="${1:-$BGN}" pid i=0 late=0
    pid="${BG_PID[n]:-}"
    if [ -z "$pid" ]; then
        _fail "ext_wait: no job $n"
        rc=255
        return 1
    fi
    # The shell reports a job that a signal ended at the first command after
    # it reaped the job; the loop and the wait share one redirection so that
    # report does not reach the suite's output (the cases check the status).
    {
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            late=1
            kill -KILL "$pid"
            wait "$pid"
            rc=255
        else
            wait "$pid"
            rc=$?
        fi
    } 2>/dev/null
    if [ "$late" = 1 ]; then _fail "ext_wait: job $n did not end within 60 s"; fi
    OUT="$(< "$CASE/bg.$n.out")"
    ERR="$(< "$CASE/bg.$n.err")"
    PREFIX="${BG_PREFIX[n]}"
}

ext_tty() { # args...: ext with standard error on a terminal; sets rc and OUT (all the terminal got)
    local path="${EXT_PATH:-$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels}" cmd q a
    check_path "$path"
    ext_prefix "$@"
    printf -v cmd '%q' "$CASE/skill/scripts/ext-run"
    for a in "$@"; do
        printf -v q '%q' "$a"
        cmd+=" $q"
    done
    OUT="$({ cd "${EXT_CWD:-$WORK}" && ext_env "$path" && export SHELL="$BIN_ROOT/utils/bash" &&
        exec "$BIN_ROOT/utils/timeout" -k 2s 60s "$BIN_ROOT/utils/script" -q -e -c "$cmd" /dev/null; } \
        < /dev/null 2>&1)"
    rc=$?
    case "$rc" in 124 | 137) _fail "the runner did not end within 60 s: ext_tty $*" ;; esac
}

wait_for() { # path [tenths]
    local n=0 max="${2:-100}"
    until [ -e "$1" ]; do
        if [ "$n" -ge "$max" ]; then
            _fail "wait_for: $1 did not appear"
            return 1
        fi
        sleep 0.1
        n=$((n + 1))
    done
}

st() { jq -r "$1" "$RUN/$PREFIX.status"; }
stj() { jq -cS "$1" "$RUN/$PREFIX.status"; }

wait_st() { # filter value [tenths]
    local n=0 max="${3:-100}"
    until [ "$(jq -r "$1" "$RUN/$PREFIX.status" 2>/dev/null)" = "$2" ]; do
        if [ "$n" -ge "$max" ]; then
            _fail "wait_st: $1 did not become $2"
            return 1
        fi
        sleep 0.1
        n=$((n + 1))
    done
}

ncalls() { # key: the number of model invocations recorded for it
    local d rest n=0
    for d in "$CALLS/$1".*; do
        [ -d "$d" ] || continue
        rest="${d#"$CALLS/$1".}"
        case "$rest" in '' | *[!0-9]*) continue ;; esac
        n=$((n + 1))
    done
    printf '%s\n' "$n"
}

argv() { # key k: that invocation's arguments as one compact JSON array
    if [ ! -f "$CALLS/$1.$2/argv.json" ]; then
        _fail "argv: $1.$2 was not recorded"
        return 1
    fi
    jq -c . "$CALLS/$1.$2/argv.json"
}

callf() { # key k file: one file of that invocation's record
    if [ ! -d "$CALLS/$1.$2" ]; then
        _fail "callf: $1.$2 was not recorded"
        return 1
    fi
    cat "$CALLS/$1.$2/$3" 2>/dev/null
}

dead_pid() { # the pid of a child that has ended and been reaped
    local p
    true &
    p=$!
    wait "$p"
    printf '%s\n' "$p"
}

keep() { cp -p "$1" "$CASE/kept/${1##*/}"; }

unchanged() { # file label
    if cmp -s "$1" "$CASE/kept/${1##*/}"; then _pass; else _fail "$2: ${1##*/} changed"; fi
}

sum() { # file: its SHA-256
    local s
    s="$(sha256sum < "$1")" || return 1
    printf '%s\n' "${s%% *}"
}

codex_err() { # uuid [last lines...]: a Codex standard error in the saved shape
    local u="$1"
    shift
    printf '%s\n' \
        '2026-11-14T10:58:38.263448Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed' \
        '2026-11-14T10:58:38.264282Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed' \
        'OpenAI Codex v0.167.2' '--------' "workdir: $WORK" 'model: gpt-6-astra' 'provider: openai' \
        'approval: never' 'sandbox: read-only' 'reasoning effort: max' 'reasoning summaries: none' \
        "session id: $u" '--------' user PROMPT "$@"
}

# OpenCode's error text for a call a permission rule denied, and agy's denied
# actions, in the saved shapes.
RULE_TEXT='The user has specified a rule which prevents you from using this specific tool call.'
DENIED_JSON='[{"action":"read_file","display_name":"ReadFile"}]'

# One agy trace line each, in the shapes of the saved traces.
agy_init() { # cid [model]: the first event; agy writes the model only when --model was passed
    if [ $# -ge 2 ]; then
        jq -cn --arg c "$1" --arg m "$2" '{event: "init", conversation_id: $c, init: {model: $m}}'
    else
        jq -cn --arg c "$1" '{event: "init", conversation_id: $c}'
    fi
}

agy_cmd() { # cid command: a shell command step
    jq -cn --arg c "$1" --arg cmd "$2" '{event: "step_update", step_update: {conversation_id: $c,
        tool_name: "run_command", state: "ACTIVE", tool_info: {parameters: {CommandLine: $cmd}}}}'
}

agy_result() { # cid status response [denied-json [total input output thinking]]: the result event
    jq -cn --arg c "$1" --arg s "$2" --arg r "$3" --argjson d "${4:-null}" --argjson t "${5:-9}" \
        --argjson i "${6:-4}" --argjson o "${7:-3}" --argjson th "${8:-2}" '{event: "result",
        result: {conversation_id: $c, status: $s, response: $r, denied_actions: $d, num_turns: 1,
            duration_seconds: 1.5,
            usage: {input_tokens: $i, output_tokens: $o, thinking_tokens: $th, total_tokens: $t}}}'
}

# One OpenCode trace line each, in the shapes of the saved traces.
oc_start() { # sid
    jq -cn --arg s "$1" '{type: "step_start", sessionID: $s, part: {}}'
}

oc_tool() { # tool input-key sid value [completed|error] [error text]: a tool_use event; error is null when no text is given
    jq -cn --arg tool "$1" --arg k "$2" --arg s "$3" --arg v "$4" --arg st "${5:-completed}" \
        --arg e "${6-}" --argjson has "$#" '{type: "tool_use", sessionID: $s, part: {tool: $tool,
        state: {status: $st, input: {($k): $v}, error: (if $has >= 6 then $e else null end)}}}'
}

oc_bash() { oc_tool bash command "$@"; } # sid command [completed|error] [error text]
oc_read() { oc_tool read filePath "$@"; } # sid path [completed|error] [error text]

oc_text() { # sid text
    jq -cn --arg s "$1" --arg t "$2" '{type: "text", sessionID: $s, part: {text: $t}}'
}

oc_finish() { # sid reason [total input output reasoning cached cost]
    jq -cn --arg s "$1" --arg r "$2" --argjson t "${3:-10}" --argjson i "${4:-4}" --argjson o "${5:-3}" \
        --argjson rs "${6:-2}" --argjson cr "${7:-1}" --argjson c "${8:-0.5}" '{type: "step_finish",
        sessionID: $s, part: {reason: $r,
            tokens: {total: $t, input: $i, output: $o, reasoning: $rs, cache: {read: $cr, write: 0}}, cost: $c}}'
}

oc_error() { # sid name message
    jq -cn --arg s "$1" --arg n "$2" --arg m "$3" '{type: "error", sessionID: $s, error: {name: $n, data: {message: $m}}}'
}

# Whole traces, used by name in later cases.
t_oc_only() { # sid [text]: one step that writes the text (ONLY by default) and stops
    oc_start "$1"
    oc_text "$1" "${2-ONLY}"
    oc_finish "$1" stop
}

t_oc_empty_final() { # sid: a note in a tool-calling step, then a final step without text
    oc_start "$1"
    oc_bash "$1" ls
    oc_text "$1" NOTE
    oc_finish "$1" tool-calls
    oc_start "$1"
    oc_finish "$1" stop
}

t_agy_answer() { # cid [text]: a command, then a result that answers with the text (ANSWER by default)
    agy_init "$1"
    agy_cmd "$1" ls
    agy_result "$1" SUCCESS "${2-ANSWER}"
}

t_agy_empty() { # cid
    agy_init "$1"
    agy_result "$1" SUCCESS ''
}

t_agy_denied() { # cid: an empty response with a denied action
    agy_init "$1"
    agy_result "$1" SUCCESS '' "$DENIED_JSON"
}

answering() { # key k: an answering scenario for whatever kind the key is
    case "$1" in
        codex) play codex "$2" --stdout A --stderr "$(codex_err U1)" ;;
        agy) play agy "$2" --stdout "$(t_agy_answer C A)" ;;
        *) play "$1" "$2" --stdout "$(t_oc_only S A)" ;;
    esac
}

mk_tool() { # path: an executable bash script whose body is standard input
    mkdir -p "${1%/*}" && { printf '#!%s\n' "$BIN_ROOT/utils/bash" && cat; } > "$1" && chmod +x "$1"
}

took_under() { # start seconds msg: less than that many seconds passed since start (an $EPOCHREALTIME)
    local s="${1//[!0-9]/}" e="${EPOCHREALTIME//[!0-9]/}"
    e=$(((e - s) / 1000000))
    if [ "$e" -lt "$2" ]; then _pass; else _fail "$3 (took $e s)"; fi
}

has_cr() { # text: yes when it holds a carriage return
    case "$1" in *$'\r'*) echo yes ;; *) echo no ;; esac
}

# Codex's usage-limit message has a typographic apostrophe, as here.
# shellcheck disable=SC1112
ul_line='ERROR: You’ve hit your usage limit. Upgrade to Pro, or try again at 2:40 PM.'

# ---------------------------------------------------------------------------
# The frame's own cases.

# a broken fake setup stops the suite before any case runs, and no sentinel was reached on the way
if [ -z "${EXT_TEST_BREAK:-}" ]; then
    out="$(EXT_TEST_BREAK=agy bash "$0" 2>&1)"
    brc=$?
    assert_eq "$brc" 2 "a missing fake stops the suite"
    assert_eq "$(printf '%s\n' "$out" | grep -c -E 'FAIL|SENTINEL REACHED')" 0 "no case ran and no sentinel was reached"
fi
# new_case removes "$CASE/bin/$EXT_TEST_BREAK" before check_fakes when that variable is set. The inner
# run has its own root and sentinel log, and its teardown turns a reached sentinel into status 3.

# clean_env drops the overrides a caller could have left in the environment
# shellcheck disable=SC2034  # the three are read by clean_env's caller check below
(
    EXT_PATH=/x
    EXT_CWD=/y
    PRE_LIMIT=9
    clean_env
    [ -z "${EXT_PATH:-}${EXT_CWD:-}${PRE_LIMIT:-}" ]
)
assert_eq "$?" 0 "clean_env unsets EXT_PATH, EXT_CWD and PRE_LIMIT"

# ext refuses a PATH on which a CLI name resolves outside the fakes
new_case path-guard
mkdir "$CASE/real"
printf '#!/bin/sh\n: > "%s/real-ran"\n' "$CASE" > "$CASE/real/codex"
chmod +x "$CASE/real/codex"
EXT_PATH="$CASE/real:$CASE/bin:$BIN_ROOT/utils"
(ext run --cli codex --run-dir "$RUN") > /dev/null 2>&1
assert_eq "$?" 2 "the suite stops on such a PATH"
assert_eq "$([ -e "$CASE/real-ran" ] && echo ran || echo no)" no "the planted program did not run"

# an inherited git environment does not reach a fixture
CASE_NAME=frame
decoy="$ROOT/decoy"
fixture_repo "$decoy"
before="$(git -C "$decoy" rev-list --count HEAD)"
(
    export GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy"
    clean_env
    fixture_repo "$ROOT/other"
)
assert_eq "$(git -C "$decoy" rev-list --count HEAD)" "$before" "the decoy repository is untouched"
assert_file "$ROOT/other/.git" "the fixture went to its own directory"
assert_eq "$(git -C "$ROOT/other" show --format= --name-only HEAD)" "README.md" "the fixture commits README.md"

# a zombie is not alive, and dead_pid names a process that is gone
# shellcheck disable=SC2016  # the script text is for the child shell to expand
printf 'until [ -e "$1" ]; do sleep 0.05; done\n' > "$ROOT/wait-go.sh"
# shellcheck disable=SC2016
bash -c 'bash "$2" "$1.go" & echo $! > "$1"; exec sleep 30' _ "$ROOT/z.pid" "$ROOT/wait-go.sh" &
zp=$!
n=0 # the child may end only once its parent has become sleep, which never reaps it
until { [ -s "$ROOT/z.pid" ] && [ "$(ps -o comm= -p "$zp")" = sleep ]; } || [ "$n" -ge 50 ]; do
    sleep 0.1
    n=$((n + 1))
done
z="$(cat "$ROOT/z.pid")"
: > "$ROOT/z.pid.go"
n=0
until [ "$(ps -o stat= -p "$z" | cut -c1)" = Z ] || [ "$n" -ge 50 ]; do
    sleep 0.1
    n=$((n + 1))
done
assert_eq "$(ps -o stat= -p "$z" | cut -c1)" Z "the child is a zombie"
assert_eq "$(alive "$z" && echo yes || echo no)" no "alive does not count a zombie"
kill "$zp"
wait "$zp" 2>/dev/null
assert_eq "$(alive "$(dead_pid)" && echo yes || echo no)" no "dead_pid is not alive"

# concurrent invocations of the fake never share a number: uutils mkdir 0.10 alone
# reported success to two racing callers in about one round of eight in five
new_case fake-numbering
counts=''
for r in 1 2 3 4 5 6 7 8 9 10; do
    pids=()
    for i in 1 2 3 4 5 6 7 8; do
        (PATH="$CASE/bin:$BIN_ROOT/utils" opencode run --model "r$r/x" < /dev/null > /dev/null 2>&1) &
        pids+=("$!")
    done
    wait "${pids[@]}"
    counts+="$(ncalls "r$r-x") "
done
assert_eq "$counts" "8 8 8 8 8 8 8 8 8 8 " "eight invocations at once get eight numbers, ten rounds"

# ---------------------------------------------------------------------------
# The runner's front door.

new_case unknown-cli
ext run --cli nope --run-dir "$RUN"
assert_eq "$rc" 64 "unknown-cli: rc"
assert_eq "$OUT" "ext-run: usage_error (unknown cli: nope); status: none" "unknown-cli: summary"

new_case default-action
ext --cli codex --run-dir "$RUN"
assert_ne "$rc" 64 "default-action: rc"
assert_file "$RUN/codex.status" "default-action: the action defaulted to run and wrote a status"

new_case bad-durations
for a in "--limit 0" "--limit 0.0" "--limit ten" "--limit -5" "--resume-limit 5x"; do
    read -r opt val <<< "$a"
    ext run --cli codex --run-dir "$RUN" "$opt" "$val"
    assert_eq "$rc" 64 "bad-durations $a: rc"
    assert_contains "$ERR" "bad duration" "bad-durations $a: message"
done
assert_eq "$(ncalls codex)" 0 "bad-durations: no call"
assert_nofile "$RUN/codex.status" "bad-durations: no status"

for v in 1.5 2m 1h 1d; do
    new_case "good-durations-$v"
    ext run --cli codex --run-dir "$RUN" --limit "$v"
    assert_ne "$rc" 64 "good-durations $v: rc"
    assert_eq "$(st .limit)" "$v" "good-durations $v: the limit as given"
done

new_case agy-effort
ext run --cli agy --run-dir "$RUN" --effort high
assert_eq "$rc" 64 "agy-effort: rc"
assert_contains "$ERR" "model ids carry the effort" "agy-effort: message"

new_case alias-model
ext run --cli qwen --run-dir "$RUN" --model a/b
assert_eq "$rc" 64 "alias-model qwen: rc"
assert_contains "$ERR" "takes no --model" "alias-model qwen: message"
ext run --cli x/y --run-dir "$RUN" --model a/b
assert_eq "$rc" 64 "alias-model x/y: rc"
assert_contains "$ERR" "takes no --model" "alias-model x/y: message"

new_case no-prompt
rm "$RUN/prompt.md"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "no-prompt: rc"
assert_contains "$ERR" "prompt.md is missing or empty" "no-prompt: message"
assert_eq "$(ncalls codex)" 0 "no-prompt: no call"
assert_nofile "$RUN/codex.status" "no-prompt: no status"

new_case empty-prompt
: > "$RUN/prompt.md"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "empty-prompt: rc"
assert_contains "$ERR" "prompt.md is missing or empty" "empty-prompt: message"
assert_eq "$(ncalls codex)" 0 "empty-prompt: no call"
assert_nofile "$RUN/codex.status" "empty-prompt: no status"

new_case no-run-dir
ext run --cli codex --run-dir "$CASE/absent"
assert_eq "$rc" 64 "no-run-dir: rc"

new_case relative-run-dir
EXT_CWD="$CASE"
ext run --cli codex --run-dir run
assert_ne "$rc" 64 "relative-run-dir: rc"
assert_ends "$OUT" "status: $RUN/codex.status" "relative-run-dir: the absolute status path"

new_case missing-helper
mkdir "$CASE/nojq"
for f in "$BIN_ROOT/utils"/*; do
    if [ "${f##*/}" != jq ]; then ln -s "$f" "$CASE/nojq/${f##*/}"; fi
done
EXT_PATH="$CASE/nojq:$CASE/bin"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "missing-helper: rc"
assert_contains "$OUT" "prerequisite_failed" "missing-helper: outcome"
assert_contains "$OUT" "status: none" "missing-helper: no status named"
assert_contains "$ERR" "jq" "missing-helper: jq named"
assert_nofile "$RUN/codex.status" "missing-helper: no status"

new_case missing-conf
rm "$CASE/skill/scripts/ext-run.conf"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "missing-conf: rc"
assert_contains "$ERR" "ext-run.conf" "missing-conf: the settings file named"
assert_nofile "$RUN/codex.status" "missing-conf: no status"

new_case missing-cli
rm "$CASE/bin/codex"
EXT_PATH="$CASE/bin:$BIN_ROOT/utils"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 127 "missing-cli: rc"
assert_eq "$(st .outcome)" missing_cli "missing-cli: outcome"
assert_eq "$(st .phase)" preflight "missing-cli: phase"
assert_ends "$OUT" "status: $RUN/codex.status" "missing-cli: the status named"

new_case claimed
mkdir "$RUN/codex.lock"
d="$(dead_pid)"
echo "$d" > "$RUN/codex.lock/pid"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "claimed: rc"
assert_contains "$ERR" "pid $d is not running" "claimed: the owner named"
assert_eq "$(printf '%s\n' "$ERR" | grep -c '^  rm -r -- ')" 1 "claimed: the removal command"
assert_file "$RUN/codex.lock" "claimed: the lock stays"
assert_nofile "$RUN/codex.status" "claimed: no status"

new_case claimed-no-pid
mkdir "$RUN/codex.lock"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "claimed-no-pid: rc"
assert_contains "$ERR" "owner unknown" "claimed-no-pid: owner unknown"
assert_contains "$ERR" "rm -r --" "claimed-no-pid: the removal command"
assert_file "$RUN/codex.lock" "claimed-no-pid: the lock stays"

new_case claimed-apostrophe
RUN="$CASE/o'run"
make_run "$RUN"
mkdir "$RUN/codex.lock"
d="$(dead_pid)"
echo "$d" > "$RUN/codex.lock/pid"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "claimed-apostrophe: rc"
line="$(printf '%s\n' "$ERR" | grep '^  rm -r -- ')"
bash -c "$line"
assert_nofile "$RUN/codex.lock" "claimed-apostrophe: the pasted command removed the lock"
assert_file "$RUN/prompt.md" "claimed-apostrophe: and nothing else"

new_case leftovers
: > "$RUN/codex.first1.stdout"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "leftovers: rc"
assert_contains "$ERR" "already exist" "leftovers: message"
assert_nofile "$RUN/codex.status" "leftovers: no status"
assert_nofile "$RUN/codex.lock" "leftovers: the claim is released"

new_case old-status-kept
echo '{"outcome":"answered"}' > "$RUN/codex.status"
keep "$RUN/codex.status"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "old-status-kept: rc"
unchanged "$RUN/codex.status" "old-status-kept"
assert_ends "$OUT" "status: none" "old-status-kept: no status named"

new_case outcomes
ext outcomes
assert_eq "$rc" 0 "outcomes: rc"
assert_eq "$OUT" "$(printf '%s\t%s\n' answered 0 answered_after_resume 0 limit 10 empty 11 denied 12 \
    usage_limit 13 cli_failure 14 trace_unreadable 15 no_handle 16 handle_conflict 17 \
    prerequisite_failed 18 unsupported_version 19 cancelled 20 runner_failure 21 usage_error 64 missing_cli 127)" \
    "outcomes: the sixteen lines in order"

# ---------------------------------------------------------------------------
# One Codex attempt, starting and stopping a command, the basic outcomes.

new_case codex-answer
play codex 1 --stdout ANSWER --stderr "$(codex_err U1 'tokens used' '8,834')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "codex-answer: rc"
assert_eq "$(cat "$RUN/codex.out")" ANSWER "codex-answer: the answer file"
assert_eq "$(st .outcome)" answered "codex-answer: outcome"
assert_eq "$(st .phase)" first "codex-answer: phase"
assert_eq "$(st .handle)" U1 "codex-answer: handle"
assert_eq "$(st .handle_source)" first1 "codex-answer: handle_source"
assert_eq "$(st '.attempts[0].rule')" 11 "codex-answer: rule"
assert_eq "$(st '.attempts[0].handle_seen')" U1 "codex-answer: handle_seen"
assert_eq "$(st '.attempts[0].pgid')" "$(callf codex 1 pgid)" "codex-answer: the group is the CLI's"
assert_eq "$(st .reported.model)" gpt-6-astra "codex-answer: reported model"
assert_eq "$(st .reported.effort)" max "codex-answer: reported effort"
assert_eq "$(st .requested.model)" null "codex-answer: requested model"
assert_eq "$(st .oc_model)" null "codex-answer: oc_model"
assert_eq "$(st '.attempts[0].tokens.reported')" 8834 "codex-answer: the attempt's tokens"
assert_eq "$(stj .tokens)" '{"reported":[8834]}' "codex-answer: the run's tokens"
assert_eq "$(argv codex 1)" '["exec","--skip-git-repo-check","-s","read-only","--codex-x","-"]' "codex-answer: argv"
assert_eq "$(callf codex 1 stdin)" PROMPT "codex-answer: the prompt on standard input"
assert_eq "$(callf codex 1 cwd)" "$WORK" "codex-answer: cwd"
assert_contains "$(callf codex 1 parent)" ' -k 1s 90m ' "codex-answer: timeout's grace and the default limit"
assert_eq "$OUT" "codex: answered; status: $RUN/codex.status" "codex-answer: summary"
assert_eq "$(has_cr "$ERR")" no "codex-answer: no progress line off a terminal"
assert_eq "$(st .prompt_sha256)" "$(sum "$RUN/prompt.md")" "codex-answer: prompt_sha256"
for x in stdout stderr time exit; do assert_file "$RUN/codex.first1.$x" "codex-answer: codex.first1.$x"; done
assert_nofile "$RUN/codex.lock" "codex-answer: no lock"
assert_nofile "$RUN/codex.status.tmp" "codex-answer: no status.tmp"
assert_nofile "$RUN/codex.out.tmp" "codex-answer: no out.tmp"

new_case codex-no-extra
conf_set 'CODEX_EXTRA_ARGS=()'
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$(argv codex 1)" '["exec","--skip-git-repo-check","-s","read-only","-"]' "codex-no-extra: argv"

new_case codex-edit-model
play codex 1 --stdout DONE --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit --model m1 --effort low
assert_eq "$(argv codex 1)" \
    '["exec","--skip-git-repo-check","-s","workspace-write","-m","m1","-c","model_reasoning_effort=low","--codex-x","-"]' \
    "codex-edit-model: argv"
assert_eq "$(stj .requested)" '{"effort":"low","model":"m1"}' "codex-edit-model: requested"
assert_eq "$(st .level)" edit "codex-edit-model: level"

new_case spaces
RUN="$CASE/run dir"
WORK="$CASE/work dir"
make_run "$RUN"
fixture_repo "$WORK"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "spaces: rc"
assert_eq "$(callf codex 1 cwd)" "$WORK" "spaces: cwd"

new_case codex-fail
play codex 1 --exit 3 --stdout PARTIAL --stderr "$(codex_err U1 boom)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 14 "codex-fail: rc"
assert_eq "$(st .outcome)" cli_failure "codex-fail: outcome"
assert_eq "$(st '.attempts[0].rule')" 8 "codex-fail: rule"
assert_nofile "$RUN/codex.out" "codex-fail: no answer file"
assert_eq "$(cat "$RUN/codex.first1.stdout")" PARTIAL "codex-fail: the attempt's stdout is kept"
assert_contains "$(st .message)" boom "codex-fail: message"

for x in 124 137 127; do
    new_case "own-$x"
    play codex 1 --exit "$x" --stderr "$(codex_err U1)"
    ext run --cli codex --run-dir "$RUN" --limit 30s
    assert_eq "$rc" 14 "own-$x: rc"
    assert_eq "$(st .outcome)" cli_failure "own-$x: outcome"
    assert_eq "$(st '.attempts[0].rule')" 8 "own-$x: rule"
    assert_eq "$(st '.attempts[0].deadline_expired')" false "own-$x: deadline_expired"
done

new_case limit
play codex 1 --sleep 5 --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --limit 1s
assert_eq "$(st '.attempts[0].verdict')" limit "limit: verdict"
assert_eq "$(st '.attempts[0].rule')" 3 "limit: rule"
assert_eq "$(st '.attempts[0].exit')" 124 "limit: exit"
assert_eq "$(st '.attempts[0].deadline_expired')" true "limit: deadline_expired"
assert_eq "$(st '.attempts[0].wall >= 1')" true "limit: wall"
assert_contains "$(callf codex 1 parent)" ' -k 1s 1s ' "limit: timeout's grace and limit"

new_case ignore-term
play codex 1 --sleep 30 --ignore-term --stderr "$(codex_err U1)"
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN" --limit 1s
took_under "$t0" 10 "ignore-term: the run took less than 10 s"
assert_eq "$(st '.attempts[0].exit')" 137 "ignore-term: exit"
assert_eq "$(st '.attempts[0].verdict')" limit "ignore-term: verdict"
assert_eq "$(alive "$(callf codex 1 pid)" && echo yes || echo no)" no "ignore-term: the CLI is gone"

new_case whitespace
play codex 1 --stdout $' \n\t\n' --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$(st '.attempts[0].verdict')" empty "whitespace: verdict"
assert_eq "$(st '.attempts[0].rule')" 12 "whitespace: rule"

new_case header-only
# shellcheck disable=SC1112  # the typographic apostrophe of Codex's message
play codex 1 --stdout ANSWER --stderr "$(codex_err U1 'session id: OTHER' \
    'ERROR: You’ve hit your usage limit. try again at 2:40 PM.' 'more tool output' 'tokens used' '9')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$(st .handle)" U1 "header-only: handle"
assert_eq "$(st .outcome)" answered "header-only: outcome"

new_case ul-after-work
play codex 1 --exit 1 --stderr "$(codex_err U1 "$ul_line" "$ul_line" 'tokens used' '131,586')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "ul-after-work: rc"
assert_eq "$(st .outcome)" usage_limit "ul-after-work: outcome"
assert_eq "$(st '.attempts[0].rule')" 5 "ul-after-work: rule"
assert_eq "$(ncalls codex)" 1 "ul-after-work: one call"

new_case ul-at-the-door
play codex 1 --exit 1 --stderr "$(codex_err U1 "$ul_line" "$ul_line")"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "ul-at-the-door: rc"
assert_eq "$(st .outcome)" usage_limit "ul-at-the-door: outcome"
assert_eq "$(st '.attempts[0].rule')" 5 "ul-at-the-door: rule"

new_case fail-with-quote
# shellcheck disable=SC1112  # the typographic apostrophe of Codex's message
play codex 1 --exit 3 --stderr "$(codex_err U1 'ERROR: You’ve hit your usage limit.' 'real error: boom')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$(st .outcome)" cli_failure "fail-with-quote: outcome"
assert_eq "$(st '.attempts[0].rule')" 8 "fail-with-quote: rule"

new_case child-after-answer
play codex 1 --stdout ANSWER --child 300 --stderr "$(codex_err U1)"
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN"
took_under "$t0" 10 "child-after-answer: the group is stopped, not waited out"
assert_eq "$rc" 0 "child-after-answer: rc"
assert_eq "$(alive "$(callf codex 1 child)" && echo yes || echo no)" no "child-after-answer: the child is gone"

new_case probe-fails
echo 1 > "$SCN/codex.sandbox.exit"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "probe-fails: rc"
assert_eq "$(st .outcome)" prerequisite_failed "probe-fails: outcome"
assert_eq "$(st .phase)" preflight "probe-fails: phase"
assert_contains "$(cat "$RUN/codex.probe.err" 2>/dev/null)" probe-stderr "probe-fails: the probe's standard error"
assert_eq "$(ncalls codex)" 0 "probe-fails: no call"

new_case probe-hangs
: > "$SCN/codex.sandbox.hold"
: > "$SCN/codex.sandbox.ignore-term"
PRE_LIMIT=1s
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN"
took_under "$t0" 10 "probe-hangs: the run took less than 10 s"
assert_eq "$rc" 18 "probe-hangs: rc"
assert_contains "$(st .message)" "timed out" "probe-hangs: message"
assert_eq "$(alive "$(cat "$CALLS/sandbox.pid" 2>/dev/null)" && echo yes || echo no)" no "probe-hangs: the probe is gone"
assert_eq "$(ncalls codex)" 0 "probe-hangs: no call"
assert_nofile "$RUN/codex.lock" "probe-hangs: no lock"

new_case slow-start
mk_tool "$CASE/slow/setsid" <<'EOF'
sleep 0.5
exec "$BIN_ROOT/utils/setsid" "$@"
EOF
EXT_PATH="$CASE/slow:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "slow-start: rc"
assert_eq "$(st '.attempts[0].pgid')" "$(callf codex 1 pgid)" "slow-start: the group is the CLI's"

new_case start-fails
mk_tool "$CASE/broken/setsid" <<'EOF'
exit 1
EOF
EXT_PATH="$CASE/broken:$CASE/bin:$BIN_ROOT/utils"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "start-fails: rc"
assert_eq "$(st .outcome)" runner_failure "start-fails: outcome"
assert_contains "$(st .message)" "could not start" "start-fails: message"
assert_eq "$(ncalls codex)" 0 "start-fails: no call"
assert_nofile "$RUN/codex.lock" "start-fails: no lock"

new_case forced-fork
mk_tool "$CASE/fork/setsid" <<'EOF'
exec "$BIN_ROOT/utils/setsid" -f "$@"
EOF
EXT_PATH="$CASE/fork:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --child 300 --stderr "$(codex_err U1)"
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN"
took_under "$t0" 10 "forced-fork: the run took less than 10 s"
assert_eq "$rc" 0 "forced-fork: rc"
assert_eq "$(st '.attempts[0].pgid')" "$(callf codex 1 pgid)" "forced-fork: the group is the CLI's, not the starter's"
assert_eq "$(alive "$(callf codex 1 child)" && echo yes || echo no)" no "forced-fork: the child is gone"

new_case start-no-gid
mk_tool "$CASE/nogid/setsid" <<'EOF'
rm -f -- "$6"
mkdir -- "$6"
exec "$BIN_ROOT/utils/setsid" -f "$@"
EOF
EXT_PATH="$CASE/nogid:$CASE/bin:$BIN_ROOT/utils"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "start-no-gid: rc"
assert_contains "$(st .message)" "could not start" "start-no-gid: message"
assert_nofile "$CALLS/sandbox.started" "start-no-gid: the command never ran"
assert_nofile "$RUN/codex.lock" "start-no-gid: no lock"

new_case survivor-probe
mk_tool "$CASE/ghost/ps" <<'EOF'
"$BIN_ROOT/utils/ps" "$@"
st=$?
if [ "${1:-}" = -A ]; then
    for f in "$CASE"/run/*.lock/gid; do
        if [ -f "$f" ]; then printf ' %s S\n' "$(cat "$f")"; fi
    done
fi
exit "$st"
EOF
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN"
took_under "$t0" 10 "survivor-probe: the run took less than 10 s"
assert_eq "$rc" 21 "survivor-probe: rc"
assert_contains "$(st .message)" "could not stop" "survivor-probe: message"
assert_file "$CALLS/sandbox.started" "survivor-probe: the probe ran"
assert_eq "$(ncalls codex)" 0 "survivor-probe: no model attempt after it"

new_case unexpected-exit
play codex 1 --hold --child 300 --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
kill -USR1 "$BG"
ext_wait
assert_eq "$rc" 138 "unexpected-exit: rc"
assert_eq "$(st .outcome)" runner_failure "unexpected-exit: outcome"
assert_contains "$(st .message)" "unexpected exit" "unexpected-exit: message"
assert_begins "$OUT" "codex: runner_failure" "unexpected-exit: summary"
assert_eq "$(alive "$(callf codex 1 pid)" && echo yes || echo no)" no "unexpected-exit: the CLI is gone"
assert_eq "$(alive "$(callf codex 1 child)" && echo yes || echo no)" no "unexpected-exit: its child is gone"
assert_nofile "$RUN/codex.lock" "unexpected-exit: no lock"

new_case unexpected-exit-forked
mk_tool "$CASE/fork/setsid" <<'EOF'
exec "$BIN_ROOT/utils/setsid" -f "$@"
EOF
EXT_PATH="$CASE/fork:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --hold --child 300 --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
kill -USR1 "$BG"
ext_wait
assert_eq "$rc" 138 "unexpected-exit-forked: rc"
assert_eq "$(alive "$(callf codex 1 pid)" && echo yes || echo no)" no "unexpected-exit-forked: the CLI is gone"
assert_eq "$(alive "$(callf codex 1 child)" && echo yes || echo no)" no "unexpected-exit-forked: its child is gone"
assert_nofile "$RUN/codex.lock" "unexpected-exit-forked: no lock"

new_case start-abandoned
mk_tool "$CASE/held/setsid" <<'EOF'
printf '%s\n' "$$" > "$CASE/setsid.pid"
k=0
until [ -e "$CASE/setsid.go" ] || [ "$k" -ge 100 ]; do
    sleep 0.1
    k=$((k + 1))
done
exec "$BIN_ROOT/utils/setsid" -f "$@"
EOF
EXT_PATH="$CASE/held:$CASE/bin:$BIN_ROOT/utils"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CASE/setsid.pid"
kill -USR1 "$BG"
ext_wait
: > "$CASE/setsid.go"
hp="$(cat "$CASE/setsid.pid")"
k=0
while alive "$hp" && [ "$k" -lt 100 ]; do
    sleep 0.1
    k=$((k + 1))
done
assert_eq "$rc" 138 "start-abandoned: rc"
assert_eq "$(alive "$hp" && echo yes || echo no)" no "start-abandoned: the starter ended"
assert_nofile "$CALLS/sandbox.started" "start-abandoned: the command never ran"
assert_nofile "$RUN/codex.lock" "start-abandoned: no lock"

new_case progress-line
play codex 1 --sleep 1 --stdout A --stderr "$(codex_err U1)"
ext_tty run --cli codex --run-dir "$RUN" --limit 30s
assert_eq "$rc" 0 "progress-line: rc"
assert_contains "$OUT" "codex first " "progress-line: the prefix and phase"
assert_contains "$OUT" "/30s" "progress-line: the limit"

new_case big-prompt-oc
head -c 131072 /dev/zero | tr '\0' x > "$RUN/prompt.md"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "big-prompt-oc: rc"
assert_contains "$ERR" 131072 "big-prompt-oc: the size named"
assert_eq "$(ncalls qwen)" 0 "big-prompt-oc: no call"
assert_nofile "$RUN/qwen.status" "big-prompt-oc: no status"

new_case big-prompt-ok
head -c 131071 /dev/zero | tr '\0' x > "$RUN/prompt.md"
ext run --cli qwen --run-dir "$RUN"
assert_ne "$rc" 64 "big-prompt-ok: rc"

new_case big-prompt-codex
head -c 200000 /dev/zero | tr '\0' x > "$RUN/prompt.md"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "big-prompt-codex: rc"
x="$(callf codex 1 stdin | wc -c)"
assert_eq "${x//[[:space:]]/}" 200000 "big-prompt-codex: the whole prompt on standard input"

# ---------------------------------------------------------------------------
# OpenCode traces: steps, answers, damaged lines, denied calls, tokens.

new_case oc-boundary
play qwen 1 --stdout "$(
    oc_start S
    oc_bash S ls
    oc_text S NOTE
    oc_finish S tool-calls
    oc_start S
    oc_text S ANSWER
    oc_finish S stop
)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" answered "oc-boundary: outcome"
assert_eq "$(cat "$RUN/qwen.out" 2>/dev/null)" ANSWER "oc-boundary: the answer is the final step's text"
assert_eq "$(cat "$RUN/qwen.first1.earlier.txt" 2>/dev/null)" NOTE "oc-boundary: the earlier step's text"
assert_eq "$(st '.attempts[0].earlier_text')" qwen.first1.earlier.txt "oc-boundary: earlier_text"
assert_eq "$(st '.attempts[0].earlier_text_bytes')" 4 "oc-boundary: earlier_text_bytes"
assert_eq "$(st .handle)" S "oc-boundary: handle"

new_case oc-empty-final
play qwen 1 --stdout "$(t_oc_empty_final S)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st '.attempts[0].verdict')" empty "oc-empty-final: verdict"
assert_eq "$(st '.attempts[0].rule')" 12 "oc-empty-final: rule"
assert_eq "$(cat "$RUN/qwen.first1.earlier.txt" 2>/dev/null)" NOTE "oc-empty-final: the note is kept"

new_case oc-only-text
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" answered "oc-only-text: outcome"
assert_eq "$(cat "$RUN/qwen.out" 2>/dev/null)" ONLY "oc-only-text: the answer"
assert_nofile "$RUN/qwen.first1.earlier.txt" "oc-only-text: no earlier text file"
assert_eq "$(st '.attempts[0].earlier_text')" null "oc-only-text: earlier_text"

new_case oc-length
play qwen 1 --stdout "$(oc_start S; oc_text S CUT; oc_finish S length)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" cli_failure "oc-length: outcome"
assert_eq "$(st '.attempts[0].rule')" 10 "oc-length: rule"
assert_nofile "$RUN/qwen.out" "oc-length: no answer file"

new_case oc-no-finish
play qwen 1 --stdout "$(oc_start S; oc_text S X)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "oc-no-finish: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "oc-no-finish: rule"

new_case oc-unfinished-step
play qwen 1 --stdout "$(t_oc_only S; oc_start S; oc_text S MORE)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "oc-unfinished-step: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "oc-unfinished-step: rule"
assert_nofile "$RUN/qwen.out" "oc-unfinished-step: no answer file"

for x in 0 1; do
    name=oc-error-event
    if [ "$x" = 1 ]; then name=oc-error-nonzero; fi
    new_case "$name"
    play qwen 1 --exit "$x" --stdout "$(oc_start S; oc_text S X; oc_error S APIError boom)"
    ext run --cli qwen --run-dir "$RUN"
    assert_eq "$(st .outcome)" cli_failure "$name: outcome"
    assert_eq "$(st '.attempts[0].rule')" 6 "$name: rule"
    assert_contains "$(st .message)" boom "$name: message"
done

new_case oc-warning-line
play qwen 1 --stdout "$(oc_start S; printf 'warning: not json\n'; oc_text S A; oc_finish S stop)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" answered "oc-warning-line: outcome"
assert_eq "$(st '.attempts[0].skipped_lines')" 1 "oc-warning-line: skipped_lines"

new_case oc-damaged-tail
play qwen 1 --stdout "$(t_oc_only S; printf '{"type":"error","sess\n')"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "oc-damaged-tail: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "oc-damaged-tail: rule"
assert_nofile "$RUN/qwen.out" "oc-damaged-tail: no answer file"

new_case oc-damaged-nonzero
play qwen 1 --exit 1 --stdout "$(t_oc_only S; printf '{"type":"error","sess\n')"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" cli_failure "oc-damaged-nonzero: outcome"
assert_eq "$(st '.attempts[0].rule')" 8 "oc-damaged-nonzero: rule"

new_case oc-damaged-error
play qwen 1 --stdout "$(oc_start S; oc_error S APIError boom; printf '{"type":"te\n')"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "oc-damaged-error: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "oc-damaged-error: rule 9, not rule 6"

new_case oc-garbage
play qwen 1 --stdout "$(printf 'garbage\n')"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "oc-garbage: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "oc-garbage: rule"
assert_eq "$(st '.attempts[0].skipped_lines')" 1 "oc-garbage: skipped_lines"

new_case oc-startup-failure
play qwen 1 --exit 1 --stderr 'database is locked'
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 14 "oc-startup-failure: rc"
assert_eq "$(st .outcome)" cli_failure "oc-startup-failure: outcome"
assert_eq "$(st '.attempts[0].rule')" 8 "oc-startup-failure: rule"
assert_eq "$(ncalls qwen)" 1 "oc-startup-failure: one call"
assert_contains "$(st .message)" 'database is locked' "oc-startup-failure: message"

oc_denied_trace() { # the trace of oc-denied: denied by rule, asked and refused, failed otherwise, denied by rule
    oc_start S
    oc_read S /x error "$RULE_TEXT"
    oc_read S /y error 'x ASK-REFUSED y'
    oc_read S /z error 'ENOENT: no such file'
    oc_bash S 'cat /w' error "$RULE_TEXT"
    oc_finish S tool-calls
    oc_start S
    oc_text S A
    oc_finish S stop
}

new_case oc-denied
play qwen 1 --stdout "$(oc_denied_trace)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" answered "oc-denied: outcome"
assert_eq "$(st '.denied | length')" 3 "oc-denied: three denied calls"
assert_eq "$(st '.attempts[0].denied | length')" 3 "oc-denied: the attempt's list"
assert_eq "$(stj '.denied[0]')" \
    "$(jq -cnS --arg e "$RULE_TEXT" '{attempt: "first1", error: $e, input: "/x", tool: "read"}')" "oc-denied: the first"
assert_eq "$(st '.denied[2].input')" 'cat /w' "oc-denied: a command's input"

new_case oc-no-ask-text
conf_set "OC_ASK_REJECT_TEXT=''"
play qwen 1 --stdout "$(oc_denied_trace)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st '.denied | length')" 2 "oc-no-ask-text: only the rule's denials"

new_case oc-ask-refused
play qwen 1 --stdout "$(oc_start S; oc_bash S 'echo x' error 'x ASK-REFUSED y'; oc_finish S tool-calls)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st '.attempts[0].verdict')" empty "oc-ask-refused: verdict"
assert_eq "$(st '.attempts[0].rule')" 12 "oc-ask-refused: rule 12, not rule 10"
assert_eq "$(st '.denied | length')" 1 "oc-ask-refused: the refused call is recorded"

new_case oc-ask-refused-no-text
conf_set "OC_ASK_REJECT_TEXT=''"
play qwen 1 --stdout "$(oc_start S; oc_bash S 'echo x' error 'x ASK-REFUSED y'; oc_finish S tool-calls)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" cli_failure "oc-ask-refused-no-text: outcome"
assert_eq "$(st '.attempts[0].rule')" 10 "oc-ask-refused-no-text: rule"
assert_eq "$(st '.denied | length')" 0 "oc-ask-refused-no-text: nothing denied"

new_case oc-rule-denied-last
play qwen 1 --stdout "$(oc_start S; oc_bash S 'cat /w' error "$RULE_TEXT"; oc_finish S tool-calls)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .outcome)" cli_failure "oc-rule-denied-last: outcome"
assert_eq "$(st '.attempts[0].rule')" 10 "oc-rule-denied-last: the rule's text does not widen rule 10"
assert_eq "$(st '.denied | length')" 1 "oc-rule-denied-last: the denied call is recorded"

new_case oc-tokens
play qwen 1 --stdout "$(
    oc_start S
    oc_bash S ls
    oc_finish S tool-calls 10 4 3 2 1 0.5
    oc_start S
    oc_text S A
    oc_finish S stop 25 11 7 5 2 0.25
)"
ext run --cli qwen --run-dir "$RUN"
x='{"cached":3,"cost":0.75,"input":15,"output":10,"reasoning":7,"steps":2,"total":35}'
assert_eq "$(stj '.attempts[0].tokens')" "$x" "oc-tokens: the attempt's sums"
assert_eq "$(stj .tokens)" "$x" "oc-tokens: the run's"

new_case oc-argv
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(argv qwen 1)" \
    '["run","--pure","--agent","ext-read","--model","alibaba-token-plan/qwen3.8-max","--format","json","PROMPT"]' \
    "oc-argv: argv"
assert_eq "$(callf qwen 1 stdin)" "" "oc-argv: nothing on standard input"
assert_eq "$(st .oc_model)" alibaba-token-plan/qwen3.8-max "oc-argv: oc_model"
assert_eq "$(st .requested.model)" null "oc-argv: requested model"
assert_eq "$(st .name)" qwen "oc-argv: name"
assert_eq "$(jq -n --rawfile c "$CASE/skill/opencode/read-agent.json" --slurpfile e "$CALLS/qwen.1/env.json" \
    '$e[0] == {OPENCODE_CONFIG_CONTENT: $c, OPENCODE_DISABLE_CLAUDE_CODE_PROMPT: "1",
        OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "1"}' 2>/dev/null)" true "oc-argv: the read agent and the two switches"

new_case oc-effort
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN" --effort high
assert_contains "$(argv qwen 1)" '"--variant","high","--format"' "oc-effort: the variant before --format"
assert_eq "$(st .requested.effort)" high "oc-effort: requested effort"

new_case oc-full-id
play a-b 1 --stdout "$(t_oc_only S)"
ext run --cli a/b --run-dir "$RUN"
assert_eq "$PREFIX" a-b "oc-full-id: prefix"
assert_file "$RUN/a-b.out" "oc-full-id: the answer file"
assert_contains "$(argv a-b 1)" '"--model","a/b"' "oc-full-id: the model id as given"
assert_eq "$(st .oc_model)" a/b "oc-full-id: oc_model"
assert_eq "$(st .name)" a/b "oc-full-id: name"

# ---------------------------------------------------------------------------
# agy traces: the result event, denied actions, damaged lines, tokens.

new_case agy-answer
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-answer: rc"
assert_eq "$(st .outcome)" answered "agy-answer: outcome"
assert_eq "$(cat "$RUN/agy.out" 2>/dev/null)" ANSWER "agy-answer: the answer"
assert_eq "$(st .handle)" C "agy-answer: handle"
assert_eq "$(stj .tokens)" '{"duration_seconds":1.5,"input":4,"output":3,"thinking":2,"total":9,"turns":1}' \
    "agy-answer: tokens"
assert_eq "$(argv agy 1)" \
    "$(jq -cn --rawfile p "$RUN/agy-prompt.md" '["-p", $p, "--output-format", "stream-json", "--agy-x"]' 2>/dev/null)" \
    "agy-answer: argv"
assert_eq "$(callf agy 1 stdin)" "" "agy-answer: nothing on standard input"
assert_eq "$(st .configured_model)" "Fixture Default" "agy-answer: configured_model"
assert_eq "$(st .reported.model)" null "agy-answer: reported model"
assert_eq "$(st .prompt_sha256)" "$(sum "$RUN/agy-prompt.md" 2>/dev/null)" "agy-answer: prompt_sha256"
assert_eq "$(callf agy 1 env.json)" \
    '{"OPENCODE_CONFIG_CONTENT":null,"OPENCODE_DISABLE_CLAUDE_CODE_PROMPT":null,"OPENCODE_DISABLE_CLAUDE_CODE_SKILLS":null}' \
    "agy-answer: OpenCode's variables stay with OpenCode"

new_case agy-no-extra
conf_set 'AGY_EXTRA_ARGS=()'
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(argv agy 1 | jq length)" 4 "agy-no-extra: four arguments"

new_case agy-model
play agy 1 --stdout "$(agy_init C gemini-3.1-pro-high; agy_result C SUCCESS A)"
ext run --cli agy --run-dir "$RUN" --model gemini-3.1-pro-high --level edit
assert_ends "$(argv agy 1)" ',"--mode","accept-edits","--model","gemini-3.1-pro-high","--agy-x"]' "agy-model: argv"
assert_eq "$(st .reported.model)" gemini-3.1-pro-high "agy-model: reported model"
assert_eq "$(st .requested.model)" gemini-3.1-pro-high "agy-model: requested model"

new_case agy-denied-empty
play agy 1 --stdout "$(t_agy_denied C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 12 "agy-denied-empty: rc"
assert_eq "$(st .outcome)" denied "agy-denied-empty: outcome"
assert_eq "$(st '.attempts[0].rule')" 4 "agy-denied-empty: rule"
assert_eq "$(st '.denied[0].tool')" read_file "agy-denied-empty: the denied action"
assert_eq "$(ncalls agy)" 1 "agy-denied-empty: one call"

new_case agy-denied-text
play agy 1 --stdout "$(agy_init C; agy_result C SUCCESS note "$DENIED_JSON")"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st .outcome)" denied "agy-denied-text: outcome"
assert_nofile "$RUN/agy.out" "agy-denied-text: no answer file"

new_case agy-denied-nonzero
play agy 1 --exit 1 --stdout "$(t_agy_denied C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st .outcome)" denied "agy-denied-nonzero: outcome"
assert_eq "$(st '.attempts[0].rule')" 4 "agy-denied-nonzero: rule 4, not rule 8"

new_case agy-denied-error
play agy 1 --stdout "$(agy_init C; agy_result C ERROR '' "$DENIED_JSON")"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st .outcome)" denied "agy-denied-error: outcome"
assert_eq "$(st '.attempts[0].rule')" 4 "agy-denied-error: rule 4, not rule 7"

for x in 0 1; do
    name=agy-error
    if [ "$x" = 1 ]; then name=agy-error-nonzero; fi
    new_case "$name"
    play agy 1 --exit "$x" --stdout "$(agy_init C; agy_result C ERROR '')"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$(st .outcome)" cli_failure "$name: outcome"
    assert_eq "$(st '.attempts[0].rule')" 7 "$name: rule"
done

new_case agy-damaged-denied
play agy 1 --stdout "$(t_agy_denied C; printf '{"event":"resu\n')"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "agy-damaged-denied: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "agy-damaged-denied: rule 9, not rule 4"

new_case agy-damaged-error
play agy 1 --stdout "$(agy_init C; agy_result C ERROR ''; printf '{"event":"resu\n')"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "agy-damaged-error: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "agy-damaged-error: rule 9, not rule 7"

new_case agy-no-result
play agy 1 --stdout "$(agy_init C; agy_cmd C ls)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st .outcome)" trace_unreadable "agy-no-result: outcome"
assert_eq "$(st '.attempts[0].rule')" 9 "agy-no-result: rule"

new_case agy-empty
play agy 1 --stdout "$(t_agy_empty C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st '.attempts[0].verdict')" empty "agy-empty: verdict"
assert_eq "$(st '.attempts[0].rule')" 12 "agy-empty: rule"

new_case agy-whitespace
play agy 1 --stdout "$(agy_init C; agy_result C SUCCESS $' \n')"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st '.attempts[0].verdict')" empty "agy-whitespace: verdict"

new_case agy-last-result
play agy 1 --stdout "$(agy_init C; agy_result C SUCCESS '' null 9 4 3 2; agy_result C SUCCESS ANSWER null 20 9 6 5)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(stj .tokens)" '{"duration_seconds":1.5,"input":9,"output":6,"thinking":5,"total":20,"turns":1}' \
    "agy-last-result: the last result's tokens"

# ---------------------------------------------------------------------------
# Step 7: the end of the suite.

CASE_NAME=end
assert_eq "$(cat "$SENTINEL_LOG" 2>/dev/null)" "" "no case reached a sentinel"
assert_eq "$(cat "$TROUBLE_LOG" 2>/dev/null)" "" "no fake ran into trouble"
if [ -s "$ROOT/subshell-fails" ]; then
    n="$(wc -l < "$ROOT/subshell-fails")"
    TESTS_RUN=$((TESTS_RUN + n))
    TESTS_FAILED=$((TESTS_FAILED + n))
fi
finish
