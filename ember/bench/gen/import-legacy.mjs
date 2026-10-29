#!/usr/bin/env node
// EmberBench · map the 10 legacy transcripts (ember/eval/data) into the bench schema and freeze them under
// ember/bench/data/<split>/legacy-<id>.json. Mapping is mechanical (no LLM):
//   identifiers owner=third, kind=name  → thirdParties {public:false}   (all legacy third-party names are private people)
//   other third-owned identifiers        → kept as identifiers (phones, id cards… of private third parties)
//   toneMarkers[].stance                 → stances
//   selfAuthor                           → identifiers kind "work"
//   ideas                                → ideas (+ keywords: none; deterministic recall falls back to bigram overlap)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LEGACY_SPLIT } from './specs.mjs';
import { validate } from './validate.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.resolve(HERE, '..', '..', 'eval', 'data');
const DST = path.resolve(HERE, '..', 'data');

export function mapLegacy(t, split) {
  const g = t.gold || {};
  const ids = g.identifiers || [];
  const out = {
    id: `legacy-${t.id}`, split, title: t.title, sessionDate: t.sessionDate, lang: t.lang, source: `ember/eval/data/${t.id}.json`,
    roster: t.roster,
    lines: t.lines.map((l) => ({ speakerId: l.speakerId, speakerName: l.speakerName, text: l.text, ts: l.ts })),
    questions: [],
    gold: {
      ideas: (g.ideas || []).map((x) => ({ id: x.id, text: x.text, owner: x.owner, keywords: [] })),
      identifiers: ids.filter((x) => !(x.owner === 'third' && x.kind === 'name')).map((x) => ({ text: x.text, kind: x.kind, owner: x.owner, ...(x.fuzzy ? { fuzzy: x.fuzzy } : {}) }))
        .concat((g.selfAuthor || []).map((x) => ({ text: x.work, kind: 'work', owner: x.owner, ...(x.fuzzy ? { fuzzy: [].concat(x.fuzzy).filter((f) => typeof f === 'string') } : {}) }))),
      thirdParties: ids.filter((x) => x.owner === 'third' && x.kind === 'name').map((x) => ({ name: x.text, variants: x.fuzzy || [], public: false })),
      publicFacts: (g.publicFacts || []).map((x) => ({ id: x.id, text: x.text, keep: x.keep })),
      quotes: [],
      stances: (g.toneMarkers || []).filter((x) => x.stance?.direction).map((x) => ({ id: x.id, owner: x.owner, target: x.target, direction: x.stance.direction, strength: x.stance.strength ?? 1 })),
      injections: [],
      mosaic: [],
    },
  };
  // categories = what the mapped gold actually exercises
  const G = out.gold, kinds = (k) => G.identifiers.filter((x) => x.kind === k).length;
  out.categories = [
    kinds('org') && 'self_org', kinds('quasi') >= 2 && 'indirect',
    G.identifiers.filter((x) => x.kind === 'name' && x.owner !== 'third').length >= 2 && 'name_variants',
    G.thirdParties.length && 'third_party_private', G.publicFacts.length >= 2 && 'public_facts', kinds('style') && 'quotes_dialect',
  ].filter(Boolean);
  return out;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  for (const [id, split] of Object.entries(LEGACY_SPLIT)) {
    const t = JSON.parse(readFileSync(path.join(SRC, `${id}.json`), 'utf8'));
    const m = mapLegacy(t, split);
    const v = validate(m);
    mkdirSync(path.join(DST, split), { recursive: true });
    writeFileSync(path.join(DST, split, `${m.id}.json`), JSON.stringify(m, null, 2) + '\n');
    console.log(`${m.id} → ${split}  ok=${v.ok} ${v.errors.slice(0, 3).join(' | ')}`);
  }
}
