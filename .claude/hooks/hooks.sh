#!/bin/bash

HOOK_TYPE="$1"

case "$HOOK_TYPE" in
  stop)
    #notify-send 'Claude Code' 'Task completed ❇️'
    paplay ~/.claude/hooks/Cloud.wav
    ;;
  notification)
    #notify-send 'Claude Code' 'Action required ⚡'
    paplay ~/.claude/hooks/Polite.wav
    ;;
  *)
    #notify-send 'Claude Code' 'Event occurred'
    paplay /usr/share/sounds/freedesktop/stereo/dialog-information.oga
    ;;
esac