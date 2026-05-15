#!/usr/bin/env bash
# Wired as OnFailure= for legion-fan-curve.service. Surfaces the failure
# via three channels so it can't sit silently for two days again:
#   1. Journal at Priority=err with a distinctive tag (greppable, picked up
#      by wanda's fleet log-alerts via journal-remote if the watch list
#      includes 'legion-fan-curve-alert').
#   2. /run/legion-fan-curve-FAILED flag file (cleared on reboot since
#      tmpfs; succeeding runs of the curve service remove it).
#   3. notify-send to every active graphical session — best-effort, only
#      reaches Dave if he's logged in at the moment of failure.

set -uo pipefail

MSG="legion-fan-curve.service failed at $(date -Is). Fans are running on whatever curve the EC last had — likely the conservative stock profile that throttles cooling at high temp. Investigate: systemctl status legion-fan-curve.service && journalctl -u legion-fan-curve.service -n 50"

# Channel 1: loud journal entry.
logger -t legion-fan-curve-alert -p user.err -- "$MSG"

# Channel 2: persistent (until reboot) flag.
mkdir -p /run
printf '%s\n' "$MSG" > /run/legion-fan-curve-FAILED || true
chmod 0644 /run/legion-fan-curve-FAILED 2>/dev/null || true

# Channel 3: notify-send to every active graphical session.
# loginctl --no-legend columns: SESSION UID USER SEAT TTY
while read -r _session uid user _rest; do
    [[ -z "${uid:-}" || -z "${user:-}" ]] && continue
    rdir="/run/user/$uid"
    [[ -S "$rdir/bus" ]] || continue
    runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="$rdir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$rdir/bus" \
        notify-send --urgency=critical --app-name=legion-fan-curve \
            "Legion fan curve FAILED" \
            "Fans on stock curve. systemctl status legion-fan-curve.service" \
        2>/dev/null || true
done < <(loginctl list-sessions --no-legend 2>/dev/null)

exit 0
