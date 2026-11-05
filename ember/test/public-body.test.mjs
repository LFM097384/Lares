// Public-body mode (opt-in gate input publicContext, METHOD P3): shared context, civic record, partner orgs, thanked names.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { expandPublicContext, isSharedOrg, learnPartnerOrgs, titleBodies, detectAffiliation, tightFragments } from '../core/gate/l2.mjs';
import { redactPII, learnThirdNames, learnThirdNamesEn } from '../core/gate/l1.mjs';
import { civicSpans, civicStrong, eligible } from '../core/gate/shield.mjs';
import { runGate } from '../core/gate/gate.mjs';

const sh = expandPublicContext(['Denver City Council']);

test('expandPublicContext derives the jurisdiction and usual forms', () => {
  for (const x of ['Denver City Council', 'Denver', 'City of Denver', 'City and County of Denver', 'City Council']) assert.ok(sh.includes(x), x);
  assert.ok(isSharedOrg('Denver', sh));
  assert.ok(!isSharedOrg('East Denver Residents Council', sh));
  assert.deepEqual(expandPublicContext(null), []);
});

test('shared org fragments are not redacted; distinct orgs still are', () => {
  const roster = [{ id: 'a', name: 'Jolon Clark', org: 'Denver City Council' }, { id: 'b', name: 'Ann Lee', org: 'East Denver Residents Council' }];
  const on = detectAffiliation('The Denver Police Department, the City of Denver and East Denver Residents Council', roster, { shared: sh }).map((x) => x.match ?? x.text);
  assert.deepEqual(on.filter(Boolean).map(String).filter((x) => /Denver/.test(x)), ['East Denver Residents Council']);
  // unset → unchanged behaviour: the roster org fragment "Denver" is redacted
  const off = detectAffiliation('The Denver Police Department', roster).map((x) => String(x.match ?? x.text));
  assert.ok(off.includes('Denver'));
});

test('learnPartnerOrgs: first-person partner / contract / alongside contexts', () => {
  const got = learnPartnerOrgs('We will be working with the Office of Sustainability. We were able to work with the Arts Council. We have contracts with CBS. We rallied alongside Africa Town Community Land Trust.');
  assert.deepEqual(got, ['Office of Sustainability', 'Arts Council', 'CBS', 'Africa Town Community Land Trust']);
  // bound-only (v3): partners / contractors are topics; only representing / being here with / working at binds
  assert.deepEqual(learnPartnerOrgs('We have contracts with CBS. I am here on behalf of Greenleaf Neighbors Alliance. I work at Harbor Legal Aid.', { bound: true }), ['Greenleaf Neighbors Alliance', 'Harbor Legal Aid']);
  assert.deepEqual(learnPartnerOrgs('The committee works on housing.'), []);
  assert.deepEqual(titleBodies('Councilmember, chair of Sustainability and Renters Rights Committee'), ['Sustainability and Renters Rights Committee']);
  assert.ok(!tightFragments('Sustainability and Renters Rights Committee').has('Committee'));
  assert.ok(tightFragments('CBS Taco').has('CBS'));
});

test('thanked full names and titled member surnames are learned only in public-body mode, never titles / shared context', () => {
  const lines = ['I want to say thank you to Lynne Ferguson for her work. Thank you, Councilman Brooks. Thank you Denver Health.'];
  assert.deepEqual(learnThirdNamesEn(lines, { shared: sh }), ['Lynne Ferguson', 'Brooks']);
  assert.deepEqual(learnThirdNamesEn(['councilmembers Morales and Sewell abstained; Council President Pro Tem spoke.'], { shared: sh }), ['Morales', 'Sewell']);
  assert.deepEqual(learnThirdNames(lines), []); // unset → unchanged
});

test('public-record addresses / dates survive L1; personal ones do not', () => {
  assert.equal(redactPII('A bill designating 3435 Albion Street as a landmark.', [], { shared: sh }), 'A bill designating 3435 Albion Street as a landmark.');
  assert.match(redactPII("I am Bruce O'Donnell, 386 Emmerson Street.", [], { shared: sh }), /\[address\]/);
  assert.match(redactPII('I am a resident with an account at 6333 East Eliot Street.', [], { shared: sh }), /\[address\]/);
  assert.match(redactPII('A bill designating 3435 Albion Street as a landmark.'), /\[address\]/); // unset → unchanged
});

test('civic-record spans by shape', () => {
  const s = civicSpans('Council Bill 22, dash 209 passed. Nine ayes, two nays. The Denver Revised Municipal Code applies. 3649 East 40th Avenue.');
  for (const x of ['Council Bill 22, dash 209', 'Nine ayes, two nays', 'Denver Revised Municipal Code', '3649 East 40th Avenue']) assert.ok(s.includes(x), x);
  assert.ok(civicStrong('Nine ayes, two nays').includes('Nine ayes, two nays'));
  // a record shape may carry a comma, a free span may not; roster tokens still block
  assert.ok(eligible('Nine ayes, two nays', 'Nine ayes, two nays.', { toks: [], own: [], record: true }));
  assert.ok(!eligible('Nine ayes, two nays', 'Nine ayes, two nays.', { toks: [], own: [] }));
  assert.ok(!eligible('Council Bill 22', 'Council Bill 22', { toks: ['Bill'], own: [], record: true }));
});

test('runGate (mock) is unchanged without publicContext and accepts it when set', async () => {
  const roster = [{ id: 'a', name: 'Jolon Clark', org: 'Denver City Council', title: 'Councilmember' }];
  const transcript = { roster, lines: [{ speakerId: 'a', text: 'We will be working with the Office of Sustainability on the Denver plan.' }], lang: 'en' };
  const off = await runGate(transcript, { llm: null });
  const on = await runGate(transcript, { llm: null, publicContext: ['Denver City Council'] });
  const t = (r) => JSON.stringify(r.sections ?? r);
  // binding-aware (v3): an org the speaker works WITH is a topic and stays; a bound private org is generalised
  assert.match(t(on), /Office of Sustainability/);
  assert.match(t(on), /Denver/);
  const priv = await runGate({ roster, lines: [{ speakerId: 'a', text: "I'm here on behalf of Greenleaf Neighbors Alliance and we support the plan." }], lang: 'en' }, { llm: null, publicContext: ['Denver City Council'] });
  assert.doesNotMatch(t(priv), /Greenleaf/);
  assert.doesNotMatch(t(off), /Denver/);
});

test('public-body mode redacts seat vocatives and council districts; wrongLang detects script drift', async () => {
  const { wrongLang } = await import('../core/gate/l4.mjs');
  const x = 'Madam Secretary, roll call on Council Bill 689. Not only District one, but my district.';
  const on = redactPII(x, [], { shared: sh });
  assert.doesNotMatch(on, /Madam Secretary|District one|my district/);
  assert.match(on, /Council Bill 689/);
  assert.equal(redactPII(x), x); // unset → unchanged
  assert.ok(wrongLang('有观点指出这个法案应该通过', 'en'));
  assert.ok(!wrongLang('The bill passed nine to two.', 'en'));
  assert.ok(wrongLang('The bill passed nine to two.', 'zh'));
});

test('stripRecordAppendix removes only the Public record section', async () => {
  const { stripRecordAppendix } = await import('../bench/metrics.mjs');
  const s = stripRecordAppendix('# Digest\n\n## A\n- x\n\n## Public record\n- Figures: 3 cats.\n\n## B\n- y\n');
  assert.match(s, /## A[\s\S]*## B/);
  assert.doesNotMatch(s, /Public record|3 cats/);
});

test('a named unit inside a member org is learned as identifying (public-body mode)', async () => {
  const { subUnitsOf } = await import('../core/gate/l2.mjs');
  const roster = [{ id: 'm', name: 'A B', org: 'Department of Development Services' }];
  assert.deepEqual(subUnitsOf('The Office of Sustainability in the Department of Development Services worked with us.', roster, sh), ['Office of Sustainability']);
  assert.deepEqual(subUnitsOf('The Office of Sustainability in the City of Long Beach.', roster, sh), []);
});
