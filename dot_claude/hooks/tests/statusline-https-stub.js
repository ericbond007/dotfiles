// Offline stand-in for https.request, loaded with NODE_OPTIONS=--require.
// Each call appends a line to $STUB_LOG; the response comes from
// $STUB_STATUS (default 200), $STUB_BODY (default "{}") and $STUB_DELAY_MS.
// Mode "hang" never answers, so the caller's timeout path runs; "drop" closes the
// connection after part of the body, without 'end'.
const https = require('https');
const fs = require('fs');
const { EventEmitter } = require('events');

https.request = function (opts, onResponse) {
  // Tests only ever use fake tokens; the tail is enough to tell which file it came from
  const auth = String((opts.headers || {}).Authorization || '').slice(-8);
  try { fs.appendFileSync(process.env.STUB_LOG, JSON.stringify({ t: Date.now(), pid: process.pid, path: opts.path, auth }) + '\n'); } catch (e) {}
  const req = new EventEmitter();
  let timer = null;
  let timeoutTimer = null;
  req.end = () => {
    if (process.env.STUB_MODE === 'hang') return;
    timer = setTimeout(() => {
      const res = new EventEmitter();
      res.statusCode = Number(process.env.STUB_STATUS || 200);
      onResponse(res);
      res.emit('data', process.env.STUB_BODY || '{}');
      // A closed socket leaves no timeout pending
      if (process.env.STUB_MODE === 'drop') { clearTimeout(timeoutTimer); res.emit('close'); return; }
      res.emit('end');
      res.emit('close');
    }, Number(process.env.STUB_DELAY_MS || 0));
  };
  req.destroy = () => { if (timer) clearTimeout(timer); };
  // A real socket keeps the process alive until its timeout fires; so does this timer
  if (opts.timeout) timeoutTimer = setTimeout(() => req.emit("timeout"), opts.timeout);
  return req;
};
