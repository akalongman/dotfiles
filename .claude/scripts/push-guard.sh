#!/usr/bin/env bash
# Second layer of the public dotfiles' publication check, run as a Claude Code
# PreToolUse hook on the Bash and Monitor tools, which both run
# tool_input.command in a shell (~/.claude/settings.json, matcher Bash|Monitor);
# every other tool passes:
#
#   push-guard.sh hook    reads the hook JSON (tool_name, tool_input.command,
#                         cwd) on stdin
#
# The first layer is the yadm repository's pre-push hook, which scans what a
# push would publish. A push with --no-verify, or with core.hooksPath pointed
# elsewhere, skips that hook. This script refuses such a push of the public
# repository, and a git config write of core.hooksPath that would redirect its
# hooks. Exit 2 with one line on stderr refuses; exit 0 with no output passes.
# Any internal failure (no jq, input that is not JSON, a missing directory, a
# failing git call) passes silently, because the hook runs before every shell
# command. A command without a bypass token returns before jq or git runs.
#
# Example, with the public work tree at ~ and another repository at ~/src/x:
#   cwd ~       git push --no-verify                       refused (cwd)
#   cwd ~/src/x git -C ~ push --no-verify                  refused (-C)
#   cwd ~/src/x yadm push --no-verify                      refused (yadm)
#   cwd ~/src/x git push --no-verify                       passes
#   cwd ~/src/x git config --global core.hooksPath /x      refused (global)
#   cwd ~/src/x git config core.hooksPath .githooks        passes
#
# Rules. The command is read as text: nothing in it is expanded except ~,
# $HOME and ${HOME}, and nothing in it is run.
#   bypass token  --no-verify or an abbreviation git accepts for it
#                 (--no-veri, --no-verif), or core.hooksPath in any letter case
#   target        the word yadm; the repository path in the command; the cwd;
#                 a directory named after -C, cd, pushd, --work-tree or
#                 GIT_WORK_TREE=; a git dir named after --git-dir or GIT_DIR=
#                 (git follows a gitfile). A directory is public when
#                 git -C <dir> rev-parse --path-format=absolute --git-common-dir
#                 resolves to PUSH_GUARD_REPO (git --git-dir=<dir> for a git
#                 dir), so a linked worktree of the public repository counts.
#   push refused  the word push (or git-push) and a bypass token anywhere in
#                 the command, with a public target
#   write refused git config (or yadm gitconfig) setting, adding, replacing or
#                 unsetting core.hooksPath: always with --global, --system or
#                 --file, otherwise with a public target. Reads pass, and so
#                 does -c core.hooksPath on a command other than push.
#
# Known false positives, accepted because the rules read the whole command:
#   - Text that holds push and a bypass token without a push that uses it is
#     refused: a commit message reading "push --no-verify", or
#     `git commit --no-verify -m x && git push`.
#   - A push of another repository spelled with cd or -C from a cwd inside
#     $HOME that has no nearer repository is refused, because that cwd itself
#     resolves to the public repository.
#
# Known gaps: a directory spelled another way ($PWD, $(...), a variable) is not
# resolved. The shell parse is small (quotes, comments, operators,
# redirections and heredoc bodies skipped); a command it cannot parse keeps only the yadm, repository
# path and cwd checks, and a nested `sh -c '...'` string is one word.
#
# Environment: PUSH_GUARD_REPO, the public git dir (default
# $HOME/.local/share/yadm/repo.git), compared after realpath.

PG_PUSH_REASON='push-guard: a push of the public dotfiles with hooks disabled is refused; the pre-push guard is the publication check, fix the content and push without --no-verify (a push of another repository from this directory needs that repository as the working directory)'
PG_WRITE_REASON="push-guard: a core.hooksPath write is refused; core.hooksPath would redirect hooks away from the public dotfiles' pre-push guard (to set it for another repository, run git config with that repository as the working directory and without --global, --system or --file)"

# Splits a command into words (quotes removed) and prints one record per named
# directory (D<tab>dir), named git dir (G<tab>dir) and core.hooksPath write
# (W<tab>global or W<tab>local). Exits 1 on an unterminated quote. Runs under
# LC_ALL=C: a bash loop over a long command is far too slow for a hook.
# shellcheck disable=SC2016  # an awk program: its $0 is awk's, not the shell's
PG_AWK='
BEGIN {
    SEP = "\037"; LONG = "\036"; SQ = "\047"; DQ = "\""; BS = "\\"
    split("{ ! if then elif else do while until time command builtin exec env nohup sudo", t, " ")
    for (k in t) PREFIX[t[k]] = 1
    split("-C -c --git-dir --work-tree --namespace --config-env --super-prefix --attr-source -Y --yadm-dir --yadm-data --yadm-repo --yadm-config --yadm-encrypt --yadm-archive --yadm-bootstrap", t, " ")
    for (k in t) GARG[t[k]] = 1
    split("--blob --type --default --comment --value --url", t, " ")
    for (k in t) CARG[t[k]] = 1
}
{ s = (NR > 1 ? s RS : "") $0 }
END { tokenize(); if (q != "") exit 1; extract() }

# Words longer than any path are kept as LONG, so building them stays linear.
function add(ch) { if (wl++ < 4096) word = word ch; inword = 1 }
function word_end() {
    if (inword) {
        if (wl > 4096) word = LONG
        if (want == 3) want = 0   # a redirection target is not an argument
        else if (want) { delim[++nd] = word; strip[nd] = (want == 2); want = 0 }
        else W[++nw] = word
    }
    word = ""; inword = 0; wl = 0; wq = 0
}

# A redirection (< > >> <> >| <& >& &> &>> <<<) drops the unquoted fd number
# before it (2>) and the word after it; << and <<- take a heredoc delimiter.
function redirect(   nx) {
    if (inword && !wq && word ~ /^[0-9]+$/) { word = ""; inword = 0; wl = 0 }
    word_end()
    if (c == "&") i++
    if (substr(s, i, 2) == "<<" && substr(s, i + 2, 1) != "<") {
        i++; want = 1
        if (substr(s, i + 1, 1) == "-") { i++; want = 2 }
        return
    }
    if (substr(s, i, 3) == "<<<") i += 2
    else { nx = substr(s, i + 1, 1); if (nx != "" && index(">&|", nx)) i++ }
    want = 3
}
function cmd_end() { word_end(); want = 0; W[++nw] = SEP }

# A heredoc body runs from the newline after its << to the delimiter line.
function body_char(   t) {
    if (c != "\n") { if (ll++ < 4096) line = line c; return }
    t = line; line = ""; ll = 0
    if (strip[bk]) sub(/^\t+/, "", t)
    if (t == delim[bk] && ++bk > nd) { inbody = 0; nd = 0 }
}

function tokenize(   n) {
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (inbody) { body_char(); continue }
        if (q == SQ) { if (c == SQ) q = ""; else add(c); continue }
        if (q == DQ) {
            if (c == DQ) q = ""
            else if (c == BS && i < n && index(DQ BS "$`\n", substr(s, i + 1, 1))) {
                i++; if (substr(s, i, 1) != "\n") add(substr(s, i, 1))
            } else add(c)
            continue
        }
        if (c == SQ || c == DQ) { q = c; inword = 1; wq = 1; continue }
        if (c == BS) { wq = 1; if (i < n) { i++; if (substr(s, i, 1) != "\n") add(substr(s, i, 1)) } continue }
        if (c == "#" && !inword) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
        if (c == " " || c == "\t") { word_end(); continue }
        if (c == "<" || c == ">" || (c == "&" && substr(s, i + 1, 1) == ">")) { redirect(); continue }
        if (index(";&|()\n", c)) {
            cmd_end()
            if (c == "\n" && nd) { inbody = 1; bk = 1; line = ""; ll = 0 }
            continue
        }
        add(c)
    }
    cmd_end()
}

function expand(w,   h, out, nx) {
    h = ENVIRON["HOME"]
    if (w == "~") return h
    if (substr(w, 1, 2) == "~/") w = h substr(w, 2)
    out = ""
    while (match(w, /\$[{]HOME[}]|\$HOME/)) {
        nx = substr(w, RSTART + RLENGTH, 1)
        if (RLENGTH == 5 && nx ~ /[A-Za-z0-9_]/) {   # $HOMEDIR is another variable
            out = out substr(w, 1, RSTART + RLENGTH - 1)
        } else out = out substr(w, 1, RSTART - 1) h
        w = substr(w, RSTART + RLENGTH)
    }
    return out w
}
function emit(kind, v) {
    if (v == LONG) return
    v = expand(v)
    if (v != "" && !index(v, "\n")) print kind "\t" v
}

function extract(   k, w, cmdpos) {
    cmdpos = 1
    for (k = 1; k <= nw; k++) {
        w = W[k]
        if (w == SEP) { cmdpos = 1; continue }
        if (w == "-C" || w == "--work-tree") { if (W[k + 1] != SEP) emit("D", W[k + 1]) }
        else if (w == "--git-dir") { if (W[k + 1] != SEP) emit("G", W[k + 1]) }
        else if (w ~ /^(--work-tree|GIT_WORK_TREE)=/) emit("D", substr(w, index(w, "=") + 1))
        else if (w ~ /^(--git-dir|GIT_DIR)=/) emit("G", substr(w, index(w, "=") + 1))
        if (!cmdpos) continue
        if ((w in PREFIX) || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        cmdpos = 0
        if (w == "cd" || w == "pushd") cd_target(k)
        else if (w ~ /(^|\/)(git|yadm)$/) config_write(k)
    }
}

# cd with no directory goes home; cd - goes to an unknown previous directory.
function cd_target(k,   j) {
    for (j = k + 1; W[j] != SEP; j++) {
        if (W[j] == "-") return
        if (W[j] == "--") { j++; break }
        if (W[j] !~ /^-/) break
    }
    emit("D", W[j] == SEP ? "~" : W[j])
}

function config_write(k,   j, o, np, P, glob, rd, wr, key, sc) {
    for (j = k + 1; W[j] != SEP; j++) {   # git or yadm options before the subcommand
        o = W[j]
        if (o in GARG) { if (W[j + 1] == SEP) return; j++; continue }
        if (o !~ /^-/) break
    }
    if (W[j] != "config" && W[j] != "gitconfig") return
    np = 0
    for (j++; W[j] != SEP; j++) {
        o = W[j]
        if (o == "--global" || o == "--system" || o ~ /^(--file=|-f.)/) glob = 1
        else if (o == "--file" || o == "-f") { glob = 1; if (W[j + 1] != SEP) j++ }
        else if (o in CARG) { if (W[j + 1] != SEP) j++ }
        else if (o == "-l" || o ~ /^--(get|get-all|get-regexp|get-urlmatch|get-color|get-colorbool|list)$/) rd = 1
        else if (o ~ /^--(add|replace-all|unset|unset-all)$/) wr = 1
        else if (o !~ /^-/) P[++np] = o
    }
    key = P[1]; sc = ""
    if (key == "set" || key == "unset") { sc = key; key = P[2] }
    if (tolower(key) != "core.hookspath") return
    if (sc == "" && !wr && (rd || np < 2)) return   # --get, or the bare key: a read
    print "W\t" (glob ? "global" : "local")
}
'

pg_usage() { printf 'usage: push-guard.sh hook < hook-input.json\n' >&2; }

pg_refuse() { printf '%s\n' "$1" >&3; exit 2; }

pg_has_word() { # text pattern: 0 when pattern stands alone (letters, digits, _ . - continue a word)
    local re="(^|[^[:alnum:]_.-])$2(\$|[^[:alnum:]_.-])"
    [[ $1 =~ $re ]]
}

pg_names_hookspath() { # text
    local rc=1
    shopt -s nocasematch
    [[ $1 == *core.hookspath* ]] && rc=0
    shopt -u nocasematch
    return "$rc"
}

pg_has_bypass() { [[ $1 == *--no-veri* ]] || pg_names_hookspath "$1"; }

pg_resolves_dir() { # dir: 0 when its common git dir (shared by linked worktrees) is the public one
    local g
    g="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" || return 1
    [ "$(realpath -m -- "$g")" = "$PG_REPO_REAL" ]
}

pg_resolves_gitdir() { # git dir value: its common git dir (git follows a gitfile), else the value
    local g
    g="$(git --git-dir="$1" rev-parse --path-format=absolute --git-common-dir)" || g="$1"
    [ "$(realpath -m -- "$g")" = "$PG_REPO_REAL" ]
}

pg_public_target() { # command cwd records: 0 when a target is the public repository
    local cmd="$1" cwd="$2" line kind path
    pg_has_word "$cmd" yadm && return 0
    [[ $cmd == *"$PG_REPO"* || $cmd == *"$PG_REPO_REAL"* ]] && return 0
    [ -n "$cwd" ] && pg_resolves_dir "$cwd" && return 0
    while IFS= read -r line; do
        kind="${line%%$'\t'*}"; path="${line#*$'\t'}"
        case $path in /*) ;; *) [ -n "$cwd" ] && path="$cwd/$path" ;; esac
        case $kind in
            D) pg_resolves_dir "$path" && return 0 ;;
            G) pg_resolves_gitdir "$path" && return 0 ;;
        esac
    done <<<"$3"
    return 1
}

pg_hook() {
    exec 3>&2 2>/dev/null   # internal failures stay silent; a refusal goes to fd 3
    LC_ALL=C                # every token is ASCII; byte matching keeps a long command cheap
    local input tool cmd cwd recs push=0 write=''
    input="$(cat)" || return 0
    pg_has_bypass "$input" || return 0
    command -v jq >/dev/null || return 0
    tool="$(jq -r '.tool_name // empty' <<<"$input")" || return 0
    case $tool in Bash|Monitor) ;; *) return 0 ;; esac
    cmd="$(jq -r '.tool_input.command // empty' <<<"$input")" || return 0
    pg_has_bypass "$cmd" || return 0
    pg_has_word "$cmd" '(git-)?push' && push=1
    [ "$push" = 1 ] || pg_names_hookspath "$cmd" || return 0
    cwd="$(jq -r '.cwd // empty' <<<"$input")" || return 0
    PG_REPO="${PUSH_GUARD_REPO:-$HOME/.local/share/yadm/repo.git}"
    PG_REPO_REAL="$(realpath -m -- "$PG_REPO")" || return 0

    recs="$(printf '%s' "$cmd" | LC_ALL=C awk -v RS='\001' "$PG_AWK")" || recs=''
    case $'\n'"$recs"$'\n' in
        *$'\nW\tglobal\n'*) write=global ;;
        *$'\nW\tlocal\n'*) write=local ;;
    esac
    [ "$push" = 1 ] || [ -n "$write" ] || return 0
    [ "$write" = global ] && pg_refuse "$PG_WRITE_REASON"
    pg_public_target "$cmd" "$cwd" "$recs" || return 0
    [ "$push" = 1 ] && pg_refuse "$PG_PUSH_REASON"
    pg_refuse "$PG_WRITE_REASON"
}

case "${1:-}" in
    hook) pg_hook; exit 0 ;;
    *) pg_usage; exit 1 ;;
esac
