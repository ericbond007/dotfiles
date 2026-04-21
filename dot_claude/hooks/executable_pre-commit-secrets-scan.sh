#!/bin/bash
# Pre-commit hook: block git commits containing plaintext secrets
# Triggered by Claude Code PreToolUse on Bash(git commit *)

set -euo pipefail

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Only check git commit commands
if [[ ! "$COMMAND" =~ git[[:space:]]commit ]]; then
  exit 0
fi

# Get the staged diff
DIFF=$(cd "$CWD" && git diff --cached 2>/dev/null || true)

if [[ -z "$DIFF" ]]; then
  exit 0
fi

# Check for added lines (+ prefix) containing secret patterns
# Exclude op:// references (1Password template refs are safe)
# Exclude comments and .tpl template source lines
SUSPECT=$(echo "$DIFF" | grep -E '^\+' | grep -v '^+++' | grep -v 'op://' | grep -v '^+#' | grep -iE '(password|passwd|secret|token|api.?key|credential)\s*[:=]' | grep -ivE '(password|token|secret|key)\s*[:=]\s*["'"'"']?\s*$' | grep -ivE '\{\{|\$\(' || true)

if [[ -n "$SUSPECT" ]]; then
  echo "BLOCKED: Possible plaintext secret in staged changes." >&2
  echo "" >&2
  echo "Suspicious lines:" >&2
  echo "$SUSPECT" | head -n 5 >&2
  echo "" >&2
  echo "If these are 1Password template refs, use op:// syntax." >&2
  echo "If these are safe (variable names, empty values), override with user approval." >&2
  exit 2
fi

exit 0
