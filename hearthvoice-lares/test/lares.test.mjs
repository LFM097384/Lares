// hearthvoice-lares:LaresRoom → 灶语 port 的映射、runVoiceBot 全流程(假房间 + mock provider)、CLI 契约(退出码 / stdout JSON)。
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { tone, checkPort } from '../../hearthvoice/index.mjs';
import { runVoiceBot, parseArgs, loadConfig, UsageError, EXIT } from '../index.mjs';
import { laresVoicePort } from '../port.mjs';
import { createLlm, createProviders } from '../providers.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ENTRY = path.join(HERE, '..', 'index.mjs');
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/// 与 LaresRoom 同形的假房间(不联网)
class FakeRoom {
  constructor(userId = 'u_ai_deadbeef') {
    this.userId = userId;
    this.handlers = { audio: [], chat: [], capctl: [], left: [], names: [], joined: [], disconnected: [] };
    this.out = { frames: [], chats: [], caps: [], states: [], renames: [], cleared: 0 };
    this.joined = false;
    this.left = false;
  }
  on(k, fn) { this.handlers[k].push(fn); return this; }
  fire(k, ...a) { for (const fn of this.handlers[k]) fn(...a); }
  async join() { this.joined = true; return this; }
  async leave() { this.left = true; }
  sink() { return { captureFrame: (f) => this.out.frames.push(f), clear: () => { this.out.cleared += 1; }, queuedMs: () => 0 }; }
  async sendChat(t) { this.out.chats.push(t); }
  async publishCaption(c) { this.out.caps.push(c); }
  async publishState(f) { this.out.states.push(f); }
  rename(n) { this.out.renames.push(n); }
}

async function speak(room, identity, ms) {
  const fr = (pcm) => room.fire('audio', identity, pcm, 48000, 1);
  for (let t = 0; t < 100; t += 10) fr(new Int16Array(480));
  for (let t = 0; t < ms; t += 10) { fr(tone(48000, 10, { freq: 200, amp: 9000 })); if (t % 50 === 0) await wait(5); }
  for (let t = 0; t < 1300; t += 10) { fr(new Int16Array(480)); if (t % 50 === 0) await wait(5); }
}
async function until(pred, ms = 8000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const v = pred(); if (v) return v; await wait(10); }
  return null;
}

test('laresVoicePort:满足灶语 port 接口;names → name;u_ai_ / bot: 不算真人', () => {
  const room = new FakeRoom();
  const port = checkPort(laresVoicePort(room));
  assert.equal(port.selfId, 'u_ai_deadbeef');
  const seen = [];
  port.on('name', (id, n) => seen.push([id, n]));
  room.fire('names', 'u_a', 'Alice');
  assert.deepEqual(seen, [['u_a', 'Alice']]);
  assert.throws(() => port.on('bogus', () => {}), /unknown port event/);
  assert.equal(port.isHuman('u_alice'), true);
  assert.equal(port.isHuman('u_ai_anon_1'), false);
  assert.equal(port.isHuman('bot:x'), false);
});

test('runVoiceBot(假房间 + mock):ready → 叫「灶语」一轮 → turn;别的 AI 的声音不理;config 热改名;stop → 0 并离房', async () => {
  const room = new FakeRoom();
  const events = [];
  const bot = await runVoiceBot({
    circleId: 'c_t', room, providers: 'mock', mock: { asr: { script: ['灶语，几点了'] }, llm: { reply: '下午三点。' } },
    emit: (e) => events.push(e), log: () => {}, env: {}, agent: { paceScale: 0.25 },
  });
  assert.ok(room.joined);
  const ready = events.find((e) => e.ev === 'ready');
  assert.deepEqual([ready.userId, ready.circleId, ready.providers, ready.trigger], ['u_ai_deadbeef', 'c_t', 'mock', 'wake']);
  assert.equal(bot.config.name, '灶语');
  assert.equal(room.out.states[0]?.t, 'state', '进房后补发 lares.ai 状态');

  await speak(room, 'u_ai_other', 300);
  await wait(200);
  assert.equal(events.filter((e) => e.ev === 'turn').length, 0, '不听别的 AI');

  room.fire('names', 'u_alice', 'Alice');
  await speak(room, 'u_alice', 500);
  const turn = await until(() => events.find((e) => e.ev === 'turn'));
  assert.ok(turn, JSON.stringify(events));
  assert.equal(room.out.chats.at(-1), '下午三点。');
  assert.ok(room.out.frames.length > 10 && room.out.frames.every((f) => f.length === 480));

  assert.equal(bot.setConfig({ name: '阿福' }), true);
  assert.deepEqual(room.out.renames, ['阿福']);
  assert.equal(bot.setConfig('坏'), false);

  assert.equal(await bot.stop(), EXIT.OK);
  assert.ok(room.left);
});

test('runVoiceBot:断线 → 退出码 1 + error 事件;圈子解散 → 0', async () => {
  for (const [why, code] of [['signaling', 1], ['circle_deleted', 0]]) {
    const room = new FakeRoom();
    const events = [];
    const bot = await runVoiceBot({ circleId: 'c', room, providers: 'mock', emit: (e) => events.push(e), log: () => {}, env: {}, agent: { warm: false } });
    room.fire('disconnected', why);
    assert.equal(await bot.done, code, why);
    assert.equal(events.some((e) => e.ev === 'error' && e.where === 'room'), code === 1);
  }
});

test('runVoiceBot:今日额度已满 → 不进房,cap_reached + 退出码 4', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'hvl-'));
  try {
    const usageFile = path.join(dir, 'u.json');
    const r1 = new FakeRoom();
    const b1 = await runVoiceBot({ circleId: 'c', room: r1, providers: 'mock', config: { maxTurnsPerDay: 1 }, usageFile, log: () => {}, env: {}, agent: { warm: false } });
    b1.hearthvoice.guard.recordTurn();
    await b1.stop();
    const r2 = new FakeRoom();
    const events = [];
    const b2 = await runVoiceBot({ circleId: 'c', room: r2, providers: 'mock', config: { maxTurnsPerDay: 1 }, usageFile, emit: (e) => events.push(e), log: () => {}, env: {} });
    assert.equal(r2.joined, false);
    assert.equal(await b2.done, EXIT.DAILY_CAP);
    assert.equal(events[0].ev, 'cap_reached');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('CLI 解析与配置:参数名不变;--name 覆盖;LARES_AI_CONFIG', () => {
  const o = parseArgs(['--circle', 'c_x', '--signaling', 'ws://h/ws', '--passcode', 'p', '--auth-v2', '--e2ee', '--config', 'f.json', '--providers', 'mock', '--user-id', 'u_1', '--name', '阿福']);
  assert.deepEqual(o, { providers: 'mock', authV2: true, e2ee: true, circleId: 'c_x', signaling: 'ws://h/ws', passcode: 'p', configPath: 'f.json', userId: 'u_1', name: '阿福' });
  assert.throws(() => parseArgs(['--bogus']), UsageError);
  assert.throws(() => parseArgs(['--circle']), UsageError);
  assert.equal(loadConfig({ env: {} }).name, '灶语');
  assert.equal(loadConfig({ env: { LARES_AI_CONFIG: '{"trigger":"always"}' }, name: '阿福' }).trigger, 'always');
  const dir = mkdtempSync(path.join(os.tmpdir(), 'hvl-'));
  try {
    const f = path.join(dir, 'c.json');
    writeFileSync(f, '{"name":"文件名"}');
    assert.equal(loadConfig({ configPath: f, env: { LARES_AI_CONFIG: '{"name":"环境"}' } }).name, '文件名', '--config 优先于 env');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('provider 组装:按 LARES_* 环境变量;缺 key 报错;extra body 错误带变量名', async () => {
  assert.equal(createProviders('mock').kind, 'mock');
  assert.throws(() => createProviders('nope'), /unknown_providers/);
  await assert.rejects(createProviders('dashscope', { env: {} }), /LARES_DASHSCOPE_API_KEY missing/);
  const p = await createProviders('dashscope', { env: { LARES_DASHSCOPE_API_KEY: 'k-not-real', LARES_DASHSCOPE_HOST: 'ds.example', LARES_AI_TTS_MODEL: 'tts-x' } });
  assert.equal(p.asr.host, 'ds.example');
  assert.equal(p.tts.model, 'tts-x');
  await assert.rejects(createLlm({ LARES_AI_LLM_EXTRA_BODY: 'nope' }), /LARES_AI_LLM_EXTRA_BODY: invalid JSON/);
  const ds = await createLlm({ LARES_DASHSCOPE_API_KEY: 'k', LARES_AI_LLM_BASE_URL: 'https://api.deepseek.com', LARES_AI_LLM_KEY: 'k2' });
  assert.equal(ds.constructor.name, 'FallbackLlm');
});

test('进程契约:--help → 0;缺 --circle → 2 且 stdout 每行 JSON;--e2ee 无口令 → 2;坏 providers → 2', () => {
  const run = (args) => spawnSync(process.execPath, [ENTRY, ...args], { encoding: 'utf8', env: { ...process.env, LARES_AI_PROVIDERS: '' }, timeout: 20000 });
  const h = run(['--help']);
  assert.equal(h.status, 0);
  assert.match(h.stderr, /usage: node index\.mjs --circle/);
  for (const args of [['--providers', 'mock'], ['--circle', 'c', '--e2ee'], ['--circle', 'c', '--providers', 'nope'], ['--bogus']]) {
    const r = run(args);
    assert.equal(r.status, EXIT.BAD_ARGS, `${args.join(' ')}: ${r.stdout}`);
    const lines = r.stdout.trim().split('\n').map((l) => JSON.parse(l));
    assert.deepEqual(lines.at(-1), { ev: 'exit', code: 2 });
    assert.equal(lines[0].ev, 'error');
  }
});

test('边界:插件不 import server/ 源码', async () => {
  const { readdirSync, readFileSync } = await import('node:fs');
  const root = path.join(HERE, '..');
  for (const f of readdirSync(root).filter((x) => x.endsWith('.mjs'))) {
    const src = readFileSync(path.join(root, f), 'utf8');
    const specs = [...src.matchAll(/(?:from\s+|import\s*\(\s*)['"]([^'"]+)['"]/g)].map((m) => m[1]);
    for (const s of specs) assert.ok(s.startsWith('node:') || s.startsWith('./') || s.startsWith('../hearthvoice/') || s.startsWith('../lares-bridge/'), `${f} imports ${s}`);
  }
});
