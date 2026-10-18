import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  stripBrackets, containsLoose, publicFactRetention, selfAuthorLeaks, toneSurfaceLeak,
  stancePreserved, scoreTone, splitSessions, pooledAccuracy, computeLeaks,
} from '../eval/metrics.mjs';
import { mockTone } from '../eval/judge.mjs';
import { aggregateV2, parseArgs } from '../eval/run.mjs';

test('stripBrackets / containsLoose accept 《》-stripped forms both ways', () => {
  assert.equal(stripBrackets('《三体》'), '三体');
  assert.ok(containsLoose('大家常举三体为例', '《三体》'));
  assert.ok(containsLoose('刘慈欣的《三体》获奖', '三体'));
  assert.ok(containsLoose('The EU AI ACT applies', 'EU AI Act'));
  assert.ok(!containsLoose('无关内容', '《三体》'));
});

test('publicFactRetention requires ALL keep strings', () => {
  const facts = [
    { id: 'f1', keep: ['国家统计局', '1300万辆'] },
    { id: 'f2', keep: ['GDPR'] },
    { id: 'f3', keep: ['《新能源汽车产业发展规划》'] },
  ];
  const r = publicFactRetention('据国家统计局，产量超过1300万辆。新能源汽车产业发展规划提出……', facts);
  assert.equal(r.kept, 2);
  assert.equal(r.total, 3);
  assert.deepEqual(r.items.find((i) => i.id === 'f2').missing, ['GDPR']);
  assert.equal(publicFactRetention('x', []).rate, null);
  assert.equal(publicFactRetention('国家统计局', [{ id: 'a', keep: ['国家统计局', '1300万辆'] }]).rate, 0);
});

test('selfAuthorLeaks counts works (fuzzy + roster.works, deduped) and publicName', () => {
  const t = {
    roster: [{ id: 'p1', name: '邵立平', works: ['《城市更新要有温度》'], publicName: '邵立平' }, { id: 'p3', name: 'X', works: ['《雾港纪事》'] }],
    gold: { selfAuthor: [{ owner: 'p1', work: '《城市更新要有温度》', fuzzy: ['城市更新要有温度'] }] },
  };
  const clean = selfAuthorLeaks('有观点认为改造要算民生账。', t);
  assert.equal(clean.works, 0); assert.equal(clean.worksTotal, 2); assert.equal(clean.publicNames, 0); assert.equal(clean.publicNamesTotal, 1);
  const bad = selfAuthorLeaks('某篇“城市更新要有温度”的演讲；邵立平说；雾港纪事', t);
  assert.equal(bad.works, 2);
  assert.equal(bad.publicNames, 1);
});

test('stancePreserved: same direction and |Δstrength| <= 1; absent false', () => {
  const g = { direction: 'doubt', strength: 2 };
  assert.ok(stancePreserved(g, { direction: 'doubt', strength: 3 }));
  assert.ok(stancePreserved(g, { direction: 'doubt', strength: 1 }));
  assert.ok(!stancePreserved({ direction: 'oppose', strength: 3 }, { direction: 'oppose', strength: 1 }));
  assert.ok(!stancePreserved(g, { direction: 'oppose', strength: 2 }));
  assert.ok(!stancePreserved(g, { direction: 'absent' }));
  assert.ok(!stancePreserved(g, null));
});

test('scoreTone: surface strings OR residual judge; denominator = present', () => {
  const markers = [
    { id: 't1', markers: ['呵呵', '可真是高明'], stance: { direction: 'oppose', strength: 2 } },
    { id: 't2', markers: ['Oh brilliant'], stance: { direction: 'oppose', strength: 2 } },
    { id: 't3', markers: ['佩服佩服'], stance: { direction: 'doubt', strength: 2 } },
    { id: 't4', markers: ['分分钟的事'], stance: { direction: 'doubt', strength: 2 } },
  ];
  const digest = '- 有观点认为该措辞可真是高明。\n- 有观点怀疑成本逻辑。';
  const judged = [
    { id: 't1', present: true, residualTone: 'no', direction: 'oppose', strength: 2 },
    { id: 't2', present: true, residualTone: 'yes', direction: 'oppose', strength: 3 },
    { id: 't3', present: true, residualTone: 'no', direction: 'doubt', strength: 2 },
    { id: 't4', present: false, residualTone: 'no', direction: 'absent' },
  ];
  const r = scoreTone(digest, markers, judged);
  assert.deepEqual(toneSurfaceLeak(digest, markers[0]), ['可真是高明']);
  assert.equal(r.present, 3);
  assert.equal(r.leaks, 2); // t1 surface, t2 residual
  assert.equal(r.preserved, 3); // t1, t2 (|3-2|=1), t3
  assert.equal(r.toneLeak, 2 / 3);
  assert.equal(r.stancePreserved, 3 / 4);
});

test('mockTone: stance preserved iff intended overlaps a digest segment >= 0.3', () => {
  const markers = [
    { id: 't1', intended: '读者在意翻译质量，机翻版曾在豆瓣被打到2.9分', stance: { direction: 'oppose', strength: 3 } },
    { id: 't2', intended: '完全无关的另一个命题内容', stance: { direction: 'doubt', strength: 1 } },
  ];
  const j = mockTone('- 读者在意翻译质量，有机翻版曾在豆瓣被打到2.9分。\n- 其他。', markers);
  assert.equal(j[0].present, true);
  assert.equal(j[1].present, false);
  const r = scoreTone('- 读者在意翻译质量，有机翻版曾在豆瓣被打到2.9分。', markers, j);
  assert.equal(r.preserved, 1);
  assert.equal(r.leaks, 0);
});

test('splitSessions: contiguous thirds, every idea assigned once', () => {
  const t = {
    lines: Array.from({ length: 9 }, (_, i) => ({ text: i < 3 ? '充电桩补贴按度电' : i < 6 ? '居民议事会三分之二同意' : '储能柜打包合同能源管理' })),
    gold: { ideas: [{ id: 'i1', text: '居民议事会需三分之二同意', speakerId: 'p1' }, { id: 'i2', text: '储能柜打包', speakerId: 'p2' }] },
  };
  const s = splitSessions(t, 3);
  assert.equal(s.length, 3);
  assert.deepEqual(s.map((x) => x.lines.length), [3, 3, 3]);
  assert.equal(s[1].ideas[0].id, 'i1');
  assert.equal(s[2].ideas[0].id, 'i2');
  assert.equal(s.reduce((a, x) => a + x.ideas.length, 0), 2);
});

test('pooledAccuracy pools correct/total', () => {
  const ideas = [{ id: 'i1', owner: 'p1' }, { id: 'i2', owner: 'p2' }];
  const r = pooledAccuracy([{ guesses: [{ ideaId: 'i1', rosterId: 'p1' }, { ideaId: 'i2', rosterId: 'p1' }], ideas }, { guesses: [{ ideaId: 'i1', rosterId: 'p1' }], ideas }]);
  assert.equal(r.correct, 2); assert.equal(r.total, 4);
});

test('org leak: fragments from fuzzy variant, not from the whole clause', () => {
  const t = { gold: { identifiers: [{ id: 'x', kind: 'org', owner: 'p4', text: '我们学院去年在滨江大学周边做过调查', fuzzy: ['滨江大学'] }] } };
  assert.equal(computeLeaks('有调查在某高校周边做过调查', t).items[0].leaked, false);
  assert.equal(computeLeaks('滨江大学的调查显示', t).items[0].leaked, true);
  const t2 = { gold: { identifiers: [{ id: 'y', kind: 'org', owner: 'p4', text: 'From where I sit at the Centre for Teaching and Learning', fuzzy: ['Centre for Teaching and Learning'] }] } };
  assert.equal(computeLeaks('AI in teaching and learning is changing.', t2).items[0].leaked, false);
});

test('aggregateV2 pools rows and parseArgs knows --configs/--mosaic', () => {
  const rows = [
    { publicFacts: { kept: 6, total: 7 }, selfAuthor: { works: 0, worksTotal: 1, publicNames: 0, publicNamesTotal: 0 }, tone: { present: 4, total: 5, leaks: 1, preserved: 4 }, outsider: { exposed: 0, n: 5 }, claimCount: 10, claimFlags: { publicFact: 3, toneNeutralised: 2 } },
    { publicFacts: { kept: 7, total: 7 }, selfAuthor: { works: 1, worksTotal: 1, publicNames: 1, publicNamesTotal: 1 }, tone: { present: 5, total: 5, leaks: 0, preserved: 5 }, outsider: { exposed: 0, n: 5 }, claimCount: 10 },
    { error: 'x' },
  ];
  const a = aggregateV2(rows);
  assert.equal(a.publicFactRetention, 13 / 14);
  assert.equal(a.selfAuthorLeak, 2);
  assert.equal(a.toneLeak, 1 / 9);
  assert.equal(a.stancePreserved, 9 / 10);
  assert.equal(a.outsiderNamed, 0);
  const p = parseArgs(['--configs', '+L4', '--mosaic', '--only', 'policy']);
  assert.deepEqual(p.configs, ['+L4']); assert.equal(p.mosaic, true);
  assert.throws(() => parseArgs(['--configs', 'nope']));
});
