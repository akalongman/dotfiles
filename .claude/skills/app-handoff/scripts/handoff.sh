#!/usr/bin/env bash
# Writes and checks the handoff files of the app-handoff skill.
#
#   handoff.sh new [--source <text>] [<topic words>...]
#       Creates YYYY-MM-DD-HHMM-<project>-<topic>.md in the handoff folder,
#       never over an existing file, with a header read from the live
#       checkout and a <!-- FILL --> marker under every section heading, and
#       prints the file's absolute path. Where git is missing, or fails
#       with anything other than "not a git repository" when asked whether
#       the folder is in a repository (a repository it refuses to read, for
#       one), it writes nothing and exits 1 with the shell's or git's
#       message.
#   handoff.sh check <file>
#       Prints ok when no marker is left, every section heading is there
#       outside code fences with a non-blank line under it, every code fence
#       is closed and the snapshot notice is in place; otherwise prints one
#       problem per line on stderr and exits 1. A fence still open at the
#       end of the file is reported with the line it opened on.
#
# Usage errors, a missing or unreadable file among them, exit 2.
# HANDOFF_DIR replaces the folder (default ~/.agents/app/handoffs);
# HANDOFF_NOW (YYYY-MM-DD-HHMM, tests only) replaces the clock for the
# file name and the Written line.

set -euo pipefail

readonly USAGE='usage: handoff.sh new [--source <text>] [<topic words>...] | handoff.sh check <file>'
readonly MARKER='<!-- FILL -->'
# check finds the notice by the start of its first line.
readonly NOTICE_START='> This is a snapshot.'
readonly NOTICE="$NOTICE_START Before acting on it, compare the directory, branch,
> commit and uncommitted files recorded above with the live checkout, and
> tell the owner about any difference first."
readonly SECTIONS=(
    'Goal'
    'State'
    'Decisions'
    'Ruled out'
    'Facts established'
    "Owner's instructions from this session"
    'Open questions'
    'Next steps'
    'In flight'
    'Pointers'
)
# Uncommitted paths listed in the header; the rest are only counted.
readonly PATHS_SHOWN=50
# A level 1 or 2 heading ends the section above it; a level 3 heading is
# part of it. A code fence opens on three or more backticks or tildes.
readonly HEADING_RE='^##?( |$)'
readonly FENCE_RE='^(`{3,}|~{3,})(.*)$'

usage_error() { # message
    printf 'handoff.sh: %s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

die() { # message
    printf 'handoff.sh: %s\n' "$1" >&2
    exit 1
}

# Prints <text> as a file name part: lowercase ASCII, each run of other
# characters one hyphen, no hyphen at either end, at most <max> characters,
# or <fallback> when nothing is left.
slug() { # text max fallback
    local s
    s="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
        LC_ALL=C tr -cs '[:lower:][:digit:]' '-')"
    s="${s#-}"
    s="${s%-}"
    s="${s:0:$2}"
    s="${s%-}"
    printf '%s\n' "${s:-$3}"
}

# Succeeds when the working directory is in a git work tree that does not
# ignore it. A folder its work tree ignores counts as outside a repository:
# with dotfiles kept in $HOME and everything else ignored, every plain
# folder under the home folder is inside that work tree, and ignored by it.
# The top of a work tree is never ignored. Below it the folder is checked
# from the top as ./<path> with no trailing slash: with the slash a "dir/*"
# pattern would match the folder itself, and the ./ keeps a leading colon
# from reading as pathspec magic.
# Only git's "not a git repository" answer, read in the C locale because git
# translates its messages, is kept off stderr. Any other failure, such as a
# repository git refuses to read (its ownership or its format) or no git
# installed, ends the script with git's or the shell's message, since a
# header calling that folder no repository could be untrue.
in_repository() {
    local err prefix top
    if ! err="$(LC_ALL=C git rev-parse --git-dir 2>&1 >/dev/null)"; then
        if [[ $err == *'not a git repository'* ]]; then return 1; fi
        die "$err"
    fi
    [ "$(git rev-parse --is-inside-work-tree)" = true ] || return 1
    prefix="$(git rev-parse --show-prefix)"
    [ -n "$prefix" ] || return 0
    top="$(git rev-parse --show-toplevel)"
    if git -C "$top" check-ignore -q -- "./${prefix%/}"; then return 1; fi
    return 0
}

cmd_new() { # [--source <text>] [<topic words>...]
    local source='' topic title clock now offset dir cwd
    local repo='not a git repository' branch='n/a' commit='n/a' uncommitted='n/a'
    local project common status listed='' path base n i section
    local -a changes=()

    if [ "${1-}" = --source ]; then
        [ $# -ge 2 ] || usage_error '--source needs a value'
        source="$2"
        shift 2
    fi
    topic="$*"
    title=untitled
    if [[ $topic == *[![:space:]]* ]]; then title="$topic"; fi

    # One clock reading for the name and the Written line.
    clock="$(date '+%Y-%m-%d-%H%M %z')"
    now="${clock% *}"
    offset="${clock#* }"
    if [ -n "${HANDOFF_NOW-}" ]; then
        [[ $HANDOFF_NOW =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] ||
            usage_error 'HANDOFF_NOW must be YYYY-MM-DD-HHMM'
        now="$HANDOFF_NOW"
    fi

    # The whole header is read before the file exists, so a failing git
    # call leaves no half-written handoff behind.
    cwd="$(pwd -P)"
    project="$cwd"
    if in_repository; then
        repo="$(git rev-parse --show-toplevel)"
        # A linked worktree is named after the project that holds the
        # common .git directory, not after the worktree's own folder.
        common="$(git rev-parse --path-format=absolute --git-common-dir)"
        project="$repo"
        if [ "${common##*/}" = .git ]; then project="${common%/*}"; fi
        branch="$(git symbolic-ref -q --short HEAD)" || branch=detached
        if git rev-parse -q --verify HEAD >/dev/null; then
            commit="$(git log -1 --no-show-signature --format='%h %s' HEAD)"
        else
            commit='no commits yet'
        fi
        status="$(git --no-optional-locks status --porcelain)"
        if [ -n "$status" ]; then mapfile -t changes <<<"$status"; fi
        uncommitted="${#changes[@]} file(s)"
        for ((i = 0; i < ${#changes[@]} && i < PATHS_SHOWN; i++)); do
            # Drop the two status characters and the space after them.
            listed+="  - ${changes[i]:3}"$'\n'
        done
        if [ "${#changes[@]}" -gt "$PATHS_SHOWN" ]; then
            listed+="  - and $((${#changes[@]} - PATHS_SHOWN)) more"$'\n'
        fi
    fi
    project="$(slug "${project##*/}" 30 project)"

    dir="${HANDOFF_DIR:-$HOME/.agents/app/handoffs}"
    case $dir in /*) ;; *) dir="$cwd/$dir" ;; esac
    mkdir -p -- "$dir"

    # Exclusive create: a name already taken, even by a file created a
    # moment ago by another session, moves on to -2, -3 and so on.
    base="$dir/$now-$project-$(slug "$topic" 40 handoff)"
    path="$base.md"
    n=1
    while ! (set -o noclobber && : >"$path") 2>/dev/null; do
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then die "cannot create $path"; fi
        n=$((n + 1))
        path="$base-$n.md"
    done

    {
        printf '# Handoff: %s\n\n' "$title"
        printf -- '- Written: %s %s:%s %s\n' "${now:0:10}" "${now:11:2}" "${now:13:2}" "$offset"
        printf -- '- Directory: %s\n' "$cwd"
        printf -- '- Repository: %s\n' "$repo"
        printf -- '- Branch: %s\n' "$branch"
        printf -- '- Commit: %s\n' "$commit"
        printf -- '- Uncommitted: %s\n' "$uncommitted"
        printf '%s' "$listed"
        printf -- '- Source: %s\n\n' "${source:-unknown}"
        printf '%s\n' "$NOTICE"
        for section in "${SECTIONS[@]}"; do
            printf '\n## %s\n\n%s\n' "$section" "$MARKER"
        done
    } >"$path"
    printf '%s\n' "$path"
}

cmd_check() { # <file>
    [ $# -eq 1 ] || usage_error 'check takes one file'
    [ -f "$1" ] || usage_error "no such file: $1"
    [ -r "$1" ] || usage_error "cannot read: $1"
    local line lineno=0 fence='' fence_at=0 unfilled=0 notice=false current=-1 i
    # Indexed like SECTIONS: the heading was seen, and a non-blank line
    # (the marker counts) stood under it.
    local -a found=() filled=() problems=()

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        if [[ $line == *"$MARKER"* ]]; then unfilled=$((unfilled + 1)); fi
        if [[ $line == "$NOTICE_START"* ]]; then notice=true; fi
        if [ -z "$fence" ] && [[ $line =~ $HEADING_RE ]]; then
            current=-1
            for i in "${!SECTIONS[@]}"; do
                if [ "$line" = "## ${SECTIONS[i]}" ]; then
                    current=$i
                    found[i]=1
                fi
            done
            continue
        fi
        # A fence closes on a run of its own character at least as long as
        # the one that opened it, with nothing after it.
        if [[ $line =~ $FENCE_RE ]]; then
            if [ -z "$fence" ]; then
                fence="${BASH_REMATCH[1]}"
                fence_at=$lineno
            elif [[ ${BASH_REMATCH[1]} == "$fence"* && ${BASH_REMATCH[2]} != *[![:space:]]* ]]; then
                fence=''
            fi
        fi
        if [ "$current" -ge 0 ] && [[ $line == *[![:space:]]* ]]; then filled[current]=1; fi
    done <"$1"

    if [ "$unfilled" -gt 0 ]; then problems+=("$unfilled unfilled section(s)"); fi
    # Named before the sections it hides, so the cause is read first.
    if [ -n "$fence" ]; then
        problems+=("unclosed code fence: line $fence_at (the rest of the file reads as code)")
    fi
    for i in "${!SECTIONS[@]}"; do
        if [ -z "${found[i]-}" ]; then
            problems+=("missing section: ${SECTIONS[i]}")
        elif [ -z "${filled[i]-}" ]; then
            problems+=("empty section: ${SECTIONS[i]}")
        fi
    done
    if ! "$notice"; then problems+=('missing snapshot notice'); fi

    if [ "${#problems[@]}" -gt 0 ]; then
        printf '%s\n' "${problems[@]}" >&2
        exit 1
    fi
    printf 'ok\n'
}

main() {
    # Folders the script creates get mode 700, files mode 600.
    umask 077
    case ${1-} in
        new) shift && cmd_new "$@" ;;
        check) shift && cmd_check "$@" ;;
        '') usage_error 'no subcommand given' ;;
        *) usage_error "unknown subcommand: $1" ;;
    esac
}

main "$@"
