// 真 LLM 抽查(无 key 时跳过):脚本对话 → IngestGate(真 L3)→ minutes skill → L4 → 草稿。
//   $env:LARES_AI_LLM_KEY='…'; $env:LARES_AI_LLM_MODEL='deepseek-flash'; node --test server/bots/anonym-agent/
// 断言:公共事实(《三体》是刘慈欣写的)保留;反讽句不被原样引用;名字 / 原话不进任何 prompt;纪要不带假名。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { runAnonAgent, llmFromEnv } from '../index.mjs';
import { FakeRoom, client } from './helpers.mjs';

const hasKey = Boolean(process.env.LARES_AI_LLM_KEY || process.env.LARES_AI_LLM_API_KEY);
const PEOPLE = [{ id: 'u_zhang', name: '张伟' }, { id: 'u_chen', name: '陈晓燕' }, { id: 'u_liu', name: '刘洋' }];
const SCRIPT = [
  ['u_zhang', '我是张伟，我觉得读书会下个月可以读《三体》，毕竟《三体》是刘慈欣写的，大家都熟。'],
  ['u_chen', '哦是吗，那可真是太有新意了呢，又是三体，我们是不是每年都要读一遍？'],
  ['u_liu', '陈晓燕说得有道理，要不三体和一本新书二选一，下周三前大家投票。'],
  ['u_zhang', '行，那就这么定了：下周三前投票，刘洋负责发投票链接。'],
];
const SARCASM = '那可真是太有新意了呢';

test('真 LLM:IngestGate + minutes 保留公共事实、中和反讽、不泄名字', { skip: !hasKey && 'no LARES_AI_LLM_KEY', timeout: 240_000 }, async () => {
  const base = await llmFromEnv(process.env);
  const calls = [];
  const l3 = [];
  const llm = { async chat(messages, opts) { const t = messages.map((m) => m.content).join('\n'); (/rewrite lines of a live/.test(messages[0]?.content) ? l3 : calls).push(t); return base.chat(messages, opts); } };
  const room = new FakeRoom(PEOPLE);
  const dir = mkdtempSync(path.join(os.tmpdir(), 'anon-real-'));
  try {
    const bot = await runAnonAgent({ circleId: 'c_real', room, asr: null, llm, memoryDir: dir, env: {}, hosted: false, log: (m) => process.stderr.write(`[agent] ${m}\n`) });
    const { agent } = bot;
    const keys = PEOPLE.map((p) => client(p.id));
    for (const c of keys) room.msg(c.id, { t: 'ack', pubKey: c.pubKey });
    for (const [id, text] of SCRIPT) agent.onTranscript(id, text);
    await agent.ingest.flush();
    const ledger = agent.ingest.ledgerView().text();
    process.stderr.write(`\n--- LEDGER ---\n${ledger}\n`);
    assert.ok(agent.ingest.ledgerView().size >= 2, 'ledger 非空');
    assert.doesNotMatch(ledger, /张伟|陈晓燕|刘洋/);

    await agent.onMessage('u_chen', { t: 'ask', q: '请帮我们出一份这次会议的纪要' });
    const d = room.last('draft')?.draft;
    assert.ok(d, `draft 生成(errors: ${JSON.stringify(room.of('error'))})`);
    const body = d.items.map((i) => `[${i.kind}${i.roleRisk ? ',risk' : ''}] ${i.topic} :: ${i.text}`).join('\n');
    process.stderr.write(`--- DRAFT ---\n${body}\n`);
    const all = d.items.map((i) => i.text).join('\n');
    assert.match(all, /三体/, '公共事实:书名');
    assert.match(all, /刘慈欣/, '公共事实:作者');
    assert.ok(!all.includes(SARCASM) && !ledger.includes(SARCASM), '反讽不原样出现');
    assert.doesNotMatch(all, /张伟|陈晓燕|刘洋|\bP\d+\b/);

    const st = room.last('state');
    for (const c of keys.slice(0, st.k)) await agent.onMessage(c.id, c.approve(st, room.last('draft').draft));
    const rel = room.last('released');
    process.stderr.write(`--- RELEASED ---\n${rel?.text}\n`);
    assert.ok(rel, '放行');
    assert.doesNotMatch(rel.text, /张伟|陈晓燕|刘洋/);

    // L3(入口改写)按定义只见 L0–L2 之后的文本;其余所有调用(路由 / skill / L4 / 泛化)只见 ledger 派生文本
    assert.doesNotMatch([...l3, ...calls].join('\n'), /张伟|陈晓燕|刘洋/, 'LLM 没见过名字');
    const seen = calls.join('\n');
    for (const [, raw] of SCRIPT) assert.ok(!seen.includes(raw) && !seen.includes(SARCASM), 'L3 之后的 LLM 调用没见过原话');
    process.stderr.write(`--- LLM calls: L3 ${l3.length}, other ${calls.length} ---\n`);
    await bot.stop();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
