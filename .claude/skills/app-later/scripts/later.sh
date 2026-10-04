#!/usr/bin/env bash
#
# later.sh: parking lot for follow-up notes, kept as a per-project backlog.
#
#   add <note>       append a stamped note to the project's NOTES.local.md
#   list             print the open notes, numbered, with their age
#   done <n>...      tick the listed notes to [x]
#   drop <n>...      delete the listed notes
#   all              one line per queue with open notes under the scan roots
#   session-start    SessionStart hook entry point: a user-visible count line,
#                    plus the oldest notes once per LATER_DIGEST_DAYS
#
# The hook owns WHEN (hooks/hooks.json fires this on session start); this
# script owns WHAT. No `set -e`: the hook path must exit 0 whatever happens,
# so a broken reminder can never delay or block a session.

NOTES_FILE_NAME='NOTES.local.md'
# shellcheck disable=SC2016  # the backticks are literal markdown
NOTE_HEADING='# Parked notes (`/later`)'

DIGEST_DAYS="${LATER_DIGEST_DAYS:-7}"
DIGEST_COUNT="${LATER_DIGEST_COUNT:-5}"
DISPLAY_WIDTH="${LATER_DISPLAY_WIDTH:-100}"   # session-start only
SCAN_DEPTH=6

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/later/v2"

OPEN_RE='^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*(.*)$'
STAMP_RE=' \(([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2})\)$'
STAMP_LEN=19   # length of " (YYYY-MM-DD HH:MM)"

# LATER_NOW (epoch seconds) replaces the clock, for tests.
now() { printf '%s' "${LATER_NOW:-$(date +%s)}"; }

# Root of the main checkout containing <dir>, or nothing outside a work tree.
# A linked worktree resolves to the main checkout through the common git dir.
project_root() {
    local dir="$1" top gitdir common
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
    gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 0
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    if [ "$gitdir" != "$common" ]; then
        dirname "$common"
    else
        printf '%s\n' "$top"
    fi
}

# Queue file for <dir>. $HOME is itself a git repository on a dotfiles setup,
# so a root equal to $HOME is discarded unless <dir> is $HOME; otherwise every
# directory under it without a repository of its own would share one queue.
queue_file() {
    local dir home root
    dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    home=$(cd "$HOME" 2>/dev/null && pwd -P)
    root=$(project_root "$dir")
    if [ -n "$root" ] && [ "$root" = "$home" ] && [ "$dir" != "$home" ]; then
        root=''
    fi
    printf '%s/%s\n' "${root:-$dir}" "$NOTES_FILE_NAME"
}

queue_label() { basename "$(dirname "$1")"; }

state_key() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

# One row per open note: "<position>\t<file line>\t<stamp epoch>\t<text>".
# The epoch is 0 for an undated note; the stamp is stripped from the text.
open_notes() {
    local file="$1" i=0 raw n text epoch
    [ -f "$file" ] || return 0
    while IFS= read -r raw; do
        n=${raw%%:*}
        [[ ${raw#*:} =~ $OPEN_RE ]] || continue
        text=${BASH_REMATCH[1]}
        epoch=0
        if [[ $text =~ $STAMP_RE ]]; then
            epoch=$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null) || epoch=0
            [ "$epoch" != 0 ] && text=${text:0:${#text}-STAMP_LEN}
        fi
        i=$((i + 1))
        printf '%s\t%s\t%s\t%s\n' "$i" "$n" "$epoch" "$text"
    done < <(grep -nE "$OPEN_RE" "$file")
}

row_count() { [ -n "$1" ] && printf '%s\n' "$1" | grep -c . || printf '0\n'; }

age_label() {
    local epoch="$1" days
    [ "$epoch" = 0 ] && { printf 'undated'; return; }
    days=$(( ($(now) - epoch) / 86400 ))
    if [ "$days" -le 0 ]; then printf 'today'; else printf '%sd' "$days"; fi
}

# Clip <text> to <width> characters, marking the cut with "...".
clip() {
    local text="$1" width="$2"
    if [ "${#text}" -gt "$width" ]; then
        printf '%s...' "${text:0:width-3}"
    else
        printf '%s' "$text"
    fi
}

# Rows on stdin -> " N. text (age)", N being the note's position in the queue.
# With a width, each text is clipped to it.
numbered() {
    local width="${1:-}" i n epoch text
    while IFS=$'\t' read -r i n epoch text; do
        [ -n "$width" ] && text=$(clip "$text" "$width")
        printf '%2d. %s (%s)\n' "$i" "$text" "$(age_label "$epoch")"
    done
}

# Run a command holding the queue's lock. Without flock, run it unlocked.
with_lock() {
    local file="$1"; shift
    mkdir -p "$STATE_DIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1 && [ -d "$STATE_DIR" ]; then
        (
            flock -w 5 9 || { echo 'later: the queue is locked by another writer' >&2; exit 1; }
            "$@"
        ) 9>"$STATE_DIR/$(state_key "$file").lock"
    else
        "$@"
    fi
}

append_note() {
    local file="$1" line="$2"
    [ -f "$file" ] || printf '%s\n\n' "$NOTE_HEADING" > "$file"
    # A hand-edited file may lack its final newline; do not glue two notes.
    [ -n "$(tail -c1 "$file")" ] && printf '\n' >> "$file"
    printf -- '- [ ] %s\n' "$line" >> "$file"
}

cmd_add() {
    local note file stamp
    note=$(printf '%s' "$*" | tr '\n\r\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    if [ -z "$note" ]; then
        echo 'later: nothing to park (empty note)'
        return 0
    fi
    file=$(queue_file "$PWD") || { echo 'later: cannot resolve the queue here' >&2; return 1; }
    stamp=$(date -d "@$(now)" '+%Y-%m-%d %H:%M')
    with_lock "$file" append_note "$file" "$note ($stamp)" || return 1
    echo "later: parked -> $note"
}

cmd_list() {
    local file rows
    file=$(queue_file "$PWD") || { echo 'later: no parked notes'; return 0; }
    rows=$(open_notes "$file")
    if [ -z "$rows" ]; then
        echo 'later: no parked notes'
        return 0
    fi
    printf '%s: %s parked\n' "$(queue_label "$file")" "$(row_count "$rows")"
    printf '%s\n' "$rows" | numbered
}

close_notes() {
    local mode="$1" file="$2"; shift 2
    local rows count n lines tmp verb target
    # Rewrite beside the real file, so a symlinked queue stays a symlink.
    target=$(readlink -f "$file" 2>/dev/null) || target=$file
    rows=$(open_notes "$file")
    count=$(row_count "$rows")
    for n in "$@"; do
        case "$n" in
            ''|*[!0-9]*|??????????*) echo "later: not a note number: $n" >&2; return 1 ;;
        esac
        if [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then
            echo "later: no note $n (the queue has $count open)" >&2
            return 1
        fi
    done
    lines=$(for n in "$@"; do
        printf '%s\n' "$rows" | awk -F'\t' -v i="$n" '$1 == i + 0 { print $2 }'
    done | sort -un | tr '\n' ' ')
    tmp=$(mktemp "$target.XXXXXX") || { echo 'later: cannot write beside the queue' >&2; return 1; }
    if awk -v lines="$lines" -v mode="$mode" '
            BEGIN { split(lines, a, " "); for (k in a) pick[a[k]] = 1 }
            (NR in pick) { if (mode == "drop") next; sub(/\[[[:space:]]\]/, "[x]") }
            { print }
        ' "$target" > "$tmp" && chmod --reference="$target" "$tmp" && mv "$tmp" "$target"; then
        verb='done'; [ "$mode" = drop ] && verb='dropped'
        for n in "$@"; do
            printf '%s\n' "$rows" | awk -F'\t' -v i="$n" -v v="$verb" '$1 == i + 0 { print "later: " v " -> " $4 }'
        done
    else
        rm -f "$tmp"
        echo 'later: could not rewrite the queue, nothing changed' >&2
        return 1
    fi
}

cmd_close() {
    local mode="$1" file; shift
    [ $# -gt 0 ] || { echo "later: $mode needs at least one note number" >&2; return 1; }
    file=$(queue_file "$PWD") || { echo 'later: cannot resolve the queue here' >&2; return 1; }
    [ -f "$file" ] || { echo 'later: no parked notes' >&2; return 1; }
    with_lock "$file" close_notes "$mode" "$file" "$@"
}

find_queues() {
    local roots="${LATER_ROOTS:-$HOME}" root
    local IFS=':'
    for root in $roots; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth "$SCAN_DEPTH" \
            \( -name node_modules -o -name vendor -o -name .git -o -name .worktrees \) -prune \
            -o -xtype f -name "$NOTES_FILE_NAME" -print 2>/dev/null
    done | sort -u
}

cmd_all() {
    local file rows count oldest label path out='' total=0 queues=0
    while IFS= read -r file; do
        rows=$(open_notes "$file")
        [ -n "$rows" ] || continue
        count=$(row_count "$rows")
        oldest=$(printf '%s\n' "$rows" | cut -f3 | sort -n | head -n1)
        label=$(age_label "$oldest")
        path=$(dirname "$file")
        case "$path" in "$HOME"*) path="~${path#"$HOME"}" ;; esac
        out+=$(printf '%s\t%s\t%s' "$count" "$label" "$path")$'\n'
        total=$((total + count)); queues=$((queues + 1))
    done < <(find_queues)
    if [ "$queues" -eq 0 ]; then
        echo 'later: no parked notes'
        return 0
    fi
    printf '%s' "$out" | sort -t$'\t' -k1,1nr -k3,3 | while IFS=$'\t' read -r count label path; do
        printf '%3d open, oldest %-8s  %s\n' "$count" "$label" "$path"
    done
    printf '%3d open in %d queues\n' "$total" "$queues"
}

# How the display reaches the user. Kept in one place: it is the only line
# that changes if the message has to go into model context instead.
emit() { jq -n --arg m "$1" '{systemMessage: $m}'; }

num_or_zero() { case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

cmd_session_start() {
    command -v jq >/dev/null 2>&1 || return 0
    local input cwd src agent file rows count sf shown=0 digest=0 t floor
    input=$(cat)
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    src=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)
    agent=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
    [ -n "$cwd" ] && [ "$src" = 'startup' ] && [ -z "$agent" ] || return 0
    [ "${CLAUDE_CODE_ENTRYPOINT:-}" = 'cli' ] || return 0

    file=$(queue_file "$cwd") || return 0
    rows=$(open_notes "$file")
    [ -n "$rows" ] || return 0
    count=$(row_count "$rows")

    mkdir -p "$STATE_DIR" 2>/dev/null
    sf="$STATE_DIR/$(state_key "$file")"
    if [ -r "$sf" ]; then
        shown=$(num_or_zero "$(sed -n 1p "$sf")")
        digest=$(num_or_zero "$(sed -n 2p "$sf")")
    fi
    t=$(now)

    # New = stamped at or after the MINUTE of the last display. Stamps have
    # minute precision, so comparing against the exact second would skip a
    # note parked later in the same minute as a display.
    floor=$(( shown - shown % 60 ))
    local new new_count msg
    new=$(printf '%s\n' "$rows" | awk -F'\t' -v f="$floor" '$3 != 0 && $3 >= f')
    new_count=$(row_count "$new")

    msg="later: $count parked in $(queue_label "$file")"
    if [ "$new_count" -gt 0 ]; then
        local names='' text
        while IFS=$'\t' read -r _ _ _ text; do
            names+="${names:+; }$(clip "$text" "$DISPLAY_WIDTH")"
        done < <(printf '%s\n' "$new" | head -n3)
        msg+=", $new_count new: $names"
        [ "$new_count" -gt 3 ] && msg+=", +$((new_count - 3)) more"
    fi

    if [ $(( t - digest )) -ge $(( DIGEST_DAYS * 86400 )) ]; then
        msg+=$'\n'"Oldest notes:"$'\n'
        msg+=$(printf '%s\n' "$rows" | sort -s -t$'\t' -k3,3n | head -n "$DIGEST_COUNT" | numbered "$DISPLAY_WIDTH")
        digest=$t
    fi

    emit "$msg"
    { printf '%s\n%s\n' "$t" "$digest" > "$sf"; } 2>/dev/null
    return 0
}

usage() {
    echo 'usage: later.sh {add <note> | list | done <n>... | drop <n>... | all | session-start}'
}

case "${1:-}" in
    add)           shift; cmd_add "$@" ;;
    list)          cmd_list ;;
    done|drop)     cmd_close "$@" ;;
    all)           cmd_all ;;
    session-start) cmd_session_start; exit 0 ;;
    *)             usage >&2; exit 1 ;;
esac
