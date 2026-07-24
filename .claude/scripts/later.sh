#!/usr/bin/env bash
#
# later.sh — parking lot for follow-up notes ("do this later").
#
# Captures throwaway follow-ups while you stay focused on the current task,
# then resurfaces them once the queue has settled. Two roles:
#
#   add <note>   appends a note to ./NOTES.local.md   (called by the /later command)
#   list         prints the pending (unchecked) queue  (called by /later with no args)
#   check        Stop-hook entry point: blocks once, after the queue has sat
#                unchanged for QUIET_SECONDS, so the assistant surfaces it and waits
#
# Design split follows the "hook owns WHEN, script owns WHAT" rule: settings.json
# decides the hook fires on Stop; this script decides whether anything is due.
#
# No `set -e`: this runs on EVERY turn end, and an accidental non-zero exit could
# be read as a blocking signal. Every path here exits 0 except a deliberate block,
# which is itself emitted as JSON with exit 0.

NOTES_FILE_NAME='NOTES.local.md'

# Surface a settled queue only after it has been untouched this long. Prevents
# nagging during a multi-turn task and stops /later from triggering an instant
# "do it now?" right after you park something. Override with LATER_QUIET_SECONDS.
QUIET_SECONDS="${LATER_QUIET_SECONDS:-300}"

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/later"
NOTE_HEADING='# Parked notes (`/later`)'

state_file_for() {
    local dir="$1"
    local key
    key=$(printf '%s' "$dir" | sha1sum | cut -d' ' -f1)
    printf '%s/%s' "$STATE_DIR" "$key"
}

# Unchecked checkbox lines ("- [ ] ..."), with leading "N:" line numbers.
unchecked_lines() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE '^[[:space:]]*-[[:space:]]\[[[:space:]]\]' "$file" || true
}

# Hash of just the pending note TEXT, order-independent, so cosmetic edits and
# checked-off history do not count as a "change".
queue_hash() {
    unchecked_lines "$1" | sed -E 's/^[0-9]+://' | sort | sha1sum | cut -d' ' -f1
}

# Strip "N:- [ ] " prefix down to a clean bullet for display.
as_bullets() {
    sed -E 's/^[0-9]+:[[:space:]]*-[[:space:]]\[[[:space:]]\][[:space:]]*/  \xe2\x80\xa2 /'
}

cmd_add() {
    local note="$*"
    if [ -z "$note" ]; then
        echo 'later: nothing to park (empty note)'
        return 0
    fi

    local file="$PWD/$NOTES_FILE_NAME"
    [ -f "$file" ] || printf '%s\n\n' "$NOTE_HEADING" > "$file"
    printf -- '- [ ] %s\n' "$note" >> "$file"

    # Seed the settle clock at parking time with reminded=0, so the note stays
    # silent right now but is still eligible to surface once QUIET_SECONDS pass.
    mkdir -p "$STATE_DIR"
    local sf; sf=$(state_file_for "$PWD")
    printf '%s\n%s\n%s\n' "$(queue_hash "$file")" "$(date +%s)" '0' > "$sf"

    echo "later: parked → $note"
}

cmd_list() {
    local file="$PWD/$NOTES_FILE_NAME"
    local lines; lines=$(unchecked_lines "$file")
    if [ -z "$lines" ]; then
        echo 'later: no parked notes'
        return 0
    fi
    echo 'Parked notes:'
    printf '%s\n' "$lines" | as_bullets
}

cmd_check() {
    local input cwd file
    input=$(cat)
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    [ -n "$cwd" ] || exit 0

    file="$cwd/$NOTES_FILE_NAME"
    [ -f "$file" ] || exit 0

    local lines; lines=$(unchecked_lines "$file")
    [ -n "$lines" ] || exit 0

    local cur_hash; cur_hash=$(queue_hash "$file")
    mkdir -p "$STATE_DIR"
    local sf; sf=$(state_file_for "$cwd")

    local prev_hash='' first_seen='' reminded=''
    if [ -f "$sf" ]; then
        prev_hash=$(sed -n '1p' "$sf")
        first_seen=$(sed -n '2p' "$sf")
        reminded=$(sed -n '3p' "$sf")
    fi
    [ -n "$first_seen" ] || first_seen=0
    [ -n "$reminded" ] || reminded=0

    local now; now=$(date +%s)

    # Queue changed since last seen → restart the settle window, stay silent.
    if [ "$cur_hash" != "$prev_hash" ]; then
        printf '%s\n%s\n%s\n' "$cur_hash" "$now" '0' > "$sf"
        exit 0
    fi

    # Already surfaced this exact queue, or still settling → stay silent.
    [ "$reminded" = '1' ] && exit 0
    [ $(( now - first_seen )) -lt "$QUIET_SECONDS" ] && exit 0

    # Due: record that we reminded, then block so the assistant surfaces it.
    printf '%s\n%s\n%s\n' "$cur_hash" "$first_seen" '1' > "$sf"

    local count; count=$(printf '%s\n' "$lines" | grep -c .)
    local body; body=$(printf '%s\n' "$lines" | as_bullets)
    local reason
    reason=$(printf 'There are %s parked note(s) in %s waiting to be revisited. Surface them to the user now and ask whether to start any. Do NOT begin work on a parked note without explicit confirmation. When a note is acted on, tick it off (change "- [ ]" to "- [x]") so it stops resurfacing.\n%s' \
        "$count" "$file" "$body")

    jq -n --arg r "$reason" '{decision:"block", reason:$r}'
    exit 0
}

case "${1:-}" in
    add)   shift; cmd_add "$@" ;;
    list)  cmd_list ;;
    check) cmd_check ;;
    *)     echo 'usage: later.sh {add <note> | list | check}' >&2; exit 1 ;;
esac
