// Public-entity shield.
//
// Public world knowledge (laws, official documents, published works by non-attendees, public figures, public
// companies cited as context, places, events, the key phrase of a cited public statistic) is not identifying, but the
// LLM layers paraphrase it away: L3 generalises it, L4 rewrites the claim, and the verbatim guard forces a paraphrase
// of a fact's own wording. The shield replaces such spans with opaque tokens (⟦P1⟧ …) before L3 and restores them
// verbatim after every other layer has run.
//
// Privacy argument: a span is only eligible if it is still present AFTER the deterministic L1/L2 scrub (so the shield
// can never un-mask anything L1/L2 masked), contains no placeholder, no roster token (names, aliases, orgs incl. orgs
// learned from self-introductions, titles, public names, the attendees' own works), no self-disclosed figure, no opaque
// token (code / e-mail / link), is short (≤ 16 CJK chars / ≤ 8 words, below the long-quote limit), and is not directly
// owned by the speaker (我的 / 我们 / our / my … right before it). Candidates come from an LLM classifier that only
// sees the scrubbed text.
import { chatJSON } from './llm.mjs';
import { rosterTokens } from './l4.mjs';
import { orgFragments } from './l2.mjs';
import { opaqueTokens, selfFigures, maskSelfFigures } from './guard.mjs';

const CLASSIFY_SYSTEM = `You find PUBLIC WORLD KNOWLEDGE in fragments of a private meeting. List exact substrings (copied character for character) that are:
- names of laws, regulations, court bodies, official documents, public programmes, public reports and their publishers;
- published books / articles / films and their authors, unless the text says a participant wrote or owns them;
- public figures, public companies or institutions mentioned as market, policy or historical context (NOT the speaker's own employer, team or unit);
- places, historical events, disasters, well-known public projects;
- the short key phrase of a cited public fact, statistic or provision (≤ 12 Chinese characters or ≤ 6 English words), e.g. 「全国乡村教师数量」, "prohibits deaccessioning".
Never list: private people (colleagues, family, friends, people on someone's team), places or employers in someone's life story, anything about the speakers themselves, their organisation, team, budget, pay, experience or plans; placeholders in square brackets; opinions; whole sentences.
Output only JSON {"spans":["...", "..."]}.`;

// Second, recall-oriented pass: shown what the first pass found, list what it missed.
const RECALL_SYSTEM = `A first pass listed public world knowledge in fragments of a private meeting (list below). Find what it MISSED. Look especially for:
- named reports, studies, datasets, laws, standards, programmes, products, AI models, software, companies and brands cited as context;
- people cited as authors, scholars or public figures, including a bare surname form used later (波兹曼, Mazzucato);
- every number that is part of a cited public statistic or public event, with its unit, copied exactly ("$100 billion", "250 institutions", "六十亿美元", "1985年", "66.16%");
- years and dates of public events, publications or policies;
- named concepts or terms coined by a cited author (差序格局), and the short key phrase of a cited public fact (≤ 12 Chinese characters or ≤ 6 English words).
Same exclusions as before: nothing about the speakers, their employer, team, unit, budget, pay, experience, family or plans; no private people; no placeholders in square brackets; no opinions; no whole sentences.
Copy each substring character for character. Output only JSON {"spans":["..."]}.`;

// Precision check over ALL candidates with the whole (scrubbed) meeting in view: chunked recall passes cannot see
// that a name is a witness or a colleague mentioned elsewhere, or that a phrase is this team's own plan or result.
const VERIFY_SYSTEM = `Below is a private meeting (already partly anonymised) and candidate spans that may be PUBLIC WORLD KNOWLEDGE. Return the candidates that are PRIVATE, i.e. any of:
- a person who is not a widely known public figure (employees, colleagues, witnesses, clients, candidates, family, anyone the participants deal with), even if their name sounds ordinary or famous;
- the participants' own organisation, unit, branch, store, site, product, project, codename or team;
- the meeting's own content: its proposals, decisions, action items, plans, internal results, budgets, timelines, counts or measurements from the participants' own work;
- anything that would help identify who in the meeting said something.
Keep (do NOT return) laws, published works and their authors, public figures, public companies cited as context, places, public events, and statistics from public sources.
Output only JSON {"private":["..."]}.`;

// Deterministic cues (no LLM): book / document titles and capitalised named documents or bodies.
const CUE_PATTERNS = [
  /《[^《》\n]{1,30}》/g,
  /\b(?:[A-Z][\w&'.-]*\s+){0,5}(?:Act|Report|Convention|Foundation|Institute|Agency|Commission|Program|Programme|Protocol|Directive|Standard|Index|Survey)\b(?:\s+(?:of\s+)?(?:19|20)\d{2})?/g,
];
const cueSpans = (text) => CUE_PATTERNS.flatMap((re) => [...text.matchAll(re)].map((m) => m[0].trim())).filter((x) => /^《|^[A-Z]/.test(x) && x.split(/\s+/).length >= (x.startsWith('《') ? 1 : 2));

const CJK = /[\u3400-\u9fff]/g;
const OWN_BEFORE = /(?:我的|我们的?|咱们的?|我那|我这|本单位|本公司|\bour\b|\bmy\b)\s*$/i;
// Life-story context: a personal word (我 / 女儿 / my / I / grandmother …) in the stretch just before the span, within
// the same clause, makes it part of someone's biography ("我女儿刚考上北大法学院", "since I moved here from Beijing",
// "I covered the Takata airbag recall") — unless that stretch cites or reads something (我查过… / 我想起… / I read …).
const PERSONAL = /我|咱|俺|本人|女儿|儿子|老婆|老公|丈夫|妻子|爸|妈|奶奶|爷爷|外婆|外公|侄|同事|\b(?:I|I'm|I've|I'd|me|my|mine)\b|grandmother|grandfather|daughter|\bson\b|wife|husband|colleague/i;
const CITING = /公布|统计|数据|报告|调查|显示|规定|引用|参考|查过|看过|读|想起|想到|记得|提到|说过|说的|讲过|书里|书中|在讲|讨论|概念|听说|提醒|颁布|出台|发布|写于|出版|发表|印发|估值|according to|surveyed|\bfound\b|\breport|survey|statistic|\bdata\b|\bread\b|\bcited?\b|quoted?|\bsaid\b|\bwrote\b|\bproposed\b|\bsays\b|look at/i;
const leadIn = (text, at) => {
  const before = text.slice(Math.max(0, at - 60), at);
  const cut = Math.max(...['。', '！', '？', '!', '?', '；', ';', '\n', '，', ',', '. '].map((b) => before.lastIndexOf(b) + (before.lastIndexOf(b) >= 0 ? b.length : 0)));
  const seg = before.slice(Math.max(0, cut));
  return /[\u3400-\u9fff]/.test(seg) ? seg.slice(-14) : seg.slice(-50);
};
// Figures: a number is only public when its whole sentence is not about the speaker's circle (我们 / 我的 / our / my),
// or the sentence explicitly cites a source with no ownership word ("我记得2023年发行规模超过1.5万亿").
const NUMERIC = /\d|百分之|[一二三四五六七八九十两百千万亿]{2,}|[一二三四五六七八九十百千两半]+(?:元|块|万|亿|个|人|年|岁|周|天|月|小时|分钟|次|倍)/;
// L1/L2 placeholders ([参与者] / [某机构] / "in their organisation") mark the room itself.
const OWN_WORD = /我们|我的|咱们|咱|俺们|本单位|本公司|\[某机构\]|\b(?:our|my|we|us)\b|\bin their organi[sz]ation\b/i;
// what follows a span can also tie it to the room: "Priya Raman on our team", L2's "… in their organisation"
const FOLLOW_OWN = /^\s*(?:(?:on|in|from|at)\s+(?:our|my|their)\s+(?:team|organi[sz]ation|lab|unit|group|company)\b|(?:是)?(?:我们|我的|咱们))/i;
// effort / duration figures ("折腾了整整三周", "spent two weeks") are the speaker's own experience
const EFFORT_BEFORE = /(?:干了|做了|折腾了|花了|用了|等了|搞了|忙了|\bspent\b|\btook\b)\S{0,4}$/i;
const sentenceAt = (text, at, len) => {
  const b = /[。！？!?；;\n]|\.\s/g; let lo = 0, hi = text.length, m;
  while ((m = b.exec(text))) { if (m.index < at) lo = m.index + m[0].length; else if (m.index >= at + len) { hi = m.index; break; } }
  return text.slice(lo, hi);
};
export function eligible(span, text, { toks, own }) {
  const s = String(span || '').trim();
  if (s.length < 2 || /[\[\]⟦⟧\n]/.test(s)) return false;
  // a span with clause punctuation outside a title is a saying / sentence (a style cue), never a public name
  if (/[，,。；;！？!?：:]/.test(s.replace(/《[^《》]*》/g, ''))) return false;
  const nC = (s.match(CJK) || []).length, nW = (s.match(/[A-Za-z0-9]+/g) || []).length;
  if (nC > 16 || nW > 8 || (!nC && nW < 1)) return false;
  if (opaqueTokens(s).length || /@|https?:|www\./i.test(s)) return false;
  // a statute named after an organisation (British Museum Act 1963, 《某某法》) is a law, not the organisation — the same
  // exemption L2 applies; the roster token is only ignored when the statute suffix follows it directly
  const low = s.toLowerCase().replace(/[\p{L}\p{N} .'&-]+?(?=\s+(?:act|acts|law|ordinance|regulations?)\b|(?:法|条例|章程)》)/gu, (m) => (toks.some((t) => m.trim() === t.toLowerCase()) ? ' ' : m));
  for (const t of toks) { const tl = t.toLowerCase(); if (tl.length >= 2 && (low.includes(tl) || (tl.includes(low) && low.length >= 2))) return false; }
  if (own.length && maskSelfFigures(s, own) !== s) return false;
  // a span discussed in ≥ 3 utterances is a topic of the meeting, not a detail of one person's biography
  const topic = text.split('\n').filter((l) => l.includes(s)).length >= 3;
  let at = text.indexOf(s), seen = false;
  while (at >= 0) {
    seen = true;
    if (OWN_BEFORE.test(text.slice(Math.max(0, at - 8), at))) return false;
    if (FOLLOW_OWN.test(text.slice(at + s.length, at + s.length + 32))) return false;
    // a bare figure (not a title or a capitalised name containing a year) inherits the ownership of the sentence up to it
    if (NUMERIC.test(s) && !/^《/.test(s) && !/\b[A-Z][a-z]{2,}/.test(s)) { const sen = sentenceAt(text, at, s.length); const pre = sen.slice(0, Math.max(0, sen.indexOf(s))); if ((OWN_WORD.test(pre) && !CITING.test(leadIn(text, at))) || (PERSONAL.test(pre) && !CITING.test(pre)) || EFFORT_BEFORE.test(pre)) return false; }
    const lead = leadIn(text, at);
    // a published title is world knowledge unless the speaker claims it (我的 / 我写的 …)
    if (/^《/.test(s) ? /我(?:们)?(?:写|著|编|译|出)/.test(lead) : !topic && PERSONAL.test(lead) && !CITING.test(lead)) return false;
    at = text.indexOf(s, at + s.length);
  }
  return seen;
}

/**
 * shieldPublic(clusters, { llm, stats, roster, rawLines }) -> { clusters, restore(text), spans }
 * clusters: [{ topic, segments[] }] already scrubbed by L1/L2.
 */
export async function shieldPublic(clusters, { llm, stats, roster = [], rawLines = [] } = {}) {
  const none = { clusters, restore: (t) => t, spans: [] };
  if (!llm || !clusters?.length) return none;
  const text = clusters.flatMap((c) => c.segments).join('\n');
  // classify in chunks of ~20 fragments: one long request truncates or fails as a whole, losing every span at once
  const lines = text.split('\n'), chunks = [];
  for (let i = 0; i < lines.length; i += 20) chunks.push(lines.slice(i, i + 20).join('\n'));
  // models sometimes return {text} objects instead of strings
  const ask = async (system, user) => { try { const { data } = await chatJSON(llm, [{ role: 'system', content: system }, { role: 'user', content: user }], { stats, temperature: 0 }); return Array.isArray(data?.spans) ? data.spans.map((x) => String((x && typeof x === 'object' ? x.text ?? x.span ?? '' : x) ?? '').trim()).filter(Boolean) : null; } catch { return null; } };
  const per = await Promise.all(chunks.map(async (ch) => {
    const first = await ask(CLASSIFY_SYSTEM, `FRAGMENTS:\n${ch}`);
    if (!first) return null;
    const more = await ask(RECALL_SYSTEM, `FIRST PASS:\n${JSON.stringify(first)}\n\nFRAGMENTS:\n${ch}`);
    return [...first, ...(more || [])];
  }));
  if (per.every((x) => x == null)) return none;
  const cand = per.flatMap((x) => x || []);
  cand.push(...cueSpans(text));
  // the full L2 identifier set: roster names, aliases, titles, own works, orgs (incl. self-declared ones the gate folded
  // into the roster) AND every org fragment L2 redacts, plus learned third-party names (roster entries added by the gate).
  // A span containing any of them is never tagged, so nothing identifying is ever restored verbatim.
  const toks = [...new Set([...rosterTokens(roster), ...roster.flatMap((p) => (p?.org ? [...orgFragments(p.org)] : [])).map((x) => String(x).trim()).filter((x) => x.length >= 2)])].sort((a, b) => b.length - a.length);
  const own = selfFigures(rawLines);
  let spans = [...new Set(cand)].filter((s) => eligible(s, text, { toks, own })).sort((a, b) => b.length - a.length);
  if (spans.length) {
    try {
      const msgs = [{ role: 'system', content: VERIFY_SYSTEM }, { role: 'user', content: `MEETING:\n${text}\n\nCANDIDATES:\n${JSON.stringify(spans)}` }];
      const { data } = await chatJSON(llm, msgs, { stats, temperature: 0 }).catch(() => chatJSON(llm, msgs, { stats, temperature: 0 })); // one retry before failing closed
      const priv = new Set((Array.isArray(data?.private) ? data.private : []).map((x) => String((x && typeof x === 'object' ? x.text ?? '' : x) ?? '').trim()));
      spans = spans.filter((s) => !priv.has(s));
    } catch (e) { // no precision check → no shield (fail closed), logged and counted
      if (stats) stats.shieldFailClosed = (stats.shieldFailClosed || 0) + 1;
      console.warn(`[shield] precision pass failed, shield dropped (fail closed): ${String(e?.message ?? e).slice(0, 160)}`);
      return none;
    }
  }
  // longest first: a short span inside a longer one (波兹曼 in 尼尔·波兹曼) still shields its bare occurrences elsewhere
  const kept = spans;
  if (!kept.length) return none;
  const tok = new Map(kept.map((s, i) => [s, `⟦P${i + 1}⟧`]));
  const back = new Map([...tok].map(([s, t]) => [t, s]));
  const apply = (s) => { let o = String(s ?? ''); for (const [span, t] of tok) o = o.split(span).join(t); return o; };
  // defence in depth: a restored span is re-checked against the identifier set and dropped if it would un-mask anything
  const safeBack = (v) => (v && !toks.some((t) => t.length >= 2 && v.toLowerCase().includes(t.toLowerCase())) ? v : '');
  const restore = (s) => String(s ?? '').replace(/⟦P(\d+)⟧/g, (m) => safeBack(back.get(m))).replace(/⟦[^⟧]*⟧/g, '');
  return { clusters: clusters.map((c) => ({ topic: apply(c.topic), segments: c.segments.map(apply) })), hide: apply, restore, spans: kept };
}

export const SHIELD_NOTE = 'Tokens like ⟦P1⟧ stand for public names or public facts (laws, works, public figures, statistics). Copy every such token unchanged, exactly where it belongs in the sentence; never drop, translate or explain it.';
