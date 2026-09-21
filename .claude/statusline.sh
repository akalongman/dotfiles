#!/bin/bash
input=$(cat)

#echo "$input" | jq '.' > /tmp/claude-statusline-dump.json

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '(.context_window.used_percentage // 0) | round')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
OUTPUT_STYLE=$(echo "$input" | jq -r '.output_style.name')
EFFORT=$(echo "$input" | jq -r '.effort.level // empty')
RL_5H=$(echo "$input" | jq -r '(.rate_limits.five_hour.used_percentage // empty) | round')
RL_7D=$(echo "$input" | jq -r '(.rate_limits.seven_day.used_percentage // empty) | round')
RL_5H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
RL_7D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
REMOTE=$(git -C "$DIR" remote get-url origin 2>/dev/null)
REMOTE=$(echo "$REMOTE" \
    | sed 's|git@\([^:]*\):|https://\1/|' \
    | sed 's|ssh://git@\([^/]*\)/|https://\1/|' \
    | sed 's|\.git$||')
if [ -n "$REMOTE" ]; then
    REPO_PATH=${REMOTE#https://*/}
    REPO_HOST=${REMOTE#https://}
    REPO_HOST=${REPO_HOST%%/*}

    # Self-hosted support: add an instance domain to the matching list. An entry
    # matches that exact host and any subdomain of it (so "mycorp.io" covers
    # "git.mycorp.io"). Hosts literally containing github/gitlab/bitbucket are
    # auto-detected and need not be listed. Machine and client specific hosts
    # stay out of the public dotfiles: the optional overlay file below appends
    # them (e.g. GITLAB_HOSTS+=(git.mycorp.io)).
    GITHUB_HOSTS=(github.com)
    GITLAB_HOSTS=(gitlab.com)
    BITBUCKET_HOSTS=(bitbucket.org)
    [ -f "$HOME/.claude/statusline-hosts.sh" ] && source "$HOME/.claude/statusline-hosts.sh"

    host_matches() {
        local host="$1"; shift
        local pattern
        for pattern in "$@"; do
            [ "$host" = "$pattern" ] && return 0
            [ "${host%."$pattern"}" != "$host" ] && return 0
        done
        return 1
    }

    # Emoji icons; their color is intrinsic (ANSI cannot recolor an emoji glyph).
    if   [[ $REPO_HOST == *github* ]]    || host_matches "$REPO_HOST" "${GITHUB_HOSTS[@]}";    then REPO_ICON='🐙'
    elif [[ $REPO_HOST == *gitlab* ]]    || host_matches "$REPO_HOST" "${GITLAB_HOSTS[@]}";    then REPO_ICON='🦊'
    elif [[ $REPO_HOST == *bitbucket* ]] || host_matches "$REPO_HOST" "${BITBUCKET_HOSTS[@]}"; then REPO_ICON='🪣'
    else REPO_ICON='🔗'
    fi
    # Second OSC 8 link; the folder link is emitted first, so it survives renderers
    # that keep only the first hyperlink, and the short label still auto-linkifies as
    # a fallback (anthropics/claude-code#26356).
    REPO_LINK=" | ${REPO_ICON} \033]8;;${REMOTE}\a\033[4m${REPO_PATH}\033[24m\033]8;;\a"
else
    REPO_LINK=""
fi

BRANCH=""
WORKTREE=""
if git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH_NAME=$(git -C "$DIR" branch --show-current 2>/dev/null)
    BRANCH=" | 🌿 ${BRANCH_NAME}"

    # A linked worktree keeps its per-worktree git dir under <common>/worktrees/<name>,
    # so when the canonicalized git dir differs from the common dir we are in one (and
    # the main checkout stays silent). Both are canonicalized via cd + pwd -P because
    # --git-common-dir can come back relative to the working dir.
    GIT_DIR_ABS=$(cd "$(git -C "$DIR" rev-parse --absolute-git-dir 2>/dev/null)" 2>/dev/null && pwd -P)
    COMMON_DIR_ABS=$(cd "$DIR" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
    if [ -n "$GIT_DIR_ABS" ] && [ "$GIT_DIR_ABS" != "$COMMON_DIR_ABS" ]; then
        WT_NAME=$(basename "$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)")
        # Drop the name when it merely echoes the branch (the usual --worktree case); 🌳
        # alone still flags "linked worktree" without repeating what 🌿 already shows.
        if [ "$WT_NAME" = "$BRANCH_NAME" ]; then
            WORKTREE=" | 🌳"
        else
            WORKTREE=" | 🌳 ${WT_NAME}"
        fi
    fi
fi

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; MAGENTA='\033[35m'; BLUE='\033[34m'; DIM='\033[2m'; RESET='\033[0m'

# Account badge, always shown. Reads the active slot's cached identity so a
# /login in the wrong terminal is visible immediately (R6 in the multi-account
# design). CLAUDE_CONFIG_DIR is exported by the claude<N> wrappers; unset means
# the default slot, whose state file is the legacy ~/.claude.json (a config
# dir relocates it to $CLAUDE_CONFIG_DIR/.claude.json). Color marks the slot
# by the config dir's name: ~/.claude green, ~/.claude2 magenta, ~/.claude3
# blue, anything else yellow so an unexpected dir stands out. The badge shows
# the full address: accounts can share a local part across domains.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    ACCT_FILE="$CLAUDE_CONFIG_DIR/.claude.json"
    case "$(basename "$CLAUDE_CONFIG_DIR")" in
        .claude)  ACCT_COLOR="$GREEN" ;;
        .claude2) ACCT_COLOR="$MAGENTA" ;;
        .claude3) ACCT_COLOR="$BLUE" ;;
        *)        ACCT_COLOR="$YELLOW" ;;
    esac
else
    ACCT_FILE="$HOME/.claude.json"
    ACCT_COLOR="$GREEN"
fi
ACCT_EMAIL=$(jq -r '.oauthAccount.emailAddress // empty' "$ACCT_FILE" 2>/dev/null)
if [ -n "$ACCT_EMAIL" ]; then
    ACCT_SEG="${ACCT_COLOR}[👤 ${ACCT_EMAIL}]${RESET} "
else
    ACCT_SEG="${RED}[👤 not logged in]${RESET} "
fi

# Pick bar color based on context usage
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
printf -v FILL "%${FILLED}s"; printf -v PAD "%${EMPTY}s"
BAR="${FILL// /█}${PAD// /░}"

# Session wall clock on a unit ladder. Seconds stop carrying information once
# a session has run for an hour, and minutes stop once it has run for a day,
# so each step drops the smallest unit rather than printing 312m or 1874m.
DUR_S=$((DURATION_MS / 1000))
if [ "$DUR_S" -ge 86400 ]; then
    printf -v DURATION '%dd %dh' "$((DUR_S / 86400))" "$(( (DUR_S % 86400) / 3600 ))"
elif [ "$DUR_S" -ge 3600 ]; then
    printf -v DURATION '%dh %dm' "$((DUR_S / 3600))" "$(( (DUR_S % 3600) / 60 ))"
else
    printf -v DURATION '%dm %ds' "$((DUR_S / 60))" "$((DUR_S % 60))"
fi

url_encode_path() {
    local LC_ALL=C string="$1" out='' i char dec hex
    for (( i = 0; i < ${#string}; i++ )); do
        char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9/._~-]) out+="$char" ;;
            *)
                # & 0xFF guards against bash builds that sign-extend a high byte
                # (e.g. 0xC3 -> -61), which would emit %FFFFFFC3 and corrupt UTF-8.
                printf -v dec '%d' "'$char"
                printf -v hex '%%%02X' "$(( dec & 0xFF ))"
                out+="$hex"
                ;;
        esac
    done
    REPLY="$out"
}

format_path() {
    local path="${1/#$HOME/'~'}"
    local width=60
    local len=${#path}
    if [ "$len" -le "$width" ]; then
        printf '%s' "$path"
    else
        local keep=$((width - 3))
        local left=$(( (keep + 1) / 2 ))
        local right=$(( keep / 2 ))
        printf '%s...%s' "${path:0:$left}" "${path: -$right}"
    fi
}

DIR_DISP=$(format_path "$DIR")
url_encode_path "$DIR"
DIR_URI="file://$REPLY"
printf -v DIR_PAD '%*s' "$(( 60 - ${#DIR_DISP} > 0 ? 60 - ${#DIR_DISP} : 0 ))" ''

# BEL terminator (\a), not ST (\e\\): Claude Code's status line renderer passes the
# BEL form through to the terminal but drops ST (anthropics/claude-code#26356).
DIR_LINK="\033]8;;${DIR_URI}\a\033[4m${DIR_DISP}\033[24m\033]8;;\a${DIR_PAD}"

echo -e "${ACCT_SEG}${CYAN}[$MODEL]${RESET} | 📁 ${DIR_LINK} $BRANCH$WORKTREE $REPO_LINK"
COST_FMT=$(printf '$%.2f' "$COST")

EFFORT_SEG=""
if [ -n "$EFFORT" ]; then
    EFFORT_SEG=" 🧠 ${CYAN}${EFFORT}${RESET} |"
fi

rl_color() {
    if [ "$1" -ge 90 ]; then printf '%s' "$RED"
    elif [ "$1" -ge 70 ]; then printf '%s' "$YELLOW"
    else printf '%s' "$GREEN"; fi
}

# Per-model weekly windows (a Fable cap today, whatever the server scopes
# later). The status line payload has no such bucket as of 2.1.278, so a helper
# caches them from the usage endpoint out of band and this reads the cache;
# see statusline-usage.sh for why that fetch is throttled. A future CLI that
# ships rate_limits.model_scoped wins, and the helper is never called.
#
# Either source yields four fields: name, percent, reset epoch, and 1 when
# the number is too old to pass off as live. Payload rows are current by
# definition, so they get 0. The helper's percent is "?" when its fetch is
# failing and nothing current is cached.
MODEL_ROWS=$(echo "$input" | jq -r '
    (.rate_limits.model_scoped // [])[]
    | select(.utilization != null)
    | [.display_name, (.utilization | floor), (.resets_at // 0), 0] | @tsv')
if [ -z "$MODEL_ROWS" ] && [ -x "$HOME/.claude/statusline-usage.sh" ]; then
    MODEL_ROWS=$("$HOME/.claude/statusline-usage.sh" read 2>/dev/null)
fi

RL_PARTS=()
while IFS=$'\t' read -r M_NAME M_PCT M_RESET M_STALE; do
    [ -n "$M_NAME" ] || continue
    # Placeholder: shown dim, so an outage reads as unknown rather than as a
    # cap that does not exist.
    if [ "$M_PCT" = "?" ]; then RL_PARTS+=("${M_NAME} ${DIM}?${RESET}"); continue; fi
    [[ $M_PCT =~ ^[0-9]+$ ]] || continue
    # The cache stores an epoch; the payload branch would carry ISO 8601, so
    # anything non-numeric goes through date rather than being trusted as one.
    [[ $M_RESET =~ ^[0-9]+$ ]] || M_RESET=$(date -d "$M_RESET" +%s 2>/dev/null || echo 0)
    M_WHEN=""
    # A scoped week ends when the all-model week does, so the timestamp is
    # printed only when it actually differs and carries information.
    if [ "$M_RESET" != "0" ] && [ "$M_RESET" != "$RL_7D_RESET" ]; then
        printf -v M_WHEN ' (↻ %s)' "$(date -d "@$M_RESET" '+%d %b %H:%M')"
    fi
    # Trailing ~ reads as "about": these windows come from a cache that can
    # only refresh as often as a stingy endpoint allows, and a number nobody
    # can date is worse than one openly marked as approximate.
    M_AGED=""
    [ "${M_STALE:-0}" = "1" ] && M_AGED="~"
    RL_PARTS+=("${M_NAME} $(rl_color "$M_PCT")${M_PCT}%${M_AGED}${RESET}${M_WHEN}")
done <<< "$MODEL_ROWS"

RL_SEG=""
if [ -n "$RL_5H" ] || [ -n "$RL_7D" ] || [ ${#RL_PARTS[@]} -gt 0 ]; then
    if [ -n "$RL_5H" ] || [ -n "$RL_7D" ]; then
        RL_WHEN=""
        if [ -n "$RL_5H_RESET" ]; then
            RL_LEFT=$(( RL_5H_RESET - $(date +%s) ))
            [ "$RL_LEFT" -lt 0 ] && RL_LEFT=0
            printf -v RL_WHEN ' (↻ %dh%02dm)' "$(( RL_LEFT / 3600 ))" "$(( (RL_LEFT % 3600) / 60 ))"
        fi
        RL_7D_WHEN=""
        if [ -n "$RL_7D_RESET" ]; then
            printf -v RL_7D_WHEN ' (↻ %s)' "$(date -d "@$RL_7D_RESET" '+%d %b %H:%M')"
        fi
        # The plan windows lead; scoped model windows follow in server order.
        RL_PARTS=("5h $(rl_color "${RL_5H:-0}")${RL_5H:-0}%${RESET}${RL_WHEN}" \
                  "7d $(rl_color "${RL_7D:-0}")${RL_7D:-0}%${RESET}${RL_7D_WHEN}" \
                  "${RL_PARTS[@]}")
    fi
    RL_JOINED=$(printf ' · %s' "${RL_PARTS[@]}")
    RL_SEG=" 🚦${RL_JOINED# ·} |"
fi

#echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET} | ⏱️ ${DURATION}"
echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% | 🎨 ${YELLOW}${OUTPUT_STYLE}${RESET} |${EFFORT_SEG}${RL_SEG} ⏱️ ${DURATION}"
