#!/usr/bin/env bash
# Apply the Tokyo Night colour scheme to the default GNOME Terminal profile.
#
# Idempotent: safe to re-run. Invoked by ~/.config/yadm/bootstrap on a new
# machine so the terminal re-themes itself after `yadm clone`. The companion
# backup/restore lives in ~/.config/gnome-terminal-backup/.
set -euo pipefail

if ! command -v gsettings >/dev/null 2>&1 || ! command -v dconf >/dev/null 2>&1; then
    echo "gsettings/dconf not available; skipping GNOME Terminal theme." >&2
    exit 0
fi

profile=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'")
if [ -z "$profile" ]; then
    echo "No default GNOME Terminal profile found; skipping." >&2
    exit 0
fi
p="/org/gnome/terminal/legacy/profiles:/:$profile/"

dconf write "${p}use-theme-colors"          "false"
dconf write "${p}background-color"           "'#1A1B26'"
dconf write "${p}foreground-color"           "'#C0CAF5'"
dconf write "${p}bold-color-same-as-fg"      "true"
dconf write "${p}palette" "['#15161E', '#F7768E', '#9ECE6A', '#E0AF68', '#7AA2F7', '#BB9AF7', '#7DCFFF', '#A9B1D6', '#414868', '#F7768E', '#9ECE6A', '#E0AF68', '#7AA2F7', '#BB9AF7', '#7DCFFF', '#C0CAF5']"
dconf write "${p}cursor-colors-set"          "true"
dconf write "${p}cursor-background-color"     "'#C0CAF5'"
dconf write "${p}cursor-foreground-color"     "'#1A1B26'"
dconf write "${p}highlight-colors-set"        "true"
dconf write "${p}highlight-background-color"  "'#283457'"
dconf write "${p}highlight-foreground-color"  "'#C0CAF5'"

echo "Applied Tokyo Night to GNOME Terminal profile ${profile}."
