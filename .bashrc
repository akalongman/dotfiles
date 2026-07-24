# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# History sizes and filters live in .exports (sourced below); the
# bash-specific pieces stay here. histappend avoids clobbering on exit,
# and flushing on every prompt makes history visible to new tmux panes
# immediately (starship chains the existing PROMPT_COMMAND, so this survives).
shopt -s histappend
PROMPT_COMMAND='history -a'

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

#if [ "$color_prompt" = yes ]; then
#    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
#else
#    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
#fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
#export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

#source /etc/profile.d/ps.sh

# Load the shell dotfiles (exports must come first; nvm relies on NVM_DIR
# from .exports, aliases/functions may reference exported vars).
for file in ~/.{exports,aliases,functions}; do
    [ -r "$file" ] && [ -f "$file" ] && source "$file"
done

for file in ~/.dotfiles-private/home/.{exports,aliases,functions}; do
    [ -r "$file" ] && [ -f "$file" ] && source "$file"
done
unset file

# NVM (NVM_DIR is exported by .exports above)
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# GPG TTY: must be re-evaluated per interactive shell, so it cannot live
# in .exports (which is also sourced once at graphical login with no tty).
GPG_TTY=$(tty)
export GPG_TTY

command -v starship &> /dev/null && eval "$(starship init bash)"

command -v zoxide &> /dev/null && eval "$(zoxide init bash)"

command -v direnv &> /dev/null && eval "$(direnv hook bash)"

[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash
[ -f /usr/share/bash-completion/completions/fzf ] && source /usr/share/bash-completion/completions/fzf

# Modern CLI aliases (eza/bat/fd/rg) live in ~/.aliases, sourced above.

# Auto-start tmux for interactive LOCAL shells only.
# The non-interactive `return` near the top of this file already excludes
# scripts and scp. These guards additionally skip remote logins (so SSH into
# the fleet stays vanilla, unless the host opts in by dropping the marker file
# ~/.config/tmux-ssh-autostart) and prevent nesting tmux inside tmux. `exec` hands
# the shell over to tmux so closing tmux closes the window cleanly. Placed last
# so PATH and all dotfiles are loaded before `command -v tmux` is checked.
# Set NO_TMUX=1 to bypass on demand (e.g. a dedicated plain-shell profile).
# IDE integrated terminals (JetBrains sets TERMINAL_EMULATOR, VS Code sets
# TERM_PROGRAM) are also skipped: the IDE manages its own terminal tabs.
#
# The first local terminal attaches to (or creates) `main`. Once `main` already
# has a client attached, extra terminals get their own fresh session instead of
# mirroring `main`. To make the extras share main's window list instead, change
# `new-session` to `new-session -t main` in the branch below.
if command -v tmux >/dev/null 2>&1 \
    && [ -n "$PS1" ] \
    && [ -z "$TMUX" ] \
    && { [ -z "$SSH_CONNECTION" ] || [ -f "$HOME/.config/tmux-ssh-autostart" ]; } \
    && [ -z "$NO_TMUX" ] \
    && [ -z "$TERMINAL_EMULATOR" ] \
    && [ "$TERM_PROGRAM" != "vscode" ]; then
    if tmux has-session -t main 2>/dev/null && [ -n "$(tmux list-clients -t main 2>/dev/null)" ]; then
        exec tmux new-session
    else
        exec tmux new-session -A -s main
    fi
fi
