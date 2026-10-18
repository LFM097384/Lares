import test from 'node:test';
import assert from 'node:assert/strict';
import { verify } from '../lib/l4.mjs';
import { scoreOutsider } from '../eval/judge.mjs';

const roster = [{ id: 'p1', name: '王建国', aliases: ['老王'], org: '某某研究院', title: '研究员' }, { id: 'p2', name: 'Sarah Whitfield', aliases: ['Sarah'], org: 'Hollis Family Trust', title: 'Program Officer' }];

test('L4 returns claim objects; residual risk marks role-revealing instead of dropping silently', async () => {
  const r = await verify([{ topic: 'T', claims: ['利率可能下调。'] }], roster, { mock: true, maxRounds: 2 });
  const c = r.sections[0].claims[0];
  assert.equal(typeof c, 'object');
  assert.equal(c.text, '利率可能下调。');
  assert.equal(c.risk, undefined);
  assert.equal(typeof r.residual, 'number');
});

test('outsider scoring: exact/fuzzy names and org fragments', () => {
  const ideas = [{ id: 'i1', owner: 'p2' }, { id: 'i2', owner: 'p1' }];
  const s = scoreOutsider(roster, ideas, { attendees: [{ name: 'Sarah W.', org: 'unknown' }, { name: 'unknown', org: 'Hollis Trust' }, { name: '张三', org: 'unknown' }], speakers: [{ ideaId: 'i1', name: 'Sarah', org: 'unknown' }, { ideaId: 'i2', name: 'unknown', org: 'unknown' }] });
  assert.equal(s.people, 1);
  assert.equal(s.exposed, 1);
  assert.equal(s.speakerHits, 1);
  const none = scoreOutsider(roster, ideas, { attendees: [{ name: 'a participant', org: 'an organisation' }], speakers: [] });
  assert.equal(none.exposed, 0);
});
