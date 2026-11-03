---
name: writing-fleet-hooks
description: Use when creating, editing, registering, or sharing a Claude Code or Codex lifecycle hook (PreToolUse, PermissionRequest, PostToolUse, Notification, Stop, SessionStart, SessionEnd, UserPromptSubmit) across some or all of the ericbond.net fleet via chezmoi. Covers the shared Bash-guard path and the compatibility boundaries that prevent blindly reusing transcript- or edit-shape-dependent hooks.
---

# Writing Fleet Hooks

Claude Code and Codex hooks on this fleet are managed through chezmoi. Scripts live in the shared Claude source so every machine has them on disk. Claude's `modify_private_settings.json.tmpl` registers hooks conditionally by hostname; Codex uses `dot_codex/hooks.json`. Follow this when adding or changing a hook.

**Bash-guard special case:** the fleet's per-Bash-call guards (blast-radius / AUR review / npm review) are consolidated in the single `bash-guards.sh` dispatcher (2026-07-01). A new guard that matches on Bash commands should be added as another matcher section inside that dispatcher, NOT as a new registration — every separate per-Bash registration costs an extra process spawn + jq parse on every shell command.

## Where things live

| Path | Role |
|---|---|
| `~/.claude/hooks/<name>.sh` | Working copy on each host (what Claude Code runs) |
| `~/.local/share/chezmoi/dot_claude/hooks/executable_<name>.sh` | Chezmoi source (tracked in git) |
| `~/.local/share/chezmoi/dot_claude/modify_private_settings.json.tmpl` | Hostname-templated hook registry (modify_ script; owns `hooks` + `permissions.allow`, pins `permissions.defaultMode` off-flattop only; other `permissions.*` keys stay runtime) |
| `~/.claude/settings.local.json` | Per-host permissions overrides (not chezmoi-tracked) |
| `~/.codex/hooks.json` | Codex hook registry working copy |
| `~/.local/share/chezmoi/dot_codex/hooks.json` | Codex hook registry source; shared scripts must not assume rendered Claude targets exist |

## Hook script contract

- **Input:** JSON on stdin. Relevant fields per event:
  - `PreToolUse`/`PostToolUse`: `tool_name`, `tool_input.file_path` (Edit/Write; `NotebookEdit` sends `notebook_path` and is NOT covered by the blockers), `tool_input.command` (Bash), `cwd`
  - `Notification`: `message`, `title`, `notification_type`
  - `SessionEnd`: `session_id`, `cwd`, `reason`
- **Exit codes:**
  - `0` — silent pass
  - `2` — blocks the tool (PreToolUse) / aborts (others print stderr but don't block)
  - other non-zero — stderr shown to Claude as warning
- **Output:** stderr goes to Claude's context; stdout is mostly ignored except PostToolUse where it's appended
- **Early exit:** check `tool_name` / `file_path` / `command` up top and exit 0 fast when not applicable
- **Never `set -e` without `set -u`** and always trap broken deps with `|| true` for side-effect calls that can legitimately fail

### Codex compatibility boundary

- Codex 0.145 sends the same `tool_name`, `tool_input.command`, `cwd`,
  `session_id`, and `transcript_path` fields for `PreToolUse(Bash)`. Exit 2
  blocks before execution. The shared `bash-guards.sh` is verified on both.
- Codex requires explicit hash-bound trust for non-managed hook definitions.
  Trusting a command that merely names a mutable script does not attest that
  script's later content. The shared Bash guard therefore embeds the source
  file's SHA-256 in the registered command and exits 2 on mismatch. After every
  registry, command, or pinned-script change, update the expected SHA-256, open
  `/hooks`, review the exact command, and trust it; verify without
  `--dangerously-bypass-hook-trust`. `hooks/tests/codex-hash-pin.test.sh` fails whenever the
  source hash and the pin drift (even a comment edit does it, 2026-11-03) — run it before
  committing any `bash-guards.sh` change.
- Do **not** assume other hooks are portable. Codex file writes normally arrive
  as `apply_patch`, not Claude's `Edit`/`Write` `file_path` shape, and transcript
  JSONL is not a stable cross-product format. `chezmoi-preflight.sh`,
  `chezmoi-readd.sh`, and `code-review-before-done.sh` therefore remain
  Claude-only until they gain and pass explicit Codex adapters/tests.

## Authoring checklist

1. **Write script** at `~/.claude/hooks/<name>.sh`, `chmod +x`
2. **Validate locally:** pipe a fake payload through it:
   ```bash
   echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}' | ~/.claude/hooks/<name>.sh
   ```
3. **Register in `modify_private_settings.json.tmpl`.** Shared = top-level entry. Machine-specific = wrap in `{{ if eq .chezmoi.hostname "host" }} ... {{ end }}`. (Bash-command guards: extend `bash-guards.sh` instead — see above.)
4. **Render-check both branches.** The file is a modify_ SHELL script (not raw JSON), so render what apply would produce:
   ```bash
   chezmoi cat ~/.claude/settings.json | jq .   # this host's branch
   # simulate another host's branch (e.g. wanda) — override the hostname so EVERY
   # hostname conditional (eq AND ne, e.g. the off-flattop defaultMode pin) renders as it would there:
   chezmoi execute-template --override-data '{"chezmoi":{"hostname":"wanda"}}' \
     < ~/.local/share/chezmoi/dot_claude/modify_private_settings.json.tmpl > /tmp/render-modify.sh
   echo '{}' | sh /tmp/render-modify.sh | jq .                 # fresh host
   ssh wanda 'cat ~/.claude/settings.json' | sh /tmp/render-modify.sh | jq .   # that host's live file
   ```
   Both must emit valid JSON, and the live-file render must be semantically identical to the live file unless you meant to change it (`diff <(jq -S . live) <(… | jq -S .)`).
5. **Chezmoi-add the script:**
   ```bash
   chezmoi add ~/.claude/hooks/<name>.sh
   ```
   Source will get `executable_` prefix automatically.
6. **Apply so the local working copy matches the template render:**
   ```bash
   chezmoi apply ~/.claude/settings.json
   ```
7. **Commit + push** in `~/.local/share/chezmoi`, then run `~/.claude/hooks/chezmoi-sync.sh` (or `/chezmoi-sync`) to push and `chezmoi update` every peer. It is NOT auto-invoked by any hook — sync is a deliberate step.

If the hook is also Codex-compatible:

8. Register it in `dot_codex/hooks.json`, apply `~/.codex/hooks.json`, then open
   Codex `/hooks`, review, and trust the new definition. A Codex-compatible
   shared script must also work on Codex-only hosts: invoke the canonical
   `dot_claude/hooks/executable_<name>.sh` source through Bash, or create a
   Codex-managed executable target. Do not point at `~/.claude/hooks/<name>.sh`
   unless Claude targets are guaranteed present on every intended host. For a
   writable script source, pin its SHA-256 inside the registered command and
   exit 2 before execution when the actual hash differs; update that pin with
   every script-content change.
9. Run an isolated trigger through a normal Codex session (no hook-trust
   bypass) and prove the expected pass/block behavior.

## Shared vs machine-specific — decision

```dot
digraph {
    "Hook touches host-specific paths?" [shape=diamond];
    "Makes sense on every host?" [shape=diamond];
    "Shared: unconditional entry" [shape=box];
    "Machine-specific: wrap in {{ if eq .chezmoi.hostname \"X\" }}" [shape=box];

    "Hook touches host-specific paths?" -> "Makes sense on every host?" [label="no"];
    "Hook touches host-specific paths?" -> "Machine-specific: wrap in {{ if eq .chezmoi.hostname \"X\" }}" [label="yes"];
    "Makes sense on every host?" -> "Shared: unconditional entry" [label="yes"];
    "Makes sense on every host?" -> "Machine-specific: wrap in {{ if eq .chezmoi.hostname \"X\" }}" [label="no"];
}
```

Machine-specific scripts still live in the shared `dot_claude/hooks/` — they're dead weight on other hosts, never invoked unless registered. That's fine and simpler than per-host script paths.

## Template pattern

A hook entry is a JSON object inside its event's array. For shared entries, just add the object. For host-specific, use a trailing conditional so commas stay valid:

```jsonc
"PreToolUse": [
  { "matcher": "Edit|Write",
    "hooks": [{ "type": "command", "command": "~/.claude/hooks/shared.sh" }]
  }{{ if eq .chezmoi.hostname "wanda" }},
  { "matcher": "Bash",
    "hooks": [{ "type": "command", "command": "~/.claude/hooks/wanda-only.sh" }]
  }{{ end }}
]
```

The `{{ if ... }},` pattern puts the comma *inside* the conditional so the shared entry is always valid JSON on its own, and the wanda branch contributes a leading comma + its entries.

## Common matchers

| Intent | Matcher |
|---|---|
| Any file edit | `Edit\|Write` (MultiEdit no longer exists; NotebookEdit is a separate tool) |
| Shell commands only | `Bash` |
| Everything | `*` (or omit — empty matcher matches all) |
| Specific tool | exact name, e.g. `Read`, `Grep` |

## Things to avoid

- **Don't `exec 2>>file`** in hooks — Claude can't see warnings then. Use normal stderr.
- **Don't call `git` from hooks without `-C <path>`** — `cwd` is Claude's, not the chezmoi source.
- **Stop hooks CAN block** in current Claude Code — emit **top-level** `{"decision":"block","reason":"..."}` on stdout + exit 0 (exit 2 + stderr also blocks). On Stop, `hookSpecificOutput` carries ONLY `additionalContext`; the PreToolUse-style `{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block"}}` is silently IGNORED — `code-review-before-done.sh` emitted exactly that from 2026-06-27 to 2026-10-18 and never blocked once (zero `Stop hook feedback:` injections in any transcript on flattop). Verify a new Stop hook end to end with a throwaway headless session (`claude -p … --max-turns 3`): a real block shows up in its transcript as a user message `Stop hook feedback: <reason>` and as the reason under `stop_hook_summary.hookErrors`; `preventedContinuation` stays `false` even when the block works, so never use it as the signal. See `code-review-before-done.sh` for the working pattern, including a block-count cap so a session can't wedge, and `hooks/tests/` for its battery. SessionEnd cannot block; the session ends regardless.
- **Don't register a hook for `Bash` that runs long commands** — every shell call pays the cost. New Bash guards belong inside `bash-guards.sh`, not as new registrations.
- **Don't put secrets in modify_private_settings.json.tmpl** — it's in git. Reference a file (`$(cat /etc/op-...)` pattern) instead.
- **Don't reuse Claude edit or Stop hooks in Codex just because the event names
  match.** Capture and compare the real payload first; transcript formats and
  tool argument shapes differ.

## Verify before relying

After push + `chezmoi update` on each host, confirm the registry looks right per host:

```bash
ssh <host> 'jq ".hooks | to_entries | map({event: .key, count: (.value | length)})" ~/.claude/settings.json'
```

Counts should match the shared+host-specific sum you expect.

For Codex, open `/hooks` and confirm the expected Installed and Active counts,
then run the hook's safe trigger without a trust bypass.
