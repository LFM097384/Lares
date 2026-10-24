// 可选:真 LLM 的端到端(只在设置了 LARES_AI_LLM_KEY / LARES_AI_LLM_API_KEY 时跑;否则 skip)。
// 走 RTMS 模拟器 + 真 DeepSeek:转写 → IngestGate(L3 改写)→ 侧边栏提问 → 纪要 k 签名放行。断言只看「无名字、无单位」。
import test from 'node:test';
import assert from 'node:assert/strict';
import { client as approver } from '../../ember/test/helpers.mjs';
import { runEmberZoom, llmFromEnv } from '../index.mjs';
import { RtmsSim } from '../sim/rtms_sim.mjs';
import { sidebar, until } from './_util.mjs';

const HAS_KEY = Boolean(String(process.env.LARES_AI_LLM_API_KEY ?? process.env.LARES_AI_LLM_KEY ?? '').trim());
const CFG = { clientId: 'cid_real', clientSecret: 'csec_real', webhookSecret: 'whsec_real', port: 0, host: '127.0.0.1', k: 2, asrKind: 'zoom', postChat: false, lang: null, allowOrigins: null };
const ZW = { user_id: 501, user_name: '张伟' };
const LX = { user_id: 502, user_name: '李秀梅' };
const NAMES = /张伟|李秀梅/;
const ORG = /星辰科技|星辰/;

test('real LLM e2e (RTMS sim + DeepSeek)', { skip: HAS_KEY ? false : 'LARES_AI_LLM_KEY not set', timeout: 300_000 }, async (t) => {
  const llm = await llmFromEnv(process.env);
  const app = await runEmberZoom({ config: CFG, llm, asr: null, memoryDir: null, emit: () => {}, log: () => {}, sessionOpts: { ingestOpts: { batchMs: 200 } } });
  const sim = await new RtmsSim({ clientId: CFG.clientId, clientSecret: CFG.clientSecret, keepAliveMs: 5000 }).listen(0);
  const sbs = [];
  t.after(async () => { for (const s of sbs) s.close(); await app.stop(); await sim.close(); });
  const a = await sidebar(app.url, { meetingUuid: sim.meetingUuid, participantId: '501', screenName: ZW.user_name });
  const b = await sidebar(app.url, { meetingUuid: sim.meetingUuid, participantId: '502', screenName: LX.user_name });
  sbs.push(a, b);
  assert.equal((await sim.sendWebhook(`${app.url}/webhook`, { secret: CFG.webhookSecret })).status, 200);
  await sim.waitReady();
  sim.join([ZW, LX]);
  await a.wait('zoom_welcome', (m) => m.bound);
  await b.wait('zoom_welcome', (m) => m.bound);
  const ka = approver('zu_501'), kb = approver('zu_502');
  a.send({ t: 'ack', pubKey: ka.pubKey });
  b.send({ t: 'ack', pubKey: kb.pubKey });
  const st = await a.wait('state', (m) => m.members.filter((x) => x.acked).length === 2);
  await sim.play([
    { say: { ...ZW, text: '大家好，我是张伟，在星辰科技负责产品。我觉得下季度预算应该先做小范围试点，别一下子铺开。' } },
    { say: { ...LX, text: '我同意张伟，试点可以下周先在两个城市跑一下，预算控制在十万以内。' } },
    { say: { ...ZW, text: '那就定了：月底前复盘一次试点数据。' } },
  ]);
  const session = [...app.sessions.values()][0].ember.session;
  await until(() => session.ingest.metrics().utterances >= 3, 10_000);
  await session.ingest.flush();

  b.send({ t: 'ask', q: '刚才关于预算和试点达成了什么？' });
  const ans = await b.wait('answer', () => true, 120_000);
  t.diagnostic(`answer: ${ans.a}`);
  assert.doesNotMatch(ans.a, NAMES);
  assert.doesNotMatch(ans.a, ORG);

  a.send({ t: 'skill', name: 'minutes', args: {} });
  let cur = (await a.wait('draft', () => true, 120_000)).draft;
  for (const it of cur.items.filter((x) => x.roleRisk)) {
    a.send({ t: 'review', draftId: cur.draftId, itemId: it.id, action: 'cut' });
    cur = (await a.wait('draft', (m) => m.draft.draftHash !== cur.draftHash, 60_000)).draft;
  }
  a.send(ka.approve(st, cur));
  b.send(kb.approve(st, cur));
  const rel = await a.wait('released', () => true, 60_000);
  t.diagnostic(`released: ${rel.text.replace(/\n/g, ' | ')}`);
  assert.doesNotMatch(rel.text, NAMES);
  assert.doesNotMatch(rel.text, ORG);
  a.send({ t: 'end' });
  await a.wait('ended');
});
