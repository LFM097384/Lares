// lares.ai-voice + 新服务端功能的**生产**端到端(https://lares.westus.cloudapp.azure.com)。
//
// 用法:cd server/tool; node ai_voice_prod_e2e.mjs [--skip-ai] [--skip-probe]
// 需要:~/.ssh/lares_ed25519(读容器日志 / docker top,只读);本地 TTS 提示语缓存
//   (%TEMP%\lares-ai-voice-e2e-cache,由 ai_voice_e2e.mjs 生成;本脚本不调 TTS、不需要 DashScope key)。
//
// 流程:
//   [P] 功能探针:circle_features_set(圈主 ok / 非圈主 not_owner)、circle_purpose_apply study → /api/v1/circle
//       看 features+purpose、push_cfg_get/set(含非圈主拒绝)、push_summon 不在房 → not_in_room、focus_social_get
//   [A] 自定义用途「开会+AI」(meeting 内置项 + lares.ai-voice 插件)→ 真人 LaresBot 进房 → 等 supervisor 拉起 u_ai_*
//       → 2 轮唤醒提问(音频非静音 / lares.cap partial→final / lares.chat)+ 1 次打断 = 最多 3 次真实 LLM 回合
//       (配置 maxTurnsPerHour=3 作为服务端硬上限)→ 冒充 u_ai_ hello → userId_reserved → 真人离开 → 宽限 ~20s 后进程退出
//   清理:transcript_clear + circle_delete
// 输出写 tool/ai_voice_prod_e2e.last.txt(token / key 全部打码)。

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { AudioFrame } from '@livekit/rtc-node';
import { LaresBot, authVerifier } from './lares_bot.mjs';
import { resample, concatInt16 } from '../bots/voice-agent/audio.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const SKIP_AI = argv.includes('--skip-ai');
const SKIP_PROBE = argv.includes('--skip-probe');
const HTTP = 'https://lares.westus.cloudapp.azure.com';
const WSURL = 'wss://lares.westus.cloudapp.azure.com/ws';
const SSH = ['-i', path.join(homedir(), '.ssh', 'lares_ed25519'), '-o', 'ConnectTimeout=15', '-o', 'BatchMode=yes', 'azureuser@20.228.115.95'];
const CONTAINER = 'lares-lares-server-1';
const PASSCODE = `prod-ai-e2e-${crypto.randomBytes(4).toString('hex')}`;
const QUAL_WAV = 'D:\\Projects\\Qualitati\\v2v-lab\\data\\asr_eval\\syn_0_00.wav';
const CACHE = path.join(tmpdir(), 'lares-ai-voice-e2e-cache');
const MAX_TURNS = 3;
const SILENT_DB = -45;
const CURL = process.platform === 'win32' ? 'curl.exe' : 'curl';

const redact = (s) => String(s)
  .replace(/lrb_[A-Za-z0-9_-]+/g, 'lrb_***')
  .replace(/sk-[A-Za-z0-9]{16,}/g, 'sk-***')
  .replace(/("(?:ownerKey|token|webhookSecret|proof|verifier|ownerHash)"\s*:\s*")[^"]+/g, '$1***');
const results = {};
const lines = [];
let failed = 0;
const say = (s) => { const r = redact(s); lines.push(r); console.log(r); };
const fmt = (v) => (typeof v === 'string' ? v : JSON.stringify(v));
const ok = (cond, name, val) => { results[name] = val; say(`${cond ? '✓' : '✗'} ${name}: ${fmt(val)}`); if (!cond) failed++; return cond; };
const info = (name, val) => { results[name] = val; say(`· ${name}: ${fmt(val)}`); };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m).digest('hex');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const p50 = (a) => { const s = a.filter(Number.isFinite).sort((x, y) => x - y); return s.length ? s[Math.floor((s.length - 1) / 2)] : null; };

function dbfs(pcm) {
  if (!pcm.length) return -100;
  let s = 0;
  for (let i = 0; i < pcm.length; i++) s += pcm[i] * pcm[i];
  const r = Math.sqrt(s / pcm.length) / 32768;
  return r <= 1e-7 ? -100 : 20 * Math.log10(r);
}
function newCircleId() {
  const a = 'abcdefghijklmnopqrstuvwxyz234567';
  let s = 'c_';
  for (const b of crypto.randomBytes(24)) s += a[b & 31];
  return s;
}

// ── 远端:容器日志流 + 一次性命令 ──────────────────────────────────────────
const logLines = []; // {at, line}
const logWaiters = [];
let logProc = null;
function startLogStream() {
  logProc = spawn('ssh', [...SSH, `docker logs -f --since 5s ${CONTAINER} 2>&1`], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let buf = '';
  const on = (d) => {
    buf += d.toString('utf8');
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const l = redact(buf.slice(0, i).replace(/\r$/, ''));
      buf = buf.slice(i + 1);
      if (!l.trim()) continue;
      const e = { at: Date.now(), line: l };
      logLines.push(e);
      for (const w of [...logWaiters]) if (w.pred(l)) { logWaiters.splice(logWaiters.indexOf(w), 1); clearTimeout(w.t); w.res(e); }
    }
  };
  logProc.stdout.on('data', on);
  logProc.stderr.on('data', on);
}
const waitLog = (pred, ms = 15000, fromIdx = 0) => {
  const hit = logLines.slice(fromIdx).find((e) => pred(e.line));
  if (hit) return Promise.resolve(hit);
  return new Promise((res) => { const w = { pred, res, t: setTimeout(() => res(null), ms) }; logWaiters.push(w); });
};
function sshRun(cmd) {
  return new Promise((resolve) => {
    const p = spawn('ssh', [...SSH, cmd], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.on('close', (code) => resolve({ code, out: redact(out) }));
  });
}

function curl(args) {
  return new Promise((resolve, reject) => {
    const p = spawn(CURL, ['-s', '-S', '-w', '\n%{http_code}', ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.on('error', reject);
    p.on('close', () => {
      const i = out.lastIndexOf('\n');
      let body = out.slice(0, i);
      try { body = JSON.parse(body); } catch { /* */ }
      resolve({ status: Number(out.slice(i + 1)), body });
    });
  });
}

// ── WS 成员 ──────────────────────────────────────────────────────────────
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
        return new Promise((res) => { const w = { pred, res, t: setTimeout(() => res(null), ms) }; waiters.push(w); });
      },
      req: (o, pred, ms) => { const p = m.waitFor(pred, ms); m.send(o); return p; },
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
      all.push({ ...msg, _at: Date.now() });
      const w = waiters.find((x) => x.pred(msg));
      if (w) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(msg); } else inbox.push(msg);
      if (msg.t === 'welcome') resolve(m);
      if (msg.t === 'error' && !m._welcomed) reject(new Error(`hello error ${msg.message}`));
      if (msg.t === 'welcome') m._welcomed = true;
    });
    ws.on('close', (code) => reject(new Error(`ws closed ${code}`)));
    ws.on('error', reject);
  });
}

/// 冒充 u_ai_*:合法圈口令证明 + 可选伪造 aiAuth,返回挑战后的第一条消息
function spoofHello(cid, verifier, userId, aiAuth) {
  return new Promise((resolve) => {
    const ws = new WebSocket(WSURL);
    const t = setTimeout(() => { ws.terminate(); resolve({ t: 'timeout' }); }, 10000);
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw);
      if (msg.t === 'challenge') {
        ws.send(JSON.stringify({
          t: 'hello', userId, deviceId: `d-spoof-${crypto.randomBytes(2).toString('hex')}`, name: '冒充AI', platform: 'e2e',
          auth: { mode: 'circle', v: 2, circleId: cid, nonce: msg.nonce, proof: hmac(verifier, `${msg.nonce}:${userId}:${cid}`) },
          ...(aiAuth ? { aiAuth: { circleId: cid, proof: aiAuth } } : {}),
        }));
        return;
      }
      clearTimeout(t); ws.close(); resolve(msg);
    });
    ws.on('error', (e) => { clearTimeout(t); resolve({ t: 'ws_error', message: String(e.message) }); });
  });
}

// ── 音频素材(只读本地缓存,不调 TTS)──────────────────────────────────────
function readWav(file) {
  const b = readFileSync(file);
  let o = 12; let rate = 0; let ch = 1;
  while (o + 8 <= b.length) {
    const id = b.toString('ascii', o, o + 4);
    const n = b.readUInt32LE(o + 4);
    if (id === 'fmt ') { ch = b.readUInt16LE(o + 10); rate = b.readUInt32LE(o + 12); }
    if (id === 'data') {
      const cnt = Math.floor(n / 2 / ch);
      const out = new Int16Array(cnt);
      for (let i = 0; i < cnt; i++) out[i] = b.readInt16LE(o + 8 + i * 2 * ch);
      return { rate, pcm: out };
    }
    o += 8 + n + (n & 1);
  }
  throw new Error('no data chunk');
}
function trim(pcm, rate) {
  const f = Math.round(rate / 100);
  let a = 0; let b = Math.floor(pcm.length / f);
  while (a < b && dbfs(pcm.subarray(a * f, (a + 1) * f)) < SILENT_DB) a++;
  while (b > a && dbfs(pcm.subarray((b - 1) * f, b * f)) < SILENT_DB) b--;
  return pcm.slice(a * f, b * f);
}
function prompt(text) {
  const f = path.join(CACHE, `${sha256(`Cherry:${text}`).slice(0, 16)}.wav`);
  if (!existsSync(f)) throw new Error(`缺 TTS 缓存 ${f}(先跑一次 ai_voice_e2e.mjs)`);
  const w = readWav(f);
  return trim(resample(w.pcm, w.rate, 48000), 48000);
}

// ── 「真人」 ─────────────────────────────────────────────────────────────
class Human {
  constructor(cid) {
    this.bot = new LaresBot({ circleId: cid, name: '真人', passcode: PASSCODE, authVersion: 2, signaling: WSURL });
    this.ai = []; this.chats = []; this.caps = []; this.utter = null; this.stopped = false;
  }
  async join() {
    this.bot.onAudio((frame, from) => {
      if (!String(from).startsWith('u_ai_')) return;
      const pcm = Int16Array.from(frame.data);
      this.ai.push({ t: Date.now(), db: dbfs(pcm), pcm, rate: frame.sampleRate, from });
    });
    this.bot.onChat((m) => this.chats.push({ ...m, at: Date.now() }));
    this.bot.onCaption((c) => this.caps.push({ ...c, at: Date.now() }));
    await this.bot.join();
    await this.bot._ensurePublished();
    this._pumpP = this._pump();
  }
  async _pump() {
    const silence = new Int16Array(480);
    let base = Date.now(); let n = 0;
    while (!this.stopped) {
      let frame;
      const u = this.utter;
      if (u) {
        if (u.off === 0) u.onsetAt = Date.now();
        frame = u.pcm.slice(u.off, u.off + 480);
        if (frame.length < 480) { const f = new Int16Array(480); f.set(frame); frame = f; }
        u.off += 480;
        if (u.off >= u.pcm.length) { u.endAt = Date.now() + 10; this.utter = null; u.resolve({ onsetAt: u.onsetAt, endAt: u.endAt }); }
      } else frame = silence.slice();
      try { await this.bot.source.captureFrame(new AudioFrame(frame, 48000, 1, 480)); } catch { if (this.stopped) break; }
      n += 1;
      const d = base + n * 10 - Date.now();
      if (d > 0) await wait(d); else if (d < -200) { base = Date.now(); n = 0; }
    }
  }
  say(pcm) { return new Promise((resolve) => { this.utter = { pcm, off: 0, resolve }; }); }
  async leave() { this.stopped = true; await this._pumpP?.catch(() => {}); await this.bot.leave(); }
}
function aiStats(h, from, to = Infinity) {
  const fr = h.ai.filter((x) => x.t >= from && x.t < to);
  const voiced = fr.filter((x) => x.db >= SILENT_DB);
  return {
    frames: fr.length,
    first: voiced[0]?.t ?? null,
    last: voiced.at(-1)?.t ?? null,
    voicedMs: Math.round(voiced.reduce((s, x) => s + (x.pcm.length / x.rate) * 1000, 0)),
    meanDb: voiced.length ? Math.round(voiced.reduce((s, x) => s + x.db, 0) / voiced.length) : null,
    peakDb: voiced.length ? Math.round(Math.max(...voiced.map((x) => x.db))) : null,
  };
}

// 服务端 turn 日志:[ai-voice] <cid> turn wake ttfa=870ms llm1=412ms heard=46 reply=46[ interrupted]
const TURN_RE = /turn (\S+) ttfa=(\S+?)ms llm1=(\S+?)ms heard=(\d+) reply=(\d+)( interrupted)?/;
const parseTurn = (l) => { const m = TURN_RE.exec(l); return m && { trigger: m[1], ttfaMs: Number(m[2]), llmFirstTokenMs: Number(m[3]), heardChars: Number(m[4]), replyChars: Number(m[5]), interrupted: Boolean(m[6]) }; };
let turnCount = 0;

async function wakeTurn(h, cid, label, pcm) {
  if (turnCount >= MAX_TURNS) { ok(false, `${label}: 回合上限`, turnCount); return null; }
  const idx = logLines.length;
  const chats0 = h.chats.length; const caps0 = h.caps.length;
  const sp = await h.say(pcm);
  const ev = await waitLog((l) => l.includes(cid) && TURN_RE.test(l), 45000, idx);
  turnCount += ev ? 1 : 0;
  await wait(3000);
  const turn = ev && parseTurn(ev.line);
  if (!ok(Boolean(turn), `${label}: 服务端 turn 日志`, turn ?? 'timeout')) return null;
  const st = aiStats(h, sp.endAt);
  const chat = h.chats.slice(chats0).find((m) => String(m.from).startsWith('u_ai_'));
  const capF = h.caps.slice(caps0).filter((c) => String(c.from).startsWith('u_ai_') && c.final).at(-1);
  const capP = h.caps.slice(caps0).filter((c) => String(c.from).startsWith('u_ai_') && !c.final);
  ok(st.voicedMs > 1000 && st.meanDb > -40, `${label}: 真人收到 AI 非静音语音`, { voicedMs: st.voicedMs, meanDb: st.meanDb, peakDb: st.peakDb, frames: st.frames });
  ok(Boolean(chat?.body) && [...chat.body].length === turn.replyChars, `${label}: lares.chat 收到回复`, chat?.body ?? null);
  ok(capF?.text === chat?.body && capP.length >= 1, `${label}: lares.cap partial→final`, { partials: capP.length, final: capF?.text ?? null });
  const m = { extTtfaMs: st.first ? st.first - sp.endAt : null, botTtfaMs: turn.ttfaMs, llmFirstTokenMs: turn.llmFirstTokenMs, speechMs: sp.endAt - sp.onsetAt };
  info(`${label}: 延迟`, m);
  return m;
}

async function interruptTurn(h, cid, label, promptPcm, interrupter) {
  if (turnCount >= MAX_TURNS) { ok(false, `${label}: 回合上限`, turnCount); return null; }
  const idx = logLines.length;
  const chats0 = h.chats.length; const caps0 = h.caps.length;
  const sp = await h.say(promptPcm);
  const t0 = Date.now();
  while (Date.now() - t0 < 30000) {
    if (aiStats(h, sp.endAt).voicedMs >= 1500) break;
    if (logLines.slice(idx).some((e) => e.line.includes(cid) && TURN_RE.test(e.line))) break;
    await wait(20);
  }
  if (logLines.slice(idx).some((e) => e.line.includes(cid) && TURN_RE.test(e.line))) { turnCount++; ok(false, `${label}: 回答在插话前就结束了`, ''); return null; }
  const ip = h.say(interrupter);
  const ev = await waitLog((l) => l.includes(cid) && TURN_RE.test(l), 30000, idx);
  turnCount += ev ? 1 : 0;
  const { onsetAt } = await ip;
  await wait(3000);
  const turn = ev && parseTurn(ev.line);
  ok(Boolean(turn?.interrupted), `${label}: turn interrupted`, turn ?? 'timeout');
  if (!turn) return null;
  const before = aiStats(h, sp.endAt, onsetAt);
  const after = aiStats(h, onsetAt);
  const stopMs = after.last ? after.last - onsetAt : 0;
  ok(turn.heardChars > 0 && turn.heardChars < turn.replyChars, `${label}: heard < reply`, { heard: turn.heardChars, reply: turn.replyChars });
  ok(stopMs <= 800, `${label}: 插话开始 → 最后一个非静音 AI 帧`, { stopMs, aiVoicedBeforeMs: before.voicedMs, aiVoicedAfterMs: after.voicedMs });
  const chat = h.chats.slice(chats0).find((m) => String(m.from).startsWith('u_ai_'));
  const capF = h.caps.slice(caps0).filter((c) => String(c.from).startsWith('u_ai_') && c.final).at(-1);
  ok(Boolean(chat?.body?.endsWith('…')) && [...chat.body].length - 1 === turn.heardChars, `${label}: 聊天只发听到的部分 + …`, chat?.body ?? null);
  ok(capF?.text === chat?.body, `${label}: 最终字幕 = 听到的部分`, capF?.text ?? null);
  return { stopMs };
}

// ── 主流程 ────────────────────────────────────────────────────────────────
async function main() {
  startLogStream();
  await wait(2500);
  info('prod log stream', logProc.exitCode === null ? 'attached' : `ssh exited ${logProc.exitCode}`);
  const health = await curl([`${HTTP}/health`]);
  ok(health.status === 200 && health.body?.rtcConfigured === true, 'health', { status: health.status, rtcConfigured: health.body?.rtcConfigured });

  const cid = newCircleId();
  const verifier = await authVerifier(PASSCODE, cid);
  const ownerKey = crypto.randomBytes(32).toString('hex');
  const owner = await wsMember({ cid, verifier, userId: `u_e2e_owner_${crypto.randomBytes(3).toString('hex')}`, name: 'E2E圈主', register: { verifier, ownerHash: sha256(ownerKey) } });
  ok(true, 'register circle', cid);
  const aiId = `u_ai_${sha256(cid).slice(0, 8)}`;
  let token = null;

  try {
    // ── [P] 功能探针 ──
    if (!SKIP_PROBE) {
      say('\n[P] feature probe');
      const nonOwner = await wsMember({ cid, verifier, userId: `u_e2e_m_${crypto.randomBytes(3).toString('hex')}`, name: '非圈主' });
      let r = await nonOwner.req({ t: 'circle_features_set', circleId: cid, features: { map: true } }, (m) => m.op === 'circle_features_set');
      ok(r?.t === 'owner_error' && r.reason === 'not_owner', 'circle_features_set 非圈主 → not_owner', r);
      r = await nonOwner.req({ t: 'circle_features_set', circleId: cid, ownerKey: crypto.randomBytes(32).toString('hex'), features: { map: true } }, (m) => m.op === 'circle_features_set');
      ok(r?.t === 'owner_error' && r.reason === 'not_owner', 'circle_features_set 错 ownerKey → not_owner', r);
      r = await owner.req({ t: 'circle_features_set', circleId: cid, ownerKey, features: { map: true, devTools: true } }, (m) => m.op === 'circle_features_set');
      ok(r?.t === 'owner_ok', 'circle_features_set 圈主 {map,devTools}', r);
      r = await owner.req({ t: 'circle_features_set', circleId: cid, ownerKey, features: { bogus: true } }, (m) => m.op === 'circle_features_set');
      ok(r?.t === 'owner_error' && r.reason === 'bad_request', 'circle_features_set 未知键 → bad_request', r);
      r = await nonOwner.req({ t: 'circle_purpose_apply', circleId: cid, purpose: 'study' }, (m) => m.op === 'circle_purpose_apply');
      ok(r?.t === 'owner_error' && r.reason === 'not_owner', 'circle_purpose_apply 非圈主 → not_owner', r);
      const pa = owner.waitFor((m) => m.t === 'purpose_applied');
      r = await owner.req({ t: 'circle_purpose_apply', circleId: cid, ownerKey, purpose: 'study' }, (m) => m.op === 'circle_purpose_apply');
      const paMsg = await pa;
      ok(r?.t === 'owner_ok' && paMsg?.purpose?.id === 'study', 'circle_purpose_apply study', { ack: r?.t, reason: r?.reason, purpose: paMsg?.purpose });

      const tok = await owner.req({ t: 'bot_token_create', circleId: cid, name: 'AI-E2E', ownerKey }, (m) => m.t === 'bot_token' || (m.t === 'owner_error' && m.op === 'bot_token_create'));
      token = tok?.token ?? null;
      const ci = await curl(['-H', `Authorization: Bearer ${token}`, `${HTTP}/api/v1/circle`]);
      const f = ci.body?.features ?? {};
      ok(ci.status === 200 && f.focus === true && f.captions === false && f.voiceNotes === false && f.map === true && f.devTools === true && ci.body?.purpose?.id === 'study' && ci.body.purpose.builtin === true,
        'GET /api/v1/circle features+purpose', { status: ci.status, features: f, purpose: ci.body?.purpose });

      r = await owner.req({ t: 'push_cfg_get', circleId: cid }, (m) => m.t === 'push_cfg' || m.op === 'push_cfg_get');
      ok(r?.t === 'push_cfg' && r.cfg?.triggers && typeof r.cfg.crowdN === 'number', 'push_cfg_get', { cfg: r?.cfg, custom: r?.custom, limits: r?.limits });
      const crowd0 = r?.cfg?.crowdN ?? 3;
      const n1 = crowd0 === 5 ? 6 : 5;
      r = await owner.req({ t: 'push_cfg_set', circleId: cid, ownerKey, cfg: { triggers: { crowd: true }, crowdN: n1 } }, (m) => m.op === 'push_cfg_set');
      ok(r?.t === 'owner_ok', 'push_cfg_set 圈主', r);
      r = await owner.req({ t: 'push_cfg_get', circleId: cid }, (m) => m.t === 'push_cfg');
      ok(r?.cfg?.crowdN === n1 && r.cfg.triggers.crowd === true && r.custom === true, 'push_cfg_get 回读', { cfg: r?.cfg, custom: r?.custom });
      r = await owner.req({ t: 'push_cfg_set', circleId: cid, ownerKey, cfg: { crowdN: 99 } }, (m) => m.op === 'push_cfg_set');
      ok(r?.t === 'owner_error' && r.reason === 'bad_config', 'push_cfg_set crowdN=99 → bad_config', r);
      r = await nonOwner.req({ t: 'push_cfg_set', circleId: cid, cfg: { crowdN: 4 } }, (m) => m.op === 'push_cfg_set');
      ok(r?.t === 'owner_error' && r.reason === 'not_owner', 'push_cfg_set 非圈主 → not_owner', r);
      r = await owner.req({ t: 'push_summon', circleId: cid, ownerKey }, (m) => m.op === 'push_summon' || m.t === 'push_summon_ok');
      ok(r?.t === 'owner_error' && r.reason === 'not_in_room', 'push_summon 不在房 → not_in_room', r);
      const st = owner.waitFor((m) => m.t === 'focus_streaks');
      const wk = owner.waitFor((m) => m.t === 'focus_weekly' || m.t === 'focus_error');
      owner.send({ t: 'focus_social_get', circleId: cid });
      const [sm, wm] = await Promise.all([st, wk]);
      ok(sm?.circleId === cid && typeof sm.streaks === 'object' && wm?.t === 'focus_weekly', 'focus_social_get', { streaks: sm?.streaks, weekly: wm });
      nonOwner.close();
    }

    if (!SKIP_AI) {
      // ── [A] AI 语音 ──
      say('\n[A] lares.ai-voice on prod (custom purpose 开会+AI)');
      const P1 = '小助手，请用一句话介绍一下北京。';
      const P2 = '小助手，上海有什么好吃的？一句话回答。';
      const PL = '小助手，请详细讲讲长城的历史，多说一点。';
      const audio = { P1: prompt(P1), P2: prompt(P2), PL: prompt(PL) };
      const qw = readWav(QUAL_WAV);
      const interrupter = trim(resample(qw.pcm, qw.rate, 48000), 48000);
      info('audio (cached TTS Cherry + syn_0_00.wav interrupter)', { P1: `${Math.round(audio.P1.length / 48)}ms`, P2: `${Math.round(audio.P2.length / 48)}ms`, PL: `${Math.round(audio.PL.length / 48)}ms`, interrupter: `${Math.round(interrupter.length / 48)}ms`, wakeWord: '小助手(默认 name)' });

      const cfg = { name: '小助手', trigger: 'wake', maxTurnsPerHour: MAX_TURNS, maxReplyChars: 120 };
      const purpose = {
        v: 1, id: 'meeting-ai', name: '开会+AI', icon: '📝',
        features: { captions: true, transcript: true, voiceNotes: false, focus: false, plugins: true },
        plugins: [{ id: 'lares.ai-voice', enabled: true, config: cfg }],
        settings: { e2eeWarning: true },
      };
      const pa = owner.waitFor((m) => m.t === 'purpose_applied', 10000);
      let r = await owner.req({ t: 'circle_purpose_apply', circleId: cid, ownerKey, purpose }, (m) => m.op === 'circle_purpose_apply', 10000);
      const paMsg = await pa;
      ok(r?.t === 'owner_ok' && paMsg?.purpose?.id === 'meeting-ai', 'circle_purpose_apply 开会+AI(含 lares.ai-voice)', { ack: r?.t, reason: r?.reason, detail: r?.detail, purpose: paMsg?.purpose });
      if (r?.t !== 'owner_ok') {
        r = await owner.req({ t: 'plugin_install', circleId: cid, pluginId: 'lares.ai-voice', ownerKey }, (m) => m.t === 'plugin_installed' || (m.t === 'owner_error' && m.op === 'plugin_install'));
        ok(r?.t === 'plugin_installed', 'fallback plugin_install lares.ai-voice', r?.t === 'plugin_installed' ? r.plugin?.id : r);
        r = await owner.req({ t: 'plugin_config_set', circleId: cid, pluginId: 'lares.ai-voice', config: cfg, ownerKey }, (m) => m.op === 'plugin_config_set');
        ok(r?.t === 'owner_ok', 'fallback plugin_config_set', r);
      }
      const pl = await owner.req({ t: 'plugin_list', circleId: cid }, (m) => m.t === 'plugins', 5000);
      const aiPl = pl?.items?.find((x) => x.id === 'lares.ai-voice');
      info('plugin view lares.ai-voice', aiPl ? { enabled: aiPl.enabled, config: aiPl.config } : pl);
      await wait(1500);
      ok(!logLines.some((e) => e.line.includes(cid) && e.line.includes('已启动')), '房里没人时不拉起 AI', true);

      const h = new Human(cid);
      const idx0 = logLines.length;
      const tJoin = Date.now();
      await h.join();
      ok(true, 'human joined + publishing', { userId: h.bot.userId, ms: Date.now() - tJoin });
      const started = await waitLog((l) => l.includes(cid) && l.includes('已启动'), 15000, idx0);
      const ready = await waitLog((l) => l.includes(cid) && / ready$/.test(l), 40000, idx0);
      const sum = await owner.waitFor((m) => m.t === 'circle_summary' && m.circleId === cid && m.ai >= 1, 15000);
      ok(Boolean(started && ready), 'supervisor spawned AI bot → ready', { startedMs: started ? started.at - tJoin : null, readyMs: ready ? ready.at - tJoin : null, pid: /pid=(\d+)/.exec(started?.line ?? '')?.[1] ?? null });
      ok(Boolean(sum), 'circle_summary 出现 AI 成员 (ai≥1, 不计人数)', sum ? { count: sum.count, ai: sum.ai, names: sum.names } : 'timeout');
      const top1 = await sshRun(`docker top ${CONTAINER} -o pid,args`);
      ok(top1.out.includes(cid), 'docker top: voice-agent 进程在跑', top1.out.split('\n').filter((l) => l.includes('voice-agent')).map((l) => l.replace(/\s+/g, ' ').trim()));

      // 冒充 u_ai_(在 AI 真在房时测)
      let sp = await spoofHello(cid, verifier, aiId);
      ok(sp?.t === 'error' && sp.message === 'userId_reserved', '冒充 u_ai_ hello(无 aiAuth) → userId_reserved', sp);
      sp = await spoofHello(cid, verifier, aiId, crypto.randomBytes(32).toString('hex'));
      ok(sp?.t === 'error' && sp.message === 'userId_reserved', '冒充 u_ai_ hello(伪造 aiAuth) → userId_reserved', sp);

      const lat = { ext: [], bot: [], llm: [] };
      let stopMs = null;
      if (ready) {
        await wait(3000);
        for (const [label, pcm] of [['T1', audio.P1], ['T2', audio.P2]]) {
          const m = await wakeTurn(h, cid, label, pcm);
          if (m) { lat.ext.push(m.extTtfaMs); lat.bot.push(m.botTtfaMs); lat.llm.push(m.llmFirstTokenMs); }
        }
        const ir = await interruptTurn(h, cid, 'T3 barge-in', audio.PL, interrupter);
        stopMs = ir?.stopMs ?? null;
      } else {
        say(logLines.slice(idx0).filter((e) => e.line.includes('ai-voice')).slice(-20).map((e) => e.line).join('\n'));
      }
      info('TTFA (ms)', { externalRaw: lat.ext, external_p50: p50(lat.ext), botInternalRaw: lat.bot, llmFirstTokenRaw: lat.llm, bargeInStopMs: stopMs });
      info('real LLM turns', turnCount);
      const usage = logLines.filter((e) => e.line.includes(cid) && e.line.includes(' usage ')).at(-1);
      if (usage) info('usage (server log)', usage.line.replace(/^.*usage /, ''));

      // 真人离开 → 宽限 → 停
      const idx2 = logLines.length;
      const tLeave = Date.now();
      await h.leave();
      const stopLog = await waitLog((l) => l.includes(cid) && l.includes('停止(empty)'), 40000, idx2);
      const exitLog = await waitLog((l) => l.includes(cid) && l.includes('已退出'), 15000, idx2);
      ok(Boolean(stopLog && exitLog), '房间清空 → 宽限后停 AI', { stopAfterMs: stopLog ? stopLog.at - tLeave : null, exitAfterMs: exitLog ? exitLog.at - tLeave : null, exit: exitLog?.line.replace(/^.*已退出/, '已退出') ?? null });
      const top2 = await sshRun(`docker top ${CONTAINER} -o pid,args`);
      ok(!top2.out.includes(cid), 'docker top: voice-agent 进程已不在', top2.out.split('\n').map((l) => l.replace(/\s+/g, ' ').trim()).filter(Boolean));
    }
  } catch (e) {
    ok(false, 'exception', String(e?.stack ?? e));
  } finally {
    try {
      let c = await owner.req({ t: 'transcript_clear', circleId: cid, ownerKey }, (m) => m.op === 'transcript_clear');
      ok(c?.t === 'owner_ok', 'transcript_clear', c?.t ?? 'timeout');
      c = await owner.req({ t: 'circle_delete', circleId: cid, ownerKey }, (m) => m.op === 'circle_delete');
      ok(c?.t === 'owner_ok', 'circle_delete', c?.t ?? 'timeout');
    } catch (e) { ok(false, 'cleanup', String(e)); }
    if (token) {
      const r = await curl(['-H', `Authorization: Bearer ${token}`, `${HTTP}/api/v1/circle`]);
      ok(r.status === 401, 'token after circle_delete → 401', r.status);
    }
    owner.close();
    await wait(2000);
    const errs = logLines.filter((e) => /error|Error|ERR|崩溃|失败|exception|uncaught/i.test(e.line)).map((e) => e.line);
    info('prod log lines captured', logLines.length);
    info('prod log error-ish lines', errs.length ? errs.slice(-30) : 'none');
    info('prod ai-voice log', logLines.filter((e) => e.line.includes('[ai-voice]')).map((e) => e.line).slice(-30));
    try { logProc?.kill(); } catch { /* */ }
    say(failed === 0 ? '\nAI VOICE PROD E2E ALL PASS' : `\nAI VOICE PROD E2E ${failed} FAILED`);
    writeFileSync(path.join(HERE, 'ai_voice_prod_e2e.last.txt'), redact(`# ai_voice_prod_e2e ${new Date().toISOString()}\n${lines.join('\n')}\n\nRESULTS ${JSON.stringify(results, null, 1)}\n`));
    setTimeout(() => process.exit(failed === 0 ? 0 : 1), 500);
  }
}

main().catch((e) => { console.error('fatal', redact(e?.stack ?? e)); try { logProc?.kill(); } catch { /* */ } process.exit(1); });
