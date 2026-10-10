#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HOME/.claude/scripts/tests/assert.sh"
REAPER="$HERE/../tmux-reap"

# Every tmux call, the reaper's own included, goes to a private server: a
# shim first on PATH pins the socket and skips ~/.tmux.conf (plugins, the
# continuum restore). TMUX_TMPDIR is not enough: tmux 3.4 falls back to
# /tmp when that directory is missing.
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

# A client that stays attached: script(1) gives tmux a pty and keeps it
# until the server goes away.
attach() { script -q -f -c "tmux $1" /dev/null <> "$T/keep" >/dev/null 2>&1 & }
names() { tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
attached() { tmux list-sessions -F '#{session_name} #{session_attached}' | awk -v n="$1" '$1 == n { print $2 }'; }

# hold: a holder with two windows, two restored views (detached, without
# destroy-unattached, exactly what tmux-resurrect recreates) and one live view.
tmux new-session -d -s hold
tmux new-window -t =hold
tmux new-session -d -t =hold -s hold-40
tmux new-session -d -t =hold -s hold-41
attach 'new-session -t =hold -s hold-99 \; set-option destroy-unattached on'
# orphan: a group whose holder is gone; nothing says which member owns it.
tmux new-session -d -s orphan-1
tmux new-window -t =orphan-1
tmux new-session -d -t =orphan-1 -s orphan-2
# idle: unattached, one idle shell. busy: the same, but something is running.
tmux new-session -d -s idle
tmux new-session -d -s busy
tmux send-keys -t busy 'sleep 300' Enter
sleep 1
assert_eq "$(attached hold-99)" "1" "precondition: the live view is attached"

would="$("$REAPER" | awk '/would kill/ { print $3 }' | sort | tr '\n' ' ')"
assert_eq "$would" "hold-40 hold-41 idle " "dry run names the restored views and the idle shell"

"$REAPER" --apply >/dev/null
assert_eq "$(names)" "busy hold hold-99 orphan-1 orphan-2 " "apply keeps the holder, the live view, the orphans and the busy shell"
assert_eq "$(tmux list-windows -t =hold -F '#{window_id}' | wc -l)" "2" "killing views leaves the shared windows"

tmux kill-server 2>/dev/null; wait
finish
