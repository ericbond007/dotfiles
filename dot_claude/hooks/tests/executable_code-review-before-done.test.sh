#!/usr/bin/env bash
# Battery for code-review-before-done.sh (NOT a registered hook). Run after ANY edit:
#   ~/.claude/hooks/tests/code-review-before-done.test.sh [path-to-hook]
# Asserts the DOCUMENTED Stop contract on STDOUT ONLY: {"decision":"block","reason":"…"}.
# History: the hook emitted a PreToolUse-shaped block from 2026-06-27 to 2026-10-18 and
# never fired; a substring grep would have passed it. Hermetic: TMPDIR is a temp dir.
set -u
H="${1:-$HOME/.local/share/chezmoi/dot_claude/hooks/executable_code-review-before-done.sh}"
[ -r "$H" ] || H="$HOME/.claude/hooks/code-review-before-done.sh"
T="$(mktemp -d)"; export TMPDIR="$T"; trap 'rm -rf "$T"' EXIT
tu(){ printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":%s}]}}\n' "$1" "$2"; }
edit(){ tu Edit "{\"file_path\":\"$1\"}"; }
agent(){ tu Agent "{\"subagent_type\":\"${2:-general-purpose}\",\"description\":\"$1\"}"; }
skill(){ tu Skill "{\"skill\":\"$1\"}"; }
slash(){ tu SlashCommand "{\"command\":\"$1\"}"; }
bashc(){ tu Bash "{\"command\":\"$1\"}"; }
run(){ printf '{"transcript_path":"%s","session_id":"crbd-%s"}' "$1" "$RANDOM$RANDOM$RANDOM" | bash "$H" 2>/dev/null; }
verdict(){ out="$1"
  if [ -z "$out" ]; then echo allow
  elif printf '%s' "$out" | jq -e '.decision=="block" and (.reason|type=="string") and (.hookSpecificOutput|not)' >/dev/null 2>&1; then echo BLOCK
  elif printf '%s' "$out" | jq -e '(.decision|not) and (.systemMessage|type=="string")' >/dev/null 2>&1; then echo allow
  else echo "BADSHAPE"; fi; }
pass=0; fail=0
report(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); s=ok; else fail=$((fail+1)); s=FAIL; fi; printf '%-4s %-62s got %-8s expect %s\n' "$s" "$1" "$2" "$3"; }
chk(){ f="$T/$RANDOM$RANDOM.jsonl"; printf '%s\n' "$2" > "$f"; report "$1" "$(verdict "$(run "$f")")" "$3"; }
chk_nonl(){ f="$T/$RANDOM$RANDOM.jsonl"; printf '%s' "$2" > "$f"; report "$1" "$(verdict "$(run "$f")")" "$3"; }
bash -n "$H" || { echo "FAIL: bash syntax error in $H"; exit 1; }
q="'"; if grep -q "$q" <(sed -n "/jq -nRr '/,/' \"\$transcript\"/p" "$H" | sed '1d;$d'); then echo "FAIL: stray single quote inside the jq program"; exit 1; fi
# --- blocks
chk "spec edited, no review"                      "$(edit /x/docs/superpowers/specs/2026-foo-design.md)"            BLOCK
chk "plan edited, no review"                      "$(edit /x/docs/superpowers/plans/2026-foo.md)"                   BLOCK
chk "Write to a .ts, no review"                   "$(tu Write '{"file_path":"/x/src/a.ts","content":"x"}')"         BLOCK
chk "MultiEdit to a .py, no review"               "$(tu MultiEdit '{"file_path":"/x/a.py"}')"                       BLOCK
chk "NotebookEdit, no review"                     "$(tu NotebookEdit '{"notebook_path":"/x/a.ipynb"}')"             BLOCK
chk "systemd .service, no review"                 "$(edit /x/deploy/jail-blotter/jail-blotter.service)"             BLOCK
chk ".rules file, no review"                      "$(edit /x/deploy/monitoring/jail.rules)"                         BLOCK
chk ".tpl stripped: jail.conf.tpl is a .conf"        "$(edit /x/deploy/jail.conf.tpl)"                                 BLOCK
chk "settings.json.tmpl under dot_claude"         "$(edit /h/.local/share/chezmoi/dot_claude/modify_private_settings.json.tmpl)" BLOCK
chk "package.json, no review"                     "$(edit /x/package.json)"                                         BLOCK
chk "CLAUDE.md, no review"                        "$(edit /h/.claude/CLAUDE.md)"                                    BLOCK
chk "skill reference .md, no review"              "$(edit /h/.local/share/chezmoi/dot_claude/skills/x/references/brief.md)" BLOCK
chk "README.md, no review"                        "$(edit /x/README.md)"                                            BLOCK
chk "review BEFORE a tpl edit (stale review)"     "$(agent 'Cold review of spec')
$(edit /x/deploy/jail.env.tpl)"                                                                                     BLOCK
chk "edit, then user prose mentions review"       "$(edit /x/src/a.ts)
{\"type\":\"user\",\"message\":{\"content\":\"please review this\"}}"                                               BLOCK
chk "edit, then tool_result echo of /code-review" "$(edit /x/src/a.ts)
{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"run /code-review\"}]}}"        BLOCK
chk "edit, then Explore agent 'review options'"   "$(edit /x/src/a.ts)
$(agent 'Explore and review options' Explore)"                                                                      BLOCK
chk "edit, then writer agent 'review fixes'"      "$(edit /x/src/a.ts)
$(agent 'PR 3a holistic-review fixes')"                                                                             BLOCK
chk "edit, then 'Implement task then request review'" "$(edit /x/src/a.ts)
$(agent 'Implement Task 3 then request review')"                                                                    BLOCK
chk "edit, then Skill review-design ALONE"        "$(edit /x/docs/specs/a.md)
$(skill review-design)"                                                                                             BLOCK
chk "edit, then Skill requesting-code-review alone" "$(edit /x/src/a.ts)
$(skill superpowers:requesting-code-review)"                                                                        BLOCK
chk_nonl "spec edited, NO trailing newline"       "$(edit /x/docs/superpowers/specs/foo-design.md)"                 BLOCK
chk "edit, then a malformed line, no review"      "$(edit /x/src/a.ts)
{not json"                                                                                                          BLOCK
# --- allows
chk "spec edited, then Agent 'Cold review of spec'" "$(edit /x/docs/superpowers/specs/foo-design.md)
$(agent 'Cold review of API migration spec')"                                                                       allow
chk "unit edited, then Agent 'cold pass'"         "$(edit /x/deploy/jail-blotter/jail-blotter.service)
$(agent 'Fourth cold pass on spec rev 4')"                                                                          allow
chk "code edited, then Skill code-review"         "$(edit /x/src/a.ts)
$(skill code-review)"                                                                                               allow
chk "code edited, then SlashCommand /code-review" "$(edit /x/src/a.ts)
$(slash '/code-review high')"                                                                                       allow
chk "code edited, then code-reviewer subagent_type" "$(edit /x/src/a.ts)
$(agent 'Look at the diff' feature-dev:code-reviewer)"                                                              allow
chk "edit, then override for ANOTHER session"      "$(edit /x/src/a.ts)
$(bashc 'echo claude-review-ok-some-other-session')"                                                               BLOCK
chk "edit, then wrong-type JSON lines, no review"  "$(edit /x/src/a.ts)
42
[1,2]
{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"input\":{\"file_path\":7}}]}}"                      BLOCK
chk "edit, then Plan agent 'fix fresh-eyes review'"  "$(edit /x/src/a.ts)
$(agent 'fix fresh-eyes review of the draft' Plan)"                                                                 allow
chk "edit, then Skill engineering:code-review"     "$(edit /x/src/a.ts)
$(skill engineering:code-review)"                                                                                  BLOCK
chk ".qml edited, no review"                       "$(edit /x/ui/Main.qml)"                                                   BLOCK
chk "override, THEN another edit (not session-wide)" "$(bashc 'echo claude-review-ok-x')
$(edit /x/src/a.ts)"                                                                                                BLOCK
chk "random notes.md edited"                      "$(edit /h/notes/shopping.md)"                                    allow
chk "explanation.md (keyword inside a word)"      "$(edit /x/explanation.md)"                                       allow
chk "inspection-notes.md"                         "$(edit /x/inspection-notes.md)"                                  allow
chk "Cargo.toml edited (toml, code-ish, gated)"   "$(edit /x/Cargo.toml)"                                           BLOCK
chk "scratchpad report, excluded"                 "$(edit /tmp/claude-1000/x/scratchpad/plan7-rev2-report.md)"       allow
chk "/tmp spec, excluded"                         "$(edit /tmp/foo-design.md)"                                      allow
chk "Claude plan-mode file, excluded"             "$(edit /h/.claude/plans/2026-foo.md)"                            allow
chk "memory file, excluded"                       "$(edit /h/.claude/projects/-h-x/memory/feedback_design_review_lessons.md)" allow
chk "user prose mentions review, no edits"        '{"type":"user","message":{"content":"please review this spec"}}' allow
chk_nonl "spec+review, NO trailing newline"       "$(edit /x/docs/superpowers/specs/foo-design.md)
$(agent 'Cold review of spec')"                                                                                     allow
# --- override for THIS session, visible
f="$T/ovr.jsonl"; { edit /x/src/a.ts; bashc 'echo claude-review-ok-crbd-ovr'; } > "$f"
out=$(printf '{"transcript_path":"%s","session_id":"crbd-ovr"}' "$f" | bash "$H" 2>/dev/null)
report "override for this session -> allow" "$(verdict "$out")" allow
report "override prints a visible systemMessage" "$(printf '%s' "$out" | jq -r '.systemMessage // "none"' | cut -c1-14)" "review gate OV"
# --- cap and reset
f="$T/cap.jsonl"; edit /x/src/a.ts > "$f"; export TMPDIR="$T"; echo 8 > "$T/claude-review-blocks-crbd-cap"
r=$(printf '{"transcript_path":"%s","session_id":"crbd-cap"}' "$f" | bash "$H" 2>/dev/null); report "counter at 8, no review -> fail open" "$(verdict "$r")" allow
f3="$T/cap2.jsonl"; { edit /x/src/a.ts; agent 'Cold review of code'; } > "$f3"; echo 8 > "$T/claude-review-blocks-crbd-cap2"
r=$(printf '{"transcript_path":"%s","session_id":"crbd-cap2"}' "$f3" | bash "$H" 2>/dev/null); report "counter at 8, review after edit -> counter removed" "$( [ -f "$T/claude-review-blocks-crbd-cap2" ] && echo kept || echo reset )" reset
f4="$T/cap3.jsonl"; { edit /x/src/a.ts; agent 'Cold review of code'; edit /x/src/b.ts; } > "$f4"; echo 8 > "$T/claude-review-blocks-crbd-cap3"
r=$(printf '{"transcript_path":"%s","session_id":"crbd-cap3"}' "$f4" | bash "$H" 2>/dev/null); report "counter at 8, edit after the review -> still capped (allow)" "$(verdict "$r")" allow
f2="$T/reset.jsonl"; { edit /x/src/a.ts; agent 'Cold review of code'; } > "$f2"; echo 5 > "$T/claude-review-blocks-crbd-reset"
r=$(printf '{"transcript_path":"%s","session_id":"crbd-reset"}' "$f2" | bash "$H" 2>/dev/null); report "review after edit resets the counter" "$( [ -f "$T/claude-review-blocks-crbd-reset" ] && echo kept || echo reset )" reset
r=$(printf '{"transcript_path":"/nonexistent/x.jsonl","session_id":"crbd-x"}' | bash "$H" 2>/dev/null); report "fail-open on missing transcript" "$(verdict "$r")" allow
echo "=== $pass passed, $fail failed"; [ "$fail" -eq 0 ]
