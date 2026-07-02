#!/bin/bash
# Pre-reload validation: block nftables reload if config has syntax errors
# Triggered by Claude Code PreToolUse on Bash

set -euo pipefail

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Match nftables reload commands
if [[ ! "$COMMAND" =~ (nft[[:space:]]+-f|nft[[:space:]]+--file|systemctl[[:space:]]+(restart|reload)[[:space:]]+nftables) ]]; then
  exit 0
fi

# Validate syntax before allowing reload. The status MUST be captured in the
# `if` itself: under `set -e` a failing bare $(...) assignment kills the script
# at exit 1 (non-blocking) before any check runs — i.e. the guard failed OPEN
# on exactly the broken-config case it exists for (aiImprove audit 2026-07-01).
if ! RESULT=$(sudo nft -c -f /etc/nftables.conf 2>&1); then
  echo "BLOCKED: nftables config has syntax errors." >&2
  echo "" >&2
  echo "$RESULT" >&2
  echo "" >&2
  echo "Fix /etc/nftables.conf before reloading." >&2
  exit 2
fi

exit 0
