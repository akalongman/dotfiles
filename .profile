# ~/.profile: executed by the command interpreter for login shells.
# This file is not read by bash(1), if ~/.bash_profile or ~/.bash_login
# exists.
# see /usr/share/doc/bash/examples/startup-files for examples.
# the files are located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask
# for ssh logins, install and configure the libpam-umask package.
#umask 022

# Canonical exports live in ~/.exports. Source it here so
# GUI sessions (display manager runs .profile in /bin/sh) see the same
# environment as terminals. Keep .exports POSIX-compatible for this to work.
[ -r "$HOME/.exports" ] && . "$HOME/.exports"
[ -r "$HOME/.dotfiles-private/home/.exports" ] && . "$HOME/.dotfiles-private/home/.exports"

# if running bash, source ~/.bashrc
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi


