// lares.ai-voice 真机端到端:真 LiveKit(livekit-server --dev)+ 真信令服务 + 真 DashScope(ASR/LLM/TTS)。
//
// 用法(脚本自己拉起 livekit-server 与 node src/index.js,结束时杀掉;7880 已有 LiveKit 就复用):
//   cd server/tool; node ai_voice_e2e.mjs [--key-csv <DashScope apiKey CSV>] [--mode both|server|standalone]
//   (也可用 env LARES_DASHSCOPE_API_KEY;CSV 默认 C:\Users\Liu_F\Downloads\默认业务空间-apiKey-6421725.csv)
//
// 流程:
//   1. 注册 v2 新圈;圈主 WS 装内置插件 lares.ai-voice 并写配置 {name:'小助手', trigger:'wake'}
//   2. 「真人」LaresBot 进房、持续发音频(静音泵 + 话语);服务端看到有人 → 拉起 AI 子进程(server-managed)
//   3. 三轮唤醒提问:测外部 TTFA(人话尾 → 收到首个非静音 AI 帧)、bot 自报 turn 延迟、ASR 定稿延迟;
//      第一轮把收到的 AI 音频回灌 qwen3-asr-flash-realtime 做往返识别
//   4. 打断:长回答播出 ~1.5s 后真人插话,测「插话开始 → 最后一个非静音 AI 帧」
//   5. 停用插件 → AI 进程退出;再以 standalone(--passcode --auth-v2)跑一轮并 {"cmd":"stop"} 退出
// 密钥只进进程环境;所有输出 / 结果文件都过 redact()。真实调用量硬上限:LLM ≤ 6 轮。

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, appendFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { AudioFrame } from '@livekit/rtc-node';
import { LaresBot, authVerifier } from './lares_bot.mjs';
import { DashscopeAsr, DashscopeTts } from '../bots/voice-agent/providers/dashscope.mjs';
import { resample, concatInt16 } from '../bots/voice-agent/audio.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = path.join(HERE, '..');
const argv = process.argv.slice(2);
const argOf = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
const MODE = argOf('--mode', 'both');
const KEY_CSV = argOf('--key-csv', process.env.LARES_KEY_CSV ?? 'C:\\Users\\Liu_F\\Downloads\\默认业务空间-apiKey-6421725.csv');
const QUAL_WAV = 'D:\\Projects\\Qualitati\\v2v-lab\\data\\asr_eval\\syn_0_00.wav';
const PORT = Number(process.env.LARES_E2E_PORT ?? 18791);
const HTTP = `http://127.0.0.1:${PORT}`;
const WSURL = `ws://127.0.0.1:${PORT}/ws`;
const LK_PORT = 7880;
const PASSCODE = `ai-e2e-${crypto.randomBytes(4).toString('hex')}`;
const MAX_LLM_TURNS = 6;
const SILENT_DB = -45; // 非静音帧阈值(dBFS)
const CACHE = path.join(tmpdir(), 'lares-ai-voice-e2e-cache');
const RUN_DIR = mkdtempSync(path.join(tmpdir(), 'lares-ai-e2e-'));
const SERVER_LOG = path.join(RUN_DIR, 'server.log');

// ── 密钥(只进 env,永不打印)──────────────────────────────────────────────
if (!process.env.LARES_DASHSCOPE_API_KEY && existsSync(KEY_CSV)) {
  for (const line of readFileSync(KEY_CSV, 'utf8').split(/\r?\n/)) {
    const [k, ...v] = line.split(',');
    if (k?.trim() === 'apiKey') process.env.LARES_DASHSCOPE_API_KEY = v.join(',').trim();
  }
}
const KEY = process.env.LARES_DASHSCOPE_API_KEY ?? '';
const redact = (s) => {
  let o = String(s);
  if (KEY) o = o.split(KEY).join('***');
  return o.replace(/sk-[A-Za-z0-9]{16,}/g, 'sk-***');
};

const results = {};
const lines = [];
let failed = 0;
const say = (s) => { const r = redact(s); lines.push(r); console.log(r); };
const ok = (cond, name, val) => {
  results[name] = val;
  say(`${cond ? '✓' : '✗'} ${name}: ${typeof val === 'string' ? val : JSON.stringify(val)}`);
  if (!cond) failed++;
  return cond;
};
const info = (name, val) => { results[name] = val; say(`· ${name}: ${typeof val === 'string' ? val : JSON.stringify(val)}`); };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const hmac = (k, m) => crypto.createHmac('sha256', k).update(m).digest('hex');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const p50 = (a) => { const s = a.filter((x) => Number.isFinite(x)).sort((x, y) => x - y); return s.length ? s[Math.floor((s.length - 1) / 2)] : null; };
const cjk = (s) => (String(s).match(/[\u4e00-\u9fff]/g) ?? []).length;
const api = { llmTurns: 0, ttsPromptSessions: 0, asrRoundTrip: 0 };

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

// ── 子进程 ────────────────────────────────────────────────────────────────
const children = [];
function lineSplit(stream, onLine) {
  let buf = '';
  stream.setEncoding('utf8');
  stream.on('data', (c) => {
    buf += c;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i).replace(/\r$/, ''); buf = buf.slice(i + 1); if (l.trim()) onLine(l); }
  });
}
async function httpUp(url, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    try { const r = await fetch(url, { signal: AbortSignal.timeout(1000) }); if (r.status < 500) return true; } catch { /* */ }
    await wait(250);
  }
  return false;
}

async function startLivekit() {
  if (await httpUp(`http://127.0.0.1:${LK_PORT}`, 500)) return { reused: true };
  const exe = path.join(SERVER_DIR, 'livekit', process.platform === 'win32' ? 'livekit-server.exe' : 'livekit-server');
  const p = spawn(exe, ['--dev', '--bind', '127.0.0.1'], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  children.push(p);
  const log = (l) => appendFileSync(path.join(RUN_DIR, 'livekit.log'), `${l}\n`);
  lineSplit(p.stdout, log); lineSplit(p.stderr, log);
  if (!(await httpUp(`http://127.0.0.1:${LK_PORT}`, 15000))) throw new Error('livekit-server 没起来');
  return { reused: false, pid: p.pid };
}

const serverWaiters = [];
const serverLines = [];
function onServerLine(l) {
  const r = redact(l);
  serverLines.push(r);
  appendFileSync(SERVER_LOG, `${r}\n`);
  for (const w of [...serverWaiters]) if (w.pred(r)) { serverWaiters.splice(serverWaiters.indexOf(w), 1); clearTimeout(w.t); w.res(r); }
  const i = r.indexOf('turn-metrics ');
  if (i >= 0) { try { pushTurn(JSON.parse(r.slice(i + 13))); } catch { /* */ } }
}
const waitServer = (pred, ms = 15000, { fromIdx = 0 } = {}) => {
  const hit = serverLines.slice(fromIdx).find(pred);
  if (hit) return Promise.resolve(hit);
  return new Promise((res) => { const w = { pred, res, t: setTimeout(() => res(null), ms) }; serverWaiters.push(w); });
};

async function startServer() {
  const dataDir = path.join(RUN_DIR, 'data');
  mkdirSync(dataDir, { recursive: true });
  const env = {
    ...process.env,
    LIVEKIT_URL: `ws://127.0.0.1:${LK_PORT}`, LIVEKIT_API_KEY: 'devkey', LIVEKIT_API_SECRET: 'secret',
    LARES_AUTH_MODE: 'circle', LARES_CIRCLE_PASSCODE: `global-${crypto.randomBytes(4).toString('hex')}`,
    LARES_DATA_DIR: dataDir, LARES_PORT: String(PORT),
    LARES_DASHSCOPE_API_KEY: KEY,
    LARES_AI_LOG_TEXT: '1', // 测试里要比对回复正文;turn 事件不含密钥
  };
  const p = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], { cwd: SERVER_DIR, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  children.push(p);
  lineSplit(p.stdout, onServerLine); lineSplit(p.stderr, onServerLine);
  if (!(await httpUp(`${HTTP}/health`, 15000))) throw new Error('Lares 服务没起来');
  return p;
}

// ── turn 事件(两种模式都汇到这里)──────────────────────────────────────────
const turns = [];
const turnWaiters = [];
function pushTurn(ev) {
  if (!ev || ev.ev !== 'turn') return;
  turns.push(ev);
  api.llmTurns += 1;
  for (const w of [...turnWaiters]) if (w.pred(ev)) { turnWaiters.splice(turnWaiters.indexOf(w), 1); clearTimeout(w.t); w.res(ev); }
}
const waitTurn = (pred, ms = 40000) => {
  const hit = turns.find(pred);
  if (hit) return Promise.resolve(hit);
  return new Promise((res) => { const w = { pred, res, t: setTimeout(() => res(null), ms) }; turnWaiters.push(w); });
};

// ── 圈主 WS ───────────────────────────────────────────────────────────────
function wsMember({ cid, verifier, userId, name, register }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WSURL);
    const inbox = [];
    const waiters = [];
    const m = {
      ws, inbox,
      send: (o) => ws.send(JSON.stringify(o)),
      waitFor: (pred, ms = 8000) => {
        const i = inbox.findIndex(pred);
        if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
        return new Promise((res) => { const w = { pred, res, t: setTimeout(() => res(null), ms) }; waiters.push(w); });
      },
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
      const w = waiters.find((x) => x.pred(msg));
      if (w) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(msg); } else inbox.push(msg);
      if (msg.t === 'welcome') resolve(m);
    });
    ws.on('close', (code) => reject(new Error(`ws closed ${code}`)));
    ws.on('error', reject);
  });
}

// ── 音频素材 ──────────────────────────────────────────────────────────────
function readWav(file) {
  const b = readFileSync(file);
  if (b.toString('ascii', 0, 4) !== 'RIFF') throw new Error('not wav');
  let o = 12; let rate = 0; let ch = 1; let bits = 16;
  while (o + 8 <= b.length) {
    const id = b.toString('ascii', o, o + 4);
    const n = b.readUInt32LE(o + 4);
    if (id === 'fmt ') { ch = b.readUInt16LE(o + 10); rate = b.readUInt32LE(o + 12); bits = b.readUInt16LE(o + 22); }
    if (id === 'data') {
      if (bits !== 16) throw new Error('need 16-bit');
      const cnt = Math.floor(n / 2 / ch);
      const out = new Int16Array(cnt);
      for (let i = 0; i < cnt; i++) out[i] = b.readInt16LE(o + 8 + i * 2 * ch);
      return { rate, pcm: out };
    }
    o += 8 + n + (n & 1);
  }
  throw new Error('no data chunk');
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
/// 去掉首尾静音(10ms 帧 RMS < -45 dBFS)
function trim(pcm, rate) {
  const f = Math.round(rate / 100);
  let a = 0; let b = Math.floor(pcm.length / f);
  while (a < b && dbfs(pcm.subarray(a * f, (a + 1) * f)) < SILENT_DB) a++;
  while (b > a && dbfs(pcm.subarray((b - 1) * f, b * f)) < SILENT_DB) b--;
  return pcm.slice(a * f, b * f);
}

/// DashScope TTS 合成(一次会话合成全部未缓存的文本),缓存到临时目录(不进仓库)
async function synthAll(texts) {
  mkdirSync(CACHE, { recursive: true });
  const fileOf = (t) => path.join(CACHE, `${sha256(`Cherry:${t}`).slice(0, 16)}.wav`);
  const todo = texts.filter((t) => !existsSync(fileOf(t)));
  if (todo.length) {
    const tts = new DashscopeTts({ apiKey: KEY });
    const s = await tts.open({ voice: 'Cherry' });
    api.ttsPromptSessions += 1;
    const parts = todo.map(() => []);
    await new Promise((resolve, reject) => {
      let done = 0;
      s.setHandlers({
        onAudio: (i, pcm) => parts[i]?.push(pcm),
        onSegmentDone: () => { if (++done === todo.length) resolve(); },
        onError: reject,
      });
      for (const t of todo) s.send(t);
      setTimeout(() => reject(new Error('tts_timeout')), 30000);
    });
    s.close();
    todo.forEach((t, i) => writeWav(fileOf(t), concatInt16(parts[i]), 24000));
  }
  const out = {};
  for (const t of texts) {
    const w = readWav(fileOf(t));
    out[t] = trim(resample(w.pcm, w.rate, 48000), 48000);
  }
  return out;
}

// ── 「真人」参与者:连续发音频(静音泵),话语插队 ──────────────────────────
class Human {
  constructor(cid) {
    this.bot = new LaresBot({ circleId: cid, name: '真人', passcode: PASSCODE, authVersion: 2, signaling: WSURL });
    this.ai = []; // {t, db, pcm}
    this.chats = [];
    this.caps = [];
    this.utter = null;
    this.stopped = false;
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
    let base = Date.now();
    let n = 0;
    while (!this.stopped) {
      let frame = silence;
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
      if (d > 0) await wait(d);
      else if (d < -200) { base = Date.now(); n = 0; }
    }
  }
  /// 说一段话(48k PCM,已去首尾静音);返回 {onsetAt, endAt}
  say(pcm) {
    return new Promise((resolve) => { this.utter = { pcm, off: 0, resolve }; });
  }
  async leave() { this.stopped = true; await this._pumpP?.catch(() => {}); await this.bot.leave(); }
}

/// 收到的 AI 帧里,时间窗 [from, to) 内的非静音统计
function aiStats(h, from, to = Infinity) {
  const fr = h.ai.filter((x) => x.t >= from && x.t < to);
  const voiced = fr.filter((x) => x.db >= SILENT_DB);
  const ms = voiced.reduce((s, x) => s + (x.pcm.length / x.rate) * 1000, 0);
  return {
    frames: fr.length,
    first: voiced[0]?.t ?? null,
    last: voiced.at(-1)?.t ?? null,
    voicedMs: Math.round(ms),
    peakDb: voiced.length ? Math.round(Math.max(...voiced.map((x) => x.db))) : null,
    meanDb: voiced.length ? Math.round(voiced.reduce((s, x) => s + x.db, 0) / voiced.length) : null,
    pcm: () => concatInt16(fr.map((x) => (x.rate === 48000 ? x.pcm : resample(x.pcm, x.rate, 48000)))),
  };
}

/// 收到的 AI 音频回灌 qwen3-asr-flash-realtime
async function asrRoundTrip(pcm48) {
  api.asrRoundTrip += 1;
  const pcm16 = resample(trim(pcm48, 48000), 48000, 16000);
  const asr = new DashscopeAsr({ apiKey: KEY });
  const finals = [];
  return new Promise((resolve) => {
    let timer = null;
    const h = asr.open({
      identity: 'rt',
      onFinal: (t) => finals.push(t),
      onError: () => {},
      onClose: () => { clearTimeout(timer); resolve(finals.join('')); },
    });
    (async () => {
      for (let o = 0; o < pcm16.length; o += 1600) { h.send(pcm16.slice(o, o + 1600)); await wait(50); }
      for (let k = 0; k < 15; k++) { h.send(new Int16Array(1600)); await wait(50); }
      await h.finish(4000);
    })();
    timer = setTimeout(() => { h.close(); }, 30000);
  });
}

function overlap(a, b) {
  const A = new Set(String(a).match(/[\u4e00-\u9fff]/g) ?? []);
  const B = String(b).match(/[\u4e00-\u9fff]/g) ?? [];
  if (!B.length) return 0;
  return B.filter((c) => A.has(c)).length / B.length;
}

// ── 一轮 ─────────────────────────────────────────────────────────────────
async function wakeTurn(h, label, pcm, aiId) {
  if (api.llmTurns >= MAX_LLM_TURNS) { ok(false, `${label}: LLM 轮数上限`, api.llmTurns); return null; }
  const nTurns = turns.length;
  const chats0 = h.chats.length;
  const caps0 = h.caps.length;
  const sp = await h.say(pcm);
  const turn = await waitTurn((e) => turns.indexOf(e) >= nTurns, 45000);
  await wait(2500); // 等尾音 / 聊天 / 最终字幕
  if (!ok(Boolean(turn), `${label}: bot turn 事件`, turn ? { query: turn.query, reply: turn.reply, ttfaMs: turn.ttfaMs } : 'timeout')) return null;
  const st = aiStats(h, sp.endAt);
  const extTtfa = st.first ? st.first - sp.endAt : null;
  const asrDelay = turn.asrFinalAt - sp.endAt;
  const chat = h.chats.slice(chats0).find((m) => String(m.from).startsWith('u_ai_'));
  const capF = h.caps.slice(caps0).filter((c) => String(c.from).startsWith('u_ai_') && c.final).at(-1);
  const capP = h.caps.slice(caps0).filter((c) => String(c.from).startsWith('u_ai_') && !c.final);
  ok(st.voicedMs > 1000 && st.meanDb > -40, `${label}: 真人收到 AI 非静音语音`, { voicedMs: st.voicedMs, meanDb: st.meanDb, peakDb: st.peakDb, frames: st.frames, from: aiId });
  ok(chat?.body === turn.reply, `${label}: lares.chat 收到回复`, chat?.body ?? null);
  ok(capF?.text === turn.reply && capP.length >= 1, `${label}: lares.cap 字幕 partial→final`, { partials: capP.length, final: capF?.text ?? null });
  const m = { extTtfaMs: extTtfa, botTtfaMs: turn.ttfaMs, llmFirstTokenMs: turn.llmFirstTokenMs, firstSentenceMs: turn.firstSentenceMs, ttsFirstAudioMs: turn.ttsFirstAudioMs, asrFinalAfterSpeechEndMs: asrDelay, speechMs: sp.endAt - sp.onsetAt };
  info(`${label}: 延迟`, m);
  return { turn, st, m, sp };
}

async function interruptTurn(h, label, prompt, interrupter) {
  if (api.llmTurns >= MAX_LLM_TURNS) { ok(false, `${label}: LLM 轮数上限`, api.llmTurns); return; }
  const nTurns = turns.length;
  const chats0 = h.chats.length;
  const caps0 = h.caps.length;
  const sp = await h.say(prompt);
  // 等 AI 音频播出 ~1.5s(按收到的非静音时长算)
  const t0 = Date.now();
  let onset = null;
  while (Date.now() - t0 < 30000) {
    const st = aiStats(h, sp.endAt);
    if (st.voicedMs >= 1500) break;
    if (turns.length > nTurns) break; // 回答太短,已经结束
    await wait(20);
  }
  if (turns.length > nTurns) { ok(false, `${label}: 回答在插话前就结束了`, turns.at(-1)); return; }
  const interP = h.say(interrupter);
  await wait(30);
  onset = h.utter?.onsetAt ?? Date.now();
  const turn = await waitTurn((e) => turns.indexOf(e) >= nTurns, 30000);
  const ip = await interP;
  onset = ip.onsetAt;
  await wait(3000);
  const before = aiStats(h, sp.endAt, onset);
  const after = aiStats(h, onset);
  const stopMs = after.last ? after.last - onset : 0;
  ok(Boolean(turn?.interrupted), `${label}: turn.interrupted`, turn ? { interrupted: turn.interrupted, heardChars: turn.heardChars, replyChars: turn.replyChars } : 'timeout');
  if (!turn) return;
  ok(turn.heardChars > 0 && turn.heardChars < turn.replyChars, `${label}: heardChars < replyChars`, { heard: turn.heardChars, reply: turn.replyChars });
  ok(stopMs <= 500, `${label}: 插话开始 → 最后一个非静音 AI 帧`, { stopMs, aiVoicedBeforeMs: before.voicedMs, aiVoicedAfterMs: after.voicedMs });
  const chat = h.chats.slice(chats0).find((m) => String(m.from).startsWith('u_ai_'));
  const capF = h.caps.slice(caps0).filter((c) => String(c.from).startsWith('u_ai_') && c.final).at(-1);
  const heardOk = chat && chat.body.endsWith('…') && [...chat.body].length - 1 === turn.heardChars && String(turn.reply).startsWith(chat.body.slice(0, -1));
  ok(Boolean(heardOk), `${label}: 聊天只发听到的部分 + …`, { chat: chat?.body ?? null, reply: turn.reply });
  ok(capF?.text === chat?.body, `${label}: 最终字幕 = 听到的部分`, capF?.text ?? null);
  return { stopMs, turn };
}

// ── 主流程 ────────────────────────────────────────────────────────────────
async function main() {
  ok(KEY.length > 20, 'DashScope key loaded (env only)', `len=${KEY.length}`);
  info('run dir (logs, not in repo)', RUN_DIR);
  const lk = await startLivekit();
  info('livekit-server', lk);
  const srv = await startServer();
  const health = await (await fetch(`${HTTP}/health`)).json();
  ok(health.rtcConfigured === true, 'server health.rtcConfigured', health.rtcConfigured);

  // 素材
  const P1 = '小助手，请用一句话介绍一下北京。';
  const P2 = '小助手，上海有什么好吃的？一句话回答。';
  const P3 = '小助手，推荐一项适合冬天的运动，简短一点。';
  const PL = '小助手，请详细讲讲长城的历史，多说一点。';
  const P5 = '小助手，杭州最有名的景点是哪里？一句话。';
  const audio = await synthAll([P1, P2, P3, PL, P5]);
  const qw = readWav(QUAL_WAV);
  const interrupter = trim(resample(qw.pcm, qw.rate, 48000), 48000);
  info('prompts (TTS Cherry 24k→48k, cached in temp)', Object.fromEntries(Object.entries(audio).map(([k, v]) => [k, `${Math.round(v.length / 48)}ms`])));
  info('interrupter (syn_0_00.wav 16k→48k)', `${Math.round(interrupter.length / 48)}ms`);

  // 圈 + 插件
  const cid = newCircleId();
  const verifier = await authVerifier(PASSCODE, cid);
  const ownerKey = crypto.randomBytes(32).toString('hex');
  const owner = await wsMember({ cid, verifier, userId: 'u_owner', name: '圈主', register: { verifier, ownerHash: sha256(ownerKey) } });
  ok(true, 'v2 circle registered', cid);
  const cfg = { name: '小助手', trigger: 'wake', maxTurnsPerHour: MAX_LLM_TURNS, maxReplyChars: 120 };
  const aiId = `u_ai_${sha256(cid).slice(0, 8)}`;
  const latency = { ext: [], bot: [], llm: [], tts: [], asr: [], firstSentence: [] };
  const rec = (r) => { if (!r) return; latency.ext.push(r.m.extTtfaMs); latency.bot.push(r.m.botTtfaMs); latency.llm.push(r.m.llmFirstTokenMs); latency.tts.push(r.m.ttsFirstAudioMs); latency.asr.push(r.m.asrFinalAfterSpeechEndMs); latency.firstSentence.push(r.m.firstSentenceMs); };
  const modes = {};

  if (MODE === 'both' || MODE === 'server') {
    say('\n[A] server-managed (builtin plugin lares.ai-voice)');
    owner.send({ t: 'plugin_install', circleId: cid, pluginId: 'lares.ai-voice', ownerKey });
    const inst = await owner.waitFor((m) => m.t === 'plugin_installed' || (m.t === 'owner_error' && m.op === 'plugin_install'));
    ok(inst?.t === 'plugin_installed' && inst.plugin?.enabled === true, 'plugin_install lares.ai-voice', inst?.t === 'plugin_installed' ? { id: inst.plugin.id, enabled: inst.plugin.enabled } : inst);
    owner.send({ t: 'plugin_config_set', circleId: cid, pluginId: 'lares.ai-voice', config: cfg, ownerKey });
    const cs = await owner.waitFor((m) => m.op === 'plugin_config_set');
    ok(cs?.t === 'owner_ok', 'plugin_config_set', cs);
    await wait(300);
    ok(!serverLines.some((l) => l.includes(cid) && l.includes('已启动')), '房里没人时不拉起 AI', true);

    const h = new Human(cid);
    const idx0 = serverLines.length;
    await h.join();
    ok(true, 'human joined + publishing (silence pump)', h.bot.userId);
    const started = await waitServer((l) => l.includes(cid) && l.includes('已启动'), 10000, { fromIdx: idx0 });
    const pid = Number(/pid=(\d+)/.exec(started ?? '')?.[1]) || null;
    const ready = await waitServer((l) => l.includes(cid) && / ready$/.test(l), 30000, { fromIdx: idx0 });
    ok(Boolean(started) && Boolean(ready), 'supervisor spawned AI bot → ready', { pid, ready: Boolean(ready) });
    if (!ready) {
      say(serverLines.slice(idx0).filter((l) => l.includes('ai-voice')).slice(-20).join('\n'));
    } else {
      await wait(2500); // 订阅真人音轨 + TTS 热连接
      const r1 = await wakeTurn(h, 'A1', audio[P1], aiId);
      rec(r1);
      if (r1) {
        const text = await asrRoundTrip(r1.st.pcm());
        const ov = overlap(text, r1.turn.reply);
        ok(cjk(text) >= 5 && ov >= 0.5, 'A1: AI 音频回灌 ASR(qwen3-asr-flash-realtime)', { asr: text, overlapWithReply: Number(ov.toFixed(2)) });
      }
      rec(await wakeTurn(h, 'A2', audio[P2], aiId));
      rec(await wakeTurn(h, 'A3', audio[P3], aiId));
      const ir = await interruptTurn(h, 'A4 interrupt', audio[PL], interrupter);
      if (ir) results.interruptStopMs = ir.stopMs;
      modes.serverManaged = turns.length >= 3 ? 'worked' : 'partial';
    }

    // 停用 → 进程退出
    const idx1 = serverLines.length;
    owner.send({ t: 'plugin_set_enabled', circleId: cid, pluginId: 'lares.ai-voice', enabled: false, ownerKey });
    const se = await owner.waitFor((m) => m.op === 'plugin_set_enabled');
    ok(se?.t === 'owner_ok', 'plugin_set_enabled false', se?.t);
    const exited = await waitServer((l) => l.includes(cid) && l.includes('已退出'), 8000, { fromIdx: idx1 });
    let alive = null;
    if (pid) { try { process.kill(pid, 0); alive = true; } catch { alive = false; } }
    ok(Boolean(exited) && alive === false, '停用插件 → AI 进程退出', { log: exited?.replace(/^.*已退出/, '已退出') ?? null, pidAlive: alive });
    await h.leave();
    await wait(500);
  }

  if (MODE === 'both' || MODE === 'standalone') {
    say('\n[B] standalone (index.mjs --passcode --auth-v2)');
    const cfgFile = path.join(RUN_DIR, 'ai.json');
    writeFileSync(cfgFile, JSON.stringify(cfg));
    const h = new Human(cid);
    await h.join();
    const env = { ...process.env, LARES_AI_LOG_TEXT: '1', LARES_AI_USAGE_FILE: path.join(RUN_DIR, 'usage_b.json') };
    for (const k of Object.keys(env)) if (k.startsWith('LIVEKIT_')) delete env[k];
    const bot = spawn(process.execPath, [path.join(SERVER_DIR, 'bots', 'voice-agent', 'index.mjs'), '--circle', cid, '--signaling', WSURL, '--passcode', PASSCODE, '--auth-v2', '--config', cfgFile],
      { cwd: SERVER_DIR, env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    children.push(bot);
    const evs = [];
    let readyRes;
    const readyP = new Promise((r) => { readyRes = r; });
    lineSplit(bot.stdout, (l) => {
      const r = redact(l);
      appendFileSync(path.join(RUN_DIR, 'standalone.log'), `OUT ${r}\n`);
      let ev; try { ev = JSON.parse(r); } catch { return; }
      evs.push(ev);
      if (ev.ev === 'ready') readyRes(ev);
      if (ev.ev === 'turn') pushTurn(ev);
    });
    lineSplit(bot.stderr, (l) => appendFileSync(path.join(RUN_DIR, 'standalone.log'), `ERR ${redact(l)}\n`));
    const exitP = new Promise((r) => bot.on('exit', (code) => r(code)));
    const rd = await Promise.race([readyP, wait(30000).then(() => null)]);
    ok(Boolean(rd), 'standalone bot ready', rd);
    if (rd) {
      await wait(2500);
      const r5 = await wakeTurn(h, 'B1', audio[P5], aiId);
      rec(r5);
      if (r5) modes.standalone = 'worked';
    }
    const t0 = Date.now();
    bot.stdin.write('{"cmd":"stop"}\n');
    const code = await Promise.race([exitP, wait(6000).then(() => 'timeout')]);
    ok(code === 0 && evs.some((e) => e.ev === 'exit' && e.code === 0), 'standalone {"cmd":"stop"} → exit 0', { code, ms: Date.now() - t0 });
    await h.leave();
  }

  info('modes', modes);
  info('latency p50 (ms)', {
    externalTtfa_speechEnd_to_firstAiAudio: p50(latency.ext),
    botTtfa_asrFinal_to_firstFrame: p50(latency.bot),
    llmFirstToken: p50(latency.llm),
    firstSentence: p50(latency.firstSentence),
    ttsFirstAudio: p50(latency.tts),
    asrFinalAfterSpeechEnd: p50(latency.asr),
    samples: latency.ext.length,
  });
  info('latency raw (ms)', latency);
  info('real API calls (approx)', { llmTurns: api.llmTurns, ttsPromptSynthSessions: api.ttsPromptSessions, asrRoundTrip: api.asrRoundTrip, note: 'bot side: 1 ASR session per utterance burst, 1 TTS session used per turn (+ idle warm spares)' });
  owner.close();
  srv.kill();
}

function finish(code) {
  for (const c of children.reverse()) { try { c.kill(); } catch { /* */ } }
  say(failed === 0 && code === 0 ? '\nAI VOICE E2E 全部通过' : `\nAI VOICE E2E ${failed} 项失败`);
  const out = `# ai_voice_e2e ${new Date().toISOString()}\n${lines.join('\n')}\n\nRESULTS ${JSON.stringify(results, null, 1)}\n`;
  writeFileSync(path.join(HERE, 'ai_voice_e2e.last.txt'), redact(out));
  setTimeout(() => process.exit(failed === 0 && code === 0 ? 0 : 1), 500);
}

main().then(() => finish(0), (e) => { say(`✗ E2E 异常: ${e?.stack ?? e}`); failed++; finish(1); });
