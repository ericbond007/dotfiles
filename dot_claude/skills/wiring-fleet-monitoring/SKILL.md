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
  probe/exporter, or a systemd timer that must not silently die.
---

# Wiring a new service into fleet monitoring

When you stand up a new service, wire it into monitoring **before** calling it done. The fleet has a deliberate split that's easy to get backwards:

- **blackbox-exporter = the single synthetic-check ALERT source.** `probe_success == 0` routes through Alertmanager → `incident-triage` → **The Claw**. This is the one alert engine.
- **Uptime Kuma = status-page UI ONLY** (`uptime.ericbond.net`). It does **NOT** drive alerts. Do not re-add a Kuma→Prometheus alert rule — that double-alerts (`KumaMonitorDown` was removed for this reason).

Both do "is it up" synthetic checks; running both as alert engines was redundancy that got removed. Blackbox wins as the engine (Grafana history, cert-expiry, content-matching, already wired to triage); Kuma's value is just the human dashboard.

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

### SSO-gated content checks

Kuma **cannot** auth through Authelia — its axios client strips the reserved `Proxy-Authorization` header, so requests arrive `<anonymous>`. Blackbox does **not** strip it. So for an authenticated content check behind SSO, use a blackbox probe carrying the header + a dedicated lldap service account — not Kuma. (For Traefik specifically, router data is already in Prom as `traefik_router_requests_total` — don't duplicate it.)

## 2. Add the Uptime Kuma monitor (status page only)

Add a monitor at `uptime.ericbond.net` for the human dashboard — `uptime-kuma-api` with the 1Password **"Uptime Kuma Admin"** login. Remember: this is UI only; blackbox is what pages.

## 3. Prometheus metrics

Containers are already covered by **cAdvisor** (`job_name: cadvisor`). Add a **dedicated exporter** only when the service exposes metrics genuinely worth alerting/dashboarding on (the *arr stack, mariadb, postgres, nut, pihole, etc. each have one). Otherwise cAdvisor up/restart metrics suffice.

## 4. Scheduled jobs: `enable --now`, then verify, then watchdog

Silent scheduled-job death is a recurring fleet failure class (config-backup dark 6 days; living-pi 12 days). Two rules:

- **`systemctl enable --now`, never bare `enable`.** Bare `enable` only symlinks the timer into `timers.target.wants` — it does NOT start it until the next reboot, so on a long-uptime box an enabled timer sits `inactive` and never fires. Then **confirm**: `systemctl is-active <timer>`.
- **Critical job? Add it to the watchdog.** Append the unit name (without `.timer`) to the host's `CRITICAL` list in `/opt/services/ops/systemd-timer-watchdog.sh` (host-aware: `wanda*` / `serp*` / `bondo*` cases). The `timers` Prometheus rule group then pages The Claw on enabled-but-inactive / stale-past-2.5×-cadence / non-zero-exit.

Why the watchdog is necessary: `node_systemd_timer_last_trigger_seconds` is **not collected** (node-exporter's systemd collector excludes `.timer` units), and `SystemdUnitFailed` only catches `failed`, not `inactive`. The watchdog's textfile metrics (`systemd_timers.prom`) are what actually cover timer liveness.

## Done checklist for a new service

- [ ] blackbox probe added (`http_site`, or a content module if it can 200-but-break)
- [ ] Prometheus + blackbox reloaded; probe shows up and `probe_success == 1`
- [ ] Uptime Kuma monitor added (status page)
- [ ] dedicated exporter added only if metrics warrant it (else cAdvisor covers it)
- [ ] any new timer: `enable --now` + `is-active` confirmed + added to watchdog CRITICAL if critical
- [ ] `/opt/services` changes committed per-service (NOT `git add -A`)
- [ ] service page updated on the ops wiki (see `reading-writing-the-ops-wiki`)
