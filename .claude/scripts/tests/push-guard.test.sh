#!/usr/bin/env bash
# The commands under test are data: their $HOME and ~ must reach the hook unexpanded.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # assert.sh is linted as its own file
source "$HERE/assert.sh"
ENGINE="$HOME/.claude/scripts/push-guard.sh"

# An inherited GIT_DIR or GIT_WORK_TREE would point the fixture's git calls at
# another repository, so clear git's repository-local variables first.
while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)

root="$(mktemp -d -p "$TMPROOT")"; git init -q --separate-git-dir "$root/repo.git" "$root/home"; mkdir "$root/home/sub"; other="$(mk_repo)"

run_hook() { # tool command cwd; sets RC ERR
    ERR="$(jq -n --arg t "$1" --arg c "$2" --arg d "$3" '{tool_name:$t,tool_input:{command:$c},cwd:$d}' \
        | PUSH_GUARD_REPO="$root/repo.git" bash "$ENGINE" hook 2>&1 >/dev/null)"; RC=$?
}

# As run_hook, with HOME set to the fixture work tree, so that ~ and $HOME in a
# command under test never reach the real home directory.
run_home() { # tool command cwd; sets RC ERR
    ERR="$(jq -n --arg t "$1" --arg c "$2" --arg d "$3" '{tool_name:$t,tool_input:{command:$c},cwd:$d}' \
        | HOME="$root/home" PUSH_GUARD_REPO="$root/repo.git" bash "$ENGINE" hook 2>&1 >/dev/null)"; RC=$?
}

hook_json() { # command cwd -> hook input on stdout
    jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}

lines() { printf '%s\n' "$1" | wc -l; }

# The brief's cases.
run_hook Bash 'git push --no-verify' "$root/home";          assert_eq "$RC" 2 "no-verify push from the public work tree is refused"
assert_contains "$ERR" "push-guard: a push of the public dotfiles with hooks disabled is refused" "refusal reason"
run_hook Bash 'git push --no-verify origin main' "$root/home/sub"; assert_eq "$RC" 2 "refused from a subdirectory of the work tree"
run_hook Bash 'yadm push --no-verify' "$other";             assert_eq "$RC" 2 "yadm push with no-verify is refused from any directory"
run_hook Bash "git --git-dir=$root/repo.git -c core.hooksPath=/dev/null push" "$other"; assert_eq "$RC" 2 "a hooksPath bypass naming the public git dir is refused"
run_hook Bash 'git push' "$root/home";                      assert_eq "$RC" 0 "a plain push passes"
run_hook Bash 'git commit --no-verify -m x' "$root/home";   assert_eq "$RC" 0 "a commit with no-verify passes"
run_hook Bash 'git push --no-verify' "$other";              assert_eq "$RC" 0 "no-verify push of another repository passes"
run_hook Read 'git push --no-verify' "$root/home";          assert_eq "$RC" 0 "a tool other than Bash passes"
ERR="$(printf 'not json' | PUSH_GUARD_REPO="$root/repo.git" bash "$ENGINE" hook 2>&1)"; assert_eq "$?" 0 "unparsable input passes"; assert_eq "$ERR" "" "and prints nothing"
assert_fail "unknown subcommand exits nonzero" bash "$ENGINE" bogus

# Tools (owner ruling): Monitor runs tool_input.command in a shell, as Bash does.
run_hook Monitor 'git push --no-verify' "$root/home";       assert_eq "$RC" 2 "a Monitor command is checked like a Bash command"
run_hook Grep 'git push --no-verify' "$root/home";          assert_eq "$RC" 0 "another tool with the same command passes"

# The refusal contract: the exact push text, one line on stderr, nothing on stdout.
run_hook Bash 'git push --no-verify' "$root/home"
assert_eq "$ERR" "push-guard: a push of the public dotfiles with hooks disabled is refused; the pre-push guard is the publication check, fix the content and push without --no-verify (a push of another repository from this directory needs that repository as the working directory)" "the push refusal text is exact"
assert_eq "$(lines "$ERR")" 1 "the push refusal is one line"
out="$(hook_json 'git push --no-verify' "$root/home" | PUSH_GUARD_REPO="$root/repo.git" bash "$ENGINE" hook 2>/dev/null)"
assert_eq "$out" "" "a refusal prints nothing on stdout"
out="$(hook_json 'git push --no-verify' "$other" | PUSH_GUARD_REPO="$root/repo.git" bash "$ENGINE" hook 2>&1)"
assert_eq "$out" "" "a pass with a bypass token prints nothing at all"
assert_ok "the hook is executable" test -x "$ENGINE"
hook_json 'git push --no-verify' "$root/home" | PUSH_GUARD_REPO="$root/repo.git" "$ENGINE" hook 2>/dev/null
assert_eq "$?" 2 "the hook runs directly through its shebang"
out="$(bash "$ENGINE" bogus 2>&1)"; assert_contains "$out" "usage: push-guard.sh hook" "an unknown subcommand prints the usage line"
assert_fail "no subcommand exits nonzero" bash "$ENGINE"

# Named directories (owner ruling): -C, cd, --git-dir, --work-tree, GIT_DIR=
# and GIT_WORK_TREE= name targets besides cwd; only ~, $HOME and ${HOME} expand.
other2="$(mk_repo)"
run_home Bash 'git -C "$HOME" push --no-verify' "$other";   assert_eq "$RC" 2 "-C naming the public work tree is refused"
run_home Bash 'cd ~ && git push --no-verify' "$other";      assert_eq "$RC" 2 "cd to the public work tree is refused"
run_home Bash 'git --git-dir="$HOME/.git" -c core.hooksPath=/dev/null push' "$other"; assert_eq "$RC" 2 "--git-dir naming the gitfile of the public work tree is refused"
run_hook Bash "git -C $other push --no-verify" "$other2";   assert_eq "$RC" 0 "-C naming another repository passes"
run_home Bash 'cd && git push --no-verify' "$other";        assert_eq "$RC" 2 "a bare cd names the home directory"
run_home Bash 'pushd ~ && git push --no-verify' "$other";   assert_eq "$RC" 2 "pushd counts as cd"
run_home Bash 'if cd ~; then git push --no-verify; fi' "$other"; assert_eq "$RC" 2 "a cd after a shell keyword counts"
run_home Bash 'git -C "${HOME}/sub" push --no-verify' "$other"; assert_eq "$RC" 2 "\${HOME} expands"
ln -s home "$root/homeDIR"   # a wrong expansion of $HOMEDIR would land on the work tree
run_home Bash 'git -C "$HOMEDIR" push --no-verify' "$other"; assert_eq "$RC" 0 "a longer name that starts with HOME does not expand"
run_hook Bash "git -C ../$(basename "$root")/home push --no-verify" "$other"; assert_eq "$RC" 2 "a relative directory resolves against cwd"
run_home Bash 'GIT_DIR=~/.git git push --no-verify' "$other"; assert_eq "$RC" 2 "GIT_DIR naming a gitfile follows it"
ln -s repo.git "$root/link.git"
run_hook Bash "GIT_DIR=$root/link.git git push --no-verify" "$other"; assert_eq "$RC" 2 "a git dir reached through a symlink is refused"
mkdir "$root/rel"; printf 'gitdir: ../repo.git\n' > "$root/rel/gitfile"
run_hook Bash "git --git-dir $root/rel/gitfile push --no-verify" "$other"; assert_eq "$RC" 2 "a relative gitfile resolves against its own directory"
run_home Bash 'git --work-tree ~ push --no-verify' "$other"; assert_eq "$RC" 2 "--work-tree naming the public work tree is refused"
run_home Bash 'GIT_WORK_TREE=$HOME git push --no-verify' "$other"; assert_eq "$RC" 2 "GIT_WORK_TREE naming the public work tree is refused"
run_hook Bash "cd $TMPROOT/gone && git push --no-verify" "$other"; assert_eq "$RC" 0 "a cd to a missing directory passes"; assert_eq "$ERR" "" "and prints nothing"

# Linked worktrees (owner ruling): a directory resolves to its common git dir, so
# a linked worktree of the public repository is the public repository.
git -C "$root/home" config user.email t@t.t; git -C "$root/home" config user.name t
git -C "$root/home" config commit.gpgsign false   # global gpgsign=true would hang/fail in tests
git -C "$root/home" commit -q --allow-empty -m init
wt="$TMPROOT/wt";   git -C "$root/home" worktree add -q --detach "$wt"
owt="$TMPROOT/owt"; git -C "$other" worktree add -q --detach "$owt"
assert_contains "$(git -C "$wt" rev-parse --absolute-git-dir)" "/repo.git/worktrees/" "the fixture is a linked worktree"
assert_file "$owt/.git" "the other repository has a linked worktree"
run_hook Bash 'git push --no-verify' "$wt";                 assert_eq "$RC" 2 "a push from a linked worktree of the public repository is refused"
run_hook Bash "git -C $wt push --no-verify" "$other";       assert_eq "$RC" 2 "-C naming a linked worktree of the public repository is refused"
run_hook Bash "GIT_DIR=$wt/.git git push --no-verify" "$other"; assert_eq "$RC" 2 "a git dir naming a linked worktree's gitfile is refused"
run_hook Bash 'git push --no-verify' "$owt";                assert_eq "$RC" 0 "a linked worktree of another repository passes"

# The command is read, never run.
marker="$TMPROOT/evaluated"
run_hook Bash "git -C \"\$(touch $marker)\" -C \`touch $marker\` push --no-verify" "$other"
assert_eq "$RC" 0 "a directory spelled as a command substitution does not resolve"
assert_nofile "$marker" "and no part of the command runs"

# Quoting that would hide a named directory from a naive split.
run_home Bash $'cat > notes.txt <<\'EOF\'\nit\'s a note\nEOF\ncd ~ && git push --no-verify' "$other"; assert_eq "$RC" 2 "a heredoc body with an apostrophe does not hide a later cd"
run_home Bash "git -C ~ push --no-verify # don't" "$other"; assert_eq "$RC" 2 "a comment with an apostrophe does not hide -C"
run_home Bash "git -C ~ push --no-verify 'unclosed" "$other"; assert_eq "$RC" 0 "a command the shell cannot parse passes the named-directory rule"

# Further bypass spellings.
run_hook Bash 'git push --no-veri' "$root/home";            assert_eq "$RC" 2 "the abbreviation --no-veri is refused"
run_hook Bash 'git push --no-verif' "$root/home";           assert_eq "$RC" 2 "the abbreviation --no-verif is refused"
run_hook Bash 'git -c core.hookspath=/dev/null push' "$root/home"; assert_eq "$RC" 2 "core.hooksPath matches in any letter case"
run_hook Bash 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git push' "$root/home"; assert_eq "$RC" 2 "core.hooksPath set through the config environment is refused"
run_hook Bash 'git --config-env=core.hooksPath=HOOKS push' "$root/home"; assert_eq "$RC" 2 "core.hooksPath set through --config-env is refused"
run_hook Bash '/usr/lib/git-core/git-push --no-verify' "$root/home"; assert_eq "$RC" 2 "the dashed git-push is a push"
run_hook Bash 'git commit --no-verify -m "add push-guard"' "$root/home"; assert_eq "$RC" 0 "push inside a hyphenated word is not a push"

# The pre-push guard's DOTFILES_GUARD_ pointers aim its list and its scanner at
# stand-ins (final review I1): a push that sets one is refused, a run without a
# push passes.
run_hook Bash 'DOTFILES_GUARD_DENYLIST=/tmp/x yadm push' "$other"; assert_eq "$RC" 2 "a push setting the guard's list pointer is refused from any directory"
assert_contains "$ERR" "push-guard: a push of the public dotfiles with hooks disabled is refused" "with the push reason"
run_hook Bash 'DOTFILES_GUARD_DENYLIST=/tmp/x bash tests/dotfiles-guard.test.sh' "$root/home"; assert_eq "$RC" 0 "the guard's list pointer without a push passes"

# Known false positives, documented in the script header.
run_hook Bash 'git commit -m "push --no-verify is refused"' "$root/home"; assert_eq "$RC" 2 "known false positive: a message that reads push --no-verify"
run_hook Bash "git -C $other push --no-verify" "$root/home"; assert_eq "$RC" 2 "known false positive: another repository by -C from the public work tree"

# core.hooksPath writes (owner ruling): refused globally, or locally for the
# public repository; reads and -c on a command other than push pass.
run_hook Bash 'git config --global core.hooksPath /dev/null' "$other"; assert_eq "$RC" 2 "a global hooksPath write is refused from any directory"
assert_contains "$ERR" "core.hooksPath would redirect hooks away from the public dotfiles' pre-push guard" "config refusal reason"
assert_eq "${ERR:0:12}" "push-guard: " "the config refusal starts with the guard name"
assert_eq "$(lines "$ERR")" 1 "the config refusal is one line"
run_hook Bash 'git config --system core.hooksPath /x' "$other"; assert_eq "$RC" 2 "a system hooksPath write is refused from any directory"
run_hook Bash 'sudo git config --system core.hooksPath /x' "$other"; assert_eq "$RC" 2 "a write after a command prefix is refused"
run_hook Bash 'git config --global CORE.HOOKSPATH /x' "$other"; assert_eq "$RC" 2 "the config key matches in any letter case"
for f in '--file /tmp/x' '-f /tmp/x' '--file=/tmp/x'; do
    run_hook Bash "git config $f core.hooksPath /x" "$other"; assert_eq "$RC" 2 "a write with $f is refused from any directory"
done
run_hook Bash 'git config core.hooksPath /dev/null' "$root/home"; assert_eq "$RC" 2 "a local write in the public work tree is refused"
run_home Bash 'git -C ~ config core.hooksPath /dev/null' "$other"; assert_eq "$RC" 2 "a local write naming the public work tree is refused"
run_hook Bash 'yadm gitconfig core.hooksPath /dev/null' "$other"; assert_eq "$RC" 2 "a yadm gitconfig write is refused"
for w in 'set core.hooksPath /x' 'unset core.hooksPath' '--unset core.hooksPath' '--unset-all core.hooksPath' \
         '--add core.hooksPath /x' '--replace-all core.hooksPath /x' 'core.hooksPath /x --local'; do
    run_hook Bash "git config $w" "$root/home"; assert_eq "$RC" 2 "git config $w is a write"
done
run_hook Bash 'git config core.hooksPath .githooks' "$other"; assert_eq "$RC" 0 "a local write in another repository passes"
for r in '--get core.hooksPath' 'core.hooksPath' 'get core.hooksPath' '--get-all core.hooksPath' \
         '--get-regexp core.hooksPath' '--global --get core.hooksPath'; do
    run_hook Bash "git config $r" "$root/home"; assert_eq "$RC" 0 "git config $r is a read"
done
run_hook Bash 'git config --list | grep -i core.hooksPath' "$root/home"; assert_eq "$RC" 0 "listing the config passes"

# A redirection is not an argument (review I1): a read with a redirect stays a read.
run_hook Bash 'git config core.hooksPath 2>/dev/null' "$root/home"; assert_eq "$RC" 0 "a bare-key read with 2>/dev/null passes"
run_hook Bash 'git config --global core.hooksPath 2>/dev/null || echo unset' "$other"; assert_eq "$RC" 0 "a global bare-key read with 2>/dev/null passes"
for r in 'core.hooksPath >/dev/null' 'core.hooksPath 2>&1' 'core.hooksPath &>/dev/null' 'core.hooksPath 2> /dev/null' \
         'core.hooksPath <<<x' '--get core.hooksPath 2>/dev/null' '--get-all core.hooksPath >/dev/null 2>&1'; do
    run_hook Bash "git config $r" "$root/home"; assert_eq "$RC" 0 "git config $r is a read"
done
run_hook Bash 'git config --global core.hooksPath /x 2>/dev/null' "$other"; assert_eq "$RC" 2 "a global write with a redirect is still refused"
run_hook Bash 'git config core.hooksPath /x &>/dev/null' "$root/home"; assert_eq "$RC" 2 "a local write with &> is still refused"
run_hook Bash 'git config core.hooksPath "7">/dev/null' "$root/home"; assert_eq "$RC" 2 "a quoted digit before > is a value, not an fd number"
run_hook Bash 'git config core.hooksPath 2>&1 /x' "$root/home"; assert_eq "$RC" 2 "2>&1 does not end the command: a value after it is a write"
run_hook Bash 'git config core.hooksPath &>/dev/null /x' "$root/home"; assert_eq "$RC" 2 "&> does not end the command: a value after it is a write"
# &> takes no fd number, so a digit before it is a value (final review I2).
run_hook Bash 'git config core.hooksPath 2&>/dev/null' "$root/home"; assert_eq "$RC" 2 "a digit before &> is a value: a local write in the public work tree is refused"
run_hook Bash 'git config --global core.hooksPath 2&>/dev/null' "$other"; assert_eq "$RC" 2 "a digit before &> is a value: a global write is refused from any directory"
run_home Bash 'cd 2>/dev/null && git push --no-verify' "$other"; assert_eq "$RC" 2 "a bare cd with a redirect names the home directory"
run_hook Bash 'git -c core.hooksPath=/dev/null commit -m x' "$root/home"; assert_eq "$RC" 0 "-c core.hooksPath on a command other than push passes"

# Internal failures pass silently.
ERR="$(printf 'not json --no-verify' | PUSH_GUARD_REPO="$root/repo.git" bash "$ENGINE" hook 2>&1)"; assert_eq "$?" 0 "unparsable input holding a bypass token passes"; assert_eq "$ERR" "" "and prints nothing"
ERR="$(printf '["git push --no-verify"]' | PUSH_GUARD_REPO="$root/repo.git" bash "$ENGINE" hook 2>&1)"; assert_eq "$?" 0 "JSON that is not an object passes"; assert_eq "$ERR" "" "and prints nothing"
nojq="$TMPROOT/nojq"; mkdir "$nojq"
for t in cat git realpath awk; do ln -s "$(command -v "$t")" "$nojq/$t"; done
ERR="$(hook_json 'git push --no-verify' "$root/home" | PATH="$nojq" PUSH_GUARD_REPO="$root/repo.git" "$BASH" "$ENGINE" hook 2>&1)"; assert_eq "$?" 0 "a missing jq passes"; assert_eq "$ERR" "" "and prints nothing"
run_hook Bash 'git push --no-verify' "$TMPROOT/gone";       assert_eq "$RC" 0 "a cwd that does not exist passes"; assert_eq "$ERR" "" "and prints nothing"

finish
