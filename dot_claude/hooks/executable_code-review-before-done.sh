#!/usr/bin/env bash
# code-review-before-done.sh — Stop hook, fleet-wide.
#
# Dave's standing order (2026-06-27), made AUTOMATIC and universal 2026-10-18:
# every artifact gets a SEPARATE cold review (a reviewer that did NOT write it)
# before the agent declares the work done. Self-review is not enough. Code gets
# /code-review or a code-reviewer agent; specs, plans, runbooks, systemd units,
# env templates, monitoring rules, hooks, skills and CLAUDE.md get the
# review-design skill (an Opus reviewer agent with the standard brief).
#
# Mechanism: on Stop, scan the session transcript (JSONL). Find the last
# assistant tool_use that EDITED a reviewable artifact, and the last assistant
# tool_use that was a REVIEW action. If an edit has no review after it, BLOCK
# the stop (Claude keeps working) with instructions. A fix that edits again
# re-blocks until re-reviewed (fix -> re-review is correct).
#
# Detection is STRUCTURAL, not substring: only real assistant tool_use blocks
# count. Skill/agent listings, tool_result echoes, assistant prose and this
# hook's own block text all mention "review" and must NOT count.
#
# Stop-hook contract (code.claude.com/docs/en/hooks, re-verified 2026-10-18):
# block by printing  {"decision":"block","reason":"..."}  (TOP-LEVEL decision)
# on stdout and exiting 0. hookSpecificOutput on Stop only carries
# additionalContext. HISTORY: from 2026-06-27 to 2026-10-18 this hook emitted
# {"hookSpecificOutput":{"hookEventName":"Stop","decision":"block"}} — the
# PreToolUse shape — and the harness ignored it: in every transcript on
# flattop there was not one "Stop hook feedback:" injection (the message the
# harness adds when a Stop hook blocks) before 2026-10-18. The gate never fired
# once. NOTE the harness bookkeeping: a successful block shows up as a user
# message "Stop hook feedback: <reason>" and as the reason under
# stop_hook_summary.hookErrors; stop_hook_summary.preventedContinuation stays
# false either way, so it is NOT the signal to check. The test battery asserts
# the documented shape on stdout, and a live end-to-end block (headless session,
# scratch .ts, "Stop hook feedback" injected, agent continued) was observed
# before this version was synced.
#
# Fail-open everywhere: any internal error allows the stop, never wedges a
# session. Malformed transcript lines are skipped (fromjson?), not fatal.
# An 8-block cap per session prevents loops; the cap resets whenever the gate
# allows because a review landed after the last edit. When the cap trips, the
# allow carries a visible systemMessage (2026-11-03) instead of passing silently.
#
# Override, POSITIONAL (not a session-wide off switch): an assistant Bash
# tool_use whose command contains "claude-review-ok-<this session id>" counts
# as a review at that point in the transcript, and the allow then carries a
# visible systemMessage so Dave sees that no reviewer ran.
#
# ACCEPTED RESIDUALS (documented, by design):
#  - edits made through Bash (sed -i, tee, heredocs, `ssh host 'sudo bash -s'`)
#    are invisible to this gate — most live ops edits on wanda/serp are;
#  - edits made by writer SUBAGENTS live in their own transcripts, invisible here;
#  - the Agent DISPATCH of a reviewer counts as the review, even though its
#    findings arrive later — "present only after the findings are in" is honour;
#  - a /code-review typed by Dave himself is a user message, not a tool_use;
#  - tickets, wiki pages and memory files are not gated (CLAUDE.md honour rule).
set -u

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

# Session key: fall back to the transcript basename so an empty session_id
# can't collapse every sessionless run onto one shared "-nosession" marker.
[ -n "$session" ] || session="$(basename "$transcript" .jsonl)"

# Reap stale counters (tmpfs clears on reboot; this covers long uptimes).
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'claude-review-*' -mtime +2 -delete 2>/dev/null || true

# 8-block cap: after 8 blocks in one session WITHOUT an intervening review,
# fail open rather than wedge a session that genuinely lacks review tooling.
counter="${TMPDIR:-/tmp}/claude-review-blocks-${session}"
blocks="$(cat "$counter" 2>/dev/null || true)"
case "$blocks" in *[!0-9]*|'') blocks=0 ;; esac
# (the cap is applied AFTER the scan, so a review that lands after the last
# edit can still reset it — otherwise a capped session stayed off for good)

# One structural pass. Emits "<last_edit_idx> <last_review_idx>" (0 if none).
# NO apostrophes inside the jq program: it sits in a bash single-quoted string
# and one quote silently turns the gate into a no-op (happened 2026-10-18).
read -r last_edit last_review last_kind < <(
  jq -nRr --arg s "$session" '
    # Reviewable artifact = CODE (by extension) or a DESIGN/PLAN/OPS artifact.
    # .tmpl is stripped first so chezmoi sources are judged by their real type.
    # Excluded on purpose: /tmp, session scratchpads, Claude plan-mode files,
    # per-project memory dirs (the CLAUDE.md honour rule covers findings).
    def path_of($c): ((($c.input.file_path? // $c.input.notebook_path? // "") | strings) // "") | sub("\\.(tmpl|tpl)$"; "");
    def excluded($p):
      ($p | test("^/tmp/|/scratchpad/|/\\.claude/plans/|/\\.claude/projects/[^/]+/memory/"));
    def reviewable($p):
      ($p | (test("\\.(ts|tsx|js|jsx|mjs|cjs|svelte|vue|py|go|rs|java|rb|php|c|cc|cpp|cxx|h|hpp|cs|swift|kt|kts|scala|lua|pl|pm|sh|bash|zsh|fish|sql|tf|yaml|yml|nix|zig|ex|exs|ipynb|qml|html|css)$")
            or test("(^|/)(Dockerfile|Makefile|Justfile|Caddyfile)[^/]*$")
            or test("(^|/)package\\.json$")
            or test("/(docs|specs|plans|runbooks|wiki)/.*\\.md$"; "i")
            or test("(^|/)([^/]*[-_.])?(spec|plan|design|runbook|cutover|readme)s?([-_.][^/]*)?\\.md$"; "i")
            or test("\\.(service|timer|socket|path|mount|rules|conf|toml|ini|nft|env)$")
            or test("(^|/)(CLAUDE|AGENTS|CLAUDE-origins)\\.md$")
            or test("/skills/.*\\.md$")
            or test("/(dot_claude|\\.claude)/agents/.*\\.md$")
            or test("/(dot_claude|\\.claude)/.*settings\\.json$")));
    def artifact_edit($c):
      ($c.type? == "tool_use")
      # MultiEdit kept ON PURPOSE (2026-11-03): the tool is gone from the matchers, but a --resume of a
      # pre-removal session still carries MultiEdit edits in its transcript; do not "clean up" this regex.
      and (($c.name? // "") | tostring | test("^(Edit|Write|MultiEdit|NotebookEdit)$"))
      and (path_of($c) as $p | (reviewable($p) and (excluded($p) | not)));
    # A review action. Writer agents whose description says "implement ... review
    # fixes" are NOT reviews; Explore agents are never reviews; loading a skill
    # that merely INSTRUCTS a review is not a review (the Agent dispatch is).
    def review($c):
      ($c.type? == "tool_use") and (
        ((($c.name? == "Task") or ($c.name? == "Agent"))
          and (($c.input.subagent_type? // "") | test("^Explore$") | not)
          and ((($c.input.subagent_type? // "") | test("review"; "i"))
               or ((($c.input.description? // "") | test("review|cold pass|fresh.?eyes"; "i"))
                   and ((($c.input.subagent_type? // "") == "Plan")
                        or (($c.input.description? // "") | test("^(implement|apply|address|fix)\\b|review[- ]fix"; "i") | not)))))
        or (($c.name? == "Skill")
            and (($c.input.skill? // $c.input.command? // "") | test("^(code-review|security-review|code-review:code-review)(\\s|$)"; "i")))
        or (($c.name? == "SlashCommand")
            and (($c.input.command? // "") | test("^/?(code-review|security-review)(\\s|$)"; "i")))
      );
    # positional override: the escape hatch named in the block message, for THIS
    # session only (accidental substring matches in unrelated commands do not count)
    def override($c):
      ($c.type? == "tool_use") and ($c.name? == "Bash")
      and ((($c.input.command? // "") | tostring) | contains("claude-review-ok-" + $s));
    # Explicit event counter, NOT input_line_number (that counts newlines consumed,
    # so a final line without a trailing newline numbered as 0). Malformed lines
    # are skipped via fromjson?, never fatal.
    reduce (inputs | fromjson? | objects) as $m ({e:0,r:0,n:0,k:"none"};
      .n += 1 | .n as $ln
      | (($m.message.content?) // []) as $content
      | if (($content|type) == "array") and ($content | any(artifact_edit(.))) then .e = $ln
        elif (($content|type) == "array") and ($content | any(review(.)))        then .r = $ln | .k = "review"
        elif (($content|type) == "array") and ($content | any(override(.)))      then .r = $ln | .k = "override"
        else . end)
    | "\(.e) \(.r) \(.k)"
  ' "$transcript" 2>/dev/null
)

# jq failed or produced no parseable result -> fail open.
[ -n "${last_edit:-}" ] && [ -n "${last_review:-}" ] && [ -n "${last_kind:-}" ] || exit 0
case "${last_edit}${last_review}" in *[!0-9]*) exit 0 ;; esac

# Nothing reviewable edited this session -> nothing to enforce.
[ "$last_edit" -eq 0 ] && exit 0
# A review action landed AFTER the last edit -> allow, and reset the block cap.
# If that action was the positional OVERRIDE (not a reviewer), say so visibly:
# Stop hooks may return systemMessage, which the harness shows to the user.
if [ "$last_review" -gt "$last_edit" ]; then
  rm -f "$counter" 2>/dev/null || true
  if [ "${last_kind:-}" = "override" ]; then
    jq -nc '{systemMessage:"review gate OVERRIDDEN by the agent (claude-review-ok): no reviewer ran after the last edit"}'
  fi
  exit 0
fi
# Cap reached without an intervening review -> fail open rather than wedge, but SAY SO
# (2026-11-03): a silent cap looked exactly like a passed review in the transcript.
if [ "$blocks" -ge 8 ]; then
  jq -nc --arg n "$blocks" '{systemMessage:("review gate CAP reached: " + $n + " blocks in this session without a review — the gate is now OPEN (fail-open cap); a separate review is still owed for the last edit")}'
  exit 0
fi

reason="FLEET MANDATE (Dave, 2026-10-18): code or a design/plan/runbook/ops artifact was written or modified this session, but no SEPARATE cold review has run after the last change. Everything gets reviewed automatically, without being asked. Before finishing: for CODE run /code-review (or dispatch a code-reviewer agent); for a spec, plan, runbook, unit, template, rule, hook, skill or CLAUDE.md change use the review-design skill (dispatch an Opus reviewer Agent with its brief; the DISPATCH is what this gate counts). Address the findings, re-review until a pass reports nothing material, then finish. Re-review after any fix that changes the artifact. Only if you GENUINELY already ran a separate review this session and this check missed it, or the edit is trivially not reviewable (a typo, a scratch file), override at this point with the Bash command (it is logged visibly):  echo claude-review-ok-${session}"

echo $((blocks + 1)) > "$counter" 2>/dev/null || true
jq -nc --arg r "$reason" '{decision:"block",reason:$r}'
exit 0
