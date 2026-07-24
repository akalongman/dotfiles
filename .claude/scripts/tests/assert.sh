#!/usr/bin/env bash
# Plain-bash test helpers. No bats dependency.

TESTS_RUN=0
TESTS_FAILED=0
TMPDIRS=()

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf 'FAIL: %s\n' "$1" >&2; }

assert_eq() { # actual expected msg
    if [ "$1" = "$2" ]; then _pass; else _fail "$3 (expected '$2', got '$1')"; fi
}

assert_contains() { # haystack needle msg
    case "$1" in
        *"$2"*) _pass ;;
        *) _fail "$3 (missing '$2')" ;;
    esac
}

assert_ok() { # msg cmd...
    local msg="$1"; shift
    if "$@" >/dev/null 2>&1; then _pass; else _fail "$msg (command failed: $*)"; fi
}

assert_fail() { # msg cmd...
    local msg="$1"; shift
    if "$@" >/dev/null 2>&1; then _fail "$msg (command unexpectedly succeeded: $*)"; else _pass; fi
}

assert_file() { # path msg
    if [ -e "$1" ]; then _pass; else _fail "$2 (no such path: $1)"; fi
}

assert_nofile() { # path msg
    if [ -e "$1" ]; then _fail "$2 (path exists: $1)"; else _pass; fi
}

mk_repo() {
    local dir; dir="$(mktemp -d)"
    TMPDIRS+=("$dir")
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name t
    git -C "$dir" config commit.gpgsign false   # global gpgsign=true would hang/fail in tests
    printf 'root\n' > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -qm init
    printf '%s' "$dir"
}

mk_setup_target() { # dir kind
    local dir="$1" kind="$2"
    # Markers are gitignored so the worktree stays clean for non-force removal,
    # mirroring real projects where setup artifacts (vendor/, node_modules/) are ignored.
    printf '.wt-setup-ran\n.wt-teardown-ran\n' > "$dir/.gitignore"
    case "$kind" in
        composer)
            printf '{"scripts":{"worktree:setup":"touch .wt-setup-ran","worktree:teardown":"touch .wt-teardown-ran"}}\n' > "$dir/composer.json"
            git -C "$dir" add composer.json .gitignore; git -C "$dir" commit -qm composer ;;
        npm)
            printf '{"scripts":{"worktree:setup":"touch .wt-setup-ran","worktree:teardown":"touch .wt-teardown-ran"}}\n' > "$dir/package.json"
            printf '{}\n' > "$dir/package-lock.json"
            git -C "$dir" add package.json package-lock.json .gitignore; git -C "$dir" commit -qm npm ;;
        yarn)
            printf '{"scripts":{"worktree:setup":"touch .wt-setup-ran","worktree:teardown":"touch .wt-teardown-ran"}}\n' > "$dir/package.json"
            printf '\n' > "$dir/yarn.lock"
            git -C "$dir" add package.json yarn.lock .gitignore; git -C "$dir" commit -qm yarn ;;
        none) git -C "$dir" add .gitignore; git -C "$dir" commit -qm gitignore ;;
    esac
}

finish() {
    printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED" >&2
    for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done
    [ "$TESTS_FAILED" -eq 0 ]
}
