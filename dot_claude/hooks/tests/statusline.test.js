// Tests for ~/.claude/hooks/statusline.js. Run: node --test ~/.claude/hooks/tests/statusline.test.js
// (STATUSLINE=<path> tests another copy).
// Every run gets its own HOME and the https stub, so nothing touches ~/.claude or the network.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const SCRIPT = process.env.STATUSLINE || path.join(__dirname, '..', 'statusline.js');
const STUB = path.join(__dirname, 'statusline-https-stub.js');
const H = 3600 * 1000;

// Every sandbox is removed when the run ends
const sandboxes = [];
process.on('exit', () => { for (const d of sandboxes) { try { fs.rmSync(d, { recursive: true, force: true }); } catch (e) {} } });

function sandbox() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sltest-'));
  sandboxes.push(home);
  const claude = path.join(home, '.claude');
  fs.mkdirSync(path.join(claude, 'cache'), { recursive: true });
  fs.writeFileSync(path.join(claude, '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: 'fake-token-HOMETOKEN' } }));
  const box = {
    home, claude,
    cacheFile: path.join(claude, 'cache', 'usage-cache.json'),
    lockFile: path.join(claude, 'cache', 'usage-api.lock'),
    stubLog: path.join(home, 'stub.log'),
    calls() { try { return fs.readFileSync(box.stubLog, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); } catch (e) { return []; } },
    cache() { try { return JSON.parse(fs.readFileSync(box.cacheFile, 'utf8')); } catch (e) { return null; } },
    lock() { try { return JSON.parse(fs.readFileSync(box.lockFile, 'utf8')); } catch (e) { return null; } },
    env(extra) {
      const env = { ...process.env, HOME: home, STUB_LOG: box.stubLog, NODE_OPTIONS: `--require ${STUB}`, ...extra };
      delete env.CLAUDE_CONFIG_DIR;
      delete env.ANTHROPIC_API_KEY;
      if (extra && extra.CLAUDE_CONFIG_DIR) env.CLAUDE_CONFIG_DIR = extra.CLAUDE_CONFIG_DIR;
      return env;
    },
    run(input, extra) {
      const r = spawnSync(process.execPath, [SCRIPT], { input: JSON.stringify(input), env: box.env(extra), encoding: 'utf8', timeout: 8000 });
      return r.stdout;
    },
    runAsync(input, extra) {
      return new Promise((resolve) => {
        const p = spawn(process.execPath, [SCRIPT], { env: box.env(extra) });
        let out = '';
        p.stdout.on('data', (d) => out += d);
        p.on('close', () => resolve(out));
        p.stdin.end(JSON.stringify(input));
      });
    }
  };
  return box;
}

// A stdin payload as Claude Code sends it: rate_limits plus prompt_cache stamped so that
// the reading was observed at `observedAt` (ms).
function stdin({ five, seven, observedAt, ttl = '1h', noPromptCache = false }) {
  const rl = {};
  if (five) rl.five_hour = { used_percentage: five, resets_at: Math.floor((Date.now() + 2 * H) / 1000) };
  if (seven) rl.seven_day = { used_percentage: seven, resets_at: Math.floor((Date.now() + 72 * H) / 1000) };
  const ttlMs = { '5m': 300000, '1h': 3600000 }[ttl] || 3600000;
  const data = { model: { display_name: 'Opus' }, workspace: { current_dir: '/tmp' }, session_id: 'test' };
  if (five || seven) data.rate_limits = rl;
  if (!noPromptCache) data.prompt_cache = { ttl, expires_at: Math.ceil((observedAt + ttlMs) / 1000), requests: 3 };
  return data;
}

const COLD = { model: { display_name: 'Opus' }, workspace: { current_dir: '/tmp' }, session_id: 'cold' };
const WEEKLY_ONLY_BODY = JSON.stringify({ five_hour: null, seven_day: { utilization: 93.0, resets_at: '2026-11-11T06:00:00+00:00' } });

function writeCache(box, timestamp, data) {
  fs.writeFileSync(box.cacheFile, JSON.stringify({ timestamp, data }));
}

test('T1 weekly-only stdin is stored with its observation time, shown, no API call', () => {
  const b = sandbox();
  const observedAt = Date.now() - 30000;
  const out = b.run(stdin({ seven: 93.4, observedAt }));
  const c = b.cache();
  assert.ok(c, 'cache written');
  assert.ok(Math.abs(c.timestamp - observedAt) < 1000, 'timestamp = observation time');
  assert.strictEqual(c.data.fiveHour, null);
  assert.strictEqual(c.data.weekly.percentage, 93.4);
  assert.match(c.data.weekly.resetsAt, /^\d{4}-\d\d-\d\dT/);
  assert.match(out, /7d .*93%/);
  assert.doesNotMatch(out, /5h /);
  assert.strictEqual(b.calls().length, 0);
});

test('T2 both windows are stored and shown', () => {
  const b = sandbox();
  const out = b.run(stdin({ five: 12.5, seven: 40, observedAt: Date.now() - 1000 }));
  const c = b.cache();
  assert.strictEqual(c.data.fiveHour.percentage, 12.5);
  assert.strictEqual(c.data.weekly.percentage, 40);
  assert.match(out, /5h .*13%/);
  assert.match(out, /7d .*40%/);
});

test('T3 an older observation does not replace a newer one', () => {
  const b = sandbox();
  const t = Date.now() - 60000;
  writeCache(b, t, { fiveHour: null, weekly: { percentage: 95, resetsAt: null } });
  b.run(stdin({ seven: 90, observedAt: t - 5000 }));
  assert.strictEqual(b.cache().data.weekly.percentage, 95);
  assert.strictEqual(b.cache().timestamp, t);
});

test('T4 a newer observation replaces the file, even with a lower value', () => {
  const b = sandbox();
  const t = Date.now() - 60000;
  writeCache(b, t, { fiveHour: null, weekly: { percentage: 95, resetsAt: null } });
  b.run(stdin({ seven: 2, observedAt: t + 5000 }));
  assert.strictEqual(b.cache().data.weekly.percentage, 2);
});

test('T5 no usable prompt_cache: shown but not stored, no API call', () => {
  for (const variant of [{ noPromptCache: true }, { ttl: '2h' }]) {
    const b = sandbox();
    const out = b.run(stdin({ seven: 50, observedAt: Date.now(), ...variant }));
    assert.strictEqual(b.cache(), null, JSON.stringify(variant));
    assert.match(out, /7d .*50%/);
    assert.strictEqual(b.calls().length, 0);
  }
});

test('T6 an observation more than a minute in the future is not stored', () => {
  const b = sandbox();
  b.run(stdin({ seven: 50, observedAt: Date.now() + 5 * 60000 }));
  assert.strictEqual(b.cache(), null);
});

test('T7 cold session, no cache: exactly one API call; a weekly-only 200 is stored', () => {
  const b = sandbox();
  const before = Date.now();
  const out = b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 1);
  const c = b.cache();
  assert.strictEqual(c.data.fiveHour, null);
  assert.strictEqual(c.data.weekly.percentage, 93);
  assert.ok(c.timestamp >= before);
  assert.match(out, /7d .*93%/);
});

test('T8 two concurrent cold fallbacks make one API call between them', async () => {
  const b = sandbox();
  await Promise.all([
    b.runAsync(COLD, { STUB_BODY: WEEKLY_ONLY_BODY, STUB_DELAY_MS: '300' }),
    b.runAsync(COLD, { STUB_BODY: WEEKLY_ONLY_BODY, STUB_DELAY_MS: '300' })
  ]);
  assert.strictEqual(b.calls().length, 1);
});

test('T9 a failed request holds the lease for the backoff and shows no stale bars', () => {
  for (const extra of [{ STUB_STATUS: '429', STUB_BODY: '{"error":{"type":"rate_limit_error"}}' },
                       { STUB_BODY: '{"five_hour":null,"seven_day":null}' },
                       { STUB_MODE: 'hang' }]) {
    const b = sandbox();
    const out = b.run(COLD, extra);
    assert.strictEqual(b.calls().length, 1, JSON.stringify(extra));
    const lock = b.lock();
    assert.ok(lock && lock.until > Date.now() + 4 * 60000 && lock.until <= Date.now() + 5 * 60000, JSON.stringify(extra));
    assert.doesNotMatch(out, /7d /);
    assert.match(out, /CTX /, 'status line still printed');
  }
});

test('T9b after a failure a cache under 30 min is shown, an older one is not', () => {
  for (const [ageMin, shown] of [[20, true], [40, false]]) {
    const b = sandbox();
    writeCache(b, Date.now() - ageMin * 60000, { fiveHour: null, weekly: { percentage: 61, resetsAt: null } });
    const out = b.run(COLD, { STUB_STATUS: '429' });
    assert.strictEqual(b.calls().length, 1, `${ageMin} min: one call (cache older than 10 min)`);
    if (shown) assert.match(out, /7d .*61%/, `${ageMin} min`);
    else assert.doesNotMatch(out, /7d /, `${ageMin} min`);
    assert.match(out, /CTX /, `${ageMin} min: status line printed`);
  }
});

test('T15 a connection dropped mid-body counts as a failure: backoff, and a status line is printed', () => {
  const b = sandbox();
  const out = b.run(COLD, { STUB_MODE: 'drop', STUB_BODY: '{"five_hour":null,"seven' });
  assert.strictEqual(b.calls().length, 1);
  const lock = b.lock();
  assert.ok(lock && lock.until > Date.now() + 4 * 60000, 'backoff written');
  assert.match(out, /CTX /, 'status line still printed');
});

test('T10 inside the lease no call is made; the same setup without it makes one', () => {
  const b = sandbox();
  b.run(COLD, { STUB_STATUS: '429' });           // takes the lease, fails -> 5 min backoff
  assert.strictEqual(b.calls().length, 1);
  b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 1, 'no call while the backoff holds');
  fs.writeFileSync(b.lockFile, JSON.stringify({ until: Date.now() - 1000 }));
  b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 2, 'expired lease -> one call');
});

test('T11 CLAUDE_CONFIG_DIR: credentials and cache come from that folder', () => {
  const b = sandbox();
  const other = path.join(b.home, 'other-account');
  fs.mkdirSync(other);
  fs.writeFileSync(path.join(other, '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: 'fake-token-OTHERTOK' } }));
  b.run(COLD, { CLAUDE_CONFIG_DIR: other, STUB_BODY: WEEKLY_ONLY_BODY });
  const calls = b.calls();
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(calls[0].auth, 'OTHERTOK');
  assert.ok(fs.existsSync(path.join(other, 'cache', 'usage-cache.json')));
  assert.strictEqual(b.cache(), null, 'default account untouched');
});

test('T12 concurrent writers: every read parses; old temp files are swept, fresh ones kept', async () => {
  const b = sandbox();
  const cacheDir = path.dirname(b.cacheFile);
  const oldTmp = path.join(cacheDir, '.usage-cache.json.1.old.tmp');
  const freshTmp = path.join(cacheDir, '.usage-cache.json.2.fresh.tmp');
  fs.writeFileSync(oldTmp, 'x');
  fs.writeFileSync(freshTmp, 'x');
  const past = new Date(Date.now() - 2 * 60000);
  fs.utimesSync(oldTmp, past, past);

  let reads = 0, bad = 0, done = false;
  const reader = (async () => {
    while (!done) {
      try { JSON.parse(fs.readFileSync(b.cacheFile, 'utf8')); reads++; }
      catch (e) { if (e.code !== 'ENOENT') bad++; }
      await new Promise((r) => setImmediate(r));
    }
  })();
  const base = Date.now() - 60000;
  await Promise.all(Array.from({ length: 20 }, (_, i) => b.runAsync(stdin({ seven: 10 + i, observedAt: base + i * 100 }))));
  done = true;
  await reader;
  assert.strictEqual(bad, 0, `${bad} partial reads`);
  assert.ok(reads > 20, `reader ran (${reads} reads)`);
  assert.ok(!fs.existsSync(oldTmp), 'old temp file swept');
  assert.ok(fs.existsSync(freshTmp), 'fresh temp file kept');
  const leftovers = fs.readdirSync(cacheDir).filter((n) => n.endsWith('.tmp') && !n.includes('fresh'));
  assert.deepStrictEqual(leftovers, []);
});

test('T12b the sweep leaves every other file in the cache folder alone', () => {
  const b = sandbox();
  const dir = path.dirname(b.cacheFile);
  const keep = [path.join(dir, 'changelog.md'), path.join(dir, '.other.123.abc.tmp')];
  const past = new Date(Date.now() - 3600000);
  for (const f of keep) { fs.writeFileSync(f, 'x'); fs.utimesSync(f, past, past); }
  b.run(stdin({ seven: 50, observedAt: Date.now() - 1000 }));
  assert.ok(b.cache(), 'a write (and so a sweep) happened');
  for (const f of keep) assert.ok(fs.existsSync(f), f);
});

test('T13 cold session with a 5-minute-old weekly-only cache: no call, 7d shown', () => {
  const b = sandbox();
  writeCache(b, Date.now() - 5 * 60000, { fiveHour: null, weekly: { percentage: 88, resetsAt: null } });
  const out = b.run(COLD);
  assert.strictEqual(b.calls().length, 0);
  assert.match(out, /7d .*88%/);
});

test('L1 an unreadable lock made just now counts as held', () => {
  const b = sandbox();
  fs.writeFileSync(b.lockFile, '');
  b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 0);
});

test('L2 an unreadable lock two minutes old is taken over', () => {
  const b = sandbox();
  fs.writeFileSync(b.lockFile, '');
  const past = new Date(Date.now() - 2 * 60000);
  fs.utimesSync(b.lockFile, past, past);
  b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 1);
});

test('L3 a lock claiming hours (bad until) holds at most one backoff after it was written', () => {
  const b = sandbox();
  fs.writeFileSync(b.lockFile, JSON.stringify({ until: Date.now() + 10 * H }));
  b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 0, 'written just now: held');
  const past = new Date(Date.now() - 6 * 60000);
  fs.utimesSync(b.lockFile, past, past);
  b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 1, 'written 6 min ago: expired despite until');
});

test('L4 a lock written in the future (clock stepped back) is taken over', () => {
  const b = sandbox();
  fs.writeFileSync(b.lockFile, JSON.stringify({ until: Date.now() + 2 * H }));
  const future = new Date(Date.now() + H);
  fs.utimesSync(b.lockFile, future, future);
  b.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(b.calls().length, 1);
});

test('L5 a cache stamped in the future (clock stepped back) is replaced and not trusted', () => {
  const b = sandbox();
  writeCache(b, Date.now() + 3 * 3600000, { fiveHour: null, weekly: { percentage: 99, resetsAt: null } });
  b.run(stdin({ seven: 50, observedAt: Date.now() - 1000 }));
  assert.strictEqual(b.cache().data.weekly.percentage, 50, 'stdin observation replaces it');
  const c = sandbox();
  writeCache(c, Date.now() + 3 * 3600000, { fiveHour: null, weekly: { percentage: 99, resetsAt: null } });
  c.run(COLD, { STUB_BODY: WEEKLY_ONLY_BODY });
  assert.strictEqual(c.calls().length, 1, 'cold session does not treat it as fresh');
});

test('D1 a bar is filled from the value it shows', () => {
  const b = sandbox();
  const cells = (out) => (out.match(/7d [^█░]*([█░]+)/) || [])[1];
  const a = b.run(stdin({ seven: 91.6, observedAt: Date.now() - 2000 }));
  const z = b.run(stdin({ seven: 92.0, observedAt: Date.now() - 1000 }));
  assert.match(a, /92%/);
  assert.strictEqual(cells(a), cells(z));
});

test('T14 an old cache is still shown while another process holds the lease', () => {
  const b = sandbox();
  writeCache(b, Date.now() - 20 * 60000, { fiveHour: null, weekly: { percentage: 77, resetsAt: null } });
  fs.writeFileSync(b.lockFile, JSON.stringify({ until: Date.now() + 30000 }));
  const out = b.run(COLD);
  assert.strictEqual(b.calls().length, 0);
  assert.match(out, /7d .*77%/);
});
