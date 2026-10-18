import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createSession, computeDraftHash } from '../core/index.mjs';
import { createMemory } from '../core/memory.mjs';
import { generateEd25519, signEd25519, approvalMessage } from '../core/crypto.mjs';
import { createScriptedLLM } from '../core/mock-llm.mjs';

const UTTS = [
  ['a', '我们决定下季度把预算削减20%，Alice Wang 认为风险可控。'],
  ['b', '待办：李明负责下周提交评估报告。'],
  ['c', 'I think the rollout should wait until the audit is complete.'],
  ['a', 'Honestly the vendor contract with Northwind needs renegotiation before March.'],
];

function setup({ memory = null, llm = null, k = 2, gate } = {}) {
  const keys = { a: generateEd25519(), b: generateEd25519(), c: generateEd25519(), x: generateEd25519() };
  const roster = [
    { id: 'a', name: 'Alice Wang', org: 'Acme Bank', title: 'CFO' },
    { id: 'b', name: '李明', org: '星河医院', title: '主任医师', pubKey: keys.b.pubB64 },
    { id: 'c', name: 'Bob Stone', aliases: ['Bobby'], org: 'Org C', title: 'Engineer' },
  ];
  let t = 1_700_000_000_000;
  const s = createSession({ sid: 'S-1', roster, policy: { k }, llm, clock: () => t++, memory, gate });
  for (const [id, text] of UTTS) s.ingest({ speakerId: id, text, ts: t++, final: true });
  s.ingest({ speakerId: 'a', text: 'interim words never drafted', ts: t++, final: false });
  const sign = (who, d, nonce = randomUUID(), signer = who) => ({
    draftId: d.draftId, draftHash: d.draftHash, memberId: who, pubKey: keys[signer].pubB64, nonce,
    sig: signEd25519(keys[signer].privateKey, approvalMessage({ sid: 'S-1', draftId: d.draftId, draftHash: d.draftHash, nonce })),
  });
  return { s, keys, roster, sign };
}

const deepStrings = (v, out = []) => {
  if (typeof v === 'string') out.push(v);
  else if (v && typeof v === 'object') for (const x of (v instanceof Map ? [...v.entries()] : Object.values(v))) deepStrings(x, out);
  return out;
};

test('non-roster speakers / askers are rejected', async () => {
  const { s } = setup();
  assert.throws(() => s.ingest({ speakerId: 'zz', text: 'hi', ts: 1, final: true }), { code: 'not_member' });
  await assert.rejects(s.ask({ askerId: 'zz', question: 'q?' }), { code: 'not_member' });
});

test('happy path: draft (mock gate), review changes hash, k=2 approvals with Ed25519, release, memory, end wipes', async () => {
  const memory = createMemory({ circleId: 'circle-1' });
  const { s, sign, roster } = setup({ memory });
  const d0 = await s.draft();
  assert.ok(d0.items.length >= 3);
  assert.equal(d0.draftHash, computeDraftHash('S-1', d0.draftId, d0.items));
  assert.ok(!d0.items.some((i) => /interim/.test(i.text)), 'non-final excluded');
  assert.ok(!JSON.stringify(d0.items).includes('Alice Wang'));
  assert.ok(d0.items.some((i) => i.kind === 'decision') && d0.items.some((i) => i.kind === 'todo'));

  // approval on d0 then a review invalidates it
  assert.equal(s.approve(sign('a', d0)).approvals, 1);
  const cutTarget = d0.items.find((i) => /Northwind|vendor/i.test(i.text)) || d0.items[d0.items.length - 1];
  const d1 = await s.review({ draftId: d0.draftId, memberId: 'b', itemId: cutTarget.id, action: 'cut' });
  assert.notEqual(d1.draftHash, d0.draftHash);
  assert.equal(d1.items.length, d0.items.length - 1);
  assert.equal(d1.metrics.approvals, 0, 'approvals cleared by review');
  assert.throws(() => s.approve(sign('b', d0)), { code: 'hash_mismatch' });

  const genTarget = d1.items.find((i) => /20/.test(i.text)) || d1.items[0];
  const d2 = await s.review({ draftId: d0.draftId, memberId: 'c', itemId: genTarget.id, action: 'generalise' });
  assert.notEqual(d2.draftHash, d1.draftHash);
  const gen = d2.items.find((i) => i.id === genTarget.id);
  assert.ok(gen.flags.includes('generalised'));
  assert.ok(!/\d/.test(gen.text), 'mock generalise strips numbers');

  const d3 = await s.review({ draftId: d0.draftId, memberId: 'a', itemId: d2.items[0].id, action: 'keep' });
  assert.equal(d3.draftHash, d2.draftHash, 'keep on a non-roleRisk item is a no-op for the signed content');
  assert.ok(d3.items[0].flags.includes('reviewed-keep'));
  await assert.rejects(s.review({ draftId: d0.draftId, memberId: 'a', itemId: 'nope', action: 'keep' }), { code: 'unknown_item' });
  await assert.rejects(s.review({ draftId: 'zz', memberId: 'a', itemId: 'i1', action: 'keep' }), { code: 'unknown_draft' });

  // rejections
  const bad = sign('a', d3); bad.sig = sign('a', d3).sig; // signature over a different nonce
  assert.throws(() => s.approve(bad), { code: 'bad_sig' });
  assert.throws(() => s.approve({ ...sign('a', d3), memberId: 'zz' }), { code: 'not_member' });
  assert.throws(() => s.approve(sign('b', d3, randomUUID(), 'x')), { code: 'key_mismatch' }, 'b has a roster key');
  assert.throws(() => s.approve(sign('a', d3, randomUUID(), 'x')), { code: 'key_mismatch' }, 'a pinned key on first approve (TOFU)');
  assert.throws(() => s.approve({ ...sign('a', d3), draftId: 'nope' }), { code: 'unknown_draft' });

  const n = randomUUID();
  assert.deepEqual(s.approve(sign('a', d3, n)), { approvals: 1, k: 2, released: false });
  assert.throws(() => s.approve(sign('a', d3, n)), { code: 'replay' });
  assert.throws(() => s.approve(sign('c', d3, n)), { code: 'replay' }, 'nonces are global per session');
  assert.equal(s.approve(sign('a', d3)).approvals, 1, 'same member twice counted once');
  assert.equal(s.released(d0.draftId), null);
  const r = s.approve(sign('c', d3));
  assert.deepEqual(r, { approvals: 2, k: 2, released: true });

  const rel = s.released(d0.draftId);
  assert.ok(rel.text.startsWith('会议纪要 · 不署名 / Minutes · no attribution'));
  assert.equal(rel.items.length, d3.items.length);
  assert.deepEqual(rel.items.map((i) => Object.keys(i).sort()), rel.items.map(() => ['id', 'kind', 'text']));
  for (const p of roster) assert.ok(!rel.text.includes(p.name));
  assert.ok(!rel.text.includes(cutTarget.text), 'cut item not released');
  await assert.rejects(s.review({ draftId: d0.draftId, memberId: 'a', itemId: d3.items[0].id, action: 'cut' }), { code: 'already_released' });

  // memory got the release (no speaker), recall finds it
  const list = memory.list();
  assert.equal(list.length, rel.items.length);
  assert.ok(list.every((x) => x.sid === 'S-1' && x.approvals === 2 && !('speaker' in x) && !('speakerId' in x)));
  assert.ok(memory.recall('评估报告').length >= 1);
  const todo = memory.list().find((x) => x.kind === 'todo');
  assert.equal(memory.retract(todo.id, 'b'), false, 'b did not approve');
  assert.equal(memory.retract(todo.id, 'c'), true);

  // end wipes raw text
  const receipt = s.end();
  assert.equal(receipt.sid, 'S-1');
  assert.deepEqual(receipt.counts, { utterances: 5, drafts: 1, releases: 1, approvals: 3 }, 'approvals = all accepted signatures incl. one invalidated by review; utterances incl. non-final');
  assert.match(receipt.sha256, /^[0-9a-f]{64}$/);
  assert.equal(s.end(), receipt, 'idempotent');
  // Everything internal except the released (approved, de-identified) output must be free of raw text.
  const { released: keptReleased, ...internals } = s._inspect();
  assert.equal(keptReleased.length, 1);
  for (const [, text] of UTTS) assert.ok(!keptReleased[0][1].text.includes(text), 'no verbatim utterance in release');
  const dump = JSON.stringify(internals);
  const strings = deepStrings(internals);
  for (const [, text] of UTTS) {
    for (const frag of [text, text.slice(0, 12), text.slice(-12)]) assert.ok(!dump.includes(frag), `raw text leaked: ${frag}`);
  }
  assert.ok(!dump.includes('interim words'));
  for (const p of roster) { assert.ok(!dump.includes(p.name), `name leaked: ${p.name}`); assert.ok(!strings.includes(p.org)); }
  assert.ok(!dump.includes(cutTarget.text));
  for (const fn of [() => s.ingest({ speakerId: 'a', text: 'x', ts: 1 }), () => s.join({ id: 'q' }), () => s.leave('a'), () => s.approve(sign('a', d3))])
    assert.throws(fn, { code: 'ended' });
  await assert.rejects(s.draft(), { code: 'ended' });
  await assert.rejects(s.ask({ askerId: 'a', question: 'x' }), { code: 'ended' });
  assert.equal(s.released(d0.draftId).text, rel.text, 'released text survives end');
});

test('roleRisk items are not released unless reviewed (fail closed); reason is review-only', async () => {
  const memory = createMemory({ circleId: 'c' });
  const gate = {
    NOTICE: '会议纪要 · 不署名 / Minutes · no attribution',
    async runGate(transcript, opts) {
      assert.equal(opts.mock, true); assert.equal(opts.llm, null);
      assert.equal(transcript.lines.length, 4);
      return { claims: [
        { topic: 'T1', text: 'Risky claim pointing at the CFO.', kind: 'idea', flags: [], risk: 'role-revealing', confidence: 0.9, reason: 'Alice Wang', guess: 'a' },
        { topic: 'T1', text: 'Safe claim.', kind: 'decision', flags: ['tone-neutralised'] },
      ], meta: { ms: 1 } };
    },
  };
  const { s, sign } = setup({ memory, gate });
  const d = await s.draft();
  assert.equal(d.items[0].roleRisk, true);
  assert.equal(d.items[0].reason, 'Alice Wang');
  assert.ok(d.items[0].flags.includes('role-revealing'));
  s.approve(sign('a', d));
  assert.equal(s.approve(sign('b', d)).released, true);
  const rel = s.released(d.draftId);
  assert.ok(!rel.text.includes('Risky') && rel.text.includes('Safe claim.'));
  assert.deepEqual(rel.items.map((i) => i.text), ['Safe claim.']);
  assert.ok(!JSON.stringify(memory.toJSON()).includes('Alice'));
  assert.deepEqual(memory.list().map((x) => x.kind), ['decision']);

  // keep clears roleRisk -> released
  const s2 = setup({ gate }).s, sg2 = setup({ gate });
  const dd = await sg2.s.draft();
  sg2.s.approve(sg2.sign('b', dd));
  const kept = await sg2.s.review({ draftId: dd.draftId, memberId: 'c', itemId: dd.items[0].id, action: 'keep' });
  assert.notEqual(kept.draftHash, dd.draftHash, 'keep of a roleRisk item changes the hash');
  assert.equal(kept.metrics.approvals, 0, 'and clears approvals');
  assert.equal(kept.items[0].roleRisk, false);
  assert.equal(kept.items[0].reason, undefined);
  sg2.s.approve(sg2.sign('a', kept)); sg2.s.approve(sg2.sign('c', kept));
  assert.equal(sg2.s.released(dd.draftId).items.length, 2);
  s2.end();
});

test('generalise uses llm when present; ask uses recall context via llm', async () => {
  const memory = createMemory({ circleId: 'c' });
  memory.addRelease({ sid: 'old', draftId: 'd', approvals: 2, k: 2, items: [{ text: '上次决定：预算冻结到年底。', kind: 'decision' }] });
  const llm = createScriptedLLM((messages) => {
    const user = messages.find((m) => m.role === 'user').content;
    if (/CIRCLE KNOWLEDGE/.test(user)) {
      assert.ok(user.includes('预算冻结到年底'), 'prompt has recalled knowledge');
      assert.ok(user.includes('Alice Wang: '), 'in-room transcript keeps speakers');
      assert.ok(!user.includes('interim'), 'non-final excluded');
      return '上次定的是预算冻结到年底。';
    }
    if (/more general/.test(messages[0].content)) return { text: 'A general statement by Alice Wang.' };
    throw new Error('unexpected prompt');
  });
  const gate = { async runGate(tr, opts) { assert.equal(opts.llm, llm); assert.equal(opts.mock, false); return { claims: [{ topic: 'T', text: 'Specific 20% cut', kind: 'decision' }], meta: {} }; } };
  const { s } = setup({ memory, llm, gate });
  const { answer } = await s.ask({ askerId: 'b', question: '上次我们预算定了什么？' });
  assert.equal(answer, '上次定的是预算冻结到年底。');
  const d = await s.draft();
  const g = await s.review({ draftId: d.draftId, memberId: 'a', itemId: d.items[0].id, action: 'generalise' });
  assert.equal(g.items[0].text, 'A general statement by .'.replace(' .', ' .'));
  assert.ok(!g.items[0].text.includes('Alice'));
  assert.ok(!JSON.stringify(s._inspect()).includes('上次我们预算定了什么'), 'ask not retained');
});

test('mock ask (llm null) answers from recall + buffer', async () => {
  const memory = createMemory({ circleId: 'c' });
  memory.addRelease({ sid: 'old', draftId: 'd', approvals: 2, k: 2, items: [{ text: 'The audit timeline was agreed last time.' }] });
  const { s } = setup({ memory });
  const { answer } = await s.ask({ askerId: 'a', question: 'what about the audit?' });
  assert.match(answer, /audit timeline was agreed/);
  assert.match(answer, /rollout should wait/);
});

test('draftHash binds text, kind, roleRisk; ring buffer bounded', async () => {
  const items = [{ id: 'i1', text: 'x', kind: 'idea', roleRisk: false, topic: 'T' }];
  const h = computeDraftHash('s', 'd', items);
  assert.notEqual(h, computeDraftHash('s', 'd', [{ ...items[0], text: 'y' }]));
  assert.notEqual(h, computeDraftHash('s', 'd', [{ ...items[0], kind: 'todo' }]));
  assert.notEqual(h, computeDraftHash('s', 'd', [{ ...items[0], roleRisk: true }]));
  assert.notEqual(h, computeDraftHash('s2', 'd', items));
  const s = createSession({ sid: 'b', roster: [{ id: 'a', name: 'A A' }], policy: { k: 1, bufferSize: 3 } });
  for (let i = 0; i < 10; i++) s.ingest({ speakerId: 'a', text: `line number ${i}.`, ts: i, final: true });
  const st = s._inspect();
  assert.equal(st.buffer.length, 3);
  assert.equal(st.buffer[0].text, 'line number 7.');
  const d = await s.draft({ fromTs: 8, toTs: 9 });
  assert.equal(d.metrics.lines, 2);
});

test('join registers key (TOFU) and approve accepts PEM; k=1 single release', async () => {
  const kp = generateEd25519();
  const s = createSession({ sid: 'j', roster: [], policy: { k: 1 } });
  s.join({ id: 'm', name: 'Zed Q', pubKey: kp.pem });
  s.ingest({ speakerId: 'm', text: 'We agreed to ship on Friday.', ts: 1, final: true });
  const d = await s.draft();
  const nonce = 'n1';
  const sig = signEd25519(kp.privateKey, approvalMessage({ sid: 'j', draftId: d.draftId, draftHash: d.draftHash, nonce }));
  assert.throws(() => s.approve({ draftId: d.draftId, draftHash: d.draftHash, memberId: 'm', pubKey: generateEd25519().pubB64, sig, nonce }), { code: 'key_mismatch' });
  assert.equal(s.approve({ draftId: d.draftId, draftHash: d.draftHash, memberId: 'm', pubKey: kp.pem, sig, nonce: nonce }).released, true);
  assert.throws(() => s.join({ id: 'm', pubKey: generateEd25519().pubB64 }), { code: 'key_mismatch' });
});

test('leave({forgetKey}) unpins the key so a rejoin can register a fresh one', () => {
  const s = createSession({ sid: 'fk', roster: [], policy: { k: 1 } });
  s.join({ id: 'm', name: 'Zed Q', pubKey: generateEd25519().pubB64 });
  s.leave('m');
  assert.throws(() => s.join({ id: 'm', pubKey: generateEd25519().pubB64 }), { code: 'key_mismatch' }, 'plain leave keeps the pin');
  s.leave('m', { forgetKey: true });
  assert.doesNotThrow(() => s.join({ id: 'm', pubKey: generateEd25519().pubB64 }));
});
