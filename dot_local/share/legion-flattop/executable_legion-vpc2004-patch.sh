#!/usr/bin/env bash
# Patches lenovolegionlinux-dkms source so the platform driver matches VPC2004
# (the Ideapad VPC) instead of PNP0C09 (the EC, exclusively owned by acpi-ec).
# The latter prevents .probe from ever being called on Lenovo Legions whose EC
# is bound by the kernel's built-in acpi-ec driver. Upstream TODO at the line
# we rewrite acknowledges this. See: github.com/johnfanv2/LenovoLegionLinux
set -euo pipefail

shopt -s nullglob
sources=(/usr/src/lenovolegionlinux-*/legion-laptop.c)
if (( ${#sources[@]} == 0 )); then
    echo "legion-vpc2004-patch: no lenovolegionlinux source found, nothing to do" >&2
    exit 0
fi

patched_any=0
for src in "${sources[@]}"; do
    if grep -q '{ "VPC2004", 0 }' "$src"; then
        echo "legion-vpc2004-patch: $src already patched, skipping"
        continue
    fi
    if ! grep -q '{ "PNP0C09", 0 }' "$src"; then
        echo "legion-vpc2004-patch: WARNING $src has neither expected pattern; upstream may have changed shape, leaving alone" >&2
        continue
    fi
    sed -i 's|{ "PNP0C09", 0 },|{ "VPC2004", 0 },|' "$src"
    if ! grep -q '{ "VPC2004", 0 }' "$src"; then
        echo "legion-vpc2004-patch: ERROR sed did not produce expected result in $src" >&2
        exit 1
    fi
    echo "legion-vpc2004-patch: rewrote PNP0C09 -> VPC2004 in $src"
    patched_any=1
done

if (( patched_any == 0 )); then
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
        echo "legion-vpc2004-patch: dkms unbuild+build+install lenovolegionlinux/$ver -k $kver"
        dkms unbuild "lenovolegionlinux/$ver" -k "$kver" >/dev/null 2>&1 || true
        dkms build   "lenovolegionlinux/$ver" -k "$kver" || \
            { echo "legion-vpc2004-patch: WARNING dkms build failed for $kver" >&2; continue; }
        dkms install --force "lenovolegionlinux/$ver" -k "$kver" || \
            echo "legion-vpc2004-patch: WARNING dkms install failed for $kver" >&2
    done
done
