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

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# Pick bar color based on context usage
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
printf -v FILL "%${FILLED}s"; printf -v PAD "%${EMPTY}s"
BAR="${FILL// /█}${PAD// /░}"

MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))

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

echo -e "${CYAN}[$MODEL]${RESET} | 📁 ${DIR_LINK} $BRANCH$WORKTREE $REPO_LINK"
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

RL_SEG=""
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
    RL_SEG=" 🚦 5h $(rl_color "${RL_5H:-0}")${RL_5H:-0}%${RESET}${RL_WHEN} · 7d $(rl_color "${RL_7D:-0}")${RL_7D:-0}%${RESET}${RL_7D_WHEN} |"
fi

#echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET} | ⏱️ ${MINS}m ${SECS}s"
echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% | 🎨 ${YELLOW}${OUTPUT_STYLE}${RESET} |${EFFORT_SEG}${RL_SEG} ⏱️ ${MINS}m ${SECS}s"
