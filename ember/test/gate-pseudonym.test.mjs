// EmberBench v5 · L0P pseudonymisation, reveal adjudication, post-check, verbatim relaxation, v5 metrics. No network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildPseudonyms, boundAt, isPublicTitle } from '../core/gate/pseudonym.mjs';
import { runGate, sensitiveRun, locateRun } from '../core/gate/gate.mjs';
import { relaxVerbatim, SYSTEM_PROMPT } from '../core/gate/l3.mjs';
import { bindingLeaksV5, sensitiveQuoteLeaks, boundPosition, publicByTitle } from '../bench/metrics-v5.mjs';
import { summariseV5 } from '../bench/v4/score-v5.mjs';

const roster = [
  { id: 's0', name: 'Unnamed speaker (Speaker 0)', unnamed: true, title: 'Council President', org: 'Riverton City Council' },
  { id: 's1', name: 'Dana Cashman', aliases: ['Cashman'], title: 'Councilmember', org: 'Riverton City Council' },
  { id: 's2', name: 'Jessie Parris', aliases: ['Parris'], title: 'public speaker', org: '' },
  { id: 's3', name: 'Valerie Ararat', aliases: ['Ararat'], title: 'staff — Planning', org: 'Planning' },
];
const lines = [
  { speakerId: 's0', text: 'Councilmember Cashman, will you please put Council Bill 22 on the floor?' },
  { speakerId: 's1', text: 'Yes, Madam President, I move that Council Bill 22 be placed upon final consideration.' },
  { speakerId: 's3', text: 'My name is Valerie Ararat, senior planner. The Herndon amendment raised the height limit, as Councilmember Herndon proposed.' },
  { speakerId: 's2', text: 'Thank you. I live in my district, District 8, and Ms. Parris supports this. I think Cashmann was right.' },
  { speakerId: 's0', text: 'Thank you, Val. Roll call: Cashman, aye. Herndon, aye.' },
];
const T = { roster, lines, lang: 'en' };
const shared = ['Riverton City Council'];

test('isPublicTitle: office-holders yes, staff / clerks / public no', () => {
  for (const t of ['Councilmember', 'Council President', 'Vice Mayor', 'Councilmember, District 6', 'City Manager']) assert.ok(isPublicTitle(t), t);
  for (const t of ['public speaker', 'staff — City Attorney\'s Office', 'City Clerk', 'Council Secretary', "owner's representative", '']) assert.ok(!isPublicTitle(t), t);
  assert.equal(publicByTitle('staff — City Manager\'s office'), false);
});

test('mask: every name variant becomes a stable token; titles fold into the token; seats and officer vocatives masked', () => {
  const P = buildPseudonyms(T, { shared, seed: 1, lang: 'en' });
  const out = lines.map((l) => P.mask(l.text).text).join('\n');
  for (const n of ['Cashman', 'Parris', 'Ararat', 'Valerie', 'Herndon', 'Cashmann', 'Val,', 'Madam President', 'District 8']) assert.ok(!out.includes(n), `${n} survived: ${out}`);
  assert.ok(!/Councilmember \[Speaker/.test(out), 'title folded into token');
  const tok = P.entries.find((e) => e.id === 's1').token;
  assert.equal((out.match(new RegExp(tok.replace(/[[\]]/g, '\\$&'), 'g')) || []).length >= 3, true);
  assert.match(out, /a council district/);
  assert.match(out, /the presiding officer/);
  // stable across calls, permutation by seed (not order of appearance)
  assert.equal(buildPseudonyms(T, { shared, seed: 1 }).entries.find((e) => e.id === 's1').token, tok);
  const herndon = P.entries.find((e) => e.names.includes('Herndon'));
  assert.ok(herndon && herndon.kind === 'person' && herndon.public, 'titled name drop → public person');
});

test('boundAt: vocative / procedural / speaker positions are bound; topic mentions are not', () => {
  const at = (s, w) => { const i = s.indexOf(w); return boundAt(s, i, i + w.length); };
  assert.ok(at('Thank you, [Person 1].', '[Person 1]'));
  assert.ok(at('The motion was seconded by [Person 1].', '[Person 1]'));
  assert.ok(at('[Person 1], you are recognised.', '[Person 1]'));
  assert.ok(at('[Person 1] said the plan was flawed.', '[Person 1]'));
  assert.ok(at('Roll call: [Person 1], aye.', '[Person 1]'));
  assert.ok(!at('The [Person 1] amendment raised the height limit.', '[Person 1]'));
  assert.ok(!at("The council discussed [Person 1]'s budget proposal for parks.", '[Person 1]'));
});

test('adjudicate + finalize: public topic mention revealed, private / bound / no-reason denied, post-check re-masks', () => {
  const P = buildPseudonyms(T, { shared, seed: 1, lang: 'en' });
  const H = P.entries.find((e) => e.names.includes('Herndon')).token, J = P.entries.find((e) => e.id === 's2').token;
  const C = P.entries.find((e) => e.id === 's1').token;
  const log = P.adjudicate([
    { token: H, sentence: `The ${H} amendment raised the height limit.`, reason: 'the amendment is named after the official' },
    { token: J, sentence: `${J}'s letter was discussed.`, reason: 'topic' },
    { token: C, sentence: `Thank you, ${C}.`, reason: 'x' },
    { token: C, sentence: `The ${C} plan`, reason: '' },
    { token: '[Person 99]', sentence: 'x', reason: 'y' },
  ]);
  assert.deepEqual(log.map((r) => r.decision), ['granted', 'denied', 'denied', 'denied', 'denied']);
  assert.deepEqual(log.slice(1).map((r) => r.why), ['private', 'bound-position', 'no-reason', 'unknown-token']);
  assert.equal(P.finalize(`The ${H} amendment raised the height limit.`), 'The Herndon amendment raised the height limit.');
  assert.equal(P.finalize(`${H} said the limit was too low.`), 'A participant said the limit was too low.');
  assert.equal(P.finalize(`The ${J} letter about parking was discussed.`), `The ${J} letter about parking was discussed.`);
  // a real name reappearing (hallucinated or restored by a later layer) is re-masked
  assert.ok(!P.finalize('Jessie Parris opposed the bill.').includes('Parris'));
  const s = P.summary();
  assert.equal(s.mode, 'two-pass'); assert.equal(s.requests, 5); assert.equal(s.granted, 1); assert.equal(s.denied.private, 1);
  assert.ok(!JSON.stringify(s.log).includes('Herndon'), 'log carries tokens, not names');
});

test('runGate: pseudonym mode off → byte-identical to v4; on (mock) → no roster names, meta.pseudonym present', async () => {
  const a = await runGate(T, { llm: null, publicContext: shared, seed: 1 });
  const b = await runGate(T, { llm: null, publicContext: shared, seed: 1, pseudonym: false });
  assert.equal(a.digest, b.digest);
  const c = await runGate(T, { llm: null, publicContext: shared, seed: 1, pseudonym: true });
  for (const n of ['Cashman', 'Parris', 'Ararat', 'Herndon']) assert.ok(!c.digest.includes(n), n);
  assert.equal(c.meta.pseudonym.mode, 'two-pass');
  // private mode ignores the option
  const d = await runGate(T, { llm: null, seed: 1, pseudonym: true });
  assert.equal(d.meta.pseudonym, undefined);
});

test('runGate (scripted LLM): reveal requests ride the L3 JSON and are applied after L4', async () => {
  let P;
  const llm = { async chat(messages) {
    const sys = messages[0].content, user = messages.at(-1).content;
    if (/rewrite stage/.test(sys)) {
      assert.ok(/PSEUDONYMS/.test(user) && !/Max verbatim run/.test(user) && /14\. WORDING/.test(sys));
      const tok = (user.split('FRAGMENTS:')[1].match(/\[Person \d+\]/) || [])[0];
      return { text: JSON.stringify({ sections: [{ topic: 'Height', claims: [{ text: `The ${tok} amendment raised the height limit.`, kind: 'idea' }] }], reveals: [{ token: tok, sentence: `The ${tok} amendment raised the height limit.`, reason: 'named amendment' }] }) };
    }
    if (/"results"/.test(sys) || /ATTENDEES/.test(user)) return { text: '{"results":[]}' };
    return { text: '{"spans":[],"private":[],"rewrites":[]}' };
  } };
  const r = await runGate(T, { llm, publicContext: shared, seed: 1, pseudonym: true, layers: ['L0', 'L1', 'L2', 'L3', 'L4'] });
  assert.match(r.digest, /The Herndon amendment raised the height limit/);
  assert.equal(r.meta.pseudonym.granted, 1);
});

test('verbatim relaxation: prompt rules replaced; sensitiveRun flags only identity-bearing copies', () => {
  const p = relaxVerbatim(SYSTEM_PROMPT(20));
  assert.ok(!/Do not copy any run/.test(p) && !/PARAPHRASE\. Never reproduce/.test(p) && /14\. WORDING/.test(p));
  const f = sensitiveRun({ safe: (s) => s.replace(/Acme Corp/g, 'an organisation'), own: [], lang: 'en' });
  const claim = 'the bill would raise the height limit to five stories across the whole corridor next year';
  assert.equal(locateRun(claim, 'raise the height limit to five stories across'), 'raise the height limit to five stories across');
  assert.equal(f(claim, 'the bill would raise the height limit to five stories across'), false);
  assert.equal(f('I have lived here for 40 years and the bill would raise the limit', 'i have lived here for 40 years and the bill'), true);
  assert.equal(f('as I represent the area the bill would raise the limit greatly', 'as i represent the area the bill would raise'), true);
  assert.equal(f('they said Acme Corp would build the whole corridor next year', 'acme corp would build the whole corridor next'), true);
});

const item = {
  id: 'x', roster, lines, publicContext: shared,
  gold: { thirdParties: [{ name: 'Herndon', variants: [], public: true }], identifiers: [], publicFacts: [],
    spansV3: [
      { text: 'Madam President', kind: 'title', binding: 'bound', boundTo: 's0' },
      { text: 'District 8', kind: 'number', binding: 'bound', boundTo: 's2' },
      { text: 'I live in my district', kind: 'selfTrait', binding: 'bound', boundTo: 's2' },
    ] },
};
test('T1 v5: private names anywhere, public names only bound, tokens never', () => {
  assert.equal(bindingLeaksV5('The Herndon amendment raised the height limit. [Speaker 2] and [Person 1] were mentioned.', item).total, 0);
  const a = bindingLeaksV5('Thank you, Herndon. Cashman said the bill was fine.', item);
  assert.equal(a.vocatives, 2); assert.equal(a.publicBound, 2);
  assert.equal(bindingLeaksV5('Parris wrote a letter about the corridor.', item).names, 1);
  assert.equal(bindingLeaksV5('Ararat presented the staff report.', item).names, 1, 'staff are private');
  assert.equal(bindingLeaksV5('A council district: District 8 has the site.', item).seats, 1);
  assert.equal(bindingLeaksV5('Madam President opened the hearing.', item).vocatives, 1);
  assert.ok(boundPosition('The motion was moved by Herndon.', 24, 31));
});

test('T2 v5: long verbatim copy counts only when sensitive', () => {
  const it = { ...item, lines: [{ speakerId: 's3', text: 'The amendment raised the height limit to five stories across the whole corridor next year as proposed.' }, { speakerId: 's2', text: 'Ms. Parris supports the amendment that raised the height limit to five stories across the corridor.' }] };
  assert.equal(sensitiveQuoteLeaks('It was noted that the amendment raised the height limit to five stories across the whole corridor next year.', it).length, 0);
  const h = sensitiveQuoteLeaks('Ms. Parris supports the amendment that raised the height limit to five stories across the corridor.', it);
  assert.equal(h.length, 1); assert.equal(h[0].why, 'private-name');
});

test('summariseV5: v5 hard zeros drive the verdict; reveal stats aggregated', () => {
  const recs = [{ config: '+L4', tid: 'x', seed: 1, v5bind: { total: 0 }, v5quotes: { sensitive: 0, plain: 3 }, v4out6: 0, pseudonym: { mode: 'two-pass', requests: 4, granted: 1, denied: { private: 3 }, unmasked: 1, boundTokens: 0, remasked: 0, entries: { speakers: 4, persons: 1, public: 2, asrVariants: 0 } } }];
  const s = summariseV5({ blocks: [], records: recs, items: [item], attackers: [], calib: {} });
  assert.equal(s.hard.T1v5, 0); assert.equal(s.hard.T2v5, 0); assert.equal(s.hard.T2plainReported, 3); assert.equal(s.hard.pass, true);
  assert.equal(s.reveal.requests, 4); assert.equal(s.reveal.grantRate, 0.25); assert.equal(s.reveal.denied.private, 3);
});
