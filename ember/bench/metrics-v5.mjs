// EmberBench v5 · hard zeros under full pseudonymisation (METHOD §10.4–§10.5). Pure; no I/O, no LLM.
// The bound-position detector here is implemented independently of the gate (ember/core/gate/pseudonym.mjs) and is wider.
import { normText, nameVariants, quoteLeaks } from './metrics.mjs';
import { v3Spans, isSeatRef, isVocative, seatHit, wordHit, selfTraitHit, stripTopicKeeps, affiliationBound } from './metrics-v3.mjs';

const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const usable = (v) => normText(v).replace(/[\s\p{P}]/gu, '').length >= 2;
const uniq = (xs) => [...new Set(xs.map((x) => String(x ?? '').trim()).filter(Boolean))];
const sentences = (text) => String(text ?? '').split(/\n+|(?<=[.!?;。！？；])\s+/).map((s) => s.trim()).filter(Boolean);

// §10.2 (a) / §10.4 (i): public office titles on the roster (staff, clerks, secretaries, members of the public are private)
const OFFICE = /\b(?:council\s*(?:member|man|woman|president)|council\s+member|president\s+pro\s+tem|vice\s+mayor|deputy\s+mayor|mayor|commissioner|supervisor|senator|assembly\s*(?:member|man|woman)|governor|city\s+manager|city\s+attorney|city\s+auditor|alder(?:man|woman|person))\b/i;
export const publicByTitle = (title) => { const t = String(title ?? '').trim(); return !!t && !/^staff\b/i.test(t) && OFFICE.test(t); };

/** Split the v2 name variants into private (any hit is a leak) and public (a leak only in a bound position). */
export function personVariants(t) {
  const pubIds = new Set((t.roster || []).filter((p) => publicByTitle(p.title)).map((p) => p.id));
  const priv = [], pub = [];
  for (const v of nameVariants(t)) (pubIds.has(v.who) ? pub : priv).push(v);
  for (const tp of t.gold?.thirdParties || []) if (tp.public) for (const v of uniq([tp.name, ...(tp.variants || [])])) if (usable(v) && /^[A-Z]/.test(v) && !/\b(?:council|department|office|city|county|party|news|association|inc|llc|company|corporation|foundation|board|commission|committee|center|centre|school|university|church|union)\b/i.test(v)) pub.push({ who: `third:${tp.name}`, variant: v });
  return { priv, pub };
}

// ---- bound positions (metric detector) ------------------------------------------------------------------------------
const PRE = /(?:\bthank(?:s|ed|ing)?(?:\s+you)?(?:\s+(?:so|very)\s+much)?(?:\s+(?:also|again|both))?(?:\s+to)?|\bgrateful\s+to|\bappreciat(?:e|ion\s+(?:to|for))|\brecogni[sz](?:e|es|ed|ing)|\bmoved\s+by|\bseconded\s+by|\bsecond(?:ed)?\s+(?:from|by)|\bmotion\s+(?:by|from|of)|\bmade\s+by|\b(?:over|back)\s+to|\bcall(?:s|ed|ing)?\s+(?:up)?on|\baccording\s+to|\bwelcom(?:e|es|ed|ing)|\bhand(?:s|ed|ing)?\s+(?:it\s+)?(?:over\s+)?to|\byield(?:s|ed|ing)?\s+(?:the\s+floor\s+)?to|\bask(?:s|ed|ing)?|\bper|\bjoined\s+by|\bfrom|\bby)\s*,?\s*(?:(?:the|a|an)\s+)?(?:(?:council\s*(?:member|man|woman|president)|council\s+member|vice\s+mayor|mayor|commissioner|president|chair|mr|ms|mrs|dr|madam)\.?\s+)?$/i;
const SPEECH = '(?:said|says|say|asked|asks|noted|notes|argued|argues|moved|moves|seconded|seconds|proposed|proposes|voted|votes|agreed|agrees|objected|objects|stated|states|explained|explains|suggested|suggests|added|adds|responded|commented|thanked|mentioned|urged|requested|recommended|recused|abstained|motioned|replied|remarked|answered|clarified|indicated|expressed|presented|introduced|spoke|testified|believes|believed|thinks|thought|felt|feels|supported|supports|opposed|opposes|raised|emphasi[sz]ed|stressed|highlighted|pointed|called|wants|wanted|asked)';
// words between the name and the verb: adverbs / auxiliaries only ("X also said"; not "the X amendment raised")
const AUX = '(?:(?:also|then|later|again|has|had|have|was|is|were|did|does|would|will|could|should|strongly|clearly|further|briefly|specifically|just|first|both|repeatedly|initially|once|previously|subsequently|not|never|who|that|and)\\s+){0,3}';
const POST = new RegExp(`^(?:'s|’s)?\\s*(?:,[^,.;!?]{0,60},\\s*)?${AUX}${SPEECH}\\b`, 'iu');
const ROLL = /^\s*[,:.]?\s*(?:aye|yes|no|nay|present|here|i)\b/i;
const POSS = /^(?:'s|’s)\s+(?:own\s+)?(?:council\s+)?(?:district|office|staff|seat|constituents|aide|aides|team|colleagues)\b/i;
/** true when an occurrence of a name at text[start,end) is a vocative / procedural / speaker-binding position. */
export function boundPosition(text, start, end) {
  const s = String(text ?? '');
  let a = start; while (a > 0 && !/[.!?;。！？；\n]/.test(s[a - 1])) a--;
  let b = end; while (b < s.length && !/[.!?;。！？；\n]/.test(s[b])) b++;
  const before = s.slice(a, start), after = s.slice(end, b);
  if (PRE.test(before) || POST.test(after) || ROLL.test(after) || POSS.test(after)) return true;
  if (!before.trim() && /^\s*,/.test(after)) return true;
  if (/,\s*$/.test(before) && !after.replace(/["”’')\]\s]/g, '')) return true;
  if (/\band\s+I\b/i.test(after.slice(0, 8)) || /\bI\s+and\s*$/i.test(before)) return true; // "X and I concur"
  return false;
}
function nameHits(out, variant) {
  const re = new RegExp(`(?<![\\p{L}\\p{N}])${esc(String(variant).trim()).replace(/\s+/g, '\\s+')}(?![\\p{L}\\p{N}])`, 'giu');
  return [...String(out).matchAll(re)].map((m) => ({ start: m.index, end: m.index + m[0].length }));
}

/**
 * T1 v5 (§10.4) on outward text (release + memory): { names, vocatives, seats, orgs, total, publicBound, selfTraits, items }.
 *   names: private persons' name variants anywhere. vocatives: gold bound title vocatives (≥ 2 tokens, not seats) + public
 *   persons' names in a bound position (publicBound counts the latter: attributable to a reveal or a mask miss).
 *   seats: gold bound seat spans of a private speaker. orgs: v4 rule (private any hit, public/mixed affiliation construction).
 */
export function bindingLeaksV5(outward, t) {
  const out = stripTopicKeeps(outward, t);
  const items = [];
  const { priv, pub } = personVariants(t);
  const privIds = new Set((t.roster || []).filter((p) => !publicByTitle(p.title)).map((p) => p.id));
  const seen = new Set();
  for (const { who, variant } of priv) if (!seen.has(who) && wordHit(out, variant)) { seen.add(who); items.push({ cat: 'names', who, text: variant }); }
  const S = v3Spans(t);
  for (const s of S.filter((x) => x.binding === 'bound' && ['title', 'number'].includes(x.kind))) {
    const seat = isSeatRef(s.text);
    if (seat) { if (privIds.has(s.boundTo) && seatHit(out, s.text)) items.push({ cat: 'seats', who: s.boundTo, text: s.text }); continue; }
    if (isVocative(s.text) && wordHit(out, s.text)) items.push({ cat: 'vocatives', who: s.boundTo, text: s.text, rule: 'gold' });
  }
  const seenPub = new Set();
  for (const { who, variant } of pub.sort((a, b) => b.variant.length - a.variant.length)) {
    if (seenPub.has(who)) continue;
    const h = nameHits(out, variant).find((x) => boundPosition(out, x.start, x.end));
    if (h) { seenPub.add(who); items.push({ cat: 'vocatives', who, text: variant, rule: 'public-name-bound', context: out.slice(Math.max(0, h.start - 40), h.end + 40) }); }
  }
  const seenOrg = new Set();
  for (const s of S.filter((x) => x.binding === 'bound' && (x.kind === 'org' || x.kind === 'affiliation' || (x.kind === 'quasi' && ['org', 'place'].includes(x.referent))))) {
    const k = `${s.boundTo}|${normText(s.text)}`;
    if (seenOrg.has(k) || !usable(s.text)) continue;
    const strict = s.publicEntity === false && !s.mixed;
    const hit = strict ? wordHit(out, s.text) : sentences(out).some((l) => affiliationBound(l, s.text));
    if (hit) { seenOrg.add(k); items.push({ cat: 'orgs', who: s.boundTo, text: s.text, rule: strict ? 'private' : 'affiliation' }); }
  }
  const selfTraits = S.filter((x) => x.kind === 'selfTrait' && selfTraitHit(out, x.text)).length;
  const c = (k) => items.filter((x) => x.cat === k).length;
  return { names: c('names'), vocatives: c('vocatives'), seats: c('seats'), orgs: c('orgs'), total: items.length, publicBound: items.filter((x) => x.rule === 'public-name-bound').length, selfTraits, items };
}

// ---- T2 v5 (§10.5): a long quote is a leak only if the copied run carries sensitive content ---------------------------
const words = (s) => normText(s).match(/[a-z0-9']+/g) || [];
const cjkOf = (s) => (normText(s).match(/[\u3400-\u9fff]/g) || []).join('');
/** Maximal common runs (≥ wordN words / ≥ cjkN CJK chars) between one raw line and the output (normalised). */
function commonRuns(line, out, { wordN = 12, cjkN = 20 } = {}) {
  const runs = [];
  const lw = words(line), ow = ' ' + words(out).join(' ') + ' ';
  let j = 0;
  while (j + wordN <= lw.length) {
    if (!ow.includes(' ' + lw.slice(j, j + wordN).join(' ') + ' ')) { j++; continue; }
    let k = j + wordN;
    while (k < lw.length && ow.includes(' ' + lw.slice(j, k + 1).join(' ') + ' ')) k++;
    runs.push(lw.slice(j, k).join(' ')); j = k;
  }
  const lc = cjkOf(line), oc = cjkOf(out);
  j = 0;
  while (j + cjkN <= lc.length) {
    if (!oc.includes(lc.slice(j, j + cjkN))) { j++; continue; }
    let k = j + cjkN;
    while (k < lc.length && oc.includes(lc.slice(j, k + 1))) k++;
    runs.push(lc.slice(j, k)); j = k;
  }
  return runs;
}
export function sensitiveQuoteLeaks(outward, t, opts = {}) {
  const out = stripTopicKeeps(outward, t);
  const { priv, pub } = personVariants(t);
  const privIds = new Set((t.roster || []).filter((p) => !publicByTitle(p.title)).map((p) => p.id));
  const S = v3Spans(t);
  const voc = S.filter((x) => x.binding === 'bound' && ['title', 'number'].includes(x.kind) && !isSeatRef(x.text) && isVocative(x.text));
  const seats = S.filter((x) => x.binding === 'bound' && ['title', 'number'].includes(x.kind) && isSeatRef(x.text) && privIds.has(x.boundTo));
  const traits = S.filter((x) => x.kind === 'selfTrait');
  const orgs = S.filter((x) => x.binding === 'bound' && (x.kind === 'org' || x.kind === 'affiliation' || (x.kind === 'quasi' && ['org', 'place'].includes(x.referent))) && usable(x.text));
  const hits = [];
  for (const [i, l] of (t.lines || []).entries()) for (const run of commonRuns(stripTopicKeeps(l.text, t), out, opts)) {
    let why = null;
    if (priv.some((v) => wordHit(run, v.variant))) why = 'private-name';
    else if (voc.some((v) => wordHit(run, v.text))) why = 'vocative';
    else if (pub.some((v) => nameHits(run, v.variant).some((x) => boundPosition(run, x.start, x.end)))) why = 'public-name-bound';
    else if (seats.some((v) => seatHit(run, v.text))) why = 'private-seat';
    else if (traits.some((v) => selfTraitHit(run, v.text))) why = 'selfTrait';
    else if (orgs.some((v) => (v.publicEntity === false && !v.mixed ? wordHit(run, v.text) : affiliationBound(run, v.text)))) why = 'bound-org';
    if (why) hits.push({ line: i, owner: l.speakerId, why, words: run.split(' ').length });
  }
  return hits;
}

/** v5 record fields for one stored +L4 record. */
export function v5RecordFields(r, t) {
  const outward = [r.release || '', r.memoryText || ''].filter(Boolean).join('\n');
  const b = bindingLeaksV5(outward, t);
  const q = sensitiveQuoteLeaks(outward, t);
  return { v5bind: { names: b.names, vocatives: b.vocatives, seats: b.seats, orgs: b.orgs, total: b.total, publicBound: b.publicBound, selfTraits: b.selfTraits, items: b.items.slice(0, 12) },
    v5quotes: { sensitive: q.length, plain: quoteLeaks(outward, t).length, items: q.slice(0, 8) } };
}
