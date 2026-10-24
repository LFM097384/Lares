import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { signWebhook, verifyWebhook, urlValidationResponse, splitServerUrls } from '../webhook.mjs';
import { createZoomServer, securityHeaders } from '../server.mjs';

const SECRET = 'test-webhook-secret';
const now = 1_760_000_000_000;
const ts = String(Math.floor(now / 1000));

test('signWebhook = v0= + HMAC-SHA256(secret, v0:ts:body)', () => {
  const body = '{"event":"x"}';
  const want = `v0=${createHmac('sha256', SECRET).update(`v0:${ts}:${body}`).digest('hex')}`;
  assert.equal(signWebhook(SECRET, ts, body), want);
});

test('verifyWebhook: good / tampered / stale / missing / bad ts / no secret', () => {
  const body = Buffer.from('{"event":"meeting.rtms_started","payload":{}}');
  const h = (sig, t = ts) => ({ 'x-zm-signature': sig, 'x-zm-request-timestamp': t });
  const good = signWebhook(SECRET, ts, body);
  assert.deepEqual(verifyWebhook({ secret: SECRET, headers: h(good), rawBody: body, now }), { ok: true });
  assert.equal(verifyWebhook({ secret: SECRET, headers: h(good), rawBody: Buffer.from(`${body} `), now }).code, 'bad_signature');
  assert.equal(verifyWebhook({ secret: 'other', headers: h(good), rawBody: body, now }).code, 'bad_signature');
  assert.equal(verifyWebhook({ secret: SECRET, headers: h(good.slice(0, -2)), rawBody: body, now }).code, 'bad_signature');
  assert.equal(verifyWebhook({ secret: SECRET, headers: h(good), rawBody: body, now: now + 301_000 }).code, 'stale');
  assert.equal(verifyWebhook({ secret: SECRET, headers: h(good), rawBody: body, now: now - 301_000 }).code, 'stale');
  assert.equal(verifyWebhook({ secret: SECRET, headers: h(good), rawBody: body, now: now + 299_000 }).ok, true);
  assert.equal(verifyWebhook({ secret: SECRET, headers: { 'x-zm-request-timestamp': ts }, rawBody: body, now }).code, 'missing_headers');
  assert.equal(verifyWebhook({ secret: SECRET, headers: h(good, '12a'), rawBody: body, now }).code, 'bad_timestamp');
  assert.equal(verifyWebhook({ secret: '', headers: h(good), rawBody: body, now }).code, 'no_secret');
});

test('urlValidationResponse = HMAC-SHA256(secret, plainToken) hex', () => {
  const r = urlValidationResponse(SECRET, 'qgg8vlvZRS6UYooatFL8Aw');
  assert.equal(r.plainToken, 'qgg8vlvZRS6UYooatFL8Aw');
  assert.equal(r.encryptedToken, createHmac('sha256', SECRET).update('qgg8vlvZRS6UYooatFL8Aw').digest('hex'));
});

test('splitServerUrls', () => {
  assert.deepEqual(splitServerUrls('wss://a/x, wss://b/y'), ['wss://a/x', 'wss://b/y']);
  assert.deepEqual(splitServerUrls(''), []);
});

test('HTTP: url_validation, signed event dispatch, negatives, sidebar headers', async (t) => {
  const events = [];
  const srv = createZoomServer({ webhookSecret: SECRET, onWebhook: (e, p) => { events.push([e, p]); } });
  const port = await srv.listen(0);
  t.after(() => srv.close());
  const base = `http://127.0.0.1:${port}`;
  const post = (obj, { secret = SECRET, tsOverride, sigOverride, raw } = {}) => {
    const body = raw ?? JSON.stringify(obj);
    const tt = tsOverride ?? String(Math.floor(Date.now() / 1000));
    return fetch(`${base}/webhook`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-zm-request-timestamp': tt, 'x-zm-signature': sigOverride ?? signWebhook(secret, tt, body) }, body });
  };

  let r = await post({ event: 'endpoint.url_validation', payload: { plainToken: 'abc' } });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), urlValidationResponse(SECRET, 'abc'));
  // url_validation 也要先过签名
  r = await post({ event: 'endpoint.url_validation', payload: { plainToken: 'abc' } }, { secret: 'nope' });
  assert.equal(r.status, 401);
  assert.equal((await r.json()).error, 'bad_signature');

  r = await post({ event: 'meeting.rtms_started', payload: { meeting_uuid: 'm1', rtms_stream_id: 's1', server_urls: 'wss://x' } });
  assert.equal(r.status, 200);
  r = await post({ event: 'meeting.rtms_stopped', payload: { meeting_uuid: 'm1', rtms_stream_id: 's1', stop_reason: 6 } });
  assert.equal(r.status, 200);
  r = await post({ event: 'meeting.rtms_interrupted', payload: { meeting_uuid: 'm1', rtms_stream_id: 's1' } });
  assert.equal(r.status, 200);
  r = await post({ event: 'meeting.started', payload: {} });
  assert.equal(r.status, 200);
  await new Promise((res) => setTimeout(res, 30));
  assert.deepEqual(events.map((e) => e[0]), ['meeting.rtms_started', 'meeting.rtms_stopped', 'meeting.rtms_interrupted']);
  assert.equal(events[0][1].rtms_stream_id, 's1');

  // 负例:不派发
  r = await post({ event: 'meeting.rtms_started', payload: {} }, { tsOverride: String(Math.floor(Date.now() / 1000) - 3600) });
  assert.equal(r.status, 401);
  r = await post({ event: 'meeting.rtms_started', payload: {} }, { sigOverride: 'v0=deadbeef' });
  assert.equal(r.status, 401);
  r = await fetch(`${base}/webhook`, { method: 'POST', body: '{}' });
  assert.equal(r.status, 401);
  r = await fetch(`${base}/webhook`);
  assert.equal(r.status, 405);
  r = await post(null, { raw: 'x'.repeat(70 * 1024) });
  assert.equal(r.status, 413);
  r = await post(null, { raw: 'not json' });
  assert.equal(r.status, 400);
  assert.equal(events.length, 3);

  // 侧边栏静态页 + OWASP 头
  r = await fetch(`${base}/sidebar/`);
  assert.equal(r.status, 200);
  assert.match(await r.text(), /炉灵/);
  for (const h of ['content-security-policy', 'strict-transport-security', 'x-content-type-options', 'referrer-policy']) assert.ok(r.headers.get(h), h);
  assert.match(r.headers.get('content-security-policy'), /appssdk\.zoom\.us/);
  assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
  r = await fetch(`${base}/sidebar/app.js`);
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type'), /javascript/);
  r = await fetch(`${base}/sidebar/..%2f..%2fpackage.json`);
  assert.equal(r.status, 404);
  r = await fetch(`${base}/sidebar/%2e%2e/index.mjs`);
  assert.equal(r.status, 404);
  assert.ok(securityHeaders('h:1')['content-security-policy'].includes('wss://h:1'));
});
