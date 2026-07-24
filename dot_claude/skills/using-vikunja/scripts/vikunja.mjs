#!/usr/bin/env node

/**
 * Reusable Vikunja CLI for Codex skills.
 *
 * Authentication is read from 1Password into process memory. Tokens are never
 * accepted on the command line, printed, or written to disk.
 */

import { execFileSync } from 'node:child_process';

const DEFAULT_API = 'https://projects.ericbond.net/api/v1';
const DEFAULT_TOKEN_REF = 'op://vault.ericbond.net/projects api key/password';
const TOKEN_REF =
  process.env.VIKUNJA_TOKEN_REF ?? DEFAULT_TOKEN_REF;
const TITLE_OK = /^(?:🔴|🟡|⚪)?\s?#(\d+[a-z]?)\s—\s/u;
const SEVERITIES = Object.freeze({
  critical: { priority: 5, emoji: '🔴' },
  high: { priority: 4, emoji: '🔴' },
  bug: { priority: 3, emoji: '🔴' },
  medium: { priority: 3, emoji: '🟡' },
  low: { priority: 1, emoji: '⚪' },
  backlog: { priority: 0, emoji: '' },
});

function apiBase() {
  const raw = process.env.VIKUNJA_API_BASE ?? DEFAULT_API;
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`Invalid VIKUNJA_API_BASE: ${raw}`);
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error('VIKUNJA_API_BASE must not contain credentials, a query, or a fragment');
  }

  const production = new URL(DEFAULT_API);
  if (parsed.origin !== production.origin) {
    const local = new Set(['localhost', '127.0.0.1', '[::1]']).has(parsed.hostname);
    if (parsed.protocol !== 'https:' && !(local && parsed.protocol === 'http:')) {
      throw new Error('A custom VIKUNJA_API_BASE must use HTTPS (HTTP is allowed only on localhost)');
    }
    if (!process.env.VIKUNJA_TOKEN_REF || TOKEN_REF === DEFAULT_TOKEN_REF) {
      throw new Error(
        'Refusing to send the production Vikunja token to a custom API host; ' +
          'set a distinct VIKUNJA_TOKEN_REF for that host',
      );
    }
  }
  return raw.replace(/\/+$/, '');
}

const API = apiBase();

function usage(message) {
  if (message) process.stderr.write(`${message}\n\n`);
  process.stderr.write(`Usage:
  vikunja.mjs list --project <id> [--all] [--json]
  vikunja.mjs audit --project <id> [--repo <path>] [--rev <rev>] [--json]
  vikunja.mjs get <task-id> [task-id...]
  vikunja.mjs views --project <id> [--json]
  vikunja.mjs buckets --project <id> [--view <id>] [--json]
  vikunja.mjs create --project <id> --severity <critical|high|bug|medium|low|backlog>
                     --title <text> --description <text> [--bucket <name>]
  vikunja.mjs edit <task-id> --severity <critical|high|bug|medium|low|backlog>
                   --title <text> --description <text>
  vikunja.mjs severity <task-id> [task-id...] --severity <critical|high|bug|medium|low|backlog>
  vikunja.mjs comment <task-id> --text <text>
  vikunja.mjs move <task-id> --project <id> --bucket <name> [--view <id>]
  vikunja.mjs start <task-id> --project <id> [--view <id>] [--comment <text>]
  vikunja.mjs done <task-id> --project <id> [--view <id>] [--comment <text>]
  vikunja.mjs label-add <task-id> --label <id>
  vikunja.mjs label-remove <task-id> --label <id>
  vikunja.mjs relate <task-id> <other-task-id>
                     [--kind <subtask|related|blocking|blocked>]
  vikunja.mjs self-test

Environment:
  VIKUNJA_API_BASE   API root (default: https://projects.ericbond.net/api/v1)
  VIKUNJA_TOKEN_REF  1Password secret reference; a distinct explicit ref is
                     required when VIKUNJA_API_BASE uses another host
`);
  process.exit(message ? 2 : 0);
}

function parseArgs(words) {
  const positional = [];
  const options = {};
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index];
    if (!word.startsWith('--')) {
      positional.push(word);
      continue;
    }
    const name = word.slice(2);
    if (name === 'all' || name === 'json') {
      options[name] = true;
      continue;
    }
    const value = words[index + 1];
    if (value === undefined || value.startsWith('--')) usage(`Missing value for --${name}`);
    options[name] = value;
    index += 1;
  }
  return { positional, options };
}

function positiveInt(raw, label) {
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) usage(`Invalid ${label}: ${raw ?? ''}`);
  return value;
}

function required(options, name) {
  const value = options[name];
  if (value === undefined || String(value).trim() === '') usage(`Missing --${name}`);
  return value;
}

function authorization() {
  try {
    const token = execFileSync('op', ['read', TOKEN_REF], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    if (token === '') throw new Error('empty token');
    return token;
  } catch {
    throw new Error(`Unable to read the Vikunja API token from ${TOKEN_REF}`);
  }
}

let cachedAuthorization;

async function http(method, path, body) {
  cachedAuthorization ??= authorization();
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${cachedAuthorization}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 800);
    throw new Error(`Vikunja ${method} ${path} failed (${response.status}): ${detail}`);
  }
  if (response.status === 204) return undefined;
  const text = await response.text();
  return text === '' ? undefined : JSON.parse(text);
}

async function getTask(id, expand = true) {
  return http('GET', `/tasks/${id}${expand ? '?expand=buckets' : ''}`);
}

async function projectTasks(project, includeDone) {
  const tasks = [];
  for (let page = 1; ; page += 1) {
    const query = new URLSearchParams({
      per_page: '50',
      page: String(page),
      expand: 'buckets',
    });
    const chunk = await http('GET', `/projects/${project}/tasks?${query}`);
    tasks.push(...chunk.filter((task) => includeDone || !task.done));
    if (chunk.length < 50) return tasks;
  }
}

async function views(project) {
  return http('GET', `/projects/${project}/views`);
}

async function resolveKanban(project, requestedView) {
  const candidates = (await views(project)).filter((view) => view.view_kind === 'kanban');
  if (requestedView !== undefined) {
    const id = positiveInt(requestedView, 'view id');
    const match = candidates.find((view) => view.id === id);
    if (!match) throw new Error(`Project ${project} has no kanban view ${id}`);
    return match;
  }
  if (candidates.length !== 1) {
    throw new Error(
      `Project ${project} has ${candidates.length} kanban views; pass --view explicitly`,
    );
  }
  return candidates[0];
}

function bucketAliases(title) {
  const normalized = title.toLowerCase().replaceAll(/[^a-z0-9]+/g, '');
  const aliases = new Set([normalized]);
  if (['todo', 'backlog', 'open'].includes(normalized)) {
    for (const alias of ['todo', 'backlog', 'open']) aliases.add(alias);
  }
  if (['doing', 'inprogress', 'active'].includes(normalized)) {
    for (const alias of ['doing', 'inprogress', 'active']) aliases.add(alias);
  }
  if (['done', 'shipped', 'closed'].includes(normalized)) {
    for (const alias of ['done', 'shipped', 'closed']) aliases.add(alias);
  }
  return aliases;
}

async function resolveBucket(project, requestedView, requestedBucket) {
  const view = await resolveKanban(project, requestedView);
  const buckets = await http('GET', `/projects/${project}/views/${view.id}/buckets`);
  const wanted = String(requestedBucket).toLowerCase().replaceAll(/[^a-z0-9]+/g, '');
  const matches = buckets.filter((bucket) => bucketAliases(bucket.title).has(wanted));
  if (matches.length !== 1) {
    throw new Error(
      `Bucket "${requestedBucket}" matched ${matches.length} buckets in view ${view.id}: ` +
        buckets.map((bucket) => `${bucket.id}:${bucket.title}`).join(', '),
    );
  }
  return { view, bucket: matches[0] };
}

async function moveTask(id, project, requestedView, requestedBucket) {
  const destination = await resolveBucket(project, requestedView, requestedBucket);
  return moveTaskTo(id, project, destination);
}

async function moveTaskTo(id, project, destination) {
  const { view, bucket } = destination;
  await http('POST', `/projects/${project}/views/${view.id}/buckets/${bucket.id}/tasks`, {
    task_id: id,
    project_view_id: view.id,
    bucket_id: bucket.id,
  });
  return { task: id, project, view: { id: view.id, title: view.title }, bucket };
}

function severity(name) {
  const result = SEVERITIES[name];
  if (!result) usage(`Unknown severity: ${name ?? ''}`);
  return result;
}

function titleIdentifier(task) {
  return task.title.match(TITLE_OK)?.[1] ?? String(task.id);
}

function formattedTitle(identifier, title, emoji) {
  const withoutPrefix = title
    .replace(/^(?:(?:(?:🔴|🟡|⚪)\s*)?#\d+[a-z]?\s—\s*)+/u, '')
    .replace(/^(?:BUG|TODO):\s*/i, '')
    .trim();
  if (withoutPrefix === '') usage('Title must not be empty');
  return `${emoji === '' ? '' : `${emoji} `}#${identifier} — ${withoutPrefix}`;
}

function concise(task) {
  return {
    id: task.id,
    title: task.title,
    done: task.done,
    priority: task.priority,
    project_id: task.project_id,
    buckets: (task.buckets ?? []).map(({ id, title }) => ({ id, title })),
    labels: (task.labels ?? []).map(({ id, title }) => ({ id, title })),
    description: task.description,
    updated: task.updated,
  };
}

function taskIssues(task) {
  const issues = [];
  const titleMatch = task.title.match(TITLE_OK);
  if (!titleMatch) {
    issues.push('title-format');
  } else if (titleMatch[1] !== String(task.id)) {
    issues.push('legacy-display-id');
  }
  if ((task.description ?? '').replaceAll(/<[^>]*>/g, '').trim() === '') {
    issues.push('missing-description');
  }
  const labels = new Set((task.labels ?? []).map((label) => label.title.toLowerCase()));
  if (labels.has('bug') && (task.priority !== 3 || !task.title.startsWith('🔴 '))) {
    issues.push('bug-severity');
  }
  if (
    labels.has('deferred') &&
    (task.priority !== 0 || /^[🔴🟡⚪]\s/.test(task.title))
  ) {
    issues.push('deferred-severity');
  }
  const bucketTitles = new Set((task.buckets ?? []).map((bucket) => bucket.title.toLowerCase()));
  if (task.done && ![...bucketTitles].some((title) => ['done', 'shipped'].includes(title))) {
    issues.push('done-bucket-mismatch');
  }
  if (
    !task.done &&
    [...bucketTitles].some((title) => ['done', 'shipped'].includes(title))
  ) {
    issues.push('open-bucket-mismatch');
  }
  return issues;
}

function printTasks(tasks, json) {
  if (json) {
    console.log(JSON.stringify(tasks.map(concise), null, 2));
    return;
  }
  for (const task of tasks) {
    const bucket = (task.buckets ?? []).map((item) => item.title).join(',');
    const labels = (task.labels ?? []).map((item) => item.title).join(',');
    console.log(
      `${task.id}\tp${task.priority}\t${task.done ? 'done' : 'open'}\t${bucket}\t${labels}\t${task.title}`,
    );
  }
}

async function setDone(id, done) {
  const task = await getTask(id, false);
  task.done = done;
  return http('POST', `/tasks/${id}`, task);
}

const [command, ...rawArgs] = process.argv.slice(2);
const { positional, options } = parseArgs(rawArgs);

try {
  switch (command) {
    case undefined:
    case 'help':
    case '--help':
    case '-h':
      usage();
      break;

    case 'self-test': {
      const checks = [
        [formattedTitle(1579, '🟡 #1579 — Docker hygiene', '🟡'), '🟡 #1579 — Docker hygiene'],
        [formattedTitle(1579, '🟡 #1579 — 🟡 #1579 — Docker hygiene', '🟡'), '🟡 #1579 — Docker hygiene'],
        [formattedTitle(1495, '#1495 — Scanner admin', ''), '#1495 — Scanner admin'],
        [formattedTitle(42, '🔴 #42 — Broken auth', '⚪'), '⚪ #42 — Broken auth'],
        [formattedTitle(7, 'BUG: Bad state', '🔴'), '🔴 #7 — Bad state'],
        [formattedTitle('287a', '⚪ #287a — Slice', '🔴'), '🔴 #287a — Slice'],
        [severity('critical').priority, 5],
        [severity('high').priority, 4],
      ];
      for (const [actual, expected] of checks) {
        if (actual !== expected) throw new Error(`self-test failed: ${actual} !== ${expected}`);
      }
      console.log('ok');
      break;
    }

    case 'list': {
      const project = positiveInt(required(options, 'project'), 'project id');
      printTasks(await projectTasks(project, Boolean(options.all)), Boolean(options.json));
      break;
    }

    case 'audit': {
      const project = positiveInt(required(options, 'project'), 'project id');
      const tasks = await projectTasks(project, true);
      let shipped = new Set();
      if (options.repo) {
        const log = execFileSync(
          'git',
          ['log', options.rev ?? 'master', '--format=%s%n%b'],
          { cwd: options.repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
        );
        shipped = new Set([...log.matchAll(/#(\d+)/g)].map((match) => Number(match[1])));
      }
      const findings = tasks
        .map((task) => ({
          task: concise(task),
          issues: [
            ...taskIssues(task),
            ...(!task.done && shipped.has(task.id) ? ['commit-reference'] : []),
          ],
        }))
        .filter((finding) => finding.issues.length > 0);
      if (options.json) {
        console.log(JSON.stringify({ project, open: tasks.filter((task) => !task.done).length, findings }, null, 2));
      } else {
        console.log(`project=${project} open=${tasks.filter((task) => !task.done).length} findings=${findings.length}`);
        for (const finding of findings) {
          console.log(
            `${finding.task.id}\t${finding.issues.join(',')}\t${finding.task.title}`,
          );
        }
      }
      break;
    }

    case 'get': {
      if (positional.length === 0) usage('get requires at least one task id');
      const tasks = await Promise.all(
        positional.map((raw) => getTask(positiveInt(raw, 'task id'))),
      );
      console.log(JSON.stringify(
        tasks.length === 1 ? concise(tasks[0]) : tasks.map(concise),
        null,
        2,
      ));
      break;
    }

    case 'views': {
      const project = positiveInt(required(options, 'project'), 'project id');
      const result = await views(project);
      console.log(JSON.stringify(result.map(({ id, title, view_kind, filter, done_bucket_id }) => ({
        id, title, view_kind, filter, done_bucket_id,
      })), null, 2));
      break;
    }

    case 'buckets': {
      const project = positiveInt(required(options, 'project'), 'project id');
      const view = await resolveKanban(project, options.view);
      const buckets = await http('GET', `/projects/${project}/views/${view.id}/buckets`);
      console.log(JSON.stringify({
        view: { id: view.id, title: view.title },
        buckets: buckets.map(({ id, title }) => ({ id, title })),
      }, null, 2));
      break;
    }

    case 'create': {
      const project = positiveInt(required(options, 'project'), 'project id');
      const selected = severity(required(options, 'severity'));
      const title = required(options, 'title');
      const description = required(options, 'description').trim();
      const destination = await resolveBucket(
        project,
        options.view,
        options.bucket ?? 'todo',
      );
      const created = await http('PUT', `/projects/${project}/tasks`, { title, description });
      created.title = formattedTitle(created.id, title, selected.emoji);
      created.priority = selected.priority;
      const updated = await http('POST', `/tasks/${created.id}`, created);
      const moved = await moveTaskTo(created.id, project, destination);
      console.log(JSON.stringify({ task: concise(updated), moved }, null, 2));
      break;
    }

    case 'edit': {
      const id = positiveInt(positional[0], 'task id');
      const selected = severity(required(options, 'severity'));
      const task = await getTask(id, false);
      task.title = formattedTitle(
        titleIdentifier(task),
        required(options, 'title'),
        selected.emoji,
      );
      task.description = required(options, 'description').trim();
      task.priority = selected.priority;
      console.log(JSON.stringify(concise(await http('POST', `/tasks/${id}`, task)), null, 2));
      break;
    }

    case 'severity': {
      if (positional.length === 0) usage('severity requires at least one task id');
      const selected = severity(required(options, 'severity'));
      const updated = [];
      for (const raw of positional) {
        const id = positiveInt(raw, 'task id');
        const task = await getTask(id, false);
        task.title = formattedTitle(titleIdentifier(task), task.title, selected.emoji);
        task.priority = selected.priority;
        updated.push(concise(await http('POST', `/tasks/${id}`, task)));
      }
      console.log(JSON.stringify(updated.length === 1 ? updated[0] : updated, null, 2));
      break;
    }

    case 'comment': {
      const id = positiveInt(positional[0], 'task id');
      const comment = required(options, 'text').trim();
      const result = await http('PUT', `/tasks/${id}/comments`, { comment });
      console.log(JSON.stringify({ task: id, comment_id: result.id }, null, 2));
      break;
    }

    case 'move': {
      const id = positiveInt(positional[0], 'task id');
      const project = positiveInt(required(options, 'project'), 'project id');
      console.log(JSON.stringify(
        await moveTask(id, project, options.view, required(options, 'bucket')),
        null,
        2,
      ));
      break;
    }

    case 'start':
    case 'done': {
      const id = positiveInt(positional[0], 'task id');
      const project = positiveInt(required(options, 'project'), 'project id');
      const done = command === 'done';
      const destination = await resolveBucket(
        project,
        options.view,
        done ? 'done' : 'doing',
      );
      await setDone(id, done);
      const moved = await moveTaskTo(id, project, destination);
      if (options.comment) {
        await http('PUT', `/tasks/${id}/comments`, { comment: options.comment.trim() });
      }
      console.log(JSON.stringify({ task: id, done, moved }, null, 2));
      break;
    }

    case 'label-add':
    case 'label-remove': {
      const id = positiveInt(positional[0], 'task id');
      const label = positiveInt(required(options, 'label'), 'label id');
      if (command === 'label-add') {
        await http('PUT', `/tasks/${id}/labels`, { label_id: label });
      } else {
        await http('DELETE', `/tasks/${id}/labels/${label}`);
      }
      console.log(JSON.stringify({ task: id, label, action: command }, null, 2));
      break;
    }

    case 'relate': {
      const id = positiveInt(positional[0], 'task id');
      const other = positiveInt(positional[1], 'other task id');
      const kind = options.kind ?? 'subtask';
      const allowed = new Set(['subtask', 'related', 'blocking', 'blocked']);
      if (!allowed.has(kind)) usage(`Unsupported relation kind: ${kind}`);
      await http('PUT', `/tasks/${id}/relations`, {
        relation_kind: kind,
        other_task_id: other,
        task_id: id,
      });
      console.log(JSON.stringify({ task: id, other_task: other, kind }, null, 2));
      break;
    }

    default:
      usage(`Unknown command: ${command}`);
  }
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}
