// EmberBench v5 · P13 post-hoc OFFLINE replay on the spent test-v5 outputs (METHOD P13). No network, no LLM.
// NOT a fresh confirmation and optimistic by construction: records hold only the FINAL release / memory text, so only the
// deterministic last step (P.finalize: re-mask + bound-position generalisation, with the P13 rules) can be re-applied to
// those outputs; the P13 changes that act BEFORE the model (masking of the LLM input, the sensitive-run check that forces a
// paraphrase) cannot be replayed — the model would have seen different text. Grants of the original run are re-applied
// (each granted display is granted again) so topic reveals survive as they did. Metric code is unchanged (metrics-v5.mjs).
//   node ember/bench/v5/replay-p13.mjs [--run <dir>] [--data <dir>] [--out <file.json>]
import fs from 'node:fs';
import path from 'node:path';
import { buildPseudonyms } from '../../core/gate/pseudonym.mjs';
import { expandPublicContext } from '../../core/gate/l2.mjs';
import { v5RecordFields } from '../metrics-v5.mjs';

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const RUN = arg('--run', '.data/emberbench-public/runs/2026-11-17T0037-public-test');
const DATA = arg('--data', '.data/emberbench-public/data/test-v5');
const OUT = arg('--out', null);
const REDACT = process.argv.includes('--redact');
const initials = (s) => String(s).replace(/\b([A-Z])[\p{L}'’-]+/gu, '$1.');

export function replayRecord(r, t) {
  const shared = expandPublicContext(t.publicContext || []);
  const P = buildPseudonyms({ roster: t.roster, lines: t.lines }, { seed: r.seed ?? 1, lang: t.lang || 'en', shared });
  // re-grant what the original adjudicator granted (by display name), via a neutral topic sentence
  const grants = new Set((r.pseudonym?.log || []).filter((x) => x.decision === 'granted' && x.display).map((x) => String(x.display)));
  P.adjudicate(P.entries.filter((e) => e.display && grants.has(e.display)).map((e) => ({ token: e.token, sentence: `The ${e.token} item was discussed.`, reason: 'replay of original grant' })));
  const fin = (txt) => String(txt ?? '').split('\n').map((l) => { const m = l.match(/^(\s*(?:#+|[-*]|\d+\.)\s+)(.*)$/); return m ? m[1] + P.finalize(m[2]) : P.finalize(l); }).join('\n');
  return { ...r, release: fin(r.release), memoryText: fin(r.memoryText) };
}

function main() {
  const recs = fs.readFileSync(path.join(RUN, 'records.jsonl'), 'utf8').split('\n').filter(Boolean).map(JSON.parse);
  const items = new Map();
  const T = (tid) => { if (!items.has(tid)) items.set(tid, JSON.parse(fs.readFileSync(path.join(DATA, `${tid}.json`), 'utf8'))); return items.get(tid); };
  const ctl = new Map(recs.filter((r) => r.config === 'ideas-only').map((r) => [`${r.tid}|${r.seed}`, r.outsiderControl?.named || r.outsider?.named || null]));
  const tot = (rs) => {
    const a = { records: 0, T1v5: 0, names: 0, vocatives: 0, seats: 0, orgs: 0, publicBound: 0, T2v5: 0, T6v5: 0 };
    for (const { r, f } of rs) { a.records++; a.T1v5 += f.v5bind.total; for (const k of ['names', 'vocatives', 'seats', 'orgs', 'publicBound']) a[k] += f.v5bind[k]; a.T2v5 += f.v5quotes.sensitive; a.T6v5 += f.v5out6; }
    return a;
  };
  const L4 = recs.filter((r) => r.config === '+L4');
  const before = L4.map((r) => ({ r, f: v5RecordFields(r, T(r.tid), ctl.get(`${r.tid}|${r.seed}`)) }));
  const after = L4.map((r) => { const rr = replayRecord(r, T(r.tid)); return { r: rr, f: v5RecordFields(rr, T(r.tid), ctl.get(`${r.tid}|${r.seed}`)) }; });
  const residual = after.flatMap(({ r, f }) => [...f.v5bind.items.map((x) => ({ tid: r.tid, seed: r.seed, metric: 'T1v5', cat: x.cat, rule: x.rule || '', text: REDACT ? initials(x.text) : x.text })), ...f.v5quotes.items.map((x) => ({ tid: r.tid, seed: r.seed, metric: 'T2v5', why: x.why, words: x.words })), ...(f.v5out6 ? [{ tid: r.tid, seed: r.seed, metric: 'T6v5', count: f.v5out6 }] : [])]);
  // how much outward text the replay changed (a crude utility proxy: characters changed)
  const changed = after.filter((x, i) => x.r.release !== L4[i].release || x.r.memoryText !== L4[i].memoryText).length;
  const res = { label: 'post-hoc offline replay on the spent test-v5 outputs, not a fresh confirmation, optimistic by construction', run: RUN, before: tot(before), after: tot(after), recordsChanged: changed, residual };
  if (OUT) fs.writeFileSync(OUT, JSON.stringify(res, null, 2));
  console.log(JSON.stringify({ ...res, residual: residual.length ? residual : [] }, null, 1));
}
if (import.meta.url === `file:///${process.argv[1].replace(/\\/g, '/')}` || process.argv[1]?.endsWith('replay-p13.mjs')) main();
