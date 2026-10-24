import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { RtmsClient, rtmsSignature, backoffDelay, MEDIA } from '../rtms_client.mjs';
import { RtmsSim } from '../sim/rtms_sim.mjs';

const CID = 'cid_test', CSEC = 'csec_test';
const until = async (fn, ms = 5000, what = 'condition') => {
  const t0 = Date.now();
  while (!fn()) { if (Date.now() - t0 > ms) throw new Error(`timeout: ${what}`); await new Promise((r) => setTimeout(r, 5)); }
};
async function setup(t, simOpts = {}, clientOpts = {}) {
  const sim = await new RtmsSim({ clientId: CID, clientSecret: CSEC, keepAliveMs: 50, ...simOpts }).listen(0);
  const client = new RtmsClient({ clientId: CID, clientSecret: CSEC, meetingUuid: sim.meetingUuid, streamId: sim.streamId, serverUrls: sim.signalingUrl, backoff: { initialMs: 30, maxMs: 200 }, ...clientOpts });
  const seen = { transcript: [], join: [], leave: [], audio: [], stopped: [], reconnecting: [], speaker: [] };
  for (const k of Object.keys(seen)) client.on(k, (x) => seen[k].push(x));
  t.after(async () => { client.stop('test_end'); await sim.close(); });
  return { sim, client, seen };
}

test('signature + backoff schedule', () => {
  assert.equal(rtmsSignature('a', 'b', 'm', 's'), createHmac('sha256', 'b').update('a,m,s').digest('hex'));
  assert.match(rtmsSignature('a', 'b', 'm', 's'), /^[0-9a-f]{64}$/);
  assert.notEqual(rtmsSignature('a', 'b', 'm', 's'), rtmsSignature('a', 'b', 'm', 's2'));
  assert.deepEqual([0, 1, 2, 3, 4, 5, 9].map((n) => backoffDelay(n)), [3000, 6000, 12000, 24000, 30000, 30000, 30000]);
});

test('handshake order 1→2→3→4→7→5, events, transcripts, keep-alive on both sockets', async (t) => {
  const { sim, client, seen } = await setup(t);
  client.start();
  await client.waitReady(5000);
  await sim.waitReady();
  assert.equal(sim.stats.signalingHandshakes, 1);
  assert.equal(sim.stats.dataHandshakes, 1);
  assert.equal(sim.stats.readyAcks, 1);
  assert.deepEqual(sim.stats.subscriptions, [[3, 4, 2]]);
  assert.equal(sim.session.media.mediaType, MEDIA.TRANSCRIPT);
  sim.join([{ user_id: 101, user_name: '张伟' }, { user_id: 102, user_name: '李秀梅' }]);
  sim.say({ user_id: 101, user_name: '张伟', text: '你好' });
  sim.speaker({ user_id: 102, user_name: '李秀梅' });
  sim.leave([{ user_id: 102, user_name: '李秀梅' }]);
  await until(() => seen.leave.length === 1 && seen.transcript.length === 1 && seen.speaker.length === 1);
  assert.deepEqual(seen.join.map((p) => p.userId), ['101', '102']);
  assert.deepEqual(seen.transcript[0], { ...seen.transcript[0], userId: '101', userName: '张伟', text: '你好' });
  // 几轮心跳之后连接仍在,两条连接都回了 13
  await until(() => sim.stats.keepAliveReplies.signaling >= 3 && sim.stats.keepAliveReplies.media >= 3, 3000, 'keep-alive replies');
  assert.equal(sim.stats.keepAliveMissedDrops, 0);
  assert.deepEqual(sim.violations, []);
  assert.equal(seen.reconnecting.length, 0);
});

test('audio media type: 3 asks audio(1)+transcript(8) with L16 params; msg 14 decoded to Int16Array', async (t) => {
  const { sim, client, seen } = await setup(t, {}, { media: { transcript: true, audio: true } });
  client.start();
  await client.waitReady(5000);
  await sim.waitReady();
  assert.equal(sim.session.media.mediaType, MEDIA.AUDIO | MEDIA.TRANSCRIPT);
  sim.audio({ user_id: 7, user_name: 'x', pcm: Int16Array.from([1, -2, 300, -32768]) });
  await until(() => seen.audio.length === 1);
  assert.deepEqual([...seen.audio[0].pcm], [1, -2, 300, -32768]);
  assert.equal(seen.audio[0].sampleRate, 16000);
  assert.deepEqual(sim.violations, []);
});

test('bad signature → status 3 → stopped (no retry storm)', async (t) => {
  const { sim, client, seen } = await setup(t);
  sim.failures.badSignature = true;
  client.start();
  await assert.rejects(client.waitReady(5000), /stopped/);
  assert.equal(seen.stopped[0].reason, 'signaling_handshake_failed');
  assert.equal(seen.stopped[0].statusCode, 3);
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(sim.stats.connections, 1);
  assert.equal(seen.reconnecting.length, 0);
});

test('wrong client secret is rejected by the sim', async (t) => {
  const { client, seen } = await setup(t, {}, { clientSecret: 'wrong' });
  client.start();
  await assert.rejects(client.waitReady(5000));
  assert.equal(seen.stopped[0].statusCode, 3);
});

test('dropped media connection mid-stream → backoff → full re-handshake → stream continues', async (t) => {
  const { sim, client, seen } = await setup(t);
  client.start();
  await client.waitReady();
  await sim.waitReady();
  sim.join([{ user_id: 1, user_name: 'A' }]);
  sim.say({ user_id: 1, user_name: 'A', text: 'before' });
  await until(() => seen.transcript.length === 1);
  sim.drop('media');
  await until(() => seen.reconnecting.length === 1, 3000, 'reconnecting');
  assert.equal(seen.reconnecting[0].delayMs, 30);
  await until(() => sim.stats.readyAcks === 2, 5000, 'second ready');
  await sim.waitReady();
  sim.say({ user_id: 1, user_name: 'A', text: 'after' });
  await until(() => seen.transcript.length === 2);
  assert.equal(seen.transcript[1].text, 'after');
  assert.equal(sim.stats.signalingHandshakes, 2);
  assert.equal(client.connects, 2);
  assert.equal(seen.stopped.length, 0);
  assert.deepEqual(sim.violations, []);
});

test('backoff doubles while the server stays down, resets after success', async (t) => {
  const { sim, client, seen } = await setup(t);
  client.start();
  await client.waitReady();
  sim.failures.badSignature = false;
  // 让信令连上就被掐:关掉 sim 的握手(直接 terminate 每条新连接)
  const realOn = sim._onConn.bind(sim);
  sim._onConn = (ws) => { ws.terminate(); };
  sim.drop('signaling');
  await until(() => seen.reconnecting.length >= 4, 5000, 'several retries');
  assert.deepEqual(seen.reconnecting.slice(0, 4).map((r) => r.delayMs), [30, 60, 120, 200]);
  sim._onConn = realOn;
  await until(() => client.connects === 2, 5000, 'recovered');
  assert.equal(client.attempt, 0);
});

test('keep-alive: client that stops answering is dropped by sim; client watchdog redoes handshake', async (t) => {
  const { sim, client, seen } = await setup(t, { keepAliveMs: 30, maxMissed: 3 }, { keepAliveTimeoutMs: 400 });
  client.start();
  await client.waitReady();
  // 让客户端不回 13:拦截 _send
  const orig = client._send.bind(client);
  client._send = (ws, obj) => { if (obj.msg_type === 13) return; orig(ws, obj); };
  await until(() => sim.stats.keepAliveMissedDrops >= 1, 3000, 'sim drop');
  client._send = orig;
  await until(() => client.connects >= 2, 5000, 'reconnected');
  assert.ok(seen.reconnecting.length >= 1);

  // 服务器不再发 12:客户端 65 s(此处 400 ms)看门狗触发重握手
  const before = client.connects;
  for (const c of sim.conns) clearInterval(c.ka);
  sim._startKeepAlive = () => {};
  await until(() => seen.reconnecting.some((r) => r.why === 'keepalive_timeout'), 3000, 'watchdog');
  await until(() => client.connects > before, 3000, 'rehandshake');
});

test('session stop (msg 9, state 5) with stop reason → stopped, no reconnect', async (t) => {
  const { sim, client, seen } = await setup(t);
  client.start();
  await client.waitReady();
  sim.stop(6);
  await until(() => seen.stopped.length === 1);
  assert.equal(seen.stopped[0].reason, 'session_stopped');
  assert.equal(seen.stopped[0].stopReason, 6);
  assert.equal(seen.stopped[0].stopReasonName, 'MEETING_ENDED');
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(seen.reconnecting.length, 0);
});

test('client.stop sends STREAM_CLOSE_REQ and goes quiet', async (t) => {
  const { sim, client, seen } = await setup(t);
  client.start();
  await client.waitReady();
  client.stop('bye');
  await until(() => sim.stats.closeReqs === 1);
  assert.equal(seen.stopped[0].reason, 'bye');
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(seen.reconnecting.length, 0);
});
