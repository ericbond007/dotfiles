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
# Curve targets as of 2026-09-01 (knees shifted down ~5 °C; PWM values unchanged):
#   Tctl ≤ 55 °C  →  fans off (silent at idle / light load)
#   Tctl 60 °C    →  ~5 % PWM (barely audible)
#   Tctl 63 °C    →  ~8 % (quiet)
#   Tctl 66 °C    →  ~12 % (low whir)
#   Tctl 70 °C    →  ~18 % (moderate)
#   Tctl 75 °C    →  ~24 % (audible but not loud)
#   Tctl 80 °C    →  ~35 % (firm — this is now the normal sustained-work band)
#   Tctl 86 °C    →  ~59 %
#   Tctl ≥ 100 °C →  100 % (rotors physically cap at ~5500 RPM well before this)
#
# IC CHANNEL (unresolved, 2026-09-01): the EC consults THREE sensor channels --
# CPU (pwm1_), GPU (pwm2_) and IC (pwm3_). This script writes only CPU and GPU;
# the IC thresholds are whatever the EC shipped with (max 40/43/48, then 127 for
# every remaining point, i.e. the IC channel cannot upshift past point 4). The
# arbitration rule between channels is not documented in the driver, so this is
# FLAGGED, not guessed at. Same bug class as the stale HYST floors fixed on
# 2026-09-01, one channel further out.
#
# 2026-06-29: softened the 75-90 °C band. The prior curve hit PWM 160 (which
# already saturates the rotors at ~5600 RPM) the moment Tctl crossed ~78 °C, so
# the fans went to full blast at 80 °C — a perfectly normal load temperature for
# a 5800H (throttle is ~95 °C). Empirically the EC's hysteresis parks "normal
# work" on the PWM-90 band, so that band is the real
# work-noise lever (it was the 85 °C band; the 2026-09-01 shift moved it to 80 °C) — it's now PWM 90 (~3700-4000 RPM) instead of 160. The chip
# settles a few degrees warmer (~85-88 °C under sustained load) in exchange for
# noticeably quieter fans, with ~7-10 °C still in hand before the 95 °C throttle.
# The hard ramp at 90/100 °C (PWM 150 → 255) is kept intact so a genuine runaway
# is still caught.
#
# These are the PWM values written to EC RAM. Measured on this hardware the EC
# stores them ~1:1 (an input of 90 reads back ~90), and delivered RPM is
# non-linear and saturates near the top: PWM 150-160 already pins the rotors at
# ~5600 RPM, while the work band (PWM 90 around 80-85 °C) delivers ~3700-4000 RPM
# and PWM 60 (≈75 °C in this curve) ~3000-3500 RPM.
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

# 2026-08-30: SERIALIZE. Five independent triggers run this same script --
# legion-fan-curve.service (boot), legion-fancurve-ac.service (udev AC event),
# power-profiles-daemon's ExecStartPost, the /usr/lib/systemd/system-sleep
# resume hook, and (since 2026-10-09) the legion-profile-watch daemon, which
# runs this script directly (under `timeout`) after every PPD profile change
# and on powermode/shape drift. They are separate units/processes, so systemd
# does NOT serialize them.
# Every hwmon curve write is a read-modify-write of ALL EC slots, so two
# interleaved runs can produce a mixed curve or the collapsed size this script
# already has to defend against. One lock removes that whole class of race.
exec 9>/run/legion-fan-curve.lock
if ! flock -w 60 9; then
    echo "legion-fan-curve: could not acquire /run/legion-fan-curve.lock within 60s; another run is wedged" >&2
    exit 1
fi

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

# 3. Program the curve. Each write is a read-modify-write of the whole curve in
#    EC RAM. PWM values are 0-255; the EC reports back as RPM-of-100.
#
#    SIZE-AWARENESS (added 2026-06-30): the EC fan curve holds either 10 or 9
#    points depending on EC state. A failed/raced powermode transition can
#    collapse a 10-point curve to 9, and the hwmon write path CANNOT grow it back
#    — writing a 10th point into a size-9 curve is silently dropped, then fails
#    verification. That is exactly what wedged legion-fancurve-ac.service on
#    2026-06-30 (top point read back 0; CPU left on a curve with no 100 °C cap).
#    So we read the live curve size (after powermode=255 is set) and write
#    EXACTLY that many points. Both variants top out at 100 °C / PWM 255 — the
#    hard safety cap is present whether we get 9 or 10 slots. The 9-point variant
#    just drops the inaudible 63 °C knee; the quiet 80-85 °C work band and the
#    90→100 °C safety ramp are identical to the 10-point curve.
# Prefer the hwmon attribute over debugfs: it is the SAME value the repair path
# below writes to, needs no debugfs mount (a hardened boot or a CONFIG_DEBUG_FS
# change would otherwise hard-fail this script at every boot and resume for no
# reason), and reading it does not emit the ACPI/WMI error spam that every
# debugfs fancurve read logs -- which matters because legion-fan-curve-check
# .timer polls every 2 minutes. debugfs stays as the fallback.
read_curve_size() {
    local sz
    sz=$(cat "$HWMON/auto_points_size" 2>/dev/null || true)
    if [[ -z "$sz" ]]; then
        sz=$(awk '/Fan curve points size/{print $NF; exit}' /sys/kernel/debug/legion/fancurve 2>/dev/null || true)
    fi
    printf '%s' "$sz"
}

# HYSTERESIS (2026-09-01): each EC curve point has TWO temperatures -- an
# upshift threshold (hwmon `..._temp`, shown as cpu_max_temp in debugfs) and a
# downshift floor (hwmon `..._temp_hyst`, shown as cpu_min_temp). This script
# historically wrote ONLY the upshift temp, leaving the floors at whatever the
# EC already held. That is silently fine as long as the curve never moves, but
# it is a live landmine the moment anyone retunes: lowering an upshift temp
# below its own stale floor produces an INVERTED point (min > max).
# Observed exactly that on 2026-09-01 -- shifting point 9 to 86 C left its floor
# at 87 C, so the point read `cpu_min=87 cpu_max=86` and its step-down behaviour
# was undefined. Both arrays are now written and verified together.
#
# Selects TEMP[]/HYST[]/PWM[] for the given size. Plain assignment (NOT `declare`,
# which would scope them to this function) so the writer loop below sees them.
select_curve() {
    case "$1" in
        # 2026-09-01: knees 4-9 shifted DOWN ~5 C. PWM values are UNCHANGED --
        # this is purely "reach the same fan speed sooner", not "spin faster".
        #
        # WHY: measured a 60 s all-core load on 2026-09-01. Tctl crossed 80 C at
        # t+6s and sat at 85-87 C until t+14s, while both fans stayed parked at
        # ~1840 RPM; they only reached 3650 RPM at t+26s, after which Tctl fell
        # to 78-81 C and stayed there. So the steady state was already healthy
        # (no throttle, 3.82 GHz all-core held) but there was a ~12 s dead band
        # where the chip ran 6-9 C hotter than it needed to, purely waiting on
        # the EC to climb three curve points. That window is where burst work
        # (shader compile, level load) lives, and it is also when Dynamic Boost
        # decides how much of the 140 W budget to give the dGPU.
        #
        # Moving the pwm-90 knee 85 C -> 80 C makes the EC start that climb at
        # the temperature the load actually reaches first. This partially walks
        # back the 2026-06-29 "softened 75-90 C band" change, which traded ~5 C
        # for quiet -- an explicit, opted-into noise-for-thermals trade.
        # The 100 C / PWM 255 runaway cap is deliberately UNTOUCHED.
        #
        # HYST[] is the DOWNSHIFT floor (EC "cpu_min_temp"); TEMP[] is the
        # UPSHIFT threshold ("cpu_max_temp").
        #
        # The invariant that matters is CROSS-point, not intra-point: a point i
        # is ENTERED by upshifting from i-1, which happens at T > TEMP[i-1]. So
        # it is only stable on entry if HYST[i] < TEMP[i-1]. If HYST[i] is at or
        # above the temperature you arrive at, the EC immediately downshifts,
        # heats back past TEMP[i-1], upshifts again -- fan hunting.
        #
        # The ORIGINAL curve violated this at its top two points (floor 87 vs
        # entry 85; floor 91 vs entry 90) but got away with it, because 85-87 C
        # sat ABOVE the ~78-81 C the machine actually settles at, so the bad
        # band was rarely entered. Shifting the knees down on 2026-09-01 moved
        # that same defect INTO the working band (floor 82 vs entry 80) and made
        # it live. Floors for the top two points are therefore set to give +4/+3
        # of real hysteresis rather than inheriting the original's -2/-1.
        10) TEMP=(50 55 60 63 66 70 75 80  86 100)
            HYST=( 0 45 51 55 57 64 67 73  76  83)
            PWM=(  0  0 12 20 30 45 60 90 150 255) ;;
        9)  TEMP=(50 55 60 66 70 75 80  86 100)
            HYST=( 0 45 51 57 64 67 73  76  83)
            PWM=(  0  0 12 30 45 60 90 150 255) ;;
        *)  return 1 ;;
    esac
    return 0
}

# Validate the currently-selected TEMP/HYST/PWM. Refuses a self-inconsistent
# curve: an inverted or zero-hysteresis point leaves the EC's step behaviour
# undefined, and a non-monotonic ladder can park the fans on the wrong point.
validate_curve() {
    local label="$1" n=${#TEMP[@]} i
    if (( ${#HYST[@]} != n || ${#PWM[@]} != n )); then
        echo "legion-fan-curve: $label: TEMP/HYST/PWM length mismatch (${#TEMP[@]}/${#HYST[@]}/${#PWM[@]})" >&2
        return 1
    fi
    for ((i=0; i<n; i++)); do
        if (( HYST[i] >= TEMP[i] )); then
            echo "legion-fan-curve: $label: point $((i+1)) inverted (floor ${HYST[i]} >= threshold ${TEMP[i]})" >&2
            return 1
        fi
        if (( i > 0 )); then
            if (( TEMP[i] <= TEMP[i-1] )) || (( HYST[i] <= HYST[i-1] )); then
                echo "legion-fan-curve: $label: point $((i+1)) breaks monotonicity" >&2
                return 1
            fi
            # THE important one -- see the HYSTERESIS note in select_curve.
            if (( HYST[i] >= TEMP[i-1] )); then
                echo "legion-fan-curve: $label: point $((i+1)) has non-positive hysteresis (floor ${HYST[i]} >= entry temp ${TEMP[i-1]}); fans would hunt" >&2
                return 1
            fi
        fi
    done
    return 0
}

# STATIC SELF-TEST of the constants, before we touch the EC at all.
# Both tables are checked on every run, not just the one this boot happens to
# select -- otherwise a typo in the size-9 fallback would lie dormant until a
# suspend/resume collapsed the curve, and would then make the RECOVERY path
# refuse to write during exactly the emergency it exists for.
for _sz in 10 9; do
    select_curve "$_sz" || { echo "legion-fan-curve: internal: no table for size $_sz" >&2; exit 1; }
    validate_curve "size-$_sz table" || { echo "legion-fan-curve: refusing to write a bad curve" >&2; exit 1; }
done
unset _sz

SIZE=$(read_curve_size)
if ! select_curve "$SIZE"; then
    #    SIZE RECOVERY (added 2026-08-30): a suspend/resume can collapse the EC
    #    curve to a size we have no table for (observed: size 8 on 2026-08-30,
    #    which left the CPU on the stock curve at 90 C for ~47 min). Cycling
    #    powermode 3 -> 255 makes the EC rebuild a full 10-point curve (the
    #    2026-06-30 finding). NOTE step 2 above already wrote 255 -- but if
    #    powermode was ALREADY 255 that write is a no-op and the EC never
    #    rebuilds. That is precisely why recovery failed on 2026-08-30. So force
    #    a REAL transition here before giving up.
    echo "legion-fan-curve: unexpected EC fan-curve size '${SIZE:-<empty>}' - growing it back via auto_points_size" >&2
    # 2026-08-30 (revised): the FIRST version of this recovery cycled powermode
    # 3 -> 255 to make the EC rebuild its curve. That worked, but it deliberately
    # passed THROUGH performance mode (the stock overheating curve) to repair the
    # safe one, and each powermode write emits a platform_profile notification --
    # PPD re-reads platform_profile ~2 s later and ADOPTS any non-"custom" value
    # it finds (ppd-driver-platform-profile.c), i.e. the very drift we are fixing. The driver exposes a direct primitive instead:
    # storing auto_points_size routes to fancurve_set_size(..., init_values=true)
    # (legion-laptop.c:6664/2961), which grows the curve by cloning the last point
    # into the new slots. No mode change, no notification, no stock-curve window.
    # Guarded: stage 2 exists for "accepted but ineffective", but this write can
    # also be REJECTED (-EBUSY / -EOPNOTSUPP from fan_control_write_allowed,
    # read_fancurve or write_fancurve). Bare under `set -e` that would kill the
    # script here and skip the powermode cycle entirely -- i.e. reproduce the
    # 45 h uncapped-curve incident on the very path added to prevent it.
    if ! echo 10 > "$HWMON/auto_points_size" 2>/dev/null; then
        echo "legion-fan-curve: WARN - auto_points_size write rejected; going straight to the powermode cycle" >&2
    fi
    sleep 1
    SIZE=$(read_curve_size)

    # STAGE 2 (added 2026-09-13): auto_points_size DOES NOT ALWAYS WORK.
    #
    # Observed 2026-09-11 16:40 and again 2026-09-13 13:54: the EC collapsed to
    # size *8* (not 9), auto_points_size=10 was accepted but the size stayed 8,
    # and this function then gave up and exited 1 -- leaving the machine on an
    # 8-point curve whose TOP POINT WAS PWM 89 HELD TO 127 C. No high-temp ramp,
    # no 255 cap, for ~45 hours across two AC events. That is the exact
    # overheating shape this whole script exists to prevent.
    #
    # The powermode 3 -> 255 cycle (the ORIGINAL 2026-06-30 lever, replaced on
    # 2026-08-30 by auto_points_size) still works: it rebuilt 8 -> 10 on the
    # first try. The 2026-08-30 reasoning for dropping it was sound but
    # incomplete -- yes, the cycle passes briefly through the stock curve and
    # emits a platform_profile notification that PPD may answer by ADOPTING
    # "performance" as its own profile if its re-read (~2 s later) lands before
    # the 255 write (2026-10-09 review), so it is NOT the first choice. But "briefly on the stock curve" is
    # strictly better than "indefinitely on a curve with no cap at all".
    #
    # So: gentle path first, big hammer only if it failed.
    if ! select_curve "$SIZE"; then
        echo "legion-fan-curve: auto_points_size did not grow the curve (still '${SIZE:-<empty>}'); falling back to a powermode 3->255 cycle" >&2

        # TRAP FIRST, and it is not optional. Between the two writes below the
        # EC sits in PERFORMANCE mode = the stock curve. `sleep` is an
        # interruptible foreground child and bash dies on SIGTERM/SIGINT by
        # default, so without this a Ctrl-C, a `systemctl stop`, a shutdown, or
        # an earlyoom signal in that ~2 s window would strand the EC on the
        # stock curve with NOTHING to put it back -- the drift checker is
        # alert-only by design. That is this script making things WORSE than
        # not running. Handler is idempotent, so it is harmless on success.
        #
        # ⚠️ The handlers EXIT rather than just running a command. A bare
        # `trap '<cmd>' TERM` runs the command and then RESUMES the script,
        # swallowing the signal. Both curve units carry TimeoutStopUSec=10s, so
        # a swallowed TERM does not hang shutdown (an earlier version of this
        # comment claimed it would -- wrong); the real cost is that systemd
        # escalates to SIGKILL at 10 s, and SIGKILL runs NO handler, so the EC
        # would be stranded at powermode 3 after all. Caught by testing the
        # trap instead of assuming it. Residual uncoverable paths: SIGKILL and
        # power loss.
        # EXIT restores only; the signal traps restore and exit with the
        # conventional 128+signo so systemd still sees a signal death.
        # Restores BOTH powermode and the override flags: lockfancontroller=1
        # freezes the fans at their current PWM, and a repair runs at idle with
        # fans parked low, so leaving it set is worse than doing nothing.
        _restore_pm() {
            echo 255 > "$VPC/powermode" 2>/dev/null || true
            echo 0 > "$VPC/fan_fullspeed" 2>/dev/null || true
            echo 0 > "$VPC/lockfancontroller" 2>/dev/null || true
        }
        trap '_restore_pm' EXIT
        trap '_restore_pm; exit 130' INT
        trap '_restore_pm; exit 143' TERM
        trap '_restore_pm; exit 129' HUP
        trap '_restore_pm; exit 131' QUIT

        echo 3 > "$VPC/powermode"; sleep 2
        # Verify the transition was REAL. The premise of cycling is that a
        # same-value write is a no-op the EC ignores; if the 3 never lands we
        # have degenerated to a 255->255 write -- exactly the no-op that made
        # the 2026-08-30 recovery fail, reproduced one level down.
        pm_mid=$(cat "$VPC/powermode" 2>/dev/null || true)
        [[ "$pm_mid" == "3" ]] || echo "legion-fan-curve: WARN - powermode read back '${pm_mid:-<empty>}' after writing 3; the 3->255 cycle may be degenerate" >&2

        echo 255 > "$VPC/powermode"; sleep 2
        trap - EXIT INT TERM HUP QUIT
        unset -f _restore_pm
        # Re-normalise the override flags BEFORE the size re-check, not after.
        # The mode transition can disturb them, and lockfancontroller=1 FREEZES
        # the fans at their current PWM. Doing this after the `exit 1` below
        # would leave a failed repair with frozen fans on an uncapped curve --
        # strictly worse than the incident this path exists to fix. The drift
        # checker monitors neither flag, so nothing else would catch it.
        echo 0 > "$VPC/fan_fullspeed"
        echo 0 > "$VPC/lockfancontroller"

        SIZE=$(read_curve_size)
        if ! select_curve "$SIZE"; then
            echo "legion-fan-curve: size still '${SIZE:-<empty>}' after BOTH auto_points_size and a powermode cycle (want 9 or 10); refusing to write a partial curve" >&2
            exit 1
        fi
        echo "legion-fan-curve: EC curve grown back to size $SIZE via powermode cycle (auto_points_size was insufficient)"
    else
        echo "legion-fan-curve: EC curve grown back to size $SIZE via auto_points_size"
    fi
fi
N=${#TEMP[@]}
echo "legion-fan-curve: EC curve size=$SIZE → writing $N points (top = ${TEMP[$((N-1))]} °C / pwm ${PWM[$((N-1))]})"
for ((i=1; i<=N; i++)); do
    # HYST BEFORE TEMP, deliberately. Every knee in this curve moved DOWN, so
    # lowering the threshold first would leave the point transiently inverted
    # (old floor > new threshold) for one EC round-trip. The driver currently
    # range-checks only (0..127, no cross-field validation) so it would be
    # accepted -- but writing the floor first means the window does not exist,
    # and keeps us safe if a future driver adds validation, where `set -e` would
    # otherwise abort mid-loop on a half-written curve.
    #
    # NOTE ON CHANNELS: pwm1_* and pwm2_* here are NOT fan 1 and fan 2. Per
    # legion-laptop.c (enum FANCURVE_ATTR / autopoint_show) the TEMPERATURE
    # attributes are per-SENSOR: pwm1_=CPU, pwm2_=GPU, pwm3_=IC. Only
    # pwm{1,2}_auto_pointN_pwm are genuinely per-fan. We deliberately program
    # the same thresholds into the CPU and GPU channels. pwm3_ (IC) is NOT
    # written here -- see the IC CHANNEL note in the header.
    echo "${HYST[$((i-1))]}" > "$HWMON/pwm1_auto_point${i}_temp_hyst"   # CPU floor
    echo "${TEMP[$((i-1))]}" > "$HWMON/pwm1_auto_point${i}_temp"        # CPU threshold
    echo "${PWM[$((i-1))]}"  > "$HWMON/pwm1_auto_point${i}_pwm"         # fan 1 speed
    echo "${HYST[$((i-1))]}" > "$HWMON/pwm2_auto_point${i}_temp_hyst"   # GPU floor
    echo "${TEMP[$((i-1))]}" > "$HWMON/pwm2_auto_point${i}_temp"        # GPU threshold
    echo "${PWM[$((i-1))]}"  > "$HWMON/pwm2_auto_point${i}_pwm"        # fan 2 speed
done

# 4. Verify the EC actually accepted the curve. The driver scales PWM writes
#    slightly (1-2 LSB rounding on this hardware), so allow ±3 absolute on
#    PWM readback; temps must match exactly. powermode must report EXACTLY
#    255. ⚠️ An earlier version of this comment said "3 (EC custom mode) or
#    255" -- that is WRONG for this sysfs attribute and directly invites
#    re-introducing the 2026-08-30 critical bug described at the check
#    itself below. read_powermode() runs ec_to_wmi_powermode(), so the
#    attribute reports WMI-space, where 3 = PERFORMANCE (the stock
#    overheating curve) and 255 = CUSTOM. EC-space 3 never reaches here.
# NOTE on the PPD race, deliberately NOT "fixed" with a sleep (2026-09-13):
# a powermode write emits a platform_profile notification, and PPD/powerdevil
# may counter-assert its own profile. An earlier version of this change slept 5 s
# and re-asserted 255 here. That was wrong twice over: (1) it wrote powermode
# AFTER the curve, inverting this script's own order and risking clobbering the
# curve we just programmed, and (2) the re-assert landed ~1 s before the verify
# below, so the powermode check passed BY CONSTRUCTION and could no longer
# detect the very drift it exists to detect. The 5 s was also sized against
# "PPD asserted a profile 13 s after boot" -- a BOOT-relative number, not a
# notify->react latency; it never measured what it was being used for.
# So: no sleep, no re-assert. The verify below is honest -- if PPD has already
# clobbered powermode we exit 1 (the boot/AC units retry and fire OnFailure;
# legion-profile-watch retries and alerts after 3 failures). A later drift is
# repaired by legion-profile-watch's 5 s poll, and legion-fan-curve-check.timer
# alerts on drift that persists for ~1 minute.

fail=0
for ((i=1; i<=N; i++)); do
    want_t="${TEMP[$((i-1))]}"
    want_h="${HYST[$((i-1))]}"
    want_p="${PWM[$((i-1))]}"
    for fan in 1 2; do
        chan=$( ((fan==1)) && echo CPU || echo GPU )
        got_t=$(cat "$HWMON/pwm${fan}_auto_point${i}_temp")
        got_h=$(cat "$HWMON/pwm${fan}_auto_point${i}_temp_hyst")
        got_p=$(cat "$HWMON/pwm${fan}_auto_point${i}_pwm")
        if [[ "$got_t" != "$want_t" ]]; then
            echo "legion-fan-curve: VERIFY FAIL ${chan}-channel point${i} temp: want=$want_t got=$got_t" >&2
            fail=1
        fi
        if [[ "$got_h" != "$want_h" ]]; then
            echo "legion-fan-curve: VERIFY FAIL ${chan}-channel point${i} temp_hyst: want=$want_h got=$got_h" >&2
            fail=1
        fi
        if (( got_h >= got_t )); then
            echo "legion-fan-curve: VERIFY FAIL ${chan}-channel point${i} INVERTED: hyst=$got_h >= temp=$got_t" >&2
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
if [[ "$pm" != "255" ]]; then
    # 2026-08-30: this used to accept 3 as well. It must NOT: legion-laptop.c
    # defines LEGION_WMI_POWERMODE_PERFORMANCE=3 and _CUSTOM=255, so powermode=3
    # is the STOCK overheating curve. Accepting it let this script print
    # "applied + verified" and exit 0 while the EC was on the stock curve --
    # firing no OnFailure alert and even clearing the FAILED flag.
    echo "legion-fan-curve: VERIFY FAIL powermode: want=255 (custom) got=$pm (3=performance/stock curve, 2=balanced, 1=quiet -- EC is NOT on our curve)" >&2
    fail=1
fi
if (( fail )); then
    echo "legion-fan-curve: verification failed — curve may not be in effect" >&2
    exit 1
fi

# Clear the OnFailure flag if a prior run set it.
rm -f /run/legion-fan-curve-FAILED 2>/dev/null || true

echo "legion-fan-curve: applied + verified. fan1_target=$(cat "$HWMON/fan1_target") fan2_target=$(cat "$HWMON/fan2_target") powermode=$pm"
