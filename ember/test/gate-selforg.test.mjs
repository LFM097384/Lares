// Session-learned self-declared organisations: a participant who says "我是张伟，在星辰科技负责产品" told the room
// their org; it must be redacted in every utterance of that session (theirs and others'), deterministically.
import test from 'node:test';
import assert from 'node:assert/strict';
import { redactPII } from '../core/gate/l1.mjs';
import { redactAffiliation, learnSelfOrgs, withLearnedOrgs } from '../core/gate/l2.mjs';
import { runGate } from '../core/gate/gate.mjs';
import { createSession } from '../core/index.mjs';
import { createIngestGate } from '../agent/ingest_gate.mjs';

const A_SAYS = '大家好，我是张伟，在星辰科技负责产品。今天想聊聊下半年团队的读书计划。';
const B_SAYS = '呵呵，星辰科技可真行，上个季度的项目又延期了三个月，真是厉害了，佩服佩服。';
// Lares-style roster: names only, no org
const NAMES = [{ id: 'a', name: '张伟' }, { id: 'b', name: '李秀梅' }];
const L12 = (s, r) => redactAffiliation(redactPII(s, r), r);

test('learnSelfOrgs: zh / en self-declarations', () => {
  const cases = [
    [A_SAYS, '星辰科技'], ['我在星辰科技负责产品', '星辰科技'], ['我目前在星辰科技工作。', '星辰科技'],
    ['我是星辰科技的产品经理', '星辰科技'], ['我来自星辰科技。', '星辰科技'], ['我们星辰科技一直这么做', '星辰科技'],
    ['我叫李雷，目前就职于远山资本。', '远山资本'], ['I work at Starfield Labs as a PM.', 'Starfield Labs'],
    ["I'm at Starfield Labs.", 'Starfield Labs'], ["I'm from Starfield Labs", 'Starfield Labs'], ['We at Starfield Labs disagree.', 'Starfield Labs'],
  ];
  for (const [s, org] of cases) assert.deepEqual(learnSelfOrgs(s), [org], s);
});

test('learnSelfOrgs: generic / weak cues are not learned', () => {
  for (const s of [B_SAYS, '我们公司最近很忙', '我在家工作', '我在这边负责', '我在一家科技公司上班', '我现在在北京工作', '我是做产品的',
    '我在会上说过', '我在读世界银行的报告', '我们世界银行一直这么做', '我在清华的时候做过', "I'm from Beijing", 'I work at home',
    'I worked at Google for years.', '星辰科技发布了新产品。', '《三体》是刘慈欣写的']) {
    assert.deepEqual(learnSelfOrgs(s), [], s);
  }
});

test('withLearnedOrgs folds orgs into the speaker entry (or a name-less entry)', () => {
  const r = withLearnedOrgs(NAMES, new Map([['a', new Set(['星辰科技'])], ['zz', ['远山资本']]]));
  assert.equal(r.find((p) => p.id === 'a').org, '星辰科技');
  assert.deepEqual(r.find((p) => p.id === 'zz'), { id: 'zz', org: '远山资本' });
  assert.equal(NAMES[0].org, undefined, 'input roster not mutated');
  assert.equal(withLearnedOrgs(NAMES, new Map()), NAMES);
});

test('single utterance: self-declared org redacted in that utterance (L2 alone)', () => {
  const out = L12(A_SAYS, NAMES);
  assert.ok(!out.includes('星辰'), out);
  assert.ok(!out.includes('张伟'), out);
  assert.ok(out.includes('读书计划'), out);
  const en = L12("Hi, I'm Dana. I work at Starfield Labs; Starfield Labs ships slowly.", []);
  assert.ok(!en.includes('Starfield'), en);
});

test('runGate (mock): A declares, B mentions → no 星辰 anywhere in digest / claims', async () => {
  for (const lines of [
    [{ speakerId: 'a', speakerName: '张伟', text: A_SAYS }, { speakerId: 'b', speakerName: '李秀梅', text: B_SAYS }],
    [{ speakerId: 'b', speakerName: '李秀梅', text: B_SAYS }, { speakerId: 'a', speakerName: '张伟', text: A_SAYS }], // mention BEFORE the declaration
  ]) {
    const g = await runGate({ roster: NAMES, sessionDate: '2026-10-01', lines }, { llm: null });
    const all = g.digest + g.digestStrict + JSON.stringify(g.claims);
    assert.ok(!all.includes('星辰'), g.digest);
    assert.ok(g.digest.includes('延期'), g.digest);
  }
});

test('runGate (mock): English declaration redacted in another speaker line', async () => {
  const lines = [
    { speakerId: 'a', speakerName: 'Dana Reyes', text: "Hi all, I'm Dana and I work at Starfield Labs on the product side." },
    { speakerId: 'b', speakerName: 'Tom Hale', text: 'Starfield Labs delayed their roadmap again by three months.' },
  ];
  const g = await runGate({ roster: [{ id: 'a', name: 'Dana Reyes' }, { id: 'b', name: 'Tom Hale' }], sessionDate: '2026-10-01', lines }, { llm: null });
  assert.ok(!g.digest.includes('Starfield'), g.digest);
  assert.ok(/roadmap/.test(g.digest), g.digest);
});

test('negative: no self-declaration → unknown org mentioned once is kept; public facts kept', async () => {
  const lines = [
    { speakerId: 'a', speakerName: '张伟', text: '星辰科技上个季度发布了新产品，评价不错。' },
    { speakerId: 'b', speakerName: '李秀梅', text: '《三体》是刘慈欣写的，世界银行的公开报告也提过。' },
  ];
  const g = await runGate({ roster: NAMES, sessionDate: '2026-10-01', lines }, { llm: null });
  assert.ok(g.digest.includes('星辰科技'), g.digest);
  assert.match(g.digest, /《三体》是刘慈欣写的/);
  assert.match(g.digest, /世界银行的公开报告/);
});

test('public facts survive alongside a learned org', async () => {
  const lines = [
    { speakerId: 'a', speakerName: '张伟', text: A_SAYS },
    { speakerId: 'b', speakerName: '李秀梅', text: '《三体》是刘慈欣写的，世界银行的公开报告也引用过。' },
  ];
  const g = await runGate({ roster: NAMES, sessionDate: '2026-10-01', lines }, { llm: null });
  assert.match(g.digest, /《三体》是刘慈欣写的/);
  assert.match(g.digest, /世界银行的公开报告/);
  assert.ok(!g.digest.includes('星辰'), g.digest);
});

test('createSession.draft: learned org applies to the whole buffer (incl. outside the draft window)', async () => {
  const s = createSession({ sid: 'so', roster: NAMES, policy: { k: 1 } });
  s.ingest({ speakerId: 'a', text: A_SAYS, ts: 1 });
  s.ingest({ speakerId: 'b', text: B_SAYS, ts: 2 });
  const d = await s.draft();
  assert.ok(!JSON.stringify(d.items).includes('星辰'), JSON.stringify(d.items));
  const d2 = await s.draft({ fromTs: 2 }); // only B's line selected; A's declaration still applies
  assert.ok(d2.items.length && !JSON.stringify(d2.items).includes('星辰'), JSON.stringify(d2.items));
  s.end();
});

test('IngestGate (Lares path): declaration before AND after the mention; buffered + ledger re-scrubbed', async () => {
  for (const order of [['a', 'b'], ['b', 'a']]) {
    const g = createIngestGate({ roster: () => NAMES, batchMs: 10_000, setTimer: () => null, clearTimer: () => {} });
    const say = { a: A_SAYS, b: B_SAYS };
    g.utterance(order[0], say[order[0]]);
    if (order[0] === 'b') await g.flush(); // B's line already in the ledger when A declares
    g.utterance(order[1], say[order[1]]);
    assert.ok(!JSON.stringify(g._pending()).includes('星辰'), JSON.stringify(g._pending()));
    await g.flush();
    const txt = g.ledgerView().text();
    assert.ok(!txt.includes('星辰'), txt);
    assert.ok(txt.includes('延期'), txt);
    assert.equal(g.gateRoster().find((p) => p.id === 'a').org, '星辰科技');
    g.wipe();
    assert.equal(g.gateRoster().find((p) => p.id === 'a').org, undefined, 'learned orgs wiped');
  }
});
