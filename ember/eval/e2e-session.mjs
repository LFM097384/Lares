// Real-LLM end-to-end smoke of one 隐名之约 session (no network unless LARES_AI_LLM_KEY set).
// Usage: $env:LARES_AI_LLM_KEY=...; node ember/eval/e2e-session.mjs
import { createSession } from '../core/index.mjs';
import { createMemory } from '../core/memory.mjs';
import { createDeepSeekLLM } from '../core/gate/llm.mjs';
import { generateKeyPairSync, sign, randomBytes } from 'node:crypto';
import { canonicalJSON } from '../core/index.mjs';

const key = process.env.LARES_AI_LLM_KEY;
if (!key) { console.log('no key; skip'); } else {
  const llm = createDeepSeekLLM({ key, model: process.env.LARES_AI_LLM_MODEL || 'deepseek-flash' });
  const roster = [
    { id: 'u1', name: '王建国', org: '星河出版社', title: '总编辑' },
    { id: 'u2', name: '李梅', org: '市卫健委', title: '处长' },
    { id: 'u3', name: '陈默', title: '作家', works: ['《夜航的灯》'] },
  ];
  const memory = createMemory({ circleId: 'c1', roster, llm });
  const s = createSession({ sid: 's-e2e', roster, policy: { k: 2 }, llm, memory });
  const keys = {};
  for (const m of roster) { keys[m.id] = generateKeyPairSync('ed25519'); s.join({ ...m, pubKey: keys[m.id].publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64') }); }
  const lines = [
    ['u1', '我最近重读了《三体》，刘慈欣写黑暗森林那段，其实很适合拿来讲行业里的信任问题。'],
    ['u2', '哎呀，王总编的方案真是太"高瞻远瞩"了，我们卫健委这种小地方可跟不上，呵呵。'],
    ['u3', '我那本《夜航的灯》里写过类似的困境，读者反馈说太悲观了。'],
    ['u1', '我建议出版业和医疗系统合作做一个科普丛书，明年第一季度先出三本。'],
    ['u2', '预算从哪里出？我不觉得这能落地。'],
  ];
  let ts = Date.now();
  for (const [sp, t] of lines) s.ingest({ speakerId: sp, text: t, ts: ts += 1000, final: true });
  const q = await s.ask({ askerId: 'u1', question: '刚才大家对科普丛书方案的主要分歧是什么？' });
  console.log('ASK →', q.answer);
  let d = await s.draft({});
  console.log('DRAFT items:');
  for (const it of d.items) console.log(' -', it.roleRisk?.toFixed?.(2) ?? it.roleRisk, it.text, it.flags?.length ? JSON.stringify(it.flags) : '');
  for (const id of ['u1', 'u2']) {
    const nonce = randomBytes(16).toString('base64url');
    const msg = canonicalJSON({ sid: 's-e2e', draftId: d.draftId, draftHash: d.draftHash, nonce });
    const sig = sign(null, Buffer.from(msg), keys[id].privateKey).toString('base64');
    const r = await s.approve({ draftId: d.draftId, draftHash: d.draftHash, memberId: id, nonce, sig });
    console.log('approve', id, r.approvals, '/', r.k, r.released);
  }
  const rel = s.released(d.draftId);
  console.log('RELEASED →\n' + rel?.text);
  const out = rel?.text || '';
  const checks = {
    'public fact kept (三体/刘慈欣)': /三体/.test(out) && /刘慈欣/.test(out),
    'no participant names': !/王建国|李梅|陈默|王总编/.test(out),
    'no affiliation': !/星河出版社|卫健委/.test(out),
    'self-authored work removed': !/夜航的灯/.test(out),
    'sarcasm neutralised': !/高瞻远瞩|呵呵|小地方/.test(out),
  };
  console.log(checks);
  const r = s.end();
  console.log('receipt', r);
  const recalled = await memory.recallForOutput('科普丛书', { limit: 5 });
  console.log('knowledge recall', recalled.map((x) => x.text));
  process.exitCode = Object.values(checks).every(Boolean) ? 0 : 1;
}
