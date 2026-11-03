#!/usr/bin/env bash
# codex-hash-pin.test.sh — the Codex Bash-guard registration (dot_codex/hooks.json) pins the SHA-256
# of the bash-guards SOURCE file and exits 2 on mismatch, which blocks EVERY Codex Bash call.
# Any content change to the source (even a comment) must come with a matching pin update.
# Found the hard way 2026-11-03 (aiImprove audit hygiene bundle): a header-comment edit broke Codex.
#
# Source-tree resolution: relative to this file first (so a scratch copy of a tree tests itself),
# else `chezmoi source-path`, else ~/.local/share/chezmoi — the deployed copy under
# ~/.claude/hooks/tests/ lands on the fallback. Also checks the LIVE ~/.codex/hooks.json pin when
# that file exists (it is what Codex actually reads). Exit 0 = everything in sync, 1 = drift.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [ -f "$here/dot_codex/hooks.json" ]; then src="$here"
else src="$(chezmoi source-path 2>/dev/null)"; [ -n "$src" ] || src="$HOME/.local/share/chezmoi"; fi
guard="$src/dot_claude/hooks/executable_bash-guards.sh"
reg="$src/dot_codex/hooks.json"
echo "source tree: $src"
[ -f "$guard" ] || { echo "FAIL: missing $guard"; exit 1; }
[ -f "$reg" ]   || { echo "FAIL: missing $reg"; exit 1; }
actual="$(/usr/bin/sha256sum "$guard" | cut -d' ' -f1)"
rc=0
check_reg() { # $1 = label, $2 = hooks.json path
  local n pinned
  n="$(/usr/bin/grep -o 'expected=[0-9a-f]\{64\}' "$2" | wc -l)"
  if [ "$n" -ne 1 ]; then echo "FAIL: $1 has $n expected=<sha256> pins, want exactly 1 ($2)"; rc=1; return; fi
  pinned="$(/usr/bin/grep -o 'expected=[0-9a-f]\{64\}' "$2" | cut -d= -f2)"
  if [ "$pinned" = "$actual" ]; then echo "PASS: $1 pin matches the bash-guards source hash ($actual)"
  else echo "FAIL: $1 pin $pinned != bash-guards source hash $actual ($2)"; rc=1; fi
}
check_reg "source dot_codex/hooks.json" "$reg"
if [ -f "$HOME/.codex/hooks.json" ]; then check_reg "live ~/.codex/hooks.json" "$HOME/.codex/hooks.json"
else echo "skip: no ~/.codex/hooks.json on this host"; fi
if [ "$rc" -ne 0 ]; then
  echo "      fix: update expected= in dot_codex/hooks.json, apply ~/.codex/hooks.json, re-trust in Codex /hooks on every Codex host"
fi
exit "$rc"
