#!/usr/bin/env bash
# bash-guards.sh — single PreToolUse(Bash) dispatcher for the fleet's Bash guards.
#
# Merges blast-radius.sh + aur-review.sh + npm-install-review.sh (2026-07-01,
# aiImprove audit): three hook processes × 2 jq forks each per Bash call became
# ONE process + ONE jq parse. Guard semantics and the block-once + env-override
# idiom are unchanged: BLAST_OK=1 / AUR_OK=1 / NPM_OK=1 prefixes pass through.
# The old three scripts are exec-shims onto this file for sessions that
# snapshotted the pre-merge registration; delete them once those sessions end.
#
# Hardening added in the merge (closing audit findings):
#   - binaries also match path-prefixed (/bin/kill, /usr/bin/yay) and
#     `command `/`exec `-prefixed forms;
#   - `pacman -U <pkgfile>` is gated (a locally-built package still runs
#     arbitrary .install scriptlets) under the AUR_OK idiom;
#   - npx/bunx/pnpm dlx/yarn dlx are gated when they look like a REMOTE fetch
#     (-y/--yes, a name@version/@latest spec, or an @scope/ package) under the
#     NPM_OK idiom. Bare `npx <local-bin>` (svelte-check, vitest…) still passes —
#     accepted residual risk, kept for friction reasons.
# Fail-open contract: any parse failure exits 0 — guards must never wedge a
# session on their own bugs.
set -u

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
eval "$(printf '%s' "$payload" \
  | jq -r '@sh "tool=\(.tool_name // "") cmd=\(.tool_input.command // "")"' 2>/dev/null)" || exit 0
[ "${tool:-}" = "Bash" ] || exit 0
[ -n "${cmd:-}" ] || exit 0

# Optional path/wrapper prefix for a binary in command position.
BIN='(/[[:alnum:]_./-]*/)?'
# Command position: start of line, or after ; & | or $( — optionally sudo/command/exec.
POS='(^|[;&|]|[$][(])[[:space:]]*(sudo[[:space:]]+)?(command[[:space:]]+|exec[[:space:]]+)?'

# ---------------------------------------------------------------- BLAST RADIUS
# Kill/stress-class commands: force one deliberate look at the process table.
case "$cmd" in *BLAST_OK=1*) : ;; *)
if printf '%s' "$cmd" | grep -qE "(^|[;&|[:space:]])(sudo[[:space:]]+)?(command[[:space:]]+|exec[[:space:]]+)?${BIN}(kill|pkill|killall|stress|stress-ng)\b"; then
  {
    echo "BLAST-RADIUS GUARD: this command kills processes or loads the system."
    echo "Command: $cmd"
    echo
    echo "Top CPU consumers right now:"
    ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -8
    echo
    watch='steam|gamescope|playwright|firefox|chromium|chrome|wine|proton|obs|mpv|kdenlive'
    hits="$(ps -eo pid,comm,args 2>/dev/null | grep -iE "$watch" | grep -v 'grep -iE' \
            | grep -v -- '--type=' | cut -c1-120 | head -8)" || true
    if [ -n "${hits:-}" ]; then
      echo "Possibly-active user sessions (collateral risk):"
      echo "$hits"
      echo
    fi
    echo "Review the list above. If the targets are exactly what you intend and no"
    echo "active user work (game, Playwright, browser session) is collateral, re-run"
    echo "the command prefixed with: env BLAST_OK=1"
    echo "If anything listed could be the user's live work, STOP and ask Dave first."
  } >&2
  exit 2
fi ;; esac

# ------------------------------------------------------------------ AUR REVIEW
# AUR builds/installs/upgrades run arbitrary maintainer code; read the PKGBUILD
# first. Read-only ops (-Ss/-Si/-Q*, and -G, the review-fetch itself) pass.
case "$cmd" in *AUR_OK=1*) : ;; *)
if printf '%s' "$cmd" | grep -qE '\b(yay|paru|makepkg|pacman)\b'; then
  aur_blocked=0
  printf '%s' "$cmd" | grep -qE "${POS}${BIN}(yay|paru)[[:space:]]+-S[a-z]*u"                 && aur_blocked=1
  # -S / -Sy / -Syy + target (install); -Sy* keeps read-only -Ss/-Si/-Sl/-Sg passing
  printf '%s' "$cmd" | grep -qE "${POS}${BIN}(yay|paru)[[:space:]]+-Sy*([[:space:]]|$)"       && aur_blocked=1
  printf '%s' "$cmd" | grep -qE "${POS}${BIN}(yay|paru)[[:space:]]+--sync([[:space:]]|$)"     && aur_blocked=1
  printf '%s' "$cmd" | grep -qE "${POS}${BIN}(yay|paru)([[:space:]]*$|[[:space:]]+[^-[:space:]])" && aur_blocked=1
  printf '%s' "$cmd" | grep -qE "${POS}${BIN}makepkg([[:space:]]*$|[[:space:]]+(-[a-z]*[isf][a-z]*|--install|--syncdeps))" && aur_blocked=1
  printf '%s' "$cmd" | grep -qE "${POS}${BIN}(pacman|yay|paru)[[:space:]]+(-[A-Za-z]*U[A-Za-z]*|--upgrade)\b" && aur_blocked=1
  if [ "$aur_blocked" -eq 1 ]; then
    {
      echo "AUR-REVIEW GUARD: this command builds/installs/upgrades AUR or local packages,"
      echo "which run arbitrary maintainer code from the PKGBUILD / .install scriptlets."
      echo "Command: $cmd"
      echo
      echo "Before letting it run, inspect the PKGBUILD(s) WITHOUT building:"
      echo "  yay -G <pkg>      # clones PKGBUILD + sources into ./<pkg>/ (no build)"
      echo "  # then Read: PKGBUILD, *.install, and any local source files."
      echo "  # for pacman -U <file>: inspect the .PKGINFO/.INSTALL inside the package."
      echo
      echo "Look for: curl|wget piped to sh/bash, base64/eval/obfuscated blobs,"
      echo "unexpected network fetches, suspicious prepare()/build()/package() or"
      echo "post-install hooks, sources pointing off the upstream project, and names"
      echo "on the AUR-malware campaign lists (github.com/lenucksi/aur-malware-check,"
      echo "data/campaigns/). For an UPGRADE, review the PKGBUILD diff."
      echo
      echo "If it is clean and you intend to proceed, re-run prefixed with: env AUR_OK=1"
      echo "If anything looks off, STOP and ask Dave."
    } >&2
    exit 2
  fi
fi ;; esac

# ------------------------------------------------------------------ NPM REVIEW
# Global JS installs + remote-exec (npx-class) pull whole dependency trees and
# run lifecycle scripts — supply-chain vector. Local installs stay ungated.
case "$cmd" in *NPM_OK=1*) : ;; *)
if printf '%s' "$cmd" | grep -qE '\b(npm|pnpm|yarn|bun|npx|bunx)\b'; then
  GLOBAL='([[:space:]]-g([[:space:]]|$)|--global(=true)?([[:space:]]|$)|--location[= ]global)'
  npm_blocked=0
  printf '%s' "$cmd" | grep -qE "\b(npm|pnpm|bun)[[:space:]]+(install|i|add|up|update)\b[^|;&]*${GLOBAL}" && npm_blocked=1
  printf '%s' "$cmd" | grep -qE '\byarn[[:space:]]+global[[:space:]]+add\b' && npm_blocked=1
  # Remote-exec: npx/bunx/pnpm dlx/yarn dlx with -y/--yes, a name@version/@tag
  # spec, or an @scope/ package — the explicit fetch-and-run shapes.
  REXEC="${POS}${BIN}(npx|bunx|(pnpm|yarn)[[:space:]]+dlx|npm[[:space:]]+(exec|x))[[:space:]]+"
  printf '%s' "$cmd" | grep -qE "${REXEC}([^|;&]*[[:space:]])?(-y|--yes)([[:space:]]|$)" && npm_blocked=1
  printf '%s' "$cmd" | grep -qE "${REXEC}([^|;&]*[[:space:]])?[a-zA-Z0-9@._/-]+@[a-zA-Z0-9.^~*-]+" && npm_blocked=1
  printf '%s' "$cmd" | grep -qE "${REXEC}([^|;&]*[[:space:]])?@[a-zA-Z0-9._-]+/" && npm_blocked=1
  # pnpm/yarn dlx ALWAYS fetch from the registry (no local-bin fallback like
  # npx) — any non-flag package argument is a remote fetch-and-run.
  printf '%s' "$cmd" | grep -qE "${POS}${BIN}(pnpm|yarn)[[:space:]]+dlx[[:space:]]+([^|;&]*[[:space:]])?[^-[:space:]]" && npm_blocked=1
  if [ "$npm_blocked" -eq 1 ]; then
    {
      echo "NPM-REVIEW GUARD: this command installs a package GLOBALLY or fetches-and-runs"
      echo "a remote package (npx-class), pulling its dependency tree — a real supply-chain"
      echo "malware vector."
      echo "Command: $cmd"
      echo
      echo "Before letting it run, review the package and its deps WITHOUT installing:"
      echo "  npm view <pkg>                 # publisher, repo, version, dist-tags"
      echo "  npm view <pkg> dependencies    # direct deps"
      echo
      echo "Look for: IOC names (atomic-lockfile / lockfile-js / js-digest), publisher"
      echo "'herbsobering', typosquats, unexpected/obfuscated pre/post/install scripts,"
      echo "off-upstream repository URLs, and a dependency tree that doesn't match expectations."
      echo
      echo "If it is clean and you intend to proceed, re-run prefixed with: env NPM_OK=1"
      echo "If anything looks off, STOP and ask Dave."
    } >&2
    exit 2
  fi
fi ;; esac

exit 0
