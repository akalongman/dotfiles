#!/usr/bin/env bash
# Tests for ~/bin/yadm-stage-settings: it stages a filtered settings.json
# straight into the index, never writes the live file, and saves the MCP
# approval list through mcp-approvals export when the private dotfiles exist.
# Each case runs with HOME at a throwaway git repository holding a fixture
# settings.json and a fake ~/.dotfiles-private/home/bin/mcp-approvals.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # assert.sh is linted as its own file
source "$HERE/assert.sh"
SCRIPT="$HOME/bin/yadm-stage-settings"

# An inherited GIT_DIR or GIT_WORK_TREE would point the fixture's git calls at
# another repository, so clear git's repository-local variables first.
while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)
unset MCP_SETTINGS_FILE MCP_APPROVALS_FILE

assert_not_contains() { # haystack needle msg
    case "$1" in
        *"$2"*) _fail "$3 (unexpectedly found '$2')" ;;
        *) _pass ;;
    esac
}

H="$(mktemp -d -p "$TMPROOT")"
git init -q "$H"
mkdir -p "$H/.claude" "$H/bin" "$H/.dotfiles-private/home/bin"
# The fake records the settings file it was handed and its arguments, and
# exits with the status in $HOME/fake_rc (0 when absent).
cat >"$H/.dotfiles-private/home/bin/mcp-approvals" <<'FAKE'
#!/bin/sh
printf '%s %s\n' "${MCP_SETTINGS_FILE:-unset}" "$*" >>"$HOME/calls"
exit "$(cat "$HOME/fake_rc" 2>/dev/null || echo 0)"
FAKE
chmod 755 "$H/.dotfiles-private/home/bin/mcp-approvals"
ln -s ../.dotfiles-private/home/bin/mcp-approvals "$H/bin/mcp-approvals"
jq . >"$H/.claude/settings.json" <<'JSON'
{"permissions":{"allow":["Bash(ls)"]},"autoMode":{"x":1},"enabledMcpjsonServers":["alpha"],"disabledMcpjsonServers":["beta"]}
JSON

OUT="" ERR="" RC=0
run_stage() { # sets OUT ERR RC
    HOME="$H" bash "$SCRIPT" >"$H/out" 2>"$H/err"
    RC=$?
    OUT="$(cat "$H/out")"
    ERR="$(cat "$H/err")"
}
staged() { git -C "$H" ls-files -s -- .claude/settings.json; }
# Clears the index entry so the next case starts from nothing staged; the
# staged blob differs from the work tree by design, so `git rm --cached`
# would refuse.
unstage() {
    git -C "$H" update-index --force-remove -- .claude/settings.json
    assert_eq "$(staged)" "" "the fixture index is empty before the next case"
}

ino="$(stat -c %i "$H/.claude/settings.json")"
sha="$(sha256sum <"$H/.claude/settings.json")"
run_stage; assert_eq "$RC" 0 "stages"
assert_eq "$(git -C "$H" show :.claude/settings.json | jq -c 'keys')" '["permissions"]' "the three keys are gone from the blob"
assert_eq "$(git -C "$H" show :.claude/settings.json | jq -c .permissions)" '{"allow":["Bash(ls)"]}' "other keys staged as they are"
assert_eq "$(staged | cut -d' ' -f1)" 100644 "staged as a regular file"
assert_eq "$(jq -c keys "$H/.claude/settings.json")" '["autoMode","disabledMcpjsonServers","enabledMcpjsonServers","permissions"]' "live file untouched"
assert_eq "$(sha256sum <"$H/.claude/settings.json")" "$sha" "live file byte-identical"
assert_eq "$(stat -c %i "$H/.claude/settings.json")" "$ino" "live inode untouched"
assert_contains "$(cat "$H/calls")" "export" "export ran"; assert_not_contains "$(cat "$H/calls")" "$H/.claude/settings.json" "export read the snapshot, not the live file"
assert_not_contains "$(cat "$H/calls")" "unset" "export was handed a settings file"
assert_contains "$OUT" "staged .claude/settings.json without autoMode and the MCP server lists (live file untouched)" "final line"

echo 1 >"$H/fake_rc"; unstage
run_stage; assert_eq "$RC" 0 "a failing export still stages"; assert_contains "$ERR" "warning: mcp-approvals export failed (exit 1)" "warned"
assert_eq "$(git -C "$H" show :.claude/settings.json | jq -c 'keys')" '["permissions"]' "the blob is staged after a failing export"
rm -f "$H/fake_rc"

unstage
rm "$H/bin/mcp-approvals"; run_stage; assert_eq "$RC" 1 "private repo present but no resolving script aborts"
assert_contains "$ERR" "run link.sh first" "the fix is named"
assert_eq "$(staged)" "" "nothing staged after the abort"
cp "$H/.dotfiles-private/home/bin/mcp-approvals" "$H/bin/mcp-approvals"; run_stage; assert_eq "$RC" 1 "a plain-file script aborts"
assert_eq "$(staged)" "" "nothing staged after the plain-file abort"
rm "$H/bin/mcp-approvals"; ln -s ../.dotfiles-private/home/bin/mcp-approvals "$H/bin/mcp-approvals"

: >"$H/calls"
rm -r "$H/.dotfiles-private"; run_stage; assert_eq "$RC" 0 "no private repo: silent"; assert_not_contains "$ERR" "warning" "no warning"
assert_eq "$(cat "$H/calls")" "" "no export without the private repo"

unstage
printf '{}' >"$H/.claude/settings.json"; run_stage; assert_eq "$RC" 1 "an empty object is refused before staging"
assert_eq "$(staged)" "" "nothing staged for an empty object"
printf '{"autoMode":{}}' >"$H/.claude/settings.json"; run_stage; assert_eq "$RC" 1 "an object of local keys only is refused"
printf 'not json' >"$H/.claude/settings.json"; run_stage; assert_eq "$RC" 1 "invalid JSON is refused"
assert_eq "$(staged)" "" "nothing staged for invalid JSON"

finish
