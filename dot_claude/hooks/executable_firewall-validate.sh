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

# Validate syntax before allowing reload
RESULT=$(sudo nft -c -f /etc/nftables.conf 2>&1)
if [[ $? -ne 0 ]]; then
  echo "BLOCKED: nftables config has syntax errors." >&2
  echo "" >&2
  echo "$RESULT" >&2
  echo "" >&2
  echo "Fix /etc/nftables.conf before reloading." >&2
  exit 2
fi

exit 0
