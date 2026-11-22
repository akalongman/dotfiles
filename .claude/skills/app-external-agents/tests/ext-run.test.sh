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
    for f in "$ROOT"/cases/*/calls/*/pid "$ROOT"/cases/*/calls/*/child "$ROOT"/cases/*/calls/*/worker \
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
        GIT_CEILING_DIRECTORIES XDG_CONFIG_HOME XDG_DATA_HOME CODEX_HOME GH_CONFIG_DIR CLAUDE_CONFIG_DIR GNUPGHOME OPENCODE_CONFIG_CONTENT \
        OPENCODE_DISABLE_CLAUDE_CODE_PROMPT OPENCODE_DISABLE_CLAUDE_CODE_SKILLS \
        EXT_RUN_GRACE EXT_RUN_KILL_WAIT EXT_RUN_PREFLIGHT_LIMIT EXT_RUN_POLL EXT_RUN_START_WAIT \
        EXT_PATH EXT_CWD EXT_RUNNER PRE_LIMIT
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

assert_lacks() { # haystack needle msg
    case "$1" in
        *"$2"*) _fail "$3 (found '$2')" ;;
        *) _pass ;;
    esac
}

assert_line() { # text line msg: one of the text's lines is exactly that line
    local l
    while IFS= read -r l; do
        if [ "$l" = "$2" ]; then
            _pass
            return
        fi
    done <<< "$1"
    _fail "$3 (no line '$2')"
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

which_on() { # path name [dir]: prints the file the name resolves to, canonical (a link to it resolved); 1 when none, 2 on a bad PATH
    # A relative element is let through only when it leads from dir, where
    # the runner looks the CLI up (lookup_dir), to the case's fakes; any
    # other is a bad PATH.
    local IFS=: d c dirs
    read -r -a dirs <<< "$1"
    for d in "${dirs[@]}"; do
        case "$d" in
            /*) ;;
            *)
                if [ -z "$d" ] || [ -z "${3:-}" ] || [ "$(cd -P -- "$3/$d" 2>/dev/null && pwd -P)" != "$CASE/bin" ]; then
                    printf 'ext-run.test: PATH %s has an empty or relative element\n' "$1" >&2
                    return 2
                fi
                d="$CASE/bin"
                ;;
        esac
        if [ -f "$d/$2" ] && [ -x "$d/$2" ]; then
            c="$(realpath -e -- "$d/$2")" || return 2
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

lookup_dir() { # runner args...: sets LOOKUP_DIR to the directory the runner looks the CLI up in: where it starts, or for a continue the working directory its status file records, when that file names one
    local a prev='' run='' cwd
    LOOKUP_DIR="${EXT_CWD:-$WORK}"
    [ "${1:-}" = continue ] || return 0
    for a in "$@"; do
        if [ "$prev" = --run-dir ]; then run="$a"; fi
        prev="$a"
    done
    ext_prefix "$@"
    [ -n "$run" ] && [ -n "$PREFIX" ] || return 0
    case "$run" in /*) ;; *) run="$LOOKUP_DIR/$run" ;; esac
    # A status file the suite cannot read names no directory; the runner
    # cannot read it either and refuses before its lookup.
    cwd="$(jq -r '.cwd | strings' "$run/$PREFIX.status" 2>/dev/null)"
    case "$cwd" in /*) LOOKUP_DIR="$cwd" ;; esac
}

check_path() { # path [runner args...]: stops the suite when a CLI name resolves outside the fakes and the sentinels, as seen from where the runner looks it up
    local n p r
    case "$1" in
        '' | *:) printf 'ext-run.test: PATH %s has an empty element\n' "$1" >&2; exit 2 ;;
    esac
    lookup_dir "${@:2}"
    for n in codex agy opencode; do
        p="$(which_on "$1" "$n" "$LOOKUP_DIR")"
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
    local n d
    unset EXT_PATH EXT_CWD EXT_RUNNER PRE_LIMIT
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
            --stdout | --stdout-file | --stdout-early | --stderr | --stderr-file | --exit | --sleep | --child | --worker | --then-version)
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
            --worker) printf '%s\n' "$2" > "$d/worker" ;;
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
    PREFIX=""
    case "$cli" in
        codex | agy | deepseek | qwen) PREFIX="$cli" ;;
        *)
            # A full model id, as the runner's valid_model_id accepts it.
            if [[ $cli =~ ^[A-Za-z0-9][A-Za-z0-9._:@+-]*(/[A-Za-z0-9._:@+-]+)+$ ]]; then PREFIX="${cli//\//-}"; fi
            ;;
    esac
}

ext_env() { # path: the runner's environment, exported in the current (sub)shell
    local kv
    export PATH="$1" EXT_RUN_GRACE=1s EXT_RUN_KILL_WAIT=2s EXT_RUN_POLL=0.1 EXT_RUN_START_WAIT=5 \
        EXT_RUN_PREFLIGHT_LIMIT="${PRE_LIMIT:-10s}"
    for kv in "${EXT_VARS[@]}"; do export "${kv?}"; done
}

ext() { # args...: runs the case's runner (EXT_RUNNER, as a path from EXT_CWD, when set) in the foreground; sets rc, OUT, ERR and PREFIX
    local path="${EXT_PATH:-$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels}"
    check_path "$path" "$@"
    ext_prefix "$@"
    OUT="$({ cd "${EXT_CWD:-$WORK}" && ext_env "$path" &&
        exec "$BIN_ROOT/utils/timeout" -k 2s 60s "${EXT_RUNNER:-$CASE/skill/scripts/ext-run}" "$@"; } \
        < /dev/null 2> "$CASE/ext.err")"
    rc=$?
    ERR="$(< "$CASE/ext.err")"
    case "$rc" in 124 | 137) _fail "the runner did not end within 60 s: ext $*" ;; esac
}

ext_bg() { # args...: the runner in the background, its pid the job's; sets BG, BGN and PREFIX
    local path="${EXT_PATH:-$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels}"
    check_path "$path" "$@"
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
    check_path "$path" "$@"
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

# agy's quota error, in the shapes of the saved traces of 2026-11-15
# (build-probes/2026-11-15-1852-agy-no-slash, agy.ndjson and agy.err) and
# 2026-11-16 (build-probes/2026-11-16-2137-acceptance, a/agy.first1.*).
agy_quota_text() { # duration: the result's error text
    printf 'Individual quota reached. Please upgrade your subscription to increase your limits. Resets in %s.' "$1"
}

agy_step() { # cid index type: a finished step
    jq -cn --arg c "$1" --argjson i "$2" --arg t "$3" '{event: "step_update",
        step_update: {conversation_id: $c, step_index: $i, state: "DONE", step_type: $t}}'
}

agy_error_result() { # cid error-text: a result with status ERROR, no response and no tokens
    jq -cn --arg c "$1" --arg e "$2" '{event: "result", result: {conversation_id: $c, status: "ERROR",
        response: "", error: $e, duration_seconds: 0, num_turns: 1,
        usage: {input_tokens: 0, output_tokens: 0, thinking_tokens: 0, cache_read_tokens: 0, total_tokens: 0},
        finished_reason: "error"}}'
}

agy_quota_err() { # duration: agy's standard error for the quota error
    printf 'error: %s\n' "$(agy_quota_text "$1")"
    printf 'AGY_ERROR: %s\n' "$(jq -cn --arg s "RESOURCE_EXHAUSTED (code 429): $(agy_quota_text "$1")" \
        '{short_error: $s, status: "RESOURCE_EXHAUSTED", error_code: 429, code_kind: "http", retryable: true,
          error_id: "566e972d-937e-4866-8700-7f1a1beb7f74-1"}')"
}

t_agy_quota_door() { # cid duration: the quota refused the run before the model's first turn
    jq -cn --arg c "$1" '{event: "init", conversation_id: $c, init: {cwd: "/w", permission_mode: "request-review"}}'
    agy_step "$1" 0 user_input
    agy_step "$1" 1 error_message
    agy_error_result "$1" "$(agy_quota_text "$2")"
}

t_agy_quota_work() { # cid duration: the quota ended the run after a model turn and a tool step
    jq -cn --arg c "$1" '{event: "init", conversation_id: $c, init: {cwd: "/w", permission_mode: "request-review"}}'
    agy_step "$1" 0 user_input
    agy_step "$1" 1 agent_response
    jq -cn --arg c "$1" '{event: "step_update", step_update: {conversation_id: $c, step_index: 2, state: "DONE",
        step_type: "tool", tool_name: "run_command", tool_info: {name: "run_command",
        parameters: {CommandLine: "cat notes.txt"}}}}'
    agy_step "$1" 3 error_message
    agy_error_result "$1" "$(agy_quota_text "$2")"
}

reset_within() { # label seconds s0 s1: reset_at is a local time in the form %Y-%m-%d %H:%M:%S %z, the stated seconds after an end between s0 and s1
    local r e
    r="$(st .reset_at)"
    if [[ ! $r =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]]; then
        _fail "$1: reset_at '$r' is not in the form %Y-%m-%d %H:%M:%S %z"
        return
    fi
    e="$(date -d "$r" +%s)"
    if [ "$e" -ge $(($3 + $2)) ] && [ "$e" -le $(($4 + $2)) ]; then
        _pass
    else
        _fail "$1: reset_at $r is not $2 s after the attempt's end"
    fi
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

# The arguments of the listing step 2 asks ps for; a ps stand-in that fails
# elsewhere lets this one through to the real ps.
PS_PROBE='-A -o pid=,pgid=,sid=,stat='

mk_ghost_ps() { # dir: a ps there that also shows, with -A, a live process in every group a lock's gid file of the case's run names
    mk_tool "$1/ps" <<'EOF'
"$BIN_ROOT/utils/ps" "$@"
st=$?
if [ "${1:-}" = -A ]; then
    for f in "$CASE"/run/*.lock/gid; do
        if [ -f "$f" ]; then printf ' %s S\n' "$(cat "$f")"; fi
    done
fi
exit "$st"
EOF
}

mk_ghost_session_ps() { # dir: a ps there whose session listing (-A -o pid=,sid=,stat=) also shows a live process in the session of every group a lock's gid file names
    # The ghost's pid, 2147483000, lies above the kernel's highest pid
    # (4194304), so no process has it and a signal sent to it reaches none.
    mk_tool "$1/ps" <<'EOF'
"$BIN_ROOT/utils/ps" "$@"
st=$?
if [ "$*" = '-A -o pid=,sid=,stat=' ]; then
    for f in "$CASE"/run/*.lock/gid; do
        if [ -f "$f" ]; then printf ' 2147483000 %s S\n' "$(cat "$f")"; fi
    done
fi
exit "$st"
EOF
}

mk_pad_ps() { # dir listing...: a ps there that adds 12,500 lines "0 0 0 S" (100,000 bytes) to each listing named by its arguments, so that table is longer than a pipe holds; pid, group and session 0 are none that a reader asks about
    local l
    mkdir -p "$1" && printf '0 0 0 S\n%.0s' {1..12500} > "$1/pad" || return 1
    # shellcheck disable=SC2016  # the stand-in's own text, expanded when it runs
    {
        printf '%s\n' '"$BIN_ROOT/utils/ps" "$@"' 'st=$?' 'case "$*" in'
        for l in "${@:2}"; do printf "    '%s') cat %q ;;\n" "$l" "$1/pad"; done
        printf '%s\n' 'esac' 'exit "$st"'
    } | mk_tool "$1/ps"
}

nosearch_ok() { # case-name: makes $CASE/nosearch, a TMPDIR that bash takes as writable (its write bit set) and cannot make a file in (its search bit cleared); 1 as root, which needs no search bit, with a line on standard error
    if [ "$(id -u)" = 0 ]; then
        printf 'ext-run.test: %s skipped in part: as root a directory without its search bit can be searched\n' "$1" >&2
        return 1
    fi
    mkdir -m 700 "$CASE/nosearch" && chmod 600 "$CASE/nosearch"
}

worker_placed() { # key k label: the invocation's worker led a process group of its own inside the invocation's session
    assert_ne "$(callf "$1" "$2" worker.pgid)" "$(callf "$1" "$2" pgid)" "$3: the worker leads a group of its own"
    assert_eq "$(callf "$1" "$2" worker.sid)" "$(callf "$1" "$2" pgid)" "$3: the worker is in the session the group leads"
}

agent_env_is() { # key k agent-file: true when that invocation's environment held the agent file as injected with no outside directory (the read agent's external_directory a deny of everything) and the two switches
    jq -n --slurpfile a "$CASE/skill/opencode/$3" --slurpfile e "$CALLS/$1.$2/env.json" '
        ($a[0] | if .agent["ext-read"] then .agent["ext-read"].permission.external_directory = {"*": "deny"} else . end)
            as $want
        | ($e[0].OPENCODE_CONFIG_CONTENT | fromjson) == $want
            and $e[0].OPENCODE_DISABLE_CLAUDE_CODE_PROMPT == "1" and $e[0].OPENCODE_DISABLE_CLAUDE_CODE_SKILLS == "1"' \
        2>/dev/null
}

section() { # name: the lines of prompts/followup.md after "## <name>" up to the next "## " line, blank lines at either end dropped
    local l on=0 got=()
    while IFS= read -r l || [ -n "$l" ]; do
        if [ "$on" = 1 ]; then
            case "$l" in '## '*) break ;; esac
            got+=("$l")
        elif [ "$l" = "## $1" ]; then
            on=1
        fi
    done < "$SKILL/prompts/followup.md"
    while [ "${#got[@]}" -gt 0 ] && [[ ${got[0]} =~ ^[[:space:]]*$ ]]; do got=("${got[@]:1}"); done
    while [ "${#got[@]}" -gt 0 ] && [[ ${got[-1]} =~ ^[[:space:]]*$ ]]; do unset 'got[-1]'; done
    if [ "${#got[@]}" -gt 0 ]; then printf '%s\n' "${got[@]}"; fi
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

# The follow-up texts, as the runner must send them.
LIMIT_TEXT="$(section limit)"
EMPTY_TEXT="$(section empty)"
# shellcheck disable=SC2034  # read by name in the check below
CONTINUE_TEXT="$(section continue)"
AFTER_EDIT="$(section after-edit)"
for x in LIMIT_TEXT EMPTY_TEXT CONTINUE_TEXT AFTER_EDIT; do assert_ne "${!x}" "" "the follow-up text $x is not empty"; done

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
# shellcheck disable=SC2034  # the four are read by clean_env's caller check below
(
    EXT_PATH=/x
    EXT_CWD=/y
    EXT_RUNNER=/z
    PRE_LIMIT=9
    clean_env
    [ -z "${EXT_PATH:-}${EXT_CWD:-}${EXT_RUNNER:-}${PRE_LIMIT:-}" ]
)
assert_eq "$?" 0 "clean_env unsets EXT_PATH, EXT_CWD, EXT_RUNNER and PRE_LIMIT"

# ext refuses a PATH on which a CLI name resolves outside the fakes
new_case path-guard
mkdir "$CASE/real"
printf '#!/bin/sh\n: > "%s/real-ran"\n' "$CASE" > "$CASE/real/codex"
chmod +x "$CASE/real/codex"
EXT_PATH="$CASE/real:$CASE/bin:$BIN_ROOT/utils"
(ext run --cli codex --run-dir "$RUN") > /dev/null 2>&1
assert_eq "$?" 2 "the suite stops on such a PATH"
assert_eq "$([ -e "$CASE/real-ran" ] && echo ran || echo no)" no "the planted program did not run"

# the same when the name in the case's bin is a link to a program elsewhere
new_case path-guard-link
mkdir "$CASE/real"
printf '#!/bin/sh\n: > "%s/real-ran"\n' "$CASE" > "$CASE/real/codex"
chmod +x "$CASE/real/codex"
rm "$CASE/bin/codex"
ln -s "$CASE/real/codex" "$CASE/bin/codex"
(ext run --cli codex --run-dir "$RUN") > /dev/null 2>&1
assert_eq "$?" 2 "path-guard-link: the suite stops on such a link"
assert_eq "$([ -e "$CASE/real-ran" ] && echo ran || echo no)" no "path-guard-link: the planted program did not run"

# new_case keeps its own loop variables, so a case's loop may use any name
n=N d=D
new_case new-case-locals
assert_eq "$n $d" "N D" "new_case leaves n and d as they were"

# ext_prefix derives the prefix the runner names in its summary, and none for
# a --cli value the runner refuses (each run stops at the bad --level)
new_case ext-prefix-as-runner
for v in codex qwen a/b x.y/z-1 x/ a//b /x 'a b/c' nope; do
    ext run --cli "$v" --run-dir "$RUN" --level bogus
    assert_eq "${PREFIX:-ext-run}" "${OUT%%: *}" "ext-prefix-as-runner: --cli '$v'"
done

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

# kimi is no alias and holds no /, so it is refused as any unknown name is
new_case kimi-not-a-name
ext run --cli kimi --run-dir "$RUN"
assert_eq "$rc" 64 "kimi-not-a-name: rc"
assert_eq "$OUT" "ext-run: usage_error (unknown cli: kimi); status: none" "kimi-not-a-name: summary"
assert_nofile "$RUN/kimi.status" "kimi-not-a-name: no status"
assert_nofile "$RUN/kimi.lock" "kimi-not-a-name: no claim"
assert_eq "$(ls -A "$CALLS")" "" "kimi-not-a-name: no CLI started"

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

new_case missing-awk
mkdir "$CASE/noawk"
for f in "$BIN_ROOT/utils"/*; do
    if [ "${f##*/}" != awk ]; then ln -s "$f" "$CASE/noawk/${f##*/}"; fi
done
EXT_PATH="$CASE/noawk:$CASE/bin"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "missing-awk: rc"
assert_contains "$ERR" "missing helper programs: awk" "missing-awk: awk named"
assert_nofile "$RUN/codex.status" "missing-awk: no status"

mk_old_jq() { # dir: a jq there that refuses --raw-output0 as jq 1.6 does, and runs the real jq otherwise
    mk_tool "$1/jq" <<'EOF'
for a in "$@"; do
    if [ "$a" = --raw-output0 ]; then
        printf '%s\n' 'jq: Unknown option: --raw-output0' 'Use jq --help for help with command-line options,' \
            'or see the jq manpage, or online docs  at https://jqlang.github.io/jq' >&2
        exit 2
    fi
done
exec "$BIN_ROOT/utils/jq" "$@"
EOF
}

# The runner needs jq 1.7 or later: step 2 checks once that jq takes
# --raw-output0, so a jq that does not stops every kind before anything
# starts, not later at a read that would name a file.
new_case jq-without-raw-output0
mk_old_jq "$CASE/oldjq"
EXT_PATH="$CASE/oldjq:$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels"
for cli in codex agy qwen; do
    answering "$cli" 1
    ext run --cli "$cli" --run-dir "$RUN"
    assert_eq "$rc" 18 "jq-without-raw-output0 $cli: rc"
    assert_eq "$OUT" \
        "$cli: prerequisite_failed (jq 1.7 or later is needed: $CASE/oldjq/jq does not take --raw-output0); status: none" \
        "jq-without-raw-output0 $cli: the summary names jq and the option"
    assert_eq "$(ncalls "$cli")" 0 "jq-without-raw-output0 $cli: no call"
    assert_nofile "$RUN/$cli.status" "jq-without-raw-output0 $cli: no status"
done
assert_nofile "$CALLS/sandbox.started" "jq-without-raw-output0: no sandbox probe"
assert_nofile "$CALLS/version.started" "jq-without-raw-output0: no version command"

# Every stop of a started command reads the process table, so step 2 checks
# once that ps lists the runner's own process: a ps that fails, or prints
# nothing, stops every kind before anything starts, instead of after agy's
# whole first attempt (no preflight command) or Codex's and OpenCode's
# preflight command.
new_case ps-cannot-list
mk_tool "$CASE/failps/ps" <<'EOF'
printf 'ps: cannot list the processes\n' >&2
exit 1
EOF
mk_tool "$CASE/mutps/ps" <<'EOF'
exit 0
EOF
for bad in failps mutps; do
    EXT_PATH="$CASE/$bad:$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels"
    for cli in codex agy qwen; do
        RUN="$CASE/run-$bad-$cli"
        make_run "$RUN" || exit 2
        answering "$cli" 1
        ext run --cli "$cli" --run-dir "$RUN"
        assert_eq "$rc" 18 "ps-cannot-list $bad $cli: rc"
        assert_eq "$OUT" \
            "$cli: prerequisite_failed (a ps that lists the processes is needed: $CASE/$bad/ps $PS_PROBE does not show the runner's own process); status: none" \
            "ps-cannot-list $bad $cli: the summary names ps and what it did not show"
        assert_eq "$(ncalls "$cli")" 0 "ps-cannot-list $bad $cli: no call"
        assert_nofile "$RUN/$cli.status" "ps-cannot-list $bad $cli: no status"
        assert_nofile "$RUN/$cli.lock" "ps-cannot-list $bad $cli: no claim"
    done
done
assert_nofile "$CALLS/sandbox.started" "ps-cannot-list: no sandbox probe"
assert_nofile "$CALLS/version.started" "ps-cannot-list: no version command"

# For OpenCode, step 2 also refuses a tested version in the settings file
# that is not a version, which does not stop a Codex run, and a HOME that
# is not absolute, since the protected directories are found from it.
new_case oc-tested-version-bad
conf_set 'OC_TESTED_VERSION=1.19'
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 18 "oc-tested-version-bad: rc"
assert_eq "$OUT" "qwen: prerequisite_failed (OC_TESTED_VERSION in $CASE/skill/scripts/ext-run.conf is not a version: '1.19'); status: none" \
    "oc-tested-version-bad: the summary names the setting and its value"
assert_eq "$(ncalls qwen)" 0 "oc-tested-version-bad: no call"
assert_nofile "$CALLS/version.started" "oc-tested-version-bad: no version command"
assert_nofile "$RUN/qwen.status" "oc-tested-version-bad: no status"
answering codex 1
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "oc-tested-version-bad: codex runs"

new_case oc-home-relative
EXT_VARS=("HOME=home")
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 18 "oc-home-relative: rc"
assert_contains "$ERR" "HOME is not an absolute path" "oc-home-relative: message"
assert_eq "$(ncalls qwen)" 0 "oc-home-relative: no call"
assert_nofile "$RUN/qwen.status" "oc-home-relative: no status"

# An awk that runs and prints nothing leaves the waits unconverted: the run
# stops before it writes, instead of taking every wait as zero and every
# status 124 as an expired deadline.
new_case awk-fails
mk_tool "$CASE/badawk/awk" <<'EOF'
exit 1
EOF
EXT_PATH="$CASE/badawk:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --exit 124 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN" --limit 30s
assert_eq "$rc" 18 "awk-fails: rc"
assert_contains "$ERR" "cannot convert EXT_RUN_GRACE" "awk-fails: the wait named"
assert_nofile "$RUN/agy.status" "awk-fails: no status"
assert_eq "$(ncalls agy)" 0 "awk-fails: no call"

new_case bad-knobs
answering codex 1
for kv in EXT_RUN_POLL=1s EXT_RUN_START_WAIT=0 EXT_RUN_GRACE=ten EXT_RUN_KILL_WAIT=-1 EXT_RUN_PREFLIGHT_LIMIT=0; do
    EXT_VARS=("$kv")
    ext run --cli codex --run-dir "$RUN"
    assert_eq "$rc" 18 "bad-knobs $kv: rc"
    assert_contains "$ERR" "bad values in the environment: $kv" "bad-knobs $kv: the knob named"
done
assert_nofile "$RUN/codex.status" "bad-knobs: no status"
assert_eq "$(ncalls codex)" 0 "bad-knobs: no call"

new_case missing-conf
rm "$CASE/skill/scripts/ext-run.conf"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "missing-conf: rc"
assert_contains "$ERR" "ext-run.conf" "missing-conf: the settings file named"
assert_nofile "$RUN/codex.status" "missing-conf: no status"

# The follow-up texts are read in step 2, before the claim, like the settings
# file: a missing file stops a run that would have answered, and no CLI
# command starts, the sandbox probe included.
new_case followup-missing-run
rm "$CASE/skill/prompts/followup.md"
answering codex 1
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "followup-missing-run: rc"
assert_begins "$OUT" "codex: prerequisite_failed (" "followup-missing-run: outcome"
assert_ends "$OUT" "status: none" "followup-missing-run: no status named"
assert_contains "$ERR" "the follow-up texts are missing or unreadable: $CASE/skill/scripts/../prompts/followup.md" \
    "followup-missing-run: the file named"
assert_eq "$(ncalls codex)" 0 "followup-missing-run: no call"
assert_nofile "$CALLS/sandbox.started" "followup-missing-run: no sandbox probe"
assert_nofile "$RUN/codex.status" "followup-missing-run: no status"
assert_nofile "$RUN/codex.lock" "followup-missing-run: no lock"

# A section that is there but empty stops it the same way, also one this run
# would not have used.
new_case followup-section-empty-run
awk '$0 == "## empty" { print; skip = 1; next } /^## / { skip = 0 } !skip' "$SKILL/prompts/followup.md" \
    > "$CASE/skill/prompts/followup.md"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 18 "followup-section-empty-run: rc"
assert_begins "$OUT" "qwen: prerequisite_failed (" "followup-section-empty-run: outcome"
assert_contains "$ERR" "the follow-up text for empty is missing or empty in $CASE/skill/scripts/../prompts/followup.md" \
    "followup-section-empty-run: the section and the file named"
assert_eq "$(ncalls qwen)" 0 "followup-section-empty-run: no call"
assert_nofile "$CALLS/version.started" "followup-section-empty-run: no version command"
assert_nofile "$RUN/qwen.status" "followup-section-empty-run: no status"

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

# A ps that cannot list the processes cannot show the claim's owner gone, so
# the refusal takes it to be running, says that it may be and why, and
# offers no removal command. The stand-in lets step 2's listing through, so
# the claim's look is what fails.
new_case claimed-ps-fails
mkdir "$RUN/codex.lock"
d="$(dead_pid)"
echo "$d" > "$RUN/codex.lock/pid"
mk_tool "$CASE/badps/ps" <<EOF
if [ "\$*" = '$PS_PROBE' ]; then exec "\$BIN_ROOT/utils/ps" "\$@"; fi
printf 'ps: cannot list the processes\n' >&2
exit 1
EOF
EXT_PATH="$CASE/badps:$CASE/bin:$BIN_ROOT/utils"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "claimed-ps-fails: rc"
assert_contains "$ERR" "pid $d may be running (ps could not list the processes)" \
    "claimed-ps-fails: the owner taken to be running, and ps named"
assert_lacks "$ERR" "rm -r" "claimed-ps-fails: no removal command"
assert_file "$RUN/codex.lock" "claimed-ps-fails: the lock stays"

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

# The files of a longer prefix that begins with this one and a dot (qwen.x-y,
# the prefix of the model id qwen.x/y) are not leftovers of this prefix; any
# other file that begins with it still is.
new_case leftovers-longer-prefix
play qwen.x-y 1 --stdout "$(t_oc_only S)"
ext run --cli qwen.x/y --run-dir "$RUN"
assert_eq "$rc" 0 "leftovers-longer-prefix: the run of qwen.x/y"
play qwen 1 --stdout "$(t_oc_only S A)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "leftovers-longer-prefix: rc of the run of qwen beside it"
assert_eq "$(cat "$RUN/qwen.out" 2>/dev/null)" A "leftovers-longer-prefix: its answer"
RUN="$CASE/run2"
make_run "$RUN"
: > "$RUN/qwen.x-y.notes"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "leftovers-longer-prefix: rc with a file no prefix writes"
assert_contains "$ERR" "already exist in $RUN: qwen.x-y.notes" "leftovers-longer-prefix: that file named"
assert_eq "$(ncalls qwen)" 1 "leftovers-longer-prefix: one call of qwen"

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
assert_eq "$(cat "$RUN/codex.first1.exit")" 3 "codex-fail: the exit file holds the CLI's status"
t="$(cat "$RUN/codex.first1.time")"
assert_eq "$([[ $t =~ ^[0-9]+\.[0-9]{3}$ ]] && echo yes || echo no)" yes "codex-fail: the time file holds wall seconds ($t)"
assert_eq "$(jq -n --argjson t "$t" --argjson w "$(st '.attempts[0].wall')" '$t == $w' 2>/dev/null)" true \
    "codex-fail: the time file and the attempt's wall agree"

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
assert_eq "$(st .message)" "could not start codex sandbox: the start ended with status 1 before a process group was recorded" \
    "start-fails: message, the start's own end"
assert_eq "$(ncalls codex)" 0 "start-fails: no call"
assert_nofile "$RUN/codex.lock" "start-fails: no lock"

# A start that is still running and has recorded no group when the wait for
# one ends is killed, and the message names the wait.
new_case start-times-out
mk_tool "$CASE/stuck/setsid" <<'EOF'
exec sleep 30
EOF
EXT_PATH="$CASE/stuck:$CASE/bin:$BIN_ROOT/utils"
EXT_VARS=(EXT_RUN_START_WAIT=1)
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN"
took_under "$t0" 10 "start-times-out: the run took less than 10 s"
assert_eq "$rc" 21 "start-times-out: rc"
assert_eq "$(st .message)" "could not start codex sandbox: no process group was recorded within 1 s" \
    "start-times-out: message, the wait"
assert_eq "$(ncalls codex)" 0 "start-times-out: no call"
assert_nofile "$RUN/codex.lock" "start-times-out: no lock"

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

# The start ends before the command has recorded its group, and the group
# appears while the runner waits one poll for it: the runner stops it, and a
# process of it that outlives the kill is named beside the failed start.
new_case start-late-survivor
mk_ghost_ps "$CASE/late"
mk_tool "$CASE/late/setsid" <<'EOF'
( sleep 0.5; exec "$BIN_ROOT/utils/setsid" "$@" ) &
exit 0
EOF
EXT_PATH="$CASE/late:$CASE/bin:$BIN_ROOT/utils"
EXT_VARS=(EXT_RUN_POLL=2)
answering agy 1
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 21 "start-late-survivor: rc"
assert_contains "$(st .message)" "could not start" "start-late-survivor: the failed start named"
assert_contains "$(st .message)" "could not stop process group" "start-late-survivor: and the survivor"
assert_eq "$(ncalls agy)" 0 "start-late-survivor: no call"
assert_nofile "$RUN/agy.lock" "start-late-survivor: no lock"

new_case survivor-probe
mk_ghost_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN"
took_under "$t0" 10 "survivor-probe: the run took less than 10 s"
assert_eq "$rc" 21 "survivor-probe: rc"
assert_contains "$(st .message)" "could not stop" "survivor-probe: message"
assert_file "$CALLS/sandbox.started" "survivor-probe: the probe ran"
assert_eq "$(ncalls codex)" 0 "survivor-probe: no model attempt after it"

# A ps that cannot list the processes confirms nothing: the stop goes on to
# the kill and ends the run as a runner failure, instead of reading the
# failure as "no process is alive". The stand-in lets step 2's listing
# through, so the stop is what meets the failure.
new_case ps-fails
mk_tool "$CASE/badps/ps" <<EOF
if [ "\${1:-}" = -A ] && [ "\$*" != '$PS_PROBE' ]; then
    printf 'ps: cannot list the processes\n' >&2
    exit 1
fi
exec "\$BIN_ROOT/utils/ps" "\$@"
EOF
EXT_PATH="$CASE/badps:$CASE/bin:$BIN_ROOT/utils"
answering codex 1
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "ps-fails: rc"
assert_eq "$(st .outcome)" runner_failure "ps-fails: outcome"
assert_contains "$(st .message)" "could not stop process group" "ps-fails: the group named"
assert_contains "$(st .message)" "ps could not list the processes" "ps-fails: the cause named"
assert_eq "$(ncalls codex)" 0 "ps-fails: no model attempt after the probe"
assert_eq "$(alive "$(cat "$CALLS/sandbox.pid" 2>/dev/null)" && echo yes || echo no)" no "ps-fails: the probe is gone"

# A stop names what its last look at the table found: a ps that fails at the
# first look of a stop and then shows a process of the group that outlives
# the kill (as mk_ghost_ps does) names the survivor, not ps.
new_case ps-fails-once
mk_ghost_ps "$CASE/ghost"
mv "$CASE/ghost/ps" "$CASE/ghost/ps.ghost"
mk_tool "$CASE/ghost/ps" <<'EOF'
if [ "$*" = '-A -o pgid= -o stat=' ] && [ ! -e "$CASE/ps-failed" ]; then
    : > "$CASE/ps-failed"
    printf 'ps: cannot list the processes\n' >&2
    exit 1
fi
exec "$CASE/ghost/ps.ghost" "$@"
EOF
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "ps-fails-once: rc"
assert_file "$CASE/ps-failed" "ps-fails-once: ps failed once"
assert_contains "$(st .message)" "could not stop process group" "ps-fails-once: the group named"
assert_contains "$(st .message)" "a process outlived the kill" "ps-fails-once: the survivor named"
assert_lacks "$(st .message)" "ps could not list the processes" "ps-fails-once: not ps"

# A worker that leads a process group of its own inside the CLI's session (as
# Codex's node_repl was seen on 2026-11-16) is stopped with the session.
new_case worker-after-answer
play codex 1 --stdout ANSWER --worker 300 --stderr "$(codex_err U1)"
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN"
took_under "$t0" 10 "worker-after-answer: the session is stopped, not waited out"
assert_eq "$rc" 0 "worker-after-answer: rc"
worker_placed codex 1 worker-after-answer
assert_eq "$(alive "$(callf codex 1 worker)" && echo yes || echo no)" no "worker-after-answer: the worker is gone"

new_case worker-deadline
play codex 1 --hold --worker 300 --stderr "$(codex_err U1)"
play codex 2 --stdout LATE --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --limit 2s --resume-limit 20s
assert_eq "$rc" 0 "worker-deadline: rc"
assert_eq "$(st .outcome)" answered_after_resume "worker-deadline: outcome"
assert_eq "$(st '.attempts[0].deadline_expired')" true "worker-deadline: the deadline expired"
worker_placed codex 1 worker-deadline
assert_eq "$(callf codex 2 prior_alive)" 0 "worker-deadline: the worker was gone before the resume started"
assert_eq "$(alive "$(callf codex 1 worker)" && echo yes || echo no)" no "worker-deadline: the worker is gone"

new_case worker-cancel
play codex 1 --hold --worker 300 --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "worker-cancel: rc"
assert_eq "$(st .outcome)" cancelled "worker-cancel: outcome"
worker_placed codex 1 worker-cancel
assert_eq "$(alive "$(callf codex 1 worker)" && echo yes || echo no)" no "worker-cancel: the worker is gone"
assert_nofile "$RUN/codex.lock" "worker-cancel: no lock"

# A process of the session outlived the kill: the attempt is recorded as
# measured and not classified, as for a survivor in the group.
new_case session-survivor
mk_ghost_session_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --stdout "$(t_agy_answer C)"
t0="$EPOCHREALTIME"
ext run --cli agy --run-dir "$RUN"
took_under "$t0" 10 "session-survivor: the run took less than 10 s"
assert_eq "$rc" 21 "session-survivor: rc"
assert_eq "$(st .outcome)" runner_failure "session-survivor: outcome"
assert_contains "$(st .message)" "could not stop session" "session-survivor: message"
assert_eq "$(st '.attempts | length')" 1 "session-survivor: the attempt is recorded"
assert_eq "$(st '.attempts[0].verdict')" null "session-survivor: and not classified"
assert_nofile "$RUN/agy.out" "session-survivor: no answer published"
assert_eq "$(ncalls agy)" 1 "session-survivor: one call"

new_case session-survivor-probe
mk_ghost_session_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "session-survivor-probe: rc"
assert_contains "$(st .message)" "could not stop session" "session-survivor-probe: message"
assert_contains "$(st .message)" "codex sandbox" "session-survivor-probe: the probe is named"
assert_file "$CALLS/sandbox.started" "session-survivor-probe: the probe ran"
assert_eq "$(ncalls codex)" 0 "session-survivor-probe: no model attempt after it"

new_case session-survivor-version
mk_ghost_session_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 21 "session-survivor-version: rc"
assert_contains "$(st .message)" "could not stop session" "session-survivor-version: message"
assert_file "$CALLS/version.started" "session-survivor-version: the version command ran"
assert_eq "$(ncalls qwen)" 0 "session-survivor-version: no model attempt after it"

new_case unexpected-exit
play codex 1 --hold --child 300 --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
kill -USR1 "$BG"
ext_wait
assert_eq "$rc" 138 "unexpected-exit: rc"
assert_eq "$(st .outcome)" runner_failure "unexpected-exit: outcome"
assert_contains "$(st .message)" "unexpected exit: a fault in the runner, or a signal it does not trap (last status " \
    "unexpected-exit: message, its status named as the last one bash saw"
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

# An unplanned exit while a process of the group outlives the kill: the
# message keeps the unexpected exit and names the survivor after it.
new_case unexpected-exit-survivor
mk_ghost_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --hold --child 300 --stdout "$(t_agy_answer C)"
ext_bg run --cli agy --run-dir "$RUN"
wait_for "$CALLS/agy.1/started"
kill -USR1 "$BG"
ext_wait
assert_eq "$rc" 138 "unexpected-exit-survivor: rc"
assert_eq "$(st .outcome)" runner_failure "unexpected-exit-survivor: outcome"
assert_contains "$(st .message)" "unexpected exit" "unexpected-exit-survivor: the unexpected exit named"
assert_contains "$(st .message)" "could not stop process group" "unexpected-exit-survivor: and the survivor"
assert_nofile "$RUN/agy.lock" "unexpected-exit-survivor: no lock"

# The runner dies while its starter is held before setsid; the finalizer
# kills the starter there, so it never runs the command (the started shell's
# own wait is the next case's).
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

# A runner killed outright (no finalizer runs) after it started a command
# that has not yet recorded its group: the started shell records it later,
# gets no go-ahead and exits 125 by itself once its wait of five seconds has
# passed, without running the command.
new_case start-abandoned-killed
mk_tool "$CASE/held/setsid" <<'EOF'
printf '%s\n' "$$" > "$CASE/setsid.pid"
(
    k=0
    until [ -e "$CASE/setsid.go" ]; do
        [ "$k" -lt 200 ] || exit 99
        sleep 0.05
        k=$((k + 1))
    done
    exec "$BIN_ROOT/utils/setsid" "$@"
) &
wait "$!"
printf '%s\n' "$?" > "$CASE/starter.rc"
EOF
EXT_PATH="$CASE/held:$CASE/bin:$BIN_ROOT/utils"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CASE/setsid.pid"
kill -KILL "$BG"
ext_wait
: > "$CASE/setsid.go"
wait_for "$RUN/codex.lock/gid" 50
wait_for "$CASE/starter.rc" 150
assert_eq "$rc" 137 "start-abandoned-killed: rc"
assert_eq "$(cat "$CASE/starter.rc" 2>/dev/null)" 125 "start-abandoned-killed: the started shell exited 125 for want of a go-ahead"
assert_nofile "$RUN/codex.lock/gid.go" "start-abandoned-killed: no go-ahead was given"
assert_nofile "$CALLS/sandbox.started" "start-abandoned-killed: the command never ran"

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

# Several text parts of one step are joined with a newline: the final step's
# into the answer, the earlier steps' into the earlier text.
new_case oc-two-parts
play qwen 1 --stdout "$(
    oc_start S
    oc_text S N1
    oc_bash S ls
    oc_text S N2
    oc_finish S tool-calls
    oc_start S
    oc_text S A
    oc_text S B
    oc_finish S stop
)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-two-parts: rc"
assert_eq "$(cat "$RUN/qwen.out" 2>/dev/null)" "$(printf 'A\nB')" "oc-two-parts: the final step's parts, one per line"
assert_eq "$(cat "$RUN/qwen.first1.earlier.txt" 2>/dev/null)" "$(printf 'N1\nN2')" \
    "oc-two-parts: the earlier step's parts, one per line"
assert_eq "$(st '.attempts[0].earlier_text_bytes')" 5 "oc-two-parts: earlier_text_bytes"

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
assert_eq "$(agent_env_is qwen 1 read-agent.json)" true "oc-argv: the read agent and the two switches"

new_case oc-effort
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN" --effort high
assert_contains "$(argv qwen 1)" '"--variant","high","--format"' "oc-effort: the variant before --format"
assert_eq "$(st .requested.effort)" high "oc-effort: requested effort"

new_case oc-full-id
play a-b 1 --stdout "$(t_oc_only S)"
ext run --cli a/b --run-dir "$RUN"
assert_begins "$OUT" "a-b: " "oc-full-id: the summary line names the prefix"
assert_file "$RUN/a-b.out" "oc-full-id: the answer file"
assert_contains "$(argv a-b 1)" '"--model","a/b"' "oc-full-id: the model id as given"
assert_eq "$(st .oc_model)" a/b "oc-full-id: oc_model"
assert_eq "$(st .name)" a/b "oc-full-id: name"

# the model id that a removed alias stood for is still taken as a full model id: the runner does not judge model ids
new_case oc-full-id-former-alias
play kimi-code-plan-global-k3 1 --stdout "$(t_oc_only S)"
ext run --cli kimi-code-plan-global/k3 --run-dir "$RUN"
assert_eq "$rc" 0 "oc-full-id-former-alias: rc"
assert_begins "$OUT" "kimi-code-plan-global-k3: answered" "oc-full-id-former-alias: the summary line names the prefix"
assert_eq "$(st .kind)" opencode "oc-full-id-former-alias: kind"
assert_eq "$(st .prefix)" kimi-code-plan-global-k3 "oc-full-id-former-alias: prefix"
assert_eq "$(st .name)" kimi-code-plan-global/k3 "oc-full-id-former-alias: name"
assert_eq "$(st .oc_model)" kimi-code-plan-global/k3 "oc-full-id-former-alias: oc_model"
assert_contains "$(argv kimi-code-plan-global-k3 1)" '"--model","kimi-code-plan-global/k3"' "oc-full-id-former-alias: the model id as given"
assert_eq "$(cat "$RUN/kimi-code-plan-global-k3.out" 2>/dev/null)" ONLY "oc-full-id-former-alias: the answer"

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
# The resume: one later attempt of the same session after an attempt that
# ended without an answer.

CODEX_RESUME_READ='["exec","resume","U1","--skip-git-repo-check","-c","sandbox_mode=\"read-only\"","--codex-x","-"]'

new_case resume-limit
play codex 1 --sleep 5 --stderr "$(codex_err U1)"
play codex 2 --stdout LATE --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --limit 1s --resume-limit 20s
assert_eq "$rc" 0 "resume-limit: rc"
assert_eq "$(st .outcome)" answered_after_resume "resume-limit: outcome"
assert_eq "$(st .phase)" resume "resume-limit: phase"
assert_eq "$(st .resume_reason)" limit "resume-limit: resume_reason"
assert_eq "$(st .resume_used)" true "resume-limit: resume_used"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" LATE "resume-limit: the answer is the resume's"
assert_eq "$(argv codex 2)" "$CODEX_RESUME_READ" "resume-limit: argv"
assert_eq "$(callf codex 2 stdin)" "$LIMIT_TEXT" "resume-limit: the limit text on standard input"
assert_contains "$(callf codex 1 parent)" ' -k 1s 1s ' "resume-limit: the first attempt under the limit"
assert_contains "$(callf codex 2 parent)" ' -k 1s 20s ' "resume-limit: the resume under the resume limit"
assert_eq "$(st '.attempts | length')" 2 "resume-limit: two attempts"
assert_eq "$(st '.attempts[1].phase')" resume "resume-limit: the second attempt's phase"
assert_eq "$(st '.tokens.reported | length')" 2 "resume-limit: one token entry per attempt"
for x in stdout stderr time exit; do
    assert_file "$RUN/codex.first1.$x" "resume-limit: codex.first1.$x"
    assert_file "$RUN/codex.resume1.$x" "resume-limit: codex.resume1.$x"
done

new_case resume-empty-edit
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --stdout OK --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit --model m1 --effort low
assert_eq "$(callf codex 2 stdin)" "$EMPTY_TEXT $AFTER_EDIT" "resume-empty-edit: the empty text and the after-edit sentence"
assert_eq "$(argv codex 2)" \
    '["exec","resume","U1","--skip-git-repo-check","-m","m1","-c","model_reasoning_effort=low","-c","sandbox_mode=\"read-only\"","--codex-x","-"]' \
    "resume-empty-edit: argv, read-only and the named model and effort"
assert_contains "$(callf codex 2 parent)" ' -k 1s 30m ' "resume-empty-edit: the default resume limit"

new_case resume-not-named
play codex 1 --sleep 5 --stderr "$(codex_err U1)"
play codex 2 --stdout LATE --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --limit 1s --resume-limit 20s
assert_eq "$(ncalls codex)" 2 "resume-not-named: two calls"
assert_eq "$(st .reported.model)" gpt-6-astra "resume-not-named: the model the header reported"
assert_eq "$(argv codex 2)" "$CODEX_RESUME_READ" "resume-not-named: no -m for a model the user did not name"

new_case child-before-resume
play codex 1 --stdout '' --child 300 --stderr "$(codex_err U1)"
play codex 2 --stdout OK --stderr "$(codex_err U1)"
t0="$EPOCHREALTIME"
ext run --cli codex --run-dir "$RUN" --level edit
took_under "$t0" 15 "child-before-resume: the run took less than 15 s"
assert_eq "$rc" 0 "child-before-resume: rc"
assert_eq "$(ncalls codex)" 2 "child-before-resume: two calls"
assert_eq "$(callf codex 2 prior_alive)" 0 "child-before-resume: no process of the first attempt is alive"

new_case survivor-no-resume
mk_ghost_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --stdout "$(t_agy_empty C)"
play agy 2 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 21 "survivor-no-resume: rc"
assert_contains "$(st .message)" "could not stop" "survivor-no-resume: message"
assert_eq "$(ncalls agy)" 1 "survivor-no-resume: no resume while a process of the attempt is reported alive"
assert_eq "$(st '.attempts | length')" 1 "survivor-no-resume: the attempt is recorded"
assert_eq "$(st '.attempts[0].verdict')" null "survivor-no-resume: and not classified"

# A process of the group outlived the kill after the attempt ended: the
# attempt is recorded as measured but not classified, because the survivor may
# still write to its files, so an answer in them is not published.
new_case survivor-unclassified
mk_ghost_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 21 "survivor-unclassified: rc"
assert_eq "$(st .outcome)" runner_failure "survivor-unclassified: outcome"
assert_contains "$(st .message)" "could not stop" "survivor-unclassified: message"
assert_eq "$(st '.attempts | length')" 1 "survivor-unclassified: the attempt is recorded"
assert_eq "$(stj '.attempts[0] | [.verdict, .rule, .handle_seen, .tokens, .skipped_lines, .earlier_text, .denied]')" \
    '[null,null,null,null,null,null,[]]' "survivor-unclassified: no verdict, no rule, no trace fields"
assert_eq "$(st '.attempts[0].exit')" 0 "survivor-unclassified: exit as measured"
assert_eq "$(st '.attempts[0].pgid')" "$(callf agy 1 pgid)" "survivor-unclassified: pgid as measured"
assert_eq "$(st '.attempts[0].signalled')" false "survivor-unclassified: signalled as measured"
assert_eq "$(st '.attempts[0].wall | type')" number "survivor-unclassified: wall as measured"
assert_file "$RUN/agy.first1.exit" "survivor-unclassified: agy.first1.exit"
assert_file "$RUN/agy.first1.time" "survivor-unclassified: agy.first1.time"
assert_nofile "$RUN/agy.out" "survivor-unclassified: no answer published"
assert_eq "$(st .answer)" null "survivor-unclassified: answer"
assert_eq "$(st .handle)" null "survivor-unclassified: no handle taken from an unclassified attempt"
assert_eq "$(ncalls agy)" 1 "survivor-unclassified: one call"

new_case resume-fails
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --exit 3 --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 14 "resume-fails: rc"
assert_eq "$(st .outcome)" cli_failure "resume-fails: outcome"
assert_eq "$(st .phase)" resume "resume-fails: phase"
assert_eq "$(ncalls codex)" 2 "resume-fails: two calls"
assert_nofile "$RUN/codex.out" "resume-fails: no answer file"

new_case resume-empty-again
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --stdout '' --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 11 "resume-empty-again: rc"
assert_eq "$(st .outcome)" empty "resume-empty-again: outcome"
assert_eq "$(st .phase)" resume "resume-empty-again: phase"
assert_eq "$(ncalls codex)" 2 "resume-empty-again: no second resume"

new_case resume-limit-again
play codex 1 --sleep 5 --stderr "$(codex_err U1)"
play codex 2 --sleep 5 --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --limit 1s --resume-limit 1s
assert_eq "$rc" 10 "resume-limit-again: rc"
assert_eq "$(st .outcome)" limit "resume-limit-again: outcome"
assert_eq "$(st .phase)" resume "resume-limit-again: phase"
assert_eq "$(ncalls codex)" 2 "resume-limit-again: no second resume"
assert_contains "$(st .message)" "resume limit of 1s" "resume-limit-again: the message names the resume limit"

new_case resume-usage-limit
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --exit 1 --stderr "$(codex_err U1 "$ul_line" "$ul_line" 'tokens used' '131,586')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "resume-usage-limit: rc"
assert_eq "$(st .outcome)" usage_limit "resume-usage-limit: outcome"
assert_eq "$(st .phase)" resume "resume-usage-limit: phase"
assert_eq "$(ncalls codex)" 2 "resume-usage-limit: two calls"

new_case resume-unreadable
play qwen 1 --stdout "$(t_oc_empty_final S)"
play qwen 2 --stdout "$(oc_start S; oc_text S X)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 15 "resume-unreadable: rc"
assert_eq "$(st .phase)" resume "resume-unreadable: phase"

new_case no-handle
play codex 1 --stdout '' --stderr 'no header'
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 16 "no-handle: rc"
assert_eq "$(st .outcome)" no_handle "no-handle: outcome"
assert_eq "$(ncalls codex)" 1 "no-handle: no resume"
# The record a handle failure before the resume leaves, on which a continue's
# checks rely: decided in the resume phase, with the resume itself unused.
assert_eq "$(st .phase)" resume "no-handle: phase"
assert_eq "$(st .resume_used)" false "no-handle: resume_used"
assert_eq "$(st .resume_reason)" null "no-handle: resume_reason"
assert_eq "$(st '.attempts | length')" 1 "no-handle: one attempt"

new_case two-handles
play agy 1 --stdout "$(agy_init C; agy_cmd D ls; agy_result C SUCCESS '')"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 17 "two-handles: rc"
assert_eq "$(st .outcome)" handle_conflict "two-handles: outcome"
assert_eq "$(ncalls agy)" 1 "two-handles: no resume"
assert_eq "$(st .phase)" resume "two-handles: phase"
assert_eq "$(st .resume_used)" false "two-handles: resume_used"
assert_eq "$(st .resume_reason)" null "two-handles: resume_reason"
assert_eq "$(st '.attempts | length')" 1 "two-handles: one attempt"

# A read of the session handles that fails is the runner's fault, named as
# such; it is never taken for no handle or no conflict. Here the first
# attempt's read fails (a jq that refuses the handles of the events).
new_case handles-unreadable-first
mk_tool "$CASE/failjq/jq" <<'EOF'
if [ "$1" = -r ] && [ "$2" = -s ] && [[ $3 == *' oc_handles' ]]; then
    printf '%s\n' 'jq: error: cannot read the events' >&2
    exit 5
fi
exec "$BIN_ROOT/utils/jq" "$@"
EOF
EXT_PATH="$CASE/failjq:$CASE/bin:$BIN_ROOT/utils"
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 21 "handles-unreadable-first: rc"
assert_eq "$(st .outcome)" runner_failure "handles-unreadable-first: outcome"
assert_eq "$(st .message)" "cannot read the session handles of attempt first1" "handles-unreadable-first: message"
assert_nofile "$RUN/qwen.out" "handles-unreadable-first: no answer"
assert_eq "$(ncalls qwen)" 1 "handles-unreadable-first: one call"

# The same for a later attempt's check of rule 2: an awk that cannot read the
# resume's standard error the first time it looks for the session id there,
# which is that check; the record's read after it would succeed.
new_case handles-unreadable-resume
mk_tool "$CASE/failawk/awk" <<'EOF'
for a in "$@"; do last="$a"; done
for a in "$@"; do
    if [ "$a" = 'k=session id: ' ] && [[ $last == *.resume1.stderr ]] && mkdir "$CASE/awk-failed" 2>/dev/null; then
        printf 'awk: cannot open "%s"\n' "$last" >&2
        exit 2
    fi
done
exec "$BIN_ROOT/utils/awk" "$@"
EOF
EXT_PATH="$CASE/failawk:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --stdout OK --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "handles-unreadable-resume: rc"
assert_eq "$(st .outcome)" runner_failure "handles-unreadable-resume: outcome"
assert_eq "$(st .phase)" resume "handles-unreadable-resume: phase"
assert_eq "$(st .message)" "cannot read the session handles of attempt resume1" "handles-unreadable-resume: message"
assert_nofile "$RUN/codex.out" "handles-unreadable-resume: no answer"

# Codex's other reads of its files, and agy's quota text on standard error,
# fail the same way: a read that fails is never taken for an empty answer,
# no header, no tokens or no usage limit. Codex's standard output, made
# unreadable while the attempt runs, would otherwise be an empty answer and
# a resume. As root a file without its read bits can still be read.
new_case codex-answer-unreadable
if [ "$(id -u)" = 0 ]; then
    printf 'ext-run.test: codex-answer-unreadable skipped: as root a file without its read bits can be read\n' >&2
else
    play codex 1 --stdout A --stderr "$(codex_err U1)" --hold
    ext_bg run --cli codex --run-dir "$RUN"
    wait_for "$CALLS/codex.1/started"
    chmod 000 "$RUN/codex.first1.stdout"
    release codex 1
    ext_wait
    assert_eq "$rc" 21 "codex-answer-unreadable: rc"
    assert_eq "$(st .outcome)" runner_failure "codex-answer-unreadable: outcome"
    assert_eq "$(st .message)" "cannot read the answer in $RUN/codex.first1.stdout" "codex-answer-unreadable: message"
    assert_nofile "$RUN/codex.out" "codex-answer-unreadable: no answer"
    assert_eq "$(ncalls codex)" 1 "codex-answer-unreadable: no resume"
    chmod 600 "$RUN/codex.first1.stdout"
fi

# The header's model and effort: an awk that cannot read the first
# attempt's standard error when it looks for that key there.
for key in model 'reasoning effort'; do
    new_case "codex-header-unreadable-${key// /-}"
    mk_tool "$CASE/failawk/awk" <<EOF
for a in "\$@"; do last="\$a"; done
for a in "\$@"; do
    if [ "\$a" = 'k=$key: ' ] && [[ \$last == *.first1.stderr ]]; then
        printf 'awk: cannot open "%s"\n' "\$last" >&2
        exit 2
    fi
done
exec "\$BIN_ROOT/utils/awk" "\$@"
EOF
    EXT_PATH="$CASE/failawk:$CASE/bin:$BIN_ROOT/utils"
    answering codex 1
    ext run --cli codex --run-dir "$RUN"
    assert_eq "$rc" 21 "$CASE_NAME: rc"
    assert_eq "$(st .outcome)" runner_failure "$CASE_NAME: outcome"
    assert_eq "$(st .message)" "cannot read the header in $RUN/codex.first1.stderr" "$CASE_NAME: message"
    assert_nofile "$RUN/codex.out" "$CASE_NAME: no answer"
done

# The tokens used lines and the usage-limit error: a tail that cannot read
# the first attempt's standard error.
mk_fail_tail() { # dir [glob [n]]: a tail there that fails on a file whose path matches the glob (*.first1.stderr by default), on every read of one or on the nth only, and runs the real tail otherwise
    mk_tool "$1/tail" <<'EOF' &&
read -r glob nth < "${0%/*}/tail.fail"
for a in "$@"; do last="$a"; done
if [[ $last == $glob ]]; then
    k=$(($(cat "${0%/*}/tail.count" 2>/dev/null || echo 0) + 1))
    echo "$k" > "${0%/*}/tail.count"
    if [ "$nth" = all ] || [ "$nth" = "$k" ]; then
        printf 'tail: cannot open %s for reading\n' "$last" >&2
        exit 1
    fi
fi
exec "$BIN_ROOT/utils/tail" "$@"
EOF
        printf '%s %s\n' "${2:-*.first1.stderr}" "${3:-all}" > "$1/tail.fail"
}

new_case codex-tokens-unreadable
mk_fail_tail "$CASE/failtail"
EXT_PATH="$CASE/failtail:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout ANSWER --stderr "$(codex_err U1 'tokens used' '8,834')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "codex-tokens-unreadable: rc"
assert_eq "$(st .message)" "cannot read the tokens of attempt first1" "codex-tokens-unreadable: message"
assert_nofile "$RUN/codex.out" "codex-tokens-unreadable: no answer"

# Taken for no usage limit, the attempt would fall to rule 8, a record that
# cannot be continued.
new_case codex-usage-limit-unreadable
mk_fail_tail "$CASE/failtail"
EXT_PATH="$CASE/failtail:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --exit 1 --stderr "$(codex_err U1 "$ul_line" "$ul_line" 'tokens used' '131,586')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "codex-usage-limit-unreadable: rc"
assert_eq "$(st .outcome)" runner_failure "codex-usage-limit-unreadable: outcome"
assert_eq "$(st .message)" "cannot read the usage-limit error in $RUN/codex.first1.stderr" \
    "codex-usage-limit-unreadable: message"
assert_eq "$(ncalls codex)" 1 "codex-usage-limit-unreadable: one call"

# agy's quota text on standard error, when the result's error does not hold
# its own: a jq that cannot read the first attempt's standard error.
new_case agy-quota-stderr-unreadable
mk_tool "$CASE/failjq/jq" <<'EOF'
for a in "$@"; do last="$a"; done
if [[ $last == *agy.first1.stderr ]]; then
    printf 'jq: error: Could not open %s: Permission denied\n' "$last" >&2
    exit 2
fi
exec "$BIN_ROOT/utils/jq" "$@"
EOF
EXT_PATH="$CASE/failjq:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --exit 3 --stdout "$(t_agy_quota_door C1 45m | jq -c 'if .event == "result" then .result.error = "" else . end')" \
    --stderr "$(agy_quota_err 45m)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 21 "agy-quota-stderr-unreadable: rc"
assert_eq "$(st .outcome)" runner_failure "agy-quota-stderr-unreadable: outcome"
assert_eq "$(st .message)" "cannot read the quota error in $RUN/agy.first1.stderr" "agy-quota-stderr-unreadable: message"
assert_eq "$(ncalls agy)" 1 "agy-quota-stderr-unreadable: one call"

# Rule 8 rests on the exit status, which was read; its reason is the last
# line of standard error. A standard error that cannot be read leaves the
# outcome a CLI failure, and the message says that the reason could not be
# read and names the file. For Codex the usage-limit check reads the same
# file first, so its tail fails on the second read only.
new_case rule8-stderr-unreadable
mk_fail_tail "$CASE/failtail"
mk_fail_tail "$CASE/failtail2" '*.first1.stderr' 2
play agy 1 --exit 3 --stdout "$(t_agy_answer C)" --stderr 'agy: boom'
play qwen 1 --exit 3 --stdout "$(t_oc_only S)" --stderr 'opencode: boom'
play codex 1 --exit 3 --stderr "$(codex_err U1 boom)"
for k in agy:agy:failtail qwen:opencode:failtail codex:codex:failtail2; do
    IFS=: read -r p kind d <<< "$k"
    EXT_PATH="$CASE/$d:$CASE/bin:$BIN_ROOT/utils"
    ext run --cli "$p" --run-dir "$RUN"
    l="rule8-stderr-unreadable $p"
    assert_eq "$rc" 14 "$l: rc"
    assert_eq "$(st .outcome)" cli_failure "$l: outcome"
    assert_eq "$(st '.attempts[0].rule')" 8 "$l: rule"
    assert_eq "$(st .message)" "$kind exited with status 3; its standard error could not be read: $RUN/$p.first1.stderr" \
        "$l: message"
    assert_eq "$(ncalls "$p")" 1 "$l: one call"
done
assert_eq "$(cat "$CASE/failtail2/tail.count")" 3 "rule8-stderr-unreadable: Codex's usage-limit check, rule 8 and the tokens read the file"

# The same for the reason of a failed Codex sandbox probe: the probe's own
# exit status decides, and the message says its standard error could not be
# read. A readable one gives its last line.
new_case probe-stderr-unreadable
echo 1 > "$SCN/codex.sandbox.exit"
ext run --cli codex --run-dir "$RUN"
assert_eq "$(st .message)" "the Codex sandbox probe failed with status 1: probe-stderr; its standard error is in $RUN/codex.probe.err" \
    "probe-stderr-unreadable: a readable standard error gives the reason"
RUN="$CASE/run2"
make_run "$RUN"
mk_fail_tail "$CASE/failtail" '*/codex.probe.err'
EXT_PATH="$CASE/failtail:$CASE/bin:$BIN_ROOT/utils"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "probe-stderr-unreadable: rc"
assert_eq "$(st .outcome)" prerequisite_failed "probe-stderr-unreadable: outcome"
assert_eq "$(st .message)" "the Codex sandbox probe failed with status 1; its standard error could not be read: $RUN/codex.probe.err" \
    "probe-stderr-unreadable: message"
assert_eq "$(ncalls codex)" 0 "probe-stderr-unreadable: no call"

# And for the reason of a failed opencode --version, whose standard error is
# in the lock directory.
new_case version-stderr-unreadable
mk_fail_tail "$CASE/failtail" '*/qwen.lock/cmd.err'
EXT_PATH="$CASE/failtail:$CASE/bin:$BIN_ROOT/utils"
echo 1 > "$SCN/opencode.version.exit"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 19 "version-stderr-unreadable: rc"
assert_eq "$(st .outcome)" unsupported_version "version-stderr-unreadable: outcome"
assert_eq "$(st .message)" "opencode --version failed with status 1; its standard error could not be read: $RUN/qwen.lock/cmd.err" \
    "version-stderr-unreadable: message"
assert_eq "$(ncalls qwen)" 0 "version-stderr-unreadable: no call"

# The last lines of a standard error are split from a here-string. bash
# writes one longer than a pipe holds (65,536 bytes by default, two pages
# once the user's pipes have reached pipe-user-pages-soft) to a temporary
# file in TMPDIR, else /tmp; when that file cannot be made or written (a
# full or unusable temporary directory), the lines are not read, and the
# read fails as one that cannot open the file does. Here the last lines
# hold a line of 100,000 bytes, and TMPDIR names a directory that bash
# takes as writable, its write bit set, and cannot make a file in, its
# search bit cleared. With a usable TMPDIR the same lines are read whole.
# Each of the three readers of those lines fails as it does for a file it
# cannot open: Codex's usage-limit error, Codex's tokens used lines and
# rule 8's reason.
new_case tail-temp-file-fails
printf -v long '%*s' 100000 ''
long="${long// /x}"
mkdir -m 700 "$CASE/tmp" "$CASE/nosearch"
EXT_VARS=("TMPDIR=$CASE/tmp")
play codex 1 --exit 1 --stderr "$(codex_err U1 "$long" "$ul_line" 'tokens used' '131,586')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "tail-temp-file-fails: a usable TMPDIR: rc"
assert_eq "$(st '.attempts[0].rule')" 5 "tail-temp-file-fails: a usable TMPDIR: the usage limit is read"
if [ "$(id -u)" = 0 ]; then
    printf 'ext-run.test: tail-temp-file-fails skipped in part: as root a directory without its search bit can be searched\n' >&2
else
    chmod 600 "$CASE/nosearch"
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    RUN="$CASE/run2"
    make_run "$RUN"
    play codex 2 --exit 1 --stderr "$(codex_err U2 "$long" "$ul_line" 'tokens used' '131,586')"
    ext run --cli codex --run-dir "$RUN"
    l='tail-temp-file-fails usage limit'
    assert_eq "$rc" 21 "$l: rc"
    assert_eq "$(st .outcome)" runner_failure "$l: outcome"
    assert_eq "$(st .message)" "cannot read the usage-limit error in $RUN/codex.first1.stderr" "$l: message"
    assert_contains "$ERR" 'cannot create temp file for here-document' "$l: the temporary file could not be made"
    RUN="$CASE/run3"
    make_run "$RUN"
    play codex 3 --stdout ANSWER --stderr "$(codex_err U3 "$long" 'tokens used' '8,834')"
    ext run --cli codex --run-dir "$RUN"
    l='tail-temp-file-fails tokens'
    assert_eq "$rc" 21 "$l: rc"
    assert_eq "$(st .message)" "cannot read the tokens of attempt first1" "$l: message"
    assert_nofile "$RUN/codex.out" "$l: no answer"
    RUN="$CASE/run4"
    make_run "$RUN"
    play agy 1 --exit 3 --stdout "$(t_agy_answer C)" --stderr "$(printf '%s\n' "$long" 'agy: boom')"
    ext run --cli agy --run-dir "$RUN"
    l='tail-temp-file-fails rule 8'
    assert_eq "$rc" 14 "$l: rc"
    assert_eq "$(st '.attempts[0].rule')" 8 "$l: rule"
    assert_eq "$(st .message)" "agy exited with status 3; its standard error could not be read: $RUN/agy.first1.stderr" "$l: message"
    chmod 700 "$CASE/nosearch"
    assert_eq "$(ncalls codex)" 3 "tail-temp-file-fails: one call per Codex run"
fi

# The other reads that take a text whose length the runner does not bound
# from a here-string meet the same failure (see tail-temp-file-fails). Each
# read that decides something counts a text it could not read as the run
# already counts a failure of that read: the process table as a ps that
# cannot list the processes (a claim's owner running, a stop's group or
# session alive), and the session handles and the status object as a runner
# failure named after the read. A stop looks at the table at every poll,
# and bash's warning about the temporary file is kept off standard error
# there. The reason in a git message is split into words by the shell
# itself, with no here-string. Each case first reads the same long text
# under a usable TMPDIR.
#
# Step 2's look at the process table already refuses one it cannot read, as
# it refuses a ps that fails (ps-cannot-list).
new_case ps-probe-temp-file-fails
mkdir -m 700 "$CASE/tmp"
mk_pad_ps "$CASE/padps" "$PS_PROBE"
EXT_PATH="$CASE/padps:$CASE/bin:$BIN_ROOT/utils"
EXT_VARS=("TMPDIR=$CASE/tmp")
answering agy 1
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "ps-probe-temp-file-fails: a usable TMPDIR: rc"
if nosearch_ok ps-probe-temp-file-fails; then
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    RUN="$CASE/run2"
    make_run "$RUN"
    ext run --cli agy --run-dir "$RUN"
    l='ps-probe-temp-file-fails'
    assert_eq "$rc" 18 "$l: rc"
    assert_eq "$OUT" \
        "agy: prerequisite_failed (a ps that lists the processes is needed: $CASE/padps/ps $PS_PROBE does not show the runner's own process); status: none" \
        "$l: the summary names ps"
    assert_contains "$ERR" 'cannot create temp file for here-document' "$l: the table could not be read"
    assert_nofile "$RUN/agy.status" "$l: no status"
    assert_nofile "$RUN/agy.lock" "$l: no claim"
    chmod 700 "$CASE/nosearch"
    assert_eq "$(ncalls agy)" 1 "$l: no call after the first run's"
fi

# A claim's owner that is running, behind a table bash cannot read, is taken
# to be running, with ps named and no removal command (as in
# claimed-ps-fails).
new_case claimed-temp-file-fails
mkdir -m 700 "$CASE/tmp"
mk_pad_ps "$CASE/padps" '-A -o pid=,stat='
EXT_PATH="$CASE/padps:$CASE/bin:$BIN_ROOT/utils"
EXT_VARS=("TMPDIR=$CASE/tmp")
mkdir "$RUN/codex.lock"
echo "$$" > "$RUN/codex.lock/pid"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "claimed-temp-file-fails: a usable TMPDIR: rc"
assert_contains "$ERR" "pid $$ is running" "claimed-temp-file-fails: a usable TMPDIR: the owner is running"
if nosearch_ok claimed-temp-file-fails; then
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    ext run --cli codex --run-dir "$RUN"
    l='claimed-temp-file-fails'
    assert_eq "$rc" 64 "$l: rc"
    assert_contains "$ERR" "pid $$ may be running (ps could not list the processes)" "$l: the owner taken to be running, and ps named"
    assert_lacks "$ERR" "rm -r" "$l: no removal command"
    assert_contains "$ERR" 'cannot create temp file for here-document' "$l: the table could not be read"
    assert_file "$RUN/codex.lock/pid" "$l: the claim stays"
    chmod 700 "$CASE/nosearch"
fi

# A stop's look at a group behind a table bash cannot read: the group is
# taken to be alive, so the stop goes on to the kill and the run ends as a
# runner failure naming the group and ps (as in ps-fails). The attempt
# leaves a child in its group. With the session's table readable, the
# session stop would reach the child anyway; with both tables unreadable,
# the group's kill is the only one that reaches it.
new_case group-temp-file-fails
mkdir -m 700 "$CASE/tmp"
mk_pad_ps "$CASE/padg" '-A -o pgid= -o stat='
mk_pad_ps "$CASE/padgs" '-A -o pgid= -o stat=' '-A -o pid=,sid=,stat='
EXT_PATH="$CASE/padgs:$CASE/bin:$BIN_ROOT/utils"
EXT_VARS=("TMPDIR=$CASE/tmp")
play agy 1 --stdout "$(t_agy_answer C)" --child 300
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "group-temp-file-fails: a usable TMPDIR: rc"
assert_eq "$(alive "$(callf agy 1 child)" && echo yes || echo no)" no "group-temp-file-fails: a usable TMPDIR: the child is gone"
if nosearch_ok group-temp-file-fails; then
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    for k in 2:padg 3:padgs; do
        IFS=: read -r n d <<< "$k"
        EXT_PATH="$CASE/$d:$CASE/bin:$BIN_ROOT/utils"
        RUN="$CASE/run$n"
        make_run "$RUN"
        play agy "$n" --stdout "$(t_agy_answer C)" --child 300
        ext run --cli agy --run-dir "$RUN"
        l="group-temp-file-fails $d"
        assert_eq "$rc" 21 "$l: rc"
        assert_eq "$(st .outcome)" runner_failure "$l: outcome"
        assert_contains "$(st .message)" "could not stop process group" "$l: the group named"
        assert_contains "$(st .message)" "ps could not list the processes" "$l: the cause named"
        assert_lacks "$ERR" 'cannot create temp file' "$l: no warning at each look"
        assert_eq "$(st '.attempts[0].verdict')" null "$l: the attempt is not classified"
        assert_nofile "$RUN/agy.out" "$l: no answer published"
        assert_eq "$(alive "$(callf agy "$n" child)" && echo yes || echo no)" no "$l: the child is gone"
    done
    chmod 700 "$CASE/nosearch"
fi

# The same for a stop's look at the session, with a worker that leads a
# process group of its own inside the attempt's session: the session is
# taken to be alive, and the run ends as a runner failure naming the session
# and ps. Without a table the stop has no process to send the kill to, so
# here the case stops the worker itself.
new_case session-temp-file-fails
mkdir -m 700 "$CASE/tmp"
mk_pad_ps "$CASE/pads" '-A -o pid=,sid=,stat='
EXT_PATH="$CASE/pads:$CASE/bin:$BIN_ROOT/utils"
EXT_VARS=("TMPDIR=$CASE/tmp")
play agy 1 --stdout "$(t_agy_answer C)" --worker 300
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "session-temp-file-fails: a usable TMPDIR: rc"
worker_placed agy 1 "session-temp-file-fails: a usable TMPDIR"
assert_eq "$(alive "$(callf agy 1 worker)" && echo yes || echo no)" no "session-temp-file-fails: a usable TMPDIR: the worker is gone"
if nosearch_ok session-temp-file-fails; then
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    RUN="$CASE/run2"
    make_run "$RUN"
    play agy 2 --stdout "$(t_agy_answer C)" --worker 300
    ext run --cli agy --run-dir "$RUN"
    l='session-temp-file-fails'
    assert_eq "$rc" 21 "$l: rc"
    assert_eq "$(st .outcome)" runner_failure "$l: outcome"
    assert_contains "$(st .message)" "could not stop session" "$l: the session named"
    assert_contains "$(st .message)" "ps could not list the processes" "$l: the cause named"
    assert_lacks "$ERR" 'cannot create temp file' "$l: no warning at each look"
    assert_eq "$(st '.attempts[0].verdict')" null "$l: the attempt is not classified"
    assert_nofile "$RUN/agy.out" "$l: no answer published"
    w="$(callf agy 2 worker)"
    if alive "$w"; then kill -KILL "$w"; fi
    chmod 700 "$CASE/nosearch"
fi

# A list of session handles bash cannot read is not "no handle": the run
# ends as a runner failure named after the read, as for a list that cannot
# be taken from the attempt's files. Here the one handle is 70,000 bytes.
new_case handles-temp-file-fails
big="$(printf 's%.0s' {1..70000})"
mkdir -m 700 "$CASE/tmp"
EXT_VARS=("TMPDIR=$CASE/tmp")
play qwen 1 --stdout "$(t_oc_only "$big" A)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "handles-temp-file-fails: a usable TMPDIR: rc"
assert_eq "$(st '.handle | length')" 70000 "handles-temp-file-fails: a usable TMPDIR: the handle is read"
if nosearch_ok handles-temp-file-fails; then
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    RUN="$CASE/run2"
    make_run "$RUN"
    play qwen 2 --stdout "$(t_oc_only "$big" A)"
    ext run --cli qwen --run-dir "$RUN"
    l='handles-temp-file-fails'
    assert_eq "$rc" 21 "$l: rc"
    assert_eq "$(st .outcome)" runner_failure "$l: outcome"
    assert_eq "$(st .message)" "cannot read the session handles of attempt first1" "$l: message"
    assert_contains "$ERR" 'cannot create temp file for here-document' "$l: the temporary file could not be made"
    assert_nofile "$RUN/qwen.out" "$l: no answer published"
    chmod 700 "$CASE/nosearch"
    assert_eq "$(ncalls qwen)" 2 "$l: one call per run"
fi

# Whether the one resume is still unused is read from the status object,
# which a denied call's command of 70,000 bytes makes longer than a pipe
# holds once the attempt is recorded. The attempt has no session handle, so
# with a usable TMPDIR the resume is due and ends as no handle. A status
# object bash cannot read leaves the resume neither used nor unused: the run
# ends as a runner failure named after the read, and no resume starts. The
# final status needs the same read of the object, so with a TMPDIR that
# stays unusable it cannot be written either: the summary names no status
# file, and the read's own message is on standard error.
new_case resume-temp-file-fails
big="$(printf 'x%.0s' {1..70000})"
mkdir -m 700 "$CASE/tmp"
EXT_VARS=("TMPDIR=$CASE/tmp")
play qwen 1 --stdout "$(oc_start ''; oc_bash '' "$big" error "$RULE_TEXT"; oc_finish '' stop)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 16 "resume-temp-file-fails: a usable TMPDIR: rc"
assert_eq "$(st .phase)" resume "resume-temp-file-fails: a usable TMPDIR: the resume was due"
assert_eq "$(st '.attempts[0].verdict')" empty "resume-temp-file-fails: a usable TMPDIR: the attempt ended empty"
assert_eq "$(st '.denied[0].input | length')" 70000 "resume-temp-file-fails: a usable TMPDIR: the command is recorded"
if nosearch_ok resume-temp-file-fails; then
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    RUN="$CASE/run2"
    make_run "$RUN"
    play qwen 2 --stdout "$(oc_start ''; oc_bash '' "$big" error "$RULE_TEXT"; oc_finish '' stop)"
    ext run --cli qwen --run-dir "$RUN"
    l='resume-temp-file-fails'
    assert_eq "$rc" 21 "$l: rc"
    assert_contains "$ERR" "cannot read resume_used from the status object" "$l: the read named"
    assert_begins "$OUT" "qwen: runner_failure (" "$l: the outcome"
    assert_ends "$OUT" "status: none" "$l: no status file"
    chmod 700 "$CASE/nosearch"
    assert_eq "$(ncalls qwen)" 2 "$l: no resume started"
fi

# git's standard error reaches a message as its words on one line, the
# first 10,000 characters split into words by the shell itself, with no
# here-string, so a long one still gives git's reason where bash could not
# make a temporary file, whatever size a pipe has.
new_case git-reason-temp-file-fails
mk_tool "$CASE/failgit/git" <<'EOF'
printf 'fatal: VARS-REASON\n' >&2
printf 'w %.0s' {1..40000} >&2
exit 1
EOF
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
mkdir -m 700 "$CASE/tmp"
EXT_VARS=("TMPDIR=$CASE/tmp")
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "git-reason-temp-file-fails: a usable TMPDIR: rc"
assert_contains "$OUT" "failed with status 1 (fatal: VARS-REASON w w w" "git-reason-temp-file-fails: a usable TMPDIR: git's reason"
if nosearch_ok git-reason-temp-file-fails; then
    EXT_VARS=("TMPDIR=$CASE/nosearch")
    ext run --cli qwen --run-dir "$RUN"
    l='git-reason-temp-file-fails'
    assert_eq "$rc" 64 "$l: rc"
    assert_contains "$OUT" "failed with status 1 (fatal: VARS-REASON w w w" "$l: git's reason"
    assert_lacks "$ERR" 'cannot create temp file' "$l: no temporary file was needed"
    chmod 700 "$CASE/nosearch"
fi
assert_eq "$(ncalls qwen)" 0 "git-reason-temp-file-fails: no call"

# The same in a UTF-8 locale, where bash counts a six-byte form as one
# character: git's reason followed by 16,000 such forms, about 96,000
# bytes, more than a pipe holds; its first 10,000 characters are about
# 60,000 bytes.
new_case git-reason-six-byte-temp-file-fails
mk_tool "$CASE/failgit/git" <<'EOF'
printf 'fatal: SIX-REASON\n' >&2
printf '\xfc\x84\x80\x80\x80\x80%.0s' {1..16000} >&2
exit 1
EOF
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
mkdir -m 700 "$CASE/tmp"
l='git-reason-six-byte-temp-file-fails'
assert_eq "$(LC_ALL=C.UTF-8 && s=$'\xfc\x84\x80\x80\x80\x80' && printf %s "${#s}")" 1 "$l: C.UTF-8 counts a six-byte form as one character"
EXT_VARS=("TMPDIR=$CASE/tmp" LC_ALL=C.UTF-8)
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "$l: a usable TMPDIR: rc"
assert_contains "$OUT" "failed with status 1 (fatal: SIX-REASON " "$l: a usable TMPDIR: git's reason"
if nosearch_ok "$l"; then
    EXT_VARS=("TMPDIR=$CASE/nosearch" LC_ALL=C.UTF-8)
    ext run --cli qwen --run-dir "$RUN"
    assert_eq "$rc" 64 "$l: rc"
    assert_contains "$OUT" "failed with status 1 (fatal: SIX-REASON " "$l: git's reason"
    assert_lacks "$ERR" 'cannot create temp file' "$l: no temporary file was needed"
    chmod 700 "$CASE/nosearch"
fi
assert_eq "$(ncalls qwen)" 0 "$l: no call"

new_case one-handle-repeated
play agy 1 --stdout "$(agy_init C; agy_cmd C ls; agy_result C SUCCESS '')"
play agy 2 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "one-handle-repeated: rc"
assert_eq "$(st .handle)" C "one-handle-repeated: handle"

new_case wrong-handle
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --sleep 5 --stderr "$(codex_err U2)"
ext run --cli codex --run-dir "$RUN" --resume-limit 1s
assert_eq "$rc" 17 "wrong-handle: rc"
assert_eq "$(st .outcome)" handle_conflict "wrong-handle: outcome"
assert_eq "$(st '.attempts[1].rule')" 2 "wrong-handle: rule 2, before the deadline"
assert_eq "$(st .handle)" U1 "wrong-handle: the handle is still the first attempt's"

new_case wrong-handle-ul
play codex 1 --stdout '' --stderr "$(codex_err U1)"
# shellcheck disable=SC1112  # the typographic apostrophe of Codex's message
play codex 2 --exit 1 --stderr "$(codex_err U2 'ERROR: You’ve hit your usage limit. try again at 2:40 PM.')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 17 "wrong-handle-ul: rc"
assert_eq "$(st .outcome)" handle_conflict "wrong-handle-ul: outcome"
assert_eq "$(st '.attempts[1].rule')" 2 "wrong-handle-ul: the handle check comes before the usage limit"

new_case later-no-handle
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --stdout OK --stderr 'no header'
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "later-no-handle: rc (no handle in a later attempt's files is no conflict)"

new_case agy-resume
play agy 1 --stdout "$(t_agy_empty C)"
play agy 2 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN" --model gm
assert_eq "$(argv agy 2)" "$(jq -cn --arg t "$EMPTY_TEXT" \
    '["--conversation", "C", "-p", $t, "--output-format", "stream-json", "--model", "gm", "--agy-x"]')" \
    "agy-resume: argv"

new_case agy-edit-resume
play agy 1 --stdout "$(t_agy_empty C)"
play agy 2 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN" --model gm --level edit
assert_eq "$(ncalls agy)" 2 "agy-edit-resume: two calls"
assert_contains "$(argv agy 1)" '"--mode","accept-edits"' "agy-edit-resume: the first attempt at the edit level"
assert_eq "$(argv agy 2)" "$(jq -cn --arg t "$EMPTY_TEXT $AFTER_EDIT" \
    '["--conversation", "C", "-p", $t, "--output-format", "stream-json", "--model", "gm", "--agy-x"]')" \
    "agy-edit-resume: argv, the after-edit sentence and no --mode"

new_case agy-resume-tokens
play agy 1 --stdout "$(agy_init C; agy_result C SUCCESS '' null 100 60 30 10)"
play agy 2 --stdout "$(agy_init C; agy_result C SUCCESS ANSWER null 130 80 35 15)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(st '.attempts[0].tokens.total')" 100 "agy-resume-tokens: the first attempt's total"
assert_eq "$(st '.attempts[1].tokens.total')" 130 "agy-resume-tokens: the resume's total"
assert_eq "$(stj .tokens)" '{"duration_seconds":1.5,"input":80,"output":35,"thinking":15,"total":130,"turns":1}' \
    "agy-resume-tokens: the run's are the last attempt's, not a sum"

new_case agy-denied-no-resume
play agy 1 --stdout "$(t_agy_denied C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$(ncalls agy)" 1 "agy-denied-no-resume: one call"
assert_eq "$(st .outcome)" denied "agy-denied-no-resume: outcome"

new_case agy-denied-at-deadline
play agy 1 --stdout-early "$(t_agy_denied C)" --sleep 5
play agy 2 --stdout "$(t_agy_answer C LATE)"
ext run --cli agy --run-dir "$RUN" --limit 1s
assert_eq "$(st '.attempts[0].rule')" 3 "agy-denied-at-deadline: rule 3, the deadline before the denial"
assert_eq "$(st '.attempts[0].verdict')" limit "agy-denied-at-deadline: verdict"
assert_eq "$(st '.attempts[0].denied | length')" 1 "agy-denied-at-deadline: the denial is recorded"
assert_eq "$rc" 0 "agy-denied-at-deadline: rc"
assert_eq "$(st .outcome)" answered_after_resume "agy-denied-at-deadline: outcome"

new_case agy-denied-in-resume
play agy 1 --stdout "$(t_agy_empty C)"
play agy 2 --stdout "$(t_agy_denied C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 12 "agy-denied-in-resume: rc"
assert_eq "$(st .outcome)" denied "agy-denied-in-resume: outcome"
assert_eq "$(st .phase)" resume "agy-denied-in-resume: phase"
assert_eq "$(ncalls agy)" 2 "agy-denied-in-resume: two calls"

new_case oc-resume
play qwen 1 --stdout "$(t_oc_empty_final S)"
play qwen 2 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN" --effort high
assert_eq "$(argv qwen 2)" "$(jq -cn --arg t "$EMPTY_TEXT" '["run", "--pure", "-s", "S", "--agent", "ext-read",
    "--model", "alibaba-token-plan/qwen3.8-max", "--variant", "high", "--format", "json", $t]')" "oc-resume: argv"
assert_eq "$(agent_env_is qwen 2 read-agent.json)" true "oc-resume: the read agent and the two switches"
assert_eq "$(cat "$RUN/qwen.first1.earlier.txt" 2>/dev/null)" NOTE "oc-resume: the first attempt's note is kept"
assert_eq "$(cat "$RUN/qwen.out" 2>/dev/null)" ONLY "oc-resume: the answer"
assert_eq "$(stj .tokens)" '{"cached":3,"cost":1.5,"input":12,"output":9,"reasoning":6,"steps":3,"total":30}' \
    "oc-resume: the run's tokens are the sums over both attempts"

new_case oc-edit-resume
play qwen 1 --stdout "$(t_oc_empty_final S)"
play qwen 2 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN" --effort high --level edit
assert_contains "$(argv qwen 1)" '"--agent","ext-edit"' "oc-edit-resume: the first attempt with the edit agent"
assert_contains "$(argv qwen 2)" '"--agent","ext-read"' "oc-edit-resume: the resume with the read agent"
assert_eq "$(agent_env_is qwen 1 edit-agent.json)" true "oc-edit-resume: the first attempt's environment"
assert_eq "$(agent_env_is qwen 2 read-agent.json)" true "oc-edit-resume: the resume's environment is the read agent's"

new_case oc-denied-empty
play qwen 1 --stdout "$(
    oc_start S
    oc_read S /x error "$RULE_TEXT"
    oc_read S /y error "$RULE_TEXT"
    oc_finish S tool-calls
    oc_start S
    oc_finish S stop
)"
play qwen 2 --stdout "$(
    oc_start S
    oc_read S /z error "$RULE_TEXT"
    oc_finish S tool-calls
    oc_start S
    oc_text S A
    oc_finish S stop
)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-denied-empty: rc"
assert_eq "$(st '.denied | length')" 3 "oc-denied-empty: the denials of both attempts"
assert_eq "$(st '.denied[2].attempt')" resume1 "oc-denied-empty: the resume's denial"

new_case oc-ask-refused-resume
play qwen 1 --stdout "$(oc_start S; oc_bash S 'echo x' error 'x ASK-REFUSED y'; oc_finish S tool-calls)"
play qwen 2 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-ask-refused-resume: rc"
assert_eq "$(st .outcome)" answered_after_resume "oc-ask-refused-resume: outcome"
assert_eq "$(st .phase)" resume "oc-ask-refused-resume: phase"
assert_eq "$(st '.attempts[0].rule')" 12 "oc-ask-refused-resume: rule"
assert_eq "$(st '.attempts[0].verdict')" empty "oc-ask-refused-resume: verdict"
assert_eq "$(st .resume_reason)" empty "oc-ask-refused-resume: resume_reason"
assert_eq "$(st '.denied | length')" 1 "oc-ask-refused-resume: the refused call is recorded"
assert_eq "$(st '.denied[0].attempt')" first1 "oc-ask-refused-resume: in the first attempt"
assert_eq "$(cat "$RUN/qwen.out" 2>/dev/null)" ONLY "oc-ask-refused-resume: the answer"

# ---------------------------------------------------------------------------
# The usage limit and the continue action.

ul_msg() { # time: Codex's usage-limit error line as saved, stating that time
    # shellcheck disable=SC1112  # the typographic apostrophe of Codex's message
    printf '%s\n' "ERROR: You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits or try again at $1."
}

ul_work() { # uuid time: a Codex standard error that a usage limit ended after work
    local l
    l="$(ul_msg "$2")"
    codex_err "$1" "$l" "$l" 'tokens used' '131,586'
}

ul_door() { # uuid time: the same when the limit refused the run before its first model turn
    local l
    l="$(ul_msg "$2")"
    codex_err "$1" "$l" "$l"
}

rewrite_status() { # prefix filter: applies the jq filter to the case's saved status of that prefix
    local f="$RUN/$1.status" t
    if t="$(jq -c "$2" "$f")" && [ -n "$t" ] && printf '%s\n' "$t" > "$f"; then return 0; fi
    _fail "rewrite_status: cannot apply $2 to $f"
    return 1
}

fake_ul() { # prefix [filter]: the saved status of a run that answered, made the record a usage limit after work leaves
    rewrite_status "$1" '.outcome = "usage_limit" | .phase = "first" | .cut_off_phase = "first" | .fresh_start = false
        | .answer = null | .reset_at = "2:40 PM" | .attempts[-1].verdict = "usage_limit" | .attempts[-1].rule = 5
        | '"${2:-.}" && rm -f "$RUN/$1.out"
}

ul_first_run() { # the first row of ul-first: a Codex run at the edit level that a usage limit cut off after work
    play codex 1 --exit 1 --stderr "$(ul_work U1 '2:40 PM')"
    ext run --cli codex --run-dir "$RUN" --level edit --limit 40s --resume-limit 7s --model m1
    keep "$RUN/codex.first1.stderr"
}

new_case ul-first
ul_first_run
assert_eq "$rc" 13 "ul-first: rc"
assert_eq "$(st .cut_off_phase)" first "ul-first: cut_off_phase"
assert_eq "$(st .reset_at)" "2:40 PM" "ul-first: reset_at"
assert_eq "$(st .fresh_start)" false "ul-first: fresh_start"
assert_eq "$(st .handle)" U1 "ul-first: handle"
assert_eq "$(ncalls codex)" 1 "ul-first: one call"
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
EXT_CWD="$CASE" ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "ul-first continue: rc"
assert_eq "$(st .outcome)" answered "ul-first continue: outcome"
assert_eq "$(st .phase)" continue "ul-first continue: phase"
assert_eq "$(argv codex 2)" \
    '["exec","resume","U1","--skip-git-repo-check","-m","m1","-c","sandbox_mode=\"workspace-write\"","--codex-x","-"]' \
    "ul-first continue: argv, the same session at the recorded level and model"
assert_eq "$(callf codex 2 stdin)" "$CONTINUE_TEXT" "ul-first continue: the continue text"
assert_eq "$(callf codex 2 cwd)" "$WORK" "ul-first continue: the recorded directory, not the caller's"
assert_contains "$(callf codex 2 parent)" ' -k 1s 40s ' "ul-first continue: the first-attempt limit"
assert_file "$RUN/codex.continue1.stdout" "ul-first continue: codex.continue1.stdout"
unchanged "$RUN/codex.first1.stderr" "ul-first continue"
assert_eq "$(st .limit)" 40s "ul-first continue: limit"
assert_eq "$(st .resume_limit)" 7s "ul-first continue: resume_limit"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" DONE "ul-first continue: the answer"
assert_eq "$(st .reset_at)" null "ul-first continue: no reset time under another outcome"

new_case ul-door
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 13 "ul-door: rc"
assert_eq "$(st .fresh_start)" true "ul-door: fresh_start"
assert_eq "$(st .cut_off_phase)" first "ul-door: cut_off_phase"
assert_eq "$(st .reset_at)" "6:58 PM" "ul-door: reset_at"
play codex 2 --stdout DONE --stderr "$(codex_err U2)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "ul-door continue: rc"
assert_eq "$(st .outcome)" answered "ul-door continue: outcome"
assert_eq "$(argv codex 2)" '["exec","--skip-git-repo-check","-s","workspace-write","--codex-x","-"]' \
    "ul-door continue: argv, the first-attempt form"
assert_eq "$(callf codex 2 stdin)" PROMPT "ul-door continue: the original prompt"
assert_eq "$(st .handle)" U2 "ul-door continue: the new session's handle"
assert_eq "$(st .handle_source)" continue1 "ul-door continue: handle_source"
assert_eq "$(st '.attempts[1].fresh')" true "ul-door continue: the attempt started afresh"
assert_eq "$(st '.attempts[0].fresh')" false "ul-door continue: the first attempt did not"
assert_eq "$(st .fresh_start)" false "ul-door continue: fresh_start"
assert_file "$RUN/codex.continue1.stdout" "ul-door continue: codex.continue1.stdout"

new_case ul-door-twice
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
play codex 2 --exit 1 --stderr "$(ul_door U2 '6:58 PM')"
play codex 3 --stdout OK --stderr "$(codex_err U3)"
ext run --cli codex --run-dir "$RUN"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "ul-door-twice: rc after the first continue"
assert_eq "$(st .fresh_start)" true "ul-door-twice: fresh_start after the first continue"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$(argv codex 3)" '["exec","--skip-git-repo-check","-s","read-only","--codex-x","-"]' \
    "ul-door-twice: argv, the first-attempt form again"
assert_eq "$rc" 0 "ul-door-twice: rc"
assert_eq "$(st .handle)" U3 "ul-door-twice: handle"
assert_eq "$(st .handle_source)" continue2 "ul-door-twice: handle_source"
assert_file "$RUN/codex.continue2.stdout" "ul-door-twice: codex.continue2.stdout"

# A session that had worked is not started again when a later attempt of it
# is refused at the door.
new_case continue-at-the-door
ul_first_run
play codex 2 --exit 1 --stderr "$(ul_door U1 '7:10 PM')"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "continue-at-the-door: rc"
assert_eq "$(st .cut_off_phase)" first "continue-at-the-door: cut_off_phase"
assert_eq "$(st .fresh_start)" false "continue-at-the-door: fresh_start"
assert_eq "$(st .reset_at)" "7:10 PM" "continue-at-the-door: reset_at"
assert_eq "$(st .handle_source)" first1 "continue-at-the-door: handle_source"

new_case ul-no-reset-time
# shellcheck disable=SC1112  # the typographic apostrophe of Codex's message
play codex 1 --exit 1 --stderr "$(codex_err U1 'ERROR: You’ve hit your usage limit.')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "ul-no-reset-time: rc"
assert_eq "$(st .reset_at)" null "ul-no-reset-time: no time stated, none recorded"

# agy's quota error is its usage limit (rule 5, ahead of rule 7). Refused
# before the model's first turn, the trace holds only the user_input and
# error_message steps (a system_message step may stand among them, see
# agy-quota-door-system-message), so a continue starts afresh with
# agy-prompt.md.
new_case agy-quota-door
play agy 1 --exit 3 --stdout "$(t_agy_quota_door C1 113h24m55s)" --stderr "$(agy_quota_err 113h24m55s)"
s0="$(date +%s)"
ext run --cli agy --run-dir "$RUN"
s1="$(date +%s)"
assert_eq "$rc" 13 "agy-quota-door: rc"
assert_eq "$(st .outcome)" usage_limit "agy-quota-door: outcome"
assert_eq "$(st '.attempts[0].rule')" 5 "agy-quota-door: rule"
assert_eq "$(st .message)" "$(agy_quota_text 113h24m55s)" "agy-quota-door: message"
assert_eq "$(st .cut_off_phase)" first "agy-quota-door: cut_off_phase"
assert_eq "$(st .fresh_start)" true "agy-quota-door: fresh_start"
assert_eq "$(st .handle)" C1 "agy-quota-door: handle"
reset_within agy-quota-door $((113 * 3600 + 24 * 60 + 55)) "$s0" "$s1"
play agy 2 --stdout "$(t_agy_answer C2)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-quota-door continue: rc"
assert_eq "$(st .outcome)" answered "agy-quota-door continue: outcome"
assert_eq "$(argv agy 2)" \
    "$(jq -cn --rawfile p "$RUN/agy-prompt.md" '["-p", $p, "--output-format", "stream-json", "--agy-x"]' 2>/dev/null)" \
    "agy-quota-door continue: argv, the first-attempt form with agy-prompt.md"
assert_eq "$(st '.attempts[1].fresh')" true "agy-quota-door continue: the attempt started afresh"
assert_eq "$(st .handle)" C2 "agy-quota-door continue: the new conversation's handle"

# After a model turn and a tool step there is a conversation to continue.
new_case agy-quota-work
play agy 1 --exit 3 --stdout "$(t_agy_quota_work C1 2h5m)" --stderr "$(agy_quota_err 2h5m)"
s0="$(date +%s)"
ext run --cli agy --run-dir "$RUN"
s1="$(date +%s)"
assert_eq "$rc" 13 "agy-quota-work: rc"
assert_eq "$(st '.attempts[0].rule')" 5 "agy-quota-work: rule"
assert_eq "$(st .fresh_start)" false "agy-quota-work: fresh_start"
reset_within agy-quota-work $((2 * 3600 + 5 * 60)) "$s0" "$s1"
play agy 2 --stdout "$(t_agy_answer C1)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-quota-work continue: rc"
assert_eq "$(argv agy 2)" "$(jq -cn --arg t "$CONTINUE_TEXT" \
    '["--conversation", "C1", "-p", $t, "--output-format", "stream-json", "--agy-x"]')" \
    "agy-quota-work continue: argv, the conversation continued by its handle"

# A system_message step is not a model turn: agy writes one, with no text,
# no tokens and a duration under a millisecond, right after the user's
# input of a later attempt of a conversation (agy 1.5.7 and 1.5.14), also
# in one that ended before any model step. Refused at the door with one in
# its trace, the attempt still counts as refused before the model's first
# turn, so a continue starts afresh; with a model turn after it, the
# conversation is continued by its handle.
new_case agy-quota-door-system-message
play agy 1 --exit 3 --stdout "$(jq -cn '{event: "init", conversation_id: "C1", init: {cwd: "/w", permission_mode: "request-review"}}'
    agy_step C1 0 user_input; agy_step C1 1 system_message; agy_step C1 2 error_message
    agy_error_result C1 "$(agy_quota_text 1h)")" --stderr "$(agy_quota_err 1h)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 13 "agy-quota-door-system-message: rc"
assert_eq "$(st '.attempts[0].rule')" 5 "agy-quota-door-system-message: rule"
assert_eq "$(st .fresh_start)" true "agy-quota-door-system-message: fresh_start"
play agy 2 --stdout "$(t_agy_answer C2)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-quota-door-system-message continue: rc"
assert_eq "$(argv agy 2)" \
    "$(jq -cn --rawfile p "$RUN/agy-prompt.md" '["-p", $p, "--output-format", "stream-json", "--agy-x"]' 2>/dev/null)" \
    "agy-quota-door-system-message continue: argv, the first-attempt form with agy-prompt.md"
assert_eq "$(st '.attempts[1].fresh')" true "agy-quota-door-system-message continue: the attempt started afresh"

new_case agy-quota-work-system-message
play agy 1 --exit 3 --stdout "$(jq -cn '{event: "init", conversation_id: "C1", init: {cwd: "/w", permission_mode: "request-review"}}'
    agy_step C1 0 user_input; agy_step C1 1 system_message; agy_step C1 2 agent_response; agy_step C1 3 error_message
    agy_error_result C1 "$(agy_quota_text 1h)")" --stderr "$(agy_quota_err 1h)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 13 "agy-quota-work-system-message: rc"
assert_eq "$(st .fresh_start)" false "agy-quota-work-system-message: fresh_start"
play agy 2 --stdout "$(t_agy_answer C1)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-quota-work-system-message continue: rc"
assert_eq "$(argv agy 2)" "$(jq -cn --arg t "$CONTINUE_TEXT" \
    '["--conversation", "C1", "-p", $t, "--output-format", "stream-json", "--agy-x"]')" \
    "agy-quota-work-system-message continue: argv, the conversation continued by its handle"

# The quota wording on standard error alone is enough; the reset time is read
# from the line that holds it.
new_case agy-quota-stderr
play agy 1 --exit 3 --stdout "$(t_agy_quota_door C1 45m)" --stderr "$(agy_quota_err 45m)"
jq -c 'if .event == "result" then .result.error = "" else . end' "$SCN/agy.1/stdout" > "$CASE/t" &&
    mv "$CASE/t" "$SCN/agy.1/stdout"
s0="$(date +%s)"
ext run --cli agy --run-dir "$RUN"
s1="$(date +%s)"
assert_eq "$rc" 13 "agy-quota-stderr: rc"
assert_eq "$(st '.attempts[0].rule')" 5 "agy-quota-stderr: rule"
assert_contains "$(st .message)" "RESOURCE_EXHAUSTED (code 429)" "agy-quota-stderr: message"
reset_within agy-quota-stderr $((45 * 60)) "$s0" "$s1"

# An ERROR result without the quota wording stays a CLI failure (rule 7).
new_case agy-error-not-quota
play agy 1 --exit 3 --stdout "$(t_agy_quota_door C1 1h | jq -c 'if .event == "result" then .result.error = "Internal error." else . end')" \
    --stderr 'error: Internal error.'
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 14 "agy-error-not-quota: rc"
assert_eq "$(st .outcome)" cli_failure "agy-error-not-quota: outcome"
assert_eq "$(st '.attempts[0].rule')" 7 "agy-error-not-quota: rule"
assert_eq "$(st .reset_at)" null "agy-error-not-quota: reset_at"
assert_eq "$(st .fresh_start)" false "agy-error-not-quota: fresh_start"

# The usage-limit message is the CLI's error made one line of at most 300
# characters, as rule 7's is, while the reset time is read from the whole
# error: here it stands after a line break and 400 characters of padding.
new_case agy-quota-long
pad="$(printf 'w%.0s' {1..400})"
play agy 1 --exit 3 --stdout "$(t_agy_quota_door C1 1h | jq -c --arg p "$pad" \
    'if .event == "result" then .result.error = ("Individual quota reached.\n" + $p + " Resets in 2h5m.") else . end')"
s0="$(date +%s)"
ext run --cli agy --run-dir "$RUN"
s1="$(date +%s)"
assert_eq "$rc" 13 "agy-quota-long: rc"
assert_eq "$(st '.attempts[0].rule')" 5 "agy-quota-long: rule"
assert_eq "$(st .message)" "Individual quota reached. ${pad:0:274}" "agy-quota-long: the message, one line of 300 characters"
reset_within agy-quota-long $((2 * 3600 + 5 * 60)) "$s0" "$s1"

# The same for Codex's usage-limit line.
new_case codex-ul-long
pad="$(printf 'w%.0s' {1..400})"
# shellcheck disable=SC1112  # the typographic apostrophe of Codex's message
play codex 1 --exit 1 --stderr "$(codex_err U1 "ERROR: You’ve hit your usage limit. $pad or try again at 2:40 PM.")"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "codex-ul-long: rc"
# shellcheck disable=SC1112
want="You’ve hit your usage limit. $pad"
assert_eq "$(st .message)" "${want:0:300}" "codex-ul-long: the message, at most 300 characters"
assert_eq "$(st .reset_at)" "2:40 PM" "codex-ul-long: reset_at, from the whole line"

# Rule 7's status is bounded as its error text is.
new_case agy-error-long-status
pad="$(printf 'w%.0s' {1..400})"
play agy 1 --stdout "$(t_agy_quota_door C1 1h | jq -c --arg p "$pad" \
    'if .event == "result" then .result.status = ("BAD\nSTATE " + $p) | .result.error = "Internal error." else . end')"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 14 "agy-error-long-status: rc"
assert_eq "$(st '.attempts[0].rule')" 7 "agy-error-long-status: rule"
assert_eq "$(st .message)" "agy's result has status BAD STATE ${pad:0:290}: Internal error." \
    "agy-error-long-status: the status, one line of 300 characters, then the error"

# ---------------------------------------------------------------------------
# An agy result that did not succeed, in the shape of the trace of
# 2026-11-21 (agy on its default model, a/agy.first1.stdout): agy exited 0
# with an empty standard error, and its last event was a result with status
# ERROR, finished_reason error, the server's capacity error, and the model's
# complete answer as its response. Rule 7's message carries the error, made
# one line and bounded as rule 6's is, and the response of an agy attempt
# that was not answered is kept as that attempt's earlier text, never
# published. A damaged trace, a result without a response that is a string
# that is not blank, and an answered attempt keep no earlier text.

AGY_503='API error (attempt 4): UNAVAILABLE (code 503): No capacity available for model gemini-4-argon-high on the server'
R_LINES=$'The first lines:\n\n1. `alpha.txt`: alpha one  \n2. "beta.txt": beta \\ two\n\nThey share a token.\n'
R_NO_NL=$'one\ttab  \nnot ASCII: \xc3\xa9 \xe6\xbc\xa2\r\nno newline at the end'

jstr() { jq -cn --arg t "$1" '$t'; } # text: the text as a JSON string

agy_failed_result() { # cid status response error: a result in the shape of the trace of 2026-11-21; response and error are JSON values, or - to leave the key out
    jq -cn --arg c "$1" --arg s "$2" --arg r "$3" --arg e "$4" '{conversation_id: $c, status: $s}
        + (if $r == "-" then {} else {response: ($r | fromjson)} end)
        + (if $e == "-" then {} else {error: ($e | fromjson)} end)
        + {finished_reason: "error", num_turns: 1, duration_seconds: 460.226,
           usage: {input_tokens: 37057, output_tokens: 5120, thinking_tokens: 4437, total_tokens: 42177}}
        | {event: "result", result: .}'
}

t_agy_failed() { # cid response error [status]: two model turns and a shell step, four error steps, a last turn, then that result (status ERROR by default)
    jq -cn --arg c "$1" '{event: "init", conversation_id: $c, init: {cwd: "/w", permission_mode: "request-review"}}'
    agy_step "$1" 0 user_input
    agy_step "$1" 1 agent_response
    agy_cmd "$1" ls
    agy_step "$1" 3 agent_response
    agy_step "$1" 4 error_message
    agy_step "$1" 5 error_message
    agy_step "$1" 6 error_message
    agy_step "$1" 7 error_message
    agy_step "$1" 8 agent_response
    agy_failed_result "$1" "${4:-ERROR}" "$2" "$3"
}

earlier_is() { # index attempt label text: <p>.<attempt>.earlier.txt holds exactly the text, and attempt <index>'s two fields name it and its size
    local f="$RUN/$PREFIX.$2.earlier.txt" n
    printf '%s' "$4" > "$CASE/earlier.want"
    if cmp -s "$CASE/earlier.want" "$f"; then _pass; else _fail "$3: $PREFIX.$2.earlier.txt does not hold the response byte for byte"; fi
    n="$(wc -c < "$CASE/earlier.want")"
    assert_eq "$(stj ".attempts[$1] | [.earlier_text, .earlier_text_bytes]")" "[\"$PREFIX.$2.earlier.txt\",${n//[[:space:]]/}]" \
        "$3: earlier_text and earlier_text_bytes of $2"
}

no_earlier() { # index attempt label: no earlier text for that attempt
    assert_nofile "$RUN/$PREFIX.$2.earlier.txt" "$3: no $PREFIX.$2.earlier.txt"
    assert_eq "$(stj ".attempts[$1] | [.earlier_text, .earlier_text_bytes]")" '[null,null]' "$3: earlier_text and its size null for $2"
}

# The shape of the trace of 2026-11-21, with a response of several lines
# that ends with a newline (as that one did) and one that does not.
for x in lines no-nl; do
    name="agy-error-text-$x"
    r="$R_LINES"
    if [ "$x" = no-nl ]; then r="$R_NO_NL"; fi
    new_case "$name"
    play agy 1 --stdout "$(t_agy_failed C "$(jstr "$r")" "$(jstr "$AGY_503")")"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$rc" 14 "$name: rc"
    assert_eq "$(stj '[.outcome, .phase, .attempts[0].rule, .attempts[0].verdict]')" '["cli_failure","first",7,"cli_failure"]' \
        "$name: cli_failure by rule 7 in the first phase"
    assert_eq "$(st .message)" "agy's result has status ERROR: $AGY_503" "$name: the message carries agy's error"
    assert_eq "$OUT" "agy: cli_failure (agy's result has status ERROR: $AGY_503); status: $RUN/agy.status" "$name: summary"
    assert_line "$ERR" "ext-run: agy's result has status ERROR: $AGY_503" "$name: the message on standard error"
    earlier_is 0 first1 "$name" "$r"
    assert_eq "$(st .answer)" null "$name: answer"
    assert_nofile "$RUN/agy.out" "$name: no answer file"
    assert_eq "$(ncalls agy)" 1 "$name: no resume"
    assert_eq "$(st .resume_used)" false "$name: resume_used"
done

# The worked example of the trace of 2026-11-21: a repository with no
# commit, so the snapshot's note follows the message.
new_case agy-error-no-commit
WORK="$CASE/unborn"
mkdir "$WORK"
git init -q --template="$ROOT/tpl" "$WORK"
printf 'alpha\n' > "$WORK/alpha.txt"
play agy 1 --stdout "$(t_agy_failed C "$(jstr "$R_LINES")" "$(jstr "$AGY_503")")"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 14 "agy-error-no-commit: rc"
assert_eq "$(st .message)" "agy's result has status ERROR: $AGY_503; no commit yet: before.diff is empty" \
    "agy-error-no-commit: the error, then the note"
assert_eq "$OUT" \
    "agy: cli_failure (agy's result has status ERROR: $AGY_503; no commit yet: before.diff is empty); status: $RUN/agy.status" \
    "agy-error-no-commit: summary"
earlier_is 0 first1 agy-error-no-commit "$R_LINES"

# No error text, an empty one, a blank one and one that is not a string:
# the message is the status alone, with no ": " after it.
x=0
for e in - '""' "$(jstr $' \t\n ')" '{"code":503}' 503; do
    x=$((x + 1))
    name="agy-error-no-text-$x"
    new_case "$name"
    play agy 1 --stdout "$(t_agy_failed C "$(jstr "$R_LINES")" "$e")"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$rc" 14 "$name ($e): rc"
    assert_eq "$(st .message)" "agy's result has status ERROR" "$name ($e): the message names the status only"
    assert_eq "$OUT" "agy: cli_failure (agy's result has status ERROR); status: $RUN/agy.status" "$name ($e): summary"
    earlier_is 0 first1 "$name ($e)" "$R_LINES"
done

# No response, an empty or blank one, and one that is not a string: no
# earlier text, and the error is still in the message.
x=0
for r in - '""' "$(jstr $' \n\t ')" null '["x"]' '{"text":"x"}' 42; do
    x=$((x + 1))
    name="agy-error-no-response-$x"
    new_case "$name"
    play agy 1 --stdout "$(t_agy_failed C "$r" "$(jstr "$AGY_503")")"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$rc" 14 "$name ($r): rc"
    assert_eq "$(st '.attempts[0].rule')" 7 "$name ($r): rule"
    assert_eq "$(st .message)" "agy's result has status ERROR: $AGY_503" "$name ($r): message"
    no_earlier 0 first1 "$name ($r)"
    assert_nofile "$RUN/agy.out" "$name ($r): no answer file"
done

# An error text with control characters, runs of white space and more than
# 300 characters is one line in the message: its words joined by single
# spaces, the first 300 characters of them, as one_line makes rule 6's
# error and every other text a CLI supplies to a message.
new_case agy-error-long-text
long="$(printf 'abcdefghij%.0s' {1..40})"
play agy 1 --stdout "$(t_agy_failed C "$(jstr "$R_LINES")" "$(jstr $'  E1\nE2\r\n\tE3\x01E4   E5 '"$long"$'\x7f end\n')")"
ext run --cli agy --run-dir "$RUN"
want="E1 E2 E3 E4 E5 $long end"
want="${want:0:300}"
assert_eq "$rc" 14 "agy-error-long-text: rc"
assert_eq "$(st .message)" "agy's result has status ERROR: $want" "agy-error-long-text: the error made one line, 300 characters"
assert_eq "$(st '.message | ltrimstr("agy'"'"'s result has status ERROR: ") | length')" 300 \
    "agy-error-long-text: the error's part is 300 characters"
assert_eq "$(st '.message | test("[[:cntrl:]]")')" false "agy-error-long-text: no control character in the message"
assert_eq "$OUT" "agy: cli_failure (agy's result has status ERROR: $want); status: $RUN/agy.status" \
    "agy-error-long-text: the summary is one line"
earlier_is 0 first1 agy-error-long-text "$R_LINES"

# An answered attempt keeps no earlier text: its response is the answer.
new_case agy-answer-no-earlier
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-answer-no-earlier: rc"
assert_eq "$(cat "$RUN/agy.out" 2>/dev/null)" ANSWER "agy-answer-no-earlier: the answer published"
assert_eq "$(st .answer)" "$RUN/agy.out" "agy-answer-no-earlier: answer"
no_earlier 0 first1 agy-answer-no-earlier

# Denied actions (rule 4), with a response before the denial, and with a
# status ERROR and an error text too: the response is the earlier text, and
# the message is rule 4's.
x=0
for s in SUCCESS ERROR; do
    x=$((x + 1))
    name="agy-denied-earlier-$x"
    new_case "$name"
    play agy 1 --stdout "$(t_agy_failed C "$(jstr 'a note before the denial')" "$(jstr "$AGY_503")" "$s" |
        jq -c --argjson d "$DENIED_JSON" 'if .event == "result" then .result.denied_actions = $d else . end')"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$rc" 12 "$name ($s): rc"
    assert_eq "$(stj '[.outcome, .attempts[0].rule]')" '["denied",4]' "$name ($s): denied by rule 4"
    assert_eq "$(st .message)" "agy ended on denied actions: read_file" "$name ($s): message"
    earlier_is 0 first1 "$name ($s)" 'a note before the denial'
    assert_nofile "$RUN/agy.out" "$name ($s): no answer file"
done

# A non-zero exit with a result that succeeded (rule 8): the response is the
# earlier text. With a damaged line in the trace there is none, and the same
# with exit 0 (rule 9).
new_case agy-exit-earlier
play agy 1 --exit 1 --stderr 'error: the CLI broke' \
    --stdout "$(t_agy_failed C "$(jstr 'a partial answer')" - SUCCESS)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 14 "agy-exit-earlier: rc"
assert_eq "$(st '.attempts[0].rule')" 8 "agy-exit-earlier: rule 8"
assert_eq "$(st .message)" "agy exited with status 1: error: the CLI broke" "agy-exit-earlier: message"
earlier_is 0 first1 agy-exit-earlier 'a partial answer'
assert_nofile "$RUN/agy.out" "agy-exit-earlier: no answer file"
for x in 1 0; do
    name="agy-damaged-no-earlier-$x"
    new_case "$name"
    play agy 1 --exit "$x" --stdout "$(t_agy_failed C "$(jstr "$R_LINES")" "$(jstr "$AGY_503")"; printf '{"event":"resu\n')"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$(st '.attempts[0].rule')" "$((x == 1 ? 8 : 9))" "$name: rule"
    no_earlier 0 first1 "$name"
done

# The deadline (rule 3) after a result with a response: that response is the
# first attempt's earlier text, and the resume's answer is published.
new_case agy-deadline-earlier
play agy 1 --stdout-early "$(t_agy_failed C "$(jstr "$R_LINES")" "$(jstr "$AGY_503")")" --sleep 5
play agy 2 --stdout "$(t_agy_answer C LATE)"
ext run --cli agy --run-dir "$RUN" --limit 1s
assert_eq "$rc" 0 "agy-deadline-earlier: rc"
assert_eq "$(stj '[.outcome, .attempts[0].rule, .attempts[0].verdict]')" '["answered_after_resume",3,"limit"]' \
    "agy-deadline-earlier: the first attempt reached the deadline, the resume answered"
earlier_is 0 first1 agy-deadline-earlier "$R_LINES"
no_earlier 1 resume1 agy-deadline-earlier
assert_eq "$(cat "$RUN/agy.out" 2>/dev/null)" LATE "agy-deadline-earlier: the resume's answer"

# A resume that reports another conversation (rule 2): its response is its
# own earlier text.
new_case agy-conflict-earlier
play agy 1 --stdout "$(t_agy_empty C)"
play agy 2 --stdout "$(t_agy_failed D "$(jstr 'from another conversation')" "$(jstr "$AGY_503")")"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 17 "agy-conflict-earlier: rc"
assert_eq "$(st '.attempts[1].rule')" 2 "agy-conflict-earlier: rule 2"
no_earlier 0 first1 agy-conflict-earlier
earlier_is 1 resume1 agy-conflict-earlier 'from another conversation'

# A signal while agy holds a complete trace open (rule 1): the response is
# kept as for any attempt that was not answered.
new_case agy-cancelled-earlier
play agy 1 --stdout-early "$(t_agy_failed C "$(jstr "$R_NO_NL")" "$(jstr "$AGY_503")")" --hold
ext_bg run --cli agy --run-dir "$RUN"
wait_for "$CALLS/agy.1/started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "agy-cancelled-earlier: rc"
assert_eq "$(st '.attempts[0].rule')" 1 "agy-cancelled-earlier: rule 1"
earlier_is 0 first1 agy-cancelled-earlier "$R_NO_NL"

# The quota after work (rule 5) with a response: the earlier text of the cut
# attempt, which the continue leaves as it is while its own attempt, a
# failure again, keeps its own.
new_case agy-quota-earlier
play agy 1 --exit 3 --stderr "$(agy_quota_err 2h5m)" --stdout "$(t_agy_quota_work C1 2h5m |
    jq -c --arg r "$R_LINES" 'if .event == "result" then .result.response = $r else . end')"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 13 "agy-quota-earlier: rc"
assert_eq "$(stj '[.outcome, .attempts[0].rule, .fresh_start]')" '["usage_limit",5,false]' "agy-quota-earlier: rule 5 after work"
assert_eq "$(st .message)" "$(agy_quota_text 2h5m)" "agy-quota-earlier: rule 5's message"
earlier_is 0 first1 agy-quota-earlier "$R_LINES"
keep "$RUN/agy.first1.earlier.txt"
play agy 2 --stdout "$(t_agy_failed C1 "$(jstr "$R_NO_NL")" "$(jstr "$AGY_503")")"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 14 "agy-quota-earlier continue: rc"
assert_eq "$(stj '[.outcome, .phase, .attempts[1].rule]')" '["cli_failure","continue",7]' "agy-quota-earlier continue: rule 7"
unchanged "$RUN/agy.first1.earlier.txt" "agy-quota-earlier continue"
earlier_is 0 first1 agy-quota-earlier-continue "$R_LINES"
earlier_is 1 continue1 agy-quota-earlier-continue "$R_NO_NL"

# A continue refuses to start when its attempt's earlier text file is
# already there, so the write never overwrites one; a run refuses a run
# directory that holds an earlier text file of its prefix.
new_case agy-continue-earlier-in-the-way
play agy 1 --exit 3 --stdout "$(t_agy_quota_work C1 2h5m)" --stderr "$(agy_quota_err 2h5m)"
ext run --cli agy --run-dir "$RUN"
: > "$RUN/agy.continue1.earlier.txt"
keep "$RUN/agy.status"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 64 "agy-continue-earlier-in-the-way: rc"
assert_contains "$ERR" ": agy.continue1.earlier.txt" "agy-continue-earlier-in-the-way: the file named"
unchanged "$RUN/agy.status" "agy-continue-earlier-in-the-way"
assert_eq "$(ncalls agy)" 1 "agy-continue-earlier-in-the-way: no call after the run"
new_case leftovers-agy-earlier
: > "$RUN/agy.first1.earlier.txt"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 64 "leftovers-agy-earlier: rc"
assert_contains "$ERR" "already exist in $RUN: agy.first1.earlier.txt" "leftovers-agy-earlier: the file named"
assert_nofile "$RUN/agy.status" "leftovers-agy-earlier: no status"
assert_eq "$(ncalls agy)" 0 "leftovers-agy-earlier: no call"

# An earlier text file that cannot be written ends the run as a runner
# failure, and nothing is published.
new_case write-fails-agy-earlier
play agy 1 --hold --stdout "$(t_agy_failed C "$(jstr "$R_LINES")" "$(jstr "$AGY_503")")"
ext_bg run --cli agy --run-dir "$RUN"
wait_for "$CALLS/agy.1/started"
mkdir "$RUN/agy.first1.earlier.txt"
release agy 1
ext_wait
assert_eq "$rc" 21 "write-fails-agy-earlier: rc"
assert_eq "$(st .outcome)" runner_failure "write-fails-agy-earlier: outcome"
assert_eq "$(st .message)" "cannot write $RUN/agy.first1.earlier.txt" "write-fails-agy-earlier: the file named"
assert_lacks "$ERR" "Is a directory" "write-fails-agy-earlier: no unprefixed error line"
assert_nofile "$RUN/agy.out" "write-fails-agy-earlier: no answer file"

# The before snapshot's notes are recorded in notes and outlive a continue,
# which repeats them after its own message: a continue cut off again, then
# one that answers.
new_case notes-continue-no-git
WORK="$CASE/plain"
mkdir "$WORK"
play agy 1 --exit 3 --stdout "$(t_agy_quota_door C1 45m)" --stderr "$(agy_quota_err 45m)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 13 "notes-continue-no-git: the run's rc"
assert_eq "$(stj .notes)" '["not a git repository: no before snapshot"]' "notes-continue-no-git: the run's notes"
play agy 2 --exit 3 --stdout "$(t_agy_quota_door C2 30m)" --stderr "$(agy_quota_err 30m)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 13 "notes-continue-no-git: the first continue's rc"
assert_eq "$(st .message)" "$(agy_quota_text 30m); not a git repository: no before snapshot" \
    "notes-continue-no-git: the first continue's message, then the note"
play agy 3 --stdout "$(t_agy_answer C3)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "notes-continue-no-git: rc"
assert_eq "$(stj .notes)" '["not a git repository: no before snapshot"]' "notes-continue-no-git: the notes kept"
assert_eq "$(st .message)" "not a git repository: no before snapshot" "notes-continue-no-git: the message repeats the note"
assert_eq "$OUT" "agy: answered (not a git repository: no before snapshot); status: $RUN/agy.status" \
    "notes-continue-no-git: and so does the summary"

new_case notes-continue-no-commit
WORK="$CASE/unborn"
mkdir "$WORK"
git init -q --template="$ROOT/tpl" "$WORK"
echo x > "$WORK/new"
play agy 1 --exit 3 --stdout "$(t_agy_quota_work C1 2h5m)" --stderr "$(agy_quota_err 2h5m)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 13 "notes-continue-no-commit: the run's rc"
assert_eq "$(stj .notes)" '["no commit yet: before.diff is empty"]' "notes-continue-no-commit: the run's notes"
play agy 2 --stdout "$(t_agy_answer C1)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "notes-continue-no-commit: rc"
assert_eq "$(stj .notes)" '["no commit yet: before.diff is empty"]' "notes-continue-no-commit: the notes kept"
assert_eq "$(st .message)" "no commit yet: before.diff is empty" "notes-continue-no-commit: the message repeats the note"
assert_contains "$OUT" "(no commit yet: before.diff is empty)" "notes-continue-no-commit: and so does the summary"

new_case fresh-then-empty
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN"
play codex 2 --stdout '' --stderr "$(codex_err U2)"
play codex 3 --stdout OK --stderr "$(codex_err U2)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "fresh-then-empty: rc"
assert_eq "$(st .outcome)" answered_after_resume "fresh-then-empty: outcome"
assert_begins "$(argv codex 3)" '["exec","resume","U2",' "fresh-then-empty: the resume gets the new handle"
assert_eq "$(st .handle)" U2 "fresh-then-empty: handle"
assert_file "$RUN/codex.resume1.stdout" "fresh-then-empty: codex.resume1.stdout"
assert_eq "$(ncalls codex)" 3 "fresh-then-empty: three calls"

# The run starts under the default limit, so that the door attempt never meets
# a deadline on a loaded machine; the record's limit is then made 1 s, the
# limit the fresh attempt must run under.
new_case fresh-then-limit
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN" --resume-limit 20s
assert_eq "$rc" 13 "fresh-then-limit: rc of the run"
rewrite_status codex '.limit = "1s"'
play codex 2 --sleep 5 --stderr "$(codex_err U2)"
play codex 3 --stdout LATE --stderr "$(codex_err U2)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "fresh-then-limit: rc"
assert_eq "$(st .outcome)" answered_after_resume "fresh-then-limit: outcome"
assert_begins "$(argv codex 3)" '["exec","resume","U2",' "fresh-then-limit: the resume gets the new handle"
assert_eq "$(callf codex 3 stdin)" "$LIMIT_TEXT" "fresh-then-limit: the limit text"
assert_contains "$(callf codex 2 parent)" ' -k 1s 1s ' "fresh-then-limit: the fresh attempt under the first-attempt limit"
assert_contains "$(callf codex 3 parent)" ' -k 1s 20s ' "fresh-then-limit: the resume under the resume limit"

new_case fresh-then-no-handle
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN"
play codex 2 --stdout '' --stderr 'no header'
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 16 "fresh-then-no-handle: rc"
assert_eq "$(st .outcome)" no_handle "fresh-then-no-handle: outcome"
assert_eq "$(ncalls codex)" 2 "fresh-then-no-handle: the discarded U1 is not used"
assert_eq "$(st .handle)" null "fresh-then-no-handle: the discarded U1 is not kept"
assert_eq "$(st .handle_source)" continue1 "fresh-then-no-handle: handle_source"

new_case ul-resume-twice
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --exit 1 --stderr "$(ul_work U1 '2:40 PM')"
ext run --cli codex --run-dir "$RUN" --level edit --limit 40s --resume-limit 7s
assert_eq "$rc" 13 "ul-resume-twice: rc"
assert_eq "$(st .cut_off_phase)" resume "ul-resume-twice: cut_off_phase"
play codex 3 --exit 1 --stderr "$(ul_door U1 '3:00 PM')"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "ul-resume-twice: rc after the first continue"
assert_eq "$(st .cut_off_phase)" resume "ul-resume-twice: cut_off_phase after the first continue"
assert_eq "$(st .fresh_start)" false "ul-resume-twice: only a first attempt can start again"
assert_eq "$(st .reset_at)" "3:00 PM" "ul-resume-twice: the new reset time"
assert_contains "$(argv codex 3)" 'sandbox_mode=\"read-only\"' "ul-resume-twice: the first continue at the read level"
assert_eq "$(callf codex 3 stdin)" "$EMPTY_TEXT $AFTER_EDIT" "ul-resume-twice: the resume's text again"
assert_contains "$(callf codex 3 parent)" ' -k 1s 7s ' "ul-resume-twice: under the resume limit"
play codex 4 --stdout OK --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "ul-resume-twice: rc after the second continue"
assert_eq "$(st .outcome)" answered_after_resume "ul-resume-twice: outcome"
assert_contains "$(argv codex 4)" 'sandbox_mode=\"read-only\"' "ul-resume-twice: the second continue at the read level"
assert_file "$RUN/codex.continue2.stdout" "ul-resume-twice: codex.continue2.stdout"
assert_eq "$(ncalls codex)" 4 "ul-resume-twice: four calls"

new_case continue-then-resume
play codex 1 --exit 1 --stderr "$(ul_work U1 '2:40 PM')"
play codex 2 --stdout '' --stderr "$(codex_err U1)"
play codex 3 --stdout OK --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "continue-then-resume: rc"
assert_eq "$(st .outcome)" answered_after_resume "continue-then-resume: outcome"
assert_eq "$(ncalls codex)" 3 "continue-then-resume: three calls"
assert_file "$RUN/codex.resume1.stdout" "continue-then-resume: codex.resume1.stdout"
assert_eq "$(st .resume_used)" true "continue-then-resume: resume_used"

new_case continue-oc
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
mkdir "$CASE/out"
fake_ul qwen ".oc_model=\"zz/qq\" | .allow_dirs=[\"$CASE/out\"]"
play zz-qq 1 --stdout "$(t_oc_only S)"
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "continue-oc: rc"
assert_begins "$(argv zz-qq 1)" '["run","--pure","-s","S","--agent","ext-read","--model","zz/qq"' \
    "continue-oc: argv, the recorded model and not the alias resolved again"
assert_eq "$(argv zz-qq 1 | jq -r '.[-1]')" "$CONTINUE_TEXT" "continue-oc: the continue text last"
assert_eq "$(callf zz-qq 1 env.json | jq -c '[.OPENCODE_DISABLE_CLAUDE_CODE_PROMPT, .OPENCODE_DISABLE_CLAUDE_CODE_SKILLS]')" \
    '["1","1"]' "continue-oc: the two switches"
assert_file "$RUN/qwen.continue1.stdout" "continue-oc: qwen.continue1.stdout"

new_case continue-answered
answering codex 1
ext run --cli codex --run-dir "$RUN"
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-answered: rc"
assert_contains "$ERR" "this one is answered" "continue-answered: message"
unchanged "$RUN/codex.status" "continue-answered"
assert_ends "$OUT" "status: none" "continue-answered: no status named"

new_case continue-other-outcomes
ext outcomes
others=()
while IFS=$'\t' read -r o _; do
    case "$o" in usage_limit | usage_error) ;; *) others+=("$o") ;; esac
done <<< "$OUT"
assert_eq "${#others[@]}" 14 "continue-other-outcomes: fourteen other outcomes"
for o in "${others[@]}"; do
    new_case "continue-other-$o"
    printf '{"outcome":"%s"}\n' "$o" > "$RUN/codex.status"
    ext continue --cli codex --run-dir "$RUN"
    assert_eq "$rc" 64 "continue-other-outcomes $o: rc"
    assert_contains "$ERR" "this one is $o" "continue-other-outcomes $o: message"
done

new_case continue-running
echo '{"outcome":"running"}' > "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-running: rc"
assert_contains "$ERR" "this one is running" "continue-running: message"

new_case continue-stale-lock
echo '{"outcome":"running"}' > "$RUN/codex.status"
mkdir "$RUN/codex.lock"
dead_pid > "$RUN/codex.lock/pid"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-stale-lock: rc"
assert_contains "$ERR" "rm -r --" "continue-stale-lock: the removal command"
assert_contains "$ERR" "is not running" "continue-stale-lock: the owner is gone"

new_case continue-no-status
rm "$RUN/prompt.md"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-no-status: rc"
assert_contains "$ERR" "no status file" "continue-no-status: message"

new_case continue-thin-status
echo '{"outcome":"usage_limit"}' > "$RUN/codex.status"
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-thin-status: rc"
assert_contains "$ERR" "incomplete: name" "continue-thin-status: the first missing field named"
unchanged "$RUN/codex.status" "continue-thin-status"
assert_eq "$(ncalls codex)" 0 "continue-thin-status: no call"

new_case continue-other-name
play a-b-c 1 --stdout "$(t_oc_only S)"
ext run --cli a/b-c --run-dir "$RUN"
fake_ul a-b-c
keep "$RUN/a-b-c.status"
ext continue --cli a-b/c --run-dir "$RUN"
assert_eq "$rc" 64 "continue-other-name: rc"
assert_contains "$ERR" "a/b-c" "continue-other-name: the name the record was written for"
unchanged "$RUN/a-b-c.status" "continue-other-name"

new_case continue-cwd-gone
ul_first_run
keep "$RUN/codex.status"
rm -rf "$WORK"
EXT_CWD="$CASE" ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-cwd-gone: rc"
assert_contains "$ERR" "working directory" "continue-cwd-gone: the directory named"
assert_contains "$ERR" "does not exist" "continue-cwd-gone: the fault named"
unchanged "$RUN/codex.status" "continue-cwd-gone"

new_case continue-relative-run-dir
ul_first_run
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
EXT_CWD="$CASE" ext continue --cli codex --run-dir run
assert_eq "$rc" 0 "continue-relative-run-dir: rc"
assert_file "$RUN/codex.continue1.stdout" "continue-relative-run-dir: the run directory taken from the caller's directory"
assert_nofile "$WORK/run" "continue-relative-run-dir: and not from the recorded one"
assert_ends "$OUT" "status: $RUN/codex.status" "continue-relative-run-dir: the absolute status path"

# The runner started by a relative path from a directory that is not the
# recorded one still finds its own files once it has changed directory.
new_case continue-relative-runner
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
fake_ul qwen
play qwen 2 --stdout "$(t_oc_only S)"
EXT_CWD="$CASE/skill" EXT_RUNNER=scripts/ext-run ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "continue-relative-runner: rc"
assert_eq "$(agent_env_is qwen 2 read-agent.json)" true "continue-relative-runner: the agent file was found"
assert_eq "$(callf qwen 2 cwd)" "$WORK" "continue-relative-runner: in the recorded directory"
assert_file "$RUN/qwen.continue1.stdout" "continue-relative-runner: qwen.continue1.stdout"

# The same start under an exported CDPATH that holds another scripts
# directory: the runner still finds its own directory.
new_case relative-runner-cdpath
mkdir -p "$CASE/decoy/scripts"
answering codex 1
EXT_VARS=("CDPATH=$CASE/decoy")
EXT_CWD="$CASE/skill" EXT_RUNNER=scripts/ext-run ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "relative-runner-cdpath: rc"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" A "relative-runner-cdpath: the answer"

# A CLI found through a relative PATH element is started by an absolute name:
# the directory of the lookup in front of its answer, so the same file runs
# and no link is resolved. A run and its continue both start in the recorded
# directory, where the element leads to the fakes; the suite's guard still
# refuses a relative element that leads anywhere else.
new_case relative-path-element
mkdir "$CASE/real"
printf '#!/bin/sh\n: > "%s/real-ran"\n' "$CASE" > "$CASE/real/codex"
chmod +x "$CASE/real/codex"
EXT_PATH="../real:../bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels"
out="$( (ext run --cli codex --run-dir "$RUN") 2>&1 > /dev/null)"
assert_eq "$?" 2 "relative-path-element: the suite stops on a relative element that leads elsewhere"
assert_contains "$out" "has an empty or relative element" "relative-path-element: refused as a relative element"
assert_nofile "$CASE/real-ran" "relative-path-element: the planted program did not run"
EXT_PATH="./../bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels"
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "relative-path-element: rc"
assert_contains "$(callf codex 1 parent)" " -k 1s 90m $WORK/../bin/codex exec " \
    "relative-path-element: the run's directory in front of the lookup's answer"
play codex 2 --stdout DONE --stderr "$(codex_err U2)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "relative-path-element continue: rc"
assert_eq "$(st .outcome)" answered "relative-path-element continue: outcome"
assert_contains "$(callf codex 2 parent)" " -k 1s 90m $WORK/../bin/codex exec " \
    "relative-path-element continue: the recorded directory in front of the lookup's answer"
# A continue started in another directory still looks the CLI up in the
# recorded one, and the guard resolves a relative element from there: ./bin
# leads to the fakes from the case's directory and nowhere from the recorded
# one, ./../bin the other way round. The record says answered, so a continue
# the guard lets through is refused before its lookup.
out="$( (EXT_CWD="$CASE" EXT_PATH="./bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels" ext continue --cli codex --run-dir "$RUN") 2>&1 > /dev/null)"
assert_eq "$?" 2 "relative-path-element continue elsewhere: the guard refuses what leads elsewhere from the recorded directory"
assert_contains "$out" "has an empty or relative element" "relative-path-element continue elsewhere: refused as a relative element"
(EXT_CWD="$CASE" EXT_PATH="./../bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels" ext continue --cli codex --run-dir "$RUN"; exit "$rc") > /dev/null 2>&1
assert_eq "$?" 64 "relative-path-element continue elsewhere: the guard lets through what leads to the fakes from the recorded directory"
assert_eq "$(ncalls codex)" 2 "relative-path-element: no call after the continue"

new_case continue-foreign-prefix
ul_first_run
rewrite_status codex '.prefix = "agy"'
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-foreign-prefix: rc"
assert_contains "$ERR" "does not match" "continue-foreign-prefix: message"
unchanged "$RUN/codex.status" "continue-foreign-prefix"

new_case continue-bad-nested
ul_first_run
rewrite_status codex '.requested = {}'
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-bad-nested: rc"
assert_contains "$ERR" "incomplete: requested" "continue-bad-nested: the field named"
unchanged "$RUN/codex.status" "continue-bad-nested"

# A record written before notes were recorded continues, its notes read as
# none; a notes field that is there must be a list of strings.
new_case notes-old-record
ul_first_run
rewrite_status codex 'del(.notes)'
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "notes-old-record: rc"
assert_eq "$(st .outcome)" answered "notes-old-record: outcome"
assert_eq "$(stj .notes)" '[]' "notes-old-record: no notes"
assert_eq "$(st .message)" "" "notes-old-record: message"

new_case notes-ill-formed
ul_first_run
cp "$RUN/codex.status" "$CASE/saved.status"
for f in '.notes = "x"' '.notes = [1]' '.notes = null'; do
    cp "$CASE/saved.status" "$RUN/codex.status"
    rewrite_status codex "$f"
    keep "$RUN/codex.status"
    ext continue --cli codex --run-dir "$RUN"
    assert_eq "$rc" 64 "notes-ill-formed $f: rc"
    assert_contains "$ERR" "incomplete: notes is missing or ill formed" "notes-ill-formed $f: the field named"
    unchanged "$RUN/codex.status" "notes-ill-formed $f"
done
assert_eq "$(ncalls codex)" 1 "notes-ill-formed: no call after the run"

new_case continue-contradiction
ul_first_run
cp "$RUN/codex.status" "$CASE/saved.status"
for f in '.fresh_start = true | .cut_off_phase = "resume" | .resume_reason = "empty" | .resume_used = true' \
    '.cut_off_phase = "resume" | .resume_reason = "empty"'; do
    cp "$CASE/saved.status" "$RUN/codex.status"
    rewrite_status codex "$f"
    keep "$RUN/codex.status"
    ext continue --cli codex --run-dir "$RUN"
    assert_eq "$rc" 64 "continue-contradiction $f: rc"
    assert_contains "$ERR" "contradicts itself" "continue-contradiction $f: message"
    unchanged "$RUN/codex.status" "continue-contradiction $f"
done
assert_eq "$(ncalls codex)" 1 "continue-contradiction: no call after the run"

new_case continue-files-in-the-way
ul_first_run
: > "$RUN/codex.continue1.stdout"
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-files-in-the-way: rc"
assert_contains "$ERR" "already exist" "continue-files-in-the-way: message"
unchanged "$RUN/codex.status" "continue-files-in-the-way"
assert_eq "$(ncalls codex)" 1 "continue-files-in-the-way: no call after the run"

# While the one resume is unused, a file of that resume is in the way too.
new_case continue-resume-file-in-the-way
ul_first_run
: > "$RUN/codex.resume1.stdout"
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-resume-file-in-the-way: rc"
assert_contains "$ERR" "already exist" "continue-resume-file-in-the-way: message"
assert_contains "$ERR" ": codex.resume1.stdout" "continue-resume-file-in-the-way: the file named"
unchanged "$RUN/codex.status" "continue-resume-file-in-the-way"
assert_eq "$(ncalls codex)" 1 "continue-resume-file-in-the-way: no call after the run"

# The files of a longer prefix whose name begins with this continue's
# attempt or the resume and a dot (codex.continue1.x-y, from the model id
# codex.continue1.x/y; codex.resume1.x-y likewise) are not in the way, as in
# leftovers-longer-prefix; any other such file still is.
new_case continue-longer-prefix-files
ul_first_run
for f in codex.continue1.x-y.status codex.continue1.x-y.first1.stdout codex.resume1.x-y.status codex.resume1.x-y.out; do
    : > "$RUN/$f"
done
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "continue-longer-prefix-files: rc"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" DONE "continue-longer-prefix-files: the answer"

new_case continue-longer-prefix-other
ul_first_run
: > "$RUN/codex.continue1.x-y.notes"
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "continue-longer-prefix-other: rc"
assert_contains "$ERR" "already exist in $RUN: codex.continue1.x-y.notes" "continue-longer-prefix-other: that file named"
unchanged "$RUN/codex.status" "continue-longer-prefix-other"

# A continue's read of the session handle that fails leaves the saved status
# as it was, so the run can be continued once the file can be read again.
# As root a file without its read bits can still be read.
new_case handles-unreadable-continue
if [ "$(id -u)" = 0 ]; then
    printf 'ext-run.test: handles-unreadable-continue skipped: as root a file without its read bits can be read\n' >&2
else
    ul_first_run
    chmod 000 "$RUN/codex.first1.stderr"
    keep "$RUN/codex.status"
    ext continue --cli codex --run-dir "$RUN"
    assert_eq "$rc" 21 "handles-unreadable-continue: rc"
    assert_contains "$OUT" "runner_failure (cannot read the session handles of attempt first1)" \
        "handles-unreadable-continue: outcome and message"
    assert_ends "$OUT" "status: none" "handles-unreadable-continue: no status named"
    unchanged "$RUN/codex.status" "handles-unreadable-continue"
    assert_eq "$(ncalls codex)" 1 "handles-unreadable-continue: no call after the run"
    chmod 600 "$RUN/codex.first1.stderr"
fi

new_case fresh-prompt-changed
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN"
echo more >> "$RUN/prompt.md"
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "fresh-prompt-changed: rc"
assert_contains "$ERR" "prompt.md changed" "fresh-prompt-changed: message"
unchanged "$RUN/codex.status" "fresh-prompt-changed"
assert_eq "$(ncalls codex)" 1 "fresh-prompt-changed: no call after the run"

new_case continue-extra-option
ul_first_run
ext continue --cli codex --run-dir "$RUN" --level read
assert_eq "$rc" 64 "continue-extra-option: rc"
assert_contains "$ERR" "continue takes only" "continue-extra-option: message"

new_case continue-no-handle
l="$(ul_msg '2:40 PM')"
play codex 1 --exit 1 --stderr "$(printf '%s\n' 'no header' "$l" "$l" 'tokens used' 9)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "continue-no-handle: the run's rc"
keep "$RUN/codex.status"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 16 "continue-no-handle: rc"
assert_ends "$OUT" "status: none" "continue-no-handle: no status named"
unchanged "$RUN/codex.status" "continue-no-handle"
assert_eq "$(ncalls codex)" 1 "continue-no-handle: no call after the run"

new_case continue-preflight-keeps
ul_first_run
keep "$RUN/codex.status"
echo 1 > "$SCN/codex.sandbox.exit"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "continue-preflight-keeps: rc"
assert_contains "$OUT" prerequisite_failed "continue-preflight-keeps: outcome"
assert_ends "$OUT" "status: none" "continue-preflight-keeps: no status named"
unchanged "$RUN/codex.status" "continue-preflight-keeps"
assert_eq "$(ncalls codex)" 1 "continue-preflight-keeps: no call after the run"
rm "$SCN/codex.sandbox.exit"
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "continue-preflight-keeps: rc of the continue after the fix"
assert_file "$RUN/codex.continue1.stdout" "continue-preflight-keeps: codex.continue1.stdout"

# A continue reads the follow-up texts in step 2 as well: before the claim and
# before the sandbox probe, so the saved status stays as it was and the run
# can be continued once the file is back.
new_case followup-missing-continue
ul_first_run
keep "$RUN/codex.status"
rm "$CASE/skill/prompts/followup.md" "$CALLS/sandbox.started"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "followup-missing-continue: rc"
assert_begins "$OUT" "codex: prerequisite_failed (" "followup-missing-continue: outcome"
assert_ends "$OUT" "status: none" "followup-missing-continue: no status named"
assert_contains "$ERR" "the follow-up texts are missing or unreadable: $CASE/skill/scripts/../prompts/followup.md" \
    "followup-missing-continue: the file named"
assert_nofile "$CALLS/sandbox.started" "followup-missing-continue: no sandbox probe"
assert_eq "$(ncalls codex)" 1 "followup-missing-continue: no call after the run"
unchanged "$RUN/codex.status" "followup-missing-continue"
cp "$SKILL/prompts/followup.md" "$CASE/skill/prompts/followup.md"
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "followup-missing-continue: rc of the continue once the file is back"

# An emptied section refuses a continue that starts afresh too, which would
# send no follow-up text at all.
new_case followup-section-empty-continue
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 13 "followup-section-empty-continue: the run's rc"
keep "$RUN/codex.status"
awk '$0 == "## after-edit" { print; skip = 1; next } /^## / { skip = 0 } !skip' "$SKILL/prompts/followup.md" \
    > "$CASE/skill/prompts/followup.md"
rm "$CALLS/sandbox.started"
play codex 2 --stdout DONE --stderr "$(codex_err U2)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "followup-section-empty-continue: rc"
assert_nofile "$CALLS/sandbox.started" "followup-section-empty-continue: no sandbox probe"
assert_ends "$OUT" "status: none" "followup-section-empty-continue: no status named"
assert_contains "$ERR" "the follow-up text for after-edit is missing or empty in $CASE/skill/scripts/../prompts/followup.md" \
    "followup-section-empty-continue: the section and the file named"
assert_eq "$(ncalls codex)" 1 "followup-section-empty-continue: no call after the run"
unchanged "$RUN/codex.status" "followup-section-empty-continue"

# A run keeps the texts step 2 read: the file removed while the first attempt
# runs no longer costs the resume.
new_case followup-removed-during-run
play codex 1 --hold --stdout '' --stderr "$(codex_err U1)"
play codex 2 --stdout LATE --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
rm "$CASE/skill/prompts/followup.md"
release codex 1
ext_wait
assert_eq "$rc" 0 "followup-removed-during-run: rc"
assert_eq "$(st .outcome)" answered_after_resume "followup-removed-during-run: outcome"
assert_eq "$(callf codex 2 stdin)" "$EMPTY_TEXT" "followup-removed-during-run: the resume got the text read at the start"

# A continue makes the same jq check in step 2: the saved status stays as it
# was, where a later read of it would have ended as a runner failure.
new_case jq-without-raw-output0-continue
ul_first_run
keep "$RUN/codex.status"
rm "$CALLS/sandbox.started"
mk_old_jq "$CASE/oldjq"
EXT_PATH="$CASE/oldjq:$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels"
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "jq-without-raw-output0-continue: rc"
assert_eq "$OUT" \
    "codex: prerequisite_failed (jq 1.7 or later is needed: $CASE/oldjq/jq does not take --raw-output0); status: none" \
    "jq-without-raw-output0-continue: the summary names jq and the option"
assert_nofile "$CALLS/sandbox.started" "jq-without-raw-output0-continue: no sandbox probe"
assert_eq "$(ncalls codex)" 1 "jq-without-raw-output0-continue: no call after the run"
unchanged "$RUN/codex.status" "jq-without-raw-output0-continue"

# A continue makes the same ps check in step 2, before its claim: the saved
# status stays as it was, and the run can be continued once ps works.
new_case ps-cannot-list-continue
ul_first_run
keep "$RUN/codex.status"
rm "$CALLS/sandbox.started"
mk_tool "$CASE/failps/ps" <<'EOF'
printf 'ps: cannot list the processes\n' >&2
exit 1
EOF
EXT_PATH="$CASE/failps:$CASE/bin:$BIN_ROOT/utils:$BIN_ROOT/sentinels"
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 18 "ps-cannot-list-continue: rc"
assert_eq "$OUT" \
    "codex: prerequisite_failed (a ps that lists the processes is needed: $CASE/failps/ps $PS_PROBE does not show the runner's own process); status: none" \
    "ps-cannot-list-continue: the summary names ps"
assert_nofile "$CALLS/sandbox.started" "ps-cannot-list-continue: no sandbox probe"
assert_eq "$(ncalls codex)" 1 "ps-cannot-list-continue: no call after the run"
assert_nofile "$RUN/codex.lock" "ps-cannot-list-continue: no claim"
unchanged "$RUN/codex.status" "ps-cannot-list-continue"
unset EXT_PATH
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "ps-cannot-list-continue: with ps working the same continue answers"

# ---------------------------------------------------------------------------
# What an OpenCode run is given and may read: the injected config, the
# outside directories, the project boundary and the version guard.

# The permission key that denies OpenCode's skill tool, from the shipped settings file.
# shellcheck source=/dev/null
K="$(source "$SKILL/scripts/ext-run.conf" && printf '%s' "$OC_SKILL_DENY_KEY")"

oc_config() { # key k: the config that invocation was given in OPENCODE_CONFIG_CONTENT
    callf "$1" "$2" env.json | jq -r '.OPENCODE_CONFIG_CONTENT // empty' 2>/dev/null
}

oc_grants() { # key k: the read agent's external_directory in that invocation's config, as key=value pairs in order
    oc_config "$1" "$2" |
        jq -r '.agent["ext-read"].permission.external_directory | to_entries | map(.key + "=" + .value) | join(" ")' \
            2>/dev/null
}

oc_key_rule() { # key k agent: the rule for K in that agent's permission in that invocation's config
    oc_config "$1" "$2" | jq -r --arg a "$3" --arg k "$K" '.agent[$a].permission[$k]' 2>/dev/null
}

config_as_injected() { # key k file: true when that file of the run directory holds exactly what the invocation was given
    jq -n --rawfile c "$RUN/$3" --slurpfile e "$CALLS/$1.$2/env.json" '$e[0].OPENCODE_CONFIG_CONTENT == $c' 2>/dev/null
}

refused() { # reason allow-dir [more options]: an answering qwen run given that directory is refused before it writes
    local reason="$1" dir="$2"
    shift 2
    answering qwen 1
    ext run --cli qwen --run-dir "$RUN" --allow-dir "$dir" "$@"
    assert_eq "$rc" 64 "$CASE_NAME: rc"
    assert_contains "$ERR" "$reason" "$CASE_NAME: the reason"
    assert_eq "$(ncalls qwen)" 0 "$CASE_NAME: no call"
    assert_nofile "$RUN/qwen.status" "$CASE_NAME: no status"
}

new_case oc-env
play qwen 1 --stdout "$(t_oc_empty_final S)"
play qwen 2 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-env: rc"
for k in 1 2; do
    assert_eq "$(callf qwen "$k" env.json | jq -c '[.OPENCODE_DISABLE_CLAUDE_CODE_PROMPT, .OPENCODE_DISABLE_CLAUDE_CODE_SKILLS]')" \
        '["1","1"]' "oc-env $k: the two switches"
    assert_eq "$(argv qwen "$k" | jq -r '.[1]')" --pure "oc-env $k: --pure at index 1"
    assert_eq "$(oc_key_rule qwen "$k" ext-read)" deny "oc-env $k: the skill key is denied"
done
assert_eq "$(config_as_injected qwen 1 qwen.first1.config.json)" true "oc-env: qwen.first1.config.json is what the first attempt got"
assert_eq "$(config_as_injected qwen 2 qwen.resume1.config.json)" true "oc-env: qwen.resume1.config.json is what the resume got"

new_case oc-shipped-agents
assert_ne "$K" "" "oc-shipped-agents: OC_SKILL_DENY_KEY is not empty"
assert_eq "$(jq -r --arg k "$K" '.agent["ext-read"].permission[$k]' "$SKILL/opencode/read-agent.json")" deny \
    "oc-shipped-agents: the read agent denies the skill key"
assert_eq "$(jq -r --arg k "$K" '.agent["ext-edit"].permission[$k]' "$SKILL/opencode/edit-agent.json")" deny \
    "oc-shipped-agents: the edit agent denies the skill key"

new_case oc-edit-config
answering qwen 1
ext run --cli qwen --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "oc-edit-config: rc"
assert_contains "$(argv qwen 1)" '"--agent","ext-edit"' "oc-edit-config: the edit agent"
assert_eq "$(oc_key_rule qwen 1 ext-edit)" deny "oc-edit-config: the skill key is denied"
assert_eq "$(config_as_injected qwen 1 qwen.first1.config.json)" true "oc-edit-config: qwen.first1.config.json is what was injected"

new_case oc-no-key
conf_set "OC_SKILL_DENY_KEY=''"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 18 "oc-no-key: rc"
assert_contains "$ERR" OC_SKILL_DENY_KEY "oc-no-key: the setting named"
assert_eq "$(ncalls qwen)" 0 "oc-no-key: no call"
assert_nofile "$RUN/qwen.status" "oc-no-key: no status"

new_case oc-allow
mkdir -p "$CASE/out/a" "$CASE/out/b"
answering qwen 1
ext run --cli qwen --run-dir "$RUN" --allow-dir "$CASE/out/a" --allow-dir "$CASE/out/b"
assert_eq "$rc" 0 "oc-allow: rc"
assert_eq "$(oc_grants qwen 1)" \
    "*=deny $CASE/out/a=allow $CASE/out/a/*=allow $CASE/out/b=allow $CASE/out/b/*=allow" \
    "oc-allow: deny everything, then each directory and everything under it"
assert_eq "$(st '.allow_dirs | length')" 2 "oc-allow: allow_dirs"

new_case oc-allow-link
mkdir -p "$CASE/out/a"
ln -s "$CASE/out/a" "$CASE/lnk"
answering qwen 1
ext run --cli qwen --run-dir "$RUN" --allow-dir "$CASE/lnk"
assert_eq "$rc" 0 "oc-allow-link: rc"
assert_eq "$(oc_config qwen 1 | jq -r '.agent["ext-read"].permission.external_directory
    | [to_entries[] | select(.value == "allow") | .key] | join(" ")' 2>/dev/null)" \
    "$CASE/out/a $CASE/out/a/*" "oc-allow-link: the canonical path is granted"
assert_eq "$(st '.allow_dirs[0]')" "$CASE/out/a" "oc-allow-link: allow_dirs holds the canonical path"

new_case oc-allow-resume
mkdir "$CASE/out"
play qwen 1 --stdout "$(t_oc_empty_final S)"
play qwen 2 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN" --allow-dir "$CASE/out"
assert_eq "$rc" 0 "oc-allow-resume: rc"
assert_eq "$(oc_grants qwen 2)" "*=deny $CASE/out=allow $CASE/out/*=allow" "oc-allow-resume: the resume has the same grants"
assert_eq "$(oc_grants qwen 2)" "$(oc_grants qwen 1)" "oc-allow-resume: as the first attempt"

new_case oc-continue-config
play qwen 1 --stdout "$(t_oc_only S)"
ext run --cli qwen --run-dir "$RUN"
mkdir "$CASE/out"
fake_ul qwen ".allow_dirs=[\"$CASE/out\"]"
play qwen 2 --stdout "$(t_oc_only S)"
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-continue-config: rc"
assert_eq "$(oc_grants qwen 2)" "*=deny $CASE/out=allow $CASE/out/*=allow" "oc-continue-config: the recorded directory is granted"
assert_eq "$(oc_key_rule qwen 2 ext-read)" deny "oc-continue-config: the skill key is denied"
assert_eq "$(config_as_injected qwen 2 qwen.continue1.config.json)" true \
    "oc-continue-config: qwen.continue1.config.json is what was injected"

new_case continue-oc-from-home
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
fake_ul qwen
play qwen 2 --stdout "$(t_oc_only S)"
EXT_CWD="$HOME" ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "continue-oc-from-home: rc"
assert_eq "$(callf qwen 2 cwd)" "$WORK" "continue-oc-from-home: in the recorded directory, not the refused caller's"

new_case continue-oc-bad-record
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
mkdir -p "$HOME/.codex/sessions"
fake_ul qwen ".cwd=\"$HOME/.codex/sessions\""
keep "$RUN/qwen.status"
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "continue-oc-bad-record: rc"
assert_contains "$ERR" protected "continue-oc-bad-record: the reason"
unchanged "$RUN/qwen.status" "continue-oc-bad-record"
assert_eq "$(ncalls qwen)" 1 "continue-oc-bad-record: no call after the run"

new_case boundary-own-repo
git -C "$HOME" init -q --template="$ROOT/tpl"
EXT_VARS=("GIT_DIR=$HOME/.git" "GIT_WORK_TREE=$HOME")
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "boundary-own-repo: rc"
assert_eq "$(st .boundary)" "$WORK" "boundary-own-repo: inherited repository variables do not move the boundary"

# OpenCode gets none of them either, so that its own repository discovery finds
# the bundle the runner checked, not the home directory they point at. A
# stand-in in front of the fake writes only whether each variable reached it,
# never a value, and then becomes the fake; a run and a continue each start
# the version command and an attempt through it.
new_case oc-git-vars
git -C "$HOME" init -q --template="$ROOT/tpl"
WORK="$RUN/bundle"
mkdir "$WORK"
git -C "$WORK" init -q --template="$ROOT/tpl"
EXT_VARS=("GIT_DIR=$HOME/.git" "GIT_WORK_TREE=$HOME")
# Without the stand-in the name would resolve to the sentinel, so a failed
# setup stops the suite.
if ! { mkdir "$CASE/oc-fake" && mv "$CASE/bin/opencode" "$CASE/oc-fake/opencode" &&
    mk_tool "$CASE/bin/opencode"; } <<'EOF'; then
d=absent w=absent
if [ -n "${GIT_DIR+set}" ]; then d=present; fi
if [ -n "${GIT_WORK_TREE+set}" ]; then w=present; fi
printf '%s GIT_DIR %s GIT_WORK_TREE %s\n' "${1:-}" "$d" "$w" >> "$CASE/git-vars"
exec "$CASE/oc-fake/opencode" "$@"
EOF
    printf 'ext-run.test: cannot put the stand-in in front of the fake opencode\n' >&2
    exit 2
fi
none=$'--version GIT_DIR absent GIT_WORK_TREE absent\nrun GIT_DIR absent GIT_WORK_TREE absent'
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-git-vars: rc"
assert_eq "$(st .boundary)" "$WORK" "oc-git-vars: the boundary is the bundle"
assert_eq "$(LC_ALL=C sort -u "$CASE/git-vars")" "$none" \
    "oc-git-vars: neither variable reached the version command or the first attempt"
mv "$CASE/git-vars" "$CASE/git-vars.run"
fake_ul qwen
play qwen 2 --stdout "$(t_oc_only S)"
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-git-vars continue: rc"
assert_eq "$(LC_ALL=C sort -u "$CASE/git-vars")" "$none" \
    "oc-git-vars continue: neither variable reached the version command or the continue attempt"

new_case boundary-git-hangs
mk_tool "$CASE/slowgit/git" <<< 'sleep 30'
EXT_PATH="$CASE/slowgit:$CASE/bin:$BIN_ROOT/utils"
PRE_LIMIT=1s
answering qwen 1
t0="$EPOCHREALTIME"
ext run --cli qwen --run-dir "$RUN"
took_under "$t0" 10 "boundary-git-hangs: the run ended within 10 s"
assert_eq "$rc" 18 "boundary-git-hangs: rc"
assert_contains "$ERR" "git did not answer" "boundary-git-hangs: message"
assert_eq "$(ncalls qwen)" 0 "boundary-git-hangs: no call"
assert_nofile "$RUN/qwen.status" "boundary-git-hangs: no status"

# A git that answers with a failure is a usage error, not a missing prerequisite.
new_case boundary-git-fails
mk_tool "$CASE/failgit/git" <<< "echo 'fatal: VARS-REASON' >&2; exit 1"
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "boundary-git-fails: rc"
assert_contains "$ERR" "--local-env-vars" "boundary-git-fails: the message names the query"
assert_contains "$ERR" "fatal: VARS-REASON" "boundary-git-fails: git's reason"
assert_eq "$(ncalls qwen)" 0 "boundary-git-fails: no call"
assert_nofile "$RUN/qwen.status" "boundary-git-fails: no status"

# A git that cannot be run, or that lists what is not a variable name, is a
# missing prerequisite, and the message names git.
new_case git-cannot-run
mk_tool "$CASE/nogit/git" <<< 'exit 127'
EXT_PATH="$CASE/nogit:$CASE/bin:$BIN_ROOT/utils"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 18 "git-cannot-run: rc"
assert_contains "$ERR" "git cannot be run" "git-cannot-run: git named"
assert_contains "$ERR" "status 127" "git-cannot-run: the status named"
assert_eq "$(ncalls qwen)" 0 "git-cannot-run: no call"
assert_nofile "$RUN/qwen.status" "git-cannot-run: no status"

new_case git-vars-not-names
mk_tool "$CASE/oddgit/git" <<'EOF'
if [ "$*" = 'rev-parse --local-env-vars' ]; then
    echo 'not a name'
    exit 0
fi
exec "$BIN_ROOT/utils/git" "$@"
EOF
EXT_PATH="$CASE/oddgit:$CASE/bin:$BIN_ROOT/utils"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 18 "git-vars-not-names: rc"
assert_contains "$ERR" "git rev-parse --local-env-vars" "git-vars-not-names: git named"
assert_contains "$ERR" "not a name" "git-vars-not-names: what it printed"
assert_eq "$(ncalls qwen)" 0 "git-vars-not-names: no call"
assert_nofile "$RUN/qwen.status" "git-vars-not-names: no status"

# Every git lists GIT_DIR among the variables local to a repository, so an
# answer that does not (none at all, or other names only) is not git's list,
# and the variables to leave out are unknown: a missing prerequisite that
# names git, before the run writes anything.
new_case git-vars-no-git-dir
mk_tool "$CASE/emptygit/git" <<'EOF'
if [ "$*" = 'rev-parse --local-env-vars' ]; then exit 0; fi
exec "$BIN_ROOT/utils/git" "$@"
EOF
mk_tool "$CASE/shortgit/git" <<'EOF'
if [ "$*" = 'rev-parse --local-env-vars' ]; then echo GIT_WORK_TREE; exit 0; fi
exec "$BIN_ROOT/utils/git" "$@"
EOF
answering qwen 1
for g in emptygit shortgit; do
    RUN="$CASE/run-$g"
    make_run "$RUN"
    EXT_PATH="$CASE/$g:$CASE/bin:$BIN_ROOT/utils"
    ext run --cli qwen --run-dir "$RUN"
    assert_eq "$rc" 18 "git-vars-no-git-dir $g: rc"
    assert_contains "$ERR" "git rev-parse --local-env-vars" "git-vars-no-git-dir $g: git named"
    assert_contains "$ERR" "did not list GIT_DIR" "git-vars-no-git-dir $g: what is missing"
    assert_ends "$OUT" "status: none" "git-vars-no-git-dir $g: no status named"
    assert_nofile "$RUN/qwen.status" "git-vars-no-git-dir $g: no status"
done
assert_eq "$(ncalls qwen)" 0 "git-vars-no-git-dir: no call"

# A continue meets git as a run does: one that cannot be run, or that lists
# what is not a variable name, is a missing prerequisite, and the saved
# status stays as it was.
new_case continue-git-broken
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
fake_ul qwen
keep "$RUN/qwen.status"
mk_tool "$CASE/nogit/git" <<< 'exit 127'
mk_tool "$CASE/oddgit/git" <<'EOF'
if [ "$*" = 'rev-parse --local-env-vars' ]; then
    echo 'not a name'
    exit 0
fi
exec "$BIN_ROOT/utils/git" "$@"
EOF
play qwen 2 --stdout "$(t_oc_only S)"
for g in nogit:'git cannot be run: git rev-parse --local-env-vars ended with status 127' \
    oddgit:'git rev-parse --local-env-vars (status 0) printed what is not a variable name: not a name'; do
    msg="${g#*:}" g="${g%%:*}"
    EXT_PATH="$CASE/$g:$CASE/bin:$BIN_ROOT/utils"
    ext continue --cli qwen --run-dir "$RUN"
    assert_eq "$rc" 18 "continue-git-broken $g: rc"
    assert_ends "$OUT" "status: none" "continue-git-broken $g: no status named"
    assert_contains "$ERR" "$msg" "continue-git-broken $g: git and its fault named"
    unchanged "$RUN/qwen.status" "continue-git-broken $g"
done
assert_eq "$(ncalls qwen)" 1 "continue-git-broken: no call after the first"
unset EXT_PATH
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "continue-git-broken: the run can still be continued"

# The same for an answer that does not name GIT_DIR: the saved status stays as
# it was, and the run can be continued once git answers.
new_case continue-git-no-git-dir
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
fake_ul qwen
keep "$RUN/qwen.status"
mk_tool "$CASE/emptygit/git" <<'EOF'
if [ "$*" = 'rev-parse --local-env-vars' ]; then exit 0; fi
exec "$BIN_ROOT/utils/git" "$@"
EOF
play qwen 2 --stdout "$(t_oc_only S)"
EXT_PATH="$CASE/emptygit:$CASE/bin:$BIN_ROOT/utils"
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 18 "continue-git-no-git-dir: rc"
assert_contains "$ERR" "did not list GIT_DIR" "continue-git-no-git-dir: git and what is missing named"
assert_ends "$OUT" "status: none" "continue-git-no-git-dir: no status named"
unchanged "$RUN/qwen.status" "continue-git-no-git-dir"
assert_eq "$(ncalls qwen)" 1 "continue-git-no-git-dir: no call after the first"
unset EXT_PATH
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "continue-git-no-git-dir: the run can still be continued"

# A git that runs and fails while an OpenCode continue checks the project
# boundary of the recorded directory is a usage error, as in a run
# (boundary-git-fails), with git's reason: the continue owns no status file
# yet, so the saved status stays as it was.
new_case continue-oc-git-vars-fails
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
fake_ul qwen
keep "$RUN/qwen.status"
mk_tool "$CASE/failgit/git" <<< "echo 'fatal: VARS-REASON' >&2; exit 1"
play qwen 2 --stdout "$(t_oc_only S)"
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "continue-oc-git-vars-fails: rc"
assert_eq "$OUT" "qwen: usage_error (git rev-parse --local-env-vars failed with status 1 (fatal: VARS-REASON)); status: none" \
    "continue-oc-git-vars-fails: the query and git's reason named, no status"
unchanged "$RUN/qwen.status" "continue-oc-git-vars-fails"
assert_eq "$(ncalls qwen)" 1 "continue-oc-git-vars-fails: no call after the first"
unset EXT_PATH
ext continue --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "continue-oc-git-vars-fails: the run can still be continued"

# git fails although a .git lies above the directory (here a .git file git
# cannot read): the boundary is unknown, and the directory is not taken for it.
new_case boundary-unknown
mkdir -p "$CASE/broken/sub"
: > "$CASE/broken/.git"
WORK="$CASE/broken/sub"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "boundary-unknown: rc"
assert_contains "$ERR" "cannot tell the project boundary" "boundary-unknown: message"
assert_contains "$ERR" "(fatal: " "boundary-unknown: git's own reason"
assert_eq "$(ncalls qwen)" 0 "boundary-unknown: no call"
assert_nofile "$RUN/qwen.status" "boundary-unknown: no status"

# Refused outside directories: each row creates what it names, so that only
# the stated check can refuse it.
new_case refuse-relative
mkdir -p "$WORK/relative/dir"
refused 'not absolute' relative/dir

new_case refuse-missing
refused 'does not exist' "$CASE/missing"

new_case refuse-file
: > "$CASE/afile"
refused 'not a directory' "$CASE/afile"

new_case refuse-pattern
mkdir -p "$CASE/out/star*"
refused 'pattern character' "$CASE/out/star*"

for b in / /tmp /home /var/tmp home parent-of-home; do
    new_case "refuse-broad-${b//\//_}"
    case "$b" in
        home) b="$HOME" ;;
        parent-of-home) b="${HOME%/*}" ;;
    esac
    refused 'too broad' "$b"
done

for p in .claude .claude/skills/x .claude2 .codex .gemini .config/opencode .local/share/opencode .opencode \
    .ssh .gnupg .aws .secrets .config/gh .config; do
    q="${p#.}"
    new_case "refuse-protected-${q//\//-}"
    mkdir -p "$HOME/$p"
    refused protected "$HOME/$p"
done

new_case refuse-link-into-ssh
mkdir -p "$HOME/.ssh/sub"
ln -s "$HOME/.ssh/sub" "$CASE/link-into-ssh"
refused protected "$CASE/link-into-ssh"

new_case refuse-xdg-data
mkdir -p "$CASE/xdg/opencode/sessions"
EXT_VARS=("XDG_DATA_HOME=$CASE/xdg")
refused protected "$CASE/xdg/opencode/sessions"

new_case refuse-codex-home
mkdir -p "$CASE/chome/sessions"
EXT_VARS=("CODEX_HOME=$CASE/chome")
refused protected "$CASE/chome/sessions"

new_case refuse-xdg-config-gh
mkdir -p "$CASE/xcfg/gh"
EXT_VARS=("XDG_CONFIG_HOME=$CASE/xcfg")
refused protected "$CASE/xcfg/gh"

new_case refuse-config-link
mkdir "$CASE/cfg-real"
ln -s "$CASE/cfg-real" "$CASE/cfg-link"
EXT_VARS=("XDG_CONFIG_HOME=$CASE/cfg-link")
refused protected "$CASE/cfg-real"

# A location a variable moves is protected beside the default one, which may
# still hold credentials; GH_CONFIG_DIR moves gh's.
new_case refuse-xdg-config-default-gh
mkdir -p "$HOME/.config/gh"
EXT_VARS=("XDG_CONFIG_HOME=$CASE/xcfg")
refused protected "$HOME/.config/gh"

new_case refuse-gh-config-dir
mkdir -p "$CASE/ghc/sub"
EXT_VARS=("GH_CONFIG_DIR=$CASE/ghc")
refused protected "$CASE/ghc/sub"

new_case refuse-codex-home-default
mkdir -p "$HOME/.codex"
EXT_VARS=("CODEX_HOME=$CASE/chome")
refused protected "$HOME/.codex"

new_case refuse-xdg-data-default
mkdir -p "$HOME/.local/share/opencode"
EXT_VARS=("XDG_DATA_HOME=$CASE/xdg")
refused protected "$HOME/.local/share/opencode"

# CLAUDE_CONFIG_DIR moves this agent's own directory; the default ~/.claude
# stays protected beside it.
new_case refuse-claude-config-dir
mkdir -p "$CASE/cc/projects"
EXT_VARS=("CLAUDE_CONFIG_DIR=$CASE/cc")
refused protected "$CASE/cc/projects"

new_case refuse-claude-config-default
mkdir -p "$HOME/.claude/skills"
EXT_VARS=("CLAUDE_CONFIG_DIR=$CASE/cc")
refused protected "$HOME/.claude/skills"

# GNUPGHOME moves the owner's GnuPG key store; the default ~/.gnupg stays
# protected beside it.
new_case refuse-gnupghome
mkdir -p "$CASE/gpg/private-keys-v1.d"
EXT_VARS=("GNUPGHOME=$CASE/gpg")
refused protected "$CASE/gpg/private-keys-v1.d"

new_case refuse-gnupghome-default
mkdir -p "$HOME/.gnupg/sub"
EXT_VARS=("GNUPGHOME=$CASE/gpg")
refused protected "$HOME/.gnupg/sub"

new_case refuse-edit-level
mkdir "$CASE/out"
refused 'read level only' "$CASE/out" --level edit

new_case refusal-not-for-codex
mkdir -p "$HOME/.ssh"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --allow-dir "$HOME/.ssh"
assert_eq "$rc" 0 "refusal-not-for-codex: rc"
assert_eq "$(st .outcome)" answered "refusal-not-for-codex: outcome"

new_case refusal-not-for-agy
mkdir -p "$HOME/.ssh"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN" --allow-dir "$HOME/.ssh"
assert_eq "$rc" 0 "refusal-not-for-agy: rc"
assert_eq "$(st .outcome)" answered "refusal-not-for-agy: outcome"

# The project boundary.
new_case oc-home-tree
git -C "$HOME" init -q --template="$ROOT/tpl"
WORK="$HOME/.claude/skills/x"
mkdir -p "$WORK"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "oc-home-tree: rc"
assert_contains "$ERR" "too broad" "oc-home-tree: the reason"
assert_contains "$ERR" bundle "oc-home-tree: the remedy"
assert_eq "$(ncalls qwen)" 0 "oc-home-tree: no call"
assert_nofile "$RUN/qwen.status" "oc-home-tree: no status"

new_case oc-inside-protected
WORK="$HOME/.codex/sessions"
mkdir -p "$WORK"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 64 "oc-inside-protected: rc"
assert_contains "$ERR" protected "oc-inside-protected: the reason"
assert_contains "$ERR" bundle "oc-inside-protected: the remedy"
assert_eq "$(ncalls qwen)" 0 "oc-inside-protected: no call"

new_case oc-bundle
WORK="$RUN/bundle"
mkdir "$WORK"
git -C "$WORK" init -q --template="$ROOT/tpl"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "oc-bundle: rc"
assert_eq "$(st .boundary)" "$WORK" "oc-bundle: boundary"

for c in codex agy; do
    new_case "home-tree-$c"
    git -C "$HOME" init -q --template="$ROOT/tpl"
    WORK="$HOME/.claude/skills/x"
    mkdir -p "$WORK"
    answering "$c" 1
    ext run --cli "$c" --run-dir "$RUN"
    assert_eq "$rc" 0 "home-tree-$c: rc"
done

# The version guard.
new_case version-major
echo 2.0.1 > "$SCN/opencode.version"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 19 "version-major: rc"
assert_eq "$(st .outcome)" unsupported_version "version-major: outcome"
assert_eq "$(st .phase)" preflight "version-major: phase"
assert_eq "$(ncalls qwen)" 0 "version-major: no call"
assert_eq "$(st .versions.preflight)" 2.0.1 "version-major: the version recorded"

new_case version-minor
echo 1.20.3 > "$SCN/opencode.version"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "version-minor: rc"
assert_eq "$(st .version_untested)" true "version-minor: version_untested"
assert_eq "$(st .versions.preflight)" 1.20.3 "version-minor: the version recorded"

new_case version-tested
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$(st .version_untested)" false "version-tested: version_untested"

new_case version-garbage
echo banana > "$SCN/opencode.version"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 19 "version-garbage: rc"
assert_contains "$(st .message)" banana "version-garbage: the output named"
assert_eq "$(ncalls qwen)" 0 "version-garbage: no call"

new_case version-fails
echo 1 > "$SCN/opencode.version.exit"
answering qwen 1
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 19 "version-fails: rc"
assert_eq "$(ncalls qwen)" 0 "version-fails: no call"

new_case version-hangs
: > "$SCN/opencode.version.hold"
: > "$SCN/opencode.version.ignore-term"
PRE_LIMIT=1s
answering qwen 1
t0="$EPOCHREALTIME"
ext run --cli qwen --run-dir "$RUN"
took_under "$t0" 10 "version-hangs: the run ended within 10 s"
assert_eq "$rc" 19 "version-hangs: rc"
assert_contains "$(st .message)" "timed out" "version-hangs: message"
assert_eq "$(alive "$(cat "$CALLS/version.pid" 2>/dev/null)" && echo alive || echo gone)" gone \
    "version-hangs: the version command is gone"
assert_eq "$(ncalls qwen)" 0 "version-hangs: no call"
assert_nofile "$RUN/qwen.lock" "version-hangs: no lock"

new_case version-changes
play qwen 1 --stdout "$(t_oc_empty_final S)" --then-version 2.0.0
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 19 "version-changes: rc"
assert_eq "$(st .phase)" resume "version-changes: phase"
assert_eq "$(ncalls qwen)" 1 "version-changes: no resume call"
assert_eq "$(stj .versions.later)" '["2.0.0"]' "version-changes: the later version recorded"
assert_eq "$(st .versions.preflight)" 1.19.0 "version-changes: the preflight version recorded"

# ---------------------------------------------------------------------------
# agy's prompt copy and the before snapshot.

new_case agy-prompt
mkdir -p "$CASE/ok/in" "$CASE/elsewhere"
ln -s "$CASE/elsewhere" "$CASE/ok/link"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN" --allow-dir "$CASE/ok/in" --allow-dir "$CASE/ok/link"
assert_eq "$rc" 0 "agy-prompt: rc"
p="$(cat "$RUN/agy-prompt.md" 2>/dev/null)"
assert_begins "$p" PROMPT "agy-prompt: the copy begins with prompt.md"
for l in "- cat" "- grep" "- $CASE/ok" "- $CASE/elsewhere"; do
    assert_line "$p" "$l" "agy-prompt: a list line"
done
assert_lacks "$p" "- $CASE/ok/in" "agy-prompt: an outside directory under a file-reading directory is not named"
assert_eq "$(argv agy 1 | jq -r '.[1]')" "$p" "agy-prompt: agy is given the copy"
# shellcheck disable=SC2016  # the backticks are the copy's own text
printf '%s\n' PROMPT '' '# Shell commands' 'You may run only these shell commands (matched by word prefix):' \
    '- cat' '- grep' \
    'Any other shell command is denied and ends this run with no answer. When a command would have settled a question, say which command and what you expected instead of running it.' \
    '' '# Reading files' \
    "Your file-reading tool works in your working directory and under these directories, matched against a file's real path:" \
    "- $CASE/ok" \
    'For every other path, and for any path that may be a symbolic link, use `cat`, `head` or `grep`. One refused file read ends this run with no answer.' \
    'These directories named for this task are outside those rules, so read them with shell commands only:' \
    "- $CASE/elsewhere" > "$CASE/want-copy"
assert_eq "$(cmp -s "$CASE/want-copy" "$RUN/agy-prompt.md" && echo same || echo differs)" same \
    "agy-prompt: the whole copy, byte for byte"

new_case agy-prompt-no-dirs
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-prompt-no-dirs: rc"
assert_lacks "$(cat "$RUN/agy-prompt.md" 2>/dev/null)" "outside those rules" "agy-prompt-no-dirs: no outside list"

# An outside directory under the working directory is not named either.
new_case agy-prompt-in-work
mkdir "$WORK/sub"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN" --allow-dir "$WORK/sub"
assert_eq "$rc" 0 "agy-prompt-in-work: rc"
assert_contains "$(cat "$RUN/agy-prompt.md" 2>/dev/null)" "# Reading files" "agy-prompt-in-work: the copy has its blocks"
assert_lacks "$(cat "$RUN/agy-prompt.md" 2>/dev/null)" "outside those rules" "agy-prompt-in-work: no outside list"

# allow_dirs records what the CLI was given of the outside directories: for
# agy exactly the ones its prompt copy names (a link by its real path, one
# that does not resolve as given), not one under a file-reading directory or
# inside the working directory.
new_case agy-allow-dirs
mkdir -p "$CASE/out" "$CASE/ok/in" "$WORK/sub"
ln -s "$CASE/out" "$CASE/lnk"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN" --allow-dir "$CASE/lnk" --allow-dir "$CASE/ok/in" --allow-dir "$WORK/sub" \
    --allow-dir "$CASE/nowhere"
assert_eq "$rc" 0 "agy-allow-dirs: rc"
assert_eq "$(stj .allow_dirs)" "$(jq -cn --arg a "$CASE/out" --arg b "$CASE/nowhere" '[$a, $b]')" \
    "agy-allow-dirs: the two directories the copy names"
assert_eq "$(stj .allow_dirs)" "$(sed -n '/^These directories named for this task/,$ s/^- //p' "$RUN/agy-prompt.md" |
    jq -R . | jq -cs .)" "agy-allow-dirs: exactly the copy's list"

# Codex is given none of them.
new_case codex-allow-dirs
mkdir "$CASE/out"
answering codex 1
ext run --cli codex --run-dir "$RUN" --allow-dir "$CASE/out"
assert_eq "$rc" 0 "codex-allow-dirs: rc"
assert_eq "$(stj .allow_dirs)" '[]' "codex-allow-dirs: none recorded"

new_case agy-no-settings
rm "$HOME/.gemini/antigravity-cli/settings.json"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 18 "agy-no-settings: rc"
assert_contains "$OUT" prerequisite_failed "agy-no-settings: outcome"
assert_contains "$OUT" "status: none" "agy-no-settings: no status named"
assert_contains "$ERR" "$HOME/.gemini/antigravity-cli/settings.json" "agy-no-settings: the file named"
assert_eq "$(ncalls agy)" 0 "agy-no-settings: no call"
assert_nofile "$RUN/agy.status" "agy-no-settings: no status"

# agy's settings must be one JSON object; anything else stops a run before it writes.
new_case agy-settings-not-object
play agy 1 --stdout "$(t_agy_answer C)"
for s in '[]' '{} {}' '"x"'; do
    printf '%s\n' "$s" > "$HOME/.gemini/antigravity-cli/settings.json"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$rc" 18 "agy-settings-not-object $s: rc"
    assert_eq "$OUT" "agy: prerequisite_failed (cannot read agy's settings file $HOME/.gemini/antigravity-cli/settings.json); status: none" \
        "agy-settings-not-object $s: the file named"
    assert_eq "$(ncalls agy)" 0 "agy-settings-not-object $s: no call"
    assert_nofile "$RUN/agy.status" "agy-settings-not-object $s: no status"
done

new_case agy-settings-untouched
s="$(sum "$HOME/.gemini/antigravity-cli/settings.json")"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-settings-untouched: rc"
assert_eq "$(sum "$HOME/.gemini/antigravity-cli/settings.json")" "$s" "agy-settings-untouched: the settings file"

new_case big-prompt-agy
head -c 131000 /dev/zero | tr '\0' x > "$RUN/prompt.md"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 64 "big-prompt-agy: rc"
assert_contains "$ERR" 131072 "big-prompt-agy: the limit named"
assert_eq "$(ncalls agy)" 0 "big-prompt-agy: no call"
assert_nofile "$RUN/agy.status" "big-prompt-agy: no status"

new_case snap-edit
echo changed >> "$WORK/README.md"
echo x > "$WORK/untracked"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "snap-edit: rc"
assert_line "$(cat "$RUN/before.txt" 2>/dev/null)" ' M README.md' "snap-edit: before.txt, the change"
assert_line "$(cat "$RUN/before.txt" 2>/dev/null)" '?? untracked' "snap-edit: before.txt, the untracked file"
assert_line "$(cat "$RUN/before.diff" 2>/dev/null)" '+changed' "snap-edit: before.diff"
assert_eq "$(st .message)" "" "snap-edit: no note"

new_case snap-agy-read
echo changed >> "$WORK/README.md"
echo x > "$WORK/untracked"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "snap-agy-read: rc"
assert_line "$(cat "$RUN/before.txt" 2>/dev/null)" ' M README.md' "snap-agy-read: before.txt"

new_case snap-codex-read
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "snap-codex-read: rc"
assert_nofile "$RUN/before.txt" "snap-codex-read: no before.txt"
assert_nofile "$RUN/before.diff" "snap-codex-read: no before.diff"

new_case snap-unborn
WORK="$CASE/unborn"
mkdir "$WORK"
git init -q --template="$ROOT/tpl" "$WORK"
echo x > "$WORK/new"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "snap-unborn: rc"
assert_contains "$(cat "$RUN/before.txt" 2>/dev/null)" '??' "snap-unborn: before.txt"
assert_file "$RUN/before.diff" "snap-unborn: before.diff exists"
assert_eq "$(wc -c 2>/dev/null < "$RUN/before.diff" | tr -d '[:space:]')" 0 "snap-unborn: before.diff is empty"
assert_contains "$(st .message)" "no commit" "snap-unborn: message"
assert_contains "$OUT" "no commit" "snap-unborn: the note in the summary"

# No .git anywhere above the working directory: the note, and the run goes on
# without a snapshot (a git that fails under a .git: snap-git-fails-in-repo).
new_case snap-no-git
WORK="$CASE/plain"
mkdir "$WORK"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "snap-no-git: rc"
assert_eq "$(st .outcome)" answered "snap-no-git: outcome"
assert_nofile "$RUN/before.txt" "snap-no-git: no before.txt"
assert_nofile "$RUN/before.diff" "snap-no-git: no before.diff"
assert_contains "$(st .message)" "not a git repository" "snap-no-git: message"

# The snapshot leaves the project's index alone, also when it is stale (a file
# touched without a change): git status and git diff would otherwise refresh
# and rewrite it.
new_case snap-index-untouched
touch -d @1000000000 "$WORK/README.md"
keep "$WORK/.git/index"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "snap-index-untouched: rc"
assert_file "$RUN/before.txt" "snap-index-untouched: the snapshot was taken"
unchanged "$WORK/.git/index" "snap-index-untouched"
# The fixture is one in which the option matters: a plain git status rewrites it.
git -C "$WORK" status --short > /dev/null 2>&1
assert_ne "$(sum "$WORK/.git/index")" "$(sum "$CASE/kept/index")" "snap-index-untouched: the fixture's index was stale"

# The note stays when the outcome brings a message of its own.
new_case snap-note-kept
WORK="$CASE/plain"
mkdir "$WORK"
play codex 1 --exit 3 --stderr "$(codex_err U1 boom)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 14 "snap-note-kept: rc"
assert_contains "$(st .message)" "boom" "snap-note-kept: the outcome's message"
assert_contains "$(st .message)" "not a git repository" "snap-note-kept: the note"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d '[:space:]')" 1 "snap-note-kept: one summary line"

new_case snap-own-repo
fixture_repo "$CASE/other"
echo elsewhere >> "$CASE/other/README.md"
echo changed >> "$WORK/README.md"
EXT_VARS=("GIT_DIR=$CASE/other/.git" "GIT_WORK_TREE=$CASE/other")
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "snap-own-repo: rc"
assert_line "$(cat "$RUN/before.diff" 2>/dev/null)" '+changed' "snap-own-repo: the working directory's change"
assert_lacks "$(cat "$RUN/before.diff" 2>/dev/null)" '+elsewhere' "snap-own-repo: not the inherited repository's"

new_case snap-no-helper
# shellcheck disable=SC2016  # expanded when git runs the helper
mk_tool "$CASE/helper" <<< ': > "$CASE/helper-ran"'
git -C "$WORK" config diff.external "$CASE/helper"
echo changed >> "$WORK/README.md"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "snap-no-helper: rc"
assert_line "$(cat "$RUN/before.diff" 2>/dev/null)" '+changed' "snap-no-helper: before.diff"
assert_nofile "$CASE/helper-ran" "snap-no-helper: the snapshot ran no diff helper"

# The snapshot is plain text of the whole work tree, whatever the project's
# configuration says about colour and relative diffs; the run starts in a
# subdirectory, and the changes lie inside and outside it.
new_case snap-plain
git -C "$WORK" config color.ui always
git -C "$WORK" config color.status always
git -C "$WORK" config color.diff always
git -C "$WORK" config diff.relative true
mkdir "$WORK/sub"
echo inside > "$WORK/sub/f"
git -C "$WORK" add sub/f
git -C "$WORK" commit -q -m sub
echo changed >> "$WORK/README.md"
echo more >> "$WORK/sub/f"
WORK="$CASE/work/sub"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "snap-plain: rc"
assert_eq "$(LC_ALL=C grep -c $'\033' "$RUN/before.txt" "$RUN/before.diff" 2>&1)" \
    "$RUN/before.txt:0"$'\n'"$RUN/before.diff:0" "snap-plain: no escape sequence in either file"
assert_line "$(cat "$RUN/before.txt" 2>/dev/null)" ' M ../README.md' "snap-plain: before.txt, the change outside the directory"
assert_line "$(cat "$RUN/before.txt" 2>/dev/null)" ' M f' "snap-plain: before.txt, the change inside it"
assert_line "$(cat "$RUN/before.diff" 2>/dev/null)" '+changed' "snap-plain: before.diff, the change outside the directory"
assert_line "$(cat "$RUN/before.diff" 2>/dev/null)" '+more' "snap-plain: before.diff, the change inside it"

new_case snap-kept-by-continue
ul_first_run
assert_file "$RUN/before.diff" "snap-kept-by-continue: the run wrote before.diff"
keep "$RUN/before.diff"
keep "$RUN/before.txt"
echo more >> "$WORK/README.md"
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "snap-kept-by-continue: rc"
unchanged "$RUN/before.diff" "snap-kept-by-continue"
unchanged "$RUN/before.txt" "snap-kept-by-continue"

new_case agy-continue-keeps-copy
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
fake_ul agy
keep "$RUN/agy-prompt.md"
keep "$RUN/before.txt"
rm "$HOME/.gemini/antigravity-cli/settings.json"
echo more >> "$WORK/README.md"
play agy 2 --stdout "$(t_agy_answer C)"
ext continue --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-continue-keeps-copy: rc (a continue does not read agy's settings)"
unchanged "$RUN/agy-prompt.md" "agy-continue-keeps-copy"
unchanged "$RUN/before.txt" "agy-continue-keeps-copy"
assert_eq "$(st .configured_model)" "Fixture Default" "agy-continue-keeps-copy: configured_model"
assert_begins "$(argv agy 2)" '["--conversation","C","-p",' "agy-continue-keeps-copy: argv"
assert_eq "$(argv agy 2 | jq -r '.[3]')" "$CONTINUE_TEXT" "agy-continue-keeps-copy: the continue text"

# In step 7 the run owns its status file, where no usage error is written: a
# git that cannot be run, or that fails, there ends the run as a missing
# prerequisite, recorded in the status file, before the CLI starts.
new_case snap-git-cannot-run
mk_tool "$CASE/nogit/git" <<< 'exit 127'
EXT_PATH="$CASE/nogit:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 18 "snap-git-cannot-run: rc"
assert_eq "$(st .outcome)" prerequisite_failed "snap-git-cannot-run: outcome"
assert_contains "$(st .message)" "git cannot be run" "snap-git-cannot-run: message"
assert_eq "$(ncalls codex)" 0 "snap-git-cannot-run: no call"

new_case snap-git-vars-fail
mk_tool "$CASE/failgit/git" <<< 'exit 1'
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 18 "snap-git-vars-fail: rc, not a usage error"
assert_eq "$(st .outcome)" prerequisite_failed "snap-git-vars-fail: outcome"
assert_contains "$(st .message)" "--local-env-vars" "snap-git-vars-fail: the query named"
assert_eq "$(ncalls codex)" 0 "snap-git-vars-fail: no call"

# The same for agy, which takes its snapshot at the read level too: the run
# owns its status file by then, so the failed call is recorded as a missing
# prerequisite, not refused as a usage error.
new_case snap-git-vars-fail-agy
mk_tool "$CASE/failgit/git" <<< "echo 'fatal: VARS-REASON' >&2; exit 1"
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
answering agy 1
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 18 "snap-git-vars-fail-agy: rc, not a usage error"
assert_eq "$(st .outcome)" prerequisite_failed "snap-git-vars-fail-agy: outcome"
assert_eq "$(st .message)" "git rev-parse --local-env-vars failed with status 1 (fatal: VARS-REASON)" \
    "snap-git-vars-fail-agy: the query and git's reason named"
assert_ends "$OUT" "status: $RUN/agy.status" "snap-git-vars-fail-agy: the status named"
assert_nofile "$RUN/before.txt" "snap-git-vars-fail-agy: no before.txt"
assert_eq "$(ncalls agy)" 0 "snap-git-vars-fail-agy: no call"

# An answer that does not name GIT_DIR, met first in the snapshot for Codex:
# the run ends there, recorded, before the CLI starts.
new_case snap-git-vars-no-git-dir
mk_tool "$CASE/emptygit/git" <<'EOF'
if [ "$*" = 'rev-parse --local-env-vars' ]; then exit 0; fi
exec "$BIN_ROOT/utils/git" "$@"
EOF
EXT_PATH="$CASE/emptygit:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 18 "snap-git-vars-no-git-dir: rc"
assert_eq "$(st .outcome)" prerequisite_failed "snap-git-vars-no-git-dir: outcome"
assert_contains "$(st .message)" "git rev-parse --local-env-vars" "snap-git-vars-no-git-dir: git named"
assert_contains "$(st .message)" "did not list GIT_DIR" "snap-git-vars-no-git-dir: what is missing"
assert_nofile "$RUN/before.txt" "snap-git-vars-no-git-dir: no before.txt"
assert_eq "$(ncalls codex)" 0 "snap-git-vars-no-git-dir: no call"

new_case snap-status-fails
mk_tool "$CASE/failgit/git" <<'EOF'
case " $* " in *' status '*) echo 'fatal: STATUS-REASON' >&2; exit 1 ;; esac
exec "$BIN_ROOT/utils/git" "$@"
EOF
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 18 "snap-status-fails: rc"
assert_eq "$(st .outcome)" prerequisite_failed "snap-status-fails: outcome"
assert_contains "$(st .message)" "git status" "snap-status-fails: the query named"
assert_contains "$(st .message)" "fatal: STATUS-REASON" "snap-status-fails: git's reason"
assert_eq "$(ncalls codex)" 0 "snap-status-fails: no call"

# The snapshot's later queries: a failing look at HEAD, or a failing diff,
# ends the run as a missing prerequisite with git's own reason, before the
# CLI starts.
new_case snap-verify-fails
mk_tool "$CASE/failgit/git" <<'EOF'
case " $* " in *' --verify '*) echo 'fatal: VERIFY-REASON' >&2; exit 128 ;; esac
exec "$BIN_ROOT/utils/git" "$@"
EOF
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 18 "snap-verify-fails: rc"
assert_eq "$(st .outcome)" prerequisite_failed "snap-verify-fails: outcome"
assert_contains "$(st .message)" "git rev-parse --verify HEAD failed with status 128" "snap-verify-fails: the query named"
assert_contains "$(st .message)" "fatal: VERIFY-REASON" "snap-verify-fails: git's reason"
assert_eq "$(ncalls codex)" 0 "snap-verify-fails: no call"

new_case snap-diff-fails
mk_tool "$CASE/failgit/git" <<'EOF'
case " $* " in *' diff '*) echo 'fatal: DIFF-REASON' >&2; exit 128 ;; esac
exec "$BIN_ROOT/utils/git" "$@"
EOF
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 18 "snap-diff-fails: rc"
assert_eq "$(st .outcome)" prerequisite_failed "snap-diff-fails: outcome"
assert_contains "$(st .message)" "git diff failed with status 128" "snap-diff-fails: the query named"
assert_contains "$(st .message)" "fatal: DIFF-REASON" "snap-diff-fails: git's reason"
assert_eq "$(ncalls codex)" 0 "snap-diff-fails: no call"

# git runs and fails although a .git lies above the working directory: a
# .git file git cannot read, or a repository git refuses (a stand-in that
# answers as git does for a repository of another owner). The snapshot cannot
# be taken, so the run stops before the CLI starts, at the edit level and for
# agy at the read level, and its status names git's reason. A directory with
# no .git above still gets the note (snap-no-git, notes-continue-no-git).
new_case snap-git-fails-in-repo
mkdir -p "$CASE/broken/sub"
: > "$CASE/broken/.git"
mk_tool "$CASE/refusinggit/git" <<'EOF'
case " $* " in
    *' --is-inside-work-tree '*) echo "fatal: detected dubious ownership in repository at '$CASE/work'" >&2; exit 128 ;;
esac
exec "$BIN_ROOT/utils/git" "$@"
EOF
play codex 1 --stdout A --stderr "$(codex_err U1)"
play agy 1 --stdout "$(t_agy_answer C)"
k=0
for f in broken refusing; do
    for a in "codex --level edit" agy; do
        k=$((k + 1))
        RUN="$CASE/run$k"
        make_run "$RUN"
        if [ "$f" = broken ]; then
            WORK="$CASE/broken/sub" top="$CASE/broken/.git" why='(fatal: '
            unset EXT_PATH
        else
            WORK="$CASE/work" top="$CASE/work/.git" why='(fatal: detected dubious ownership'
            EXT_PATH="$CASE/refusinggit:$CASE/bin:$BIN_ROOT/utils"
        fi
        read -r -a w <<< "$a"
        ext run --cli "${w[0]}" --run-dir "$RUN" "${w[@]:1}"
        l="snap-git-fails-in-repo $f ${w[0]}"
        assert_eq "$rc" 18 "$l: rc"
        assert_eq "$OUT" "${w[0]}: prerequisite_failed ($(st .message)); status: $RUN/${w[0]}.status" "$l: the status named"
        assert_eq "$(st .outcome)" prerequisite_failed "$l: outcome"
        assert_eq "$(st .phase)" preflight "$l: phase"
        assert_contains "$(st .message)" "git rev-parse --is-inside-work-tree failed with status 128 in $WORK" "$l: the query named"
        assert_contains "$(st .message)" "$why" "$l: git's reason"
        assert_contains "$(st .message)" "$top exists" "$l: the .git named"
        assert_eq "$(stj .notes)" '[]' "$l: no note"
        assert_nofile "$RUN/before.txt" "$l: no before.txt"
    done
done
assert_eq "$(ncalls codex)" 0 "snap-git-fails-in-repo: no call of codex"
assert_eq "$(ncalls agy)" 0 "snap-git-fails-in-repo: no call of agy"

# A working directory that its git work tree ignores gets no before snapshot,
# only a note, and the run goes on: git status shows nothing of what a CLI
# writes there. The stand-in is a home directory that is a git work tree as
# the dotfiles make it: the repository is reached through a link named .git
# (core.worktree the home directory, untracked files hidden), and the ignore
# file ignores every top-level entry ("/*") except a few ("!/"). git
# check-ignore reports a directory below an ignored top-level entry as ignored
# (~/Downloads/proj, ~/.cache/external-agents) and one below an exception as
# not ignored (~/.claude/skills/x), which keeps its snapshot of the work tree.
# A directory a project's own ignore file names gets the note too.
new_case snap-ignored
D="$HOME/.local/share/yadm/repo.git"
mkdir -p "$HOME/Downloads/proj" "$HOME/.cache/external-agents" "$HOME/.claude/skills/x" "${D%/*}"
if ! { git init -q --bare --template="$ROOT/tpl" "$D" &&
    git -C "$D" config core.bare false &&
    git -C "$D" config core.worktree "$HOME" &&
    git -C "$D" config status.showUntrackedFiles no &&
    git -C "$D" config user.name Fixture &&
    git -C "$D" config user.email fixture@example.invalid &&
    git -C "$D" config core.hooksPath "$ROOT/tpl" &&
    ln -s .local/share/yadm/repo.git "$HOME/.git" &&
    printf '%s\n' '/*' '!/.gitignore' '!/.claude' > "$HOME/.gitignore" &&
    printf 'skill\n' > "$HOME/.claude/skills/x/SKILL.md" &&
    git -C "$HOME" add .gitignore .claude/skills/x/SKILL.md &&
    git -C "$HOME" commit -q -m dotfiles; }; then
    printf 'ext-run.test: snap-ignored: the stand-in home could not be made\n' >&2
    exit 2
fi
git -C "$HOME/Downloads/proj" check-ignore -q .
assert_eq "$?" 0 "snap-ignored: git reports a directory below an ignored top-level entry as ignored"
git -C "$HOME/.cache/external-agents" check-ignore -q .
assert_eq "$?" 0 "snap-ignored: and another"
git -C "$HOME/.claude/skills/x" check-ignore -q .
assert_eq "$?" 1 "snap-ignored: and one below an exception as not ignored"
# Changes the snapshot of the work tree would hold, as another session leaves them.
echo more >> "$HOME/.claude/skills/x/SKILL.md"
echo x > "$HOME/.claude/skills/x/untracked"
mkdir "$CASE/work/build"
printf 'build/\n' > "$CASE/work/.gitignore"
note='the working directory is ignored by its git work tree: no before snapshot'
play codex 1 --stdout A --stderr "$(codex_err U1)"
play codex 2 --stdout A --stderr "$(codex_err U1)"
play codex 3 --stdout A --stderr "$(codex_err U1)"
play agy 1 --stdout "$(t_agy_answer C)"
k=0
for a in "codex $HOME/Downloads/proj note" "agy $HOME/.cache/external-agents note" \
    "codex $HOME/.claude/skills/x snapshot" "codex $CASE/work/build note"; do
    read -r cli WORK want <<< "$a"
    k=$((k + 1))
    RUN="$CASE/run$k"
    make_run "$RUN"
    if [ "$cli" = codex ]; then
        ext run --cli codex --run-dir "$RUN" --level edit
    else
        ext run --cli agy --run-dir "$RUN"
    fi
    l="snap-ignored $cli in ${WORK#"$CASE/"}"
    assert_eq "$rc" 0 "$l: rc"
    assert_eq "$(st .outcome)" answered "$l: outcome"
    if [ "$want" = note ]; then
        assert_eq "$(stj .notes)" "$(jq -cn --arg n "$note" '[$n]')" "$l: the note"
        assert_eq "$OUT" "$cli: answered ($note); status: $RUN/$cli.status" "$l: the note in the summary"
        assert_nofile "$RUN/before.txt" "$l: no before.txt"
        assert_nofile "$RUN/before.diff" "$l: no before.diff"
    else
        assert_eq "$(stj .notes)" '[]' "$l: no note"
        assert_line "$(cat "$RUN/before.txt" 2>/dev/null)" ' M SKILL.md' "$l: before.txt, the change"
        assert_line "$(cat "$RUN/before.txt" 2>/dev/null)" '?? untracked' "$l: before.txt, the untracked file"
        assert_line "$(cat "$RUN/before.diff" 2>/dev/null)" '+more' "$l: before.diff"
    fi
done
assert_eq "$(callf codex 1 cwd)" "$HOME/Downloads/proj" "snap-ignored: the CLI ran in the ignored directory"
assert_eq "$(ncalls codex) $(ncalls agy)" "3 1" "snap-ignored: every run made its call"

# The query runs without the repository variables the runner inherited, as
# the snapshot's other queries do: an inherited repository whose exclude file
# names the working directory does not make it ignored.
new_case snap-ignored-own-repo
fixture_repo "$CASE/other"
mkdir -p "$CASE/other/.git/info"
printf '/work/\n' > "$CASE/other/.git/info/exclude"
EXT_VARS=("GIT_DIR=$CASE/other/.git" "GIT_WORK_TREE=$CASE")
env "${EXT_VARS[@]}" git -C "$WORK" check-ignore -q .
assert_eq "$?" 0 "snap-ignored-own-repo: the inherited repository calls the working directory ignored"
echo changed >> "$WORK/README.md"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 0 "snap-ignored-own-repo: rc"
assert_eq "$(stj .notes)" '[]' "snap-ignored-own-repo: no note"
assert_line "$(cat "$RUN/before.diff" 2>/dev/null)" '+changed' "snap-ignored-own-repo: the working directory's own snapshot"

# Only status 0 (ignored) and 1 (not ignored) are check-ignore's answers. Any
# other is a git failure, never "not ignored": with a .git above, the run
# ends as a missing prerequisite before the CLI starts, with git's reason, as
# for the snapshot's other queries.
new_case snap-check-ignore-fails
mk_tool "$CASE/failgit/git" <<'EOF'
case " $* " in *' check-ignore '*) echo 'fatal: IGNORE-REASON' >&2; exit "$(cat "$CASE/ignore-rc")" ;; esac
exec "$BIN_ROOT/utils/git" "$@"
EOF
EXT_PATH="$CASE/failgit:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
play agy 1 --stdout "$(t_agy_answer C)"
k=0
for r in 128 2; do
    echo "$r" > "$CASE/ignore-rc"
    for a in "codex --level edit" agy; do
        k=$((k + 1))
        RUN="$CASE/run$k"
        make_run "$RUN"
        read -r -a w <<< "$a"
        ext run --cli "${w[0]}" --run-dir "$RUN" "${w[@]:1}"
        l="snap-check-ignore-fails $r ${w[0]}"
        assert_eq "$rc" 18 "$l: rc"
        assert_eq "$(st .outcome)" prerequisite_failed "$l: outcome"
        assert_eq "$(st .phase)" preflight "$l: phase"
        assert_eq "$(st .message)" \
            "git check-ignore failed with status $r in $WORK (fatal: IGNORE-REASON), so no before snapshot was taken" \
            "$l: the query and git's reason named"
        assert_eq "$(stj .notes)" '[]' "$l: no note"
        assert_nofile "$RUN/before.txt" "$l: no before.txt"
    done
done
assert_eq "$(ncalls codex) $(ncalls agy)" "0 0" "snap-check-ignore-fails: no call"

# A run that would take the before snapshot (the edit level, agy at either
# level) refuses a run directory that holds one already, decided under the
# claim without asking git, so also outside a git work tree: no status, no
# call, the files and a new run directory named, the files left as they were.
# A read-level Codex or OpenCode run beside them takes no snapshot and runs.
new_case snap-exists
mkdir "$CASE/plain"
play codex 1 --stdout A --stderr "$(codex_err U1)"
play agy 1 --stdout "$(t_agy_answer C)"
answering qwen 1
for files in before.txt before.diff 'before.txt before.diff'; do
    rm -f "$RUN/before.txt" "$RUN/before.diff"
    for f in $files; do printf 'OLD\n' > "$RUN/$f"; done
    for a in "codex --level edit" agy "qwen --level edit" "codex --level edit plain"; do
        read -r -a w <<< "$a"
        WORK="$CASE/work"
        if [ "${w[3]:-}" = plain ]; then WORK="$CASE/plain"; fi
        ext run --cli "${w[0]}" --run-dir "$RUN" "${w[@]:1:2}"
        l="snap-exists $files, $a"
        assert_eq "$rc" 64 "$l: rc"
        assert_eq "$OUT" "${w[0]}: usage_error (a before snapshot already exists in $RUN: $files); status: none" "$l: summary"
        assert_contains "$ERR" "Start the run in a new run directory" "$l: the remedy"
        assert_nofile "$RUN/${w[0]}.status" "$l: no status"
        assert_nofile "$RUN/${w[0]}.lock" "$l: no lock"
    done
    for f in $files; do assert_eq "$(cat "$RUN/$f")" OLD "snap-exists $files: $f left as it was"; done
done
assert_nofile "$RUN/agy-prompt.md" "snap-exists: no prompt copy"
assert_eq "$(ncalls codex) $(ncalls agy) $(ncalls qwen)" "0 0 0" "snap-exists: no call"
WORK="$CASE/work"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "snap-exists: a read-level Codex run beside them"
ext run --cli qwen --run-dir "$RUN"
assert_eq "$rc" 0 "snap-exists: a read-level OpenCode run beside them"
for f in before.txt before.diff; do assert_eq "$(cat "$RUN/$f")" OLD "snap-exists: $f still as it was"; done

# ---------------------------------------------------------------------------
# Signals, the live status, failed writes, and concurrency. Every case here
# synchronises on files: the runner in the background, a wait for the fact the
# action needs, the action, then the wait for the runner.

alive_yn() { # pid: yes when alive, no otherwise
    if alive "$1"; then echo yes; else echo no; fi
}

err_last() { # the last line of ERR
    printf '%s\n' "$ERR" | tail -n 1
}

no_locks() { # the case's run directory holds no lock directory
    local f
    for f in "$RUN"/*.lock; do
        if [ -e "$f" ]; then
            echo "${f##*/}"
            return
        fi
    done
    echo none
}

mk_gate() { # [-p]: a mkdir in $CASE/gate that holds every claim until two claimants have reached it (at most 5 s), then makes the directory (with -p when asked, so that it succeeds for both) and records its status in $CASE/gate.rc
    mkdir "$CASE/gate.d" "$CASE/gate.rc" || exit 2
    if [ "${1:-}" = -p ]; then : > "$CASE/gate.p"; fi
    mk_tool "$CASE/gate/mkdir" <<'EOF' || exit 2
last="${*: -1}"
if [[ $last == *.lock ]]; then
    : > "$CASE/gate.d/$$"
    n=0
    while :; do
        f=("$CASE/gate.d"/*)
        if [ "${#f[@]}" -ge 2 ] || [ "$n" -ge 500 ]; then break; fi
        sleep 0.01
        n=$((n + 1))
    done
    if [ -e "$CASE/gate.p" ]; then set -- -p "$@"; fi
    "$BIN_ROOT/utils/mkdir" "$@"
    st=$?
    printf '%s\n' "$st" > "$CASE/gate.rc/$$"
    exit "$st"
fi
exec "$BIN_ROOT/utils/mkdir" "$@"
EOF
}

gate_count() { # the number of claimants that reached the gate
    local f n=0
    for f in "$CASE/gate.d"/*; do
        if [ -e "$f" ]; then n=$((n + 1)); fi
    done
    echo "$n"
}

mk_jq_hold() { # glob: a jq in $CASE/slowjq that, the first time one of its arguments matches the glob, creates $CASE/jq-entered and waits (at most 10 s) for $CASE/jq-go before it runs
    printf '%s' "$1" > "$CASE/jq-hold" || exit 2
    mk_tool "$CASE/slowjq/jq" <<'EOF' || exit 2
p="$(cat "$CASE/jq-hold")"
for a in "$@"; do
    if [[ $a == $p ]] && [ ! -e "$CASE/jq-entered" ]; then
        : > "$CASE/jq-entered"
        n=0
        until [ -e "$CASE/jq-go" ] || [ "$n" -ge 100 ]; do
            sleep 0.1
            n=$((n + 1))
        done
    fi
done
exec "$BIN_ROOT/utils/jq" "$@"
EOF
}

new_case term
play codex 1 --hold --child 30 --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
assert_eq "$(cat "$RUN/codex.lock/pid" 2>/dev/null)" "$BG" "term: the background runner holds the claim"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "term: rc"
assert_eq "$(st .outcome)" cancelled "term: outcome"
assert_eq "$(st .phase)" first "term: phase"
assert_eq "$(st '.attempts[0].signalled')" true "term: signalled"
assert_eq "$(st '.attempts[0].rule')" 1 "term: rule 1"
assert_ne "$(st '.attempts[0].exit')" 0 "term: the attempt's exit is not 0, so rule 8 would match too"
assert_nofile "$RUN/codex.lock" "term: no lock"
assert_eq "$(alive_yn "$(callf codex 1 pid)")" no "term: the CLI is gone"
assert_eq "$(alive_yn "$(callf codex 1 child)")" no "term: its child is gone"
assert_begins "$OUT" "codex: cancelled" "term: summary"
assert_ends "$OUT" "status: $RUN/codex.status" "term: the status named"

new_case hup
play codex 1 --hold --child 30 --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
kill -HUP "$BG"
ext_wait
assert_eq "$rc" 20 "hup: rc"
assert_eq "$(st .outcome)" cancelled "hup: outcome"
assert_eq "$(alive_yn "$(callf codex 1 pid)")" no "hup: the CLI is gone"
assert_eq "$(alive_yn "$(callf codex 1 child)")" no "hup: its child is gone"
assert_nofile "$RUN/codex.lock" "hup: no lock"

new_case term-ignored
play codex 1 --hold --ignore-term --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
t0="$EPOCHREALTIME"
kill -TERM "$BG"
ext_wait
took_under "$t0" 10 "term-ignored: from the signal to the end"
assert_eq "$rc" 20 "term-ignored: rc"
assert_eq "$(st .outcome)" cancelled "term-ignored: outcome"
assert_eq "$(alive_yn "$(callf codex 1 pid)")" no "term-ignored: the CLI is gone"

# A signal while the CLI runs, and a process of its group outlives the kill:
# the attempt is recorded as signalled and not classified, and the run ends
# as a runner failure.
new_case cancel-survivor
mk_ghost_ps "$CASE/ghost"
EXT_PATH="$CASE/ghost:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --hold --stdout "$(t_agy_answer C)"
ext_bg run --cli agy --run-dir "$RUN"
wait_for "$CALLS/agy.1/started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 21 "cancel-survivor: rc"
assert_eq "$(st .outcome)" runner_failure "cancel-survivor: outcome"
assert_contains "$(st .message)" "could not stop process group" "cancel-survivor: message"
assert_eq "$(st '.attempts | length')" 1 "cancel-survivor: the attempt is recorded"
assert_eq "$(stj '.attempts[0] | [.signalled, .verdict, .rule]')" '[true,null,null]' \
    "cancel-survivor: signalled, and not classified"
assert_file "$RUN/agy.first1.exit" "cancel-survivor: agy.first1.exit"
assert_nofile "$RUN/agy.out" "cancel-survivor: no answer published"
assert_eq "$(ncalls agy)" 1 "cancel-survivor: one call"
assert_nofile "$RUN/agy.lock" "cancel-survivor: no lock"

new_case agy-denied-cancelled
play agy 1 --stdout-early "$(t_agy_denied C)" --hold
ext_bg run --cli agy --run-dir "$RUN"
wait_for "$CALLS/agy.1/started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "agy-denied-cancelled: rc"
assert_eq "$(st .outcome)" cancelled "agy-denied-cancelled: outcome"
assert_eq "$(st '.attempts[0].rule')" 1 "agy-denied-cancelled: rule 1, not rule 4"
assert_eq "$(st '.attempts[0].denied | length')" 1 "agy-denied-cancelled: the denied action is recorded"

new_case term-in-resume
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --hold --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.2/started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "term-in-resume: rc"
assert_eq "$(st .outcome)" cancelled "term-in-resume: outcome"
assert_eq "$(st .phase)" resume "term-in-resume: phase"
assert_eq "$(st '.attempts | length')" 2 "term-in-resume: two attempts"
assert_eq "$(st '.attempts[1].signalled')" true "term-in-resume: the resume was signalled"
assert_eq "$(alive_yn "$(callf codex 2 pid)")" no "term-in-resume: the CLI is gone"

# A signal after the CLI has exited, while the runner reads the attempt (a
# jq stand-in holds the look at resume_used): the attempt's verdict stands,
# and the resume that would have followed is not started.
new_case term-before-resume
mk_jq_hold .resume_used
EXT_PATH="$CASE/slowjq:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout '' --stderr "$(codex_err U1)"
play codex 2 --stdout LATE --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CASE/jq-entered"
kill -TERM "$BG"
: > "$CASE/jq-go"
ext_wait
assert_eq "$rc" 20 "term-before-resume: rc"
assert_eq "$(st .outcome)" cancelled "term-before-resume: outcome"
assert_eq "$(st .phase)" resume "term-before-resume: phase"
assert_eq "$(st '.attempts | length')" 1 "term-before-resume: one attempt"
assert_eq "$(stj '.attempts[0] | [.verdict, .signalled]')" '["empty",false]' "term-before-resume: its verdict stands"
assert_eq "$(st .resume_used)" false "term-before-resume: the resume was not used"
assert_eq "$(ncalls codex)" 1 "term-before-resume: no resume call"
assert_nofile "$RUN/codex.lock" "term-before-resume: no lock"

# The same when the attempt answered (the stand-in holds the attempt's
# record): the run ends answered and publishes the answer.
new_case term-after-answer
# shellcheck disable=SC2016  # the runner's jq filter, as written
mk_jq_hold '*rule: $rule, verdict: $verdict*'
EXT_PATH="$CASE/slowjq:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout ANSWER --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CASE/jq-entered"
kill -TERM "$BG"
: > "$CASE/jq-go"
ext_wait
assert_eq "$rc" 0 "term-after-answer: rc"
assert_eq "$(st .outcome)" answered "term-after-answer: outcome"
assert_eq "$(stj '.attempts[0] | [.verdict, .signalled]')" '["answered",false]' "term-after-answer: the verdict stands"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" ANSWER "term-after-answer: the answer is published"
assert_eq "$(ncalls codex)" 1 "term-after-answer: one call"

# A tail whose first read of a file whose path matches the glob prints the
# file's last lines, closes its output and then lingers until the case
# creates tail-go: the runner has every line by then and waits only for the
# status, which is when the case sends its signal.
mk_hold_tail() { # dir glob
    mk_tool "$1/tail" <<'EOF' &&
read -r glob < "${0%/*}/tail.hold"
for a in "$@"; do last="$a"; done
if [[ $last == $glob ]] && mkdir "$CASE/tail-held" 2>/dev/null; then
    "$BIN_ROOT/utils/tail" "$@"
    st=$?
    exec >&-
    : > "$CASE/tail-entered"
    n=0
    until [ -e "$CASE/tail-go" ] || [ "$n" -ge 100 ]; do
        sleep 0.1
        n=$((n + 1))
    done
    exit "$st"
fi
exec "$BIN_ROOT/utils/tail" "$@"
EOF
        printf '%s\n' "$2" > "$1/tail.hold"
}

# The same when the signal arrives while the runner takes the status of a
# read of the ended attempt's files: the read is whole, not a failed one, so
# the verdict stands. For an answer that read is the tokens used lines,
# taken in a command substitution of its own.
new_case term-in-tail-answer
mk_hold_tail "$CASE/holdtail" '*/codex.first1.stderr'
EXT_PATH="$CASE/holdtail:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout ANSWER --stderr "$(codex_err U1 'tokens used' '8,834')"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CASE/tail-entered"
sleep 0.5
kill -TERM "$BG"
: > "$CASE/tail-go"
ext_wait
assert_eq "$rc" 0 "term-in-tail-answer: rc"
assert_eq "$(st .outcome)" answered "term-in-tail-answer: outcome"
assert_eq "$(stj '.attempts[0].tokens')" '{"reported":8834}' "term-in-tail-answer: the tokens, read whole"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" ANSWER "term-in-tail-answer: the answer is published"

# For an attempt that a usage limit ended, it is the usage-limit error: the
# run ends usage_limit, a record a continue accepts.
new_case term-in-tail-usage-limit
mk_hold_tail "$CASE/holdtail" '*/codex.first1.stderr'
EXT_PATH="$CASE/holdtail:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --exit 1 --stderr "$(codex_err U1 "$ul_line" 'tokens used' '131,586')"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CASE/tail-entered"
sleep 0.5
kill -TERM "$BG"
: > "$CASE/tail-go"
ext_wait
assert_eq "$rc" 13 "term-in-tail-usage-limit: rc"
assert_eq "$(st .outcome)" usage_limit "term-in-tail-usage-limit: outcome"
assert_eq "$(st '.attempts[0].rule')" 5 "term-in-tail-usage-limit: rule"

# For a CLI that failed it is rule 8's reason, which the message keeps.
new_case term-in-tail-rule8
mk_hold_tail "$CASE/holdtail" '*/agy.first1.stderr'
EXT_PATH="$CASE/holdtail:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --exit 3 --stdout "$(t_agy_answer C)" --stderr 'agy: boom'
ext_bg run --cli agy --run-dir "$RUN"
wait_for "$CASE/tail-entered"
sleep 0.5
kill -TERM "$BG"
: > "$CASE/tail-go"
ext_wait
assert_eq "$rc" 14 "term-in-tail-rule8: rc"
assert_eq "$(st '.attempts[0].rule')" 8 "term-in-tail-rule8: rule"
assert_eq "$(st .message)" "agy exited with status 3: agy: boom" "term-in-tail-rule8: the reason, read whole"

new_case term-in-preflight
: > "$SCN/codex.sandbox.hold"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/sandbox.started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "term-in-preflight: rc"
assert_eq "$(st .outcome)" cancelled "term-in-preflight: outcome"
assert_eq "$(st .phase)" preflight "term-in-preflight: phase"
assert_eq "$(ncalls codex)" 0 "term-in-preflight: no call"
assert_eq "$(alive_yn "$(cat "$CALLS/sandbox.pid" 2>/dev/null)")" no "term-in-preflight: the probe is gone"
assert_nofile "$RUN/codex.lock" "term-in-preflight: no lock"

# A signal during the part of step 7 that starts no command (a jq stand-in
# holds the recording of the prompt's checksum): the run ends in the
# preflight phase, before the first attempt is written as running.
new_case term-before-first
# shellcheck disable=SC2016  # the runner's jq filter, as written
mk_jq_hold '.prompt_sha256 = $s'
EXT_PATH="$CASE/slowjq:$CASE/bin:$BIN_ROOT/utils"
answering codex 1
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CASE/jq-entered"
kill -TERM "$BG"
: > "$CASE/jq-go"
ext_wait
assert_eq "$rc" 20 "term-before-first: rc"
assert_eq "$(st .outcome)" cancelled "term-before-first: outcome"
assert_eq "$(st .phase)" preflight "term-before-first: phase"
assert_eq "$(st '.attempts | length')" 0 "term-before-first: no attempt"
assert_eq "$(ncalls codex)" 0 "term-before-first: no call"
assert_nofile "$RUN/codex.lock" "term-before-first: no lock"

# agy's settings are read once, in step 3, for the rules and the model: a file
# that no longer parses by step 7 is not read again, the run goes on, and the
# status records the model step 3 read.
new_case agy-settings-changed
# shellcheck disable=SC2016  # the runner's jq filter, as written
mk_jq_hold '.prompt_sha256 = $s'
EXT_PATH="$CASE/slowjq:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --stdout "$(t_agy_answer C)"
ext_bg run --cli agy --run-dir "$RUN"
wait_for "$CASE/jq-entered"
printf 'not json\n' > "$HOME/.gemini/antigravity-cli/settings.json"
: > "$CASE/jq-go"
ext_wait
assert_eq "$rc" 0 "agy-settings-changed: rc"
assert_eq "$(st .outcome)" answered "agy-settings-changed: outcome"
assert_eq "$(st .configured_model)" "Fixture Default" "agy-settings-changed: configured_model, as step 3 read it"
assert_eq "$(ncalls agy)" 1 "agy-settings-changed: one call"

# One read of the settings file in a whole run: a jq in front of the real one
# notes every call that names the file.
new_case agy-settings-read-once
mk_tool "$CASE/logjq/jq" <<'EOF'
for a in "$@"; do
    if [ "$a" = "$HOME/.gemini/antigravity-cli/settings.json" ]; then echo read >> "$CASE/settings-reads"; fi
done
exec "$BIN_ROOT/utils/jq" "$@"
EOF
EXT_PATH="$CASE/logjq:$CASE/bin:$BIN_ROOT/utils"
play agy 1 --stdout "$(t_agy_answer C)"
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 0 "agy-settings-read-once: rc"
assert_eq "$(wc -l < "$CASE/settings-reads" 2>/dev/null | tr -d '[:space:]')" 1 "agy-settings-read-once: one read"
assert_eq "$(st .configured_model)" "Fixture Default" "agy-settings-read-once: configured_model"
assert_line "$(cat "$RUN/agy-prompt.md" 2>/dev/null)" '- cat' "agy-settings-read-once: the rules from the same read"

# A settings file that names no model, or no string for it, gives null.
new_case agy-settings-no-model
k=0
for m in none 5 '""'; do
    k=$((k + 1))
    RUN="$CASE/run$k"
    make_run "$RUN"
    if [ "$m" = none ]; then
        jq -cn '{permissions: {allow: ["command(cat)"]}}' > "$HOME/.gemini/antigravity-cli/settings.json"
    else
        jq -cn --argjson m "$m" '{model: $m, permissions: {allow: ["command(cat)"]}}' > "$HOME/.gemini/antigravity-cli/settings.json"
    fi
    play agy "$k" --stdout "$(t_agy_answer C)"
    ext run --cli agy --run-dir "$RUN"
    assert_eq "$rc" 0 "agy-settings-no-model $m: rc"
    assert_eq "$(st .configured_model)" null "agy-settings-no-model $m: configured_model"
done

new_case term-in-version
: > "$SCN/opencode.version.hold"
ext_bg run --cli qwen --run-dir "$RUN"
wait_for "$CALLS/version.started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "term-in-version: rc"
assert_eq "$(st .outcome)" cancelled "term-in-version: outcome"
assert_eq "$(st .phase)" preflight "term-in-version: phase"
assert_eq "$(ncalls qwen)" 0 "term-in-version: no call"
assert_eq "$(alive_yn "$(cat "$CALLS/version.pid" 2>/dev/null)")" no "term-in-version: the version command is gone"
assert_nofile "$RUN/qwen.lock" "term-in-version: no lock"

# The signal arrives during the --local-env-vars call: the call ends at its
# limit, and the signal decides.
new_case term-in-git
mk_tool "$CASE/slowgit/git" <<'EOF'
: > "$CASE/git-entered"
exec sleep 30
EOF
EXT_PATH="$CASE/slowgit:$CASE/bin:$BIN_ROOT/utils"
PRE_LIMIT=3s
answering qwen 1
ext_bg run --cli qwen --run-dir "$RUN"
wait_for "$CASE/git-entered"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "term-in-git: rc, not 18"
assert_begins "$OUT" "qwen: cancelled" "term-in-git: summary"
assert_ends "$OUT" "status: none" "term-in-git: no status named"
assert_eq "$(ncalls qwen)" 0 "term-in-git: no call"
assert_nofile "$RUN/qwen.status" "term-in-git: no status"
assert_nofile "$RUN/qwen.lock" "term-in-git: no lock"

# The same during the query that follows, once --local-env-vars has answered.
new_case term-in-git-query
mk_tool "$CASE/slowgit/git" <<'EOF'
printf '%s\n' "$*" >> "$CASE/git-calls"
if [ "$*" = 'rev-parse --local-env-vars' ]; then exec "$BIN_ROOT/utils/git" "$@"; fi
: > "$CASE/git-entered"
exec sleep 30
EOF
EXT_PATH="$CASE/slowgit:$CASE/bin:$BIN_ROOT/utils"
PRE_LIMIT=3s
answering qwen 1
ext_bg run --cli qwen --run-dir "$RUN"
wait_for "$CASE/git-entered"
kill -TERM "$BG"
ext_wait
assert_eq "$(head -n 1 "$CASE/git-calls")" 'rev-parse --local-env-vars' "term-in-git-query: --local-env-vars answered first"
assert_contains "$(tail -n 1 "$CASE/git-calls")" 'rev-parse --show-toplevel' "term-in-git-query: the signal came during the query"
assert_eq "$rc" 20 "term-in-git-query: rc, not 18"
assert_begins "$OUT" "qwen: cancelled" "term-in-git-query: summary"
assert_ends "$OUT" "status: none" "term-in-git-query: no status named"
assert_eq "$(ncalls qwen)" 0 "term-in-git-query: no call"
assert_nofile "$RUN/qwen.lock" "term-in-git-query: no lock"

new_case term-in-continue-preflight
ul_first_run
keep "$RUN/codex.status"
rm "$CALLS/sandbox.started"
: > "$SCN/codex.sandbox.hold"
ext_bg continue --cli codex --run-dir "$RUN"
wait_for "$CALLS/sandbox.started"
kill -TERM "$BG"
ext_wait
assert_eq "$rc" 20 "term-in-continue-preflight: rc"
assert_begins "$OUT" "codex: cancelled" "term-in-continue-preflight: summary"
assert_ends "$OUT" "status: none" "term-in-continue-preflight: no status named"
unchanged "$RUN/codex.status" "term-in-continue-preflight"
assert_nofile "$RUN/codex.lock" "term-in-continue-preflight: no lock"
rm "$SCN/codex.sandbox.hold"
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "term-in-continue-preflight then: the cancelled continue left the run continuable"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" DONE "term-in-continue-preflight then: the answer"

# The same once the probe has returned: the signal arrives while the continue
# reads the handle, before step 7, and still leaves the saved status alone.
# A jq stand-in holds require_handle's first query until the signal is sent.
new_case term-after-continue-probe
ul_first_run
keep "$RUN/codex.status"
rm "$CALLS/sandbox.started"
mk_tool "$CASE/slowjq/jq" <<'EOF'
for a in "$@"; do
    if [ "$a" = '.handle_source | strings' ] && [ ! -e "$CASE/jq-entered" ]; then
        : > "$CASE/jq-entered"
        n=0
        until [ -e "$CASE/jq-go" ] || [ "$n" -ge 100 ]; do
            sleep 0.1
            n=$((n + 1))
        done
    fi
done
exec "$BIN_ROOT/utils/jq" "$@"
EOF
EXT_PATH="$CASE/slowjq:$CASE/bin:$BIN_ROOT/utils"
ext_bg continue --cli codex --run-dir "$RUN"
wait_for "$CASE/jq-entered"
kill -TERM "$BG"
: > "$CASE/jq-go"
ext_wait
assert_file "$CALLS/sandbox.started" "term-after-continue-probe: the continue's probe had run"
assert_eq "$rc" 20 "term-after-continue-probe: rc"
assert_begins "$OUT" "codex: cancelled" "term-after-continue-probe: summary"
assert_ends "$OUT" "status: none" "term-after-continue-probe: no status named"
unchanged "$RUN/codex.status" "term-after-continue-probe"
assert_eq "$(ncalls codex)" 1 "term-after-continue-probe: no continue attempt"
assert_nofile "$RUN/codex.lock" "term-after-continue-probe: no lock"
unset EXT_PATH
play codex 2 --stdout DONE --stderr "$(codex_err U1)"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 0 "term-after-continue-probe then: the cancelled continue left the run continuable"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" DONE "term-after-continue-probe then: the answer"

new_case running-status
play codex 1 --hold --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
wait_st .handle U1 50
assert_eq "$(st .outcome)" running "running-status: outcome while held"
assert_eq "$(st .phase)" first "running-status: phase while held"
assert_eq "$(st .handle)" U1 "running-status: handle while held"
assert_eq "$(st '.attempts | length')" 0 "running-status: no attempt recorded while it runs"
release codex 1
ext_wait
assert_eq "$rc" 0 "running-status: rc"
assert_eq "$(st '.attempts | length')" 1 "running-status: the attempt recorded once it ended"

new_case late-handle
play codex 1 --stderr-held --hold --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
sleep 1
assert_eq "$(st .handle)" null "late-handle: no handle before the header"
release_stderr codex 1
wait_st .handle U1 50
assert_eq "$(st .outcome)" running "late-handle: the handle came while the attempt was held"
release codex 1
ext_wait
assert_eq "$rc" 0 "late-handle: rc"

# A header whose closing line of dashes is not written yet: its session id
# line may still be partly written, so the running status shows no handle;
# the final record reads the header as the ended attempt left it.
new_case handle-before-dashes
codex_err U1 | sed -n '1,/^session id: /p' > "$CASE/open-header.err"
play codex 1 --hold --stdout A --stderr-file "$CASE/open-header.err"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
sleep 1
assert_eq "$(st .handle)" null "handle-before-dashes: no handle while the header is open"
assert_eq "$(st .outcome)" running "handle-before-dashes: the attempt was still held"
release codex 1
ext_wait
assert_eq "$rc" 0 "handle-before-dashes: rc"
assert_eq "$(st .handle)" U1 "handle-before-dashes: the final record's handle"

new_case running-status-agy
play agy 1 --stdout-early "$(agy_init C)" --hold --stdout "$(agy_result C SUCCESS A)"
ext_bg run --cli agy --run-dir "$RUN"
wait_st .handle C 50
assert_eq "$(st .outcome)" running "running-status-agy: outcome while held"
assert_eq "$(st .phase)" first "running-status-agy: phase while held"
release agy 1
ext_wait
assert_eq "$rc" 0 "running-status-agy: rc"
assert_eq "$(cat "$RUN/agy.out" 2>/dev/null)" A "running-status-agy: the answer"

new_case running-status-oc
play qwen 1 --stdout-early "$(oc_start S)" --hold --stdout "$(oc_text S A; oc_finish S stop)"
ext_bg run --cli qwen --run-dir "$RUN"
wait_st .handle S 50
assert_eq "$(st .outcome)" running "running-status-oc: outcome while held"
release qwen 1
ext_wait
assert_eq "$rc" 0 "running-status-oc: rc"

# A continue that starts afresh creates the session, so its handle is shown
# while it runs too.
new_case running-status-fresh
play codex 1 --exit 1 --stderr "$(ul_door U1 '6:58 PM')"
ext run --cli codex --run-dir "$RUN"
play codex 2 --hold --stdout DONE --stderr "$(codex_err U2)"
ext_bg continue --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.2/started"
wait_st .handle U2 50
assert_eq "$(st .outcome)" running "running-status-fresh: outcome while held"
assert_eq "$(st .phase)" continue "running-status-fresh: phase while held"
assert_eq "$(st .handle_source)" continue1 "running-status-fresh: handle_source"
assert_eq "$(st '.attempts | length')" 1 "running-status-fresh: only the first attempt recorded"
release codex 2
ext_wait
assert_eq "$rc" 0 "running-status-fresh: rc"
assert_eq "$(st .handle)" U2 "running-status-fresh: handle"

new_case live-write-fails
play codex 1 --stderr-held --hold --child 30 --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
mkdir "$RUN/codex.status.tmp"
t0="$EPOCHREALTIME"
release_stderr codex 1
ext_wait
rmdir "$RUN/codex.status.tmp"
took_under "$t0" 10 "live-write-fails: the run ended while the CLI was still held"
assert_eq "$(err_last | jq -r '.attempts | length' 2>/dev/null)" 0 "live-write-fails: no attempt had ended"
assert_eq "$rc" 21 "live-write-fails: rc"
assert_begins "$OUT" "codex: runner_failure" "live-write-fails: summary"
assert_ends "$OUT" "status: none" "live-write-fails: no status named"
assert_eq "$(err_last | jq -r .outcome 2>/dev/null)" runner_failure "live-write-fails: the status object on standard error"
assert_eq "$(alive_yn "$(callf codex 1 pid)")" no "live-write-fails: the CLI was stopped"
assert_eq "$(alive_yn "$(callf codex 1 child)")" no "live-write-fails: its child too"
assert_eq "$(ncalls codex)" 1 "live-write-fails: one call"
assert_nofile "$RUN/codex.lock" "live-write-fails: no lock"

new_case final-write-fails
play codex 1 --hold --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
wait_st .handle U1 50
mkdir "$RUN/codex.status.tmp"
release codex 1
ext_wait
rmdir "$RUN/codex.status.tmp"
assert_eq "$rc" 21 "final-write-fails: rc"
assert_ends "$OUT" "status: none" "final-write-fails: no status named"
assert_eq "$(err_last | jq -c '[.outcome, .attempts[0].verdict, .answer]' 2>/dev/null)" \
    "[\"runner_failure\",\"answered\",\"$RUN/codex.out\"]" "final-write-fails: the status object on standard error"
assert_eq "$(cat "$RUN/codex.out" 2>/dev/null)" A "final-write-fails: the answer was published"
assert_nofile "$RUN/codex.lock" "final-write-fails: no lock"

new_case publish-fails
play codex 1 --hold --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
wait_st .handle U1 50
mkdir "$RUN/codex.out.tmp"
release codex 1
ext_wait
rmdir "$RUN/codex.out.tmp"
assert_eq "$rc" 21 "publish-fails: rc"
assert_eq "$(st .outcome)" runner_failure "publish-fails: outcome"
assert_eq "$(st .answer)" null "publish-fails: answer"
assert_eq "$(st '.attempts[0].verdict')" answered "publish-fails: verdict"
assert_nofile "$RUN/codex.out" "publish-fails: no answer file"
assert_eq "$(cat "$RUN/codex.first1.stdout" 2>/dev/null)" A "publish-fails: the attempt's output is kept"
assert_ends "$OUT" "status: $RUN/codex.status" "publish-fails: the status named"

new_case write-fails-exit
play codex 1 --hold --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
mkdir "$RUN/codex.first1.exit"
release codex 1
ext_wait
assert_eq "$rc" 21 "write-fails-exit: rc"
assert_eq "$(st .outcome)" runner_failure "write-fails-exit: outcome"
assert_nofile "$RUN/codex.out" "write-fails-exit: no answer file"

# An output file of a command that cannot be opened is named as a failed
# write before the command starts, not as a start that recorded no group.
new_case write-fails-stdout
: > "$SCN/codex.sandbox.hold"
answering codex 1
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/sandbox.started"
mkdir "$RUN/codex.first1.stdout"
: > "$SCN/codex.sandbox.release"
ext_wait
assert_eq "$rc" 21 "write-fails-stdout: rc"
assert_eq "$(st .message)" "cannot write $RUN/codex.first1.stdout" "write-fails-stdout: the file named"
assert_lacks "$ERR" "Is a directory" "write-fails-stdout: no unprefixed error line"
assert_eq "$(ncalls codex)" 0 "write-fails-stdout: no call"

# The same for the sandbox probe's standard error in a continue, which then
# leaves the saved status as it was.
new_case write-fails-probe-err
ul_first_run
keep "$RUN/codex.status"
rm "$RUN/codex.probe.err"
mkdir "$RUN/codex.probe.err"
ext continue --cli codex --run-dir "$RUN"
assert_eq "$rc" 21 "write-fails-probe-err: rc"
assert_ends "$OUT" "status: none" "write-fails-probe-err: no status named"
assert_contains "$ERR" "cannot write $RUN/codex.probe.err" "write-fails-probe-err: the file named"
assert_lacks "$ERR" "Is a directory" "write-fails-probe-err: no unprefixed error line"
unchanged "$RUN/codex.status" "write-fails-probe-err"
assert_eq "$(ncalls codex)" 1 "write-fails-probe-err: no continue attempt"

new_case write-fails-config
: > "$SCN/opencode.version.hold"
answering qwen 1
ext_bg run --cli qwen --run-dir "$RUN"
wait_for "$CALLS/version.started"
mkdir "$RUN/qwen.first1.config.json"
: > "$SCN/opencode.version.release"
ext_wait
assert_eq "$rc" 21 "write-fails-config: rc"
assert_eq "$(st .outcome)" runner_failure "write-fails-config: outcome"
assert_eq "$(ncalls qwen)" 0 "write-fails-config: no call"

new_case write-fails-agy-copy
mkdir "$RUN/agy-prompt.md"
answering agy 1
ext run --cli agy --run-dir "$RUN"
assert_eq "$rc" 21 "write-fails-agy-copy: rc"
assert_eq "$(st .outcome)" runner_failure "write-fails-agy-copy: outcome"
assert_eq "$(ncalls agy)" 0 "write-fails-agy-copy: no call"

# A snapshot file that cannot be written ends the run as a runner failure.
# before.txt becomes a directory once the run has passed its check of the
# run directory (step 5): when git is first asked, in step 7. (One that is
# already there is refused in step 5: snap-exists.)
new_case write-fails-snapshot
mk_tool "$CASE/mkgit/git" <<'EOF'
if [ "$*" = 'rev-parse --local-env-vars' ]; then mkdir -p "$CASE/run/before.txt"; fi
exec "$BIN_ROOT/utils/git" "$@"
EOF
EXT_PATH="$CASE/mkgit:$CASE/bin:$BIN_ROOT/utils"
answering codex 1
ext run --cli codex --run-dir "$RUN" --level edit
assert_eq "$rc" 21 "write-fails-snapshot: rc"
assert_eq "$(st .outcome)" runner_failure "write-fails-snapshot: outcome"
assert_contains "$(st .message)" "cannot write $RUN/before.txt" "write-fails-snapshot: the file named"
assert_eq "$(ncalls codex)" 0 "write-fails-snapshot: no call"

new_case unwritable-claim
if [ "$(id -u)" = 0 ]; then
    printf 'ext-run.test: unwritable-claim skipped: as root the run directory stays writable\n' >&2
else
    answering codex 1
    chmod a-w "$RUN"
    ext run --cli codex --run-dir "$RUN"
    chmod u+w "$RUN"
    assert_eq "$rc" 21 "unwritable-claim: rc"
    assert_contains "$OUT" runner_failure "unwritable-claim: outcome"
    assert_contains "$OUT" "status: none" "unwritable-claim: no status named"
    assert_eq "$(err_last | jq -r .outcome 2>/dev/null)" runner_failure "unwritable-claim: the status object on standard error"
    assert_eq "$(ncalls codex)" 0 "unwritable-claim: no call"
fi

new_case prefix-in-use
play codex 1 --hold --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
wait_for "$CALLS/codex.1/started"
ext run --cli codex --run-dir "$RUN"
assert_eq "$rc" 64 "prefix-in-use: the second's rc"
assert_contains "$ERR" "pid $BG is running" "prefix-in-use: the owner named"
assert_lacks "$ERR" "rm -r" "prefix-in-use: no removal command for a running owner"
release codex 1
ext_wait 1
assert_eq "$rc" 0 "prefix-in-use: the first's rc"
assert_eq "$(ncalls codex)" 1 "prefix-in-use: one call"

# Two runs with one prefix reach the claim before either has made it; the
# exclusive pid file lets exactly one of them through (uutils mkdir alone can
# report success to both).
for r in 1 2 3; do
    new_case "same-prefix-race-$r"
    mk_gate
    EXT_PATH="$CASE/gate:$CASE/bin:$BIN_ROOT/utils"
    play codex 1 --stdout A --stderr "$(codex_err U1)"
    ext_bg run --cli codex --run-dir "$RUN"
    ext_bg run --cli codex --run-dir "$RUN"
    ext_wait 1
    r1="$rc"
    ext_wait 2
    assert_eq "$(gate_count)" 2 "same-prefix-race-$r: both runners reached the claim"
    assert_eq "$(printf '%s\n' "$r1" "$rc" | LC_ALL=C sort | tr '\n' ' ')" "0 64 " "same-prefix-race-$r: one rc 0, one rc 64"
    assert_eq "$(ncalls codex)" 1 "same-prefix-race-$r: one call"
    assert_eq "$(no_locks)" none "same-prefix-race-$r: no lock"
done

# The same with a gate that makes the lock directory with mkdir -p, so that
# mkdir reports success to both claimants, as uutils mkdir can under a race,
# and only the exclusive pid file decides.
new_case same-prefix-race-both-made
mk_gate -p
EXT_PATH="$CASE/gate:$CASE/bin:$BIN_ROOT/utils"
play codex 1 --stdout A --stderr "$(codex_err U1)"
ext_bg run --cli codex --run-dir "$RUN"
ext_bg run --cli codex --run-dir "$RUN"
ext_wait 1
r1="$rc"
ext_wait 2
assert_eq "$(cat "$CASE/gate.rc"/* 2>/dev/null | tr '\n' ' ')" "0 0 " "same-prefix-race-both-made: mkdir succeeded for both"
assert_eq "$(printf '%s\n' "$r1" "$rc" | LC_ALL=C sort | tr '\n' ' ')" "0 64 " "same-prefix-race-both-made: one rc 0, one rc 64"
assert_eq "$(ncalls codex)" 1 "same-prefix-race-both-made: one call"
assert_eq "$(no_locks)" none "same-prefix-race-both-made: no lock"

new_case two-continues
ul_first_run
mk_gate
EXT_PATH="$CASE/gate:$CASE/bin:$BIN_ROOT/utils"
play codex 2 --stdout A --stderr "$(codex_err U1)"
ext_bg continue --cli codex --run-dir "$RUN"
ext_bg continue --cli codex --run-dir "$RUN"
ext_wait 1
r1="$rc"
ext_wait 2
assert_eq "$(gate_count)" 2 "two-continues: both reached the claim"
assert_eq "$(printf '%s\n' "$r1" "$rc" | LC_ALL=C sort | tr '\n' ' ')" "0 64 " "two-continues: one rc 0, one rc 64"
assert_eq "$(ncalls codex)" 2 "two-continues: the run's call and one continue's"
assert_eq "$(no_locks)" none "two-continues: no lock"

# Five prefixes share one run directory at once: two kinds without a config
# file, and three OpenCode prefixes with one each, two aliases and a full model id.
new_case five-at-once
clis=(codex agy deepseek qwen a/b)
five=(codex agy deepseek qwen a-b)
play codex 1 --hold --stdout codex --stderr "$(codex_err U1)"
play agy 1 --hold --stdout "$(t_agy_answer C agy)"
for a in deepseek qwen a-b; do play "$a" 1 --hold --stdout "$(t_oc_only S "$a")"; done
for c in "${clis[@]}"; do ext_bg run --cli "$c" --run-dir "$RUN"; done
for a in "${five[@]}"; do wait_for "$CALLS/$a.1/started" 300; done
for a in "${five[@]}"; do release "$a" 1; done
for i in 1 2 3 4 5; do
    ext_wait "$i"
    assert_eq "$rc" 0 "five-at-once: ${BG_PREFIX[i]} rc"
done
for a in "${five[@]}"; do
    assert_eq "$(cat "$RUN/$a.out" 2>/dev/null)" "$a" "five-at-once: $a.out holds its own answer"
    assert_file "$RUN/$a.status" "five-at-once: $a.status"
    for x in stdout stderr time exit; do assert_file "$RUN/$a.first1.$x" "five-at-once: $a.first1.$x"; done
done
for a in deepseek qwen a-b; do assert_file "$RUN/$a.first1.config.json" "five-at-once: $a.first1.config.json"; done
assert_eq "$(no_locks)" none "five-at-once: no lock is left"

# ---------------------------------------------------------------------------
# The skill text pinned to the runner: SKILL.md's outcome table, every command
# line it shows in a fenced block, and the fixed sentences of SKILL.md and
# prompts/review.md.

# the outcome table of SKILL.md is the runner's list: same names, same numbers, same order
new_case skill-outcomes; ext outcomes
doc="$(awk -F'|' '/^\| `[a-z_]+` \| [0-9]+ \|/ { n = $2; c = $3; gsub(/[ `]/, "", n); gsub(/ /, "", c); print n "\t" c }' "$SKILL/SKILL.md")"
assert_eq "$doc" "$OUT" "SKILL.md's outcome table equals ext-run outcomes"

fenced_lines() { # file: the lines of its fenced blocks, indented or not, each without its indent; a line that ends in a backslash joined with the next
    awk '/^[ \t]*```/ { f = !f; next }
  f { sub(/^[ \t]+/, ""); if (sub(/\\$/, "")) { buf = buf $0 " "; next } print buf $0; buf = "" }' "$1"
}

# fenced_lines also reads a fence that is indented, as one in a list item is
new_case fenced-lines
printf '%s\n' 'Text.' '```' 'ext-run outcomes' '```' '- An item:' '' '   ```' '   codex exec x' '   ```' > "$CASE/sample.md"
assert_eq "$(fenced_lines "$CASE/sample.md")" $'ext-run outcomes\ncodex exec x' "fenced-lines: both blocks"

# every command line SKILL.md shows is one the runner accepts, for every CLI the line is written for
mapfile -t shown < <(fenced_lines "$SKILL/SKILL.md")
nrun=0; ncont=0; i=0; raw=()   # raw is filled by the eval below
for line in "${shown[@]}"; do
  case "$line" in
    codex\ *|agy\ *|opencode\ *|timeout\ *) _fail "SKILL.md shows a bare CLI command line: $line"; continue ;;
    ext-run\ *|*/ext-run\ *) ;;
    *) continue ;;
  esac
  args="${line#*ext-run }"
  args="${args//<name>/@NAME@}"; args="${args//<run>/@RUN@}"; args="${args//<dir>/@DIR@}"
  args="${args//<dur>/30s}"; args="${args//<id>/m1}"; args="${args//<value>/low}"
  case "$args" in
    *'<'*|*'>'*|*'['*|*']'*|*'$'*|*'`'*|*';'*|*'|'*|*'&'*)
      _fail "SKILL.md shows a command line the suite cannot run: $line"; continue ;;
  esac
  eval "raw=($args)"   # quote removal only: the line holds no operator and no expansion
  cli=''
  for ((j = 0; j < ${#raw[@]}; j++)); do [ "${raw[j]}" = --cli ] && cli="${raw[j + 1]:-}"; done
  case "${raw[0]}:$cli" in
    outcomes:*) names=none ;;
    *:@NAME@) names='codex agy qwen' ;;
    *:codex|*:agy|*:qwen) names="$cli" ;;
    *) _fail "SKILL.md shows a command line whose CLI the suite cannot tell: $line"; continue ;;
  esac
  for name in $names; do
    i=$((i + 1)); new_case "skill-line-$i"; mkdir "$CASE/dir"
    words=()
    for w in "${raw[@]}"; do w="${w//@NAME@/$name}"; w="${w//@RUN@/$RUN}"; words+=("${w//@DIR@/$CASE/dir}"); done
    case "${words[0]}" in
      run) nrun=$((nrun + 1)); answering "$name" 1 ;;
      continue) ncont=$((ncont + 1))
        answering "$name" 1; ext run --cli "$name" --run-dir "$RUN"; fake_ul "$name"; answering "$name" 2 ;;
      outcomes) ;;
      *) _fail "SKILL.md shows ext-run without an action: $line"; continue ;;
    esac
    ext "${words[@]}"
    assert_eq "$rc" 0 "the runner accepts, for $name: $line"
  done
done
assert_eq "$([ "$nrun" -ge 1 ] && [ "$ncont" -ge 1 ] && echo yes || echo no)" yes "SKILL.md shows a run line and a continue line"

assert_eq "$(grep -c -F 'Do not modify any files and do not run experiments.' "$SKILL/SKILL.md")" 1 "the read-level line is stated"
assert_eq "$(grep -c -F 'Write your complete answer as your final message' "$SKILL/SKILL.md")" 1 "the closing instruction is stated"
assert_eq "$(grep -c -F 'Never tell a reviewer not to question, argue with or reverse a decision.' "$SKILL/prompts/review.md")" 1 "the ban is stated"
assert_eq "$(grep -c -F 'Decisions I would reopen' "$SKILL/prompts/review.md")" 1 "the reopen section is named"
assert_eq "$(grep -c -E 'timeout 30m|codex exec --skip-git' "$SKILL/SKILL.md")" 0 "no hand-typed command line is left"

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
