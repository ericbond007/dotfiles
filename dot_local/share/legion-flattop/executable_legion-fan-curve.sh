#!/usr/bin/env bash
# Programs the EC's custom fan curve on Lenovo Legion 7 16ACHg6 via the
# patched legion-laptop module (see legion-flattop-patches.sh).
#
# The EC always drives the fans; this script writes a curve into EC RAM and
# flips the EC into custom mode so it uses our curve instead of the conservative
# stock "performance" curve (which capped at PWM 114 ≈ 45% at 95°C, the original
# overheating bug). Once written, the EC executes autonomously — even after
# legion-laptop unloads. This script just programs and exits.
#
# Curve targets (Tctl-driven). Note the legion-laptop EC write path on this
# model has an off-by-one quirk: input point N lands at EC point N+1. Stock
# point 0 (PWM 0 @ ≤48°C, hardware-fixed) and our point 1 (input forced to 0
# by validator) effectively give us 8 useful points at output positions 3-10.
# We map our 9 inputs (p1..p9) to occupy that range and accept the shift.
#
#   Tctl ≤ 55 °C  →  fans off (silent at idle / light load)
#   Tctl 60 °C    →  ~10 % PWM (whisper)
#   Tctl 65 °C    →  ~16 % (quiet)
#   Tctl 70 °C    →  ~24 % (low whir)
#   Tctl 75 °C    →  ~35 % (moderate)
#   Tctl 80 °C    →  ~51 % (firm — "we actually need cooling" range)
#   Tctl 85 °C    →  ~71 %
#   Tctl 90 °C    →  ~90 %
#   Tctl ≥ 100 °C →  100 % (rotors physically cap at ~5500 RPM well before this)
#
# These are the PWM values written to EC RAM; the legion-laptop driver scales
# them up (roughly 1.2× at high values, 2× at low values) before they take
# effect, so steady-state fan response is more aggressive than the raw
# percentages above suggest — at 80 °C expect ~73 % delivered duty cycle.
#
# Sequence is load-bearing: at boot ideapad_acpi binds VPC2004:00 before us,
# so we unload it, modprobe legion-laptop, then reload ideapad (which then
# fails-bind harmlessly).

set -euo pipefail

VPC=/sys/bus/platform/devices/VPC2004:00

modprobe -r ideapad_laptop 2>/dev/null || true
modprobe legion-laptop

if [[ ! -e "$VPC/fan_fullspeed" ]]; then
    echo "legion-fan-curve: legion-laptop did not bind to VPC2004:00" >&2
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
    echo "legion-fan-curve: no legion_hwmon found" >&2
    exit 1
fi

# 1. Clear overrides — fan_fullspeed=1 would max fans regardless of curve;
#    lockfancontroller=1 freezes fans at current PWM (misleadingly named).
echo 0 > "$VPC/fan_fullspeed"
echo 0 > "$VPC/lockfancontroller"

# 2. Engage custom mode at the EC (powermode=255 → driver translates to EC=3
#    via the EC access path enabled by legion-flattop-patches.sh patch #2).
#    Write to powermode directly rather than going through platform_profile —
#    the platform-profile choices list dynamically drops "balanced-performance"
#    (its name for "Custom Mode") in some driver states, but the numeric
#    powermode write always works.
echo 255 > "$VPC/powermode"

# 3. Program the curve. Each write is a read-modify-write of the whole 10-point
#    curve in EC RAM. PWM values are 0-255; the EC reports back as RPM-of-100.
declare -a TEMP=(50 55 60 65 70 75 80 85 90 100)
declare -a PWM=( 0  0 25 40 60  90 130 180 230 255)
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "${TEMP[$((i-1))]}" > "$HWMON/pwm1_auto_point${i}_temp"
    echo "${PWM[$((i-1))]}"  > "$HWMON/pwm1_auto_point${i}_pwm"
    echo "${TEMP[$((i-1))]}" > "$HWMON/pwm2_auto_point${i}_temp"
    echo "${PWM[$((i-1))]}"  > "$HWMON/pwm2_auto_point${i}_pwm"
done

echo "legion-fan-curve: applied. fan1_target=$(cat "$HWMON/fan1_target") fan2_target=$(cat "$HWMON/fan2_target")"
