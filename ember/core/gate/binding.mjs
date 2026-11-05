// Public-body mode (gate opt publicContext) only: binding-aware handling of organisations, seats and self-traits
// (EmberBench v3 framework, METHOD §8.1). Nothing here runs without a publicContext.
//   - an org mentioned as a TOPIC stays; an org BOUND to the speaker (my / our / I work at / on behalf of / X's staff /
//     as director of X) is an affiliation;
//   - bound + public entity → the affiliation construction is removed and the org survives as a topic subject;
//   - bound + private / unknown → generalised (L2 keeps redacting it everywhere);
//   - self-disclosed identity traits ("as the only woman on the council", "I've lived here 40 years") are removed.
// All rules are by shape (no names, no meeting-specific strings).

const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Government / public-body shape: a unit noun of public administration, and no private-entity marker.
const PUBLIC_UNIT = /\b(?:Department|Dept|Office|Division|Bureau|Agency|Authority|Commission|Board|Committee|Council|Court|Police|Fire|Library|Libraries|Parks?|Recreation|Public\s+Works|Public\s+Health|Health\s+Department|Transit|Transportation|Utilities|Utility|Port|Airport|Housing\s+Authority|Planning|Development\s+Services|Attorney|Clerk|Auditor|Treasurer|Assessor|Sheriff|Manager|Mayor|District|School\s+District|Services)\b/i;
const PRIVATE_MARK = /\b(?:Inc|Incorporated|LLC|L\.L\.C|Ltd|Limited|Corp|Corporation|Co|Company|LLP|PLLC|Foundation|Association|Alliance|Coalition|Club|Society|Union|Trust|Church|Ministries|Movement|Party|Network|Partners|Group|Holdings|Ventures|Capital|News|Media|Press|Neighbors|Neighbours|Residents|Friends\s+of|Pride|Chamber|Institute|Collective|Project|Studio|Studios|Restaurant|Cafe|Bar|Store|Shop|Realty|Properties|Construction|Consulting|Law\s+(?:Firm|Group|Office)|corporation|company|business)\b/;
const PRIVATE_SHAPE = /\(|\bnational corporation\b|\b(?:LLC|Inc)\b/i;
/** Deterministic public-entity test (unknown → false). Shared context (the convening body) is public by definition. */
export function isPublicEntity(org, shared = []) {
  const o = String(org || '').trim();
  if (!o) return false;
  if ((shared || []).some((s) => s.toLowerCase() === o.toLowerCase())) return true;
  if (PRIVATE_MARK.test(o) || PRIVATE_SHAPE.test(o)) return false;
  // short acronym (CPD, SDOT): public only when the org string itself is just that acronym of a public unit — unknown otherwise
  if (/^[A-Z]{2,6}$/.test(o)) return false;
  return PUBLIC_UNIT.test(o) || /^City\s+(?:Attorney|Manager|Clerk|Auditor)/i.test(o);
}

// ---- binding: affiliation constructions around an org mention -------------------------------------------------------
const PERSON = "(?:participant|speaker|member|members|representative|representatives|rep|presenter|resident|residents|staff|staffer|official|officials|director|employee|employees|someone|person|people|one|commenter|caller|volunteer|volunteers|leader|head|manager|chair|president|ceo|founder|spokesperson|attendee|delegate|advocate|organi[sz]er|worker|workers|colleague|view|voice|perspective)";
const ROLE = "(?:representative|representatives|director|staff|staffer|official|officials|employee|employees|spokesperson|presenter|leadership|head|chief|ceo|president|chair|manager|team|member|members|volunteers?)";
/** Regexes (one per construction) that bind `org` to a person in a sentence. Each has named group `a` = whole construction. */
export function affiliationRes(org) {
  const o = `(?:the\\s+)?${esc(org)}`;
  return [
    new RegExp(`\\b(?:an?\\s+|the\\s+|one\\s+)?${PERSON}s?\\s+(?:from|of|at|with|in|within|representing|for)\\s+${o}(?![\\p{L}\\p{N}])`, 'giu'),
    new RegExp(`\\b(?:on behalf of|speaking on behalf of|speaking for|representing|works? (?:at|for|with)|worked (?:at|for)|working (?:at|for)|employed (?:at|by)|volunteers? (?:at|for|with))\\s+${o}(?![\\p{L}\\p{N}])`, 'giu'),
    new RegExp(`\\b(?:an?\\s+|one\\s+)?${o}(?:'s|’s)?\\s+${ROLE}(?![\\p{L}\\p{N}])`, 'giu'),
    new RegExp(`\\b(?:my|our|their|his|her)\\s+(?:own\\s+)?(?:[\\p{L}-]+\\s+){0,3}?${esc(org)}(?![\\p{L}\\p{N}])`, 'giu'),
    new RegExp(`\\bas\\s+(?:the\\s+|a\\s+|an\\s+)?(?:[\\p{L}-]+\\s+){0,2}?(?:director|head|chair|president|manager|ceo|founder|member|representative|employee|staff)\\s+(?:of|at|for)\\s+${o}(?![\\p{L}\\p{N}])`, 'giu'),
    new RegExp(`\\b(?:I|we)(?:'m|’m|'re|’re|\\s+am|\\s+are)\\s+(?:here\\s+)?(?:with|from|at)\\s+${o}(?![\\p{L}\\p{N}])`, 'giu'),
  ];
}
export const hasAffiliation = (sentence, org) => affiliationRes(org).some((re) => { re.lastIndex = 0; return re.test(String(sentence ?? '')); });

/**
 * Orgs co-listed with a speaker's own org in one sentence of that speaker ("… as well as the Unity League, the
 * Eastside Residents Council, Frontline News"): a list of affiliations that contains the speaker's own org is a list of
 * the speaker's affiliations, so every capitalised org-shaped item in it is bound to the speaker.
 */
const ORG_ITEM = /(?:the\s+)?([A-Z][\w'&.-]*(?:\s+(?:[A-Z][\w'&.-]*|of|for|and|de)){1,6})/;
export function coListedOrgs(text, ownOrgs = []) {
  const own = ownOrgs.map((o) => String(o).trim()).filter((o) => o.length >= 4);
  if (!own.length) return [];
  const out = new Set();
  for (const sen of sentencesOf(text)) {
    const at = own.find((o) => sen.includes(o));
    if (!at) continue;
    // split the sentence into list items around the own org
    const items = sen.split(/,\s*(?:and\s+|as\s+well\s+as\s+)?|\s+as\s+well\s+as\s+|\s+and\s+(?=(?:the\s+)?[A-Z])/);
    const k = items.findIndex((x) => x.includes(at));
    if (k < 0) continue;
    for (let j = Math.max(0, k - 3); j <= Math.min(items.length - 1, k + 3); j++) {
      if (j === k) continue;
      const m = items[j].trim().match(new RegExp(`^${ORG_ITEM.source}$`));
      if (!m) continue;
      const o = m[1].trim();
      if (/\s(?:of|for|and|de)$/.test(o) || /^(?:I|We|They|He|She|It|This|That|And|But|So|Thank|Good|Yes|No)\b/.test(o) || /^(?:Council\s*[Mm]ember|Councilmember|Councilwoman|Councilman|Mayor|President|Commissioner|Chair|Mr|Ms|Mrs|Dr|Senator|Governor)\b/.test(o)) continue;
      out.add(o);
    }
  }
  return [...out];
}

/** Article for a public org named as a topic subject: "the Parks Department", "the Office of X", but "Public Works". */
export const withThe = (org) => (/^the\s/i.test(org) || !/^(?:Office|Department|Division|Bureau|Agency|Board|Commission|Committee|Council|City|County|Port)\b|\b(?:Department|Office|Division|Bureau|Agency|Authority|Board|Commission|Committee|Council|Library|District)$/.test(org) ? org : `the ${org}`);
const capFirst = (s) => s.replace(/^\s*([a-z])/, (m, c) => m.replace(c, c.toUpperCase()));
const tidy = (s) => s.replace(/\s{2,}/g, ' ').replace(/\s+([,.;:!?])/g, '$1').replace(/,\s*,/g, ',').replace(/^\s*[,;:]\s*/, '').trim();
const sentencesOf = (t) => String(t ?? '').match(/[^.!?]+(?:[.!?]+|$)\s*/g) || [String(t ?? '')];

/**
 * Output guard: in each sentence, an affiliation construction around a PUBLIC org is removed and the sentence becomes
 * "Regarding <org>, …" (topic subject, no affiliation); around a PRIVATE / unknown org the org is generalised.
 * orgs: [{ org, public }]. Returns the rewritten text.
 */
export function unbindAffiliations(text, orgs = []) {
  const list = orgs.filter((x) => x?.org && String(x.org).trim().length >= 3).sort((a, b) => b.org.length - a.org.length);
  if (!list.length) return String(text ?? '');
  return sentencesOf(text).map((sen) => {
    let s = sen;
    // repeat: unbinding one org can expose another ("staff from X in Y" → "a participant in Y")
    for (let pass = 0; pass < 3; pass++) for (const { org, public: pub } of list) {
      if (!hasAffiliation(s, org)) continue;
      if (!pub) { s = s.replace(new RegExp(`(?:the\\s+)?${esc(org)}(?![\\p{L}\\p{N}])`, 'giu'), 'an organisation'); continue; }
      const [person, behalf, role, poss, asRole, iam] = affiliationRes(org);
      s = s.replace(person, 'a participant').replace(behalf, '').replace(role, (m) => (/^\s*(?:an?|one)\s/i.test(m) ? 'a participant' : 'staff'))
        .replace(poss, '').replace(asRole, '').replace(iam, 'I am here');
      s = tidy(s);
      const lead = sen.match(/^\s*/)[0], trail = /\s$/.test(sen) ? ' ' : '';
      const head = s.match(/^Regarding (.+?), /);
      if (head) { s = `${lead}Regarding ${head[1]} and ${withThe(org)}, ${s.slice(head[0].length)}${trail}`; continue; }
      const body = s ? s.replace(/^\s*([A-Z])(?=[a-z])/, (m, c) => c.toLowerCase()) : '';
      s = `${lead}Regarding ${withThe(org)}, ${body || 'a view was noted.'}${trail}`;
    }
    return s;
  }).join('');
}

// ---- referent rule: "my / our <category>" ---------------------------------------------------------------------------
const CATEGORY = '(?:department|office|division|bureau|agency|unit|program|programme|team|staff|center|centre|organization|organisation|company|firm|business|group|association|church|school|clinic|library|board|commission|committee|council|coalition|alliance|foundation|nonprofit|non-profit|shelter|store|restaurant)';
const CAT_RE = new RegExp(`\\b(my|our|My|Our)\\s+(own\\s+)?(${CATEGORY})\\b(?!\\s+(?:of|for)\\s+[A-Z])`, 'g');
const headOf = (cat) => cat.toLowerCase().replace(/^(?:centre)$/, 'center').replace(/^organisation$/, 'organization').replace(/^programme$/, 'program').replace(/^non-?profit$/, 'organization');
const orgHead = (org) => {
  const o = String(org || '').toLowerCase().replace(/centre/g, 'center').replace(/organisation/g, 'organization').replace(/programme/g, 'program');
  return o;
};
/**
 * Resolve "my / our <category>" in one speaker's line against that speaker's known orgs (roster + learned):
 *  - a public org whose name contains the category word → "the <Org>" (a topic subject, possessive removed);
 *  - otherwise (private / unknown / unresolved) → "a <category>" (generalised, no possessive).
 * "my / our office | staff | team" of an elected official (no non-shared org) is their seat → "a council office".
 */
export function resolveReferents(text, speakerOrgs = [], { shared = [] } = {}) {
  const orgs = speakerOrgs.map((o) => String(o || '').trim()).filter((o) => o && !(shared || []).some((s) => s.toLowerCase() === o.toLowerCase()));
  return String(text ?? '').replace(CAT_RE, (m, poss, own, cat) => {
    const h = headOf(cat);
    const hit = orgs.find((o) => new RegExp(`\\b${esc(h)}\\b`, 'i').test(orgHead(o)) || (h === 'department' && /\bDepartment\b|\bServices\b/i.test(o)));
    const art = /^[aeiou]/i.test(cat) ? 'an' : 'a';
    // a generic unit word ("our department", "my team") of a speaker with exactly one org refers to that org
    const ref = hit || (orgs.length === 1 && /^(?:department|office|division|bureau|agency|unit|team|staff)$/i.test(cat) ? orgs[0] : null);
    const up = (s) => (/^[A-Z]/.test(poss) ? s.replace(/^./, (x) => x.toUpperCase()) : s);
    if (ref && isPublicEntity(ref, shared)) return up(withThe(ref));
    if (!orgs.length && /^(?:office|staff|team)$/i.test(cat)) return up('a council office');
    return up(`${art} ${cat}`);
  });
}

// ---- seats: a district is bound only when the speaker refers to it as their own ------------------------------------
const ORD = '(?:\\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen)';
const DISTRICT_RE = new RegExp(`\\b(?:Council\\s+)?District\\s+(?:No\\.?\\s*)?${ORD}\\b|\\b(?:the\\s+)?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|1st|2nd|3rd|[4-9]th)\\s+(?:council\\s+)?district\\b`, 'gi');
const OWN_SEAT = /\b(?:my|our)\s+(?:own\s+)?(?:council\s+)?district\b|\bI\s+represent\b|\b(?:represent(?:s|ing)?|in)\s+my\s+district\b|\bmy\s+constituents\b/i;
/** Seat references ("District six", "the fourth district") that a speaker binds to themselves in the same utterance. */
export function boundSeats(lines = []) {
  const out = new Set();
  for (const l of lines || []) {
    const t = String(l?.text ?? '');
    if (!OWN_SEAT.test(t)) continue;
    for (const m of t.matchAll(DISTRICT_RE)) out.add(m[0].replace(/^the\s+/i, '').toLowerCase());
  }
  return out;
}

// ---- self-disclosed identity traits ---------------------------------------------------------------------------------
const NUM = '(?:\\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|several|many|a\\s+few|a\\s+couple\\s+of)(?:[\\s-]+(?:one|two|three|four|five|six|seven|eight|nine|plus|odd))?';
const TRAIT_PATTERNS = [
  // "as the only / first / last / youngest X (on|in|of) the council" — the clause up to the next comma
  /\b[Aa]s\s+(?:the|a|an|one\s+of\s+the)\s+(?:only|first|last|youngest|oldest|longest[- ]serving|newest|sole)\b[^,.;!?]{1,60}/g,
  // "I've lived here (for) 40 years" / "I have lived in X for 40 years" / "I've been a resident (of X) for 25 years"
  new RegExp(`\\b(?:I|we)(?:'ve|’ve|\\s+have|\\s+had)?\\s+(?:lived|resided|been\\s+(?:living|residing)|been\\s+an?\\s+(?:resident|homeowner|renter|tenant|member|teacher|nurse|business\\s+owner|owner|volunteer)|owned\\s+(?:a|my|our)\\s+\\w+|worked|served|taught)\\b[^,.;!?]{0,50}?\\b(?:for\\s+)?(?:the\\s+(?:past|last)\\s+)?${NUM}\\s+(?:years?|decades?)\\b`, 'gi'),
  // "for 40 years I have lived …" / "on record for the past 25 years"
  new RegExp(`\\b(?:for|over)\\s+(?:the\\s+(?:past|last)\\s+)?${NUM}\\s+(?:years?|decades?)\\s*,?\\s+(?:I|we)(?:'ve|’ve|\\s+have)?\\s+(?:lived|been|worked|served|owned)\\b[^,.;!?]{0,40}`, 'gi'),
  // "when I became / was a legislative assistant", "I used to be a X", "I grew up in X", "I was born in X"
  /\b(?:when\s+I\s+(?:first\s+)?(?:became|was|started\s+as)\s+(?:a|an|the)\s+[^,.;!?]{2,50}|I\s+used\s+to\s+(?:be|work\s+as)\s+(?:a|an|the)\s+[^,.;!?]{2,50}|I\s+(?:grew\s+up|was\s+born|was\s+raised)\s+(?:in|on|here)[^,.;!?]{0,40})/gi,
  // "a native of X", "a (lifelong|third-generation) resident of X", "as a mother of two", "as a veteran"
  /\b(?:I'?m|I\s+am|as)\s+(?:a|an)\s+(?:lifelong\s+|longtime\s+|long-time\s+|proud\s+|(?:second|third|fourth|fifth)[- ]generation\s+)?(?:native|resident|veteran|mother|father|parent|grandmother|grandfather|widow|immigrant|refugee|survivor|cancer\s+survivor|single\s+mom|single\s+mother|renter|homeowner)\b(?:\s+of\s+[^,.;!?]{1,40})?/gi,
];
/** Remove first-person self-disclosed identity traits from one utterance (public-body mode, before L3). */
export function stripSelfTraits(text) {
  let s = String(text ?? '');
  for (const re of TRAIT_PATTERNS) s = s.replace(re, '');
  return tidy(s.replace(/\(\s*\)/g, '')).replace(/^\s*(?:and|but|so)\s+/i, '') || '';
}
// third-person echoes the rewrite may produce ("a participant who has lived in the area for 40 years")
const TRAIT_OUT = [
  new RegExp(`,?\\s*(?:who|which)\\s+(?:has|had)\\s+(?:lived|resided|been\\s+(?:a|an)\\s+[\\w-]+|worked|served)\\b[^,.;!?]{0,50}?${NUM}\\s+(?:years?|decades?)\\b[^,.;!?]{0,20},?`, 'gi'),
  /,?\s*(?:as|being)\s+(?:the|a|an)\s+(?:only|first|sole|youngest|oldest|longest[- ]serving)\s+[^,.;!?]{1,50}(?:on|in|of)\s+the\s+(?:council|board|commission|committee|body|panel)\b,?/gi,
  /,?\s*(?:a\s+)?(?:lifelong|longtime|long-time|(?:second|third|fourth|fifth)[- ]generation)\s+(?:resident|native)(?:\s+of\s+[^,.;!?]{1,40})?,?/gi,
];
export function stripSelfTraitsOut(text) {
  let s = String(text ?? '');
  for (const re of TRAIT_OUT) s = s.replace(re, (m) => (/^,/.test(m) && /,$/.test(m) ? ',' : ' '));
  return tidy(s);
}

// ---- meeting-officer references in the digest -----------------------------------------------------------------------
// "the chair will sign", "the clerk is to call the roll": each names one seat holder. Public-body mode neutralises them.
const OFFICER = /\b(?:the|our)\s+(?:council\s+|committee\s+)?(?:chair(?:man|woman|person)?(?:\s+of\s+the\s+committee)?|clerk|council\s+secretary|secretary|presiding\s+officer|council\s+president|president\s+pro\s+tem(?:pore)?)\b/gi;
export function neutraliseOfficers(text) {
  return String(text ?? '').replace(OFFICER, (m) => {
    const r = /clerk|secretary/i.test(m) ? 'meeting staff' : 'the presiding officer';
    return /^[A-Z]/.test(m) ? r.replace(/^./, (x) => x.toUpperCase()) : r;
  });
}

// ---- verbatim restore of the civic record ---------------------------------------------------------------------------
const STOP = new Set('the a an and or of to in on at for from by with as is are was were be been this that these those it its which who will would should could can may might has have had not no there their they we our you your i me my he she his her them than then into about over under also just very so such per each any all some more most other'.split(' '));
const words = (s) => new Set((String(s).toLowerCase().match(/[a-z][a-z'-]{2,}|\d+/g) || []).filter((w) => !STOP.has(w)));
const norm = (s) => String(s).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
/**
 * For every civic span missing from the body, append it (verbatim, in parentheses) to the claim most similar to the
 * source sentence(s) it came from. Only copies existing spans; never writes a number of its own. Returns
 * { sections, restored, left } (left = spans with no good home; they stay for the Public record appendix).
 */
const VOTE_SPAN = /\b(?:ayes?|eyes|yeas?|nays?|noes|in\s+favou?r|opposed|abstentions?|passes|passed|carries|carried|fails|failed|adopted)\b/i;
const VOTE_CLAIM = /\b(?:vot(?:e|ed|ing)|roll[- ]call|in\s+favou?r|opposed|unanimous|passed|passes|adopted|approved|carried|fail(?:s|ed))\b/i;
export function restoreCivic(sections, spans = [], rawText = '', { minScore = 0.12, maxPerClaim = 3 } = {}) {
  const flat = sections.flatMap((s, si) => s.claims.map((c, ci) => ({ si, ci, c, w: words(`${s.topic} ${c.text}`) })));
  const body = () => norm(sections.flatMap((s) => [s.topic, ...s.claims.map((c) => c.text)]).join(' \n '));
  const sents = String(rawText).split(/(?<=[.!?])\s+|\n/);
  const added = new Map();
  let restored = 0; const left = [];
  for (const sp of [...new Set(spans)].sort((a, b) => b.length - a.length)) {
    if (!sp || body().includes(norm(sp))) continue;
    const idx = sents.map((x, i) => (x.includes(sp) ? i : -1)).filter((i) => i >= 0);
    if (!idx.length) { left.push(sp); continue; }
    // the source sentence plus its neighbours (a short vote line "seven in favor one opposed." has little context)
    const own = words(idx.map((i) => sents[i]).join(' '));
    const sw = words(idx.flatMap((i) => sents.slice(Math.max(0, i - 1), i + 2)).join(' '));
    for (const w of words(sp)) { sw.delete(w); own.delete(w); }
    const vote = VOTE_SPAN.test(sp);
    let best = null, bs = 0;
    for (const x of flat) {
      if ((added.get(x) || 0) >= maxPerClaim) continue;
      // own-sentence words count fully, neighbour-only words half
      let inter = 0; for (const w of x.w) if (own.has(w)) inter++; else if (sw.has(w)) inter += 0.5;
      const sc = inter / Math.max(4, Math.min(sw.size, x.w.size)) + (vote && VOTE_CLAIM.test(x.c.text) ? 0.25 : 0);
      if (sc > bs) { bs = sc; best = x; }
    }
    if (!best || bs < minScore) { left.push(sp); continue; }
    const t = String(best.c.text).replace(/\s+$/, '');
    best.c.text = /[.!?]$/.test(t) ? `${t.slice(0, -1)} (${sp})${t.slice(-1)}` : `${t} (${sp})`;
    added.set(best, (added.get(best) || 0) + 1); restored++;
  }
  return { sections, restored, left };
}

export { capFirst };
