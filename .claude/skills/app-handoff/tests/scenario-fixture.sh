#!/usr/bin/env bash
# Builds the fixture of the handoff scenarios in tests/scenarios.md.
#
#   scenario-fixture.sh <target>
#       Creates <target>/shop-api, a repository on fix/queue-retries with
#       two commits, one modified test file and an ignored .env, and
#       <target>/session-knowledge.md, the memory of the session that
#       writes the handoff.
#   scenario-fixture.sh --drift <target>
#       Adds one commit to <target>/shop-api on fix/queue-retries that
#       leaves the modified test file alone, so the checkout no longer
#       matches a handoff written before it.
#
# <target> must be an existing folder. Commits use the configured identity
# and signing. Usage errors exit 2, other failures exit 1.

set -euo pipefail

# Nothing the caller set reaches git: a GIT_DIR exported by yadm enter or a
# hook would send the fixture commits into that repository, and a hook's
# identity and dates would override the configured ones. A CDPATH would let
# cd land somewhere else.
mapfile -t git_local_vars < <(git rev-parse --local-env-vars)
unset -v "${git_local_vars[@]}" \
    GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
    GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE CDPATH

readonly USAGE='usage: scenario-fixture.sh <target> | scenario-fixture.sh --drift <target>'
readonly BRANCH=fix/queue-retries

usage_error() { # message
    printf 'scenario-fixture.sh: %s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

die() { # message
    printf 'scenario-fixture.sh: %s\n' "$1" >&2
    exit 1
}

build() { # target
    local repo="$1/shop-api"
    [ ! -e "$repo" ] || die "$repo already exists"
    [ ! -e "$1/session-knowledge.md" ] || die "$1/session-knowledge.md already exists"

    git init -q -b main "$repo"
    mkdir -p -- "$repo/config" "$repo/shop_api" "$repo/tests" "$repo/docs/specs"

    # First commit, on main: the job, its test and the shared queue settings.
    cat >"$repo/.gitignore" <<'EOF'
.env
__pycache__/
EOF
    cat >"$repo/README.md" <<'EOF'
# shop-api

The shop's back end. The queue worker runs the order sync job
(`shop_api/sync_orders.py`), which sends changed orders to the storefront.

Run the tests with `python -m pytest`.
EOF
    cat >"$repo/requirements.txt" <<'EOF'
orderwire==2.4.1
pytest==8.3.3
EOF
    cat >"$repo/config/queue" <<'EOF'
# Queue worker settings, shared by every job the worker runs.
connection = redis://localhost:6379/0
visibility_timeout = 30
max_attempts = 1
EOF
    cat >"$repo/shop_api/sync_orders.py" <<'EOF'
"""The order sync job: sends changed orders to the storefront."""

from orderwire import encode


def sync_orders(orders, connect):
    payload = encode(orders)
    with connect() as conn:
        conn.publish("orders.sync", payload)
EOF
    cat >"$repo/tests/test_sync_orders.py" <<'EOF'
import contextlib

from shop_api.sync_orders import sync_orders


class FakeConnection:
    def __init__(self):
        self.sent = []

    def publish(self, topic, payload):
        self.sent.append((topic, payload))


def test_small_payload_is_sent():
    conn = FakeConnection()
    sync_orders([{"id": 1}], lambda: contextlib.nullcontext(conn))
    assert len(conn.sent) == 1
EOF
    git -C "$repo" add -- .gitignore README.md requirements.txt config/queue \
        shop_api/sync_orders.py tests/test_sync_orders.py
    git -C "$repo" commit -q -m 'Add the order sync job'

    # Second commit, on the branch: the spec the owner opened the work with.
    git -C "$repo" switch -q -c "$BRANCH"
    cat >"$repo/docs/specs/queue-retries.md" <<'EOF'
# Queue retries for the order sync job

Ticket: SHOP-482

## Problem

The order sync job fails now and then in the queue worker. Until the next
successful run, customers see stale orders.

## Scope

Make the job recover from these failures. Due before Friday's release.
EOF
    git -C "$repo" add -- docs/specs/queue-retries.md
    git -C "$repo" commit -q -m 'Add the queue retries spec'

    # The session's uncommitted work: the test that reproduces the failure.
    cat >>"$repo/tests/test_sync_orders.py" <<'EOF'


def test_payload_over_1_mb_is_sent():
    conn = FakeConnection()
    orders = [{"id": i, "note": "x" * 1000} for i in range(1200)]
    sync_orders(orders, lambda: contextlib.nullcontext(conn))
    assert len(conn.sent) == 1
EOF
    # The secret lives where the session says it does; .gitignore hides it.
    printf 'SHOP_API_TOKEN=FAKE-TOKEN-9f3a7c21\n' >"$repo/.env"

    cat >"$1/session-knowledge.md" <<'EOF'
# My memory of this session

I am the agent working with the owner in the shop-api repository. This is
everything I know at this point of the session. The owner has read my
replies. The items under "Never said aloud" stayed in my own reasoning and
never went into a reply.

## Said in the session

- Goal: the order sync job fails now and then in the queue worker. The
  owner wants it fixed before Friday's release, because customers see
  stale orders.
- Done: I reproduced the failure with a failing test,
  `test_payload_over_1_mb_is_sent` in `tests/test_sync_orders.py`, not
  committed yet. I have not started the fix.
- Verified fact: the job fails only for payloads over 1 MB. I checked it
  with two sizes: a 900 KB payload syncs, a 1.2 MB payload fails.
- Unverified assumption: the serializer truncates large payloads. I have
  not checked it.
- The owner's instructions: stay on `fix/queue-retries`. Do not touch
  `config/queue`. Earlier the owner said yes to pushing the branch once the
  tests pass.
- Secret: the staging token `FAKE-TOKEN-9f3a7c21` is in `.env` as
  `SHOP_API_TOKEN`.
- Open question for the owner: cap retries at 3 or at 5.
- Next steps, in this order: check the serializer on a 2 MB payload;
  implement the backoff; run the suite; push the branch.
- In flight: I started a test watcher in this session. It ends with the
  session.
- Pointers: ticket `SHOP-482`, `docs/specs/queue-retries.md`.

## Never said aloud

- Decision: retry with backoff inside the job, not in the queue
  configuration, because other jobs share that configuration.
- Ruled out: a Redis timeout, because the job fails before it opens the
  connection.
EOF
}

drift() { # target
    local repo="$1/shop-api" branch
    [ -d "$repo/.git" ] || die "no fixture repository at $repo"
    branch="$(git -C "$repo" symbolic-ref -q --short HEAD)" || branch=detached
    [ "$branch" = "$BRANCH" ] || die "$repo is on $branch, not $BRANCH"
    # The commit takes README.md as it is on disk, so an edit left there by
    # an earlier run would ride along.
    git -C "$repo" diff --quiet HEAD -- README.md ||
        die "README.md in $repo has uncommitted changes"

    cat >>"$repo/README.md" <<'EOF'

## Releases

Releases go out on Fridays. Tag the release commit before deploying.
EOF
    # Path-limited, so nothing an earlier run staged goes into this commit.
    git -C "$repo" commit -q -m 'Note the release day in the README' -- README.md
}

main() {
    local action=build target
    if [ "${1-}" = --drift ]; then
        action=drift
        shift
    fi
    [ $# -eq 1 ] || usage_error 'give one target'
    [ -d "$1" ] || usage_error "no such folder: $1"
    target="$(cd -P -- "$1" && pwd -P)"
    "$action" "$target"
}

main "$@"
