---
name: sending-email-programmatically
description: Use when a fleet service needs to send email, or when you need to provision a new mailbox/sending identity on Dave's mail server. Covers the canonical recipe — create a mailbox via postfixadmin-cli, store its credential in 1Password, and send via authenticated SMTP submission — plus the non-obvious gotchas (the op-item-create stdin hang, the postfixadmin-cli open_basedir + password2 flags, the docker extra_hosts requirement, and the ps/pgrep secret-leak trap). The fleet runs its OWN Postfix/Dovecot/Rspamd stack on wanda; do NOT reach for Resend or external providers for fleet-internal mail.
---

# Sending email programmatically (ericbond.net fleet)

The fleet runs a full self-hosted mail stack on **wanda** — use it, not Resend/SendGrid/etc., for fleet-internal notifications. This skill is the end-to-end runbook: provision a sending identity → store its secret → send. Every step here was learned the hard way; the gotchas are load-bearing.

## Mail architecture (the facts that matter)

- **Stack:** Postfix + Dovecot (LMTP/IMAP/SASL) + Rspamd (DKIM/spam), native systemd services on **wanda** (`mail.ericbond.net` / `smtp.ericbond.net` / `mx.ericbond.net` → `10.0.0.7`). Wiki: `wanda:/opt/services/wiki/docs/services/email.md`.
- **Ports:** `25` inbound (inbound mail; also accepts local→local delivery), `465` SMTPS, `587` submission (STARTTLS + SASL — **this is what apps use**), `993` IMAPS.
- **`mynetworks = 127.0.0.0/8, 10.0.0.0/24`.** Docker bridge (`172.17.0.0/16`) is NOT trusted. DMARC is `p=quarantine`, SPF `-all`. ⟹ **An app must authenticate (SASL on :587), not blast unauthenticated :25** — unauthenticated mail from the docker bridge gets Rspamd-quarantined. (Plain inbound *to* a local mailbox works unauthenticated because that's MX delivery, not relaying — but for *sending* from a service, always authenticate.)
- **op secrets:** 1Password service-account token at `wanda:/etc/op-service-account-token` (root-only). Vault for fleet secrets: **`vault.ericbond.net`**. The same token op-deploy-secrets uses. It can read AND create items (see the create-hang gotcha below).

## Step 1 — Provision a mailbox (postfixadmin-cli)

PostfixAdmin is MariaDB-backed; its supported scripted interface is `postfixadmin-cli.php`. Two gotchas make or break this:

1. **`open_basedir`**: the default `php` CLI on wanda has a pihole-scoped `open_basedir` that blocks PostfixAdmin's `common.php`. Always invoke with `php -d open_basedir=` and run as **root** (the config is a root/postfixadmin-owned symlink into `/run/php-fpm-conf/`).
2. **`password2` is a required field** and so is the `welcome_mail` toggle. Omit `--password2` and the CLI silently drops to an interactive prompt — which **hangs** a non-interactive run (or fails on EOF). Always pass `--password`, `--password2` (identical), and `--welcome_mail 0` for a no-mailbox-needed sending identity.

Mailbox field names come from `MailboxHandler.php`'s struct: `username` (positional), `password`, `password2`, `name`, `quota` (MB), `active` (bool), `welcome_mail` (bool).

```bash
# run AS ROOT on wanda; ADDR e.g. btown@ericbond.net
php -d open_basedir= /usr/share/webapps/postfixadmin/scripts/postfixadmin-cli.php \
  mailbox add "$ADDR" \
  --password "$PW" --password2 "$PW" --name "<service> notifications" \
  --quota 50 --active 1 --welcome_mail 0 </dev/null
# success line: "The mailbox <addr> has been added to the mailbox table."
```

Related: `mailbox view <addr>`, `mailbox update <addr> --password X --password2 X` (reset), `mailbox delete <addr>`. The domain must already exist (`domain view ericbond.net`).

## Step 2 — Store the credential in 1Password

⚠️ **THE op-item-create HANG.** `op item create` with the service-account token **blocks forever on interactive stdin** (it tries an interactive flow). `op item get` does NOT hang. The fix is non-negotiable:

```bash
# AS ROOT on wanda. timeout = belt; </dev/null = suspenders.
export OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op-service-account-token)"
timeout 30 op item create --category=password --title="<service> smtp" \
  --vault="vault.ericbond.net" "username=$ADDR" "password=$PW" \
  --tags <service>,smtp </dev/null
```

A 1Password **service account REQUIRES `--vault`** on every call (`op item get`/`create` error "a vault query must be provided when this command is called by a service account" otherwise).

## ⚠️ Secret-safety (the ps/pgrep leak — read this)

`op item create "...password=$PW..."` puts the password in **argv**, visible in `ps`/`pgrep -af` for the process's lifetime. This is normally a sub-second flash — **but if the process hangs (see above), the secret sits in the process table indefinitely and WILL leak** (it leaked into a session transcript exactly this way). Therefore:

- **Always** wrap `op item create` in `timeout` + `</dev/null`. A hung secret-bearing process is the failure mode.
- **Hardened form** (no secret in argv at all) — pipe the item as a JSON template on stdin:
  ```bash
  printf '{"title":"%s","category":"PASSWORD","vault":{"id":"vault.ericbond.net"},"fields":[{"id":"username","value":"%s","type":"STRING"},{"id":"password","value":"%s","type":"CONCEALED"}]}' \
    "$TITLE" "$ADDR" "$PW" | timeout 30 op item create --vault vault.ericbond.net -
  ```
- Generate, use, and store the password **entirely server-side in one root script** (`ssh wanda 'sudo tee /root/x.sh' <<'EOF' … EOF; ssh wanda "bash -lc 'sudo bash /root/x.sh; sudo rm -f /root/x.sh'"`). The plaintext must never transit the agent transcript. Echo only non-secret status (`RESULT=ok`, op item id).
- Order: **op-store first, then set the mailbox password to match** (`mailbox update`). If the store fails you haven't stranded an unknown password on a live mailbox.
- Remote shell on wanda/serp is **fish** — wrap every remote command in `bash -lc '…'` (fleet rule). `rc=$?` etc. is bash-only.
- Generate strong: `openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 32`.

## Step 3 — Send from a service

Authenticated submission, STARTTLS, port 587. Python (async, matches most fleet collectors):

```python
import aiosmtplib
from email.message import EmailMessage

async def send(subject, body, *, host, port, user, pw, mail_from, mail_to):
    m = EmailMessage()
    m["From"], m["To"], m["Subject"] = mail_from, mail_to, f"[svc] {subject}"
    m.set_content(body)
    try:
        await aiosmtplib.send(m, hostname=host, port=port, username=user,
                              password=pw, start_tls=True, timeout=10)
    except Exception as e:           # best-effort: log + swallow, never crash the caller
        log.warning("email send failed: %s", e)
```

- **Docker containers can't resolve `mail.ericbond.net` to the LAN** (public DNS → WAN hairpin). Add to the service in `docker-compose.yml`:
  ```yaml
  extra_hosts: ["mail.ericbond.net:10.0.0.7"]
  ```
- **Secret into the app:** `op read "op://vault.ericbond.net/<service> smtp/password"` at deploy time, rendered into the service's `.env` (or credstore — match the service's existing pattern; btown uses plain `.env` consistent with its other keys). Never bake into the image, never commit.
- Config keys convention: `SMTP_HOST` (=`mail.ericbond.net`), `SMTP_PORT` (=`587`), `SMTP_USER` (=`<svc>@ericbond.net`), `SMTP_PASSWORD`, plus app-level `NOTIFY_EMAIL_TO`.

## Step 4 — Verify delivery

Don't trust "send returned" — confirm on the server:

```bash
ssh wanda "bash -lc 'sudo journalctl -u postfix --since \"2 min ago\" | grep -iE \"<svc>|<recipient>\" | tail'"
# want: submission/smtpd ... sasl_username=<svc>@ericbond.net   (auth OK)
#       lmtp ... to=<recipient> ... status=sent (250 ... Saved)  (delivered)
```

## Failure-mode cheat-sheet

| Symptom | Cause | Fix |
|---|---|---|
| `op item create` never returns | SA-token interactive-stdin hang | `timeout 30 … </dev/null` (mandatory) |
| Secret seen in `ps`/transcript | hung secret-in-argv process | timeout+`</dev/null`; prefer stdin-template form; kill stale `op`/script procs |
| postfixadmin-cli hangs / "EMAIL is not valid" | missing `--password2`/required field → interactive prompt | pass ALL fields incl. `--password2`, `--welcome_mail 0`, `</dev/null` |
| `php` "open_basedir restriction" | pihole-scoped php.ini | `php -d open_basedir=` as root |
| op "a vault query must be provided" | service-account needs explicit vault | `--vault vault.ericbond.net` on every op call |
| App mail quarantined / not delivered | unauthenticated send from docker bridge (not in mynetworks; SPF -all/DMARC quarantine) | authenticate on :587 SASL, never raw :25 |
| Container can't connect to mail host | `mail.ericbond.net` → WAN hairpin inside container | `extra_hosts: ["mail.ericbond.net:10.0.0.7"]` |
| remote command syntax errors | wanda default shell is fish | wrap in `bash -lc '…'` |

## Out of scope / don't

- Don't use Resend/SendGrid/external SMTP for fleet-internal mail — the fleet has its own stack; external is only for things that must originate off-fleet.
- Don't write raw `op://` plaintext or commit secrets (see `feedback_prefer_op_no_plaintext_secrets`, `feedback_never_dump_rendered_secrets`).
- Don't create mailboxes by hand-INSERTing into the PostfixAdmin MariaDB tables — use `postfixadmin-cli` (it handles Dovecot password hashing + maildir correctly).
