// 端到端(无浏览器、无网络):FakeBridge → jitsiPort → createEmber(MockAsr、llm:null 确定性路径)→ 会议聊天。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { MockAsr, audio, generateEd25519, signEd25519, approvalMessage } from '../../ember/index.mjs';
import { runEmberJitsi } from '../index.mjs';
import { FakeBridge, until, tick, allFiles } from './_util.mjs';

const NAMES = /张伟|李秀梅|王强|秀梅/;
const ORG = /星辰科技|星辰/;
const SAY = {
  a: ['我是张伟，在星辰科技负责产品，我们决定下个月开始读书会', '读书会每周三晚上见面'],
  b: ['我是李秀梅，同意读书会，先读三体', '预算控制在五百元以内'],
  c: ['我是王强，我反对这个安排', '王强觉得周末更好'],
};
const UTTER = Object.values(SAY).flat();

/// 一句话:1.5 s 正弦(10 ms 帧)+ 1.2 s 静音,16 kHz
function speak(bridge, id) {
  const on = audio.tone(16000, 1500, { amp: 8000 });
  for (let i = 0; i + 160 <= on.length; i += 160) bridge.audio(id, on.subarray(i, i + 160), 16000);
  for (let i = 0; i < 120; i++) bridge.audio(id, new Int16Array(160), 16000);
}

async function start(t, { k = 2 } = {}) {
  const memoryDir = mkdtempSync(path.join(os.tmpdir(), 'ember-jitsi-e2e-'));
  const bridge = new FakeBridge();
  const asr = new MockAsr({ script: (id, n) => (SAY[id] ?? ['你好'])[n % 2] });
  const logs = [];
  const events = [];
  const bot = await runEmberJitsi({
    room: 't', bridge, llm: null, asr, memoryDir, k, env: {},
    log: (m) => logs.push(String(m)), emit: (e) => events.push(e),
    sessionOpts: { ingestOpts: { batchMs: 20 } },
  });
  t.after(async () => { await bot.stop(0); rmSync(memoryDir, { recursive: true, force: true }); });
  return { bot, bridge, asr, memoryDir, logs, events, session: bot.ember.session };
}

test('e2e: ack gate → ask private → minutes k-of-n in chat → memory retract leaves no trace → convener ends', async (t) => {
  const { bot, bridge, memoryDir, logs, events, session } = await start(t);
  assert.equal(bridge.joins, 1);
  assert.match(bridge.public[0], /同意/, 'rules announced publicly on join');
  assert.ok(events.some((e) => e.ev === 'ready' && e.room === 't' && e.llm === false && e.k === 2));

  bridge.participant('a', '张伟'); // 第一个进来 = 召集人
  bridge.participant('b', '李秀梅');
  bridge.participant('c', '王强');
  bridge.participant('rec', 'Jibri', true);
  await until(() => session.present.size === 3, 2000, 'present');
  assert.equal(session.convenerId, 'a');
  assert.ok(!session.present.has('rec'), 'hidden participant is not a member');

  bridge.chat('a', '@炉灵 同意');
  bridge.chat('b', '同意', true); // 私信不用 @
  await until(() => session.acked.size === 2, 2000, 'acks');
  await until(() => bridge.public.some((p) => /已同意 2 人/.test(p)), 2000, 'ack count public');

  // 王强还没同意:他的声音在转写之前丢掉
  speak(bridge, 'c');
  assert.ok(session.counts.droppedUnackedFrames > 0, 'unacked audio dropped');
  assert.equal(session.speakers.has('c'), false);

  for (const id of ['a', 'b']) speak(bridge, id);
  await until(() => session.counts.utterances >= 2, 4000, 'utterances');
  for (const id of ['a', 'b']) speak(bridge, id);
  await until(() => session.counts.utterances >= 4, 4000, 'utterances 2');
  await session.ingest.flush();
  const ledger = session.ingest.ledgerView().entries();
  assert.ok(ledger.length >= 2, 'ledger filled');
  for (const e of ledger) { assert.doesNotMatch(e.text, NAMES); assert.doesNotMatch(e.text, ORG); }

  bridge.chat('c', '@炉灵 同意');
  await until(() => session.acked.size === 3, 2000, 'c acked');

  // 提问:答案只私信给已同意的人
  const pubBefore = bridge.public.length;
  bridge.chat('b', '@炉灵 问 读书会什么时候开始');
  await until(() => ['a', 'b', 'c'].every((id) => bridge.privTo(id).some((x) => x.includes('【炉灵·回答】'))), 3000, 'answer');
  for (const id of ['a', 'b', 'c']) {
    const ans = bridge.privTo(id).find((x) => x.includes('【炉灵·回答】'));
    assert.match(ans, /读书会/, 'answer draws on the ledger');
    assert.doesNotMatch(ans, NAMES);
    assert.doesNotMatch(ans, ORG);
  }
  assert.ok(!bridge.public.slice(pubBefore).some((x) => x.includes('回答')), 'answer never public');

  // 纪要草稿 → 私信
  bridge.chat('a', '@炉灵 纪要');
  await until(() => bridge.privTo('a').some((x) => x.includes('纪要草稿 D1')), 3000, 'draft');
  const draftText = bridge.privTo('a').find((x) => x.includes('纪要草稿 D1'));
  assert.ok(bridge.privTo('b').some((x) => x.includes('纪要草稿 D1')));
  assert.ok(!bridge.public.some((x) => x.includes('纪要草稿 D1】')), 'draft never public');
  assert.doesNotMatch(draftText, NAMES);
  assert.doesNotMatch(draftText, ORG);
  // 有 ⚠ 条目就逐条泛化(否则 fail-closed 不出门)
  const [d] = [...session.drafts.values()];
  assert.ok(d.items.length >= 1, 'draft has items');
  for (let i = d.items.length; i >= 1; i--) {
    if (d.items[i - 1].roleRisk) {
      const h = d.draftHash;
      bridge.chat('a', `@炉灵 泛化 D1 ${i}`);
      await until(() => d.draftHash !== h, 2000, 'review');
    }
  }
  assert.ok(d.items.some((x) => !x.roleRisk), 'at least one releasable item');

  // 1/2:不放行
  bridge.chat('a', '@炉灵 批准 D1');
  await until(() => bridge.public.some((x) => /D1 已获 1\/2 人批准,未放行/.test(x)), 2000, '1/2');
  bridge.chat('a', '@炉灵 批准'); // 同一人再批(缺省最新草稿)
  await until(() => bridge.public.filter((x) => /D1 已获 1\/2 人批准,未放行/.test(x)).length >= 2, 2000, '1/2 again');
  await tick(50);
  assert.equal(session.counts.releases, 0, 'same human twice is still 1');
  assert.ok(!bridge.public.some((x) => x.includes('已放行纪要')));

  bridge.chat('b', '批准 D1', true);
  const rel = await until(() => bridge.public.find((x) => x.includes('已放行纪要 D1')), 3000, 'released');
  assert.doesNotMatch(rel, NAMES, 'released: no names');
  assert.doesNotMatch(rel, ORG, 'released: no org');
  assert.ok(!rel.includes(SAY.a[0]), 'self-introduction never verbatim'); // 无 LLM 的 mock 改写对中性句不改字,这是确定性路径的预期
  await until(() => events.some((e) => e.ev === 'host' && e.type === 'released' && e.items >= 1), 2000, 'host released');

  // 记忆 → 私信列表
  bridge.chat('c', '@炉灵 记忆');
  await until(() => bridge.privTo('c').some((x) => x.includes('本圈记忆') && /M1\./.test(x)), 2000, 'mem list');
  const memItem = [...session.memory ? (await session.memory.list()) : []].find((x) => !x.retracted);
  assert.ok(memItem, 'released item in memory');
  assert.ok(allFiles(memoryDir).some((f) => readFileSync(f, 'utf8').includes(memItem.text)), 'memory written to disk');

  // 撤回:王强没批准 → 拒绝;张伟批准过 → 撤回,文件零痕迹
  bridge.chat('c', '@炉灵 撤回 M1');
  await until(() => bridge.privTo('c').some((x) => /只有当时批准这条的人能撤回/.test(x)), 2000, 'retract rejected');
  assert.ok(!bridge.public.some((x) => x.includes('已撤回')));
  bridge.chat('a', '@炉灵 撤回 M1');
  await until(() => bridge.public.some((x) => /记忆 M1 已撤回/.test(x)), 3000, 'retracted');
  for (const f of allFiles(memoryDir)) assert.ok(!readFileSync(f, 'utf8').includes(memItem.text), `retracted text still in ${path.relative(memoryDir, f)}`);

  // 散会:非召集人被拒,召集人 → 公开回执 + 离会 + done = 0
  bridge.chat('b', '@炉灵 结束');
  await until(() => bridge.privTo('b').some((x) => /只有召集人能散会/.test(x)), 2000, 'not convener');
  assert.equal(session.ended, false);
  bridge.chat('a', '@炉灵 结束');
  assert.equal(await bot.done, 0);
  assert.ok(bridge.public.some((x) => /散会。放行 1 份纪要/.test(x)));
  assert.equal(bridge.leaves, 1);
  assert.ok(events.some((e) => e.ev === 'ended'));

  // 公开聊天里绝无名字 / 单位 / 原话
  for (const p of bridge.public) { assert.doesNotMatch(p, NAMES); assert.doesNotMatch(p, ORG); }
  // 日志 / stdout 事件卫生
  const blob = `${logs.join('\n')}\n${JSON.stringify(events)}`;
  assert.doesNotMatch(blob, NAMES, 'no names in logs/events');
  assert.doesNotMatch(blob, ORG, 'no org in logs/events');
  for (const u of UTTER) assert.ok(!blob.includes(u), 'no utterance in logs/events');
  assert.doesNotMatch(blob, /读书会|三体|预算/, 'no utterance fragments in logs/events');
  const finals = events.filter((e) => e.ev === 'asr_final');
  assert.ok(finals.length >= 4);
  for (const f of finals) assert.deepEqual(Object.keys(f).sort(), ['chars', 'endpoint', 'ev']);
  assert.ok(!finals.some((f) => f.endpoint === 'c'), 'unacked speaker never reached ASR');
});

test('e2e: self-held key via EMBER1 envelopes counts toward k; custodial 批准 refused for it', async (t) => {
  const { bot, bridge, session } = await start(t);
  bridge.participant('a', '张伟');
  bridge.participant('z', 'Zed');
  const kp = generateEd25519();
  bridge.chat('a', '@炉灵 同意');
  bridge.chat('z', `EMBER1 ${JSON.stringify({ t: 'ack', pubKey: kp.pubB64 })}`, true);
  await until(() => session.acked.size === 2, 2000, 'acks');
  const st = await until(() => bridge.envelopesTo('z').filter((m) => m.t === 'state').find((m) => m.members.filter((x) => x.acked).length === 2), 2000, 'state envelope');
  assert.equal(st.sid, session.sid);
  assert.equal(bridge.envelopesTo('a').length, 0, 'custodial users get no envelopes');
  assert.equal(bot.port._debug().selfKeyed, 1);

  bridge.chat('z', '同意', true);
  await until(() => bridge.privTo('z').some((x) => /你已用自己的密钥同意过/.test(x)), 2000, 'double ack refused');

  speak(bridge, 'a');
  await until(() => session.counts.utterances >= 1, 4000, 'utterance');
  bridge.chat('a', '@炉灵 纪要');
  const dm = await until(() => bridge.envelopesTo('z').find((m) => m.t === 'draft'), 3000, 'draft envelope');
  let draft = dm.draft;
  // 风险条目逐条泛化(自持密钥客户端用信封)
  for (const it of draft.items.filter((x) => x.roleRisk)) {
    bridge.chat('z', `EMBER1 ${JSON.stringify({ t: 'review', draftId: draft.draftId, itemId: it.id, action: 'generalise' })}`, true);
    const prev = draft.draftHash;
    draft = (await until(() => bridge.envelopesTo('z').filter((m) => m.t === 'draft').map((m) => m.draft).find((x) => x.draftHash !== prev && x.draftId === draft.draftId), 2000, 'reviewed')).draft ?? draft;
  }
  draft = bridge.envelopesTo('z').filter((m) => m.t === 'draft').at(-1).draft;

  bridge.chat('z', '批准 D1', true);
  await until(() => bridge.privTo('z').some((x) => /自持密钥/.test(x) && /EMBER1 approve/.test(x)), 2000, 'custodial approve refused');
  assert.equal(session.counts.approvals, 0);

  const nonce = 'nonce-z-1';
  const sig = signEd25519(kp.privateKey, approvalMessage({ sid: st.sid, draftId: draft.draftId, draftHash: draft.draftHash, nonce }));
  bridge.chat('z', `EMBER1 ${JSON.stringify({ t: 'approve', draftId: draft.draftId, draftHash: draft.draftHash, nonce, sig })}`, true);
  await until(() => bridge.public.some((x) => /D1 已获 1\/2 人批准/.test(x)), 2000, 'z approval counted');
  assert.ok(bridge.envelopesTo('z').some((m) => m.t === 'approvals' && m.count === 1));

  // 坏签名:错误以信封 + 文字私信回去
  bridge.chat('z', `EMBER1 ${JSON.stringify({ t: 'approve', draftId: draft.draftId, draftHash: draft.draftHash, nonce: 'n2', sig: sig.replace(/^./, sig[0] === 'A' ? 'B' : 'A') })}`, true);
  await until(() => bridge.envelopesTo('z').some((m) => m.t === 'error' && m.code === 'bad_sig'), 2000, 'bad sig envelope');
  assert.ok(bridge.privTo('z').some((x) => /签名无效/.test(x)));

  bridge.chat('a', '@炉灵 批准 D1');
  await until(() => bridge.public.some((x) => x.includes('已放行纪要 D1')), 3000, 'released');
  assert.ok(bridge.envelopesTo('z').some((m) => m.t === 'released'));
  assert.equal(session.counts.releases, 1);
  await bot.stop(0);
  assert.equal(bridge.leaves, 1);
});

test('e2e: bridge disconnect → stop with crash code; last human leaving ends session', async (t) => {
  {
    const { bot, bridge } = await start(t);
    bridge.participant('a', '张伟');
    bridge.disconnect('conference_failed');
    assert.equal(await bot.done, 1);
    assert.equal(bridge.leaves, 1);
  }
  {
    const { bot, bridge, session } = await start(t);
    bridge.participant('a', '张伟');
    await until(() => session.present.size === 1);
    bridge.left('a');
    assert.equal(await bot.done, 0);
    assert.equal(session.ended, true);
    assert.equal(bridge.leaves, 1);
  }
});
