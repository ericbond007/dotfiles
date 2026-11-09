---
name: wiring-fleet-monitoring
description: >-
  Use when standing up a NEW service on the fleet (wanda/serp) and wiring it
  into monitoring before calling it done, or when adding/checking a synthetic
  health check, a Prometheus exporter, an Uptime Kuma monitor, or a systemd
  timer's liveness alerting. The fleet's split is non-obvious and easy to get
  wrong: blackbox-exporter is the single ALERT engine, Uptime Kuma is a
  status-page UI ONLY, and enabled-but-inactive timers die silently. Trigger
  this whenever Dave mentions monitoring, alerting, blackbox, "wire it into
  the Claw / Alertmanager", a health check, an uptime monitor, a Prometheus
  probe/exporter, or a systemd timer that must not silently die. Also holds
  the recipe for PROVING an alert fires without emailing Dave (silence first; § 6).
---

# Wiring a new service into fleet monitoring

When you stand up a new service, wire it into monitoring **before** calling it done. The fleet has a deliberate split that's easy to get backwards:

- **blackbox-exporter = the single synthetic-check ALERT source.** `probe_success == 0` routes through Alertmanager → **email** (The Claw is dead: its `incident-triage` routes were removed on 2026-10-21, and `warning` and `critical` both email now). This is the one alert engine.
- **Uptime Kuma = status-page UI ONLY** (`uptime.ericbond.net`). It does **NOT** drive alerts. Do not re-add a Kuma→Prometheus alert rule — that double-alerts (`KumaMonitorDown` was removed for this reason). Its own email is off except for the `KEEP_EMAIL` monitors (§ 2).

Both do "is it up" synthetic checks; running both as alert engines was redundancy that got removed. Blackbox wins as the engine (Grafana history, cert-expiry, content-matching, already wired to triage); Kuma's value is just the human dashboard.  *(2026-10-21: "triage" here means the Alertmanager → email path; The Claw is dead.)*

Config lives under `/opt/services` — **commit per-service** with `sudo git -C /opt/services`, **never `git add -A`** (see the `deploying-wanda-services` skill for the monorepo git discipline). Gitignore any data/secret files before committing.

## 1. Add a blackbox synthetic probe (the alert)

Edit `/opt/services/prometheus/prometheus.yml`. For a plain status check, add the URL to the **`blackbox-http`** job's alphabetical target list (module `http_site` — status-only):

```yaml
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_site]
    static_configs:
      - targets:
          - https://existing.ericbond.net
          - https://your-new-service.ericbond.net   # <-- add here, keep alphabetical
```

`http_site` (defined in `/opt/services/blackbox-exporter/blackbox.yml`) accepts `200,201,204,301,302,307,308,401,403` as healthy — so an auth-gated 401/403 still reads as "up".

### 200-but-broken endpoints need a CONTENT check

Login pages and webmail can serve **HTTP 200 with a broken body** (the 2026-06-14 Roundcube break: 200 + "Internal Error"). Status-only misses this. Use a content-matching module instead — add the target to the **`blackbox-content`** job and point it at a module with `fail_if_body_not_matches_regexp`:

```yaml
# in blackbox.yml — a module that asserts on body text:
  http_login:
    prober: http
    http:
      valid_status_codes: [200]
      fail_if_body_not_matches_regexp:
        - "<expected text that only appears when healthy>"
```

Pattern after the existing `http_login` (webmail) and `http_jailbeat` (public jailbeat.com) modules.

### Reloading after a config edit

Both run as Docker containers under `/opt/services` and **reload config on SIGHUP without restarting** — signal them, don't bounce them:

```bash
# Prometheus (picks up prometheus.yml — new targets/jobs):
ssh wanda 'docker compose -f /opt/services/prometheus/docker-compose.yml kill -s HUP prometheus'
# blackbox-exporter (picks up blackbox.yml — new/changed modules):
ssh wanda 'docker kill -s HUP blackbox-exporter'
```

Prometheus also runs with `--web.enable-lifecycle`, so `POST http://127.0.0.1:9090/-/reload` works as an alternative (blackbox exposes the same on :9115). SIGHUP is the simplest and needs no host-port reachability. After reloading, confirm the new probe is live — its target shows `UP` and `probe_success == 1` in Prometheus.

Two traps (2026-11-08, VK #2461):
- **`prometheus.yml` and `blackbox.yml` are single-file bind mounts.** An editor save-as, `mv` or `install` replaces the inode, and the container keeps reading the old file. Write in place (`cat new > file`) and check the in-container sha (`docker exec … sha256sum /etc/prometheus/prometheus.yml`).
- **Read the reload result from `:9090/metrics` (or `:9115/metrics`) directly.** A PromQL query of `prometheus_config_last_reload_success_timestamp_seconds` shows the last *self-scrape*, which can lag the reload by a scrape interval.

Validate before the HUP:
- Prometheus: `docker exec -i prometheus-prometheus-1 sh -c 'cat > /tmp/p.yml && promtool check config --lint-fatal /tmp/p.yml' < candidate`, judged by promtool's own exit code.
- blackbox: its container is read-only, so run `--config.check` in a throwaway container from the same image. It rejects bad regexes and unknown fields, but **not** a bad prober name, so calibrate each new module on a known-good and a known-bad target with `curl '127.0.0.1:9115/probe?module=M&target=T'`.

### SSO-gated content checks

Kuma **cannot** auth through Authelia — its axios client strips the reserved `Proxy-Authorization` header, so requests arrive `<anonymous>`. Blackbox does **not** strip it. So for an authenticated content check behind SSO, use a blackbox probe carrying the header + a dedicated lldap service account — not Kuma. (For Traefik specifically, router data is already in Prom as `traefik_router_requests_total` — don't duplicate it.)

## 2. Add the Uptime Kuma monitor (status page only)

Add a monitor at `uptime.ericbond.net` for the human dashboard — `uptime-kuma-api` with the 1Password **"Uptime Kuma Admin"** login. Remember: this is UI only; blackbox is what pages.

**Kuma's own email (VK #2461, 2026-11-08).** Kuma's SMTP notification mails Dave directly, past Alertmanager and every silence (6 mails during the 2026-11-08 failover drills). So:
- "Email" is not the default for new monitors.
- It stays bound only to the monitors named in `KEEP_EMAIL` in `/opt/services/uptime-kuma/scripts/bootstrap.py`. Today that is 17 "Prometheus" (nothing else sees Prometheus down) and 24 "jailbeat error-rate synthetic" (≥ 2 of 12 cache-busted 5xx, which no blackbox probe sees).
- Don't bind it to a new monitor. Give the check a blackbox probe instead.
- The bootstrap is the declarative source. Edit it, run `--dry-run`, then run it.
- uptime_kuma_api 1.2.1 takes `notificationIDList` as a **list of ids**: its input conversion turns every element or dict key into `{id: True}`, so a dict `{id: False}` **binds**.
- Monitors made in the UI can carry `dns_resolve_type` NULL, which the library rejects on edit. The bootstrap pre-checks every edit and sends nothing if one fails.

## 3. Prometheus metrics

Containers are already covered by **cAdvisor** (`job_name: cadvisor`). Add a **dedicated exporter** only when the service exposes metrics genuinely worth alerting/dashboarding on (the *arr stack, mariadb, postgres, nut, pihole, etc. each have one). Otherwise cAdvisor up/restart metrics suffice.

## 4. Scheduled jobs: `enable --now`, then verify, then watchdog

Silent scheduled-job death is a recurring fleet failure class (config-backup dark 6 days; living-pi 12 days). Two rules:

- **`systemctl enable --now`, never bare `enable`.** Bare `enable` only symlinks the timer into `timers.target.wants` — it does NOT start it until the next reboot, so on a long-uptime box an enabled timer sits `inactive` and never fires. Then **confirm**: `systemctl is-active <timer>`.
- **Critical job? Add it to the watchdog.** Append the unit name (without `.timer`) to the host's `CRITICAL` list in `/opt/services/ops/systemd-timer-watchdog.sh` (host-aware: `wanda*` / `serp*` cases; its `bondo*` case is dead — bondo was decommissioned 2026-10-07). The `timers` Prometheus rule group then pages The Claw on enabled-but-inactive / stale-past-2.5×-cadence / non-zero-exit.

Why the watchdog is necessary: `node_systemd_timer_last_trigger_seconds` is **not collected** (node-exporter's systemd collector excludes `.timer` units), and `SystemdUnitFailed` only catches `failed`, not `inactive`. The watchdog's textfile metrics (`systemd_timers.prom`) are what actually cover timer liveness.

## 5. Alerting about the alerting path itself — `severity: critical` is MANDATORY

**If the thing you are alerting *about* is part of the delivery path, `severity: warning` sends the alert to the broken component.**

> **2026-10-21: The Claw is dead** and the two `incident-triage` routes are gone from `alertmanager.yml` — `warning` now falls through to the root `email` receiver (24 h repeat); `critical` still takes its own child route (10 s wait, 6 h repeat). Exceptions: bondo and living-pi non-critical → `null`. Email is now the ONLY delivery path — there is no escape path for an alert about the mail path itself; `AlertmanagerEmailDeliveryFailing` (`rules/alertmanager.yml`) watches it but can only page through it. The paragraph below describes the pre-2026-10-21 topology; its principle — an alert about the delivery path must not depend on that path — still applies to the mail path (postfix, Alertmanager itself).

In wanda's `alertmanager.yml` the `warning` tier matches **only** the two `incident-triage` routes — and incident-triage delivers **through The Claw (openclaw)**. So a warning-tier "The Claw is down" alert is handed to the dead component and never arrives. `severity: critical` additionally matches the third route, which has **no `receiver:`** and therefore inherits the parent `email` receiver — the only escape path that does not touch openclaw.

Applies to any alert on openclaw, incident-triage-receiver, Alertmanager itself, or the mail path.

**Origin (2026-07-26):** The Claw could not reach any model for ~7.5h. `openclaw.service` reported `active (running)` with `NRestarts=0` the whole time, so systemd, the timer watchdog and Prometheus all saw it healthy while Alertmanager delivered **53 webhooks** into a component that could act on none of them. Nothing noticed until Dave asked. → `ClawAllModelsFailed` + `ClawSilent` in `/opt/services/loki/rules/fake/openclaw.yml` (VK #1956).

### Three traps when writing a log-based alert

- **Grep-based alerts self-trigger.** sudo command-audit lines echo the command text into the journal, so investigating with `journalctl | grep "<the alert phrase>"` fires your own alert. Scope to the `unit` **and** add `!= "COMMAND="` — `KernelOOMOrPanic` carries this guard after a real false page on 2026-06-15.
- **Use `absent_over_time(...)`, never `== 0`,** for "no logs at all": an empty stream returns **no series**, so `== 0` can never match.
- **A `/health` endpoint can return 200 while the service is functionally dead.** openclaw's did, throughout the outage. Verify the health check actually reflects the failure mode you care about before wiring it.

**Prefer alerting on the failure line over staleness.** A "time since last success" heartbeat was rejected for The Claw: measured cadence was only ~3 heartbeats/24h plus sparse user traffic, so any false-positive-safe threshold would have been slower than the outage it was meant to catch.

**Loki rules live in `/opt/services/loki/rules/fake/*.yml`** (owned `loki:loki`), ruler → `host.docker.internal:9093`. No restart needed: the ruler re-reads that directory on its 1-minute poll (measured 2026-11-05: a deleted group was gone from `/prometheus/api/v1/rules` in ~45 s; note `/loki/api/v1/rules` only lists files on disk, so it proves nothing). Confirm at `/prometheus/api/v1/rules` that the group shows `health=ok` — a rule file that exists but is not evaluated is worthless. **Prove a new rule would have caught the incident** by replaying its expr over the incident window with `query_range`.

## 6. Proving an alert fires — without emailing Dave (silence first)

*Moved from CLAUDE.md § "Plans that LAND", class 9 "Exception for alerts", 2026-11-03. The RULE stays in CLAUDE.md ("a proof never reaches Dave's inbox" — Dave, 2026-10-29 — and the "Silence first" line). This section is the full mechanics; the `review-design` brief checks for them.*

- **Silence first.** Put a silence in place BEFORE the deliberate firing.
  - Match the test firing's labels as narrowly as possible.
  - Set `endsAt` just past the expected resolve, and extend it if the alert is still firing.
  - Expire it only after `/api/v2/alerts` shows the alert resolved or gone. Expiring it while the alert still fires is a lapse.
  - Put it in before the firing reaches Alertmanager: a new critical alert's first email goes out 10 s after it arrives.
  - A silenced alert sends neither its firing email nor its "resolved" email.
  - If the silence lapses while the alert is still firing, the group's next flush emails it, within 5 min (`group_interval`), whatever the severity. Nothing arriving 2 minutes after a lapse does not mean you're safe.
  - A signal that stays up until a reset (e.g. a daily counter like `cap_hit_today`) can't be silenced both narrowly and briefly. Prove it with a test-only label instead of the real signal, or say plainly that the silence also hides any real hit until the reset.
- **Then the proof, which stops at Alertmanager.** The alert appears in `/api/v2/alerts` with `status.state: suppressed` and `status.silencedBy` set to your silence's id. That is the pass: `active` means the silence missed and an email is coming. A brief `unprocessed` state right after arrival is normal, so poll for a moment.
- **And the route.** Inside `alertmanager-alertmanager-1`, run `amtool config routes test --alertmanager.url=http://localhost:9093 --verify.receivers=<expected> <its full labelset>`. Copy the labels from the `/api/v2/alerts` entry, including `cluster`, `instance` and `job`. That entry's `receivers[].name` is a second, live check. It must exit 0. Without `--verify.receivers` it exits 0 even when it prints the wrong receiver.
- **The email hop itself** is proven by real alerts arriving. `AlertmanagerEmailDeliveryFailing` watches only the Alertmanager → Postfix hand-off, and it pages through the very path it watches. No test page.
- **Real problems still email as normal**, provided the silence stays narrow and short.

## Done checklist for a new service

- [ ] if a proof firing is planned: alert proven under a narrow silence per § 6 — never Dave's inbox
- [ ] blackbox probe added (`http_site`, or a content module if it can 200-but-break)
- [ ] Prometheus + blackbox reloaded; probe shows up and `probe_success == 1`
- [ ] Uptime Kuma monitor added (status page)
- [ ] dedicated exporter added only if metrics warrant it (else cAdvisor covers it)
- [ ] any new timer: `enable --now` + `is-active` confirmed + added to watchdog CRITICAL if critical
- [ ] `/opt/services` changes committed per-service (NOT `git add -A`)
- [ ] if the alert is *about the delivery path* (openclaw / incident-triage / Alertmanager / mail): `severity: critical`, or it routes to the broken component (§5)
- [ ] service page updated on the ops wiki (see `reading-writing-the-ops-wiki`)
