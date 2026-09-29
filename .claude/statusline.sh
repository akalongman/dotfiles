#!/bin/bash
# Claude Code exports the terminal size in COLUMNS; the script's stdout is a
# pipe, so tput cannot ask. Read before any child runs, because bash may
# rewrite the variable once one exits.
TERM_COLS=${COLUMNS:-}
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
REPO_ICON=""
REPO_PATH=""
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
fi

IN_REPO=0
IN_WORKTREE=0
BRANCH_NAME=""
WT_NAME=""
if git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
    IN_REPO=1
    BRANCH_NAME=$(git -C "$DIR" branch --show-current 2>/dev/null)

    # A linked worktree keeps its per-worktree git dir under <common>/worktrees/<name>,
    # so when the canonicalized git dir differs from the common dir we are in one (and
    # the main checkout stays silent). Both are canonicalized via cd + pwd -P because
    # --git-common-dir can come back relative to the working dir.
    GIT_DIR_ABS=$(cd "$(git -C "$DIR" rev-parse --absolute-git-dir 2>/dev/null)" 2>/dev/null && pwd -P)
    COMMON_DIR_ABS=$(cd "$DIR" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
    if [ -n "$GIT_DIR_ABS" ] && [ "$GIT_DIR_ABS" != "$COMMON_DIR_ABS" ]; then
        IN_WORKTREE=1
        WT_NAME=$(basename "$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)")
        # Drop the name when it merely echoes the branch (the usual --worktree case); 🌳
        # alone still flags "linked worktree" without repeating what 🌿 already shows.
        [ "$WT_NAME" = "$BRANCH_NAME" ] && WT_NAME=""
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
    ACCT_TEXT="[👤 ${ACCT_EMAIL}]"
    ACCT_SEG="${ACCT_COLOR}${ACCT_TEXT}${RESET} "
else
    ACCT_TEXT="[👤 not logged in]"
    ACCT_SEG="${RED}${ACCT_TEXT}${RESET} "
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

# Cuts from the middle: both ends of a path, a branch or a repo slug carry
# meaning (root and leaf, ticket prefix and topic, owner and name).
shorten() {
    local text="$1" width="$2"
    if [ "${#text}" -le "$width" ]; then
        REPLY="$text"
        return
    fi
    local keep=$(( width > 3 ? width - 3 : 0 ))
    local left=$(( (keep + 1) / 2 ))
    local right=$(( keep / 2 ))
    # ${text: -0} would expand to the whole string, so a zero tail is spelled out.
    if [ "$right" -gt 0 ]; then
        REPLY="${text:0:$left}...${text: -$right}"
    else
        REPLY="${text:0:$left}..."
    fi
}

# Layout of the name rows. Row 1 holds the badge, the model and the path; row 2
# holds the git names and exists only inside a repository. On each row the
# names share whatever the terminal leaves after the fixed parts, so a row
# fills a wide terminal and still fits a narrow one.
LINE_RESERVE=4      # the interface's own margins, plus slack for icon widths
NAME_FLOOR=10       # below this a name says little, so segments collapse first
NAME_MIN=6          # last resort once nothing is left to collapse
FALLBACK_COLS=120   # COLUMNS is absent when Claude Code has no terminal
if ! [[ $TERM_COLS =~ ^[0-9]+$ ]] || [ "$TERM_COLS" -eq 0 ]; then
    TERM_COLS=$FALLBACK_COLS
fi

# fit_names <floor> <fixed cells> <name>...
# Finds the largest common cap under which the names of one row fit, so short
# names stay whole and only the long ones give way. Fails when the floor is
# still too wide. Empty names are skipped; every other one also costs the
# space that separates it from its icon.
fit_names() {
    local floor=$1 avail=$(( TERM_COLS - LINE_RESERVE - $2 )) len total name
    local lens=()
    shift 2
    for name in "$@"; do
        [ -n "$name" ] || continue
        lens+=("${#name}")
        avail=$(( avail - 1 ))
    done
    NAME_CAP=0
    for len in "${lens[@]}"; do
        [ "$len" -gt "$NAME_CAP" ] && NAME_CAP=$len
    done
    while :; do
        total=0
        for len in "${lens[@]}"; do
            total=$(( total + (len < NAME_CAP ? len : NAME_CAP) ))
        done
        [ "$total" -le "$avail" ] && return 0
        [ "$NAME_CAP" -le "$floor" ] && return 1
        NAME_CAP=$(( NAME_CAP - 1 ))
    done
}

# Fixed cells: ${#} counts characters and each icon is two cells wide, hence
# one extra per icon.
DIR_NAME="${DIR/#$HOME/'~'}"
ROW1_FIXED=$(( ${#ACCT_TEXT} + 1 + 1 + ${#MODEL} + 2 + 5 ))    # badge, [model], " | 📁"

# Effort and output style describe how the model answers, so they sit next to it.
MODE_SEG=""
if [ -n "$EFFORT" ]; then
    MODE_SEG+=" | 🧠 ${CYAN}${EFFORT}${RESET}"
    ROW1_FIXED=$(( ROW1_FIXED + 6 + ${#EFFORT} ))
fi
MODE_SEG+=" | 🎨 ${YELLOW}${OUTPUT_STYLE}${RESET}"
ROW1_FIXED=$(( ROW1_FIXED + 6 + ${#OUTPUT_STYLE} ))

# A row that is still too long at the minimum is left for the terminal to clip.
fit_names "$NAME_FLOOR" "$ROW1_FIXED" "$DIR_NAME" \
    || fit_names "$NAME_MIN" "$ROW1_FIXED" "$DIR_NAME"

url_encode_path "$DIR"
DIR_URI="file://$REPLY"

# BEL terminator (\a), not ST (\e\\): Claude Code's status line renderer passes the
# BEL form through to the terminal but drops ST (anthropics/claude-code#26356).
# A link always points at the full target, however short its label was cut.
shorten "$DIR_NAME" "$NAME_CAP"
echo -e "${ACCT_SEG}${CYAN}[$MODEL]${RESET}${MODE_SEG} | 📁 \033]8;;${DIR_URI}\a\033[4m${REPLY}\033[24m\033]8;;\a"

if [ "$IN_REPO" = 1 ]; then
    REPO_NAME="$REPO_PATH"
    ROW2_FIXED=2                                                # "🌿"
    [ "$IN_WORKTREE" = 1 ] && ROW2_FIXED=$(( ROW2_FIXED + 5 ))  # " | 🌳"
    [ -n "$REPO_ICON" ] && ROW2_FIXED=$(( ROW2_FIXED + 5 ))     # " | 🐙"

    # When the floor does not fit, the repo falls back to its icon (which then
    # carries the link), after that the worktree loses its name, and what
    # remains is cut down to the minimum.
    fit_names "$NAME_FLOOR" "$ROW2_FIXED" "$BRANCH_NAME" "$WT_NAME" "$REPO_NAME" \
        || { REPO_NAME=""; fit_names "$NAME_FLOOR" "$ROW2_FIXED" "$BRANCH_NAME" "$WT_NAME"; } \
        || { WT_NAME=""; fit_names "$NAME_FLOOR" "$ROW2_FIXED" "$BRANCH_NAME"; } \
        || fit_names "$NAME_MIN" "$ROW2_FIXED" "$BRANCH_NAME"

    ROW2="🌿"
    if [ -n "$BRANCH_NAME" ]; then
        shorten "$BRANCH_NAME" "$NAME_CAP"
        ROW2+=" ${REPLY}"
    fi

    if [ "$IN_WORKTREE" = 1 ]; then
        ROW2+=" | 🌳"
        if [ -n "$WT_NAME" ]; then
            shorten "$WT_NAME" "$NAME_CAP"
            ROW2+=" ${REPLY}"
        fi
    fi

    # Second OSC 8 link; the folder link is emitted first, so it survives renderers
    # that keep only the first hyperlink, and the short label still auto-linkifies as
    # a fallback (anthropics/claude-code#26356).
    if [ -n "$REPO_ICON" ]; then
        if [ -n "$REPO_NAME" ]; then
            shorten "$REPO_NAME" "$NAME_CAP"
            ROW2+=" | ${REPO_ICON} \033]8;;${REMOTE}\a\033[4m${REPLY}\033[24m\033]8;;\a"
        else
            ROW2+=" | \033]8;;${REMOTE}\a${REPO_ICON}\033]8;;\a"
        fi
    fi

    echo -e "$ROW2"
fi
COST_FMT=$(printf '$%.2f' "$COST")

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
echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% |${RL_SEG} ⏱️ ${DURATION}"
