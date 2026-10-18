// Chatham Gate orchestrator ("Rule-inspired" tier). Not a claim of Chatham House compliance.
import { structural } from './l0.mjs';
import { redactPII } from './l1.mjs';
import { redactAffiliation } from './l2.mjs';
import { rewrite } from './l3.mjs';
import { verify } from './l4.mjs';

export const NOTICE = 'Rule-inspired digest: no attribution.';

function render(sections, sessionDate) {
  const date = String(sessionDate || '').slice(0, 10).match(/^\d{4}-\d{2}-\d{2}$/) ? String(sessionDate).slice(0, 10) : 'undated';
  const md = [NOTICE, '', `# Digest (session ${date})`];
  for (const s of sections) {
    if (!s.claims.length) { continue; }
    md.push('', `## ${s.topic}`, ...s.claims.map((c) => `- ${String(c).replace(/\s*\n+\s*/g, ' ')}`));
  }
  return md.join('\n') + '\n';
}

export async function runGate(transcript, { layers = ['L0', 'L1', 'L2', 'L3', 'L4'], mock = !process.env.CHATHAM_LLM_KEY, threshold = 0.5, flagThreshold = 0.7, maxVerifierRounds = 2, seed = 1 } = {}) {
  const t0 = Date.now();
  const roster = transcript.roster || [];
  const lines = transcript.lines || [];
  const stats = { calls: 0, promptTokens: 0, completionTokens: 0 };
  const L = new Set(layers.map((x) => String(x).toUpperCase()));
  if (L.has('L3') && !L.has('L1')) { L.add('L1'); L.add('L2'); } // the LLM must never see raw names
  const applied = ['L0', 'L1', 'L2', 'L3', 'L4'].filter((x) => L.has(x));
  const meta = (extra) => ({ layers: applied, mock: !!mock, llmCalls: stats.calls, promptTokens: stats.promptTokens, completionTokens: stats.completionTokens, ms: Date.now() - t0, verifierRounds: 0, dropped: 0, ...extra });

  if (!L.size) {
    const raw = lines.map((l) => `${l.speakerName}: ${l.text}`);
    return { digest: raw.join('\n') + '\n', claims: raw.map((text) => ({ topic: 'raw', text })), meta: meta({}) };
  }

  let clusters = L.has('L0') ? structural(lines, { seed }) : [{ topic: 'Discussion', segments: lines.map((l) => l.text) }];
  const scrub = (s) => { if (L.has('L1')) s = redactPII(s, roster); if (L.has('L2')) s = redactAffiliation(s, roster); return s; };
  clusters = clusters.map((c) => ({ topic: scrub(c.topic), segments: c.segments.map(scrub) }));

  let sections = L.has('L3')
    ? await rewrite(clusters, { mock, stats, lang: transcript.lang })
    : clusters.map((c) => ({ topic: c.topic, claims: c.segments }));

  let verifierRounds = 0, dropped = 0;
  if (L.has('L4')) {
    const v = await verify(sections, roster, { mock, stats, threshold, flagThreshold, maxRounds: maxVerifierRounds });
    sections = v.sections; verifierRounds = v.rounds; dropped = v.dropped;
  }

  // Final safety pass over LLM output with the requested deterministic layers
  // (so ablation rows stay honest: "L0+L1" never silently gets L2).
  const safe = (s) => scrub(String(s));
  const norm = (c) => (typeof c === 'string' ? { text: c } : c);
  sections = sections
    .map((s) => ({ topic: safe(s.topic), claims: s.claims.map(norm).map((c) => ({ ...c, text: safe(c.text) })).filter((c) => c.text.trim()) }))
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
