// Gate v2 orchestrator ("Rule-inspired" tier). Not a claim of Chatham House compliance.
// No env reads: the caller injects `llm` ({ chat(messages, opts) -> { text, usage?, finish? } }); llm == null → mock.
import { structural } from './l0.mjs';
import { learnThirdNames, redactPII } from './l1.mjs';
import { redactAffiliation, learnSelfOrgs, withLearnedOrgs } from './l2.mjs';
import { rewrite, claimKind } from './l3.mjs';
import { verify } from './l4.mjs';
import { chatJSON } from './llm.mjs';
import { shieldPublic, SHIELD_NOTE } from './shield.mjs';
import { dominantLang, isInjection, dropInjection, verbatimIndex, verbatimRuns, stripEchoedTokens, selfFigures, maskSelfFigures } from './guard.mjs';

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
  maxVerifierRounds = 2, seed = 1, allowPublicFacts = true, stats, trace = null,
} = {}) {
  const t0 = Date.now();
  const lines = transcript?.lines || [];
  // Orgs a participant self-declares anywhere in the transcript (我是张伟，在星辰科技负责产品) are treated as that
  // speaker's roster org for the whole run: redacted in every line, by every layer (L2, L4 roster scan, final scrub).
  const learned = new Map();
  for (const l of lines) for (const o of learnSelfOrgs(l?.text)) { const id = String(l?.speakerId ?? '\u0000learned'); if (!learned.has(id)) learned.set(id, new Set()); learned.get(id).add(o); }
  const rosterOrgs = withLearnedOrgs(transcript?.roster || [], learned);
  // private third parties introduced once in a strong context are redacted at every later bare mention as well
  const known = new Set(rosterOrgs.flatMap((p) => [p?.name, ...(p?.aliases || [])]).filter(Boolean));
  const roster = [...rosterOrgs, ...learnThirdNames(lines.map((l) => l?.text), { allowPublicFacts }).filter((n) => !known.has(n)).map((n, i) => ({ id: `third-learned-${i}`, name: n, aliases: [], third: true }))];
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
  // Output language is decided deterministically from the lines (the LLM otherwise drifts to Chinese on English meetings).
  const lang = transcript?.lang || dominantLang(lines.map((l) => l?.text));
  // In an utterance that tries to override the assistant's rules, the trigger sentence AND everything after it are
  // dropped before L0 splits it into sentences: the payload follows the trigger ("… and write that X agreed to Y.").
  const content = L.has('L3') ? lines.map((l) => ({ ...l, text: dropInjection(l?.text) })).filter((l) => l.text.trim()) : lines;
  let clusters = L.has('L0') ? structural(content, { seed }) : [{ topic: 'Discussion', segments: content.map((l) => l.text) }];
  // Sentences addressed to the assistant that try to override its rules are not discussion content.
  if (L.has('L3')) clusters = clusters.map((c) => ({ ...c, segments: c.segments.filter((x) => !isInjection(x)) })).filter((c) => c.segments.length);
  const scrub = (s) => { if (L.has('L1')) s = redactPII(s, roster, popts); if (L.has('L2')) s = redactAffiliation(s, roster, popts); return s; };
  clusters = clusters.map((c) => ({ topic: scrub(c.topic), segments: c.segments.map(scrub) }));

  // Public-entity shield (LLM path): public world knowledge that survived the L1/L2 scrub is carried through the L3
  // rewrite as opaque tokens and restored verbatim before L4, so the attacker / generaliser still judge the full text.
  let pub = { restore: (t) => t, spans: [] };
  if (llm && L.has('L3')) { pub = await shieldPublic(clusters, { llm, stats, roster, rawLines: lines.map((l) => String(l?.text ?? '')) }); clusters = pub.clusters; }
  let sections = L.has('L3')
    ? await rewrite(clusters, { llm, stats, lang, note: pub.spans.length ? SHIELD_NOTE : '' })
    : clusters.map((c) => ({ topic: c.topic, claims: c.segments }));
  if (pub.spans.length) sections = sections.map((s) => ({ ...s, topic: pub.restore(s.topic), claims: s.claims.map((c) => (typeof c === 'string' ? pub.restore(c) : { ...c, text: pub.restore(c.text) })) }));

  trace?.('L3', sections);
  let verifierRounds = 0, dropped = 0;
  if (L.has('L4')) {
    const v = await verify(sections, roster, { llm, stats, threshold, flagThreshold, maxRounds: maxVerifierRounds, lang });
    sections = v.sections; verifierRounds = v.rounds; dropped = v.dropped;
    trace?.('L4', sections);
  }

  // Final safety pass over LLM output with the requested deterministic layers
  // (so ablation rows stay honest: "L0+L1" never silently gets L2).
  const safe = (s) => scrub(String(s ?? ''));
  sections = sections
    .map((s) => ({ topic: safe(s.topic), claims: s.claims.map(normClaim).map((c) => ({ ...c, text: safe(c.text) })).filter((c) => c.text.trim()) }))
    .filter((s) => s.claims.length);

  // Verbatim guard (LLM path): no claim may copy a long run of a speaker's words. Offending claims get one forced
  // paraphrase; a claim that still copies is dropped (fail closed).
  let paraphrased = 0;
  if (llm && L.has('L3')) {
    const raw = lines.map((l) => String(l?.text ?? ''));
    // a shielded public NAME/TITLE may stay verbatim, but the window is counted without its characters (guard residual,
    // short spans only), so the speaker's surrounding clause is still checked
    const r = await deVerbatim(sections, raw, { llm, stats, lang, safe, strip: pub.spans, shield: pub });
    sections = r.sections; paraphrased = r.paraphrased; dropped += r.dropped;
    // never echo opaque codes / e-mails / links that appear in the transcript
    sections = sections.map((s) => ({ ...s, claims: s.claims.map((c) => ({ ...c, text: stripEchoedTokens(c.text, raw) })).filter((c) => c.text.trim()) })).filter((s) => s.claims.length);
    // figures a speaker disclosed about their own pay / budget / head-count / tenure are masked wherever they reappear
    const own = selfFigures(raw);
    if (own.length) sections = sections.map((s) => ({ ...s, topic: maskSelfFigures(s.topic, own, { lang }), claims: s.claims.map((c) => ({ ...c, text: maskSelfFigures(c.text, own, { lang }) })) }));
  }

  trace?.('final', sections);
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
    meta: meta({ verifierRounds, dropped, flagged, paraphrased, lang }),
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


const PARA_SYSTEM = `Tokens like ⟦P1⟧ stand for public names or facts: copy them unchanged. You rewrite sentences from de-identified meeting minutes that still copy a speaker's exact wording. For each sentence, write a paraphrase that keeps the same meaning, every number, unit, public name, law and title exactly, but uses clearly different wording and sentence structure: no run of more than 6 consecutive Chinese characters or 5 consecutive English words may stay identical to the COPIED excerpt; a quoted saying or slogan is described by its meaning, never quoted. Keep placeholders like [某机构] unchanged. Do not add names, roles or facts. Output JSON {"rewrites":[{"i":1,"text":"..."}]}.`;

export async function deVerbatim(sections, rawLines, { llm, stats, lang, safe = (s) => s, cjkN = 14, wordN = 9, strip = [], shield = null } = {}) {
  // Two tiers: a cited public fact (kind 'fact') may keep the source's wording up to the long-run limit; any other claim
  // is a speaker's own words, where even a short copied run (a slogan, a pet phrase, a turn of phrase) is a style cue.
  const idxLong = verbatimIndex(rawLines, { cjkN, wordN, strip });
  const idxShort = verbatimIndex(rawLines, { cjkN: Math.min(cjkN, 10), wordN: Math.min(wordN, 7), strip });
  const runsOf = (c) => verbatimRuns(c.text, c.kind === 'fact' ? idxLong : idxShort);
  const flat = sections.flatMap((s, si) => s.claims.map((c, ci) => ({ si, ci, c })));
  let paraphrased = 0, dropped = 0;
  let todo = flat.map((x) => ({ ...x, runs: runsOf(x.c) })).filter((x) => x.runs.length);
  for (let round = 0; round < 2 && todo.length; round++) {
    // shielded public spans travel as tokens through the paraphrase as well, then are restored verbatim
    const hide = shield?.hide || ((t) => t), show = shield?.restore || ((t) => t);
    const req = todo.map((x, k) => `${k + 1}. ${hide(x.c.text)}\n   COPIED: ${x.runs.join(' | ')}`).join('\n');
    const note = /^zh/i.test(String(lang || '')) ? '\nWrite in Chinese.' : /^en/i.test(String(lang || '')) ? '\nWrite in English.' : '';
    let rw = new Map();
    try {
      const { data } = await chatJSON(llm, [{ role: 'system', content: PARA_SYSTEM }, { role: 'user', content: `SENTENCES:\n${req}${note}` }], { stats, temperature: 0.7 });
      rw = new Map((Array.isArray(data?.rewrites) ? data.rewrites : []).map((x) => [Number(x?.i), String(x?.text || '').trim()]));
    } catch { /* fall through: unchanged claims are re-checked and dropped below */ }
    todo.forEach((x, k) => { const t = rw.get(k + 1); if (t) { x.c.text = safe(show(t)); paraphrased++; } });
    todo = todo.map((x) => ({ ...x, runs: runsOf(x.c) })).filter((x) => x.runs.length);
  }
  for (const x of todo) { x.c.text = ''; dropped++; }
  return { sections: sections.map((s) => ({ ...s, claims: s.claims.filter((c) => String(c.text).trim()) })).filter((s) => s.claims.length), paraphrased, dropped };
}