#!/usr/bin/env bash
# Fire desktop notifications for Codex turn completion only when inside tmux.
# Outside tmux, Codex's terminal notification mechanism can handle the alert.
[ -z "${TMUX:-}" ] && exit 0

# Codex passes its notification payload as the first argument. Accept stdin as
# well so the script remains easy to exercise by hand.
payload=${1:-}
[ -n "$payload" ] || payload=$(cat)

message=$(jq -r '."last-assistant-message" // .message // "Codex needs your attention"' <<<"$payload")

context=""
if [ -n "${TMUX_PANE:-}" ]; then
    context=$(tmux display-message -p -t "$TMUX_PANE" '#S:#I #W' 2>/dev/null)
fi

summary="Codex"
[ -n "$context" ] && summary="$summary — $context"

notify-send -a "Codex" -u normal "$summary" "$message"
