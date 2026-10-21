#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/assert.sh"
HELPER="$HOME/.claude/statusline-work.sh"
# shellcheck source=SCRIPTDIR/../../statusline-work.sh
source "$HELPER"

# Dispatch: sourcing defines the functions and runs nothing; executing the
# file runs the entry point.
assert_eq "$(bash -c "source '$HELPER'" 2>&1)" "" "sourcing prints nothing"
assert_ok "sourcing defines work_scan_range" bash -c "source '$HELPER'; declare -F work_scan_range >/dev/null"
assert_ok "executing the helper exits 0" bash "$HELPER"

# One assistant transcript line holding a single tool_use block.
mk_record() { # name field value cwd [field2 value2]
    jq -nc --arg n "$1" --arg f "$2" --arg v "$3" --arg c "$4" --arg f2 "${5:-}" --arg v2 "${6:-}" \
        '{type: "assistant", cwd: $c, message: {content: [{type: "tool_use", name: $n,
          input: ({($f): $v} + (if $f2 == "" then {} else {($f2): $v2} end))}]}}'
}

mk_transcript() { # file
    {
        mk_record Read file_path /r/docs/superpowers/plans/2026-01-01-alpha.md /r
        mk_record Bash command 'openspec instructions apply --change add-groups --json; cat openspec/changes/add-groups/tasks.md' /r
        mk_record Write file_path /r/docs/x.md /r content 'see docs/plans/quoted.md'
        mk_record Bash command 'cd /other && cat docs/plans/elsewhere.md' /r
        mk_record Bash command 'cat "docs/plans/my plan.md"' /r
        mk_record Agent prompt 'Read .superpowers/sdd/add-groups/progress.md first' /r
        mk_record Bash command 'ls openspec/changes/archive/old-one/' /r
        printf 'not json\n'
        jq -nc '{type: "user", cwd: "/r", message: {role: "user",
          content: [{type: "tool_result", tool_use_id: "t1", content: "see docs/plans/result.md"}]}}'
        printf '%s' '{"type":"assistant","cwd":"/r","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/r/docs/plans/partial.md"'
    } > "$1"
}

scan_file() { # file
    work_scan_range "$1" 0 "$(stat -c %s "$1")"
}

# Task 1: evidence extraction
t="$(mktemp -p "$TMPROOT")"; mk_transcript "$t"
size=$(stat -c %s "$t")
out="$(work_scan_range "$t" 0 "$size")"
assert_contains "$out" $'1\t/r/docs/superpowers/plans/2026-01-01-alpha.md\t/r' "Read file_path is evidence"
assert_contains "$out" $'0\topenspec/changes/add-groups/\t/r' "change dir from a Bash command, cut after the name"
assert_contains "$out" $'0\t.superpowers/sdd/add-groups/\t/r' "workspace from an Agent prompt"
assert_contains "$out" $'0\topenspec/changes/archive/\t/r' "archive mention is extracted (rejected later)"
assert_eq "$(printf '%s\n' "$out" | /bin/grep -c 'quoted.md')" "0" "Write content is not evidence"
assert_eq "$(printf '%s\n' "$out" | /bin/grep -c 'elsewhere.md')" "0" "relative path after cd is skipped"
assert_eq "$(printf '%s\n' "$out" | /bin/grep -c 'my')" "0" "quoted path with a space yields nothing"
assert_eq "$(printf '%s\n' "$out" | /bin/grep -c 'partial.md')" "0" "partial last line is not parsed"
assert_eq "$(printf '%s\n' "$out" | wc -l)" "4" "four occurrences in total"
assert_ok "bad JSON line does not fail the scan" work_scan_range "$t" 0 "$size"
assert_eq "$(printf '%s\n' "$out" | /bin/grep -c 'result.md')" "0" "a tool result is not evidence"
assert_eq "$out" $'0\t1\t/r/docs/superpowers/plans/2026-01-01-alpha.md\t/r\n1\t0\topenspec/changes/add-groups/\t/r\n5\t0\t.superpowers/sdd/add-groups/\t/r\n6\t0\topenspec/changes/archive/\t/r' "positions count every line of the range, oldest first"

# Byte ranges: FROM inclusive, TO exclusive, positions relative to FROM.
off2=$(head -n 2 "$t" | wc -c)
off5=$(head -n 5 "$t" | wc -c)
assert_eq "$(work_scan_range "$t" "$off5" "$size")" $'0\t0\t.superpowers/sdd/add-groups/\t/r\n1\t0\topenspec/changes/archive/\t/r' "positions start at the range's first line"
assert_eq "$(work_scan_range "$t" 0 $((off2 - 1)))" $'0\t1\t/r/docs/superpowers/plans/2026-01-01-alpha.md\t/r' "a line cut before its newline is not parsed, even when it is whole JSON"
assert_eq "$(work_scan_range "$t" "$off2" "$off2")" "" "an empty range prints nothing"
assert_ok "an empty range exits 0" work_scan_range "$t" "$off2" "$off2"
evaluated="$TMPROOT/evaluated"
assert_eq "$(work_scan_range "$t" "BASH_VERSINFO[\$(touch $evaluated)]" "$size")" "" "a non-numeric offset scans nothing"
assert_nofile "$evaluated" "a non-numeric offset is never evaluated"

# The abs flag.
a="$(mktemp -p "$TMPROOT")"
{
    mk_record Read file_path \~/.claude/docs/plans/home.md /r
    mk_record Bash command 'cat docs/plans/rel.md' /r
} > "$a"
assert_eq "$(scan_file "$a")" $'0\t1\t~/.claude/docs/plans/home.md\t/r\n1\t0\tdocs/plans/rel.md\t/r' "a home-relative path is absolute, a bare relative path is not"

# A path field is one token from its first character.
s="$(mktemp -p "$TMPROOT")"
mk_record Read file_path '/r/my dir/docs/plans/spaced.md' /r > "$s"
assert_eq "$(scan_file "$s")" "" "a file_path with a space before the pattern yields nothing"

# Several blocks of one record share its position; a missing cwd is empty;
# a text block is not evidence.
m="$(mktemp -p "$TMPROOT")"
jq -nc '{type: "assistant", message: {content: [
    {type: "text", text: "docs/plans/text.md"},
    {type: "tool_use", name: "Read", input: {file_path: "/r/docs/plans/one.md"}},
    {type: "tool_use", name: "Grep", input: {path: "/r/openspec/changes/two/"}}]}}' > "$m"
assert_eq "$(scan_file "$m")" $'0\t1\t/r/docs/plans/one.md\t\n0\t1\t/r/openspec/changes/two/\t' "blocks of one record share its position"

# Line breaks and tabs inside a value separate tokens and never reach the
# output; a cwd holding a control character is dropped.
n="$(mktemp -p "$TMPROOT")"
mk_record Bash command $'cat docs/plans/a.md\ncat\tdocs/plans/b.md' $'/r\nx' > "$n"
assert_eq "$(scan_file "$n")" $'0\t0\tdocs/plans/a.md\t\n0\t0\tdocs/plans/b.md\t' "multi-line command yields one line per token"
z="$(mktemp -p "$TMPROOT")"
jq -nc '{type: "assistant", cwd: "/r", message: {content: [
    {type: "tool_use", name: "Bash", input: {command: "cat docs/plans/a\u0000b.md"}}]}}' > "$z"
assert_eq "$(scan_file "$z")" "" "a value holding a NUL yields nothing, not a joined path"

# A cd command still yields its absolute paths; a description is not evidence.
c="$(mktemp -p "$TMPROOT")"
mk_record Bash command 'cd /other && cat /r/docs/plans/abs.md' /r description 'docs/plans/desc.md' > "$c"
assert_eq "$(scan_file "$c")" $'0\t1\t/r/docs/plans/abs.md\t/r' "absolute path after cd is kept"

# Heredoc bodies of a Bash command are not evidence; the operator's line and
# the lines after the closing line are.
scan_record() { # name field value: scans a one-record transcript, cwd /r
    local f; f="$(mktemp -p "$TMPROOT")"
    mk_record "$1" "$2" "$3" /r > "$f"
    scan_file "$f"
}
assert_eq "$(scan_record Bash command $'cat > /r/notes.md <<\'EOF\'\nsee docs/plans/body-quoted.md\nEOF')" "" "a quoted heredoc body is not evidence"
assert_eq "$(scan_record Bash command $'cat <<-"END"\n\tdocs/plans/body-dash.md\n\tEND\ncat docs/plans/after-dash.md')" $'0\t0\tdocs/plans/after-dash.md\t/r' "a <<- body ends at its tab-indented closing line"
assert_eq "$(scan_record Bash command $'cat docs/plans/opline.md - <<EOF\nbody docs/plans/body-bare.md\nEOF\ncat docs/plans/after-bare.md')" $'0\t0\tdocs/plans/opline.md\t/r\n0\t0\tdocs/plans/after-bare.md\t/r' "the operator line and the lines after the closing line are evidence"
assert_eq "$(scan_record Bash command $'cat << \\EOF\ndocs/plans/body-escaped.md\nEOF\ncat docs/plans/after-escaped.md')" $'0\t0\tdocs/plans/after-escaped.md\t/r' "an escaped delimiter after a blank is a heredoc"
assert_eq "$(scan_record Bash command $'cat <<A <<B\na docs/plans/body-a.md\nA\nb docs/plans/body-b.md\nB\ncat docs/plans/after-two.md')" $'0\t0\tdocs/plans/after-two.md\t/r' "two heredocs on one line are read in order"
assert_eq "$(scan_record Bash command $'cat <<EOF\ndocs/plans/never-closed.md')" "" "an unclosed heredoc runs to the end"
assert_eq "$(scan_record Bash command $'grep -c x <<<"docs/plans/herestring.md"\ncat docs/plans/after-herestring.md')" $'0\t0\tdocs/plans/herestring.md\t/r\n0\t0\tdocs/plans/after-herestring.md\t/r' "a here-string is evidence and opens no body"
assert_eq "$(scan_record Agent prompt $'cat <<EOF\ndocs/plans/agent-body.md\nEOF')" $'0\t0\tdocs/plans/agent-body.md\t/r' "only a Bash command loses its heredoc bodies"

# Long values stay linear. Each case takes seconds under a quadratic step:
# gsub or jq's join in the whitespace normalization, jq's join in the heredoc
# strip, or an uncapped heredoc operator queue.
long_record() { # file holding a command: one Bash record with it, cwd /r
    jq -nc --rawfile v "$1" '{type: "assistant", cwd: "/r", message: {content: [
        {type: "tool_use", name: "Bash", input: {command: $v}}]}}'
}
timed_scan() { # file: sets SCAN_OUT and SCAN_US (microseconds)
    local start end
    start=${EPOCHREALTIME//[!0-9]/}
    SCAN_OUT="$(scan_file "$1")"
    end=${EPOCHREALTIME//[!0-9]/}
    SCAN_US=$((end - start))
}
v="$(mktemp -p "$TMPROOT")"; r="$(mktemp -p "$TMPROOT")"
{ printf 'cat docs/plans/long.md\n'; seq 40000 | sed 's/^/echo filler line /'; } > "$v"
long_record "$v" > "$r"; timed_scan "$r"
assert_eq "$SCAN_OUT" $'0\t0\tdocs/plans/long.md\t/r' "a 40000-line command is scanned"
assert_ok "a 40000-line command scans in under 1 s" test "$SCAN_US" -lt 1000000
{ printf 'cat <<EOF\nbody docs/plans/body-long.md\nEOF\n'; seq 40000 | sed 's/^/echo filler line /'; printf 'cat docs/plans/after-long.md\n'; } > "$v"
long_record "$v" > "$r"; timed_scan "$r"
assert_eq "$SCAN_OUT" $'0\t0\tdocs/plans/after-long.md\t/r' "40000 lines after a heredoc are kept"
assert_ok "40000 lines after a heredoc scan in under 1 s" test "$SCAN_US" -lt 1000000
{ for _ in $(seq 32000); do printf '1<<3 '; done; printf '\n'; seq 32000 | sed 's/.*/3/'; printf 'cat docs/plans/after-ops.md\n'; } > "$v"
long_record "$v" > "$r"; timed_scan "$r"
assert_eq "$SCAN_OUT" "" "a line with more than 16 << opens a body that runs to the end"
assert_ok "32000 heredoc operators on one line scan in under 1 s" test "$SCAN_US" -lt 1000000

# The pattern covers the five forms and nothing else.
forms='openspec/changes/a/ docs/superpowers/plans/b.md docs/plans/c.md .claude/docs/plans/d.md .superpowers/sdd/e/ docs/plans/f.txt openspec/changes/g'
assert_eq "$(printf '%s\n' "$forms" | /bin/grep -oE "$WORK_PATTERN" | tr '\n' ' ')" 'openspec/changes/a/ docs/superpowers/plans/b.md docs/plans/c.md .claude/docs/plans/d.md .superpowers/sdd/e/ ' "WORK_PATTERN matches the five forms only"

# Task 2: resolution and classification
# Fixture root, reused by later tasks: a change and an archived one, two
# plans, a plan whose name breaks the character set, workspaces in each
# header grammar, an empty workspace, and a symlink onto docs/plans.
R="$(mktemp -d -p "$TMPROOT")"
mkdir -p "$R/openspec/changes/add-groups" "$R/openspec/changes/archive/old-one" \
    "$R/docs/superpowers/plans" "$R/docs/plans" "$R/.superpowers/sdd/tasks"
: > "$R/openspec/changes/add-groups/tasks.md"
: > "$R/openspec/changes/archive/old-one/tasks.md"
: > "$R/docs/superpowers/plans/2026-01-01-alpha.md"
: > "$R/docs/plans/beta.md"
: > "$R/docs/plans/bad\$name.md"
: > "$R/docs/plans/with space.md"
ln -s docs/plans "$R/link"
mk_ws() { # name file line: writes the line as .superpowers/sdd/<name>/<file> under R
    mkdir -p "$R/.superpowers/sdd/$1"
    printf '%s\n' "$3" > "$R/.superpowers/sdd/$1/$2"
}
emdash=$'\xe2\x80\x94' # U+2014, the separator of the older header grammar
mk_ws add-groups progress.md '# SDD ledger: plan openspec/changes/add-groups/tasks.md'
mk_ws 2026-01-01-alpha plan-path 'docs/superpowers/plans/2026-01-01-alpha.md'
mk_ws legacy progress.md "# SDD ledger $emdash plan: docs/plans/beta.md"
mk_ws changeform progress.md '# SDD ledger: change add-groups (openspec/changes/add-groups/tasks.md)'
mk_ws gone progress.md '# SDD ledger: plan docs/plans/missing.md'
mk_ws archived progress.md '# SDD ledger: plan openspec/changes/archive/old-one/tasks.md'

assert_eq "$(work_resolve "openspec/changes/add-groups/" 0 "$R")" $'change\tadd-groups\t'"$R"$'/openspec/changes/add-groups/tasks.md\t' "relative change resolves against cwd"
assert_eq "$(work_resolve "$R/openspec/changes/add-groups/tasks.md" 1 "")" $'change\tadd-groups\t'"$R"$'/openspec/changes/add-groups/tasks.md\t' "tasks.md inside a change is the change, not a plan"
assert_fail "archive is rejected" work_resolve "openspec/changes/archive/old-one/" 0 "$R"
assert_eq "$(work_resolve "docs/plans/beta.md" 0 "$R")" $'plan\tbeta\t'"$R"$'/docs/plans/beta.md\t' "plan by basename"
assert_eq "$(work_resolve "$R/link/beta.md" 1 "")" "$(work_resolve "docs/plans/beta.md" 0 "$R")" "symlinked and real path are one subject"
assert_eq "$(work_resolve ".superpowers/sdd/add-groups/" 0 "$R")" $'change\tadd-groups\t'"$R"$'/openspec/changes/add-groups/tasks.md\t'"$R/.superpowers/sdd/add-groups" "workspace via current ledger header"
assert_eq "$(work_resolve ".superpowers/sdd/2026-01-01-alpha/" 0 "$R" | cut -f1,2)" $'plan\t2026-01-01-alpha' "workspace via plan-path marker"
assert_eq "$(work_resolve ".superpowers/sdd/legacy/" 0 "$R" | cut -f1,2)" $'plan\tbeta' "older header grammar"
assert_eq "$(work_resolve ".superpowers/sdd/changeform/" 0 "$R" | cut -f1,2)" $'change\tadd-groups' "change header grammar"
assert_fail "workspace with neither marker nor header is skipped" work_resolve ".superpowers/sdd/tasks/" 0 "$R"
assert_fail "workspace whose source is missing is not a subject" work_resolve ".superpowers/sdd/gone/" 0 "$R"
assert_fail "missing plan file is not a subject" work_resolve "docs/plans/nope.md" 0 "$R"
assert_eq "$(work_resolve "$R/link/beta.md" 1 "" | cut -f3)" "$R/docs/plans/beta.md" "a symlinked path opens the real file"
work_resolve ".superpowers/sdd/archived/" 0 "$R"; assert_eq "$?" 1 "a workspace naming an archived change is skipped"
assert_file "$R/docs/plans/bad\$name.md" "the plan with a disallowed character exists"
assert_fail "a plan name outside the allowed set is dropped" work_resolve "docs/plans/bad\$name.md" 0 "$R"

# Exit status: 1 is invalid evidence, so the caller tries an older
# occurrence; 2 is a valid subject whose file is missing, which retires the
# subject when a render has shown that occurrence and is otherwise skipped
# like 1.
work_resolve "docs/plans/nope.md" 0 "$R"; assert_eq "$?" 2 "a missing plan file exits 2"
work_resolve ".superpowers/sdd/gone/" 0 "$R"; assert_eq "$?" 2 "a workspace whose source is missing exits 2"
work_resolve "openspec/changes/archive/old-one/" 0 "$R"; assert_eq "$?" 1 "an archived change exits 1"
work_resolve ".superpowers/sdd/tasks/" 0 "$R"; assert_eq "$?" 1 "a workspace with neither marker nor header exits 1"
work_resolve "docs/plans/bad\$name.md" 0 "$R"; assert_eq "$?" 1 "a disallowed character exits 1"
work_resolve "openspec/changes/retired/" 0 "$R"; assert_eq "$?" 2 "a change whose directory is gone exits 2"
work_resolve "$R/docs/plans/" 1 ""; assert_eq "$?" 1 "a path that classifies as nothing exits 1"

# The base directory: CWD for a relative raw, HOME for ~/.
work_resolve "docs/plans/beta.md" 0 ""; assert_eq "$?" 1 "a relative raw with no cwd exits 1"
in_root() { (cd / && "$@"); }
in_root work_resolve "docs/plans/beta.md" 0 "${R#/}"; assert_eq "$?" 1 "a relative cwd exits 1 even where it would resolve"
assert_eq "$(HOME="$R" work_resolve \~/docs/plans/beta.md 1 "")" $'plan\tbeta\t'"$R"$'/docs/plans/beta.md\t' "a home-relative raw resolves against HOME"
work_resolve "$R/docs/plans/beta.md" 0 /; assert_eq "$?" 1 "an absolute raw flagged relative exits 1"

# Punctuation-prefixed raws fail the character check even when the prefixed
# path exists.
P="$(mktemp -d -p "$TMPROOT")"
for pre in '(' '--x=' "\$HOME/" '[a]('; do
    mkdir -p "$P/${pre}docs/plans"; : > "$P/${pre}docs/plans/p.md"
    work_resolve "${pre}docs/plans/p.md" 0 "$P"; assert_eq "$?" 1 "a raw prefixed with $pre exits 1"
done
# Both the path as named and the path as resolved are checked, and the
# workspace directory too; the plain forms of each case resolve.
mkdir -p "$P/docs/plans" "$P/odd(ws)" "$P/.superpowers/sdd/plain"
: > "$P/docs/plans/p.md"; : > "$P/odd(1).md"
ln -s "$P/odd(1).md" "$P/docs/plans/link.md"
printf '# SDD ledger: plan docs/plans/p.md\n' | tee "$P/.superpowers/sdd/plain/progress.md" > "$P/odd(ws)/progress.md"
ln -s "$P/odd(ws)" "$P/.superpowers/sdd/wslink"
assert_eq "$(work_resolve "docs/plans/p.md" 0 "$P" | cut -f1,2)" $'plan\tp' "the plain plan resolves"
assert_eq "$(work_resolve ".superpowers/sdd/plain/" 0 "$P" | cut -f1,2)" $'plan\tp' "the plain workspace resolves"
work_resolve "x(/../docs/plans/p.md" 0 "$P"; assert_eq "$?" 1 "a named segment that .. removes still drops the raw"
mkdir -p "$P/.superpowers/sdd/absolute" "$P/x("
printf '# SDD ledger: plan %s/docs/plans/p.md\n' "$P" > "$P/.superpowers/sdd/absolute/progress.md"
assert_eq "$(work_resolve ".superpowers/sdd/absolute/" 0 "$P" | cut -f1,2)" $'plan\tp' "a workspace naming an absolute source resolves"
work_resolve "x(/../.superpowers/sdd/absolute/" 0 "$P"; assert_eq "$?" 1 "a named segment that .. removes still drops a workspace"
work_resolve "docs/plans/link.md" 0 "$P"; assert_eq "$?" 1 "a symlink onto a disallowed name exits 1"
work_resolve ".superpowers/sdd/wslink/" 0 "$P"; assert_eq "$?" 1 "a workspace that resolves to a disallowed name exits 1"
ln -s loop.md "$P/docs/plans/loop.md"
work_resolve "docs/plans/loop.md" 0 "$P"; assert_eq "$?" 2 "a plan that cannot be resolved exits 2"

# The archive rule holds for the path as named and as resolved. The
# archive's own tasks.md exists here, so a missing archive rule would yield
# a change named archive instead of failing the existence check.
A="$(mktemp -d -p "$TMPROOT")"
mkdir -p "$A/openspec/changes/archive/x" "$A/named/openspec/changes"
: > "$A/openspec/changes/archive/tasks.md"
: > "$A/openspec/changes/archive/x/tasks.md"
ln -s "$A/openspec/changes/archive/x" "$A/openspec/changes/y"
ln -s "$R/openspec/changes/add-groups" "$A/named/openspec/changes/archive"
work_resolve "$A/openspec/changes/archive/x/" 1 ""; assert_eq "$?" 1 "an archived change is skipped"
work_resolve "$A/openspec/changes/y/" 1 ""; assert_eq "$?" 1 "a change that resolves into the archive is skipped"
work_resolve "$A/named/openspec/changes/archive/" 1 ""; assert_eq "$?" 1 "a raw naming the archive is skipped where it resolves elsewhere"
# The resolved change directory and the resolved file are checked apart.
: > "$A/outside-notes.md"
mkdir -p "$A/openspec/changes/archive/w" "$A/openspec/changes/v"
ln -s "$A/outside-notes.md" "$A/openspec/changes/archive/w/tasks.md"
ln -s "$A/openspec/changes/archive/w" "$A/openspec/changes/z"
ln -s "$A/openspec/changes/archive/x/tasks.md" "$A/openspec/changes/v/tasks.md"
work_resolve "$A/openspec/changes/z/" 1 ""; assert_eq "$?" 1 "a change directory in the archive is skipped wherever its tasks.md points"
work_resolve "$A/openspec/changes/v/" 1 ""; assert_eq "$?" 1 "a tasks.md that resolves into the archive is skipped"
assert_eq "$(work_resolve "$R/openspec/changes/archive/../add-groups/" 1 "" | cut -f1,2)" $'change\tadd-groups' "a .. is normalised away before classifying"

# Classification reads the path as named; the file to open is resolved.
M="$(mktemp -d -p "$TMPROOT")"
mkdir -p "$M/openspec/changes/foo" "$M/elsewhere" "$M/outside/bar-dir" "$M/docs/plans" "$M/.superpowers/sdd/foo"
: > "$M/elsewhere/notes.md"; : > "$M/outside/bar-dir/tasks.md"
ln -s "$M/elsewhere/notes.md" "$M/openspec/changes/foo/tasks.md"
ln -s "$M/outside/bar-dir" "$M/openspec/changes/bar"
ln -s "$M/elsewhere/notes.md" "$M/docs/plans/alias.md"
printf '# SDD ledger: plan openspec/changes/foo/tasks.md\n' > "$M/.superpowers/sdd/foo/progress.md"
assert_eq "$(work_resolve ".superpowers/sdd/foo/" 0 "$M" | cut -f1-3)" $'change\tfoo\t'"$M/elsewhere/notes.md" "a symlinked tasks.md stays its change"
assert_eq "$(work_resolve "openspec/changes/foo/" 0 "$M" | cut -f1-3)" "$(work_resolve ".superpowers/sdd/foo/" 0 "$M" | cut -f1-3)" "a change and the workspace naming its tasks.md are one subject"
assert_eq "$(work_resolve "openspec/changes/bar/" 0 "$M")" $'change\tbar\t'"$M"$'/outside/bar-dir/tasks.md\t' "a symlinked change directory stays its change"
assert_eq "$(work_resolve "docs/plans/alias.md" 0 "$M" | cut -f1-3)" $'plan\talias\t'"$M/elsewhere/notes.md" "a plan is named by the path as named"
norm=""
_work_normalise norm "/a/./b//c/../d/"; assert_eq "$norm" "/a/b/d" "lexical normalisation"
_work_normalise norm "/../a/.."; assert_eq "$norm" "/" "lexical normalisation stops at the root"

# Header forms found in real ledgers; only the first line is read.
i=0
for header in '# SDD ledger, plan: docs/plans/beta.md' '# SDD ledger. plan: docs/plans/beta.md' \
        '# SDD ledger - plan: docs/plans/beta.md' '# SDD ledger: plan: docs/plans/beta.md'; do
    i=$((i + 1)); mk_ws "variant-$i" progress.md "$header"
    assert_eq "$(work_resolve ".superpowers/sdd/variant-$i/" 0 "$R" | cut -f1,2)" $'plan\tbeta' "header form: $header"
done
mk_ws variant-change progress.md '# SDD ledger, change: add-groups (openspec/changes/add-groups/tasks.md)'
assert_eq "$(work_resolve ".superpowers/sdd/variant-change/" 0 "$R" | cut -f1,2)" $'change\tadd-groups' "change header with a colon"
mk_ws other-first progress.md "# Progress ledger $emdash Ansible folder reorganization"
printf '# SDD ledger: plan docs/plans/beta.md\n' >> "$R/.superpowers/sdd/other-first/progress.md"
work_resolve ".superpowers/sdd/other-first/" 0 "$R"; assert_eq "$?" 1 "a header on the second line is not read"
mk_ws both plan-path 'docs/superpowers/plans/2026-01-01-alpha.md'
printf '# SDD ledger: plan docs/plans/beta.md\n' > "$R/.superpowers/sdd/both/progress.md"
assert_eq "$(work_resolve ".superpowers/sdd/both/" 0 "$R" | cut -f2)" "2026-01-01-alpha" "the marker wins over the header"
mk_ws blank-marker plan-path ''
printf '# SDD ledger: plan docs/plans/beta.md\n' > "$R/.superpowers/sdd/blank-marker/progress.md"
assert_eq "$(work_resolve ".superpowers/sdd/blank-marker/" 0 "$R" | cut -f2)" "beta" "an empty marker falls back to the header"
mk_ws spaced progress.md '# SDD ledger: plan docs/plans/with space.md'
assert_eq "$(work_resolve ".superpowers/sdd/spaced/" 0 "$R" | cut -f1,2)" $'plan\twith space' "a source path with a space survives"
mk_ws home progress.md '# SDD ledger: plan ~/docs/plans/beta.md'
assert_eq "$(HOME="$R" work_resolve ".superpowers/sdd/home/" 0 "$R" | cut -f1,2)" $'plan\tbeta' "a home-relative source resolves against HOME"

# The workspace source and the classification on their own.
assert_eq "$(work_ws_source "$R/.superpowers/sdd/2026-01-01-alpha")" "$R/docs/superpowers/plans/2026-01-01-alpha.md" "a relative source joins the workspace root"
assert_fail "a directory outside .superpowers/sdd is no workspace" work_ws_source "$R/docs/plans"
assert_eq "$(work_classify /r/openspec/changes/foo/design.md)" $'change\tfoo\t/r/openspec/changes/foo/tasks.md' "any file in a change is the change"
assert_eq "$(work_classify /r/openspec/changes/foo)" $'change\tfoo\t/r/openspec/changes/foo/tasks.md' "a change directory without its slash"
assert_eq "$(work_classify /r/docs/plans/x.md)" $'plan\tx\t/r/docs/plans/x.md' "a .md file is a plan"
assert_fail "a file in an archived change is not a plan" work_classify /r/openspec/changes/archive/old/notes.md
assert_fail "a file that is not .md is no subject" work_classify /r/docs/plans/x.txt
assert_fail "a bare .md has no name" work_classify /r/x/.md
assert_fail "a relative path is not classified" work_classify docs/plans/x.md

# Task 3: stage
# A ledger is the progress.md of a fresh workspace directory, so the
# workspace is the ledger's dirname.
mk_ledger() { # line...: writes the lines to a new workspace's progress.md, prints its path
    local d; d="$(mktemp -d -p "$TMPROOT")"
    printf '%s\n' "$@" > "$d/progress.md"
    printf '%s' "$d/progress.md"
}
L1="$(mk_ledger '# SDD ledger: plan openspec/changes/add-account-permission-scopes/tasks.md' \
    'Run base: fc09252' 'Section 1: handed to controller' 'Section 1: complete (commit abc1234)' \
    'Final phase: controller returned needs-ruling (tail pending while the detached test:parallel runs)' \
    'Section 5: complete (ruling R3/R9; gates at 4d2b84f)' \
    'Final phase: complete db66634 (review and gates at 4d2b84f)')"
L2="$(mk_ledger 'Unit A: complete' 'Section 8h: paused' 'Section 6.1: handed to controller')"
L3="$(mk_ledger '# SDD ledger: plan docs/plans/beta.md')"
L4="$(mk_ledger 'Section 1: complete')"; printf 'Section 2: comp' >> "$L4"
fence='```'
T1="$(mktemp -p "$TMPROOT")"; T2="$(mktemp -p "$TMPROOT")"
printf '%s\n' '- [x] 1.1 a' '  - [X] 1.2 b' '- [ ] 2.1 c' "${fence}bash" '- [ ] not counted' "$fence" '- [ ] 3.1 d' > "$T1"
printf '%s\n' '## 1. Tasks' 'Nothing to tick.' > "$T2"
# A plan carries task boxes too; without a workspace they give no stage.
PL="$(mktemp -p "$TMPROOT")"; cp "$T1" "$PL"

assert_eq "$(work_stage change /x "$(dirname "$L1")")" "final phase complete db66634" "last marker wins, annotation cut"
assert_eq "$(work_stage plan /x "$(dirname "$L2")")" "Section 6.1 handed to controller" "dotted id"
assert_eq "$(work_stage plan /x "$(dirname "$L3")")" "" "no marker lines, no stage"
assert_eq "$(bash -c "source '$HELPER'; work_stage plan /x '$(dirname "$L3")'" 2>&1)" "" "no marker lines, no stage, outside set -u too"
assert_eq "$(work_stage plan /x "$(dirname "$L4")")" "Section 1 complete" "partial last line ignored"
assert_eq "$(work_stage change "$T1" "")" "2/4" "ticks over total, fenced block skipped"
assert_eq "$(work_stage change "$T2" "")" "" "no boxes, no stage"
assert_eq "$(work_stage plan "$PL" "")" "" "plan without workspace has no stage"

L5="$(mk_ledger 'Section 4: complete' \
    'Final phase: controller returned needs-ruling (tail pending while the detached test:parallel runs)')"
assert_eq "$(work_stage plan /x "$(dirname "$L5")")" "final phase controller returned needs-ruling" "a needs-ruling final phase, annotation cut"

# The 40-character cap applies to the status after the cut, and counts
# characters whatever the caller's locale.
L6="$(mk_ledger 'Task 2: 0123456789012345678901234567890123456789XYZ')"
assert_eq "$(work_stage plan /x "$(dirname "$L6")")" "Task 2 0123456789012345678901234567890123456789" "status capped at 40 characters"
L7="$(mk_ledger 'Task 2: 012345678901234567890123456789012345678 (a long annotation)')"
assert_eq "$(work_stage plan /x "$(dirname "$L7")")" "Task 2 012345678901234567890123456789012345678" "the cap applies after the cut"
printf -v z39 '%039d' 0
L8="$(mk_ledger "Task 3: $z39${emdash}tail")"
assert_eq "$(LC_ALL=C work_stage plan /x "$(dirname "$L8")")" "Task 3 $z39$emdash" "the cap counts characters, not bytes, under LC_ALL=C"

# A carriage return ending a line is part of the line ending; any other
# control character in the status gives no stage, and no earlier marker
# stands in for it.
q="$(mktemp -d -p "$TMPROOT")"; printf 'Section 1: complete\r\n' > "$q/progress.md"
assert_eq "$(work_stage plan /x "$q")" "Section 1 complete" "a carriage return ending the line is dropped"
L9="$(mk_ledger 'Section 1: complete' $'Section 2: comp\e[31mlete')"
assert_eq "$(work_stage plan /x "$(dirname "$L9")")" "" "a status holding an escape gives no stage"
L10="$(mk_ledger $'Section 3: a\tb')"
assert_eq "$(work_stage plan /x "$(dirname "$L10")")" "" "a status holding a tab gives no stage"
L11="$(mk_ledger $'Section 3: complete (x\ty)')"
assert_eq "$(work_stage plan /x "$(dirname "$L11")")" "Section 3 complete" "a control character after the cut is not part of the status"

# The ledger is read whole and scanned from the end, past lines that cannot
# be markers; a ledger holding a NUL is read line by line instead, which
# drops the NUL, so a NUL after the cut leaves the last marker standing.
L12="$(mk_ledger 'Section 1: complete' 'Unit A: complete')"
assert_eq "$(work_stage plan /x "$(dirname "$L12")")" "Unit A complete" "a Unit marker is found from the end"
q2="$(mktemp -d -p "$TMPROOT")"; printf 'Section 1: complete\nSection 2: paused (x\0y)\n' > "$q2/progress.md"
assert_eq "$(work_stage plan /x "$q2")" "Section 2 paused" "a NUL in the last marker's annotation is dropped, not a cut line"
printf 'Section 1: complete (x\0y)\nSection 2: comp' > "$q2/progress.md"
assert_eq "$(work_stage plan /x "$q2")" "Section 1 complete" "a ledger read line by line still ignores its partial last line"

# A workspace's stage comes from its ledger alone; a task list's last line
# counts without its newline.
assert_eq "$(work_stage change "$T1" "$(dirname "$L3")")" "" "a change with a workspace does not fall back to its task list"
T3="$(mktemp -p "$TMPROOT")"; printf -- '- [x] 1.1 a\n- [ ] 1.2 b' > "$T3"
assert_eq "$(work_stage change "$T3" "")" "1/2" "a task list's unterminated last line counts"

# No stage is silent and exits 0; only regular files are read, so a FIFO
# cannot block the status line.
assert_eq "$(work_stage plan /x "$TMPROOT/no-such-ws" 2>&1)" "" "a missing ledger prints nothing"
assert_ok "a missing ledger exits 0" work_stage plan /x "$TMPROOT/no-such-ws"
assert_eq "$(work_stage change "$TMPROOT/no-such-tasks.md" "" 2>&1)" "" "a missing task list prints nothing"
assert_ok "a missing task list exits 0" work_stage change "$TMPROOT/no-such-tasks.md" ""
assert_ok "a plan without a workspace exits 0" work_stage plan "$PL" ""
f="$(mktemp -d -p "$TMPROOT")"; mkfifo "$f/progress.md" "$f/tasks.md"
timeout 5 bash -c "source '$HELPER'; work_stage plan /x '$f'" >/dev/null 2>&1
assert_eq "$?" 0 "a FIFO ledger is not opened"
timeout 5 bash -c "source '$HELPER'; work_stage change '$f/tasks.md' ''" >/dev/null 2>&1
assert_eq "$?" 0 "a FIFO task list is not opened"

# Task 4: cache, lock, chunked scan and the entry point
# The cache directory is exported, so a helper run as a command (under
# timeout) shares it with the runs made in this shell.
WORK_CACHE_DIR="$(mktemp -d -p "$TMPROOT")"; export WORK_CACHE_DIR
t="$(mktemp -p "$TMPROOT")"
{
    mk_record Read file_path "$R/docs/superpowers/plans/2026-01-01-alpha.md" "$R"
    mk_record Bash command 'cat openspec/changes/add-groups/tasks.md' "$R"
    mk_record Write file_path "$R/docs/x.md" "$R" content 'see docs/plans/quoted.md'
    mk_record Bash command 'cd /other && cat docs/plans/elsewhere.md' "$R"
    mk_record Agent prompt 'Read .superpowers/sdd/add-groups/progress.md first' "$R"
    mk_record Bash command 'ls openspec/changes/archive/old-one/' "$R"
    printf 'not json\n'
} > "$t"

# full scan, subject, cache written
out="$(work_main s1 "$t" "$R")"
assert_eq "$out" $'change\tadd-groups\t'"$R"$'/openspec/changes/add-groups/tasks.md\t' "newest valid occurrence is the subject"
assert_file "$WORK_CACHE_DIR/work-s1.tsv" "cache written"
assert_eq "$(head -1 "$WORK_CACHE_DIR/work-s1.tsv" | cut -f1,4)" "$WORK_CACHE_VERSION"$'\t'"$(stat -c %s "$t")" "offset at end of transcript"
# incremental: append a Read of a plan, only new bytes scanned, subject changes
mk_record Read file_path "$R/docs/plans/beta.md" "$R" >> "$t"
assert_eq "$(work_main s1 "$t" "$R" | cut -f1,2)" $'plan\tbeta' "appended evidence replaces the subject"
# retirement: remove the plan, segment blank, older subject not resurrected
rm "$R/docs/plans/beta.md"
assert_eq "$(work_main s1 "$t" "$R")" "" "vanished subject blanks the segment"
# late resolution: a workspace mentioned before its ledger exists
mk_record Agent prompt "read .superpowers/sdd/late/progress.md" "$R" >> "$t"
assert_eq "$(work_main s1 "$t" "$R")" "" "unresolved workspace shows nothing"
mkdir -p "$R/.superpowers/sdd/late"; printf '# SDD ledger: plan docs/superpowers/plans/2026-01-01-alpha.md\nTask 1: complete\n' > "$R/.superpowers/sdd/late/progress.md"
assert_eq "$(work_main s1 "$t" "$R" | cut -f2,4)" $'2026-01-01-alpha\tTask 1 complete' "resolved on a later run without a rescan"
# invalidation
sed -i "1s/^$WORK_CACHE_VERSION\t/9\t/" "$WORK_CACHE_DIR/work-s1.tsv"
assert_eq "$(work_main s1 "$t" "$R" | cut -f2)" "2026-01-01-alpha" "stale version restarts from zero and still resolves"
printf '%s\t%s\t1\t999999999\n' "$WORK_CACHE_VERSION" "$t" > "$WORK_CACHE_DIR/work-s1.tsv"
assert_eq "$(work_main s1 "$t" "$R" | cut -f2)" "2026-01-01-alpha" "offset beyond size restarts from zero"
# missing transcript, odd ids
assert_eq "$(work_main s2 "$TMPROOT/does not exist.jsonl" "$R")" "" "missing transcript prints nothing"
assert_ok "missing transcript exits 0" work_main s2 "$TMPROOT/does not exist.jsonl" "$R"
sp="$(mktemp -d -p "$TMPROOT" 'dir with space.XXXX')"; cp "$t" "$sp/t.jsonl"
assert_eq "$(work_main 'id with space' "$sp/t.jsonl" "$R" | cut -f2)" "2026-01-01-alpha" "paths with spaces work"
# lock contention: second run renders from cache and does not scan
( exec 9>"$WORK_CACHE_DIR/work-s1.lock"; flock 9; sleep 2 ) & lp=$!; sleep 0.2
mk_record Read file_path "$R/docs/superpowers/plans/2026-01-01-alpha.md" "$R" >> "$t"
before="$(head -1 "$WORK_CACHE_DIR/work-s1.tsv")"
work_main s1 "$t" "$R" >/dev/null
assert_eq "$(head -1 "$WORK_CACHE_DIR/work-s1.tsv")" "$before" "held lock leaves the cache untouched"
# The cached subject came through the late workspace and carries its stage;
# the appended Read, had it been scanned, would give the plan without one.
assert_eq "$(work_main s1 "$t" "$R" | cut -f2,4)" $'2026-01-01-alpha\tTask 1 complete' "held lock renders from the cache"
# While the cached offset is below the size the last commit recorded, a
# catch-up is in flight, and a run that finds the lock held prints nothing.
printf '%s\t%s\t%s\t0\n0\t1\t%s\t\t0\n' "$WORK_CACHE_VERSION" "$t" "$(stat -c %s "$t")" "$R/docs/superpowers/plans/2026-01-01-alpha.md" > "$WORK_CACHE_DIR/work-s1.tsv"
assert_eq "$(work_main s1 "$t" "$R")" "" "held lock during a catch-up prints nothing"
wait "$lp"
# A call in this shell leaves no descriptor holding the lock.
work_main s1 "$t" "$R" >/dev/null
assert_ok "the lock is released when work_main returns" flock -n "$WORK_CACHE_DIR/work-s1.lock" true

# The cache header records the size seen at the run's start and the offset
# of the last newline; a partial last line is read once it is complete.
pl="$(mktemp -p "$TMPROOT")"
mk_record Read file_path "$R/docs/superpowers/plans/2026-01-01-alpha.md" "$R" > "$pl"
whole="$(stat -c %s "$pl")"
rec="$(mk_record Read file_path "$R/openspec/changes/add-groups/tasks.md" "$R")"
printf '%s' "${rec:0:40}" >> "$pl"
assert_eq "$(work_main s6 "$pl" "$R" | cut -f2)" "2026-01-01-alpha" "a partial last line leaves the subject of the whole lines"
assert_eq "$(head -1 "$WORK_CACHE_DIR/work-s6.tsv" | cut -f3,4)" "$(stat -c %s "$pl")"$'\t'"$whole" "the offset stops after the last newline"
printf '%s\n' "${rec:40}" >> "$pl"
assert_eq "$(work_main s6 "$pl" "$R" | cut -f2)" "add-groups" "the completed line is read on the next run"

# A transcript shorter than the size the cache recorded was replaced, and a
# cache line that does not parse discards the cache: both restart from zero
# rather than rendering the cached add-groups occurrence.
sh="$(mktemp -p "$TMPROOT")"
mk_record Read file_path "$R/docs/superpowers/plans/2026-01-01-alpha.md" "$R" > "$sh"
n="$(stat -c %s "$sh")"
printf '%s\t%s\t%s\t%s\n0\t1\t%s\t\t0\n' "$WORK_CACHE_VERSION" "$sh" "$((n + 100))" "$n" "$R/openspec/changes/add-groups/" > "$WORK_CACHE_DIR/work-s7.tsv"
assert_eq "$(work_main s7 "$sh" "$R" | cut -f2)" "2026-01-01-alpha" "a shrunk transcript restarts from zero"
printf '%s\t%s\t%s\t%s\n0\t1\t%s\t\t0\nnot a row\n' "$WORK_CACHE_VERSION" "$sh" "$n" "$n" "$R/openspec/changes/add-groups/" > "$WORK_CACHE_DIR/work-s7.tsv"
assert_eq "$(work_main s7 "$sh" "$R" | cut -f2)" "2026-01-01-alpha" "a cache line that does not parse restarts from zero"

# An id that is empty or holds a slash, or an empty transcript path, prints
# nothing and writes no file: the id becomes part of a file name.
odd="$(mktemp -d -p "$TMPROOT")"
assert_eq "$(WORK_CACHE_DIR="$odd" work_main '' "$t" "$R")" "" "an empty session id prints nothing"
assert_eq "$(WORK_CACHE_DIR="$odd" work_main '../x' "$t" "$R")" "" "a session id holding a slash prints nothing"
assert_eq "$(WORK_CACHE_DIR="$odd" work_main s8 '' "$R")" "" "an empty transcript path prints nothing"
assert_eq "$(ls -A "$odd")" "" "an unusable id or path writes no file"
assert_ok "an empty session id exits 0" work_main '' "$t" "$R"
assert_ok "no arguments exit 0" work_main

# Catch-up and cancellation: 64 KiB chunks over about 300 KiB of records,
# each run killed after 50 ms. The offset only grows and no run prints
# before the scan has caught up. The loop is capped, so a scan that never
# converges fails instead of hanging.
: > "$R/docs/plans/beta.md"
filler="$(jq -nc --arg c "$R" --arg x "$(printf '%01000d' 0)" '{type: "user", cwd: $c, message: {role: "user", content: $x}}')"
cu="$(mktemp -p "$TMPROOT")"
{
    for _ in $(seq 140); do printf '%s\n' "$filler"; done
    mk_record Read file_path "$R/docs/plans/beta.md" "$R"
    for _ in $(seq 140); do printf '%s\n' "$filler"; done
} > "$cu"
beta=$'plan\tbeta\t'"$R"$'/docs/plans/beta.md\t'
runs=0 prev=0 early="" backwards="" out=""
while [ "$runs" -lt 200 ]; do
    runs=$((runs + 1))
    out="$(WORK_CHUNK=65536 timeout -s KILL 0.05 bash "$HELPER" s3 "$cu" "$R")"; rc=$?
    cur="$(head -1 "$WORK_CACHE_DIR/work-s3.tsv" 2>/dev/null | cut -f4)"; cur="${cur:-0}"
    [ "$cur" -ge "$prev" ] || backwards+="$prev>$cur "
    prev="$cur"
    if [ "$rc" = 0 ] && [ -n "$out" ]; then break; fi
    early+="$out"
done
assert_eq "$out" "$beta" "a scan killed every 50 ms still reaches the subject"
assert_eq "$backwards" "" "the committed offset never moves backwards"
assert_eq "$early" "" "no run prints before the scan has caught up"

# With the work budget spent, a run stops after one chunk and prints
# nothing, though that chunk already holds the subject; the next run
# continues from the committed offset.
cb="$(mktemp -p "$TMPROOT")"
{
    mk_record Read file_path "$R/docs/plans/beta.md" "$R"
    for _ in $(seq 280); do printf '%s\n' "$filler"; done
} > "$cb"
out="$(WORK_CHUNK=65536 WORK_BUDGET_MS=0 work_main s9 "$cb" "$R")"
first="$(head -1 "$WORK_CACHE_DIR/work-s9.tsv" | cut -f4)"
assert_eq "$out" "" "a run stopped by the budget prints nothing"
assert_ok "a run stopped by the budget commits its first chunk" test "${first:-0}" -ge 65536
assert_ok "a run stopped by the budget commits one chunk only" test "${first:-0}" -lt 131072
runs=1
while [ -z "$out" ] && [ "$runs" -lt 20 ]; do
    runs=$((runs + 1))
    out="$(WORK_CHUNK=65536 WORK_BUDGET_MS=0 work_main s9 "$cb" "$R")"
done
assert_eq "$out" "$beta" "each run continues from the committed offset"
assert_eq "$(head -1 "$WORK_CACHE_DIR/work-s9.tsv" | cut -f4)" "$(stat -c %s "$cb")" "the last run ends at the transcript's end"

# The cache keeps the newest ten occurrences with distinct raw matches:
# repeats of one archive mention take one slot, so the older plan stays
# reachable behind it; ten newer distinct workspaces then push it out.
dd="$(mktemp -p "$TMPROOT")"
{
    mk_record Read file_path "$R/docs/superpowers/plans/2026-01-01-alpha.md" "$R"
    for _ in $(seq 11); do mk_record Bash command 'ls openspec/changes/archive/old-one/' "$R"; done
} > "$dd"
assert_eq "$(work_main s10 "$dd" "$R" | cut -f2)" "2026-01-01-alpha" "repeated raw matches take one slot"
assert_eq "$(tail -n +2 "$WORK_CACHE_DIR/work-s10.tsv" | cut -f3 | tr '\n' ' ')" "openspec/changes/archive/ $R/docs/superpowers/plans/2026-01-01-alpha.md " "occurrences are kept newest first"
for i in $(seq 10); do mk_record Agent prompt "see .superpowers/sdd/none-$i/" "$R"; done >> "$dd"
assert_eq "$(work_main s10 "$dd" "$R")" "" "ten newer invalid occurrences push the plan out"
assert_eq "$(tail -n +2 "$WORK_CACHE_DIR/work-s10.tsv" | cut -f3 | tr '\n' ' ')" "$(for i in $(seq 10 -1 1); do printf '.superpowers/sdd/none-%s/ ' "$i"; done)" "at most ten occurrences are kept"

# A record longer than a chunk grows the chunk to its newline: the scan
# neither stalls nor splits it, so the record's own evidence is kept.
big="$(mktemp -p "$TMPROOT")"
{
    mk_record Bash command "echo $(printf '%0102400d' 0); cat docs/plans/inside-big.md" "$R"
    mk_record Read file_path "$R/docs/superpowers/plans/2026-01-01-alpha.md" "$R"
} > "$big"
assert_eq "$(WORK_CHUNK=65536 work_main s4 "$big" "$R" | cut -f1,2)" $'plan\t2026-01-01-alpha' "a record longer than a chunk does not stall the scan"
assert_eq "$(sed -n 3p "$WORK_CACHE_DIR/work-s4.tsv" | cut -f3)" "docs/plans/inside-big.md" "a record longer than a chunk is read whole"

# Pruning runs at most once a day and deletes caches untouched for 14 days;
# lock and temp files stay.
pd="$(mktemp -d -p "$TMPROOT")"
touch -d '20 days ago' "$pd/work-old.tsv" "$pd/work-old.lock" "$pd/work-old.tmp.1"
touch "$pd/work-new.tsv"
WORK_CACHE_DIR="$pd" work_main s5 "$t" "$R" >/dev/null
assert_nofile "$pd/work-old.tsv" "a cache untouched for 20 days is pruned"
assert_file "$pd/work-new.tsv" "a recent cache is kept"
assert_file "$pd/work-old.lock" "a lock file is never pruned"
assert_file "$pd/work-old.tmp.1" "a temp file is never pruned"
touch -d '20 days ago' "$pd/work-old2.tsv"
WORK_CACHE_DIR="$pd" work_main s5 "$t" "$R" >/dev/null
assert_file "$pd/work-old2.tsv" "a second run within the day does not prune"

# Tasks 5 and 6: the work row on the status line
# The real status line script runs end to end under a temporary HOME whose
# .claude/statusline-work.sh links to the helper or to a stub, or is absent,
# so the real home's usage helper and account file stay out of the run. The
# ceiling keeps git from finding a repository above the temporary
# directories.
STATUSLINE="$HOME/.claude/statusline.sh"
E2E_CACHE="$(mktemp -d -p "$TMPROOT")"
statusline() { # home columns payload: prints the rendered rows
    (
        unset CLAUDE_CONFIG_DIR
        export HOME="$1" COLUMNS="$2" WORK_CACHE_DIR="$E2E_CACHE" GIT_CEILING_DIRECTORIES="$TMPROOT"
        printf '%s' "$3" | bash "$STATUSLINE"
    )
}
mk_home() { # target: a temporary HOME whose helper links to target, or has none when target is empty
    local h; h="$(mktemp -d -p "$TMPROOT")"
    mkdir "$h/.claude"
    [ -z "$1" ] || ln -s "$1" "$h/.claude/statusline-work.sh"
    printf '%s' "$h"
}
payload() { # current_dir session_id transcript
    jq -nc --arg d "$1" --arg s "$2" --arg t "$3" '{model: {display_name: "Model"},
        workspace: {current_dir: $d}, session_id: $s, transcript_path: $t,
        cost: {total_cost_usd: 0, total_duration_ms: 0}, context_window: {used_percentage: 0}}'
}
# mktemp names hold only characters url_encode_path keeps, so the encoded
# link target is the path itself.
tasks="$R/openspec/changes/add-groups/tasks.md"
work_link() { # label [path]: the row's icon and its link to path, by default the fixture change
    printf '📝 \e]8;;file://%s\a\e[4m%s\e[24m\e]8;;\a' "${2:-$tasks}" "$1"
}

git init -q -b main "$R"
printf '%s\n' '- [x] a' '- [x] b' '- [ ] c' '- [ ] d' > "$tasks"
et="$(mktemp -p "$TMPROOT")"
mk_record Bash command 'cat openspec/changes/add-groups/tasks.md' "$R" > "$et"
HW="$(mk_home "$HELPER")"
H0="$(mk_home "")"
link="$(work_link add-groups)"

# work_rows label home dir columns session transcript: renders the rows
# from one payload at one width, with the helper home gives and with none.
# The rows with a subject are the rows without one plus the work row,
# inserted just before the last line, the usage bar row; every other row
# matches byte for byte. Sets WORK_ROW to the inserted line.
work_rows() {
    local with without n
    with="$(statusline "$2" "$4" "$(payload "$3" "$5" "$6")")"
    without="$(statusline "$H0" "$4" "$(payload "$3" "$5" "$6")")"
    n="$(wc -l <<< "$with")"
    assert_eq "$n" "$(( $(wc -l <<< "$without") + 1 ))" "$1: the work row adds one line"
    assert_eq "$(sed "$(( n - 1 ))d" <<< "$with")" "$without" "$1: the other rows are the no-helper rows, byte for byte"
    assert_contains "$(tail -1 <<< "$with")" '░░░░░░░░░░' "$1: the usage bar row stays last"
    WORK_ROW="$(sed -n "$(( n - 1 ))p" <<< "$with")"
}

work_rows "in a repository" "$HW" "$R" 200 e2e1 "$et"
assert_eq "$WORK_ROW" "$link · 2/4" "the work row is the change's file link labelled with its name, its stage after it"

# The work row's fixed cells are 📝 (2) and " · 2/4" (6), 8 in all, and
# fit_names charges the name one more cell for the space before it, so 23
# columns leave 23 - 4 (LINE_RESERVE) - 8 - 1 = 10 cells, all of
# "add-groups": the narrowest width where the name and the stage fit whole.
work_rows "23 columns" "$HW" "$R" 23 e2e1 "$et"
assert_eq "$WORK_ROW" "$link · 2/4" "at 23 columns the name and the stage fit whole"
# One column less, the stage cannot stay. Dropping it gives back 6 cells,
# 22 - 4 - 2 - 1 = 15, so the name stays whole.
work_rows "22 columns" "$HW" "$R" 22 e2e1 "$et"
assert_eq "$WORK_ROW" "$link" "the stage drops before the name is cut"
# At 15 columns 15 - 4 - 2 - 1 = 8 cells are left without the stage, under
# the floor, so the last step cuts the name to 8 from the middle.
work_rows "15 columns" "$HW" "$R" 15 e2e1 "$et"
assert_eq "$WORK_ROW" "$(work_link 'add...ps')" "the name is cut from the middle once the stage is gone"

# Outside a repository there is no git row, so the work row follows row 1.
# The row has a budget of its own: at 76 columns, too narrow for row 1 to
# show the fixture's folder whole, the work row is unchanged.
NR="$(mktemp -d -p "$TMPROOT")"
work_rows "outside a repository" "$HW" "$NR" 200 e2e1 "$et"
assert_eq "$WORK_ROW" "$link · 2/4" "outside a repository the work row is the same"
assert_eq "$(statusline "$HW" 200 "$(payload "$NR" e2e1 "$et")" | wc -l)" "3" "outside a repository the work row is the second of three lines"
work_rows "outside a repository at 76 columns" "$HW" "$NR" 76 e2e1 "$et"
assert_eq "$WORK_ROW" "$link · 2/4" "the work row's budget does not depend on row 1"

# Anything but one well-formed line on a zero exit leaves the rows as they
# are with no helper at all; the same line from a stub that exits 0 renders
# as the helper's own.
mk_stub() { # status line...: a helper stub that prints the lines and exits with status
    local s; s="$(mktemp -p "$TMPROOT")"
    { printf '#!/bin/bash\nprintf "%%s\\n"'; printf ' %q' "${@:2}"; printf '\nexit %s\n' "$1"; } > "$s"
    chmod +x "$s"; printf '%s' "$s"
}
stub_rows() { # status line...: the rows rendered with a stub as the helper
    statusline "$(mk_home "$(mk_stub "$@")")" 200 "$(payload "$R" e2e1 "$et")"
}
none="$(statusline "$H0" 200 "$(payload "$R" e2e1 "$et")")"
assert_eq "$(printf '%s\n' "$none" | /bin/grep -c '📝')" "0" "no helper, no work row"
good=$'change\tadd-groups\t'"$tasks"$'\t2/4'
assert_eq "$(stub_rows 0 "$good")" "$(statusline "$HW" 200 "$(payload "$R" e2e1 "$et")")" "a stub's well-formed line renders as the helper's"
assert_eq "$(stub_rows 0 garbage)" "$none" "a garbage helper line renders as no helper"
assert_eq "$(stub_rows 1 "$good")" "$none" "a line on a nonzero exit renders as no helper"
assert_eq "$(stub_rows 0 "$good" "$good")" "$none" "two lines render as no helper"
assert_eq "$(stub_rows 0 $'prd\tadd-groups\t'"$tasks"$'\t')" "$none" "an unknown kind renders as no helper"
assert_eq "$(stub_rows 0 $'change\tadd\\groups\t'"$tasks"$'\t')" "$none" "a backslash in the name renders as no helper"
assert_eq "$(stub_rows 0 $'change\tadd-groups\t'"$R"$'/caf\xc3\xa9.md\t')" "$none" "a letter outside ASCII in the path renders as no helper"
assert_eq "$(stub_rows 0 "$good"$'\e[31m')" "$none" "an escape in the stage renders as no helper"

# A name longer than the floor keeps its stage only while it fits whole.
# A stub serves plan 2026-10-20-statusline-work (26 characters) at stage
# "Task 5 complete" (15), so the fixed cells are 2 + 3 + 15 = 20 with the
# stage and 2 without it.
long_plan="$R/docs/superpowers/plans/2026-10-20-statusline-work.md"
: > "$long_plan"
HL="$(mk_home "$(mk_stub 0 $'plan\t2026-10-20-statusline-work\t'"$long_plan"$'\tTask 5 complete')")"
long_link="$(work_link 2026-10-20-statusline-work "$long_plan")"
# 51 columns leave 51 - 4 - 20 - 1 = 26 cells, the whole name.
work_rows "a long name at 51 columns" "$HL" "$R" 51 e2e1 "$et"
assert_eq "$WORK_ROW" "$long_link · Task 5 complete" "a long name that fits whole keeps its stage"
# At 40 columns the stage could stay only with the name cut to
# 40 - 4 - 20 - 1 = 15. The stage goes instead, and 40 - 4 - 2 - 1 = 33
# cells hold the whole name.
work_rows "a long name at 40 columns" "$HL" "$R" 40 e2e1 "$et"
assert_eq "$WORK_ROW" "$long_link" "the stage drops before a long name is cut"
# At 25 columns 25 - 4 - 2 - 1 = 18 cells are left without the stage, and
# shorten keeps 8 characters in front and 7 behind.
work_rows "a long name at 25 columns" "$HL" "$R" 25 e2e1 "$et"
assert_eq "$WORK_ROW" "$(work_link '2026-10-...ne-work' "$long_plan")" "a long name is cut only once the stage is gone"

# The stage reaches the terminal as written: a backslash sequence in it is
# not read as an escape (echo -e would stop the row at \c and swallow its
# newline, so the usage bar row would join it).
mk_ws backslash progress.md '# SDD ledger: change add-groups (openspec/changes/add-groups/tasks.md)'
printf '%s\n' 'Section 1: complete \c tail' >> "$R/.superpowers/sdd/backslash/progress.md"
bt="$(mktemp -p "$TMPROOT")"
mk_record Agent prompt 'Read .superpowers/sdd/backslash/progress.md first' "$R" > "$bt"
work_rows "a backslash in the stage" "$HW" "$R" 200 e2e2 "$bt"
assert_eq "$WORK_ROW" "$link"' · Section 1 complete \c tail' "a backslash in the stage is printed literally"

# Final review I1: one record naming a subject and its workspace. An apply
# loop's dispatch prompt names both, often the plan or change last, so that
# row comes first in the cache and resolves without a workspace; the stage
# then comes from the workspace named in the same record, when it resolves
# to the same file. The change's task list holds 2/4 ticks from Task 5.
same_record() { # session prompt: one Agent prompt record under cwd R, then the helper's line
    local f; f="$(mktemp -p "$TMPROOT")"
    mk_record Agent prompt "$2" "$R" > "$f"
    work_main "$1" "$f" "$R"
}
mk_ws same-record progress.md '# SDD ledger: change add-groups (openspec/changes/add-groups/tasks.md)'
printf '%s\n' 'Section 2: complete' >> "$R/.superpowers/sdd/same-record/progress.md"
alpha="$R/docs/superpowers/plans/2026-01-01-alpha.md"
assert_eq "$(same_record t1 'Use .superpowers/sdd/late/ for docs/superpowers/plans/2026-01-01-alpha.md')" $'plan\t2026-01-01-alpha\t'"$alpha"$'\tTask 1 complete' "a plan named after its workspace in one record takes the ledger's stage"
assert_eq "$(same_record t2 'Use .superpowers/sdd/same-record/ for openspec/changes/add-groups/')" $'change\tadd-groups\t'"$tasks"$'\tSection 2 complete' "a change named after its workspace in one record takes the ledger's stage, not its ticks"
# A workspace of another subject in the same record lends nothing; nor
# does a retired one (exit 2), which does not blank the subject either.
assert_eq "$(same_record t3 'Use .superpowers/sdd/late/ for docs/plans/beta.md')" $'plan\tbeta\t'"$R"$'/docs/plans/beta.md\t' "a plan beside another subject's workspace has no stage"
assert_eq "$(same_record t4 'Use .superpowers/sdd/late/ for openspec/changes/add-groups/')" $'change\tadd-groups\t'"$tasks"$'\t2/4' "a change beside another subject's workspace keeps its ticks"
assert_eq "$(same_record t5 'Use .superpowers/sdd/gone/ for docs/plans/beta.md')" $'plan\tbeta\t'"$R"$'/docs/plans/beta.md\t' "a retired workspace in the same record changes nothing"

# Two records scanned by two runs each sit first in their run's bytes, yet
# stay two records: the cache keys a row by its position in the file. The
# stage search spans the whole cache (Task 7), so a plan read in the second
# run takes its stage from the workspace named in the first.
two="$(mktemp -p "$TMPROOT")"; tie_cache="$(mktemp -d -p "$TMPROOT")"
mk_record Agent prompt 'Use .superpowers/sdd/late/' "$R" > "$two"
assert_eq "$(WORK_CACHE_DIR="$tie_cache" work_main t6 "$two" "$R" | cut -f2,4)" $'2026-01-01-alpha\tTask 1 complete' "the workspace alone gives its ledger's stage"
first_end="$(stat -c %s "$two")"
mk_record Read file_path "$alpha" "$R" >> "$two"
assert_eq "$(WORK_CACHE_DIR="$tie_cache" work_main t6 "$two" "$R")" $'plan\t2026-01-01-alpha\t'"$alpha"$'\tTask 1 complete' "a plan read in a later run takes its stage from an earlier record's workspace"
assert_eq "$(tail -n +2 "$tie_cache/work-t6.tsv" | cut -f1 | tr '\n' ' ')" "$first_end 0 " "rows of two runs keep their positions in the file"
# A version 1 cache, whose positions restarted at every run, is discarded:
# its cached beta row is not rendered, and the rescan finds the plan.
end="$(stat -c %s "$two")"
printf '1\t%s\t%s\t%s\n0\t1\t%s\t\n' "$two" "$end" "$end" "$R/docs/plans/beta.md" > "$tie_cache/work-t6.tsv"
assert_eq "$(WORK_CACHE_DIR="$tie_cache" work_main t6 "$two" "$R" | cut -f2)" "2026-01-01-alpha" "a version 1 cache is discarded and rescanned"

# Task 7: an occurrence whose file is gone retires its subject only once a
# render has shown it, and a subject without a workspace takes its stage
# from any cached workspace occurrence of the same subject.
WORK_CACHE_DIR="$(mktemp -d -p "$TMPROOT")"; export WORK_CACHE_DIR
# never-resolved path does not retire: newest row is a relative path that never existed
t="$(mktemp -p "$TMPROOT")"
mk_record Read file_path "$R/docs/plans/beta.md" "$R" > "$t"
mk_record Bash command "git -C /elsewhere add home/docs/plans/beta.md" "$R" >> "$t"
assert_eq "$(work_main s7a "$t" "$R" | cut -f1,2)" $'plan\tbeta' "a never-existing relative path is skipped, not a retirement"
# a shown subject retires when its file goes
t2="$(mktemp -p "$TMPROOT")"; cp "$R/docs/plans/beta.md" "$R/docs/plans/gamma.md"
mk_record Read file_path "$R/docs/plans/gamma.md" "$R" > "$t2"
assert_eq "$(work_main s7b "$t2" "$R" | cut -f2)" "gamma" "shown once"
assert_eq "$(tail -n +2 "$WORK_CACHE_DIR/work-s7b.tsv" | head -1 | cut -f5)" "1" "the shown flag is committed"
# A commit renames a new file over the cache, so an unchanged inode means
# the redraw wrote nothing.
ino="$(stat -c %i "$WORK_CACHE_DIR/work-s7b.tsv")"
work_main s7b "$t2" "$R" >/dev/null
assert_eq "$(stat -c %i "$WORK_CACHE_DIR/work-s7b.tsv")" "$ino" "a redraw that sets no flag writes nothing"
rm "$R/docs/plans/gamma.md"
assert_eq "$(work_main s7b "$t2" "$R")" "" "a shown subject whose file vanished blanks the segment"
# stage borrowed from an older workspace occurrence of the same subject
t3="$(mktemp -p "$TMPROOT")"
mk_record Agent prompt "read .superpowers/sdd/add-groups/progress.md" "$R" > "$t3"
mk_record Bash command "ls" "$R" >> "$t3"
mk_record Read file_path "$R/openspec/changes/add-groups/tasks.md" "$R" >> "$t3"
printf '# SDD ledger: plan openspec/changes/add-groups/tasks.md\nSection 2: complete\n' > "$R/.superpowers/sdd/add-groups/progress.md"
assert_eq "$(work_main s7c "$t3" "$R" | cut -f2,4)" $'add-groups\tSection 2 complete' "a plain Read borrows the stage from the older workspace occurrence"
# version 2 cache discarded; a cache read from its offset of 1 would miss
# the workspace named in the first record
printf '2\t%s\t1\t1\n' "$t3" > "$WORK_CACHE_DIR/work-s7c.tsv"
assert_eq "$(work_main s7c "$t3" "$R" | cut -f2)" "add-groups" "a version 2 cache restarts from zero"
assert_eq "$(tail -n +2 "$WORK_CACHE_DIR/work-s7c.tsv" | cut -f3 | tr '\n' ' ')" "$R/openspec/changes/add-groups/ .superpowers/sdd/add-groups/ " "the rescan of a version 2 cache reaches the first record"
# A newer occurrence of a cached one's raw takes over its shown flag when the
# two resolve alike, as an absolute raw always does: a plan read and then
# removed by the same path retires instead of passing the walk to beta.
t4="$(mktemp -p "$TMPROOT")"; : > "$R/docs/plans/delta.md"
mk_record Read file_path "$R/docs/plans/beta.md" "$R" > "$t4"
mk_record Read file_path "$R/docs/plans/delta.md" "$R" >> "$t4"
assert_eq "$(work_main s7d "$t4" "$R" | cut -f2)" "delta" "the plan read last is shown"
rm "$R/docs/plans/delta.md"
mk_record Bash command "rm $R/docs/plans/delta.md" "$R" >> "$t4"
assert_eq "$(work_main s7d "$t4" "$R")" "" "a removal by the shown raw takes over its flag and retires the subject"
# A relative raw under another cwd resolves elsewhere, so its newer
# occurrence starts unshown.
t5="$(mktemp -p "$TMPROOT")"; : > "$R/docs/plans/epsilon.md"
mk_record Bash command "cat docs/plans/epsilon.md" "$R" > "$t5"
assert_eq "$(work_main s7e "$t5" "$R" | cut -f2)" "epsilon" "a relative raw is shown"
mk_record Bash command "cat docs/plans/epsilon.md" "$TMPROOT" >> "$t5"
work_main s7e "$t5" "$R" >/dev/null
assert_eq "$(tail -n +2 "$WORK_CACHE_DIR/work-s7e.tsv" | cut -f4,5)" "$TMPROOT"$'\t0' "a newer occurrence under another cwd starts unshown"
# A run that finds the lock held renders an unshown occurrence from the
# cache and leaves the cache as it was.
t6="$(mktemp -p "$TMPROOT")"
mk_record Read file_path "$R/docs/plans/beta.md" "$R" > "$t6"
n="$(stat -c %s "$t6")"
printf '%s\t%s\t%s\t%s\n0\t1\t%s\t%s\t0\n' "$WORK_CACHE_VERSION" "$t6" "$n" "$n" "$R/docs/plans/beta.md" "$R" > "$WORK_CACHE_DIR/work-s7f.tsv"
before="$(cat "$WORK_CACHE_DIR/work-s7f.tsv")"
( exec 9>"$WORK_CACHE_DIR/work-s7f.lock"; flock 9; sleep 1 ) & lp=$!; sleep 0.2
assert_eq "$(work_main s7f "$t6" "$R" | cut -f2)" "beta" "a run that finds the lock held shows an unshown occurrence"
assert_eq "$(cat "$WORK_CACHE_DIR/work-s7f.tsv")" "$before" "a run that finds the lock held writes no shown flag"
wait "$lp"

finish
