import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, writeFileSync, readFileSync } from 'node:fs';
import { testDaemon, tmpDir, cleanEnv, DESK } from './helpers.mjs';
import { startDaemon } from '../daemon.mjs';
import { files } from '../paths.mjs';
import { readJson } from '../config.mjs';

const runNode = (args, env, input) => new Promise((resolve) => {
  const p = spawn(process.execPath, args, { env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  let out = '';
  p.stdout.on('data', (d) => { out += d; });
  if (input !== undefined) p.stdin.end(input);
  p.on('exit', (code) => resolve({ code, out }));
});

test('first start writes config defaults, token, state.json; clean stop removes state + lock', async (t) => {
  const dir = tmpDir(t);
  const d = await testDaemon(t, { dir });
  const f = files(dir);
  assert.deepEqual(readJson(f.config).enabledChannels, ['feed', 'toast']);
  assert.deepEqual(readJson(f.config).jitsiHosts, ['localhost:8443']);
  assert.match(readFileSync(f.token, 'utf8'), /^[0-9a-f]{64}$/);
  const st = readJson(f.state);
  assert.equal(st.port, d.port);
  assert.equal(st.pid, process.pid);
  assert.equal(st.version, '0.1.0');
  assert.ok(existsSync(f.lock));
  await d.stop();
  assert.ok(!existsSync(f.state));
  assert.ok(!existsSync(f.lock));
});

test('single instance: second start → already_running (in-process and real process exit 3)', async (t) => {
  const dir = tmpDir(t);
  const d = await testDaemon(t, { dir });
  const evs = [];
  const second = await startDaemon({ stateDir: dir, env: cleanEnv(), secrets: {}, stdout: (e) => evs.push(e) });
  assert.equal(second.already, true);
  assert.equal(second.port, d.port);
  assert.deepEqual(evs, [{ ev: 'already_running', port: d.port }]);
  const r = await runNode([path.join(DESK, 'daemon.mjs')], cleanEnv({ EMBER_DESK_HOME: dir }));
  assert.equal(r.code, 3);
  assert.deepEqual(JSON.parse(r.out.trim()), { ev: 'already_running', port: d.port });
  assert.equal(readJson(files(dir).state).pid, process.pid, 'state.json untouched');
});

test('stale lock (dead pid, port not answering) is taken over', async (t) => {
  const dir = tmpDir(t);
  const dead = spawnSync(process.execPath, ['-e', 'console.log(process.pid)'], { encoding: 'utf8' }).stdout.trim();
  const f = files(dir);
  const { mkdirSync } = await import('node:fs');
  mkdirSync(dir, { recursive: true });
  writeFileSync(f.lock, dead);
  writeFileSync(f.state, JSON.stringify({ pid: Number(dead), port: 1, startedAt: 'x', version: '0.1.0' }));
  const d = await testDaemon(t, { dir });
  assert.ok(!d.already);
  assert.equal(readFileSync(f.lock, 'utf8'), String(process.pid));
  assert.equal(readJson(f.state).port, d.port);
});

test('real daemon process: CLI status / quit, exit code 0, files cleaned', async (t) => {
  const dir = tmpDir(t);
  const env = cleanEnv({ EMBER_DESK_HOME: dir });
  const p = spawn(process.execPath, [path.join(DESK, 'daemon.mjs')], { env, stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
  t.after(() => { try { p.kill(); } catch { /* */ } });
  const exited = new Promise((r) => p.on('exit', (code) => r(code)));
  await new Promise((r) => p.stdout.once('data', r));
  const cli = path.join(DESK, 'cli.mjs');
  const s = await runNode([cli, 'status', '--json'], env);
  assert.equal(s.code, 0);
  assert.equal(JSON.parse(s.out).state, 'idle');
  const q = await runNode([cli, 'quit', '--json'], env);
  assert.equal(q.code, 0);
  assert.equal(await exited, 0);
  assert.ok(!existsSync(files(dir).state));
  const s2 = await runNode([cli, 'status', '--json'], env);
  assert.equal(s2.code, 1);
  assert.equal(JSON.parse(s2.out).error, 'not_running');
});

test('daemon stops on stdin {"cmd":"stop"}', async (t) => {
  const dir = tmpDir(t);
  const p = spawn(process.execPath, [path.join(DESK, 'daemon.mjs')], { env: cleanEnv({ EMBER_DESK_HOME: dir }), stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
  t.after(() => { try { p.kill(); } catch { /* */ } });
  const exited = new Promise((r) => p.on('exit', (code) => r(code)));
  await new Promise((r) => p.stdout.once('data', r));
  p.stdin.write('{"cmd":"stop"}\n');
  assert.equal(await exited, 0);
  assert.ok(!existsSync(files(dir).lock));
});
