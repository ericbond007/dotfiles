---
name: using-vikunja
description: Use when interacting with the user's Vikunja project tracker at projects.ericbond.net — listing tasks, creating/updating tasks, marking done, applying labels, setting parent/child relations, bootstrapping a new project, or auditing for stale tickets. Vikunja is the de-facto project-management tool across all of Dave's projects; treat it as the source of truth for what's open vs shipped.
---

# Using Vikunja

Vikunja is Dave's self-hosted project tracker at **https://projects.ericbond.net**. Source of truth for every project. Per-project IDs (project, view, bucket, label) live in the project's memory dir; this skill captures the API patterns, v2.3 quirks, and conventions that apply across every project.

## Auth — never plaintext

```bash
VIKUNJA_TOKEN=$(op read "op://vault.ericbond.net/<vault-item>/password")
```

The vault item is project-specific (e.g. `projects api key`). Per-project memory should record the vault path. **Never** hardcode the token; never write it to disk.

Header: `Authorization: Bearer $VIKUNJA_TOKEN` on every request. API base: `https://projects.ericbond.net/api/v1`.

## Pattern: a Python helper for every script

Inline-Python via `python3` heredoc beats curl+jq for anything multi-step. stdlib only — `urllib.request` + `json`. No third-party deps.

```python
VIKUNJA_TOKEN=$(op read "op://vault.ericbond.net/projects api key/password") python3 <<'PY'
import os, json, urllib.request
H = {"Authorization": f"Bearer {os.environ['VIKUNJA_TOKEN']}", "Content-Type": "application/json"}
def http(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"https://projects.ericbond.net/api/v1{path}",
                                 data=data, headers=H, method=method)
    return json.loads(urllib.request.urlopen(req).read())

# ... your operations ...
PY
```

For DELETE that returns no JSON: `urllib.request.urlopen(req).read()` (skip `json.loads`).

For Bash heredocs with embedded JSON: encode the JSON via `python3 -c` or `jq -n` rather than inline strings — newlines + quoting break shell heredoc passthrough. Prefer the all-Python approach.

## v2.3 quirks (the gotchas that bit me on hoosierTrail)

### POST /tasks/{id} replaces the entire task body

`POST /tasks/{id}` with `{priority: 2}` silently zeros every other field not in the body (done, title, labels, etc.). To preserve fields, **GET → mutate → POST whole**:

```python
t = http("GET", f"/tasks/{tid}")
t['priority'] = 3
t['done'] = True
http("POST", f"/tasks/{tid}", t)
```

Single-field flips (just `{done: true}`) work because the done-bucket auto-move triggers cleanly on done-flip and other fields aren't part of the diff intent. But priority + title + labels all reset — so always full-body for anything beyond a single boolean.

### Bucket assignment lives in a join table, not on the task

`task.bucket_id` is **dormant** in v2.3 (it was the v1 single-view bucket). Per-view bucket assignments live in `task_buckets`. Consequences:
- `GET /tasks/{id}` returns `bucket_id: 0` even when the task is correctly bucketed in a kanban view — don't trust the field
- `GET /tasks/{id}?expand=buckets` returns the populated `buckets[]` array — that's the truth
- The bucket `count` field stays 0 even when tasks are assigned — frontend kanban ignores it

Move a task into a bucket (or between buckets in the kanban):

```python
http("POST", f"/projects/{proj}/views/{view}/buckets/{bucket}/tasks",
     {"task_id": tid, "project_view_id": view, "bucket_id": bucket})
```

POSTing to a different bucket replaces the existing assignment automatically (within the same view).

### Cross-project task moves

A task moved to a different project needs both `project_id` updated AND a fresh bucket assignment (the old bucket belongs to the old project's view):

```python
http("POST", f"/tasks/{tid}", {"project_id": NEW_PROJECT})
http("POST", f"/projects/{NEW_PROJECT}/views/{NEW_VIEW}/buckets/{NEW_BUCKET}/tasks",
     {"task_id": tid, "project_view_id": NEW_VIEW, "bucket_id": NEW_BUCKET})
```

### Filter syntax — limited DSL

The filter DSL on `filter.filter` view body fields uses numeric label IDs and only `=` / `!=` / `||`. There is no `in (1, 2)` — use `||` for unions.

```
labels = 4 || labels = 5
labels != 16
(labels = 4 || labels = 5) && done = false
```

Done = strictly hidden outside Shipped: every non-kanban view (List, Table, Gantt, filtered views) appends `done = false`. Kanban views NEVER filter on done — that empties the Shipped column.

## Title format + description + severity (mandatory conventions)

Every task in every project follows three rules. Apply at create time AND retroactively if you find violators.

**1. Title format**: `<emoji> #<task_id> — <descriptive title>` — always include the literal `#<id>` so tasks are referenceable in chat ("close #287" / "what's #266 about?"). The emoji marks severity at a glance.

| Tier | Priority | Emoji | When |
|---|---|---|---|
| High security / vuln residual / actively-broken-with-user-impact | 4 (or 5 for critical) | 🔴 | Open audit High findings; CSP/auth/data-corruption bugs; outages |
| Bug (label `bug`) | 3 | 🔴 | Anything labeled `bug`. Emoji marks bug regardless of true sev — frontend renders priority 3 mid-tone, the 🔴 + label make severity unambiguous |
| Medium ops / audit non-bug | 3 | 🟡 | Reliability work, audit Mediums, refactors with risk |
| Low / Info / hygiene | 1 | ⚪ | Audit Lows + Info, dep bumps, polish |
| Backlog / research / feature idea | 0 | (no emoji) | `deferred`-labeled or pre-spec ideas |

Strip redundant `bug:` / `BUG:` / `todo:` prefixes from titles — the emoji + label do that work.

**2. Description required**. No empty bodies. At minimum one sentence saying what the task is + (for non-trivial tasks) why it matters. For audit-derived tasks, link the finding ID (F-NNN). For bugs, include repro steps if known. If the task came in as a one-line title (Dave often files quick-capture asks), fill in a short description from context the next time you sync — keep a `_(extrapolated; refine if wrong)_` tag if extrapolating.

**3. Priority** matches the severity tier above. Don't pile every task at priority 3 — the kanban becomes unreadable. Default for non-bug, non-security work is **priority 1** (low/hygiene); reserve 3+ for things that genuinely need attention this week.

## Common operations — recipe block

### Create a task (two-step: PUT, then POST to add `#<id>`)

The `#<id>` part of the title needs the task id, which only exists after PUT. So create-then-rename:

```python
# Step 1: PUT to get the id back. Use the descriptive title (no #<id> yet).
t = http("PUT", f"/projects/{proj}/tasks", {
    "title": "Profession rebalance",
    "description": "Markdown body — REQUIRED, never empty."
})
tid = t['id']

# Step 2: POST the full task back with the `#<id>` prefix + severity emoji injected.
t['title'] = f"🟡 #{tid} — {t['title']}"
t['priority'] = 3
http("POST", f"/tasks/{tid}", t)

# Place in a bucket (per-view assignment):
http("POST", f"/projects/{proj}/views/{view}/buckets/{backlog}/tasks",
     {"task_id": tid, "project_view_id": view, "bucket_id": backlog})

# Apply labels:
for lid in [12, 7, 3]:
    http("PUT", f"/tasks/{tid}/labels", {"label_id": lid})
```

### Mark done (the safe way — full-body POST)

```python
t = http("GET", f"/tasks/{tid}")
t['done'] = True
http("POST", f"/tasks/{tid}", t)
```

If `done_bucket_id` is set on the kanban view, the task auto-moves to Shipped.

### Re-apply title/priority/emoji to existing tasks (audit + repair sweep)

When auditing a project, retroactively bring all tasks into compliance — see "Title format + description + severity" above for the rules:

```python
def fix_task(tid, prio, emoji, desc_if_missing=None):
    t = http("GET", f"/tasks/{tid}")
    raw = t['title']
    # Strip redundant prefixes the emoji+label already convey.
    for p in ("BUG:", "bug:", "Bug:", "TODO:", "todo:"):
        if raw.startswith(p): raw = raw[len(p):].strip()
    # Don't double-prefix.
    already = raw.startswith(f"#{tid} —") or any(raw.startswith(f"{e} #{tid} —") for e in "🔴🟡⚪")
    if not already:
        raw = f"{emoji} #{tid} — {raw}".lstrip() if emoji else f"#{tid} — {raw}"
    t['title'] = raw
    t['priority'] = prio
    if desc_if_missing and not (t.get('description') or '').strip():
        t['description'] = desc_if_missing
    http("POST", f"/tasks/{tid}", t)
```

### Looking up a specific ticket — and why `?s=` will lie to you

**When you have a ticket ID** (`#1040`, `#287`, etc.), ALWAYS look it up by direct GET:

```python
t = http("GET", f"/tasks/{tid}")
```

This works for both open AND shipped tickets, and is the only reliable way to confirm a ticket exists. Do not assume "ticket X doesn't exist" from anything except a 404 on this endpoint.

**The `?s=<query>` fuzzy search is unreliable for ID lookups.** Even searching for the ID digits in title text can silently miss the ticket — the matching is loose and ranks results by an opaque score, so a ticket whose title is literally `🟢 #1040 — Historical mileage pass` may NOT appear when you query `?s=mile sequencing` or `?s=mileage`. Burned by this 2026-05-26: an agent reported `#1040 NOT FOUND` when it was a real shipped ticket — a follow-up was filed unnecessarily.

**Lookup decision tree:**

| You know | Use |
|---|---|
| Ticket ID | `GET /tasks/<id>` — definitive |
| Exact title text | `GET /projects/<p>/tasks?filter=title%20like%20%22<text>%22` |
| Just a topic/keyword | Walk all pages (see "audit pattern" below); **include `done`** — shipped tickets are valid context |
| Whether *anything* has shipped on a topic | `?s=<keyword>` can be a quick sanity check, but treat 0 hits as "maybe" not "no" |

**Audit pattern — walk all pages, include done:**

```python
hits = {}
for proj in [2, 3, 4]:
    page = 1
    while True:
        chunk = http("GET", f"/projects/{proj}/tasks?per_page=50&page={page}")
        if not chunk: break
        for t in chunk:
            # NOTE: do NOT filter `t['done']` here — done tickets often
            # contain the very context (shipped work) you need to find
            haystack = (t['title'] + ' ' + (t.get('description') or '')).lower()
            if any(kw in haystack for kw in keywords):
                hits[t['id']] = t
        if len(chunk) < 50: break
        page += 1
```

The done-skip in the stale-ticket recipe below is a deliberate exception for that one workflow (closing tickets that already shipped). Everywhere else, done tickets are part of the project's institutional memory — include them.

### Find tasks that need title-format repair

Pair with `fix_task` above — that function repairs a known tid; this sweep discovers which tids need it. Run after every "sync with Vikunja" / new-project bootstrap.

```python
import re
TITLE_OK = re.compile(r"^[🔴🟡⚪]?\s?#\d+\s—\s")  # emoji optional, #<tid> + em-dash required
for tid, title, done in [(t['id'], t['title'], t['done']) for _, t in tasks]:
    if done: continue
    if not TITLE_OK.match(title):
        print(f"format-violator: #{tid} {title[:80]}")
```

Feed each violator id into `fix_task(tid, prio, emoji, desc_if_missing)`. Pick `prio`/`emoji` from the severity tier table — for raw quick-capture entries Dave dropped in, default to ⚪/1 unless context says otherwise.

### Find stale shipped tickets (open in Vikunja, already merged on master)

Cross-reference open tickets against shipped commit messages. The deliverable shipped but the ticket never got marked done.

```python
import subprocess, re
log = subprocess.check_output(['git', 'log', 'master', '--oneline'], cwd=repo_path).decode()
shipped = set(re.findall(r"#(\d+[a-z]?)", log))
for proj, t in tasks:
    if t['done']: continue
    m = re.search(r"#(\d+[a-z]?)", t['title'])
    if m and m.group(1) in shipped:
        print(f"likely-stale: #{t['id']} matches commit #{m.group(1)} — {t['title'][:80]}")
```

**Verify before closing.** A `#306 phase 1` shipping doesn't mean `#306 phase 3` shipped — read the actual commit messages for phase qualifiers, slice letters, and partial-implementation notes. Mark done only when the ticket's stated deliverable is genuinely merged.

### Parent / child relations

For sliced clusters (e.g. parent #287 → children #287a/b/c/d), use the `subtask` relation. Vikunja v2.3 auto-mirrors: creating `subtask` from parent's side auto-creates `parenttask` from the child's side.

```python
http("PUT", f"/tasks/{parent_id}/relations", {
    "relation_kind": "subtask",
    "other_task_id": child_id,
    "task_id": parent_id
})
```

Other relation kinds: `parenttask`, `related`, `duplicateof`, `duplicates`, `blocking`, `blocked`, `precedes`, `follows`, `copiedfrom`, `copiedto`, `unknown`.

Convention:
- Umbrella ticket has bare issue id ("#287 — Named bot profiles")
- Children have suffix ("#287a — Profile registry", "#287b — Persona variants")
- Mark umbrella done only when ALL children are done

### Update view filters

```python
view = http("GET", f"/projects/{proj}/views/{view_id}")
view['filter']['filter'] = "labels = 2 && done = false"
http("POST", f"/projects/{proj}/views/{view_id}", view)
```

### Delete task

```python
urllib.request.urlopen(urllib.request.Request(
    f"https://projects.ericbond.net/api/v1/tasks/{tid}",
    headers=H, method="DELETE"
)).read()
```

## Bootstrapping a new project

When Dave starts a new project that needs a Vikunja tracker:

1. **Vault item** — create one in 1Password under `op://vault.ericbond.net/`, e.g. `<project> api key`. Use Vikunja's UI → User → Settings → API tokens to generate. Record the vault path in the project's memory.
2. **Project** — create via `PUT /projects` with `{title, description}`. Note the returned `id`.
3. **Discover view + bucket IDs** — Vikunja auto-creates a kanban view + 3 buckets (To-Do/Doing/Done) per project. Query `/projects/{id}/views` and `/projects/{p}/views/{v}/buckets` to get the IDs. Optionally rename buckets to Backlog / In Progress / Shipped.
4. **`done_bucket_id`** — set on the kanban view via `POST /projects/{p}/views/{v}` so dragging to Shipped auto-marks done. Body: `{...currentView, done_bucket_id: SHIPPED_BUCKET_ID}`.
5. **Filter views** — create List views with workstream filters via `PUT /projects/{p}/views`. Always include `&& done = false` so done items stay hidden outside Shipped.
6. **Labels** — labels are instance-wide, not project-scoped. Reuse existing ones; if you need new ones, `PUT /labels` with `{title, hex_color}` (no `#` on color). Standard labels seen so far: `historical` (1), `wagon-train` (2), `npc-parity` (3), `game-ai` (4), `bot` (5), `audit` (6), `period-mechanic` (7), `ui-ux` (8), `art` (9), `infrastructure` (10), `tooling` (11), `balance` (12), `bug` (13), `content` (14), `multiplayer` (15), `deferred` (16), `phase-2` (17), `phase-3` (18).
7. **Project memory** — write a `reference_vikunja.md` (or similar) in the project's memory dir capturing the IDs:
   - Vault path for the API token
   - Project ID, parent/child IDs if multi-project
   - View IDs (kanban + filtered views)
   - Bucket IDs per view (Backlog / In Progress / Shipped)
   - Filter conventions used

The skill stays generic; per-project memory holds the IDs.

## Workflow conventions

### Lean Vikunja

Hundreds of shipped tickets in a backlog is a UX disaster. Keep only **active work** — open + in-progress + recently shipped. Migrate-and-delete old shipped items; the audit trail lives in git log + PR descriptions, not Vikunja.

### Mark transitions on PR events, not by hand

- Open PR → mark task **In Progress** (move to bucket 2 / "Doing")
- Merge PR → mark task **Shipped** (`done: true` triggers auto-move if `done_bucket_id` set)

### Bug + severity discipline

See the "Title format + description + severity" section near the top — bugs get the `bug` label + 🔴 emoji + priority 3 at create-time. Higher-severity vulns / outages get priority 4-5 (still 🔴). Apply retroactively if you find a violator: missing `#<id>`, missing emoji, missing description, wrong priority.

### Slice clusters get parent/child wiring

When a ticket grows too big and gets sliced (e.g. #287 → #287a/b/c/d), create the children as separate tickets and wire the `subtask` relation. Vikunja v2.3 auto-mirrors. Mark the umbrella done when all children are done.

### `done = false` everywhere except kanban Shipped

Every filtered view (List, Table, Gantt, workstream lists) must include `done = false` in its filter. The Shipped kanban column is the only place done items show up. This rule is invariant — when adding a new view, always include the gate.

## Schema discovery

The OpenAPI spec is at `https://projects.ericbond.net/api/v1/docs.json` (Swagger 2.0, ~400KB). Use it when you need an endpoint or enum value not documented here:

```python
spec = json.loads(urllib.request.urlopen("https://projects.ericbond.net/api/v1/docs.json").read())
# RelationKind enum:
print(spec['definitions']['models.RelationKind']['enum'])
# All endpoints containing 'label':
print([p for p in spec['paths'] if 'label' in p])
```

## Common gotchas

- **Heredoc + jq + embedded newlines = parse errors.** Use Python urllib for any multi-line JSON body.
- **Don't use `urllib.parse.quote` on filter values** — Vikunja expects them as form-encoded query params. Use `urllib.parse.urlencode` or pre-build the query string.
- **Empty bodies on DELETE** — strip the `json.loads` for DELETEs, they return empty 204.
- **Per-page default is small (~50).** Always paginate with `?per_page=50&page=N` and stop when the chunk is shorter than per_page.
- **The `priority` field uses 1-5 (1=lowest, 5=highest).** Frontend renders ⚪ low (1) / 🟡 mid (2-3) / 🔴 high (4-5).

## When to invoke this skill

Invoke when Dave asks anything like:
- "Add a Vikunja ticket for X"
- "Mark #N as done / shipped / in progress"
- "What's open in Vikunja?"
- "Sync with Vikunja" / "what new tickets are there?"
- "Set up a tracker for this new project"
- "Are there stale tickets I should close?"
- "Link these as parent/child"

Don't invoke for non-Vikunja project-management talk — pure design discussions, code reviews, etc. — unless tickets need creating/updating as part of the work.
