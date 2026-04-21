#!/usr/bin/env bash
# Fire desktop notifications for Claude Code events — only when inside tmux.
# Kitty handles OSC 9 notifications natively outside tmux; firing the hook
# there would produce duplicate notifications.
[ -z "$TMUX" ] && exit 0

payload=$(cat)
message=$(jq -r '.message // "Claude needs your attention"' <<<"$payload")
title=$(jq -r '.title // empty' <<<"$payload")

context=""
if [ -n "$TMUX_PANE" ]; then
    context=$(tmux display-message -p -t "$TMUX_PANE" '#S:#I #W' 2>/dev/null)
fi

summary="Claude Code"
[ -n "$context" ] && summary="$summary — $context"
[ -n "$title" ]   && summary="$summary: $title"

notify-send -a "Claude Code" -u normal "$summary" "$message"
