import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { rewrite, mockRewriteSegment } from '../lib/l3.mjs';
import { verify } from '../lib/l4.mjs';
import { runGate } from '../lib/gate.mjs';
import { parseJSON } from '../lib/llm.mjs';

const DATA = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'eval', 'data');
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const contains = (hay, needle) => /^[\x00-\x7f]+$/.test(needle)
  ? new RegExp(`(^|[^A-Za-z0-9])${esc(needle)}($|[^A-Za-z0-9])`, 'i').test(hay)
  : hay.includes(needle);
const cjk = (s) => (s.match(/[\u3400-\u9fff]/g) || []).length;

test('chatJSON parsing handles fences and prose', () => {
  assert.deepEqual(parseJSON('```json\n{"a":1,"b":{"c":"}"}}\n```'), { a: 1, b: { c: '}' } });
  assert.deepEqual(parseJSON('Sure! Here: {"sections":[]} hope it helps'), { sections: [] });
  assert.throws(() => parseJSON('nothing here'));
});

test('mock rewrite: first person -> third, tics removed, quasi generalised, no long quotes', async () => {
  const out = await rewrite([{ topic: 'T', segments: [
    '说白了，我们的现金只够撑到明年4月，我觉得要尽快签。',
    '坦率讲，我的双胞胎下个月出生，我要休假。',
    '我刚从北大毕业，我老家在湖南。',
    'Frankly, I think we should ship it, you know, bottom line.',
    'I covered energy policy for 12 years and I believe the subsidy will end in 2027 because the ministry budget keeps shrinking every year.',
  ] }], { mock: true, maxQuoteChars: 20 });
  const text = out[0].claims.join('\n');
  for (const tic of ['说白了', '坦率讲', 'Frankly', 'you know', 'bottom line']) assert.ok(!text.toLowerCase().includes(tic.toLowerCase()), tic);
  assert.ok(!/我/.test(text), 'no 我');
  assert.ok(!/\b(I|we|my|our)\b/i.test(text), 'no EN first person');
  assert.match(text, /与会方|一位参与者/);
  assert.match(text, /a participant|participants/);
  assert.match(text, /提及家庭情况/);
  assert.ok(!text.includes('双胞胎'));
  assert.match(text, /近期完成了学业/);
  assert.match(text, /提及家乡/);
  assert.match(text, /has prior relevant experience/);
  for (const c of out[0].claims) for (const clause of c.split(/[；;。.，,]/)) {
    assert.ok(cjk(clause) <= 20, `long CJK run: ${clause}`);
    assert.ok((clause.match(/[A-Za-z0-9'-]+/g) || []).length <= 12, `long EN run: ${clause}`);
  }
  assert.equal(mockRewriteSegment('嗯，这个方案可以嘛', 20).includes('嘛'), false);
});

test('mock verify flags and strips a roster org', async () => {
  const roster = [{ id: 'p1', name: '王建国', aliases: ['老王'], org: '某某研究院', title: '高级研究员' }];
  const r = await verify([{ topic: 'T', claims: ['某某研究院的数据显示增长放缓。', '利率可能下调。'] }], roster, { mock: true });
  assert.equal(r.flagged.length, 1);
  assert.equal(r.flagged[0].i, 1);
  const all = r.sections.flatMap((s) => s.claims).map((c) => (typeof c === 'string' ? c : c.text)).join('\n');
  assert.ok(!all.includes('某某研究院'));
  assert.ok(all.includes('利率可能下调'));
  assert.ok(r.rounds >= 1);
});

const files = (await readdir(DATA)).filter((f) => f.endsWith('.json'));
for (const f of files) {
  test(`runGate mock all layers leaks nothing: ${f}`, async () => {
    const t = JSON.parse(await readFile(path.join(DATA, f), 'utf8'));
    const { digest, claims, meta } = await runGate(t, { mock: true });
    assert.ok(digest.startsWith('Rule-inspired digest: no attribution.'));
    assert.match(digest, new RegExp(`# Digest \\(session ${t.sessionDate.slice(0, 10)}\\)`));
    assert.ok(claims.length > 0);
    assert.equal(meta.mock, true);
    assert.equal(meta.llmCalls, 0);
    const leaks = [];
    for (const p of t.roster) {
      for (const n of [p.name, ...(p.aliases || [])]) if (n && n.length >= 2 && contains(digest, n)) leaks.push(`name:${n}`);
      if (new RegExp(`\\b${esc(p.id)}\\b`).test(digest)) leaks.push(`id:${p.id}`);
    }
    for (const g of t.gold.identifiers.filter((g) => ['phone', 'email', 'url'].includes(g.kind))) {
      for (const s of [g.text, ...(g.fuzzy || [])]) if (s && s.length >= 4 && digest.includes(s)) leaks.push(`${g.kind}:${s}`);
    }
    assert.deepEqual(leaks, [], `leaks in ${f}`);
  });
}

test('layers=[] returns raw lines with names', async () => {
  const t = JSON.parse(await readFile(path.join(DATA, files[0]), 'utf8'));
  const { digest } = await runGate(t, { layers: [], mock: true });
  for (const p of t.roster) assert.ok(digest.includes(`${p.name}:`) || !t.lines.some((l) => l.speakerId === p.id), p.name);
});

test('L3 without L1 forces L1+L2', async () => {
  const t = JSON.parse(await readFile(path.join(DATA, files[0]), 'utf8'));
  const { meta } = await runGate(t, { layers: ['L3'], mock: true });
  assert.deepEqual(meta.layers, ['L1', 'L2', 'L3']);
});
