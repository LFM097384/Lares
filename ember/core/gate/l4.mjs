// L4: attribution attack + targeted generalisation loop (Gate v2: also a tone check).
import { chatJSON } from './llm.mjs';
import { hasToneMarker } from './l3.mjs';

export const ATTACKER_PROMPT = `You are a red-team re-identification analyst. You are given the public attendee list of a private meeting (id, name, organisation, title, and any published works / public name) and numbered claims from an anonymised digest of that meeting.
For EACH claim, guess which attendee most likely said it, using every available cue: role/expertise/organisation cues (who would know or care about this), self-revealing facts (career history, life events, responsibilities, ownership of a task), domain-insider framing, references to one's own team/budget/patients/sources/books, and stylistic cues (catchphrases, verbal tics, language mix).
PUBLIC WORLD FACTS ARE NOT CUES: a well-known book and its author, a public figure's public acts, a public institution's published policy or report, a law. Anyone may cite them. They become a cue ONLY if an attendee is that person / author (see "works" / "publicName" in the attendee list) or the claim says the speaker wrote / owns / works at it.
Be calibrated: confidence is your probability (0..1) that the guess is correct. Generic claims anyone could make should get guess null or a low confidence.
TONE: also set "tone": true for a claim if residual sarcasm, irony, backhanded praise, rhetorical questions, mock enthusiasm, idiolect, a catchphrase or dialect / 方言腔 remains in it (even if you cannot guess the speaker); otherwise false.
Output only JSON: {"results":[{"i":<claim number>,"guess":"<attendee id>"|null,"confidence":<0..1>,"reason":"<short cue>","tone":true|false}]}`;

export const GENERALISER_PROMPT = `You edit flagged lines of an anonymised meeting digest so that a reader who knows the attendee list cannot attribute them to anyone.
For each flagged claim you get the attacker's reason. Rewrite it to keep the underlying idea, numbers and decisions, but remove the cue: drop insider framing ("as the one running sales", "my team", "our patients"), ownership of tasks, role/organisation hints, life facts and stylistic tics. Use impersonal phrasing ("有观点认为……" / "It was argued that…"). Do not add names, roles or facts. Keep the claim's language.
Claims marked "tone" still carry sarcasm / irony / idiolect / dialect: rewrite them as a neutral propositional statement that preserves the stance DIRECTION (support / doubt / oppose) and STRENGTH (mild / clear / strong), e.g. 「真是好方案，再拍脑袋几次公司就上市了」→「有观点对该方案的决策依据表示明显怀疑」. Never quote or echo the sarcastic phrase. Use "oppose" wording (反对 / 认为……不合理、没有必要 / opposed, argued it is unnecessary) when the speaker rejects the target and "doubt" wording (质疑……能否 / doubted whether) only when they question it without rejecting it; do not inflate strength (a single ironic aside is mild or clear, not strong). Keep the stance together with its reasons, numbers and its concrete target.
Keep public world facts (well-known books and their authors, public figures' public acts, public institutions' policies, laws) verbatim — original language and exact form, no translation or expansion of the name — unless the cue says an attendee is that person.
If the idea cannot be kept without pointing to a person, return the text "DROP".
Output only JSON: {"rewrites":[{"i":<claim number>,"text":"..."}]}`;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function rosterTokens(roster = []) {
  const set = new Set();
  for (const p of roster) {
    for (const v of [p.name, ...(p.aliases || []), p.org, p.title, p.publicName, ...(p.works || [])]) {
      if (!v) continue;
      const s = String(v).trim();
      if (s.length >= 2) set.add(s);
      for (const part of s.split(/\s*[\/／,，、&]\s*|\s+(?:and|兼)\s+|兼/)) if (part.trim().length >= 2) set.add(part.trim());
      const inner = s.replace(/^《|》$/g, '');
      if (inner !== s && inner.length >= 2) set.add(inner);
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
    const hits = toks.filter((t) => tokenRe(t).test(c.text));
    if (!hits.length) continue;
    flagged.push({ i: c.i, guess: null, confidence: 1, reason: `roster token: ${hits.length} hit(s)`, tone: false });
    let t = c.text;
    for (const tok of hits) t = t.replace(tokenRe(tok), '');
    t = t.replace(/\s{2,}/g, ' ').replace(/([，,])\s*[，,]+/g, '$1').replace(/^[\s，,]+/, '').trim();
    c.text = t.replace(/[\s。.；;，,]/g, '') ? t : 'DROP';
  }
  return flagged;
}

// Returns { flagged: attribution hits >= threshold, tone: Set of claim numbers with residual tone }.
async function attackRound(llm, live, pub, { stats, threshold }) {
  const list = live.map((c) => `${c.i}. ${c.text}`).join('\n');
  const { data } = await chatJSON(llm, [{ role: 'system', content: ATTACKER_PROMPT },
    { role: 'user', content: `ATTENDEES:\n${JSON.stringify(pub)}\n\nCLAIMS:\n${list}` }], { stats, temperature: 0.2 });
  const ids = new Set(live.map((c) => c.i));
  const rows = (Array.isArray(data?.results) ? data.results : []).filter((r) => ids.has(Number(r?.i)));
  const tone = new Set(rows.filter((r) => r.tone === true || r.tone === 'true').map((r) => Number(r.i)));
  const flagged = rows
    .filter((r) => r.guess && Number(r.confidence) >= threshold)
    .map((r) => ({ i: Number(r.i), guess: String(r.guess), confidence: Number(r.confidence), reason: String(r.reason || '').slice(0, 200), tone: tone.has(Number(r.i)) }));
  return { flagged, tone };
}

const asClaim = (c) => (typeof c === 'string' ? { text: c } : { ...c });

// verify(sections, roster, { llm, stats, threshold, flagThreshold, maxRounds })
// sections: [{ topic, claims: [string | { text, kind?, flags? }] }]
// Returns sections whose claims are objects {text, kind?, flags[], risk?, confidence?, reason?, guess?}; kind/flags
// are carried through. After at most maxRounds attack→generalise rounds, one final attack pass measures residual
// risk; claims still attributable at >= max(threshold, flagThreshold) are NOT silently kept or dropped: they are
// marked risk:'role-revealing' (+flag 'role-revealing') for human k-of-n review. Claims whose tone is still
// flagged after the last round get flag 'tone-residual' and risk 'role-revealing' (tone itself identifies).
// `reason`/`guess` may name an attendee: review-only metadata, never exported.
export async function verify(sections, roster, { llm = null, stats, threshold = 0.5, flagThreshold = 0.7, maxRounds = 2 } = {}) {
  const flat = [];
  sections.forEach((s, si) => s.claims.forEach((c) => { const o = asClaim(c); flat.push({ ...o, i: flat.length + 1, si, flags: [...(o.flags || [])] }); }));
  const flaggedAll = [];
  let rounds = 0;
  const pub = (roster || []).map((p) => {
    const o = { id: p.id, name: p.name, org: p.org, title: p.title };
    if (p.works?.length) o.works = p.works;
    if (p.publicName) o.publicName = p.publicName;
    return o;
  });
  const toks = rosterTokens(roster);
  let residual = [], residualTone = new Set();
  for (; rounds < maxRounds; ) {
    const live = flat.filter((c) => c.text !== 'DROP');
    if (!live.length) break;
    rounds++;
    let flagged, toneSet = new Set();
    if (!llm) {
      flagged = mockVerifyRound(live, toks);
    } else {
      const byI = new Map(live.map((c) => [c.i, c]));
      const r = await attackRound(llm, live, pub, { stats, threshold });
      flagged = r.flagged; toneSet = r.tone;
      const toFix = new Map(flagged.map((f) => [f.i, f]));
      for (const i of toneSet) if (!toFix.has(i)) toFix.set(i, { i, guess: null, confidence: 0, reason: 'residual tone', tone: true });
      if (toFix.size) {
        const req = [...toFix.values()].map((f) => `${f.i}. ${byI.get(f.i).text}\n   cue: ${f.reason}${f.tone || toneSet.has(f.i) ? '\n   tone: true' : ''}`).join('\n');
        const { data: g } = await chatJSON(llm, [{ role: 'system', content: GENERALISER_PROMPT },
          { role: 'user', content: `FLAGGED CLAIMS:\n${req}` }], { stats, temperature: 0.3 });
        const rw = new Map((Array.isArray(g?.rewrites) ? g.rewrites : []).map((x) => [Number(x?.i), String(x?.text || '').trim()]));
        for (const f of toFix.values()) {
          const c = byI.get(f.i);
          const t = rw.get(f.i);
          if (flagged.some((x) => x.i === f.i)) c.text = t || 'DROP'; // attributable claim with no rewrite → fail closed
          else if (t) c.text = t; // tone-only: keep original if no rewrite came back (residual check will flag it)
          if (t && t !== 'DROP' && toneSet.has(f.i) && !c.flags.includes('tone-neutralised')) c.flags.push('tone-neutralised');
        }
        flagged = [...toFix.values()].filter((f) => flagged.some((x) => x.i === f.i) || toneSet.has(f.i));
      }
    }
    flaggedAll.push(...flagged.map((f) => ({ ...f, round: rounds })));
    if (!flagged.length) break;
    // Final residual-risk check after the last allowed rewrite round.
    if (rounds === maxRounds) {
      const live2 = flat.filter((c) => c.text !== 'DROP');
      if (!llm) {
        residual = live2.filter((c) => toks.some((t) => tokenRe(t).test(c.text))).map((c) => ({ i: c.i, guess: null, confidence: 1, reason: 'roster token' }));
        residualTone = new Set(live2.filter((c) => hasToneMarker(c.text)).map((c) => c.i));
      } else if (live2.length) {
        const r = await attackRound(llm, live2, pub, { stats, threshold: Math.max(threshold, flagThreshold) });
        residual = r.flagged; residualTone = r.tone;
      }
    }
  }
  // Mock path: tone markers that survived L3 (mock strips the known ones) are residual too.
  if (!llm) for (const c of flat) if (c.text !== 'DROP' && hasToneMarker(c.text)) residualTone.add(c.i);
  const risk = new Map(residual.map((r) => [r.i, r]));
  const out = sections.map((s) => ({ topic: s.topic, claims: [] }));
  let dropped = 0;
  for (const c of flat) {
    if (c.text === 'DROP' || !c.text) { dropped++; continue; }
    const { i, si, ...rest } = c;
    const claim = { ...rest, flags: [...rest.flags] };
    delete claim.risk; delete claim.confidence; delete claim.reason; delete claim.guess;
    const r = risk.get(i);
    const toneLeft = residualTone.has(i);
    if (toneLeft) {
      claim.flags = claim.flags.filter((f) => f !== 'tone-neutralised');
      claim.flags.push('tone-residual');
    }
    if (r || toneLeft) {
      claim.risk = 'role-revealing';
      if (!claim.flags.includes('role-revealing')) claim.flags.push('role-revealing');
      claim.confidence = r ? r.confidence : 0;
      claim.reason = r ? r.reason : 'residual tone';
      claim.guess = r ? r.guess : null;
    }
    out[si].claims.push(claim);
  }
  return { sections: out.filter((s) => s.claims.length), rounds, dropped, flagged: flaggedAll, residual: residual.length + [...residualTone].filter((i) => !risk.has(i)).length };
}
