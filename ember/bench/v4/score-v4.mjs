// EmberBench v4 · per-item v4 scoring (METHOD §9.2–§9.7) and summary. Used by run.mjs --schema v4 and rescore-v4.mjs.
import { createHash } from 'node:crypto';
import { extractClaims, calibrate, leakBits, hierBootstrap, meanOf, excessOf, ece, deName } from './estimator.mjs';
import { attackDistributions, alignClaims, memorisationProbe } from './attack-v4.mjs';
const rawRelease = (t) => t.lines.map((l) => `${l.speakerName}: ${l.text}`).join('\n');
import { bootstrapMean, bootstrapRatio } from '../bootstrap.mjs';
import { scoreV3, outsiderV3 } from '../metrics-v3.mjs';
import { fitTemperature } from './estimator.mjs';

export const BENCH_VERSION_V4 = 'emberbench-4';
export const P1_MAX = 0.25, C_MIN = 0.80, RAW_MIN_BITS = 1.0, UNATTR_FLAG = 0.30;
export const PROBE_HIT_FLAG = 0.20, PROBE_EXCESS_FLAG = 1.0;
const idsOf = (n, p = 'c') => Array.from({ length: n }, (_, k) => `${p}${k + 1}`);
const sha = (s) => createHash('sha256').update(s).digest('hex');

/** The v4 claim set of one (item, config, record). → [{id, text, truth, sources?}] (truth null = unattributable). */
export function claimSet(config, t, rec) {
  const ideas = t.gold.ideas.filter((i) => !i.disputed);
  if (config === 'raw' || config === 'ideas-only') return ideas.map((i, k) => ({ id: `c${k + 1}`, text: i.text, truth: String(i.owner), sources: [String(i.owner)] }));
  const texts = extractClaims(rec?.release || '');
  return texts.map((text, k) => ({ id: `c${k + 1}`, text, truth: undefined }));
}

/**
 * v4 LLM part for one record. attackers: [{name, llm}], aligner: llm. Returns the stored v4 block:
 * { claims:[{id,text,truth,sources,det}], dist:{[attacker]: {[claimId]: number[]}}, failed:{[attacker]:n} }
 */
export async function scoreV4Record(config, t, rec, { attackers, aligner, seed = 1 }) {
  const claims = claimSet(config, t, rec);
  if (config === '+L4' && claims.length) {
    const al = await alignClaims(aligner, { lines: t.lines, roster: t.roster, claims });
    for (const c of claims) { const a = al.get(c.id) || {}; c.truth = a.primary ?? null; c.sources = a.sources || []; c.det = a.det ?? null; }
  }
  const released = config === 'raw' ? rawRelease(t) : config === 'ideas-only' ? null : [rec?.release, rec?.memoryText].filter(Boolean).join('\n');
  const mode = config === 'raw' ? 'raw' : config === 'ideas-only' ? 'ideas-only' : 'release';
  const dist = {}, failed = {};
  await Promise.all(attackers.map(async ({ name, llm }) => {
    const r = await attackDistributions(llm, { roster: t.roster, released, claims, mode, seed });
    dist[name] = Object.fromEntries([...r.dists].map(([id, d]) => [id, d.p.map((x) => Math.round(x * 1e4) / 1e4)]));
    failed[name] = r.failed;
  }));
  return { claims, dist, failed };
}

/** Deterministic probe excerpts for an item (§9.7). */
export function probeExcerpts(t, { n = 6, minWords = 25 } = {}) {
  const names = t.roster.filter((r) => !r.unnamed).flatMap((r) => [r.name, ...(r.aliases || [])]).concat((t.gold.identifiers || []).filter((x) => x.kind === 'name').map((x) => x.text));
  const cand = t.lines.map((l, i) => ({ i, l })).filter((x) => String(x.l.text).split(/\s+/).length >= minWords)
    .sort((a, b) => sha(`emberbench-v4-probe${t.id}${a.i}`).localeCompare(sha(`emberbench-v4-probe${t.id}${b.i}`))).slice(0, n);
  return cand.map((x, k) => ({ id: `e${k + 1}`, text: deName(x.l.text, { names }).slice(0, 1200), truth: String(x.l.speakerId) }));
}
export async function runProbe(t, { attackers }) {
  const ex = probeExcerpts(t);
  const out = { excerpts: ex.map(({ id, truth }) => ({ id, truth })), dist: {}, meeting: {}, failed: {} };
  await Promise.all(attackers.map(async ({ name, llm }) => {
    const r = await memorisationProbe(llm, { roster: t.roster, excerpts: ex.map(({ id, text }) => ({ id, text })) });
    out.dist[name] = Object.fromEntries([...r.dists].map(([id, d]) => [id, d.p.map((x) => Math.round(x * 1e4) / 1e4)]));
    out.meeting[name] = r.meeting; out.failed[name] = r.failed;
  }));
  return out;
}
/** Probe meeting identification hit: year AND month right (sessionDate of the item). */
export function probeHit(meeting, t) {
  const d = String(t.sessionDate || '').match(/^(\d{4})-(\d{2})/);
  if (!meeting || !d) return false;
  return Number(meeting.year) === Number(d[1]) && Number(meeting.month) === Number(d[2]);
}

// ---------------------------------------------------------------- calibration

/** Calibration rows for one attacker from v4 blocks: [{p, t}] with t = index of the true roster id. */
export function calibRows(blocks, items, attacker, { configs = ['raw'], useAny = false } = {}) {
  const byId = new Map(items.map((t) => [t.id, t]));
  const rows = [];
  for (const b of blocks) {
    if (!configs.includes(b.config)) continue;
    const t = byId.get(b.tid); if (!t) continue;
    const ix = new Map(t.roster.map((r, i) => [String(r.id), i]));
    for (const c of b.v4.claims) {
      const p = b.v4.dist?.[attacker]?.[c.id]; if (!p || c.truth == null || !ix.has(c.truth)) continue;
      rows.push({ p, t: ix.get(c.truth), ...(useAny ? { any: (c.sources || []).map((s) => ix.get(s)).filter((x) => x != null) } : {}) });
    }
  }
  return rows;
}
export function eceReport(rows, tau) { return { before: ece(rows.map((r) => ({ p: r.p, t: r.t }))), after: ece(rows.map((r) => ({ p: calibrate(r.p, tau), t: r.t }))) }; }

// ---------------------------------------------------------------- bits

/** Per-claim bits for one block under one attacker (calibrated). any=true → max p over the claim's source set. */
export function claimBits(b, t, attacker, tau, { any = false } = {}) {
  const ix = new Map(t.roster.map((r, i) => [String(r.id), i]));
  const k = t.roster.length;
  const out = [];
  for (const c of b.v4.claims) {
    const raw = b.v4.dist?.[attacker]?.[c.id];
    if (!raw) continue;
    if (c.truth == null) { out.push({ id: c.id, bits: null, truth: null }); continue; }
    const p = calibrate(raw, tau);
    const set = any ? [...new Set([c.truth, ...(c.sources || [])])] : [c.truth];
    const pt = Math.max(...set.map((s) => (ix.has(s) ? p[ix.get(s)] : 0)));
    out.push({ id: c.id, bits: leakBits(pt, k), truth: c.truth });
  }
  return out;
}

/**
 * Bootstrap units from v4 blocks: one per item; cells[config][attacker] = bits of every attributable claim pooled over runs
 * (the same claim order for every attacker). unattributable: 'exclude' | 'zero'.
 */
export function buildUnits(blocks, items, attackers, calib, { configs = ['raw', 'ideas-only', '+L4'], unattributable = 'exclude', any = false } = {}) {
  const byId = new Map(items.map((t) => [t.id, t]));
  const units = new Map();
  for (const b of blocks) {
    if (!configs.includes(b.config)) continue;
    const t = byId.get(b.tid); if (!t) continue;
    if (!units.has(b.tid)) units.set(b.tid, { meeting: t.meetingUid || t.id, item: t.id, cells: {}, stats: {} });
    const u = units.get(b.tid);
    const cell = (u.cells[b.config] ||= attackers.map(() => []));
    const per = attackers.map((a) => claimBits(b, t, a, calib[a]?.tau ?? 1, { any }));
    // align: only claims scored by every attacker
    const common = per[0].map((x) => x.id).filter((id) => per.every((arr) => arr.some((y) => y.id === id)));
    for (const id of common) {
      const vals = per.map((arr) => arr.find((y) => y.id === id).bits);
      if (vals[0] == null) { if (unattributable === 'zero') vals.forEach((_, a) => cell[a].push(0)); continue; }
      vals.forEach((v, a) => cell[a].push(v));
    }
    const st = (u.stats[b.config] ||= { claims: 0, unattributable: 0 });
    st.claims += b.v4.claims.length; st.unattributable += b.v4.claims.filter((c) => c.truth == null).length;
  }
  return [...units.values()];
}

/** Bits per speaker: sum of a speaker's claim bits per run, averaged over runs, then mean over speakers (§9.2). */
export function bitsPerSpeaker(blocks, items, attackers, calib, config) {
  const byId = new Map(items.map((t) => [t.id, t]));
  const per = []; // per (item, speaker) mean-over-runs of max-over-attackers of sum
  const acc = new Map();
  for (const b of blocks.filter((x) => x.config === config)) {
    const t = byId.get(b.tid); if (!t) continue;
    const sums = attackers.map((a) => { const m = new Map(); for (const c of claimBits(b, t, a, calib[a]?.tau ?? 1)) if (c.bits != null) m.set(c.truth, (m.get(c.truth) || 0) + c.bits); return m; });
    for (const r of t.roster) {
      const v = Math.max(...sums.map((m) => m.get(String(r.id)) || 0));
      const key = `${t.id}|${r.id}`; if (!acc.has(key)) acc.set(key, []); acc.get(key).push(v);
    }
  }
  for (const [, vs] of acc) per.push(vs.reduce((s, x) => s + x, 0) / vs.length);
  return bootstrapMean(per, { seed: 12345 });
}

/** Full v4 summary over blocks (+ v2/v3 records for C and the hard zeros). */
export function summariseV4({ blocks, records, items, attackers, calib, probes = [] }) {
  const units = buildUnits(blocks, items, attackers, calib);
  const configs = ['raw', 'ideas-only', '+L4'].filter((c) => blocks.some((b) => b.config === c));
  const abs = Object.fromEntries(configs.map((c) => [c, hierBootstrap(units.filter((u) => u.cells[c]), meanOf(c))]));
  const perAtt = Object.fromEntries(attackers.map((a, ai) => [a, Object.fromEntries(configs.map((c) => [c, hierBootstrap(units.filter((u) => u.cells[c]).map((u) => ({ ...u, cells: { [c]: [u.cells[c][ai]] } })), meanOf(c))]))]));
  const pair = units.filter((u) => u.cells['+L4'] && u.cells['ideas-only']);
  const P1 = configs.includes('+L4') ? hierBootstrap(pair, excessOf('+L4', 'ideas-only')) : null;
  const P1zero = configs.includes('+L4') ? hierBootstrap(buildUnits(blocks, items, attackers, calib, { unattributable: 'zero' }).filter((u) => u.cells['+L4'] && u.cells['ideas-only']), excessOf('+L4', 'ideas-only')) : null;
  const P1any = configs.includes('+L4') ? hierBootstrap(buildUnits(blocks, items, attackers, calib, { any: true }).filter((u) => u.cells['+L4'] && u.cells['ideas-only']), excessOf('+L4', 'ideas-only')) : null;
  const rawExcess = configs.includes('raw') ? hierBootstrap(units.filter((u) => u.cells.raw && u.cells['ideas-only']), excessOf('raw', 'ideas-only')) : null;
  const speaker = Object.fromEntries(configs.map((c) => [c, bitsPerSpeaker(blocks, items, attackers, calib, c)]));
  const l4b = blocks.filter((b) => b.config === '+L4');
  const nClaims = l4b.reduce((s, b) => s + b.v4.claims.length, 0), nUn = l4b.reduce((s, b) => s + b.v4.claims.filter((c) => c.truth == null).length, 0);
  const detAgree = l4b.flatMap((b) => b.v4.claims.filter((c) => c.truth != null && c.det != null)).reduce((a, c) => [a[0] + (c.truth === c.det ? 1 : 0), a[1] + 1], [0, 0]);
  const unattrByItem = Object.fromEntries(units.filter((u) => u.stats['+L4']).map((u) => [u.item, u.stats['+L4'].claims ? u.stats['+L4'].unattributable / u.stats['+L4'].claims : null]));
  const failed = Object.fromEntries(attackers.map((a) => [a, blocks.reduce((s, b) => s + (b.v4.failed?.[a] || 0), 0)]));
  // content composite & hard zeros from the v2/v3 record fields of +L4
  const L4 = (records || []).filter((r) => r.config === '+L4');
  const perItem = (f) => { const m = new Map(); for (const r of L4) { const v = f(r); if (v == null || !Number.isFinite(v)) continue; if (!m.has(r.tid)) m.set(r.tid, []); m.get(r.tid).push(v); } return [...m.values()].map((vs) => vs.reduce((s, x) => s + x, 0) / vs.length); };
  const byId = new Map(items.map((t) => [t.id, t]));
  const T8 = bootstrapMean(perItem((r) => r.retention), { seed: 12345 });
  const T11 = bootstrapMean(perItem((r) => r.qa?.mean), { seed: 12345 });
  const t9pairs = (() => { const m = new Map(); for (const r of L4) { const t = byId.get(r.tid); if (!t || !r.v3facts) continue; const p = m.get(r.tid) || [0, 0]; p[0] += r.v3facts.kept; p[1] += r.v3facts.total; m.set(r.tid, p); } return [...m.values()].filter((p) => p[1] > 0); })();
  const T9 = bootstrapRatio(t9pairs, { seed: 12345 });
  const comps = [T8.mean, T9.mean, T11.mean];
  const C = comps.every((x) => x != null) ? comps.reduce((s, x) => s + x, 0) / 3 : null;
  const sumF = (f) => L4.reduce((s, r) => s + (f(r) || 0), 0);
  const hard = { T1v4: sumF((r) => r.v4bind?.total), T1v4by: { names: sumF((r) => r.v4bind?.names), roles: sumF((r) => r.v4bind?.roles), orgs: sumF((r) => r.v4bind?.orgs) }, selfTraitsReported: sumF((r) => r.v4bind?.selfTraits), T2: sumF((r) => r.leaks?.quotes), T6: sumF((r) => r.v4out6) };
  hard.pass = hard.T1v4 === 0 && hard.T2 === 0 && hard.T6 === 0;
  // memorisation probe
  let probe = null;
  if (probes.length) {
    const pu = probes.map((pr) => { const t = byId.get(pr.tid); const ix = new Map(t.roster.map((r, i) => [String(r.id), i])); const cells = { probe: attackers.map((a) => pr.excerpts.map((e) => leakBits(calibrate(pr.dist[a]?.[e.id] || t.roster.map(() => 1 / t.roster.length), calib[a]?.tau ?? 1)[ix.get(e.truth)] ?? 0, t.roster.length))) }; const io = units.find((u) => u.item === pr.tid); if (io?.cells['ideas-only']) cells['ideas-only'] = io.cells['ideas-only']; return { meeting: t.meetingUid || t.id, item: t.id, cells }; });
    const hits = probes.map((pr) => attackers.some((a) => probeHit(pr.meeting?.[a], byId.get(pr.tid))));
    const hitRate = hits.filter(Boolean).length / (hits.length || 1);
    const ex = hierBootstrap(pu.filter((u) => u.cells['ideas-only']), excessOf('probe', 'ideas-only'));
    probe = { bits: hierBootstrap(pu, meanOf('probe')), excessOverIdeasOnly: ex, meetingHitRate: hitRate, hitsPerAttacker: Object.fromEntries(attackers.map((a) => [a, probes.filter((pr) => probeHit(pr.meeting?.[a], byId.get(pr.tid))).length])), items: probes.length };
    probe.flag = hitRate >= PROBE_HIT_FLAG || (ex.lo != null && ex.lo > PROBE_EXCESS_FLAG);
  }
  const rawOk = abs.raw ? abs.raw.mean != null && abs.raw.mean >= RAW_MIN_BITS : null;
  const p1pass = P1 ? P1.hi != null && P1.hi <= P1_MAX : null;
  const cpass = C != null ? C >= C_MIN : null;
  const overall = rawOk === false ? 'INVALID' : hard.pass && p1pass && cpass ? 'PASS' : 'FAIL';
  return { version: BENCH_VERSION_V4, attackers, calib, abs, perAttacker: perAtt, P1, P1sensitivity: { unattributableAsZero: P1zero, anySource: P1any }, rawExcess, bitsPerSpeaker: speaker, attribution: { claims: nClaims, unattributable: nUn, rate: nClaims ? nUn / nClaims : null, flag: nClaims ? nUn / nClaims > UNATTR_FLAG : null, detAgreement: detAgree[1] ? detAgree[0] / detAgree[1] : null, byItem: unattrByItem }, parseFailures: failed, content: { C, T8, T9, T11, pass: cpass }, hard, probe, verdicts: { rawSanity: rawOk, hardZeros: hard.pass, P1: p1pass, C: cpass }, overall };
}

/** v3 metric fields needed by v4 (hard zeros without selfTraits, T9 v3 no appendix, T6 v3) for one stored +L4 record. */
export function v4RecordFields(r, t, ctlNamed) {
  const channels = { release: r.release || '', memory: r.memoryText || '' };
  const s = scoreV3(channels, t);
  const outward = [channels.release, channels.memory].filter(Boolean).join('\n');
  const o = outsiderV3(r.outsider?.named || [], outward, t, ctlNamed || null);
  return { v4bind: { names: s.bind.names, roles: s.bind.roles, orgs: s.bind.orgs, selfTraits: s.bind.selfTraits, total: s.bind.names + s.bind.roles + s.bind.orgs }, v3facts: s.factsV3NoAppendix, v4out6: o.count };
}

const f2 = (x) => (x == null ? '—' : x.toFixed(2));
export const ci = (c) => (c?.mean == null ? '—' : `${f2(c.mean)} [${f2(c.lo)}, ${f2(c.hi)}]`);
export function renderV4(s, { title = 'EmberBench v4', meta = {} } = {}) {
  const L = [`# ${title}`, '', `version ${s.version} · attackers ${s.attackers.join(', ')} · calibration τ ${s.attackers.map((a) => `${a}=${s.calib[a]?.tau?.toFixed(3)}`).join(', ')}`, ...(meta.lines || []), '',
    `**Overall: ${s.overall}** (hard zeros ${s.verdicts.hardZeros ? 'PASS' : 'FAIL'} · P1 ${s.verdicts.P1 == null ? '—' : s.verdicts.P1 ? 'PASS' : 'FAIL'} · C ${s.verdicts.C == null ? '—' : s.verdicts.C ? 'PASS' : 'FAIL'} · raw sanity ${s.verdicts.rawSanity == null ? '—' : s.verdicts.rawSanity ? 'ok' : 'INVALID'})`, '',
    '| quantity | value [95% CI] | threshold |', '|---|---|---|',
    `| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | ${ci(s.P1)} | CI upper ≤ ${P1_MAX} |`,
    `| P1, unattributable claims counted as 0 bits | ${ci(s.P1sensitivity.unattributableAsZero)} | (sensitivity) |`,
    `| P1, any-source truth | ${ci(s.P1sensitivity.anySource)} | (sensitivity) |`,
    ...Object.entries(s.abs).map(([c, v]) => `| bits/claim ${c} | ${ci(v)} | ${c === 'raw' ? `mean ≥ ${RAW_MIN_BITS} (sanity)` : ''} |`),
    `| raw − ideas-only | ${ci(s.rawExcess)} | |`,
    ...Object.entries(s.bitsPerSpeaker).map(([c, v]) => `| bits/speaker (sum over a speaker's claims) ${c} | ${ci(v)} | (reported) |`),
    `| C content composite | ${f2(s.content.C)} | ≥ ${C_MIN} |`,
    `| · T8 idea retention | ${ci(s.content.T8)} | |`, `| · T9 v3 public facts (no appendix) | ${ci(s.content.T9)} | |`, `| · T11 in-room QA | ${ci(s.content.T11)} | |`,
    `| T1 v4 (names / seats / bound private orgs) | ${s.hard.T1v4} (${s.hard.T1v4by.names} / ${s.hard.T1v4by.roles} / ${s.hard.T1v4by.orgs}) | 0 |`,
    `| selfTraits (reported, not a hard zero in v4) | ${s.hard.selfTraitsReported} | — |`,
    `| T2 long quotes | ${s.hard.T2} | 0 |`, `| T6 v3 outsider-named | ${s.hard.T6} | 0 |`,
    `| +L4 claims / unattributable | ${s.attribution.claims} / ${s.attribution.unattributable} (${s.attribution.rate == null ? '—' : (100 * s.attribution.rate).toFixed(1) + '%'})${s.attribution.flag ? ' ⚠ > 30%' : ''} | |`,
    `| aligner vs bigram agreement | ${s.attribution.detAgreement == null ? '—' : (100 * s.attribution.detAgreement).toFixed(1) + '%'} | |`,
    `| attacker parse failures (uniform fallback) | ${Object.entries(s.parseFailures).map(([a, n]) => `${a}: ${n}`).join(', ')} | |`, ''];
  L.push('Per attacker bits/claim:', '', `| attacker | ${Object.keys(s.abs).join(' | ')} |`, `|---|${Object.keys(s.abs).map(() => '---').join('|')}|`);
  for (const a of s.attackers) L.push(`| ${a} | ${Object.keys(s.abs).map((c) => ci(s.perAttacker[a][c])).join(' | ')} |`);
  if (s.probe) L.push('', `Memorisation probe (${s.probe.items} items): bits/excerpt ${ci(s.probe.bits)}, excess over ideas-only ${ci(s.probe.excessOverIdeasOnly)}, meeting (year+month) hit rate ${(100 * s.probe.meetingHitRate).toFixed(0)}% (${Object.entries(s.probe.hitsPerAttacker).map(([a, n]) => `${a} ${n}`).join(', ')}) → ${s.probe.flag ? '**FLAG: possible memorisation**' : 'no memorisation flag'}`);
  return L.join('\n') + '\n';
}

/** Fit one temperature per attacker on the raw config of dev blocks (§9.2) → calibration record (to be frozen). */
export function fitCalibration(blocks, items, attackers, meta = {}) {
  const out = { version: BENCH_VERSION_V4, fittedOn: 'dev raw', grid: '[0.2, 5] log, 201 points', eps: 0.02, ...meta, attackers: {} };
  for (const a of attackers) {
    const rows = calibRows(blocks, items, a, { configs: ['raw'] });
    const fit = fitTemperature(rows);
    out.attackers[a] = { tau: fit.tau, nll: fit.nll, nllAtTau1: fit.nll1, n: fit.n, atBoundary: fit.atBoundary, ece: eceReport(rows, fit.tau) };
  }
  return out;
}
/** Calibration diagnostics on other configs with a frozen τ (ECE before / after). */
export function calibDiagnostics(blocks, items, attackers, calib) {
  return Object.fromEntries(attackers.map((a) => [a, Object.fromEntries(['raw', 'ideas-only', '+L4'].map((c) => { const rows = calibRows(blocks, items, a, { configs: [c] }); return [c, { n: rows.length, ...eceReport(rows, calib[a]?.tau ?? 1) }]; }))]));
}