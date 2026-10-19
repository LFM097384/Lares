// lares-bridge:线协议(帧 / id / 真人判定)、信令握手(本地 ws 服务器)、data topic 映射、音频出口、依赖解析与边界。
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  LaresRoom, AuthError, CircleGoneError, E2eeRequiredError,
  CHAT_TOPIC, CAPTION_TOPIC, AI_STATE_TOPIC, ROOM_RATE, FRAME_SAMPLES,
  encodeChatFrame, decodeChatFrame, defaultAiUserId, isLaresHuman, authVerifier, e2eeKeyHex,
  framesOf, monoOf, importDep, WebSocket, argon2id,
} from '../index.mjs';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m, 'utf8').digest('hex');

test('线协议常量不变', () => {
  assert.equal(CHAT_TOPIC, 'lares.chat');
  assert.equal(CAPTION_TOPIC, 'lares.cap');
  assert.equal(AI_STATE_TOPIC, 'lares.ai');
  assert.equal(ROOM_RATE, 48000);
  assert.equal(FRAME_SAMPLES, 480);
});

test('defaultAiUserId = u_ai_<sha256(circleId) 前 8 hex>;isLaresHuman', () => {
  const id = defaultAiUserId('c_demo');
  assert.match(id, /^u_ai_[0-9a-f]{8}$/);
  assert.equal(id, `u_ai_${crypto.createHash('sha256').update('c_demo').digest('hex').slice(0, 8)}`);
  assert.equal(isLaresHuman('u_alice'), true);
  for (const x of ['u_ai_12345678', 'u_ai_anon_1', 'bot:x', '', null, undefined, 3]) assert.equal(isLaresHuman(x), false, String(x));
});

test('聊天帧:4 字节大端长度 + JSON 头,往返一致;坏帧返回 null', () => {
  const h = { v: 1, t: 'text', id: 'm1', sid: 'u_a', body: '你好' };
  const f = encodeChatFrame(h);
  assert.ok(f instanceof Uint8Array);
  assert.equal(Buffer.from(f).readUInt32BE(0), Buffer.byteLength(JSON.stringify(h)));
  assert.deepEqual(decodeChatFrame(f).header, h);
  assert.equal(decodeChatFrame(new Uint8Array([0, 0])), null);
  assert.equal(decodeChatFrame(new Uint8Array([0, 0, 0, 9, 1])), null);
});

test('E2EE / v2 verifier:Argon2id,确定性,与 app 同参数(64 hex)', async () => {
  const a = await e2eeKeyHex('口令', 'c_x');
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.equal(await e2eeKeyHex('口令', 'c_x'), a);
  assert.notEqual(await e2eeKeyHex('口令', 'c_y'), a);
  const v = await authVerifier('口令', 'c_x');
  assert.match(v, /^[0-9a-f]{64}$/);
  assert.notEqual(v, a, 'verifier 与媒体密钥的盐不同');
});

test('音频小工具:framesOf 切 480 样本帧(尾巴补零、独立拷贝);monoOf 取第一声道', () => {
  const pcm = new Int16Array(1000).map((_, i) => i);
  const fr = framesOf(pcm);
  assert.equal(fr.length, 3);
  assert.ok(fr.every((f) => f.length === 480));
  assert.equal(fr[2][39], 999);
  assert.equal(fr[2][40], 0);
  assert.notEqual(fr[0].buffer, pcm.buffer);
  assert.deepEqual([...monoOf(new Int16Array([1, 2, 3, 4]), 2)], [1, 3]);
});

/// 本地信令服务器:按脚本回应 hello / join
async function signalingServer(onHello) {
  const wsMod = await importDep('ws');
  const WebSocketServer = wsMod.WebSocketServer ?? wsMod.default?.WebSocketServer ?? wsMod.default?.Server;
  const wss = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  await new Promise((r) => wss.once('listening', r));
  const seen = [];
  wss.on('connection', (ws) => {
    const nonce = crypto.randomBytes(8).toString('hex');
    ws.send(JSON.stringify({ t: 'challenge', nonce, modes: ['circle'] }));
    ws.on('message', (raw) => {
      const m = JSON.parse(raw);
      seen.push(m);
      onHello(ws, m, nonce);
    });
  });
  return { url: `ws://127.0.0.1:${wss.address().port}/ws`, seen, close: () => new Promise((r) => { for (const c of wss.clients) c.terminate(); wss.close(r); }) };
}

test('信令握手:HMAC 证明 + aiAuth(u_ai_ 凭证)+ v2 标记 → join → token', async () => {
  const circleId = 'c_t';
  const userId = defaultAiUserId(circleId);
  const srv = await signalingServer((ws, m, nonce) => {
    if (m.t === 'hello') {
      const ok = m.auth?.proof === hmac('verifier-hex', `${nonce}:${userId}:${circleId}`)
        && m.aiAuth?.proof === hmac('member-secret', `${nonce}:${userId}:${circleId}`);
      if (!ok) return ws.close(4401);
      ws.send(JSON.stringify({ t: 'welcome', circle: { e2ee: false } }));
    } else if (m.t === 'join') ws.send(JSON.stringify({ t: 'token', url: 'wss://lk', token: 'tok' }));
  });
  try {
    const room = new LaresRoom({ circleId, userId, name: '灶语', signaling: srv.url, authSecret: 'verifier-hex', authV: 2, memberSecret: 'member-secret' });
    const tok = await room._signal();
    assert.deepEqual([tok.url, tok.token], ['wss://lk', 'tok']);
    const hello = srv.seen.find((m) => m.t === 'hello');
    assert.equal(hello.platform, 'ai');
    assert.equal(hello.name, '灶语');
    assert.equal(hello.auth.v, 2);
    assert.match(hello.deviceId, /^d_ai_[0-9a-f]{12}$/);
    assert.equal(hello.aiAuth.circleId, circleId);
    assert.deepEqual(srv.seen.find((m) => m.t === 'join'), { t: 'join', circleId });
    await room.leave();
  } finally { await srv.close(); }
});

test('信令握手失败映射:4401 → AuthError;4410 → CircleGoneError;E2EE 圈不带 --e2ee → E2eeRequiredError', async () => {
  for (const [act, Err] of [['4401', AuthError], ['4410', CircleGoneError], ['e2ee', E2eeRequiredError]]) {
    const srv = await signalingServer((ws, m) => {
      if (m.t !== 'hello') return;
      if (act === 'e2ee') ws.send(JSON.stringify({ t: 'welcome', circle: { e2ee: true } }));
      else ws.close(Number(act));
    });
    try {
      const room = new LaresRoom({ circleId: 'c', userId: 'u_x', name: 'n', signaling: srv.url, authSecret: 's', joinTimeoutMs: 3000 });
      await assert.rejects(room._signal(), Err, act);
    } finally { await srv.close(); }
  }
});

test('没有凭证就不发 hello(no_credentials)', async () => {
  const srv = await signalingServer(() => {});
  try {
    const room = new LaresRoom({ circleId: 'c', userId: 'u_x', name: 'n', signaling: srv.url, joinTimeoutMs: 3000 });
    await assert.rejects(room._signal(), (e) => e instanceof AuthError && e.message === 'no_credentials');
    assert.equal(srv.seen.length, 0);
  } finally { await srv.close(); }
});

test('data topic 映射:聊天(真人 / 冒充 bot / 服务器 bot)、字幕控制、名字;忽略自己', () => {
  const room = new LaresRoom({ circleId: 'c', userId: 'u_ai_self', name: 'n', signaling: 'ws://x' });
  const got = { chat: [], capctl: [], names: [] };
  room.on('chat', (m) => got.chat.push(m)).on('capctl', (id, m) => got.capctl.push([id, m.t])).on('names', (id, n) => got.names.push([id, n]));
  const frame = (h) => encodeChatFrame({ v: 1, t: 'text', id: 'm', ...h });
  room._data(frame({ sid: 'u_a', sn: 'Alice', body: '@AI 你好' }), 'u_a', CHAT_TOPIC);
  room._data(frame({ sid: 'bot:x', body: '冒充' }), 'u_b', CHAT_TOPIC);
  room._data(frame({ sid: 'u_c', bot: true, body: '假 bot' }), 'u_c', CHAT_TOPIC);
  room._data(frame({ sid: 'bot:srv', bot: true, body: '服务器 bot' }), null, CHAT_TOPIC);
  room._data(frame({ sid: 'u_d', body: '无来源非 bot' }), null, CHAT_TOPIC);
  room._data(frame({ sid: 'u_ai_self', body: '我自己' }), 'u_ai_self', CHAT_TOPIC);
  room._data(new TextEncoder().encode(JSON.stringify({ t: 'capack', on: false })), 'u_a', CAPTION_TOPIC);
  room._data(new TextEncoder().encode(JSON.stringify({ t: 'cap', text: 'x' })), 'u_a', CAPTION_TOPIC);
  assert.deepEqual(got.chat.map((m) => [m.senderId, m.bot, m.body]), [['u_a', false, '@AI 你好'], ['bot:srv', true, '服务器 bot']]);
  assert.deepEqual(got.capctl, [['u_a', 'capack']]);
  assert.deepEqual(got.names, [['u_a', 'Alice']]);
});

test('出站:sink() 把 480 样本帧交给 AudioSource;字幕 / 状态 / 聊天走各自 topic;leave 后静默', async () => {
  const published = [];
  const captured = [];
  let cleared = 0;
  class AudioFrame { constructor(d, r, c, n) { Object.assign(this, { d, r, c, n }); } }
  const room = new LaresRoom({ circleId: 'c_1', userId: 'u_ai_1', name: '灶语', signaling: 'ws://x' });
  room.rtc = { AudioFrame };
  room.source = { captureFrame: (f) => captured.push(f), clearQueue: () => { cleared += 1; }, queuedDuration: 120 };
  room.room = { localParticipant: { publishData: async (data, o) => published.push([o.topic, o.reliable, data]) }, disconnect: async () => {} };
  const sink = room.sink();
  sink.captureFrame(new Int16Array(480));
  sink.clear();
  assert.equal(sink.queuedMs(), 120);
  assert.deepEqual([captured[0].r, captured[0].c, captured[0].n], [48000, 1, 480]);
  assert.equal(cleared, 1);
  await room.publishCaption({ t: 'cap', id: 'x', seq: 1, text: '嗨', final: true });
  await room.publishState({ t: 'state', state: 'listening', seq: 1 });
  await room.sendChat('你好');
  assert.deepEqual(published.map((p) => [p[0], p[1]]), [[CAPTION_TOPIC, true], [AI_STATE_TOPIC, true], [CHAT_TOPIC, true]]);
  const chat = decodeChatFrame(published[2][2]).header;
  assert.deepEqual([chat.t, chat.sid, chat.sn, chat.cid, chat.body], ['text', 'u_ai_1', '灶语', 'c_1', '你好']);
  await room.leave();
  sink.captureFrame(new Int16Array(480));
  await room.sendChat('离房后');
  assert.equal(captured.length, 1);
  assert.equal(published.length, 3);
});

test('依赖:ws / hash-wasm 可解析(开发机走 server/node_modules 退路)', async () => {
  assert.equal(typeof WebSocket, 'function');
  assert.equal(typeof argon2id, 'function');
  await assert.rejects(importDep('definitely-not-a-real-package-xyz'));
});

test('边界:lares-bridge 不 import server/ 源码,也不认识任何 AI 本体', () => {
  for (const f of readdirSync(ROOT).filter((x) => x.endsWith('.mjs'))) {
    const src = readFileSync(path.join(ROOT, f), 'utf8');
    const specs = [...src.matchAll(/(?:from\s+|import\s*\(\s*)['"]([^'"]+)['"]/g)].map((m) => m[1]);
    for (const s of specs) assert.ok(s.startsWith('node:') || s.startsWith('./'), `${f} imports ${s}`);
  }
});
