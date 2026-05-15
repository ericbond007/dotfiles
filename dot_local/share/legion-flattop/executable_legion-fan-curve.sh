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
#   Tctl 60 °C    →  ~6 % PWM (barely audible)
#   Tctl 65 °C    →  ~10 % (quiet)
#   Tctl 70 °C    →  ~16 % (low whir)
#   Tctl 75 °C    →  ~25 % (moderate)
#   Tctl 80 °C    →  ~39 % (firm — "we actually need cooling" range)
#   Tctl 85 °C    →  ~63 %
#   Tctl 90 °C    →  ~86 %
#   Tctl ≥ 100 °C →  100 % (rotors physically cap at ~5500 RPM well before this)
#
# These are the PWM values written to EC RAM; the legion-laptop driver scales
# them up (roughly 1.2× at high values, 2× at low values) before they take
# effect, so steady-state fan response is more aggressive than the raw
# percentages above suggest — at 80 °C expect ~57 % delivered duty cycle.
#
# Module bind strategy:
#   - MODERN path: legion-laptop registers its own platform_device "legion"
#     (legion-laptop.c:6663 platform_device_register_simple). Coexists with
#     ideapad_laptop; do NOT touch ideapad — unloading/reloading it makes
#     the ideapad_wlan rfkill switch default-init to BLOCKED, which kills
#     WiFi for ~60s every time this script runs.
#   - LEGACY path: legion-laptop binds the ACPI alias VPC2004:00, which
#     ideapad_acpi grabs first at boot. Only then do we need to evict
#     ideapad_laptop, modprobe legion-laptop, reload ideapad. Has the
#     WiFi-drop side effect, but unavoidable to bind.
# Try modern path with plain modprobe first; only fall back to the eviction
# dance if that doesn't expose the sysfs root.

set -euo pipefail

modprobe legion-laptop 2>/dev/null || true

VPC=
if [[ -e /sys/devices/platform/legion/fan_fullspeed ]]; then
    VPC=/sys/devices/platform/legion
elif [[ -e /sys/bus/platform/devices/VPC2004:00/fan_fullspeed ]]; then
    VPC=/sys/bus/platform/devices/VPC2004:00
else
    echo "legion-fan-curve: WARN — neither bind path present after plain modprobe; evicting ideapad_laptop (will briefly drop WiFi)" >&2
    modprobe -r ideapad_laptop 2>/dev/null || true
    modprobe legion-laptop
    for candidate in /sys/devices/platform/legion /sys/bus/platform/devices/VPC2004:00; do
        if [[ -e "$candidate/fan_fullspeed" ]]; then
            VPC="$candidate"; break
        fi
    done
    modprobe ideapad_laptop 2>/dev/null || true
fi

if [[ -z "$VPC" ]]; then
    echo "legion-fan-curve: legion-laptop did not expose fan_fullspeed at any known path" >&2
    exit 1
fi

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
declare -a PWM=( 0  0 15 25 40  65 100 160 220 255)
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "${TEMP[$((i-1))]}" > "$HWMON/pwm1_auto_point${i}_temp"
    echo "${PWM[$((i-1))]}"  > "$HWMON/pwm1_auto_point${i}_pwm"
    echo "${TEMP[$((i-1))]}" > "$HWMON/pwm2_auto_point${i}_temp"
    echo "${PWM[$((i-1))]}"  > "$HWMON/pwm2_auto_point${i}_pwm"
done

# 4. Verify the EC actually accepted the curve. The driver scales PWM writes
#    slightly (1-2 LSB rounding on this hardware), so allow ±3 absolute on
#    PWM readback; temps must match exactly. powermode must report as 3
#    (EC custom mode) or 255 (driver-side enum for same), depending on
#    whether the read goes through the EC or WMI access path.
fail=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    want_t="${TEMP[$((i-1))]}"
    want_p="${PWM[$((i-1))]}"
    for fan in 1 2; do
        got_t=$(cat "$HWMON/pwm${fan}_auto_point${i}_temp")
        got_p=$(cat "$HWMON/pwm${fan}_auto_point${i}_pwm")
        if [[ "$got_t" != "$want_t" ]]; then
            echo "legion-fan-curve: VERIFY FAIL fan${fan} point${i} temp: want=$want_t got=$got_t" >&2
            fail=1
        fi
        # bash arithmetic for absolute delta
        delta=$(( got_p - want_p )); (( delta < 0 )) && delta=$(( -delta ))
        if (( delta > 3 )); then
            echo "legion-fan-curve: VERIFY FAIL fan${fan} point${i} pwm: want=$want_p got=$got_p delta=$delta" >&2
            fail=1
        fi
    done
done
pm=$(cat "$VPC/powermode")
if [[ "$pm" != "3" && "$pm" != "255" ]]; then
    echo "legion-fan-curve: VERIFY FAIL powermode: want=3|255 got=$pm (EC not in custom mode)" >&2
    fail=1
fi
if (( fail )); then
    echo "legion-fan-curve: verification failed — curve may not be in effect" >&2
    exit 1
fi

# Clear the OnFailure flag if a prior run set it.
rm -f /run/legion-fan-curve-FAILED 2>/dev/null || true

echo "legion-fan-curve: applied + verified. fan1_target=$(cat "$HWMON/fan1_target") fan2_target=$(cat "$HWMON/fan2_target") powermode=$pm"
