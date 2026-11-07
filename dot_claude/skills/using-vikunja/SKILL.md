---
name: using-vikunja
description: Use when Dave mentions "vk", "vikunja", "ticket(s)", "the tracker", or projects.ericbond.net in ANY phrasing — including quick ad-hoc asks ("check that vk thing", "close the ticket", "file a ticket for that") — or when doing any Vikunja work; listing tasks, creating/updating tasks, marking done, applying labels, setting parent/child relations, bootstrapping a new project, or auditing for stale tickets. Vikunja is the de-facto project-management tool across all of Dave's projects; treat it as the source of truth for what's open vs shipped.
---

# Using Vikunja

Vikunja is Dave's self-hosted project tracker at **https://projects.ericbond.net**. Source of truth for every project. This skill bundles a reusable client and captures the conventions that apply across every project. A project only needs to record its project ID; the client discovers kanban views and buckets.

## Use the bundled client first

```bash
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs list --project 6
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs audit --project 6 --repo /path/to/repo --rev master
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs get 1514
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs buckets --project 6
```

**Always call it by that literal path, one command per call** — not through a `VK=…`/`$VK`
variable, `bash -c`, or a Python/shell wrapper. The fleet's Claude Code permission allow-rule
(`Bash(node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs *)` and its absolute-path twin, in
`modify_private_settings.json.tmpl`) matches only that form; any other form goes to the auto-mode
classifier, which blocks Vikunja writes as external-system writes (Dave, 2026-11-07: grooming the
board is allowed). For a multi-line `--description`, pass the text with `"$(cat FILE)"`.

Do not write a fresh curl/Python/Node helper for routine Vikunja work. Use
`scripts/vikunja.mjs`; it already handles pagination, 1Password authentication,
full-body task updates, title formatting, view/bucket discovery, and empty DELETE
responses.

Read-only commands:

```bash
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs list --project <id> [--all] [--json]
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs audit --project <id> [--repo <path>] [--rev master] [--json]
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs get <task-id> [task-id...]
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs views --project <id>
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs buckets --project <id> [--view <id>]
```

Mutation commands:

```bash
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs create --project <id> --severity low --title "..." --description "..."
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs edit <task-id> --severity medium --title "..." --description "..."
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs severity <task-id> [task-id...] --severity high
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs move <task-id> --project <id> --bucket todo|doing|done
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs start <task-id> --project <id> [--comment "..."]
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs done <task-id> --project <id> [--comment "..."]
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs comment <task-id> --text "..."
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs label-add <task-id> --label <label-id>
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs label-remove <task-id> --label <label-id>
node ~/.claude/skills/using-vikunja/scripts/vikunja.mjs relate <parent-id> <child-id> --kind subtask
```

Run the script with `--help` for the complete syntax. Pass `--view` only when a
project has multiple kanban views. Bucket names accept the common aliases
To-Do/Backlog/Open, Doing/In Progress/Active, and Done/Shipped/Closed.
`list` shows open tasks unless `--all` is passed; `audit` always includes done
tasks because shipped work is institutional context and bucket consistency
checks require it.
Run `self-test` after modifying the client, then validate the skill directory.

## Authentication and API fallback

The client reads the token directly into process memory from
`op://vault.ericbond.net/projects api key/password`. Override the secret
reference with `VIKUNJA_TOKEN_REF` for a project using a different vault item,
or the API root with `VIKUNJA_API_BASE`. A different API host requires a
distinct, explicitly set `VIKUNJA_TOKEN_REF`; the client refuses to send the
production token to another host. Never put tokens in command arguments, logs,
or files.

Use direct API code only when the bundled client genuinely lacks an operation.
When extending the client would make that operation reusable, extend and test
the client instead of leaving a one-off helper behind.

## v2.3 quirks (the gotchas that bit me on hoosierTrail)

### POST /tasks/{id} replaces the entire task body

`POST /tasks/{id}` with `{priority: 2}` can reset fields omitted from the body.
Always preserve fields with **GET → mutate → POST whole**:

```python
t = http("GET", f"/tasks/{tid}")
t['priority'] = 3
t['done'] = True
http("POST", f"/tasks/{tid}", t)
```

Do this even for a one-field change. The bundled client does it automatically.

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
t = http("GET", f"/tasks/{tid}")
t["project_id"] = NEW_PROJECT
http("POST", f"/tasks/{tid}", t)
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

**1. Title format**: `<emoji> #<global_task_id> — <descriptive title>` — for
new tasks, always use the numeric global API `task.id` so a chat reference such
as "close #287" maps safely to `GET /tasks/287`. The emoji marks severity at a
glance.

Imported projects may contain a legacy display number (or suffix such as
`#287a`) that does **not** equal the global task ID. Treat that prefix as display
text only: resolve the task from the project listing, operate on the returned
numeric `task.id`, and preserve the legacy prefix unless Dave explicitly asks
to migrate the numbering. The bundled client reports this as
`legacy-display-id` and preserves it during severity/title edits.

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
    import re

    t = http("GET", f"/tasks/{tid}")
    raw = t['title']
    # Preserve an imported legacy display id (including suffixes such as 287a).
    match = re.match(r"^(?:(?:🔴|🟡|⚪)\s*)?#(\d+[a-z]?)\s+—\s+(.*)$", raw)
    display_id = match.group(1) if match else str(tid)
    raw = match.group(2) if match else raw
    # Strip redundant prefixes the emoji+label already convey.
    for p in ("BUG:", "bug:", "Bug:", "TODO:", "todo:"):
        if raw.startswith(p): raw = raw[len(p):].strip()
    prefix = f"{emoji} " if emoji else ""
    t['title'] = f"{prefix}#{display_id} — {raw}"
    t['priority'] = prio
    if desc_if_missing and not (t.get('description') or '').strip():
        t['description'] = desc_if_missing
    http("POST", f"/tasks/{tid}", t)
```

### Looking up a specific ticket — and why `?s=` will lie to you

**When you have a confirmed global task ID**, ALWAYS look it up by direct GET:

```python
t = http("GET", f"/tasks/{tid}")
```

This works for both open AND shipped tickets, and is the only reliable way to
confirm a global task exists. In an imported project, a `#N` title prefix may
be only a legacy display number; first resolve it by walking that project's
task listing and use the separate numeric `id` field. Never send a legacy
display number to `/tasks/<id>`.

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

Pair with `fix_task` above — that function repairs a known global task ID; this
sweep discovers which tasks need it. Do not feed a legacy display-ID mismatch
into `fix_task`; preserve it and operate on the listing's global `id`.

```python
import re
TITLE_OK = re.compile(r"^[🔴🟡⚪]?\s?#(\d+[a-z]?)\s—\s")
for tid, title, done in [(t['id'], t['title'], t['done']) for _, t in tasks]:
    if done: continue
    match = TITLE_OK.match(title)
    if not match:
        print(f"format-violator: #{tid} {title[:80]}")
    elif match.group(1) != str(tid):
        print(f"legacy-display-id: global={tid} display={match.group(1)}")
```

Feed each violator id into `fix_task(tid, prio, emoji, desc_if_missing)`. Pick `prio`/`emoji` from the severity tier table — for raw quick-capture entries Dave dropped in, default to ⚪/1 unless context says otherwise.

### Find stale shipped tickets (open in Vikunja, already merged on master)

Cross-reference open tickets against shipped commit messages. The deliverable shipped but the ticket never got marked done.

```python
import subprocess, re
log = subprocess.check_output(['git', 'log', 'master', '--oneline'], cwd=repo_path).decode()
shipped = set(map(int, re.findall(r"#(\d+)", log)))
for proj, t in tasks:
    if t['done']: continue
    if t['id'] in shipped:
        print(f"likely-stale: global #{t['id']} appears in a commit — {t['title'][:80]}")
```

**Verify before closing.** A `#306 phase 1` shipping doesn't mean `#306 phase 3` shipped — read the actual commit messages for phase qualifiers, slice letters, and partial-implementation notes. Mark done only when the ticket's stated deliverable is genuinely merged.

### Parent / child relations

For sliced clusters, use the `subtask` relation. Vikunja v2.3 auto-mirrors:
creating `subtask` from the parent's side auto-creates `parenttask` from the
child's side.

```python
http("PUT", f"/tasks/{parent_id}/relations", {
    "relation_kind": "subtask",
    "other_task_id": child_id,
    "task_id": parent_id
})
```

Other relation kinds: `parenttask`, `related`, `duplicateof`, `duplicates`, `blocking`, `blocked`, `precedes`, `follows`, `copiedfrom`, `copiedto`, `unknown`.

Convention:
- Umbrella and children each keep their own numeric global IDs.
- Put slice names such as "Profile registry — slice A" in the descriptive title
  rather than inventing non-addressable ID suffixes.
- Mark umbrella done only when ALL children are done

### Update view filters

```python
view = http("GET", f"/projects/{proj}/views/{view_id}")
view['filter']['filter'] = "labels = 2 && done = false"
http("POST", f"/projects/{proj}/views/{view_id}", view)
```

### Delete task

Auditing, checking, syncing, or grooming does not authorize deletion. Delete a
task only after Dave explicitly requests deletion of that exact resolved global
task ID. Prefer preserving shipped context or migrating it to a durable
repository record.

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

Keep active views focused on open, in-progress, and recently shipped work.
Older shipped tasks remain valid institutional context and stay hidden from
active views. Migrate or delete them only as a separate, explicitly authorized
retention task after verifying the durable repository record.

### Mark transitions on PR events, not by hand

- Open PR → mark task **In Progress** (move to bucket 2 / "Doing")
- Merge PR → mark task **Shipped** (`done: true` triggers auto-move if `done_bucket_id` set)

### Bug + severity discipline

See the "Title format + description + severity" section near the top — bugs get the `bug` label + 🔴 emoji + priority 3 at create-time. Higher-severity vulns / outages get priority 4-5 (still 🔴). Apply retroactively if you find a violator: missing `#<id>`, missing emoji, missing description, wrong priority.

### Slice clusters get parent/child wiring

When a ticket grows too big and gets sliced, create children as separate tasks
with their own global IDs and wire the `subtask` relation. Put slice names in
the descriptive title, not in an ID suffix. Vikunja v2.3 auto-mirrors. Mark the
umbrella done when all children are done.

### Organizing a project into group tabs (Views + Labels)

When a backlog grows unwieldy ("things are getting out of hand"), don't just retitle in place — reorganize it into **group tabs**. The vocabulary matters because Dave navigates by it:

- The **tabs across the top of a project are Views** (saved filters). "Add a View" = add a tab. Every project is born with List/Kanban/Table/Gantt; extras are custom filtered Views.
- A ticket lands in a tab because of its **Labels** (tags). A View is just a filter, and it matches on labels — e.g. a "Wagon train" tab is literally `labels = wagon-train`.
- Not "group"/"category" (Vikunja has neither as a first-class thing); a **Project** is the sidebar item, a **Bucket** is a Kanban column.

The pattern, per thematic group:
1. **A Label** — `PUT /labels {title, hex_color}` (reuse an existing label if one already means this group).
2. **A filtered List View (the tab)** — `PUT /projects/{p}/views` with `{title, view_kind:"list", project_id, filter:{filter:"labels = N && done = false", s:"", sort_by:[], order_by:[], filter_include_nulls:false}}`.
3. **Tag every member** with that label (and the umbrella ticket too, so it anchors the tab).
4. Optionally pair with an **umbrella ticket** (subtask relations) for the done-rollup semantic — umbrella and label/tab are complementary, not redundant.

Two rules that bite if ignored:

- **Group by LAYER, not just topic.** Keep in-game-*action*/mechanic tickets separate from *view*/UI/render tickets — they usually live in different sub-projects and mixing them muddies the tab. (A "Camp actions" tab is for the actions; the "scout-ahead *view*" ticket belongs with UI, related-linked, not bucketed as an action.) **Exception:** when the group *is* a cross-layer feature (e.g. "Documentation" = a wiki + a screen + a guidebook item), group by feature — the tab is the feature area.
- **Views are PROJECT-SCOPED.** A tab only shows tickets in *its own* project; a parent project's view does NOT aggregate child-project tasks. So a cluster that straddles projects renders incompletely. Unify each cluster into one project (move the minority strays — that's also "proper categorization") before relying on its tab.

When you delete redundant/broad Views after building granular ones (`DELETE /projects/{p}/views/{viewID}` — tickets keep their labels), first sweep for tickets that were *only* findable through them and re-home or re-label them, so nothing orphans. Deferred-labelled backlog items are an acceptable exception (they're hidden from active views anyway).

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
- **Views are project-scoped.** A custom View only filters tickets in its own project; parent projects do NOT aggregate child-project tasks into their Views. Cross-project group tabs therefore render incompletely — unify the cluster into one project first.
- **In migrated projects, the `#N` or `#Na` in a title may NOT be the global task `id`.** If a project was imported (e.g. from a TODO.md), titles often kept old display numbers while Vikunja assigned fresh global IDs, and those display numbers can collide with other projects' real IDs. Never `GET/POST/relate /tasks/<displayN>`; always resolve the numeric global `id` from the project task listing first. The bundled client accepts only numeric global IDs and preserves legacy display prefixes on edits.

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
