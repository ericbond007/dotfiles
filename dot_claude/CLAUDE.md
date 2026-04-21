# Fleet-wide Claude Code instructions

Applies on every machine in the ericbond fleet (flattop, wanda, serp). Machine-specific behaviors stay in per-host memory at `~/.claude/projects/-home-eric/memory/`.

## User

- Colors: Cream `#eeedeb`, Crimson `#990000`. Use in any color context (UI, palettes, generated assets).
- Shell: fish. Editor: nvim (via `$VISUAL`/`$EDITOR`). Terminal: kitty + tmux on flattop; server hosts vary.

## Fleet topology

- **flattop** — primary workstation; CachyOS/Wayland/KDE; kitty + tmux. This is typically where I'm running.
- **wanda** (10.0.0.x) — Arch server. Hosts Home Assistant, docker services, firewall (nftables), own UPS. Has machine-specific Claude hooks (firewall/service-owned-files/wiki/secrets) registered via the hostname-conditional block in `dot_claude/settings.json.tmpl`.
- **serp / serpentii** (10.0.0.9) — Arch server. GTX 980 Ti, UPS CyberPower CP1500 on USB, NUT netserver on 10.0.0.9:3493. Kernel pinned to 6.18.2 (nvidia-580xx AUR incompatible with ≥6.19) — do NOT upgrade `linux`/`linux-headers` without confirming the AUR patch. Bootloader: syslinux on BIOS/GPT, root=sda2 ext4. DM=SDDM. `/usr/bin/fish` must remain in `/etc/shells`.

Network: `10.0.0.0/24` domain `ericbond.net`. Live host scanner at `https://scan.ericbond.net`.

### Conventions on wanda/serp

- **`/opt/services`** — most custom running services live here. Check there first when investigating services. The wiki also lives under `/opt/services/wiki`.
- **etckeeper** — `/etc` (and tracked service files) is git-backed via etckeeper. Treat etckeeper-tracked state as the per-host system-configuration reference. After editing `/etc` or service files on wanda/serp, commit via etckeeper, then update the relevant `/opt/services/wiki/docs/` page.

## Behavior rules

### Run commands yourself

Execute shell commands via the Bash tool rather than asking the user to run them. They can copy your transcript to reproduce; they shouldn't have to interrupt their flow to dispatch your work.

### Least privilege on wanda/serp

Use sudo only when required. Prefer 1Password CLI (`op read ...`) over hardcoded secrets anywhere. Before dangerous edits (`/etc/*`, systemd units, nftables, pam), back up the file and diff the change with the user before applying.

### Chezmoi workflow (flattop primarily)

When editing any `$HOME` config file that chezmoi manages, or editing the chezmoi source tree at `~/.local/share/chezmoi`, drive the full flow to completion — don't hand off mid-sync:

1. The `PreToolUse` hook (`chezmoi-preflight.sh`) warns if source is behind origin. Heed it.
2. Make the edit. If target was edited, `PostToolUse` (`chezmoi-readd.sh`) mirrors it into the source tree automatically.
3. If the edit was to a `.tmpl` source, also `chezmoi apply <target>` locally to refresh the rendered file.
4. Show `git status` + diff in chezmoi source. Compose a real commit message (why, not just file list). Stage + commit.
5. Run `~/.claude/hooks/chezmoi-sync.sh` — this refuses on a dirty tree, pushes to origin, then ssh's peers (`serp`, `wanda`, `flattop` minus self) to run `chezmoi update`.
6. Resolve any peer errors explicitly:
   - **Local drift on peer** (e.g. `lazy-lock.json` regenerated) — decide: chezmoiignore it (churn), force-overwrite from source (source is truth), or `chezmoi re-add` on the peer and push as the new canonical. Explain the choice.
   - **Non-fast-forward push** — fetch, show divergent commits, rebase or merge deliberately.
   - **SSH timeout / offline host** — note it, continue with others, flag for follow-up.
7. Summarize what synced where.

The `/chezmoi-sync` slash command is a manual fallback — I shouldn't normally make the user run it.

### Writing Claude Code hooks for this fleet

Follow the `writing-fleet-hooks` skill: scripts at `~/.claude/hooks/`, chezmoi-track as `dot_claude/hooks/executable_<name>.sh`, register in `dot_claude/settings.json.tmpl` with `{{ if eq .chezmoi.hostname "host" }}` blocks for host-specific hooks.

## Memory vs this file

- This `CLAUDE.md` = stable cross-machine behaviors + fleet context.
- `~/.claude/projects/-home-eric/memory/` = host-specific or recent learnings (not chezmoi-tracked). When I learn something universal, put it here; when it's specific to one host (e.g. wanda's HA paths), keep it in that host's memory dir.
