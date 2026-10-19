// Production E2E for 隐名之约 agent v2 (server-spawned LiveKit member u_ai_anon_<8hex>).
// For each of two fresh v2 circles (plain + E2EE):
//   register → (E2EE: circle_e2ee_set) → 3 humans join (signaling + LiveKit, real mic tracks)
//   → owner anon_agent_invite k=2 → (E2EE: keyreq → seal(mediaKeyHex) → anon_agent_key)
//   → agent participant appears → state → 3× ack (Ed25519) → real speech (DashScope TTS → LiveKit audio)
//   → ask → answer → skill minutes → draft → 2 signed approvals → released (content checks)
//   → mem_list / mem_retract → SSH: memory dir has no retracted text → transcript_append refused (anonym_active)
//   → owner end → ended{receipt} → agent participant leaves → circle_delete → SSH: memory dir gone.
// Finally: SSH server log scan (utterance leakage / agent child errors).
// Writes anonym_v2_prod_e2e.last.txt (PASS/FAIL per step, no secrets).
// Usage: cd server/tool; node anonym_v2_prod_e2e.mjs [--only plain|e2ee]
// Needs ~/.ssh/lares_ed25519 (read-only: printenv for the DashScope TTS key, logs, memory dir listing).

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { AudioFrame } from '@livekit/rtc-node';
import { LaresBot, authVerifier, e2eeKeyHex } from './lares_bot.mjs';
import { resample, concatInt16 } from '../../hearthvoice/audio.mjs';
import { DashscopeTts } from '../../hearthvoice/providers/dashscope.mjs';
import { seal, hasToneMarker } from '../../ember/index.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, 'anonym_v2_prod_e2e.last.txt');
const HOST = 'lares.westus.cloudapp.azure.com';
const WSURL = process.env.LARES_WS ?? `wss://${HOST}/ws`;
const SSH = ['-i', path.join(homedir(), '.ssh', 'lares_ed25519'), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', `azureuser@${HOST}`];
const CONTAINER = 'lares-lares-server-1';
const CACHE = path.join(tmpdir(), 'lares-anonym-v2-e2e-cache');
const TOPIC = 'lares.anon';
const ONLY = (() => { const i = process.argv.indexOf('--only'); return i > 0 ? process.argv[i + 1] : null; })();
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m).digest('hex');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const rid = () => crypto.randomBytes(3).toString('hex');
const agentIdOf = (cid) => `u_ai_anon_${sha256(cid).slice(0, 8)}`;

// ── secrets: kept in memory only, scrubbed from every printed / written line ──
const SECRETS = new Set();
const redact = (s) => {
  let out = String(s);
  for (const x of SECRETS) if (x && x.length >= 8) out = out.split(x).join('***');
  return out.replace(/sk-[A-Za-z0-9]{16,}/g, 'sk-***');
};

// ── report ──
const steps = [];
let curStep = null;
const detail = [];
function step(name) { curStep = { name, ok: true, notes: [] }; steps.push(curStep); const l = `\n[${steps.length}] ${name}`; console.log(l); detail.push(l); }
function ok(cond, what, val) {
  const s = typeof val === 'string' ? val : JSON.stringify(val ?? null);
  const v = redact(s.length > 900 ? s.slice(0, 900) + '…' : s);
  const l = `  ${cond ? '✓' : '✗'} ${what}: ${v}`;
  console.log(l); detail.push(l);
  if (!cond && curStep) { curStep.ok = false; curStep.notes.push(what); }
  return cond;
}
function info(what, val) { const s = typeof val === 'string' ? val : JSON.stringify(val ?? null); const l = `  · ${what}: ${redact(s.length > 1500 ? s.slice(0, 1500) + '…' : s)}`; console.log(l); detail.push(l); }

// ── ssh (stdin script → bash -s; stdout captured in memory) ──
function ssh(script, { timeoutMs = 90_000 } = {}) {
  return new Promise((resolve) => {
    const p = spawn('ssh', [...SSH, 'bash -s'], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    const out = []; const err = [];
    const t = setTimeout(() => { try { p.kill(); } catch { /* */ } }, timeoutMs);
    p.stdout.on('data', (b) => out.push(b));
    p.stderr.on('data', (b) => err.push(b));
    p.on('close', (code) => { clearTimeout(t); resolve({ code, out: Buffer.concat(out).toString('utf8'), err: Buffer.concat(err).toString('utf8') }); });
    p.on('error', (e) => { clearTimeout(t); resolve({ code: -1, out: '', err: String(e) }); });
    p.stdin.end(script.replace(/\r\n/g, '\n'));
  });
}
async function memDir(cid) {
  const js = 'const fs=require("fs"),p=require("path");const d=process.argv[1];if(!fs.existsSync(d)){console.log(JSON.stringify({exists:false}));}else{const files=[];const w=(x)=>{for(const e of fs.readdirSync(x,{withFileTypes:true})){const f=p.join(x,e.name);if(e.isDirectory())w(f);else files.push({f:p.relative(d,f),s:fs.readFileSync(f,"utf8")});}};w(d);console.log(JSON.stringify({exists:true,files}));}';
  const r = await ssh(`docker exec ${CONTAINER} node -e '${js}' "/app/data/anonym_memory/${cid}"\n`);
  try { return JSON.parse(r.out.trim().split('\n').pop()); } catch { return { error: (r.err || r.out).slice(0, 300) }; }
}

// ── Ed25519 approvals (client-canonicalisation.md) ──
function canonicalJSON(v) {
  if (Array.isArray(v)) return `[${v.map(canonicalJSON).join(',')}]`;
  if (v && typeof v === 'object') return `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonicalJSON(v[k])}`).join(',')}}`;
  return JSON.stringify(v);
}
function newKey() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  return { privateKey, pubKey: Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64') };
}
function signApproval(key, { sid, draftId, draftHash }) {
  const nonce = crypto.randomBytes(16).toString('base64url');
  const sig = crypto.sign(null, Buffer.from(canonicalJSON({ sid, draftId, draftHash, nonce }), 'utf8'), key.privateKey).toString('base64');
  return { nonce, sig };
}
function newCircleId() {
  const a = 'abcdefghijklmnopqrstuvwxyz234567';
  let s = 'c_';
  for (const b of crypto.randomBytes(24)) s += a[b & 31];
  return s;
}

// ── raw ws: register the circle (owner hello with register), optional e2ee flag ──
function registrar({ cid, verifier, ownerKey }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WSURL);
    const userId = `u_e2e_reg_${rid()}`;
    const inbox = [];
    const m = { ws, close: () => { try { ws.close(); } catch { /* */ } }, next: (pred, ms = 10000) => new Promise((res) => { const t0 = Date.now(); const tick = () => { const i = inbox.findIndex(pred); if (i >= 0) return res(inbox.splice(i, 1)[0]); if (Date.now() - t0 > ms) return res(null); setTimeout(tick, 50); }; tick(); }) };
    ws.on('message', (raw) => {
      let msg; try { msg = JSON.parse(raw); } catch { return; }
      if (msg.t === 'challenge') {
        ws.send(JSON.stringify({ t: 'hello', userId, deviceId: `d-${userId}`, name: '登记', platform: 'e2e', auth: { mode: 'circle', v: 2, circleId: cid, nonce: msg.nonce, proof: hmac(verifier, `${msg.nonce}:${userId}:${cid}`), register: { verifier, ownerHash: sha256(ownerKey) } } }));
        return;
      }
      inbox.push(msg);
      if (msg.t === 'welcome') resolve(m);
      if (msg.t === 'error' && !m.ok) reject(new Error(`hello error ${msg.message ?? msg.reason}`));
    });
    ws.on('close', (c) => reject(new Error(`ws closed ${c}`)));
    ws.on('error', reject);
  });
}

// ── scenario ──
const PEOPLE = [
  { key: 'A', name: '张伟', org: '星辰科技' },
  { key: 'B', name: '李娜', org: '青松律所' },
  { key: 'C', name: '王强', org: '海川资本' },
];
const NAMES = PEOPLE.map((p) => p.name);
const ORGS = ['星辰科技', '青松律所', '海川资本', '星辰', '青松', '海川'];
const SARCASM = ['呵呵', '可真行', '真是厉害', '佩服佩服', '厉害了'];
const UTTS = [
  ['A', '大家好，我是张伟，在星辰科技负责产品。今天想聊聊下半年团队的读书计划。'],
  ['C', '我在海川资本做投资，最近在读科幻小说。顺便说一句，《三体》是刘慈欣写的，这本书讨论的是文明之间的猜疑链。'],
  ['B', '呵呵，星辰科技可真行，上个季度的项目又延期了三个月，真是厉害了，佩服佩服。'],
  ['A', '我提议请李娜牵头，从下个月开始，每两周的周五下午办一次读书会，第一本就读《三体》，每次一小时。'],
  ['C', '我同意这个提议，读书会可以轮流主持，每次结束时写一页读书笔记，共享给大家。'],
];
const QUESTION = '刚才提到的《三体》是谁写的？';
const LOG_PROBES = ['刘慈欣', '猜疑链', '可真行', '佩服佩服', '读书会', '读书笔记', '延期了三个月', '轮流主持', '下半年团队', '三体'];

// ── TTS (DashScope realtime; key read from the prod container over SSH, memory only) ──
function readWav(file) {
  const b = readFileSync(file);
  const n = b.readUInt32LE(40);
  const pcm = new Int16Array(n / 2);
  for (let i = 0; i < pcm.length; i++) pcm[i] = b.readInt16LE(44 + i * 2);
  return { rate: b.readUInt32LE(24), pcm };
}
function writeWav(file, pcm, rate) {
  const data = Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0, 'ascii'); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8, 'ascii');
  h.write('fmt ', 12, 'ascii'); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36, 'ascii'); h.writeUInt32LE(data.length, 40);
  writeFileSync(file, Buffer.concat([h, data]));
}
async function synthAll(texts, key) {
  mkdirSync(CACHE, { recursive: true });
  const voices = { A: 'Cherry', B: 'Cherry', C: 'Cherry' };
  const fileOf = (v, t) => path.join(CACHE, `${sha256(`${v}:${t}`).slice(0, 16)}.wav`);
  const out = {};
  for (const [who, t] of texts) {
    const v = voices[who] ?? 'Cherry';
    const f = fileOf(v, t);
    if (!existsSync(f)) {
      if (!key) throw new Error('no_tts_key');
      const tts = new DashscopeTts({ apiKey: key, openTimeoutMs: 30000 });
      const s = await tts.open({ voice: v });
      const parts = [];
      await new Promise((resolve, reject) => {
        const to = setTimeout(() => reject(new Error('tts_timeout')), 30000);
        s.setHandlers({ onAudio: (_i, pcm) => parts.push(pcm), onSegmentDone: () => { clearTimeout(to); resolve(); }, onError: (e) => { clearTimeout(to); reject(e); } });
        s.send(t);
      });
      s.close();
      writeWav(f, concatInt16(parts), 24000);
    }
    const w = readWav(f);
    out[t] = resample(w.pcm, w.rate, 48000);
  }
  return out;
}

// ── a simulated human: LaresBot + continuous mic pump + lares.anon inbox ──
class Human {
  constructor({ cid, person, passcode, e2ee }) {
    this.person = person;
    this.name = person.name;
    this.userId = `u_e2e_anon_${person.key.toLowerCase()}_${rid()}`;
    this.bot = new LaresBot({ circleId: cid, name: person.name, userId: this.userId, passcode, authVersion: 2, signaling: WSURL, e2ee });
    this.anon = []; this.sig = []; this.waiters = []; this.sigWaiters = [];
    this.key = newKey();
    this.utter = null; this.stopped = false;
    this.bot.onText((payload, from) => {
      let msg; try { msg = JSON.parse(Buffer.from(payload).toString('utf8')); } catch { return; }
      if (!msg || typeof msg.t !== 'string') return;
      msg._from = from;
      this._push(this.anon, this.waiters, msg);
    });
  }
  _push(box, waiters, msg) {
    const w = waiters.find((x) => x.pred(msg));
    if (w) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(msg); } else { box.push(msg); if (box.length > 300) box.shift(); }
  }
  _wait(box, waiters, pred, ms) {
    const i = box.findIndex(pred);
    if (i >= 0) return Promise.resolve(box.splice(i, 1)[0]);
    return new Promise((res) => { const w = { pred, res, t: setTimeout(() => { const k = waiters.indexOf(w); if (k >= 0) waiters.splice(k, 1); res(null); }, ms) }; waiters.push(w); });
  }
  waitAnon(pred, ms = 15000) { return this._wait(this.anon, this.waiters, pred, ms); }
  waitSig(pred, ms = 15000) { return this._wait(this.sig, this.sigWaiters, pred, ms); }
  drain() { this.anon.length = 0; this.sig.length = 0; }
  async join() {
    await this.bot.join();
    this.bot.ws.on('message', (raw) => { let m; try { m = JSON.parse(raw); } catch { return; } this._push(this.sig, this.sigWaiters, m); });
    await this.bot._ensurePublished();
    this._pumpP = this._pump();
  }
  sendSig(o) { this.bot.ws.send(JSON.stringify(o)); }
  async toAgent(agentId, obj) {
    await this.bot.room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(obj)), { reliable: true, topic: TOPIC, destination_identities: [agentId] });
  }
  has(id) { return [...(this.bot.room?.remoteParticipants?.values?.() ?? [])].some((p) => p.identity === id); }
  async _pump() {
    const silence = new Int16Array(480);
    let base = Date.now(); let n = 0;
    while (!this.stopped) {
      let frame;
      const u = this.utter;
      if (u) {
        frame = u.pcm.slice(u.off, u.off + 480);
        if (frame.length < 480) { const f = new Int16Array(480); f.set(frame); frame = f; }
        u.off += 480;
        if (u.off >= u.pcm.length) { this.utter = null; u.resolve(); }
      } else frame = silence.slice();
      try { await this.bot.source.captureFrame(new AudioFrame(frame, 48000, 1, 480)); } catch { if (this.stopped) break; }
      n += 1;
      const d = base + n * 10 - Date.now();
      if (d > 0) await wait(d); else if (d < -200) { base = Date.now(); n = 0; }
    }
  }
  say(pcm) { return new Promise((resolve) => { this.utter = { pcm, off: 0, resolve }; }); }
  async leave() { this.stopped = true; await this._pumpP?.catch(() => {}); try { await this.bot.leave(); } catch { /* */ } }
}

async function runCircle(label, e2ee, audio) {
  const P = `[${label}]`;
  const cid = newCircleId();
  const ownerKey = crypto.randomBytes(32).toString('hex');
  const passcode = `prod-anon2-${crypto.randomBytes(6).toString('hex')}`;
  SECRETS.add(ownerKey); SECRETS.add(passcode);
  const agentId = agentIdOf(cid);
  const res = { label, cid: cid.slice(0, 8), released: null, receipt: null };
  const humans = [];
  let reg = null;
  let A = null;
  let ended = false;
  let deleted = false;
  try {
    step(`${P} register temporary v2 circle${e2ee ? ' + circle_e2ee_set' : ''}`);
    const verifier = await authVerifier(passcode, cid);
    SECRETS.add(verifier);
    reg = await registrar({ cid, verifier, ownerKey });
    ok(true, 'registered (welcome)', `${cid.slice(0, 8)}… agent=${agentId}`);
    if (e2ee) {
      reg.ws.send(JSON.stringify({ t: 'circle_e2ee_set', circleId: cid, enabled: true, ownerKey }));
      const r = await reg.next((m) => m.op === 'circle_e2ee_set');
      ok(r?.t === 'owner_ok', 'circle_e2ee_set enabled', r && { t: r.t, reason: r.reason });
    }

    step(`${P} 3 humans join (signaling + LiveKit${e2ee ? ', passcode-derived E2EE key' : ''})`);
    for (const person of PEOPLE) {
      const h = new Human({ cid, person, passcode, e2ee });
      await h.join();
      humans.push(h);
    }
    [A] = humans;
    await wait(1500);
    ok(humans.every((h) => humans.filter((o) => o !== h).every((o) => h.has(o.userId))), 'all humans see each other in LiveKit', humans.map((h) => h.bot.room.remoteParticipants.size));

    step(`${P} owner anon_agent_invite k=2${e2ee ? ' + sealed key' : ''}`);
    let keyreqSeen = null;
    let keyOk = null;
    if (e2ee) {
      // owner seals on keyreq (listener armed before the invite)
      void (async () => {
        const kr = await A.waitSig((m) => m.t === 'anon_agent_keyreq', 90000);
        keyreqSeen = kr;
        if (!kr) return;
        const hex = await e2eeKeyHex(passcode, cid);
        SECRETS.add(hex);
        const sealed = seal(hex, kr.x25519Pub, cid);
        A.sendSig({ t: 'anon_agent_key', circleId: cid, sealed, x25519Pub: kr.x25519Pub, ownerKey });
        keyOk = await A.waitSig((m) => m.op === 'anon_agent_key' && (m.t === 'anon_ok' || m.t === 'anon_error'), 10000);
      })();
    }
    A.sendSig({ t: 'anon_agent_invite', circleId: cid, k: 2, ownerKey });
    const inv = await A.waitSig((m) => m.op === 'anon_agent_invite' && (m.t === 'anon_ok' || m.t === 'anon_error'), 10000);
    ok(inv?.t === 'anon_ok', 'anon_agent_invite → anon_ok', inv && { t: inv.t, code: inv.code });
    const st0 = await humans[1].waitSig((m) => m.t === 'anon_agent_state' && m.invited, 10000);
    ok(Boolean(st0), 'anon_agent_state{invited} broadcast to members', st0 && { present: st0.present, active: st0.active, invited: st0.invited });

    step(`${P} agent participant appears${e2ee ? ' (after keyreq/seal)' : ''} → state`);
    const t0 = Date.now();
    while (Date.now() - t0 < 90000 && !humans.every((h) => h.has(agentId))) await wait(250);
    if (e2ee) {
      ok(Boolean(keyreqSeen) && typeof keyreqSeen.x25519Pub === 'string', 'owner received anon_agent_keyreq', keyreqSeen && { x25519PubLen: keyreqSeen.x25519Pub?.length });
      ok(keyOk?.t === 'anon_ok', 'anon_agent_key forwarded (anon_ok)', keyOk && { t: keyOk.t, code: keyOk.code });
    }
    ok(humans.every((h) => h.has(agentId)), `agent ${agentId} in LiveKit room`, { ms: Date.now() - t0 });
    const agentP = [...A.bot.room.remoteParticipants.values()].find((p) => p.identity === agentId);
    info('agent display name', agentP?.name ?? null);
    // first state may have gone out before our handler saw it; acks below trigger re-broadcasts
    let st = await A.waitAnon((m) => m.t === 'state', 8000);
    ok(Boolean(st), 'state received from agent', st && { k: st.k, active: st.active, members: st.members?.length, convener: st.convenerId });

    step(`${P} 3× ack (Ed25519 pubKey) → state all acked`);
    for (const h of humans) h.drain();
    for (const h of humans) await h.toAgent(agentId, { t: 'ack', pubKey: h.key.pubKey });
    st = await humans[2].waitAnon((m) => m.t === 'state' && m.members?.filter((x) => x.acked).length === 3, 15000);
    ok(Boolean(st), 'state: 3 members acked', st && { k: st.k, active: st.active, members: st.members?.map((x) => ({ n: x.name, a: x.acked })) });
    ok(st?.k === 2 && st?.active === true, 'state k=2 active', st && { k: st.k, active: st.active });
    const sid = st?.sid;
    const convenerId = st?.convenerId;
    info('convener is owner?', { convenerIsOwner: convenerId === A.userId, convener: humans.find((h) => h.userId === convenerId)?.name ?? convenerId });
    const ackErr = humans.flatMap((h) => h.anon.filter((m) => m.t === 'error'));
    ok(ackErr.length === 0, 'no ack errors', ackErr.map((e) => `${e.op}:${e.code}`));

    step(`${P} humans speak (real TTS audio over LiveKit)`);
    if (!audio) ok(false, 'audio available', 'TTS failed — see synth step');
    else {
      const by = { A: humans[0], B: humans[1], C: humans[2] };
      for (const [k, text] of UTTS) {
        await by[k].say(audio[text]);
        await wait(1200);
      }
      ok(true, `${UTTS.length} utterances played`, { seconds: Math.round(UTTS.reduce((s, [, t]) => s + audio[t].length / 48000, 0)) });
      await wait(6000); // last ASR final
    }
    const st2 = await A.waitAnon((m) => m.t === 'error', 500);
    ok(!st2, 'no agent error during speech', st2 && `${st2.op}:${st2.code}`);

    step(`${P} ask → answer`);
    for (const h of humans) h.drain();
    let tq = Date.now();
    await humans[1].toAgent(agentId, { t: 'ask', q: QUESTION });
    const ans = await humans[2].waitAnon((m) => m.t === 'answer' || (m.t === 'error' && m.op === 'ask'), 120000);
    const errAsk = await humans[1].waitAnon((m) => m.t === 'error', 200);
    ok(ans?.t === 'answer' && typeof ans.a === 'string' && ans.a.length > 0, 'answer broadcast', ans && { t: ans.t, code: ans.code ?? errAsk?.code, ms: Date.now() - tq });
    ok(/刘慈欣/.test(ans?.a ?? ''), 'answer names 刘慈欣', ans?.a ?? null);
    ok(!NAMES.some((n) => (ans?.a ?? '').includes(n)), 'answer has no participant name', NAMES.filter((n) => (ans?.a ?? '').includes(n)));

    step(`${P} skill minutes → draft`);
    for (const h of humans) h.drain();
    tq = Date.now();
    await A.toAgent(agentId, { t: 'skill', name: 'minutes', args: {} });
    const dm = await humans[1].waitAnon((m) => m.t === 'draft' || (m.t === 'error' && m.op === 'skill'), 180000);
    const errSk = await A.waitAnon((m) => m.t === 'error' && m.op === 'skill', 300);
    const draft = dm?.draft;
    ok(dm?.t === 'draft' && Array.isArray(draft?.items) && draft.items.length > 0, 'draft broadcast', dm && { t: dm.t, code: errSk?.code, items: draft?.items?.length, k: draft?.k, ms: Date.now() - tq });
    info('draft items', draft?.items?.map((i) => ({ kind: i.kind, roleRisk: i.roleRisk, flags: i.flags, text: i.text })));
    ok(draft?.sid === sid && typeof draft?.draftHash === 'string', 'draft{sid,draftHash} matches session', { sidMatch: draft?.sid === sid });

    step(`${P} 2 signed approvals → released`);
    for (const h of humans) h.drain();
    let released = null;
    if (draft) {
      for (const h of [humans[0], humans[1]]) {
        const { nonce, sig } = signApproval(h.key, { sid: draft.sid, draftId: draft.draftId, draftHash: draft.draftHash });
        await h.toAgent(agentId, { t: 'approve', draftId: draft.draftId, draftHash: draft.draftHash, nonce, sig });
        await wait(400);
      }
      released = await humans[2].waitAnon((m) => m.t === 'released' && m.draftId === draft.draftId, 20000);
    }
    const apErr = humans.flatMap((h) => h.anon.filter((m) => m.t === 'error'));
    ok(Boolean(released), 'released broadcast', released ? { len: released.text.length } : { errors: apErr.map((e) => `${e.op}:${e.code}`) });
    ok(apErr.length === 0, 'no approve errors', apErr.map((e) => `${e.op}:${e.code}`));
    const text = released?.text ?? '';
    res.released = text;
    info('released text', text);

    step(`${P} released content checks`);
    ok(/三体/.test(text) && /刘慈欣/.test(text), 'keeps 《三体》 + 刘慈欣 (public fact)', { 三体: /三体/.test(text), 刘慈欣: /刘慈欣/.test(text) });
    const nameHits = NAMES.filter((n) => text.includes(n));
    ok(nameHits.length === 0, 'no participant name', nameHits);
    const orgHits = ORGS.filter((o) => text.includes(o));
    ok(orgHits.length === 0, 'no organisation', orgHits);
    const sarc = SARCASM.filter((s) => text.includes(s));
    ok(sarc.length === 0 && !hasToneMarker(text.replace(/^>.*$/gm, '')), 'sarcasm gone', { phrases: sarc, toneMarker: hasToneMarker(text.replace(/^>.*$/gm, '')) });
    ok(!/\bP\d+\b/.test(text), 'no pseudonyms (P1/P2…)', (text.match(/\bP\d+\b/g) ?? []));

    step(`${P} mem_list → mem_retract → mem_retracted; memory dir has no retracted text`);
    for (const h of humans) h.drain();
    await A.toAgent(agentId, { t: 'mem_list' });
    const mem = await humans[1].waitAnon((m) => m.t === 'mem', 15000);
    ok(Array.isArray(mem?.items) && mem.items.length > 0, 'mem{items}', mem && { n: mem.items?.length });
    const victim = mem?.items?.find((x) => !/刘慈欣|三体/.test(x.text)) ?? mem?.items?.[0];
    if (victim) {
      info('retract target', victim.text);
      const before = await memDir(cid);
      ok(before.exists && before.files?.some((f) => f.s.includes(victim.text)), 'before retract: item text present in memory dir', { exists: before.exists, files: before.files?.length, err: before.error });
      await A.toAgent(agentId, { t: 'mem_retract', itemId: victim.id });
      const rr = await humans[2].waitAnon((m) => m.t === 'mem_retracted' || (m.t === 'error' && m.op === 'mem_retract'), 20000);
      const rErr = await A.waitAnon((m) => m.t === 'error' && m.op === 'mem_retract', 300);
      ok(rr?.t === 'mem_retracted' && rr.itemId === victim.id, 'mem_retracted', rr ? { t: rr.t } : { err: rErr?.code });
      await wait(1500);
      const after = await memDir(cid);
      const frag = victim.text.replace(/\s+/g, '');
      const probes = [victim.text, ...[0, Math.floor(frag.length / 2)].map((i) => frag.slice(i, i + 12)).filter((s) => s.length >= 8)];
      const hits = (after.files ?? []).filter((f) => probes.some((p) => f.s.replace(/\s+/g, '').includes(p.replace(/\s+/g, ''))));
      ok(after.exists && hits.length === 0, 'after retract: no retracted text in DATA_DIR/anonym_memory/<cid>/', { exists: after.exists, files: (after.files ?? []).map((f) => f.f), hits: hits.map((f) => f.f), err: after.error });
      await A.toAgent(agentId, { t: 'mem_list' });
      const mem2 = await humans[1].waitAnon((m) => m.t === 'mem', 15000);
      ok(mem2 && !mem2.items.some((x) => x.id === victim.id), 'mem_list no longer lists the retracted item', mem2 && { n: mem2.items.length });
    } else ok(false, 'retract target', 'no memory items');

    step(`${P} transcript_append refused (anonym_active)`);
    humans[2].sendSig({ t: 'transcript_append', circleId: cid, id: `t_${rid()}`, text: '测试转写一行' });
    const ta = await humans[2].waitSig((m) => m.t === 'transcript_error' || m.t === 'transcript_ok' || (m.t?.startsWith?.('transcript') && m.op === 'append'), 8000);
    ok(ta?.t === 'transcript_error' && ta.reason === 'anonym_active', 'transcript_error{reason:anonym_active}', ta && { t: ta.t, reason: ta.reason });

    step(`${P} owner end → ended{receipt} → agent leaves`);
    for (const h of humans) h.drain();
    await A.toAgent(agentId, { t: 'end' });
    let en = await humans[1].waitAnon((m) => m.t === 'ended' || (m.t === 'error' && m.op === 'end'), 15000);
    const endErr = await A.waitAnon((m) => m.t === 'error' && m.op === 'end', 300);
    if (en?.t !== 'ended') {
      ok(false, 'owner end accepted', { err: endErr?.code ?? en?.code ?? 'timeout', ownerIsConvener: convenerId === A.userId });
      const conv = humans.find((h) => h.userId === convenerId);
      if (conv && conv !== A) {
        await conv.toAgent(agentId, { t: 'end' });
        en = await humans[1].waitAnon((m) => m.t === 'ended', 15000);
        info('fallback: convener end', { ended: en?.t === 'ended' });
      }
    } else ok(true, 'owner end accepted', 'ended');
    const rc = en?.receipt;
    ok(en?.t === 'ended' && /^[0-9a-f]{64}$/.test(rc?.sha256 ?? '') && rc?.counts?.releases === 1 && rc?.sid === sid, 'ended{receipt:{sid,counts,releases,sha256}}', rc && { reason: rc.reason, counts: rc.counts, releases: rc.releases?.length, sha256: Boolean(rc.sha256) });
    res.receipt = rc ? { reason: rc.reason, counts: rc.counts } : null;
    ended = en?.t === 'ended';
    const tl = Date.now();
    while (Date.now() - tl < 20000 && humans.some((h) => h.has(agentId))) await wait(250);
    ok(!humans.some((h) => h.has(agentId)), 'agent participant left the room', { ms: Date.now() - tl });
    const st3 = await humans[1].waitSig((m) => m.t === 'anon_agent_state' && !m.present, 10000);
    ok(Boolean(st3) && st3.active === false, 'anon_agent_state{present:false,active:false}', st3 && { present: st3.present, active: st3.active, invited: st3.invited });
    humans[2].sendSig({ t: 'transcript_append', circleId: cid, id: `t_${rid()}`, text: '测试转写一行' });
    const ta2 = await humans[2].waitSig((m) => m.t === 'transcript_error' || m.t === 'transcript_ok' || m.op === 'append', 8000);
    info('transcript_append after end', ta2 && { t: ta2.t, reason: ta2.reason });
    ok(ta2?.reason !== 'anonym_active', 'anonym_active cleared after end', ta2 && { t: ta2.t, reason: ta2.reason });
  } catch (e) {
    ok(false, 'exception', String(e?.stack ?? e));
  } finally {
    step(`${P} circle_delete → memory dir gone`);
    try {
      if (!ended && A) { try { await A.toAgent(agentId, { t: 'end' }); await wait(1500); } catch { /* */ } }
      let r = null;
      if (A?.bot?.ws?.readyState === 1) { A.sendSig({ t: 'circle_delete', circleId: cid, ownerKey }); r = await A.waitSig((m) => m.op === 'circle_delete' && (m.t === 'owner_ok' || m.t === 'owner_error'), 10000); }
      else if (reg) { reg.ws.send(JSON.stringify({ t: 'circle_delete', circleId: cid, ownerKey })); r = await reg.next((m) => m.op === 'circle_delete'); }
      ok(r?.t === 'owner_ok', 'circle_delete', r && { t: r.t, reason: r.reason });
      deleted = r?.t === 'owner_ok';
    } catch (e) { ok(false, 'circle_delete', String(e)); }
    for (const h of humans) await h.leave();
    reg?.close();
    await wait(3000);
    const d = await memDir(cid);
    ok(d.exists === false, 'DATA_DIR/anonym_memory/<cid>/ removed', { exists: d.exists, err: d.error });
    res.deleted = deleted;
  }
  return res;
}

async function main() {
  const t0 = new Date();
  const results = [];
  step('SSH reachable + DashScope key (prod container env, memory only) + TTS synthesis');
  let audio = null;
  const probe = await ssh(`docker exec ${CONTAINER} printenv LARES_DASHSCOPE_API_KEY\n`);
  const key = probe.out.trim();
  if (key) SECRETS.add(key);
  ok(probe.code === 0 && key.length > 10, 'DashScope key read from prod container', { code: probe.code, present: key.length > 10 });
  try {
    audio = await synthAll(UTTS, key);
    ok(true, 'TTS synthesised (DashScope qwen3-tts-flash-realtime, 48 kHz)', UTTS.map(([, t]) => Math.round(audio[t].length / 480) / 100));
  } catch (e) { ok(false, 'TTS synthesis', String(e?.message ?? e)); }

  for (const [label, e2ee] of [['plain', false], ['e2ee', true]]) {
    if (ONLY && ONLY !== label) continue;
    results.push(await runCircle(label, e2ee, audio));
  }

  step('server logs (since run start): no utterance text, no agent child errors');
  const mins = Math.ceil((Date.now() - t0.getTime()) / 60000) + 1;
  const lg = await ssh(`cd ~/Lares/deploy && docker compose -p lares logs --no-color --since ${mins}m lares-server 2>&1\n`, { timeoutMs: 120000 });
  const lines = lg.out.split('\n');
  const leaks = lines.filter((l) => LOG_PROBES.some((p) => l.includes(p)) || UTTS.some(([, u]) => l.includes(u.slice(0, 10))));
  ok(lg.code === 0 && lines.length > 1, 'logs fetched', { lines: lines.length });
  ok(leaks.length === 0, 'no utterance / released text in logs', leaks.slice(0, 5).map((l) => l.slice(0, 200)));
  const ag = lines.filter((l) => /ember-lares|anonym /.test(l));
  info('anonym log lines', ag.map((l) => l.replace(/^\S+\s+\|\s*/, '').slice(0, 160)).slice(-60));
  const bad = ag.filter((l) => /ev=error|崩溃|启动失败|子进程错误|code=[1-9]|signal=SIG/.test(l));
  ok(bad.length === 0, 'no agent child errors / crashes', bad.map((l) => l.replace(/^\S+\s+\|\s*/, '').slice(0, 200)));
  const nameLeak = lines.filter((l) => NAMES.some((n) => l.includes(n)));
  info('log lines containing display names (join/presence, not utterances)', nameLeak.length);

  const failed = steps.filter((s) => !s.ok).length;
  const out = [
    `anonym v2 prod e2e  ${t0.toISOString()}  server=${WSURL.replace(/\/ws$/, '')}`,
    ...results.map((r) => `circle[${r.label}]=${r.cid}… (temporary, ${r.deleted ? 'deleted' : 'DELETE FAILED'})`),
    '',
    ...steps.map((s, i) => `${s.ok ? 'PASS' : 'FAIL'}  ${i + 1}. ${s.name}${s.notes.length ? '  — ' + s.notes.join('; ') : ''}`),
    '',
    `${failed === 0 ? 'ALL PASS' : `${failed} FAILED`}  (${steps.length} steps)`,
    '',
    ...results.flatMap((r) => [`── released text [${r.label}] ──`, r.released ?? '(none)', `── receipt [${r.label}] ── ${JSON.stringify(r.receipt)}`, '']),
    '── detail ──',
    ...detail,
  ];
  writeFileSync(OUT, redact(out.join('\n')) + '\n');
  console.log(`\nreport → ${OUT}\n${failed === 0 ? 'ALL PASS' : `${failed} FAILED`}`);
  process.exitCode = failed === 0 ? 0 : 1;
}

main().catch((e) => { console.error(redact(String(e?.stack ?? e))); process.exitCode = 1; }).finally(() => {
  // LiveKit FFI keeps the loop alive; give pending writes a moment, then let rtc-node dispose
  setTimeout(async () => { try { const { dispose } = await import('@livekit/rtc-node'); await dispose(); } catch { /* */ } }, 500).unref?.();
});
