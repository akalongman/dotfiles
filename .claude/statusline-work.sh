#!/bin/bash
# Status line helper: names the plan or OpenSpec change a session works on.
#
# Evidence comes only from tool calls in the session's own transcript, and
# only from these input fields: file_path of Read, Edit, Write and
# NotebookEdit; path of Grep and Glob; command of Bash; prompt of Agent; args
# of Skill. File bodies (content, old_string, new_string), descriptions and
# tool results never count, and neither do the heredoc bodies inside a Bash
# command, since file writes go through them. Transcript text is matched as
# data and never evaluated by a shell.
#
# Sourcing the file defines the work_* functions only; executing it runs
# work_main.

# A token free of whitespace, quotes and backticks that ends in a change
# directory, a plan file or an apply-run workspace directory.
_work_seg="[^/[:space:]\"'\`]+"
readonly WORK_PATTERN="[^[:space:]\"'\`]*(openspec/changes/${_work_seg}/|docs/superpowers/plans/${_work_seg}\\.md|docs/plans/${_work_seg}\\.md|\\.claude/docs/plans/${_work_seg}\\.md|\\.superpowers/sdd/${_work_seg}/)"
unset _work_seg

# Turns a byte range of the transcript into "pos<TAB>field<TAB>value<TAB>cwd"
# lines, one per evidence field that could hold a match. Only lines ending
# in a newline are read, so a partly written last line is skipped. pos is
# the line's 0-based index in the range. A Bash command loses its heredoc
# bodies first. Whitespace control characters in a value become spaces
# (they separate tokens either way); a value holding a NUL is dropped, and
# a cwd holding a control character becomes empty, so no field can break
# the line framing. Every step is linear in the value's length: jq's gsub,
# and its join over many items, are quadratic, so neither is used here.
IFS= read -r -d '' WORK_EVIDENCE_JQ <<'EOF' || true
def evidence_field:
  {Read: "file_path", Edit: "file_path", Write: "file_path",
   NotebookEdit: "file_path", Grep: "path", Glob: "path",
   Bash: "command", Agent: "prompt", Skill: "args"}[.] // empty;
def marked: test("openspec/changes/|docs/(superpowers/)?plans/|\\.superpowers/sdd/");
# join in linear time: add appends to its accumulator in place.
def joined($sep): [.[0] // empty, (.[1:][] | $sep + .)] | add // "";
# The heredoc operators of one line, in order: <<WORD, <<-WORD, <<'WORD',
# <<"WORD" and <<\WORD, with optional blanks after the <<, never the <<< of
# a here-string.
def heredoc_ops:
  [match("(?<!<)<<(-?)[ \\t]*(?:'([^']+)'|\"([^\"]+)\"|\\\\?([^\\s|&;()<>'\"\\\\]+))"; "g")
   | (.captures | map(.string)) as $c
   | {dash: ($c[0] == "-"), word: ([$c[1], $c[2], $c[3]] | map(strings) | first)}];
# Drops each heredoc body, from the line after its operator through its
# closing line; the operator's own line stays. A line holding more than 16
# "<<" opens a body that runs to the end, which bounds the operator queue.
def strip_heredocs:
  if contains("<<") | not then .
  else
    [foreach split("\n")[] as $line ({q: [], keep: true};
        if (.q | length) == 0 then
          .keep = true
          | .q = if $line | contains("<<") | not then []
                 elif ($line | indices("<<") | length) > 16 then [{dash: false, word: null}]
                 else $line | heredoc_ops end
        else
          .keep = false
          | if (if .q[0].dash then $line | sub("^\t+"; "") else $line end) == .q[0].word
            then .q |= .[1:] else . end
        end;
        if .keep then $line else empty end)]
    | joined("\n")
  end;
def spaced: reduce ("\t", "\n", "\u000b", "\f", "\r") as $c (.; split($c) | joined(" "));
(split("\n") | .[:-1]) as $lines
| range(0; $lines | length) as $pos
| $lines[$pos] | fromjson?
| select(type == "object" and .type == "assistant")
| (.cwd | if type == "string" and (test("[\\x00-\\x1f\\x7f]") | not) then . else "" end) as $cwd
| .message | objects | .content | arrays | .[]
| objects | select(.type == "tool_use")
| (.name | strings | evidence_field) as $field
| .input | objects | .[$field] | strings
| select(marked)
| select(test("\\x00") | not)
| if $field == "command" then strip_heredocs | select(marked) else . end
| [($pos | tostring), $field, spaced, $cwd] | join("\t")
EOF
readonly WORK_EVIDENCE_JQ

# work_scan_range TRANSCRIPT FROM TO
# Prints one "pos<TAB>abs<TAB>raw<TAB>cwd" line per occurrence in the bytes
# [FROM, TO) of TRANSCRIPT, oldest first. pos is the record's 0-based line
# number in the range, abs is 1 when raw starts with / or ~/, raw is the
# matched token cut after the pattern, cwd is the record's cwd or empty.
# A file_path or path value is one token, matched from its first
# character. Free text yields every match, except relative ones when the
# text holds "cd ", since their base directory is unknown. Exits 0.
work_scan_range() {
    local transcript="$1" from="$2" to="$3"
    local anchored="^($WORK_PATTERN)" number='^(0|[1-9][0-9]*)$'
    local pos field value cwd token abs relative_ok
    local -a tokens
    # Offsets reach shell arithmetic, which would evaluate an expression.
    if ! [[ $from =~ $number && $to =~ $number ]] || [ "$to" -le "$from" ]; then
        return 0
    fi
    while IFS=$'\t' read -r pos field value cwd; do
        tokens=()
        relative_ok=1
        case "$field" in
            file_path|path)
                if [[ $value =~ $anchored ]]; then tokens=("${BASH_REMATCH[1]}"); fi
                ;;
            *)
                if [[ $value == *"cd "* ]]; then relative_ok=0; fi
                mapfile -t tokens < <(/bin/grep -oE -- "$WORK_PATTERN" <<<"$value")
                ;;
        esac
        for token in "${tokens[@]}"; do
            case "$token" in
                /*|\~/*) abs=1 ;;
                *) abs=0; [ "$relative_ok" = 1 ] || continue ;;
            esac
            printf '%s\t%s\t%s\t%s\n' "$pos" "$abs" "$token" "$cwd"
        done
    done < <(tail -c +"$((from + 1))" -- "$transcript" 2>/dev/null \
        | head -c "$((to - from))" \
        | jq -rRs "$WORK_EVIDENCE_JQ" 2>/dev/null)
    return 0
}

# The first line of a workspace's progress.md that names its source: "# SDD
# ledger", a separator of punctuation and spaces, then "plan <path>" or
# "change <name> (<path>)", the keyword optionally followed by a colon. Real
# ledgers separate with ": ", ", ", ". ", " - " or an em dash between spaces:
# "# SDD ledger: plan docs/plans/x.md",
# "# SDD ledger, change: add-groups (openspec/changes/add-groups/tasks.md)".
readonly WORK_LEDGER_HEADER='^# SDD ledger[^[:alnum:]]+(plan|change):?[[:space:]]+(.*)$'

# _work_allowed STRING...
# Exits 0 when every STRING holds only letters, digits, /, ., _, -, ~ and
# space, the characters a subject's name and path may carry.
_work_allowed() {
    local s
    for s in "$@"; do
        [[ $s != *[!A-Za-z0-9/._~\ -]* ]] || return 1
    done
}

# work_classify ABSPATH
# Prints "kind<TAB>name<TAB>open" for an absolute path. A path under
# openspec/changes/<name>/, whatever file in it was named, is the change
# <name>, opened at its tasks.md; a path under openspec/changes/archive/ is
# no subject at all. Any other .md file is a plan named by its basename
# without .md and opened as is. Anything else exits 1. Purely lexical: no
# symlink is resolved and no existence is checked.
work_classify() {
    local path="$1" name
    [[ $path == /* ]] || return 1
    case "$path" in
        */openspec/changes/archive|*/openspec/changes/archive/*) return 1 ;;
        */openspec/changes/*)
            name="${path#*/openspec/changes/}"
            name="${name%%/*}"
            [[ -n $name && $name != . && $name != .. ]] || return 1
            printf 'change\t%s\t%s\n' "$name" "${path%%/openspec/changes/*}/openspec/changes/$name/tasks.md"
            return 0
            ;;
    esac
    name="${path##*/}"
    [[ $name == ?*.md ]] || return 1
    printf 'plan\t%s\t%s\n' "${name%.md}" "$path"
}

# work_ws_source WSDIR
# Prints the absolute path of the source an apply-run workspace names, or
# exits 1. WSDIR is the workspace directory as named, an absolute path
# ending in /.superpowers/sdd/<name>, before any symlink is resolved, so the
# workspace root is the directory that holds .superpowers in that path. The
# plan-path marker comes first; when it is missing or blank, the first line
# of progress.md, when it matches WORK_LEDGER_HEADER: the path is the text
# after the keyword, inside the parentheses for a change, up to the end of
# the line or a ")". A relative source resolves against the workspace root,
# one starting with ~/ against HOME. Each read stops at 4096 characters.
work_ws_source() {
    local ws="${1%/}" root name src="" line="" rest
    [[ $ws =~ ^(.*)/\.superpowers/sdd/([^/]+)$ ]] || return 1
    root="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
    [[ $ws == /* && $name != . && $name != .. ]] || return 1
    if [ -f "$ws/plan-path" ]; then
        IFS= read -r -n 4096 src 2>/dev/null < "$ws/plan-path" || true
    fi
    if [[ $src != *[![:space:]]* ]] && [ -f "$ws/progress.md" ]; then
        src=""
        IFS= read -r -n 4096 line 2>/dev/null < "$ws/progress.md" || true
        if [[ $line =~ $WORK_LEDGER_HEADER ]]; then
            rest="${BASH_REMATCH[2]}"
            if [ "${BASH_REMATCH[1]}" = change ]; then
                [[ $rest == *' ('* ]] || return 1
                rest="${rest#*' ('}"
            fi
            src="${rest%%)*}"
        fi
    fi
    src="${src#"${src%%[![:space:]]*}"}"
    src="${src%"${src##*[![:space:]]}"}"
    [ -n "$src" ] || return 1
    case "$src" in
        /*) ;;
        \~/*) [[ ${HOME:-} == /* ]] || return 1; src="$HOME/${src#\~/}" ;;
        *) src="$root/$src" ;;
    esac
    printf '%s\n' "$src"
}

# work_resolve RAW ABS CWD
# Resolves one occurrence from work_scan_range and prints
# "kind<TAB>name<TAB>open<TAB>ws", or prints nothing and exits 1. With ABS 1,
# RAW starts with / or with ~/, which resolves against HOME; with ABS 0, RAW
# joins CWD, which must be absolute. A workspace token, one ending in
# .superpowers/sdd/<name>/, stands for the source work_ws_source reads, and
# ws is the workspace's absolute, symlink-resolved directory; for any other
# token ws is empty. open is symlink-resolved up to the file (a change's
# tasks.md is opened in its resolved directory), so two names of one file
# give one subject. Exits 1 for a path under openspec/changes/archive/ as
# named or as resolved, a workspace that names no source, a path, workspace
# or name with a character outside the allowed set, or an open file that
# does not exist. Name and open are cut from the checked resolved path, so
# they hold only allowed characters too.
work_resolve() {
    local raw="$1" abs="$2" cwd="$3" path ws="" real row kind name open
    case "$abs:$raw" in
        1:/*) path="$raw" ;;
        1:\~/*) [[ ${HOME:-} == /* ]] || return 1; path="$HOME/${raw#\~/}" ;;
        0:/*|0:\~/*) return 1 ;;
        0:?*) [[ $cwd == /* ]] || return 1; path="$cwd/$raw" ;;
        *) return 1 ;;
    esac
    if [[ $path =~ /\.superpowers/sdd/[^/]+/?$ ]]; then
        _work_allowed "$path" || return 1
        ws="$(realpath -m -- "$path" 2>/dev/null)" || return 1
        path="$(work_ws_source "$path")" || return 1
    fi
    case "$path" in
        */openspec/changes/archive|*/openspec/changes/archive/*) return 1 ;;
    esac
    _work_allowed "$path" "$ws" || return 1
    real="$(realpath -m -- "$path" 2>/dev/null)" || return 1
    _work_allowed "$real" || return 1
    row="$(work_classify "$real")" || return 1
    IFS=$'\t' read -r kind name open <<<"$row"
    [ -e "$open" ] || return 1
    printf '%s\t%s\t%s\t%s\n' "$kind" "$name" "$open" "$ws"
}

# Entry point; a stub until the cache and the rendering exist.
work_main() {
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    work_main "$@"
fi
