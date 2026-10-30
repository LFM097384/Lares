#!/usr/bin/env node
// EmberBench-Public · importer for real council transcripts (MeetingBank derivative, Kaggle
// abhishekunnam/meeting-transcripts). Deterministic, no network, no LLM.
//   node ember/bench/gen/import-public.mjs [--src .data/kaggle-meeting] [--out .data/emberbench-public/raw]
//        [--per-city 8] [--max-words 2000] [--seed emberbench-public-1]
// Writes skeleton transcripts (bench schema; roster from the deterministic name heuristic, gold empty) to
// <out>/<split>/<id>.json plus <out>/selection.json. The text NEVER goes into git: the default paths are under
// .data/ (git-excluded). gen/annotate-public.mjs then adds the roster mapping and gold (Kimi + Qwen check).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '..', '..', '..');
export const PUBLIC_ROOT = path.join(REPO, '.data', 'emberbench-public');

// ---------------------------------------------------------------- split by city (METHOD §7.3)
// dev = the three largest pools (room to grow dev later without touching test); test = held-out cities,
// including a county council (King County) and a council with a different title convention (Boston "Councilor").
export const CITIES = {
  LongBeachCC: { split: 'dev', city: 'Long Beach', body: 'Long Beach City Council', context: ['Long Beach City Council', 'City of Long Beach', 'Long Beach', 'City Council'] },
  DenverCityCouncil: { split: 'dev', city: 'Denver', body: 'Denver City Council', context: ['Denver City Council', 'City and County of Denver', 'City of Denver', 'Denver', 'City Council'] },
  SeattleCityCouncil: { split: 'dev', city: 'Seattle', body: 'Seattle City Council', context: ['Seattle City Council', 'City of Seattle', 'Seattle', 'City Council'] },
  AlamedaCC: { split: 'test', city: 'Alameda', body: 'Alameda City Council', context: ['Alameda City Council', 'City of Alameda', 'Alameda', 'City Council'] },
  BostonCC: { split: 'test', city: 'Boston', body: 'Boston City Council', context: ['Boston City Council', 'City of Boston', 'Boston', 'City Council'] },
  KingCountyCC: { split: 'test', city: 'King County', body: 'King County Council', context: ['Metropolitan King County Council', 'King County Council', 'King County', 'County Council'] },
};
export const cityOf = (meetingUid) => String(meetingUid).split('_')[0];

// ---------------------------------------------------------------- CSV
export function parseCSV(s) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === '"') { if (s[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
    else if (c !== '\r') f += c;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  return rows;
}
export function loadRows(src) {
  const out = [];
  for (const part of ['train', 'validation', 'test']) {
    const file = path.join(src, `${part}_df.csv`);
    if (!existsSync(file)) continue;
    const [h, ...rs] = parseCSV(readFileSync(file, 'utf8'));
    const ix = Object.fromEntries(h.map((k, i) => [k.trim(), i]));
    for (const r of rs) if (r[ix.Transcript]) out.push({ id: r[ix.id], item: r[ix.Item_UID], meeting: r[ix.Meeting_UID], transcript: r[ix.Transcript], date: r[ix.Date], kagglePart: part });
  }
  return out;
}

// ---------------------------------------------------------------- turns
/** "Speaker N: …" segments → [{label, text}] (labels kept as in the source). */
export function segments(transcript) {
  return [...String(transcript).matchAll(/(?:^|\n)\s*Speaker (\d+):\s*([\s\S]*?)(?=\n\s*Speaker \d+:|$)/g)].map((m) => ({ label: `Speaker ${m[1]}`, text: m[2].replace(/\s+/g, ' ').trim() })).filter((x) => x.text);
}
/** Consecutive segments of one speaker are one turn (the ASR splits long turns at arbitrary points). */
export function mergeTurns(segs) {
  const out = [];
  for (const s of segs) { if (out.length && out.at(-1).label === s.label) out.at(-1).text += ' ' + s.text; else out.push({ ...s }); }
  return out;
}
export const wordCount = (s) => (String(s).match(/\S+/g) || []).length;

export function profile(row) {
  const turns = mergeTurns(segments(row.transcript));
  return { words: wordCount(row.transcript), speakers: new Set(turns.map((t) => t.label)).size, turns: turns.length, turnList: turns };
}
/** Eligibility (METHOD §7.2): 600–3500 words, 4–8 distinct speakers, 18–60 merged turns, known city. */
export function eligible(p, { minWords = 600, maxWords = 3500, minSpeakers = 4, maxSpeakers = 8, minTurns = 18, maxTurns = 60 } = {}) {
  return p.words >= minWords && p.words <= maxWords && p.speakers >= minSpeakers && p.speakers <= maxSpeakers && p.turns >= minTurns && p.turns <= maxTurns;
}

// ---------------------------------------------------------------- roster heuristic
// A titled name: "Councilwoman Gonzalez", "Mayor Foster", "Councilor Lydia Edwards", "Vice Mayor Knox White".
const TITLES = ['Council President', 'Council Member', 'Councilmember', 'Councilwoman', 'Councilman', 'Councilperson', 'Councilor', 'Counselor', 'Council Woman', 'Council Man', 'Vice Mayor', 'Mayor', 'Vice Chair', 'Chairwoman', 'Chairman', 'Chair', 'President', 'Madam Clerk', 'Commissioner', 'Supervisor', 'Vice President', 'Mr.', 'Mrs.', 'Ms.', 'Dr.'];
const NAME = "[A-Z][a-zA-Z'\\-]+(?:\\s+(?!And\\b|The\\b|For\\b|You\\b)[A-Z][a-zA-Z'\\-]+)?";
const TITLE_RE = new RegExp(`\\b(${TITLES.map((t) => t.replace(/[.]/g, '\\.').replace(/ /g, '\\s+')).join('|')})\\s+(${NAME})`, 'g');
const NOT_NAMES = new Set(['City', 'Council', 'Clerk', 'Pro', 'Tem', 'Members', 'Member', 'Of', 'The', 'And', 'Thank', 'Yes', 'No', 'Please', 'So', 'Okay', 'Madam', 'Mister', 'Chair', 'Speaker', 'Public', 'Item', 'Vice', 'President', 'Mayor', 'Chairman', 'Chairwoman', 'Councilmember', 'Councilwoman', 'Councilman', 'Councilor']);

/** All titled names in a text: [{title, name, surname, at}] */
export function titledNames(text) {
  const out = [];
  for (const m of String(text).matchAll(TITLE_RE)) {
    const parts = m[2].split(/\s+/).filter((w) => !NOT_NAMES.has(w));
    if (!parts.length) continue;
    const name = parts.join(' ');
    out.push({ title: m[1].replace(/\s+/g, ' '), name, surname: parts.at(-1), at: m.index, end: m.index + m[0].length });
  }
  return out;
}
const FLOOR_CUE = /(you have the floor|the floor is yours|go ahead|please proceed|recogni[sz]es?|is recognized|your (?:turn|time)|welcome)/i;

/**
 * Deterministic speaker → name proposal from addressing patterns (a hint for the annotator, never gold by itself):
 *   - turn i names "<Title> X" in its last ~160 chars or with a floor cue, and turn i+1 is another speaker → X for turn i+1 (w 2)
 *   - a roll call "<Title> X?" followed by a short "Yes/Aye/No" turn → X for that speaker (w 2)
 *   - turn i+1 opens "Thank you, <Title> X" → X for the speaker of turn i (w 1)
 *   - self-identification "I'm / My name is / This is X" → own speaker (w 2)
 * Returns { [label]: {surname, name, title, votes, share, evidence[]} | null }.
 */
export function proposeRoster(turns) {
  const votes = new Map(); // label → Map(surnameKey → {name,title,w,evidence[]})
  const add = (label, n, w, evidence) => {
    if (!label || !n) return;
    if (!votes.has(label)) votes.set(label, new Map());
    const k = n.surname.toLowerCase();
    const v = votes.get(label).get(k) || { surname: n.surname, name: n.name, title: n.title, w: 0, evidence: [] };
    if (n.name.split(' ').length > v.name.split(' ').length) v.name = n.name;
    if (!/^(Mr\.|Mrs\.|Ms\.|Dr\.)$/.test(n.title)) v.title = n.title;
    v.w += w; if (v.evidence.length < 3) v.evidence.push(evidence);
    votes.get(label).set(k, v);
  };
  for (let i = 0; i < turns.length; i++) {
    const cur = turns[i], next = turns[i + 1], prev = turns[i - 1];
    const names = titledNames(cur.text);
    if (next && next.label !== cur.label) {
      for (const n of names) {
        const tail = cur.text.length - n.end <= 160;
        const cue = FLOOR_CUE.test(cur.text.slice(Math.max(0, n.at - 80), n.end + 80));
        if (tail || cue) add(next.label, n, tail && cue ? 3 : 2, cur.text.slice(n.at, n.end));
      }
    }
    if (prev && prev.label !== cur.label) {
      const m = cur.text.match(new RegExp(`^(?:thank you|thanks)[,.]?\\s+(?:very much,?\\s+)?(?:madam\\s+|mr\\.\\s+)?`, 'i'));
      if (m) { const n = titledNames(cur.text.slice(m[0].length - 1, m[0].length + 60))[0]; if (n && n.at <= 2) add(prev.label, n, 1, cur.text.slice(0, m[0].length + n.end)); }
    }
    for (const m of cur.text.matchAll(/\b(?:I'm|I am|my name is|this is)\s+((?:Councilmember|Councilwoman|Councilman|Councilor|Mayor|Vice Mayor)\s+)?([A-Z][a-z'\-]+(?:\s+[A-Z][a-z'\-]+)?)\b/g)) {
      const parts = m[2].split(/\s+/).filter((w) => !NOT_NAMES.has(w));
      if (parts.length && (m[1] || parts.length === 2)) add(cur.label, { title: (m[1] || '').trim() || 'self', name: parts.join(' '), surname: parts.at(-1) }, 2, m[0]);
    }
  }
  // resolve: best surname per label, then a surname may belong to only one label (higher weight wins)
  const best = new Map();
  for (const [label, m] of votes) {
    const xs = [...m.values()].sort((a, b) => b.w - a.w);
    const total = xs.reduce((s, x) => s + x.w, 0);
    const top = xs[0];
    if (top.w >= 2 && top.w / total >= 0.6) best.set(label, { ...top, votes: top.w, share: top.w / total });
  }
  const owner = new Map();
  for (const [label, b] of best) { const k = b.surname.toLowerCase(); if (!owner.has(k) || best.get(owner.get(k)).votes < b.votes) owner.set(k, label); }
  const labels = [...new Set(turns.map((t) => t.label))];
  return Object.fromEntries(labels.map((l) => { const b = best.get(l); return [l, b && owner.get(b.surname.toLowerCase()) === l ? { surname: b.surname, name: b.name, title: b.title, votes: b.votes, share: Number(b.share.toFixed(2)), evidence: b.evidence } : null]; }));
}

// ---------------------------------------------------------------- aliases
// Surnames that are ordinary English words ("Price", "Brown", "Long") cannot be scanned bare without flooding T1 with
// false positives; for them only titled forms and the full name enter the deterministic leak list.
const COMMON_WORDS = new Set('long price rice black brown white green young king hill wood woods street rivers river lane bell gray grey west north south east fox hunter mason carpenter baker cook miller turner parker walker wells mayor chase grant may june rose hope frank bush little large best good love case early ward park banks cash bond strong sharp stone moon day knight power powers small short sweet waters lake field fields english major council city'.split(' '));
/** A surname is "common" if it is a listed English word or occurs in the text as an ordinary lower-case word. */
export function isCommonWord(surname, text = '') {
  const w = String(surname).toLowerCase();
  if (COMMON_WORDS.has(w)) return true;
  return new RegExp(`(^|[^A-Za-z])${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}($|[^A-Za-z])`).test(String(text)); // case-sensitive: lower-case use only
}
const TITLE_FORMS = { council: ['Councilmember', 'Councilwoman', 'Councilman', 'Council Member', 'Councilor'], mayor: ['Mayor'], 'vice mayor': ['Vice Mayor'], president: ['President', 'Council President'], chair: ['Chair', 'Chairman', 'Chairwoman'], clerk: [] };
/**
 * Leak-list aliases for a named roster member: full name, titled surname forms seen in the text or standard for the
 * role, and the bare surname unless it is a common word. Placeholder (unnamed) members get no aliases.
 */
export function buildAliases({ name, aliases = [], role = '' }, text = '') {
  if (!name) return [];
  const parts = String(name).trim().split(/\s+/);
  const surname = parts.at(-1);
  const out = new Set([...aliases.filter(Boolean)]);
  if (parts.length > 1) out.add(parts.join(' '));
  // The bare surname covers every titled form on a whole-word scan, so titled forms are added only for common-word surnames
  // (gate L1 splits every alias into parts; a lean list keeps the roster close to what a real deployment would enter).
  if (!isCommonWord(surname, text)) out.add(surname);
  else {
    const r = String(role).toLowerCase();
    const forms = Object.entries(TITLE_FORMS).filter(([k]) => r.includes(k)).flatMap(([, v]) => v);
    for (const f of new Set(forms)) out.add(`${f} ${surname}`);
  }
  return [...out].filter((a) => a && a !== name && a.length >= 2);
}

// ---------------------------------------------------------------- transcript skeleton
/** Placeholder for a speaker whose name the transcript does not reveal: a neutral display name (no name parts the gate could
 *  mistake for vocabulary); never in the leak list (metrics: roster.unnamed). */
export const placeholderName = (label) => `Participant ${String(label).replace(/\D+/g, '')}`;
export const transcriptId = (row) => `pub-${row.id.replace(/[^A-Za-z0-9_-]+/g, '-')}`;
export function toSkeleton(row, split) {
  const city = CITIES[cityOf(row.meeting)];
  const turns = mergeTurns(segments(row.transcript));
  const labels = [...new Set(turns.map((t) => t.label))];
  const idOf = (l) => `s${l.replace(/\D+/g, '')}`;
  const proposal = proposeRoster(turns);
  const roster = labels.map((l) => ({ id: idOf(l), label: l, name: placeholderName(l), unnamed: true, aliases: [], org: city.body, title: '' }));
  return {
    id: transcriptId(row), split, track: 'public', title: `${city.body} — agenda item ${row.item} (${row.date})`, sessionDate: row.date, lang: 'en',
    source: `meetingbank:${cityOf(row.meeting)}`, city: city.city, meetingUid: row.meeting, itemUid: row.item, kaggleId: row.id, kagglePart: row.kagglePart,
    publicContext: city.context,
    roster,
    lines: turns.map((t, i) => ({ speakerId: idOf(t.label), speakerName: roster.find((r) => r.label === t.label).name, text: t.text, ts: i * 60000 })),
    questions: [],
    gold: { ideas: [], identifiers: [], thirdParties: [], publicFacts: [], quotes: [], stances: [], injections: [], mosaic: [] },
    proposal,
    categories: [],
  };
}

// ---------------------------------------------------------------- selection
const h = (s) => createHash('sha256').update(s).digest('hex');
/**
 * Deterministic selection: per city, eligible items ordered by sha256(seed|id), ≤ 1 item per meeting (independent
 * transcripts), plus one 3-item mosaic circle per split (same Meeting_UID, the three items whose heuristic name
 * proposals overlap most). Items above maxWords are not drawn (budget), see METHOD §7.2.
 */
export function select(rows, { perCity = 8, maxWords = 2000, seed = 'emberbench-public-1', circleCities = { dev: ['LongBeachCC', 'DenverCityCouncil'], test: ['BostonCC', 'AlamedaCC', 'KingCountyCC'] } } = {}) {
  const pool = rows.map((r) => ({ r, p: profile(r), city: cityOf(r.meeting) })).filter((x) => CITIES[x.city] && eligible(x.p, { maxWords }));
  const picked = [];
  const circles = {};
  for (const [split, cityKeys] of Object.entries(circleCities)) {
    const byMeeting = new Map();
    for (const cityKey of cityKeys) {
    if (byMeeting.size && [...byMeeting.values()].some((v) => v.length >= 3)) break;
    for (const x of pool.filter((y) => y.city === cityKey)) { if (!byMeeting.has(x.r.meeting)) byMeeting.set(x.r.meeting, []); byMeeting.get(x.r.meeting).push(x); }
    }
    let best = null;
    for (const [m, xs] of [...byMeeting].sort((a, b) => (h(seed + a[0]) < h(seed + b[0]) ? -1 : 1))) {
      if (xs.length < 3) continue;
      const names = xs.map((x) => new Set(Object.values(proposeRoster(x.p.turnList)).filter(Boolean).map((v) => v.surname.toLowerCase())));
      // best triple by pairwise overlap of proposed names
      for (let a = 0; a < xs.length; a++) for (let b = a + 1; b < xs.length; b++) for (let c = b + 1; c < xs.length; c++) {
        const ov = (i, j) => [...names[i]].filter((n) => names[j].has(n)).length;
        const score = ov(a, b) + ov(a, c) + ov(b, c);
        if (!best || score > best.score) best = { meeting: m, score, items: [xs[a], xs[b], xs[c]].sort((u, v) => (u.r.item < v.r.item ? -1 : 1)) };
      }
    }
    if (best) { circles[split] = { meeting: best.meeting, overlap: best.score, items: best.items.map((x) => x.r.id) }; for (const [k, x] of best.items.entries()) picked.push({ ...x, split, circle: `circle-${best.meeting}`, session: k + 1 }); }
  }
  for (const [cityKey, c] of Object.entries(CITIES)) {
    const usedMeetings = new Set(picked.map((x) => x.r.meeting));
    const already = picked.filter((x) => x.city === cityKey).length;
    const cand = pool.filter((x) => x.city === cityKey && !usedMeetings.has(x.r.meeting)).sort((a, b) => (h(seed + a.r.id) < h(seed + b.r.id) ? -1 : 1));
    const seen = new Set();
    let n = perCity - already; // a circle city gets its 3-item circle plus perCity−3 singles
    for (const x of cand) { if (n <= 0) break; if (seen.has(x.r.meeting)) continue; seen.add(x.r.meeting); picked.push({ ...x, split: c.split }); n--; }
  }
  return { picked, circles, poolSizes: Object.fromEntries(Object.keys(CITIES).map((k) => [k, pool.filter((x) => x.city === k).length])) };
}

async function main() {
  const args = Object.fromEntries(process.argv.slice(2).map((a, i, xs) => (a.startsWith('--') ? [a.slice(2), xs[i + 1] && !xs[i + 1].startsWith('--') ? xs[i + 1] : true] : null)).filter(Boolean));
  const src = path.resolve(args.src || path.join(REPO, '.data', 'kaggle-meeting'));
  const out = path.resolve(args.out || path.join(PUBLIC_ROOT, 'raw'));
  const rows = loadRows(src);
  const sel = select(rows, { perCity: Number(args['per-city']) || 8, maxWords: Number(args['max-words']) || 2000, seed: args.seed || 'emberbench-public-1' });
  for (const x of sel.picked) {
    const t = toSkeleton(x.r, x.split);
    if (x.circle) { t.circle = x.circle; t.session = x.session; }
    mkdirSync(path.join(out, x.split), { recursive: true });
    writeFileSync(path.join(out, x.split, `${t.id}.json`), JSON.stringify(t, null, 2) + '\n');
  }
  const summary = { createdAt: new Date().toISOString(), rows: rows.length, poolSizes: sel.poolSizes, circles: sel.circles, picked: sel.picked.map((x) => ({ id: transcriptId(x.r), split: x.split, city: x.city, words: x.p.words, speakers: x.p.speakers, turns: x.p.turns, circle: x.circle || null })) };
  writeFileSync(path.join(out, 'selection.json'), JSON.stringify(summary, null, 2) + '\n');
  const by = (s) => summary.picked.filter((x) => x.split === s);
  console.log(JSON.stringify({ pool: sel.poolSizes, circles: sel.circles, dev: by('dev').length, test: by('test').length, words: { dev: by('dev').reduce((s, x) => s + x.words, 0), test: by('test').reduce((s, x) => s + x.words, 0) } }, null, 1));
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
