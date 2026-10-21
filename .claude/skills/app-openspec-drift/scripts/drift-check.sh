#!/usr/bin/env bash
# Compares the OpenSpec schema copies that repositories vendor with the
# canonical schema, and the canonical schema with the upstream spec-driven
# schema of the @fission-ai/openspec npm package.
#
#   drift-check.sh [REPO]      the status of REPO's copy (default: the
#                              current directory), followed by a diff when
#                              the copy is locally modified
#   drift-check.sh --fleet     the status of every repository's copy, found
#                              the way openspec-fleet finds them
#   drift-check.sh --upstream  the block-and-template report of the
#                              canonical against upstream spec-driven
#
# The status of a copy:
#   upstream spec-driven  the repository uses the schema OpenSpec ships
#   missing copy          openspec/schemas/<schema>/ is absent
#   legacy copy           the copy has no SOURCE naming a commit
#   unknown commit        the canonical clone does not hold that commit
#   locally modified      the copy differs from the tree that commit holds
#   in sync               the copy is that tree and the commit is HEAD
#   behind canonical      the copy is that tree, an ancestor of HEAD
#   ahead of canonical    the copy is that tree, not an ancestor of HEAD
#   no canonical          the canonical directory does not resolve to a
#                         git clone
#
# Read-only, and always exit 0: it writes only its own temporary directory,
# runs no git command in a repository it checks, and runs only reading ones
# in the canonical clone. The canonical is the tree the clone's HEAD holds,
# never its working tree, as openspec-fleet schema-sync vendors it.
#
# The environment, overridden by the tests only:
#   OPENSPEC_CANONICAL_DIR  the canonical schema directory or a link to it
#                           ($HOME/.local/share/openspec/schemas/spec-driven-longish)
#   FLEET_ROOTS             space-separated discovery roots ($HOME/projects)

set -euo pipefail

# A GIT_DIR, GIT_WORK_TREE or GIT_INDEX_FILE exported by the caller (yadm
# enter, a git hook) would point the reads of the canonical clone at that
# repository instead. The list is asked for from /, so that no git command
# runs in the repository being checked.
mapfile -t git_local_vars < <(git -C / rev-parse --local-env-vars 2>/dev/null || true)
unset -v "${git_local_vars[@]}" CDPATH

USAGE='usage: drift-check.sh [REPO] | drift-check.sh --fleet | drift-check.sh --upstream'
NO_CANONICAL='no canonical (run the machine playbook, tag openspec)'

# --- Arguments ---
# --fleet and --upstream exclude each other and take no REPO; the default
# mode takes at most one. Anything else prints the usage line, exit 0.

MODE=repo
OPERANDS=()
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help)
            echo "$USAGE"
            exit 0
            ;;
        --fleet|--upstream)
            if [ "$MODE" != repo ] && [ "$MODE" != "${1#--}" ]; then
                echo "$USAGE"
                exit 0
            fi
            MODE="${1#--}"
            ;;
        --)
            shift
            OPERANDS+=("$@")
            break
            ;;
        -?*)
            echo "drift-check.sh: unknown option $1" >&2
            echo "$USAGE"
            exit 0
            ;;
        *)
            OPERANDS+=("$1")
            ;;
    esac
    shift
done

if [ ${#OPERANDS[@]} -gt 1 ] || { [ "$MODE" != repo ] && [ ${#OPERANDS[@]} -gt 0 ]; }; then
    echo "$USAGE"
    exit 0
fi

# Every temporary file lives under this one directory.
if ! TMPDIR_DRIFT="$(mktemp -d)"; then
    echo "drift-check.sh: cannot create a temporary directory"
    exit 0
fi
trap 'rm -rf -- "$TMPDIR_DRIFT"' EXIT

# --- The canonical ---

CANON_DIR=''
CANON_TOP=''
CANON_PREFIX=''
CANON_HEAD=''

# Sets CANON_DIR (the canonical schema directory, links resolved),
# CANON_TOP (its clone's top level), CANON_PREFIX (its path inside the
# clone, with a trailing slash; empty at the top) and CANON_HEAD (the
# commit the clone has checked out). Leaves all four empty when the
# directory does not exist (a removed or dangling link), is in no git work
# tree, or HEAD names no commit.
canonical_resolve() {
    local link="${OPENSPEC_CANONICAL_DIR:-$HOME/.local/share/openspec/schemas/spec-driven-longish}"
    local dir top prefix head
    dir="$(readlink -f -- "$link" 2>/dev/null)" || return 0
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        return 0
    fi
    if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
        return 0
    fi
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
    prefix="$(git -C "$dir" rev-parse --show-prefix 2>/dev/null)" || return 0
    head="$(git -C "$dir" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || return 0
    CANON_DIR="$dir"
    CANON_TOP="$top"
    CANON_PREFIX="$prefix"
    CANON_HEAD="$head"
}

# --- Discovery ---
# fleet_roots, fleet_repos and top_value are openspec-fleet's _fleet_roots,
# fleet_repos and _fleet_top_value (private dotfiles), copied rather than
# sourced so that this public skill does not depend on the private tool.
# A change to how the fleet is found belongs in both places.

# The discovery roots, one per line, without a trailing slash: the words of
# FLEET_ROOTS, or $HOME/projects as one root when it is unset or empty.
fleet_roots() {
    local root
    local roots=()
    if [ -n "${FLEET_ROOTS:-}" ]; then
        read -r -a roots <<< "$FLEET_ROOTS"
    else
        roots=("$HOME/projects")
    fi
    for root in "${roots[@]}"; do
        printf '%s\n' "${root%/}"
    done
}

# The repositories, sorted, one path per line: every <root>/<org>/<project>
# and <root>/oss/<owner>/<repo> directory holding openspec/config.yaml,
# leaving out one whose path below its root passes through a .worktrees/ or
# vendor/ directory.
fleet_repos() {
    local root config repo
    local roots=()
    mapfile -t roots < <(fleet_roots)
    for root in "${roots[@]}"; do
        for config in "$root"/*/*/openspec/config.yaml "$root"/oss/*/*/openspec/config.yaml; do
            if [ ! -f "$config" ]; then continue; fi
            repo="${config%/openspec/config.yaml}"
            case "/${repo#"$root"/}" in
                */.worktrees/*|*/vendor/*) continue ;;
            esac
            printf '%s\n' "$repo"
        done
    done | LC_ALL=C sort -u
}

# How a status line names <repo>: its path below the first root holding it
# (the root as given, or resolved physically), else <parent>/<name>.
repo_label() { # repo
    local root phys parent
    while IFS= read -r root; do
        case $1 in
            "$root"/*) printf '%s\n' "${1#"$root"/}"; return 0 ;;
        esac
        if phys="$(cd -P -- "$root" 2>/dev/null && pwd -P)"; then
            case $1 in
                "$phys"/*) printf '%s\n' "${1#"$phys"/}"; return 0 ;;
            esac
        fi
    done < <(fleet_roots)
    parent="${1%/*}"
    printf '%s/%s\n' "${parent##*/}" "${1##*/}"
}

# The value of the first line of <file> that starts with "<key>:", without
# a trailing comment, the surrounding blanks or one pair of quotes, so an
# indented or commented-out key never counts; nothing when the file or the
# key is missing.
top_value() { # file key
    local line v
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then return 0; fi
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            "$2":*)
                v=" ${line#"$2":}"
                v="${v%%[[:space:]]#*}"
                v="${v#"${v%%[![:space:]]*}"}"
                v="${v%"${v##*[![:space:]]}"}"
                case $v in
                    \"*\"|\'*\') v="${v:1:${#v}-2}" ;;
                esac
                printf '%s\n' "$v"
                return 0
                ;;
        esac
    done < "$1"
    return 0
}

# --- Canonical comparison ---

# The directory holding the tree <commit> carries at the canonical
# directory's path, extracted once per commit. It is read from git objects
# with git archive run from the clone's top level (run below it, the path
# would apply a second time and the archive come out empty), as
# openspec-fleet schema-sync writes a copy. Empty when the commit holds
# nothing at that path. Status 1 when git or tar fails.
vendored_tree() { # commit
    local out="$TMPDIR_DRIFT/vendored/$1"
    if [ ! -d "$out" ]; then
        mkdir -p -- "$out" || return 1
        if git -C "$CANON_TOP" cat-file -e "$1:$CANON_PREFIX" 2>/dev/null; then
            if ! git -C "$CANON_TOP" archive -o "$out.tar" "$1:$CANON_PREFIX" \
                || ! tar -xf "$out.tar" -C "$out"; then
                rm -rf -- "$out"
                return 1
            fi
        fi
    fi
    printf '%s\n' "$out"
}

# The files below <dir>, one relative path per line in C order, leaving out
# the SOURCE sidecar at its top.
tree_files() { # dir
    (cd -- "$1" && find . ! -type d ! -path ./SOURCE -print) | sed 's|^\./||' | LC_ALL=C sort
}

# Compares the copy <dir> with the vendored tree <vdir>, SOURCE left out:
# the same file set and the same bytes. Writes to <out> the unified diff
# from the vendored tree to the copy, file by file in C order, a file on one
# side only shown against /dev/null; the vendored side is labelled
# <short>:<path in the clone> and the copy's side with its path in the
# repository. Status 0 when they are equal, 1 when they differ.
copy_diff() { # vdir dir short schema out
    local rel a b la lb rc=0
    : > "$5"
    while IFS= read -r rel; do
        a="$1/$rel"
        la="$3:$CANON_PREFIX$rel"
        b="$2/$rel"
        lb="openspec/schemas/$4/$rel"
        if [ ! -e "$a" ] && [ ! -L "$a" ]; then a=/dev/null; la=/dev/null; fi
        if [ ! -e "$b" ] && [ ! -L "$b" ]; then b=/dev/null; lb=/dev/null; fi
        if [ "$a" != /dev/null ] && [ "$b" != /dev/null ] && cmp -s -- "$a" "$b"; then
            continue
        fi
        rc=1
        diff -u --label "$la" --label "$lb" -- "$a" "$b" >> "$5" || true
    done < <({ tree_files "$1"; tree_files "$2"; } | LC_ALL=C sort -u)
    return "$rc"
}

# <file> capped at 40 lines, with a note of how many more it held.
print_capped() { # file
    local total
    total="$(wc -l < "$1")"
    if [ "$total" -le 40 ]; then
        cat -- "$1"
    else
        head -n 40 -- "$1"
        echo "[... $((total - 40)) more lines truncated]"
    fi
}

# The status of <repo>'s schema copy, one line on stdout. The capped diff of
# a locally modified copy goes to <difffile>, which is left empty otherwise.
# The states decided from the repository alone come first, so they print
# whatever the canonical's state. Always status 0.
repo_status() { # repo difffile
    local schema dir commit short full vdir
    : > "$2"
    schema="$(top_value "$1/openspec/config.yaml" schema)"
    schema="${schema:-spec-driven}"
    if [ "$schema" = spec-driven ]; then
        echo "upstream spec-driven (no copy; the recipe switches it)"
        return 0
    fi
    dir="$1/openspec/schemas/$schema"
    case $schema in
        */*|.|..) dir='' ;;
    esac
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "missing copy"
        return 0
    fi
    commit="$(top_value "$dir/SOURCE" commit)"
    if [[ ! $commit =~ ^[[:xdigit:]]{40}$ ]]; then
        echo "legacy copy (no SOURCE; run openspec-fleet schema-sync)"
        return 0
    fi
    if [ -z "$CANON_HEAD" ]; then
        echo "$NO_CANONICAL"
        return 0
    fi
    short="${commit:0:7}"
    if ! full="$(git -C "$CANON_TOP" rev-parse --verify --quiet "$commit^{commit}" 2>/dev/null)"; then
        echo "unknown commit (vendored $short is not in the canonical clone)"
        return 0
    fi
    short="${full:0:7}"
    if ! vdir="$(vendored_tree "$full")"; then
        echo "cannot read vendored $short from the canonical clone"
        return 0
    fi
    if ! copy_diff "$vdir" "$dir" "$short" "$schema" "$TMPDIR_DRIFT/full-diff"; then
        echo "locally modified (differs from vendored $short; diff below)"
        print_capped "$TMPDIR_DRIFT/full-diff" > "$2"
        return 0
    fi
    if [ "$full" = "$CANON_HEAD" ]; then
        echo "in sync"
    elif git -C "$CANON_TOP" merge-base --is-ancestor "$full" "$CANON_HEAD" 2>/dev/null; then
        echo "behind canonical (vendored $short, canonical ${CANON_HEAD:0:7})"
    else
        echo "ahead of canonical (vendored $short, canonical ${CANON_HEAD:0:7}; update the canonical clone)"
    fi
    return 0
}

# The canonical comparison for one repository: one status line, then the
# diff when the copy is locally modified.
repo_mode() { # repo
    local arg="$1" repo='' label status
    case $arg in
        /*) ;;
        *) arg="./$arg" ;;
    esac
    if ! repo="$(cd -P -- "$arg" 2>/dev/null && pwd -P)" || [ ! -f "$repo/openspec/config.yaml" ]; then
        echo "not an OpenSpec project (no openspec/config.yaml in ${repo:-$1})"
        return 0
    fi
    label="$(repo_label "$repo")"
    status="$(repo_status "$repo" "$TMPDIR_DRIFT/diff")"
    printf '%s  %s\n' "$label" "$status"
    if [ -s "$TMPDIR_DRIFT/diff" ]; then
        cat -- "$TMPDIR_DRIFT/diff"
    fi
}

# The canonical comparison for every repository: a line naming the
# canonical, one status line per repository with the statuses in one
# column, then each locally modified copy's diff under a line naming it.
fleet_mode() {
    local i width=0
    local repos=() labels=() statuses=()
    if [ -n "$CANON_HEAD" ]; then
        echo "canonical: $CANON_TOP @ ${CANON_HEAD:0:7}"
    else
        echo "canonical: none (run the machine playbook, tag openspec)"
    fi
    mapfile -t repos < <(fleet_repos)
    if [ ${#repos[@]} -eq 0 ]; then
        echo "no OpenSpec repository found under: $(fleet_roots | paste -sd ' ')"
        return 0
    fi
    for i in "${!repos[@]}"; do
        labels[i]="$(repo_label "${repos[i]}")"
        statuses[i]="$(repo_status "${repos[i]}" "$TMPDIR_DRIFT/diff.$i")"
        if [ ${#labels[i]} -gt "$width" ]; then
            width=${#labels[i]}
        fi
    done
    for i in "${!repos[@]}"; do
        printf '%-*s  %s\n' "$width" "${labels[i]}" "${statuses[i]}"
    done
    for i in "${!repos[@]}"; do
        if [ -s "$TMPDIR_DRIFT/diff.$i" ]; then
            printf '\ndiff: %s\n' "${labels[i]}"
            cat -- "$TMPDIR_DRIFT/diff.$i"
        fi
    done
}

# --- Upstream report (--upstream) ---
# The canonical schema directory is the overlay: its schema.yaml and
# templates/ are compared block by block with upstream spec-driven.

# --- YAML parser ---
# extract_field reads a top-level scalar (name, version, description,
# apply.tracks) or list (apply.requires). extract_artifact_field reads
# description or instruction for a given artifacts[].id. Both prefer yq,
# falling back to python3 + PyYAML. Output is verbatim.

have_yq() { command -v yq >/dev/null 2>&1; }
have_python_yaml() { python3 -c 'import yaml' >/dev/null 2>&1; }

extract_field() {
    local file="$1" path="$2"
    if have_yq; then
        yq -r ".$path" "$file"
    else
        python3 -c "
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
path = sys.argv[2].split('.')
for key in path:
    data = data[key]
if isinstance(data, list):
    print('\n'.join(map(str, data)))
else:
    print(data)
" "$file" "$path"
    fi
}

extract_artifact_field() {
    local file="$1" artifact_id="$2" field="$3"
    if have_yq; then
        yq -r ".artifacts[] | select(.id == \"$artifact_id\") | .$field" "$file"
    else
        python3 -c "
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
aid, field = sys.argv[2], sys.argv[3]
for artifact in data.get('artifacts', []):
    if artifact.get('id') == aid:
        print(artifact.get(field, ''))
        break
" "$file" "$artifact_id" "$field"
    fi
}

list_artifact_ids() {
    local file="$1"
    if have_yq; then
        yq -r '.artifacts[].id' "$file"
    else
        python3 -c "
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
for a in data.get('artifacts', []):
    print(a.get('id'))
" "$file"
    fi
}

# --- Classify ---
# classify_string returns unchanged, overlay, or diverged for a pair of
# strings. Byte-for-byte: no normalization, no whitespace stripping.

classify_string() {
    local upstream="$1" custom="$2"
    if [ "$upstream" = "$custom" ]; then
        echo unchanged
        return
    fi
    case "$custom" in
        *"$upstream"*) echo overlay ;;
        *) echo diverged ;;
    esac
}

declare -a CLASSIFY_ROWS=()

emit_row() {
    local label="$1" status="$2" notes="$3"
    CLASSIFY_ROWS+=("$label|$status|$notes")
}

classify_top_level() {
    local UV CV
    UV="$(extract_field "$UPSTREAM_SCHEMA" name)"
    CV="$(extract_field "$CUSTOM_SCHEMA" name)"
    emit_row "name" "rename intentional" "$CV ← $UV"

    UV="$(extract_field "$UPSTREAM_SCHEMA" version)"
    CV="$(extract_field "$CUSTOM_SCHEMA" version)"
    if [ "$UV" = "$CV" ]; then
        emit_row "version" "unchanged" "$UV"
    else
        emit_row "version" "diverged" "upstream $UV, custom $CV"
    fi

    UV="$(extract_field "$UPSTREAM_SCHEMA" description)"
    CV="$(extract_field "$CUSTOM_SCHEMA" description)"
    emit_row "description" "$(classify_string "$UV" "$CV")" ""
}

classify_artifacts() {
    local upstream_ids custom_ids
    upstream_ids="$(list_artifact_ids "$UPSTREAM_SCHEMA")"
    custom_ids="$(list_artifact_ids "$CUSTOM_SCHEMA")"

    local id UV CV field
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if grep -qxF "$id" <<<"$custom_ids"; then
            for field in description instruction; do
                UV="$(extract_artifact_field "$UPSTREAM_SCHEMA" "$id" "$field")"
                CV="$(extract_artifact_field "$CUSTOM_SCHEMA"   "$id" "$field")"
                emit_row "artifact $id.$field" "$(classify_string "$UV" "$CV")" ""
            done
        else
            emit_row "artifact $id (missing in overlay)" "diverged" "upstream-only"
        fi
    done <<<"$upstream_ids"

    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if ! grep -qxF "$id" <<<"$upstream_ids"; then
            emit_row "artifact $id (extra in overlay)" "diverged" "overlay-only"
        fi
    done <<<"$custom_ids"
}

classify_apply() {
    local UV CV
    UV="$(extract_field "$UPSTREAM_SCHEMA" apply.requires)"
    CV="$(extract_field "$CUSTOM_SCHEMA"   apply.requires)"
    if [ "$UV" = "$CV" ]; then
        emit_row "apply.requires" "unchanged" "$UV"
    else
        emit_row "apply.requires" "diverged" "upstream [$UV], custom [$CV]"
    fi

    UV="$(extract_field "$UPSTREAM_SCHEMA" apply.tracks)"
    CV="$(extract_field "$CUSTOM_SCHEMA"   apply.tracks)"
    if [ "$UV" = "$CV" ]; then
        emit_row "apply.tracks" "unchanged" "$UV"
    else
        emit_row "apply.tracks" "diverged" "upstream $UV, custom $CV"
    fi

    UV="$(extract_field "$UPSTREAM_SCHEMA" apply.instruction)"
    CV="$(extract_field "$CUSTOM_SCHEMA"   apply.instruction)"
    emit_row "apply.instruction" "$(classify_string "$UV" "$CV")" ""
}

# --- Diff renderer ---
# render_diff produces a fenced unified diff for a single block, capped at
# 40 lines. Its temporary files live under TMPDIR_DRIFT.

render_diff() {
    local label="$1" upstream="$2" custom="$3"
    local up_tmp cu_tmp
    up_tmp="$(mktemp -p "$TMPDIR_DRIFT" up.XXXXXX)"
    cu_tmp="$(mktemp -p "$TMPDIR_DRIFT" cu.XXXXXX)"
    printf '%s' "$upstream" > "$up_tmp"
    printf '%s' "$custom"   > "$cu_tmp"

    echo "<details><summary>diff: $label</summary>"
    echo
    echo '```diff'
    local diff_out total
    diff_out="$(diff -u "$up_tmp" "$cu_tmp" || true)"
    total="$(printf '%s\n' "$diff_out" | wc -l)"
    if [ "$total" -le 40 ]; then
        printf '%s\n' "$diff_out"
    else
        printf '%s\n' "$diff_out" | head -n 40
        echo "[... $((total - 40)) more lines truncated]"
    fi
    echo '```'
    echo "</details>"
    rm -f "$up_tmp" "$cu_tmp"
}

# --- Templates ---

declare -a TEMPLATE_ROWS=()

classify_templates() {
    local f status
    for f in proposal.md spec.md design.md tasks.md; do
        if [ ! -f "$UPSTREAM_TEMPLATES_DIR/$f" ] || [ ! -f "$CUSTOM_TEMPLATES_DIR/$f" ]; then
            TEMPLATE_ROWS+=("$f|missing|one side is absent")
            continue
        fi
        if cmp -s "$UPSTREAM_TEMPLATES_DIR/$f" "$CUSTOM_TEMPLATES_DIR/$f"; then
            status=unchanged
        else
            status=diverged
        fi
        TEMPLATE_ROWS+=("$f|$status|")
    done
}

# --- Render report ---

upstream_mode() {
    local candidate npm_root row label status notes UV CV aid fld
    local any_diverged=false

    if [ -z "$CANON_HEAD" ]; then
        echo "$NO_CANONICAL"
        return 0
    fi

    CUSTOM_NAME="${CANON_DIR##*/}"
    CUSTOM_SCHEMA="$CANON_DIR/schema.yaml"
    CUSTOM_TEMPLATES_DIR="$CANON_DIR/templates"

    # Locate upstream: the global npm root, else the newest nvm install.
    UPSTREAM_SCHEMA=""
    if npm_root="$(npm root -g 2>/dev/null)" && [ -f "$npm_root/@fission-ai/openspec/schemas/spec-driven/schema.yaml" ]; then
        UPSTREAM_SCHEMA="$npm_root/@fission-ai/openspec/schemas/spec-driven/schema.yaml"
    fi
    if [ -z "$UPSTREAM_SCHEMA" ]; then
        for candidate in "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/lib/node_modules/@fission-ai/openspec/schemas/spec-driven/schema.yaml; do
            if [ ! -f "$candidate" ]; then continue; fi
            if [ -z "$UPSTREAM_SCHEMA" ] || [ "$candidate" -nt "$UPSTREAM_SCHEMA" ]; then
                UPSTREAM_SCHEMA="$candidate"
            fi
        done
    fi
    if [ -z "$UPSTREAM_SCHEMA" ] || [ ! -f "$UPSTREAM_SCHEMA" ]; then
        cat <<EOF
OpenSpec is not installed globally. Install via:
  npm i -g @fission-ai/openspec
EOF
        return 0
    fi
    UPSTREAM_TEMPLATES_DIR="$(dirname "$UPSTREAM_SCHEMA")/templates"

    if [ ! -f "$CUSTOM_SCHEMA" ]; then
        echo "the canonical schema is missing at $CUSTOM_SCHEMA"
        return 0
    fi

    echo "upstream schema: $UPSTREAM_SCHEMA"
    echo "canonical schema: $CUSTOM_SCHEMA"

    if ! have_yq && ! have_python_yaml; then
        cat <<EOF
Drift check requires yq or python3 + PyYAML. Install one of:
  apt install yq      # or: brew install yq
  apt install python3-yaml
EOF
        return 0
    fi

    classify_top_level
    classify_artifacts
    classify_apply
    classify_templates

    UPSTREAM_VERSION="$(extract_field "$UPSTREAM_SCHEMA" version)"

    echo "Drift report: $CUSTOM_NAME vs upstream spec-driven@$UPSTREAM_VERSION"
    echo

    echo "| Block | Status | Notes |"
    echo "|---|---|---|"
    for row in "${CLASSIFY_ROWS[@]}"; do
        IFS='|' read -r label status notes <<<"$row"
        if [ "$status" = "diverged" ]; then any_diverged=true; fi
        echo "| \`$label\` | $status | $notes |"
    done

    echo
    echo "| Template | Status | Notes |"
    echo "|---|---|---|"
    for row in "${TEMPLATE_ROWS[@]}"; do
        IFS='|' read -r label status notes <<<"$row"
        if [ "$status" = "diverged" ]; then any_diverged=true; fi
        if [ "$status" = "missing" ]; then any_diverged=true; fi
        echo "| \`$label\` | $status | $notes |"
    done
    echo

    if [ "$any_diverged" = false ]; then
        echo "In sync with upstream spec-driven@$UPSTREAM_VERSION. No action needed."
        return 0
    fi

    for row in "${CLASSIFY_ROWS[@]}"; do
        IFS='|' read -r label status notes <<<"$row"
        [ "$status" != "diverged" ] && continue
        UV=""; CV=""
        case "$label" in
            "name"|"version"|"description"|"apply.requires"|"apply.tracks"|"apply.instruction")
                UV="$(extract_field "$UPSTREAM_SCHEMA" "$label")"
                CV="$(extract_field "$CUSTOM_SCHEMA"   "$label")"
                ;;
            "artifact "*" (missing in overlay)")
                aid="$(echo "$label" | sed -E 's/^artifact (.*) \(missing in overlay\)$/\1/')"
                UV="$(printf '%s\n---\n%s\n' \
                      "$(extract_artifact_field "$UPSTREAM_SCHEMA" "$aid" description)" \
                      "$(extract_artifact_field "$UPSTREAM_SCHEMA" "$aid" instruction)")"
                CV=""
                ;;
            "artifact "*" (extra in overlay)")
                aid="$(echo "$label" | sed -E 's/^artifact (.*) \(extra in overlay\)$/\1/')"
                UV=""
                CV="$(printf '%s\n---\n%s\n' \
                      "$(extract_artifact_field "$CUSTOM_SCHEMA" "$aid" description)" \
                      "$(extract_artifact_field "$CUSTOM_SCHEMA" "$aid" instruction)")"
                ;;
            "artifact "*.description|"artifact "*.instruction)
                aid="$(echo "$label" | awk '{print $2}' | sed 's/\..*//')"
                fld="${label##*.}"
                UV="$(extract_artifact_field "$UPSTREAM_SCHEMA" "$aid" "$fld")"
                CV="$(extract_artifact_field "$CUSTOM_SCHEMA"   "$aid" "$fld")"
                ;;
        esac
        render_diff "$label" "$UV" "$CV"
    done

    cat <<EOF

No files were modified. To absorb upstream changes:
  1. For diverged schema rows: open $CUSTOM_SCHEMA,
     locate the affected block and merge the upstream change in, keeping
     the canonical's own prepended and appended policy blocks.
  2. For diverged template rows: compare
     $UPSTREAM_TEMPLATES_DIR/<filename> with
     $CUSTOM_TEMPLATES_DIR/<filename> and merge the upstream
     change. A canonical template may extend the upstream one on purpose,
     so review the diff before replacing anything.
  3. Commit the change in the canonical clone ($CANON_TOP), then
     vendor it into each repository with openspec-fleet schema-sync.
  4. Re-run drift-check.sh --upstream to confirm every row returns to
     \`unchanged\` or \`overlay\`.
EOF
}

# --- Main ---

canonical_resolve
case $MODE in
    fleet) fleet_mode ;;
    upstream) upstream_mode ;;
    *) repo_mode "${OPERANDS[0]:-.}" ;;
esac
exit 0
