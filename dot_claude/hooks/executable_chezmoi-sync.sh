#!/usr/bin/env bash
# SessionEnd hook: auto-commit any pending chezmoi source changes, push to
# origin, then ssh to peer hosts and run `chezmoi update` so every machine
# converges on the same state.
#
# All output is logged to ~/.claude/hooks/chezmoi-sync.log.
# SSH per-host has a timeout so a down host can't hang session teardown.

set -u

LOG=~/.claude/hooks/chezmoi-sync.log
exec >>"$LOG" 2>&1

printf '\n=== SessionEnd sync at %s on %s ===\n' "$(date -Iseconds)" "$(hostname)"

src=$(chezmoi source-path 2>/dev/null) || { echo 'no chezmoi source-path'; exit 0; }
[ -z "$src" ] && { echo 'empty chezmoi source-path'; exit 0; }

cd "$src" || { echo "cannot cd $src"; exit 0; }

# 1. Commit any uncommitted changes (includes re-added files from PostToolUse).
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    git add -A
    files=$(git diff --cached --name-only | head -5 | paste -sd, -)
    extra=""
    total=$(git diff --cached --name-only | wc -l)
    [ "$total" -gt 5 ] && extra=" (+$((total - 5)) more)"
    msg="Auto-sync from $(hostname): $files$extra"
    echo "committing: $msg"
    git commit -m "$msg" || echo "commit failed"
else
    echo 'no local changes to commit'
fi

# 2. Push if ahead of origin.
ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
if [ "$ahead" != "0" ] && [ -n "$ahead" ]; then
    echo "pushing $ahead commit(s) to origin"
    git push origin HEAD || echo 'push failed'
else
    echo 'nothing to push'
fi

# 3. Tell peer hosts to pull and apply. Skip self.
self=$(hostname)
for h in serp wanda flattop; do
    [ "$h" = "$self" ] && continue
    echo "--- $h ---"
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" 'chezmoi update 2>&1 | tail -20' \
        || echo "[$h] sync failed or timed out"
done

echo 'done'
