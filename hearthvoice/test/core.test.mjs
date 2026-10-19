// 灶语本体:createHearthvoice + 内存 port 的端到端回合(mock provider,不联网、不进房)、port 校验、平台无关性。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createHearthvoice, checkPort, memoryPort, PORT_EVENTS, AGENT_NAME, AGENT_NAME_EN,
  AI_VOICE_DEFAULTS, normalizeConfig, detectWake, MockAsr, MockLlm, MockTts, tone,
} from '../index.mjs';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function providers({ script = ['灶语，今天天气怎么样？'], reply = '今天天气不错，适合出门。' } = {}) {
  return { asr: new MockAsr({ script }), llm: new MockLlm({ reply }), tts: new MockTts({}) };
}

/// 10ms 帧喂「人声」:静音 → 有声 → 静音
async function speak(port, identity, ms) {
  const fr = (pcm) => port.emit('audio', identity, pcm, 48000, 1);
  for (let t = 0; t < 100; t += 10) fr(new Int16Array(480));
  for (let t = 0; t < ms; t += 10) { fr(tone(48000, 10, { freq: 200, amp: 9000 })); if (t % 50 === 0) await wait(5); }
  for (let t = 0; t < 1300; t += 10) { fr(new Int16Array(480)); if (t % 50 === 0) await wait(5); }
}
async function until(pred, ms = 8000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const v = pred(); if (v) return v; await wait(10); }
  return null;
}

test('名字:灶语 / Hearthvoice;默认配置的名字与唤醒词都是「灶语」', () => {
  assert.equal(AGENT_NAME, '灶语');
  assert.equal(AGENT_NAME_EN, 'Hearthvoice');
  assert.equal(AI_VOICE_DEFAULTS.name, '灶语');
  assert.equal(AI_VOICE_DEFAULTS.wakeWords, '灶语');
  const c = normalizeConfig({}).config;
  assert.equal(c.name, '灶语');
});

test('唤醒词「灶语」:精确与常见 ASR 同音都能叫应', () => {
  const cfg = AI_VOICE_DEFAULTS;
  for (const v of ['灶语', '造语', '早语', '灶雨', '灶鱼', '躁语']) {
    const r = detectWake(`${v}，讲个笑话`, cfg);
    assert.ok(r.hit && r.query === '讲个笑话', `${v} → ${JSON.stringify(r)}`);
  }
  assert.ok(!detectWake('我们去吃饭吧', cfg).hit);
});

test('checkPort:缺成员时报出名字;memoryPort 合格', () => {
  assert.throws(() => checkPort(null), /port must be an object/);
  assert.throws(() => checkPort({ selfId: 'x', on() {} }), /join, leave, audioOut, sendChat, publishCaption/);
  assert.throws(() => checkPort({ ...memoryPort(), selfId: '' }), /selfId/);
  assert.throws(() => checkPort({ ...memoryPort(), isHuman: 3 }), /isHuman/);
  const p = memoryPort();
  assert.equal(checkPort(p), p);
  assert.deepEqual(Object.keys(PORT_EVENTS).sort(), ['audio', 'capctl', 'chat', 'disconnected', 'joined', 'left', 'name']);
});

test('createHearthvoice:缺 provider / 坏配置立即报错', () => {
  assert.throws(() => createHearthvoice({ port: memoryPort(), ...providers(), llm: null }), /llm provider required/);
  assert.throws(() => createHearthvoice({ port: memoryPort(), ...providers(), policy: { config: [] } }), /bad config/);
});

test('一轮完整对话:叫「灶语」→ 字幕 / 聊天 / 出站音轨 / 状态 都经 port 发出;stop 离房', async () => {
  const port = memoryPort({ selfId: 'hv_self' });
  const events = [];
  const pv = providers();
  const hv = createHearthvoice({ port, ...pv, policy: { emit: (e) => events.push(e), agent: { paceScale: 0.25 } } });
  assert.equal(port.joined, false);
  await hv.start();
  assert.equal(port.joined, true);
  assert.ok(hv.agent, 'start 后有回合引擎');
  port.emit('name', 'p_alice', 'Alice');
  await speak(port, 'p_alice', 600);
  const turn = await until(() => events.find((e) => e.ev === 'turn'));
  assert.ok(turn, `应有 turn 事件: ${JSON.stringify(events)}`);
  assert.equal(turn.trigger, 'wake');
  assert.equal(port.out.chats.at(-1), '今天天气不错，适合出门。');
  assert.equal(port.out.caps.at(-1).final, true);
  assert.ok(port.out.frames.length > 20 && port.out.frames.every((f) => f instanceof Int16Array && f.length === 480), '48k 10ms 帧进出站音轨');
  const states = port.out.states.map((s) => s.state);
  assert.ok(states.includes('thinking') && states.includes('speaking') && states.at(-1) === 'listening', states.join(','));
  assert.equal(pv.llm.calls[0].messages.at(-1).content, 'Alice: 今天天气怎么样？');
  assert.match(pv.llm.calls[0].messages[0].content, /灶语/, '系统提示里有自己的名字');
  await hv.stop();
  assert.equal(port.left, true);
  await hv.stop(); // 幂等
});

test('isHuman:port 判定为非真人的声音与文字一律不理', async () => {
  const port = memoryPort({ selfId: 'hv_self', isHuman: (id) => !id.startsWith('robot_') });
  const pv = providers();
  const hv = createHearthvoice({ port, ...pv, policy: { config: { trigger: 'always' }, agent: { paceScale: 0.25, warm: false } } });
  await hv.start();
  await speak(port, 'robot_1', 300);
  port.emit('chat', { senderId: 'robot_2', body: '@AI 你好' });
  port.emit('chat', { senderId: 'hv_self', body: '@AI 自己' });
  await wait(300);
  assert.equal(pv.asr.sessions ?? 0, 0, '不给非真人开 ASR');
  assert.equal(pv.llm.calls.length, 0, '不回答非真人');
  port.emit('chat', { senderId: 'p_bob', senderName: 'Bob', body: '@AI 一加一' });
  await until(() => pv.llm.calls.length > 0);
  assert.equal(pv.llm.calls.length, 1, '真人的 @AI 照常回答');
  await hv.stop();
});

test('setConfig:热更新、改名走 port.rename;坏配置返回 false', async () => {
  const port = memoryPort();
  const hv = createHearthvoice({ port, ...providers(), policy: { agent: { warm: false } } });
  assert.equal(hv.setConfig({ name: '阿福' }), true, '进房前也能改');
  await hv.start();
  assert.equal(hv.setConfig({ name: '阿福', trigger: 'ptt' }), true);
  assert.equal(hv.config.trigger, 'ptt');
  assert.equal(hv.agent.config.trigger, 'ptt');
  assert.equal(hv.setConfig('bogus'), false);
  assert.equal(hv.config.trigger, 'ptt', '坏配置不改动');
  assert.equal(hv.setConfig({ name: '阿福', trigger: 'bogus' }), true, '不认识的触发方式按默认归一化');
  assert.equal(hv.config.trigger, 'wake');
  assert.deepEqual(port.out.names, ['阿福']);
  await hv.stop();
});

test('每日上限:持久化文件里今天已满 → dailyCapReached', () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'hv-'));
  try {
    const file = path.join(dir, 'usage.json');
    const hv = createHearthvoice({ port: memoryPort(), ...providers(), policy: { config: { maxTurnsPerDay: 1 }, usageFile: file } });
    assert.equal(hv.dailyCapReached(), false);
    hv.guard.recordTurn();
    const again = createHearthvoice({ port: memoryPort(), ...providers(), policy: { config: { maxTurnsPerDay: 1 }, usageFile: file } });
    assert.equal(again.dailyCapReached(), true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('平台无关:本体源码不 import Lares / LiveKit / server / lares-bridge', () => {
  const files = [];
  const walk = (d) => { for (const f of readdirSync(d)) { const p = path.join(d, f); if (f === 'test' || f === 'node_modules') continue; if (statSync(p).isDirectory()) walk(p); else if (f.endsWith('.mjs')) files.push(p); } };
  walk(ROOT);
  assert.ok(files.length >= 10);
  for (const f of files) {
    const src = readFileSync(f, 'utf8');
    const specs = [...src.matchAll(/(?:from\s+|import\s*\(\s*)['"]([^'"]+)['"]/g)].map((m) => m[1]);
    for (const s of specs) {
      assert.ok(!/livekit|lares|server\//i.test(s), `${path.relative(ROOT, f)} imports ${s}`);
      assert.ok(s.startsWith('node:') || s.startsWith('.') || s === 'ws', `${path.relative(ROOT, f)}: unexpected dependency ${s}`);
    }
    assert.ok(!/LARES_/.test(src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '')), `${path.relative(ROOT, f)} reads LARES_* env`);
  }
});
