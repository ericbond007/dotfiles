#!/bin/bash
# Post-commit reminder: nudge to update wiki when significant paths change
# Triggered by Claude Code PostToolUse on Bash (after git commit succeeds)

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Only check successful git commits
if [[ "$TOOL" != "Bash" ]]; then
  exit 0
fi

if [[ ! "$COMMAND" =~ git[[:space:]]commit ]]; then
  exit 0
fi

# Check what paths were in the commit
CHANGED=$(cd "$CWD" && git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)

if [[ -z "$CHANGED" ]]; then
  exit 0
fi

# Paths that warrant a wiki update
WIKI_TRIGGERS=(
  "nftables"
  "traefik"
  "docker-compose"
  "systemd/system"
  "op-deploy-secrets"
  "dnsmasq"
  "pihole"
  "postfix"
  "dovecot"
)

MATCHED=""
for trigger in "${WIKI_TRIGGERS[@]}"; do
  if echo "$CHANGED" | grep -q "$trigger"; then
    MATCHED="${MATCHED} ${trigger}"
  fi
done

if [[ -n "$MATCHED" ]]; then
  echo "Wiki update recommended — significant config changed:${MATCHED}" >&2
  echo "Update docs at /opt/services/wiki/docs/ then: cd /opt/services/wiki && mkdocs build && sudo chown -R wiki:wiki site/" >&2
fi

# Always exit 0 — this is advisory, not blocking
exit 0
