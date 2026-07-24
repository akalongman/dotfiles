#!/usr/bin/env bash
# Global, project-agnostic git-worktree orchestrator.
# Reachable as the `worktree` CLI (~/bin/worktree) and as Claude Code
# WorktreeCreate/WorktreeRemove hooks (~/.claude/settings.json).
# Sourcable: defines wt_*/cmd_* functions without executing.

if [ -t 2 ]; then
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_BOLD=''; C_DIM=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

wt_tag()   { printf '%s[worktree]%s ' "$C_CYAN" "$C_RESET" >&2; }
wt_info()  { wt_tag; printf '%s\n' "$*" >&2; }
wt_field() { wt_tag; printf '%s%-8s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2" >&2; }
wt_phase() { printf '\n' >&2; wt_tag; printf '%s>> %s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
wt_ok()    { printf '\n' >&2; wt_tag; printf '%s%sDone:%s %s\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$*" >&2; }
wt_warn()  { wt_tag; printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
wt_fail()  { wt_tag; printf '%s%sFAILED:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2; }

wt_usage() {
    cat >&2 <<'EOF'
worktree — project-agnostic git worktree orchestrator

  worktree create <name>        create + provision a worktree
  worktree remove <path|name>   teardown + remove a worktree
  worktree list                 list this repo's worktrees
  worktree doctor               diagnose tools + project readiness

EOF
}

# --- Detection -------------------------------------------------------------

wt_is_worktree() { # base_path -> 0 if worktree
    local git_path="$1/.git"
    [ -f "$git_path" ] || return 1
    case "$(cat "$git_path" 2>/dev/null)" in
        "gitdir: "*) return 0 ;;
        *) return 1 ;;
    esac
}

wt_safe_name() { printf '%s' "$1" | tr '/' '-'; }

wt_resolve_repo_dir() {
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        printf '%s' "$CLAUDE_PROJECT_DIR"
        return 0
    fi
    git rev-parse --show-toplevel 2>/dev/null
}

# --- Provisioning target discovery -----------------------------------------

wt_manifest_has_script() { # manifest target -> 0 if present
    [ -f "$1" ] || return 1
    jq -e --arg t "$2" '.scripts[$t] // empty' "$1" >/dev/null 2>&1
}

wt_npm_pm() { # dir -> yarn|pnpm|npm
    if [ -f "$1/yarn.lock" ]; then printf 'yarn'
    elif [ -f "$1/pnpm-lock.yaml" ]; then printf 'pnpm'
    else printf 'npm'; fi
}

wt_detect_primitive() { # dir target -> composer|yarn|pnpm|npm|""
    local dir="$1" target="$2" has_composer='' has_npm=''
    wt_manifest_has_script "$dir/composer.json" "$target" && has_composer=1
    wt_manifest_has_script "$dir/package.json" "$target" && has_npm=1
    if [ -n "$has_composer" ] && [ -n "$has_npm" ]; then
        wt_warn "both composer.json and package.json define $target; running composer's, ignoring package.json's."
    fi
    if [ -n "$has_composer" ]; then printf 'composer'; return 0; fi
    if [ -n "$has_npm" ]; then wt_npm_pm "$dir"; return 0; fi
    printf ''
}

wt_run_target() { # dir target -> exit code of the target (0 if none)
    local dir="$1" target="$2" pm
    pm="$(wt_detect_primitive "$dir" "$target")"
    case "$pm" in
        composer)
            local composer_bin="composer"
            [ -x "$dir/bin/composer" ] && composer_bin="$dir/bin/composer"
            ( cd "$dir" && "$composer_bin" run-script "$target" ) ;;
        yarn|pnpm|npm)
            ( cd "$dir" && "$pm" run "$target" ) ;;
        *) return 0 ;;
    esac
}

# --- .worktreeinclude copy -------------------------------------------------

wt_apply_include() { # repo_dir worktree_dir
    local repo_dir="$1" wt_dir="$2"
    local manifest="$repo_dir/.worktreeinclude"
    [ -f "$manifest" ] || return 0
    wt_phase "Copying .worktreeinclude entries"
    local line entry src dest matched
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        entry="${line#/}"                       # strip leading anchor slash
        matched=''
        local prev_dir; prev_dir="$(pwd)"
        cd "$repo_dir" || continue
        local g
        for g in $entry; do
            [ -e "$g" ] || continue
            matched=1
            src="$repo_dir/$g"
            dest="$wt_dir/$g"
            if [ -d "$src" ]; then
                # Directory entry: merge contents, never clobbering files already
                # present (a tracked placeholder like .gitignore makes the dir exist,
                # so a whole-dir skip would miss the untracked secrets inside it).
                mkdir -p "$dest"
                cp -an "$src/." "$dest/" 2>/dev/null || cp -rn "$src/." "$dest/"
                wt_field "merge" "$g/"
            elif [ -e "$dest" ]; then
                wt_field "skip" "$g (already present)"
            else
                mkdir -p "$(dirname "$dest")"
                cp -a "$src" "$dest"
                wt_field "copy" "$g"
            fi
        done
        cd "$prev_dir" || true
        [ -n "$matched" ] || wt_warn ".worktreeinclude entry matched nothing: $line"
    done < "$manifest"
    return 0
}

# --- Create ----------------------------------------------------------------

wt_default_branch() { # repo_dir -> base ref
    local repo_dir="$1" def ref
    def="$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [ -z "$def" ] && def="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    [ -z "$def" ] && def="main"
    if git -C "$repo_dir" rev-parse --verify --quiet "origin/$def" >/dev/null 2>&1; then
        ref="origin/$def"
    else
        ref="$def"
    fi
    printf '%s' "$ref"
}

wt_rollback() { # repo_dir worktree_dir
    wt_warn "Rolling back $2"
    git -C "$1" worktree remove --force "$2" 2>/dev/null || rm -rf "$2"
}

wt_create() { # name -> prints worktree path on stdout
    local name="$1"
    command -v git >/dev/null 2>&1 || { wt_fail "git not found"; return 1; }
    command -v jq  >/dev/null 2>&1 || { wt_fail "jq not found"; return 1; }

    local repo_dir; repo_dir="$(wt_resolve_repo_dir)"
    [ -n "$repo_dir" ] || { wt_fail "not inside a git repository"; return 1; }
    if wt_is_worktree "$repo_dir"; then
        wt_fail "already inside a worktree; create from the main checkout."; return 1
    fi

    local branch="$name" safe wt_path base
    safe="$(wt_safe_name "$name")"
    wt_path="$repo_dir/.worktrees/$safe"
    base="$(wt_default_branch "$repo_dir")"

    wt_info "${C_BOLD}Initializing worktree${C_RESET}"
    wt_field "branch:" "$branch"
    wt_field "base:" "$base"
    wt_field "path:" "${wt_path#"$repo_dir"/}"

    if [ -e "$wt_path" ]; then wt_fail "$wt_path already exists"; return 1; fi

    wt_phase "Creating git worktree"
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repo_dir" worktree add "$wt_path" "$branch" >&2 || { wt_fail "git worktree add failed"; return 1; }
    else
        git -C "$repo_dir" worktree add -b "$branch" "$wt_path" "$base" >&2 || { wt_fail "git worktree add failed"; return 1; }
    fi

    wt_apply_include "$repo_dir" "$wt_path"

    local primitive; primitive="$(wt_detect_primitive "$wt_path" worktree:setup)"
    if [ -z "$primitive" ]; then
        wt_warn "no worktree:setup target found; created an unprovisioned worktree."
    else
        wt_phase "Running worktree:setup ($primitive)"
        if ! wt_run_target "$wt_path" worktree:setup >&2; then
            wt_fail "worktree:setup failed"; wt_rollback "$repo_dir" "$wt_path"; return 1
        fi
    fi

    if [ ! -d "$wt_path" ] || [ ! -e "$wt_path/.git" ]; then
        wt_fail "postflight: worktree missing after setup"; wt_rollback "$repo_dir" "$wt_path"; return 1
    fi

    wt_ok "Worktree ready at $wt_path"
    printf '%s\n' "$wt_path"
}

cmd_create() {
    [ -n "${1:-}" ] || { wt_fail "usage: worktree create <name>"; return 2; }
    wt_create "$1"
}

# --- Remove ----------------------------------------------------------------

wt_warn_unpushed() { # worktree_dir
    local wt_dir="$1" branch count
    branch="$(git -C "$wt_dir" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] || return 0
    if ! git -C "$wt_dir" rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
        wt_warn "branch '$branch' has no upstream (never pushed). Its commits stay in the main repo."
        return 0
    fi
    count="$(git -C "$wt_dir" rev-list --count '@{u}..HEAD' 2>/dev/null || printf '0')"
    [ "$count" -gt 0 ] 2>/dev/null && wt_warn "branch '$branch' has $count unpushed commit(s). They stay in the main repo."
    return 0
}

wt_remove() { # path|name
    local arg="$1" repo_dir wt_path candidate
    repo_dir="$(wt_resolve_repo_dir)"
    [ -n "$repo_dir" ] || { wt_fail "not inside a git repository"; return 1; }
    # A branch name may contain slashes (feature/foo), so a bare slash does NOT
    # imply a path. Resolve the worktree-name candidate first; fall back to a
    # literal path only when that candidate does not exist.
    candidate="$repo_dir/.worktrees/$(wt_safe_name "$arg")"
    case "$arg" in
        /*) wt_path="$arg" ;;
        *)
            if [ -d "$candidate" ]; then
                wt_path="$candidate"
            elif [ -d "$arg" ]; then
                wt_path="$(cd "$arg" && pwd)"
            else
                wt_path="$candidate"
            fi
            ;;
    esac

    if [ ! -d "$wt_path" ]; then wt_warn "$wt_path is not a directory; nothing to remove."; return 0; fi
    if ! wt_is_worktree "$wt_path"; then wt_fail "$wt_path is not a git worktree."; return 1; fi

    wt_info "${C_BOLD}Removing worktree${C_RESET}"
    wt_field "path:" "$wt_path"
    wt_warn_unpushed "$wt_path"

    local td_pm; td_pm="$(wt_detect_primitive "$wt_path" worktree:teardown)"
    if [ -n "$td_pm" ]; then
        wt_phase "Running worktree:teardown ($td_pm)"
        wt_run_target "$wt_path" worktree:teardown >&2 || wt_warn "worktree:teardown failed; continuing."
    fi

    wt_phase "Removing git worktree"
    if git -C "$repo_dir" worktree remove "$wt_path" >&2; then
        wt_ok "Worktree removed"; return 0
    fi
    wt_fail "git worktree remove refused (uncommitted changes?). Resolve with: git -C \"$repo_dir\" worktree remove --force \"$wt_path\""
    return 1
}

cmd_remove() {
    [ -n "${1:-}" ] || { wt_fail "usage: worktree remove <path|name>"; return 2; }
    wt_remove "$1"
}

# --- list / doctor ---------------------------------------------------------

cmd_list() {
    local repo_dir; repo_dir="$(wt_resolve_repo_dir)"
    [ -n "$repo_dir" ] || { wt_fail "not inside a git repository"; return 1; }
    git -C "$repo_dir" worktree list
}

cmd_doctor() {
    local repo_dir; repo_dir="$(wt_resolve_repo_dir)"
    wt_info "${C_BOLD}worktree doctor${C_RESET}"

    local t
    for t in git jq; do
        if command -v "$t" >/dev/null 2>&1; then wt_field "tool" "$t ok"; else wt_warn "missing required tool: $t"; fi
    done

    [ -n "$repo_dir" ] || { wt_warn "not inside a git repository"; return 0; }

    local setup_pm teardown_pm
    setup_pm="$(wt_detect_primitive "$repo_dir" worktree:setup)"
    teardown_pm="$(wt_detect_primitive "$repo_dir" worktree:teardown)"
    [ -n "$setup_pm" ] && wt_field "setup" "$setup_pm" || wt_warn "no worktree:setup target (worktrees will be bare)"
    [ -n "$teardown_pm" ] && wt_field "teardown" "$teardown_pm" || wt_field "teardown" "none"

    if [ -f "$repo_dir/.worktreeinclude" ]; then
        local line entry g found
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|\#*) continue ;; esac
            entry="${line#/}"; found=''
            ( cd "$repo_dir" || exit 0; for g in $entry; do [ -e "$g" ] && exit 0; done; exit 1 ) && found=1
            [ -n "$found" ] || wt_warn ".worktreeinclude entry missing in checkout: $line"
        done < "$repo_dir/.worktreeinclude"
    fi

    local settings="$repo_dir/.claude/settings.json"
    if [ -f "$settings" ] && grep -qE 'WorktreeCreate|WorktreeRemove' "$settings" 2>/dev/null; then
        wt_warn "project defines its own WorktreeCreate/WorktreeRemove hook in .claude/settings.json; it will double-run alongside the global hook. Remove it to rely on the global engine."
    fi
    return 0
}

# --- Claude hook adapters --------------------------------------------------

wt_hook_log() { # repo_dir payload basename
    local repo_dir="$1" payload="$2" name="$3"
    local dir="$repo_dir/storage/logs"
    [ -d "$dir" ] || return 0
    { date -Iseconds; printf '%s\n---\n' "$payload"; } >> "$dir/$name" 2>/dev/null || true
}

cmd_hook_create() {
    local input name repo_dir
    input="$(cat)"
    repo_dir="$(wt_resolve_repo_dir)"
    wt_hook_log "$repo_dir" "$input" "claude-worktree-create.log"
    name="$(printf '%s' "$input" | jq -r '.name // empty' 2>/dev/null)"
    [ -n "$name" ] || name="claude-wt-$(date +%s)"
    wt_create "$name"
}

cmd_hook_remove() {
    local input path repo_dir
    input="$(cat)"
    repo_dir="$(wt_resolve_repo_dir)"
    wt_hook_log "$repo_dir" "$input" "claude-worktree-remove.log"
    path="$(printf '%s' "$input" | jq -r '.worktree_path // empty' 2>/dev/null)"
    [ -n "$path" ] || { wt_fail "no worktree_path in hook payload"; return 1; }
    wt_remove "$path"
}

# --- Dispatch --------------------------------------------------------------

main() {
    set -uo pipefail
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        create)      cmd_create "$@" ;;
        remove)      cmd_remove "$@" ;;
        list)        cmd_list "$@" ;;
        doctor)      cmd_doctor "$@" ;;
        hook-create) cmd_hook_create "$@" ;;
        hook-remove) cmd_hook_remove "$@" ;;
        help|-h|--help) wt_usage ;;
        *) wt_fail "unknown subcommand: $cmd"; wt_usage; return 2 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
