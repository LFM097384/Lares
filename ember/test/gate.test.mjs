// Gate v2 layers — ported from server/chatham/test/{l0l1l2,l3l4gate,riskflag}.test.mjs + v2 additions.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { structural, mulberry32 } from '../core/gate/l0.mjs';
import { redactPII, detectPII } from '../core/gate/l1.mjs';
import { redactAffiliation, orgFragments } from '../core/gate/l2.mjs';
import { rewrite, mockRewriteSegment, SYSTEM_PROMPT } from '../core/gate/l3.mjs';
import { verify, ATTACKER_PROMPT } from '../core/gate/l4.mjs';
import { runGate, verifyClaims, NOTICE } from '../core/gate/gate.mjs';
import { parseJSON, chatJSON, createDeepSeekLLM } from '../core/gate/llm.mjs';

const DATA = join(dirname(fileURLToPath(import.meta.url)), '..', 'eval', 'data');
const files = readdirSync(DATA).filter((f) => f.endsWith('.json'));
const load = (f) => JSON.parse(readFileSync(join(DATA, f), 'utf8'));
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const contains = (hay, needle) => /^[\x00-\x7f]+$/.test(needle)
  ? new RegExp(`(^|[^A-Za-z0-9])${esc(needle)}($|[^A-Za-z0-9])`, 'i').test(hay)
  : hay.includes(needle);
const cjk = (s) => (s.match(/[\u3400-\u9fff]/g) || []).length;

// Scripted fake LLM: `script(messages, callNo)` returns an object (JSON-encoded) or a raw string.
function fakeLLM(script) {
  const calls = [];
  return {
    calls,
    async chat(messages, opts) {
      calls.push({ messages, opts });
      const r = await script(messages, calls.length);
      return { text: typeof r === 'string' ? r : JSON.stringify(r), usage: { prompt_tokens: 10, completion_tokens: 5 } };
    },
  };
}
const sys = (m) => m[0].content;

const roster = [
  { id: 'p1', name: '陈志远', aliases: ['陈主任', '老陈', '志远'], org: '中国医学科学院肿瘤医院胸外科', title: '主任医师' },
  { id: 'p2', name: 'Sarah Whitfield', aliases: ['Sarah', 'Ms. Whitfield'], org: 'Hollis Family Trust', title: 'Asia Program Officer' },
  { id: 'p3', name: '赵磊', aliases: ['磊哥', 'Leo', 'JG'], org: '极光数栈科技', title: 'CTO' },
];

// ---------------- L0 / L1 / L2 (ported) ----------------
test('L0: drops speakers/timestamps, deterministic, reorders', () => {
  const lines = Array.from({ length: 12 }, (_, i) => ({ speakerId: 'p' + (i % 3), speakerName: ['陈志远', 'Sarah', '赵磊'][i % 3], ts: `2026-09-01T09:0${i % 10}:00+08:00`, text: `第${i}个观点：定价方案${i % 2 ? '按席位' : '按用量'}收费，毛利率${30 + i}%。` }));
  const a = structural(lines, { seed: 7 }), b = structural(lines, { seed: 7 });
  assert.deepEqual(a, b);
  const flat = a.flatMap((c) => c.segments);
  assert.equal(flat.length, 12);
  assert.ok(!/陈志远|Sarah|赵磊|2026-09-01T|speaker/.test(JSON.stringify(a)));
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
    ['ring me on 01632 960 418', '[phone]'], ['我上个月3号刚到', '[日期]'],
  ];
  for (const [inp, ph] of cases) { const out = redactPII(inp, roster); assert.ok(out.includes(ph), `${inp} -> ${out}`); }
  assert.ok(!redactPII('kzhao@meridian-ai.com', roster).includes('@meridian'));
});

test('L1: roster names, aliases, surname+honorific, 老X', () => {
  const out = redactPII('陈主任说，志远和陈总都觉得老陈对。Thanks, Sarah. Ms. Whitfield agreed; Leo and JG too. 磊哥呢？赵工也在。', roster);
  for (const n of ['陈主任', '志远', '陈总', '老陈', 'Sarah', 'Whitfield', 'Leo', 'JG', '磊哥', '赵工']) assert.ok(!out.includes(n), `${n} leaked: ${out}`);
});

test('L1: no false positives on common words and numbers', () => {
  const s = '总体来说，总结一下：成本下降35%，融资3000万，2019年的数据，Q3目标，老师们辛苦了。The grant was approved. 这个思路跟市里的方向一致。';
  const out = redactPII(s, [...roster, { id: 'p4', name: 'Michael Grant', aliases: ['Mike', 'the Chair'] }]);
  for (const k of ['总体来说', '总结', '35%', '3000万', '2019年', 'Q3', 'The grant was approved', '思路跟市里']) assert.ok(out.includes(k), `${k}: ${out}`);
});

test('L1: third-party names in context (private persons still redacted)', () => {
  const out = redactPII('病例是赵立新，男，61岁。宝武的李卫东副总说贵。质量副总刘振华签字。Dr. Okafor and Priya Raman agreed. Thanks, Qiuping.', []);
  for (const n of ['赵立新', '李卫东', '刘振华', 'Okafor', 'Priya Raman', 'Qiuping']) assert.ok(!out.includes(n), `${n}: ${out}`);
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

// Gold semantics: participant-owned direct/affiliation identifiers never survive L1+L2 (per line and after L0).
const DIRECT = ['phone', 'email', 'idcard', 'url', 'handle', 'name', 'address', 'date'];
const AFFIL = ['org', 'title'];
for (const f of files) {
  test(`L1+L2 gold: no participant-owned direct/affil identifier survives — ${f}`, () => {
    const t = load(f);
    const perLine = t.lines.map((l) => redactAffiliation(redactPII(l.text, t.roster), t.roster)).join('\n');
    const afterL0 = structural(t.lines).flatMap((c) => c.segments).map((s) => redactAffiliation(redactPII(s, t.roster), t.roster)).join('\n');
    for (const text of [perLine, afterL0]) {
      const surv = t.gold.identifiers.filter((g) => g.owner !== 'third' && [...DIRECT, ...AFFIL].includes(g.kind) && text.includes(g.text));
      assert.deepEqual(surv.map((g) => `${g.kind}:${g.text}`), [], `${t.id}`);
      // contact identifiers of anyone (incl. third parties) never survive
      for (const g of t.gold.identifiers.filter((g) => ['phone', 'email', 'idcard', 'url', 'handle'].includes(g.kind))) assert.ok(!text.includes(g.text), `${t.id}: ${g.kind} survived`);
      for (const p of t.roster) for (const n of [p.name, ...(p.aliases || []), ...(p.works || [])].filter((x) => x.length >= 2)) {
        const re = /[\u4e00-\u9fff]/.test(n) ? new RegExp(esc(n)) : new RegExp(`(?<![A-Za-z])${esc(n)}(?![A-Za-z])`);
        assert.ok(!re.test(text), `${t.id}: roster token ${n} survived`);
      }
    }
  });
}

// ---------------- LLM client ----------------
test('parseJSON handles fences and prose', () => {
  assert.deepEqual(parseJSON('```json\n{"a":1,"b":{"c":"}"}}\n```'), { a: 1, b: { c: '}' } });
  assert.deepEqual(parseJSON('Sure! Here: {"sections":[]} hope it helps'), { sections: [] });
  assert.throws(() => parseJSON('nothing here'));
});

test('chatJSON: one retry on bad JSON, stats accounted, tolerates missing usage', async () => {
  let n = 0;
  const llm = { async chat() { n++; return n === 1 ? { text: 'oops not json' } : { text: '{"ok":true}', usage: { prompt_tokens: 7, completion_tokens: 3 } }; } };
  const stats = {};
  const { data } = await chatJSON(llm, [{ role: 'user', content: 'x' }], { stats });
  assert.deepEqual(data, { ok: true });
  assert.deepEqual(stats, { calls: 2, promptTokens: 7, completionTokens: 3 });
  const bad = { async chat() { return { text: 'never' }; } };
  await assert.rejects(chatJSON(bad, [], {}), /no JSON/);
});

test('createDeepSeekLLM: request body, retries on 5xx, key never in errors', async () => {
  const seen = [];
  let n = 0;
  const fetchImpl = async (url, init) => {
    seen.push({ url, body: JSON.parse(init.body), auth: init.headers.Authorization });
    n++;
    if (n === 1) return new Response('busy', { status: 503 });
    return new Response(JSON.stringify({ choices: [{ message: { content: '{"x":1}' }, finish_reason: 'stop' }], usage: { prompt_tokens: 1, completion_tokens: 2 } }), { status: 200 });
  };
  const llm = createDeepSeekLLM({ key: 'sk-SECRET123', baseUrl: 'https://example.test/', fetchImpl });
  const r = await llm.chat([{ role: 'user', content: 'hi' }], { json: true });
  assert.equal(r.text, '{"x":1}');
  assert.equal(r.finish, 'stop');
  assert.equal(seen.length, 2);
  assert.equal(seen[0].url, 'https://example.test/chat/completions');
  assert.deepEqual(seen[0].body.thinking, { type: 'disabled' });
  assert.deepEqual(seen[0].body.response_format, { type: 'json_object' });
  assert.equal(seen[0].body.model, 'deepseek-flash');
  assert.equal(seen[0].body.max_tokens, 8192);
  const leaky = createDeepSeekLLM({ key: 'sk-SECRET123', fetchImpl: async () => new Response('bad key sk-SECRET123', { status: 401 }) });
  await assert.rejects(leaky.chat([]), (e) => !String(e.message).includes('sk-SECRET123') && /401/.test(e.message));
  const net = createDeepSeekLLM({ key: 'sk-SECRET123', retries: 1, fetchImpl: async () => { throw new Error('connect sk-SECRET123 refused'); } });
  await assert.rejects(net.chat([]), (e) => !String(e.message).includes('sk-SECRET123'));
  assert.throws(() => createDeepSeekLLM({}), /key/);
});

// ---------------- L3 ----------------
test('mock rewrite: first person -> third, tics removed, quasi generalised, no long quotes', async () => {
  const out = await rewrite([{ topic: 'T', segments: [
    '说白了，我们的现金只够撑到明年4月，我觉得要尽快签。',
    '坦率讲，我的双胞胎下个月出生，我要休假。',
    '我刚从北大毕业，我老家在湖南。',
    'Frankly, I think we should ship it, you know, bottom line.',
    'I covered energy policy for 12 years and I believe the subsidy will end in 2027 because the ministry budget keeps shrinking every year.',
  ] }], { llm: null, maxQuoteChars: 20 });
  const texts = out[0].claims.map((c) => c.text);
  const text = texts.join('\n');
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
  for (const c of texts) for (const clause of c.split(/[；;。.，,]/)) {
    assert.ok(cjk(clause) <= 20, `long CJK run: ${clause}`);
    assert.ok((clause.match(/[A-Za-z0-9'-]+/g) || []).length <= 12, `long EN run: ${clause}`);
  }
  assert.equal(mockRewriteSegment('嗯，这个方案可以嘛', 20).includes('嘛'), false);
  assert.ok(out[0].claims.every((c) => ['idea', 'decision', 'todo', 'fact'].includes(c.kind) && Array.isArray(c.flags)));
});

test('mock rewrite: sarcasm markers / dialect particles stripped, kind heuristic, tone flag', async () => {
  const out = await rewrite([{ topic: 'T', segments: ['呵呵，这方案可真行。', '俺觉得咋整都不行。', '待办：下周提交草稿。', '大家一致同意按度电补贴。', 'Oh brilliant, another committee.'] }], { llm: null });
  const c = out[0].claims;
  const text = c.map((x) => x.text).join('\n');
  for (const m of ['呵呵', '可真行', '俺', '咋整', 'brilliant']) assert.ok(!text.includes(m), `${m}: ${text}`);
  assert.ok(c[0].flags.includes('tone-neutralised'));
  assert.equal(c[2].kind, 'todo');
  assert.equal(c[3].kind, 'decision');
  assert.equal(c[0].kind, 'idea');
});

test('L3 LLM path: prompt carries PUBLIC FACTS + TONE rules; object and legacy string claims accepted', async () => {
  const llm = fakeLLM(() => ({ sections: [{ topic: '翻译', claims: [
    { text: '《三体》英文版由刘宇昆翻译。', kind: 'fact', flags: ['public-fact'] },
    { text: '有观点对该方案的决策依据表示明显怀疑。', kind: 'idea', flags: ['tone-neutralised', 'bogus'] },
    '待办：整理机翻错误对照表。',
    { text: '与会方决定按度电补贴。', kind: 'weird' },
  ] }] }));
  const stats = {};
  const out = await rewrite([{ topic: 'T1', segments: ['x'] }], { llm, stats });
  const p = sys(llm.calls[0].messages);
  assert.match(p, /PUBLIC FACTS/);
  assert.match(p, /《三体》" must NOT become "某作品"/);
  assert.match(p, /TONE/);
  assert.match(p, /有观点对该方案的决策依据表示明显怀疑/);
  assert.equal(llm.calls[0].opts.json, true);
  const c = out[0].claims;
  assert.deepEqual(c[0], { text: '《三体》英文版由刘宇昆翻译。', kind: 'fact', flags: ['public-fact'] });
  assert.deepEqual(c[1].flags, ['tone-neutralised']);
  assert.equal(c[2].kind, 'todo');
  assert.equal(c[3].kind, 'decision');
  assert.equal(stats.calls, 1);
  assert.equal(SYSTEM_PROMPT(20).includes('"flags"'), true);
});

// ---------------- L4 ----------------
test('mock verify flags and strips a roster org', async () => {
  const r0 = [{ id: 'p1', name: '王建国', aliases: ['老王'], org: '某某研究院', title: '高级研究员' }];
  const r = await verify([{ topic: 'T', claims: ['某某研究院的数据显示增长放缓。', '利率可能下调。'] }], r0, { llm: null });
  assert.equal(r.flagged.length, 1);
  assert.equal(r.flagged[0].i, 1);
  const all = r.sections.flatMap((s) => s.claims).map((c) => c.text).join('\n');
  assert.ok(!all.includes('某某研究院'));
  assert.ok(all.includes('利率可能下调'));
  assert.ok(r.rounds >= 1);
});

const rosterR = [{ id: 'p1', name: '王建国', aliases: ['老王'], org: '某某研究院', title: '研究员' }, { id: 'p2', name: 'Sarah Whitfield', aliases: ['Sarah'], org: 'Hollis Family Trust', title: 'Program Officer' }];

test('L4 returns claim objects; residual risk marks role-revealing instead of dropping silently', async () => {
  const r = await verify([{ topic: 'T', claims: ['利率可能下调。'] }], rosterR, { llm: null, maxRounds: 2 });
  const c = r.sections[0].claims[0];
  assert.equal(typeof c, 'object');
  assert.equal(c.text, '利率可能下调。');
  assert.equal(c.risk, undefined);
  assert.equal(typeof r.residual, 'number');
});

test('L4 keeps kind/flags through mock rounds', async () => {
  const r = await verify([{ topic: 'T', claims: [{ text: '某某研究院认为利率会降。', kind: 'fact', flags: ['public-fact'] }] }], rosterR, { llm: null });
  const c = r.sections[0].claims[0];
  assert.equal(c.kind, 'fact');
  assert.deepEqual(c.flags, ['public-fact']);
  assert.ok(!c.text.includes('某某研究院'));
});

test('L4 LLM: attacker sees works + public-fact rule; tone rewrite; residual tone → tone-residual + role-revealing', async () => {
  const roster2 = [...rosterR, { id: 'p3', name: '苏曼宁', org: '自由撰稿人', title: '小说家', works: ['《雾港纪事》'] }];
  const llm = fakeLLM((m, n) => {
    const s = sys(m);
    if (s === ATTACKER_PROMPT) {
      if (n === 1) return { results: [
        { i: 1, guess: 'p1', confidence: 0.9, reason: 'research institute data', tone: false },
        { i: 2, guess: null, confidence: 0.1, reason: '', tone: true },
        { i: 3, guess: null, confidence: 0, reason: '', tone: false },
        { i: 4, guess: null, confidence: 0, reason: '', tone: true },
      ] };
      if (n === 3) return { results: [{ i: 4, guess: null, confidence: 0, tone: true }] };
      return { results: [{ i: 1, guess: 'p1', confidence: 0.95, reason: 'still insider', tone: false }, { i: 4, guess: null, confidence: 0, tone: true }] };
    }
    // generaliser
    const u = m[1].content;
    const rw = [];
    if (/^1\./m.test(u)) rw.push({ i: 1, text: '有观点认为增长放缓。' });
    if (/^2\./m.test(u)) rw.push({ i: 2, text: '有观点对该方案的可行性表示明显怀疑。' });
    return { rewrites: rw }; // claim 4 (tone-only) never rewritten
  });
  const stats = {};
  const r = await verify([{ topic: 'T', claims: [
    { text: '我们院的数据显示增长放缓。', kind: 'idea', flags: [] },
    { text: '这方案真是高明，写了跟没写一样。', kind: 'idea', flags: [] },
    { text: '《三体》是刘慈欣写的。', kind: 'fact', flags: ['public-fact'] },
    { text: '读者不挑？那豆瓣2.9分是谁家的？', kind: 'idea', flags: [] },
  ] }], roster2, { llm, stats, maxRounds: 2 });
  const user0 = llm.calls[0].messages[1].content;
  assert.match(user0, /《雾港纪事》/);
  assert.match(ATTACKER_PROMPT, /PUBLIC WORLD FACTS ARE NOT CUES/);
  assert.match(ATTACKER_PROMPT, /"tone"/);
  const genReq = llm.calls[1].messages[1].content;
  assert.match(genReq, /tone: true/);
  const cs = r.sections[0].claims;
  const byText = (re) => cs.find((c) => re.test(c.text));
  const c2 = byText(/可行性表示明显怀疑/);
  assert.ok(c2 && c2.flags.includes('tone-neutralised') && !c2.risk, JSON.stringify(cs));
  const c3 = byText(/三体/);
  assert.deepEqual(c3.flags, ['public-fact']);
  assert.equal(c3.kind, 'fact');
  const c4 = byText(/豆瓣/);
  assert.ok(c4.flags.includes('tone-residual') && c4.flags.includes('role-revealing'), JSON.stringify(c4));
  assert.equal(c4.risk, 'role-revealing');
  const c1 = byText(/增长放缓/);
  assert.equal(c1.risk, 'role-revealing');
  assert.equal(c1.guess, 'p1');
  assert.ok(stats.calls >= 4);
});

test('L4 LLM: flagged claim with no rewrite is dropped (fail closed)', async () => {
  const llm = fakeLLM((m) => (sys(m) === ATTACKER_PROMPT ? { results: [{ i: 1, guess: 'p1', confidence: 0.9, reason: 'x' }] } : { rewrites: [] }));
  const r = await verify([{ topic: 'T', claims: ['我们院的数据。', '利率可能下调。'] }], rosterR, { llm, maxRounds: 1 });
  assert.equal(r.dropped, 1);
  assert.deepEqual(r.sections[0].claims.map((c) => c.text), ['利率可能下调。']);
});

// ---------------- gate ----------------
for (const f of files) {
  test(`runGate mock all layers leaks nothing: ${f}`, async () => {
    const t = load(f);
    const { digest, digestStrict, claims, meta } = await runGate(t, { llm: null });
    assert.ok(digest.startsWith(NOTICE));
    assert.ok(digestStrict.startsWith(NOTICE));
    assert.match(digest, new RegExp(`# Digest \\(session ${t.sessionDate.slice(0, 10)}\\)`));
    assert.ok(claims.length > 0);
    assert.ok(claims.every((c) => typeof c.text === 'string' && ['idea', 'decision', 'todo', 'fact'].includes(c.kind) && Array.isArray(c.flags)));
    assert.equal(meta.mock, true);
    assert.equal(meta.llmCalls, 0);
    const leaks = [];
    for (const p of t.roster) {
      for (const n of [p.name, ...(p.aliases || []), ...(p.works || [])]) if (n && n.length >= 2 && contains(digest, n)) leaks.push(`name:${n}`);
      if (new RegExp(`\\b${esc(p.id)}\\b`).test(digest)) leaks.push(`id:${p.id}`);
    }
    for (const g of t.gold.identifiers.filter((g) => ['phone', 'email', 'url'].includes(g.kind))) {
      for (const s of [g.text, ...(g.fuzzy || [])]) if (s && s.length >= 4 && digest.includes(s)) leaks.push(`${g.kind}:${s}`);
    }
    assert.deepEqual(leaks, [], `leaks in ${f}`);
  });
}

test('layers=[] returns raw lines with names', async () => {
  const t = load(files[0]);
  const { digest } = await runGate(t, { layers: [], llm: null });
  for (const p of t.roster) assert.ok(digest.includes(`${p.name}:`) || !t.lines.some((l) => l.speakerId === p.id), p.name);
});

test('L3 without L1 forces L1+L2', async () => {
  const t = load(files[0]);
  const { meta } = await runGate(t, { layers: ['L3'], llm: null });
  assert.deepEqual(meta.layers, ['L1', 'L2', 'L3']);
});

test('runGate LLM path: final scrub re-redacts LLM output, flagged go to digest only, stats counted', async () => {
  const t = { roster: rosterR, sessionDate: '2026-10-01', lang: 'zh', lines: [
    { speakerId: 'p1', speakerName: '王建国', text: '我觉得利率会下调。', ts: '' },
    { speakerId: 'p2', speakerName: 'Sarah Whitfield', text: 'Thanks, everyone, I agree.', ts: '' },
  ] };
  const llm = fakeLLM((m) => {
    const s = sys(m);
    if (s.startsWith('You are the rewrite stage')) {
      assert.ok(!/王建国|Sarah/.test(m[1].content), 'LLM saw raw names');
      return { sections: [{ topic: '利率', claims: [
        { text: '王建国认为利率会下调。', kind: 'idea', flags: [] },
        { text: '《三体》是刘慈欣写的。', kind: 'fact', flags: ['public-fact'] },
        { text: '与会方决定下周再议。', kind: 'decision', flags: [] },
      ] }] };
    }
    if (s === ATTACKER_PROMPT) return { results: [{ i: 3, guess: 'p2', confidence: 0.9, reason: 'chair-like', tone: false }] };
    return { rewrites: [{ i: 3, text: '与会方决定下周再议此事。' }] };
  });
  const stats = { calls: 0, promptTokens: 0, completionTokens: 0 };
  const g = await runGate(t, { llm, stats, maxVerifierRounds: 1 });
  assert.equal(g.meta.mock, false);
  assert.equal(g.meta.llmCalls, stats.calls);
  assert.ok(stats.calls >= 3);
  assert.ok(!g.digest.includes('王建国'), g.digest);
  assert.ok(g.digest.includes('《三体》是刘慈欣写的'));
  const flagged = g.claims.filter((c) => c.risk);
  assert.equal(flagged.length, 1);
  assert.ok(flagged[0].flags.includes('role-revealing'));
  assert.equal(flagged[0].kind, 'decision');
  assert.match(g.digest, /\[review: role-revealing\] 与会方决定下周再议此事/);
  assert.ok(!g.digestStrict.includes('下周再议'));
  assert.equal(g.claims.find((c) => /三体/.test(c.text)).kind, 'fact');
});

test('verifyClaims: flat list, aligned items, DROP for fail-closed, flagged count', async () => {
  const mock = await verifyClaims(['利率可能下调。', '某某研究院'], rosterR, { llm: null });
  assert.equal(mock.items.length, 2);
  assert.equal(mock.items[0].text, '利率可能下调。');
  assert.equal(mock.items[1], 'DROP');
  const llm = fakeLLM((m) => (sys(m) === ATTACKER_PROMPT
    ? { results: [{ i: 1, guess: 'p1', confidence: 0.95, reason: 'combo' }, { i: 2, guess: 'p2', confidence: 0.9, reason: 'x' }] }
    : { rewrites: [{ i: 1, text: '有观点认为利率会降。' }] }));
  const r = await verifyClaims(['A 研究院内部数据显示利率会降。', 'B 只有基金会知道。', 'C 公开信息。'], rosterR, { llm, maxRounds: 1 });
  assert.equal(r.items[0].text, '有观点认为利率会降。');
  assert.equal(r.items[0].risk, 'role-revealing');
  assert.equal(r.items[1], 'DROP');
  assert.deepEqual(r.items[2], { text: 'C 公开信息。' });
  assert.equal(r.flagged, 1);
  assert.deepEqual(await verifyClaims([], rosterR), { items: [], flagged: 0 });
});
