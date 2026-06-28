#!/usr/bin/env bash
# code-review-before-done.sh — Stop hook, fleet-wide.
#
# Dave's standing order (2026-06-27): after writing or modifying code, a
# SEPARATE code review (fresh eyes that did NOT write the code) must run before
# the agent declares the work done. Self-review by the writer is not enough — a
# separate pass consistently finds real issues (this hook's own first draft
# shipped two critical bugs that a separate review caught).
#
# Mechanism: on Stop, scan the session transcript (JSONL). Find the last
# assistant tool_use that EDITED a code file, and the last assistant tool_use
# (or slash command) that was a REVIEW action. If a code edit has no review
# after it, BLOCK the stop (Claude keeps working) with instructions. A fix that
# edits code again re-blocks until re-reviewed (fix -> re-review is correct).
#
# Detection is STRUCTURAL, not substring: it only counts a real assistant
# tool_use. This is load-bearing — the recurring skill/agent *listing*
# attachments, tool_result echoes, assistant prose, and this hook's own
# block-reason text all mention "code-review" but are NOT a review being run.
# Matching them as reviews would silently no-op the gate.
#
# Escape hatch: `touch "$marker"` (path is in the block message). Fail-open
# everywhere: any internal error allows the stop, never wedges a session.
#
# Stop-hook contract (verified current Claude Code): block via
# {"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":...}}
# on stdout, exit 0. An 8-block cap + the marker prevent infinite loops.
set -u

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

marker="${TMPDIR:-/tmp}/claude-review-ok-${session:-nosession}"
[ -f "$marker" ] && exit 0

# One structural pass. Emits "<last_edit_line> <last_review_line>" (0 if none).
read -r last_edit last_review < <(
  jq -nr '
    def code_edit($c):
      ($c.type? == "tool_use")
      and ($c.name? | test("^(Edit|Write|MultiEdit)$"))
      and (($c.input.file_path? // "")
           | test("\\.(ts|tsx|js|jsx|mjs|cjs|svelte|vue|py|go|rs|java|rb|php|c|cc|cpp|cxx|h|hpp|cs|swift|kt|kts|scala|lua|pl|pm|sh|bash|zsh|fish|sql|tf)$"));
    def review($c):
      ($c.type? == "tool_use") and (
        ((($c.name? == "Task") or ($c.name? == "Agent"))
          and ((($c.input.description? // "") | test("review";"i"))
               or (($c.input.subagent_type? // "") | test("review";"i"))))
        or (($c.name? == "Skill")
            and (($c.input.skill? // $c.input.command? // "") | test("code-review|requesting-code-review|security-review";"i")))
        or (($c.name? == "SlashCommand")
            and (($c.input.command? // "") | test("code-review|security-review";"i")))
      );
    reduce (inputs) as $m ({e:0,r:0};
      input_line_number as $ln
      | (($m.message.content?) // []) as $content
      | if (($content|type) == "array") and ($content | any(code_edit(.))) then .e = $ln
        elif (($content|type) == "array") and ($content | any(review(.)))    then .r = $ln
        else . end)
    | "\(.e) \(.r)"
  ' "$transcript" 2>/dev/null
)

# jq failed or produced no parseable result -> fail open.
[ -n "${last_edit:-}" ] && [ -n "${last_review:-}" ] || exit 0
case "${last_edit}${last_review}" in *[!0-9]*) exit 0 ;; esac

# No code edited this session -> nothing to enforce.
[ "$last_edit" -eq 0 ] && exit 0
# A review action landed AFTER the last code edit -> allow.
[ "$last_review" -gt "$last_edit" ] && exit 0

reason="STANDING ORDER (Dave, fleet-wide): code was written or modified this session, but no SEPARATE code review has run after the last code change. Before finishing, run a fresh-eyes review that did NOT write the code — invoke the /code-review command, or dispatch a reviewer subagent (e.g. the superpowers:requesting-code-review skill or a code-reviewer agent) — and address its findings. Then finish. Re-review after any fix that changes code. If you GENUINELY already ran a separate review this session and this check missed it (or you have a real reason to skip for this specific change), override with:  touch '${marker}'"

jq -nc --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"Stop",decision:"block",reason:$r}}'
exit 0
