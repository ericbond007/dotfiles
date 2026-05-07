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

## Common operations — recipe block

### Create a task

```python
t = http("PUT", f"/projects/{proj}/tasks", {
    "title": "#317 — Profession rebalance",
    "description": "Markdown body."
})
tid = t['id']
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

### Set priority + emoji prefix (bug convention)

Bugs get priority 3 + `🔴 ` title prefix. Other priority emojis: 🟡 medium (2), ⚪ low (1).

```python
t = http("GET", f"/tasks/{tid}")
t['priority'] = 3
t['title'] = '🔴 ' + t['title']
http("POST", f"/tasks/{tid}", t)
```

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

### Bug tickets

`bug` label → priority 3 + `🔴 ` title prefix at create-time. Apply retroactively if you find an unflagged bug.

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
