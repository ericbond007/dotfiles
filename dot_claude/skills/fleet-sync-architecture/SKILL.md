---
name: fleet-sync-architecture
description: Use when debugging or reasoning about how the flattop/wanda/serp fleet shares config via chezmoi (what's tracked where, the sync hooks, why an edit did/didn't propagate), or when onboarding a brand-new host into the fleet. Reference for the chezmoi+GitHub topology — NOT needed for routine edits (the chezmoi-readd hook and `chezmoi-sync` skill handle those).
---

# Fleet sync architecture

The flattop/wanda/serp fleet shares configuration via **chezmoi** with **GitHub as the hub**. This is what makes "edit on one machine, see it everywhere" work. For the day-to-day edit→commit→push→peer-apply flow, use the `chezmoi-sync` skill/command; for adding or changing a hook, use `writing-fleet-hooks`. This skill is the underlying topology reference.

## What lives where

| Location | Role |
|---|---|
| `~/.local/share/chezmoi/` | chezmoi source tree (git repo) — the canonical state |
| `github.com:ericbond007/dotfiles` | shared hub; all three hosts push/pull from `origin/master` |
| `~/.claude/hooks/*.sh` | rendered working copies (what Claude Code invokes) |
| `~/.claude/settings.json` | rendered from `dot_claude/settings.json.tmpl` with hostname conditionals |
| `~/.claude/skills/`, `~/.claude/commands/`, `~/.claude/CLAUDE.md` | all chezmoi-tracked — same on every host |
| `~/.claude/settings.local.json` | per-host permission overrides — **not** chezmoi-tracked |
| `~/.claude/projects/.../memory/` | per-host memories — **not** chezmoi-tracked |

## Hooks that make it work

- `chezmoi-preflight.sh` — **PreToolUse** on `Edit|Write|MultiEdit`. Warns on stderr if the chezmoi source is behind origin (cached 5-min fetch) or if you're editing a rendered target whose `.tmpl` you should edit instead.
- `chezmoi-readd.sh` — **PostToolUse** on `Edit|Write|MultiEdit`. When the edited path is a chezmoi-managed target and not templated, runs `chezmoi re-add` so the source tree mirrors `$HOME`.
- `chezmoi-sync.sh` — **not registered as a hook**. Manually invoked (typically by Claude driving the workflow, sometimes via `/chezmoi-sync`). Refuses on a dirty tree, pushes `origin/master`, then ssh's each peer (self-excluded via `hostname -s`) to run `chezmoi update`.
- `notify-tmux.sh` — **Notification**. Only fires inside tmux (guarded by `$TMUX`). Calls `notify-send` with tmux window context so Claude notifications reach KDE even when tmux swallows the OSC 9 sequence.

Wanda additionally registers `block-generated-files`, `block-service-owned-files`, `firewall-validate`, `pre-commit-secrets-scan` (PreToolUse) and `firewall-post-edit`, `wiki-update-reminder` (PostToolUse) via the `{{ if eq .chezmoi.hostname "wanda" }}` block in `dot_claude/settings.json.tmpl`. Those scripts ship in the shared source tree but never register elsewhere.

For the `settings.json.tmpl` hostname-conditional pattern and the per-host verify command, see the `writing-fleet-hooks` skill — it owns that material.

## Onboarding a new host

1. Install: chezmoi, git, jq, notify-send (if graphical), openssh. Install Claude Code if the host will run it.
2. `ssh-keyscan github.com >> ~/.ssh/known_hosts` (verify fingerprint matches GitHub's published Ed25519 key `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`).
3. `chezmoi init --apply git@github.com:ericbond007/dotfiles.git`.
4. Exchange SSH keys so the new host can ssh to the existing peers and they to it.
5. Add the new short hostname to the `peers=(...)` array in `dot_claude/hooks/executable_chezmoi-sync.sh`.
6. If the host needs its own hooks, drop them in `dot_claude/hooks/executable_<name>.sh` and wrap the `settings.json.tmpl` registration in `{{ if eq .chezmoi.hostname "<host>" }} ... {{ end }}` (see `writing-fleet-hooks`).
7. Commit, push, sync. Verify the new host's rendered `settings.json` matches expectations.
