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

# The pattern covers the five forms and nothing else.
forms='openspec/changes/a/ docs/superpowers/plans/b.md docs/plans/c.md .claude/docs/plans/d.md .superpowers/sdd/e/ docs/plans/f.txt openspec/changes/g'
assert_eq "$(printf '%s\n' "$forms" | /bin/grep -oE "$WORK_PATTERN" | tr '\n' ' ')" 'openspec/changes/a/ docs/superpowers/plans/b.md docs/plans/c.md .claude/docs/plans/d.md .superpowers/sdd/e/ ' "WORK_PATTERN matches the five forms only"

finish
