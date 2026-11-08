#!/usr/bin/env node
// Claude Code Enhanced Statusline
// Shows: directory | model | context usage | current (5-hour) + weekly usage | current task
// Auto-detects API key vs subscription usage
// https://github.com/MithunWijayasiri/ctxline-claude
//
// Modified for the ericbond fleet (2026-11-07): either usage window may be missing, readings
// are stored for the plasma usage widget, and the usage API is asked under a shared lock.
//
// MIT License
//
// Copyright (c) 2026 Mithun Wijayasiri
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');
const { execSync } = require('child_process');

const IS_API_KEY = !!process.env.ANTHROPIC_API_KEY;

// Shared width (cells) for all progress bars: context, current, weekly.
const BAR_WIDTH = 6;

// Max characters shown for the git branch; longer names are tail-truncated with "…".
// Tail-truncation keeps the start (ticket IDs like "TAMA5-32796" live there) visible.
const MAX_BRANCH_LEN = 24;

// Claude Code's config folder: $CLAUDE_CONFIG_DIR when set, else ~/.claude. Credentials and
// the usage cache both live under it, so a second account never mixes with the first.
const CONFIG_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');

// Cache configuration. usage-cache.json is also read by the KDE usage widget
// (plasma-claude-usage fork): { timestamp, data: { fiveHour, weekly } }, where timestamp is
// when the reading was OBSERVED (not when the file was written) and either bucket may be
// null. Keep that contract when changing the format.
const CACHE_DIR = path.join(CONFIG_DIR, 'cache');
const USAGE_CACHE_FILE = path.join(CACHE_DIR, 'usage-cache.json');
// Fresh: an observation this recent is shown without asking the API.
const FRESH_TTL_MS = 10 * 60 * 1000;   // 10 minutes
// Stale: the oldest observation still shown when the API can't be asked or fails.
const STALE_TTL_MS = 30 * 60 * 1000;   // 30 minutes

// The usage API allows only a few requests per access token every few minutes, and every
// Claude Code session on this machine shares the token. One process at a time may ask it:
// the lock file holds { until } and a fallback only calls the API after taking it.
const API_LOCK_FILE = path.join(CACHE_DIR, 'usage-api.lock');
const LEASE_MS = 75 * 1000;                 // held while one request is in flight; at 75 s
                                            // aborted runs alone make <= 4 calls per rolling 5 min
const FAILURE_BACKOFF_MS = 5 * 60 * 1000;   // after a failed request (429, timeout, ...)

// prompt_cache.ttl values Claude Code reports, in ms
const PROMPT_CACHE_TTL_MS = { '5m': 5 * 60 * 1000, '1h': 60 * 60 * 1000 };

// ANSI color codes
const colors = {
  reset: '\x1b[0m',
  dim: '\x1b[2m',
  bold: '\x1b[1m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  orange: '\x1b[38;5;208m',
  red: '\x1b[31m',
  purple: '\x1b[38;5;135m',
  blink: '\x1b[5m'
};

// Color for the thinking-effort indicator. Levels rank low < medium < high < xhigh < max
// < ultracode; only the top two are highlighted — "max" red, "ultracode" purple. Every
// other level (including xhigh) renders dim like the rest of the metadata.
function getEffortColor(level) {
  const lvl = String(level).toLowerCase();
  if (lvl === 'max') return colors.red;
  if (lvl === 'ultracode') return colors.purple;
  return colors.dim;
}

function getUsageColor(percentage) {
  if (percentage < 50) return colors.green;
  if (percentage < 75) return colors.yellow;
  if (percentage < 90) return colors.orange;
  return colors.red;
}

// Shorten verbose model names for the statusline: "Opus 4.8 (1M context)" -> "Opus 4.8 (1M)".
function shortenModel(name) {
  return name.replace(/\s+context\)/i, ')');
}

// Tail-truncate an over-long branch name, preserving the leading ticket ID.
function truncateBranch(name) {
  return name.length > MAX_BRANCH_LEN ? name.slice(0, MAX_BRANCH_LEN - 1) + '…' : name;
}

// Resolve the current git branch by reading .git/HEAD directly (no `git` subprocess —
// keeps the render fast and dependency-free). Walks up from `dir` to find the repo,
// handles worktrees (.git as a file) and detached HEAD (short sha). Best-effort: '' on any failure.
function getGitBranch(dir) {
  try {
    let cur = dir;
    let gitPath = '';
    for (let i = 0; i < 50 && cur; i++) {
      const candidate = path.join(cur, '.git');
      if (fs.existsSync(candidate)) { gitPath = candidate; break; }
      const parent = path.dirname(cur);
      if (parent === cur) break;        // reached filesystem root
      cur = parent;
    }
    if (!gitPath) return '';

    let gitDir = gitPath;
    if (fs.statSync(gitPath).isFile()) {
      // Worktree/submodule: ".git" is a file like "gitdir: /path/to/.git/worktrees/x".
      const m = fs.readFileSync(gitPath, 'utf8').match(/gitdir:\s*(.+)/);
      if (!m) return '';
      gitDir = path.resolve(path.dirname(gitPath), m[1].trim());
    }

    const head = fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8').trim();
    const ref = head.match(/^ref:\s*refs\/heads\/(.+)$/);
    if (ref) return truncateBranch(ref[1]);
    if (/^[0-9a-f]{7,40}$/i.test(head)) return head.slice(0, 7);  // detached HEAD -> short sha
    return '';
  } catch (e) {
    return '';
  }
}

function getContextBar(remaining) {
  const effectiveRemaining = remaining ?? 100;
  const used = Math.max(0, Math.min(100, 100 - Math.round(effectiveRemaining)));

  const filled = Math.round((used / 100) * BAR_WIDTH);
  const bar = '\u2588'.repeat(filled) + '\u2591'.repeat(BAR_WIDTH - filled);

  let coloredBar;
  if (used < 50) {
    coloredBar = `${colors.green}${bar} ${used}%${colors.reset}`;
  } else if (used < 65) {
    coloredBar = `${colors.yellow}${bar} ${used}%${colors.reset}`;
  } else if (used < 80) {
    coloredBar = `${colors.orange}${bar} ${used}%${colors.reset}`;
  } else {
    coloredBar = `${colors.blink}${colors.red}${bar} ${used}%${colors.reset}`;
  }

  return coloredBar;
}

// Render the usage bar from raw data. Called on every read (live or cached) so the
// reset countdown is always recomputed from resetsAt rather than frozen at fetch time.
function buildUsageBar(percentage, resetsAt) {
  let timeStr = '';
  if (resetsAt) {
    const diffMins = Math.max(0, Math.floor((new Date(resetsAt) - new Date()) / 60000));
    const days = Math.floor(diffMins / 1440);
    const hours = Math.floor((diffMins % 1440) / 60);
    const mins = diffMins % 60;
    if (days > 0) timeStr = `${days}d${hours}h`;
    else if (hours > 0) timeStr = `${hours}h${mins}m`;
    else timeStr = `${mins}m`;
  }

  const shown = Math.round(percentage);
  const filledWidth = Math.max(0, Math.min(BAR_WIDTH, Math.round((shown / 100) * BAR_WIDTH)));
  const filled = '█'.repeat(filledWidth);
  const empty = '░'.repeat(BAR_WIDTH - filledWidth);
  const color = getUsageColor(shown);
  const timePart = timeStr ? `${colors.dim} (${timeStr})${colors.reset}` : '';

  return `${color}${filled}${empty} ${shown}%${colors.reset}${timePart}`;
}

// Build both usage bars from raw entries. Each entry is { percentage, resetsAt } or
// null/absent. Returns { current, weekly } where each is a rendered bar string or null.
function buildUsageBars(fiveHour, weekly) {
  return {
    current: fiveHour ? buildUsageBar(fiveHour.percentage, fiveHour.resetsAt) : null,
    weekly: weekly ? buildUsageBar(weekly.percentage, weekly.resetsAt) : null
  };
}

// Normalize a raw utilization into a 0-100 number with one decimal (what Claude Code and
// the API report); bars round it for display. Returns null when the value isn't a finite
// number, so callers can omit that bar instead of rendering "NaN%".
function normalizePercentage(value) {
  if (!Number.isFinite(value)) return null;
  return Math.max(0, Math.min(100, Math.round(value * 10) / 10));
}

// Usage entries from stdin `rate_limits` (Claude.ai Pro/Max, present only after the first
// API response of a session). Claude Code fills it from the rate-limit headers of its own
// responses, so reading it here needs no network. Either window can be missing: since
// 2026-11-04 the account reports no five_hour window at all. `resets_at` is a Unix epoch in
// SECONDS (not ISO) — ×1000 before Date. Returns { fiveHour, weekly } (each an entry or
// null), or null when rate_limits is absent or neither window is usable.
function usageEntriesFromStdin(data) {
  const rl = data?.rate_limits;
  if (!rl) return null;

  const toEntry = (seg) => {
    if (!seg) return null;
    const pct = normalizePercentage(seg.used_percentage);
    if (pct == null) return null;
    // resets_at is a Unix epoch in SECONDS. Coerce + validate defensively: a non-numeric
    // or out-of-range value would make new Date(...).toISOString() throw, and this path
    // runs outside outputStatus's try/catch. Fall back to resetsAt: null on anything bad.
    let resetsAt = null;
    const epoch = Number(seg.resets_at);
    if (Number.isFinite(epoch) && epoch > 0) {
      const d = new Date(epoch * 1000);
      if (!Number.isNaN(d.getTime())) resetsAt = d.toISOString();
    }
    return { percentage: pct, resetsAt };
  };

  const fiveHour = toEntry(rl.five_hour);
  const weekly = toEntry(rl.seven_day);
  if (!fiveHour && !weekly) return null;
  return { fiveHour, weekly };
}

// When the session's rate_limits were observed. Claude Code re-renders idle sessions too
// (prompt cache expiry, a window reset, mode changes) with readings that can be hours old,
// so the render time says nothing about the data's age. prompt_cache.expires_at is the
// send time of the session's last main-thread request plus the cache TTL; requests that
// don't move it (subagents, compaction) only make the reading look older than it is, which
// is the safe direction. Returns ms, or null when it can't be told (no prompt_cache yet,
// unknown TTL, or a time more than a minute in the future).
function observedAtFromStdin(data, now) {
  const pc = data?.prompt_cache;
  if (!pc) return null;
  const ttlMs = PROMPT_CACHE_TTL_MS[pc.ttl];
  const expiresAt = Number(pc.expires_at);
  if (!ttlMs || !Number.isFinite(expiresAt) || expiresAt <= 0) return null;
  const observedAt = expiresAt * 1000 - ttlMs;
  if (observedAt > now + 60 * 1000) return null;
  return observedAt;
}

// Validate a single usage entry ({ percentage, resetsAt }). Returns true only for a
// finite 0-100 percentage and a parseable (or absent) resetsAt.
function isValidUsageEntry(entry) {
  if (!entry || typeof entry !== 'object') return false;
  if (!Number.isFinite(entry.percentage) || entry.percentage < 0 || entry.percentage > 100) return false;
  if (entry.resetsAt != null && Number.isNaN(new Date(entry.resetsAt).getTime())) return false;
  return true;
}

// Read the cached usage ({ timestamp, data: { fiveHour, weekly } }, either bucket may be
// null but not both). Returns { timestamp, age, data } or null. Age-vs-TTL decisions are
// made by the caller. The legacy single-{percentage,resetsAt} format has neither bucket
// and is ignored.
function readCachedUsage() {
  try {
    const cache = JSON.parse(fs.readFileSync(USAGE_CACHE_FILE, 'utf8'));
    if (!cache || !Number.isFinite(cache.timestamp) || cache.timestamp <= 0) return null;
    // Stamped in the future: the clock was stepped back since. Treat it as missing, so the
    // next observation replaces it instead of being refused until the clock catches up.
    if (cache.timestamp > Date.now() + 60 * 1000) return null;

    const data = cache.data;
    if (!data || typeof data !== 'object') return null;
    if (data.fiveHour != null && !isValidUsageEntry(data.fiveHour)) return null;
    if (data.weekly != null && !isValidUsageEntry(data.weekly)) return null;
    if (data.fiveHour == null && data.weekly == null) return null;

    return { timestamp: cache.timestamp, age: Date.now() - cache.timestamp, data };
  } catch (e) {
    return null;
  }
}

// A temp file name in the cache folder that no other process uses
function tempPath(stem) {
  return path.join(CACHE_DIR, `.${stem}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`);
}

// Writes text to `file` in one step: a reader (another session, the widget) sees the old
// or the new content, never a partial one. Temp files left by runs Claude Code aborted
// mid-write are swept once they are a minute old.
function writeAtomic(file, text) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const tmp = tempPath(path.basename(file));
  try {
    fs.writeFileSync(tmp, text, 'utf8');
    fs.renameSync(tmp, file);
  } finally {
    try { fs.unlinkSync(tmp); } catch (e) {}
  }
  try {
    const cutoff = Date.now() - 60 * 1000;
    for (const name of fs.readdirSync(CACHE_DIR)) {
      if (!/^\.(usage-cache\.json|usage-api\.lock)\.\d+\.[a-z0-9]+\.tmp$/.test(name)) continue;
      const p = path.join(CACHE_DIR, name);
      try { if (fs.statSync(p).mtimeMs < cutoff) fs.unlinkSync(p); } catch (e) {}
    }
  } catch (e) {}
}

// Store a reading observed at `observedAt` (shared across sessions and with the widget).
// Only a newer observation replaces the file, and it replaces it whole: each reading is one
// account-wide header snapshot, so a window missing from the newest one is gone. Two
// sessions writing at the same moment can still leave the older of two close readings;
// the next render corrects it, and the widget also ignores readings older than it shows.
function storeUsage(observedAt, entries) {
  try {
    const cached = readCachedUsage();
    if (cached && cached.timestamp >= observedAt) return;
    writeAtomic(USAGE_CACHE_FILE, JSON.stringify({
      timestamp: observedAt,
      data: { fiveHour: entries.fiveHour || null, weekly: entries.weekly || null }
    }));
  } catch (e) {
    // Best effort: the bars are still rendered from the reading itself
  }
}

// The API lease. Returns true when this process may call the usage API now. The lock is
// created by linking a fully written temp file into place, so it is never seen half
// written by a competing process; EEXIST means another one holds it. An unreadable lock
// (left by an aborted run) counts as held until LEASE_MS after it was made. Taking over an
// expired lock is unlink + link: N processes that see the same expired lock within the same
// millisecond or so can each win (N-1 extra requests; e.g. tmux restoring every session at
// once). Rare enough to accept.
function readLeaseUntil(now) {
  let st;
  try { st = fs.statSync(API_LOCK_FILE); } catch (e) { return null; }
  // Written "in the future": the clock was stepped back since, so the lock means nothing
  if (st.mtimeMs > now + 60 * 1000) return now - 1;
  let until = st.mtimeMs + LEASE_MS;
  try {
    const lock = JSON.parse(fs.readFileSync(API_LOCK_FILE, 'utf8'));
    if (Number.isFinite(lock?.until)) until = lock.until;
  } catch (e) {}
  // Never held for longer than one backoff after it was written
  return Math.min(until, st.mtimeMs + FAILURE_BACKOFF_MS);
}

function tryAcquireApiLease() {
  const now = Date.now();
  const until = readLeaseUntil(now);
  if (until !== null && until > now) return false;
  if (until !== null) {
    try { fs.unlinkSync(API_LOCK_FILE); } catch (e) {}
  }
  let tmp = null;
  try {
    fs.mkdirSync(CACHE_DIR, { recursive: true });
    tmp = tempPath('usage-api.lock');
    fs.writeFileSync(tmp, JSON.stringify({ until: now + LEASE_MS }), 'utf8');
    fs.linkSync(tmp, API_LOCK_FILE);
    return true;
  } catch (e) {
    return false;
  } finally {
    if (tmp) { try { fs.unlinkSync(tmp); } catch (e) {} }
  }
}

// After a failed request: nobody asks the API again until the backoff has passed
function holdApiLease(ms) {
  try {
    writeAtomic(API_LOCK_FILE, JSON.stringify({ until: Date.now() + ms }));
  } catch (e) {}
}

function getCredentials() {
  // Try file first (legacy / Linux / Windows)
  const credsPath = path.join(CONFIG_DIR, '.credentials.json');
  if (fs.existsSync(credsPath)) {
    try {
      return JSON.parse(fs.readFileSync(credsPath, 'utf8'));
    } catch (e) {}
  }

  // Fallback: macOS keychain
  if (os.platform() === 'darwin') {
    try {
      const raw = execSync('security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null', { encoding: 'utf8', timeout: 1000 });
      return JSON.parse(raw.trim());
    } catch (e) {}
  }

  return null;
}

// Calls the usage API once. callback(entries) with { fiveHour, weekly } on success (either
// may be null, not both), callback(null) on any failure. Called at most once per process.
function getApiUsage(callback) {
  let done = false;
  const finish = (entries) => {
    if (done) return;
    done = true;
    callback(entries);
  };

  try {
    // Read credentials (file or macOS keychain)
    const creds = getCredentials();
    if (!creds) {
      return finish(null);
    }

    const accessToken = creds.claudeAiOauth?.accessToken;

    if (!accessToken) {
      return finish(null);
    }

    // Adaptive timeout: if cache exists, be faster (1200ms); if not, be patient (1500ms)
    // API typically takes ~850ms, so 1200ms gives reasonable headroom
    const hasCache = fs.existsSync(USAGE_CACHE_FILE);
    const timeout = hasCache ? 1200 : 1500;

    // Make API call with adaptive timeout
    const req = https.request({
      hostname: 'api.anthropic.com',
      path: '/api/oauth/usage',
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
        'anthropic-beta': 'oauth-2025-04-20'
      },
      timeout: timeout
    }, (res) => {
      let data = '';

      res.on('data', chunk => data += chunk);
      // Closed before the body ended (no 'end' follows): a failure. After 'end' it is a no-op.
      res.on('close', () => finish(null));
      res.on('end', () => {
        try {
          if (res.statusCode !== 200) return finish(null);
          const usage = JSON.parse(data);

          // Either window may be missing (five_hour has been null since 2026-11-04).
          // Normalize utilization first so a missing/non-finite value omits the bar
          // instead of rendering "NaN%" or an out-of-range percentage.
          const toEntry = (seg) => {
            const pct = seg ? normalizePercentage(seg.utilization) : null;
            return pct != null ? { percentage: pct, resetsAt: seg.resets_at || null } : null;
          };
          const fiveHour = toEntry(usage.five_hour);
          const weekly = toEntry(usage.seven_day);
          if (!fiveHour && !weekly) return finish(null);

          // Observed now; shared with the other sessions and the widget
          storeUsage(Date.now(), { fiveHour, weekly });
          finish({ fiveHour, weekly });
        } catch (e) {
          finish(null);
        }
      });
    });

    req.on('error', () => finish(null));
    req.on('timeout', () => {
      req.destroy();
      finish(null);
    });

    req.end();
  } catch (e) {
    finish(null);
  }
}

// Get usage, cache-first. Only reached when stdin has no rate_limits (a session before its
// first response, or no Pro/Max plan).
function getUsageWithCache(callback) {
  const cached = readCachedUsage();
  const cachedBars = (maxAge) => (cached && cached.age < maxAge)
    ? buildUsageBars(cached.data.fiveHour, cached.data.weekly) : null;

  // A recent observation from any session -> render it and skip the API entirely.
  if (cached && cached.age < FRESH_TTL_MS) {
    return callback(cachedBars(FRESH_TTL_MS));
  }

  // Another process is asking (or the last request failed): show what we have.
  if (!tryAcquireApiLease()) {
    return callback(cachedBars(STALE_TTL_MS));
  }

  getApiUsage((entries) => {
    if (entries) {
      callback(buildUsageBars(entries.fiveHour, entries.weekly));
    } else {
      holdApiLease(FAILURE_BACKOFF_MS);
      // API failed/timed out, but a recent cache exists -> show it instead of nothing.
      callback(cachedBars(STALE_TTL_MS));
    }
  });
}

function getCurrentTask(sessionId) {
  if (!sessionId) return '';

  const homeDir = os.homedir();
  const todosDir = path.join(homeDir, '.claude', 'todos');

  if (!fs.existsSync(todosDir)) return '';

  try {
    const files = fs.readdirSync(todosDir)
      .filter(f => f.startsWith(sessionId) && f.includes('-agent-') && f.endsWith('.json'))
      .map(f => ({ name: f, mtime: fs.statSync(path.join(todosDir, f)).mtime }))
      .sort((a, b) => b.mtime - a.mtime);

    if (files.length > 0) {
      const todos = JSON.parse(fs.readFileSync(path.join(todosDir, files[0].name), 'utf8'));
      const inProgress = todos.find(t => t.status === 'in_progress');
      if (inProgress) return inProgress.activeForm || '';
    }
  } catch (e) {}

  return '';
}

// Main
function outputStatus(data, usage) {
  try {
    const model = shortenModel(data?.model?.display_name || 'Claude');
    const dir = data?.workspace?.current_dir || process.cwd();
    const dirname = path.basename(dir);
    const branch = getGitBranch(dir);
    const effort = data?.effort?.level || '';
    const sessionId = data?.session_id || '';
    const remaining = data?.context_window?.remaining_percentage;

    const contextBar = getContextBar(remaining);
    const task = getCurrentTask(sessionId);
    const parts = [];
    parts.push(branch ? `${dirname} ${colors.dim}⎇ ${branch}${colors.reset}` : dirname);
    parts.push(effort ? `${model}${getEffortColor(effort)} · ${effort}${colors.reset}` : model);
    parts.push(`CTX ${contextBar}`);

    if (usage?.current) parts.push(`5h ${usage.current}`);
    if (usage?.weekly) parts.push(`7d ${usage.weekly}`);

    if (task) parts.push(`${colors.dim}${task}${colors.reset}`);
    process.stdout.write(parts.join(' \u2502 '));
  } catch (e) {
    process.stdout.write('Status unavailable');
  }
}

function outputFallback(usage) {
  const contextBar = getContextBar(undefined);
  const parts = ['~', 'Claude', `CTX ${contextBar}`];
  if (usage?.current) parts.push(`5h ${usage.current}`);
  if (usage?.weekly) parts.push(`7d ${usage.weekly}`);
  process.stdout.write(parts.join(' \u2502 '));
}

// Resolve usage bars for a (possibly null) parsed stdin payload.
// Order: API-key users get none; otherwise prefer stdin `rate_limits` (no network),
// then fall back to the cache+API flow when stdin lacks it (cold start / non-Pro/Max).
function resolveUsage(data, callback) {
  if (IS_API_KEY) {
    return callback(null);
  }
  const entries = usageEntriesFromStdin(data);
  if (entries) {
    const observedAt = observedAtFromStdin(data, Date.now());
    if (observedAt !== null) storeUsage(observedAt, entries);
    return callback(buildUsageBars(entries.fiveHour, entries.weekly));
  }
  getUsageWithCache(callback);
}

// Process with timeout
// Parse the accumulated stdin into a payload object, or null if empty/unparseable.
function parseInput(input) {
  if (!input || input.length === 0) return null;
  try {
    return JSON.parse(input);
  } catch (e) {
    return null;
  }
}

// Resolve usage for `data` (preferring stdin rate_limits), then render and exit.
function emit(data) {
  resolveUsage(data, (usage) => {
    if (data) {
      outputStatus(data, usage);
    } else {
      outputFallback(usage);
    }
    process.exit(0);
  });
}

if (process.stdin.isTTY) {
  emit(null);
} else {
  let input = '';
  let timeoutReached = false;

  const overallTimeout = IS_API_KEY ? 500 : (fs.existsSync(USAGE_CACHE_FILE) ? 1300 : 1600);

  const timeout = setTimeout(() => {
    timeoutReached = true;
    emit(parseInput(input));
  }, overallTimeout);

  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => input += chunk);
  process.stdin.on('end', () => {
    if (timeoutReached) return;
    clearTimeout(timeout);
    emit(parseInput(input));
  });
}
