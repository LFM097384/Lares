// minutes skill —— 只读 ctx.ledger(见 SKILL.md)。产出出门稿条目,agent 负责 L4 / 审阅 / 签名放行。
const SYSTEM = `You are 炉灵 (Ember), the AI assistant of a private meeting. You turn an anonymised meeting ledger into exportable minutes. Speakers appear only as pseudonyms (P1, P2, …): DROP every pseudonym and every attribution — use impersonal phrasing ("有观点认为……", "与会者一致同意……", "It was argued that …").
Group into topics (2–6 words naming the subject, never people). Each item is ONE claim of kind:
- idea (a view, proposal, concern, open question),
- decision (something agreed / decided),
- todo (an action item, no owner),
- fact (a public world fact, e.g. a well-known book and its author — keep it verbatim and flag "public-fact").
Keep numbers and stance direction/strength; keep tone neutral (never quote sarcasm). Do not invent content. Write in the ledger's dominant language.
Output only JSON: {"sections":[{"topic":"...","items":[{"kind":"idea","text":"...","flags":[]}]}]}`;
const KINDS = new Set(['idea', 'decision', 'todo', 'fact']);

export default async function run(ctx) {
  const entries = ctx.ledger.entries();
  if (!entries.length) return { items: [] };
  if (!ctx.llm) {
    const items = entries.map((e) => ({
      topic: e.topic || (e.kind === 'decision' ? '决定' : e.kind === 'todo' ? '待办' : e.kind === 'fact' ? '公共事实' : '讨论'),
      kind: KINDS.has(e.kind) ? e.kind : 'idea',
      text: e.text,
      flags: e.flags.filter((f) => f === 'public-fact'),
    }));
    return { items };
  }
  const r = await ctx.llm.chat([{ role: 'system', content: SYSTEM }, { role: 'user', content: `LEDGER:\n${ctx.ledger.text({ maxChars: 16000 })}\n\nReturn the JSON minutes now.` }],
    { json: true, temperature: 0.2, maxTokens: 4000 });
  let data = null;
  try { data = ctx.parseJSON(r.text); } catch { data = null; }
  const items = [];
  for (const s of Array.isArray(data?.sections) ? data.sections : []) {
    const topic = String(s?.topic ?? '').trim() || '讨论';
    for (const it of Array.isArray(s?.items) ? s.items : []) {
      const text = String(it?.text ?? '').trim();
      if (!text) continue;
      const flags = (Array.isArray(it?.flags) ? it.flags : []).map(String).filter((f) => f === 'public-fact');
      items.push({ topic, kind: KINDS.has(it?.kind) ? it.kind : 'idea', text, flags });
    }
  }
  return { items };
}
