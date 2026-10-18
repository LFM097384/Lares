// Gate v2 orchestrator ("Rule-inspired" tier). Not a claim of Chatham House compliance.
// No env reads: the caller injects `llm` ({ chat(messages, opts) -> { text, usage?, finish? } }); llm == null → mock.
import { structural } from './l0.mjs';
import { redactPII } from './l1.mjs';
import { redactAffiliation } from './l2.mjs';
import { rewrite, claimKind } from './l3.mjs';
import { verify } from './l4.mjs';

export const NOTICE = '会议纪要 · 不署名 / Minutes · no attribution';

function render(sections, sessionDate) {
  const date = String(sessionDate || '').slice(0, 10).match(/^\d{4}-\d{2}-\d{2}$/) ? String(sessionDate).slice(0, 10) : 'undated';
  const md = [NOTICE, '', `# Digest (session ${date})`];
  for (const s of sections) {
    if (!s.claims.length) { continue; }
    md.push('', `## ${s.topic}`, ...s.claims.map((c) => `- ${String(c).replace(/\s*\n+\s*/g, ' ')}`));
  }
  return md.join('\n') + '\n';
}

const KINDS = new Set(['idea', 'decision', 'todo', 'fact']);
const normClaim = (c) => {
  const o = typeof c === 'string' ? { text: c } : { ...c };
  o.flags = [...new Set(Array.isArray(o.flags) ? o.flags : [])];
  if (!KINDS.has(o.kind)) o.kind = claimKind(o.text, o.flags);
  return o;
};

// runGate({ roster, lines, sessionDate, lang }, { llm, layers, threshold, flagThreshold, maxVerifierRounds, seed, allowPublicFacts, stats })
//  -> { digest, digestStrict, claims:[{ topic, text, kind, flags[], risk?, confidence?, reason?, guess? }], meta }
export async function runGate(transcript, {
  llm = null, layers = ['L0', 'L1', 'L2', 'L3', 'L4'], threshold = 0.5, flagThreshold = 0.7,
  maxVerifierRounds = 2, seed = 1, allowPublicFacts = true, stats,
} = {}) {
  const t0 = Date.now();
  const roster = transcript?.roster || [];
  const lines = transcript?.lines || [];
  stats = stats || {};
  for (const k of ['calls', 'promptTokens', 'completionTokens']) stats[k] = stats[k] || 0;
  const base = { calls: stats.calls, promptTokens: stats.promptTokens, completionTokens: stats.completionTokens };
  const L = new Set(layers.map((x) => String(x).toUpperCase()));
  if ((L.has('L3') || L.has('L4')) && !L.has('L1')) { L.add('L1'); L.add('L2'); } // the LLM must never see raw names
  const applied = ['L0', 'L1', 'L2', 'L3', 'L4'].filter((x) => L.has(x));
  const meta = (extra) => ({
    layers: applied, mock: !llm, allowPublicFacts,
    llmCalls: stats.calls - base.calls, promptTokens: stats.promptTokens - base.promptTokens, completionTokens: stats.completionTokens - base.completionTokens,
    ms: Date.now() - t0, verifierRounds: 0, dropped: 0, ...extra,
  });

  if (!L.size) {
    const raw = lines.map((l) => `${l.speakerName}: ${l.text}`);
    const d = raw.join('\n') + '\n';
    return { digest: d, digestStrict: d, claims: raw.map((text) => ({ topic: 'raw', text, kind: 'idea', flags: [] })), meta: meta({ flagged: 0 }) };
  }

  const popts = { allowPublicFacts };
  let clusters = L.has('L0') ? structural(lines, { seed }) : [{ topic: 'Discussion', segments: lines.map((l) => l.text) }];
  const scrub = (s) => { if (L.has('L1')) s = redactPII(s, roster, popts); if (L.has('L2')) s = redactAffiliation(s, roster, popts); return s; };
  clusters = clusters.map((c) => ({ topic: scrub(c.topic), segments: c.segments.map(scrub) }));

  let sections = L.has('L3')
    ? await rewrite(clusters, { llm, stats, lang: transcript.lang })
    : clusters.map((c) => ({ topic: c.topic, claims: c.segments }));

  let verifierRounds = 0, dropped = 0;
  if (L.has('L4')) {
    const v = await verify(sections, roster, { llm, stats, threshold, flagThreshold, maxRounds: maxVerifierRounds });
    sections = v.sections; verifierRounds = v.rounds; dropped = v.dropped;
  }

  // Final safety pass over LLM output with the requested deterministic layers
  // (so ablation rows stay honest: "L0+L1" never silently gets L2).
  const safe = (s) => scrub(String(s ?? ''));
  sections = sections
    .map((s) => ({ topic: safe(s.topic), claims: s.claims.map(normClaim).map((c) => ({ ...c, text: safe(c.text) })).filter((c) => c.text.trim()) }))
    .filter((s) => s.claims.length);

  // claims[] is review metadata (risk flags + attacker reason may reference attendees: never export it).
  const claims = sections.flatMap((s) => s.claims.map((c) => ({ topic: s.topic, ...c })));
  const flagged = claims.filter((c) => c.risk).length;
  // digest = everything incl. flagged claims marked "[review: role-revealing]" (worst case: reviewers keep all);
  // digestStrict = flagged claims removed (reviewers cut all flagged).
  const mark = (strict) => sections.map((s) => ({ topic: s.topic, claims: s.claims.filter((c) => !(strict && c.risk)).map((c) => (c.risk ? `[review: role-revealing] ${c.text}` : c.text)) }));
  return {
    digest: render(mark(false), transcript.sessionDate),
    digestStrict: render(mark(true), transcript.sessionDate),
    claims,
    meta: meta({ verifierRounds, dropped, flagged }),
  };
}

// verifyClaims(texts, roster, { llm, threshold, flagThreshold, maxRounds, stats })
//  -> { items: [{ text, risk?, reason?, confidence? } | 'DROP'], flagged }
// Runs L4 over a flat list (single section). items[k] corresponds to texts[k]; a dropped claim is the string 'DROP'.
// Used by memory for the output-time mosaic check.
export const DROP = 'DROP';
export async function verifyClaims(texts, roster, { llm = null, threshold = 0.5, flagThreshold = 0.7, maxRounds = 2, stats } = {}) {
  const list = (texts || []).map((t) => String(t ?? ''));
  if (!list.length) return { items: [], flagged: 0 };
  const v = await verify([{ topic: 'recall', claims: list.map((text, k) => ({ text, _k: k, flags: [] })) }], roster || [], { llm, stats, threshold, flagThreshold, maxRounds });
  const items = list.map(() => DROP);
  for (const c of v.sections.flatMap((s) => s.claims)) {
    const it = { text: c.text };
    if (c.risk) { it.risk = c.risk; it.reason = c.reason; it.confidence = c.confidence; }
    items[c._k] = it;
  }
  return { items, flagged: items.filter((x) => x !== DROP && x.risk).length };
}
