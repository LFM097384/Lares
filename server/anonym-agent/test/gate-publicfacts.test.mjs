// Gate v2 §1 "public facts": world knowledge kept unless it points back to a participant / their org.
import test from 'node:test';
import assert from 'node:assert/strict';
import { redactPII } from '../core/gate/l1.mjs';
import { redactAffiliation } from '../core/gate/l2.mjs';
import { runGate } from '../core/gate/gate.mjs';

const L12 = (s, roster, opts) => redactAffiliation(redactPII(s, roster, opts), roster, opts);
const generic = [
  { id: 'p1', name: '王建国', aliases: ['老王'], org: '某某研究院', title: '研究员' },
  { id: 'p2', name: 'Sarah Whitfield', aliases: ['Sarah'], org: 'Hollis Family Trust', title: 'Program Officer' },
];

test('《三体》是刘慈欣写的 survives L1+L2 with a generic roster', () => {
  assert.equal(L12('《三体》是刘慈欣写的', generic), '《三体》是刘慈欣写的');
  assert.equal(L12('大家都爱拿刘慈欣的《三体》举例。', generic), '大家都爱拿刘慈欣的《三体》举例。');
  assert.equal(L12('鲁迅说过的话今天还适用。', generic), '鲁迅说过的话今天还适用。');
  const en = L12("Orwell's essay and George Orwell's book 1984 are often cited.", generic);
  assert.ok(en.includes('George Orwell'), en);
});

test('public laws / policies / public institutions survive', () => {
  for (const s of ['世界银行的公开报告显示贫困率下降。', 'CBAM在WTO框架下有GATT第20条的空间。', '2021年施行的新修订《著作权法》没有明确规定。', 'The World Bank published a report.', 'Google released a model last week.']) {
    assert.equal(L12(s, generic), s, s);
  }
});

test('我在清华的时候 redacts 清华', () => {
  const out = L12('我在清华的时候做过类似研究。', generic);
  assert.ok(!out.includes('清华'), out);
});

test('我们世界银行 redacted; I worked at Google redacted', () => {
  const out = L12('我们世界银行一直这么做。', generic);
  assert.ok(!out.includes('世界银行'), out);
  const out2 = L12('我上个月刚从MD安德森进修回来。', generic);
  assert.ok(!out2.includes('MD安德森'), out2);
  const en = L12('I worked at Google for years. Google released a report.', generic);
  assert.ok(!/I worked at Google/.test(en), en);
  assert.ok(en.includes('Google released a report'), en);
});

test('roster member works → title redacted wherever it appears', () => {
  const roster = [...generic, { id: 'p3', name: '苏曼宁', org: '自由撰稿人', title: '小说家', works: ['《沉默的河》'] }];
  const out = L12('《沉默的河》这本书写得好。', roster);
  assert.ok(!out.includes('沉默的河'), out);
  assert.ok(out.includes('[某作品]'), out);
  const en = L12('Everyone read The Salt Archive.', [{ id: 'p1', name: 'Ingrid Solberg', org: 'Halden University', works: ['The Salt Archive'] }]);
  assert.ok(!en.includes('Salt Archive'), en);
});

test('我那本书《边城往事》里写过 → title redacted even if not on roster', () => {
  const out = L12('我那本书《边城往事》里写过这个。', generic);
  assert.ok(!out.includes('边城往事'), out);
  assert.ok(L12('拙作《边城往事》也提过。', generic).includes('[某作品]'));
  assert.ok(!L12('《边城往事》是我写的。', generic).includes('边城往事'));
  const en = L12('In my book "The Quiet River" I argued the opposite.', generic);
  assert.ok(!en.includes('Quiet River'), en);
  // A third-party title is kept
  assert.ok(L12('他那本《边城往事》挺好。', generic).includes('《边城往事》'));
});

test('roster publicName is participant identity even if a public figure', () => {
  const roster = [{ id: 'p1', name: '刘慈欣', publicName: '大刘', org: '某某研究院' }];
  const out = L12('《三体》是刘慈欣写的，大刘很低调。', roster);
  assert.ok(!out.includes('刘慈欣') && !out.includes('大刘'), out);
});

test('roster org fragment still redacted; KNOWN_ORGS in roster org redacted everywhere', () => {
  assert.ok(!L12('某某研究院的数据显示增长放缓。', generic).includes('某某研究院'));
  const r = [{ id: 'p1', name: '张三', org: '清华大学公共管理学院' }];
  for (const s of ['清华的报告说', '清华大学发布了政策']) assert.ok(!L12(s, r).includes('清华'), s);
  const r2 = [{ id: 'p1', name: '李四', org: '中国人民大学环境学院' }];
  assert.ok(!L12('人大的老师也同意', r2).includes('人大'));
});

test('private third parties in strong contexts are still redacted', () => {
  const out = L12('患者赵立新，男，61岁。宝武的李卫东副总说贵。', generic);
  assert.ok(!out.includes('赵立新') && !out.includes('李卫东'), out);
});

test('allowPublicFacts:false restores prototype behaviour', () => {
  const off = { allowPublicFacts: false };
  assert.ok(!L12('世界银行的公开报告显示', generic, off).includes('世界银行'));
  assert.ok(!L12('刘慈欣老师写的书', generic, off).includes('刘慈欣'));
  assert.ok(L12('刘慈欣老师写的书', generic).includes('刘慈欣'));
});

test('runGate mock keeps public facts end-to-end and threads allowPublicFacts', async () => {
  const t = { roster: generic, sessionDate: '2026-10-01', lines: [
    { speakerId: 'p1', speakerName: '王建国', text: '《三体》是刘慈欣写的，世界银行的公开报告也引用过。' },
    { speakerId: 'p2', speakerName: 'Sarah Whitfield', text: '我们世界银行没有这个说法。' },
  ] };
  const g = await runGate(t, { llm: null });
  assert.match(g.digest, /《三体》是刘慈欣写的/);
  assert.match(g.digest, /世界银行的公开报告/);
  assert.equal((g.digest.match(/世界银行/g) || []).length, 1, g.digest);
  assert.equal(g.meta.allowPublicFacts, true);
  const g2 = await runGate(t, { llm: null, allowPublicFacts: false });
  assert.ok(!g2.digest.includes('世界银行'), g2.digest); // (prototype never caught "是刘慈欣写的" either)
});
