// 机器人 REST API 真机端到端:真 LiveKit(livekit-server --dev)+ 真信令服务 + curl.exe + rtc-node 监听者。
//
// 前置(两个都要先跑起来):
//   server\livekit\livekit-server.exe --dev --bind 127.0.0.1          (devkey / secret, :7880)
//   $env:LIVEKIT_URL='ws://127.0.0.1:7880'; $env:LIVEKIT_API_KEY='devkey'; $env:LIVEKIT_API_SECRET='secret'
//   $env:LARES_AUTH_MODE='circle'; $env:LARES_CIRCLE_PASSCODE='<随便>'; $env:LARES_DATA_DIR='<临时目录>'
//   $env:LARES_PORT='18790'; node server/src/index.js
// 然后:
//   cd server/tool; $env:LARES_E2E_PORT='18790'; node bot_api_e2e.mjs
//
// 流程:
//   1. WS 注册新圈(v2),圈主开转写,签一个机器人 token
//   2. LaresBot 监听者(onChat / onCaption / onAudio)进房
//   3. curl.exe -N 订阅 SSE;POST /messages、POST /captions(final);WS 成员 transcript_append
//   4. POST /speak 一段 2 秒 440 Hz 的 WAV(24 kHz,故意不是 48k),监听者用 YIN 测频
//   5. 圈主开 E2EE:REST 一律 409;两个带口令的 LaresBot(e2ee:true)互发聊天 / 字幕
// 输出每一步的实测值;任何一项不达标退出码 1。

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import Pitchfinder from 'pitchfinder';
import { LaresBot, authVerifier } from './lares_bot.mjs';

const PORT = Number(process.env.LARES_E2E_PORT ?? 18790);
const HTTP = `http://127.0.0.1:${PORT}`;
const WSURL = `ws://127.0.0.1:${PORT}/ws`;
const PASSCODE = 'e2e-pass-' + crypto.randomBytes(4).toString('hex');
const CURL = process.platform === 'win32' ? 'curl.exe' : 'curl';
const results = {};
let failed = 0;
const ok = (cond, name, val) => {
  results[name] = val;
  console.log(`${cond ? '✓' : '✗'} ${name}: ${typeof val === 'string' ? val : JSON.stringify(val)}`);
  if (!cond) failed++;
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m).digest('hex');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

function newCircleId() {
  const a = 'abcdefghijklmnopqrstuvwxyz234567';
  let s = 'c_';
  for (const b of crypto.randomBytes(24)) s += a[b & 31];
  return s;
}

/// 原始 WS 成员(圈主 / 普通成员)
function wsMember({ cid, verifier, userId, name, register }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WSURL);
    const inbox = [];
    const waiters = [];
    const m = {
      ws, inbox,
      send: (o) => ws.send(JSON.stringify(o)),
      waitFor: (pred, ms = 5000) => {
        const i = inbox.findIndex(pred);
        if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
        return new Promise((res) => { const w = { pred, res, t: setTimeout(() => res(null), ms) }; waiters.push(w); });
      },
      close: () => ws.close(),
    };
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw);
      if (msg.t === 'challenge') {
        const body = `${msg.nonce}:${userId}:${cid}`;
        ws.send(JSON.stringify({
          t: 'hello', userId, deviceId: 'd-' + userId, name, platform: 'e2e',
          auth: { mode: 'circle', v: 2, circleId: cid, nonce: msg.nonce, proof: hmac(verifier, body), ...(register ? { register } : {}) },
        }));
        return;
      }
      const w = waiters.find((x) => x.pred(msg));
      if (w) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(msg); } else inbox.push(msg);
      if (msg.t === 'welcome') resolve(m);
    });
    ws.on('close', (code) => reject(new Error('ws closed ' + code)));
    ws.on('error', reject);
  });
}

/// curl.exe 调 REST,返回 {status, body}
function curl(args, { input } = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(CURL, ['-s', '-S', '-w', '\n%{http_code}', ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', reject);
    p.on('close', () => {
      const i = out.lastIndexOf('\n');
      const status = Number(out.slice(i + 1));
      let body = out.slice(0, i);
      try { body = JSON.parse(body); } catch { /* 原文 */ }
      resolve({ status, body, err });
    });
    if (input) p.stdin.end(input); else p.stdin.end();
  });
}

/// curl.exe -N 订阅 SSE
function curlSse(token) {
  const p = spawn(CURL, ['-s', '-N', '-H', `Authorization: Bearer ${token}`, `${HTTP}/api/v1/events`], { stdio: ['ignore', 'pipe', 'pipe'] });
  const sse = { p, raw: '', events: [], keepalives: 0, waiters: [] };
  let buf = '';
  p.stdout.on('data', (d) => {
    const s = d.toString('utf8');
    sse.raw += s;
    buf += s;
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      if (block.startsWith(': keepalive')) { sse.keepalives++; continue; }
      const ev = {};
      for (const line of block.split('\n')) { const m = /^(id|event|data): (.*)$/.exec(line); if (m) ev[m[1]] = m[2]; }
      if (!ev.event) continue;
      ev.data = JSON.parse(ev.data);
      sse.events.push(ev);
      for (const w of [...sse.waiters]) if (w.pred(ev)) { sse.waiters.splice(sse.waiters.indexOf(w), 1); clearTimeout(w.t); w.res(ev); }
    }
  });
  sse.waitFor = (pred, ms = 5000) => {
    const hit = sse.events.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((res) => { const w = { pred, res, t: setTimeout(() => res(null), ms) }; sse.waiters.push(w); });
  };
  return sse;
}

function wav440(rate, seconds) {
  const n = Math.floor(rate * seconds);
  const data = Buffer.alloc(n * 2);
  for (let i = 0; i < n; i++) data.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 440 * i / rate) * 12000), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0, 'ascii'); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8, 'ascii');
  h.write('fmt ', 12, 'ascii'); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36, 'ascii'); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

function estimateFreq(samples, sampleRate) {
  const threshold = 32768 * 0.02;
  let start = 0;
  while (start < samples.length && Math.abs(samples[start]) < threshold) start++;
  let end = samples.length - 1;
  while (end > start && Math.abs(samples[end]) < threshold) end--;
  if (end - start < sampleRate * 0.1) return { freq: 0, voicedMs: 0 };
  const voiced = samples.subarray(start, end + 1);
  const f32 = new Float32Array(voiced.length);
  for (let i = 0; i < voiced.length; i++) f32[i] = voiced[i] / 32768;
  const detect = Pitchfinder.YIN({ sampleRate });
  const res = [];
  for (let i = 0; i + 2048 <= f32.length; i += 2048) { const p = detect(f32.subarray(i, i + 2048)); if (p && Number.isFinite(p)) res.push(p); }
  res.sort((a, b) => a - b);
  return { freq: res.length ? res[Math.floor(res.length / 2)] : 0, voicedMs: Math.round((voiced.length / sampleRate) * 1000) };
}

async function main() {
  const health = await (await fetch(`${HTTP}/health`)).json();
  ok(health.rtcConfigured === true, 'health.rtcConfigured', health.rtcConfigured);

  // 1. 注册圈、开转写、签 token
  const cid = newCircleId();
  const verifier = await authVerifier(PASSCODE, cid);
  const ownerKey = crypto.randomBytes(32).toString('hex');
  const owner = await wsMember({ cid, verifier, userId: 'u_owner', name: '圈主', register: { verifier, ownerHash: sha256(ownerKey) } });
  owner.send({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey });
  const set = await owner.waitFor((m) => m.op === 'circle_transcript_set');
  ok(set?.t === 'owner_ok', 'circle_transcript_set', set?.t);
  owner.send({ t: 'bot_token_create', circleId: cid, name: 'E2E 机器人', ownerKey });
  const tok = await owner.waitFor((m) => m.t === 'bot_token');
  ok(/^lrb_/.test(tok?.token ?? ''), 'bot_token', { id: tok?.id, prefix: tok?.token?.slice(0, 8) });
  const token = tok.token;

  // 2. 监听者进房
  const listener = new LaresBot({ circleId: cid, name: '监听者', passcode: PASSCODE, authVersion: 2, signaling: WSURL });
  const chats = [];
  const caps = [];
  const audio = new Map(); // from -> {rate, samples[]}
  listener.onChat((m) => chats.push(m));
  listener.onCaption((c) => caps.push(c));
  listener.onAudio((frame, from) => {
    const a = audio.get(from) ?? { rate: frame.sampleRate, chunks: [] };
    a.chunks.push(Int16Array.from(frame.data));
    audio.set(from, a);
  });
  await listener.join();
  ok(true, 'listener joined', listener.userId);
  // 圈主也进房(transcript_append 要求在房)
  owner.send({ t: 'join', circleId: cid });
  await owner.waitFor((m) => m.t === 'room');

  // 3. SSE + messages + captions + transcript
  const sse = curlSse(token);
  const ready = await sse.waitFor((e) => e.event === 'ready');
  ok(ready?.data?.circleId === cid, 'SSE ready (curl.exe -N)', { members: ready?.data?.members?.map((m) => m.name) });

  let r = await curl(['-X', 'POST', '-H', `Authorization: Bearer ${token}`, '-H', 'Content-Type: application/json', '--data-binary', '@-', `${HTTP}/api/v1/messages`],
    { input: JSON.stringify({ text: '你好,我是机器人 👋' }) });
  ok(r.status === 200, 'POST /messages', r);
  const chatEv = await sse.waitFor((e) => e.event === 'chat');
  ok(chatEv?.data?.body === '你好,我是机器人 👋', 'SSE chat event', chatEv?.data && { sid: chatEv.data.sid, sn: chatEv.data.sn });

  r = await curl(['-X', 'POST', '-H', `Authorization: Bearer ${token}`, '-H', 'Content-Type: application/json', '--data-binary', '@-', `${HTTP}/api/v1/captions`],
    { input: JSON.stringify({ text: '这是一条机器人字幕', final: true }) });
  ok(r.status === 200 && r.body.archivedSeq >= 1, 'POST /captions final', r.body);
  const capTr = await sse.waitFor((e) => e.event === 'transcript' && e.data.userId === `bot:${tok.id}`);
  ok(Boolean(capTr), 'SSE transcript (bot caption archived)', capTr?.data && { seq: capTr.data.seq, name: capTr.data.name });

  owner.send({ t: 'transcript_append', circleId: cid, id: 'e2e-1', text: '圈主说的一句话', startedAt: Date.now() - 1000 });
  const ap = await owner.waitFor((m) => m.t === 'transcript_appended' || m.t === 'transcript_error');
  const memTr = await sse.waitFor((e) => e.event === 'transcript' && e.data.id === 'e2e-1');
  ok(ap?.t === 'transcript_appended' && memTr?.data?.userId === 'u_owner', 'WS transcript_append -> SSE transcript', memTr?.data && { seq: memTr.data.seq, name: memTr.data.name, text: memTr.data.text });

  r = await curl(['-H', `Authorization: Bearer ${token}`, `${HTTP}/api/v1/transcript?limit=10`]);
  ok(r.status === 200 && r.body.items.length === 2, 'GET /transcript', r.body.items?.map((x) => `${x.seq}:${x.name}:${x.text}`));
  r = await curl(['-H', `Authorization: Bearer ${token}`, `${HTTP}/api/v1/circle`]);
  ok(r.status === 200, 'GET /circle', r.body);

  await wait(500);
  const botChat = chats.find((c) => c.bot);
  ok(botChat?.body === '你好,我是机器人 👋' && botChat.senderId === `bot:${tok.id}` && botChat.from === null, 'listener onChat 收到机器人消息(participant=null, bot:true)', botChat);
  const botCap = caps.find((c) => c.bot);
  ok(botCap?.text === '这是一条机器人字幕' && botCap.final === true && botCap.bot.id === tok.id, 'listener onCaption 收到机器人字幕', botCap);

  // 4. speak
  const wav = wav440(24000, 2);
  const tmp = mkdtempSync(path.join(tmpdir(), 'lares-e2e-'));
  const wavPath = path.join(tmp, 'tone.wav');
  writeFileSync(wavPath, wav);
  const t0 = Date.now();
  r = await curl(['-X', 'POST', '-H', `Authorization: Bearer ${token}`, '-H', 'Content-Type: audio/wav', '--data-binary', `@${wavPath}`, `${HTTP}/api/v1/speak`]);
  ok(r.status === 200, 'POST /speak (2 s 440 Hz @24 kHz)', { ...r.body, wallMs: Date.now() - t0 });
  const joinEv = sse.events.find((e) => e.event === 'join' && String(e.data.userId).startsWith('bot:'));
  await wait(800);
  const fromBot = audio.get(`bot:${tok.id}`);
  if (fromBot) {
    const total = fromBot.chunks.reduce((s, c) => s + c.length, 0);
    const all = new Int16Array(total);
    let o = 0;
    for (const c of fromBot.chunks) { all.set(c, o); o += c.length; }
    const est = estimateFreq(all, fromBot.rate);
    ok(Math.abs(est.freq - 440) < 440 * 0.03, 'listener 收到 bot 音频,YIN 测频', { freqHz: Number(est.freq.toFixed(1)), voicedMs: est.voicedMs, rxRate: fromBot.rate, samples: total });
  } else {
    ok(false, 'listener 收到 bot 音频', [...audio.keys()]);
  }
  results.speakJoinSeenOnSse = Boolean(joinEv); // 信令侧看不到 speak 的媒体身份(它不走 WS),预期 false

  // 5. E2EE
  owner.send({ t: 'circle_e2ee_set', circleId: cid, enabled: true, ownerKey });
  await owner.waitFor((m) => m.op === 'circle_e2ee_set');
  const codes = {};
  for (const [p, extra] of [['messages', ['-X', 'POST', '-d', '{"text":"x"}']], ['captions', ['-X', 'POST', '-d', '{"text":"x","final":true}']], ['speak', ['-X', 'POST', '--data-binary', `@${wavPath}`]], ['transcript', []]]) {
    const x = await curl(['-H', `Authorization: Bearer ${token}`, ...extra, `${HTTP}/api/v1/${p}`]);
    codes[p] = `${x.status} ${x.body?.error}`;
  }
  ok(Object.values(codes).every((v) => v === '409 e2ee'), 'E2EE 圈 REST -> 409', codes);
  await listener.leave();

  const a = new LaresBot({ circleId: cid, name: 'E2EE-A', passcode: PASSCODE, authVersion: 2, e2ee: true, signaling: WSURL });
  const b = new LaresBot({ circleId: cid, name: 'E2EE-B', passcode: PASSCODE, authVersion: 2, e2ee: true, signaling: WSURL });
  const wrong = new LaresBot({ circleId: cid, name: 'NoKey', passcode: PASSCODE, authVersion: 2, signaling: WSURL }); // 能进房(口令对)但不设 E2EE 密钥
  const collect = (bot) => { const m = new Map(); bot.onAudio((fr, from) => { const x = m.get(from) ?? { rate: fr.sampleRate, chunks: [] }; x.chunks.push(Int16Array.from(fr.data)); m.set(from, x); }); return m; };
  const bAudio = collect(b);
  const wAudio = collect(wrong);
  const bChats = [];
  const bCaps = [];
  const wrongChats = [];
  b.onChat((m) => bChats.push(m));
  b.onCaption((c) => bCaps.push(c));
  wrong.onChat((m) => wrongChats.push(m));
  await b.join();
  await wrong.join();
  await a.join();
  await wait(1500);
  const { sineWave } = await import('./lares_bot.mjs');
  await a.speak(sineWave(440, 2));
  await wait(800);
  const measure = (m) => {
    const x = m.get(a.userId);
    if (!x) return { freqHz: null, samples: 0, rms: 0 };
    const n = x.chunks.reduce((s, c) => s + c.length, 0);
    const all = new Int16Array(n); let o = 0; for (const c of x.chunks) { all.set(c, o); o += c.length; }
    let sq = 0; for (let i = 0; i < n; i++) sq += all[i] * all[i];
    const e = estimateFreq(all, x.rate);
    return { freqHz: Number(e.freq.toFixed(1)), samples: n, rms: Math.round(Math.sqrt(sq / Math.max(1, n))) };
  };
  const bm = measure(bAudio);
  const wm = measure(wAudio);
  ok(Math.abs(bm.freqHz - 440) < 13, 'E2EE: 同口令 bot 音频解密,YIN 测频', bm);
  ok(!(Math.abs((wm.freqHz ?? 0) - 440) < 13), 'E2EE: 无密钥参与者听不出 440 Hz(音频确实加密)', wm);
  await a.sendChat('加密聊天 🔒');
  await a.sendCaption('加密字幕', { final: true });
  await wait(1500);
  ok(bChats.some((m) => m.body === '加密聊天 🔒' && !m.bot && m.senderId === a.userId), 'E2EE: sendChat -> 同口令 onChat', bChats.map((m) => m.body));
  ok(bCaps.some((c) => c.text === '加密字幕' && c.final && c.bot === null), 'E2EE: sendCaption -> 同口令 onCaption', bCaps.map((c) => c.text));
  ok(!wrongChats.some((m) => m.body === '加密聊天 🔒'), 'E2EE: 无密钥参与者解不出聊天(数据通道已加密)', { decodedChats: wrongChats.length });
  for (const x of [a, b, wrong]) await x.leave();
  sse.p.kill();
  owner.close();
  console.log('\nRESULTS ' + JSON.stringify(results));
  console.log(failed === 0 ? '\nE2E 全部通过' : `\nE2E ${failed} 项失败`);
  setTimeout(() => process.exit(failed === 0 ? 0 : 1), 300);
}

main().catch((e) => {
  console.error('✗ E2E 异常:', e);
  process.exit(1);
});
