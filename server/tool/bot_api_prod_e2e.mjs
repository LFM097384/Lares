// Production E2E of bot API (adapted from bot_api_e2e.mjs). Creates a temp circle and deletes it.
// Usage: cd server/tool; node bot_api_prod_e2e.mjs

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import Pitchfinder from 'pitchfinder';
import { LaresBot, authVerifier } from './lares_bot.mjs';

const HTTP = 'https://lares.westus.cloudapp.azure.com';
const WSURL = 'wss://lares.westus.cloudapp.azure.com/ws';
const PASSCODE = 'prod-e2e-' + crypto.randomBytes(4).toString('hex');
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
      ev.at = Date.now();
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


const auth = (t) => ['-H', `Authorization: Bearer ${t}`];
const lat = {};
async function main() {
  const health = await curl([`${HTTP}/health`]);
  ok(health.status === 200, 'health', { status: health.status, rtcConfigured: health.body?.rtcConfigured });
  const un = await curl([`${HTTP}/api/v1/circle`]);
  ok(un.status === 401, 'unauth /api/v1/circle -> 401', un.status);

  // 1. register
  const cid = newCircleId();
  const verifier = await authVerifier(PASSCODE, cid);
  const ownerKey = crypto.randomBytes(32).toString('hex');
  let owner;
  const tReg = Date.now();
  try {
    owner = await wsMember({ cid, verifier, userId: 'u_e2e_owner_' + crypto.randomBytes(3).toString('hex'), name: 'E2E圈主', register: { verifier, ownerHash: sha256(ownerKey) } });
  } catch (e) { ok(false, 'register circle', String(e.message)); process.exit(2); }
  const welcome = owner.inbox.find((m) => m.t === 'welcome');
  ok(true, 'register circle', { cid, ms: Date.now() - tReg, registered: welcome?.registered });
  const cleanup = async () => {
    try {
      owner.send({ t: 'transcript_clear', circleId: cid, ownerKey });
      const c = await owner.waitFor((m) => m.op === 'transcript_clear');
      ok(c?.t === 'owner_ok', 'transcript_clear', c?.t ?? 'timeout');
      owner.send({ t: 'circle_delete', circleId: cid, ownerKey });
      const d = await owner.waitFor((m) => m.op === 'circle_delete');
      ok(d?.t === 'owner_ok', 'circle_delete', d?.t ?? 'timeout');
    } catch (e) { ok(false, 'cleanup', String(e)); }
  };
  let token, tok;
  try {
    owner.send({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey });
    const set = await owner.waitFor((m) => m.op === 'circle_transcript_set');
    ok(set?.t === 'owner_ok', 'circle_transcript_set on', set?.t ?? set);
    owner.send({ t: 'bot_token_create', circleId: cid, name: 'E2E机器人', ownerKey });
    tok = await owner.waitFor((m) => m.t === 'bot_token' || (m.t === 'owner_error' && m.op === 'bot_token_create'));
    ok(/^lrb_/.test(tok?.token ?? ''), 'bot_token_create', { id: tok?.id, reason: tok?.reason });
    token = tok.token;

    // 3. listener + owner in room
    const listener = new LaresBot({ circleId: cid, name: '监听者', passcode: PASSCODE, authVersion: 2, signaling: WSURL });
    const chats = [], caps = [], audio = new Map();
    listener.onChat((m) => { m._at = Date.now(); chats.push(m); });
    listener.onCaption((c) => { c._at = Date.now(); caps.push(c); });
    listener.onAudio((frame, from) => { const a = audio.get(from) ?? { rate: frame.sampleRate, chunks: [] }; a.chunks.push(Int16Array.from(frame.data)); audio.set(from, a); });
    let t = Date.now();
    await listener.join();
    ok(true, 'listener joined (LiveKit)', { ms: Date.now() - t });
    owner.send({ t: 'join', circleId: cid });
    ok(Boolean(await owner.waitFor((m) => m.t === 'room')), 'owner WS joined room', '');

    // 4. SSE
    t = Date.now();
    const sse = curlSse(token);
    const ready = await sse.waitFor((e) => e.event === 'ready', 8000);
    ok(ready?.data?.circleId === cid, 'SSE ready', { ms: ready ? ready.at - t : null, transcript: ready?.data?.transcript, members: ready?.data?.members?.map((m) => m.name) });

    // second WS member joins -> SSE join latency
    const m2id = 'u_e2e_m2_' + crypto.randomBytes(3).toString('hex');
    const m2 = await wsMember({ cid, verifier, userId: m2id, name: '成员二' });
    t = Date.now();
    m2.send({ t: 'join', circleId: cid });
    const jEv = await sse.waitFor((e) => e.event === 'join' && e.data.userId === m2id);
    ok(Boolean(jEv) && jEv.at - t < 1500, 'SSE join event (2nd WS member) latency', { ms: jEv ? jEv.at - t : null });

    let r = await curl([...auth(token), `${HTTP}/api/v1/circle`]);
    ok(r.status === 200 && r.body.id === cid, 'GET /api/v1/circle', { status: r.status, transcript: r.body?.transcript, e2ee: r.body?.e2ee, members: r.body?.members?.map((m) => m.name), bot: r.body?.bot?.name });

    t = Date.now();
    r = await curl(['-X', 'POST', ...auth(token), '-H', 'Content-Type: application/json', '--data-binary', '@-', `${HTTP}/api/v1/messages`], { input: JSON.stringify({ text: '你好,我是机器人 👋' }) });
    const tMsgDone = Date.now();
    ok(r.status === 200, 'POST /messages', { status: r.status, ms: tMsgDone - t, err: r.body?.error });
    const chatEv = await sse.waitFor((e) => e.event === 'chat');
    ok(chatEv?.data?.body === '你好,我是机器人 👋' && chatEv.at - t < 1500, 'SSE chat event latency', { msFromPost: chatEv ? chatEv.at - t : null });
    await wait(1000);
    const botChat = chats.find((c) => c.bot);
    ok(botChat?.body === '你好,我是机器人 👋' && botChat.senderId === `bot:${tok.id}`, 'listener onChat bot:true', { bot: botChat?.bot, sid: botChat?.senderId, msFromPost: botChat ? botChat._at - t : null });

    t = Date.now();
    r = await curl(['-X', 'POST', ...auth(token), '-H', 'Content-Type: application/json', '--data-binary', '@-', `${HTTP}/api/v1/captions`], { input: JSON.stringify({ text: '这是一条机器人字幕', final: true }) });
    ok(r.status === 200 && r.body.archivedSeq >= 1, 'POST /captions final', { status: r.status, ms: Date.now() - t, archivedSeq: r.body?.archivedSeq, err: r.body?.error });
    const capTr = await sse.waitFor((e) => e.event === 'transcript' && e.data.userId === `bot:${tok.id}`);
    ok(Boolean(capTr) && capTr.at - t < 1500, 'SSE transcript (caption archived) latency', { seq: capTr?.data?.seq, msFromPost: capTr ? capTr.at - t : null });
    await wait(1000);
    const botCap = caps.find((c) => c.bot);
    ok(botCap?.text === '这是一条机器人字幕' && botCap.final === true, 'listener onCaption', { final: botCap?.final, msFromPost: botCap ? botCap._at - t : null });

    t = Date.now();
    owner.send({ t: 'transcript_append', circleId: cid, id: 'e2e-1', text: '圈主说的一句话', startedAt: Date.now() - 1000 });
    const ap = await owner.waitFor((m) => m.t === 'transcript_appended' || m.t === 'transcript_error');
    const memTr = await sse.waitFor((e) => e.event === 'transcript' && e.data.id === 'e2e-1');
    ok(ap?.t === 'transcript_appended' && Boolean(memTr) && memTr.at - t < 1000, 'WS transcript_append -> SSE latency', { ack: ap?.t, reason: ap?.reason, msToSse: memTr ? memTr.at - t : null });
    owner.send({ t: 'transcript_get', circleId: cid, limit: 10 });
    const pg = await owner.waitFor((m) => m.t === 'transcript_page' || m.t === 'transcript_error');
    ok(pg?.t === 'transcript_page' && pg.items.length === 2 && pg.items.some((x) => x.id === 'e2e-1'), 'WS transcript_get', pg?.items?.map((x) => `${x.seq}:${x.name}:${x.text}`) ?? pg);
    r = await curl([...auth(token), `${HTTP}/api/v1/transcript?limit=10`]);
    ok(r.status === 200 && r.body.items?.length === 2, 'GET /api/v1/transcript', r.body.items?.map((x) => `${x.seq}:${x.name}:${x.text}`) ?? r.status);

    // speak
    const tmp = mkdtempSync(path.join(tmpdir(), 'lares-prod-e2e-'));
    const wavPath = path.join(tmp, 'tone.wav');
    writeFileSync(wavPath, wav440(24000, 2));
    t = Date.now();
    r = await curl(['-X', 'POST', ...auth(token), '-H', 'Content-Type: audio/wav', '--data-binary', `@${wavPath}`, `${HTTP}/api/v1/speak`]);
    ok(r.status === 200, 'POST /speak (2s 440Hz @24k)', { status: r.status, body: r.body, wallMs: Date.now() - t });
    await wait(1000);
    const fromBot = audio.get(`bot:${tok.id}`);
    if (fromBot) {
      const total = fromBot.chunks.reduce((s, c) => s + c.length, 0);
      const all = new Int16Array(total); let o = 0;
      for (const c of fromBot.chunks) { all.set(c, o); o += c.length; }
      const est = estimateFreq(all, fromBot.rate);
      ok(Math.abs(est.freq - 440) < 440 * 0.03, 'listener audio YIN', { freqHz: Number(est.freq.toFixed(1)), voicedMs: est.voicedMs, rxRate: fromBot.rate, samples: total });
    } else ok(false, 'listener audio received', [...audio.keys()]);

    // 5. errors
    r = await curl([...auth('lrb_' + crypto.randomBytes(32).toString('base64url')), `${HTTP}/api/v1/circle`]);
    ok(r.status === 401, 'wrong token -> 401', `${r.status} ${r.body?.error}`);
    owner.send({ t: 'bot_token_create', circleId: cid, name: 'E2E临时', ownerKey });
    const tok2 = await owner.waitFor((m) => m.t === 'bot_token');
    r = await curl([...auth(tok2.token), `${HTTP}/api/v1/circle`]);
    const pre = r.status;
    const sse2 = curlSse(tok2.token);
    await sse2.waitFor((e) => e.event === 'ready', 8000);
    let sse2Closed = null;
    sse2.p.on('close', () => { sse2Closed = Date.now(); });
    t = Date.now();
    owner.send({ t: 'bot_token_revoke', circleId: cid, id: tok2.id, ownerKey });
    const rv = await owner.waitFor((m) => m.op === 'bot_token_revoke');
    r = await curl([...auth(tok2.token), `${HTTP}/api/v1/circle`]);
    await wait(1500);
    ok(pre === 200 && rv?.t === 'owner_ok' && r.status === 401, 'revoked token -> 401', { before: pre, after: `${r.status} ${r.body?.error}`, sseClosedMs: sse2Closed ? sse2Closed - t : 'not closed' });
    if (!sse2Closed) sse2.p.kill();

    console.log('SSE keepalives seen:', sse.keepalives, 'events:', sse.events.map((e) => e.event).join(','));
    sse.p.kill();
    m2.close();
    await listener.leave();
  } catch (e) {
    ok(false, 'exception', String(e?.stack ?? e).replace(/lrb_[A-Za-z0-9_-]+/g, 'lrb_***'));
  } finally {
    await cleanup();
    if (token) {
      const r = await curl([...auth(token), `${HTTP}/api/v1/circle`]);
      ok(r.status === 401, 'token after circle_delete -> 401', `${r.status} ${r.body?.error}`);
    }
    owner.close();
    console.log(failed === 0 ? '\nPROD E2E ALL PASS' : `\nPROD E2E ${failed} FAILED`);
    setTimeout(() => process.exit(failed === 0 ? 0 : 1), 300);
  }
}
main().catch((e) => { console.error('fatal', String(e).replace(/lrb_[A-Za-z0-9_-]+/g, 'lrb_***')); process.exit(1); });