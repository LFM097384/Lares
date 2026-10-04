// Production E2E: (1) captions off + transcript on → cap_token issued, own transcript line seen live + in history
// (optional real DashScope ASR with the issued temp token); (2) profile_set (member_updated, invalid emoji,
// rate limit, control-char stripping); (3) cleanup (transcript_clear + circle_delete).
// Usage: cd server/tool; node profile_transcript_prod_e2e.mjs   (SKIP_ASR=1 to skip the real ASR call)

import crypto from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import WebSocket from 'ws';
import { authVerifier } from './lares_bot.mjs';
import { DashscopeAsr } from '../bots/voice-agent/providers/dashscope.mjs';

const WSURL = 'wss://lares.westus.cloudapp.azure.com/ws';
const PASSCODE = 'prod-e2e-' + crypto.randomBytes(4).toString('hex');
const WAV = 'D:\\Projects\\Qualitati\\v2v-lab\\data\\asr_eval\\syn_0_00.wav';
let failed = 0;
const redact = (v) => JSON.stringify(v ?? null).replace(/"token":"[^"]*"/g, '"token":"***"');
const ok = (cond, name, val) => {
  console.log(`${cond ? '✓' : '✗'} ${name}: ${typeof val === 'string' ? val : redact(val)}`);
  if (!cond) failed++;
  return cond;
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m).digest('hex');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const rid = () => crypto.randomBytes(3).toString('hex');

function newCircleId() {
  const a = 'abcdefghijklmnopqrstuvwxyz234567';
  let s = 'c_';
  for (const b of crypto.randomBytes(24)) s += a[b & 31];
  return s;
}

function wsMember({ cid, verifier, userId, name, register }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WSURL);
    const inbox = [];
    const all = [];
    const waiters = [];
    const m = {
      ws, inbox, all, userId,
      send: (o) => ws.send(JSON.stringify(o)),
      waitFor: (pred, ms = 8000) => {
        const i = inbox.findIndex(pred);
        if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
        return new Promise((res) => { const w = { pred, res, t: setTimeout(() => { const k = waiters.indexOf(w); if (k >= 0) waiters.splice(k, 1); res(null); }, ms) }; waiters.push(w); });
      },
      req: (o, pred, ms) => { const p = m.waitFor(pred, ms); m.send(o); return p; },
      drain: (pred) => { for (let i = inbox.length - 1; i >= 0; i--) if (pred(inbox[i])) inbox.splice(i, 1); },
      close: () => ws.close(),
    };
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw);
      if (msg.t === 'challenge') {
        ws.send(JSON.stringify({
          t: 'hello', userId, deviceId: `d-${userId}`, name, platform: 'e2e',
          auth: { mode: 'circle', v: 2, circleId: cid, nonce: msg.nonce, proof: hmac(verifier, `${msg.nonce}:${userId}:${cid}`), ...(register ? { register } : {}) },
        }));
        return;
      }
      all.push(msg);
      const w = waiters.find((x) => x.pred(msg));
      if (w) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(msg); } else inbox.push(msg);
      if (msg.t === 'welcome') { m._welcomed = true; resolve(m); }
      if (msg.t === 'error' && !m._welcomed) reject(new Error(`hello error ${msg.message ?? msg.reason}`));
    });
    ws.on('close', (code) => reject(new Error(`ws closed ${code}`)));
    ws.on('error', reject);
  });
}

/// Real DashScope ASR with the server-issued temporary token (same path as the app's captions)
async function realAsr(token, url) {
  const buf = readFileSync(WAV);
  // 16 kHz mono 16-bit, standard 44-byte header (verified)
  const pcm = new Int16Array(buf.buffer.slice(buf.byteOffset + 44, buf.byteOffset + buf.length - ((buf.length - 44) % 2)));
  const host = new URL(url).host;
  process.env.LARES_DASHSCOPE_HOST = host;
  const asr = new DashscopeAsr({ apiKey: token });
  const finals = [];
  let err = null;
  return new Promise((resolve) => {
    let timer = null;
    const h = asr.open({
      identity: 'e2e',
      onFinal: (t) => finals.push(t),
      onError: (e) => { err = String(e?.message ?? e); },
      onClose: () => { clearTimeout(timer); resolve({ text: finals.join(''), err }); },
    });
    (async () => {
      for (let o = 0; o < pcm.length; o += 1600) { h.send(pcm.slice(o, o + 1600)); await wait(50); }
      for (let k = 0; k < 20; k++) { h.send(new Int16Array(1600)); await wait(50); }
      await h.finish(5000);
    })().catch((e) => { err = String(e?.message ?? e); });
    timer = setTimeout(() => h.close(), 40000);
  });
}

async function main() {
  const cid = newCircleId();
  const verifier = await authVerifier(PASSCODE, cid);
  const ownerKey = crypto.randomBytes(32).toString('hex');
  const owner = await wsMember({ cid, verifier, userId: `u_e2e_owner_${rid()}`, name: 'E2E圈主', register: { verifier, ownerHash: sha256(ownerKey) } });
  ok(true, 'register circle', cid);
  const ownerReply = (op) => (m) => m.op === op && (m.t === 'owner_ok' || m.t === 'owner_error');
  const members = [];
  try {
    // ── 1. captions off (study) + transcript on ──
    console.log('\n[1] captions off + transcript on');
    const pa = owner.waitFor((m) => m.t === 'purpose_applied');
    let r = await owner.req({ t: 'circle_purpose_apply', circleId: cid, ownerKey, purpose: 'study' }, ownerReply('circle_purpose_apply'));
    const paMsg = await pa;
    ok(r?.t === 'owner_ok' && paMsg?.purpose?.id === 'study', 'circle_purpose_apply study', { ack: r?.t, reason: r?.reason, purpose: paMsg?.purpose?.id, captions: paMsg?.features?.captions });
    owner.send({ t: 'join', circleId: cid });
    await owner.waitFor((m) => m.t === 'room');

    const aId = `u_e2e_a_${rid()}`;
    const a = await wsMember({ cid, verifier, userId: aId, name: '成员甲' });
    members.push(a);
    a.send({ t: 'join', circleId: cid });
    const roomA = await a.waitFor((m) => m.t === 'room');
    ok(Boolean(roomA), 'member A joined room', { members: roomA?.members?.length, captions: roomA?.features?.captions ?? roomA?.circle?.features?.captions });

    const capReq = () => a.req({ t: 'cap_token' }, (m) => m.t === 'cap_token' || m.t === 'cap_error', 8000);
    r = await capReq();
    ok(r?.t === 'cap_error' && r.reason === 'feature_off', 'captions off + transcript off → feature_off (baseline)', { t: r?.t, reason: r?.reason });

    r = await owner.req({ t: 'circle_transcript_set', circleId: cid, ownerKey, on: true }, ownerReply('circle_transcript_set'));
    ok(r?.t === 'owner_ok', 'circle_transcript_set on', { t: r?.t, reason: r?.reason });
    await wait(300);
    r = await capReq();
    const capOk = ok(r?.t === 'cap_token' && typeof r.token === 'string' && r.token.length > 10, 'captions off + transcript on → cap_token issued',
      { t: r?.t, reason: r?.reason, hasToken: Boolean(r?.token), expiresInS: r?.expiresAt ? Math.round((r.expiresAt > 1e12 ? r.expiresAt / 1000 : r.expiresAt) - Date.now() / 1000) : null, url: r?.url, model: r?.model });

    let lineText = '我自己说的话(生产验证)';
    if (capOk && process.env.SKIP_ASR !== '1' && existsSync(WAV)) {
      const t0 = Date.now();
      const asr = await realAsr(r.token, r.url);
      ok(asr.text.length >= 2 && !asr.err, 'real DashScope ASR with issued temp token', { text: asr.text, err: asr.err, ms: Date.now() - t0 });
      if (asr.text) lineText = asr.text;
    } else console.log('- real ASR skipped');

    a.drain(() => true);
    const lineId = `own-${rid()}`;
    const live = a.waitFor((m) => m.t === 'transcript_line' && m.item?.id === lineId, 8000);
    const ownerLive = owner.waitFor((m) => m.t === 'transcript_line' && m.item?.id === lineId, 8000);
    r = await a.req({ t: 'transcript_append', circleId: cid, id: lineId, text: lineText, startedAt: Date.now() - 2000 }, (m) => m.t === 'transcript_appended' || m.t === 'transcript_error');
    ok(r?.t === 'transcript_appended', 'transcript_append own final line', { t: r?.t, reason: r?.reason, seq: r?.seq });
    const ownLine = await live;
    ok(ownLine?.item?.userId === aId && ownLine.item.text === lineText, 'sender sees own transcript_line live', { userId: ownLine?.item?.userId === aId ? 'self' : ownLine?.item?.userId, text: ownLine?.item?.text, seq: ownLine?.item?.seq });
    const ol = await ownerLive;
    ok(Boolean(ol), 'other member (owner) also sees the line live', Boolean(ol));
    r = await a.req({ t: 'transcript_get', circleId: cid, limit: 20 }, (m) => m.t === 'transcript_page' || m.t === 'transcript_error');
    ok(r?.t === 'transcript_page' && r.items?.some((it) => it.id === lineId && it.userId === aId), 'sender transcript_get contains own line',
      r?.items?.map((x) => `${x.seq}:${x.name}:${x.text}`) ?? r);

    // ── 2. profile_set ──
    console.log('\n[2] profile_set');
    const bId = `u_e2e_b_${rid()}`;
    const b = await wsMember({ cid, verifier, userId: bId, name: '成员乙' });
    members.push(b);
    b.send({ t: 'join', circleId: cid });
    await b.waitFor((m) => m.t === 'room');
    await wait(300);
    a.drain(() => true); b.drain(() => true);

    let upd = b.waitFor((m) => m.t === 'member_updated' && m.member?.userId === aId);
    r = await a.req({ t: 'profile_set', name: '甲·新名', emoji: '🔥', bio: '生产验证中 ✨' }, (m) => m.t === 'profile_ok' || m.t === 'profile_error');
    ok(r?.t === 'profile_ok' && r.name === '甲·新名' && r.emoji === '🔥' && r.bio === '生产验证中 ✨', 'A gets profile_ok', r);
    let u = await upd;
    ok(u?.member?.name === '甲·新名' && u.member.emoji === '🔥' && u.member.bio === '生产验证中 ✨', 'B receives member_updated with new values', u?.member);
    let used = 1;

    r = await a.req({ t: 'profile_set', emoji: '🔥🔥', name: '不该生效' }, (m) => m.t === 'profile_ok' || m.t === 'profile_error');
    used++;
    ok(r?.t === 'profile_error' && r.reason === 'invalid', 'invalid emoji → invalid', r);
    const notApplied = await b.waitFor((m) => m.t === 'member_updated' && m.member?.userId === aId, 800);
    ok(!notApplied, 'invalid update not broadcast', notApplied?.member ?? 'none');

    upd = b.waitFor((m) => m.t === 'member_updated' && m.member?.userId === aId);
    r = await a.req({ t: 'profile_set', name: '控\u0000制\u202E符\u200B', bio: '第一行\n\n第二\t行\u0007\u2066' }, (m) => m.t === 'profile_ok' || m.t === 'profile_error');
    used++;
    u = await upd;
    ok(r?.t === 'profile_ok' && r.name === '控制符' && r.bio === '第一行 第二 行' && u?.member?.name === '控制符' && u.member.bio === '第一行 第二 行',
      'control chars stripped (profile_ok + member_updated)', { ok: { name: r?.name, bio: r?.bio }, upd: { name: u?.member?.name, bio: u?.member?.bio } });

    // rate limit: bucket 10, refill 1/6s → burst until rate_limited
    a.drain(() => true);
    let successes = 0;
    let limited = null;
    for (let i = 0; i < 15 && !limited; i++) {
      r = await a.req({ t: 'profile_set', name: `名${i}` }, (m) => m.t === 'profile_ok' || m.t === 'profile_error');
      used++;
      if (r?.t === 'profile_ok') successes++;
      else if (r?.reason === 'rate_limited') limited = { attempt: used, retryMs: r.retryMs };
      else { ok(false, 'unexpected profile_set reply', r); break; }
    }
    ok(limited && limited.attempt >= 11 && limited.attempt <= 12 && limited.retryMs > 0, 'rate_limited after 10 updates/minute', { ...limited, burstSuccesses: successes, totalSent: used });

    // ── final member snapshot check via a fresh join ──
    const c = await wsMember({ cid, verifier, userId: `u_e2e_c_${rid()}`, name: '成员丙' });
    members.push(c);
    c.send({ t: 'join', circleId: cid });
    const roomC = await c.waitFor((m) => m.t === 'room');
    const snapA = roomC?.members?.find((m) => m.userId === aId);
    ok(snapA?.emoji === '🔥' && /^名\d+$/.test(snapA?.name ?? ''), 'room snapshot for newcomer carries A profile', { name: snapA?.name, emoji: snapA?.emoji, bio: snapA?.bio });
  } catch (e) {
    ok(false, 'exception', String(e?.stack ?? e));
  } finally {
    console.log('\n[3] cleanup');
    try {
      let r = await owner.req({ t: 'transcript_clear', circleId: cid, ownerKey }, ownerReply('transcript_clear'));
      ok(r?.t === 'owner_ok', 'transcript_clear', { t: r?.t, reason: r?.reason });
      for (const m of members) m.close();
      r = await owner.req({ t: 'circle_delete', circleId: cid, ownerKey }, ownerReply('circle_delete'));
      ok(r?.t === 'owner_ok', 'circle_delete', { t: r?.t, reason: r?.reason });
    } catch (e) { ok(false, 'cleanup', String(e)); }
    owner.close();
    console.log(failed === 0 ? '\nPROD E2E ALL PASS' : `\nPROD E2E ${failed} FAILED`);
    setTimeout(() => process.exit(failed === 0 ? 0 : 1), 300);
  }
}
main().catch((e) => { console.error('fatal', String(e?.message ?? e)); process.exit(1); });
