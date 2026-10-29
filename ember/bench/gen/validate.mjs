// EmberBench · deterministic schema + consistency validation of a bench transcript.
// validate(t) → { ok, errors[], warnings[] }. Errors make a transcript unusable; warnings are recorded.
import { normText } from '../../eval/metrics.mjs';

export const ID_KINDS = new Set(['name', 'org', 'title', 'quasi', 'number', 'style', 'phone', 'email', 'url', 'handle', 'address', 'date', 'idcard', 'work']);
const DIRS = new Set(['support', 'doubt', 'oppose']);
const squash = (s) => normText(s).replace(/[\s\p{P}\p{S}]+/gu, '');

/** Deterministic repair before validation: identifiers that never occur in the transcript (e.g. a roster-only
 *  title) carry no leak signal → dropped, with a note. Returns the list of dropped identifier texts. */
export function repair(t) {
  const hay = normText([...(t.lines || []).map((l) => l.text), ...(t.questions || []).map((q) => q.q)].join('\n'));
  const dropped = [];
  if (Array.isArray(t.gold?.identifiers)) {
    t.gold.identifiers = t.gold.identifiers.filter((x) => {
      const ok = [x.text, ...(x.fuzzy || [])].some((v) => v && hay.includes(normText(v)));
      if (!ok && x.kind !== 'quasi' && x.kind !== 'style') { dropped.push(`${x.kind}:${x.text}`); return false; }
      return true;
    });
  }
  for (const k of ['ideas']) for (const x of t.gold?.[k] || []) if (Array.isArray(x.keywords)) x.keywords = x.keywords.filter((w) => hay.includes(normText(w)));
  return dropped;
}

export function validate(t, { minLines = 18, maxLines = 60 } = {}) {
  const errors = [];
  const warnings = [];
  const E = (m) => errors.push(m);
  const W = (m) => warnings.push(m);
  if (!t || typeof t !== 'object') return { ok: false, errors: ['not an object'], warnings };
  for (const k of ['id', 'title', 'lang', 'roster', 'lines', 'gold']) if (t[k] == null) E(`missing ${k}`);
  if (errors.length) return { ok: false, errors, warnings };
  if (!['zh', 'en', 'mixed'].includes(t.lang)) E(`bad lang ${t.lang}`);
  const ids = new Set();
  if (!Array.isArray(t.roster) || t.roster.length < 3 || t.roster.length > 8) E('roster must have 3–8 members');
  for (const p of t.roster || []) {
    if (!p.id || !p.name) E(`roster entry without id/name`);
    if (ids.has(p.id)) E(`duplicate roster id ${p.id}`);
    ids.add(p.id);
    if (!Array.isArray(p.aliases)) E(`roster ${p.id}: aliases must be array`);
    if (!p.org) W(`roster ${p.id}: no org`);
  }
  const owner = (o, where) => { if (o !== 'third' && !ids.has(o)) E(`${where}: unknown owner ${o}`); };
  if (!Array.isArray(t.lines) || t.lines.length < minLines || t.lines.length > maxLines) E(`lines must be ${minLines}–${maxLines} (got ${t.lines?.length})`);
  const spoke = new Set();
  for (const [i, l] of (t.lines || []).entries()) {
    if (!ids.has(l.speakerId)) E(`line ${i}: unknown speaker ${l.speakerId}`);
    if (!String(l.text || '').trim()) E(`line ${i}: empty text`);
    spoke.add(l.speakerId);
  }
  for (const id of ids) if (!spoke.has(id)) E(`roster ${id} never speaks`);
  const all = (t.lines || []).map((l) => l.text).join('\n');
  const allQ = (t.questions || []).map((q) => q.q).join('\n');
  const inText = (s) => normText(all).includes(normText(s));
  const g = t.gold || {};
  // ideas
  const ideas = g.ideas || [];
  if (ideas.length < 5) E(`need ≥5 ideas (got ${ideas.length})`);
  const ideaOwners = new Set();
  for (const x of ideas) {
    if (!x.id || !x.text) E('idea without id/text');
    owner(x.owner, `idea ${x.id}`);
    if (x.owner === 'third') E(`idea ${x.id}: owner must be a participant`);
    ideaOwners.add(x.owner);
    if (!Array.isArray(x.keywords) || !x.keywords.length) W(`idea ${x.id}: no keywords`);
    else for (const k of x.keywords) if (!inText(k)) W(`idea ${x.id}: keyword "${k}" not in lines`);
  }
  if (ideaOwners.size < Math.min(3, ids.size)) E(`ideas must cover ≥3 speakers (got ${ideaOwners.size})`);
  // identifiers: verbatim in the lines (or a question), or a fuzzy variant is
  for (const x of g.identifiers || []) {
    if (!ID_KINDS.has(x.kind)) E(`identifier "${x.text}": bad kind ${x.kind}`);
    owner(x.owner, `identifier "${x.text}"`);
    const hay = all + '\n' + allQ;
    const found = [x.text, ...(x.fuzzy || [])].some((v) => normText(hay).includes(normText(v)));
    if (!found && x.kind !== 'style' && x.kind !== 'quasi') E(`identifier "${x.text}" (${x.kind}) not verbatim in transcript`);
    else if (!found) W(`identifier "${x.text}" (${x.kind}) not verbatim`);
  }
  for (const x of g.thirdParties || []) {
    if (!x.name || typeof x.public !== 'boolean') E(`thirdParty needs name + public:boolean`);
    else if (![x.name, ...(x.variants || [])].some((v) => inText(v) || normText(allQ).includes(normText(v)))) E(`thirdParty "${x.name}" not in transcript`);
    for (const p of t.roster || []) if (normText(p.name) === normText(x.name)) E(`thirdParty "${x.name}" is a participant`);
  }
  for (const x of g.publicFacts || []) {
    if (!x.id || !Array.isArray(x.keep) || !x.keep.length) E(`publicFact ${x.id}: keep[] required`);
    for (const k of x.keep || []) if (!inText(k)) E(`publicFact ${x.id}: keep "${k}" not in lines`);
  }
  for (const x of g.quotes || []) {
    owner(x.owner, 'quote');
    if (!squash(all).includes(squash(x.text))) E(`quote not verbatim: "${String(x.text).slice(0, 30)}"`);
  }
  for (const x of g.stances || []) {
    owner(x.owner, `stance ${x.id}`);
    if (!DIRS.has(x.direction)) E(`stance ${x.id}: bad direction ${x.direction}`);
    if (!x.target) E(`stance ${x.id}: no target`);
  }
  const qids = new Set((t.questions || []).map((q) => q.id));
  for (const q of t.questions || []) {
    if (!q.id || !q.q) E('question needs id + q');
    if (q.askerId && !ids.has(q.askerId)) E(`question ${q.id}: unknown asker`);
    if (!q.injection && !q.answer) E(`question ${q.id}: needs gold answer`);
  }
  for (const x of g.injections || []) {
    if (!['speech', 'question'].includes(x.channel)) E(`injection ${x.id}: bad channel`);
    if (!x.canary) E(`injection ${x.id}: no canary`);
    const hay = x.channel === 'speech' ? all : allQ;
    if (x.canary && !hay.includes(x.canary)) E(`injection ${x.id}: canary ${x.canary} not in ${x.channel}`);
    if (x.channel === 'question' && x.questionId && !qids.has(x.questionId)) E(`injection ${x.id}: unknown questionId`);
    for (const m of x.markers || []) if (String(m).length < 2) E(`injection ${x.id}: marker too short`);
  }
  for (const x of g.mosaic || []) {
    owner(x.owner, 'mosaic');
    if (!Array.isArray(x.facts) || !x.facts.length) E('mosaic entry needs facts[]');
  }
  // categories → required gold
  const cats = new Set(t.categories || []);
  const need = (c, cond, m) => { if (cats.has(c) && !cond) E(`category ${c}: ${m}`); };
  const kinds = (k) => (g.identifiers || []).filter((x) => x.kind === k).length;
  need('self_org', kinds('org') >= 1, 'needs org identifiers');
  need('indirect', kinds('quasi') >= 2, 'needs ≥2 quasi identifiers');
  need('name_variants', (g.identifiers || []).filter((x) => x.kind === 'name' && x.owner !== 'third').length >= 2, 'needs ≥2 participant name identifiers');
  need('asr_names', (g.identifiers || []).some((x) => x.kind === 'name' && x.asr), 'needs a name identifier with asr:true');
  need('third_party', (g.thirdParties || []).some((x) => x.public) && (g.thirdParties || []).some((x) => !x.public), 'needs one public and one private third party');
  need('public_facts', (g.publicFacts || []).length >= 2, 'needs ≥2 public facts');
  need('quotes_dialect', (g.quotes || []).length >= 1 || kinds('style') >= 1, 'needs quotes or style identifiers');
  need('numbers', kinds('number') >= 2, 'needs ≥2 number identifiers');
  need('injection_speech', (g.injections || []).some((x) => x.channel === 'speech'), 'needs a speech injection');
  need('injection_question', (g.injections || []).some((x) => x.channel === 'question'), 'needs a question injection');
  need('mosaic', (g.mosaic || []).length >= 1, 'needs mosaic facts');
  return { ok: errors.length === 0, errors, warnings };
}
