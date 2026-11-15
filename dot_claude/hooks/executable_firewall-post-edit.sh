#!/bin/bash
# Post-edit reminder for a path containing "nftables": the live /etc/nftables.conf, an nftables.service
# drop-in, or (in practice) an editable copy. Validate, install with Dave's OK, reload, verify, commit, wiki.
# Triggered by Claude Code PostToolUse on Edit/Write

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ "$TOOL" != "Edit" && "$TOOL" != "Write" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != *"nftables"* ]]; then
  exit 0
fi

# PostToolUse: stderr on exit 0 reaches only the transcript, never the model (hook docs). To put the
# reminder in front of Claude it must be JSON additionalContext on stdout (2026-11-04; before that this
# reminder printed to stderr and was invisible to the session it was written for).
# What actually fires this: Claude runs as eric, and /etc/nftables.conf and the nftables.service.d drop-in
# dir are root-owned, so an Edit/Write of a live file fails and PostToolUse never runs. Edits made with sudo
# in Bash don't match Edit|Write either. In practice this fires for an eric-writable COPY, or for any other
# file whose path contains "nftables" (a doc, a vim syntax file), so a non-live path gets a "you edited a
# copy" message that installs nothing by itself.
Q_PATH=$(printf '%q' "$FILE_PATH")
DROPIN_DIR=/etc/systemd/system/nftables.service.d
COMMON="  2. Reload:    sudo systemctl restart nftables
                On wanda and serp, never load /etc/nftables.conf with 'nft -f' (the 'nft -c' check
                above is fine). The file loads the Pi-hole DHCP gate (chain pihole_dhcp_gate)
                CLOSED. 'systemctl restart nftables' usually re-applies the right state at once (its
                ExecStartPost runs the gate reconcile); after 'nft -f' the gate stays closed until
                the next reconcile, normally the minutely timer, so the host holding the DNS VIP
                10.0.0.6 answers no DHCP for up to a minute (up to ~2 min if the gate lock is
                busy). VK #2294.
  3. Verify:    sudo nft list chain inet filter input | grep -c 'jump pihole_dhcp_gate'   -> must print 1
                sudo /opt/services/pihole-standby/bin/pihole-dhcp-gate status
                Pass: gate= equals want= (open on the host holding 10.0.0.6, closed on the other).
                gate=unknown: the change removed or renamed the gate chain; restore it.
                gate differs from want: sudo /opt/services/pihole-standby/bin/pihole-dhcp-gate reconcile,
                then re-check.
  4. Commit:    give Dave these two commands and run neither yourself: in a Claude session on wanda/serp
                the secrets-scan hook refuses 'sudo git -C /etc commit' (VK #2518), and a file staged
                alone would be swept into the next whole-tree commit. Don't work around the scan.
                  sudo git -C /etc add -- <each live file you changed, relative to /etc>
                  sudo git -C /etc commit -m '...'    (bare: NO pathspec; 'commit -- <path>' ignores the index)
                Never config-commit (git add -A in /etc and /opt/services) or a bare 'etckeeper commit'
                (whole tree).
  5. Wiki:      update the firewall page under /opt/services/wiki/docs/ on wanda (ssh wanda if this is not wanda)"
if [[ "$FILE_PATH" == /etc/nftables.conf ]]; then
  MSG="Firewall config modified (/etc/nftables.conf). Next steps:
  1. Validate:  sudo nft -c -f /etc/nftables.conf
$COMMON"
elif [[ "$FILE_PATH" == "$DROPIN_DIR"/* ]]; then
  MSG="nftables.service drop-in modified ($Q_PATH). Next steps:
  1. Reload units: sudo systemctl daemon-reload, then validate: sudo nft -c -f /etc/nftables.conf
$COMMON"
else
  MSG="You edited $Q_PATH, which is NOT a live firewall file; nothing is applied yet.
If it is neither a candidate /etc/nftables.conf nor a candidate nftables.service drop-in (a doc, a
note, a vim syntax file), ignore this reminder.
If it is a candidate /etc/nftables.conf:
  1. Validate it:  sudo nft -c -f $Q_PATH
     Copy the live file to your scratch dir as a backup (it is 0644: no sudo, nothing written in /etc),
     show Dave the literal diff, and only with his OK install it:
                   sudo install -m 0644 -o root -g root $Q_PATH /etc/nftables.conf
If it is a candidate drop-in for nftables.service:
  1. Its name must end in .conf; reuse 50-pihole-dhcp-gate.conf's name only to replace that file.
     Copy any file it replaces to your scratch dir, show Dave the literal diff, and only with his OK:
                   sudo install -m 0644 -o root -g root $Q_PATH $DROPIN_DIR/<name>.conf
                   sudo systemctl daemon-reload
     Check it took: systemctl cat nftables   (the ExecStartPost gate reconcile must still be listed)
Then:
$COMMON"
fi
jq -nc --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'

exit 0
