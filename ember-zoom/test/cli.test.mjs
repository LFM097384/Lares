import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { configFromEnv, UsageError } from '../index.mjs';

const ENTRY = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'index.mjs');
const BASE_ENV = { ZOOM_CLIENT_ID: 'c', ZOOM_CLIENT_SECRET: 's', ZOOM_WEBHOOK_SECRET: 'w' };

function run(env, { stdin } = {}) {
  const clean = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(ZOOM_|LARES_AI_LLM_|EMBER_)/.test(k)));
  const p = spawn(process.execPath, [ENTRY], { env: { ...clean, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = [];
  let buf = '';
  p.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { lines.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1); } if (stdin) stdin(p, lines); });
  p.stderr.resume();
  return new Promise((resolve) => p.on('exit', (code) => resolve({ code, lines })));
}

test('configFromEnv: required vars, PORT / EMBER_K validation', () => {
  assert.throws(() => configFromEnv({}), UsageError);
  assert.throws(() => configFromEnv({ ...BASE_ENV, EMBER_K: '0' }), UsageError);
  assert.throws(() => configFromEnv({ ...BASE_ENV, PORT: 'x' }), UsageError);
  const c = configFromEnv({ ...BASE_ENV, PORT: '9000', EMBER_K: '3', EMBER_ZOOM_POST_CHAT: '1' });
  assert.equal(c.port, 9000);
  assert.equal(c.k, 3);
  assert.equal(c.postChat, true);
  assert.equal(c.asrKind, 'zoom');
});

test('CLI: missing env → exit 2 with JSON error', async () => {
  const r = await run({});
  assert.equal(r.code, 2);
  assert.ok(r.lines.some((l) => l.ev === 'error' && /ZOOM_CLIENT_ID/.test(l.message)));
  assert.deepEqual(r.lines.at(-1), { ev: 'exit', code: 2 });
});

test('CLI: listens, then {"cmd":"stop"} on stdin → clean exit 0', async () => {
  let sent = false;
  const r = await run({ ...BASE_ENV, PORT: '0' }, {
    stdin: (p, lines) => {
      if (!sent && lines.some((l) => l.ev === 'listening')) { sent = true; p.stdin.write('{"cmd":"stop"}\n'); }
    },
  });
  assert.equal(r.code, 0);
  const listening = r.lines.find((l) => l.ev === 'listening');
  assert.ok(listening.port > 0);
  assert.deepEqual(r.lines.at(-1), { ev: 'exit', code: 0 });
});
