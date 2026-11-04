#!/bin/bash
# Block direct writes to files owned by service users without sudo
# Remind to use proper ownership/permissions workflow
# Triggered by Claude Code PreToolUse on Edit/Write

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only check Edit/Write tools (MultiEdit dropped 2026-11-03 — the tool no longer exists).
if [[ "$TOOL" != "Edit" && "$TOOL" != "Write" ]]; then
  exit 0
fi

if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
  exit 0
fi

# Get file owner
OWNER=$(stat -c '%U' "$FILE_PATH" 2>/dev/null || true)

if [[ -z "$OWNER" ]]; then
  exit 0
fi

# Service users that own their config files
SERVICE_USERS=(
  "wiki"
  "music-search"
  "homeassistant"
  "homepage"
  "navidrome"
  "rtlamr"
  "frontcam"
  "sonarr"
  "radarr"
  "lidarr"
  "prowlarr"
  "jackett"
  "qbt"
  "sabnzbd"
  "pihole"
  "mosquitto"
  "dovecot"
  "postfix"
  "trunk-recorder"   # serp: scanner-transcriber (added 2026-11-04 when serp got this hook)
)

for user in "${SERVICE_USERS[@]}"; do
  if [[ "$OWNER" == "$user" ]]; then
    echo "BLOCKED: ${FILE_PATH} is owned by service user '${user}'." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  1. Use Bash with sudo to edit: sudo vi ${FILE_PATH}" >&2
    echo "  2. If this is config, edit via the service's management interface" >&2
    echo "  3. If ownership is wrong, fix it: sudo chown ${user}:${user} ${FILE_PATH}" >&2
    exit 2
  fi
done

# Also block edits to root-owned files in /opt/services (HA .storage, etc.)
if [[ "$FILE_PATH" =~ ^/opt/services/ && "$OWNER" == "root" ]]; then
  # Allow .tpl files and .gitignore (those are meant to be edited)
  if [[ "$FILE_PATH" =~ \.(tpl|gitignore)$ ]]; then
    exit 0
  fi
  # Allow docker-compose files (root-owned but edited directly)
  if [[ "$FILE_PATH" =~ docker-compose\.ya?ml$ ]]; then
    exit 0
  fi
  echo "BLOCKED: ${FILE_PATH} is owned by root." >&2
  echo "" >&2
  echo "Use sudo to edit root-owned service files." >&2
  exit 2
fi

exit 0
