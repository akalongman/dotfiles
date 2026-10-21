#!/usr/bin/env bash
# Tests for scripts/drift-check.sh.
#
# Every case runs the script as a subprocess against a throwaway tree: a
# canonical clone of two commits (v1, v2) with a link into it, fixture
# repositories holding schema copies vendored from those commits, and an
# npm stub first on PATH naming a fixture global root that holds the
# upstream spec-driven schema. No case reads this machine's projects or its
# canonical schema, and no case needs yq or a global OpenSpec install.

set -uo pipefail

# Nothing the caller set reaches the cases: a GIT_DIR exported by yadm enter
# or a hook would send the fixture commits into that repository, and a knob
# of this suite left set would change what a case sees.
mapfile -t git_local_vars < <(git rev-parse --local-env-vars)
unset -v "${git_local_vars[@]}" OPENSPEC_CANONICAL_DIR FLEET_ROOTS

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../../scripts/tests/assert.sh"
DC="$HERE/../scripts/drift-check.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
ROOT="$(cd -P -- "$ROOT" && pwd -P)"

# An empty git repository at <dir> with assert.sh's identity and signing off.
fixture_git() { # dir
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email t@t.t
    git -C "$1" config user.name t
    git -C "$1" config commit.gpgsign false
}

# A fixture repository at <dir> whose openspec/config.yaml starts with
# <schema line>, or has no schema line when it is empty.
project() { # dir schema-line
    fixture_git "$1"
    mkdir -p "$1/openspec"
    {
        if [ -n "$2" ]; then printf '%s\n\n' "$2"; fi
        printf 'context: |\n  Fixture project.\n'
    } > "$1/openspec/config.yaml"
}

# The canonical tree of <commit> as <dir>'s copy, with a SOURCE naming
# <source commit> (default <commit>).
vendor() { # dir commit [source-commit]
    local copy="$1/openspec/schemas/spec-driven-longish"
    mkdir -p "$copy"
    git -C "$ROOT/canon" archive "$2:schemas/spec-driven-longish" | tar -x -C "$copy"
    printf 'repo: https://github.com/akalongman/openspec-schemas\npath: schemas/spec-driven-longish\ncommit: %s\n' "${3-$2}" > "$copy/SOURCE"
}

# Commits <dir>'s openspec tree, so a later git status shows any write.
seal() { # dir
    git -C "$1" add -- openspec && git -C "$1" commit -qm fixture
}

# --- The upstream spec-driven schema, under a fixture global npm root ---

UPSTREAM="$ROOT/npmroot/@fission-ai/openspec/schemas/spec-driven"
mkdir -p "$UPSTREAM/templates" "$ROOT/bin"
cat > "$UPSTREAM/schema.yaml" <<'EOF'
name: spec-driven
version: 1
description: Spec-driven workflow
artifacts:
  - id: proposal
    generates: proposal.md
    description: Why and what
    template: proposal.md
    instruction: |
      Write the proposal.
apply:
  requires:
    - proposal
  tracks: tasks.md
  instruction: Work through the tasks.
EOF
for t in proposal spec design tasks; do printf '## %s\n' "$t" > "$UPSTREAM/templates/$t.md"; done
cat > "$ROOT/bin/npm" <<EOF
#!/bin/sh
printf '%s\n' '$ROOT/npmroot'
EOF
chmod +x "$ROOT/bin/npm"
export PATH="$ROOT/bin:$PATH"

# --- The canonical clone: v1, then v2 changing proposal.md ---

fixture_git "$ROOT/canon"
S="$ROOT/canon/schemas/spec-driven-longish"
mkdir -p "$S/templates"
cat > "$S/schema.yaml" <<'EOF'
name: spec-driven-longish
version: 1
description: Spec-driven workflow with house additions
artifacts:
  - id: proposal
    generates: proposal.md
    description: Why and what
    template: proposal.md
    instruction: |
      Write the proposal.
      Keep it short.
apply:
  requires:
    - proposal
  tracks: tasks.md
  instruction: Work through the tasks.
EOF
printf '## Why\n\nproposal v1\n' > "$S/templates/proposal.md"
for t in spec design tasks; do printf '## %s\n' "$t" > "$S/templates/$t.md"; done
git -C "$ROOT/canon" add -- schemas && git -C "$ROOT/canon" commit -qm v1
V1FULL="$(git -C "$ROOT/canon" rev-parse HEAD)"
V1="${V1FULL:0:7}"
printf '## Why\n\nproposal v2\n' > "$S/templates/proposal.md"
git -C "$ROOT/canon" add -- schemas && git -C "$ROOT/canon" commit -qm v2
V2FULL="$(git -C "$ROOT/canon" rev-parse HEAD)"
V2="${V2FULL:0:7}"
ln -s "$S" "$ROOT/link"
export OPENSPEC_CANONICAL_DIR="$ROOT/link"

# A second clone whose HEAD is v1 while its origin/HEAD holds v2: the clone
# of a machine that fetched but has not moved on.
git clone -q "$ROOT/canon" "$ROOT/canon-old"
git -C "$ROOT/canon-old" reset -q --hard "$V1FULL"

# --- The five fixture repositories of the fleet ---

SYNC="$ROOT/projects/acme/sync"
BEHIND="$ROOT/projects/acme/behind"
MOD="$ROOT/projects/acme/mod"
LEGACY="$ROOT/projects/beta/legacy"
UP="$ROOT/projects/beta/up"

project "$SYNC" 'schema: spec-driven-longish'; vendor "$SYNC" "$V2FULL"; seal "$SYNC"
project "$BEHIND" 'schema: spec-driven-longish'; vendor "$BEHIND" "$V1FULL"; seal "$BEHIND"
project "$MOD" 'schema: spec-driven-longish'; vendor "$MOD" "$V1FULL"
MC="$MOD/openspec/schemas/spec-driven-longish"
printf 'edited line\n' >> "$MC/templates/proposal.md"
printf 'note\n' > "$MC/templates/notes.md"
rm "$MC/templates/tasks.md"
seal "$MOD"
project "$LEGACY" 'schema: spec-driven-longish'; vendor "$LEGACY" "$V1FULL"
rm "$LEGACY/openspec/schemas/spec-driven-longish/SOURCE"; seal "$LEGACY"
project "$UP" 'schema: spec-driven'; seal "$UP"

# --- Fixtures outside the fleet root, one per remaining state ---

MISSING="$ROOT/extra/acme/missing"; project "$MISSING" 'schema: spec-driven-longish'
NOSCHEMA="$ROOT/extra/acme/noschema"; project "$NOSCHEMA" ''
BADCOMMIT="$ROOT/extra/acme/badcommit"; project "$BADCOMMIT" 'schema: spec-driven-longish'
vendor "$BADCOMMIT" "$V1FULL" "${V1FULL:0:12}"
UNKNOWN="$ROOT/extra/acme/unknown"; project "$UNKNOWN" 'schema: spec-driven-longish'
vendor "$UNKNOWN" "$V1FULL" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BIG="$ROOT/extra/acme/big"; project "$BIG" 'schema: spec-driven-longish'; vendor "$BIG" "$V1FULL"
for i in $(seq 1 60); do printf 'added %d\n' "$i"; done >> "$BIG/openspec/schemas/spec-driven-longish/templates/proposal.md"
mkdir -p "$ROOT/plain"

# A second discovery root: an oss repository with a legacy copy, and one
# under vendor/ that discovery leaves out.
OSS="$ROOT/more/oss/x/y"; project "$OSS" 'schema: spec-driven-longish'; vendor "$OSS" "$V1FULL"
rm "$OSS/openspec/schemas/spec-driven-longish/SOURCE"
VENDORED="$ROOT/more/vendor/pkg"; project "$VENDORED" 'schema: spec-driven-longish'

# --- The brief's cases ---

assert_contains "$(cd "$SYNC" && bash "$DC")" "in sync" "in sync"
assert_contains "$(cd "$BEHIND" && bash "$DC")" "behind canonical (vendored $V1, canonical $V2)" "behind"
assert_contains "$(cd "$MOD" && bash "$DC")" "locally modified (differs from vendored $V1; diff below)" "locally modified"
assert_contains "$(cd "$MOD" && bash "$DC")" "+edited line" "diff shown"
assert_contains "$(cd "$LEGACY" && bash "$DC")" "legacy copy" "legacy"
assert_contains "$(cd "$UP" && bash "$DC")" "upstream spec-driven" "upstream"
assert_eq "$(FLEET_ROOTS=$ROOT/projects bash "$DC" --fleet | grep -c -e 'in sync' -e 'behind canonical' -e 'locally modified' -e 'legacy copy' -e 'upstream spec-driven')" "5" "fleet prints one status per repo"
assert_contains "$(FLEET_ROOTS=$ROOT/projects bash "$DC" --fleet)" "canonical: $ROOT/canon @ $V2" "fleet names the canonical"
# The upstream report runs before the link goes: without a canonical it
# prints only the no canonical line.
assert_contains "$(cd "$SYNC" && bash "$DC" --upstream)" "Drift report:" "upstream report kept"
rm "$ROOT/link"; assert_contains "$(cd "$SYNC" && bash "$DC")" "no canonical (run the machine playbook, tag openspec)" "missing link"
ln -s "$S" "$ROOT/link"

# --- Single mode: the line, the label, the diff ---

assert_eq "$(cd "$SYNC" && bash "$DC")" "acme/sync  in sync" "single mode prints label, two spaces, status"
assert_eq "$(cd "$LEGACY" && bash "$DC")" "beta/legacy  legacy copy (no SOURCE; run openspec-fleet schema-sync)" "legacy line in full"
assert_eq "$(cd "$UP" && bash "$DC")" "beta/up  upstream spec-driven (no copy; the recipe switches it)" "upstream line in full"
assert_contains "$(cd "$ROOT/plain" && bash "$DC" "$MOD")" "acme/mod  locally modified (differs from vendored $V1; diff below)" "REPO operand from another directory"
ln -s "$SYNC" "$ROOT/synclink"
assert_eq "$(bash "$DC" "$ROOT/synclink")" "acme/sync  in sync" "REPO is resolved physically"
assert_eq "$(cd "$ROOT/plain" && bash "$DC")" "not an OpenSpec project (no openspec/config.yaml in $ROOT/plain)" "not an OpenSpec project"
out="$(cd "$MOD" && bash "$DC")"
assert_contains "$out" "--- $V1:schemas/spec-driven-longish/templates/proposal.md" "diff labels the vendored side with the commit"
assert_contains "$out" "+++ openspec/schemas/spec-driven-longish/templates/proposal.md" "diff labels the copy side with its path"
assert_contains "$out" "$(printf -- '--- /dev/null\n+++ openspec/schemas/spec-driven-longish/templates/notes.md')" "a file only in the copy is shown"
assert_contains "$out" "$(printf -- '--- %s:schemas/spec-driven-longish/templates/tasks.md\n+++ /dev/null' "$V1")" "a file only in the vendored tree is shown"
assert_eq "$(printf '%s\n' "$out" | grep -c -e "$ROOT" -e '/tmp')" "0" "diff names no temporary path"

# --- The remaining states (K1, K2) ---

assert_eq "$(bash "$DC" "$MISSING")" "acme/missing  missing copy" "missing copy"
assert_eq "$(bash "$DC" "$NOSCHEMA")" "acme/noschema  upstream spec-driven (no copy; the recipe switches it)" "no schema line reads upstream"
assert_eq "$(bash "$DC" "$BADCOMMIT")" "acme/badcommit  legacy copy (no SOURCE; run openspec-fleet schema-sync)" "malformed commit line reads legacy"
assert_eq "$(bash "$DC" "$UNKNOWN")" "acme/unknown  unknown commit (vendored aaaaaaa is not in the canonical clone)" "unknown commit"
assert_eq "$(OPENSPEC_CANONICAL_DIR=$ROOT/canon-old/schemas/spec-driven-longish bash "$DC" "$SYNC")" "acme/sync  ahead of canonical (vendored $V2, canonical $V1; update the canonical clone)" "ahead of canonical"
assert_eq "$(OPENSPEC_CANONICAL_DIR=$ROOT/canon-old/schemas/spec-driven-longish bash "$DC" "$BEHIND")" "acme/behind  in sync" "in sync with an older clone"
out="$(bash "$DC" "$BIG")"
assert_contains "$out" "[... 26 more lines truncated]" "diff capped at 40 lines with the note"
assert_eq "$(printf '%s\n' "$out" | wc -l)" "42" "status line, 40 diff lines, the note"

# The canonical is the clone's HEAD tree: neither an uncommitted edit nor an
# untracked file under the canonical directory counts.
printf 'uncommitted\n' >> "$S/templates/proposal.md"
printf 'untracked\n' > "$S/templates/new.md"
assert_eq "$(bash "$DC" "$SYNC")" "acme/sync  in sync" "working tree of the canonical is not read"
git -C "$ROOT/canon" checkout -q -- schemas
rm "$S/templates/new.md"

# An exported GIT_DIR (yadm enter) does not redirect the reads of the clone.
git init -q --bare "$ROOT/decoy.git"
assert_eq "$(GIT_DIR=$ROOT/decoy.git bash "$DC" "$SYNC")" "acme/sync  in sync" "exported GIT_DIR is ignored"

# --- No canonical (K3) ---

ln -s "$ROOT/nowhere/schemas/spec-driven-longish" "$ROOT/dangling"
mkdir -p "$ROOT/plaincanon"
fixture_git "$ROOT/emptyclone"
assert_eq "$(OPENSPEC_CANONICAL_DIR=$ROOT/dangling bash "$DC" "$SYNC")" "acme/sync  no canonical (run the machine playbook, tag openspec)" "dangling link"
assert_eq "$(OPENSPEC_CANONICAL_DIR=$ROOT/plaincanon bash "$DC" "$SYNC")" "acme/sync  no canonical (run the machine playbook, tag openspec)" "canonical outside a git work tree"
assert_eq "$(OPENSPEC_CANONICAL_DIR=$ROOT/emptyclone bash "$DC" "$SYNC")" "acme/sync  no canonical (run the machine playbook, tag openspec)" "canonical clone without a commit"
assert_contains "$(OPENSPEC_CANONICAL_DIR=$ROOT/dangling bash "$DC" "$LEGACY")" "legacy copy" "legacy reads legacy without a canonical"
out="$(OPENSPEC_CANONICAL_DIR=$ROOT/dangling FLEET_ROOTS=$ROOT/projects bash "$DC" --fleet)"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" "canonical: none (run the machine playbook, tag openspec)" "fleet header without a canonical"
assert_eq "$(OPENSPEC_CANONICAL_DIR=$ROOT/dangling bash "$DC" --upstream)" "no canonical (run the machine playbook, tag openspec)" "upstream without a canonical"

# --- The fleet (K4) ---

out="$(FLEET_ROOTS=$ROOT/projects bash "$DC" --fleet)"
assert_contains "$out" "$(printf 'acme/sync    in sync\nbeta/legacy  legacy copy')" "statuses align two spaces after the longest label"
list="$(printf '%s\n' "$out" | sed '/^$/q')"
assert_eq "$(printf '%s\n' "$list" | grep -c -e '^diff:' -e 'edited line')" "0" "the list holds no diff"
assert_contains "${out#*diff: acme/mod}" "+edited line" "the diff follows the list under its label"
out="$(FLEET_ROOTS="$ROOT/projects $ROOT/more/ $ROOT/projects" bash "$DC" --fleet)"
assert_contains "$out" "oss/x/y      legacy copy" "an oss repository is found and labelled"
assert_eq "$(printf '%s\n' "$out" | grep -c 'vendor/pkg')" "0" "a repository under vendor/ is left out"
assert_eq "$(printf '%s\n' "$out" | grep -c -e 'in sync' -e 'behind canonical' -e 'locally modified' -e 'legacy copy' -e 'upstream spec-driven')" "6" "roots listed twice list each repository once"
assert_eq "$(FLEET_ROOTS="$ROOT/plain $ROOT/extra/acme" bash "$DC" --fleet | tail -n 1)" "no OpenSpec repository found under: $ROOT/plain $ROOT/extra/acme" "an empty fleet says where it looked"

# --- The upstream report (K5) ---

out="$(cd "$ROOT/plain" && bash "$DC" --upstream)"
assert_contains "$out" "Drift report: spec-driven-longish vs upstream spec-driven@1" "upstream report runs from any directory"
assert_contains "$out" "$S/schema.yaml" "the advice names the canonical schema"
assert_contains "$out" "openspec-fleet schema-sync" "the advice says how to vendor"
assert_eq "$(printf '%s\n' "$out" | grep -c 'a verbatim copy is correct')" "0" "the verbatim-copy claim is gone"

# --- Usage and exit status (K5) ---

for args in "--bogus" "--fleet --upstream" "--fleet $SYNC" "--upstream $SYNC" "$SYNC $MOD" "-h" "--help"; do
    # shellcheck disable=SC2086 # the words of args are the arguments
    out="$(bash "$DC" $args 2>/dev/null)"; rc=$?
    assert_contains "$out" "usage: drift-check.sh" "usage for: $args"
    assert_eq "$rc" "0" "exit 0 for: $args"
done
rc="$(cd "$MOD" && bash "$DC" >/dev/null 2>&1; echo $?)"; assert_eq "$rc" "0" "exit 0, locally modified"
rc="$(FLEET_ROOTS=$ROOT/projects bash "$DC" --fleet >/dev/null 2>&1; echo $?)"; assert_eq "$rc" "0" "exit 0, fleet"
rc="$(bash "$DC" --upstream >/dev/null 2>&1; echo $?)"; assert_eq "$rc" "0" "exit 0, upstream"
rc="$(OPENSPEC_CANONICAL_DIR=$ROOT/dangling bash "$DC" "$SYNC" >/dev/null 2>&1; echo $?)"; assert_eq "$rc" "0" "exit 0, no canonical"
rc="$(bash "$DC" "$ROOT/plain" >/dev/null 2>&1; echo $?)"; assert_eq "$rc" "0" "exit 0, not an OpenSpec project"

# --- Read-only (K6) ---

for repo in "$SYNC" "$BEHIND" "$MOD" "$LEGACY" "$UP"; do
    assert_eq "$(git -C "$repo" status --porcelain)" "" "nothing written in ${repo#"$ROOT"/}"
done

finish
