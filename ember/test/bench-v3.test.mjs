// EmberBench v3 (METHOD §8): binding-aware T1, T9 v3, T9b, T6 v3, v3 selection and merge (no network).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normFact, affiliationBound, bindingLeaks, publicFactRetentionV3, factAccuracy, numberAnchors, outsiderV3, quasiLeaksV3, scoreV3, isSeatRef } from '../bench/metrics-v3.mjs';
import { mergeV3, spanList } from '../bench/gen/annotate-v3.mjs';
import { selectV3, isoDate } from '../bench/gen/import-public.mjs';
import { judgeV3, THRESHOLDS_V3 } from '../bench/rescore-v3.mjs';

const base = () => ({
  id: 'x', track: 'public', publicContext: ['Seattle City Council', 'Seattle'],
  roster: [
    { id: 's0', name: 'Lorena Gonzalez', aliases: ['Gonzalez'], title: 'Council President', org: 'Seattle City Council' },
    { id: 's3', name: 'Dan Strauss', aliases: ['Strauss'], title: 'Councilmember', org: 'Seattle City Council' },
    { id: 's5', name: 'Participant 5', unnamed: true, aliases: [], title: 'public speaker', org: 'Seattle City Council' },
  ],
  lines: [],
  gold: {
    identifiers: [], thirdParties: [],
    publicFacts: [
      { id: 'f1', text: 'Council Bill 119906 transfers property at 530th Avenue to Central Area Senior Center', keep: ['119906', 'Central Area Senior Center'] },
      { id: 'f2', text: 'Resolution 31856 relates to social services', keep: ['Resolution 31856'] },
      { id: 'f3', text: 'The centre has served the community for over 50 years', keep: ['over 50 years'] },
      { id: 'f4', text: 'Speaker lives at 12 Elm Street', keep: ['12 Elm Street'] },
    ],
    spansV3: [
      { text: 'Madam President', kind: 'title', binding: 'bound', boundTo: 's0', referent: 'person' },
      { text: 'Mayor', kind: 'title', binding: 'bound', boundTo: 's0', referent: 'person' },
      { text: 'District six', kind: 'number', binding: 'bound', boundTo: 's3', referent: 'place' },
      { text: 'Central Area Senior Center', kind: 'org', binding: 'topic', boundTo: null, referent: 'org', publicEntity: true },
      { text: 'Greenwood Senior Center', kind: 'org', binding: 'bound', boundTo: 's5', referent: 'org', publicEntity: true, mixed: true },
      { text: 'Rainier Valley Food Co-op', kind: 'org', binding: 'bound', boundTo: 's5', referent: 'org', publicEntity: false },
      { text: 'as the only woman on this council', kind: 'selfTrait', binding: 'bound', boundTo: 's0', referent: 'person' },
      { text: 'Disputed Corp', kind: 'org', binding: 'bound', boundTo: 's5', publicEntity: false, disputed: true },
      { text: '119906', kind: 'keep', factId: 'f1', binding: 'topic' },
      { text: 'Central Area Senior Center', kind: 'keep', factId: 'f1', binding: 'topic' },
      { text: 'Resolution 31856', kind: 'keep', factId: 'f2', binding: 'topic' },
      { text: 'over 50 years', kind: 'keep', factId: 'f3', binding: 'topic' },
      { text: '12 Elm Street', kind: 'keep', factId: 'f4', binding: 'bound', boundTo: 's5' },
    ],
  },
});

test('v3 normFact: number words, scales, ordinals, currency and percent normalise', () => {
  assert.equal(normFact('District six'), 'district 6');
  assert.equal(normFact('twenty-one votes'), '21 votes');
  assert.equal(normFact('$1 million'), '1000000 dollars');
  assert.equal(normFact('1 million dollars'), '1000000 dollars');
  assert.equal(normFact('12 percent'), '12%');
  assert.equal(normFact('April 23rd, 2019'), 'april 23 2019');
  assert.equal(normFact('1,250 units'), '1250 units');
  assert.equal(normFact('the third reading'), 'the 3 reading');
});

test('v3 T1: a topic org is not a leak; the same org bound by affiliation is', () => {
  const t = base();
  assert.equal(bindingLeaks('Regarding the Central Area Senior Center, a view held that funding is short.', t).total, 0);
  assert.equal(bindingLeaks('Funding for Greenwood Senior Center was discussed.', t).orgs, 0, 'public / mixed bound org as topic subject');
  const b = bindingLeaks('A participant from Greenwood Senior Center said funding is short.', t);
  assert.equal(b.orgs, 1);
  assert.equal(b.items[0].rule, 'affiliation');
  assert.equal(bindingLeaks('Our Greenwood Senior Center needs funds.', t).orgs, 1);
  assert.equal(bindingLeaks('Greenwood Senior Center staff asked for more time.', t).orgs, 1);
});

test('v3 T1: a private bound org leaks on any whole-word presence; disputed spans never count', () => {
  const t = base();
  assert.equal(bindingLeaks('The Rainier Valley Food Co-op supports the bill.', t).orgs, 1);
  assert.equal(bindingLeaks('Disputed Corp was mentioned.', t).total, 0);
  assert.equal(bindingLeaks('A local food cooperative supports the bill.', t).total, 0);
});

test('v3 T1: names, multi-token vocatives and seat references count; bare one-word titles do not', () => {
  const t = base();
  assert.equal(bindingLeaks('Strauss supported the bill.', t).names, 1);
  assert.equal(bindingLeaks('Thank you, Madam President.', t).roles, 1);
  assert.equal(bindingLeaks('The Mayor proposed a budget.', t).roles, 0, 'bare title stays in T12');
  assert.equal(bindingLeaks('The site is in District 6, right in one member\'s district.', t).roles, 1, 'seat via number normalisation');
  assert.equal(bindingLeaks('The site is in a council district in the north.', t).roles, 0);
  assert.ok(isSeatRef('District six') && isSeatRef('the 4th district') && !isSeatRef('Madam President'));
});

test('v3 T1: self-disclosed identity traits leak verbatim or fuzzily', () => {
  const t = base();
  assert.equal(bindingLeaks('It was said, as the only woman on this council, that the process excluded people.', t).selfTraits, 1);
  assert.equal(bindingLeaks('A member noted she was the only woman on the council.', t).selfTraits, 1, 'fuzzy (bigram) rule');
  assert.equal(bindingLeaks('A member noted the process excluded people.', t).selfTraits, 0);
});

test('v3 affiliation patterns', () => {
  for (const s of ['A representative of Acme Housing spoke.', 'Speaking on behalf of Acme Housing, a view was given.', "Acme Housing's director objected.", 'Someone who works at Acme Housing objected.', 'As the director of Acme Housing, it was argued that…', 'An Acme Housing representative objected.'])
    assert.ok(affiliationBound(s, 'Acme Housing'), s);
  for (const s of ['Regarding Acme Housing, a view held that rents rise.', 'Funding for Acme Housing was approved.', 'The contract with Acme Housing was approved.'])
    assert.ok(!affiliationBound(s, 'Acme Housing'), s);
});

test('v3 T9: topic keeps only, verbatim or normalised; bound keeps are not retention targets', () => {
  const t = base();
  const r = publicFactRetentionV3('Council Bill 119906 conveys land to Central Area Senior Center. Resolution 31,856 was cited. It has served for over fifty years.', t);
  assert.equal(r.total, 4, 'f4 keep is bound → excluded');
  assert.equal(r.kept, 4);
  assert.equal(publicFactRetentionV3('Nothing of substance.', t).kept, 0);
});

test('v3 T9b: anchored numbers are correct, wrong or absent', () => {
  const t = base();
  assert.deepEqual(numberAnchors('Resolution 31856', 'Resolution 31856 relates to social services').map((a) => [a.num, a.anchor, a.side]), [['31856', 'resolution', 'L']]);
  assert.deepEqual(numberAnchors('over 50 years', 'x').map((a) => [a.num, a.anchor, a.side]), [['50', 'year', 'R']]);
  const ok = factAccuracy('Resolution 31856 was cited; it served for 50 years.', t);
  assert.equal(ok.wrong, 0); assert.ok(ok.correct >= 2);
  const bad = factAccuracy('Resolution 31865 was cited; it served for 15 years.', t);
  assert.equal(bad.wrong, 2);
  const none = factAccuracy('A resolution was cited.', t);
  assert.equal(none.correct + none.wrong, 0, 'absent numbers are not scored');
});

test('v3 T9b (P5): anchor + number pairs ambiguous in the source transcript are excluded in every config', () => {
  const t = base();
  t.lines = [{ speakerId: 's0', text: 'Resolution 31856 is the one. Resolution 31837 was earlier.' }, { speakerId: 's3', text: 'The centre has served us for over 50 years.' }];
  const r = factAccuracy('Resolution 31837 was cited; it served for 50 years.', t);
  assert.equal(r.ambiguous, 2, 'resolution is adjacent to two numbers in the source; bill 119906 never anchored in it');
  assert.equal(r.wrong, 0); assert.equal(r.correct, 1);
  const raw = factAccuracy(t.lines.map((l) => l.text).join('\n'), t);
  assert.equal(raw.wrong, 0, 'the raw transcript can never be wrong on a scorable pair');
});

test('v3 T12 denominator: bound spans only', () => {
  const q = quasiLeaksV3('Thank you Mayor.', base());
  assert.deepEqual(q.map((x) => x.text).sort(), ['District six', 'Madam President', 'Mayor']);
  assert.equal(q.filter((x) => x.leak).length, 1);
});

test('v3 T6: outsider naming a member needs evidence and beats the control; topic / public orgs do not count', () => {
  const t = base();
  const out = 'Gonzalez moved the bill. Central Area Senior Center gets the land. Rainier Valley Food Co-op supported.';
  const r = outsiderV3(['Lorena Gonzalez', 'Central Area Senior Center', 'Greenwood Senior Center', 'Rainier Valley Food Co-op'], out, t);
  assert.deepEqual(r.members, ['s0']); assert.deepEqual(r.orgs, ['s5']); assert.equal(r.count, 2);
  assert.equal(outsiderV3(['Lorena Gonzalez'], 'A member moved the bill.', t).count, 0, 'no evidence in the output');
  assert.equal(outsiderV3(['Lorena Gonzalez'], out, t, ['Gonzalez']).count, 0, 'paired control names her too');
});

test('v3 scoreV3 + judge: thresholds T1/T6 zero, T9 ≥ .90, T9b ≥ .95', () => {
  const s = scoreV3({ release: 'Thank you, Madam President. Resolution 31856 was cited.', memory: '' }, base());
  assert.equal(s.bind.roles, 1);
  assert.equal(THRESHOLDS_V3.find((x) => x.id === 'T9b').value, 0.95);
  const v = judgeV3({ T1: 0, T6: 0, T9: 0.91, T9b: 0.95, T12: 0.1 });
  assert.equal(v.T1, 'PASS'); assert.equal(v.T9, 'PASS'); assert.equal(v.T9b, 'PASS');
  const w = judgeV3({ T1: 1, T6: 2, T9: 0.89, T9b: 0.94, T12: 0.2 });
  assert.deepEqual([w.T1, w.T6, w.T9, w.T9b, w.T12], ['FAIL', 'FAIL', 'FAIL', 'FAIL', 'FAIL']);
});

test('v3 mergeV3: checker errors and non-verbatim traits are disputed; same-text topic makes a bound org mixed', () => {
  const t = { ...base(), lines: [{ speakerId: 's5', text: 'I run Greenwood Senior Center. I have lived here 40 years.' }, { speakerId: 's0', text: 'The Greenwood Senior Center property is on the list. Resolution 31856.' }] };
  t.gold = { ...t.gold, identifiers: [{ text: 'Greenwood Senior Center', kind: 'org', owner: 's5' }], publicFacts: [{ id: 'f1', text: 'Greenwood Senior Center property is listed', keep: ['Greenwood Senior Center'] }], spansV3: undefined };
  const spans = spanList(t);
  assert.deepEqual(spans.map((s) => s.source), ['identifier', 'keep']);
  const annotation = { spans: [{ i: 0, referent: 'org', binding: 'bound', boundTo: 's5', publicEntity: true }, { i: 1, referent: 'org', binding: 'topic', boundTo: null }], selfTraits: [{ text: 'I have lived here 40 years', boundTo: 's5' }, { text: 'not in the lines', boundTo: 's5' }], affiliations: [] };
  const u = mergeV3(t, { spans, annotation, check: { verdict: 'issues', issues: [{ ref: 'selfTrait:0', severity: 'warn', problem: 'ok' }] } });
  const S = u.gold.spansV3;
  assert.equal(S[0].mixed, true, 'bound org with the same text as a topic keep');
  assert.equal(S.filter((s) => s.kind === 'selfTrait' && !s.disputed).length, 1);
  assert.equal(S.filter((s) => s.kind === 'selfTrait' && s.disputed).length, 1);
  const u2 = mergeV3(t, { spans, annotation, check: { issues: [{ ref: 'span:0', severity: 'error', problem: 'wrong' }] } });
  assert.equal(u2.gold.spansV3[0].disputed, true);
  assert.equal(u2.gold.identifiers.length, 1, 'v2 gold untouched');
});

test('v3 selection: date hold-out after the latest used meeting, circle + ≤2 per meeting, deterministic', () => {
  const tx = (n) => Array.from({ length: 24 }, (_, i) => `Speaker ${i % 4}: ${'word '.repeat(n)}Councilmember Lopez and Councilmember Kim.`).join('\n');
  const row = (m, item) => ({ id: `${m}_${item}`, item, meeting: m, transcript: tx(30), date: '' });
  const rows = [row('LongBeachCC_01012022', 'a'), row('LongBeachCC_06012022', 'b'), row('LongBeachCC_06012022', 'c'), row('LongBeachCC_06012022', 'd'), row('LongBeachCC_06012022', 'e'), row('LongBeachCC_07012022', 'f'), row('LongBeachCC_07012022', 'g'), row('LongBeachCC_07012022', 'h'), row('LongBeachCC_03012022', 'i')];
  assert.equal(isoDate('LongBeachCC_06012022'), '2022-06-01');
  const s = selectV3(rows, ['LongBeachCC_05012022'], { cities: ['LongBeachCC'] });
  assert.equal(s.cutoff.LongBeachCC, '2022-05-01');
  const ids = s.picked.map((x) => x.r.id);
  assert.ok(!ids.includes('LongBeachCC_01012022_a') && !ids.includes('LongBeachCC_03012022_i'), 'before cutoff excluded');
  assert.equal(s.picked.filter((x) => x.circle).length, 3);
  const singles = s.picked.filter((x) => !x.circle);
  const per = {}; for (const x of singles) per[x.r.meeting] = (per[x.r.meeting] || 0) + 1;
  assert.ok(Object.values(per).every((n) => n <= 2));
  assert.deepEqual(selectV3(rows, ['LongBeachCC_05012022'], { cities: ['LongBeachCC'] }).picked.map((x) => x.r.id), ids);
});

test('run.mjs --schema: v2 default, v3 public-only', async () => {
  const { parseArgs } = await import('../bench/run.mjs');
  assert.equal(parseArgs([]).schema, 'v2');
  assert.equal(parseArgs(['--track', 'public', '--schema', 'v3']).schema, 'v3');
  assert.throws(() => parseArgs(['--schema', 'v3']), /public only/);
  assert.equal(parseArgs(['--track', 'public', '--schema', 'v4']).schema, 'v4');
  assert.throws(() => parseArgs(['--schema', 'v4']), /public only/);
  assert.equal(parseArgs(['--track', 'public', '--schema', 'v5']).schema, 'v5');
  assert.throws(() => parseArgs(['--schema', 'v5']), /public only/);
  assert.throws(() => parseArgs(['--track', 'public', '--schema', 'v6']), /v2\|v3\|v4\|v5/);
  assert.throws(() => parseArgs(['--track', 'public', '--schema', 'v4', '--strictness', '7']), /strictness/);
});
