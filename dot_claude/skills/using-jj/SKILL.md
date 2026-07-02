---
name: using-jj
description: >-
  Use when working in a repo that uses jj (Jujutsu) colocated with git — you'll
  see both a .git/ and a .jj/ directory. Covers the daily command set, the
  git→jj mental-model translation (bookmark ≈ branch, working copy is always a
  commit), the GitHub round-trip (jj git push/fetch), and the discipline that
  prevents lost work: spawn your own `jj workspace` before editing in a repo
  with concurrent sessions, and `jj new` right after describe+push. Trigger
  whenever Dave mentions jj/jujutsu, bookmarks, `jj edit`/`jj new`/`jj describe`,
  or you're about to branch/commit/push in a colocated jj repo (hoosierTrail,
  jailBird, …) and would otherwise reach for git checkout/stash/worktree.
---

# Using jj (Jujutsu) colocated with git

Several fleet repos use **jj colocated with git** — `.git/` and `.jj/` coexist in the same folder. Both tools work, but **jj is the preferred interface**: it lets you switch between branches in-place without stash/worktree juggling, and operations are reversible. GitHub still works normally — `jj git push` / `jj git fetch` round-trip to `origin`.

If a repo has its own jj notes in its `CLAUDE.md` (e.g. project-specific bookmark names, long-lived workspaces, a colocated-worktree layout), **that overrides this skill** — read it first.

## Daily commands

| Goal | Command |
|------|---------|
| Where am I | `jj log` (recent) / `jj log -r 'all()'` (everything) |
| Working-copy diff | `jj st` / `jj diff --summary` |
| Switch to a branch in-place (no stash) | `jj edit <bookmark-or-rev>` |
| Start a new change off current | `jj new` |
| Start a new change off master | `jj new master` |
| Describe the working copy | `jj describe -m "feat(x): ..."` |
| Move a bookmark to current change | `jj bookmark set <name> -r @` (`--allow-backwards` to go back) |
| Create a bookmark | `jj bookmark create <name> -r @` |
| Push a bookmark | `jj git push --bookmark <name>` — new bookmarks push by default on the fleet's jj 0.40; there is NO `--allow-new` flag (it errors with "unexpected argument") |
| Fetch | `jj git fetch` |
| Rebase a branch onto another | `jj rebase -b <bookmark> -d <dest>` |
| Undo anything | `jj op log` then `jj op restore <op-id>` |

## Mental model (from git)

- **Bookmark ≈ branch** — a named pointer to a commit. `jj git push --bookmark feat/x` ≈ `git push origin feat/x`.
- **The working copy is always a commit.** jj auto-snapshots your edits into a "working-copy commit" continuously. When you `jj edit <other>`, the previous working-copy commit stays on its branch automatically — **no stash needed.**
- **Conflicts are first-class.** A change can carry unresolved conflicts and still be committed; `jj st` shows them, `jj resolve` runs the merge tool.
- **Operations are reversible.** `jj op log` records every operation; `jj op restore` undoes anything. There is essentially no "lost work" failure mode — *except* the concurrent-workspace trap below.

## ⚠️ Workspace discipline — the #1 way to lose work

In a repo with **concurrent Claude sessions** sharing one `.jj/` store, the **default workspace** (the one with `.git/` colocated) shares a single `@`. When one session runs `jj edit <bookmark>` or `jj new <commit>`, the on-disk files swap out from under every other session in that workspace — in-progress edits silently revert. This has burned hours.

**Before any code-edit work, spawn your own workspace:**

```bash
jj workspace add ../<repo>-<task-name> -r <base-bookmark-or-master>
cd ../<repo>-<task-name>
# edit, run dev/verify, push, PR — each workspace has its own @
```

Cleanup when the branch lands:

```bash
jj workspace forget <task-name>
rm -rf ../<repo>-<task-name>
```

Do **not** use the Agent tool's `isolation: "worktree"` flag for this — it forks from the wrong commit. Use a real `jj workspace`.

## Sequencing gotchas

- **`jj new` right after describe+push.** After `jj describe -m "..."` + `jj git push`, immediately `jj new`. Otherwise your next edits *amend the described commit*, and the next `jj describe` eats its message. Describe → push → `jj new` is the rhythm.
- **Name + push the bookmark early.** `jj bookmark create` + push *before* the first edit. Unanchored WIP in a shared store gets stepped on by parallel sessions.
- **Verify the working set before branching.** jj auto-snapshots continuously, so stray files leak into a PR. `jj diff --summary` must list exactly the intended files before you set a bookmark and push — this is the backstop that catches a stray script riding a snapshot into a CI gate.
- **Rebase long-lived branches before merge.** `jj git fetch` then `jj rebase -b <feat> -d master` at the primary checkout, and verify on the rebased tip — text-merge hides semantic conflicts that a rebase-then-verify exposes.

## What NOT to do

- **Don't `git checkout` / `git reset --hard` / `git stash`** while a jj working copy is dirty — it desyncs the colocated state. If you must drive git directly, `jj abandon` or `jj squash` first to make the working copy a clean commit.
- **Don't `git clean -xdf`** — it deletes `.jj/`. Use `jj abandon` to discard a change.
- **Don't `git push` directly** unless you specifically mean to bypass jj's bookmark tracking. Prefer `jj git push --bookmark <name>`.

## Identity

jj uses its own identity (set globally once via `jj config set --user user.name "…"` / `user.email "…"`). It does not read `git config` user identity, so a fresh host needs this set or commits error.

## Common workflows

**Start a feature off master:**
```bash
jj git fetch
jj new master
jj describe -m "feat(x): start"
jj bookmark create feat/x -r @
jj git push --bookmark feat/x
# ...edit (auto-snapshotted)... then describe the real message + jj new
```

**Switch to another branch, make a fix, come back:**
```bash
jj edit feat/other     # working copy swaps in-place, prior work preserved on its bookmark
# ...fix...
jj describe -m "fix: small thing"
jj git push --bookmark feat/other
jj edit feat/x         # back where you were
```
