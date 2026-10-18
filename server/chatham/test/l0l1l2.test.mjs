import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { structural, mulberry32 } from '../lib/l0.mjs';
import { redactPII, detectPII } from '../lib/l1.mjs';
import { redactAffiliation, orgFragments } from '../lib/l2.mjs';

const roster = [
  { id: 'p1', name: '陈志远', aliases: ['陈主任', '老陈', '志远'], org: '中国医学科学院肿瘤医院胸外科', title: '主任医师' },
  { id: 'p2', name: 'Sarah Whitfield', aliases: ['Sarah', 'Ms. Whitfield'], org: 'Hollis Family Trust', title: 'Asia Program Officer' },
  { id: 'p3', name: '赵磊', aliases: ['磊哥', 'Leo', 'JG'], org: '极光数栈科技', title: 'CTO' },
];

test('L0: drops speakers/timestamps, deterministic, reorders', () => {
  const lines = Array.from({ length: 12 }, (_, i) => ({ speakerId: 'p' + (i % 3), speakerName: ['陈志远', 'Sarah', '赵磊'][i % 3], ts: `2026-09-01T09:0${i % 10}:00+08:00`, text: `第${i}个观点：定价方案${i % 2 ? '按席位' : '按用量'}收费，毛利率${30 + i}%。` }));
  const a = structural(lines, { seed: 7 }), b = structural(lines, { seed: 7 });
  assert.deepEqual(a, b);
  const flat = a.flatMap((c) => c.segments);
  assert.equal(flat.length, 12);
  const s = JSON.stringify(a);
  assert.ok(!/陈志远|Sarah|赵磊|2026-09-01T|speaker/.test(s));
  assert.notDeepEqual(flat, lines.map((l) => l.text));
  assert.ok(a.every((c) => /^T\d+$/.test(c.topic)));
  assert.equal(typeof mulberry32(1)(), 'number');
});

test('L1: phones / emails / ids / urls / handles / dates / addresses', () => {
  const cases = [
    ['电话139-1024-5867找我', '[电话]'], ['call +1 415-555-0187 now', '[phone]'], ['+86 10 5192 4000', '[电话]'], ['手机13800138000', '[电话]'], ['座机010-65123456', '[电话]'],
    ['mail kzhao@meridian-ai.com please', '[email]'], ['身份证110105196503127719', '[证件号]'], ['see github.com/linxy-eval/gsm-para', '[link]'],
    ['微博链接是 weibo.com/u/5832017746', '[链接]'], ['https://x.com/abc?x=1', '[link]'], ['ping @tomas_ech on it', '[handle]'], ['关注@胸外老陈', '[账号]'],
    ['我3月12日刚入职', '[日期]'], ['I defended on March 12 last year', '[date]'], ['2026-09-14开会', '[日期]'],
    ['住在北京市朝阳区安贞里三区12号楼2单元501', '[地址]'], ['office at Universitätstrasse 6, 8092 Zürich today', '[address]'],
  ];
  for (const [inp, ph] of cases) { const out = redactPII(inp, roster); assert.ok(out.includes(ph), `${inp} -> ${out}`); }
  assert.ok(!redactPII('kzhao@meridian-ai.com', roster).includes('@meridian'));
});

test('L1: roster names, aliases, surname+honorific, 老X', () => {
  const out = redactPII('陈主任说，志远和陈总都觉得老陈对。Thanks, Sarah. Ms. Whitfield agreed; Leo and JG too. 磊哥呢？赵工也在。', roster);
  for (const n of ['陈主任', '志远', '陈总', '老陈', 'Sarah', 'Whitfield', 'Leo', 'JG', '磊哥', '赵工']) assert.ok(!out.includes(n), `${n} leaked: ${out}`);
});

test('L1: no false positives on common words and numbers', () => {
  const s = '总体来说，总结一下：成本下降35%，融资3000万，2019年的数据，Q3目标，老师们辛苦了。The grant was approved.';
  const out = redactPII(s, [...roster, { id: 'p4', name: 'Michael Grant', aliases: ['Mike'] }]);
  assert.ok(out.includes('总体来说') && out.includes('总结') && out.includes('35%') && out.includes('3000万') && out.includes('2019年') && out.includes('Q3'), out);
  assert.ok(out.includes('The grant was approved'), out);
});

test('L1: third-party names in context', () => {
  const out = redactPII('病例是赵立新，男，61岁。宝武的李卫东副总说贵。质量副总刘振华签字。Dr. Okafor and Priya Raman agreed.', []);
  for (const n of ['赵立新', '李卫东', '刘振华', 'Okafor', 'Priya Raman']) assert.ok(!out.includes(n), `${n}: ${out}`);
  assert.ok(detectPII('Mr. Smith', []).length === 1);
});

test('L2: roster org fragments and titles', () => {
  const f = orgFragments('中国医学科学院肿瘤医院胸外科');
  assert.ok(f.has('中国医学科学院肿瘤医院胸外科'));
  const out = redactAffiliation('我们在肿瘤医院胸外科做了统计，主任医师的意见是手术。极光数栈的CTO也同意。Hollis said yes.', roster);
  assert.ok(!/肿瘤医院|胸外科|主任医师|极光|CTO|Hollis/.test(out), out);
});

test('L2: self-affiliation patterns zh/en', () => {
  const zh = redactAffiliation('我们部门在腾讯这块做得早。我在协和这些年见得多。作为放疗科副主任，我建议放疗。', roster);
  assert.ok(!/腾讯|协和|放疗科副主任|我们部门/.test(zh), zh);
  const en = redactAffiliation('As head of policy at Oxfam, I disagree. At my firm we never do that. When I was at Google we tried.', roster);
  assert.ok(!/Oxfam|head of policy|my firm|Google/.test(en), en);
});

test('L0+L1+L2 on every benchmark transcript: no direct identifiers survive', () => {
  const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'eval', 'data');
  const report = [];
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
    const t = JSON.parse(readFileSync(join(dir, f), 'utf8'));
    const text = structural(t.lines).flatMap((c) => c.segments).map((s) => redactAffiliation(redactPII(s, t.roster), t.roster)).join('\n');
    for (const g of t.gold.identifiers.filter((g) => ['phone', 'email', 'idcard', 'url', 'handle'].includes(g.kind))) assert.ok(!text.includes(g.text), `${t.id}: ${g.kind} survived`);
    for (const p of t.roster) for (const n of [p.name, ...(p.aliases || [])].filter((x) => x.length >= 2)) {
      const re = /[\u4e00-\u9fff]/.test(n) ? new RegExp(n) : new RegExp(`(?<![A-Za-z])${n.replace(/\./g, '\\.')}(?![A-Za-z])`);
      assert.ok(!re.test(text), `${t.id}: roster token ${n} survived`);
    }
    const soft = t.gold.identifiers.filter((g) => ['name', 'org', 'title', 'address', 'date'].includes(g.kind) && text.includes(g.text));
    report.push(`${t.id}:${soft.length}`);
  }
  console.log('surviving soft identifiers (exact):', report.join(' '));
});
