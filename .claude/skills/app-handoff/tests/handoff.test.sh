#!/usr/bin/env bash
# Tests for scripts/handoff.sh and for the command SKILL.md runs it with.
#
# Every case runs the script as a subprocess in its own tree under a
# temporary directory, with HANDOFF_DIR set to the tree's not yet existing
# app/handoffs and the clock fixed by HANDOFF_NOW, so no case writes under
# the real handoff folder. Fixture repositories commit with the configured
# identity and signing. Prints ok <name> or FAIL <name>: <what differed> per
# case and exits 1 if any case failed.

set -uo pipefail

# Nothing the caller set reaches the cases: a GIT_DIR exported by yadm enter
# or a hook would send the fixture commits into that repository, a hook's
# author and committer identity and dates would override the fixture's own,
# a knob of the script left set would change what a case sees, and a CDPATH
# would let cd land somewhere else.
mapfile -t git_local_vars < <(git rev-parse --local-env-vars)
unset -v "${git_local_vars[@]}" \
    GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
    GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE \
    HANDOFF_DIR HANDOFF_NOW CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/handoff.sh"
NOW=2026-11-13-0130
MARKER='<!-- FILL -->'

ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
ROOT="$(cd -P -- "$ROOT" && pwd -P)"
# Git never climbs into the temporary root looking for a repository, so a
# TMPDIR inside a work tree (any folder under the dotfiles' $HOME) cannot
# make the plain folders of the cases part of it.
export GIT_CEILING_DIRECTORIES="$ROOT"

# --- Helpers ---

# Ends the running case with <message> as what differed.
fail() { # message
    printf '%s\n' "$1"
    exit 1
}

# Fails unless <actual> equals <expected>.
expect_eq() { # label actual expected
    [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"
}

# Fails unless <file> exists and holds <line> as a whole line.
expect_line() { # file line
    [ -f "$1" ] || fail "no file at [$1]"
    grep -qxF -e "$2" -- "$1" || fail "no line [$2] in $1"
}

# Runs handoff.sh with tree <t>'s handoff folder and the fixed clock.
handoff() { # t args...
    local t="$1"
    shift
    HANDOFF_DIR="$t/app/handoffs" HANDOFF_NOW="$NOW" bash "$SCRIPT" "$@"
}

# Runs handoff.sh new in <dir> for tree <t>, printing what it prints.
new_in() { # dir t args...
    local dir="$1" t="$2"
    shift 2
    (cd "$dir" && handoff "$t" new "$@")
}

# Runs handoff.sh check <file> for tree <t>: its exit status goes to
# <t>/rc, its stdout to <t>/out and its stderr to <t>/err.
check_into() { # t file
    local rc
    handoff "$1" check "$2" >"$1/out" 2>"$1/err" && rc=0 || rc=$?
    printf '%s\n' "$rc" >"$1/rc"
}

# Fails unless handoff.sh <args> exits 2 with a usage line on stderr.
expect_usage_error() { # t args...
    local t="$1" rc
    shift
    handoff "$t" "$@" >"$t/out" 2>"$t/err" && rc=0 || rc=$?
    expect_eq "exit status of [$*]" "$rc" 2
    grep -q -e '^usage: ' -- "$t/err" || fail "no usage line on stderr for [$*]"
}

# A repository at <dir> on main with one commit, Initial, holding a.txt.
repo_with_commit() { # dir
    git init -q -b main "$1"
    printf 'one\n' >"$1/a.txt"
    git -C "$1" add -- a.txt
    git -C "$1" commit -q -m Initial
}

# Case 1's checkout at <dir>: a.txt modified, b.txt untracked.
case1_repo() { # dir
    repo_with_commit "$1"
    printf 'two\n' >>"$1/a.txt"
    printf 'new\n' >"$1/b.txt"
}

# Inserts <lines> after every line of <file> that equals <after>.
insert_after() { # file after lines...
    local file="$1" after="$2"
    shift 2
    awk -v after="$after" -v text="$(printf '%s\n' "$@")" \
        '{ print } $0 == after { print text }' "$file" >"$file.new"
    mv -- "$file.new" "$file"
}

# Runs the step 2 command of SKILL.md in <dir> for tree <t>, printing what
# it prints. <topic> is written in as the skill says, each ' as '\'', the
# session id is abc, and HOME is a folder whose .claude/skills/app-handoff
# is the skill under test, so the line runs as written.
skill_new_in() { # dir t topic
    local dir="$1" t="$2" cmd topic
    cmd="$(sed -n 's/^ *\(bash ~\/\.claude\/skills\/app-handoff\/scripts\/handoff\.sh new .*\)$/\1/p' \
        -- "$HERE/../SKILL.md")"
    [[ -n $cmd && $cmd != *$'\n'* ]] ||
        fail "expected one handoff.sh new command in SKILL.md, got [$cmd]"
    [[ $cmd == *'<topic>'* ]] || fail "no <topic> in the SKILL.md command [$cmd]"
    topic="${3//\'/\'\\\'\'}"
    cmd="${cmd//'<topic>'/"$topic"}"
    mkdir -p -- "$t/home/.claude/skills"
    ln -sfn -- "$HERE/.." "$t/home/.claude/skills/app-handoff"
    (cd "$dir" && HOME="$t/home" HANDOFF_DIR="$t/app/handoffs" HANDOFF_NOW="$NOW" \
        CLAUDE_SESSION_ID=abc bash -c "$cmd")
}

# The whole of case 1's handoff: the skeleton the script must write.
case1_expected() { # repo short-hash
    cat <<EOF
# Handoff: Queue Worker

- Written: 2026-11-13 01:30 $(date +%z)
- Directory: $1
- Repository: $1
- Branch: main
- Commit: $2 Initial
- Uncommitted: 2 file(s)
  - a.txt
  - b.txt
- Source: unknown

> This is a snapshot. Before acting on it, compare the directory, branch,
> commit and uncommitted files recorded above with the live checkout, and
> tell the owner about any difference first.

## Goal

<!-- FILL -->

## State

<!-- FILL -->

## Decisions

<!-- FILL -->

## Ruled out

<!-- FILL -->

## Facts established

<!-- FILL -->

## Owner's instructions from this session

<!-- FILL -->

## Open questions

<!-- FILL -->

## Next steps

<!-- FILL -->

## In flight

<!-- FILL -->

## Pointers

<!-- FILL -->
EOF
}

# --- Cases ---

case_new_in_repo() { # tree
    local T="$1" R out f short line
    R="$T/proj"
    case1_repo "$R"
    out="$(new_in "$R" "$T" Queue Worker)" || fail "new exited $?"
    f="$T/app/handoffs/$NOW-proj-queue-worker.md"
    expect_eq "stdout" "$out" "$f"
    short="$(git -C "$R" rev-parse --short HEAD)"
    for line in "# Handoff: Queue Worker" "- Directory: $R" "- Repository: $R" \
        "- Branch: main" "- Commit: $short Initial" "- Uncommitted: 2 file(s)" \
        "  - a.txt" "  - b.txt" "- Source: unknown"; do
        expect_line "$f" "$line"
    done
    expect_eq "marker lines" "$(grep -cxF -e "$MARKER" -- "$f")" 10
    expect_eq "file mode" "$(stat -c %a -- "$f")" 600
    expect_eq "handoffs folder mode" "$(stat -c %a -- "$T/app/handoffs")" 700
    expect_eq "app folder mode" "$(stat -c %a -- "$T/app")" 700
    expect_eq "whole file" "$(cat -- "$f")" "$(case1_expected "$R" "$short")"
}

case_new_outside_repo() { # tree
    local T="$1" D out line
    D="$T/my dir"
    mkdir -- "$D"
    out="$(new_in "$D" "$T")" || fail "new exited $?"
    expect_eq "stdout" "$out" "$T/app/handoffs/$NOW-my-dir-handoff.md"
    for line in "# Handoff: untitled" "- Directory: $D" \
        "- Repository: not a git repository" "- Branch: n/a" "- Commit: n/a" \
        "- Uncommitted: n/a"; do
        expect_line "$out" "$line"
    done
}

case_new_same_minute_clash() { # tree
    local T="$1" R first second third sum
    R="$T/proj"
    case1_repo "$R"
    first="$(new_in "$R" "$T" Queue Worker)" || fail "first new exited $?"
    expect_eq "first path" "$first" "$T/app/handoffs/$NOW-proj-queue-worker.md"
    # The first session has started filling its file, so an overwrite with a
    # fresh skeleton would change the checksum.
    printf 'filled by the first session\n' >>"$first"
    sum="$(sha256sum -- "$first")"
    second="$(new_in "$R" "$T" Queue Worker)" || fail "second new exited $?"
    expect_eq "second path" "$second" "$T/app/handoffs/$NOW-proj-queue-worker-2.md"
    expect_eq "first file's checksum" "$(sha256sum -- "$first")" "$sum"
    third="$(new_in "$R" "$T" Queue Worker)" || fail "third new exited $?"
    expect_eq "third path" "$third" "$T/app/handoffs/$NOW-proj-queue-worker-3.md"
}

case_new_topic_sanitized() { # tree
    local T="$1" D P out word
    # The folder's slug runs to 32 characters; the cut at 30 ends on a
    # hyphen, which is trimmed.
    D="$T/Shop API Staging Copy Old 202 v2"
    P=shop-api-staging-copy-old-202
    mkdir -- "$D"
    out="$(new_in "$D" "$T" 'Fix: API/v2 !!')" || fail "new exited $?"
    expect_eq "punctuation topic" "$out" "$T/app/handoffs/$NOW-$P-fix-api-v2.md"
    out="$(new_in "$D" "$T" ქართული ტექსტი)" || fail "new exited $?"
    expect_eq "Georgian topic" "$out" "$T/app/handoffs/$NOW-$P-handoff.md"
    expect_line "$out" "# Handoff: ქართული ტექსტი"
    word="$(printf 'abcdefghij%.0s' 1 2 3 4 5 6)"
    out="$(new_in "$D" "$T" "$word")" || fail "new exited $?"
    expect_eq "60-letter topic" "$out" "$T/app/handoffs/$NOW-$P-${word:0:40}.md"
}

case_new_in_linked_worktree() { # tree
    local T="$1" R W out
    R="$T/proj"
    repo_with_commit "$R"
    git -C "$R" worktree add -q -b feature-x .worktrees/feature-x
    W="$R/.worktrees/feature-x"
    out="$(new_in "$W" "$T" x)" || fail "new exited $?"
    expect_eq "stdout" "$out" "$T/app/handoffs/$NOW-proj-x.md"
    expect_line "$out" "- Branch: feature-x"
    expect_line "$out" "- Repository: $W"
    expect_line "$out" "- Directory: $W"
}

case_new_no_commits_and_detached() { # tree
    local T="$1" out
    git init -q -b main "$T/fresh"
    out="$(new_in "$T/fresh" "$T" x)" || fail "new exited $?"
    expect_line "$out" "- Commit: no commits yet"
    expect_line "$out" "- Branch: main"
    expect_line "$out" "- Uncommitted: 0 file(s)"
    repo_with_commit "$T/proj"
    git -C "$T/proj" checkout -q --detach
    out="$(new_in "$T/proj" "$T" x)" || fail "new exited $?"
    expect_line "$out" "- Branch: detached"
    expect_line "$out" "- Commit: $(git -C "$T/proj" rev-parse --short HEAD) Initial"
}

case_new_many_uncommitted() { # tree
    local T="$1" R out expected
    R="$T/proj"
    git init -q -b main "$R"
    touch -- "$R"/f{01..60}
    out="$(new_in "$R" "$T" x)" || fail "new exited $?"
    expect_line "$out" "- Uncommitted: 60 file(s)"
    expect_eq "path lines" "$(grep -c -e '^  - f[0-9][0-9]$' -- "$out")" 50
    expected="$(
        printf -- '- Uncommitted: 60 file(s)\n'
        printf -- '  - f%s\n' {01..50}
        printf -- '  - and 10 more\n- Source: unknown\n'
    )"
    expect_eq "uncommitted block" \
        "$(sed -n '/^- Uncommitted: /,/^- Source: /p' -- "$out")" "$expected"
}

case_new_source() { # tree
    local T="$1" out
    mkdir -- "$T/shop"
    out="$(new_in "$T/shop" "$T" --source "Claude Code session abc" x)" ||
        fail "new exited $?"
    expect_eq "stdout" "$out" "$T/app/handoffs/$NOW-shop-x.md"
    expect_line "$out" "- Source: Claude Code session abc"
    expect_line "$out" "# Handoff: x"
}

case_check_fresh_skeleton_fails() { # tree
    local T="$1" f
    case1_repo "$T/proj"
    f="$(new_in "$T/proj" "$T" Queue Worker)" || fail "new exited $?"
    check_into "$T" "$f"
    expect_eq "exit status" "$(cat -- "$T/rc")" 1
    expect_eq "stderr" "$(cat -- "$T/err")" "10 unfilled section(s)"
    expect_eq "stdout" "$(cat -- "$T/out")" ""
}

case_check_filled_passes() { # tree
    local T="$1" f
    case1_repo "$T/proj"
    f="$(new_in "$T/proj" "$T" Queue Worker)" || fail "new exited $?"
    sed -i "s/$MARKER/None./" -- "$f"
    expect_eq "markers left" "$(grep -c -F -e "$MARKER" -- "$f")" 0
    check_into "$T" "$f"
    expect_eq "exit status" "$(cat -- "$T/rc")" 0
    expect_eq "stdout" "$(cat -- "$T/out")" ok
    expect_eq "stderr" "$(cat -- "$T/err")" ""
}

case_check_missing_parts() { # tree
    local T="$1" f
    case1_repo "$T/proj"
    f="$(new_in "$T/proj" "$T" Queue Worker)" || fail "new exited $?"
    sed -i "s/$MARKER/None./" -- "$f"
    cp -- "$f" "$T/no-section.md"
    sed -i '/^## Ruled out$/d' -- "$T/no-section.md"
    check_into "$T" "$T/no-section.md"
    expect_eq "exit status without Ruled out" "$(cat -- "$T/rc")" 1
    expect_eq "stderr without Ruled out" "$(cat -- "$T/err")" "missing section: Ruled out"
    cp -- "$f" "$T/no-notice.md"
    sed -i '/^> This is a snapshot\./d' -- "$T/no-notice.md"
    check_into "$T" "$T/no-notice.md"
    expect_eq "exit status without the notice" "$(cat -- "$T/rc")" 1
    expect_eq "stderr without the notice" "$(cat -- "$T/err")" "missing snapshot notice"
    # A stray bare heading is not a missing part and must not crash check.
    cp -- "$f" "$T/bare-heading.md"
    printf '## \n' >>"$T/bare-heading.md"
    check_into "$T" "$T/bare-heading.md"
    expect_eq "exit status with a bare heading" "$(cat -- "$T/rc")" 0
    expect_eq "stderr with a bare heading" "$(cat -- "$T/err")" ""
}

case_usage_errors() { # tree
    local T="$1"
    expect_usage_error "$T"
    expect_usage_error "$T" bogus
    expect_usage_error "$T" check
    expect_usage_error "$T" check "$T/nonexistent.md"
    expect_usage_error "$T" new --source
    [ ! -e "$T/app" ] || fail "a usage error created $T/app"
}

case_new_in_ignored_folder() { # tree
    local T="$1" R out line
    # A deny-by-default repository, as dotfiles kept in $HOME are: notes/ is
    # ignored, tools/ is kept while everything in it is ignored.
    R="$T/proj"
    repo_with_commit "$R"
    printf '%s\n' '*' '!/.gitignore' '!/tools/' '/tools/*' >"$R/.gitignore"
    git -C "$R" add -- .gitignore
    git -C "$R" commit -q -m Ignore
    mkdir -- "$R/notes" "$R/tools"
    out="$(new_in "$R/notes" "$T")" || fail "new exited $?"
    expect_eq "stdout in notes" "$out" "$T/app/handoffs/$NOW-notes-handoff.md"
    for line in "# Handoff: untitled" "- Directory: $R/notes" \
        "- Repository: not a git repository" "- Branch: n/a" "- Commit: n/a" \
        "- Uncommitted: n/a"; do
        expect_line "$out" "$line"
    done
    # The top of a work tree is never ignored, though "*" matches everything;
    # with nothing tracked yet, git itself reports "." there as ignored.
    out="$(new_in "$R" "$T" top)" || fail "new exited $?"
    expect_eq "stdout at the top" "$out" "$T/app/handoffs/$NOW-proj-top.md"
    expect_line "$out" "- Repository: $R"
    git init -q -b main "$T/fresh"
    printf '*\n' >"$T/fresh/.gitignore"
    out="$(new_in "$T/fresh" "$T" top)" || fail "new exited $?"
    expect_eq "stdout at an untracked top" "$out" "$T/app/handoffs/$NOW-fresh-top.md"
    expect_line "$out" "- Repository: $T/fresh"
    # tools/ is kept, though "/tools/*" matches "tools/" with its slash.
    out="$(new_in "$R/tools" "$T" tools)" || fail "new exited $?"
    expect_eq "stdout in tools" "$out" "$T/app/handoffs/$NOW-proj-tools.md"
    expect_line "$out" "- Repository: $R"
}

case_check_empty_section() { # tree
    local T="$1" f
    case1_repo "$T/proj"
    f="$(new_in "$T/proj" "$T" Queue Worker)" || fail "new exited $?"
    sed -i "s/$MARKER/None./" -- "$f"
    # Markers deleted instead of filled: Decisions keeps a line of spaces
    # only, and Pointers, the last section, nothing up to the end of the file.
    cp -- "$f" "$T/empty.md"
    sed -i -e '/^## Decisions$/,/^## /s/^None\.$/   /' \
        -e '/^## Pointers$/,${/^None\.$/d}' -- "$T/empty.md"
    check_into "$T" "$T/empty.md"
    expect_eq "exit status with empty sections" "$(cat -- "$T/rc")" 1
    expect_eq "stderr with empty sections" "$(cat -- "$T/err")" \
        "$(printf '%s\n' 'empty section: Decisions' 'empty section: Pointers')"
    expect_eq "stdout with empty sections" "$(cat -- "$T/out")" ""
    # A level 3 heading belongs to its section, as when State goes by file.
    cp -- "$f" "$T/subheading.md"
    sed -i '/^## State$/,/^## /s/^None\.$/### a.txt\n\nHalf done./' -- "$T/subheading.md"
    check_into "$T" "$T/subheading.md"
    expect_eq "exit status with a level 3 heading" "$(cat -- "$T/rc")" 0
    expect_eq "stderr with a level 3 heading" "$(cat -- "$T/err")" ""
}

case_check_fenced_heading() { # tree
    local T="$1" f lines
    local -a fenced=()
    case1_repo "$T/proj"
    f="$(new_in "$T/proj" "$T" Queue Worker)" || fail "new exited $?"
    sed -i "s/$MARKER/None./" -- "$f"
    sed -i '/^## Ruled out$/d' -- "$f"
    # Ruled out is left only as a heading quoted in a code fence under
    # Decisions. A fence closes only on a run of its own character at least
    # as long, alone on its line; the headings after it count again.
    # shellcheck disable=SC2016 # the backticks are fence lines, not commands
    for lines in '```markdown|## Ruled out|```' '~~~|## Ruled out|~~~' \
        '````markdown|```text|## Ruled out|```|````' \
        '~~~|```|## Ruled out|```|~~~' '```|```python|## Ruled out|```'; do
        IFS='|' read -ra fenced <<<"$lines"
        cp -- "$f" "$T/fenced.md"
        insert_after "$T/fenced.md" '## Decisions' '' "${fenced[@]}"
        check_into "$T" "$T/fenced.md"
        expect_eq "exit status with [$lines]" "$(cat -- "$T/rc")" 1
        expect_eq "stderr with [$lines]" "$(cat -- "$T/err")" "missing section: Ruled out"
    done
}

case_check_unreadable_file() { # tree
    local T="$1" f
    case1_repo "$T/proj"
    f="$(new_in "$T/proj" "$T" Queue Worker)" || fail "new exited $?"
    sed -i "s/$MARKER/None./" -- "$f"
    chmod 000 -- "$f"
    [ ! -r "$f" ] || fail "cannot make a file unreadable here (running as root?)"
    expect_usage_error "$T" check "$f"
}

case_new_in_refused_repository() { # tree
    local T="$1" R rc
    # A repository format newer than git reads: git refuses the repository
    # with a message other than "not a git repository".
    R="$T/proj"
    repo_with_commit "$R"
    git -C "$R" config core.repositoryformatversion 99
    (cd "$R" && handoff "$T" new x) >"$T/out" 2>"$T/err" && rc=0 || rc=$?
    expect_eq "exit status in a refused repository" "$rc" 1
    expect_eq "stdout in a refused repository" "$(cat -- "$T/out")" ""
    grep -qF -e 'Expected git repo version' -- "$T/err" ||
        fail "no git message on stderr in a refused repository: [$(cat -- "$T/err")]"
    [ ! -e "$T/app" ] || fail "a refused repository created $T/app"
    # Outside any repository git's own answer stays off stderr.
    mkdir -- "$T/plain"
    (cd "$T/plain" && handoff "$T" new x) >"$T/out" 2>"$T/err" && rc=0 || rc=$?
    expect_eq "exit status outside a repository" "$rc" 0
    expect_eq "stderr outside a repository" "$(cat -- "$T/err")" ""
    expect_line "$(cat -- "$T/out")" "- Repository: not a git repository"
}

case_skill_command_topic_quoted() { # tree
    local T="$1" D out topic
    D="$T/shop"
    mkdir -- "$D"
    out="$(skill_new_in "$D" "$T" "owner's export")" || fail "the command exited $?"
    expect_eq "stdout with an apostrophe" "$out" "$T/app/handoffs/$NOW-shop-owner-s-export.md"
    expect_line "$out" "# Handoff: owner's export"
    expect_line "$out" "- Source: Claude Code session abc"
    # shellcheck disable=SC2016 # the topic must reach the shell unexpanded
    topic='$(touch pwned) `touch pwned2` $HOME & "x"'
    out="$(skill_new_in "$D" "$T" "$topic")" || fail "the command exited $?"
    expect_line "$out" "# Handoff: $topic"
    if [ -e "$D/pwned" ] || [ -e "$D/pwned2" ]; then fail "the topic ran a command"; fi
    # No topic gives what new gives with no topic argument.
    out="$(skill_new_in "$D" "$T" '')" || fail "the command exited $?"
    expect_eq "stdout with no topic" "$out" "$T/app/handoffs/$NOW-shop-handoff.md"
    expect_line "$out" "# Handoff: untitled"
}

# --- Runner ---

failures=0

# Runs case_<name> in a subshell with errexit on, inside a fresh tree it
# gets as its argument, so a fixture step that fails ends the case. The
# case's output is the reason shown when it fails.
run() { # name
    local name="$1" log rc msg
    log="$ROOT/$name.log"
    (
        set -e
        tree="$(mktemp -d "$ROOT/$name.XXXXXX")"
        cd "$tree"
        "case_$name" "$tree"
    ) >"$log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'ok %s\n' "$name"
    else
        failures=$((failures + 1))
        msg="$(cat -- "$log")"
        printf 'FAIL %s: %s\n' "$name" "${msg:-exited $rc with no message}"
    fi
}

for name in new_in_repo new_outside_repo new_same_minute_clash \
    new_topic_sanitized new_in_linked_worktree new_no_commits_and_detached \
    new_many_uncommitted new_source check_fresh_skeleton_fails \
    check_filled_passes check_missing_parts usage_errors \
    new_in_ignored_folder check_empty_section check_fenced_heading \
    check_unreadable_file new_in_refused_repository \
    skill_command_topic_quoted; do
    run "$name"
done

[ "$failures" -eq 0 ] || exit 1
