#!/usr/bin/env bash
# blast-radius.sh — PreToolUse(Bash) guard for process-destructive commands.
#
# Why: Claude has killed/stressed processes without checking what was running
# (16-core stress test under a live game -> 94degC; broad pkill firefox nearly
# took out an active Playwright session). This hook forces one deliberate look
# at the live process table before any kill/stress-class command executes.
#
# Mechanism: block (exit 2) the first attempt and hand Claude the current
# heavyweight-process list on stderr. If the targets are still correct, the
# command is re-run prefixed with `env BLAST_OK=1 ` (works in fish AND bash),
# which this hook passes through untouched.
set -u

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

# Operator already reviewed the blast radius — pass through.
case "$cmd" in *BLAST_OK=1*) exit 0 ;; esac

# kill/pkill/killall/stress/stress-ng as a standalone word in command position
# (start of line or after ; & | or whitespace). \b keeps "killed"/"skill" clean;
# "tmux kill-window" and "docker kill" intentionally match — they're destructive too.
printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])(sudo[[:space:]]+)?(kill|pkill|killall|stress|stress-ng)\b' || exit 0

{
  echo "BLAST-RADIUS GUARD: this command kills processes or loads the system."
  echo "Command: $cmd"
  echo
  echo "Top CPU consumers right now:"
  ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -8
  echo
  watch='steam|gamescope|playwright|firefox|chromium|chrome|wine|proton|obs|mpv|kdenlive'
  # drop browser child processes (--type=...) and truncate long arg lines
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
