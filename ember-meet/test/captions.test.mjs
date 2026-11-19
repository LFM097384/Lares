import test from 'node:test';
import assert from 'node:assert/strict';
import { CaptionTracker, normalizeName, tailAfter } from '../captions.mjs';

const mk = (o = {}) => { const got = []; const t = new CaptionTracker({ onFinal: (u) => got.push(u), ...o }); return { t, got }; };
const S = (key, speaker, text) => ({ key, speaker, text });

test('normalizeName strips guest suffixes and invisible chars', () => {
  assert.equal(normalizeName('Alice (Guest)'), 'Alice');
  assert.equal(normalizeName('测试用户（访客）'), '测试用户');
  assert.equal(normalizeName('\u200bBob  Smith (Unverified) (External)'), 'Bob Smith');
  assert.equal(normalizeName('  炉灵 '), '炉灵');
  assert.equal(normalizeName(null), '');
});

test('partial updates of the last caption are emitted once when stable', () => {
  const { t, got } = mk();
  t.update([S('a', 'Alice', 'Hello')], 0);
  t.update([S('a', 'Alice', 'Hello every')], 500);
  t.update([S('a', 'Alice', 'Hello everyone, welcome')], 1000);
  assert.equal(got.length, 0);
  t.tick(4000); // 3000ms since last change < 3500
  assert.equal(got.length, 0);
  t.tick(4600);
  assert.deepEqual(got.map((u) => [u.speaker, u.text, u.reason]), [['Alice', 'Hello everyone, welcome', 'stable']]);
  t.tick(10_000);
  assert.equal(got.length, 1, 'no re-emission');
});

test('a superseded caption finalises after supersededMs, multiple speakers keep attribution', () => {
  const { t, got } = mk();
  t.update([S('a', 'Alice', 'We should ship on Friday')], 0);
  t.update([S('a', 'Alice', 'We should ship on Friday.'), S('b', 'Bob (Guest)', 'I')], 300);
  t.update([S('a', 'Alice', 'We should ship on Friday.'), S('b', 'Bob (Guest)', 'I disagree')], 1000);
  assert.equal(got.length, 0);
  t.update([S('a', 'Alice', 'We should ship on Friday.'), S('b', 'Bob (Guest)', 'I disagree, Monday')], 1600);
  assert.deepEqual(got.map((u) => [u.speaker, u.text, u.reason]), [['Alice', 'We should ship on Friday.', 'superseded']]);
  t.tick(5200);
  assert.deepEqual(got.map((u) => u.speaker), ['Alice', 'Bob']);
  assert.equal(got[1].text, 'I disagree, Monday');
});

test('growth after emission yields only the new tail; rewrites are dropped', () => {
  const { t, got } = mk();
  t.update([S('a', 'Alice', 'First part')], 0);
  t.tick(4000);
  assert.equal(got.at(-1).text, 'First part');
  t.update([S('a', 'Alice', 'First part, and the second part')], 5000);
  t.tick(9000);
  assert.equal(got.at(-1).text, 'and the second part');
  t.update([S('a', 'Alice', 'Totally different wording now')], 10_000);
  t.tick(20_000);
  assert.equal(got.length, 2);
  assert.equal(t.stats.rewrites, 1);
  assert.equal(t.stats.deltas, 1);
});

test('re-rendered node (new key, same text) is adopted, not duplicated', () => {
  const { t, got } = mk();
  t.update([S('n1', 'Alice', 'Budget is two hundred')], 0);
  t.update([], 400); // removed (virtual list re-render)
  t.update([S('n9', 'Alice', 'Budget is two hundred thousand')], 600);
  t.tick(5000);
  assert.deepEqual(got.map((u) => u.text), ['Budget is two hundred thousand']);
  assert.equal(t.stats.adopted, 1);
});

test('caption scrolled out of the window is finalised as gone', () => {
  const { t, got } = mk();
  t.update([S('a', 'Alice', 'Short lived line'), S('b', 'Bob', 'next')], 0);
  t.update([S('b', 'Bob', 'next one')], 200);
  t.tick(1500);
  assert.deepEqual(got.map((u) => [u.text, u.reason]), [['Short lived line', 'gone']]);
});

test('ignores own name, empty speakers, too-short text, recent duplicates; flush emits rest', () => {
  const { t, got } = mk({ ignoreSpeakers: ['炉灵'] });
  t.update([S('a', '炉灵', 'I am the bot'), S('b', '', 'nobody'), S('c', 'Alice', '嗯'), S('d', 'Alice', 'ok then')], 0);
  t.tick(5000);
  assert.deepEqual(got.map((u) => u.text), ['ok then']);
  t.update([S('e', 'Alice', 'OK then.')], 6000);
  t.tick(12_000);
  assert.equal(got.length, 1, 'punctuation/case variant is a dupe');
  t.update([S('f', 'Bob', 'pending words')], 13_000);
  const flushed = t.flush(13_100);
  assert.deepEqual(flushed.map((u) => [u.speaker, u.reason]), [['Bob', 'flush']]);
});

test('speaker change inside the same node updates attribution', () => {
  const { t, got } = mk();
  t.update([S('a', '', 'hello')], 0);
  t.update([S('a', 'Carol', 'hello there')], 100);
  t.tick(5000);
  assert.equal(got[0].speaker, 'Carol');
});

test('tailAfter ignores punctuation differences', () => {
  assert.equal(tailAfter('Hello, world. And more', 'Hello world'), 'And more');
  assert.equal(tailAfter('预算是两百万,下周交付', '预算是两百万'), '下周交付');
  assert.equal(tailAfter('abc', 'abc'), '');
});
