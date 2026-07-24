#!/usr/bin/env bash
# Detects byte-for-byte drift between a project's custom OpenSpec schema
# overlay and the upstream @fission-ai/openspec spec-driven schema.
# Read-only: reports drift, modifies nothing.
# Run from the project root (the directory containing openspec/config.yaml).

set -euo pipefail

# --- Pre-flight ---

if [ ! -f openspec/config.yaml ]; then
    echo "not an OpenSpec project (no openspec/config.yaml in $(pwd))"
    exit 0
fi

CUSTOM_NAME="$(awk '/^schema:[[:space:]]/ { print $2; exit }' openspec/config.yaml)"

if [ -z "$CUSTOM_NAME" ]; then
    echo "openspec/config.yaml has no schema: field — nothing to drift from"
    exit 0
fi

if [ "$CUSTOM_NAME" = "spec-driven" ]; then
    echo "no overlay declared (schema: spec-driven). Nothing to drift from."
    exit 0
fi

echo "overlay name: $CUSTOM_NAME"

# --- Locate upstream ---

UPSTREAM_SCHEMA=""

if NPM_ROOT_G="$(npm root -g 2>/dev/null)" && [ -f "$NPM_ROOT_G/@fission-ai/openspec/schemas/spec-driven/schema.yaml" ]; then
    UPSTREAM_SCHEMA="$NPM_ROOT_G/@fission-ai/openspec/schemas/spec-driven/schema.yaml"
fi

if [ -z "$UPSTREAM_SCHEMA" ]; then
    UPSTREAM_SCHEMA="$(ls -t "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/lib/node_modules/@fission-ai/openspec/schemas/spec-driven/schema.yaml 2>/dev/null | head -n 1)"
fi

if [ -z "$UPSTREAM_SCHEMA" ] || [ ! -f "$UPSTREAM_SCHEMA" ]; then
    cat <<EOF
OpenSpec is not installed globally. Install via:
  npm i -g @fission-ai/openspec
EOF
    exit 0
fi

UPSTREAM_TEMPLATES_DIR="$(dirname "$UPSTREAM_SCHEMA")/templates"
echo "upstream schema: $UPSTREAM_SCHEMA"

# --- Locate custom overlay ---

CUSTOM_SCHEMA="openspec/schemas/$CUSTOM_NAME/schema.yaml"
CUSTOM_TEMPLATES_DIR="openspec/schemas/$CUSTOM_NAME/templates"

if [ ! -f "$CUSTOM_SCHEMA" ]; then
    echo "config declares schema: $CUSTOM_NAME but overlay file is missing at $CUSTOM_SCHEMA"
    exit 0
fi

echo "custom schema: $CUSTOM_SCHEMA"

# --- YAML parser ---
# extract_field reads a top-level scalar (name, version, description,
# apply.tracks) or list (apply.requires). extract_artifact_field reads
# description or instruction for a given artifacts[].id. Both prefer yq,
# falling back to python3 + PyYAML. Output is verbatim.

have_yq() { command -v yq >/dev/null 2>&1; }
have_python_yaml() { python3 -c 'import yaml' >/dev/null 2>&1; }

if ! have_yq && ! have_python_yaml; then
    cat <<EOF
Drift check requires yq or python3 + PyYAML. Install one of:
  apt install yq      # or: brew install yq
  apt install python3-yaml
EOF
    exit 0
fi

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

declare -a CLASSIFY_ROWS

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

    local id UV CV
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

classify_top_level
classify_artifacts
classify_apply

# --- Diff renderer ---
# render_diff produces a fenced unified diff for a single block, capped at
# 40 lines. Tempfiles are cleaned up via trap.

TMPDIR_DRIFT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DRIFT"' EXIT

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

declare -a TEMPLATE_ROWS

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

classify_templates

# --- Render report ---

UPSTREAM_VERSION="$(extract_field "$UPSTREAM_SCHEMA" version)"
ANY_DIVERGED=false

echo "Drift report: $CUSTOM_NAME vs upstream spec-driven@$UPSTREAM_VERSION"
echo

echo "| Block | Status | Notes |"
echo "|---|---|---|"
for row in "${CLASSIFY_ROWS[@]}"; do
    IFS='|' read -r label status notes <<<"$row"
    [ "$status" = "diverged" ] && ANY_DIVERGED=true
    echo "| \`$label\` | $status | $notes |"
done

echo
echo "| Template | Status | Notes |"
echo "|---|---|---|"
for row in "${TEMPLATE_ROWS[@]}"; do
    IFS='|' read -r label status notes <<<"$row"
    [ "$status" = "diverged" ] && ANY_DIVERGED=true
    [ "$status" = "missing" ]  && ANY_DIVERGED=true
    echo "| \`$label\` | $status | $notes |"
done
echo

if [ "$ANY_DIVERGED" = false ]; then
    echo "In sync with upstream spec-driven@$UPSTREAM_VERSION. No action needed."
    exit 0
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
            fld="$(echo "$label" | sed 's/.*\.//')"
            UV="$(extract_artifact_field "$UPSTREAM_SCHEMA" "$aid" "$fld")"
            CV="$(extract_artifact_field "$CUSTOM_SCHEMA"   "$aid" "$fld")"
            ;;
    esac
    render_diff "$label" "$UV" "$CV"
done

cat <<EOF

No files were modified. To absorb upstream changes:
  1. For diverged schema rows: open openspec/schemas/$CUSTOM_NAME/schema.yaml,
     locate the affected block, paste the upstream change in (preserving your
     prepend / append policy blocks).
  2. For diverged template rows: copy the upstream template verbatim from
     $UPSTREAM_TEMPLATES_DIR/<filename> to
     openspec/schemas/$CUSTOM_NAME/templates/<filename>. Templates do not
     carry per-project overrides today, so a verbatim copy is correct.
  3. Re-run the drift check to confirm every row returns to \`unchanged\` or
     \`overlay\`.
EOF
