#!/usr/bin/env bash
# Periodic health check for the Legion custom fan curve (2026-08-30).
#
# WHY: legion-fan-curve-alert.sh only fires as OnFailure= of the curve units --
# i.e. only when a unit EXITS NONZERO. The failure mode that actually keeps
# burning us is SILENT STATE DRIFT, where every unit reports success and the EC
# ends up on the stock curve anyway:
#   2026-08-28 17:21  PPD asserted a profile 13 s after boot -> powermode=3.
#                     No unit failed. No alert. 28 min at 86 C.
#   2026-08-30 16:22  powerdevil re-asserted "performance" after a resume.
#                     No unit failed. No alert. 47 min at 90 C.
#
# ALERT-ONLY: this checker never re-asserts the curve itself. Since 2026-10-09
# the REPAIR lives in legion-profile-watch (a daemon that re-applies the curve
# after every power-profile change and whenever its 5 s poll sees powermode or
# curve-shape drift; every run is logged: journalctl -u legion-profile-watch).
# It also raises its own alert when the curve keeps getting undone with no
# profile change, which this sampling cannot see if any one sample reads 255.
# A drift it repairs inside the sampling window below never reaches this checker -- a
# deliberate trade: routine profile switches were producing critical popups
# that read as "the service failed". This checker is for the drift the daemon
# did NOT fix, and for the daemon itself being down.
#
# EVIDENCE DISCIPLINE: "I cannot read the instrument" is reported as exactly
# that -- never as a thermal finding. An earlier version of this script mapped
# an unreadable debugfs file to "curve top point pwm=0 -> NO full-speed cap",
# telling Dave his fans were unsafe when the truth was only that a file was
# missing.
#
# WHAT IS CHECKED (2026-10-09):
#   * powermode must be 255 under EVERY power profile. Lenovo's own curves are
#     not safe to accept: stock performance (3) caps fans at PWM 114 (~45%),
#     and quiet (1, what power-saver selects) holds PWM 89 from 78 C up to
#     127 C (captured 2026-10-09). A profile-aware variant that accepted
#     quiet/balanced lived for ~1 h on 2026-10-09 and was reverted on review.
#   * the custom curve's shape: size 9/10 and a top point of ~255 PWM @ ~100 C
#     on BOTH fan channels (worse of each pair), read from hwmon -- live EC
#     reads that log nothing. Until 2026-10-09 this read debugfs fancurve,
#     every read of which logged ACPI/WMI errors to the kernel ring.
#   * DEGRADED (normal urgency): legion-profile-watch not active, or its
#     heartbeat file older than 60 s (a wedged daemon still reads "active";
#     the daemon also withholds its heartbeat while a repair run has been
#     stuck for over 150 s).
#   * NOTICE (normal urgency): plugged in but the power profile is not
#     performance. 2026-10-08 the CPU was found boost-locked at 3.2 GHz on
#     mains, PPD on power-saver since a 2026-10-06 unplug, with every unit
#     green -- powerdevil's in-memory AC profile had gone blank, so replug never
#     restored performance. (PPD does not log profile changes; the scx_loader
#     log shows none in between.)
#
# SAMPLING: one bad reading is not an alert. Every finding -- problem,
# unreadable instrument, degraded or notice -- must persist for all
# SAMPLES readings, SAMPLE_GAP seconds apart (~60 s); one clean reading ends
# the run silently. That covers the daemon's repair (<=5 s poll + 4 s quiet +
# the write: ~10 s, ~15 s when the EC needs the powermode cycle, longer with
# retries) and powerdevil switching the profile ~1 s after AC comes online,
# without letting a real
# drift hide: a fixed second sample could land inside the NEXT change's repair.
#
# SELF-TEST: `legion-fan-curve-check.sh --self-test` drives evaluate(),
# decide(), parse_profile and worst_of with fixed known-good and known-bad inputs and
# exits non-zero on any mismatch. It reads no sysfs and writes no flag file or
# notification.

set -uo pipefail

TAG=legion-fan-curve-drift          # distinct from legion-fan-curve-alert so a
                                    # log watcher can tell drift from unit failure
FLAG=/run/legion-fan-curve-DRIFT
WATCHER=legion-profile-watch.service
HEARTBEAT=/run/legion-profile-watch.heartbeat
HEARTBEAT_MAX_AGE=60
SAMPLES=12
SAMPLE_GAP=5
REPAIR_FIX="sudo systemctl restart legion-profile-watch.service"

problems=(); unverifiable=(); degraded=(); notices=()

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# evaluate MODE SIZE TOP_PWM TOP_TEMP PROFILE AC WATCH_STATE
# Pure: decides only from its arguments (empty string = could not read) and
# fills problems[] / unverifiable[] / degraded[] / notices[].
# WATCH_STATE is "active" when the daemon is up AND its heartbeat is fresh.
evaluate() {
    local mode=$1 size=$2 top_pwm=$3 top_temp=$4 profile=$5 ac=$6 watch=$7 d
    problems=(); unverifiable=(); degraded=(); notices=()

    if [[ -z "$mode" ]]; then
        unverifiable+=("powermode: unreadable (legion module not loaded yet?)")
    elif [[ "$mode" != "255" ]]; then
        problems+=("powermode=$mode under the ${profile:-unknown} profile (want 255=custom; 3=stock performance curve, 2=balanced, 1=quiet)")
    else
        if [[ -z "$size" ]]; then
            unverifiable+=("curve size: unreadable")
        elif [[ "$size" != "10" && "$size" != "9" ]]; then
            problems+=("EC curve size=$size (want 9 or 10; a collapsed curve drops the high-temp ramp)")
        fi
        # Top point must still carry the full-speed cap. Same +/-3 tolerance the
        # writer uses: the driver round-trips PWM through an RPM-hundreds unit,
        # so an exact compare would false-alarm on a 1% skew. Non-numeric
        # fields are an unreadable instrument, not a finding -- and must not
        # reach (( )), which would abort the script under `set -u`.
        if ! is_uint "$top_pwm" || ! is_uint "$top_temp"; then
            unverifiable+=("curve top point: hwmon pwm{1,2}_auto_point*_{pwm,temp} unreadable or unparseable")
        else
            d=$(( top_pwm - 255 )); (( d < 0 )) && d=$(( -d ))
            (( d > 3 )) && problems+=("curve top point pwm=$top_pwm (want ~255: the full-speed cap at high temp)")
            d=$(( top_temp - 100 )); (( d < 0 )) && d=$(( -d ))
            (( d > 3 )) && problems+=("curve top point cpu_max_temp=$top_temp (want ~100)")
        fi
    fi

    if [[ "$watch" != "active" ]]; then
        degraded+=("$WATCHER is ${watch:-unknown}: power-profile changes are not being repaired")
    fi

    if [[ "$ac" == "1" && -n "$profile" && "$profile" != "performance" ]]; then
        notices+=("plugged in but the power profile is $profile")
    fi
}

# decide PROFILE: turn the finding arrays into TITLE / BODY / URGENCY / PRIO.
# Pure, so the self-test pins which findings may raise a CRITICAL popup.
decide() {
    local profile=$1
    if (( ${#problems[@]} )); then
        TITLE="Legion fan curve not applied"
        BODY="${problems[0]}. Auto-repair did not fix it. Fix: $REPAIR_FIX"
        URGENCY=critical; PRIO=user.err
    elif (( ${#unverifiable[@]} )); then
        TITLE="Legion fan curve: cannot verify"
        BODY="Health check could not read its instruments. This is NOT itself a thermal fault."
        URGENCY=critical; PRIO=user.err
    elif (( ${#degraded[@]} )); then
        TITLE="Fan-curve auto-repair is not running"
        BODY="The fan curve is fine right now, but power-profile changes will not be repaired. Fix: $REPAIR_FIX"
        URGENCY=normal; PRIO=user.warning
    else
        TITLE="Power profile is not Performance"
        BODY="Plugged in, but the power profile is $profile."
        [[ "$profile" == "power-saver" ]] && BODY+=" CPU boost is off in power-saver."
        BODY+=" Pick Performance in the battery applet if that was not on purpose."
        URGENCY=normal; PRIO=user.warning
    fi
}

# worst_of A B TARGET: whichever of A/B is farther from TARGET (A on a tie);
# empty if either is not a plain integer (an unreadable instrument).
worst_of() {
    local a=$1 b=$2 t=$3 da db
    is_uint "$a" && is_uint "$b" || return 0
    da=$(( a - t )); (( da < 0 )) && da=$(( -da ))
    db=$(( b - t )); (( db < 0 )) && db=$(( -db ))
    if (( db > da )); then echo "$b"; else echo "$a"; fi
}

# parse_profile: `busctl call ... Properties Get` output on stdin -> profile.
parse_profile() {
    sed -nE 's/^v s "(.*)"$/\1/p'
}

# gather: read the live state into MODE SIZE TOP_PWM TOP_TEMP PROFILE AC WATCH.
gather() {
    local vpc="" hwmon="" cand state hb age
    MODE=""; SIZE=""; TOP_PWM=""; TOP_TEMP=""; PROFILE=""; AC=""; WATCH=""

    # Resolve the sysfs bind the same way legion-fan-curve.sh does --
    # ideapad_acpi can grab the ACPI alias first, putting the attributes on the
    # legacy path.
    for cand in /sys/devices/platform/legion /sys/bus/platform/devices/VPC2004:00; do
        [[ -r "$cand/powermode" ]] && { vpc="$cand"; break; }
    done
    for cand in /sys/class/hwmon/hwmon*; do
        [[ -r "$cand/auto_points_size" ]] && { hwmon="$cand"; break; }
    done
    [[ -n "$vpc" ]] && MODE=$(cat "$vpc/powermode" 2>/dev/null || true)
    [[ -n "$hwmon" ]] && SIZE=$(cat "$hwmon/auto_points_size" 2>/dev/null || true)

    # Only the custom curve is shape-checked. Both fan channels: a write can
    # change one without the other. Each pair is reduced to its worse value.
    if [[ "$MODE" == "255" && -n "$hwmon" ]] && is_uint "$SIZE"; then
        local p1 t1 p2 t2
        p1=$(cat "$hwmon/pwm1_auto_point${SIZE}_pwm" 2>/dev/null || true)
        t1=$(cat "$hwmon/pwm1_auto_point${SIZE}_temp" 2>/dev/null || true)
        p2=$(cat "$hwmon/pwm2_auto_point${SIZE}_pwm" 2>/dev/null || true)
        t2=$(cat "$hwmon/pwm2_auto_point${SIZE}_temp" 2>/dev/null || true)
        TOP_PWM=$(worst_of "$p1" "$p2" 255)
        TOP_TEMP=$(worst_of "$t1" "$t2" 100)
    fi

    # `call ... Properties.Get` rather than `get-property`: busctl applies
    # --auto-start=no only to call/emit, and a health check must never
    # D-Bus-activate PPD (its startup writes a profile, i.e. the very powermode
    # change this watches for).
    PROFILE=$(busctl --system --auto-start=no --timeout=5 call \
        org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles \
        org.freedesktop.DBus.Properties Get ss \
        org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null | parse_profile)
    AC=$(cat /sys/class/power_supply/ADP0/online 2>/dev/null || true)

    state=$(systemctl is-active "$WATCHER" 2>/dev/null || true)
    if [[ "$state" != "active" ]]; then
        WATCH=${state:-unknown}
    elif ! hb=$(stat -c %Y "$HEARTBEAT" 2>/dev/null); then
        WATCH="active but has no heartbeat file"
    else
        age=$(( $(date +%s) - hb ))
        if (( age > HEARTBEAT_MAX_AGE )); then
            # No age in this string: it feeds the alert de-dup key, and a
            # number that grows every run would re-alert every 2 minutes.
            WATCH="active but its heartbeat is stale (over ${HEARTBEAT_MAX_AGE}s; wedged?)"
        else
            WATCH=active
        fi
    fi
}

self_test() {
    local fails=0 want got
    _verdict() {
        if [[ "$1" == "$2" ]]; then
            printf 'ok    %-14s <= %s\n' "$1" "$3"
        else
            printf 'FAIL  want=%s got=%s <= %s\n' "$1" "$2" "$3"
            fails=$(( fails + 1 ))
        fi
    }
    check() {
        want=$1; shift
        evaluate "$@"
        got=ok
        (( ${#notices[@]} )) && got=notice
        (( ${#degraded[@]} )) && got=degraded
        (( ${#unverifiable[@]} )) && got=unverifiable
        (( ${#problems[@]} )) && got=problem
        _verdict "$want" "$got" "$*"
    }
    # Each known-bad fixture carries exactly ONE defect, so deleting any single
    # check makes at least one fixture fail; boundaries pin the +/-3 tolerance.
    #     want          mode size pwm  temp profile      ac watcher
    check ok            255  10   255  100  performance  1  active    # the normal state
    check ok            255  9    252  97   performance  1  active    # size 9; tolerance edge -3
    check ok            255  10   258  103  performance  0  active    # tolerance edge +3; on battery
    check ok            255  10   255  100  power-saver  0  active    # Dave's power-saver, on battery
    check ok            255  10   255  100  ""           1  active    # PPD not running: no notice
    check ok            255  10   255  100  power-saver  ""  active   # AC unreadable: no notice
    check notice        255  10   255  100  power-saver  1  active    # 2026-10-08: boost-locked on mains
    check notice        255  10   255  100  balanced     1  active
    check problem       3    10   ""   ""   performance  1  active    # 2026-10-09 17:31: stock curve
    check problem       1    8    ""   ""   power-saver  0  active    # Lenovo quiet: PWM 89 to 127 C
    check problem       2    9    ""   ""   balanced     0  active
    check problem       3    10   ""   ""   ""           0  active    # PPD unreadable: still strict
    # Mode as the ONLY defect (otherwise a broken mode check can hide behind
    # the size/top-point checks of the same fixture).
    check problem       3    10   255  100  performance  1  active
    check problem       2    10   255  100  balanced     0  active
    check problem       1    10   255  100  power-saver  0  active
    check problem       255  8    255  100  performance  1  active    # size only
    check problem       255  10   251  100  performance  1  active    # pwm just outside tolerance
    check problem       255  10   259  100  performance  1  active
    check problem       255  10   255  96   performance  1  active    # temp just outside tolerance
    check problem       255  10   255  104  performance  1  active
    check degraded      255  10   255  100  performance  1  inactive  # repair daemon down
    check degraded      255  10   255  100  performance  1  ""
    check degraded      255  10   255  100  performance  1  "active but its heartbeat is stale (over 60s; wedged?)"
    check unverifiable  ""   ""   ""   ""   performance  1  active
    check unverifiable  255  ""   255  100  performance  1  active
    check unverifiable  255  10   ""   ""   performance  1  active    # top point unreadable
    check unverifiable  255  10   x7   100  performance  1  active    # garbage must not abort

    # decide(): which findings may raise a CRITICAL popup.
    pick() {
        local want=$1 label=$2; shift 2
        evaluate "$@"; decide "$5"
        _verdict "$want" "$URGENCY" "decide: $label"
    }
    pick critical "stock curve"            3   10 ""  ""  performance 1 active
    pick critical "unreadable instrument"  ""  "" ""  ""  performance 1 active
    pick normal   "daemon down, curve ok"  255 10 255 100 performance 1 inactive
    pick normal   "power-saver on AC"      255 10 255 100 power-saver 1 active
    pick critical "stock curve + notice"   3   10 ""  ""  power-saver 1 active
    pick critical "stock curve + daemon down" 3 10 "" ""  performance 1 inactive
    evaluate 255 10 255 100 performance 1 inactive; decide performance
    _verdict "Fan-curve auto-repair is not running" "$TITLE" "decide: daemon-down title"
    evaluate 255 10 255 100 power-saver 1 active; decide power-saver
    _verdict "Power profile is not Performance" "$TITLE" "decide: notice title"
    evaluate 255 10 255 100 balanced 1 active; decide balanced
    [[ "$BODY" == *boost* ]] && got=mentions-boost || got=no-boost
    _verdict no-boost "$got" "decide: balanced notice must not claim boost is off"
    evaluate 255 10 255 100 power-saver 1 active; decide power-saver
    [[ "$BODY" == *boost* ]] && got=mentions-boost || got=no-boost
    _verdict mentions-boost "$got" "decide: power-saver notice says boost is off"

    # worst_of: the reduction gather() applies to each fan pair.
    _verdict "150" "$(worst_of 255 150 255)" "worst_of: fan 2 off, fan 1 fine -> 150"
    _verdict "251" "$(worst_of 251 254 255)" "worst_of: farther of two"
    _verdict "96"  "$(worst_of 100 96 100)"  "worst_of: temperature pair"
    _verdict ""    "$(worst_of 255 x 255)"   "worst_of: unreadable -> empty"
    _verdict ""    "$(worst_of "" 255 255)"  "worst_of: missing -> empty"
    _verdict "performance" "$(parse_profile <<<'v s "performance"')" "parse_profile performance"
    _verdict "power-saver" "$(parse_profile <<<'v s "power-saver"')" "parse_profile power-saver"
    _verdict ""        "$(parse_profile </dev/null)" "parse_profile empty input"

    if (( fails )); then echo "self-test: $fails FAILED"; return 1; fi
    echo "self-test: all passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
fi

for (( i = 1; i <= SAMPLES; i++ )); do
    gather
    evaluate "$MODE" "$SIZE" "$TOP_PWM" "$TOP_TEMP" "$PROFILE" "$AC" "$WATCH"
    if (( ${#problems[@]} + ${#unverifiable[@]} + ${#degraded[@]} + ${#notices[@]} == 0 )); then
        rm -f "$FLAG" 2>/dev/null || true
        exit 0
    fi
    (( i < SAMPLES )) && sleep "$SAMPLE_GAP"     # see SAMPLING above
done

SUMMARY=""
(( ${#problems[@]} ))     && SUMMARY+="NOT ACTIVE: $(printf '%s; ' "${problems[@]}")"
(( ${#unverifiable[@]} )) && SUMMARY+="CANNOT VERIFY: $(printf '%s; ' "${unverifiable[@]}")"
(( ${#degraded[@]} ))     && SUMMARY+="DEGRADED: $(printf '%s; ' "${degraded[@]}")"
(( ${#notices[@]} ))      && SUMMARY+="NOTICE: $(printf '%s; ' "${notices[@]}")"
decide "$PROFILE"

# De-duplicate: alert once per distinct condition, not every 2 min. Without this
# a 47-minute drift produced ~23 identical critical popups (KDE critical
# notifications do not auto-expire) and ~23 journal lines.
KEY=$(printf '%s' "$SUMMARY" | md5sum | cut -d' ' -f1)
PREV=$(head -1 "$FLAG" 2>/dev/null || true)
printf '%s\n%s at %s\n' "$KEY" "$SUMMARY" "$(date -Is)" > "$FLAG" 2>/dev/null || true
chmod 0644 "$FLAG" 2>/dev/null || true
[[ "$PREV" == "$KEY" ]] && exit 0

logger -t "$TAG" -p "$PRIO" -- "legion fan curve $SUMMARY"

# One popup per USER, not per session: loginctl lists several sessions for the
# same uid (manager, ttys, ptys), and KDE critical popups do not expire.
for bus in /run/user/*/bus; do
    [[ -S "$bus" ]] || continue
    rdir=${bus%/bus}
    user=$(id -nu "${rdir##*/}" 2>/dev/null) || continue
    timeout 10 runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="$rdir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
        notify-send --urgency="$URGENCY" --app-name=legion-fan-curve "$TITLE" "$BODY" \
        2>/dev/null || true
done

exit 0
