#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HOME/.claude/scripts/tests/assert.sh"
ATTACH="$HERE/../tmux-attach"

# Every tmux call, the script's own included, goes to a private server: a
# shim first on PATH pins the socket and replaces ~/.tmux.conf with a file
# the tests own (empty unless a case needs an option). TMUX_TMPDIR is not
# enough: tmux 3.4 falls back to /tmp when that directory is missing.
# The shim is also the interleaving control: when the file named by
# TMUX_ATTACH_TEST_DELAY exists it sleeps before every list command, and
# when the file named by TMUX_ATTACH_TEST_PAUSE exists it sleeps before an
# attach, so a test can force two terminals to read the same state or hold
# one between its claim and its attach.
T="$(mktemp -d)"; TMPDIRS+=("$T")
mkdir "$T/bin"
: > "$T/tmux.conf"
cat > "$T/bin/tmux" <<EOF
#!/bin/sh
case "\$1" in
    list-sessions|list-windows) [ -e "\${TMUX_ATTACH_TEST_DELAY:-/nonexistent}" ] && sleep 0.5 ;;
    attach-session) [ -e "\${TMUX_ATTACH_TEST_PAUSE:-/nonexistent}" ] && sleep 3 ;;
esac
exec /usr/bin/tmux -f "$T/tmux.conf" -S "$T/sock" "\$@"
EOF
chmod +x "$T/bin/tmux"
export PATH="$T/bin:$PATH" SHELL=/bin/sh XDG_RUNTIME_DIR="$T"
unset TMUX TMUX_PANE TMUX_ATTACH_TEST_DELAY TMUX_ATTACH_TEST_PAUSE
# A stand-in for the user's shell in the fallback cases: it records its
# environment and exits, so a fallback never leaves a shell waiting.
printf '#!/bin/sh\nenv > "%s/shell.env"\n' "$T" > "$T/fakeshell"; chmod +x "$T/fakeshell"
# script(1) copies its stdin into the pty and types the EOF character
# when stdin ends, which would close the shell a terminal lands on; a FIFO
# opened read-write never ends. Killing the server does not end a fake
# client whose command fell back to a shell, so teardown kills the clients
# by pid (fake_client records them) before it waits.
mkfifo "$T/keep"
TABS=()
# The shim by path: once finish has removed $T, the trap's call fails instead of reaching the real tmux.
teardown() { "$T/bin/tmux" kill-server 2>/dev/null; [ "${#TABS[@]}" -eq 0 ] || kill "${TABS[@]}" 2>/dev/null; wait; TABS=(); }
trap teardown EXIT

# A home tree: a repository at its root (the yadm gitlink makes every
# unmanaged directory under ~ look like part of one repository), a private
# dotfiles repository, and the project directories of the spec's key table.
H="$T/home"
mkdir -p "$H/projects/tsmu/iac/ansible" "$H/projects/personal/iac" \
    "$H/projects/tsmu/tsmulms/.worktrees/feature-x" "$H/projects/tsmu/tsmulms/src" \
    "$H/projects/oss/laravel/framework/src" "$H/projects/inex/inex-smpp" \
    "$H/projects/longisoft" "$H/projects/longisoft/company" "$H/.dotfiles-private/machine" \
    "$H/Downloads" "$H/.claude" "$H/projects/personal/my_tool" \
    "$H/projects/personal/My Project" "$H/___"
git -C "$H" init -q
git -C "$H/.dotfiles-private" init -q
export HOME="$H"

# A fake client: a command on its own pty in a directory, its pid recorded
# for teardown. A terminal is tmux-attach started that way, one second
# apart, as a person opens tabs; tab_now starts one without the pause.
fake_client() { ( cd "$1" && exec script -q -f -c "$2" /dev/null <> "$T/keep" >/dev/null 2>&1 ) & TABS+=("$!"); }
tab_now() { fake_client "$1" "$ATTACH"; }
tab() { tab_now "$1"; sleep 1; }
attached() { tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | awk -v n="$1" '$1 == n { print $2 }'; }
group_of() { tmux list-sessions -F '#{session_name} #{session_group}' 2>/dev/null | awk -v n="$1" '$1 == n { print $2 }'; }
views_of() { # holder -> names of the other members of its group, sorted
    tmux list-sessions -F '#{session_name} #{session_group}' 2>/dev/null \
        | awk -v g="$(group_of "$1")" -v h="$1" 'g != "" && $2 == g && $1 != h { print $1 }' | sort
}
shown() { # holder -> current window of every attached member of its group, sorted
    tmux list-sessions -F '#{session_group} #{session_attached} #{window_id}' 2>/dev/null \
        | awk -v g="$(group_of "$1")" 'g != "" && $1 == g && $2 > 0 { print $3 }' | sort | tr '\n' ' '
}
windows_of() { tmux list-windows -t "=$1" -F '#{window_id}' 2>/dev/null | wc -l; }
window_of() { tmux display -p -t "=$1:" '#{window_id}' 2>/dev/null; }
path_of() { tmux display -p -t "=$1:" '#{pane_current_path}' 2>/dev/null; }
n_tabs_n_windows() { # holder n
    local s; s="$(shown "$1")"
    assert_eq "$(printf '%s' "$s" | wc -w)" "$2" "$1: $2 terminals attached"
    # shellcheck disable=SC2086
    assert_eq "$(printf '%s\n' $s | sort -u | wc -l)" "$2" "$1: the terminals show different windows"
}

# --- Task 1: the key
key() { "$ATTACH" --key "$1"; }
assert_eq "$(key "$H")" "main" "key: home is main"
assert_eq "$(key "$H/projects/tsmu/iac/ansible")" "tsmu-iac" "key: org and project, subdirectory ignored"
assert_eq "$(key "$H/projects/personal/iac")" "personal-iac" "key: same project name under another org"
assert_eq "$(key "$H/projects/tsmu/tsmulms/.worktrees/feature-x")" "tsmu-tsmulms" "key: a worktree shares the project key"
assert_eq "$(key "$H/projects/oss/laravel/framework/src")" "oss-laravel-framework" "key: three components under oss"
assert_eq "$(key "$H/projects/inex/inex-smpp")" "inex-inex-smpp" "key: a repeated org name is kept"
assert_eq "$(key "$H/projects/longisoft")" "longisoft" "key: an org directory falls through to its basename"
assert_eq "$(key "$H/.dotfiles-private/machine")" "dotfiles-private" "key: git top level outside ~, leading dot dropped"
assert_eq "$(key "$H/Downloads")" "Downloads" "key: the yadm gitlink does not make ~ the top level"
assert_eq "$(key "$H/.claude")" "claude" "key: dotted directory under ~"
assert_eq "$(key "$H/projects/personal/my_tool")" "personal-my-tool" "key: underscore becomes a dash"
assert_eq "$(key "$H/projects/personal/My Project")" "personal-My-Project" "key: space becomes a dash, case kept"
assert_eq "$(cd "$H/projects/tsmu/iac/ansible" && "$ATTACH" --key)" "tsmu-iac" "key: --key without a directory reads the current one"
"$ATTACH" --key "$H/___" >/dev/null 2>&1; assert_eq "$?" "1" "key: a name of excluded characters only exits 1"
assert_eq "$(key "$H/___" 2>/dev/null)" "" "key: the error prints nothing on stdout"
"$ATTACH" --key "$H/gone" >/dev/null 2>&1; assert_eq "$?" "1" "key: a missing directory exits 1"

teardown
finish
