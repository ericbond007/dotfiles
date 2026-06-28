#!/usr/bin/env bash
# npm-install-review.sh — PreToolUse(Bash) guard for GLOBAL npm/pnpm/yarn/bun installs.
#
# Why: the JS package supply chain is a real malware vector. The 2026-06 "atomic-lockfile"
# campaign shipped infostealers via npm/bun packages (atomic-lockfile / lockfile-js /
# js-digest, publisher herbsobering) AND through dependency trees + lifecycle (install)
# scripts. aur-review.sh gates AUR but NOT npm, so a global `npm install -g` (incl. ones
# wrapped in `ssh host '...'`) slid through unreviewed — closing that gap.
#
# Mechanism: block (exit 2) the first attempt and tell Claude to review the package + its
# dependency tree + any install scripts first, then re-run prefixed with `env NPM_OK=1 `
# (works in fish AND bash), which this hook passes through untouched. Mirrors aur-review.sh /
# blast-radius.sh's block-once idiom.
#
# Scope: GLOBAL installs only (-g / --global / --location=global / `yarn global add`) —
# system-wide, persistent, run as the user. Matched ANYWHERE in the command so it also
# catches installs nested in `ssh <host> 'bash -lc "... npm install -g ..."'`. LOCAL project
# installs and read-only npm ops (view/ls/audit/outdated/search) are intentionally NOT gated.
set -u

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

# Operator already reviewed the package(s) — pass through.
case "$cmd" in *NPM_OK=1*) exit 0 ;; esac

# Cheap fast-path: does it even mention a JS package manager?
printf '%s' "$cmd" | grep -qE '\b(npm|pnpm|yarn|bun)\b' || exit 0

# Global-install signatures (install verb + a global flag within the same command segment).
GLOBAL='([[:space:]]-g([[:space:]]|$)|--global([[:space:]]|$)|--location[= ]global)'
blocked=0
printf '%s' "$cmd" | grep -qE "\b(npm|pnpm|bun)[[:space:]]+(install|i|add|up|update)\b[^|;&]*${GLOBAL}" && blocked=1
printf '%s' "$cmd" | grep -qE '\byarn[[:space:]]+global[[:space:]]+add\b' && blocked=1
[ "$blocked" -eq 1 ] || exit 0

{
  echo "NPM-REVIEW GUARD: this command installs a package GLOBALLY (npm/pnpm/yarn/bun),"
  echo "pulling its full dependency tree — a real supply-chain malware vector."
  echo "Command: $cmd"
  echo
  echo "Before letting it run, review the package and its deps WITHOUT installing:"
  echo "  npm view <pkg>                 # publisher, repo, version, dist-tags"
  echo "  npm view <pkg> dependencies    # direct deps"
  echo "  # (post-install you can also: npm ls -g <pkg> --all  +  scan node_modules)"
  echo
  echo "Look for: IOC names (atomic-lockfile / lockfile-js / js-digest), publisher"
  echo "'herbsobering', typosquats, unexpected/obfuscated pre/post/install scripts,"
  echo "off-upstream repository URLs, and a dependency tree that doesn't match expectations."
  echo
  echo "If it is clean and you intend to proceed, re-run prefixed with: env NPM_OK=1"
  echo "If anything looks off, STOP and ask Dave."
} >&2
exit 2
