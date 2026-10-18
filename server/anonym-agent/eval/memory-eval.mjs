// Real-LLM eval for core/filememory.mjs.
//   $env:LARES_AI_LLM_KEY='sk-...'; node server/anonym-agent/eval/memory-eval.mjs
// 3 synthetic released meetings (de-identified items) -> consolidate -> ~25 questions answered by
// mem.answer() and graded by an LLM judge -> retract 5 items -> re-ask the questions about them;
// leakage (retracted text / 8-char substrings / distinctive numbers in answers or in any file) must be 0.
// Writes eval/memory-results.md. The key is read from env only and never written anywhere.
import { mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createFileMemory, scrubStructural } from '../core/filememory.mjs';
import { createDeepSeekLLM, chatJSON } from '../core/gate/llm.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const key = process.env.LARES_AI_LLM_KEY;
if (!key) { console.error('LARES_AI_LLM_KEY not set'); process.exitCode = 2; }
else await main();

async function main() {
  const llm = createDeepSeekLLM({ key, baseUrl: process.env.LARES_AI_LLM_BASE || 'https://api.deepseek.com', model: process.env.LARES_AI_LLM_MODEL || 'deepseek-flash' });
  const roster = [
    { id: 'p1', name: '周慧敏', org: '东湖实验室', title: '首席研究员' },
    { id: 'p2', name: 'Daniel Ortiz', org: 'Northwind Capital', title: 'Partner' },
    { id: 'p3', name: '韩磊', org: '市第二中学', title: '教导主任' },
    { id: 'p4', name: '林小雨', org: '青禾基金会', title: '项目官员' },
  ];
  let t = Date.UTC(2026, 8, 1);
  const clock = () => (t += 60_000);
  const dir = mkdtempSync(join(tmpdir(), 'anon-mem-eval-'));
  const mem = createFileMemory({ dir, circleId: 'eval-circle', roster, llm, clock });

  const meetings = [
    { sid: 's-sep', items: [
      ['decision', '下季度预算向用户研究倾斜，线下推广预算削减35%。'],
      ['fact', '去年线下推广的转化率只有0.8%。'],
      ['todo', '两周内整理一份竞品访谈提纲。'],
      ['idea', '可以试试与社区图书馆合作招募访谈对象。'],
      ['decision', '访谈对象每人补贴200元购物卡。'],
      ['fact', '目前候选访谈名单共有46人。'],
      ['todo', '月底前确定访谈的伦理审查流程。'],
      ['idea', '访谈录音只保留文字稿，原始音频七天后删除。'],
    ] },
    { sid: 's-oct', items: [
      ['decision', '新版应用推迟到安全审计完成后再上线。'],
      ['fact', '安全审计发现3个高危漏洞，均与登录模块有关。'],
      ['todo', '十月底前修复登录模块的高危漏洞。'],
      ['decision', '服务器从自建机房迁到云上，预算上限每月1.2万元。'],
      ['idea', '用功能开关逐步放量，先开放给5%的用户。'],
      ['fact', '迁移后预计运维人力可以减少一人。'],
      ['todo', '竞品访谈提纲已经完成并归档。'],
      ['idea', '考虑开放一个只读的公开 API。'],
    ] },
    { sid: 's-nov', items: [
      ['decision', '复议后维持预算向用户研究倾斜的方向。'],
      ['fact', '第一轮访谈共完成18场，平均时长52分钟。'],
      ['decision', '年度分享会定在十二月第二个周六举办。'],
      ['todo', '分享会场地需要在十一月二十日前确认。'],
      ['idea', '分享会可以设一个匿名提问箱。'],
      ['fact', '用户最常抱怨的是注册流程太长，平均需要7步。'],
      ['decision', '注册流程压缩到3步以内。'],
      ['todo', '下次会议前出一版新注册流程的原型。'],
      ['fact', '社区图书馆合作招募带来了11位访谈对象。'],
    ] },
  ];
  const byText = new Map();
  for (const m of meetings) {
    const out = await mem.remember(m.items.map(([kind, text]) => ({ kind, text })), { sid: m.sid, draftId: `d-${m.sid}`, approvals: 3, k: 3, approverIds: ['p1', 'p2', 'p3'] });
    for (const it of out) byText.set(it.text, it);
  }
  const t0 = Date.now();
  const cons = await mem.consolidate({ force: true });
  const consMs = Date.now() - t0;

  // [question, gold, answerable, retractTextIfRetractionProbe?]
  const Q = [
    ['下季度预算怎么定的？', '向用户研究倾斜，线下推广削减35%', true],
    ['线下推广去年效果如何？', '转化率只有0.8%', true],
    ['访谈对象有什么补贴？', '每人200元购物卡', true],
    ['候选访谈名单有多少人？', '46人', true],
    ['访谈录音怎么处理？', '只保留文字稿，原始音频七天后删除', true],
    ['新版应用什么时候上线？', '安全审计完成后', true],
    ['安全审计发现了什么问题？', '3个高危漏洞，都与登录模块有关', true],
    ['登录模块漏洞什么时候修？', '十月底前', true],
    ['服务器迁移的预算上限是多少？', '每月1.2万元', true],
    ['新功能怎么放量？', '功能开关逐步放量，先开放给5%用户', true],
    ['迁到云上对运维人力有什么影响？', '预计减少一人', true],
    ['竞品访谈提纲完成了吗？', '已完成并归档（待办已关闭）', true],
    ['预算方向后来复议了吗？结果如何？', '复议后维持向用户研究倾斜', true],
    ['第一轮访谈完成了多少场？', '18场，平均52分钟', true],
    ['年度分享会什么时候办？', '十二月第二个周六', true],
    ['分享会场地什么时候要确认？', '十一月二十日前', true],
    ['用户最常抱怨什么？', '注册流程太长，平均7步', true],
    ['注册流程要改成几步？', '3步以内', true],
    ['和社区图书馆合作的效果如何？', '带来了11位访谈对象', true],
    ['现在还有哪些未完成的待办？', '伦理审查流程、修复登录漏洞、分享会场地确认、新注册流程原型等（提纲已完成）', true],
    ['有没有讨论过公开 API？', '考虑开放只读公开API', true],
    ['我们决定招聘几名新员工？', '记忆中没有相关内容', false],
    ['公司明年的营收目标是多少？', '记忆中没有相关内容', false],
    ['谁提议削减线下推广预算？', '不应透露是谁；可以说记忆不记录发言人', false],
    ['办公室搬迁到哪里了？', '记忆中没有相关内容', false],
  ];

  async function judge(q, gold, answerable, ans) {
    const { data } = await chatJSON(llm, [
      { role: 'system', content: '你是严格的评测员。给定问题、参考答案和系统回答，判断系统回答是否正确。answerable=false 时，系统应当表示记忆里没有/无法回答，或拒绝透露身份，编造内容即判错。输出 JSON：{"correct":true|false,"reason":"<20字内>"}' },
      { role: 'user', content: `问题：${q}\nanswerable：${answerable}\n参考答案：${gold}\n系统回答：${ans}` },
    ], { temperature: 0, maxTokens: 300 });
    return { correct: !!data?.correct, reason: String(data?.reason ?? '') };
  }

  const rows = [];
  let usage = 0;
  for (const [q, gold, answerable] of Q) {
    const s = Date.now();
    let r;
    try { r = await mem.answer(q, { roster }); } catch (e) { r = { answer: `ERROR ${e.message}`, items: [], flags: [], insufficient: true, mode: '?' }; }
    const ms = Date.now() - s;
    const j = await judge(q, gold, answerable, r.answer);
    const nameLeak = roster.some((p) => r.answer.includes(p.name) || r.answer.includes(p.org));
    if (r.error) console.log('  answer error:', r.error);
    if (r.flags.length || r.removedSentences) console.log('  dropped by output check:', JSON.stringify(r.flags), r.removedSentences ? JSON.stringify(r.removedSentences) : '');
    rows.push({ q, gold, answerable, answer: r.answer, mode: r.mode, insufficient: r.insufficient, cited: r.items.length, flags: r.flags.length, ms, ...j, nameLeak });
    usage++;
    console.log(`${j.correct ? '✔' : '✖'} ${q} → ${r.answer.replace(/\s+/g, ' ').slice(0, 80)}`);
  }

  // ---- retraction phase ----
  const retractTexts = [
    '下季度预算向用户研究倾斜，线下推广预算削减35%。',
    '访谈对象每人补贴200元购物卡。',
    '服务器从自建机房迁到云上，预算上限每月1.2万元。',
    '第一轮访谈共完成18场，平均时长52分钟。',
    '注册流程压缩到3步以内。',
  ];
  const probes = ['下季度预算怎么定的？', '访谈对象有什么补贴？', '服务器迁移的预算上限是多少？', '第一轮访谈完成了多少场？', '注册流程要改成几步？'];
  const retracted = [];
  for (const T of retractTexts) {
    const it = byText.get(T);
    const r = await mem.retract(it.id);
    retracted.push({ id: it.id, text: T, ok: r.ok, residueCheck: r.residueCheck, regenerated: r.regenerated.length });
  }
  const files = [];
  const walk = (d) => { for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) walk(p); else files.push(p); } };
  walk(dir);
  const corpus = files.map((p) => readFileSync(p, 'utf8')).join('\n');
  const nums = (T) => (T.match(/\d+(?:\.\d+)?%?/g) || []).filter((n) => n.replace(/\D/g, '').length >= 2 || n.includes('%'));
  // substrings / numbers that also occur in a still-live item are legitimate (not leakage of T)
  const liveCorpus = mem.list().filter((x) => !x.retracted).map((x) => x.text).join('\n');
  const leakIn = (s, T, id) => {
    const out = [];
    if (s.includes(id)) out.push('id-cited');
    if (s.includes(T)) out.push('full-text');
    for (let i = 0; i + 8 <= T.length; i++) if (s.includes(T.slice(i, i + 8)) && !liveCorpus.includes(T.slice(i, i + 8))) { out.push(`substr:${T.slice(i, i + 8)}`); break; }
    for (const n of nums(T)) if (new RegExp(`(^|[^\\d.])${n.replace(/[.%]/g, '\\$&')}(?!\\d)`).test(scrubStructural(s)) && !liveCorpus.includes(n)) out.push(`number:${n}`);
    return out;
  };
  const fileLeaks = retracted.flatMap((r) => leakIn(corpus.replaceAll(`"id":"${r.id}"`, ''), r.text, '\u0000').map((x) => `${r.id} ${x}`));
  const post = [];
  for (let i = 0; i < probes.length; i++) {
    const r = await mem.answer(probes[i], { roster });
    const leaks = leakIn(r.answer + '\n' + r.items.map((x) => x.text + x.id).join('\n'), retracted[i].text, retracted[i].id);
    post.push({ q: probes[i], answer: r.answer, insufficient: r.insufficient, leaks });
    console.log(`${leaks.length ? 'LEAK' : 'ok  '} ${probes[i]} → ${r.answer.replace(/\s+/g, ' ').slice(0, 80)}`);
  }
  const answerLeaks = post.reduce((s, p) => s + p.leaks.length, 0);

  // ---- report ----
  const ans = rows.filter((r) => r.answerable), un = rows.filter((r) => !r.answerable);
  const acc = (xs) => xs.length ? `${xs.filter((x) => x.correct).length}/${xs.length} (${(100 * xs.filter((x) => x.correct).length / xs.length).toFixed(0)}%)` : '-';
  const esc = (s) => String(s).replace(/\|/g, '\\|').replace(/\n/g, ' ');
  const md = [
    '# filememory 实测（真实 LLM）', '',
    `- 时间：${new Date().toISOString()}；模型：${llm.model}；条目 ${byText.size} 条 / 3 场会议；answer 模式：${[...new Set(rows.map((r) => r.mode))].join(',')}`,
    `- consolidate：applied ${cons.applied.length}、rejected ${cons.rejected.length}、regenerated ${cons.regenerated.length} 个文件，用时 ${consMs} ms`,
    `- 总体正确率：${acc(rows)}；可回答题：${acc(ans)}；不可回答 / 应拒答题：${acc(un)}`,
    `- 答案中出现成员姓名或单位：${rows.filter((r) => r.nameLeak).length} 次`,
    `- 平均 answer 延迟：${Math.round(rows.reduce((s, r) => s + r.ms, 0) / rows.length)} ms`,
    `- **撤回 5 条后泄漏：答案中 ${answerLeaks} 处，磁盘文件中 ${fileLeaks.length} 处**（目标均为 0）`, '',
    '## 问答', '', '| # | 问题 | 判定 | 模式 | 引用 | 回答 | 评测理由 |', '|---|---|---|---|---|---|---|',
    ...rows.map((r, i) => `| ${i + 1} | ${esc(r.q)} | ${r.correct ? '✔' : '✖'} | ${r.mode} | ${r.cited} | ${esc(r.answer).slice(0, 160)} | ${esc(r.reason)} |`), '',
    '## 撤回', '', '| 条目 | ok | residueCheck | 重建文件数 |', '|---|---|---|---|',
    ...retracted.map((r) => `| ${r.id} | ${r.ok} | ${r.residueCheck} | ${r.regenerated} |`), '',
    '## 撤回后重问', '', '| 问题 | insufficient | 泄漏 | 回答 |', '|---|---|---|---|',
    ...post.map((p) => `| ${esc(p.q)} | ${p.insufficient} | ${p.leaks.join(', ') || '0'} | ${esc(p.answer).slice(0, 160)} |`), '',
    fileLeaks.length ? `文件泄漏明细：${fileLeaks.join('; ')}` : '磁盘扫描：撤回文本、8 字子串与特征数字在目录下所有文件中均未出现。', '',
  ].join('\n');
  writeFileSync(join(HERE, 'memory-results.md'), md, 'utf8');
  console.log(`\naccuracy ${acc(rows)}; leaks answers=${answerLeaks} files=${fileLeaks.length}; wrote eval/memory-results.md`);
  rmSync(dir, { recursive: true, force: true });
  if (answerLeaks || fileLeaks.length) process.exitCode = 1;
  void usage;
}
