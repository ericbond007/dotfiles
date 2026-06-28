#!/usr/bin/env bash
# code-review-before-done.sh — Stop hook, fleet-wide.
#
# Dave's standing order (2026-06-27): after writing or modifying code, a
# SEPARATE code review (fresh eyes that did NOT write the code) must run before
# the agent declares the work done. Self-review by the writer is not enough — a
# separate pass consistently finds real issues.
#
# Mechanism: on Stop, scan the session transcript. If a code file was edited but
# no review action appears AFTER the last code edit, BLOCK the stop (Claude keeps
# working) with instructions to run /code-review or dispatch a reviewer subagent.
# Once a review action lands after the last edit, the stop is allowed. If a fix
# edits code again, it re-blocks until re-reviewed (fix -> re-review is correct).
#
# Escape hatch: `touch "$marker"` (path is in the block message) forces allow —
# use only if a review genuinely ran and detection missed it, or for a change
# you have a real reason not to review.
#
# Stop-hook contract (verified current Claude Code): block via
# {"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":...}}
# on stdout, exit 0. An 8-block cap + the marker prevent infinite loops.
set -u

# jq is a documented fleet dependency; if absent, degrade to no-op (never wedge a stop).
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

# Can't evaluate without a readable transcript -> allow (fail open, never wedge).
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

marker="${TMPDIR:-/tmp}/claude-review-ok-${session:-nosession}"
[ -f "$marker" ] && exit 0

# Last transcript line that edited/wrote a CODE file (tool name + code extension
# co-occur on the tool_use line; tool_result echoes lack the "name" key).
code_tool='"name":[[:space:]]*"(Edit|Write|MultiEdit)"'
code_ext='\.(ts|tsx|js|jsx|mjs|cjs|svelte|vue|py|go|rs|java|rb|php|c|cc|cpp|cxx|h|hpp|cs|swift|kt|kts|scala|lua|pl|pm|sh|bash|zsh|fish|sql|tf)"'
last_edit=$(grep -nE "$code_tool" "$transcript" 2>/dev/null | grep -E "$code_ext" | tail -1 | cut -d: -f1)

# No code touched this session -> nothing to enforce.
[ -z "$last_edit" ] && exit 0

# Last transcript line showing a SEPARATE code-review action: a review skill, a
# reviewer subagent (Skill/Task/Agent tool_use whose payload mentions review),
# or a /code-review|/security-review|/review command, or a code-reviewer agent.
review_re='("name":[[:space:]]*"(Skill|Task|Agent)".*[Rr]eview)|(/code-review)|(/security-review)|(/review)|(code-reviewer)|(requesting-code-review)'
last_review=$(grep -nE "$review_re" "$transcript" 2>/dev/null | tail -1 | cut -d: -f1)

# A review landed AFTER the last code edit -> the work was reviewed -> allow.
if [ -n "$last_review" ] && [ "$last_review" -gt "$last_edit" ] 2>/dev/null; then
  exit 0
fi

reason="STANDING ORDER (Dave, fleet-wide): code was written or modified this session, but no SEPARATE code review has run after the last code change. Before finishing, run a fresh-eyes review that did NOT write the code — invoke the /code-review command, or dispatch a reviewer subagent (e.g. the superpowers:requesting-code-review skill or a code-reviewer agent) — and address its findings. Then finish. Re-review after any fix that changes code. If you GENUINELY already ran a separate review this session and this check missed it (or you have a real reason to skip for this specific change), override with:  touch '${marker}'"

jq -nc --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"Stop",decision:"block",reason:$r}}'
exit 0
