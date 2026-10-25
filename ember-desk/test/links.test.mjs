import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseLink, LinkError } from '../links.mjs';

const hosts = ['localhost:8443', 'meet.example.org'];
const noProbe = async () => { throw new Error('probe must not be called'); };

test('jitsi via configured host (host:port match, room lowercased)', async () => {
  const r = await parseLink('https://localhost:8443/MyRoom?x=1#h', { jitsiHosts: hosts, probe: noProbe });
  assert.deepEqual([r.adapter, r.url, r.room, r.via], ['jitsi', 'https://localhost:8443', 'myroom', 'config']);
  const r2 = await parseLink('https://MEET.example.org/team.sync-1', { jitsiHosts: hosts, probe: noProbe });
  assert.equal(r2.url, 'https://meet.example.org');
  assert.equal(r2.room, 'team.sync-1');
});

test('jitsi host:port must match exactly; otherwise probe decides', async () => {
  let probed = null;
  const r = await parseLink('https://localhost:9443/r1', { jitsiHosts: hosts, probe: async (u) => { probed = u.host; return true; } });
  assert.equal(probed, 'localhost:9443');
  assert.equal(r.via, 'probe');
  await assert.rejects(parseLink('https://other.example/r1', { jitsiHosts: hosts, probe: async () => false }), (e) => e instanceof LinkError && e.code === 'unknown_host' && /jitsiHosts/.test(e.message));
  await assert.rejects(parseLink('https://other.example/r1', { jitsiHosts: hosts, probe: async () => { throw new Error('net'); } }), { code: 'unknown_host' });
});

test('zoom links route to zoom adapter', async () => {
  const r = await parseLink('https://us02web.zoom.us/j/81234567890?pwd=abc', { jitsiHosts: hosts, probe: noProbe });
  assert.equal(r.adapter, 'zoom');
  assert.equal(r.meetingId, '81234567890');
  assert.equal(r.passcodePresent, true);
  assert.equal((await parseLink('https://zoom.us/wc/81234567890/join', { probe: noProbe })).meetingId, '81234567890');
  assert.equal((await parseLink('https://acme.zoom.us/wc/join/81234567890', { probe: noProbe })).adapter, 'zoom');
  await assert.rejects(parseLink('https://zoom.us/profile', { probe: noProbe }), { code: 'zoom_bad_path' });
});

test('lares links route to lares adapter', async () => {
  const r = await parseLink('https://app.lares.example/circle/abc123', { probe: noProbe });
  assert.equal(r.adapter, 'lares');
  assert.equal(r.circleId, 'abc123');
  assert.equal((await parseLink('https://x.example/circle/c1', { probe: noProbe })).adapter, 'lares');
});

test('rejects non-https, javascript:, credentials, control chars, bad room, too long', async () => {
  const bad = [
    ['http://localhost:8443/r', 'not_https'],
    ['javascript:alert(1)', 'not_https'],
    ['file:///C:/x', 'not_https'],
    ['https://user:pw@localhost:8443/r', 'credentials'],
    ['https://user@localhost:8443/r', 'credentials'],
    ['https://localhost:8443/r\nx', 'control_chars'],
    ['https://localhost:8443/r%00', 'control_chars'],
    ['https://localhost:8443/', 'no_room'],
    ['https://localhost:8443/bad%20room', 'bad_room'],
    ['https://localhost:8443/a"b', 'bad_room'],
    [`https://localhost:8443/${'a'.repeat(65)}`, 'bad_room'],
    [`https://localhost:8443/r?${'a'.repeat(2100)}`, 'too_long'],
    ['', 'empty'],
    ['not a url', 'not_url'],
  ];
  for (const [l, code] of bad) {
    await assert.rejects(parseLink(l, { jitsiHosts: hosts, probe: async () => true }), (e) => e instanceof LinkError && e.code === code && /[\u4e00-\u9fff]/.test(e.message), `${l} → ${code}`);
  }
  await assert.rejects(parseLink(42, { jitsiHosts: hosts }), { code: 'empty' });
});
