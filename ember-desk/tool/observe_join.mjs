#!/usr/bin/env node
// ember-desk · 真 Jitsi 上的进会观察脚本(手动集成检查用,不在 node --test 里跑)。
//   node ember-desk/tool/observe_join.mjs --via api|cli|mcp|protocol --end leave|chat [--url https://localhost:8443] [--room R]
// 流程:观察者以「张伟」先进会(= 召集人)→ 经所选路径让炉灵进会 → 等参会者「炉灵」出现 + 公共聊天里的「AI 会议助手」自我介绍
//      → 结束(--end leave:对应路径的离会;--end chat:张伟在聊天发「@炉灵 结束」)→ 等 /status state=idle 且 lastSession.state=ended。
// 守护进程须已在运行(用默认状态目录或 EMBER_DESK_HOME)。只打印元数据,不打印密钥。
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { JitsiBrowserBridge } from '../../ember-jitsi/bridge.mjs';
import { api } from '../client.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DESK = path.join(HERE, '..');
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const VIA = opt('via', 'api');
const END = opt('end', 'leave');
const URL_ = opt('url', process.env.JITSI_URL || 'https://localhost:8443');
const ROOM = opt('room', `desk-${VIA}-${randomBytes(3).toString('hex')}`);
const LINK = `${URL_.replace(/\/+$/, '')}/${ROOM}`;
if (!['api', 'cli', 'mcp', 'protocol'].includes(VIA) || !['leave', 'chat'].includes(END)) { console.error('usage: --via api|cli|mcp|protocol --end leave|chat'); process.exit(2); }

const t0 = Date.now();
const say = (s) => process.stdout.write(`[${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s] ${s}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms, what) {
  const end = Date.now() + ms;
  for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) throw new Error(`timeout: ${what}`); await sleep(250); }
}

function run(cmd, args, { input } = {}) {
  return new Promise((resolve) => {
    const c = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    let out = ''; let err = '';
    c.stdout.on('data', (d) => { out += d; });
    c.stderr.on('data', (d) => { err += d; });
    c.on('exit', (code) => resolve({ code, out: out.trim(), err: err.trim() }));
    c.on('error', (e) => resolve({ code: -1, out: '', err: e.message }));
    if (input) c.stdin.write(input);
    c.stdin.end();
  });
}

// ── MCP 客户端(换行分隔 JSON-RPC)──
function mcpClient() {
  const c = spawn(process.execPath, [path.join(DESK, 'mcp.mjs')], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  let buf = ''; const waiting = new Map(); let id = 0;
  c.stdout.on('data', (d) => {
    buf += d; let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const l = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!l) continue;
      try { const m = JSON.parse(l); const w = waiting.get(m.id); if (w) { waiting.delete(m.id); w(m); } } catch { /* */ }
    }
  });
  const send = (o) => c.stdin.write(`${JSON.stringify(o)}\n`);
  const req = (method, params) => new Promise((resolve, reject) => {
    const my = ++id; waiting.set(my, resolve); send({ jsonrpc: '2.0', id: my, method, params });
    setTimeout(() => { if (waiting.delete(my)) reject(new Error(`mcp timeout ${method}`)); }, 60_000);
  });
  return { req, note: (method, params) => send({ jsonrpc: '2.0', method, params }), close: () => { c.stdin.end(); setTimeout(() => c.kill(), 2000).unref(); } };
}

async function trigger() {
  if (VIA === 'api') return api('POST', '/join', { link: LINK });
  if (VIA === 'cli') {
    const r = await run(process.execPath, [path.join(DESK, 'cli.mjs'), 'join', LINK, '--json']);
    say(`cli join exit ${r.code}`);
    if (r.code !== 0) throw new Error(`cli join failed: ${r.out} ${r.err}`);
    return JSON.parse(r.out);
  }
  if (VIA === 'mcp') {
    const m = mcpClient();
    const init = await m.req('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'observe_join', version: '0' } });
    say(`mcp initialize → ${init.result?.serverInfo?.name} ${init.result?.protocolVersion}`);
    m.note('notifications/initialized', {});
    const list = await m.req('tools/list', {});
    say(`mcp tools: ${(list.result?.tools ?? []).map((t) => t.name).join(',')}`);
    const r = await m.req('tools/call', { name: 'ember_join_meeting', arguments: { link: LINK } });
    say(`mcp join isError=${Boolean(r.result?.isError)} ${String(r.result?.content?.[0]?.text ?? JSON.stringify(r.error)).slice(0, 160)}`);
    if (r.error || r.result?.isError) throw new Error('mcp join failed');
    globalThis.MCP = m;
    return null;
  }
  // protocol
  const url = `ember://join?link=${encodeURIComponent(LINK)}`;
  const r = await run('cmd.exe', ['/d', '/c', 'start', '""', url]);
  say(`cmd start ember:// exit ${r.code}${r.err ? ` err=${r.err.slice(0, 120)}` : ''}`);
  return null;
}

async function leave() {
  if (VIA === 'cli') { const r = await run(process.execPath, [path.join(DESK, 'cli.mjs'), 'leave', '--json']); say(`cli leave exit ${r.code}`); return; }
  if (VIA === 'mcp') {
    const r = await globalThis.MCP.req('tools/call', { name: 'ember_leave_meeting', arguments: {} });
    say(`mcp leave isError=${Boolean(r.result?.isError)}`); return;
  }
  if (VIA === 'protocol') { const r = await run('cmd.exe', ['/d', '/c', 'start', '""', 'ember://leave']); say(`cmd start ember://leave exit ${r.code}`); return; }
  const r = await api('POST', '/leave', {}, { timeoutMs: 30_000 }); say(`api leave → session ${r.session?.state}`);
}

async function main() {
  say(`observe · via=${VIA} end=${END} · ${LINK}`);
  const st0 = await api('GET', '/status');
  if (st0.state !== 'idle') throw new Error(`daemon not idle: ${st0.state}`);
  const b = new JitsiBrowserBridge({ url: URL_, room: ROOM, name: '张伟', log: (m) => say(`bridge: ${m}`) });
  const peers = new Map(); const pub = [];
  b.on('participant', (id, n) => peers.set(id, n));
  b.on('name', (id, n) => peers.set(id, n));
  b.on('chat', (id, text, isPrivate) => { if (!isPrivate) pub.push({ id, text, at: Date.now() }); });
  const res = { via: VIA, end: END, room: ROOM, botVisible: false, announced: false, ended: false, idle: false, lastState: null };
  try {
    await b.join();
    say(`张伟 joined as ${b.myId}`);
    const r = await trigger();
    if (r) say(`join → session ${r.id ?? ''} state=${r.state ?? ''}`);
    const botId = await until(() => [...peers].find(([, n]) => n === '炉灵')?.[0], 120_000, 'bot visible').catch(() => null);
    res.botVisible = Boolean(botId);
    say(`bot visible: ${res.botVisible} ${botId ?? ''}`);
    const ann = await until(() => pub.find((m) => /AI 会议助手/.test(m.text)), 30_000, 'announce').catch(() => null);
    res.announced = Boolean(ann);
    say(`announcement seen: ${res.announced}`);
    await until(async () => (await api('GET', '/status')).state === 'in-meeting', 30_000, 'in-meeting').catch(() => null);
    if (END === 'chat') {
      await b.sendPublic('@炉灵 结束');
      say('sent 「@炉灵 结束」');
      const reply = await until(() => pub.find((m) => m.id === botId && /散会|结束|再见|只有召集人/.test(m.text) && !/AI 会议助手|已同意/.test(m.text)), 20_000, 'bot reply').catch(() => null);
      if (reply) say(`bot replied in chat (${reply.text.length} chars): ${reply.text.slice(0, 60)}`);
    } else await leave();
    const fin = await until(async () => { const s = await api('GET', '/status'); return s.state === 'idle' && s.lastSession ? s : null; }, 60_000, 'idle').catch(() => null);
    const s = fin ?? await api('GET', '/status');
    res.idle = s.state === 'idle';
    res.lastState = s.lastSession?.state ?? null;
    res.exitCode = s.lastSession?.exitCode ?? null;
    res.error = s.lastSession?.error ?? null;
    res.ended = res.lastState === 'ended' && s.lastSession?.room === ROOM;
    say(`status: state=${s.state} lastSession=${res.lastState} exit=${res.exitCode} err=${res.error ?? ''} events=${(s.lastSession?.events ?? []).join(',')}`);
  } finally {
    globalThis.MCP?.close();
    await b.leave().catch(() => {});
  }
  res.pass = res.botVisible && res.announced && res.idle && res.ended;
  console.log(`RESULT ${JSON.stringify(res)}`);
  process.exitCode = res.pass ? 0 : 1;
}
main().catch((e) => { console.error(`observe failed: ${e.message}`); process.exitCode = 1; });
