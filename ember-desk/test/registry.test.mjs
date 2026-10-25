import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { writeFileSync, mkdirSync } from 'node:fs';
import { Registry, validateChannel, ChannelShapeError } from '../registry.mjs';
import { tmpDir, cleanEnv, stubRun } from './helpers.mjs';
import { DEFAULT_CONFIG } from '../config.mjs';

function ctxFor(dir) {
  return {
    config: () => ({ ...DEFAULT_CONFIG }), secrets: {}, env: cleanEnv(), stateDir: dir, log: () => {}, emit: () => {}, session: () => null, changed: () => {},
    overrides: { toast: { run: stubRun(), engine: 'winrt' }, tts: { run: stubRun() }, mic: { ffmpegOk: false } },
  };
}

test('loads the real channels dir with the uniform interface', async (t) => {
  const dir = tmpDir(t);
  const r = await new Registry({ ctx: ctxFor(dir) }).loadDir();
  const ids = r.all().map((c) => c.id).sort();
  assert.deepEqual(ids, ['ask', 'feed', 'meeting-chat', 'meeting-jitsi', 'meeting-lares', 'meeting-zoom', 'mic', 'toast', 'tts']);
  for (const s of r.list()) {
    assert.deepEqual(Object.keys(s).filter((k) => k !== 'extra').sort(), ['configured', 'detail', 'enabled', 'id', 'kind', 'name', 'running']);
    assert.equal(typeof s.detail, 'string');
  }
  const lares = r.statusOf(r.get('meeting-lares'));
  assert.equal(lares.configured, false);
  assert.match(lares.detail, /anonym_supervisor/);
  assert.equal(r.statusOf(r.get('meeting-zoom')).configured, false);
  assert.equal(r.statusOf(r.get('mic')).configured, false);
  assert.equal(r.statusOf(r.get('mic')).detail, '找不到 ffmpeg');
});

test('rejects bad channel shapes', () => {
  const ok = { id: 'x', kind: 'output', name: 'X', describe() {}, configured() {}, start() {}, stop() {}, status() {} };
  assert.equal(validateChannel(ok), ok);
  for (const bad of [null, { ...ok, id: 'Bad Id' }, { ...ok, kind: 'other' }, { ...ok, name: '' }, { ...ok, start: undefined }, { ...ok, status: 1 }, { ...ok, send: 'x' }]) {
    assert.throws(() => validateChannel(bad), ChannelShapeError);
  }
  const r = new Registry({ ctx: {} });
  r.add(ok);
  assert.throws(() => r.add({ ...ok }), /duplicate/);
});

test('loadDir rejects a module without a factory, or a factory returning a bad shape', async (t) => {
  const dir = tmpDir(t);
  const a = path.join(dir, 'a'); mkdirSync(a);
  writeFileSync(path.join(a, 'x.mjs'), 'export default 42;');
  await assert.rejects(new Registry({ ctx: {} }).loadDir(a), ChannelShapeError);
  const b = path.join(dir, 'b'); mkdirSync(b);
  writeFileSync(path.join(b, 'y.mjs'), "export default () => ({ id: 'y', kind: 'input', name: 'Y' });");
  await assert.rejects(new Registry({ ctx: {} }).loadDir(b), /describe\(\) required/);
});

test('start / stop / broadcast to running outputs only', async (t) => {
  const changes = [];
  const r = new Registry({ ctx: {}, onChange: (s) => changes.push(s.id), isEnabled: (id) => id === 'o1' });
  const mk = (id, kind, extra = {}) => {
    let running = false;
    const got = [];
    return { id, kind, name: id, got, describe: () => id, configured: () => true, start: async () => { running = true; }, stop: async () => { running = false; }, status: () => ({ running }), send: async (m) => { got.push(m); return true; }, ...extra };
  };
  const o1 = r.add(mk('o1', 'output'));
  const o2 = r.add(mk('o2', 'output'));
  const i1 = r.add(mk('i1', 'input'));
  r.add(mk('nc', 'output', { configured: () => false }));
  assert.equal((await r.start('o1')).running, true);
  assert.equal(r.statusOf(o1).enabled, true);
  await r.start('i1');
  await assert.rejects(r.start('nc'), (e) => e.status === 400);
  await assert.rejects(r.start('nope'), (e) => e.status === 404);
  const res = await r.broadcast({ text: 'hi' });
  assert.deepEqual(res, { o1: true });
  assert.equal(o1.got.length, 1);
  assert.equal(o2.got.length, 0);
  assert.equal(i1.got.length, 0);
  await r.stop('o1');
  assert.deepEqual(await r.broadcast({ text: 'x' }), {});
  assert.deepEqual(changes, ['o1', 'i1', 'o1']);
});
