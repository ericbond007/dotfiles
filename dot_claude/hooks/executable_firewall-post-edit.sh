#!/bin/bash
# Post-edit reminder: after editing nftables.conf, remind to validate + reload + commit + wiki
# Triggered by Claude Code PostToolUse on Edit/Write

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ "$TOOL" != "Edit" && "$TOOL" != "Write" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != *"nftables"* ]]; then
  exit 0
fi

# PostToolUse: stderr on exit 0 reaches only the transcript, never the model (hook docs). To put the
# reminder in front of Claude it must be JSON additionalContext on stdout (2026-11-04; before that this
# reminder printed to stderr and was invisible to the session it was written for).
if command -v config-commit >/dev/null 2>&1; then
  COMMIT_STEP='sudo config-commit "update firewall rules"'
else
  COMMIT_STEP='sudo etckeeper commit "update firewall rules"   (no config-commit wrapper on this host)'
fi
MSG="Firewall config modified. Next steps:
  1. Validate:  sudo nft -c -f /etc/nftables.conf
  2. Reload:    sudo systemctl restart nftables
  3. Verify:    sudo nft list ruleset | grep -c 'chain'
  4. Commit:    $COMMIT_STEP
  5. Wiki:      update the firewall page under /opt/services/wiki/docs/ on wanda (ssh wanda if this is not wanda)"
jq -nc --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'

exit 0
