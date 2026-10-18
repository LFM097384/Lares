// L4: attribution attack + targeted generalisation loop.
import { chatJSON } from './llm.mjs';

export const ATTACKER_PROMPT = `You are a red-team re-identification analyst. You are given the public attendee list of a private meeting (id, name, organisation, title) and numbered claims from an anonymised digest of that meeting.
For EACH claim, guess which attendee most likely said it, using every available cue: role/expertise/organisation cues (who would know or care about this), self-revealing facts (career history, life events, responsibilities, ownership of a task), domain-insider framing, references to one's own team/budget/patients/sources, and stylistic cues (catchphrases, verbal tics, language mix).
Be calibrated: confidence is your probability (0..1) that the guess is correct. Generic claims anyone could make should get guess null or a low confidence.
Output only JSON: {"results":[{"i":<claim number>,"guess":"<attendee id>"|null,"confidence":<0..1>,"reason":"<short cue>"}]}`;

export const GENERALISER_PROMPT = `You edit flagged lines of an anonymised meeting digest so that a reader who knows the attendee list cannot attribute them to anyone.
For each flagged claim you get the attacker's reason. Rewrite it to keep the underlying idea, numbers and decisions, but remove the cue: drop insider framing ("as the one running sales", "my team", "our patients"), ownership of tasks, role/organisation hints, life facts and stylistic tics. Use impersonal phrasing ("有观点认为……" / "It was argued that…"). Do not add names, roles or facts. Keep the claim's language.
If the idea cannot be kept without pointing to a person, return the text "DROP".
Output only JSON: {"rewrites":[{"i":<claim number>,"text":"..."}]}`;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function rosterTokens(roster = []) {
  const set = new Set();
  for (const p of roster) {
    for (const v of [p.name, ...(p.aliases || []), p.org, p.title]) {
      if (!v) continue;
      const s = String(v).trim();
      if (s.length >= 2) set.add(s);
      for (const part of s.split(/\s*[\/／,，、&]\s*|\s+(?:and|兼)\s+|兼/)) if (part.trim().length >= 2) set.add(part.trim());
    }
  }
  return [...set].sort((a, b) => b.length - a.length);
}

function tokenRe(tok) {
  return /^[\x00-\x7f]+$/.test(tok) ? new RegExp(`\\b${esc(tok)}\\b`, 'gi') : new RegExp(esc(tok), 'g');
}

function mockVerifyRound(flat, toks) {
  const flagged = [];
  for (const c of flat) {
    const hits = toks.filter((t) => { const re = tokenRe(t); return re.test(c.text); });
    if (!hits.length) continue;
    flagged.push({ i: c.i, guess: null, confidence: 1, reason: `roster token: ${hits.length} hit(s)` });
    let t = c.text;
    for (const tok of hits) t = t.replace(tokenRe(tok), '');
    t = t.replace(/\s{2,}/g, ' ').replace(/([，,])\s*[，,]+/g, '$1').replace(/^[\s，,]+/, '').trim();
    c.text = t.replace(/[\s。.；;，,]/g, '') ? t : 'DROP';
  }
  return flagged;
}

async function attackRound(live, pub, { stats, threshold }) {
  const list = live.map((c) => `${c.i}. ${c.text}`).join('\n');
  const { data } = await chatJSON([{ role: 'system', content: ATTACKER_PROMPT },
    { role: 'user', content: `ATTENDEES:\n${JSON.stringify(pub)}\n\nCLAIMS:\n${list}` }], { stats, temperature: 0.2 });
  const ids = new Set(live.map((c) => c.i));
  return (Array.isArray(data?.results) ? data.results : [])
    .filter((r) => ids.has(Number(r.i)) && r.guess && Number(r.confidence) >= threshold)
    .map((r) => ({ i: Number(r.i), guess: String(r.guess), confidence: Number(r.confidence), reason: String(r.reason || '').slice(0, 200) }));
}

// Returns sections whose claims are objects {text, risk?, confidence?, reason?, guess?}.
// After at most maxRounds attack→generalise rounds, one final attack pass measures residual risk;
// claims still attributable at >= threshold are NOT silently kept or dropped: they are marked
// risk:'role-revealing' for the participants' human review (k-of-n release). `reason`/`guess`
// may name an attendee, so they are review-only metadata and must never be exported.
export async function verify(sections, roster, { mock, stats, threshold = 0.5, flagThreshold = 0.7, maxRounds = 2 } = {}) {
  const flat = [];
  sections.forEach((s, si) => s.claims.forEach((text) => flat.push({ i: flat.length + 1, si, text })));
  const flaggedAll = [];
  let rounds = 0;
  const pub = (roster || []).map((p) => ({ id: p.id, name: p.name, org: p.org, title: p.title }));
  const toks = rosterTokens(roster);
  let residual = [];
  for (; rounds < maxRounds; ) {
    const live = flat.filter((c) => c.text !== 'DROP');
    if (!live.length) break;
    rounds++;
    let flagged;
    if (mock) flagged = mockVerifyRound(live, toks);
    else {
      const byI = new Map(live.map((c) => [c.i, c]));
      flagged = await attackRound(live, pub, { stats, threshold });
      if (flagged.length) {
        const req = flagged.map((f) => `${f.i}. ${byI.get(f.i).text}\n   cue: ${f.reason}`).join('\n');
        const { data: g } = await chatJSON([{ role: 'system', content: GENERALISER_PROMPT },
          { role: 'user', content: `FLAGGED CLAIMS:\n${req}` }], { stats, temperature: 0.3 });
        const rw = new Map((Array.isArray(g?.rewrites) ? g.rewrites : []).map((r) => [Number(r.i), String(r.text || '').trim()]));
        // A flagged claim with no rewrite returned is dropped (fail closed).
        for (const f of flagged) byI.get(f.i).text = rw.get(f.i) || 'DROP';
      }
    }
    flaggedAll.push(...flagged.map((f) => ({ ...f, round: rounds })));
    if (!flagged.length) break;
    // Final residual-risk check after the last allowed rewrite round.
    if (rounds === maxRounds) {
      const live2 = flat.filter((c) => c.text !== 'DROP');
      residual = mock ? live2.filter((c) => toks.some((t) => tokenRe(t).test(c.text))).map((c) => ({ i: c.i, guess: null, confidence: 1, reason: 'roster token' }))
        : live2.length ? await attackRound(live2, pub, { stats, threshold: Math.max(threshold, flagThreshold) }) : [];
    }
  }
  const risk = new Map(residual.map((r) => [r.i, r]));
  const out = sections.map((s) => ({ topic: s.topic, claims: [] }));
  let dropped = 0;
  for (const c of flat) {
    if (c.text === 'DROP' || !c.text) { dropped++; continue; }
    const r = risk.get(c.i);
    out[c.si].claims.push(r ? { text: c.text, risk: 'role-revealing', confidence: r.confidence, reason: r.reason, guess: r.guess } : { text: c.text });
  }
  return { sections: out.filter((s) => s.claims.length), rounds, dropped, flagged: flaggedAll, residual: residual.length };
}
