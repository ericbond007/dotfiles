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

# Match the fleet idiom too (`sudo git -C /opt/services commit …`; 2026-11-05 — the old `git commit`
# match never saw it) and read the repo named by -C rather than the session cwd.
GIT_COMMIT_RE='git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit([^[:alnum:]_-]|$)'
if ! printf '%s' "$COMMAND" | grep -qE "$GIT_COMMIT_RE"; then
  exit 0
fi
# An ssh-wrapped commit targets another host's repo: nothing to inspect here.
MATCHED_CMD=$(printf '%s' "$COMMAND" | grep -oE "$GIT_COMMIT_RE" | head -1)
PREFIX=${COMMAND%%"$MATCHED_CMD"*}
if printf '%s' "$PREFIX" | grep -qE '(^|[[:space:];&|(])ssh[[:space:]]'; then
  exit 0
fi
REPO=$(printf '%s' "$COMMAND" | grep -oE "$GIT_COMMIT_RE" | head -1 | grep -oE -- '-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}' | tr -d "\"'" || true)
if [[ -n "$REPO" ]]; then
  case "$REPO" in "~") REPO="$HOME";; "~/"*) REPO="$HOME/${REPO#\~/}";; esac
  case "$REPO" in /*) ;; *) REPO="$CWD/$REPO";; esac
  CWD="$REPO"
fi
# A commit INTO the wiki is the update itself — never nag about it (its pages mention traefik/pihole/…).
case "$CWD" in /opt/services/wiki|/opt/services/wiki/*) exit 0;; esac

# Check what paths were in the commit (read-only; repo-local code paths disabled as in the secrets scan)
CHANGED=$(cd "$CWD" 2>/dev/null && git -c core.fsmonitor= -c core.hooksPath=/dev/null --no-pager diff-tree --root --no-commit-id --name-only -r HEAD 2>/dev/null || true)

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
  # PostToolUse: stderr on exit 0 reaches only the transcript, never the model (hook docs) — this reminder
  # was invisible to the session it was written for until 2026-11-05. JSON additionalContext on stdout reaches it.
  MSG="Wiki update recommended — significant config changed:${MATCHED}
Update docs at /opt/services/wiki/docs/ then: cd /opt/services/wiki && sudo -u wiki mkdocs build (commit as the wiki user; see the reading-writing-the-ops-wiki skill)"
  jq -nc --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
fi

# Always exit 0 — this is advisory, not blocking
exit 0
