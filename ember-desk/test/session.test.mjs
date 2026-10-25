import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { testDaemon, req, waitFor, tmpDir } from './helpers.mjs';

const LINK = 'https://localhost:8443/DeskTest';

test('lifecycle: joining → in-meeting → (leave via stdin) → ended → idle; feed + toast relay', async (t) => {
  const dir = tmpDir(t);
  const argsFile = path.join(dir, 'args.json');
  const d = await testDaemon(t, { dir, env: { FAKE_ARGS_FILE: argsFile } });
  const states = [];
  d.app.subscribe((type, data) => { if (type === 'session') states.push(data.state); });
  const j = await req(d, 'POST', '/join', { body: { link: LINK, k: 2, convenerName: '张伟' } });
  assert.equal(j.status, 200);
  assert.equal(j.body.state, 'joining');
  assert.equal(j.body.adapter, 'jitsi');
  assert.equal(j.body.room, 'desktest');
  await waitFor(async () => (await req(d, 'GET', '/status')).body.state === 'in-meeting');
  const st = (await req(d, 'GET', '/status')).body;
  assert.equal(st.session.state, 'in-meeting');
  assert.ok(st.session.events.includes('ready'));
  const args = JSON.parse(readFileSync(argsFile, 'utf8')).argv;
  assert.deepEqual(args.slice(0, 6), ['--room', 'desktest', '--url', 'https://localhost:8443', '--asr', 'none']);
  assert.ok(args.join(' ').includes('--k 2'));
  assert.ok(args.join(' ').includes('--convener-name 张伟'));
  assert.equal((await req(d, 'POST', '/join', { body: { link: LINK } })).status, 409);
  const mc = (await req(d, 'GET', '/channels')).body.find((c) => c.id === 'meeting-chat');
  assert.match(mc.detail, /会议中/);
  const l = await req(d, 'POST', '/leave', { body: {} });
  assert.equal(l.status, 200);
  assert.equal(l.body.session.state, 'ended');
  assert.equal(l.body.session.exitCode, 0);
  assert.ok(l.body.session.events.includes('released'));
  assert.equal(l.body.session.released, 2);
  const after = (await req(d, 'GET', '/status')).body;
  assert.equal(after.state, 'idle');
  assert.equal(after.session, null);
  assert.equal(after.lastSession.state, 'ended');
  const kinds = (await req(d, 'GET', '/feed?n=20')).body.map((i) => i.kind);
  assert.deepEqual(kinds, ['meeting_joined', 'released', 'meeting_ended']);
  const feedText = JSON.stringify((await req(d, 'GET', '/feed?n=20')).body);
  assert.match(feedText, /放行了 2 条纪要/);
  await waitFor(() => d.toastCalls.length >= 1);
  assert.match(d.toastCalls[0].payload.title, /进会/);
  assert.ok(states.includes('joining') && states.includes('in-meeting') && states.includes('ended'));
  // 再次 leave:无会议
  assert.equal((await req(d, 'POST', '/leave')).body.ok, true);
});

test('failed: plugin errors before ready → failed → idle', async (t) => {
  const d = await testDaemon(t, { fakeMode: 'fail' });
  await req(d, 'POST', '/join', { body: { link: LINK } });
  const st = await waitFor(async () => { const s = (await req(d, 'GET', '/status')).body; return s.state === 'idle' && s.lastSession ? s : null; });
  assert.equal(st.lastSession.state, 'failed');
  assert.equal(st.lastSession.exitCode, 1);
  assert.match(st.lastSession.error, /boom/);
  assert.equal((await req(d, 'GET', '/feed')).body.at(-1).kind, 'meeting_failed');
});

test('failed: crash after ready (exit 1) → failed; exit 0 without ready → failed', async (t) => {
  const d = await testDaemon(t, { fakeMode: 'crash' });
  await req(d, 'POST', '/join', { body: { link: LINK } });
  const st = await waitFor(async () => { const s = (await req(d, 'GET', '/status')).body; return s.state === 'idle' && s.lastSession ? s : null; });
  assert.equal(st.lastSession.state, 'failed');
  assert.ok(st.lastSession.events.includes('ready'));
  const d2 = await testDaemon(t, { fakeMode: 'noready' });
  await req(d2, 'POST', '/join', { body: { link: LINK } });
  const st2 = await waitFor(async () => { const s = (await req(d2, 'GET', '/status')).body; return s.lastSession ? s : null; });
  assert.equal(st2.lastSession.state, 'failed');
});

test('leave force-kills after timeout when the plugin ignores stop', async (t) => {
  const d = await testDaemon(t, { fakeMode: 'hang', stopTimeoutMs: 400 });
  await req(d, 'POST', '/join', { body: { link: LINK } });
  await waitFor(async () => (await req(d, 'GET', '/status')).body.state === 'in-meeting');
  const t0 = Date.now();
  const l = await req(d, 'POST', '/leave');
  assert.ok(Date.now() - t0 >= 350);
  assert.equal(l.body.session.state, 'ended');
  assert.match(l.body.session.error, /强制/);
  assert.equal((await req(d, 'GET', '/status')).body.state, 'idle');
});

test('daemon stop while in a meeting stops the child cleanly', async (t) => {
  const d = await testDaemon(t);
  await req(d, 'POST', '/join', { body: { link: LINK } });
  await waitFor(async () => (await req(d, 'GET', '/status')).body.state === 'in-meeting');
  const pid = d.sessions.child.pid;
  await d.stop();
  assert.equal(d.sessions.lastSession.state, 'ended');
  assert.throws(() => process.kill(pid, 0));
});
