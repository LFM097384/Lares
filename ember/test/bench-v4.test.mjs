// EmberBench v4 (METHOD §9): estimator, calibration, bootstrap, parsing, strictness knob (no network).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normaliseDist, parseDistributions, smooth, applyTemp, leakBits, fitTemperature, ece, calibrate, extractClaims, hierBootstrap, meanOf, excessOf, cellMean, deName, bigramSpeaker } from '../bench/v4/estimator.mjs';
import { buildUnits, summariseV4, probeExcerpts, probeHit, claimSet, fitCalibration } from '../bench/v4/score-v4.mjs';
import { attackDistributions, alignClaims } from '../bench/v4/attack-v4.mjs';
import { strictnessProfile, DEFAULT_STRICTNESS } from '../core/gate/strictness.mjs';
import { runGate } from '../core/gate/gate.mjs';
import { rng } from '../bench/bootstrap.mjs';

const roster = [{ id: 's0', name: 'Lorena Gonzalez', aliases: ['Gonzalez'] }, { id: 's1', name: 'Dan Strauss' }, { id: 's2', name: 'Participant 2', unnamed: true }, { id: 's3', name: 'Kshama Sawant' }];

test('v4 normaliseDist: ids, names, aliases, percentages, arrays, junk', () => {
  assert.deepEqual(normaliseDist({ s0: 3, s1: 1 }, roster).p, [0.75, 0.25, 0, 0]);
  assert.deepEqual(normaliseDist({ 'lorena gonzalez': '50%', Strauss: 0, 'Dan Strauss': '50%' }, roster).p, [0.5, 0.5, 0, 0]);
  assert.deepEqual(normaliseDist({ Gonzalez: 1 }, roster).p, [1, 0, 0, 0]);
  assert.deepEqual(normaliseDist([{ id: 's3', p: 0.2 }, { rosterId: 's1', prob: 0.2 }, { speaker: 'nobody', p: 0.6 }], roster).p, [0, 0.5, 0, 0.5]);
  const u = normaliseDist({ zz: 1, s1: -2, s2: 'x' }, roster);
  assert.equal(u.ok, false); assert.deepEqual(u.p, [0.25, 0.25, 0.25, 0.25]);
  assert.equal(normaliseDist(null, roster).ok, false);
});

test('v4 parseDistributions accepts claims / results / object forms', () => {
  assert.deepEqual(parseDistributions({ claims: [{ id: 'c1', p: { s0: 1 } }, { claimId: 'c2', probabilities: { s1: 1 } }] }).get('c2'), { s1: 1 });
  assert.deepEqual(parseDistributions({ results: [{ i: 3, dist: { s0: 1 } }] }).get('3'), { s0: 1 });
  assert.deepEqual(parseDistributions({ claims: { c1: { p: { s2: 1 } } } }).get('c1'), { s2: 1 });
  assert.equal(parseDistributions('garbage').size, 0);
});

test('v4 leak bits: uniform = 0, certain = log2 k, wrong = 0 (clipped)', () => {
  assert.equal(leakBits(0.25, 4), 0);
  assert.equal(leakBits(1, 4), 2);
  assert.equal(leakBits(0.01, 4), 0);
  assert.ok(Math.abs(leakBits(0.5, 4) - 1) < 1e-12);
  assert.equal(leakBits(1, 1), 0);
});

test('v4 smoothing + temperature keep normalisation and order', () => {
  const p = smooth([1, 0, 0, 0]);
  assert.ok(Math.abs(p.reduce((a, b) => a + b, 0) - 1) < 1e-12 && p[1] > 0);
  const hot = applyTemp([0.7, 0.2, 0.1], 0.5), cold = applyTemp([0.7, 0.2, 0.1], 2);
  assert.ok(hot[0] > 0.7 && cold[0] < 0.7 && Math.abs(hot.reduce((a, b) => a + b, 0) - 1) < 1e-12);
  assert.deepEqual(applyTemp([0.5, 0.5], 3).map((x) => x.toFixed(6)), ['0.500000', '0.500000']);
});

test('v4 temperature fit recovers over- and under-confidence and lowers ECE', () => {
  const r = rng(7);
  // overconfident attacker: always says 0.9 on its top pick, right only 50% of the time (k=4)
  const over = Array.from({ length: 400 }, () => { const right = r() < 0.5; const t = Math.floor(r() * 4); const top = right ? t : (t + 1) % 4; const p = [0.1 / 3, 0.1 / 3, 0.1 / 3, 0.1 / 3]; p[top] = 0.9; return { p, t }; });
  const f = fitTemperature(over);
  assert.ok(f.tau > 1.2, `tau ${f.tau}`);
  assert.ok(f.nll <= f.nll1);
  const before = ece(over).ece, after = ece(over.map((x) => ({ p: calibrate(x.p, f.tau), t: x.t }))).ece;
  assert.ok(after < before, `${after} < ${before}`);
  // underconfident: says 0.4 but is right 95%
  const under = Array.from({ length: 400 }, () => { const t = Math.floor(r() * 4); const top = r() < 0.95 ? t : (t + 2) % 4; const p = [0.2, 0.2, 0.2, 0.2]; p[top] = 0.4; return { p, t }; });
  assert.ok(fitTemperature(under).tau < 1);
  assert.equal(fitTemperature([]).tau, 1);
});

test('v4 ECE: perfectly calibrated bins → 0; all-wrong confident → high', () => {
  const rows = [{ p: [1, 0], t: 0 }, { p: [1, 0], t: 0 }];
  assert.equal(ece(rows).ece, 0);
  assert.ok(ece([{ p: [0.95, 0.05], t: 1 }]).ece > 0.9);
  assert.equal(ece([]).ece, null);
});

test('v4 extractClaims: bullets only, appendix and headers dropped, review marks stripped', () => {
  const rel = '会议纪要 · 不署名 / Minutes · no attribution\n\n# Digest (session 2026-11-07)\n\n## Zoning\n- The rezoning was approved.\n- [review: role-revealing] A staff report was presented.\n\n## Public record\n- Bills: CB 120164.\n\n## Parks\n* Turf conversion was discussed.\n- ok\n';
  assert.deepEqual(extractClaims(rel), ['The rezoning was approved.', 'A staff report was presented.', 'Turf conversion was discussed.']);
  assert.deepEqual(extractClaims(''), []);
});

test('v4 hierarchical bootstrap: deterministic, brackets the mean, paired excess', () => {
  const units = Array.from({ length: 12 }, (_, i) => ({ meeting: `m${i % 6}`, item: `t${i}`, cells: { a: [[1, 1.2, 0.8, 1], [0.5, 0.5, 0.5, 0.5]], b: [[0.2, 0.4, 0.3]] } }));
  const s1 = hierBootstrap(units, excessOf('a', 'b'), { B: 300 }), s2 = hierBootstrap(units, excessOf('a', 'b'), { B: 300 });
  assert.deepEqual(s1, s2);
  assert.ok(Math.abs(s1.mean - 0.7) < 1e-9, String(s1.mean));
  assert.ok(s1.lo <= s1.mean && s1.hi >= s1.mean && s1.hi - s1.lo < 0.6);
  assert.equal(s1.meetings, 6);
  assert.equal(cellMean([[1, 3], [5, 5]]), 5); // max over attackers
  assert.equal(cellMean([[1, 3], [0, 0]], [1, 1]), 3);
  const m = hierBootstrap(units, meanOf('b'), { B: 200 });
  assert.ok(Math.abs(m.mean - 0.3) < 1e-9);
});

const item = () => ({
  id: 't1', meetingUid: 'M_1', sessionDate: '2021-12-13', roster,
  lines: [{ speakerId: 's0', speakerName: 'Lorena Gonzalez', text: 'We should expand the bus lane network across downtown corridors.' }, { speakerId: 's3', speakerName: 'Kshama Sawant', text: 'Rent control is necessary to protect renters from displacement in the city.' }],
  gold: { ideas: [{ id: 'i1', text: 'expand the bus lane network across downtown corridors', owner: 's0' }, { id: 'i2', text: 'rent control to protect renters from displacement', owner: 's3' }], identifiers: [] },
});

test('v4 mock pipeline: raw leaks bits, ideas-only ≈ 0, units and summary are consistent', async () => {
  const t = item();
  const mock = { provider: 'mock' };
  const raw = t.lines.map((l) => `${l.speakerName}: ${l.text}`).join('\n');
  const rd = await attackDistributions(mock, { roster, released: raw, claims: claimSet('raw', t), mode: 'raw' });
  assert.ok(rd.dists.get('c1').p[0] > 0.5 && rd.dists.get('c2').p[3] > 0.5);
  const id = await attackDistributions(mock, { roster, released: null, claims: claimSet('ideas-only', t), mode: 'ideas-only' });
  const blk = (config, d) => ({ tid: 't1', config, seed: 1, v4: { claims: claimSet(config, t), dist: { A: Object.fromEntries([...d.dists].map(([k, v]) => [k, v.p])) }, failed: { A: 0 } } });
  const blocks = [blk('raw', rd), blk('ideas-only', id)];
  const cal = fitCalibration(blocks, [t], ['A']);
  assert.ok(cal.attackers.A.n === 2 && cal.attackers.A.tau > 0);
  const u = buildUnits(blocks, [t], ['A'], { A: { tau: 1 } });
  assert.equal(u.length, 1);
  assert.ok(u[0].cells.raw[0].every((b) => b > 0.5));
  assert.ok(u[0].cells['ideas-only'][0].every((b) => b === 0));
  const s = summariseV4({ blocks, records: [], items: [t], attackers: ['A'], calib: { A: { tau: 1 } } });
  assert.ok(s.abs.raw.mean > 0.5 && s.abs['ideas-only'].mean === 0);
});

test('v4 aligner mock → bigram speaker; unattributable claims excluded vs counted as zero', async () => {
  const t = item();
  const claims = [{ id: 'c1', text: 'The bus lane network should expand across downtown corridors.' }, { id: 'c2', text: 'The meeting was adjourned.' }];
  const al = await alignClaims({ provider: 'mock' }, { lines: t.lines, roster, claims });
  assert.equal(al.get('c1').primary, 's0');
  assert.equal(al.get('c2').primary, null);
  assert.equal(bigramSpeaker('rent control protect renters', t.lines), 's3');
  const block = { tid: 't1', config: '+L4', seed: 1, v4: { claims: [{ id: 'c1', text: '', truth: 's0' }, { id: 'c2', text: '', truth: null }], dist: { A: { c1: [1, 0, 0, 0], c2: [1, 0, 0, 0] } } } };
  const ex = buildUnits([block], [t], ['A'], { A: { tau: 1 } });
  const z = buildUnits([block], [t], ['A'], { A: { tau: 1 } }, { unattributable: 'zero' });
  assert.equal(ex[0].cells['+L4'][0].length, 1);
  assert.deepEqual(z[0].cells['+L4'][0].slice(1), [0]);
  assert.equal(ex[0].stats['+L4'].unattributable, 1);
});

test('v4 memorisation probe: deterministic de-named excerpts, hit = year + month', () => {
  const t = { ...item(), lines: [{ speakerId: 's1', speakerName: 'Dan Strauss', text: 'Thank you Councilmember Gonzalez. As the representative of District 6 I, Dan Strauss, want to say that the Ballard bridge project needs more funding this year and the next year too, for safety.' }] };
  const ex = probeExcerpts(t);
  assert.equal(ex.length, 1);
  assert.doesNotMatch(ex[0].text, /Gonzalez|Strauss|District 6|Councilmember/);
  assert.match(ex[0].text, /Ballard bridge/);
  assert.deepEqual(probeExcerpts(t), ex);
  assert.equal(deName('Madam President, thank you.', {}).startsWith('[X]'), true);
  assert.equal(probeHit({ year: 2021, month: '12' }, t), true);
  assert.equal(probeHit({ year: 2021, month: 11 }, t), false);
  assert.equal(probeHit(null, t), false);
});

test('gate strictness profile: 1 = defaults unchanged; 0 lenient; 2–3 stricter; invalid → default', () => {
  assert.equal(DEFAULT_STRICTNESS, 1);
  assert.deepEqual(strictnessProfile(1), { level: 1, stripSelfTraits: true, threshold: 0.5, maxRounds: 2, fixAll: false, withholdAll: false, strictNote: false });
  assert.deepEqual(strictnessProfile(1, { threshold: 0.6, maxRounds: 4 }).threshold, 0.6);
  const l0 = strictnessProfile(0), l2 = strictnessProfile(2), l3 = strictnessProfile(3);
  assert.ok(!l0.stripSelfTraits && l0.threshold > 0.5 && l0.maxRounds === 1);
  assert.ok(l2.fixAll && !l2.withholdAll && l2.threshold < 0.5 && l2.maxRounds === 3);
  assert.ok(l3.fixAll && l3.withholdAll && l3.strictNote && l3.threshold < l2.threshold);
  assert.equal(strictnessProfile(9).level, 1);
  assert.equal(strictnessProfile('x').level, 1);
});

test('gate strictness: default == level 1 (byte-identical), level 0 keeps self-traits, private mode ignores the knob', async () => {
  const tr = { roster: [{ id: 'a', name: 'Ann Lee', org: 'Seattle City Council', title: 'Councilmember' }, { id: 'b', name: 'Bo Chen', org: 'Seattle City Council', title: 'Councilmember' }],
    lines: [{ speakerId: 'a', speakerName: 'Ann Lee', text: "I've lived here for 40 years and I oppose the rezoning of the waterfront parcel." }, { speakerId: 'b', speakerName: 'Bo Chen', text: 'The bill passed 7 to 2 after a long debate about the waterfront parcel.' }], sessionDate: '2021-01-01', lang: 'en' };
  const pc = ['Seattle City Council', 'Seattle'];
  const d = await runGate(tr, { publicContext: pc });
  const d1 = await runGate(tr, { publicContext: pc, strictness: 1 });
  assert.equal(d.digest, d1.digest);
  const d0 = await runGate(tr, { publicContext: pc, strictness: 0 });
  assert.doesNotMatch(d1.digest, /40 years/);
  assert.match(d0.digest, /40 years/);
  const p = await runGate(tr, {}), p0 = await runGate(tr, { strictness: 0 }), p3 = await runGate(tr, { strictness: 3 });
  assert.equal(p.digest, p0.digest); assert.equal(p.digest, p3.digest);
});
