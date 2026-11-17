// METHOD P13 · pseudonymiser fixes derived from the spent test-v5 leak audit. Made-up names only; no network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildPseudonyms, boundAt } from '../core/gate/pseudonym.mjs';
import { sensitiveRun } from '../core/gate/gate.mjs';
import { classify, initials } from '../bench/v5/leak-audit.mjs';

const roster = [
  { id: 's0', name: 'Unnamed speaker (Speaker 0)', unnamed: true, title: 'Council President', org: 'Ashford City Council' },
  { id: 's1', name: 'Unnamed speaker (Speaker 1)', unnamed: true, title: 'staff — Deputy and Harbor Engineer', org: 'Public Works' },
  { id: 's2', name: 'Unnamed speaker (Speaker 2)', unnamed: true, title: 'public speaker', org: '' },
];
const lines = [
  { speakerId: 's0', text: 'Next, first we have Tavi Quorel, a sixth grader from the Brindle Academy.' },
  { speakerId: 's2', text: 'Ozzo Venkel is here tonight representing the Marlow Trust about the twenty acres.' },
  { speakerId: 's0', text: 'I want to recognize and thank Captain Drevin on my staff. Councilmember Hale has met with Rob Kestrel.' },
  { speakerId: 's0', text: 'Pellworth.' },
  { speakerId: 's2', text: 'There is also the Quimby estate, about 150 acres, near San Marisol and the Larch Lagoon.' },
  { speakerId: 's2', text: 'My name is Iva Drum with the Bureau of Tidal Records. I am a proud resident of the fourth district.' },
  { speakerId: 's1', text: 'Good evening, I am the harbor engineer. We visited San Marisol last week.' },
];
const T = { roster, lines, lang: 'en' };
const P = () => buildPseudonyms(T, { seed: 1, lang: 'en', shared: ['Ashford City Council', 'Ashford'] });

test('P13 (a): two-word names in person contexts, rank titles, called-out single names, estates are learned', () => {
  const p = P();
  const out = p.finalize('Tavi Quorel spoke. Ozzo Venkel attended. Captain Drevin helped. Rob Kestrel met staff. Pellworth was raised. The Quimby estate owns land.');
  for (const n of ['Tavi', 'Quorel', 'Ozzo', 'Venkel', 'Drevin', 'Kestrel', 'Pellworth', 'Quimby']) assert.ok(!out.includes(n), `${n} leaked: ${out}`);
});

test('P13 (a): places, orgs and topic words are NOT learned as names', () => {
  const out = P().finalize('A visit to San Marisol and the Larch Lagoon was described, with the Brindle Academy.');
  for (const w of ['San Marisol', 'Larch Lagoon', 'Brindle Academy']) assert.ok(out.includes(w), `${w} over-masked: ${out}`);
});

test('P13 (d): in-room staff titles, self-introduced orgs and resident-of seats are generalised', () => {
  const out = P().finalize('A report was presented by the harbor engineer. A representative of the Bureau of Tidal Records was present. A resident of the fourth district spoke.');
  assert.ok(!/harbor engineer/i.test(out), out);
  assert.ok(!/fourth district/i.test(out), out);
  assert.ok(!/representative of the Bureau of Tidal Records/.test(out), out);
});

test('P13 (b): appreciation / congratulation / sponsorship positions are bound', () => {
  for (const [s, w] of [['There was strong appreciation for Merrin leadership.', 'Merrin'], ['Congratulations to Merrin on the ordinance.', 'Merrin'], ['The item was co-sponsored by Merrin.', 'Merrin'], ['Merrin and Tobe sponsored the item.', 'Merrin'], ['Thanks went to a member, Merrin, for the work.', 'Merrin']]) {
    const i = s.indexOf(w); assert.ok(boundAt(s, i, i + w.length), s);
  }
  const s = 'The Merrin park plan was discussed.'; assert.ok(!boundAt(s, s.indexOf('Merrin'), s.indexOf('Merrin') + 6));
});

test('P13 (e): sensitiveRun flags a copied run that the pseudonymiser would change', () => {
  const p = P();
  const f = sensitiveRun({ safe: (x) => x, own: [], lang: 'en', unbind: [], mask: (x) => p.mask(x).text });
  const a = 'a report by the harbor engineer on the pier repairs and the dredging schedule for next spring';
  const b = 'a report on the pier repairs and the dredging schedule for next spring and the budget';
  assert.equal(f(a, a), true);
  assert.equal(f(b, b), false);
});

test('leak-audit classify + initials', () => {
  const ctx = { raw: 'Thank you, Pellworth. The Dune house.', learnedLow: new Set(), granted: ['Corrigan'] };
  assert.equal(classify({ cat: 'names', text: 'Pellworth' }, ctx), 'a');
  assert.equal(classify({ cat: 'names', text: 'Zorvan' }, ctx), 'c');
  assert.equal(classify({ cat: 'seats', text: 'first district' }, ctx), 'd');
  assert.equal(classify({ cat: 'vocatives', rule: 'public-name-bound', text: 'Corrigan' }, ctx), 'b');
  assert.equal(classify({ cat: 'vocatives', rule: 'public-name-bound', text: 'Dune house' }, ctx), 'f');
  assert.equal(initials('Tavi Quorel spoke'), 'T. Q. spoke');
});
