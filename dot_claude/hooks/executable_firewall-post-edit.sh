#!/bin/bash
# Post-edit reminder: after editing nftables.conf, remind to validate + reload + commit + wiki
# Triggered by Claude Code PostToolUse on Edit/Write

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ "$TOOL" != "Edit" && "$TOOL" != "Write" && "$TOOL" != "MultiEdit" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != *"nftables"* ]]; then
  exit 0
fi

echo "Firewall config modified. Next steps:" >&2
echo "  1. Validate:  sudo nft -c -f /etc/nftables.conf" >&2
echo "  2. Reload:    sudo systemctl restart nftables" >&2
echo "  3. Verify:    sudo nft list ruleset | grep -c 'chain'" >&2
echo "  4. Commit:    sudo config-commit \"update firewall rules\"" >&2
echo "  5. Wiki:      update /opt/services/wiki/docs/ firewall page" >&2

exit 0
