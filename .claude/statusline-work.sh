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

# Every failure path is handled explicitly, so there is no set -e.
set -u

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

# _work_normalise VAR PATH
# Sets VAR to the absolute PATH normalised without touching the disk: empty
# and "." components dropped, each ".." removing the component before it,
# no symlink resolved.
_work_normalise() {
    local _n_rest="$2" _n_part _n_out=""
    while [ -n "$_n_rest" ]; do
        _n_part="${_n_rest%%/*}"
        if [[ $_n_rest == */* ]]; then _n_rest="${_n_rest#*/}"; else _n_rest=""; fi
        case "$_n_part" in
            ''|.) ;;
            ..) _n_out="${_n_out%/*}" ;;
            *) _n_out="$_n_out/$_n_part" ;;
        esac
    done
    printf -v "$1" '%s' "${_n_out:-/}"
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
# "kind<TAB>name<TAB>open<TAB>ws". With ABS 1, RAW starts with / or with
# ~/, which resolves against HOME; with ABS 0, RAW joins CWD, which must be
# absolute. A workspace token, one ending in .superpowers/sdd/<name>/,
# stands for the source work_ws_source reads, and ws is the workspace's
# absolute, symlink-resolved directory; for any other token ws is empty.
# Kind and name come from the path as named, lexically normalised and
# before any symlink is resolved, so a change whose tasks.md or directory is
# a symlink stays that change. open is the symlink-resolved file, so two
# names of one file give one subject.
# Exit 1, printing nothing, is invalid evidence, and the caller moves on to
# an older occurrence: no usable base directory, a workspace that names no
# source, a change under openspec/changes/archive/ as named or as resolved,
# a path that classifies as nothing, or a character outside the allowed set
# in the path as named, the workspace, or the file to open. Exit 2, printing
# nothing, is a valid subject whose file to open does not exist or cannot be
# resolved: when a render has shown the occurrence before, the caller
# retires the subject and shows nothing rather than an older subject, and
# otherwise moves on as for exit 1 (see work_render).
work_resolve() {
    local raw="$1" abs="$2" cwd="$3" path ws="" named row kind name open resolved dir
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
    _work_allowed "$path" "$ws" || return 1
    _work_normalise named "$path"
    row="$(work_classify "$named")" || return 1
    IFS=$'\t' read -r kind name open <<<"$row"
    # One realpath call resolves the file to open and its directory, which
    # for a change is the change directory the archive rule applies to (the
    # trailing slash keeps a file at the root from passing an empty operand).
    # A resolved path holding a newline leaves one in open, which then fails
    # the character check.
    resolved="$(realpath -m -- "${open%/*}/" "$open" 2>/dev/null)" || return 2
    dir="${resolved%%$'\n'*}" open="${resolved#*$'\n'}"
    case "$dir/" in
        */openspec/changes/archive/*) return 1 ;;
    esac
    case "$open" in
        */openspec/changes/archive|*/openspec/changes/archive/*) return 1 ;;
    esac
    _work_allowed "$open" || return 1
    [ -e "$open" ] || return 2
    printf '%s\t%s\t%s\t%s\n' "$kind" "$name" "$open" "$ws"
}

# work_stage KIND OPEN WS
# Prints the subject's stage, or nothing, and exits 0. With a workspace WS
# the stage comes from WS/progress.md alone: its last line of the form
# "Section|Task|Unit <id>: <status>" or "Final phase: <status>", where <id>
# is letters, digits and dots, rendered as "Section 6.1 <status>" or "final
# phase <status>". Lines are read up to their newline, so a partly written
# last line is ignored. A carriage return ending the line is dropped; the
# status is cut at its first " (" and capped at 40 characters, counted as
# characters whatever the caller's locale; a status that still holds a
# control character gives no stage. Without a workspace, a change's stage
# is its ticked over total task boxes in OPEN outside fenced code blocks,
# as "2/4", with no boxes giving none, and a plan has none. Only regular
# files are opened, so a FIFO cannot block the status line.
work_stage() {
    # The cap counts characters, not bytes, whatever the caller's locale.
    local LC_ALL=C.UTF-8
    local kind="$1" open="$2" ws="$3" line last="" label status i
    local ticked=0 total=0 fenced=0
    local -a lines=() parts=()
    local marker='^((Section|Task|Unit) [A-Za-z0-9.]+|Final phase): '
    local box='^[[:space:]]*- \[( |x|X)\]'
    if [ -n "$ws" ]; then
        [ -f "$ws/progress.md" ] || return 0
        # One mapfile of the whole ledger, scanned from the end, spares a
        # redraw the per-line regex of a line loop; a glob skips lines that
        # cannot start a marker. mapfile keeps each newline, so an element
        # without one is the unterminated last line. mapfile cuts a line at a
        # NUL where the line loop drops the NUL, so a ledger with a NUL
        # before its last byte (two NUL-separated records) takes the line
        # loop and reads as it always did; a NUL as the last byte sits in the
        # unterminated last line, which neither read uses.
        mapfile -d '' -n 2 parts 2>/dev/null < "$ws/progress.md"
        if [ "${#parts[@]}" -gt 1 ]; then
            while IFS= read -r line; do
                if [[ $line =~ $marker ]]; then last="$line"; fi
            done 2>/dev/null < "$ws/progress.md"
        else
            mapfile lines 2>/dev/null < "$ws/progress.md"
            i=$((${#lines[@]} - 1))
            if [ "$i" -ge 0 ] && [[ ${lines[i]} != *$'\n' ]]; then i=$((i - 1)); fi
            for (( ; i >= 0; i-- )); do
                case ${lines[i]} in
                    'Section '* | 'Task '* | 'Unit '* | 'Final phase: '*) ;;
                    *) continue ;;
                esac
                if [[ ${lines[i]} =~ $marker ]]; then last="${lines[i]%$'\n'}"; break; fi
            done
        fi
        [[ $last =~ $marker ]] || return 0
        label="${BASH_REMATCH[1]}"
        status="${last#"${BASH_REMATCH[0]}"}"
        status="${status%$'\r'}"
        status="${status%%' ('*}"
        [[ $status != *[$'\001'-$'\037'$'\177']* ]] || return 0
        if [ "$label" = "Final phase" ]; then label="final phase"; fi
        printf '%s %s\n' "$label" "${status:0:40}"
    elif [ "$kind" = change ] && [ -f "$open" ]; then
        # The last line counts with or without its newline.
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ $line == '```'* ]]; then
                fenced=$((1 - fenced))
            elif [ "$fenced" = 0 ] && [[ $line =~ $box ]]; then
                total=$((total + 1))
                if [ "${BASH_REMATCH[1]}" != ' ' ]; then ticked=$((ticked + 1)); fi
            fi
        done 2>/dev/null < "$open"
        if [ "$total" -gt 0 ]; then printf '%s/%s\n' "$ticked" "$total"; fi
    fi
    return 0
}

# Format version of the cache file; a cache of any other version is
# discarded. Version 3 gives each occurrence the flag that a render has
# shown it (see work_render), which a version 2 cache lacks, so that cache
# is rescanned once. Version 2 keyed each occurrence by its record's
# position in the file (see work_scan_chunks), where version 1 stored the
# record's index in the bytes its run scanned, which records of different
# runs shared.
readonly WORK_CACHE_VERSION=3

# The run's state, shared by the functions below: the cache file and the
# transcript it belongs to, the offset scanned so far, the transcript size
# the last commit recorded, and the occurrences, newest first, as
# "pos<TAB>abs<TAB>raw<TAB>cwd<TAB>shown" with pos the record's position in
# the file (see work_scan_chunks) and shown 1 once a render has printed the
# occurrence's subject, 0 before (see work_render). Only cwd can be empty,
# so a row is split from its end: an empty field between two tabs would
# vanish in a read with IFS set to a tab.
_work_cache="" _work_transcript="" _work_offset=0 _work_recorded=0
_work_rows=()

# work_cache_load SIZE
# Loads the cache file _work_cache into _work_offset, _work_recorded and
# _work_rows. Each of these resets them to offset 0 and no occurrences
# instead: no cache file, another version, another transcript path than
# _work_transcript, a recorded size above SIZE (the transcript's current
# size; a shrink is a replacement), an offset above the recorded size, or a
# line that does not parse as the header or as a five-field row.
work_cache_load() {
    local size="$1" header pair recorded offset row
    local sizes=$'^(0|[1-9][0-9]{0,17})\t(0|[1-9][0-9]{0,17})$'
    local shape=$'^(0|[1-9][0-9]{0,17})\t[01]\t[^\t]+\t[^\t]*\t[01]$'
    local -a lines=()
    _work_offset=0 _work_recorded=0 _work_rows=()
    [ -f "$_work_cache" ] || return 0
    mapfile -t lines 2>/dev/null < "$_work_cache" || return 0
    header="${lines[0]:-}"
    [[ $header == "$WORK_CACHE_VERSION"$'\t'"$_work_transcript"$'\t'* ]] || return 0
    pair="${header#"$WORK_CACHE_VERSION"$'\t'"$_work_transcript"$'\t'}"
    [[ $pair =~ $sizes ]] || return 0
    recorded="${BASH_REMATCH[1]}" offset="${BASH_REMATCH[2]}"
    (( offset <= recorded && recorded <= size )) || return 0
    for row in "${lines[@]:1}"; do
        [[ $row =~ $shape ]] || return 0
    done
    _work_offset="$offset" _work_recorded="$recorded" _work_rows=("${lines[@]:1}")
}

# work_cache_commit OFFSET
# Writes the header, recording _work_recorded as the transcript size and
# OFFSET as the offset scanned, and the occurrences in _work_rows to a temp
# file unique to this process, then renames it over the cache, so the
# offset and the occurrences are replaced together. Exits 1, leaving the
# cache as it was, when the temp file cannot be written or renamed.
work_cache_commit() {
    local tmp="${_work_cache%.tsv}.tmp.$$"
    {
        printf '%s\t%s\t%s\t%s\n' "$WORK_CACHE_VERSION" "$_work_transcript" "$_work_recorded" "$1" \
            && if [ "${#_work_rows[@]}" -gt 0 ]; then printf '%s\n' "${_work_rows[@]}"; fi
    } 2>/dev/null > "$tmp" && mv -f -- "$tmp" "$_work_cache" 2>/dev/null && return 0
    rm -f -- "$tmp" 2>/dev/null
    return 1
}

# _work_chunk_end VAR FROM ENDPOINT CHUNK
# Sets VAR to the end of the chunk of _work_transcript that starts at FROM,
# a line start: just past the first newline at least CHUNK bytes on, so no record
# is split, or, when ENDPOINT comes first or no newline follows before it,
# just past the last newline before ENDPOINT. VAR is FROM when the bytes
# from FROM to ENDPOINT hold no newline: a partial line waits for a later
# run.
_work_chunk_end() {
    local _e_from="$2" _e_end="$3" _e_at=$(($2 + $4)) _e_lines="" _e_bytes=""
    if [ "$_e_at" -lt "$_e_end" ]; then
        # The line holding the chunk's last byte, cut after its newline.
        read -r _e_lines _e_bytes < <(tail -c +"$_e_at" -- "$_work_transcript" 2>/dev/null \
            | head -c "$((_e_end - _e_at + 1))" | head -n 1 | wc -lc)
        if [ "$_e_lines" = 1 ] && [[ $_e_bytes =~ ^[0-9]+$ ]]; then
            printf -v "$1" '%s' "$((_e_at - 1 + _e_bytes))"
            return 0
        fi
    fi
    # The last line of the bytes up to ENDPOINT counts one line when it ends
    # in a newline; otherwise it is the partial line of _e_bytes bytes.
    read -r _e_lines _e_bytes < <(tail -c +"$((_e_from + 1))" -- "$_work_transcript" 2>/dev/null \
        | head -c "$((_e_end - _e_from))" | tail -n 1 | wc -lc)
    if [ "$_e_lines" = 1 ]; then
        printf -v "$1" '%s' "$_e_end"
    elif [ "$_e_lines" = 0 ] && [[ $_e_bytes =~ ^[0-9]+$ ]]; then
        printf -v "$1" '%s' "$((_e_end - _e_bytes))"
    else
        printf -v "$1" '%s' "$_e_from"
    fi
}

# work_scan_chunks ENDPOINT
# Scans the transcript from _work_offset towards ENDPOINT, its size at the
# run's start, in chunks of WORK_CHUNK bytes (4 MiB), each extended to a
# line end. A chunk's occurrences go on top of _work_rows, newest first and
# not yet shown, each with its pos made the record's position in the file:
# the chunk's start offset plus the record's line index in the chunk, which
# every occurrence of one record shares and no other record has, since each
# line holds at least its newline byte. The newest ten with distinct raw
# matches are kept. A cached occurrence whose raw a newer one took over
# hands that one its shown flag when the two resolve alike (raw is
# absolute, or both have the same cwd), so a later mention of a shown
# subject's path, such as an rm of the plan read before, still retires it.
# Each chunk is then committed, recording ENDPOINT as the transcript size
# (a commit that fails leaves the progress in memory for this run only).
# Exits 0 once the offset reaches the last line end before ENDPOINT, and 1
# when the work budget of WORK_BUDGET_MS milliseconds (1500) ran out first.
# The budget is checked only after a chunk, so every run makes progress.
work_scan_chunks() {
    local endpoint="$1" chunk="${WORK_CHUNK:-}" budget="${WORK_BUDGET_MS:-}"
    local start to="" scanned=0 i j pos row raw seen_raw old new
    local -a found=() newest=() kept=() seen=()
    [[ $chunk =~ ^[1-9][0-9]{0,9}$ ]] || chunk=4194304
    [[ $budget =~ ^[0-9]{1,9}$ ]] || budget=1500
    start="${EPOCHREALTIME//[!0-9]/}"
    while [ "$_work_offset" -lt "$endpoint" ]; do
        _work_chunk_end to "$_work_offset" "$endpoint" "$chunk"
        [ "$to" -gt "$_work_offset" ] || return 0
        if [ "$scanned" = 1 ] && [ $(( ${EPOCHREALTIME//[!0-9]/} - start )) -gt $(( budget * 1000 )) ]; then
            return 1
        fi
        mapfile -t found < <(work_scan_range "$_work_transcript" "$_work_offset" "$to")
        # This chunk's occurrences from its last, then the older ones. A pos
        # reaches shell arithmetic, so anything but a number is dropped.
        newest=()
        for (( i = ${#found[@]} - 1; i >= 0; i-- )); do
            pos="${found[i]%%$'\t'*}"
            [[ $pos =~ ^(0|[1-9][0-9]{0,17})$ ]] || continue
            newest+=("$((_work_offset + pos))${found[i]#"$pos"}"$'\t0')
        done
        newest+=("${_work_rows[@]}")
        kept=() seen=()
        for row in "${newest[@]}"; do
            [ "${#kept[@]}" -lt 10 ] || break
            raw="${row#*$'\t'*$'\t'}"
            raw="${raw%%$'\t'*}"
            for seen_raw in "${seen[@]}"; do
                [ "$seen_raw" != "$raw" ] || continue 2
            done
            kept+=("$row") seen+=("$raw")
        done
        # A kept row with a cached row's raw is that row or a newer one,
        # since no new record shares a cached record's position. A newer
        # one takes the cached flag when the two resolve alike: raw is
        # absolute, or their "abs<TAB>raw<TAB>cwd" match. The flag is a
        # row's last character.
        for row in "${_work_rows[@]}"; do
            raw="${row#*$'\t'*$'\t'}"
            raw="${raw%%$'\t'*}"
            for (( j = 0; j < ${#kept[@]}; j++ )); do
                [ "${seen[j]}" = "$raw" ] || continue
                old="${row#*$'\t'}" new="${kept[j]#*$'\t'}"
                if [ "${kept[j]}" != "$row" ] && [[ $old == 1$'\t'* || ${old%$'\t'*} == "${new%$'\t'*}" ]]; then
                    kept[j]="${kept[j]%?}${row: -1}"
                fi
                break
            done
        done
        _work_rows=("${kept[@]}") _work_offset="$to" _work_recorded="$endpoint"
        work_cache_commit "$to"
        scanned=1
    done
    return 0
}

# work_render LOCKED
# Prints the subject of the newest occurrence in _work_rows that resolves,
# as "kind<TAB>name<TAB>open<TAB>stage", the stage possibly empty, and marks
# that occurrence shown. Invalid evidence (work_resolve exit 1) passes the
# walk on to the next older occurrence, and so does a valid subject whose
# file is gone (exit 2) on an occurrence no render has shown, such as a
# relative path joined to the wrong directory. Exit 2 on an occurrence
# shown before retires the subject: the walk ends with nothing printed,
# since an older subject is never shown in its place.
# LOCKED is 1 when the run holds the session's lock. Only then does an
# occurrence shown for the first time get its flag committed to the cache,
# with the offset and recorded size unchanged; a run that found the lock
# held writes nothing, and neither does a redraw that sets no flag.
# When the subject resolved without a workspace, the older occurrences,
# newest first and of any record, are resolved too, and the first that
# resolves (exit 0) to the same file to open with a workspace lends that
# workspace to the stage; the subject itself does not change. An
# occurrence that exits 1 or 2 or names another file lends nothing. Only a
# workspace token can resolve with a workspace, so no other occurrence is
# resolved for this.
work_render() {
    local locked="${1:-0}" i j abs raw cwd shown subject kind name open ws tie tie_open tie_ws
    for (( i = 0; i < ${#_work_rows[@]}; i++ )); do
        shown="${_work_rows[i]##*$'\t'}"
        IFS=$'\t' read -r _ abs raw cwd <<<"${_work_rows[i]%$'\t'*}"
        subject="$(work_resolve "$raw" "$abs" "$cwd")"
        case $? in
            0)
                IFS=$'\t' read -r kind name open ws <<<"$subject"
                # The newer occurrences exited 1 or 2 in this walk, so only
                # the older ones can lend.
                if [ -z "$ws" ]; then
                    for (( j = i + 1; j < ${#_work_rows[@]}; j++ )); do
                        IFS=$'\t' read -r _ abs raw cwd <<<"${_work_rows[j]%$'\t'*}"
                        [[ $raw == *.superpowers/sdd/?* ]] || continue
                        tie="$(work_resolve "$raw" "$abs" "$cwd")" || continue
                        IFS=$'\t' read -r _ _ tie_open tie_ws <<<"$tie"
                        if [ "$tie_open" = "$open" ] && [ -n "$tie_ws" ]; then
                            ws="$tie_ws"
                            break
                        fi
                    done
                fi
                printf '%s\t%s\t%s\t%s\n' "$kind" "$name" "$open" "$(work_stage "$kind" "$open" "$ws")"
                if [ "$shown" = 0 ] && [ "$locked" = 1 ]; then
                    _work_rows[i]="${_work_rows[i]%0}1"
                    work_cache_commit "$_work_offset"
                fi
                return 0
                ;;
            2)
                if [ "$shown" = 1 ]; then return 0; fi
                ;;
        esac
    done
    return 0
}

# work_prune DIR
# At most once a day, deletes the caches in DIR (work-*.tsv) not modified
# for more than WORK_PRUNE_DAYS days (14), counted in whole days as find
# -mtime counts them. The stamp file work-prune.stamp holds the epoch
# second of the last prune. Lock and temp files are never touched.
work_prune() {
    local dir="$1" stamp="$1/work-prune.stamp" days="${WORK_PRUNE_DAYS:-}" last=""
    [[ $days =~ ^[0-9]{1,5}$ ]] || days=14
    read -r last 2>/dev/null < "$stamp"
    if [[ $last =~ ^[0-9]{1,18}$ ]] && (( last <= EPOCHSECONDS && EPOCHSECONDS - last < 86400 )); then
        return 0
    fi
    printf '%s\n' "$EPOCHSECONDS" 2>/dev/null > "$stamp" || return 0
    find "$dir" -maxdepth 1 -type f -name 'work-*.tsv' -mtime +"$days" -delete 2>/dev/null
    return 0
}

# work_main SESSION_ID TRANSCRIPT_PATH CURRENT_DIR
# Prints the session's subject as "kind<TAB>name<TAB>open<TAB>stage", or
# nothing, and exits 0 either way. CURRENT_DIR is accepted and unused:
# every occurrence resolves against its own record's cwd. The cache, lock,
# temp and stamp files live in WORK_CACHE_DIR (by default
# ${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline), named after the
# session id, so an id that is empty or holds a slash, or a transcript path
# that is empty or holds a newline (the cache header could not hold it),
# prints nothing and writes nothing; so does a missing transcript.
# A run takes the session's lock without waiting, loads the cache, scans
# the transcript up to its size at the start, prints the subject once the
# scan has caught up and nothing while it has not, and prunes old caches.
# When another run holds the lock, it renders from the cache without
# scanning or writing, and prints nothing while the cached offset is below
# the size the last commit recorded, since a catch-up is then in flight.
# The lock is held on descriptor 9 for the call only, so a shell that
# sources this file holds no lock once work_main returns.
work_main() {
    local id="${1:-}" transcript="${2:-}" size="" locked=0
    local dir="${WORK_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/claude-statusline}"
    [[ -n $id && $id != */* && -n $transcript && $transcript != *$'\n'* ]] || return 0
    [ -f "$transcript" ] || return 0
    [ -d "$dir" ] || mkdir -p -- "$dir" 2>/dev/null || return 0
    _work_cache="$dir/work-$id.tsv" _work_transcript="$transcript"
    {
        # The size and the cache are read after the lock is taken: a run
        # that loaded before another run's commit could otherwise commit an
        # older offset over it.
        flock -n 9 && locked=1
        size="$(stat -L -c %s -- "$transcript")"
        [[ $size =~ ^(0|[1-9][0-9]{0,17})$ ]] || return 0
        work_cache_load "$size"
        if [ "$locked" = 1 ]; then
            if work_scan_chunks "$size"; then work_render 1; fi
            work_prune "$dir"
        elif [ "$_work_offset" -ge "$_work_recorded" ]; then
            work_render 0
        fi
    } 2>/dev/null 9>"$dir/work-$id.lock"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    work_main "$@"
fi
