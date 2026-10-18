import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  containsVariant, identifierLeak, computeLeaks, bigrams, bigramOverlap, windowBigramScore,
  orgFragments, aggregate, attackAccuracy, retention, estimateUSD, redact, categoryOf,
} from '../eval/metrics.mjs';
import { mockAttack, mockRetention } from '../eval/judge.mjs';

const roster = [
  { id: 'p1', name: '王建国', aliases: ['王总', '老王', 'Jianguo', 'JG'], org: '华夏战略研究院', title: '高级研究员' },
  { id: 'p2', name: 'Alice Chen', aliases: ['Alice'], org: 'Brookfield Policy Institute', title: 'Senior Fellow' },
];

test('categories', () => {
  assert.equal(categoryOf('phone'), 'direct');
  assert.equal(categoryOf('org'), 'affil');
  assert.equal(categoryOf('quasi'), 'quasi');
  assert.equal(categoryOf('style'), 'style');
  assert.equal(categoryOf('weird'), null);
});

test('digit normalisation: separators stripped on both sides', () => {
  assert.ok(containsVariant('call 138 0013 8000 now', '138-0013-8000'));
  assert.ok(containsVariant('tel:13800138000', '138-0013-8000'));
  assert.ok(containsVariant('138.0013.8000', '13800138000'));
  assert.ok(!containsVariant('138 0013 8001', '138-0013-8000'));
});

test('case-insensitive, whitespace-normalised substring', () => {
  assert.ok(containsVariant('Mail ALICE@EXAMPLE.com please', 'alice@example.com'));
  assert.ok(containsVariant('the  Brookfield\n Policy', 'brookfield policy'));
});

test('short ASCII aliases need word boundaries', () => {
  assert.ok(containsVariant('as JG said', 'JG'));
  assert.ok(!containsVariant('JGX is a codename', 'JG'));
});

test('fuzzy variants count as leaks', () => {
  const r = identifierLeak('number 13800138000', { text: '+86 138-0013-8000x', kind: 'phone', owner: 'p1', fuzzy: ['13800138000'] }, roster);
  assert.equal(r.leaked, true);
});

test('names: roster aliases of the owner, full Chinese name', () => {
  const ident = { text: '王建国', kind: 'name', owner: 'p1' };
  assert.equal(identifierLeak('老王认为应该……', ident, roster).leaked, true);
  assert.equal(identifierLeak('Jianguo argued', ident, roster).leaked, true);
  assert.equal(identifierLeak('王先生 said', ident, roster).leaked, false); // single-char 王 not matched
  assert.equal(identifierLeak('一位研究员认为', ident, roster).leaked, false);
});

test('org fragments', () => {
  assert.ok(orgFragments('华夏战略研究院').includes('华夏战略'));
  assert.ok(orgFragments('Brookfield Policy Institute').includes('brookfield'));
  const ident = { text: '华夏战略研究院', kind: 'org', owner: 'p1' };
  assert.equal(identifierLeak('来自华夏战略的同事', ident, roster).leaked, true);
  assert.equal(identifierLeak('某研究院的同事', ident, roster).leaked, false);
  assert.equal(identifierLeak('a Brookfield view', { text: 'Brookfield Policy Institute', kind: 'org', owner: 'p2' }, roster).leaked, true);
});

test('bigrams and overlap', () => {
  assert.deepEqual(bigrams('ab c'), ['ab', 'b ', ' c']);
  assert.deepEqual(bigrams('说 白了'), ['说白', '白了']);
  assert.equal(bigramOverlap('abc', 'xxabcxx'), 1);
  assert.equal(bigramOverlap('', 'x'), 0);
});

test('window bigram fuzzy for quasi identifiers', () => {
  const id = '在海军服役过八年';
  assert.ok(windowBigramScore(id, '有人说自己在海军服役八年，所以……') >= 0.6);
  assert.ok(windowBigramScore(id, '海军……（很长的无关文字很长的无关文字很长的无关文字）……服役……八年') < 0.6);
  const leak = identifierLeak('有人说自己在海军服役八年', { text: id, kind: 'quasi', owner: 'p1' }, roster);
  assert.equal(leak.leaked, true);
  assert.equal(identifierLeak('完全无关', { text: id, kind: 'quasi', owner: 'p1' }, roster).leaked, false);
});

test('style tic: exact substring only', () => {
  const ident = { text: '说白了', kind: 'style', owner: 'p1' };
  assert.equal(identifierLeak('说白了，这是成本问题', ident, roster).leaked, true);
  assert.equal(identifierLeak('坦白说，这是成本问题', ident, roster).leaked, false);
});

test('computeLeaks counts per category', () => {
  const t = { roster, gold: { identifiers: [
    { text: '王建国', kind: 'name', owner: 'p1' },
    { text: 'alice@x.org', kind: 'email', owner: 'p2' },
    { text: 'Senior Fellow', kind: 'title', owner: 'p2' },
    { text: '说白了', kind: 'style', owner: 'p1' },
  ] } };
  const r = computeLeaks('Alice: alice@x.org. 说白了 we should act.', t);
  assert.deepEqual(r.by.direct, { leaked: 1, total: 2 });
  assert.deepEqual(r.by.affil, { leaked: 0, total: 1 });
  assert.deepEqual(r.by.style, { leaked: 1, total: 1 });
  assert.deepEqual(r.by.quasi, { leaked: 0, total: 0 });
});

test('attack accuracy, retention, cost, redact', () => {
  const ideas = [{ id: 'i1', owner: 'p1' }, { id: 'i2', owner: 'p2' }];
  assert.deepEqual(attackAccuracy([{ ideaId: 'i1', rosterId: 'p1' }, { ideaId: 'i2', rosterId: 'p1' }], ideas), { correct: 1, total: 2, acc: 0.5 });
  assert.equal(retention([{ score: 1 }, { score: 0.5 }, { score: 0 }]), 0.5);
  assert.equal(retention([]), null);
  assert.ok(Math.abs(estimateUSD(1e6, 1e6, { inputPerM: 0.07, outputPerM: 0.28 }) - 0.35) < 1e-12);
  assert.equal(redact('13800138000'), '13…');
  assert.equal(redact('王建国'), '王建…');
});

test('aggregate pools counts and skips errors', () => {
  const mk = (dl, dt, c, n, ms) => ({
    leaks: { by: { direct: { leaked: dl, total: dt }, affil: { leaked: 0, total: 0 }, quasi: { leaked: 0, total: 1 }, style: { leaked: 0, total: 0 } } },
    attack: { correct: c, total: n, baselineSum: n / 4 }, retention: { sum: n / 2, n }, ms, promptTokens: 100, completionTokens: 10,
  });
  const a = aggregate([mk(1, 2, 2, 4, 100), mk(0, 2, 1, 2, 300), { error: 'boom' }], { inputPerM: 0.07, outputPerM: 0.28 });
  assert.equal(a.n, 2);
  assert.equal(a.errors, 1);
  assert.equal(a.directLeak, 0.25);
  assert.equal(a.affilLeak, null);
  assert.equal(a.quasiLeak, 0);
  assert.equal(a.attackAcc, 0.5);
  assert.equal(a.randomBaseline, 0.25);
  assert.equal(a.retention, 0.5);
  assert.equal(a.avgLatencyMs, 200);
  assert.equal(a.tokens, 220);
});

test('mock attacker and judge (stub fixture)', () => {
  const ideas = [
    { id: 'i1', text: '碳税应当逐步提高并返还给居民', owner: 'p1' },
    { id: 'i2', text: 'Grid storage subsidies should be auction-based', owner: 'p2' },
  ];
  const raw = '王建国: 我觉得碳税应当逐步提高并返还给居民\nAlice Chen: grid storage subsidies should be auction-based';
  const g = mockAttack(roster, raw, ideas);
  assert.deepEqual(g.map((x) => x.rosterId), ['p1', 'p2']);
  const anon = '## Energy\n- 碳税应当逐步提高，并返还居民\n- Storage subsidies via auctions';
  const g2 = mockAttack(roster, anon, ideas);
  assert.equal(g2.length, 2);
  const s = mockRetention(anon, ideas);
  assert.equal(s[0].score, 1);
  assert.ok(s[1].score <= 1);
  assert.equal(mockRetention('', ideas)[0].score, 0);
});
