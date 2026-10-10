#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HOME/.claude/scripts/tests/assert.sh"
ZED_TERM="$HERE/../zed-term"

# Private tmux server through a PATH shim; see tmux-reap.test.sh.
T="$(mktemp -d)"; TMPDIRS+=("$T")
mkdir "$T/bin"
printf '#!/bin/sh\nexec /usr/bin/tmux -f /dev/null -S "%s/sock" "$@"\n' "$T" > "$T/bin/tmux"
chmod +x "$T/bin/tmux"
export PATH="$T/bin:$PATH" SHELL=/bin/sh
unset TMUX TMUX_PANE
# script(1) copies its stdin into the pty and types the EOF character
# when stdin ends, which would close the shell a tab lands on; a FIFO
# opened read-write never ends.
mkfifo "$T/keep"
trap 'tmux kill-server 2>/dev/null' EXIT

# A Zed tab: zed-term started in the project directory on its own pty,
# one second apart, as Zed opens tabs by hand.
tab() { ( cd "$1" && script -q -f -c "$ZED_TERM" /dev/null <> "$T/keep" >/dev/null 2>&1 ) & sleep 1; }
shown() { # group -> current window of every attached member
    tmux list-sessions -F '#{session_group} #{session_attached} #{window_id}' \
        | awk -v g="$1" '$1 == g && $2 > 0 { print $3 }' | sort | tr '\n' ' '
}
group_of() { tmux list-sessions -F '#{session_name} #{session_group}' | awk -v n="$1" '$1 == n { print $2 }'; }
windows_of() { tmux list-windows -t "=$1" -F '#{window_id}' | wc -l; }
two_tabs_two_windows() { # group
    local s; s="$(shown "$1")"
    assert_eq "$(printf '%s' "$s" | wc -w)" "2" "$1: two tabs attached"
    # shellcheck disable=SC2086
    assert_eq "$(printf '%s\n' $s | sort -u | wc -l)" "2" "$1: the tabs show different windows"
}

# Plain holder: the group carries the holder's name.
mkdir "$T/norm"
tmux new-session -d -s zed-norm
tmux new-window -t =zed-norm
tab "$T/norm"; tab "$T/norm"
two_tabs_two_windows zed-norm
assert_eq "$(windows_of zed-norm)" "2" "zed-norm: free windows reused, none added"

# Restored group: tmux-resurrect recreated a view first, so the group
# carries the view's name and the holder is a mere member.
mkdir "$T/proj"
tmux new-session -d -s zed-proj-555
tmux new-window -t =zed-proj-555
tmux new-session -d -t =zed-proj-555 -s zed-proj
assert_eq "$(group_of zed-proj)" "zed-proj-555" "precondition: the group carries a view's name"
tab "$T/proj"; tab "$T/proj"
two_tabs_two_windows zed-proj-555
assert_eq "$(windows_of zed-proj)" "2" "zed-proj: free windows reused, none added"

# Holder gone, two views survive under a group named after one of them.
mkdir "$T/other"
tmux new-session -d -s zed-other-1
tmux new-window -t =zed-other-1
tmux new-session -d -t =zed-other-1 -s zed-other-2
tab "$T/other"
assert_eq "$(group_of zed-other)" "$(group_of zed-other-1)" "zed-other: the recreated holder joins the surviving views"
assert_eq "$(windows_of zed-other)" "2" "zed-other: the holder shares the surviving windows"

tmux kill-server 2>/dev/null; wait
finish
