---
name: fleet-sync-architecture
description: Use when debugging or reasoning about how the fleet (flattop/wanda/serp + balganor/living-pi as agent-less peers; bondo is dead) shares Claude Code and Codex configuration via chezmoi, including what is canonical, what is per-host, shared skills/hooks, why an edit did or did not propagate, or onboarding a new host. Reference for the chezmoi+GitHub topology; not needed for routine edits.
---

# Fleet sync architecture

The fleet (flattop/wanda/serp, plus balganor and living-pi as Claude-Code-less sync peers) shares configuration via **chezmoi** with **GitHub as the hub**. This is what makes "edit on one machine, see it everywhere" work. For the day-to-day edit→commit→push→peer-apply flow, use the `chezmoi-sync` skill/command; for adding or changing a hook, use `writing-fleet-hooks`. This skill is the underlying topology reference.

## What lives where

| Location | Role |
|---|---|
| `~/.local/share/chezmoi/` | chezmoi source tree (git repo) — the canonical state |
| `github.com:ericbond007/dotfiles` | shared hub; configured peers push/pull from `origin/master` |
| `~/.claude/hooks/*.sh` | rendered working copies (what Claude Code invokes) |
| `~/.claude/settings.json` | co-managed by `dot_claude/modify_private_settings.json.tmpl` (modify_ script: chezmoi owns `hooks`+`permissions`, Claude Code owns runtime keys; hostname conditionals) |
| `~/.claude/skills/`, `~/.claude/commands/`, `~/.claude/CLAUDE.md` | all chezmoi-tracked — same on every host |
| `~/.claude/settings.local.json` | per-host permission overrides — **not** chezmoi-tracked |
| `~/.claude/projects/.../memory/` | per-host memories — **not** chezmoi-tracked |
| `~/.codex/AGENTS.md` | compact global Codex routing/policy; points into the canonical Claude policy, skills, repos, and wiki |
| `~/.codex/config.toml` | co-managed by `dot_codex/modify_private_config.toml`; fleet defaults plus Codex-owned trust/TUI state |
| `~/.codex/hooks.json` | Codex lifecycle registry; invokes and content-hash-pins the canonical fleet Bash guard source, including on Codex-only hosts |
| `~/.agents/skills/<name>` | documented Codex user-skill location; symlinks directly to canonical `~/.local/share/chezmoi/dot_claude/skills/<name>` |
| `~/.codex/memories*` | generated per-host Codex recall state — **not** chezmoi-tracked and never required guidance |

## Hooks that make it work

- `chezmoi-preflight.sh` — **PreToolUse** on `Edit|Write|MultiEdit`. Warns on stderr if the chezmoi source is behind origin (cached 5-min fetch) or if you're editing a rendered target whose `.tmpl` you should edit instead.
- `chezmoi-readd.sh` — **PostToolUse** on `Edit|Write|MultiEdit`. When the edited path is a chezmoi-managed target and not templated, runs `chezmoi re-add` so the source tree mirrors `$HOME`. (Editing the SOURCE tree directly is the reverse path — readd correctly no-ops there, so you must `chezmoi apply <target>` yourself.)
- `bash-guards.sh` — **PreToolUse** on `Bash`, fleet-wide: the merged blast-radius / AUR-review / npm-review dispatcher (one process + one jq per Bash call; consolidated 2026-07-01).
- Codex registers that same dispatcher from `~/.codex/hooks.json`, invoking `dot_claude/hooks/executable_bash-guards.sh` through Bash rather than assuming the rendered `~/.claude/hooks/` tree exists. The command verifies the source file's SHA-256 and exits 2 on mismatch, so script-content changes fail closed and require a matching registry update. The Bash payload and exit-2 block contract were verified compatible on Codex 0.145 (2026-07-23). Each new/changed hook definition must be reviewed in Codex `/hooks`.
- `chezmoi-sync.sh` — **not registered as a hook**. Manually invoked (typically by Claude driving the workflow, sometimes via `/chezmoi-sync`). Refuses on a dirty tree, pushes `origin/master`, then ssh's each peer (self-excluded via `hostname -s`) to run `chezmoi update`.
- `notify-tmux.sh` — **Notification**. Only fires inside tmux (guarded by `$TMUX`). Calls `notify-send` with tmux window context so Claude notifications reach KDE even when tmux swallows the OSC 9 sequence.

Wanda additionally registers `block-generated-files`, `block-service-owned-files`, `firewall-validate`, `pre-commit-secrets-scan` (PreToolUse) and `firewall-post-edit`, `wiki-update-reminder` (PostToolUse) via the `{{ if eq .chezmoi.hostname "wanda" }}` block in `dot_claude/modify_private_settings.json.tmpl`. Those scripts ship in the shared source tree but never register elsewhere.

For the registration/hostname-conditional pattern and the per-host verify command, see the `writing-fleet-hooks` skill — it owns that material.

## Onboarding a new host

1. Install: chezmoi, git, jq, notify-send (if graphical), openssh. Install Claude Code if the host will run it.
2. `ssh-keyscan github.com >> ~/.ssh/known_hosts` (verify fingerprint matches GitHub's published Ed25519 key `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`).
3. `chezmoi init --apply git@github.com:ericbond007/dotfiles.git`.
4. Exchange SSH keys so the new host can ssh to the existing peers and they to it.
5. Add the new short hostname to the `peers=(...)` array in `dot_claude/hooks/executable_chezmoi-sync.sh`.
6. If the host needs its own hooks, drop them in `dot_claude/hooks/executable_<name>.sh` and wrap the `modify_private_settings.json.tmpl` registration in `{{ if eq .chezmoi.hostname "<host>" }} ... {{ end }}` (see `writing-fleet-hooks`).
7. Commit, push, sync. Verify the new host's rendered `settings.json` matches expectations.
8. If the host runs Codex, verify `~/.codex/{AGENTS.md,config.toml,hooks.json}`, the shared `~/.agents/skills` symlinks, `codex doctor --summary`, and trust the reviewed hook definition with `/hooks`.

All current managed hosts use the `eric` account with home
`/home/eric`; the Codex notify and guarded-hook commands rely on that invariant.
Template those paths before onboarding a host with a different account or home.
