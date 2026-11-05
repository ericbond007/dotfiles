#!/bin/bash
# Block edits to generated secret files — edit the .tpl source instead
# Triggered by Claude Code PreToolUse on Edit/Write/NotebookEdit

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')   # NotebookEdit sends notebook_path (2026-11-05)

# Only check Edit/Write/NotebookEdit tools (MultiEdit dropped 2026-11-03 — the tool no longer exists).
if [[ "$TOOL" != "Edit" && "$TOOL" != "Write" && "$TOOL" != "NotebookEdit" ]]; then
  exit 0
fi

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Check if a .tpl source exists for this file
if [[ -f "${FILE_PATH}.tpl" ]]; then
  echo "BLOCKED: ${FILE_PATH} is generated from ${FILE_PATH}.tpl" >&2
  echo "" >&2
  echo "Edit the .tpl template instead, then run: sudo op-deploy-secrets" >&2
  exit 2
fi

# Known generated files that should never be edited directly
GENERATED_PATTERNS=(
  "/etc/postfix/mysql-virtual-domains.cf"
  "/etc/postfix/mysql-virtual-mailbox-maps.cf"
  "/etc/postfix/mysql-virtual-alias-maps.cf"
  "/etc/dovecot/dovecot.conf"
  "/opt/services/homepage/config/services.yaml"
  "/opt/services/front-yard-cam/stream.env"
  "/opt/services/front-yard-cam/sensor-bridge.env"
)

for pattern in "${GENERATED_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == "$pattern" ]]; then
    echo "BLOCKED: ${FILE_PATH} is a generated secrets file." >&2
    echo "" >&2
    echo "Edit ${FILE_PATH}.tpl instead, then run: sudo op-deploy-secrets" >&2
    exit 2
  fi
done

exit 0
