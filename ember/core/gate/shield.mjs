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
import { orgFragments, memberOrgFragments, isSharedOrg } from './l2.mjs';
import { opaqueTokens, selfFigures, maskSelfFigures } from './guard.mjs';
import { isPersonShaped, PUBLIC_FIGURES } from './l1.mjs';

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

// Public-body mode: the meeting's own business (items, decisions, figures, codes, programmes) IS the public record; only
// what is private to a person in the room or binds them to an organisation is private.
const VERIFY_PUBLIC = `Below is a PUBLIC meeting of a government body (already partly anonymised) and candidate spans. The body's business is public record: agenda items, bill / ordinance / section numbers, codes, votes, outcomes, the figures, dates, addresses, programmes, agencies and organisations the items concern. Return ONLY the candidates that are PRIVATE, i.e.:
- a private person (a member of the public, staff, a relative, anyone not a public office holder) or a nickname;
- a speaker's own employer, firm, group or organisation they represent, their own home, family, pay, tenure or life story;
- a phrase that is a speaker's personal manner of speaking (a catchphrase).
Do NOT return item / bill / section numbers, codes, vote tallies, figures, dates, addresses, public agencies, public programmes, policies or the subjects of an item.
Output only JSON {"private":["..."]}.`;

// Deterministic cues (no LLM): book / document titles and capitalised named documents or bodies.
const CUE_PATTERNS = [
  /《[^《》\n]{1,30}》/g,
  /\b(?:[A-Z][\w&'.-]*\s+){0,5}(?:Act|Report|Convention|Foundation|Institute|Agency|Commission|Program|Programme|Protocol|Directive|Standard|Index|Survey)\b(?:\s+(?:of\s+)?(?:19|20)\d{2})?/g,
];
const cueSpans = (text) => CUE_PATTERNS.flatMap((re) => [...text.matchAll(re)].map((m) => m[0].trim())).filter((x) => /^《|^[A-Z]/.test(x) && x.split(/\s+/).length >= (x.startsWith('《') ? 1 : 2));

// Public-body mode only: the civic record of a public meeting, by shape (no names): bill / resolution / item numbers,
// codes, vote tallies and outcomes, named public offices and programmes, street addresses and dates of the record.
const NUMW = '(?:\\d+|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen)';
const CIVIC_PATTERNS = [
  /\b(?:[Cc]ouncil|Senate|House|Assembly)\s+[Bb]ills?\s+(?:No\.?\s*|Number\s+)?\d[\d,.-]*(?:\s+\d[\d-]*)?(?:,?\s*[Dd]ash\s+\d+\w*)?/g,
  /\b(?:Resolution|Ordinance|Bill|Item|Amendment|Proclamation|Motion|File|Case|Docket|Communication|Rezoning|Application|Report)\s+(?:No\.?\s*|Number\s+|#\s*)?\d[\w.-]*(?:\s+\d[\d-]{2,}\b)?(?:,?\s*[Dd]ash\s+\d+\w*)?(?:\s+Communication)?/g,
  // section / chapter numbers incl. spoken (ASR) continuations: "sections 7.20 4.0 or 3020 2.202.0 80 and 22.20 6.1 80"
  /\b(?:[Ss]ections?|[Cc]hapters?|[Tt]itle|[Aa]rticles?|[Ss]ubsections?)\s+\d+(?:\.\d+)+[\w.]*(?:(?:\s+(?:or|and|,)?\s*)\d[\d.]*){0,8}(?:\s+(?:of\s+the\s+(?:[A-Z][\w.]*\s+){1,4}Code))?|\b\d{1,3}\.\d{1,3}\.\d{1,4}\b/g,
  /\b[A-Z]{1,3}\s+[Dd]ash\s+\d+\w*|\b\d{1,3},?\s+[Dd]ash\s+\d+\w*/g,
  /\b(?:Title|Chapter|Section|Article)\s+\d[\w.]*\s+of\s+the\s+(?:[A-Z][\w.]*\s+){1,5}Code(?:\s+[A-Z][a-z]+)?/g,
  /\b(?:[A-Z][\w.]*\s+){0,4}(?:[Mm]unicipal|[Zz]oning|[Rr]evised|[Aa]dministrative|[Bb]uilding|[Hh]ousing|[Ll]and\s+[Uu]se|[Ff]ire)\s+[Cc]ode\b/g,
  new RegExp(`\\b${NUMW}\\s+(?:ayes?|eyes|yeas?|yes(?:es)?|in\\s+favou?r)[,.;]?\\s+(?:and\\s+)?${NUMW}\\s+(?:nays?|noes|nos?|opposed|against|abstentions?)\\b`, 'gi'),
  /\b[Tt]he\s+(?:bill|resolution|ordinance|motion|item|amendment|consent\s+agenda|appointment)\s+(?:passes|passed|carries|carried|fails|failed|is\s+adopted|is\s+approved|has\s+been\s+adopted)\b/g,
  /\b(?:[A-Z][\w'&.-]*\s+){1,4}(?:Department|Office|Board|Committee|Commission|Authority|Agency|Division|Bureau|Services|Health|Transit|Plan|Program|Programme|Code|District|Park|Library|Center|Centre)\b(?:\s+(?:of|for)\s+(?:[A-Z][\w'&.-]*\s?){1,4})?/g,
  /\b\d{1,5}(?:\s+(?:North|South|East|West|N|S|E|W)\.?)?\s+(?:[A-Z][a-z]+|\d+(?:st|nd|rd|th))(?:\s+[A-Z][a-z]+){0,2}\s+(?:Street|St|Avenue|Ave|Boulevard|Blvd|Road|Rd|Drive|Way|Place|Court|Lane|Parkway)\b/g,
  /\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+(?:19|20)\d{2})?\b/g,
  // figures of the item ("350 electric vehicle charging stations", "a 20 year contract", "$400 million"): soft — every
  // ownership check (own pay / budget / tenure figures) and the LLM precision pass still apply
  /\$\d[\d,.]*(?:\s+(?:million|billion|thousand))?(?:\s+in\s+[a-z]+)?/g,
  /(?<![\w$])\d[\d,.]*(?:\s*(?:%|percent|million|billion|thousand))?(?:[\s-]+(?:year|day|month|week|square|foot|feet|unit|storey|story))?(?:\s+(?!(?:and|or|but|to|of|in|on|at|for|with|the|a|an|is|are|was|were|that|which|we|i|it|they|this)\b)[a-z][a-z-]+){1,5}\b/g,
  /\b(?:(?:19|20)\d{2}\s+(?:budget|general\s+election|primary|census|update|plan)|(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+(?:of\s+)?(?:19|20)\d{2})\b/g,
];
// strong = record shapes (numbers / codes / votes / outcomes): public by shape. soft = offices, addresses, dates: candidates
// that still go through every ownership check and the LLM precision pass.
const civicOf = (pats, text) => pats.flatMap((re) => [...String(text ?? '').matchAll(re)].map((m) => m[0].trim().replace(/[\s,.;]+$/, '').replace(/^The\s+(?=[A-Z])/, ''))).filter((x) => x.length >= 4 && !/^(?:A|An|This|That|Our|My|Their|His|Her)\s/.test(x) && !/^The\s+[A-Z]/.test(x));
/** Type label of a civic record span (for grouping the public-record appendix by kind, never by speaker). */
export const CIVIC_KINDS = ['Legislation and items', 'Votes and outcomes', 'Codes', 'Public bodies', 'Properties', 'Dates', 'Figures'];
export function civicKind(s) {
  const at = (i) => civicOf([CIVIC_PATTERNS[i]], s).some((x) => x === s);
  if ([0, 1, 3].some(at)) return 'Legislation and items';
  if ([6, 7].some(at)) return 'Votes and outcomes';
  if ([2, 4, 5].some(at)) return 'Codes';
  if (at(9)) return 'Properties';
  if (at(10) || at(13)) return 'Dates';
  if (at(8)) return 'Public bodies';
  return 'Figures';
}
export const civicStrong = (text) => civicOf(CIVIC_PATTERNS.slice(0, 8), text);
export const civicSpans = (text) => [...civicStrong(text), ...civicOf(CIVIC_PATTERNS.slice(8), text)];

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
export function eligible(span, text, { toks, own, record = false }) {
  const s = String(span || '').trim();
  if (s.length < 2 || /[\[\]⟦⟧\n]/.test(s)) return false;
  // a span with clause punctuation outside a title is a saying / sentence (a style cue), never a public name
  // (a civic-record shape — a vote tally "nine ayes, three nays" — may carry a comma)
  if (!record && /[，,。；;！？!?：:]/.test(s.replace(/《[^《》]*》/g, ''))) return false;
  const nC = (s.match(CJK) || []).length, nW = (s.match(/[A-Za-z0-9]+/g) || []).length;
  if (nC > 16 || nW > (record ? 16 : 8) || (!nC && nW < 1)) return false;
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
    if (!record && NUMERIC.test(s) && !/^《/.test(s) && !/\b[A-Z][a-z]{2,}/.test(s)) { const sen = sentenceAt(text, at, s.length); const pre = sen.slice(0, Math.max(0, sen.indexOf(s))); if ((OWN_WORD.test(pre) && !CITING.test(leadIn(text, at))) || (PERSONAL.test(pre) && !CITING.test(pre)) || EFFORT_BEFORE.test(pre)) return false; }
    const lead = leadIn(text, at);
    // a published title is world knowledge unless the speaker claims it (我的 / 我写的 …)
    if (/^《/.test(s) ? /我(?:们)?(?:写|著|编|译|出)/.test(lead) : !record && !topic && PERSONAL.test(lead) && !CITING.test(lead)) return false;
    at = text.indexOf(s, at + s.length);
  }
  return seen;
}

/**
 * shieldPublic(clusters, { llm, stats, roster, rawLines }) -> { clusters, restore(text), spans }
 * clusters: [{ topic, segments[] }] already scrubbed by L1/L2.
 */
export async function shieldPublic(clusters, { llm, stats, roster = [], rawLines = [], shared = null } = {}) {
  const none = { clusters, restore: (t) => t, spans: [] };
  if (!llm || !clusters?.length) return none;
  const text = clusters.flatMap((c) => c.segments).join('\n');
  // classify in chunks of ~20 fragments: one long request truncates or fails as a whole, losing every span at once
  const lines = text.split('\n'), chunks = [];
  for (let i = 0; i < lines.length; i += 20) chunks.push(lines.slice(i, i + 20).join('\n'));
  // models sometimes return {text} objects instead of strings
  const ask = async (system, user) => { try { const { data } = await chatJSON(llm, [{ role: 'system', content: system }, { role: 'user', content: user }], { stats, temperature: 0 }); return Array.isArray(data?.spans) ? data.spans.map((x) => String((x && typeof x === 'object' ? x.text ?? x.span ?? '' : x) ?? '').trim()).filter(Boolean) : null; } catch { return null; } };
  const ctxNote = shared ? `${PUBLIC_BODY_NOTE(shared)}\n\n` : '';
  const per = await Promise.all(chunks.map(async (ch) => {
    const first = await ask(CLASSIFY_SYSTEM, `${ctxNote}FRAGMENTS:\n${ch}`);
    if (!first) return null;
    const more = await ask(RECALL_SYSTEM, `${ctxNote}FIRST PASS:\n${JSON.stringify(first)}\n\nFRAGMENTS:\n${ch}`);
    return [...first, ...(more || [])];
  }));
  if (per.every((x) => x == null)) return none;
  const cand = per.flatMap((x) => x || []);
  cand.push(...cueSpans(text));
  const civic = new Set(shared ? civicStrong(text) : []);
  const civicAll = new Set(shared ? civicSpans(text) : []);
  cand.push(...civicAll);
  // the full L2 identifier set: roster names, aliases, titles, own works, orgs (incl. self-declared ones the gate folded
  // into the roster) AND every org fragment L2 redacts, plus learned third-party names (roster entries added by the gate).
  // A span containing any of them is never tagged, so nothing identifying is ever restored verbatim.
  // public-body mode: the shared context (convening body, jurisdiction) is not an identifier of anyone in the room
  const rt = shared ? rosterTokens(roster.map((p) => (p?.org ? { ...p, org: String(p.org).split('，').filter((o) => !isSharedOrg(o, shared)).join('，') } : p))).filter((t) => !isSharedOrg(t, shared)) : rosterTokens(roster);
  const frag = shared ? roster.flatMap((p) => [...memberOrgFragments(p, shared)]) : roster.flatMap((p) => (p?.org ? [...orgFragments(p.org)] : []));
  const toks = [...new Set([...rt, ...frag.map((x) => String(x).trim()).filter((x) => x.length >= 2)])].sort((a, b) => b.length - a.length);
  const own = selfFigures(rawLines);
  let spans = [...new Set(cand)].filter((s) => eligible(s, text, { toks, own, record: civic.has(s) })).sort((a, b) => b.length - a.length);
  // public-body mode: a person-shaped span (given name / nickname ± surname) is never public by the shield's say-so —
  // only the curated public-figure list is; everyone else at a public hearing is a member of the public
  if (shared) spans = spans.filter((s) => !isPersonShaped(s) || PUBLIC_FIGURES.includes(s));
  if (spans.length) {
    try {
      // deterministic civic-record spans are public by shape: they skip the LLM precision pass (still eligibility-checked)
      const ask2 = spans.filter((s) => !civic.has(s));
      const msgs = [{ role: 'system', content: shared ? VERIFY_PUBLIC : VERIFY_SYSTEM }, { role: 'user', content: `${ctxNote}MEETING:\n${text}\n\nCANDIDATES:\n${JSON.stringify(ask2)}` }];
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
  const restore = (s) => String(s ?? '').replace(/⟦P(\d+)⟧/g, (m) => safeBack(back.get(m))).replace(/⟦[^⟧]*⟧/g, '').replace(/⟦P?\d*⟦?|⟧/g, '');
  return { clusters: clusters.map((c) => ({ topic: apply(c.topic), segments: c.segments.map(apply) })), hide: apply, restore, spans: kept, civic: kept.filter((s) => civicAll.has(s)) };
}

const PUBLIC_BODY_NOTE = (shared) => `CONTEXT: this is a PUBLIC meeting of ${shared[0]}. Its civic record is public world knowledge: agenda item, bill, resolution and ordinance numbers, municipal codes, vote tallies and outcomes, public departments, agencies and programmes of ${shared[0]}, and the addresses / properties and dates that the items concern. The private side is still private: who said what, a speaker's own office, employer, district, home, family or life story, private people they name, and private organisations a speaker represents or works at. An organisation discussed as the subject of an item (a contractor, a partner, a grantee) is part of the record.`;

export const SHIELD_NOTE = 'Tokens like ⟦P1⟧ stand for public names or public facts (laws, works, public figures, statistics). Copy every such token unchanged, exactly where it belongs in the sentence; never drop, translate or explain it.';
