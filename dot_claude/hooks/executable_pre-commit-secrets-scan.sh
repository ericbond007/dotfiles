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
# (core.hooksPath; wanda since 2026-05, serp since 2026-11-04). This hook catches a commit of an already-staged index.
GIT_COMMIT_RE='git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit([^[:alnum:]_-]|$)'
if ! printf '%s' "$COMMAND" | grep -qE "$GIT_COMMIT_RE"; then
  exit 0
fi
# An ssh-wrapped commit (`ssh host '… git -C /remote/path commit …'`) targets a repo on ANOTHER host:
# nothing here can scan it, and its -C path usually does not exist locally. Leave it to that host's own
# controls (wanda's /opt/services and wiki repos carry their own .githooks) and never block on it.
# Only an `ssh` token BEFORE the git-commit match counts as a wrapper (a commit message that merely
# mentions "ssh …" after it is still scanned).
MATCHED=$(printf '%s' "$COMMAND" | grep -oE "$GIT_COMMIT_RE" | head -1)
PREFIX=${COMMAND%%"$MATCHED"*}
if printf '%s' "$PREFIX" | grep -qE '(^|[[:space:];&|(])ssh[[:space:]]'; then
  exit 0
fi
# Scan the repo the command targets: `-C <dir>` wins over the session cwd (a leading ~ is expanded).
REPO=$(printf '%s' "$COMMAND" | grep -oE "$GIT_COMMIT_RE" | head -1 | grep -oE -- '-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}' | tr -d "\"'" || true)   # no -C → empty, never a failure under set -e/pipefail
# Hardening (2026-11-04, security review): the -C path comes from the command text and this scan runs
# BEFORE approval, so git is run with every repo-local code path disabled — external diff, textconv,
# fsmonitor, hooks, pager, lazy fetch and all remote transports — and the named target is always the
# one scanned (no silent fallback to the session cwd). A -C target that cannot be entered or is not a
# git work tree fails CLOSED (exit 2): a missing or wrong target is never treated as "no diff".
export GIT_NO_LAZY_FETCH=1
GIT=(git -c core.fsmonitor= -c diff.external= -c core.hooksPath=/dev/null -c protocol.allow=never -c core.sshCommand=false -c fetch.negotiationAlgorithm=noop --no-pager)
if [[ -n "$REPO" ]]; then
  case "$REPO" in "~") REPO="$HOME";; "~/"*) REPO="$HOME/${REPO#\~/}";; esac
  case "$REPO" in /*) ;; *) REPO="$CWD/$REPO";; esac   # relative -C is relative to the session cwd
  CWD=$(realpath -m -- "$REPO" 2>/dev/null || printf '%s' "$REPO")
  if ! (cd "$CWD" 2>/dev/null && "${GIT[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    echo "BLOCKED: pre-commit secrets scan cannot enter the -C target '$CWD' (missing, unreadable or not a git work tree) — not scanning blind. Fix the path, or run the commit without -C from inside the repo." >&2
    exit 2
  fi
fi
# Pathspec excludes replace the old file list (no word-splitting of file names, templates skipped in git).
DIFF=$(cd "$CWD" 2>/dev/null && "${GIT[@]}" diff --cached --no-ext-diff --no-textconv --submodule=short --diff-filter=d -- ':/' ':(top,exclude,glob)**/*.tpl' ':(top,exclude,glob)**/*.sample' ':(top,exclude,glob)**/*.example' ':(top,exclude,glob)**/*.template' 2>/dev/null || true)   # ':/' = whole repo even from a subdir

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
