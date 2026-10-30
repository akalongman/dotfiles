#!/usr/bin/env bash
# Tests for the account badge of ~/.claude/statusline.sh: the slot tag that
# follows it, its colour, and the width the tag takes from row 1's path. Each
# case drives the whole script with a fake payload under a fake HOME that
# holds one state file per slot, and reads row 1.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # assert.sh is linted as its own file
source "$HERE/assert.sh"
SCRIPT="$HOME/.claude/statusline.sh"

# The width case counts the icon as one character, which holds only under a
# UTF-8 locale; pin one so the result does not depend on the caller's.
export LC_ALL=C.UTF-8

FAKE="$TMPROOT/home"
mkdir -p "$FAKE/.claude" "$FAKE/.claude4" "$FAKE/.claude10" "$FAKE/.claude-test" "$FAKE/.claude3"
state() { printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$2" > "$1/.claude.json"; }
state "$FAKE" one@x
state "$FAKE/.claude4" four@x
state "$FAKE/.claude10" ten@x
state "$FAKE/.claude-test" odd@x
# $FAKE/.claude3 holds no state file: that slot is logged out. Neither does
# $FAKE/.claude, as on this machine, where slot 1's file is $FAKE/.claude.json.

# Outside $FAKE, so the label is the full path and longer than any cap below.
LONGDIR="$TMPROOT/$(printf 'x%.0s' $(seq 70))"
mkdir -p "$LONGDIR"

payload() { jq -nc --arg d "$LONGDIR" '{model:{display_name:"M"},workspace:{current_dir:$d},output_style:{name:"S"},cost:{total_cost_usd:0,total_duration_ms:0}}'; }
render() { # config-dir-or-"unset"-or-"empty"  columns  -> row 1, raw
    case "$1" in
        unset) env -u CLAUDE_CONFIG_DIR HOME="$FAKE" COLUMNS="$2" bash "$SCRIPT" ;;
        empty) CLAUDE_CONFIG_DIR='' HOME="$FAKE" COLUMNS="$2" bash "$SCRIPT" ;;
        *)     CLAUDE_CONFIG_DIR="$1" HOME="$FAKE" COLUMNS="$2" bash "$SCRIPT" ;;
    esac < <(payload) | sed -n 1p
}
strip() { sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x07]*\x07//g'; }
label() { local row; row="$(strip <<<"$1")"; printf '%s' "${row##*📁 }"; }

E=$'\033'

r="$(render "$FAKE/.claude4" 120)"
assert_contains "$(strip <<<"$r")" '[👤 four@x][4] [M]' "slot 4 tag follows the badge"
assert_contains "$r" "${E}[36m[👤 four@x]${E}[0m${E}[36m[4]${E}[0m " "slot 4 badge and tag are cyan"
assert_contains "$(strip <<<"$(render unset 120)")" '[👤 one@x][1] [M]' "unset config dir is slot 1"
assert_contains "$(strip <<<"$(render empty 120)")" '[👤 one@x][1] [M]' "empty config dir is slot 1"
r="$(render "$FAKE/.claude" 120)"
assert_contains "$r" "${E}[31m[👤 not logged in]${E}[0m${E}[32m[1]${E}[0m " "explicit ~/.claude is slot 1 in green beside a red badge"
assert_contains "$(strip <<<"$(render "$FAKE/.claude4/" 120)")" '[👤 four@x][4]' "trailing slash still reads slot 4"
assert_contains "$(strip <<<"$(render "$FAKE/.claude10" 120)")" '[👤 ten@x][10]' "two-digit slot"
r="$(render "$FAKE/.claude-test" 120)"
assert_contains "$r" "${E}[33m[👤 odd@x]${E}[0m${E}[33m[.claude-test]${E}[0m " "unknown dir shows its basename in yellow"
r="$(render "$FAKE/.claude3" 120)"
assert_contains "$r" "${E}[31m[👤 not logged in]${E}[0m${E}[34m[3]${E}[0m " "logged-out badge is red, tag keeps blue"
# Width (UTF-8 locale, so the icon is one character): fixed cells on row 1 =
# badge text "[👤 four@x][4]" (13) + 2 + model (1) + 2 + 5 + style (6 + 1) = 30;
# available for the one name = 80 - 4 - 30 - 1 = 45, and a name longer than
# that is cut to exactly that many characters.
l="$(label "$(render "$FAKE/.claude4" 80)")"
assert_eq "${#l}" "45" "the tag's width shortens the path"
# The row reaches the terminal through echo -e, so a dir name is data that
# must not be read as an escape or split the row. Neither dir exists, so
# both slots read as logged out.
r="$(render "$FAKE/"'.claude\033[31mX' 120)"
assert_contains "$r" "${E}[31m[👤 not logged in]${E}[0m${E}[33m[?]${E}[0m " "a backslash sequence in the dir name prints as ? in yellow"
assert_contains "$(strip <<<"$(render "$FAKE/"$'.claude\nX' 120)")" '[👤 not logged in][?] [M]' "a newline in the dir name prints as ? on row 1"
finish
