// Production E2E for 隐名之约 (anonym): fresh v2 circle → 3 humans join → anon_start k=2 → ack (Ed25519) →
// utterances (public fact / sarcasm naming another's org / proposal) → anon_ask (real LLM) → anon_draft →
// 2 signed approvals → anon_released (content checks) → anon_mem_list / retract → transcript_append blocked →
// anon_end (receipt) → circle_delete. Writes anonym_prod_e2e.last.txt (PASS/FAIL per step, no secrets).
// Usage: cd server/tool; node anonym_prod_e2e.mjs

import crypto from 'node:crypto';
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { authVerifier } from './lares_bot.mjs';
import { hasToneMarker } from '../anonym-agent/core/gate/l3.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, 'anonym_prod_e2e.last.txt');
const WSURL = process.env.LARES_WS ?? 'wss://lares.westus.cloudapp.azure.com/ws';
const PASSCODE = 'prod-e2e-' + crypto.randomBytes(6).toString('hex');
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m).digest('hex');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const rid = () => crypto.randomBytes(3).toString('hex');

// ── report ──
const steps = [];
const report = [];
let curStep = null;
function step(name) { curStep = { name, ok: true, notes: [] }; steps.push(curStep); console.log(`\n[${steps.length}] ${name}`); }
function ok(cond, what, val) {
  const s = typeof val === 'string' ? val : JSON.stringify(val ?? null);
  const v = s.length > 600 ? s.slice(0, 600) + '…' : s;
  console.log(`${cond ? '✓' : '✗'} ${what}: ${v}`);
  report.push(`  ${cond ? '✓' : '✗'} ${what}: ${v}`);
  if (!cond && curStep) { curStep.ok = false; curStep.notes.push(what); }
  return cond;
}

function newCircleId() {
  const a = 'abcdefghijklmnopqrstuvwxyz234567';
  let s = 'c_';
  for (const b of crypto.randomBytes(24)) s += a[b & 31];
  return s;
}

// ── client Ed25519 (docs/plans/chatham/client-canonicalisation.md) ──
function canonicalJSON(v) {
  if (Array.isArray(v)) return `[${v.map(canonicalJSON).join(',')}]`;
  if (v && typeof v === 'object') {
    return `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonicalJSON(v[k])}`).join(',')}}`;
  }
  if (typeof v === 'number' && !Number.isFinite(v)) throw new Error('non-finite');
  return JSON.stringify(v);
}
function newKey() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
  return { privateKey, pubKey: raw.toString('base64') }; // standard base64, padded
}
function signApproval(key, { sid, draftId, draftHash }) {
  const nonce = crypto.randomBytes(16).toString('base64url'); // 22 chars, no padding
  const msg = canonicalJSON({ sid, draftId, draftHash, nonce });
  const sig = crypto.sign(null, Buffer.from(msg, 'utf8'), key.privateKey).toString('base64');
  return { nonce, sig };
}
function selfTestVector() {
  const seed = Buffer.from([...Array(32).keys()]);
  const pk = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
  const pub = Buffer.from(crypto.createPublicKey(pk).export({ format: 'jwk' }).x, 'base64url').toString('base64');
  const msg = canonicalJSON({ sid: 'S1', draftId: 'd1', draftHash: 'h', nonce: 'AAECAwQFBgcICQoLDA0ODw' });
  const sig = crypto.sign(null, Buffer.from(msg), pk).toString('base64');
  return pub === 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg='
    && msg === '{"draftHash":"h","draftId":"d1","nonce":"AAECAwQFBgcICQoLDA0ODw","sid":"S1"}'
    && sig === 'C4fR1aepz6LZ0oEc5B+yelRCzW64Ujp43mSgWkayEd5lvwHWR91fWq3W1lHglmC+DCrocIpB7wue0EzI+ChTBQ==';
}

// ── ws member ──
function wsMember({ cid, verifier, userId, name, register }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WSURL);
    const inbox = [];
    const waiters = [];
    const m = {
      ws, inbox, userId, name,
      send: (o) => ws.send(JSON.stringify(o)),
      waitFor: (pred, ms = 10000) => {
        const i = inbox.findIndex(pred);
        if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
        return new Promise((res) => { const w = { pred, res, t: setTimeout(() => { const k = waiters.indexOf(w); if (k >= 0) waiters.splice(k, 1); res(null); }, ms) }; waiters.push(w); });
      },
      req: (o, pred, ms) => { const p = m.waitFor(pred, ms); m.send(o); return p; },
      drain: (pred = () => true) => { for (let i = inbox.length - 1; i >= 0; i--) if (pred(inbox[i])) inbox.splice(i, 1); },
      close: () => { try { ws.close(); } catch { /* */ } },
    };
    ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch { return; }
      if (msg.t === 'challenge') {
        ws.send(JSON.stringify({
          t: 'hello', userId, deviceId: `d-${userId}`, name, platform: 'e2e',
          auth: { mode: 'circle', v: 2, circleId: cid, nonce: msg.nonce, proof: hmac(verifier, `${msg.nonce}:${userId}:${cid}`), ...(register ? { register } : {}) },
        }));
        return;
      }
      const w = waiters.find((x) => x.pred(msg));
      if (w) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(msg); } else inbox.push(msg);
      if (inbox.length > 500) inbox.splice(0, inbox.length - 500);
      if (msg.t === 'welcome') { m._welcomed = true; resolve(m); }
      if (msg.t === 'error' && !m._welcomed) reject(new Error(`hello error ${msg.message ?? msg.reason}`));
    });
    ws.on('close', (code) => { if (!m._welcomed) reject(new Error(`ws closed ${code}`)); });
    ws.on('error', (e) => { if (!m._welcomed) reject(e); });
  });
}

// ── scenario data ──
const PEOPLE = [
  { key: 'A', name: '王晓明', org: '星辰科技' },
  { key: 'B', name: '李雪', org: '青松律所' },
  { key: 'C', name: '赵磊', org: '海川资本' },
];
const NAMES = PEOPLE.map((p) => p.name);
const ORGS = [...PEOPLE.map((p) => p.org), '星辰', '青松', '海川'];
const SARCASM = ['呵呵', '可真行', '真是厉害', '佩服佩服'];
const UTTS = [
  ['A', '我是王晓明，在星辰科技负责产品。今天想聊聊下半年团队的读书计划。'],
  ['C', '我在海川资本做投资，最近在读科幻。顺便说一句，《三体》是刘慈欣写的，这本书讨论的是文明之间的猜疑链。'],
  ['B', '呵呵，星辰科技可真行，上个季度的项目又延期了三个月，真是厉害了，佩服佩服。'],
  ['A', '我提议从下个月开始，每两周的周五下午办一次跨团队读书会，第一本就读《三体》，每次一小时。'],
  ['C', '我同意这个提议，读书会可以轮流主持，每次结束时写一页读书笔记共享给大家。'],
];
const QUESTION = '我们刚才提到的《三体》是谁写的？';
const LEAK_PROBES = ['刘慈欣', '星辰科技', '海川资本', '青松律所', '读书会', '猜疑链', '可真行', '佩服佩服', '轮流主持'];

async function main() {
  const cid = newCircleId();
  const ownerKey = crypto.randomBytes(32).toString('hex');
  const members = [];
  let owner = null;
  let sid = null;
  let released = null;
  let endedOk = false;
  const isErr = (op) => (m) => m.t === 'anon_error' && m.op === op;
  const ownerReply = (op) => (m) => m.op === op && (m.t === 'owner_ok' || m.t === 'owner_error');

  try {
    // 1
    step('register temporary v2 circle');
    ok(selfTestVector(), 'client signature test vector (client-canonicalisation.md)', 'match');
    const verifier = await authVerifier(PASSCODE, cid);
    owner = await wsMember({ cid, verifier, userId: `u_e2e_anon_a_${rid()}`, name: PEOPLE[0].name, register: { verifier, ownerHash: sha256(ownerKey) } });
    ok(Boolean(owner), 'registered + welcome', cid);
    members.push(owner);

    // 2
    step('3 humans join the room');
    const B = await wsMember({ cid, verifier, userId: `u_e2e_anon_b_${rid()}`, name: PEOPLE[1].name });
    const C = await wsMember({ cid, verifier, userId: `u_e2e_anon_c_${rid()}`, name: PEOPLE[2].name });
    members.push(B, C);
    const A = owner;
    const all = [A, B, C];
    for (const m of all) {
      const room = await m.req({ t: 'join', circleId: cid }, (x) => x.t === 'room' || x.t === 'error');
      ok(room?.t === 'room', `${m.name.length ? 'member' : ''} ${m.userId.slice(0, 14)} joined`, { t: room?.t, members: room?.members?.length });
    }
    await wait(500);

    // 3
    step('anon_start k=2 + 3× anon_ack (Ed25519)');
    for (const m of all) m.drain();
    let r = await A.req({ t: 'anon_start', circleId: cid, k: 2, ownerKey }, (m) => (m.t === 'anon_state' && m.active) || isErr('anon_start')(m), 10000);
    ok(r?.t === 'anon_state' && r.k === 2 && r.convenerId === A.userId && typeof r.sid === 'string' && r.members?.length === 3,
      'anon_state{active,k:2,convenerId,3 members}', r && { t: r.t, code: r.code, k: r.k, n: r.members?.length, convener: r.convenerId === A.userId });
    sid = r?.sid;
    const keys = new Map(all.map((m) => [m, newKey()]));
    for (const m of all) m.drain();
    for (const m of all) m.send({ t: 'anon_ack', circleId: cid, pubKey: keys.get(m).pubKey });
    const allAcked = await C.waitFor((m) => (m.t === 'anon_state' && m.members?.length === 3 && m.members.every((x) => x.acked)) || isErr('anon_ack')(m), 10000);
    ok(allAcked?.t === 'anon_state', 'all 3 acked (anon_state broadcast)', allAcked && { t: allAcked.t, code: allAcked.code, acked: allAcked.members?.map((x) => x.acked) });
    const ackErr = all.flatMap((m) => m.inbox.filter(isErr('anon_ack')));
    ok(ackErr.length === 0, 'no anon_ack errors', ackErr.map((e) => e.code));

    // 4
    step('anon_utt (public fact / sarcasm naming another\'s org / proposal)');
    const byKey = { A, B, C };
    let ts = Date.now();
    for (const [k, text] of UTTS) {
      byKey[k].send({ t: 'anon_utt', circleId: cid, text, ts: ts++, final: true });
      await wait(250);
    }
    await wait(800);
    const uttErr = all.flatMap((m) => m.inbox.filter(isErr('anon_utt')));
    ok(uttErr.length === 0, `${UTTS.length} utterances accepted (no anon_error)`, uttErr.map((e) => e.code));

    // 5
    step('anon_ask → real LLM answer');
    for (const m of all) m.drain();
    const t0 = Date.now();
    r = await B.req({ t: 'anon_ask', circleId: cid, question: QUESTION }, (m) => m.t === 'anon_answer' || isErr('anon_ask')(m), 90000);
    const ans = r?.answer ?? '';
    // mock answer = recalled items + raw utterance lines joined by \n; a real LLM answer is a fresh sentence
    const looksMock = UTTS.some(([, u]) => ans.includes(u)) || /No matching knowledge/.test(ans);
    ok(r?.t === 'anon_answer' && r.question === QUESTION && r.askerName === PEOPLE[1].name, 'anon_answer{askerName,question}', r && { t: r.t, code: r.code, askerName: r.askerName, ms: Date.now() - t0 });
    ok(/刘慈欣/.test(ans), 'answer names 刘慈欣', ans);
    ok(!looksMock && ans.length > 0, 'answer is LLM-generated (not mock echo of utterances)', { len: ans.length });
    const otherAns = await C.waitFor((m) => m.t === 'anon_answer', 5000);
    ok(Boolean(otherAns), 'answer also delivered to other acked member', Boolean(otherAns));

    // 6
    step('anon_draft → 2 signed approvals → anon_released');
    for (const m of all) m.drain();
    r = await A.req({ t: 'anon_draft', circleId: cid }, (m) => m.t === 'anon_draft' || isErr('anon_draft')(m), 180000);
    const draft = r?.draft;
    ok(Boolean(draft?.draftId) && /^[0-9a-f]{64}$/.test(draft?.draftHash ?? '') && draft.items?.length >= 1,
      'anon_draft{draftId,draftHash,items}', r && { t: r.t, code: r.code, items: draft?.items?.length, kinds: draft?.items?.map((i) => i.kind), flags: draft?.items?.map((i) => i.flags) });
    if (draft) {
      const dj = JSON.stringify(draft.items);
      ok(!NAMES.some((n) => dj.includes(n)), 'draft items contain no participant names', NAMES.filter((n) => dj.includes(n)));
      await C.waitFor((m) => m.t === 'anon_draft', 5000);
      for (const m of all) m.drain();
      const sgA = signApproval(keys.get(A), { sid, draftId: draft.draftId, draftHash: draft.draftHash });
      r = await A.req({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: draft.draftHash, ...sgA },
        (m) => m.t === 'anon_approvals' || isErr('anon_approve')(m), 15000);
      ok(r?.t === 'anon_approvals' && r.count === 1 && r.k === 2, 'approval #1 (owner) → anon_approvals{count:1,k:2}', r && { t: r.t, code: r.code, count: r.count, k: r.k });
      const relWait = C.waitFor((m) => m.t === 'anon_released', 30000);
      const sgB = signApproval(keys.get(B), { sid, draftId: draft.draftId, draftHash: draft.draftHash });
      r = await B.req({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: draft.draftHash, ...sgB },
        (m) => (m.t === 'anon_approvals' && m.count === 2) || isErr('anon_approve')(m), 15000);
      ok(r?.t === 'anon_approvals' && r.count === 2, 'approval #2 → anon_approvals{count:2}', r && { t: r.t, code: r.code, count: r.count });
      const rel = await relWait;
      released = rel?.text ?? null;
      ok(rel?.t === 'anon_released' && rel.draftId === draft.draftId && typeof rel.text === 'string' && rel.text.length > 0, 'anon_released{draftId,text}', rel && { draftId: rel.draftId === draft.draftId, len: rel.text?.length });
    }

    // 7
    step('released text: keeps 三体/刘慈欣, no names/orgs, no sarcasm');
    const txt = released ?? '';
    console.log(`released text:\n${txt}`);
    ok(/三体/.test(txt) && /刘慈欣/.test(txt), 'public fact kept (三体 + 刘慈欣)', { 三体: /三体/.test(txt), 刘慈欣: /刘慈欣/.test(txt) });
    ok(txt.length > 0 && !NAMES.some((n) => txt.includes(n)), 'no participant names', NAMES.filter((n) => txt.includes(n)));
    ok(txt.length > 0 && !ORGS.some((o) => txt.includes(o)), 'no participant organisations', ORGS.filter((o) => txt.includes(o)));
    ok(txt.length > 0 && !hasToneMarker(txt) && !SARCASM.some((s) => txt.includes(s)), 'no sarcasm markers', SARCASM.filter((s) => txt.includes(s)));

    // 8
    step('anon_mem_list → items; owner retracts one → anon_mem_retracted');
    r = await B.req({ t: 'anon_mem_list', circleId: cid }, (m) => m.t === 'anon_mem' || isErr('anon_mem_list')(m), 10000);
    const live = (r?.items ?? []).filter((i) => !i.retracted);
    ok(r?.t === 'anon_mem' && live.length >= 1 && live.every((i) => i.sid === sid && typeof i.text === 'string' && !('approverIds' in i)),
      'anon_mem items from this release (no approver ids)', r && { t: r.t, code: r.code, n: live.length, kinds: live.map((i) => i.kind), canRetract: live.map((i) => i.canRetract) });
    if (live.length) {
      const itemId = live[0].id;
      for (const m of all) m.drain();
      const seenC = C.waitFor((m) => m.t === 'anon_mem_retracted' && m.itemId === itemId, 10000);
      r = await A.req({ t: 'anon_mem_retract', circleId: cid, itemId, ownerKey }, (m) => (m.t === 'anon_mem_retracted' && m.itemId === itemId) || isErr('anon_mem_retract')(m), 10000);
      ok(r?.t === 'anon_mem_retracted', 'owner retract → anon_mem_retracted', r && { t: r.t, code: r.code });
      ok(Boolean(await seenC), 'anon_mem_retracted broadcast to other member', true);
      r = await A.req({ t: 'anon_mem_list', circleId: cid, ownerKey }, (m) => m.t === 'anon_mem' || isErr('anon_mem_list')(m), 10000);
      const tomb = r?.items?.find((i) => i.id === itemId);
      ok(tomb?.retracted === true && !('text' in tomb), 'retracted item is a tombstone (no text)', tomb);
    }

    // 9
    step('transcript_append rejected with anonym_active');
    r = await B.req({ t: 'transcript_append', circleId: cid, id: `x-${rid()}`, text: '这句不该被记录', startedAt: Date.now() },
      (m) => m.t === 'transcript_error' || m.t === 'transcript_appended', 10000);
    ok(r?.t === 'transcript_error' && r.reason === 'anonym_active', 'transcript_error{reason:anonym_active}', r && { t: r.t, reason: r.reason });

    // 10
    step('anon_end → anon_ended with receipt');
    for (const m of all) m.drain();
    const endedC = C.waitFor((m) => m.t === 'anon_ended', 15000);
    r = await A.req({ t: 'anon_end', circleId: cid, ownerKey }, (m) => m.t === 'anon_ended' || isErr('anon_end')(m), 15000);
    const ec = await endedC;
    ok(r?.t === 'anon_ended' && /^[0-9a-f]{64}$/.test(r.receipt?.sha256 ?? '') && r.receipt?.counts && r.receipt.counts.releases === 1,
      'anon_ended{receipt:{counts,sha256}}', r && { t: r.t, code: r.code, counts: r.receipt?.counts, sha256: Boolean(r.receipt?.sha256) });
    ok(Boolean(ec), 'anon_ended delivered to other members', Boolean(ec));
    endedOk = r?.t === 'anon_ended';
  } catch (e) {
    ok(false, 'exception', String(e?.stack ?? e));
  } finally {
    // 11
    step('circle_delete (cleanup)');
    try {
      if (owner) {
        if (!endedOk && sid) await owner.req({ t: 'anon_end', circleId: cid, ownerKey }, (m) => m.t === 'anon_ended' || m.t === 'anon_error', 8000);
        for (const m of members) if (m !== owner) m.close();
        await wait(300);
        const r = await owner.req({ t: 'circle_delete', circleId: cid, ownerKey }, ownerReply('circle_delete'), 10000);
        ok(r?.t === 'owner_ok', 'circle_delete', r && { t: r.t, reason: r.reason });
      } else ok(false, 'circle_delete', 'no owner connection');
    } catch (e) { ok(false, 'cleanup', String(e)); }
    owner?.close();

    // 12
    const failed = steps.filter((s) => !s.ok).length;
    step('write report');
    const lines = [
      `anonym prod e2e  ${new Date().toISOString()}  server=${WSURL.replace(/\/ws$/, '')}`,
      `circle=${cid.slice(0, 8)}… (temporary, deleted)`,
      '',
      ...steps.slice(0, -1).map((s, i) => `${s.ok ? 'PASS' : 'FAIL'}  ${i + 1}. ${s.name}${s.notes.length ? '  — ' + s.notes.join('; ') : ''}`),
      `PASS  ${steps.length}. write report`,
      '',
      `RESULT: ${failed === 0 ? 'ALL PASS' : `${failed} FAILED`}`,
      '',
      'released text:',
      released ?? '(none)',
      '',
      'details:',
      ...report,
    ];
    // no secrets: passcode / ownerKey / verifier / private keys are never put into report lines
    const body = lines.join('\n').split(PASSCODE).join('***').split(ownerKey).join('***') + '\n';
    writeFileSync(OUT, body, 'utf8');
    console.log(`\n${failed === 0 ? 'PROD E2E ALL PASS' : `PROD E2E ${failed} FAILED`}  → ${OUT}`);
    process.exitCode = failed === 0 ? 0 : 1;
  }
}

// LEAK_PROBES: grep these in `docker compose -p lares logs --since 10m lares-server` after a run; expect 0 hits.
void LEAK_PROBES;
main().catch((e) => { console.error('fatal', String(e?.message ?? e)); process.exitCode = 1; });
