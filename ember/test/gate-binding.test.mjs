// Public-body mode, binding-aware gate mechanisms (EmberBench v3 framework, METHOD §8.1): binding detector, referent rule,
// verbatim civic restore, self-trait strip, officer neutralisation, L4 cue filter. All synthetic strings.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isPublicEntity, coListedOrgs, hasAffiliation, unbindAffiliations, resolveReferents, stripSelfTraits, stripSelfTraitsOut, neutraliseOfficers, restoreCivic, boundSeats } from '../core/gate/binding.mjs';
import { learnPartnerOrgs } from '../core/gate/l2.mjs';
import { redactPII, isPersonShaped } from '../core/gate/l1.mjs';
import { civicSpans, civicKind } from '../core/gate/shield.mjs';
import { BINDING_CUES } from '../core/gate/l4.mjs';
import { runGate } from '../core/gate/gate.mjs';

const BAD = /\ba participant from\b|\bon behalf of\b|'s representative\b|\bspeaking for\b|\bas director of\b/i;

test('isPublicEntity: government-unit shape is public, private markers / unknown / bare acronyms are not', () => {
  for (const o of ['Parks Department', 'Office of Housing', "City Attorney's Office", 'Department of Transportation', 'Public Works', 'Harbor Transit']) assert.ok(isPublicEntity(o), o);
  for (const o of ['Greenleaf Neighbors Alliance', 'Riverside Pride Inc.', 'Orchard Street Coalition', 'Bluefin Media', 'XYZ', 'Maple Bakery']) assert.ok(!isPublicEntity(o), o);
  assert.ok(isPublicEntity('Riverton City Council', ['Riverton City Council']));
});

test('binding detector: affiliation constructions vs topic mentions', () => {
  const org = 'Parks Department';
  for (const s of ['A representative of the Parks Department said so.', 'Speaking on behalf of the Parks Department, she agreed.', 'Our Parks Department crews did it.', 'The Parks Department staff presented.', 'As director of the Parks Department, I support it.', "I'm here with the Parks Department."]) assert.ok(hasAffiliation(s, org), s);
  for (const s of ['The Parks Department budget rose by 4%.', 'Funding for the Parks Department was approved.', 'Consult the Parks Department.']) assert.ok(!hasAffiliation(s, org), s);
});

test('unbind: bound public org becomes a topic subject; bound private org is generalised; never an affiliation phrase', () => {
  const pub = [{ org: 'Parks Department', public: true }, { org: 'Office of Housing', public: true }];
  const a = unbindAffiliations('A representative of the Parks Department said the fields need lights.', pub);
  assert.match(a, /^Regarding the Parks Department, /);
  assert.doesNotMatch(a, BAD);
  const b = unbindAffiliations('Staff from the Parks Department in the Office of Housing drafted it.', pub);
  assert.match(b, /Regarding the Parks Department and the Office of Housing, /);
  assert.doesNotMatch(b, /from the Parks|in the Office/);
  const c = unbindAffiliations('Speaking on behalf of Greenleaf Neighbors Alliance, they opposed it.', [{ org: 'Greenleaf Neighbors Alliance', public: false }]);
  assert.doesNotMatch(c, /Greenleaf/);
  assert.equal(unbindAffiliations('The Parks Department budget rose.', pub), 'The Parks Department budget rose.'); // topic kept
});

test('learnPartnerOrgs (bound): representing / here with / work at bind; contracts and partners are topics', () => {
  assert.deepEqual(learnPartnerOrgs('We have contracts with Bluefin Media. We partner with Harbor Transit.', { bound: true }), []);
  assert.deepEqual(learnPartnerOrgs("I'm here on behalf of Greenleaf Neighbors Alliance.", { bound: true }), ['Greenleaf Neighbors Alliance']);
});

test('referent rule: my/our <category> → resolved public entity, else generalised, never possessive', () => {
  assert.equal(resolveReferents('Our department reviewed the plan.', ['Office of Housing']), 'The Office of Housing reviewed the plan.');
  assert.equal(resolveReferents('My office agrees.', ['Department of Transportation']), 'The Department of Transportation agrees.');
  assert.equal(resolveReferents('Our coalition opposes it.', ['Orchard Street Coalition']), 'A coalition opposes it.');
  assert.equal(resolveReferents('Our church helps.', []), 'A church helps.');
  assert.equal(resolveReferents('My office drafted the bill.', []), 'A council office drafted the bill.');
  assert.doesNotMatch(resolveReferents('my department and our team', ['Greenleaf Neighbors Alliance']), /\b(?:my|our)\b/i);
});

test('selfTrait strip: first-person identity traits removed, content kept', () => {
  assert.equal(stripSelfTraits("I've lived here for 40 years and I oppose the rezoning."), 'I oppose the rezoning.');
  assert.equal(stripSelfTraits('As the only renter on the council, I support this.'), 'I support this.');
  assert.equal(stripSelfTraits('This was the first issue I took on when I became a legislative aide, and it matters.'), 'This was the first issue I took on, and it matters.');
  assert.doesNotMatch(stripSelfTraits("I'm a lifelong resident of the Eastside, and the bus line matters."), /lifelong|Eastside/);
  assert.equal(stripSelfTraits('The bill passed 7 to 2.'), 'The bill passed 7 to 2.');
  assert.doesNotMatch(stripSelfTraitsOut('A speaker, who has lived in the area for 40 years, opposed it.'), /40 years/);
});

test('officer references are neutralised', () => {
  assert.equal(neutraliseOfficers('The chair will sign it and the clerk will read item 5.'), 'The presiding officer will sign it and meeting staff will read item 5.');
});

test('seats: a district is redacted only when a speaker binds it to themselves', () => {
  const seats = boundSeats([{ text: 'That is in District six, right in my district.' }]);
  assert.ok(seats.has('district six'));
  const sh = ['Riverton City Council', 'Riverton'];
  assert.match(redactPII('The property is in Council District eight.', [], { shared: sh, seats }), /Council District eight/);
  assert.doesNotMatch(redactPII('That is in District six.', [], { shared: sh, seats }), /District six/);
  assert.doesNotMatch(redactPII('Not only in my district.', [], { shared: sh, seats }), /my district/);
});

test('civic shapes: spoken section lists and chapter numbers', () => {
  assert.ok(civicSpans('amending sections 4.10 2.0 or 3010 and 12.30 5.1 70 of this code').includes('sections 4.10 2.0 or 3010 and 12.30 5.1 70'));
  assert.equal(civicKind('Council Bill 1234'), 'Legislation and items');
  assert.equal(civicKind('nine ayes, two nays'), 'Votes and outcomes');
});

test('verbatim restore: copies only existing spans, into the most similar claim; nothing invented', () => {
  const secs = [{ topic: 'Rezoning', claims: [{ text: 'The rezoning of the property on Elm Street was approved.' }, { text: 'Parking was discussed.' }] },
    { topic: 'Vote', claims: [{ text: 'The roll call vote was recorded.' }] }];
  const raw = 'The subject property is at 1200 North Elm Street and asks for a rezoning. Parking matters.\nClerk, please call the roll.\nSix in favor one opposed.';
  const r = restoreCivic(secs, ['1200 North Elm Street', 'Six in favor one opposed', 'Bill 77'], raw);
  assert.match(secs[0].claims[0].text, /\(1200 North Elm Street\)/);
  assert.match(secs[1].claims[0].text, /\(Six in favor one opposed\)/);
  assert.deepEqual(r.left, ['Bill 77']); // not in the source → never added
  const nums = (t) => (t.match(/\d+/g) || []).sort().join(',');
  assert.equal(nums(JSON.stringify(secs)), '1200'); // only numbers copied from the source
  const again = restoreCivic(secs, ['1200 North Elm Street'], raw);
  assert.equal(again.restored, 0); // already present → not duplicated
});

test('L4 binding cues: role / stance / procedure do not withhold', () => {
  for (const c of ['name', 'seat', 'affiliation', 'selftrait', 'style']) assert.ok(BINDING_CUES.has(c));
  for (const c of ['role', 'stance', 'procedure']) assert.ok(!BINDING_CUES.has(c));
});

test('runGate (mock, public mode): self-traits / referents / bound public org handled; synthetic (no publicContext) unchanged', async () => {
  const roster = [{ id: 'a', name: 'Dana Wills', org: 'Office of Housing', title: 'Director' }, { id: 'b', name: 'Lee Park', org: 'Riverton City Council', title: 'Councilmember' }];
  const lines = [
    { speakerId: 'a', text: 'Our department reviewed Council Bill 4410 and it meets the criteria.' },
    { speakerId: 'b', text: "I've lived here for 30 years and I support Council Bill 4410." },
  ];
  const on = await runGate({ roster, lines, lang: 'en' }, { llm: null, publicContext: ['Riverton City Council'] });
  const t = on.digest;
  assert.match(t, /Office of Housing/); // public bound entity kept as a topic subject
  assert.doesNotMatch(t, /\b[Oo]ur department\b|30 years|Dana|Wills|Lee Park/);
  assert.doesNotMatch(t, BAD);
  assert.match(t, /Council Bill 4410/);
  const off = await runGate({ roster, lines, lang: 'en' }, { llm: null });
  assert.doesNotMatch(off.digest, /Office of Housing/); // synthetic path: roster org still redacted everywhere
});

test("co-listed orgs: a list containing the speaker's own org binds every org item in it; titles / people are not orgs", () => {
  assert.deepEqual(coListedOrgs('I speak for change as well as the Unity League of Ohio, the Eastside Residents Council, Frontline Free News, and I will run.', ['Eastside Residents Council']), ['Unity League of Ohio', 'Frontline Free News']);
  assert.deepEqual(coListedOrgs('I am with the Eastside Residents Council, Councilmember Ortega, and Mayor Hall agrees.', ['Eastside Residents Council']), []);
  assert.deepEqual(coListedOrgs('The Unity League of Ohio, the Frontline Free News.', []), []);
});

test('person-shaped spans (given name / nickname ± surname) are recognised; places and items are not', () => {
  for (const s of ['Chris', 'Bob Dole', 'John Smith']) assert.ok(isPersonShaped(s), s);
  for (const s of ['Long Beach', 'Council Bill 5', 'Martin Luther King Boulevard']) assert.ok(!isPersonShaped(s), s);
});