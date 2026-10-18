// node --test ember-lares/  —— Lares 插件:线协议映射(lares.anon / anon_*)、进程契约(参数 / 退出码)、密封密钥握手。不出网、不进 LiveKit。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { EventEmitter } from 'node:events';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MockAsr, generateEd25519, signEd25519, approvalMessage, seal, generateX25519, AGENT_NAME } from '../../ember/index.mjs';
import { runEmberLares, parseArgs, UsageError, EXIT } from '../index.mjs';
import { laresPort, isLaresHuman } from '../port.mjs';
import { AnonRoom, anonAgentUserId, ANON_TOPIC } from '../room.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/// LaresRoom 事件面替身(AnonRoom 的形状):'anon' / 'names' / 'joined' / 'left' / 'audio' / 'disconnected'
class FakeRoom {
  constructor(people = []) {
    this.userId = 'u_ai_anon_test';
    this.handlers = {};
    this.sent = [];
    this.server = [];
    this.people = new Map(people.map((p) => [p.id, p.name]));
    this.left = false;
  }
  on(k, cb) { (this.handlers[k] ??= []).push(cb); return this; }
  fire(k, ...a) { for (const h of this.handlers[k] ?? []) h(...a); }
  async join() { return this; }
  async leave() { this.left = true; }
  nameOf(id) { return this.people.get(id) ?? ''; }
  participants() { return [...this.people].map(([id, name]) => ({ id, name })); }
  async publishAnon(obj, to = null) { this.sent.push({ obj: JSON.parse(JSON.stringify(obj)), to }); }
  notifyServer(msg) { this.server.push(JSON.parse(JSON.stringify(msg))); }
  msg(from, obj) { this.fire('anon', from, obj); }
  last(t) { return this.sent.filter((s) => s.obj.t === t).map((s) => s.obj).at(-1); }
}
const client = (id) => {
  const kp = generateEd25519();
  return {
    id, pubKey: kp.pubB64,
    approve: (st, d, nonce = `n_${Math.random()}`) => ({ t: 'approve', draftId: d.draftId, draftHash: d.draftHash, nonce, sig: signEd25519(kp.privateKey, approvalMessage({ sid: st.sid, draftId: d.draftId, draftHash: d.draftHash, nonce })) }),
  };
};
const ALICE = { id: 'u_alice', name: '王建国' };
const BOB = { id: 'u_bob', name: '李秀梅' };

test('线协议名不变:lares.anon、u_ai_anon_ 前缀、显示名「炉灵」', () => {
  assert.equal(ANON_TOPIC, 'lares.anon');
  assert.match(anonAgentUserId('c1'), /^u_ai_anon_[0-9a-f]{8}$/);
  assert.equal(AGENT_NAME, '炉灵');
  assert.ok(isLaresHuman('u_alice'));
  for (const id of ['u_ai_x', 'u_ai_anon_x', 'bot:x', '']) assert.ok(!isLaresHuman(id));
});

test('laresPort:Ember 中立事件 ↔ Lares 线协议', async () => {
  const room = new FakeRoom([ALICE]);
  const port = laresPort(room, { circleId: 'c1' });
  assert.equal(port.selfId, 'u_ai_anon_test');
  await port.send({ t: 'state' });
  await port.send({ t: 'error' }, 'u_alice');
  assert.deepEqual(room.sent, [{ obj: { t: 'state' }, to: null }, { obj: { t: 'error' }, to: 'u_alice' }]);
  port.notifyHost({ type: 'active', on: true });
  port.notifyHost({ type: 'released', itemIds: ['m1'] });
  port.notifyHost({ type: 'unknown' });
  assert.deepEqual(room.server, [{ t: 'anon_active', circleId: 'c1', on: true }, { t: 'anon_released_notice', circleId: 'c1', itemIds: ['m1'] }]);
  const got = [];
  port.on('message', (id, m) => got.push(['message', id, m.t]));
  port.on('name', (id, n) => got.push(['name', id, n]));
  port.on('joined', (id, n) => got.push(['joined', id, n]));
  room.fire('anon', 'u_alice', { t: 'ack' });
  room.fire('names', 'u_alice', '王建国');
  room.fire('joined', 'u_alice');
  assert.deepEqual(got, [['message', 'u_alice', 'ack'], ['name', 'u_alice', '王建国'], ['joined', 'u_alice', '王建国']]);
  assert.throws(() => port.on('nope', () => {}), /unknown event/);
});

test('托管运行:FakeRoom 上走完 ack → 纪要 → k 签名放行 → convener 散会;anon_* 信令 + 退出码 0', async () => {
  const room = new FakeRoom([ALICE, BOB]);
  const dir = mkdtempSync(path.join(os.tmpdir(), 'ember-lares-'));
  const events = [];
  try {
    const bot = await runEmberLares({
      circleId: 'c_test', room, asr: new MockAsr(), llm: null, memoryDir: dir, hosted: true, log: () => {}, emit: (e) => events.push(e.ev),
      env: { LARES_ANONYM_HOSTED: '1', LARES_ANONYM_K: '2', LARES_ANONYM_CONVENER: ALICE.id, LARES_ANONYM_USER_ID: 'u_ai_anon_test' },
    });
    assert.deepEqual(room.server[0], { t: 'anon_active', circleId: 'c_test', on: true });
    assert.ok(events.includes('ready'));
    const a = client(ALICE.id), b = client(BOB.id);
    room.msg(ALICE.id, { t: 'ack', pubKey: a.pubKey });
    room.msg(BOB.id, { t: 'ack', pubKey: b.pubKey });
    const st = room.last('state');
    assert.equal(st.k, 2);
    assert.equal(st.convenerId, ALICE.id, 'LARES_ANONYM_CONVENER');
    bot.agent.onTranscript(ALICE.id, '我觉得可以先做小范围试点。');
    bot.agent.onTranscript(BOB.id, '同意，下周先跑一下。');
    await bot.agent.onMessage(BOB.id, { t: 'skill', name: 'minutes', args: {} });
    const d = room.last('draft').draft;
    await bot.agent.onMessage(ALICE.id, a.approve(st, d));
    await bot.agent.onMessage(BOB.id, b.approve(st, d));
    assert.ok(room.last('released'), '放行');
    assert.ok(room.server.some((m) => m.t === 'anon_released_notice' && m.circleId === 'c_test' && m.itemIds.length >= 1));
    await bot.agent.onMessage(BOB.id, { t: 'end' });
    assert.equal(room.last('error').code, 'not_convener');
    await bot.agent.onMessage(ALICE.id, { t: 'end' });
    assert.equal(await bot.done, EXIT.OK);
    assert.ok(room.left);
    assert.deepEqual(room.server.at(-1), { t: 'anon_active', circleId: 'c_test', on: false });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('房间断开(非散会)→ 退出码 1;圈子解散 → 0', async () => {
  for (const [why, code] of [['signaling', EXIT.CRASH], ['circle_deleted', EXIT.OK]]) {
    const room = new FakeRoom([ALICE]);
    const bot = await runEmberLares({ circleId: 'c_x', room, asr: null, llm: null, memory: null, memoryDir: null, hosted: false, env: {}, log: () => {} });
    room.fire('disconnected', why);
    assert.equal(await bot.done, code, why);
  }
});

test('parseArgs:参数错误 → UsageError', () => {
  assert.deepEqual(parseArgs(['--circle', 'c1', '--k', '3', '--e2ee']), { e2ee: true, authV2: false, sealedKey: false, circleId: 'c1', k: 3 });
  assert.throws(() => parseArgs(['--circle']), UsageError);
  assert.throws(() => parseArgs(['--k', '0']), UsageError);
  assert.throws(() => parseArgs(['--bogus']), UsageError);
});

test('CLI:--help 退出 0;缺 --circle 退出 2', () => {
  const entry = path.join(HERE, '..', 'index.mjs');
  const h = spawnSync(process.execPath, [entry, '--help'], { encoding: 'utf8' });
  assert.equal(h.status, 0);
  assert.match(h.stderr, /usage: node index\.mjs --circle/);
  const bad = spawnSync(process.execPath, [entry], { encoding: 'utf8' });
  assert.equal(bad.status, EXIT.BAD_ARGS);
  assert.match(bad.stdout, /"ev":"exit","code":2/);
});

test('AnonRoom 密封流程:anon_agent_hello → anon_agent_key → 解封(假 WS)', async () => {
  const ws = new EventEmitter();
  const sent = [];
  ws.send = (s) => sent.push(JSON.parse(s));
  const r = new AnonRoom({ circleId: 'c1', userId: 'u_ai_anon_x', name: 'x', signaling: 'ws://x', keyTimeoutMs: 2000 });
  r.ws = ws;
  assert.match(r.deviceId, /^d_anon_[0-9a-f]{12}$/);
  const p = r._awaitSealedKey();
  const hello = sent[0];
  assert.equal(hello.t, 'anon_agent_hello');
  assert.equal(Buffer.from(hello.x25519Pub, 'base64').length, 32);
  const hex = 'ab'.repeat(32);
  ws.emit('message', JSON.stringify({ t: 'anon_agent_key', circleId: 'c1', sealed: seal(hex, generateX25519().pubB64, 'c1'), x25519Pub: 'stale' })); // 封给别人的:忽略
  ws.emit('message', JSON.stringify({ t: 'anon_agent_key', circleId: 'c1', sealed: seal(hex, hello.x25519Pub, 'c1'), x25519Pub: hello.x25519Pub }));
  assert.equal(await p, hex);
});

test('AnonRoom data:只收 lares.anon、丢自己 / 超大 / 非 JSON', () => {
  const r = new AnonRoom({ circleId: 'c1', userId: 'u_ai_anon_x', name: 'x', signaling: 'ws://x' });
  const got = [];
  r.on('anon', (id, m) => got.push([id, m.t]));
  const enc = (o) => new TextEncoder().encode(typeof o === 'string' ? o : JSON.stringify(o));
  r._data(enc({ t: 'ask' }), 'u_alice', 'lares.anon');
  r._data(enc({ t: 'ask' }), 'u_ai_anon_x', 'lares.anon');
  r._data(enc('nope'), 'u_alice', 'lares.anon');
  r._data(new Uint8Array(17 * 1024), 'u_alice', 'lares.anon');
  assert.deepEqual(got, [['u_alice', 'ask']]);
});
