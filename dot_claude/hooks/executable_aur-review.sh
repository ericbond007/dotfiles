#!/usr/bin/env bash
# aur-review.sh — PreToolUse(Bash) guard for AUR package installs/upgrades.
#
# Why: AUR PKGBUILDs run arbitrary maintainer code at build AND install time.
# The 2026-06-11 AUR campaign landed malware through ~500 packages, largely via
# UPDATES, not just fresh installs. This hook forces one deliberate read of the
# PKGBUILD (and its .install hooks + sources) before any yay/paru/makepkg
# build-or-install executes — catching a compromise before it lands.
#
# Mechanism: block (exit 2) the first attempt and tell Claude to fetch the
# PKGBUILD non-destructively first (`yay -G <pkg>`), review it, then re-run the
# install prefixed with `env AUR_OK=1 ` (works in fish AND bash), which this
# hook passes through untouched. Mirrors blast-radius.sh's block-once idiom.
#
# Scope: gates installs (`-S <pkg>`) AND upgrades (bare `yay`/`paru`, `-Su`,
# `-Syu`, `-Sua`) plus `makepkg` builds. Read-only ops (search/info/print/query,
# and crucially `-G`/--getpkgbuild, the review-fetch itself) pass through.
# Official-repo `pacman -S` is NOT gated — those aren't AUR PKGBUILDs.
set -u

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

# Operator already reviewed the PKGBUILD — pass through.
case "$cmd" in *AUR_OK=1*) exit 0 ;; esac

# Does the command even mention an AUR helper or makepkg? Cheap fast-path out.
printf '%s' "$cmd" | grep -qE '\b(yay|paru|makepkg)\b' || exit 0

# Match yay/paru/makepkg only in COMMAND POSITION — start of a command, not as a
# word inside a string, comment, or path argument. Command position = start of
# line, or right after a separator: ; & | or a `$(` command-substitution,
# optionally via `sudo `. A BARE `(` is deliberately NOT a separator — it shows
# up in prose like `echo "none (yay config inert)"` and would false-trip. This
# still catches `foo && yay -S bar`, `yes | yay -S foo`, and `$(yay -S x)`,
# while passing `echo "=== paru config ==="` and `cat ~/.config/paru/paru.conf`.
PFX='(^|[;&|]|[$][(])[[:space:]]*(sudo[[:space:]]+)?'

# Build/install/upgrade signatures (any one trips the guard):
#   -Su / -Syu / -Sua ...   any -S cluster containing 'u' (sysupgrade)
#   -S <targets>            plain sync install (-S then space/end)
#   bare `yay`/`paru`       full upgrade, or `yay <target>` (first arg not a flag)
#   makepkg build/install   bare, or a -flag cluster with i/s/f, or --install
blocked=0
printf '%s' "$cmd" | grep -qE "${PFX}(yay|paru)[[:space:]]+-S[a-z]*u"                 && blocked=1
printf '%s' "$cmd" | grep -qE "${PFX}(yay|paru)[[:space:]]+-S([[:space:]]|$)"         && blocked=1
printf '%s' "$cmd" | grep -qE "${PFX}(yay|paru)([[:space:]]*$|[[:space:]]+[^-[:space:]])" && blocked=1
printf '%s' "$cmd" | grep -qE "${PFX}makepkg([[:space:]]*$|[[:space:]]+(-[a-z]*[isf][a-z]*|--install|--syncdeps))" && blocked=1
[ "$blocked" -eq 1 ] || exit 0

{
  echo "AUR-REVIEW GUARD: this command builds/installs/upgrades AUR packages,"
  echo "which run arbitrary maintainer code from the PKGBUILD."
  echo "Command: $cmd"
  echo
  echo "Before letting it run, inspect the PKGBUILD(s) WITHOUT building:"
  echo "  yay -G <pkg>      # clones PKGBUILD + sources into ./<pkg>/ (no build)"
  echo "  # then Read: PKGBUILD, *.install, and any local source files."
  echo
  echo "Look for: curl|wget piped to sh/bash, base64/eval/obfuscated blobs,"
  echo "unexpected network fetches, suspicious prepare()/build()/package() or"
  echo "post-install hooks, sources pointing off the upstream project, and names"
  echo "on the 2026-06-11 infected list. For an UPGRADE, review the PKGBUILD diff."
  echo
  echo "If it is clean and you intend to proceed, re-run prefixed with: env AUR_OK=1"
  echo "If anything looks off, STOP and ask Dave."
} >&2
exit 2
