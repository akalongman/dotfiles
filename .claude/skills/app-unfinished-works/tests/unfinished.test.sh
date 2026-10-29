#!/usr/bin/env bash
# Tests for scripts/unfinished.py and its package scripts/unfinishedlib.
#
# Runs the unittest suite under python3 -I. Every case builds its own
# throwaway repositories and trees under a temporary directory and passes
# them in; no case reads this machine's slots, transcripts or projects.
# Extra arguments reach unittest discover (for example -v or -k <pattern>).

set -uo pipefail

# Nothing the caller set reaches the cases: a GIT_DIR exported by yadm enter
# or a hook would send the fixture commits into that repository, a hook's
# author and committer identity and dates would override the fixture's own,
# and a knob of this suite left set would change what a case sees.
mapfile -t git_local_vars < <(git rev-parse --local-env-vars)
unset -v "${git_local_vars[@]}" \
    GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
    GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE \
    UNFINISHED_HOME

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 -I -m unittest discover -s "$HERE" -t "$HERE/.." "$@"
