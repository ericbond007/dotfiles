#!/usr/bin/env bash
# Patches lenovolegionlinux-dkms source for Lenovo Legion 7 16ACHg6 (DMI 82N6,
# BIOS GKCN…). Three independent fixes; each is applied idempotently and the
# DKMS module is rebuilt if any change was made.
#
# Patch 1 — PNP0C09 → VPC2004 binding
#   The platform driver's primary ACPI alias is PNP0C09 (the EC), exclusively
#   owned by the kernel's built-in acpi-ec. Probe never fires. Upstream TODO
#   on that line says to switch to VPC2004 (the Ideapad VPC, child of EC).
#
# Patch 2 — model_v0 powermode access: WMI → EC
#   The WMI SetSmartFanMode call (method 44 on GUID 887B54E3…) silently maps
#   custom mode (255) to performance (1) on this firmware. Direct EC writes
#   honor the documented LEGION_EC_POWERMODE_CUSTOM=3 enum value.
#
# Patch 3 — ec_write_powermode validator: allow value 3
#   The driver's EC validator rejects value 3 (only accepts 0-2 and 255),
#   blocking custom-mode EC writes even on the EC access path. Bug.
#
# Without #2 and #3, the custom-curve path is dead on this hardware: writes
# land in EC RAM but the EC's powermode stays at 1, so it uses the stock
# performance curve (caps at PWM 114 ≈ 45% at 95°C — the original incident
# that motivated this whole investigation).

set -euo pipefail

shopt -s nullglob
sources=(/usr/src/lenovolegionlinux-*/legion-laptop.c)
if (( ${#sources[@]} == 0 )); then
    echo "legion-flattop-patches: no lenovolegionlinux source found, nothing to do" >&2
    exit 0
fi

patched_any=0

apply_patch1() {
    local src=$1
    if grep -q '{ "VPC2004", 0 }' "$src"; then return 0; fi
    if ! grep -q '{ "PNP0C09", 0 }' "$src"; then
        echo "legion-flattop-patches: WARNING patch1 — neither expected pattern in $src" >&2
        return 0
    fi
    sed -i 's|{ "PNP0C09", 0 },|{ "VPC2004", 0 },|' "$src"
    grep -q '{ "VPC2004", 0 }' "$src" || { echo "legion-flattop-patches: ERROR patch1 sed failed in $src" >&2; exit 1; }
    echo "legion-flattop-patches: applied patch1 (PNP0C09 → VPC2004) to $src"
    patched_any=1
}

apply_patch2() {
    local src=$1
    if awk '/^static const struct model_config model_v0 = \{/,/^\};/' "$src" | grep -q 'access_method_powermode = ACCESS_METHOD_EC,'; then
        return 0
    fi
    if ! awk '/^static const struct model_config model_v0 = \{/,/^\};/' "$src" | grep -q 'access_method_powermode = ACCESS_METHOD_WMI,'; then
        echo "legion-flattop-patches: WARNING patch2 — model_v0 lacks expected access_method_powermode line in $src" >&2
        return 0
    fi
    sed -i '/^static const struct model_config model_v0 = {/,/^};/ s|access_method_powermode = ACCESS_METHOD_WMI,|access_method_powermode = ACCESS_METHOD_EC,|' "$src"
    if ! awk '/^static const struct model_config model_v0 = \{/,/^\};/' "$src" | grep -q 'access_method_powermode = ACCESS_METHOD_EC,'; then
        echo "legion-flattop-patches: ERROR patch2 sed failed in $src" >&2
        exit 1
    fi
    echo "legion-flattop-patches: applied patch2 (model_v0 powermode WMI → EC) to $src"
    patched_any=1
}

apply_patch3() {
    local src=$1
    # Use # as sed delimiter because pattern contains || (would conflict with | delimiter)
    if grep -qF 'value >= 0 && value <= 3) || value == 255' "$src"; then return 0; fi
    if ! grep -qF 'value >= 0 && value <= 2) || value == 255' "$src"; then
        echo "legion-flattop-patches: WARNING patch3 — ec_write_powermode validator pattern not found in $src" >&2
        return 0
    fi
    sed -i 's#value >= 0 && value <= 2) || value == 255#value >= 0 \&\& value <= 3) || value == 255#' "$src"
    grep -qF 'value >= 0 && value <= 3) || value == 255' "$src" || { echo "legion-flattop-patches: ERROR patch3 sed failed in $src" >&2; exit 1; }
    echo "legion-flattop-patches: applied patch3 (ec_write_powermode allow EC value 3) to $src"
    patched_any=1
}

for src in "${sources[@]}"; do
    apply_patch1 "$src"
    apply_patch2 "$src"
    apply_patch3 "$src"
done

# Sanity check — verify legion-fan-curve.sh's sysfs probe paths are still
# discoverable in the upstream source. The script probes:
#   /sys/devices/platform/legion/       ← unconditional platform_device_register_simple("legion", ...)
#   /sys/bus/platform/devices/VPC2004:00/   ← ACPI alias bind (after our patch1)
# If neither registration pattern appears, upstream has restructured how the
# driver exposes its sysfs root and legion-fan-curve.service will silently
# break on next boot. Warn loudly here so it gets caught at upgrade time.
for src in "${sources[@]}"; do
    legion_dev=0; vpc_alias=0
    grep -qF 'platform_device_register_simple("legion"' "$src" && legion_dev=1
    grep -qF '{ "VPC2004", 0 }' "$src" && vpc_alias=1
    if (( legion_dev == 0 && vpc_alias == 0 )); then
        cat >&2 <<EOF
legion-flattop-patches: WARNING — neither known platform-device pattern in
  $src.
  Expected at least ONE of:
    platform_device_register_simple("legion", ...)   [stable upstream registration]
    { "VPC2004", 0 }                                  [acpi_device_id alias entry]
  legion-fan-curve.service probes /sys/devices/platform/legion/ and
  /sys/bus/platform/devices/VPC2004:00/. With neither pattern in the
  source, both probes will fail on next boot. Inspect the new source and
  add the new path to the probe list in
  /opt/services/legion-flattop/bin/legion-fan-curve.sh BEFORE rebooting.
EOF
    fi
done

if (( patched_any == 0 )); then
    echo "legion-flattop-patches: nothing to do, all patches present"
    exit 0
fi

# Rebuild for every installed kernel that has matching headers.
# `dkms install --force` alone reinstalls a cached .ko without rebuilding
# from the patched source, so unbuild then build explicitly.
for moddir in /lib/modules/*/build; do
    [[ -d "$moddir" ]] || continue
    kver=$(basename "$(dirname "$moddir")")
    for src in "${sources[@]}"; do
        ver=$(basename "$(dirname "$src")")
        ver=${ver#lenovolegionlinux-}
        echo "legion-flattop-patches: dkms unbuild+build+install lenovolegionlinux/$ver -k $kver"
        dkms unbuild "lenovolegionlinux/$ver" -k "$kver" >/dev/null 2>&1 || true
        dkms build   "lenovolegionlinux/$ver" -k "$kver" || \
            { echo "legion-flattop-patches: WARNING dkms build failed for $kver" >&2; continue; }
        dkms install --force "lenovolegionlinux/$ver" -k "$kver" || \
            echo "legion-flattop-patches: WARNING dkms install failed for $kver" >&2
    done
done
