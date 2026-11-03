#!/usr/bin/env bash
# Wired as OnFailure= for legion-fan-curve.service and legion-fancurve-ac.service.
# systemd passes the failed unit in $MONITOR_UNIT (OnFailure= environment), so
# the message names the unit that actually failed. Surfaces the failure
# via three channels so it can't sit silently for two days again:
#   1. Journal at Priority=err with a distinctive tag (greppable, picked up
#      by wanda's fleet log-alerts via journal-remote if the watch list
#      includes 'legion-fan-curve-alert').
#   2. /run/legion-fan-curve-FAILED flag file (cleared on reboot since
#      tmpfs; succeeding runs of the curve service remove it).
#   3. notify-send once per user with a session bus — best-effort, only
#      reaches Dave if he's logged in at the moment of failure.

set -uo pipefail

UNIT="${MONITOR_UNIT:-legion-fan-curve.service}"
PM="?"
for b in /sys/devices/platform/legion /sys/bus/platform/devices/VPC2004:00; do
    [[ -r "$b/powermode" ]] && { PM=$(cat "$b/powermode" 2>/dev/null || echo "?"); break; }
done
MSG="$UNIT failed at $(date -Is); EC powermode is now $PM (255 = our custom curve; anything else is one of Lenovo's tables). Investigate: journalctl -u $UNIT -n 50"

# Channel 1: loud journal entry.
logger -t legion-fan-curve-alert -p user.err -- "$MSG"

# Channel 2: persistent (until reboot) flag.
mkdir -p /run
printf '%s\n' "$MSG" > /run/legion-fan-curve-FAILED || true
chmod 0644 /run/legion-fan-curve-FAILED 2>/dev/null || true

# Channel 3: notify-send once per USER with a session bus (loginctl lists
# several sessions per uid, and KDE critical popups do not expire).
for bus in /run/user/*/bus; do
    [[ -S "$bus" ]] || continue
    rdir=${bus%/bus}
    user=$(id -nu "${rdir##*/}" 2>/dev/null) || continue
    timeout 10 runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="$rdir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
        notify-send --urgency=critical --app-name=legion-fan-curve \
            "Legion fan curve FAILED" \
            "$UNIT failed; powermode=$PM (255 = our curve). journalctl -u $UNIT -n 50" \
        2>/dev/null || true
done

exit 0
