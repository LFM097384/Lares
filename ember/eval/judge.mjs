// Chatham Gate eval — attribution attacker + idea-retention judge.
// Uses its OWN small LLM client (independent of lib/llm.mjs) so the judge cannot share bugs/prompts with the gate.
// Mock mode = deterministic offline heuristics (non-LLM numbers).

import { bigrams, bigramOverlap, normText, orgFragments, containsVariant, normaliseScore } from './metrics.mjs';

export const LLM_BASE_URL = (process.env.LARES_AI_LLM_BASE_URL || 'https://api.deepseek.com').replace(/\/+$/, '');
export const LLM_MODEL = process.env.LARES_AI_LLM_MODEL || 'deepseek-flash';
export const hasKey = () => Boolean(process.env.LARES_AI_LLM_KEY);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Minimal chat client returning parsed JSON. Never logs the key. */
export async function chatJSON(messages, { temperature = 0, maxTokens = 4096, retries = 3, timeoutMs = 120000 } = {}) {
  const key = process.env.LARES_AI_LLM_KEY;
  if (!key) throw new Error('LARES_AI_LLM_KEY not set');
  const scrub = (s) => String(s ?? '').split(key).join('***');
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt++) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      const res = await fetch(`${LLM_BASE_URL}/chat/completions`, {
        method: 'POST',
        signal: ctl.signal,
        headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
        body: JSON.stringify({
          model: LLM_MODEL,
          messages,
          temperature,
          max_tokens: maxTokens,
          thinking: { type: 'disabled' },
          response_format: { type: 'json_object' },
        }),
      });
      if (!res.ok) {
        const body = scrub((await res.text()).slice(0, 300));
        const err = new Error(`LLM HTTP ${res.status}: ${body}`);
        if (res.status >= 400 && res.status < 500 && res.status !== 429 && res.status !== 408) throw Object.assign(err, { fatal: true });
        throw err;
      }
      const data = await res.json();
      const content = data?.choices?.[0]?.message?.content ?? '';
      const parsed = parseJSONLoose(content);
      return { json: parsed, usage: data.usage || {} };
    } catch (e) {
      lastErr = e?.message?.includes(key) ? new Error(scrub(e.message)) : e;
      if (e.fatal) break;
      if (attempt < retries) await sleep(800 * 2 ** attempt + Math.floor(Math.random() * 300));
    } finally {
      clearTimeout(timer);
    }
  }
  throw lastErr;
}

export function parseJSONLoose(s) {
  const t = String(s).trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  try { return JSON.parse(t); } catch {}
  const a = t.indexOf('{'), b = t.lastIndexOf('}');
  if (a >= 0 && b > a) return JSON.parse(t.slice(a, b + 1));
  throw new Error('LLM returned non-JSON');
}

// ---------------------------------------------------------------- helpers
export function publicRoster(roster) {
  // works / publicName are what an insider knows about attendees (Gate v2 roster fields).
  return roster.map((r) => ({ id: r.id, name: r.name, aliases: r.aliases || [], org: r.org, title: r.title,
    ...(r.works?.length ? { works: r.works } : {}), ...(r.publicName ? { publicName: r.publicName } : {}) }));
}

/** Split digest into segments (lines/sentences), dropping empty and pure-heading markup. */
export function digestSegments(digest) {
  return String(digest || '')
    .split(/\n+|(?<=[。！？!?；;])|(?<=[.])\s+/)
    .map((s) => s.replace(/^\s*(#+|[-*•]|\d+[.)])\s*/, '').trim())
    .filter((s) => s.length > 1);
}

function bestSegment(text, segs) {
  let best = { seg: '', score: 0, idx: -1 };
  segs.forEach((seg, idx) => {
    const sc = bigramOverlap(text, seg);
    if (sc > best.score) best = { seg, score: sc, idx };
  });
  return best;
}

/** Identity tokens for one roster entry: name, aliases, org fragments, title. */
function identityTokens(p) {
  const toks = [];
  if (p.name) toks.push({ t: p.name, w: 3 });
  for (const a of p.aliases || []) toks.push({ t: a, w: 3 });
  if (p.org) { toks.push({ t: p.org, w: 2 }); for (const f of orgFragments(p.org)) toks.push({ t: f, w: 2 }); }
  if (p.title) toks.push({ t: p.title, w: 1 });
  return toks.filter((x) => normText(x.t).length >= 2);
}

function keywordOverlap(text, p) {
  const src = [p.org, p.title, ...orgFragments(p.org || '')].filter(Boolean).join(' ');
  const A = new Set(bigrams(text));
  const B = new Set(bigrams(src));
  let hit = 0;
  for (const g of B) if (A.has(g)) hit++;
  return hit;
}

// ---------------------------------------------------------------- attack
export function mockAttack(roster, digest, ideas) {
  const segs = digestSegments(digest);
  return ideas.map((idea) => {
    const best = bestSegment(idea.text, segs);
    const seg = best.seg;
    // window: best segment plus its neighbours (raw transcripts put the speaker name on the same line)
    let guess = null, how = 'keyword';
    if (seg) {
      let top = { id: null, s: 0 };
      for (const p of roster) {
        let s = 0;
        for (const { t, w } of identityTokens(p)) if (containsVariant(seg, t)) s += w;
        if (s > top.s) top = { id: p.id, s };
      }
      if (top.id) { guess = top.id; how = 'identity-token'; }
    }
    if (!guess) {
      let top = { id: roster[0]?.id ?? null, s: -1 };
      for (const p of roster) {
        const s = keywordOverlap(idea.text, p);
        if (s > top.s) top = { id: p.id, s };
      }
      guess = top.id;
    }
    return { ideaId: idea.id, rosterId: guess, confidence: how === 'identity-token' ? 0.9 : 0.3, how };
  });
}

const ATTACK_SYSTEM = 'You are a de-anonymisation attacker. You are given a public roster of meeting participants (id, name, aliases, and where available org and title; if org/title are missing, use world knowledge about the names) and an anonymised meeting digest. For each listed idea you must guess which roster id originally said it, using every clue available: names or aliases, organisational or role hints, domain expertise, verbal style, quasi-identifiers, and anything else in the digest. You must always guess a roster id (never "unknown"). Respond only with JSON.';

// Attacker knowledge levels:
//  'full'  — insider-equivalent: roster with names, aliases, orgs, titles (what attendees know).
//  'names' — names(+aliases) only, no org/title.
//  'none'  — outsider: no roster at all (true outward threat model). See llmOutsider().
export function rosterView(roster, knowledge = 'full') {
  const pub = publicRoster(roster);
  return knowledge === 'names' ? pub.map(({ id, name, aliases }) => ({ id, name, aliases })) : pub;
}

export function mockAttackNames(roster, digest, ideas) {
  return mockAttack(roster.map((r) => ({ id: r.id, name: r.name, aliases: r.aliases })), digest, ideas);
}

const OUTSIDER_SYSTEM = 'You are a de-anonymisation attacker who obtained an anonymised meeting digest but has NO attendee list. Using any clue in the text (names, nicknames, organisations, job titles, life details, writing style, world knowledge), (1) list every specific person and organisation you believe attended or is affiliated with an attendee, and (2) for each listed idea describe the most likely speaker as specifically as you can (a name if possible, else organisation + role). Never output generic descriptions like "a participant" as if they were names; give your best specific guess, or "unknown". Respond only with JSON.';

export async function llmOutsider(digest, ideas) {
  const user = {
    digest,
    ideas: ideas.map((i) => ({ id: i.id, text: i.text })),
    output_format: { attendees: [{ name: 'person name or unknown', org: 'organisation or unknown', title: 'role or unknown', confidence: 0.0 }], speakers: [{ ideaId: 'i1', name: 'unknown', org: 'unknown', title: 'unknown' }] },
  };
  const { json, usage } = await chatJSON([{ role: 'system', content: OUTSIDER_SYSTEM }, { role: 'user', content: JSON.stringify(user) }], { temperature: 0 });
  return { attendees: Array.isArray(json.attendees) ? json.attendees : [], speakers: Array.isArray(json.speakers) ? json.speakers : [], usage };
}

/** Mock outsider: anything in the digest that looks like a roster token is "named". */
export function mockOutsider(roster, digest) {
  const attendees = [];
  for (const p of roster) {
    for (const t of [p.name, ...(p.aliases || [])]) if (normText(t).length >= 2 && containsVariant(digest, t)) attendees.push({ name: t, org: 'unknown' });
    for (const f of orgFragments(p.org || '')) if (containsVariant(digest, f)) attendees.push({ name: 'unknown', org: f });
  }
  return { attendees, speakers: [] };
}

/**
 * Score outsider output against gold roster (exact/fuzzy).
 * A roster member is "exposed" if any guessed name matches their name/alias (either contains the other,
 * >=2 chars, or bigram overlap >= 0.6), or any guessed org matches an identifying fragment of their org.
 * Per idea: "speaker hit" if the speaker guess matches the true owner by name or org.
 */
export function scoreOutsider(roster, ideas, out) {
  const nameMatch = (g, p) => {
    const s = normText(g); if (!s || s === 'unknown' || s.length < 2) return false;
    return [p.name, ...(p.aliases || [])].some((a) => { const t = normText(a); return t.length >= 2 && (s.includes(t) || (t.includes(s) && s.length >= 3) || bigramOverlap(s, t) >= 0.6); });
  };
  const orgMatch = (g, p) => {
    const s = normText(g); if (!s || s === 'unknown' || s.length < 2) return false;
    return orgFragments(p.org || '').some((f) => s.includes(f) || (f.includes(s) && s.length >= 3)) || bigramOverlap(s, normText(p.org || '')) >= 0.6;
  };
  const namedPeople = new Set(), namedOrgs = new Set();
  const matched = [];
  for (const a of out.attendees || []) for (const p of roster) {
    if (nameMatch(a.name, p)) { namedPeople.add(p.id); matched.push({ id: p.id, via: 'name', guess: String(a.name) }); }
    if (orgMatch(a.org, p)) { namedOrgs.add(p.id); matched.push({ id: p.id, via: 'org', guess: String(a.org) }); }
  }
  const sp = new Map((out.speakers || []).map((s) => [String(s.ideaId), s]));
  let speakerHits = 0;
  for (const i of ideas) {
    const s = sp.get(i.id); const p = roster.find((r) => r.id === i.owner);
    if (s && p && (nameMatch(s.name, p) || orgMatch(s.org, p))) speakerHits++;
  }
  return { people: namedPeople.size, orgs: namedOrgs.size, exposed: new Set([...namedPeople, ...namedOrgs]).size, n: roster.length, speakerHits, ideas: ideas.length, matched };
}

export async function llmAttack(roster, digest, ideas, { sample = 0, knowledge = 'full' } = {}) {
  const user = {
    roster: rosterView(roster, knowledge),
    digest,
    ideas: ideas.map((i) => ({ id: i.id, text: i.text })),
    output_format: { guesses: [{ ideaId: 'i1', rosterId: 'p1', confidence: 0.0, reason: 'short' }] },
  };
  const msgs = [{ role: 'system', content: ATTACK_SYSTEM }, { role: 'user', content: JSON.stringify(user) }];
  // sample > 0: vary the order of ideas so a second sample is not byte-identical at temperature 0
  if (sample > 0) {
    user.ideas = [...user.ideas].reverse();
    msgs[1].content = JSON.stringify(user);
  }
  const { json, usage } = await chatJSON(msgs, { temperature: 0 });
  const ids = new Set(roster.map((r) => r.id));
  const got = new Map((json.guesses || []).map((g) => [String(g.ideaId), g]));
  const guesses = ideas.map((i) => {
    const g = got.get(i.id);
    const rid = g && ids.has(String(g.rosterId)) ? String(g.rosterId) : roster[0]?.id;
    return { ideaId: i.id, rosterId: rid, confidence: Number(g?.confidence ?? 0), reason: g?.reason ?? (g ? '' : 'missing → defaulted to first roster entry') };
  });
  return { guesses, usage };
}

// ---------------------------------------------------------------- tone / stance judge (Gate v2)
/** Mock: present & stance preserved iff the intended proposition overlaps the best digest segment >= 0.3. */
export function mockTone(digest, markers) {
  const segs = digestSegments(digest);
  return markers.map((m) => {
    const best = bestSegment(m.intended || '', segs);
    const present = best.score >= 0.3;
    return { id: m.id, present, residualTone: 'no', direction: present ? m.stance?.direction : 'absent', strength: present ? m.stance?.strength : null, overlap: Number(best.score.toFixed(3)) };
  });
}

const TONE_SYSTEM = [
  'You audit an anonymised meeting digest for residual speaking tone. For each probe you get the proposition a participant intended and its target.',
  'Step 1: find the digest claim(s) that express this proposition (paraphrase is fine; the digest may be in another language). If none, present=false.',
  'Step 2: residualTone = "yes" if those claim(s) still carry ANY of: sarcasm, irony, mock praise / backhanded compliments, rhetorical questions used as jabs, personal catchphrases or verbal tics, dialect or regional slang (e.g. Cantonese, Northeastern Mandarin), code-switching flourishes, or a distinctive idiolect / signature phrasing that could fingerprint the speaker. Neutral propositional wording ("a participant doubted X", "some argued X is too low") = "no". Quoting the content of the claim is not tone.',
  'Step 3: stance the DIGEST expresses toward the target: direction support|doubt|oppose (or "absent" if not present) and strength 1 (mild) .. 3 (strong). Judge only what the digest says, not what you guess the speaker felt.',
  'Definitions: oppose = the claim rejects or argues against the target (it is wrong, unnecessary, unfair, unworkable, too low/high, contradicted by evidence); doubt = the claim questions whether the target will work / is true, sceptical without rejecting it; support = endorses it. A claim that only states facts or reasons against the target counts as oppose (or doubt if it only raises a question). Strength: 1 mild, 2 clear, 3 strong/emphatic.',
  'Respond only with JSON.',
].join('\n');

export async function llmTone(digest, markers) {
  const user = {
    digest,
    probes: markers.map((m) => ({ id: m.id, target: m.target, intended: m.intended })),
    output_format: { results: [{ id: 't1', present: true, evidence: 'short quote or empty', residualTone: 'yes|no', toneType: 'sarcasm|dialect|catchphrase|...|none', direction: 'support|doubt|oppose|absent', strength: 2 }] },
  };
  const { json, usage } = await chatJSON([{ role: 'system', content: TONE_SYSTEM }, { role: 'user', content: JSON.stringify(user) }], { temperature: 0 });
  const got = new Map((json.results || []).map((r) => [String(r.id), r]));
  const results = markers.map((m) => {
    const r = got.get(String(m.id)) || {};
    const present = r.present === true || String(r.present).toLowerCase() === 'true';
    return { id: m.id, present, residualTone: present ? String(r.residualTone ?? 'no').toLowerCase() : 'no', toneType: r.toneType ?? null, direction: present ? String(r.direction ?? 'absent').toLowerCase() : 'absent', strength: Number(r.strength) || null, evidence: r.evidence ?? '' };
  });
  return { results, usage };
}

// ---------------------------------------------------------------- retention judge
export function mockRetention(digest, ideas) {
  const segs = digestSegments(digest);
  return ideas.map((idea) => {
    const best = bestSegment(idea.text, segs);
    const score = best.score >= 0.5 ? 1 : best.score >= 0.25 ? 0.5 : 0;
    return { ideaId: idea.id, score, label: ['absent', 'partial', 'present'][score * 2], overlap: Number(best.score.toFixed(3)) };
  });
}

const JUDGE_SYSTEM = 'You are a strict evaluator of meeting summaries. Given a digest and a list of key ideas, decide for each idea whether its substance is conveyed by the digest: "present" (the core claim is clearly there, paraphrase is fine), "partial" (only part of it, or it is vaguer / missing the key specific), or "absent". Judge meaning, not wording; the digest may be in a different language. Respond only with JSON.';

export async function llmRetention(digest, ideas) {
  const user = {
    digest,
    ideas: ideas.map((i) => ({ id: i.id, text: i.text })),
    output_format: { scores: [{ ideaId: 'i1', verdict: 'present|partial|absent', evidence: 'short quote or empty' }] },
  };
  const { json, usage } = await chatJSON(
    [{ role: 'system', content: JUDGE_SYSTEM }, { role: 'user', content: JSON.stringify(user) }],
    { temperature: 0 },
  );
  const got = new Map((json.scores || []).map((s) => [String(s.ideaId), s]));
  const map = { present: 1, partial: 0.5, absent: 0 };
  const scores = ideas.map((i) => {
    const s = got.get(i.id);
    const v = String(s?.verdict ?? 'absent').toLowerCase();
    const score = v in map ? map[v] : normaliseScore(s?.score);
    return { ideaId: i.id, score, label: v, evidence: s?.evidence ?? '' };
  });
  return { scores, usage };
}
