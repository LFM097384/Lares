import test from 'node:test';
import assert from 'node:assert/strict';
import { checkPort } from '../../ember/index.mjs';
import { jitsiPort, SELF_ID, ANNOUNCE } from '../port.mjs';
import { FakeBridge, tick } from './_util.mjs';

function setup(opts = {}) {
  const bridge = new FakeBridge();
  const port = jitsiPort(bridge, opts);
  const ev = [];
  for (const k of ['joined', 'left', 'name', 'message', 'disconnected', 'audio']) port.on(k, (...a) => ev.push([k, ...a]));
  return { bridge, port, ev };
}

test('shape: checkPort ok, selfId, transcripts false', () => {
  const { port } = setup();
  assert.doesNotThrow(() => checkPort(port));
  assert.equal(port.selfId, SELF_ID);
  assert.equal(port.transcripts, false);
});

test('participants() excludes hidden and self; isHuman', () => {
  const { bridge, port } = setup();
  bridge.participant('a', '张伟');
  bridge.participant('rec', 'Recorder', true);
  bridge.participant(SELF_ID, '炉灵');
  bridge.participant('b', '李秀梅');
  assert.deepEqual(port.participants(), [{ id: 'a', name: '张伟' }, { id: 'b', name: '李秀梅' }]);
  assert.equal(port.isHuman('a'), true);
  assert.equal(port.isHuman(SELF_ID), false);
  assert.equal(port.isHuman('rec'), false);
  assert.equal(port.isHuman(''), false);
  assert.equal(port.nameOf('a'), '张伟');
  assert.equal(port.nameOf('nobody'), '');
});

test('convenerName sorts that name first', () => {
  const { bridge, port } = setup({ convenerName: '王强' });
  bridge.participant('a', '张伟');
  bridge.participant('c', '王强');
  assert.equal(port.participants()[0].id, 'c');
});

test('join() joins the bridge and announces publicly once; leave idempotent', async () => {
  const { bridge, port } = setup();
  await port.join();
  await port.join();
  assert.equal(bridge.joins, 1);
  assert.equal(bridge.public.length, 1);
  assert.equal(bridge.public[0], ANNOUNCE);
  assert.match(bridge.public[0], /炉灵/);
  assert.match(bridge.public[0], /同意/);
  await port.leave();
  await port.leave();
  assert.equal(bridge.leaves, 1);
});

test('announce:false stays silent', async () => {
  const { bridge, port } = setup({ announce: false });
  await port.join();
  assert.equal(bridge.public.length, 0);
});

test('bridge events → port events: joined once, name, left, hidden ignored, disconnected', () => {
  const { bridge, port, ev } = setup();
  bridge.participant('a', '张伟');
  bridge.participant('a', '张伟'); // already present (e.g. re-announce)
  bridge.participant('rec', 'Recorder', true);
  bridge.rename('a', '张伟2');
  bridge.rename('rec', 'Rec2');
  bridge.rename('ghost', 'x');
  bridge.left('rec');
  bridge.left('ghost');
  bridge.left('a');
  bridge.disconnect('kicked');
  assert.deepEqual(ev, [['joined', 'a', '张伟'], ['name', 'a', '张伟2'], ['left', 'a'], ['disconnected', 'kicked']]);
  assert.deepEqual(port.participants(), []);
});

test('audio forwarded as (id, pcm, 16000, 1) only for present non-hidden', () => {
  const { bridge, ev } = setup();
  bridge.participant('a', '张伟');
  bridge.participant('rec', 'Recorder', true);
  const pcm = new Int16Array(160);
  bridge.audio('a', pcm, 16000);
  bridge.audio('rec', pcm, 16000);
  bridge.audio('stranger', pcm, 16000);
  bridge.fire('audio', 'a', pcm); // missing rate → 16000
  const au = ev.filter((e) => e[0] === 'audio');
  assert.equal(au.length, 2);
  assert.deepEqual(au[0], ['audio', 'a', pcm, 16000, 1]);
  assert.equal(au[1][3], 16000);
});

test('chat → protocol messages; custodial ack key; help & envelope errors are private', async () => {
  const { bridge, port, ev } = setup();
  bridge.participant('a', '张伟');
  bridge.chat('a', '普通聊天');
  bridge.chat('a', '@炉灵 同意');
  bridge.chat('a', '@炉灵 问 预算?');
  bridge.chat('a', '纪要', true);
  bridge.chat('a', '@炉灵 记忆');
  bridge.chat('a', '@炉灵 结束');
  bridge.chat(SELF_ID, '@炉灵 结束'); // own echo ignored
  await tick(5);
  const msgs = ev.filter((e) => e[0] === 'message').map((e) => e[2]);
  assert.equal(msgs[0].t, 'ack');
  assert.equal(Buffer.from(msgs[0].pubKey, 'base64').length, 32, 'raw Ed25519 public key');
  assert.deepEqual(msgs.slice(1), [{ t: 'ask', q: '预算?' }, { t: 'skill', name: 'minutes', args: {} }, { t: 'mem_list' }, { t: 'end' }]);
  assert.equal(port._debug().custodial, 1);
  bridge.chat('a', '@炉灵 帮助');
  bridge.chat('a', 'EMBER1 {"t":"ack"}'); // public envelope
  bridge.chat('a', 'EMBER1 {oops', true);
  bridge.chat('a', 'EMBER1 {"t":"wipe_everything"}', true);
  bridge.chat('a', '@炉灵 批准'); // no draft yet
  bridge.chat('a', '@炉灵 撤回 M9');
  await tick(5);
  const p = bridge.privTo('a');
  assert.ok(p.some((t) => t.includes('【炉灵 命令】')));
  assert.ok(p.some((t) => /只能私信/.test(t)));
  assert.ok(p.some((t) => /格式不对/.test(t)));
  assert.ok(p.some((t) => /不支持的操作/.test(t)));
  assert.ok(p.some((t) => /没有待批准的草稿/.test(t)));
  assert.ok(p.some((t) => /没有这条记忆/.test(t)));
  assert.equal(bridge.public.length, 0, 'nothing public from errors');
  assert.equal(ev.filter((e) => e[0] === 'message').length, 5, 'no extra protocol messages');
});

test('hidden participants cannot command', async () => {
  const { bridge, ev } = setup();
  bridge.participant('rec', 'Recorder', true);
  bridge.chat('rec', '@炉灵 同意');
  await tick(5);
  assert.equal(ev.filter((e) => e[0] === 'message').length, 0);
});

test('send(): answer/draft/mem private to acked present; state/approvals/released/ended public; error private', async () => {
  const { bridge, port } = setup();
  await port.join();
  bridge.participant('a', '张伟');
  bridge.participant('b', '李秀梅');
  bridge.participant('c', '王强');
  bridge.public.length = 0;
  const state = { t: 'state', sid: 's1', k: 2, members: [{ id: 'a', acked: true }, { id: 'b', acked: true }, { id: 'c', acked: false }], convenerId: 'a' };
  await port.send(state);
  await port.send(state); // same count → no repeat
  assert.deepEqual(bridge.public, ['炉灵:已同意 2 人 · 纪要放行需 2 人批准']);
  await port.send({ t: 'answer', q: 'Q', a: 'A' });
  assert.equal(bridge.privTo('a').length, 1);
  assert.equal(bridge.privTo('b').length, 1);
  assert.equal(bridge.privTo('c').length, 0);
  await port.send({ t: 'draft', draft: { draftId: 'uuid-1', draftHash: 'h', k: 2, items: [{ id: 'i1', kind: 'decision', topic: 'T', text: 'X', roleRisk: true }] } });
  assert.match(bridge.privTo('a').at(-1), /纪要草稿 D1/);
  assert.match(bridge.privTo('a').at(-1), /⚠/);
  assert.deepEqual(port._debug().drafts, ['D1']);
  await port.send({ t: 'approvals', draftId: 'uuid-1', count: 0, k: 2 });
  assert.equal(bridge.public.length, 1, 'count 0 not announced');
  await port.send({ t: 'approvals', draftId: 'uuid-1', count: 1, k: 2 });
  assert.match(bridge.public.at(-1), /D1 已获 1\/2 人批准,未放行/);
  await port.send({ t: 'released', draftId: 'uuid-1', text: 'RELEASED' });
  assert.match(bridge.public.at(-1), /已放行纪要 D1/);
  await port.send({ t: 'error', op: 'end', code: 'not_convener' }); // no toId → dropped
  await port.send({ t: 'error', op: 'end', code: 'not_convener' }, 'c');
  assert.match(bridge.privTo('c').at(-1), /只有召集人能散会/);
  await port.send({ t: 'mem', items: [{ id: 'it-1', kind: 'decision', text: 'MEMTEXT' }] }, 'a');
  assert.match(bridge.privTo('a').at(-1), /M1\. \[决定\] MEMTEXT/);
  await port.send({ t: 'mem_retracted', itemId: 'it-1' });
  assert.match(bridge.public.at(-1), /记忆 M1 已撤回/);
  await port.send({ t: 'ended', receipt: { sha256: 'abcdef0123456789zz', counts: { releases: 1 } } });
  assert.match(bridge.public.at(-1), /散会。放行 1 份纪要/);
  await port.send(null);
  await port.send({ t: 'unknown' });
  await port.leave();
});

test('notifyHost only passes metadata', () => {
  const host = [];
  const { port } = setup({ onHost: (e) => host.push(e) });
  port.notifyHost({ type: 'released', itemIds: ['x', 'y'] });
  port.notifyHost({ type: 'active', on: true });
  assert.deepEqual(host, [{ type: 'released', items: 2 }, { type: 'active', on: true }]);
});

test('bridge send failures are logged, not thrown', async () => {
  const logs = [];
  const bridge = new FakeBridge();
  bridge.sendPublic = async () => { throw new Error('boom'); };
  bridge.leave = async () => { throw new Error('gone'); };
  const port = jitsiPort(bridge, { log: (m) => logs.push(m) });
  await port.join();
  await port.leave();
  assert.ok(logs.some((l) => /公开聊天发送失败/.test(l)));
  assert.ok(logs.some((l) => /离会失败/.test(l)));
});
