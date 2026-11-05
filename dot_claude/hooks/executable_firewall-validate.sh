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
# sudo -n (2026-11-05): never hang on a password prompt inside a hook; if sudo cannot run non-interactively
# the guard fails CLOSED with its own message instead of mis-reporting a syntax error.
if ! sudo -n true 2>/dev/null; then
  echo "BLOCKED: cannot validate /etc/nftables.conf — sudo needs a password in this context, so the pre-reload check cannot run (or sudo itself failed). Fix sudo for this session, or validate (sudo nft -c -f /etc/nftables.conf) and reload outside it — this hook keeps blocking the reload until the check can run." >&2
  exit 2
fi
if ! RESULT=$(sudo -n nft -c -f /etc/nftables.conf 2>&1); then
  echo "BLOCKED: nftables config has syntax errors." >&2
  echo "" >&2
  echo "$RESULT" >&2
  echo "" >&2
  echo "Fix /etc/nftables.conf before reloading." >&2
  exit 2
fi

exit 0
