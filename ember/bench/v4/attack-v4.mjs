// EmberBench v4 · LLM calls: stranger distribution attacker, claim → speaker aligner, memorisation probe (METHOD §9.2, §9.7).
// Every function has a deterministic mock path (llm.provider === 'mock') so the pipeline runs offline.
import { askJSON } from '../providers.mjs';
import { normaliseDist, parseDistributions, bigramSpeaker } from './estimator.mjs';

const isMock = (llm) => !llm || llm.provider === 'mock';
/** Public roster as a stranger sees it (§9.1): id, name (or unnamed), public title / body. No evidence fields. */
export function strangerRoster(roster) {
  return roster.map((r) => ({ id: r.id, name: r.unnamed ? 'unnamed participant' : r.name, ...(r.aliases?.length && !r.unnamed ? { aliases: r.aliases } : {}), ...(r.title ? { title: r.title } : {}), ...(r.org ? { org: r.org } : {}) }));
}

const DIST_SYSTEM = `You are a de-anonymisation attacker: a STRANGER who knows only the public roster of a public city-council meeting (below: each attendee's id, public name or "unnamed participant", public title and body) plus public knowledge about the named officials (their districts, committees, known positions). You have NOT seen any transcript or video. For EACH numbered claim, give a probability distribution over the roster ids for who said it (who is the source of the content). Be calibrated: spread probability when unsure, concentrate it only when the text really points to one person. Use every clue: names, titles, seats / districts, roles in the meeting (chairing, moving, presenting staff report, public comment), expertise, stances, wording. Respond only with JSON: {"claims":[{"id":"c1","p":{"<rosterId>":0.6,"<rosterId>":0.3, ...}}, ...]} — one entry per claim, probabilities over roster ids, omitted ids mean 0.`;
const DIST_USER_NOTE = { release: 'RELEASED is the published anonymised minutes; CLAIMS are its bullet points.', raw: 'RELEASED is a speaker-labelled record of the meeting; CLAIMS are ideas expressed in it.', 'ideas-only': 'You have no record of the meeting, only the list of ideas (CLAIMS) that were expressed in it; guess from role fit.' };

/**
 * One distribution per claim. claims: [{id, text}] (ids opaque); released: string|null. Calls are chunked (≤ 40 claims) but every
 * call sees the whole released text. → { dists: Map id → {p:number[], ok}, failed: n }
 */
export async function attackDistributions(llm, { roster, released = null, claims, mode = 'release', seed = 1, chunk = 40 }) {
  const dists = new Map();
  let failed = 0;
  if (!claims.length) return { dists, failed };
  if (isMock(llm)) {
    // mock: weight each roster member by name-token / bigram hits of the claim against the released text attributed to them
    // raw: speaker-labelled lines "Name: text" → the speaker of the best bigram-matching line gets the weight
    const lab = mode === 'raw' && released ? String(released).split('\n').map((l) => { const m = l.match(/^([^:]{1,80}):\s*(.*)$/); const r = m && roster.find((x) => x.name === m[1]); return r ? { speakerId: r.id, text: m[2] } : null; }).filter(Boolean) : [];
    for (const c of claims) {
      const hit = lab.length ? bigramSpeaker(c.text, lab) : null;
      const w = roster.map((r) => { const toks = [r.name, ...(r.aliases || [])].filter((x) => x && !r.unnamed).map((x) => x.toLowerCase()); return 1 + toks.filter((t) => c.text.toLowerCase().includes(t)).length * 5 + (hit === r.id ? 20 : 0); });
      dists.set(c.id, normaliseDist(Object.fromEntries(roster.map((r, i) => [r.id, w[i]])), roster));
    }
    return { dists, failed };
  }
  const ros = strangerRoster(roster);
  for (let s = 0; s < claims.length; s += chunk) {
    const part = claims.slice(s, s + chunk);
    const user = { note: `${DIST_USER_NOTE[mode] || ''} attempt ${seed}`, roster: ros, ...(released != null ? { released: String(released).slice(0, 24000) } : {}), claims: part.map((c) => ({ id: c.id, text: c.text })) };
    let m = new Map();
    try { m = parseDistributions(await askJSON(llm, DIST_SYSTEM, JSON.stringify(user), { temperature: 0.2, maxTokens: 6000 })); } catch { m = new Map(); }
    for (const c of part) { const d = normaliseDist(m.get(c.id), roster); if (!d.ok) failed++; dists.set(c.id, d); }
  }
  return { dists, failed };
}

const ALIGN_SYSTEM = `You align the bullet points of anonymised meeting minutes back to the transcript they were written from. Given the numbered transcript lines (each with its speaker id) and the numbered claims, return for each claim the transcript line numbers whose content it reports, and "primary": the speaker id who contributed most of the claim's content. Use "none" for primary when the claim is a generic procedural or summary statement that cannot be traced to any particular speaker. Respond only with JSON: {"claims":[{"id":"c1","lines":[3,4],"primary":"s2"}, ...]}`;
/** → Map claimId → { primary: speakerId|null, sources: speakerId[], lines: number[], det: speakerId|null } */
export async function alignClaims(llm, { lines, roster, claims, chunk = 40 }) {
  const ids = new Set(roster.map((r) => String(r.id)));
  const out = new Map();
  if (!claims.length) return out;
  if (isMock(llm)) {
    for (const c of claims) { const d = bigramSpeaker(c.text, lines); out.set(c.id, { primary: d, sources: d ? [d] : [], lines: [], det: d }); }
    return out;
  }
  const tl = lines.map((l, i) => `${i}. [${l.speakerId}] ${l.text}`).join('\n').slice(0, 40000);
  for (let s = 0; s < claims.length; s += chunk) {
    const part = claims.slice(s, s + chunk);
    let rows = [];
    try { const j = await askJSON(llm, ALIGN_SYSTEM, `TRANSCRIPT:\n${tl}\n\nCLAIMS:\n${part.map((c) => `${c.id}. ${c.text}`).join('\n')}`, { temperature: 0, maxTokens: 4000 }); rows = Array.isArray(j?.claims) ? j.claims : Array.isArray(j) ? j : []; } catch { rows = []; }
    const by = new Map(rows.map((r) => [String(r?.id ?? ''), r]));
    for (const c of part) {
      const r = by.get(c.id);
      const ln = (Array.isArray(r?.lines) ? r.lines : []).map(Number).filter((n) => Number.isInteger(n) && n >= 0 && n < lines.length);
      const sources = [...new Set(ln.map((n) => String(lines[n].speakerId)))].filter((x) => ids.has(x));
      let primary = r?.primary != null && ids.has(String(r.primary)) ? String(r.primary) : null;
      if (!primary && sources.length && String(r?.primary).toLowerCase() !== 'none') {
        const cnt = new Map(); for (const n of ln) cnt.set(String(lines[n].speakerId), (cnt.get(String(lines[n].speakerId)) || 0) + 1);
        const top = [...cnt].sort((a, b) => b[1] - a[1]); if (top.length === 1 || top[0][1] > top[1][1]) primary = top[0][0];
      }
      out.set(c.id, { primary, sources, lines: ln, det: bigramSpeaker(c.text, lines) });
    }
  }
  return out;
}

const PROBE_SYSTEM = `You are a STRANGER who knows only the public roster of a public city-council meeting (ids, public names, titles). You get short excerpts from that meeting with names, titles and district numbers masked as [X]. (1) For each excerpt give a probability distribution over the roster ids for who said it. (2) Say which meeting this is, if you can: city, year, month, and the agenda item / bill number; use null for anything you do not know — do not guess wildly. Respond only with JSON: {"excerpts":[{"id":"e1","p":{"<rosterId>":0.5, ...}}],"meeting":{"city":null,"year":null,"month":null,"item":null}}`;
export async function memorisationProbe(llm, { roster, excerpts }) {
  if (!excerpts.length) return { dists: new Map(), meeting: null, failed: 0 };
  if (isMock(llm)) return { dists: new Map(excerpts.map((e) => [e.id, normaliseDist(null, roster)])), meeting: { city: null, year: null, month: null, item: null }, failed: 0 };
  let j = null;
  try { j = await askJSON(llm, PROBE_SYSTEM, JSON.stringify({ roster: strangerRoster(roster), excerpts }), { temperature: 0.2, maxTokens: 3000 }); } catch { j = null; }
  const m = parseDistributions({ claims: j?.excerpts || [] });
  let failed = 0;
  const dists = new Map(excerpts.map((e) => { const d = normaliseDist(m.get(e.id), roster); if (!d.ok) failed++; return [e.id, d]; }));
  return { dists, meeting: j?.meeting && typeof j.meeting === 'object' ? j.meeting : null, failed };
}
