// 端到端:RTMS 模拟器 → 签名 webhook → ember-zoom 服务器 → RtmsClient → zoomPort → Ember 会话 ↔ 侧边栏 hub。
// 确定性 mock LLM(录下全部 prompt),不出网。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { client as approver } from '../../ember/test/helpers.mjs';
import { recordingLLM, scriptedHandler } from '../../ember/test/helpers.mjs';
import { runEmberZoom, scopeFor } from '../index.mjs';
import { RtmsSim } from '../sim/rtms_sim.mjs';
import { sidebar, until } from './_util.mjs';

const CFG = { clientId: 'cid_e2e', clientSecret: 'csec_e2e', webhookSecret: 'whsec_e2e', port: 0, host: '127.0.0.1', k: 2, asrKind: 'zoom', postChat: true, lang: null, allowOrigins: null };
const ZW = { user_id: 16778240, user_name: '张伟' };
const LX = { user_id: 16779264, user_name: '李秀梅' };
const WJ = { user_id: 16780288, user_name: '王建国' };
const NAMES = /张伟|李秀梅|王建国|秀梅|建国/;
const ORG = /星辰科技|星辰/;
const SCRIPT = [
  { say: { ...ZW, text: '大家好，我是张伟，在星辰科技负责产品。我觉得下季度预算应该先做小范围试点。' } },
  { say: { ...LX, text: '同意张伟的看法，试点可以下周先在两个城市跑一下。' } },
  { say: { ...WJ, text: '李秀梅说得对，预算控制在十万以内，月底前复盘。' } },
];

/// 确定性 mock:L3 照 scriptedHandler 改写;answer 只从 LEDGER 里按关键词摘句(这样「答案无名字」测的是账本本身)
function handler(messages, opts, i) {
  const sys = messages.find((m) => m.role === 'system')?.content ?? '';
  const user = messages.filter((m) => m.role === 'user').map((m) => m.content).join('\n');
  if (/assistant sitting in a private/.test(sys)) {
    const ledger = (user.split('MEMORY:')[0] || '').split('\n').filter((l) => /预算|试点/.test(l));
    return { answer: ledger.length ? `账本里有这些：${ledger.join('；')}` : '账本里还没有相关内容。' };
  }
  return scriptedHandler(messages, opts, i);
}

function allFiles(d) {
  const out = [];
  if (!existsSync(d)) return out;
  for (const f of readdirSync(d)) { const p = path.join(d, f); if (statSync(p).isDirectory()) out.push(...allFiles(p)); else out.push(p); }
  return out;
}

async function meeting(app, sim, people) {
  const r = await sim.sendWebhook(`${app.url}/webhook`, { secret: CFG.webhookSecret });
  assert.equal(r.status, 200);
  await sim.waitReady();
  sim.join(people);
}

test('e2e: transcripts → gate → sidebar ask (no names) → minutes k-of-n → released (no names, no org) → stop → retract leaves no trace', async (t) => {
  const memRoot = mkdtempSync(path.join(os.tmpdir(), 'ember-zoom-e2e-'));
  const llm = recordingLLM(handler);
  const events = [];
  const app = await runEmberZoom({
    config: CFG, llm, asr: null, memoryDir: memRoot, emit: (e) => events.push(e), log: () => {},
    rtmsOpts: { backoff: { initialMs: 20, maxMs: 100 } }, sessionOpts: { ingestOpts: { batchMs: 30 } },
  });
  const sims = [];
  const sbs = [];
  t.after(async () => { for (const s of sbs) s.close(); await app.stop(); for (const s of sims) await s.close(); rmSync(memRoot, { recursive: true, force: true }); });

  // ── 会议 1 ──
  const sim = await new RtmsSim({ clientId: CFG.clientId, clientSecret: CFG.clientSecret, keepAliveMs: 200 }).listen(0);
  sims.push(sim);
  const mk = async (p) => { const s = await sidebar(app.url, { meetingUuid: sim.meetingUuid, participantId: String(p.user_id), screenName: p.user_name }); sbs.push(s); return s; };
  const [a, b, c] = [await mk(ZW), await mk(LX), await mk(WJ)];
  a.send({ t: 'zoom_invite' }); // 张伟点「邀请炉灵」→ 召集人
  await until(() => app.hub.inviterOf(sim.meetingUuid));
  await meeting(app, sim, [ZW, LX, WJ]);
  for (const s of [a, b, c]) await s.wait('zoom_welcome', (m) => m.bound);
  const keys = { a: approver('zu_16778240'), b: approver('zu_16779264'), c: approver('zu_16780288') };
  a.send({ t: 'ack', pubKey: keys.a.pubKey });
  b.send({ t: 'ack', pubKey: keys.b.pubKey });
  c.send({ t: 'ack', pubKey: keys.c.pubKey });
  const st = await a.wait('state', (m) => m.members.length === 3 && m.members.every((x) => x.acked));
  assert.equal(st.convenerId, 'zu_16778240', 'inviter is convener');
  assert.equal(st.k, 2);

  await sim.play(SCRIPT);
  const slot = [...app.sessions.values()][0];
  const session = slot.ember.session;
  await until(() => session.ingest.metrics().utterances >= 3, 5000, 'utterances');
  await session.ingest.flush();
  const ledger = session.ingest.ledgerView().entries();
  assert.ok(ledger.length >= 3, 'ledger filled from RTMS transcripts');
  for (const e of ledger) { assert.doesNotMatch(e.text, NAMES); assert.doesNotMatch(e.text, ORG); }

  // 侧边栏提问
  b.send({ t: 'ask', q: '刚才关于预算大家主张什么？' });
  const ans = await b.wait('answer');
  assert.ok(ans.a.length > 0);
  assert.match(ans.a, /预算|试点/, 'answer draws on the ledger');
  assert.doesNotMatch(ans.a, NAMES, 'answer has no names');
  assert.doesNotMatch(ans.a, ORG);

  // 纪要:需要 k=2 人签名
  a.send({ t: 'skill', name: 'minutes', args: {} });
  const draftMsg = await a.wait('draft');
  const draft = draftMsg.draft;
  assert.ok(draft.items.length >= 1);
  // 有风险条目就先 keep(真人审过),拿最新稿
  let cur = draft;
  for (const it of draft.items.filter((x) => x.roleRisk)) {
    a.send({ t: 'review', draftId: cur.draftId, itemId: it.id, action: 'generalise' });
    cur = (await a.wait('draft', (m) => m.draft.draftHash !== cur.draftHash)).draft;
  }
  a.send(keys.a.approve(st, cur));
  await b.wait('approvals', (m) => m.draftId === cur.draftId && m.count === 1);
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(b.of('released').length, 0, 'one approval is not enough');
  c.send(keys.c.approve(st, cur));
  const rel = await b.wait('released');
  assert.match(rel.text, /^会议纪要 · 不署名/);
  assert.doesNotMatch(rel.text, NAMES, 'released minutes: no names');
  assert.doesNotMatch(rel.text, ORG, 'released minutes: no 星辰科技');
  // 只有放行文本去会议聊天,且只交给召集人的侧边栏
  const post = await a.wait('zoom_post_chat');
  assert.equal(post.text, rel.text);
  assert.equal(b.of('zoom_post_chat').length + c.of('zoom_post_chat').length, 0);
  await until(() => events.some((e) => e.ev === 'host' && e.type === 'released'));

  // LLM 永远看不到名单名字与自报单位
  const seen = llm.allText();
  assert.doesNotMatch(seen, NAMES, 'no names ever reach the LLM');
  assert.doesNotMatch(seen, ORG, 'self-declared org never reaches the LLM');

  // 散会:RTMS 停(stop reason 6 MEETING_ENDED)→ 会话结束,侧边栏收到 ended
  sim.stop(6);
  const ended = await a.wait('ended');
  assert.equal(ended.receipt.counts.releases, 1);
  await until(() => app.sessions.size === 0, 5000, 'session cleaned');
  await a.wait('zoom_session', (m) => m.state === 'ended');

  // 落盘里:没有名字、没有单位、没有原话
  const scopeDir = path.join(memRoot, scopeFor(sim.startedPayload()));
  const files1 = allFiles(scopeDir);
  assert.ok(files1.length > 0, 'memory written');
  const disk1 = files1.map((f) => readFileSync(f, 'utf8')).join('\n');
  assert.doesNotMatch(disk1, NAMES);
  assert.doesNotMatch(disk1, ORG);
  for (const s of SCRIPT) assert.ok(!disk1.includes(s.say.text), 'no verbatim transcript on disk');

  // ── 会议 2(同一 meeting_id = 同一作用域):撤回记忆 ──
  const sim2 = await new RtmsSim({ clientId: CFG.clientId, clientSecret: CFG.clientSecret, meetingUuid: `${sim.meetingUuid}-2`, keepAliveMs: 200 }).listen(0);
  sims.push(sim2);
  const a2 = await sidebar(app.url, { meetingUuid: sim2.meetingUuid, participantId: String(LX.user_id), screenName: LX.user_name });
  sbs.push(a2);
  await meeting(app, sim2, [LX]);
  await a2.wait('zoom_welcome', (m) => m.bound);
  const k2 = approver('zu_16779264');
  a2.send({ t: 'ack', pubKey: k2.pubKey });
  await a2.wait('state', (m) => m.members.some((x) => x.acked));
  a2.send({ t: 'mem_list' });
  const mem = (await a2.wait('mem')).items;
  assert.ok(mem.length >= 1, 'released items are in scope memory');
  const target = mem[0];
  // 非签名者(李秀梅没签)不能撤 → 用签过名的张伟
  a2.send({ t: 'mem_retract', itemId: target.id });
  await a2.wait('error', (m) => m.op === 'mem_retract');
  const a3 = await sidebar(app.url, { meetingUuid: sim2.meetingUuid, participantId: String(ZW.user_id), screenName: ZW.user_name });
  sbs.push(a3);
  await a3.wait('zoom_welcome', (m) => m.bound);
  const k3 = approver('zu_16778240');
  a3.send({ t: 'ack', pubKey: k3.pubKey });
  await a3.wait('state', (m) => m.members.some((x) => x.id === 'zu_16778240' && x.acked));
  a3.send({ t: 'mem_retract', itemId: target.id });
  await a3.wait('mem_retracted', (m) => m.itemId === target.id);

  // 派生文件里零痕迹(topics / meetings / MEMORY.md / links.json / items / releases …)
  const files2 = allFiles(scopeDir);
  const needle = target.text.slice(0, Math.min(12, target.text.length));
  for (const f of files2) {
    const body = readFileSync(f, 'utf8');
    assert.ok(!body.includes(target.text), `retracted text still in ${path.relative(scopeDir, f)}`);
    assert.ok(!body.includes(needle), `retracted substring still in ${path.relative(scopeDir, f)}`);
  }
  for (const derived of ['MEMORY.md']) assert.ok(files2.some((f) => f.endsWith(derived)), `${derived} exists`);
  a2.send({ t: 'mem_list' });
  await until(() => a2.of('mem').length >= 2);
  assert.ok(!a2.last('mem').items.some((x) => x.id === target.id));

  // 结束会议 2:召集人(第一个入会的李秀梅)散会
  a2.send({ t: 'end' });
  await a2.wait('ended');
  await until(() => app.sessions.size === 0);
  // stdout 元数据事件里没有会话文字
  const blob = JSON.stringify(events);
  assert.doesNotMatch(blob, NAMES);
  assert.doesNotMatch(blob, /预算|试点/);
  assert.deepEqual(sim.violations, []);
  assert.deepEqual(sim2.violations, []);
});

test('e2e: bad webhook signature starts nothing', async (t) => {
  const app = await runEmberZoom({ config: CFG, llm: null, asr: null, memoryDir: null, emit: () => {}, log: () => {} });
  const sim = await new RtmsSim({ clientId: CFG.clientId, clientSecret: CFG.clientSecret }).listen(0);
  t.after(async () => { await app.stop(); await sim.close(); });
  const r = await sim.sendWebhook(`${app.url}/webhook`, { secret: CFG.webhookSecret, badSignature: true });
  assert.equal(r.status, 401);
  await new Promise((res) => setTimeout(res, 100));
  assert.equal(app.sessions.size, 0);
  assert.equal(sim.stats.connections, 0);
});

test('e2e: RTMS drop mid-meeting → reconnect → session survives; rtms_stopped webhook ends it', async (t) => {
  const events = [];
  const app = await runEmberZoom({ config: CFG, llm: null, asr: null, memoryDir: null, emit: (e) => events.push(e), log: () => {}, rtmsOpts: { backoff: { initialMs: 20, maxMs: 100 } }, sessionOpts: { ingestOpts: { batchMs: 20 } } });
  const sim = await new RtmsSim({ clientId: CFG.clientId, clientSecret: CFG.clientSecret, keepAliveMs: 200 }).listen(0);
  const sbs = [];
  t.after(async () => { for (const s of sbs) s.close(); await app.stop(); await sim.close(); });
  const a = await sidebar(app.url, { meetingUuid: sim.meetingUuid, participantId: String(ZW.user_id), screenName: ZW.user_name });
  sbs.push(a);
  await meeting(app, sim, [ZW]);
  await a.wait('zoom_welcome', (m) => m.bound);
  const k = approver('zu_16778240');
  a.send({ t: 'ack', pubKey: k.pubKey });
  await a.wait('state', (m) => m.members.some((x) => x.acked));
  const session = [...app.sessions.values()][0].ember.session;
  sim.say({ ...ZW, text: '第一句关于预算' });
  await until(() => session.ingest.metrics().utterances >= 1);
  sim.drop('media');
  await until(() => sim.stats.readyAcks >= 2, 5000, 'reconnected');
  await sim.waitReady();
  sim.say({ ...ZW, text: '第二句关于试点' });
  await until(() => session.ingest.metrics().utterances >= 2);
  assert.equal(session.ended, false, 'session survived the drop');
  const r = await sim.sendWebhook(`${app.url}/webhook`, { secret: CFG.webhookSecret, event: 'meeting.rtms_stopped' });
  assert.equal(r.status, 200);
  await a.wait('ended');
  await until(() => app.sessions.size === 0);
  assert.ok(events.some((e) => e.ev === 'rtms_stopped'));
});
