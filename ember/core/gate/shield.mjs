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
import { opaqueTokens, selfFigures, maskSelfFigures } from './guard.mjs';

const CLASSIFY_SYSTEM = `You find PUBLIC WORLD KNOWLEDGE in fragments of a private meeting. List exact substrings (copied character for character) that are:
- names of laws, regulations, court bodies, official documents, public programmes, public reports and their publishers;
- published books / articles / films and their authors, unless the text says a participant wrote or owns them;
- public figures, public companies or institutions mentioned as market, policy or historical context (NOT the speaker's own employer, team or unit);
- places, historical events, disasters, well-known public projects;
- the short key phrase of a cited public fact, statistic or provision (≤ 12 Chinese characters or ≤ 6 English words), e.g. 「全国乡村教师数量」, "prohibits deaccessioning".
Never list: private people (colleagues, family, friends, people on someone's team), places or employers in someone's life story, anything about the speakers themselves, their organisation, team, budget, pay, experience or plans; placeholders in square brackets; opinions; whole sentences.
Output only JSON {"spans":["...", "..."]}.`;

const CJK = /[\u3400-\u9fff]/g;
const OWN_BEFORE = /(?:我的|我们的?|咱们的?|我那|我这|本单位|本公司|\bour\b|\bmy\b)\s*$/i;
// Life-story context: a personal word (我 / 女儿 / my / I / grandmother …) in the stretch just before the span, within
// the same clause, makes it part of someone's biography ("我女儿刚考上北大法学院", "since I moved here from Beijing",
// "I covered the Takata airbag recall") — unless that stretch cites or reads something (我查过… / 我想起… / I read …).
const PERSONAL = /我|咱|俺|本人|女儿|儿子|老婆|老公|丈夫|妻子|爸|妈|奶奶|爷爷|外婆|外公|侄|同事|\b(?:I|I'm|I've|I'd|me|my|mine)\b|grandmother|grandfather|daughter|\bson\b|wife|husband|colleague/i;
const CITING = /公布|统计|数据|报告|调查|显示|规定|引用|参考|查过|看过|读|想起|想到|记得|提到|说过|说的|讲过|书里|书中|在讲|讨论|概念|according to|\breport|survey|statistic|\bdata\b|\bread\b|\bcited?\b|quoted?|\bsaid\b|\bwrote\b|\bproposed\b|\bsays\b|look at/i;
const leadIn = (text, at) => {
  const before = text.slice(Math.max(0, at - 60), at);
  const cut = Math.max(...['。', '！', '？', '!', '?', '；', ';', '\n', '，', ',', '. '].map((b) => before.lastIndexOf(b) + (before.lastIndexOf(b) >= 0 ? b.length : 0)));
  const seg = before.slice(Math.max(0, cut));
  return /[\u3400-\u9fff]/.test(seg) ? seg.slice(-14) : seg.slice(-50);
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
    const lead = leadIn(text, at);
    if (!topic && PERSONAL.test(lead) && !CITING.test(lead)) return false;
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
  let cand = [];
  try {
    const { data } = await chatJSON(llm, [{ role: 'system', content: CLASSIFY_SYSTEM }, { role: 'user', content: `FRAGMENTS:\n${text}` }], { stats, temperature: 0 });
    cand = Array.isArray(data?.spans) ? data.spans.map((x) => String(x ?? '').trim()) : [];
  } catch { return none; }
  const toks = rosterTokens(roster);
  const own = selfFigures(rawLines);
  const spans = [...new Set(cand)].filter((s) => eligible(s, text, { toks, own })).sort((a, b) => b.length - a.length);
  // drop spans contained in a longer kept span (the longer one shields them)
  const kept = spans.filter((s, i) => !spans.slice(0, i).some((l) => l.includes(s)));
  if (!kept.length) return none;
  const tok = new Map(kept.map((s, i) => [s, `⟦P${i + 1}⟧`]));
  const back = new Map([...tok].map(([s, t]) => [t, s]));
  const apply = (s) => { let o = String(s ?? ''); for (const [span, t] of tok) o = o.split(span).join(t); return o; };
  const restore = (s) => String(s ?? '').replace(/⟦P(\d+)⟧/g, (m) => back.get(m) ?? '').replace(/⟦[^⟧]*⟧/g, '');
  return { clusters: clusters.map((c) => ({ topic: apply(c.topic), segments: c.segments.map(apply) })), hide: apply, restore, spans: kept };
}

export const SHIELD_NOTE = 'Tokens like ⟦P1⟧ stand for public names or public facts (laws, works, public figures, statistics). Copy every such token unchanged, exactly where it belongs in the sentence; never drop, translate or explain it.';
