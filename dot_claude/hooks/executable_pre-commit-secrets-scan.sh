#!/bin/bash
# Pre-commit hook: block git commits containing plaintext secrets
# Triggered by Claude Code PreToolUse on Bash: any `git [global opts] commit …`, incl. `sudo git -C <dir> commit`

set -euo pipefail

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Only check git commit commands — including the fleet idiom `sudo git -C /opt/services commit …`
# (global options may sit between `git` and `commit`; only `-C <dir>` is honoured for WHERE to scan,
# `--git-dir`/`--work-tree`/`cd X &&` fall back to the session cwd and fail open).
# COVERAGE LIMIT (2026-11-04): this is a PreToolUse scan of the INDEX as it is before the command runs,
# so the fleet's usual `sudo git -C … add <paths> && sudo git -C … commit` form is NOT scanned — the add
# has not happened yet. The real control for /opt/services is the repo's own .githooks/pre-commit
# (core.hooksPath; wanda has it, serp does not). This hook catches a commit of an already-staged index.
GIT_COMMIT_RE='git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit([[:space:]]|$)'
if ! printf '%s' "$COMMAND" | grep -qE "$GIT_COMMIT_RE"; then
  exit 0
fi
# Scan the repo the command targets: `-C <dir>` wins over the session cwd.
REPO=$(printf '%s' "$COMMAND" | grep -oE "$GIT_COMMIT_RE" | head -1 | grep -oE -- '-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}' | tr -d "\"'" || true)   # no -C → empty, never a failure under set -e/pipefail
[[ -n "$REPO" ]] && CWD="$REPO"

# Get the staged diff — only NON-template files (templates legitimately carry
# placeholders/op:// refs; rendered secret files are gitignored). Mirrors the real
# git hook /opt/services/.githooks/pre-commit — keep the two in sync.
SCAN_FILES=$(cd "$CWD" && git diff --cached --name-only --diff-filter=d 2>/dev/null | grep -vE '\.(tpl|sample|example|template)$' || true)
DIFF=""
[[ -n "$SCAN_FILES" ]] && DIFF=$(cd "$CWD" && git diff --cached -- $SCAN_FILES 2>/dev/null || true)

if [[ -z "$DIFF" ]]; then
  exit 0
fi

# Added lines (+ prefix) with a secret-ish key before : or =, EXCLUDING: op:// refs,
# comments, empty values, template interpolation ({{ }} / $( )), and YAML env-var
# references (recyclarr's !env_var / !ENV — a name, never a value).
SUSPECT=$(echo "$DIFF" | grep -E '^\+' | grep -v '^+++' | grep -v 'op://' | grep -v '^+#' | grep -iE '(password|passwd|secret|token|api.?key|credential)\s*[:=]' | grep -ivE '(password|token|secret|key)\s*[:=]\s*["'"'"']?\s*$' | grep -ivE '\{\{|\$\(|!env_var|!ENV' || true)

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
