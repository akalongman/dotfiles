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
    local n="${1:-$BGN}" pid i=0
    pid="${BG_PID[n]:-}"
    if [ -z "$pid" ]; then
        _fail "ext_wait: no job $n"
        rc=255
        return 1
    fi
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        _fail "ext_wait: job $n did not end within 60 s"
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rc=255
    else
        wait "$pid"
        rc=$?
    fi
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
