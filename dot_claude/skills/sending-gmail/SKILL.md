---
name: sending-gmail
description: Use when Dave asks you (Claude/HAL) to send an email on his behalf from his personal Gmail, ericbond007@gmail.com — e.g. "email mom", "send someone an email", "email yourself a test", "reply to X by email". Sends via Gmail SMTP using the gmail-smtp 1Password credential. NOT for fleet/service mail — that's sending-email-programmatically (wanda Postfix).
---

# Sending email as Dave's Gmail

When Dave asks you to email someone, send it as **ericbond007@gmail.com** using
the bundled CLI. This is real outbound mail from Dave's personal account — treat
it as an action that is hard to undo, and that goes out *as Dave*.

**Tool invocation:**

- Hosts with Claude configuration:
  `~/.claude/skills/sending-gmail/send-gmail`
- Codex-only hosts:
  `python3 ~/.agents/skills/sending-gmail/executable_send-gmail`

The Codex-only path points into the chezmoi source tree, where the
`executable_` filename is source metadata rather than the installed filename.
Invoke it with Python because that source file intentionally is not executable.

## Credentials
Fetched at runtime from 1Password item `gmail-smtp` (vault `vault.ericbond.net`)
via `op read` — the tool does this itself; you never see or handle the password.
Requires `op` to be authorized on the host:
- **flattop:** service account already configured — just works.
- **serp / wanda:** needs the service-account token in the environment
  (`OP_SERVICE_ACCOUNT_TOKEN`, e.g. from `/etc/op-service-account-token`). If
  `op read` fails there, that's why.

## Recipients
Pass an alias or a full email address to `--to`. Aliases resolve from the
host-local `~/.config/hal/contacts.json` (deliberately NOT chezmoi-tracked, so
personal addresses never reach the dotfiles repo). An unknown alias makes the
tool error with the list of known aliases — do NOT guess an address.

## How to send (confirm before the real send)
1. Select the appropriate tool invocation above.
2. **Preview:** run it with
   `--to <recip> --subject "<subj>" --body "<body>" --dry-run`.
3. Show Dave the resolved **To / Subject / Body** and get explicit confirmation.
4. **Send:** rerun the identical command without `--dry-run`.
5. Report the tool's `Sent to <address>` line; on any `error:` line, report it
   verbatim and do not blind-retry.

A multi-line body: pass `--body "..."` or pipe it on stdin and omit `--body`.
