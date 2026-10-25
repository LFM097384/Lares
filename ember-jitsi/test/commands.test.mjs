import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCommand, HELP, BOT_NAME, ENVELOPE } from '../commands.mjs';

test('public chat without a mention is ignored', () => {
  assert.equal(parseCommand('大家好,今天讨论预算'), null);
  assert.equal(parseCommand('同意'), null);
  assert.equal(parseCommand(''), null);
  assert.equal(parseCommand('   '), null);
  assert.equal(parseCommand(null), null);
  assert.equal(parseCommand('我觉得炉灵很好'), null, 'mention must be at the start');
});

test('mention forms: @ / full-width ＠ / 「炉灵，」 / @Ember', () => {
  assert.deepEqual(parseCommand('@炉灵 同意'), { cmd: 'ack' });
  assert.deepEqual(parseCommand('＠炉灵 问 x'), { cmd: 'ask', q: 'x' });
  assert.deepEqual(parseCommand('炉灵，纪要'), { cmd: 'minutes' });
  assert.deepEqual(parseCommand('炉灵: 纪要'), { cmd: 'minutes' });
  assert.deepEqual(parseCommand('@Ember approve d1'), { cmd: 'approve', draft: 'D1' });
  assert.deepEqual(parseCommand('@ember ack'), { cmd: 'ack' });
  assert.deepEqual(parseCommand('\u200b@炉灵 同意'), { cmd: 'ack' }, 'zero-width space stripped');
  assert.deepEqual(parseCommand('@炉灵'), { cmd: 'help' });
  assert.deepEqual(parseCommand('@炉灵 帮助'), { cmd: 'help' });
});

test('approve / retract / review / mem / end', () => {
  assert.deepEqual(parseCommand('@炉灵 批准'), { cmd: 'approve', draft: null });
  assert.deepEqual(parseCommand('@炉灵 批准 D2'), { cmd: 'approve', draft: 'D2' });
  assert.deepEqual(parseCommand('@炉灵 撤回 m2'), { cmd: 'mem_retract', item: 'M2' });
  assert.deepEqual(parseCommand('@炉灵 撤回'), { cmd: 'help' });
  assert.deepEqual(parseCommand('@炉灵 泛化 D1 2'), { cmd: 'review', action: 'generalise', draft: 'D1', item: 2 });
  assert.deepEqual(parseCommand('@炉灵 保留 1'), { cmd: 'review', action: 'keep', draft: null, item: 1 });
  assert.deepEqual(parseCommand('@炉灵 删除 d3 4'), { cmd: 'review', action: 'cut', draft: 'D3', item: 4 });
  assert.deepEqual(parseCommand('@炉灵 泛化 D1'), { cmd: 'help' }, 'review needs an item number');
  assert.deepEqual(parseCommand('@炉灵 记忆'), { cmd: 'mem_list' });
  assert.deepEqual(parseCommand('@炉灵 结束'), { cmd: 'end' });
  assert.deepEqual(parseCommand('@炉灵 散会'), { cmd: 'end' });
  assert.deepEqual(parseCommand('@炉灵 问'), { cmd: 'help' });
});

test('bare mention with a question → ask', () => {
  assert.deepEqual(parseCommand('@炉灵 今天说了啥'), { cmd: 'ask', q: '今天说了啥' });
});

test('private (direct) messages need no mention', () => {
  assert.deepEqual(parseCommand('同意', { direct: true }), { cmd: 'ack' });
  assert.deepEqual(parseCommand('批准 D1', { direct: true }), { cmd: 'approve', draft: 'D1' });
  assert.deepEqual(parseCommand('今天说了啥', { direct: true }), { cmd: 'ask', q: '今天说了啥' });
  assert.deepEqual(parseCommand('@炉灵 纪要', { direct: true }), { cmd: 'minutes' });
});

test('EMBER1 envelope: private only, JSON + shape checked', () => {
  assert.deepEqual(parseCommand('EMBER1 {"t":"ack","pubKey":"x"}', { direct: true }), { cmd: 'envelope', msg: { t: 'ack', pubKey: 'x' } });
  assert.deepEqual(parseCommand('EMBER1{"t":"end"}', { direct: true }), { cmd: 'envelope', msg: { t: 'end' } });
  assert.deepEqual(parseCommand('EMBER1 {"t":"ack"}'), { cmd: 'bad_envelope', why: 'public' });
  assert.deepEqual(parseCommand('EMBER1 {not json', { direct: true }), { cmd: 'bad_envelope', why: 'json' });
  assert.deepEqual(parseCommand('EMBER1 {"x":1}', { direct: true }), { cmd: 'bad_envelope', why: 'shape' });
  assert.deepEqual(parseCommand('EMBER1 [1]', { direct: true }), { cmd: 'bad_envelope', why: 'shape' });
});

test('HELP mentions the bot and the core commands', () => {
  assert.equal(BOT_NAME, '炉灵');
  assert.equal(ENVELOPE, 'EMBER1');
  for (const w of ['同意', '问', '纪要', '批准', '撤回', '结束']) assert.ok(HELP.includes(w), w);
});
