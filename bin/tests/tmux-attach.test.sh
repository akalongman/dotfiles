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

# --- Task 2: first, second and third terminal
P="$H/projects/tsmu/tsmulms"
tab "$P"
assert_eq "$(attached tsmu-tsmulms)" "0" "first terminal: the holder stays unattached"
v1=$(views_of tsmu-tsmulms)
assert_eq "$(printf '%s\n' "$v1" | grep -c .)" "1" "first terminal: one view"
assert_eq "${v1%_*}" "tsmu-tsmulms" "first terminal: the view is named after the key"
case "${v1##*_}" in ''|*[!0-9]*) assert_eq "${v1##*_}" "digits" "first terminal: the view suffix is a pid" ;; *) assert_eq 1 1 "first terminal: the view suffix is a pid" ;; esac
assert_eq "$(attached "$v1")" "1" "first terminal: the view is attached"
assert_eq "$(tmux show-option -t "=$v1:" -v destroy-unattached)" "on" "first terminal: the view destroys itself on detach"
assert_eq "$(tmux show-option -t "=$v1:" -qv @view)" "1" "first terminal: the view carries the claim marker"
assert_eq "$(window_of "$v1")" "$(tmux list-windows -t =tsmu-tsmulms -F '#{window_id}' | head -1)" "first terminal: the view shows the holder's first window"
assert_eq "$(path_of "$v1")" "$P" "first terminal: the holder's window is in the project directory"
tmux new-window -d -t =tsmu-tsmulms: -c "$P"
tab "$P"
n_tabs_n_windows tsmu-tsmulms 2
assert_eq "$(windows_of tsmu-tsmulms)" "2" "second terminal: the free window is reused, none added"
tab "$P/src"
n_tabs_n_windows tsmu-tsmulms 3
assert_eq "$(windows_of tsmu-tsmulms)" "3" "third terminal: no window was free, one was added"
v3=$(views_of tsmu-tsmulms | tail -1)
assert_eq "$(path_of "$v3")" "$P/src" "third terminal: the new window opens in the terminal's directory"

# A legacy direct client on the holder (tmux attach by hand) takes its
# window, even before any view has made the holder a group.
tmux new-session -d -s personal-iac -c "$H/projects/personal/iac"
tmux new-window -d -t =personal-iac: -c "$H/projects/personal/iac"
fake_client "$H" "tmux attach-session -t =personal-iac"
sleep 1
tab "$H/projects/personal/iac"
assert_eq "$(attached personal-iac)" "1" "direct client: the holder stays attached by hand"
v=$(views_of personal-iac)
assert_eq "$(tmux list-sessions -F '#{session_name} #{window_id}' | awk -v a=personal-iac -v b="$v" '$1 == a || $1 == b { print $2 }' | sort -u | wc -l)" "2" "direct client: the terminal does not share its window"
assert_eq "$(windows_of personal-iac)" "2" "direct client: the second window was free"

# No tmux: the terminal gets a plain shell with NO_TMUX=1, not a dead tab.
mkdir "$T/broken"
printf '#!/bin/sh\nexit 1\n' > "$T/broken/tmux"; chmod +x "$T/broken/tmux"
( cd "$P" && PATH="$T/broken:$PATH" SHELL="$T/fakeshell" "$ATTACH" 2>"$T/fallback.err" )
assert_eq "$(grep -c '^NO_TMUX=1$' "$T/shell.env")" "1" "no server: the plain shell runs with NO_TMUX=1"
assert_eq "$(grep -c 'tmux-attach:' "$T/fallback.err")" "1" "no server: one line explains the fallback"
rm -f "$T/shell.env"
( cd "$P" && TMUX=fake SHELL="$T/fakeshell" "$ATTACH" 2>"$T/fallback.err" )
assert_eq "$(grep -c '^NO_TMUX=1$' "$T/shell.env")" "1" "inside tmux: the plain shell runs with NO_TMUX=1"
assert_eq "$(wc -c < "$T/fallback.err")" "0" "inside tmux: no message"
rm -f "$T/shell.env"
( cd "$H/___" && SHELL="$T/fakeshell" "$ATTACH" 2>"$T/fallback.err" )
assert_eq "$(grep -c '^NO_TMUX=1$' "$T/shell.env")" "1" "empty key: the plain shell runs with NO_TMUX=1"
rm -f "$T/shell.env"

# --- Task 3: a claimed window is taken before its client attaches
C="$H/projects/longisoft/company"
tmux new-session -d -s longisoft-company -c "$C"
tmux new-window -d -t =longisoft-company: -c "$C"
touch "$T/pause"
TMUX_ATTACH_TEST_PAUSE="$T/pause" fake_client "$C" "$ATTACH"
sleep 1
assert_eq "$(views_of longisoft-company | grep -c .)" "1" "paused claim: the first view exists before it attaches"
assert_eq "$(tmux list-sessions -F '#{session_name} #{session_attached}' | awk -v g="$(group_of longisoft-company)" -v h=longisoft-company '$1 != h && $1 ~ "^longisoft-company_" { print $2 }')" "0" "paused claim: the first view is not attached yet"
tab "$C"
sleep 3
n_tabs_n_windows longisoft-company 2
assert_eq "$(windows_of longisoft-company)" "2" "paused claim: the second terminal took the other free window"
rm -f "$T/pause"

# A stale view with this terminal's pid (pids repeat after a reboot): an
# unattached one in the holder's group gives way, and the window it marked
# as claimed is free again; anything else falls back.
I="$H/projects/inex/inex-smpp"
tmux new-session -d -s inex-inex-smpp -c "$I"
fake_client "$I" "sh -c 'tmux new-session -d -t =inex-inex-smpp -s inex-inex-smpp_\$\$ \\; set-option -t =inex-inex-smpp_\$\$: @view 1; exec $ATTACH'"
sleep 2
assert_eq "$(views_of inex-inex-smpp | grep -c .)" "1" "stale view: one view of that pid remains"
assert_eq "$(attached "$(views_of inex-inex-smpp)")" "1" "stale view: the remaining view is the live one"
assert_eq "$(windows_of inex-inex-smpp)" "1" "stale view: its claimed window was free again, none added"
( cd "$H/projects/personal/iac" && SHELL="$T/fakeshell" sh -c 'tmux new-session -d -s personal-iac_$$; exec "$0"' "$ATTACH" 2>"$T/fallback.err" )
assert_eq "$(grep -c '^NO_TMUX=1$' "$T/shell.env")" "1" "stale view outside the group: the plain shell runs"
assert_eq "$(grep -c 'exists' "$T/fallback.err")" "1" "stale view outside the group: the message names the cause"
rm -f "$T/shell.env"

# --- Task 4: terminals that open together never share a window
A="$H/projects/tsmu/iac"
tmux new-session -d -s tsmu-iac -c "$A"
touch "$T/delay"
export TMUX_ATTACH_TEST_DELAY="$T/delay"
tab_now "$A"; tab_now "$A"; tab_now "$A"
sleep 10
unset TMUX_ATTACH_TEST_DELAY; rm -f "$T/delay"
n_tabs_n_windows tsmu-iac 3
assert_eq "$(windows_of tsmu-iac)" "3" "race: the holder has exactly three windows"

# The lock stays busy: a plain shell, never an unlocked pick.
flock -o "$T/tmux-attach-tsmu-iac.lock" sleep 20 &
holder_pid=$!
sleep 0.5
( cd "$A" && SHELL="$T/fakeshell" "$ATTACH" 2>"$T/fallback.err" )
kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null
assert_eq "$(grep -c '^NO_TMUX=1$' "$T/shell.env")" "1" "busy lock: the plain shell runs with NO_TMUX=1"
assert_eq "$(grep -c 'lock' "$T/fallback.err")" "1" "busy lock: the message names the lock"
assert_eq "$(views_of tsmu-iac | grep -c .)" "3" "busy lock: no view was created"
rm -f "$T/shell.env"

# A server started under the lock must not keep it. A second shim on its
# own socket answers the bare server check while no server runs there, so
# the holder's new-session starts the server inside the locked region.
mkdir "$T/bin2"
cat > "$T/bin2/tmux" <<SHIM
#!/bin/sh
[ "\$*" = list-sessions ] && exit 0
exec /usr/bin/tmux -f "$T/tmux.conf" -S "$T/sock2" "\$@"
SHIM
chmod +x "$T/bin2/tmux"
O="$H/projects/oss/laravel/framework"
PATH="$T/bin2:$PATH" fake_client "$O" "$ATTACH"
sleep 1
assert_eq "$("$T/bin2/tmux" list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | awk '$1 ~ /^oss-laravel-framework_/ { print $2 }')" "1" "server under the lock: the terminal is attached to its view"
flock -n "$T/tmux-attach-oss-laravel-framework.lock" true
assert_eq "$?" "0" "server under the lock: the lock is free once the view exists"
"$T/bin2/tmux" kill-server 2>/dev/null

# --- Task 5: a drifted group and a missing holder (carried over from zed-term)
# tmux-resurrect restores a view first, so the group carries the view's
# name and the holder is a mere member.
L="$H/projects/personal/longmanme"; mkdir -p "$L"
tmux new-session -d -s personal-longmanme_555 -c "$L"
tmux new-window -d -t =personal-longmanme_555: -c "$L"
tmux new-session -d -t =personal-longmanme_555 -s personal-longmanme
assert_eq "$(group_of personal-longmanme)" "personal-longmanme_555" "precondition: the group carries a view's name"
tab "$L"; tab "$L"
n_tabs_n_windows personal-longmanme 2
assert_eq "$(windows_of personal-longmanme)" "2" "drifted group: free windows reused, none added"

# The holder is gone, two views survive under a group named after one of them.
O="$H/projects/oss/laravel/framework"
tmux new-session -d -s oss-laravel-framework_1 -c "$O"
tmux new-window -d -t =oss-laravel-framework_1: -c "$O"
tmux new-session -d -t =oss-laravel-framework_1 -s oss-laravel-framework_2
tab "$O"
assert_eq "$(group_of oss-laravel-framework)" "$(group_of oss-laravel-framework_1)" "missing holder: the recreated holder joins the surviving views"
assert_eq "$(windows_of oss-laravel-framework)" "2" "missing holder: the holder shares the surviving windows"
assert_eq "$(attached oss-laravel-framework)" "0" "missing holder: the recreated holder is not attached"

# A lone surviving view with no group at all: tmux-resurrect recreates a
# session whose group members are all gone as an ordinary session.
G="$H/projects/sgp/sgp"; mkdir -p "$G"
tmux new-session -d -s sgp-sgp_9 -c "$G"
tmux new-window -d -t =sgp-sgp_9: -c "$G"
tab "$G"
assert_eq "$(views_of sgp-sgp | grep -c .)" "2" "lone view: the ungrouped survivor and the terminal are the holder's members"
assert_eq "$(windows_of sgp-sgp)" "2" "lone view: the holder shares the survivor's windows"

teardown
finish
