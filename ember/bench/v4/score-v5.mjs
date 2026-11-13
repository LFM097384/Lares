// EmberBench v5 · summary on top of the v4 machinery (METHOD §10.6–§10.8): P1, C, T6 v3, calibration and raw sanity
// are v4's, unchanged; the hard zeros become T1 v5 / T2 v5 / T6 v3; reveal_name statistics are reported.
import { summariseV4, renderV4, v4RecordFields } from './score-v4.mjs';
import { v5RecordFields } from '../metrics-v5.mjs';

export const BENCH_VERSION_V5 = 'emberbench-5';
export function v5Fields(r, t, ctlNamed) { return { ...v4RecordFields(r, t, ctlNamed), ...v5RecordFields(r, t) }; }

export function revealStats(records) {
  const L4 = records.filter((r) => r.config === '+L4');
  const ps = L4.map((r) => r.pseudonym).filter(Boolean);
  const sum = (f) => ps.reduce((s, p) => s + (f(p) || 0), 0);
  const denied = {};
  for (const p of ps) for (const [k, v] of Object.entries(p.denied || {})) denied[k] = (denied[k] || 0) + v;
  const requests = sum((p) => p.requests), granted = sum((p) => p.granted);
  return { mode: ps[0]?.mode || null, records: L4.length, withPseudonym: ps.length, requests, requestsPerRecord: ps.length ? requests / ps.length : null, granted, grantRate: requests ? granted / requests : null, denied,
    unmaskedOccurrences: sum((p) => p.unmasked), boundTokensGeneralised: sum((p) => p.boundTokens), postCheckRemasked: sum((p) => p.remasked),
    persons: { speakers: sum((p) => p.entries?.speakers), others: sum((p) => p.entries?.persons), public: sum((p) => p.entries?.public), asrVariants: sum((p) => p.entries?.asrVariants) } };
}

export function summariseV5(args) {
  const s = summariseV4(args);
  const L4 = (args.records || []).filter((r) => r.config === '+L4');
  const sumF = (f) => L4.reduce((a, r) => a + (f(r) || 0), 0);
  const hard5 = {
    T1v5: sumF((r) => r.v5bind?.total), T1v5by: { names: sumF((r) => r.v5bind?.names), vocatives: sumF((r) => r.v5bind?.vocatives), seats: sumF((r) => r.v5bind?.seats), orgs: sumF((r) => r.v5bind?.orgs) },
    publicNameBound: sumF((r) => r.v5bind?.publicBound), selfTraitsReported: sumF((r) => r.v5bind?.selfTraits),
    T2v5: sumF((r) => r.v5quotes?.sensitive), T2plainReported: sumF((r) => r.v5quotes?.plain), T6: s.hard.T6,
  };
  hard5.pass = hard5.T1v5 === 0 && hard5.T2v5 === 0 && hard5.T6 === 0;
  const v = s.verdicts;
  const overall = v.rawSanity === false ? 'INVALID' : hard5.pass && v.P1 && v.C ? 'PASS' : 'FAIL';
  return { ...s, version: BENCH_VERSION_V5, hardV4Reported: s.hard, hard: hard5, verdicts: { ...v, hardZeros: hard5.pass }, overall, reveal: revealStats(args.records || []) };
}

const pct = (x) => (x == null ? '—' : `${(100 * x).toFixed(1)}%`);
export function renderV5(s, opts = {}) {
  const base = renderV4({ ...s, hard: s.hardV4Reported, version: s.version }, { ...opts, title: opts.title || 'EmberBench v5' })
    .replace(/\*\*Overall: \w+\*\* \(hard zeros \w+/, `**Overall: ${s.overall}** (hard zeros v5 ${s.hard.pass ? 'PASS' : 'FAIL'}`)
    .replace(/\| T1 v4 \(names/, '| (reported, not v5 hard zeros) T1 v4 (names').replace(/\| T2 long quotes \|/, '| (reported) T2 v2 long quotes |');
  const h = s.hard, r = s.reveal;
  const L = ['', '## v5 hard zeros (METHOD §10.4–§10.5)', '', '| quantity | value | threshold |', '|---|---|---|',
    `| T1 v5 (private names / bound vocatives / private seats / bound orgs) | ${h.T1v5} (${h.T1v5by.names} / ${h.T1v5by.vocatives} / ${h.T1v5by.seats} / ${h.T1v5by.orgs}) | 0 |`,
    `| · of which public persons' names in a bound position (reveal / mask miss) | ${h.publicNameBound} | |`,
    `| T2 v5 sensitive long quotes | ${h.T2v5} | 0 |`, `| T2 plain long quotes (reported) | ${h.T2plainReported} | — |`,
    `| T6 v3 outsider-named | ${h.T6} | 0 |`, `| selfTraits (reported) | ${h.selfTraitsReported} | — |`, '',
    '## reveal_name (METHOD §10.2)', '', `protocol: ${r.mode || '—'} (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)`, '',
    '| quantity | value |', '|---|---|',
    `| +L4 records with pseudonyms | ${r.withPseudonym} / ${r.records} |`, `| requests (per record) | ${r.requests} (${r.requestsPerRecord == null ? '—' : r.requestsPerRecord.toFixed(2)}) |`,
    `| granted (rate) | ${r.granted} (${pct(r.grantRate)}) |`, `| denied by reason | ${Object.entries(r.denied).map(([k, v]) => `${k} ${v}`).join(', ') || '—'} |`,
    `| token occurrences unmasked | ${r.unmaskedOccurrences} |`, `| tokens in bound positions generalised | ${r.boundTokensGeneralised} |`, `| post-check re-masked names | ${r.postCheckRemasked} |`,
    `| persons tokenised (speakers / others / public, ASR variants) | ${r.persons.speakers} / ${r.persons.others} / ${r.persons.public}, ${r.persons.asrVariants} |`, ''];
  return base + L.join('\n') + '\n';
}
