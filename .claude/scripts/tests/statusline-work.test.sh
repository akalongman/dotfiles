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
assert_fail "workspace whose source is missing is skipped" work_resolve ".superpowers/sdd/gone/" 0 "$R"
assert_fail "missing plan file is not a subject" work_resolve "docs/plans/nope.md" 0 "$R"
assert_eq "$(work_resolve "$R/link/beta.md" 1 "" | cut -f3)" "$R/docs/plans/beta.md" "a symlinked path opens the real file"
assert_fail "a workspace naming an archived change is skipped" work_resolve ".superpowers/sdd/archived/" 0 "$R"
assert_file "$R/docs/plans/bad\$name.md" "the plan with a disallowed character exists"
assert_fail "a plan name outside the allowed set is dropped" work_resolve "docs/plans/bad\$name.md" 0 "$R"

# The base directory: CWD for a relative raw, HOME for ~/.
assert_fail "a relative raw with no cwd fails" work_resolve "docs/plans/beta.md" 0 ""
in_root() { (cd / && "$@"); }
assert_fail "a relative cwd fails even where it would resolve" in_root work_resolve "docs/plans/beta.md" 0 "${R#/}"
assert_eq "$(HOME="$R" work_resolve \~/docs/plans/beta.md 1 "")" $'plan\tbeta\t'"$R"$'/docs/plans/beta.md\t' "a home-relative raw resolves against HOME"
assert_fail "an absolute raw flagged relative fails" work_resolve "$R/docs/plans/beta.md" 0 /

# Punctuation-prefixed raws fail the character check even when the prefixed
# path exists.
P="$(mktemp -d -p "$TMPROOT")"
for pre in '(' '--x=' "\$HOME/" '[a]('; do
    mkdir -p "$P/${pre}docs/plans"; : > "$P/${pre}docs/plans/p.md"
    assert_fail "a raw prefixed with $pre is dropped" work_resolve "${pre}docs/plans/p.md" 0 "$P"
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
assert_fail "a named segment that .. removes still drops the raw" work_resolve "x(/../docs/plans/p.md" 0 "$P"
mkdir -p "$P/.superpowers/sdd/absolute" "$P/x("
printf '# SDD ledger: plan %s/docs/plans/p.md\n' "$P" > "$P/.superpowers/sdd/absolute/progress.md"
assert_eq "$(work_resolve ".superpowers/sdd/absolute/" 0 "$P" | cut -f1,2)" $'plan\tp' "a workspace naming an absolute source resolves"
assert_fail "a named segment that .. removes still drops a workspace" work_resolve "x(/../.superpowers/sdd/absolute/" 0 "$P"
assert_fail "a symlink onto a disallowed name is dropped" work_resolve "docs/plans/link.md" 0 "$P"
assert_fail "a workspace that resolves to a disallowed name is dropped" work_resolve ".superpowers/sdd/wslink/" 0 "$P"

# The archive rule holds for the path as named and as resolved. The
# archive's own tasks.md exists here, so a missing archive rule would yield
# a change named archive instead of failing the existence check.
A="$(mktemp -d -p "$TMPROOT")"
mkdir -p "$A/openspec/changes/archive/x" "$A/named/openspec/changes"
: > "$A/openspec/changes/archive/tasks.md"
: > "$A/openspec/changes/archive/x/tasks.md"
ln -s "$A/openspec/changes/archive/x" "$A/openspec/changes/y"
ln -s "$R/openspec/changes/add-groups" "$A/named/openspec/changes/archive"
assert_fail "an archived change is skipped" work_resolve "$A/openspec/changes/archive/x/" 1 ""
assert_fail "a change that resolves into the archive is skipped" work_resolve "$A/openspec/changes/y/" 1 ""
assert_fail "a raw naming the archive is skipped where it resolves elsewhere" work_resolve "$A/named/openspec/changes/archive/" 1 ""

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
assert_fail "a header on the second line is not read" work_resolve ".superpowers/sdd/other-first/" 0 "$R"
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

finish
