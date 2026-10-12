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
export PATH="$T/bin:$PATH" SHELL=/bin/sh XDG_RUNTIME_DIR="$T"
unset TMUX TMUX_PANE
# script(1) copies its stdin into the pty and types the EOF character
# when stdin ends, which would close the shell a tab lands on; a FIFO
# opened read-write never ends.
mkfifo "$T/keep"
# The shim by path: once finish has removed $T, the trap's call fails instead of reaching the real tmux.
trap '"$T/bin/tmux" kill-server 2>/dev/null' EXIT

# A client that stays attached: script(1) gives tmux a pty and keeps it
# until the server goes away.
attach() { script -q -f -c "tmux $1" /dev/null <> "$T/keep" >/dev/null 2>&1 & }
names() { tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
attached() { tmux list-sessions -F '#{session_name} #{session_attached}' | awk -v n="$1" '$1 == n { print $2 }'; }
would() { "$@" | awk '/would kill/ { print $3 }' | sort | tr '\n' ' '; }

# hold: a holder with two windows, two restored views (detached, without
# destroy-unattached, exactly what tmux-resurrect recreates) and one live view.
tmux new-session -d -s hold
tmux new-window -t =hold
tmux new-session -d -t =hold -s hold_40
tmux new-session -d -t =hold -s hold_41
attach 'new-session -t =hold -s hold_99 \; set-option destroy-unattached on'
# orphan: a group whose holder is gone; both members are views.
tmux new-session -d -s orphan_1
tmux new-window -t =orphan_1
tmux new-session -d -t =orphan_1 -s orphan_2
# nested: a view whose parent is itself a view (the focus script used to
# name views after whichever member tmux resolved).
tmux new-session -d -s nest
tmux new-window -t =nest
tmux new-session -d -t =nest -s nest_7
tmux new-session -d -t =nest_7 -s nest_7_8
# idle: unattached, one idle shell. busy: the same, but something is running.
tmux new-session -d -s idle
tmux new-session -d -s busy
tmux send-keys -t busy 'sleep 300' Enter
sleep 1
assert_eq "$(attached hold_99)" "1" "precondition: the live view is attached"

# Everything above is seconds old: under the default grace nothing goes.
assert_eq "$(would "$REAPER")" "" "default grace: fresh views and holders are kept"

export TMUX_REAP_GRACE=0
assert_eq "$(would "$REAPER")" "hold_40 hold_41 idle nest_7 nest_7_8 orphan_1 " "no grace: dry run names the restored views, the nested views, one orphan and the idle shell"

"$REAPER" --apply >/dev/null
assert_eq "$(names)" "busy hold hold_99 nest orphan_2 " "apply keeps the holder, the live view, the surviving orphan, nest and the busy shell"
assert_eq "$(tmux list-windows -t =hold -F '#{window_id}' | wc -l)" "2" "killing views leaves the shared windows"
assert_eq "$(tmux list-windows -t =orphan_2 -F '#{window_id}' | wc -l)" "2" "the surviving orphan keeps both windows"
assert_eq "$(tmux list-windows -t =nest -F '#{window_id}' | wc -l)" "2" "nest keeps both windows"

# A holder older than the grace and a view between its claim and its
# attach: idle, unattached, but the view is younger than the grace, which
# protects both. Grace 3 keeps the test short.
export TMUX_REAP_GRACE=3
tmux new-session -d -s fresh
sleep 4
tmux new-session -d -t =fresh -s fresh_5
assert_eq "$(would "$REAPER")" "" "grace: an old holder is kept while its view is younger than the grace"
sleep 4
assert_eq "$(would "$REAPER")" "fresh fresh_5 " "grace passed: the idle pair goes"
unset TMUX_REAP_GRACE
assert_eq "$(would "$REAPER")" "" "default grace: a pair seconds old is kept"
TMUX_REAP_GRACE=0 "$REAPER" --apply >/dev/null
assert_eq "$(names)" "busy hold hold_99 nest orphan_2 " "no grace: the fresh pair is idle and goes"

# The reaper defers to tmux-attach: while a terminal holds a key's lock
# (holder check, pick, claim), nothing of that key is killed.
tmux new-session -d -s locked
tmux new-session -d -t =locked -s locked_3
flock -o "$XDG_RUNTIME_DIR/tmux-attach-locked.lock" sleep 8 &
lock_pid=$!
sleep 0.5
TMUX_REAP_GRACE=0 "$REAPER" --apply >/dev/null
assert_eq "$(names)" "busy hold hold_99 locked locked_3 nest orphan_2 " "lock held: the key's sessions are kept"
kill "$lock_pid"; wait "$lock_pid" 2>/dev/null
TMUX_REAP_GRACE=0 "$REAPER" --apply >/dev/null
assert_eq "$(names)" "busy hold hold_99 nest orphan_2 " "lock free: the idle pair goes"

# A group without a holder whose other member goes while the reaper waits
# on the key's lock: the view is now the group's last member, so it is
# kept with its windows and its work. The lock is held on a test-shell fd
# that the reaper does not inherit, and released well inside the reaper's
# lock wait, so the view is kept by the re-read, not by a busy lock.
tmux new-session -d -s lone_1
tmux new-window -t =lone_1
tmux send-keys -t =lone_1: 'sleep 300' Enter
tmux new-session -d -t =lone_1 -s lone_2
exec 8>"$XDG_RUNTIME_DIR/tmux-attach-lone.lock"
flock 8
TMUX_REAP_GRACE=0 "$REAPER" --apply >/dev/null 8>&- &
reaper_pid=$!
sleep 0.5
assert_ok "precondition: the reaper waits on the lock" kill -0 "$reaper_pid"
tmux kill-session -t =lone_2
exec 8>&-
wait "$reaper_pid"
assert_eq "$(names)" "busy hold hold_99 lone_1 nest orphan_2 " "member gone under the lock: the last view is kept"
assert_eq "$(tmux list-windows -t =lone_1 -F '#{window_id}' 2>/dev/null | wc -l)" "2" "the last view keeps both windows"
tmux kill-session -t =lone_1 2>/dev/null

"$T/bin/tmux" kill-server 2>/dev/null; wait
finish
