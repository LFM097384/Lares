// node --test server/bots/anonym-agent/  —— FakeRoom + MockAsr + 录 prompt 的 LLM,不出网。
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { mkdtempSync, rmSync, readFileSync, readdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { MockAsr } from '../../voice-agent/providers/mock.mjs';
import { ROOM_RATE } from '../../voice-agent/audio.mjs';
import { runAnonAgent } from '../index.mjs';
import { createIngestGate, stripPseudonyms } from '../ingest_gate.mjs';
import { openMemory } from '../memory_iface.mjs';
import { loadSkills } from '../skills.mjs';
import { seal, unseal, generateX25519, x25519RawPublic } from '../sealing.mjs';
import { readReleasedKnowledge } from '../../../anonym-agent/core/filememory.mjs';
import { FakeRoom, client, until, tick, speechFrames, recordingLLM, scriptedHandler } from './helpers.mjs';

const ALICE = { id: 'u_alice', name: '王建国' };
const BOB = { id: 'u_bob', name: '李秀梅' };
const CAROL = { id: 'u_carol', name: 'Carol Smith' };
const RAW = {
  u_alice: '我是王建国，我们科室的预算明年要砍掉三成，我觉得应该先做试点。',
  u_bob: '李秀梅这里补充一句，我们可以下周先在小范围跑一下。',
};

async function setup({ llm = null, people = [ALICE, BOB], script = RAW, k = null, memDir = null, ingestOpts = {} } = {}) {
  const room = new FakeRoom(people);
  const asr = new MockAsr({ script: (id) => script[id] ?? '没听清', quietMs: 60, connectMs: 0 });
  const dir = memDir ?? mkdtempSync(path.join(os.tmpdir(), 'anon-agent-'));
  const ended = [];
  const bot = await runAnonAgent({
    circleId: 'c_test', room, asr, llm, k, memoryDir: dir, env: {}, hosted: false, log: () => {}, emit: (e) => { if (e.ev === 'ended') ended.push(e); },
    agentOpts: { ingestOpts: { batchMs: 50, ...ingestOpts }, asrOpts: { hangoverMs: 200 } },
  });
  return { room, asr, bot, agent: bot.agent, dir, ended, cleanup: () => { try { rmSync(dir, { recursive: true, force: true }); } catch { /* */ } } };
}

async function speak(room, id) {
  for (const f of speechFrames()) { room.fire('audio', id, f, ROOM_RATE, 1); await tick(0); }
}

test('完整流程:ack → 说话 → ask → minutes 草稿 → 审阅 → k 签名放行 → 记忆 → 撤回 → convener 散会', async () => {
  const llm = recordingLLM(scriptedHandler);
  const { room, agent, bot, dir, cleanup } = await setup({ llm });
  try {
    assert.equal(room.server[0].t, 'anon_active');
    assert.equal(room.server[0].on, true);
    const a = client(ALICE.id), b = client(BOB.id);
    room.msg(ALICE.id, { t: 'ack', pubKey: a.pubKey });
    room.msg(BOB.id, { t: 'ack', pubKey: b.pubKey });
    const st = room.last('state');
    assert.equal(st.convenerId, ALICE.id);
    assert.deepEqual(st.members.map((m) => [m.id, m.acked]), [[ALICE.id, true], [BOB.id, true]]);
    assert.equal(st.k, 2);

    await speak(room, ALICE.id);
    await speak(room, BOB.id);
    await until(() => agent.ingest.metrics().utterances >= 2);
    await agent.ingest.flush();
    const ledger = agent.ingest.ledgerView().entries();
    assert.ok(ledger.length >= 2, 'ledger 有条目');
    assert.ok(ledger.every((e) => /^P\d/.test(e.text)), '账本用假名');

    await agent.onMessage(BOB.id, { t: 'ask', q: '刚才大家主张什么?' });
    const ans = room.last('answer');
    assert.ok(ans?.a, 'answer 广播');

    await agent.onMessage(ALICE.id, { t: 'ask', q: '帮我出一份会议纪要' });
    let draft = room.last('draft').draft;
    assert.ok(draft.items.length >= 1);
    for (const it of draft.items) {
      assert.doesNotMatch(it.text, /\bP\d+\b/, '纪要不带假名');
      assert.doesNotMatch(it.text, /王建国|李秀梅/);
    }
    // 审阅:cut 第一条 → 重新哈希、签名作废
    const before = draft.draftHash;
    if (draft.items.length > 1) {
      await agent.onMessage(BOB.id, { t: 'review', draftId: draft.draftId, itemId: draft.items[0].id, action: 'cut' });
      draft = room.last('draft').draft;
      assert.notEqual(draft.draftHash, before);
    }
    // 旧哈希签名 → hash_mismatch
    const sStale = { ...a.approve(st, draft), draftHash: before === draft.draftHash ? 'x' : before };
    await agent.onMessage(ALICE.id, sStale);
    assert.equal(room.last('error').code, 'hash_mismatch');

    await agent.onMessage(ALICE.id, a.approve(st, draft));
    assert.deepEqual(room.last('approvals'), { t: 'approvals', draftId: draft.draftId, count: 1, k: 2 });
    assert.equal(room.of('released').length, 0);
    await agent.onMessage(BOB.id, b.approve(st, draft));
    const rel = room.last('released');
    assert.ok(rel, 'k=2 后放行');
    assert.ok(rel.text.startsWith('会议纪要 · 不署名 / Minutes · no attribution'));
    assert.doesNotMatch(rel.text, /王建国|李秀梅|\bP\d+\b/);
    const notice = room.server.find((m) => m.t === 'anon_released_notice');
    assert.ok(notice && notice.itemIds.length >= 1, 'anon_released_notice');
    // 服务器读得到
    const known = readReleasedKnowledge(dir, '');
    assert.ok(notice.itemIds.every((id) => known.some((k) => k.id === id)), 'readReleasedKnowledge 可见');

    await agent.onMessage(BOB.id, { t: 'mem_list' });
    const mem = room.last('mem').items;
    assert.ok(mem.length >= 1);
    await agent.onMessage(BOB.id, { t: 'mem_retract', itemId: mem[0].id });
    assert.equal(room.last('mem_retracted').itemId, mem[0].id);

    // 只有 convener 能 end
    await agent.onMessage(BOB.id, { t: 'end' });
    assert.equal(room.last('error').code, 'not_convener');
    await agent.onMessage(ALICE.id, { t: 'end' });
    const ended = room.last('ended');
    assert.equal(ended.receipt.sid, st.sid);
    assert.equal(ended.receipt.counts.releases, 1);
    assert.match(ended.receipt.sha256, /^[0-9a-f]{64}$/);
    assert.deepEqual(room.server.at(-1), { t: 'anon_active', circleId: 'c_test', on: false });
    assert.equal(agent.ingest.ledgerView().size, 0, '散会清空 ledger');
    assert.equal(await bot.done, 0, '退出码 0');
    assert.ok(room.left);

    // LLM 从没见过名字或原话
    const seen = llm.allText();
    assert.doesNotMatch(seen, /王建国|李秀梅|Carol/);
    for (const raw of Object.values(RAW)) assert.ok(!seen.includes(raw), 'LLM 未见原话');
    assert.ok(!seen.includes('我们科室的预算明年要砍掉三成'), 'LLM 未见原话片段');
  } finally { cleanup(); }
});

test('未 ack 的说话人:音频在 ASR 之前就丢掉', async () => {
  const { room, asr, agent, bot, cleanup } = await setup({ people: [ALICE, BOB] });
  try {
    const a = client(ALICE.id);
    room.msg(ALICE.id, { t: 'ack', pubKey: a.pubKey });
    await speak(room, BOB.id); // Bob 没 ack
    await tick(150);
    assert.equal(asr.sessions, 0, '没给未 ack 的人开 ASR');
    assert.equal(asr.liveSamples, 0);
    assert.ok(agent.counts.droppedUnackedFrames > 0);
    assert.equal(agent.speakers.size, 0);
    // 未 ack 的人也不能 ask / approve
    await agent.onMessage(BOB.id, { t: 'ask', q: 'hi' });
    assert.equal(room.last('error').code, 'not_acked');
    await speak(room, ALICE.id);
    await until(() => asr.sessions === 1);
    await bot.stop();
  } finally { cleanup(); }
});

test('IngestGate:假名化 + 名单 / PII 清洗 + 公共事实保留', async () => {
  const roster = [ALICE, BOB];
  const g = createIngestGate({ roster: () => roster, batchMs: 10_000 });
  g.utterance(ALICE.id, '我是王建国，电话13812345678。');
  g.utterance(BOB.id, '我同意李秀梅的意见，另外《三体》是刘慈欣写的。');
  g.utterance(ALICE.id, '我再说一句：先做试点。');
  const pend = g._pending();
  assert.deepEqual([...new Set(pend.map((x) => x.p))], ['P1', 'P2']);
  const all = pend.map((x) => x.text).join('\n');
  assert.doesNotMatch(all, /王建国|李秀梅|13812345678/);
  assert.match(all, /刘慈欣/, '公共人物保留');
  await g.flush();
  const txt = g.ledgerView().text();
  assert.match(txt, /P1/);
  assert.match(txt, /P2/);
  assert.match(txt, /三体/);
  assert.match(txt, /刘慈欣/);
  assert.doesNotMatch(txt, /王建国|李秀梅|u_alice|u_bob/);
  // 访问器只读:拿不到映射与原话
  const v = g.ledgerView();
  assert.deepEqual(Object.keys(v).sort(), ['entries', 'size', 'text']);
  assert.throws(() => { v.entries = null; });
  // 去假名
  assert.equal(stripPseudonyms('P2 认为应该先做试点'), '有观点认为应该先做试点');
  assert.doesNotMatch(stripPseudonyms('P1 and P3 agreed that X'), /P\d/);
});

test('原始缓冲:L3 后立即清空,≥600 字触发,最长 60 s', async () => {
  let now = 0;
  const timers = [];
  const g = createIngestGate({
    clock: () => now, setTimer: (fn, ms) => { const t = { fn, ms }; timers.push(t); return t; }, clearTimer: (t) => { t.fn = null; },
  });
  g.utterance('u_a', '第一句话说的是方案的成本问题。');
  assert.equal(g._pending().length, 1);
  assert.equal(timers.at(-1).ms, 20_000, '20 s 批次定时器');
  // 定时器到点 → flush → 缓冲为空
  timers.at(-1).fn();
  await g.flush();
  assert.equal(g._pending().length, 0);
  assert.equal(g.ledgerView().size, 1);
  // 600 字
  const long = '这是一句用来凑长度的普通发言内容，没有什么特别的信息。'.repeat(25);
  g.utterance('u_b', long);
  await g.flush();
  assert.equal(g._pending().length, 0, '≥600 字立即改写并清空');
  // 60 s 硬上限:定时器被吃掉也不会超过 60 s
  g.utterance('u_a', '慢一点的发言。');
  now += 61_000;
  g.utterance('u_a', '又一句。');
  await g.flush();
  assert.equal(g._pending().length, 0);
  assert.ok(g.metrics().maxHeldMs <= 61_000);
  // L3 失败:该批丢弃(fail closed),缓冲也清空
  const bad = createIngestGate({ llm: { chat: async () => { throw new Error('boom'); } }, batchMs: 10 });
  bad.utterance('u_a', '这句会在 L3 失败时被丢弃。');
  await bad.flush();
  assert.equal(bad._pending().length, 0);
  assert.equal(bad.ledgerView().size, 0);
  assert.equal(bad.metrics().l3Failures, 1);
  // 散会:全清
  g.wipe();
  assert.equal(g.ledgerView().size, 0);
  assert.equal(g._pending().length, 0);
});

test('skill 只拿 ledger:原话与名单不进 skill ctx 也不进 LLM prompt', async () => {
  const llm = recordingLLM(scriptedHandler);
  const { room, agent, bot, cleanup } = await setup({ llm });
  try {
    const seenCtx = [];
    const spy = { name: 'spy', description: 'x', outputs: 'room', run: async (ctx) => { seenCtx.push(ctx); return { text: ctx.ledger.text() }; } };
    agent.skills = new Map([...agent.skills, ['spy', spy]]);
    room.msg(ALICE.id, { t: 'ack', pubKey: client(ALICE.id).pubKey });
    agent.onTranscript(ALICE.id, RAW.u_alice);
    await agent.onMessage(ALICE.id, { t: 'skill', name: 'spy', args: { q: '王建国说了什么' } });
    const ctx = seenCtx[0];
    assert.deepEqual(Object.keys(ctx).sort(), ['args', 'ledger', 'llm', 'memory', 'parseJSON', 'q']);
    assert.doesNotMatch(ctx.q, /王建国/, 'q 已过 L1');
    const dump = JSON.stringify({ e: ctx.ledger.entries(), t: ctx.ledger.text() });
    assert.ok(!dump.includes(RAW.u_alice));
    assert.doesNotMatch(dump, /王建国|u_alice/);
    // 守卫:skill 直接把名字塞给 LLM 也会被洗掉
    await ctx.llm.chat([{ role: 'system', content: 'x' }, { role: 'user', content: '王建国 和 李秀梅' }]);
    assert.doesNotMatch(llm.allText(), /王建国|李秀梅/);
    for (const c of llm.calls) for (const m of c.messages) assert.ok(!String(m.content).includes(RAW.u_alice));
    await bot.stop();
  } finally { cleanup(); }
});

test('签名:重放 / 坏签名 / 换钥匙被拒;未 keep 的风险条目不出门', async () => {
  const { room, agent, bot, cleanup } = await setup({ people: [ALICE, BOB, CAROL], k: 2 });
  try {
    const a = client(ALICE.id), b = client(BOB.id), c = client(CAROL.id);
    for (const x of [a, b, c]) room.msg(x.id, { t: 'ack', pubKey: x.pubKey });
    room.msg(ALICE.id, { t: 'ack', pubKey: client('z').pubKey });
    assert.equal(room.last('error').code, 'key_mismatch', 'TOFU 钉钥匙');
    agent.onTranscript(ALICE.id, '我觉得方案可以先做试点。');
    agent.onTranscript(BOB.id, '我们部门预算太少了，真是太好了呢。');
    await agent.onMessage(BOB.id, { t: 'skill', name: 'minutes', args: {} });
    const draft = room.last('draft').draft;
    const st = room.last('state');
    const s1 = a.approve(st, draft);
    await agent.onMessage(ALICE.id, s1);
    await agent.onMessage(BOB.id, { ...b.approve(st, draft, s1.nonce) });
    assert.equal(room.last('error').code, 'replay', 'nonce 全会话唯一(即使签名有效)');
    await agent.onMessage(ALICE.id, s1);
    assert.equal(room.last('error').code, 'replay');
    await agent.onMessage(CAROL.id, { ...c.approve(st, draft), sig: a.approve(st, draft).sig });
    assert.equal(room.last('error').code, 'bad_sig');
    await agent.onMessage(BOB.id, b.approve(st, draft));
    const rel = room.last('released');
    assert.ok(rel);
    const risky = draft.items.filter((i) => i.roleRisk);
    for (const r of risky) assert.ok(!rel.text.includes(r.text), 'roleRisk 条目未放行');
    await bot.stop();
  } finally { cleanup(); }
});

test('最后一个人离开 → 自动散会、回执、退出码 0', async () => {
  const { room, agent, bot, cleanup } = await setup();
  try {
    room.msg(ALICE.id, { t: 'ack', pubKey: client(ALICE.id).pubKey });
    agent.onTranscript(ALICE.id, '我觉得可以。');
    room.exit(ALICE.id);
    assert.equal(room.of('ended').length, 0);
    assert.equal(room.last('state').convenerId, BOB.id, 'convener 让给在场的人');
    room.exit(BOB.id);
    const e = await until(() => room.last('ended'));
    assert.equal(e.receipt.reason, 'empty');
    assert.equal(agent.ingest.ledgerView().size, 0);
    assert.equal(await bot.done, 0);
    assert.deepEqual(room.server.at(-1), { t: 'anon_active', circleId: 'c_test', on: false });
  } finally { cleanup(); }
});

test('密封密钥:seal/unseal 往返、测试向量、篡改 / 错 circleId 失败', () => {
  const kp = generateX25519();
  const hex = crypto.randomBytes(32).toString('hex');
  assert.equal(unseal(seal(hex, kp.pubB64, 'c1'), kp, 'c1'), hex);
  assert.throws(() => unseal(seal(hex, kp.pubB64, 'c1'), kp, 'c2'), /unseal_failed/);
  const s = Buffer.from(seal(hex, kp.pubB64, 'c1'), 'base64');
  s[50] ^= 1;
  assert.throws(() => unseal(s.toString('base64'), kp, 'c1'), /unseal_failed/);
  assert.throws(() => unseal(seal(hex, generateX25519().pubB64, 'c1'), kp, 'c1'), /unseal_failed/);
  // SEALING.md 的向量
  const mk = (b) => { const pk = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.alloc(32, b)]), format: 'der', type: 'pkcs8' }); return { privateKey: pk, publicKey: crypto.createPublicKey(pk) }; };
  const agent = mk(0x11), eph = mk(0x22);
  assert.equal(x25519RawPublic(agent.publicKey).toString('base64'), 'e06Qm75//kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM=');
  const media = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
  const sealed = seal(media, x25519RawPublic(agent.publicKey).toString('base64'), 'c_test', { ephemeral: eph, nonce: Buffer.from('000102030405060708090a0b', 'hex') });
  const md = readFileSync(new URL('../../../anonym-agent/SEALING.md', import.meta.url), 'utf8');
  assert.ok(md.includes(sealed), 'SEALING.md 向量一致');
  assert.equal(unseal(sealed, agent, 'c_test'), media);
});

test('AnonRoom 密封流程:hello → anon_agent_key → 解封(假 WS)', async () => {
  const { AnonRoom } = await import('../room.mjs');
  const { EventEmitter } = await import('node:events');
  const ws = new EventEmitter();
  const sent = [];
  ws.send = (s) => sent.push(JSON.parse(s));
  const r = new AnonRoom({ circleId: 'c1', userId: 'u_ai_anon_x', name: 'x', signaling: 'ws://x', keyTimeoutMs: 2000 });
  r.ws = ws;
  assert.match(r.deviceId, /^d_anon_[0-9a-f]{12}$/);
  const p = r._awaitSealedKey();
  const hello = sent[0];
  assert.equal(hello.t, 'anon_agent_hello');
  assert.equal(Buffer.from(hello.x25519Pub, 'base64').length, 32);
  const hex = 'ab'.repeat(32);
  ws.emit('message', JSON.stringify({ t: 'anon_agent_key', circleId: 'c1', sealed: seal(hex, generateX25519().pubB64, 'c1'), x25519Pub: 'stale' })); // 封给别人的:忽略
  ws.emit('message', JSON.stringify({ t: 'anon_agent_key', circleId: 'c1', sealed: seal(hex, hello.x25519Pub, 'c1'), x25519Pub: hello.x25519Pub }));
  assert.equal(await p, hex);
});

test('skills 加载:answer(room)与 minutes(release)', async () => {
  const s = await loadSkills();
  assert.equal(s.get('answer')?.outputs, 'room');
  assert.equal(s.get('minutes')?.outputs, 'release');
});

test('记忆接口:filememory 后端,remember/recall/list/retract', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'anon-mem-'));
  try {
    const m = await openMemory({ dir, circleId: 'c_test' });
    assert.equal(m.kind, 'file');
    const saved = await m.remember([{ text: '决定先做小范围试点。', kind: 'decision' }], { sid: 's1', draftId: 'd1', approvals: 2, approverIds: ['u_alice', 'u_bob'] });
    assert.equal(saved.length, 1);
    assert.ok((await m.recall('试点')).length >= 1);
    assert.equal(await m.retract(saved[0].id, 'u_zed'), false, '非签名者不能撤');
    assert.equal(await m.retract(saved[0].id, 'u_alice'), true);
    assert.equal((await m.list()).length, 0);
    assert.ok(readdirSync(dir).length > 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
