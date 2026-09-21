#!/bin/bash
# Per-model weekly rate-limit windows for statusline.sh.
#
# Claude Code's status line payload has a rate_limits.model_scoped array, but
# the CLI fills it only from a successful call to the usage endpoint; windows
# seeded from response headers carry no limits[], so in practice the payload
# holds just five_hour and seven_day (checked against 2.1.278 on 2026-09-21).
# A per-model weekly cap, the kind Fable has, appears only in the usage
# response's limits[] array, as a row with kind "weekly_scoped" and a
# scope.model.display_name. The flat seven_day_opus and seven_day_sonnet keys
# beside it are null, so the array is the only source.
#
# Two ways to reach that array, tried cheapest first:
#
#   1. The CLI parks its last usage response in the config file, under
#      cachedUsageUtilization. Free, no token, no network, already per
#      account. It is only as fresh as the CLI's last endpoint call, though,
#      and the CLI seeds its own windows from response headers instead, so
#      this can easily be days old.
#   2. GET /api/oauth/usage. Authoritative; asked at most once a TTL and
#      backed off when refused. It answers an unauthenticated request with
#      429, not 401, so a 429 here is as likely a dropped Authorization
#      header as a real rate limit (2026-09-21: curl 8.5 silently drops an
#      unquoted config-file header, and every call had gone out anonymous).
#
# Whichever carries the newer data wins, and its age travels with the rows so
# the status line can mark a stale number rather than passing it off as live.
#
#   read     print the cached rows and, when due, refresh them in the
#            background; this is what the status line calls
#   refresh  refresh now if due, honouring the lock and the backoff
#   fetch    refresh unconditionally, ignoring TTL and backoff (for testing)
#   path     print the cache file
#
# Cache rows are TSV: display name, whole-percent used, reset epoch, data
# epoch. read prints display name, percent, reset epoch, stale flag; the
# percent is "?" on a placeholder row, printed when nothing current is cached
# and the last attempt failed, so that an outage is visible as unknown rather
# than indistinguishable from "no scoped cap".

set -uo pipefail

API="${CLAUDE_STATUSLINE_API:-https://api.anthropic.com}"
# A weekly window moves by a percent or two an hour at most, so a quarter hour
# of staleness never shows on screen, and the endpoint's budget is small
# enough that erring long is the only way to stay inside it.
TTL="${CLAUDE_STATUSLINE_USAGE_TTL:-900}"
BACKOFF="${CLAUDE_STATUSLINE_USAGE_BACKOFF:-1800}"
# Beyond this the number is too old to show at all. Past STALE_AT but inside
# it, the status line marks it rather than dropping it. The hour matches the
# CLI's own limit for trusting its cached snapshot.
STALE_AT="${CLAUDE_STATUSLINE_USAGE_STALE_AT:-3600}"
MAX_AGE="${CLAUDE_STATUSLINE_USAGE_MAX_AGE:-86400}"
# Name on the placeholder row for a slot whose cache never held a row, so it
# has no name of its own to keep: the one cap the server scopes today.
LABEL="${CLAUDE_STATUSLINE_SCOPED_LABEL:-Fable}"

# The config dir picks the account, so everything here is keyed by it: two
# slots must never read each other's windows. Unset means the default slot,
# whose config dir is ~/.claude even though its state file, the one holding
# the snapshot, is the legacy ~/.claude.json.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SLOT=$(basename "$CFG")
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    STATE="$CLAUDE_CONFIG_DIR/.claude.json"
else
    STATE="$HOME/.claude.json"
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
CACHE="$CACHE_DIR/$SLOT.tsv"
# Holds the epoch before which no endpoint call is attempted, then "ok" or
# "fail" for how the last attempt ended. Written on every attempt, so a 429 or
# an expired token costs one call per backoff rather than one per status line
# render, and the verdict is what turns an empty cache into a placeholder.
DUE="$CACHE_DIR/$SLOT.due"
LOCK="$CACHE_DIR/$SLOT.lock"

# Read builtin rather than a command substitution: this runs on every status
# line render, and $(cat) would fork twice for a file holding one integer.
due() {
    local at=''
    # Redirections are applied left to right, so stderr must be silenced
    # before the input redirect that may fail: the shell reports a failed
    # redirect itself, and 2>/dev/null written afterwards comes too late.
    read -r at _ 2>/dev/null < "$DUE"
    [[ $at =~ ^[0-9]+$ ]] || return 0
    [ "$EPOCHSECONDS" -ge "$at" ]
}

set_due() { printf '%s %s\n' "$(( EPOCHSECONDS + $1 ))" "${2:-ok}" 2>/dev/null > "$DUE"; }

last_failed() {
    local at='' why=''
    read -r at why 2>/dev/null < "$DUE"
    [ "$why" = "fail" ]
}

# Pulls the weekly_scoped rows out of a usage response on stdin and stamps
# them with $1. resets_at is ISO 8601 with a fractional part and a numeric
# offset, which jq's fromdateiso8601 will not parse, so GNU date converts it
# here, in the background, rather than in the render path.
scoped_rows() {
    local at="$1" name pct iso epoch
    while IFS=$'\t' read -r name pct iso; do
        [ -n "$name" ] || continue
        epoch=0
        [ -n "$iso" ] && [ "$iso" != "null" ] && epoch=$(date -d "$iso" +%s 2>/dev/null || echo 0)
        printf '%s\t%s\t%s\t%s\n' "$name" "$pct" "$epoch" "$at"
    done < <(jq -r '
        .limits[]?
        | select(.kind == "weekly_scoped")
        | select(.scope.model.display_name != null and .percent != null)
        | [.scope.model.display_name, (.percent | floor), (.resets_at // "null")]
        | @tsv' 2>/dev/null)
}

# The CLI's own copy of the last usage response. Costs one jq and no network.
snapshot_rows() {
    local at
    at=$(jq -r '(.cachedUsageUtilization.fetchedAtMs // empty) / 1000 | floor' "$STATE" 2>/dev/null)
    [[ $at =~ ^[0-9]+$ ]] || return 1
    jq -c '.cachedUsageUtilization.utilization // empty' "$STATE" 2>/dev/null | scoped_rows "$at"
}

endpoint_rows() {
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CFG/.credentials.json" 2>/dev/null)
    # No OAuth token means an API key, Bedrock or Vertex session, which has no
    # plan windows to ask about. Its own status, since it is not a failure.
    [ -n "$token" ] || return 2

    # The header goes through a config file on stdin, never argv, so the token
    # stays out of the process list. The value must be quoted: curl 8.5 warns
    # about unquoted whitespace and then sends no header at all. OAuth tokens
    # are base64url, so the quoted form needs no escaping.
    local body
    body=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
        curl -sS -m 10 --config - \
            -H 'Content-Type: application/json' \
            -H 'anthropic-beta: oauth-2025-04-20' \
            "$API/api/oauth/usage" 2>/dev/null)

    # A 429 or an auth failure answers with an error object rather than
    # limits[]. Anything without limits[] is a failed attempt, so the caller
    # backs off and the rows already cached are left alone.
    printf '%s' "$body" | jq -e 'type == "object" and has("limits")' >/dev/null 2>&1 || return 1
    printf '%s' "$body" | scoped_rows "$EPOCHSECONDS"
}

# Every row of one batch carries the same data epoch, so the first row dates
# the batch. Empty input dates to 0 and loses to anything real.
rows_at() {
    local first=''
    IFS= read -r first <<< "$1"
    [ -n "$first" ] && printf '%s' "${first##*$'\t'}" || printf '0'
}

# Replaces the cache in one rename so a reader never catches a half-written
# file, and so a failed refresh leaves the previous rows untouched.
write_cache() {
    local tmp="$CACHE.$$"
    # Command substitution eats trailing newlines, so the last row would
    # otherwise arrive unterminated and a read loop would drop it.
    [ -n "$1" ] && set -- "$1"$'\n'
    printf '%s' "$1" 2>/dev/null > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$CACHE" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

do_refresh() {
    mkdir -p "$CACHE_DIR" 2>/dev/null || return 1

    local rows='' at=0 candidate c_at
    candidate=$(snapshot_rows) && { c_at=$(rows_at "$candidate"); [ "$c_at" -gt "$at" ] && { rows="$candidate"; at="$c_at"; }; }

    # The endpoint is asked only when the CLI's own copy has nothing recent.
    # Every /usage the user runs refreshes that copy, so on an active account
    # this costs no network at all, and the scarce endpoint budget is left to
    # the CLI, which needs it for the windows the status line already shows.
    if [ "$(( EPOCHSECONDS - at ))" -lt "$TTL" ]; then
        set_due "$TTL" ok
    else
        candidate=$(endpoint_rows)
        case $? in
            0)  c_at=$(rows_at "$candidate")
                [ "$c_at" -ge "$at" ] && { rows="$candidate"; at="$c_at"; }
                set_due "$TTL" ok ;;
            # Nothing to ask. Not a failure, so no placeholder either.
            2)  set_due "$TTL" ok ;;
            # Refused or unreachable. Marked so read can say so: days of 429
            # once passed for "no scoped cap" (2026-09-21).
            *)  set_due "$BACKOFF" fail ;;
        esac
    fi

    # Neither source answered, or both answered with no scoped window at all.
    # Either way there is nothing newer to write: the existing cache stays put
    # and ages out through MAX_AGE on its own, which is also what retires a
    # model cap that the server stops scoping.
    [ "$at" -gt 0 ] || return 1
    # Older than what is already cached means a stale snapshot lost the race
    # against a newer endpoint answer; leave the better rows alone.
    [ "$at" -ge "$(rows_at "$(cat "$CACHE" 2>/dev/null)")" ] || return 0
    write_cache "$rows"
}

refresh() {
    due || return 0
    mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
    exec 9>"$LOCK" 2>/dev/null || return 1
    # Single-flight across every open session on this slot. A held lock means
    # someone else is already refreshing, and flock releases it if that
    # process dies, so there is no stale lock to clean up.
    flock -n 9 || return 0
    due || return 0
    do_refresh
}

read_rows() {
    # The due check runs here too, so a render that needs nothing costs one
    # stat instead of spawning a shell that would exit immediately. When it
    # does spawn, the child is kept in its own session with every descriptor
    # closed, so the command substitution that called us is not left waiting
    # on an inherited pipe.
    if due; then setsid "$0" refresh </dev/null >/dev/null 2>&1 & fi

    local name pct reset at age shown=0 seen=''
    # Guarded rather than redirecting the loop's stderr: the shell reports a
    # failed redirect itself, before anything inside the loop can silence it.
    if [ -r "$CACHE" ]; then
        while IFS=$'\t' read -r name pct reset at || [ -n "$name" ]; do
            [ -n "$name" ] || continue
            seen="$name"
            [[ $at =~ ^[0-9]+$ ]] || continue
            age=$(( EPOCHSECONDS - at ))
            [ "$age" -lt "$MAX_AGE" ] || continue
            # Fourth field becomes the staleness flag the status line renders:
            # 0 while the number can be read as current, 1 once it cannot.
            printf '%s\t%s\t%s\t%s\n' "$name" "$pct" "$reset" "$(( age >= STALE_AT ? 1 : 0 ))"
            shown=1
        done < "$CACHE"
    fi
    # Nothing current and the last attempt failed: a placeholder row, so the
    # status line can show the window as unknown. It keeps the name the cache
    # last saw; a slot that never fetched has none and takes the default.
    if [ "$shown" -eq 0 ] && last_failed; then
        printf '%s\t?\t0\t1\n' "${seen:-$LABEL}"
    fi
}

case "${1:-read}" in
    read)    read_rows ;;
    refresh) refresh ;;
    fetch)   rm -f "$DUE"; mkdir -p "$CACHE_DIR" 2>/dev/null; do_refresh ;;
    path)    printf '%s\n' "$CACHE" ;;
    *)       printf 'usage: %s {read|refresh|fetch|path}\n' "${0##*/}" >&2; exit 2 ;;
esac
