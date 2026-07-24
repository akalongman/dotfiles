#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for t in "$HERE"/*.test.sh; do
    printf '== %s ==\n' "$(basename "$t")" >&2
    bash "$t" || status=1
done
exit "$status"
