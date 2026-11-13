// L0P · full pseudonymisation + adjudicated reveal_name (EmberBench v5, METHOD §10.1–§10.2). Deterministic, no I/O, no LLM.
// Public-body mode only (gate option `pseudonym`). Every person's name is replaced by a stable token before any model sees
// the text: roster entries → [Speaker N] ([发言者N]), other people → [Person N] ([人物N]). The rewrite may ask for a token to
// be shown by its real name (two-pass protocol: requests ride the L3 JSON, code adjudicates, code applies the grants after
// every other layer). Code decides: only PUBLIC persons (office-holder title on the roster / in the meeting materials, the
// shared public context, the curated public-figure list) in a TOPIC position are revealed; speaker labels never exist.
import { createHash } from 'node:crypto';
import { learnThirdNames, PUBLIC_FIGURES, isPersonShaped } from './l1.mjs';
import { boundSeats, isPublicEntity } from './binding.mjs';

const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const ci = (s) => [...String(s)].map((ch) => (/\p{L}/u.test(ch) && ch.toLowerCase() !== ch.toUpperCase() ? `[${esc(ch.toLowerCase())}${esc(ch.toUpperCase())}]` : /\s/.test(ch) ? '\\s+' : esc(ch))).join('');
const isCJK = (s) => /[\u3400-\u9fff]/.test(String(s));

// ---- public office titles (§10.2 (a)) -------------------------------------------------------------------------------
// roster titles: elected / appointed office. Staff ("staff — City Attorney's Office"), clerks, secretaries and members of
// the public are NOT public persons.
const OFFICE_RE = /\b(?:council\s*(?:member|man|woman|president)|council\s+member|president\s+pro\s+tem|vice\s+mayor|deputy\s+mayor|mayor|commissioner|supervisor|senator|assembly\s*(?:member|man|woman)|governor|city\s+manager|city\s+attorney|city\s+auditor|alder(?:man|woman|person))\b/i;
export const isPublicTitle = (title) => { const t = String(title ?? '').trim(); return !!t && !/^staff\b/i.test(t) && OFFICE_RE.test(t); };
// a name dropped in the meeting with one of these titles is a public office-holder (non-roster persons)
const OFFICE_WORDS = ['Council\\s*[Mm]ember', 'Council\\s+Member', 'Council\\s*[Mm]an', 'Council\\s*[Ww]oman', 'Council\\s+President', 'Vice\\s+Mayor', 'Deputy\\s+Mayor', 'Mayor', 'President', 'Commissioner', 'Supervisor', 'Senator', 'Representative', 'Assembly\\s*[Mm]ember', 'Governor', 'Judge', 'Sheriff', 'Chief(?:\\s+of\\s+Police)?', 'Alder(?:man|woman)'];
const HONORIFIC_WORDS = ['Mr', 'Ms', 'Mrs', 'Dr', 'Mister', 'Miss', 'Chair(?:man|woman|person)?', 'Vice\\s+Chair', 'Director', 'Professor', 'Officer', 'Pastor', 'Father'];
const capFirst = (w) => w.replace(/^([A-Z])/, (m) => `[${m}${m.toLowerCase()}]`);
const OFFICE_PFX = `(?:${OFFICE_WORDS.map(capFirst).join('|')})`;
const HON_PFX = `(?:${HONORIFIC_WORDS.map(capFirst).join('|')})`;
// any title that is folded into the token when it precedes a masked name ("Councilmember Cashman" → "[Speaker 4]")
const TITLE_PFX = `(?:(?:${OFFICE_PFX}|${HON_PFX}|[Mm]adam|[Mm]adame)\\.{0,2}\\s+(?:(?:pro\\s+tem|elect)\\s+)?)`;
const NAME_W = "[A-Z][a-z][\\p{L}'’-]*";
const NOT_NAME = new RegExp(`^(?:${['Council', 'City', 'County', 'District', 'Bill', 'Item', 'Resolution', 'Ordinance', 'Clerk', 'Secretary', 'Members?', 'Pro', 'Tem', 'Elect', 'President', 'Mayor', 'Chair', 'Vice', 'Deputy', 'Office', 'Department', 'Staff', 'General', 'Attorney', 'Manager', 'Auditor', 'Board', 'Committee', 'Commission', 'The', 'And', 'Of', 'Thank', 'Thanks', 'Yes', 'No', 'Aye', 'Please', 'Here', 'Present', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', 'Public', 'Speaker', 'Person', 'Madam', 'Mister', 'Pro-Tem', 'Councilmember', 'Councilman', 'Councilwoman', 'Councilor', 'Commissioner', 'Recommendation', 'All', 'This', 'That', 'These', 'Those', 'Was', 'Were', 'Is', 'It', 'One', 'Two', 'Can', 'We', 'You', 'They', 'He', 'She', 'Our', 'My', 'Your', 'So', 'But', 'Or', 'If', 'In', 'On', 'At', 'To', 'For', 'With', 'Just', 'Okay', 'Right', 'Well', 'Now', 'Then', 'There', 'Again', 'Also', 'Everyone', 'Good', 'Evening', 'Morning', 'Afternoon', 'Hello', 'Hey', 'Sorry', 'Great', 'Sure', 'Next', 'First', 'Last', 'Motion', 'Second', 'Seconded', 'Amendment', 'Agenda', 'Report', 'Street', 'Avenue', 'Boulevard', 'North', 'South', 'East', 'West', 'Beach', 'Customer', 'Black', 'White', 'God', 'SWAT'].join('|')})$`);
// single name parts that are ordinary words: masked only next to a title or another name part
const AMBIG = new Set('Bill Will May Mark Grant Price Rich Hope Joy Art Chase Dean Frank Long Rose Faith Grace Hall Street Park Lane Ray Wade Young Brown Black White Green Gray Grey King Bell Ward Field Wood Woods Hill Love Case Page Hunt Little Small Rice Cook Fox Lake Day Moore Best Hardy Strong Sharp Stone Rivers Banks Ford Lee Kelly Carter Major Judge Bishop Mayor Chair Council Price Gay Low Pierce Wise Sage Star Jay Dawn June April Summer Winter Autumn Sky Royal Noble Bond Cash Penny Cole Bush Marsh Moss Pool Glass Joyce'.split(' '));

// ---- bound positions (§10.2 (b); same rule as the v5 metric, implemented here independently) -------------------------
const PRE = /(?:\bthank(?:s|\s+you)?(?:\s+(?:so|very)\s+much)?(?:\s+(?:also|again))?(?:\s+to)?|\bthanked|\bgrateful\s+to|\brecogni[sz](?:e|es|ed|ing)|\bmoved\s+by|\bseconded\s+by|\bsecond(?:ed)?\s+(?:from|by)|\bmotion\s+(?:by|from)|\b(?:over|back)\s+to|\bcall(?:s|ed|ing)?\s+(?:up)?on|\baccording\s+to|\bwelcom(?:e|es|ed|ing)|\bhand(?:s|ed|ing)?\s+(?:it\s+)?(?:over\s+)?to|\byield(?:s|ed|ing)?\s+(?:the\s+floor\s+)?to|\bask(?:s|ed|ing)?|\bper|\b(?:proposed|introduced|offered|brought(?:\s+forward)?|put\s+forward|raised|requested|asked|suggested|presented|made|sponsored|moved|seconded|led|chaired|opened|closed|noted|stated|argued|explained|described|recommended|supported|opposed|questioned)\s+by|\bjoined\s+by|\bby|\bfrom|\bwith|感谢|谢谢|有请)\s*,?\s*(?:(?:the|a)\s+)?$/i;
const SPEECH_V = '(?:said|says|asked|asks|noted|notes|argued|argues|moved|moves|seconded|seconds|proposed|voted|votes|agreed|agrees|objected|objects|stated|states|explained|suggested|added|responded|commented|thanked|mentioned|urged|requested|recommended|recused|abstained|motioned|replied|remarked|answered|clarified|indicated|expressed|presented|introduced|spoke|testified)';
const POST = new RegExp(`^(?:'s|’s)?\\s*(?:,[^,.;!?]{0,60},\\s*)?(?:[\\p{L}\\p{N}'’-]+\\s+){0,3}?${SPEECH_V}\\b`, 'iu');
const ROLLCALL = /^\s*[,:]?\s*(?:aye|yes|no|nay|present|here)\b/i;
const POSS_OFFICE = /^(?:'s|’s)\s+(?:own\s+)?(?:council\s+)?(?:district|office|staff|seat|constituents|aide|aides|team)\b/i;
const SENT_END = /[.!?。！？;；\n]/;
/** true when the span text[start, end) is a vocative / procedural / speaker-binding position (never revealed). */
export function boundAt(text, start, end) {
  const s = String(text ?? '');
  let a = start; while (a > 0 && !SENT_END.test(s[a - 1])) a--;
  let b = end; while (b < s.length && !SENT_END.test(s[b])) b++;
  const before = s.slice(a, start), after = s.slice(end, b);
  if (PRE.test(before)) return true;
  if (POST.test(after) || ROLLCALL.test(after) || POSS_OFFICE.test(after)) return true;
  if (!before.trim() && /^\s*,/.test(after)) return true; // "X, you're recognised"
  if (/,\s*$/.test(before) && !after.replace(/["”’')\]\s]/g, '')) return true; // "… thank you, X."
  return false;
}

// ---- edit distance for ASR variants ---------------------------------------------------------------------------------
function lev(a, b) {
  const m = a.length, n = b.length; if (Math.abs(m - n) > 2) return 9;
  let prev = Array.from({ length: n + 1 }, (_, j) => j);
  for (let i = 1; i <= m; i++) { const cur = [i]; for (let j = 1; j <= n; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)); prev = cur; }
  return prev[n];
}

const NUMW = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, first: 1, second: 2, third: 3, fourth: 4, fifth: 5, sixth: 6, seventh: 7, eighth: 8, ninth: 9, tenth: 10 };
const seatNum = (s) => { const m = String(s).toLowerCase().match(/(\d+)|\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b/); return m ? Number(m[1] || NUMW[m[2]]) : null; };
const ORDW = '(?:\\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen)';
const DISTRICT = new RegExp(`\\b(?:(?:the\\s+)?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|1st|2nd|3rd|[4-9]th)\\s+(?:council\\s+)?district|(?:Council\\s+)?District\\s+(?:No\\.?\\s*)?${ORDW})\\b`, 'gi');
// clerk / secretary titles are bound to the meeting's own staff wherever they appear (gold: 'council secretary', 'Madam Clerk')
const STAFF_TITLE = /\b(?:(?:the|a|our)\s+)?(?:(?:deputy\s+)?(?:city|council|county)\s+(?:clerk|secretary)|[Mm]adam\s+(?:[Cc]ity\s+)?(?:[Mm]anager|[Aa]ttorney)|M[Rr]\.?\s+[Cc]ity\s+(?:[Mm]anagers?|[Aa]ttorneys?))\b/gi;
const OFFICER_VOC = /\b(?:[Mm]adam|[Mm]adame|[Mm]ister|M[Rr]\.?)\s+(?:(?:[Vv]ice|[Dd]eputy)\s+)?(?:[Cc]ouncil\s+)?(?:[Pp]resident|[Cc]hair(?:man|woman|person)?|[Mm]ayor|[Ss]peaker|[Cc]lerk|[Ss]ecretary)(?:\s+pro\s+tem)?\b/g;

// loose form for requests (the model may drop the brackets); strict bracketed form in the output pass
const TOKEN_RE = /\[?(Speaker|Person|发言者|人物)\s*(\d+)\]?/g;
const TOKEN_B = /\[(Speaker|Person|发言者|人物)\s?(\d+)\]/g;
const tokenOf = (kind, n, lang) => (lang === 'zh' ? `[${kind === 'speaker' ? '发言者' : '人物'}${n}]` : `[${kind === 'speaker' ? 'Speaker' : 'Person'} ${n}]`);
const keyOfToken = (kindWord, n) => `${/Speaker|发言者/.test(kindWord) ? 'speaker' : 'person'}:${n}`;

/**
 * buildPseudonyms({ roster, lines }, { seed, lang, shared }) → P
 * P.mask(text) → { text, n } · P.adjudicate(requests) → log · P.finalize(text) → text (post-check re-mask, grants, bound tokens generalised)
 */
export function buildPseudonyms(transcript, { seed = 1, lang = 'en', shared = [] } = {}) {
  const roster = transcript?.roster || [];
  const texts = (transcript?.lines || []).map((l) => String(l?.text ?? ''));
  const sharedLow = (shared || []).map((s) => String(s).toLowerCase());
  const sharedWords = new Set(sharedLow.flatMap((s) => s.split(/\s+/)));
  const entries = [];
  const add = (e) => { entries.push(e); return e; };
  // roster persons (named or unnamed: an unnamed speaker still gets a token, it simply has no name to mask or reveal)
  for (const p of roster) {
    const names = p.unnamed ? [] : [p.name, ...(p.aliases || []), p.publicName].filter(Boolean).map((x) => String(x).trim()).filter((x) => x.length >= 2);
    add({ key: `r:${p.id}`, kind: 'speaker', id: p.id, names, display: p.unnamed ? null : String(p.publicName || p.name), public: !p.unnamed && isPublicTitle(p.title), why: isPublicTitle(p.title) ? 'roster office title' : 'roster' });
  }
  const partOwner = (w) => entries.find((e) => e.names.some((n) => n.split(/\s+/).includes(w) || n === w));
  // non-roster persons: titled name drops and the gate's third-party learners
  const lowerSeen = new Set(texts.flatMap((t) => (t.match(/(?<![\p{L}'’])[a-z][a-z'’-]+/gu) || [])));
  const learned = new Map(); // name → { office:boolean }
  const TITLED = new RegExp(`(?<![\\p{L}])(${OFFICE_PFX}|${HON_PFX})\\.{0,2}\\s+(${NAME_W}(?:\\s+${NAME_W})?)`, 'gu');
  for (const t of texts) for (const m of t.matchAll(TITLED)) {
    let nm = m[2].split(/\s+/).filter((w) => !NOT_NAME.test(w));
    if (!nm.length) continue;
    if (nm.length === 2 && NOT_NAME.test(m[2].split(/\s+/)[1] || '')) nm = nm.slice(0, 1);
    const name = nm.join(' ');
    if (sharedWords.has(name.toLowerCase())) continue;
    const office = new RegExp(`^${OFFICE_PFX}$`, 'u').test(m[1]);
    if (!office && nm.length === 1 && lowerSeen.has(name.toLowerCase())) continue;
    const o = learned.get(name) || { office: false }; o.office ||= office; learned.set(name, o);
  }
  for (const n of learnThirdNames(texts, { allowPublicFacts: false, shared })) if (!learned.has(n)) learned.set(n, { office: false });
  const MYNAME = new RegExp(`\\b(?:[Mm]y\\s+name\\s+is|[Tt]his\\s+is|I'?m|I\\s+am)\\s+(${NAME_W}\\s+${NAME_W})`, 'gu');
  for (const t of texts) for (const m of t.matchAll(MYNAME)) if (!m[1].split(/\s+/).some((w) => NOT_NAME.test(w)) && !learned.has(m[1])) learned.set(m[1], { office: false });
  // given names (curated first-name / nickname list, l1 isPersonShaped) alone or with a capitalised surname: "Patty has been
  // very communicative", "Good evening, Lisa Lumley"
  const GIVEN = new RegExp(`(?<![\\p{L}'’])(${NAME_W}(?:\\s+${NAME_W})?)(?![\\p{L}'’-])`, 'gu');
  for (const t of texts) for (const m of t.matchAll(GIVEN)) {
    const ws = m[1].split(/\s+/);
    const nm = ws.length === 2 && NOT_NAME.test(ws[1]) ? ws[0] : m[1];
    if (isPersonShaped(nm) && !learned.has(nm) && !sharedWords.has(nm.toLowerCase())) learned.set(nm, { office: false });
  }
  // roll calls: in a line that answers a vote ("Sandoval, I. Sawyer, I. Torres. I. CdeBaca. Clarke."), every capitalised
  // word not used in lower case anywhere in the meeting is a member's name (an office-holder: council members vote)
  for (const t of texts) {
    const votes = (t.match(/(?:^|[.,;]\s*|\s)(?:I|Aye|Yes|No|Nay|Hi|High)(?=[.,;!]|\s*$)/g) || []).length;
    const nw = t.split(/\s+/).length;
    if (!(votes >= 2 && nw <= 60) && !(votes >= 1 && nw <= 8)) continue;
    for (const m of t.matchAll(/(?<![\p{L}'’])([A-Z][\p{L}'’-]{2,})(?![\p{L}])/gu)) {
      const w = m[1];
      if (NOT_NAME.test(w) || /^(?:Aye|Yes|Nay|High|Abstain|Absent|Hi)$/.test(w) || lowerSeen.has(w.toLowerCase()) || sharedWords.has(w.toLowerCase())) continue;
      const o = learned.get(w) || { office: false }; o.office = true; learned.set(w, o);
    }
  }
  // fold learned names into existing entries (same surname / name part), else new persons; longest form first
  const pubFig = new Set(PUBLIC_FIGURES);
  for (const [name, o] of [...learned].sort((a, b) => b[0].length - a[0].length)) {
    const parts = name.split(/\s+/);
    const owner = partOwner(name) || partOwner(parts.at(-1)) || entries.find((e) => e.kind === 'person' && e.names.some((n) => n.split(/\s+/).includes(parts.at(-1))));
    if (owner) { if (!owner.names.includes(name)) owner.names.push(name); if (owner.kind === 'person' && o.office && !owner.public) { owner.public = true; owner.why = 'office title in meeting'; } continue; }
    const pub = o.office ? 'office title in meeting' : pubFig.has(name) ? 'public-figure list' : sharedLow.includes(name.toLowerCase()) ? 'public context' : null;
    add({ key: `p:${name}`, kind: 'person', id: null, names: [name], display: name, public: !!pub, why: pub || 'learned' });
  }
  // short forms of a roster given name ("Val" for Valerie, "Chris" for Christina): a capitalised 3–4 letter prefix of a
  // ≥ 5-letter given name, never used in lower case in the meeting
  for (const e of entries.filter((x) => x.kind === 'speaker')) for (const n of [...e.names]) {
    const g = n.split(/\s+/)[0];
    if (!/^[A-Z][a-z]{4,}$/.test(g)) continue;
    for (const k of [3, 4]) { const pfx = g.slice(0, k); if (!lowerSeen.has(pfx.toLowerCase()) && !NOT_NAME.test(pfx) && !AMBIG.has(pfx) && texts.some((t) => new RegExp(`(?<![\\p{L}])${pfx}(?![\\p{L}])`, 'u').test(t)) && !e.names.includes(pfx)) e.names.push(pfx); }
  }
  // ASR variants of name parts (§10.1): capitalised, not sentence-initial, never seen in lower case, same initial
  const known = new Map();
  for (const e of entries) for (const n of e.names) for (const w of n.split(/\s+/)) if (/^[A-Z][a-z]{3,}$/.test(w)) known.set(w, e);
  for (const t of texts) for (const m of t.matchAll(/(?<![\p{L}'’])([A-Z][a-z]{3,})(?![\p{L}])/gu)) {
    const w = m[1];
    if (known.has(w) || lowerSeen.has(w.toLowerCase()) || NOT_NAME.test(w) || sharedWords.has(w.toLowerCase()) || AMBIG.has(w)) continue;
    if (/(?:^|[.!?]\s*)$/.test(t.slice(0, m.index))) continue; // sentence-initial
    for (const [k, e] of known) {
      if (k[0] !== w[0]) continue;
      const len = Math.max(k.length, w.length), d = lev(k.toLowerCase(), w.toLowerCase());
      if ((len <= 6 && d <= 1) || (len >= 7 && d <= 2)) { e.names.push(w); e.asr = (e.asr || 0) + 1; break; }
    }
  }
  // stable token numbers: a permutation by sha256(seed | entry key), not order of appearance
  const rank = (e) => createHash('sha256').update(`${seed}|${e.key}`).digest('hex');
  for (const kind of ['speaker', 'person']) entries.filter((e) => e.kind === kind).sort((a, b) => (rank(a) < rank(b) ? -1 : 1)).forEach((e, i) => { e.n = i + 1; e.token = tokenOf(kind, i + 1, lang); });
  const byKey = new Map(entries.map((e) => [`${e.kind}:${e.n}`, e]));

  // ---- the masking regex
  const full = new Map(), part = new Map(), cjk = new Map();
  for (const e of entries) for (const n of e.names) {
    if (isCJK(n)) { if (n.length >= 2) cjk.set(n, e); if (/^[\u4e00-\u9fff]{3,4}$/.test(n)) cjk.set(n.slice(1), e); continue; }
    const ws = n.split(/\s+/).filter(Boolean);
    if (ws.length > 1 && !full.has(n.toLowerCase())) full.set(n.toLowerCase(), { e, src: n });
    for (const w of ws) if (w.length >= 2 && /^[A-Z]/.test(w) && !NOT_NAME.test(w) && !sharedWords.has(w.toLowerCase()) && !part.has(w)) { part.set(w, e); if (w.length >= 3) part.set(w.toUpperCase(), e); }
  }
  const fullSrc = [...full.values()].map((x) => x.src).sort((a, b) => b.length - a.length).map(ci);
  // a single name part that is also an ordinary word in this meeting (Can, New) is masked only after a title
  const isAmb = (w) => AMBIG.has(w) || lowerSeen.has(w.toLowerCase());
  const plain = [...part.keys()].filter((w) => !isAmb(w)).sort((a, b) => b.length - a.length).map(esc);
  const amb = [...part.keys()].filter((w) => isAmb(w)).sort((a, b) => b.length - a.length).map(esc);
  const alts = [];
  if (fullSrc.length) alts.push(`(?<pfx1>${TITLE_PFX})?(?<full>${fullSrc.join('|')})`);
  if (plain.length) alts.push(`(?<pfx2>${TITLE_PFX})?(?<part>${plain.join('|')})`);
  if (amb.length) alts.push(`(?<pfx3>${TITLE_PFX})(?<amb>${amb.join('|')})`);
  const RE = alts.length ? new RegExp(`(?<![\\p{L}\\p{N}_\\[])(?:${alts.join('|')})(?<poss>'s|’s)?(?![\\p{L}\\p{N}_])`, 'gu') : null;
  const CJK_RE = cjk.size ? new RegExp([...cjk.keys()].sort((a, b) => b.length - a.length).map(esc).join('|'), 'g') : null;
  // bound seats: the speaker's own district (first-person, in the same utterance) + districts in roster titles
  const seatNums = new Set([...boundSeats(transcript?.lines || [])].map(seatNum).filter((x) => x != null));
  for (const p of roster) for (const m of String(p?.title || '').matchAll(DISTRICT)) { const k = seatNum(m[0]); if (k != null) seatNums.add(k); }
  const generic = lang === 'zh' ? '一位参与者' : 'a participant';
  // private speakers' own roster organisations (members of the public; not staff, clerks or office-holders), unless a public
  // entity: masked in any case ("National corporation" → "an organisation")
  const orgs = [];
  for (const p of roster) {
    const t = String(p?.title || '');
    if (isPublicTitle(t) || /^staff\b|clerk|secretary/i.test(t)) continue;
    for (const o0 of [p?.org, ...(p?.orgs || [])]) {
      const o = String(o0 || '').replace(/\s*\([^)]*\)\s*/g, ' ').trim();
      if (o.length < 4 || isPublicEntity(o, shared) || sharedLow.includes(o.toLowerCase()) || isPublicEntity(String(o0), shared)) continue;
      orgs.push(o);
    }
  }
  const ORG_RE = orgs.length ? new RegExp(`(?<![\\p{L}\\p{N}])(?:${[...new Set(orgs)].sort((a, b) => b.length - a.length).map((o) => esc(o).replace(/\s+/g, '\\s+')).join('|')})(?![\\p{L}\\p{N}])`, 'giu') : null;

  function mask(text) {
    let s = String(text ?? ''), n = 0;
    s = s.replace(OFFICER_VOC, (m) => { n++; return /clerk|secretary/i.test(m) ? 'meeting staff' : 'the presiding officer'; });
    s = s.replace(STAFF_TITLE, () => { n++; return 'meeting staff'; });
    if (ORG_RE) s = s.replace(ORG_RE, () => { n++; return 'an organisation'; });
    if (RE) s = s.replace(RE, (...args) => {
      const g = args.at(-1);
      const core = g.full ?? g.part ?? g.amb;
      const e = g.full != null ? full.get(core.toLowerCase().replace(/\s+/g, ' '))?.e || [...full.values()].find((x) => x.src.toLowerCase() === core.toLowerCase().replace(/\s+/g, ' '))?.e : part.get(core);
      if (!e) return args[0];
      n++;
      return `${e.token}${g.poss || ''}`;
    });
    // "[Speaker 4] [Speaker 4]" (first + last name split by the regex) → one token
    s = s.replace(/(\[(?:Speaker|Person) \d+\])(?:\s+\1)+/g, '$1');
    if (CJK_RE) s = s.replace(CJK_RE, (m) => { n++; return cjk.get(m).token; });
    if (seatNums.size) s = s.replace(DISTRICT, (m) => { const k = seatNum(m); if (k == null || !seatNums.has(k)) return m; n++; return 'a council district'; });
    return { text: s, n };
  }

  const log = [];
  const granted = new Set();
  /** §10.2: adjudicate reveal requests [{token, sentence, reason}] → log rows {token, decision, why, reason}. */
  function adjudicate(requests = []) {
    for (const r of Array.isArray(requests) ? requests : []) {
      const tok = String(r?.token ?? '').trim(), sentence = String(r?.sentence ?? ''), reason = String(r?.reason ?? '').trim();
      const m = [...tok.matchAll(TOKEN_RE)][0];
      const e = m ? byKey.get(keyOfToken(m[1], Number(m[2]))) : null;
      let why = null;
      if (!e) why = 'unknown-token';
      else if (!reason) why = 'no-reason';
      else if (!e.public || !e.display) why = 'private';
      // P9: a roster speaker is never revealed — the name would disclose who attended (T6), whatever the position
      else if (e.kind === 'speaker') why = 'speaker';
      else {
        const occ = [...sentence.matchAll(TOKEN_RE)].filter((x) => keyOfToken(x[1], Number(x[2])) === `${e.kind}:${e.n}`);
        if (!occ.length) why = 'not-in-sentence';
        else if (occ.some((x) => boundAt(sentence, x.index, x.index + x[0].length))) why = 'bound-position';
      }
      if (!why) granted.add(`${e.kind}:${e.n}`);
      log.push({ token: e ? e.token : tok.slice(0, 24), decision: why ? 'denied' : 'granted', why: why || (e.why), reason: mask(reason).text.slice(0, 160) });
    }
    return log;
  }
  const stat = { unmasked: 0, boundTokens: 0, remasked: 0 };
  /**
   * Final pass (after every other layer) + deterministic post-check: any real name that reappears (hallucinated, restored
   * by a later layer) is re-masked first; then each token occurrence is decided on its own: a bound position (vocative,
   * procedural, speaker-binding) → generic "a participant"; a granted person in a topic position → the real name.
   */
  function finalize(text) {
    const r = mask(text);
    stat.remasked += r.n;
    const s = r.text;
    let out = '', last = 0;
    for (const m of s.matchAll(TOKEN_B)) {
      const k = keyOfToken(m[1], Number(m[2])), e = byKey.get(k);
      if (!e) continue;
      let rep = e.token;
      if (boundAt(s, m.index, m.index + m[0].length)) { rep = generic; stat.boundTokens++; }
      else if (granted.has(k) && e.display) { rep = e.display; stat.unmasked++; }
      out += s.slice(last, m.index) + rep; last = m.index + m[0].length;
    }
    return (out + s.slice(last)).replace(/\b(a participant)(?:'s|’s)/g, "$1's").replace(/^a participant/, 'A participant');
  }  function summary() {
    const denied = {};
    for (const r of log) if (r.decision === 'denied') denied[r.why] = (denied[r.why] || 0) + 1;
    return { mode: 'two-pass', requests: log.length, granted: log.filter((r) => r.decision === 'granted').length, grantedPersons: granted.size, denied, unmasked: stat.unmasked, boundTokens: stat.boundTokens, remasked: stat.remasked,
      entries: { speakers: entries.filter((e) => e.kind === 'speaker').length, persons: entries.filter((e) => e.kind === 'person').length, public: entries.filter((e) => e.public && e.display).length, asrVariants: entries.reduce((s, e) => s + (e.asr || 0), 0) }, log };
  }
  return { entries, mask, adjudicate, finalize, summary, granted };
}

export const REVEAL_NOTE = (lang) => `PSEUDONYMS. Every person's name in the fragments has been replaced by a stable token such as ${lang === 'zh' ? '[发言者3] or [人物2]' : '[Speaker 3] or [Person 2]'}. Copy a token EXACTLY (with its brackets) only when that person is the subject matter of an idea (an amendment, letter, appointment or decision named after them, a public official's known position); never use a token to say who spoke, argued, moved, seconded, voted, asked, or was thanked or addressed — write those claims impersonally, as the other rules require.
REVEAL REQUESTS (reveal_name). When a claim's meaning depends on who a token is (e.g. "the [Person 4] amendment", "[Person 2]'s budget proposal"), you are strongly encouraged to request that the real name be shown: add {"token":"[Person 4]","sentence":"<the claim text exactly as you wrote it>","reason":"<why this person's identity is the topic>"} to a top-level "reveals" array. Rules: topic mentions only; never to label a speaker; never for thanks, greetings, roll calls or procedural address ("thank you X", "X moved / seconded", "X, you're recognised"); always give a reason. Code decides each request (members of the public are never revealed); a denied request is harmless.
OUTPUT then becomes {"sections":[...],"reveals":[...]}.`;
