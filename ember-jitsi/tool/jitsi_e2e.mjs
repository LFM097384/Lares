#!/usr/bin/env node
// ember-jitsi · 真 Jitsi 服务器上的端到端验证。
//   JITSI_URL(缺省 https://localhost:8443)上开一个随机房间:
//   1. 张伟(召集人)先进会 → 起炉灵 bot(子进程 `node ember-jitsi/index.mjs`,真 DashScope ASR + 真 LLM)→ 李秀梅、王强进会
//   2. 三个模拟真人 = 三个无头 Chromium,假麦克风播放 DashScope TTS 合成的真中文语音 WAV(说完后静音)
//   3. 命令全部走 Jitsi 会议聊天(lib-jitsi-meet sendTextMessage / sendPrivateTextMessage)
// 检查项见 CHECKS。结果写 tool/jitsi_e2e.last.txt(不含密钥、不含原话)。
// 密钥只来自环境变量:LARES_AI_LLM_KEY(或 _API_KEY)/ _BASE_URL / _MODEL;DashScope:LARES_DASHSCOPE_API_KEY,
// 没有时从 EMBER_DASHSCOPE_KEY_CSV(缺省 ~/Downloads/默认业务空间-apiKey-6421725.csv)读进内存,绝不打印、不落盘。
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JitsiBrowserBridge } from '../bridge.mjs';
import { loadWs } from '../deps.mjs';
import { DashscopeTts } from '../../hearthvoice/providers/dashscope.mjs';
import { concatInt16 } from '../../ember/agent/audio.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PKG = path.join(HERE, '..');
const OUT = path.join(HERE, 'jitsi_e2e.last.txt');
const URL_ = process.env.JITSI_URL || 'https://localhost:8443';
const ROOM = `ember-e2e-${randomBytes(3).toString('hex')}`;
const K = 2;
const CACHE = process.env.EMBER_E2E_CACHE || path.join(os.tmpdir(), 'ember-jitsi-e2e-cache');
const KEY_CSV = process.env.EMBER_DASHSCOPE_KEY_CSV || path.join(os.homedir(), 'Downloads', '默认业务空间-apiKey-6421725.csv');
const NAMES = ['张伟', '李秀梅', '王强'];
const ORG = '星辰科技';
const SCRIPT = {
  张伟: { voice: 'Ethan', text: '大家好，我是张伟，在星辰科技负责产品。我提议从下个月开始，每两周的周五下午办一次读书会，第一本书读《三体》。' },
  李秀梅: { voice: 'Cherry', text: '我是李秀梅。我同意这个提议，读书会由大家轮流主持，每次结束时写一页读书笔记，共享给所有人。' },
  王强: { voice: 'Ethan', text: '我是王强，补充一点：每次读书会控制在一个小时以内，地点定在三楼的大会议室。' },
};
const QUESTION = '读书会定在什么时候举行？';
const LEAD_SILENCE_S = 3; // 轨道接通前留白
const TAIL_SILENCE_S = 400; // 说完后静音(Chromium 假麦克风会循环播放文件,尾巴够长就不会重播)
// 原话探针:这些片段若出现在 bot 的 stdout / stderr 里,即为泄露
const PROBES = ['负责产品', '每两周的周五', '轮流主持', '读书笔记', '三楼', '一个小时以内', '《三体》', ...NAMES, ORG];

const lines = [];
const results = [];
const t0 = Date.now();
const say = (s) => { const l = `[${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s] ${s}`; lines.push(l); process.stdout.write(`${l}\n`); };
const check = (n, ok, what, detail = '') => { results.push({ n, ok, what }); say(`${ok ? 'PASS' : 'FAIL'} [${n}] ${what}${detail ? ` — ${detail}` : ''}`); return ok; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms, what) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timeout: ${what}`);
    await sleep(200);
  }
}
const sha = (s) => createHash('sha256').update(s).digest('hex');

// ── 密钥(只进内存)──
function dashscopeKey() {
  if (process.env.LARES_DASHSCOPE_API_KEY) return process.env.LARES_DASHSCOPE_API_KEY.trim();
  if (!existsSync(KEY_CSV)) return '';
  for (const line of readFileSync(KEY_CSV, 'utf8').split(/\r?\n/)) {
    const [k, ...v] = line.split(',');
    if (k?.trim() === 'apiKey') return v.join(',').trim();
  }
  return '';
}

// ── TTS → WAV(缓存,按 voice+text 哈希)──
function writeWav(file, pcm, rate) {
  const data = Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0, 'ascii'); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8, 'ascii');
  h.write('fmt ', 12, 'ascii'); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36, 'ascii'); h.writeUInt32LE(data.length, 40);
  writeFileSync(file, Buffer.concat([h, data]));
}
async function tts(key, WebSocket, voice, text) {
  const engine = new DashscopeTts({ apiKey: key, openTimeoutMs: 30000, WebSocket, log: () => {} });
  const s = await engine.open({ voice });
  const parts = [];
  try {
    await new Promise((resolve, reject) => {
      const to = setTimeout(() => reject(new Error('tts_timeout')), 45000);
      s.setHandlers({ onAudio: (_i, pcm) => parts.push(pcm), onSegmentDone: () => { clearTimeout(to); resolve(); }, onError: (e) => { clearTimeout(to); reject(e); } });
      s.send(text);
    });
  } finally { s.close(); }
  return { pcm: concatInt16(parts), rate: s.sampleRate || 24000 };
}
async function synth(key) {
  mkdirSync(CACHE, { recursive: true });
  const WebSocket = await loadWs();
  const files = {};
  for (const name of NAMES) {
    const { voice, text } = SCRIPT[name];
    const f = path.join(CACHE, `${sha(`v2:${voice}:${text}:${LEAD_SILENCE_S}:${TAIL_SILENCE_S}`).slice(0, 16)}.wav`);
    if (!existsSync(f)) {
      if (!key) throw new Error('no DashScope key for TTS');
      let r;
      try { r = await tts(key, WebSocket, voice, text); } catch { r = await tts(key, WebSocket, 'Cherry', text); }
      const lead = new Int16Array(r.rate * LEAD_SILENCE_S);
      const tail = new Int16Array(r.rate * TAIL_SILENCE_S);
      writeWav(f, concatInt16([lead, r.pcm, tail]), r.rate);
      say(`TTS ${name}: ${(r.pcm.length / r.rate).toFixed(1)} s speech @ ${r.rate} Hz (cached)`);
    } else say(`TTS ${name}: cached WAV`);
    files[name] = f;
  }
  return files;
}

// ── 一个模拟真人 ──
function human(name, wav) {
  const b = new JitsiBrowserBridge({ url: URL_, room: ROOM, name, fakeAudioWav: wav, log: (m) => say(`${name} bridge: ${m}`) });
  const h = { name, b, pub: [], priv: [], peers: new Map(), leftIds: new Set() };
  b.on('chat', (id, text, isPrivate) => (isPrivate ? h.priv : h.pub).push({ id, text, at: Date.now() }));
  b.on('participant', (id, n) => h.peers.set(id, n));
  b.on('name', (id, n) => h.peers.set(id, n));
  b.on('left', (id) => h.leftIds.add(id));
  h.botId = () => [...h.peers].find(([, n]) => n === '炉灵')?.[0] ?? null;
  h.cmd = (text) => b.sendPublic(text);
  h.waitPub = (re, ms = 60000, since = 0) => until(() => h.pub.find((m) => m.at >= since && re.test(m.text)), ms, `${name} public ${re}`);
  h.waitPriv = (re, ms = 60000, since = 0) => until(() => h.priv.find((m) => m.at >= since && re.test(m.text)), ms, `${name} private ${re}`);
  return h;
}

function allFiles(d) {
  const out = [];
  if (!existsSync(d)) return out;
  for (const f of readdirSync(d)) { const p = path.join(d, f); if (statSync(p).isDirectory()) out.push(...allFiles(p)); else out.push(p); }
  return out;
}
const hasName = (s) => [...NAMES].filter((n) => s.includes(n));

async function main() {
  say(`ember-jitsi e2e · server ${URL_} · room ${ROOM} · k=${K}`);
  const llmKey = (process.env.LARES_AI_LLM_API_KEY || process.env.LARES_AI_LLM_KEY || '').trim();
  const dsKey = dashscopeKey();
  say(`env: LLM key ${llmKey ? 'present' : 'MISSING (mock LLM)'} · model ${process.env.LARES_AI_LLM_MODEL || 'deepseek-flash'} · DashScope key ${dsKey ? 'present' : 'MISSING'}`);
  if (!dsKey) throw new Error('DashScope key required (ASR + TTS)');
  const wavs = await synth(dsKey);
  const memRoot = mkdtempSync(path.join(os.tmpdir(), 'ember-jitsi-e2e-mem-'));
  const H = Object.fromEntries(NAMES.map((n) => [n, human(n, wavs[n])]));
  const zw = H['张伟']; const lxm = H['李秀梅']; const wq = H['王强'];
  let bot = null;
  const botOut = []; const botErr = []; const botEv = [];
  try {
    // ── 1. 张伟先进会,然后起 bot ──
    await zw.b.join();
    say(`张伟 joined as ${zw.b.myId}`);
    const env = { ...process.env, LARES_DASHSCOPE_API_KEY: dsKey, JITSI_URL: URL_ };
    bot = spawn(process.execPath, [path.join(PKG, 'index.mjs'), '--room', ROOM, '--url', URL_, '--k', String(K), '--memory-dir', memRoot, '--asr', 'dashscope'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    let buf = '';
    bot.stdout.on('data', (d) => { const s = String(d); botOut.push(s); buf += s; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); try { botEv.push({ ...JSON.parse(l), at: Date.now() }); } catch { /* */ } } });
    bot.stderr.on('data', (d) => botErr.push(String(d)));
    const exited = new Promise((r) => bot.on('exit', (code) => r(code)));
    const ready = await until(() => botEv.find((e) => e.ev === 'ready' || e.ev === 'exit'), 90000, 'bot ready');
    if (ready.ev !== 'ready') throw new Error(`bot failed to start: ${botEv.map((e) => e.message).filter(Boolean).join('; ')}`);
    say(`bot ready: endpoint ${ready.endpoint} llm=${ready.llm} asr=${ready.asr} memory=${ready.memory}`);
    const botId = await until(() => zw.botId(), 30000, 'bot visible');
    const announce = await zw.waitPub(/AI 会议助手/, 30000).catch(() => null);
    check(1, botId === ready.endpoint && Boolean(announce), 'bot joins the real conference, visible as 「炉灵」 in the participant list and announces itself in chat', `endpoint ${botId}`);

    await lxm.b.join(); await wq.b.join();
    for (const h of [lxm, wq]) await until(() => h.botId(), 20000, `${h.name} sees 炉灵`);
    say(`李秀梅 ${lxm.b.myId} · 王强 ${wq.b.myId} joined; all see 炉灵`);

    // ── 2. 同意 → 开麦说话 → 逐人 ASR ──
    let since = Date.now();
    for (const h of [zw, lxm, wq]) await h.cmd('@炉灵 同意');
    await zw.waitPub(/已同意 3 人/, 30000, since);
    say('3 humans acked via chat');
    const finalsBy = {};
    for (const h of [zw, lxm, wq]) {
      const ts = Date.now();
      await h.b.addMic();
      try {
        await until(() => botEv.find((e) => e.ev === 'asr_final' && e.endpoint === h.b.myId && e.at >= ts), 60000, `${h.name} asr final`);
        await sleep(2500); // 余下的分句
      } catch (e) { say(`${h.name}: ${e.message}`); }
      finalsBy[h.name] = botEv.filter((e) => e.ev === 'asr_final' && e.endpoint === h.b.myId).reduce((s, e) => s + e.chars, 0);
      say(`${h.name} spoke; bot ASR finals for endpoint ${h.b.myId}: ${botEv.filter((e) => e.ev === 'asr_final' && e.endpoint === h.b.myId).length} (${finalsBy[h.name]} chars)`);
    }
    check(2, NAMES.every((n) => finalsBy[n] >= 10), 'bot per-speaker ASR (DashScope) receives each human\'s real speech, keyed by Jitsi endpoint', JSON.stringify(finalsBy));

    // ── 3. 聊天提问 → 答案(私信给已同意者)无名字 ──
    since = Date.now();
    await wq.cmd(`@炉灵 问 ${QUESTION}`);
    const ans = await wq.waitPriv(/【炉灵·回答】/, 120000, since).catch(() => null);
    const ansText = ans?.text ?? '';
    const ansBody = ansText.split('\n答:')[1] ?? '';
    const leakedInPub = zw.pub.filter((m) => m.at >= since).some((m) => m.text.includes('【炉灵·回答】'));
    check(3, Boolean(ans) && hasName(ansText).length === 0 && !leakedInPub && ansBody.length > 0, 'question in chat → answer (private to acked members) with no participant names', `answer ${ansBody.length} chars, mentions 周五: ${/周五/.test(ansBody)}, names: ${JSON.stringify(hasName(ansText))}`);

    // ── 4/5. 纪要 → k-of-n ──
    since = Date.now();
    await zw.cmd('@炉灵 纪要');
    let draft = await zw.waitPriv(/【炉灵·纪要草稿 D1】/, 180000, since);
    say(`draft D1 received privately (${draft.text.split('\n').length - 2} items)`);
    // 标 ⚠ 的条目:召集人逐条「泛化」(会清空批准、重发草稿)
    const risky = [...draft.text.matchAll(/^(\d+)\. .*⚠/gm)].map((m) => Number(m[1]));
    for (const n of risky) {
      const ts = Date.now();
      await zw.cmd(`@炉灵 泛化 D1 ${n}`);
      draft = await zw.waitPriv(/【炉灵·纪要草稿 D1】/, 120000, ts);
    }
    if (risky.length) say(`generalised ${risky.length} role-risk item(s)`);
    const pubBefore = zw.pub.length;
    since = Date.now();
    await zw.cmd('@炉灵 批准 D1');
    await zw.waitPub(/D1 已获 1\/2 人批准,未放行/, 30000, since);
    await zw.cmd('@炉灵 批准 D1'); // 同一人再批一次
    await sleep(4000);
    const releasedEarly = zw.pub.slice(pubBefore).some((m) => m.text.includes('已放行纪要'));
    const notAcked = !releasedEarly && !botEv.some((e) => e.ev === 'released');
    since = Date.now();
    await lxm.cmd('@炉灵 批准 D1');
    const rel = await zw.waitPub(/【炉灵·已放行纪要 D1】/, 60000, since).catch(() => null);
    check(4, notAcked && Boolean(rel), `minutes release needs k=${K} approvals from distinct humans: 1 approval (and a repeat by the same human) released nothing; the 2nd distinct human released`, `released-before-k: ${releasedEarly}`);
    const relText = rel?.text ?? '';
    const bad = [...hasName(relText), ...(relText.includes(ORG) ? [ORG] : [])];
    check(5, Boolean(rel) && bad.length === 0, 'released text has no 张伟/李秀梅/王强 and no 星辰科技', `${relText.length} chars; offenders: ${JSON.stringify(bad)}`);
    lines.push('---- released (public, de-identified) ----', relText, '---- end released ----');

    // ── 6. 撤回 → 派生记忆零残留 ──
    since = Date.now();
    await lxm.cmd('@炉灵 记忆');
    const memMsg = await lxm.waitPriv(/【炉灵·本圈记忆】/, 30000, since);
    const m1 = /^M1\. \[[^\]]+\] (.+)$/m.exec(memMsg.text);
    let ok6 = false; let detail6 = 'no memory item';
    if (m1) {
      const itemText = m1[1].trim();
      const filesBefore = allFiles(memRoot);
      const hitBefore = filesBefore.filter((f) => readFileSync(f, 'utf8').includes(itemText)).length;
      since = Date.now();
      await wq.cmd('@炉灵 撤回 M1'); // 王强没批准过 → 拒绝
      const denied = await wq.waitPriv(/mem_retract 未完成|没有这条记忆/, 30000, since).catch(() => null);
      since = Date.now();
      await lxm.cmd('@炉灵 撤回 M1');
      await zw.waitPub(/记忆 M1 已撤回/, 60000, since);
      await sleep(1500);
      const files = allFiles(memRoot);
      const residue = files.filter((f) => readFileSync(f, 'utf8').includes(itemText)).map((f) => path.relative(memRoot, f));
      const needle = itemText.slice(0, 12);
      const residue2 = files.filter((f) => readFileSync(f, 'utf8').includes(needle)).map((f) => path.relative(memRoot, f));
      ok6 = hitBefore > 0 && residue.length === 0 && residue2.length === 0 && Boolean(denied);
      detail6 = `item in ${hitBefore} file(s) before; after retract: ${residue.length + residue2.length} file(s) (of ${files.length}); non-approver retract denied: ${Boolean(denied)}`;
    }
    check(6, ok6, 'retract (by an approver) leaves zero trace in Ember\'s derived memory files', detail6);

    // ── 7. 结束 ──
    since = Date.now();
    await wq.cmd('@炉灵 结束'); // 不是召集人
    const denied7 = await wq.waitPriv(/只有召集人能散会/, 30000, since).catch(() => null);
    await zw.cmd('@炉灵 结束');
    const endMsg = await zw.waitPub(/散会/, 30000, since).catch(() => null);
    const code = await Promise.race([exited, sleep(30000).then(() => 'timeout')]);
    const botLeft = await until(() => zw.leftIds.has(botId), 15000, 'bot left').then(() => true, () => false);
    check(7, Boolean(denied7) && Boolean(endMsg) && code === 0 && botLeft, '「结束」 by the convener ends the session; non-convener refused; bot leaves the conference and exits 0', `exit ${code}, left: ${botLeft}`);
    bot = null;

    // ── 8. 日志无原话 ──
    const logs = botOut.join('') + botErr.join('');
    const leaks = PROBES.filter((p) => logs.includes(p));
    check(8, leaks.length === 0, 'no raw speech text (or names/org) in the bot\'s stdout/stderr logs', `${logs.length} bytes scanned, ${PROBES.length} probes, leaks: ${leaks.length}`);
    const evs = [...new Set(botEv.map((e) => e.ev))];
    say(`bot stdout events: ${evs.join(', ')}`);
  } finally {
    if (bot) { try { bot.stdin.write('{"cmd":"stop"}\n'); } catch { /* */ } await sleep(3000); try { bot.kill(); } catch { /* */ } }
    for (const h of Object.values(H)) await h.b.leave().catch(() => {});
    try { rmSync(memRoot, { recursive: true, force: true }); } catch { /* */ }
  }
}

let fatal = null;
try { await main(); } catch (e) { fatal = e; say(`FATAL ${String(e?.message ?? e).split('\n')[0]}`); }
const pass = results.filter((r) => r.ok).length;
const summary = `ember-jitsi e2e: ${pass}/8 checks passed${fatal ? ' (aborted)' : ''} · ${new Date().toISOString()}`;
say(summary);
writeFileSync(OUT, `${lines.join('\n')}\n`);
process.exitCode = pass === 8 && !fatal ? 0 : 1;
