import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFileMemory, readReleasedKnowledge } from '../core/filememory.mjs';
import { createScriptedLLM } from '../core/mock-llm.mjs';

const roster = [
  { id: 'm1', name: 'Alice Wang', org: 'Acme Bank', title: 'CFO' },
  { id: 'm2', name: '李明', org: '星河医院', title: '主任医师' },
  { id: 'm3', name: 'Bob Stone', org: 'Org C', title: 'Engineer' },
];
const passGate = { verifyClaims: async (texts) => ({ items: texts.map((text) => ({ text })) }) };
const tmp = () => mkdtempSync(join(tmpdir(), 'anon-fm-'));
let t0 = Date.UTC(2026, 9, 31);
const clock = () => (t0 += 1000);

function allFiles(d) {
  const out = [];
  for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) out.push(...allFiles(p)); else out.push(p); }
  return out;
}
const corpus = (d) => allFiles(d).map((p) => readFileSync(p, 'utf8')).join('\n');

// Mock LLM: answers by citing every candidate whose text shares a CJK bigram/word with the question;
// consolidate assigns everything to a 'budget' or 'general' topic; summaries cite all items verbatim-ish.
function mockLLM() {
  return createScriptedLLM((messages) => {
    const sys = messages[0].content, user = messages[messages.length - 1].content;
    const lines = [...user.matchAll(/\[i:(i_[0-9a-f]+)\][^\n]*?\)\s*([^\n]*)/g)].map((m) => ({ id: m[1], text: m[2] }));
    if (sys.includes('delta')) {
      const ids = [...user.matchAll(/^\[(i_[0-9a-f]+)\][^\n]*\)\s*(.*)$/gm)].map((m) => ({ id: m[1], text: m[2] }));
      return { ops: [{ op: 'new_topic', topic: 'budget', title: '预算' }, { op: 'new_topic', topic: 'general', title: '综合' },
        ...ids.map((x) => ({ op: 'assign', id: x.id, topic: /预算/.test(x.text) ? 'budget' : 'general' })),
        { op: 'assign', id: 'i_nonexistent', topic: 'budget' }, { op: 'rewrite', id: ids[0]?.id, text: 'HACKED' }] };
    }
    if (sys.includes('主题摘要')) return { summary: lines.map((x) => `${x.text} [i:${x.id}]`).join('') };
    const q = user.split('# 问题\n')[1] || '';
    const bg = new Set(); for (let i = 0; i + 1 < q.length; i++) bg.add(q.slice(i, i + 2));
    const use = lines.filter((x) => [...bg].some((b) => /[\u3400-\u9fff]{2}/.test(b) && x.text.includes(b))).map((x) => x.id);
    return use.length ? { notes: [], use, answer: use.map((id) => `${lines.find((x) => x.id === id).text}[i:${id}]`).join(''), insufficient: false }
      : { notes: [], use: [], answer: '记忆里没有相关内容。', insufficient: true };
  });
}

const seed = (mem) => mem.remember([
  { text: '决定下季度预算削减27%，砍掉线下推广。', kind: 'decision', speaker: 'Alice Wang' },
  { text: '两周内整理一份竞品访谈提纲。', kind: 'todo', speaker: '李明' },
  { text: 'Rollout should wait until the security audit is complete.', kind: 'idea' },
  { text: '去年线下推广转化率低于1%。', kind: 'fact' },
], { sid: 's-1', draftId: 'd1', approvals: 2, k: 2, approverIds: ['m1', 'm2'] });

test('remember round-trip, whitelist, reload from disk, toJSON', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', roster, clock, gate: passGate });
  const added = await seed(mem);
  assert.equal(added.length, 4);
  for (const it of added) assert.deepEqual(Object.keys(it).sort(), ['approvals', 'circleId', 'id', 'kind', 'releasedAt', 'sid', 'text']);
  assert.equal(added.rejected, 0);
  const again = createFileMemory({ dir, circleId: 'c1', roster, clock, gate: passGate });
  assert.equal(again.list().length, 4);
  assert.equal(again.recall('预算')[0].id, added[0].id);
  const j = again.toJSON();
  assert.equal(j.version, 2); assert.equal(j.items.length, 4); assert.equal(j.releases.length, 1);
  assert.deepEqual(j.releases[0].approverHashes.sort(), [again.approverHash('m1'), again.approverHash('m2')].sort());
  assert.ok(readFileSync(join(dir, 'meetings', 's-1.md'), 'utf8').includes(`[i:${added[0].id}]`));
  assert.ok(readFileSync(join(dir, 'MEMORY.md'), 'utf8').includes('条目 4 条'));
  rmSync(dir, { recursive: true, force: true });
});

test('BM25 ranking prefers rarer matching terms and kind boost', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', clock, gate: passGate });
  await mem.remember([
    { text: '会议讨论了会议室安排。', kind: 'fact' },
    { text: '会议决定采购新的服务器。', kind: 'decision' },
    { text: '服务器机房需要扩容空调。', kind: 'idea' },
    { text: 'Budget review moved to Friday.', kind: 'fact' },
  ], { sid: 's', approvals: 1 });
  const r = mem.recall('服务器 采购');
  assert.equal(r[0].text, '会议决定采购新的服务器。');
  assert.ok(r[0].score > r[1].score);
  assert.equal(mem.recall('budget')[0].text, 'Budget review moved to Friday.');
  assert.equal(mem.recall('zebra 无关键词').length, 0);
  assert.equal(mem.recall('会议定了什么')[0].kind, 'decision');
  rmSync(dir, { recursive: true, force: true });
});

test('no speaker / roster names in any file; log has no text', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', roster, clock, llm: mockLLM(), gate: passGate });
  const added = await seed(mem);
  await mem.consolidate({ force: true });
  await mem.answer('预算怎么定的');
  await mem.retract(added[1].id, { by: 'm2' });
  const all = corpus(dir);
  for (const p of roster) { assert.ok(!all.includes(p.name), p.name); assert.ok(!all.includes(`"${p.id}"`)); }
  assert.equal((all.match(/.{0,40}(speaker|"by"|\bmember).{0,40}/i) || [null])[0], null);
  const log = readFileSync(join(dir, 'log.jsonl'), 'utf8');
  for (const it of added) assert.ok(!log.includes(it.text));
  rmSync(dir, { recursive: true, force: true });
});

test('retract purges text + substrings everywhere; answer no longer cites it', async () => {
  const dir = tmp();
  const llm = mockLLM();
  const mem = createFileMemory({ dir, circleId: 'c1', roster, clock, llm, gate: passGate });
  const added = await seed(mem);
  await mem.consolidate({ force: true });
  const target = added[0];
  assert.ok(corpus(dir).includes(target.text));
  const a1 = await mem.answer('预算削减');
  assert.ok(a1.answer.includes(`[i:${target.id}]`));
  assert.equal(a1.mode, 'full');
  const r = await mem.retract(target.id);
  assert.equal(r.ok, true);
  assert.ok(r.regenerated.includes('MEMORY.md'));
  const all = corpus(dir);
  assert.ok(!all.includes(target.text));
  for (let i = 0; i + 8 <= target.text.length; i++) assert.ok(!all.includes(target.text.slice(i, i + 8)), target.text.slice(i, i + 8));
  assert.ok(!all.includes('27%'));
  const a2 = await mem.answer('预算削减');
  assert.ok(!a2.answer.includes(target.id));
  assert.ok(!a2.items.some((x) => x.id === target.id));
  const tombs = mem.list().filter((x) => x.retracted);
  assert.deepEqual(Object.keys(tombs[0]).sort(), ['id', 'retracted', 'retractedAt', 'sid']);
  // reload sees the tombstone
  assert.equal(createFileMemory({ dir, circleId: 'c1' }).list().filter((x) => x.retracted).length, 1);
  rmSync(dir, { recursive: true, force: true });
});

test('retract: forbidden, already_retracted, unknown, open when no hashes', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', clock, gate: passGate });
  const added = await seed(mem);
  assert.deepEqual(await mem.retract(added[0].id, { by: 'm3' }), { ok: false, code: 'forbidden' });
  assert.deepEqual(await mem.retract(added[0].id, { byHash: 'deadbeef' }), { ok: false, code: 'forbidden' });
  assert.equal((await mem.retract(added[0].id, { byHash: mem.approverHash('m1') })).ok, true);
  assert.deepEqual(await mem.retract(added[0].id), { ok: false, code: 'already_retracted' });
  assert.deepEqual(await mem.retract('nope'), { ok: false, code: 'unknown' });
  const [open] = await mem.remember([{ text: '无签名记录的条目。', kind: 'fact' }], { sid: 's-2', approvals: 1 });
  assert.equal((await mem.retract(open.id, { by: 'anyone' })).ok, true);
  rmSync(dir, { recursive: true, force: true });
});

test('caps: >300 chars and live-item cap -> .rejected', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', clock, gate: passGate, maxItems: 3 });
  const r1 = await mem.remember([{ text: '长'.repeat(301), kind: 'fact' }, { text: '短条目一', kind: 'fact' }], { sid: 's', approvals: 1 });
  assert.equal(r1.length, 1); assert.equal(r1.rejected, 1);
  assert.ok(!Object.keys(r1).includes('rejected'));
  const r2 = await mem.remember([{ text: '条目二', kind: 'fact' }, { text: '条目三', kind: 'fact' }, { text: '条目四', kind: 'fact' }], { sid: 's', approvals: 1 });
  assert.equal(r2.length, 2); assert.equal(r2.rejected, 1);
  rmSync(dir, { recursive: true, force: true });
});

test('readReleasedKnowledge: sync, read-only, live only, newest first', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', clock, gate: passGate });
  const added = await seed(mem);
  await mem.remember([{ text: '新的预算会议纪要。', kind: 'fact' }], { sid: 's-2', draftId: 'd2', approvals: 3 });
  await mem.retract(added[3].id);
  const all = readReleasedKnowledge(dir, '');
  assert.ok(Array.isArray(all));
  assert.equal(all.length, 4);
  assert.equal(all[0].text, '新的预算会议纪要。');
  assert.equal(all[0].draftId, 'd2');
  assert.deepEqual(Object.keys(all[0]).sort(), ['approvals', 'draftId', 'id', 'kind', 'releasedAt', 'sid', 'text']);
  const hit = readReleasedKnowledge(dir, '预算削减', { limit: 1 });
  assert.equal(hit.length, 1); assert.equal(hit[0].id, added[0].id);
  assert.deepEqual(readReleasedKnowledge(join(dir, 'missing'), ''), []);
  rmSync(dir, { recursive: true, force: true });
});

test('consolidate never alters item text; rejects invalid ops; no-LLM kind grouping', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', roster, clock, llm: mockLLM(), gate: passGate });
  const added = await seed(mem);
  const shardBefore = readdirSync(join(dir, 'items')).map((f) => readFileSync(join(dir, 'items', f), 'utf8')).join('');
  const res = await mem.consolidate({ force: true });
  assert.ok(res.applied.some((o) => o.op === 'assign' && o.topic === 'budget'));
  assert.ok(res.rejected.some((o) => o.op === 'rewrite'));
  assert.ok(res.rejected.some((o) => o.id === 'i_nonexistent'));
  assert.ok(res.regenerated.includes('topics/budget.md'));
  const shardAfter = readdirSync(join(dir, 'items')).map((f) => readFileSync(join(dir, 'items', f), 'utf8')).join('');
  assert.equal(shardAfter, shardBefore);
  assert.ok(!corpus(dir).includes('HACKED'));
  for (const it of added) assert.equal(mem.list().find((x) => x.id === it.id).text, it.text);
  const topic = readFileSync(join(dir, 'topics', 'budget.md'), 'utf8');
  for (const line of topic.split('## 条目')[1].trim().split('\n')) assert.match(line, /\[i:i_[0-9a-f]+\]/);
  // no LLM: deterministic grouping by kind
  const dir2 = tmp();
  const m2 = createFileMemory({ dir: dir2, circleId: 'c2', clock, gate: passGate });
  await seed(m2);
  const r2 = await m2.consolidate({ force: true });
  assert.ok(r2.regenerated.includes('topics/decisions.md') && r2.regenerated.includes('topics/todos.md'));
  rmSync(dir, { recursive: true, force: true }); rmSync(dir2, { recursive: true, force: true });
});

test('recallForOutput drops mosaic combos and exposes non-enumerable flags', async () => {
  const dir = tmp();
  const mem = createFileMemory({ dir, circleId: 'c1', roster, clock, gate: passGate });
  await mem.remember([{ text: '一家银行的 CFO 提到预算问题。', kind: 'fact' }, { text: 'Acme Bank 的预算偏紧。', kind: 'fact' }], { sid: 's', approvals: 1 });
  const out = await mem.recallForOutput('预算', { limit: 5 });
  assert.ok(Array.isArray(out.flags));
  assert.ok(!Object.keys(out).includes('flags'));
  assert.equal(out.length + out.flags.length, 2);
  assert.ok(out.flags.length >= 1);
  rmSync(dir, { recursive: true, force: true });
});
