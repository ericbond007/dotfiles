#!/usr/bin/env bash
# Engage the maximum-fan curve on Lenovo Legion 7 16ACHg6 via the patched
# legion-laptop kernel module. Idempotent; safe to re-run.
#
# Sequence is load-bearing — at boot, ideapad_acpi binds to VPC2004:00
# before us, so we must unload it, load legion-laptop (which then claims
# the device), then reload ideapad. Once legion is bound, the fan recipe
# is: lockfancontroller=0 (EC drives the curve), profile=balanced-performance
# (legion's name for "custom mode"), all auto-points to PWM 255, fan_fullspeed=1.
set -euo pipefail

VPC=/sys/bus/platform/devices/VPC2004:00

modprobe -r ideapad_laptop 2>/dev/null || true
modprobe legion-laptop

if [[ ! -e "$VPC/fan_fullspeed" ]]; then
    echo "legion-fancontrol-setup: legion-laptop did not bind to VPC2004:00" >&2
    exit 1
fi

modprobe ideapad_laptop 2>/dev/null || true

HWMON=
for h in /sys/class/hwmon/hwmon*; do
    if [[ "$(cat "$h/name" 2>/dev/null)" == "legion_hwmon" ]]; then
        HWMON="$h"
        break
    fi
done
if [[ -z "$HWMON" ]]; then
    echo "legion-fancontrol-setup: no legion_hwmon found" >&2
    exit 1
fi

echo 0 > "$VPC/lockfancontroller"
echo balanced-performance > "$VPC/platform-profile/platform-profile-0/profile"
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo 255 > "$HWMON/pwm1_auto_point${i}_pwm"
    echo 255 > "$HWMON/pwm2_auto_point${i}_pwm"
done
echo 1 > "$VPC/fan_fullspeed"

echo "legion-fancontrol-setup: applied. fan1_target=$(cat "$HWMON/fan1_target") fan2_target=$(cat "$HWMON/fan2_target")"
