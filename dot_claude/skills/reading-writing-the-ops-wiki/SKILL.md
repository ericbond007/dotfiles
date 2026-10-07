---
name: reading-writing-the-ops-wiki
description: >-
  Use when reading from or writing to the fleet ops wiki (the MkDocs wiki on
  wanda at /opt/services/wiki, served at wiki.ericbond.net). Trigger this
  BEFORE non-trivial work on any fleet subsystem (read the relevant page first)
  and AFTER changing one (update its page). Covers the read path, the
  page/nav map, the mkdocs build step, and the non-obvious commit discipline
  (the wiki is a nested repo owned by the `wiki` user, distinct from the
  root-owned /opt/services monorepo). Reach for this whenever Dave mentions
  "the wiki", "ops wiki", "wiki.ericbond.net", a runbook, an incident
  post-mortem, or asks you to look something up about / document a fleet
  service, host, or architecture decision.
---

# Reading & writing the ops wiki

The fleet's institutional memory is an **MkDocs wiki on wanda at `/opt/services/wiki`**, served at `wiki.ericbond.net` (traefik → `127.0.0.1:8090`). It holds architecture docs, per-service pages, per-host pages, runbooks, and incident post-mortems. Reading the relevant page before touching a subsystem saves you from re-deriving it by inspecting the live system; updating it after keeps the next debugger from doing the same.

**The wiki can drift — the live system is ground truth.** Verify claims against the running system; don't blind-trust a page (a stale "living-pi /etc not tracked" line bit this once). The canonical page list is `mkdocs.yml`'s `nav:` — re-read it when unsure, because pages get added.

## Reading

From any host, read a page's source:

```bash
ssh wanda 'sudo cat /opt/services/wiki/docs/<path>'
```

The canonical, always-current page list is the `nav:` block:

```bash
ssh wanda 'sudo sed -n "/^nav:/,/^[a-z]/p" /opt/services/wiki/mkdocs.yml'
```

### Page map (`/opt/services/wiki/docs/`)

Predictable layout — guess the path by topic before searching:

- **`architecture/`** — fleet-level "how does X work": overview · dns · tls · traefik · docker-networking · watchdogs · identity · backup-pipeline · ha-failover · vlans(planned).
- **`runbooks/`** — "how to perform operation Y": known-incidents · opt-services-restore · postgres-major-upgrade · docker-address-pool-migration · ha-control · fleet-debug · energy · openclaw-models-cost · signal-channel · music-library · media-{automation,indexers-prowlarr,import-troubleshooting} · slskd-soularr.
- **`hosts/`** — one page per host: wanda · serp · balganor · living-pi · flattop · bondo (dead, decommissioned 2026-10-07 — historical page).
- **`services/`** — one page per service at `services/<name>.md` (authelia, lldap, jail, ntfy, matrix, element, openclaw, homeassistant, media, books, pihole, homepage, netscan, email, music-search, navidrome, ups, meters, …). Start at `services/index.md` (the service map).
- **`howto/`** — add-service · secrets-management · config-version-control · external-access · troubleshooting.
- **`reference/`** — **incidents** (append here after a maintenance/incident pass) · security · backups · config-files · ports · devices · aws.
- **`plans/` · `projects/` · `specs/`** — longer-form planning and spec docs.

## Writing

Three steps, in order. The build + commit details are where this bites.

### 1. Edit the page

Write/patch the file under `docs/`. The wiki tree is owned by the `wiki` user, so write **as that user** (don't create root-owned files in the tree):

```bash
# small append / new page via heredoc:
ssh wanda 'sudo -u wiki tee /opt/services/wiki/docs/services/foo.md > /dev/null' <<'MD'
# Foo
...
MD
```

For edits to an existing page, pull it, patch locally, push it back through `sudo -u wiki tee`, or edit in place with `sudo -u wiki` and an editor over ssh.

**Adding a new page?** Also add it to `mkdocs.yml`'s `nav:` (same `sudo -u wiki` edit) or it won't appear in the rendered site.

### 2. Build (the site serves prebuilt HTML, not live)

The site serves the pre-built `site/` directory, so an edit to `docs/` is invisible until you rebuild:

```bash
ssh wanda 'sudo -u wiki bash -lc "cd /opt/services/wiki && mkdocs build"'
```

If `mkdocs` isn't on the `wiki` user's PATH, check `/opt/services/wiki/bin/` for a wrapper/venv.

### 3. Commit — `sudo -u wiki`, NOT root

⚠️ **The wiki is a NESTED repo owned by the `wiki` user** — distinct from the **root-owned `/opt/services` monorepo**. Committing it as root (via `sudo bash`) leaves root-owned `.git` objects that wedge the next wiki-user commit.

```bash
ssh wanda 'sudo -u wiki git -C /opt/services/wiki add docs/ mkdocs.yml'
ssh wanda 'sudo -u wiki git -C /opt/services/wiki commit -m "docs(services): <real message — why, not just file list>"'
```

Hardening that's already in place (so a stray root commit no longer hard-breaks it, but still **prefer `sudo -u wiki`**): the repo is shared-group-writable (`core.sharedRepository=group` + setgid `.git`, group `wiki`) and has a repo-local `user.name=HAL` / `user.email` so wiki-user commits don't error on identity. There are `.githooks` scans on commit — let them run.

## When to use this skill

- **Before** non-trivial work on a fleet subsystem → read its page first (same reflex as grepping a config).
- **After** changing a subsystem → update its page, then build + commit.
- After a maintenance/incident pass → append to `reference/incidents.md`.
- Whenever Dave says "check the wiki", "what does the wiki say about X", "write this up in the wiki", or references a runbook / post-mortem.
