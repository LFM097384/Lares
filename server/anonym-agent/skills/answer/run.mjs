// answer skill —— 只读 ctx.ledger + ctx.memory(见 SKILL.md)。
const SYSTEM = `You are 炉灵助理 (Lares Assistant), the AI assistant sitting in a private, anonymised meeting. If asked who you are, say you are 炉灵助理 / Lares Assistant.
You see only an anonymised running ledger (speakers are pseudonyms P1, P2, …) and released circle memory. You never see real names.
Answer the participant's question in its language, at most 120 Chinese characters or 80 words. Use only the ledger, the memory and public world knowledge; if the ledger does not cover it, say so.
Never speculate about who a pseudonym is, and never mention anyone's role, organisation or life facts.
Output only JSON: {"answer":"..."}`;

export default async function run(ctx) {
  const q = String(ctx.q ?? ctx.args?.q ?? '').trim();
  if (!q) return { text: '' };
  const mem = await ctx.memory.recall(q, { limit: 5 });
  const ledgerText = ctx.ledger.text({ maxChars: 8000 });
  if (!ctx.llm) {
    const words = [...new Set(q.replace(/[\s\p{P}]/gu, '').match(/[\u3400-\u9fff]{2}|[A-Za-z]{3,}/g) ?? [])];
    const hits = ctx.ledger.entries().filter((e) => words.some((w) => e.text.includes(w))).slice(-3).map((e) => e.text);
    const memHits = mem.slice(0, 2).map((m) => m.text);
    const all = [...hits, ...memHits];
    return { text: all.length ? all.join('；') : '账本里还没有相关内容。' };
  }
  const user = `LEDGER:\n${ledgerText || '(empty)'}\n\nMEMORY:\n${mem.map((m) => `- ${m.text}`).join('\n') || '(none)'}\n\nQUESTION: ${q}`;
  const r = await ctx.llm.chat([{ role: 'system', content: SYSTEM }, { role: 'user', content: user }], { json: true, temperature: 0.3, maxTokens: 600 });
  let a = '';
  try { a = String(ctx.parseJSON(r.text)?.answer ?? ''); } catch { a = String(r.text ?? ''); }
  return { text: a.trim().slice(0, 600) };
}
