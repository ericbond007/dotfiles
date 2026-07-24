---
description: Push chezmoi source changes to GitHub and pull+apply on every host in the sync script's current peer array. Requires a clean working tree — commit first.
---

Run the fleet sync script and show the output verbatim so I can verify each step:

```bash
~/.claude/hooks/chezmoi-sync.sh
```

If the script errors because of uncommitted changes, stop and show me the dirty working tree. Don't silently commit on my behalf. After a successful run, tell me which hosts updated cleanly and which (if any) had issues.
