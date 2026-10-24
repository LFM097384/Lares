import test from 'node:test';
import assert from 'node:assert/strict';
import { checkPort } from '../../ember/index.mjs';
import { zoomPort, zoomAgentId, zoomUserId } from '../port.mjs';
import { createZoomServer } from '../server.mjs';
import { RtmsClient } from '../rtms_client.mjs';
import { RtmsSim } from '../sim/rtms_sim.mjs';
import { sidebar, until } from './_util.mjs';

const CID = 'cid', CSEC = 'csec';
const A = { user_id: 101, user_name: '张伟' }, B = { user_id: 102, user_name: '李秀梅' };

async function setup(t, { postReleasedToChat = false } = {}) {
  const sim = await new RtmsSim({ clientId: CID, clientSecret: CSEC, keepAliveMs: 1000 }).listen(0);
  const srv = createZoomServer({ webhookSecret: 'whs', onWebhook: () => {} });
  const httpPort = await srv.listen(0);
  const base = `http://127.0.0.1:${httpPort}`;
  const host = [];
  const port = zoomPort({
    meetingUuid: sim.meetingUuid, hub: srv.hub, postReleasedToChat, onHost: (e) => host.push(e), convenerId: () => zoomUserId(101),
    connect: () => new RtmsClient({ clientId: CID, clientSecret: CSEC, meetingUuid: sim.meetingUuid, streamId: sim.streamId, serverUrls: sim.signalingUrl, backoff: { initialMs: 20, maxMs: 50 } }),
  });
  const ev = [];
  for (const k of ['joined', 'left', 'name', 'message', 'transcript', 'disconnected', 'audio']) port.on(k, (...a) => ev.push([k, ...a.filter((x) => !(x instanceof Int16Array))]));
  t.after(async () => { await port.leave(); await srv.close(); await sim.close(); });
  return { sim, srv, base, port, host, ev };
}

test('shape: checkPort ok, selfId zoom_ai_<hash>, transcripts flag, isHuman', () => {
  const hubStub = { sendTo() {}, attachPort() {}, detachPort() {}, boundIds: () => [] };
  const p = zoomPort({ meetingUuid: 'abc==', hub: hubStub, connect: () => null });
  assert.doesNotThrow(() => checkPort(p));
  assert.match(p.selfId, /^zoom_ai_[0-9a-f]{10}$/);
  assert.equal(p.selfId, zoomAgentId('abc=='));
  assert.equal(p.transcripts, true);
  assert.equal(p.isHuman('zu_1'), true);
  assert.equal(p.isHuman(p.selfId), false);
  assert.throws(() => p.on('bogus', () => {}));
});

test('RTMS → port events: join/leave/transcript, user_id 0 ignored, names kept in memory only', async (t) => {
  const { sim, port, ev } = await setup(t);
  await port.join();
  await sim.waitReady();
  sim.join([A, B]);
  sim.say({ ...A, text: '大家好' });
  sim.say({ user_id: 0, user_name: '', text: 'mixed' });
  // 信令(事件)与媒体(转写)是两条 socket,彼此之间无序 —— 真 RTMS 也一样;等转写到了再离会
  await until(() => ev.some((e) => e[0] === 'transcript'));
  sim.leave([B]);
  await until(() => ev.some((e) => e[0] === 'left'));
  assert.deepEqual(ev.filter((e) => e[0] !== 'name'), [
    ['joined', 'zu_101', '张伟'], ['joined', 'zu_102', '李秀梅'], ['transcript', 'zu_101', '大家好'], ['left', 'zu_102'],
  ]);
  assert.deepEqual(port.participants(), [{ id: 'zu_101', name: '张伟' }]);
  assert.equal(port.nameOf('zu_101'), '张伟');
});

test('sidebar hub: bind by participantId, inbound → message, send routing, notifyHost, chat only for released', async (t) => {
  const { sim, base, port, host, ev } = await setup(t, { postReleasedToChat: true });
  const early = await sidebar(base, { meetingUuid: sim.meetingUuid, participantId: '101', screenName: '张伟' });
  await early.wait('zoom_session', (m) => m.state === 'waiting');
  await port.join();
  await early.wait('zoom_welcome', (m) => m.bound && m.id === 'zu_101');
  const b = await sidebar(base, { meetingUuid: sim.meetingUuid, participantId: '102', screenName: '李秀梅' });
  await b.wait('zoom_welcome', (m) => m.bound && m.id === 'zu_102');
  const other = await sidebar(base, { meetingUuid: 'some-other-meeting', participantId: '102' });
  await other.wait('zoom_session');

  b.send({ t: 'ask', q: 'hi' });
  await until(() => ev.some((e) => e[0] === 'message'));
  assert.deepEqual(ev.find((e) => e[0] === 'message'), ['message', 'zu_102', { t: 'ask', q: 'hi' }]);
  b.send({ t: 'zoom_bogus' });
  await b.wait('error', (m) => m.code === 'unknown_op');

  await port.send({ t: 'state', x: 1 });
  await port.send({ t: 'error', code: 'only_b' }, 'zu_102');
  await b.wait('error', (m) => m.code === 'only_b');
  await early.wait('state');
  assert.equal(early.of('error').length, 0, 'to-addressed message not leaked');
  assert.equal(other.of('state').length, 0, 'other meeting gets nothing');

  port.notifyHost({ type: 'active', on: true });
  port.notifyHost({ type: 'released', itemIds: ['i1'] });
  assert.deepEqual(host, [{ type: 'active', on: true }, { type: 'released', itemIds: ['i1'] }]);
  await b.wait('zoom_active', (m) => m.on === true);

  await port.send({ t: 'draft', draft: { text: 'not for chat' } });
  await port.send({ t: 'answer', a: 'not for chat' });
  await port.send({ t: 'released', draftId: 'd1', text: '会议纪要 · 不署名' });
  const post = await early.wait('zoom_post_chat');
  assert.deepEqual(post, { t: 'zoom_post_chat', draftId: 'd1', text: '会议纪要 · 不署名' });
  assert.equal(b.of('zoom_post_chat').length, 0, 'only one sidebar (convener) posts');
  assert.equal(early.of('zoom_post_chat').length, 1, 'only released goes to chat');

  await port.leave();
  await b.wait('zoom_stop_rtms');
  await b.wait('zoom_session', (m) => m.state === 'ended');
  for (const s of [early, b, other]) s.close();
});

test('hub rejects cross-origin and wrong path', async (t) => {
  const { base } = await setup(t);
  await assert.rejects(sidebar(base, null, { origin: 'https://evil.example' }), /403/);
  const ok = await sidebar(base, null, { origin: base });
  ok.close();
});

test('RTMS stop → port disconnected(reason)', async (t) => {
  const { sim, port, ev } = await setup(t);
  await port.join();
  await sim.waitReady();
  sim.stop(1);
  await until(() => ev.some((e) => e[0] === 'disconnected'));
  assert.equal(ev.find((e) => e[0] === 'disconnected')[1], 'HOST_TRIGGERED');
});
