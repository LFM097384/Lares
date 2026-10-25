import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { testDaemon, req } from './helpers.mjs';
import { tokenOk, hostOk } from '../api.mjs';

test('auth: 401 without / with wrong token, 200 with the right one', async (t) => {
  const d = await testDaemon(t);
  assert.match(d.token, /^[0-9a-f]{64}$/);
  assert.deepEqual(await req(d, 'GET', '/status', { token: null }), { status: 401, body: { error: 'unauthorized', message: 'unauthorized' } });
  assert.equal((await req(d, 'GET', '/status', { token: 'f'.repeat(64) })).status, 401);
  assert.equal((await req(d, 'GET', '/status', { token: d.token.slice(0, 10) })).status, 401);
  assert.equal((await req(d, 'GET', '/status', { token: null, headers: { authorization: `Basic ${d.token}` } })).status, 401);
  assert.equal((await req(d, 'POST', '/quit', { token: 'x' })).status, 401);
  const ok = await req(d, 'GET', '/status');
  assert.equal(ok.status, 200);
  assert.equal(ok.body.ok, true);
  assert.equal(ok.body.name, '炉灵');
  assert.equal(ok.body.state, 'idle');
  assert.equal(ok.body.session, null);
  assert.ok(Array.isArray(ok.body.channels));
  assert.ok(tokenOk(`Bearer ${d.token}`, d.token));
  assert.ok(!tokenOk(undefined, d.token));
});

test('Host header guard (DNS rebinding)', async (t) => {
  const d = await testDaemon(t);
  const raw = (host) => new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port: d.port, path: '/status', headers: { host, authorization: `Bearer ${d.token}` } }, (res) => { res.resume(); resolve(res.statusCode); });
    r.on('error', reject); r.end();
  });
  assert.equal(await raw(`127.0.0.1:${d.port}`), 200);
  assert.equal(await raw(`localhost:${d.port}`), 200);
  assert.equal(await raw(`evil.example:${d.port}`), 403);
  assert.equal(await raw('127.0.0.1'), 403);
  assert.equal(await raw(`127.0.0.1:${d.port + 1}`), 403);
  assert.ok(hostOk('LOCALHOST:5', 5));
});

test('POST must be JSON, body limit 64KB, /ui has no auth and no data', async (t) => {
  const d = await testDaemon(t);
  assert.equal((await req(d, 'POST', '/ask', { raw: 'text=hi', headers: { 'content-type': 'application/x-www-form-urlencoded' } })).status, 415);
  assert.equal((await req(d, 'POST', '/ask', { raw: '{"text":"hi"}', headers: { 'content-type': 'text/plain' } })).status, 415);
  assert.equal((await req(d, 'POST', '/ask', { raw: '{bad', headers: { 'content-type': 'application/json' } })).status, 400);
  assert.equal((await req(d, 'POST', '/ask', { raw: JSON.stringify({ text: 'x'.repeat(70_000) }), headers: { 'content-type': 'application/json' } })).status, 413);
  const ui = await req(d, 'GET', '/ui', { token: null });
  assert.equal(ui.status, 200);
  assert.match(ui.body, /炉灵/);
  assert.ok(!ui.body.includes(d.token));
  assert.equal((await req(d, 'GET', '/nope')).status, 404);
});

test('ask (mock without key), speak (stubbed SAPI), feed, channels start/stop persists config', async (t) => {
  const d = await testDaemon(t);
  const a = await req(d, 'POST', '/ask', { body: { text: '今天几号' } });
  assert.equal(a.status, 200);
  assert.equal(a.body.llm, false);
  assert.match(a.body.answer, /mock/);
  assert.equal((await req(d, 'POST', '/ask', { body: { text: '  ' } })).status, 400);
  const s = await req(d, 'POST', '/speak', { body: { text: '你好"; calc; "' } });
  assert.deepEqual(s.body, { ok: true, engine: 'sapi' });
  assert.equal(d.ttsCalls.length, 1);
  assert.equal(d.ttsCalls[0].payload.text, '你好"; calc; "');
  assert.ok(!d.ttsCalls[0].script.includes('calc'), 'user text never interpolated into script');
  const f = await req(d, 'GET', '/feed?n=5');
  assert.equal(f.body.at(-1).kind, 'answer');
  assert.ok(f.body.at(-1).at);
  const on = await req(d, 'POST', '/channels/tts/start', { body: {} });
  assert.equal(on.body.running, true);
  assert.equal(on.body.enabled, true);
  const { readJson } = await import('../config.mjs');
  assert.ok(readJson(`${d.dir}/config.json`).enabledChannels.includes('tts'));
  const off = await req(d, 'POST', '/channels/tts/stop');
  assert.equal(off.body.enabled, false);
  assert.equal((await req(d, 'POST', '/channels/meeting-lares/start')).status, 400);
  assert.equal((await req(d, 'POST', '/channels/nope/start')).status, 404);
  assert.equal((await req(d, 'GET', '/channels')).body.length, 9);
});

test('SSE /events sends status then feed events', async (t) => {
  const d = await testDaemon(t);
  const ac = new AbortController();
  const r = await fetch(`http://127.0.0.1:${d.port}/events`, { headers: { authorization: `Bearer ${d.token}` }, signal: ac.signal });
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type'), /text\/event-stream/);
  const reader = r.body.getReader();
  let buf = '';
  const until = async (re) => { while (!re.test(buf)) { const { value, done } = await reader.read(); if (done) break; buf += Buffer.from(value).toString('utf8'); } };
  await until(/event: status/);
  await req(d, 'POST', '/ask', { body: { text: 'hi' } });
  await until(/event: feed\ndata: .*"answer"/);
  ac.abort();
});

test('join errors: bad link 400 with Chinese message; zoom 400 RTMS explanation; lares 400', async (t) => {
  const d = await testDaemon(t);
  const bad = await req(d, 'POST', '/join', { body: { link: 'http://localhost:8443/x' } });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error, 'not_https');
  assert.match(bad.body.message, /https/);
  const unk = await req(d, 'POST', '/join', { body: { link: 'https://unknown.example/r' } });
  assert.equal(unk.status, 400);
  assert.equal(unk.body.error, 'unknown_host');
  const z = await req(d, 'POST', '/join', { body: { link: 'https://us02web.zoom.us/j/81234567890' } });
  assert.equal(z.status, 400);
  assert.equal(z.body.error, 'zoom_needs_rtms');
  assert.match(z.body.message, /RTMS/);
  assert.match(z.body.message, /侧边栏/);
  assert.match(z.body.message, /还没配置|未运行/);
  const l = await req(d, 'POST', '/join', { body: { link: 'https://app.lares.example/circle/c1' } });
  assert.equal(l.status, 400);
  assert.match(l.body.message, /anonym_supervisor/);
  assert.equal((await req(d, 'POST', '/join', { body: { link: 'https://localhost:8443/r', k: 99 } })).status, 400);
  assert.equal((await req(d, 'GET', '/status')).body.state, 'idle');
});
