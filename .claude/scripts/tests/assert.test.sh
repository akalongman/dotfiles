#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/assert.sh"

# Every caller uses "$(mk_repo)", a command substitution. The repo it creates
# there must still be removed by finish.
# shellcheck disable=SC2016  # the script text is for the child shell to expand
leaked="$(bash -c 'source "$1"; d="$(mk_repo)"; finish >/dev/null 2>&1; printf "%s" "$d"' _ "$HERE/assert.sh")"
assert_nofile "$leaked" "finish removes a repo created through \$(mk_repo)"
rm -rf "$leaked"   # do not leak from this test while the helper is broken

finish
