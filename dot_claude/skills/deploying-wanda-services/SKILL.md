---
name: deploying-wanda-services
description: Use when committing to /opt/services, deploying or re-deploying a service on wanda/serp, running op-deploy-secrets, editing a *.tpl secret template, or when a service broke right after a secret/credstore change. Covers the two fleet landmines — /opt/services git discipline (never `git add -A`) and credstore `.tpl` drift — that silently break services if mishandled.
---

# Deploying services on wanda/serp

Two deploy-time rituals on the wanda/serp servers carry landmines that have caused real outages. Both fire when you're about to commit or re-deploy a custom service. Read the relevant half before acting.

## 1. /opt/services git discipline (NOT etckeeper)

`/opt/services` is a root-owned git mono-repo holding **loose service configs only**: each service's `docker-compose.yml`, non-secret config, and `.tpl` templates. Rendered-secret files and data dirs are **gitignored**.

Rules:

- Commit with `sudo git -C /opt/services` (root-owned).
- After editing a service, commit **that service** deliberately with a real message. **NEVER `git add -A`** — that caused the 2026-05-25 "kitchen-sink" incident. The `services-config-commit` auto-commit timer is **disabled on purpose — leave it disabled**.
- New top-level service dirs MUST get their data/secret files gitignored **before** committing (the pre-commit hook warns).
- A repo-local `core.hooksPath=.githooks` (lives in `.git/config`; re-set it after any re-clone) enforces:
  - **pre-commit** secret scan on every commit — use `op://` refs, never plaintext. Same file on wanda and on serp's `/opt/services` (since 2026-11-04, byte-identical; edit both or neither). Known false positive: Python that merely reads a token from env/args — Dave's `--no-verify` after a look.
  - **post-commit** push to the serp mirror that emails on failure (#1420) — wanda only; serp mirrors to wanda's backup remote via `serp-git-backup.timer` (daily 03:30) instead.
- The four nested app repos — `btown`, `jail/_src`, `ot-revisited`, `wiki` — were **excised** into their own backed-up repos (btown/wiki → `serp:/opt/git-backups/{btown,wiki}.git`; jailBird/ot-revisited → GitHub). They're gitignored — **don't re-add them**.
- A daily `opt-services-drift-alert.timer` emails Dave if drift sits uncommitted >3 days (#1421).
- Restore runbook: `/opt/services/wiki/docs/runbooks/opt-services-restore.md`.

`/etc` and tracked service files on wanda/serp are git-backed separately via **etckeeper** — that's the per-host system-config reference. After editing `/etc` or service files, commit via etckeeper, then update the relevant `/opt/services/wiki/docs/` page.

## 2. Credstore secrets (`op-deploy-secrets`) — drift-prone LANDMINE

The secret pipeline on wanda:

```
<svc>-creds/*.tpl  (or /etc/**/*.tpl)
  → sudo op-deploy-secrets        # op inject + systemd-creds encrypt
  → /etc/credstore.encrypted/<svc>
  → installed at boot to /run/<svc>-conf/   (the app's real config symlinks here)
```

**The landmine:** a `.tpl` can silently drift from the live value — e.g. an API key regenerated in-app and never written back to the template.

- A plain `systemctl restart` is **safe** — it re-installs from the credstore, which holds the live value.
- **BUT `sudo op-deploy-secrets` (full run) re-encrypts EVERY credstore from its `.tpl`** — so a stale `.tpl` silently overwrites the live secret and breaks the service.

On 2026-06-11 this bit Prowlarr: a credstore re-encrypt for an auth fix pushed a stale API key → 401'd exportarr and every Prowlarr-synced indexer in Lidarr/Radarr/Sonarr. All four *arr `.tpl`s were drifted.

### Rules (do these every time)

1. **Before re-deploying a credstore or running the full `op-deploy-secrets`, diff each `.tpl`'s secret against the live/deployed value** — e.g. `docker inspect exportarr-<app>` env, or read `/run/<svc>-conf/`.
2. **ALWAYS `op-deploy-secrets --dry-run` first** and treat any unexpected `CHANGED` as a landmine, not a routine update.
3. **Prefer a targeted single-service re-encrypt** over the full run.

Never `cat` a rendered secret file in chat — read the `.tpl` template only; verify the rendered side via `ls -la` / `sha256sum`. Never put secrets in plaintext anywhere — `op://` refs only.

Mechanism + remediation tracked in Vikunja services #1391. The `op-deploy-secrets` fleet pattern (daily-timer-driven 1Password rendering on wanda/serp/living-pi; boot path fully local) is in per-host memory `reference_op_deploy_secrets_fleet`.
