#!/usr/bin/env bash
# Manually-invoked fleet sync for chezmoi.
#
# Run AFTER you've reviewed and committed your chezmoi source changes.
# This script does NOT auto-commit — it expects a clean working tree.
# It pushes to origin, then tells each peer host to `chezmoi update`.
#
# Safe to re-run: no-ops if nothing to push, surfaces any peer errors.

set -u

self=$(hostname -s)
# LAN-only names. The bare `serp` and `living-pi` hostnames resolve to
# the WAN IP (router/dropbear) via DNS — `serpentii` and 10.0.0.10 force
# the LAN path so we sync the actual boxes, not the gateway.
peers=(serpentii wanda flattop 10.0.0.10)

printf '=== chezmoi fleet sync from %s at %s ===\n' "$self" "$(date -Iseconds)"

src=$(chezmoi source-path 2>/dev/null) || { echo 'error: no chezmoi source-path'; exit 1; }
cd "$src" || { echo "error: cannot cd $src"; exit 1; }

# 1. Refuse to proceed if working tree is dirty — user should commit first.
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo 'error: uncommitted changes in chezmoi source. Commit them first, then re-run.'
    git status --short
    exit 1
fi

# 2. Fetch + push if ahead.
git fetch --quiet origin
ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
behind=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)

if [ "$behind" != "0" ]; then
    echo "warning: local is $behind commit(s) behind origin. Pull/rebase before pushing."
    exit 1
fi

if [ "$ahead" != "0" ]; then
    echo "pushing $ahead commit(s) to origin..."
    git push origin HEAD || { echo 'error: push failed'; exit 1; }
else
    echo 'already up to date with origin'
fi

# 3. Tell each peer host to pull and apply. Skip self.
for h in "${peers[@]}"; do
    if [ "$h" = "$self" ]; then
        continue
    fi
    printf '\n--- %s ---\n' "$h"
    if ! timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" 'chezmoi update'; then
        printf '[%s] update failed or timed out\n' "$h"
    fi
done

printf '\n=== sync complete ===\n'
