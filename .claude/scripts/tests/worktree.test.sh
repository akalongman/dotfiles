#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/assert.sh"
ENGINE="$HOME/.claude/scripts/worktree.sh"

# Task 2: dispatch + sourcing
out="$(bash "$ENGINE" help 2>&1)"
assert_contains "$out" "worktree" "help mentions tool"
assert_ok "unknown subcommand exits non-zero" bash -c "! bash '$ENGINE' bogus-subcmd 2>/dev/null"
assert_ok "sourcing defines wt_info" bash -c "source '$ENGINE'; declare -F wt_info >/dev/null"

# Bring the engine functions into this shell for the function-level tests.
source "$ENGINE"

# Task 3: detection
main_repo="$(mk_repo)"
wt_path="$main_repo/.worktrees/feat-x"
git -C "$main_repo" worktree add -q -b feat/x "$wt_path" >/dev/null 2>&1
assert_fail "main checkout is not a worktree" wt_is_worktree "$main_repo"
assert_ok   "added worktree is a worktree"   wt_is_worktree "$wt_path"
assert_eq   "$(wt_safe_name 'feature/foo')" "feature-foo" "safe name slashes"
assert_eq   "$(cd "$main_repo" && wt_resolve_repo_dir)" "$main_repo" "resolve repo dir"

# Task 4: discovery
d_comp="$(mk_repo)"; mk_setup_target "$d_comp" composer
d_npm="$(mk_repo)";  mk_setup_target "$d_npm" npm
d_yarn="$(mk_repo)"; mk_setup_target "$d_yarn" yarn
d_none="$(mk_repo)"
assert_eq "$(wt_detect_primitive "$d_comp" worktree:setup)" "composer" "detect composer"
assert_eq "$(wt_detect_primitive "$d_npm"  worktree:setup)" "npm" "detect npm"
assert_eq "$(wt_detect_primitive "$d_yarn" worktree:setup)" "yarn" "detect yarn"
assert_eq "$(wt_detect_primitive "$d_none" worktree:setup)" "" "detect none"
( cd "$d_comp" && wt_run_target "$d_comp" worktree:setup ) >/dev/null 2>&1
assert_file "$d_comp/.wt-setup-ran" "composer target ran"

# Task 5: worktreeinclude
inc_repo="$(mk_repo)"
printf 'secret-env\n' > "$inc_repo/.env"
mkdir -p "$inc_repo/storage/app/secrets"
printf 'k\n' > "$inc_repo/storage/app/secrets/key"
printf '# comment\n.env\n/storage/app/secrets\nmissing.txt\n' > "$inc_repo/.worktreeinclude"
git -C "$inc_repo" add .worktreeinclude; git -C "$inc_repo" commit -qm inc
inc_wt="$inc_repo/.worktrees/w"
git -C "$inc_repo" worktree add -q -b w "$inc_wt" >/dev/null 2>&1
wt_apply_include "$inc_repo" "$inc_wt" >/dev/null 2>&1
assert_file "$inc_wt/.env" "env copied"
assert_file "$inc_wt/storage/app/secrets/key" "secrets dir copied"
assert_nofile "$inc_wt/missing.txt" "missing entry not created"

# Task 6: create flow
cr_repo="$(mk_repo)"; mk_setup_target "$cr_repo" composer
path="$(cd "$cr_repo" && wt_create demo 2>/dev/null | tail -n1)"
assert_eq "$path" "$cr_repo/.worktrees/demo" "create prints worktree path"
assert_file "$cr_repo/.worktrees/demo/.wt-setup-ran" "setup ran in worktree"

bare="$(mk_repo)"
bpath="$(cd "$bare" && wt_create plain 2>/dev/null | tail -n1)"
assert_eq "$bpath" "$bare/.worktrees/plain" "bare worktree created"

badrepo="$(mk_repo)"
printf '{"scripts":{"worktree:setup":"exit 7"}}\n' > "$badrepo/composer.json"
git -C "$badrepo" add composer.json; git -C "$badrepo" commit -qm bad
assert_fail "create fails when setup fails" bash -c "cd '$badrepo' && source '$ENGINE' && wt_create boom"
assert_nofile "$badrepo/.worktrees/boom" "rolled back on setup failure"

# Task 7: remove flow (teardown writes to the main repo so the marker survives removal)
rm_repo="$(mk_repo)"
printf '.wt-setup-ran\n' > "$rm_repo/.gitignore"
printf '{"scripts":{"worktree:setup":"touch .wt-setup-ran","worktree:teardown":"touch %s/.wt-teardown-ran"}}\n' "$rm_repo" > "$rm_repo/composer.json"
git -C "$rm_repo" add composer.json .gitignore; git -C "$rm_repo" commit -qm teardown-marker
rmpath="$(cd "$rm_repo" && wt_create gone 2>/dev/null | tail -n1)"
assert_file "$rmpath" "worktree exists before remove"
( cd "$rm_repo" && wt_remove gone ) >/dev/null 2>&1
assert_nofile "$rmpath" "worktree removed by name"
assert_file "$rm_repo/.wt-teardown-ran" "teardown ran (cwd was worktree)"

# Task 8: doctor / list
doc_repo="$(mk_repo)"; mk_setup_target "$doc_repo" composer
mkdir -p "$doc_repo/.claude"
printf '{"hooks":{"WorktreeCreate":[]}}\n' > "$doc_repo/.claude/settings.json"
out="$(cd "$doc_repo" && cmd_doctor 2>&1)"
assert_contains "$out" "composer" "doctor reports primitive"
assert_contains "$out" "WorktreeCreate" "doctor flags local hook"
assert_ok "doctor exits 0" bash -c "cd '$doc_repo' && source '$ENGINE' && cmd_doctor"
assert_ok "list exits 0" bash -c "cd '$doc_repo' && source '$ENGINE' && cmd_list"

# Task 9: hook adapters
hk_repo="$(mk_repo)"; mk_setup_target "$hk_repo" composer
hk_path="$(cd "$hk_repo" && printf '{"name":"hooked"}' | cmd_hook_create 2>/dev/null | tail -n1)"
assert_eq "$hk_path" "$hk_repo/.worktrees/hooked" "hook-create returns path"
( cd "$hk_repo" && printf '{"worktree_path":"%s"}' "$hk_path" | cmd_hook_remove ) >/dev/null 2>&1
assert_nofile "$hk_path" "hook-remove removed worktree"

# Task 10: shim
assert_file "$HOME/bin/worktree" "shim exists"
assert_ok "shim runs help" bash -c "'$HOME/bin/worktree' help 2>&1 | grep -q worktree"

# Regression: remove by a slashed branch name (branch names commonly contain slashes)
sl_repo="$(mk_repo)"; mk_setup_target "$sl_repo" composer
slpath="$(cd "$sl_repo" && wt_create "feature/x" 2>/dev/null | tail -n1)"
assert_eq "$slpath" "$sl_repo/.worktrees/feature-x" "slashed create path"
( cd "$sl_repo" && wt_remove "feature/x" ) >/dev/null 2>&1
assert_nofile "$slpath" "remove resolves slashed branch name"

# Regression: a .worktreeinclude directory entry merges untracked files even when a
# tracked placeholder makes the directory already exist in the worktree.
mg_repo="$(mk_repo)"
mkdir -p "$mg_repo/secretsdir"
printf 'x\n' > "$mg_repo/secretsdir/.gitignore"
printf 'sk\n' > "$mg_repo/secretsdir/real.key"
printf '/secretsdir\n' > "$mg_repo/.worktreeinclude"
git -C "$mg_repo" add .worktreeinclude secretsdir/.gitignore; git -C "$mg_repo" commit -qm mg
mg_wt="$mg_repo/.worktrees/m"
git -C "$mg_repo" worktree add -q -b m "$mg_wt" >/dev/null 2>&1
assert_nofile "$mg_wt/secretsdir/real.key" "secret absent before merge"
wt_apply_include "$mg_repo" "$mg_wt" >/dev/null 2>&1
assert_file "$mg_wt/secretsdir/real.key" "dir entry merges untracked secret"

finish
