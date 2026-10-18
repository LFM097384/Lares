import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMemory, memoryStorage, jsonFileStorage, mosaicHeuristic } from '../core/memory.mjs';

const roster = [
  { id: 'a', name: 'Alice Wang', org: 'Acme Bank', title: 'CFO' },
  { id: 'b', name: '李明', org: '星河医院', title: '主任医师' },
  { id: 'c', name: 'Bob Stone', org: 'Org C', title: 'Engineer' },
];

const seed = (mem) => mem.addRelease({
  sid: 's1', draftId: 'd1', approvals: 2, k: 2, approverIds: ['a', 'b'],
  items: [
    { id: 'i1', text: '决定下季度预算削减20%。', kind: 'decision', speaker: 'Alice Wang', reason: 'x' },
    { id: 'i2', text: 'Rollout should wait until the audit is complete.', kind: 'idea' },
    { id: 'i3', text: '下周提交评估报告。', kind: 'todo' },
    { id: 'i4', text: 'unknown kind defaults', kind: 'weird' },
  ],
});

test('addRelease stores whitelisted fields only; list/recall', () => {
  const mem = createMemory({ circleId: 'c1' });
  const added = seed(mem);
  assert.equal(added.length, 4);
  for (const it of added) assert.deepEqual(Object.keys(it).sort(), ['approvals', 'circleId', 'id', 'kind', 'releasedAt', 'sid', 'text']);
  assert.equal(added[3].kind, 'idea');
  const snap = JSON.stringify(mem.toJSON());
  assert.ok(!snap.includes('Alice') && !snap.includes('speaker') && !snap.includes('"reason"'));
  assert.ok(!snap.includes('"a"'), 'approver ids are hashed');
  assert.equal(mem.list().length, 4);
  const r = mem.recall('上次预算定了什么');
  assert.equal(r[0].text, '决定下季度预算削减20%。');
  assert.equal(mem.recall('audit rollout')[0].kind, 'idea');
  assert.equal(mem.recall('完全无关 zebra').length, 0);
});

test('retract -> tombstone, authorised approvers only', () => {
  const mem = createMemory({ circleId: 'c1' });
  const [i1, i2] = seed(mem);
  assert.equal(mem.retract(i1.id, 'c'), false, 'non-approver');
  assert.equal(mem.retract('nope', 'a'), false, 'unknown');
  assert.equal(mem.retract(i1.id, 'b'), true);
  assert.equal(mem.retract(i1.id, 'b'), false, 'already retracted');
  const t = mem.list().find((x) => x.id === i1.id);
  assert.equal(t.retracted, true);
  assert.equal(t.text, undefined);
  assert.ok(!JSON.stringify(mem.toJSON()).includes('预算削减'));
  assert.ok(!mem.recall('预算').some((x) => x.id === i1.id));
  assert.equal(mem.retract(i2.id), true, 'by omitted = pre-authorised caller');
});

test('toJSON / data restore and memoryStorage', () => {
  const st = memoryStorage();
  const mem = createMemory({ circleId: 'c1', storage: st });
  seed(mem);
  const again = createMemory({ circleId: 'c1', storage: st });
  assert.equal(again.list().length, 4);
  const fromData = createMemory({ circleId: 'c1', data: JSON.parse(JSON.stringify(mem.toJSON())) });
  assert.deepEqual(fromData.list(), mem.list());
  assert.throws(() => createMemory({ circleId: 'other', data: mem.toJSON() }), { code: 'circle_mismatch' });
});

test('jsonFileStorage round-trip, atomic, no names / raw text on disk', () => {
  const dir = mkdtempSync(join(tmpdir(), 'anonym-mem-'));
  try {
    const file = join(dir, 'sub', 'c1.json');
    const mem = createMemory({ circleId: 'c1', storage: jsonFileStorage(file) });
    const [i1] = seed(mem);
    mem.retract(i1.id, 'a');
    const disk = readFileSync(file, 'utf8');
    for (const p of roster) assert.ok(!disk.includes(p.name), 'no names on disk');
    assert.ok(!disk.includes('speaker') && !disk.includes('预算削减'));
    assert.deepEqual(readdirSync(join(dir, 'sub')), ['c1.json'], 'no tmp leftovers');
    const back = createMemory({ circleId: 'c1', storage: jsonFileStorage(file) });
    assert.deepEqual(back.list(), mem.list());
    assert.equal(back.recall('audit')[0].text, 'Rollout should wait until the audit is complete.');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('mosaic heuristic: two distinct cues for one member across items -> keep one', () => {
  const d = mosaicHeuristic(['budget for the bank branch network', 'the acme budget rollout', 'generic budget note'], roster);
  assert.deepEqual([...d.keys()], [1]);
});

test('recallForOutput drops mosaic combos (mock gate) and returns flags without names', async () => {
  const mem = createMemory({ circleId: 'c1', roster });
  mem.addRelease({ sid: 's1', draftId: 'd1', approvals: 2, k: 2, approverIds: ['a', 'b'],
    items: [{ text: 'Budget for the bank branch network was frozen.' }, { text: 'Generic budget review next month.' }] });
  mem.addRelease({ sid: 's2', draftId: 'd2', approvals: 2, k: 2, approverIds: ['a', 'c'],
    items: [{ text: 'The acme budget rollout slipped.' }] });
  const p = mem.recallForOutput('budget');
  assert.ok(p instanceof Promise);
  const out = await p;
  assert.equal(out.length, 2);
  assert.ok(!out.some((x) => /acme/i.test(x.text) && out.some((y) => /bank/i.test(y.text))), 'combo not output together');
  assert.equal(out.flags.length, 1);
  assert.deepEqual(Object.keys(out.flags[0]).sort(), ['confidence', 'itemId', 'reason']);
  assert.equal(out.flags[0].reason, 'mosaic');
  assert.ok(!Object.keys(out).includes('flags'), 'flags is non-enumerable');
  for (const it of out) assert.ok(Array.isArray(it.flags));
  const s = JSON.stringify({ out, f: out.flags });
  for (const n of roster) assert.ok(!s.includes(n.name));
  // Each alone is fine.
  assert.equal((await mem.recallForOutput('acme rollout slipped', { limit: 1 })).length, 1);
});

test('recallForOutput drops items the L4 verifier attributes >= flagThreshold (injected gate)', async () => {
  const calls = [];
  const gate = {
    async verifyClaims(texts, r, opts) {
      calls.push({ texts, r, opts });
      return { items: texts.map((t) => (/plan/.test(t) ? { text: t, risk: 'role-revealing', confidence: 0.9, reason: 'Bob Stone', guess: 'c' }
        : /summary/.test(t) ? { text: t, risk: 'role-revealing', confidence: 0.6, reason: 'Bob Stone', guess: 'c' } : { text: t })), flagged: 1 };
    },
  };
  const mem = createMemory({ circleId: 'c1', gate });
  mem.addRelease({ sid: 's1', draftId: 'd1', approvals: 2, k: 2, items: [{ text: 'the audit plan' }, { text: 'the audit report' }, { text: 'the audit report summary' }] });
  const out = await mem.recallForOutput('audit report', { roster, llm: null });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].opts.mock, true);
  assert.equal(calls[0].texts.length, 3, 'combined result checked together');
  assert.ok(out.every((x) => !/plan/.test(x.text)));
  assert.equal(out.flags.length, 1);
  assert.equal(out.flags[0].confidence, 0.9);
  assert.ok(!JSON.stringify([out, out.flags]).includes('Bob'), 'reason/guess stripped');
  const lowRisk = out.find((x) => x.flags.length);
  assert.ok(lowRisk && lowRisk.flags[0].confidence === 0.6);
});

test('recallForOutput fails closed on malformed gate output', async () => {
  const mem = createMemory({ circleId: 'c1', gate: { verifyClaims: async () => ({ items: [] }) } });
  mem.addRelease({ sid: 's1', draftId: 'd1', approvals: 2, k: 2, items: [{ text: 'audit' }] });
  await assert.rejects(mem.recallForOutput('audit'), { code: 'gate_failed' });
});
