import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseEmberUrl, registryCommandLine, ProtocolError, handleEmberUrl } from '../protocol.mjs';

test('accepts well-formed ember:// URLs', () => {
  assert.deepEqual(parseEmberUrl('ember://join?link=https%3A%2F%2Flocalhost%3A8443%2FMyRoom'), { action: 'join', link: 'https://localhost:8443/MyRoom' });
  assert.deepEqual(parseEmberUrl('ember://join?link=https://meet.example.org/team'), { action: 'join', link: 'https://meet.example.org/team' });
  assert.deepEqual(parseEmberUrl('ember://join/?link=https://meet.example.org/team'), { action: 'join', link: 'https://meet.example.org/team' });
  assert.deepEqual(parseEmberUrl('ember://leave'), { action: 'leave' });
  assert.deepEqual(parseEmberUrl('ember://leave/'), { action: 'leave' });
  assert.deepEqual(parseEmberUrl('ember://status'), { action: 'status' });
  assert.deepEqual(parseEmberUrl('ember://open'), { action: 'open' });
  assert.deepEqual(parseEmberUrl('ember:leave'), { action: 'leave' });
});

test('rejects injection attempts and anything off the whitelist', () => {
  const bad = [
    'ember://join?link=https://x/" & calc & "',
    'ember://join?link=https://x/%22%20%26%20calc%20%26%20%22',
    'ember://join?link=https://x/%22&calc',
    'ember://join?link=https://x/r%0Acalc',
    'ember://join?link=https://x/r%0D%0A',
    'ember://join?link=https://x/r%00',
    'ember://join?link=https://x/`calc`',
    'ember://join?link=https://x/%60calc%60',
    "ember://join?link=https://x/'a'",
    'ember://join?link=https://x/a|calc',
    'ember://join?link=https://x/a%7Ccalc',
    'ember://join?link=https://x/a^b',
    'ember://join?link=https://x/<script>',
    'ember://join?link=https://x/a%5Cb',
    'ember://join?link=http://x/r',
    'ember://join?link=javascript:alert(1)',
    'ember://join?link=file:///C:/Windows/System32/calc.exe',
    'ember://join?link=https://u:p@x/r',
    'ember://join',
    'ember://join?link=https://x/r&k=3',
    'ember://join?link=https://x/r&link=https://y/r',
    'ember://join?link=https://x/r#frag',
    'ember://leave?x=1',
    'ember://exec?cmd=calc',
    'ember://JOIN2',
    'ember://user@join?link=https://x/r',
    'ember://join:99?link=https://x/r',
    'ember://join/extra?link=https://x/r',
    'https://x/r',
    'ember://join?link=https://x/r x',
    `ember://join?link=https://x/${'a'.repeat(2100)}`,
    'ember://join?link=https://x/\u2028',
    '',
  ];
  for (const u of bad) assert.throws(() => parseEmberUrl(u), ProtocolError, u);
  assert.throws(() => parseEmberUrl(null), ProtocolError);
});

test('registryCommandLine quotes exactly and rejects quotes in paths', () => {
  assert.equal(registryCommandLine('C:\\Program Files\\nodejs\\node.exe', 'D:\\Projects\\Lares\\ember-desk\\protocol.mjs'), '"C:\\Program Files\\nodejs\\node.exe" "D:\\Projects\\Lares\\ember-desk\\protocol.mjs" "%1"');
  assert.throws(() => registryCommandLine('C:\\a"b\\node.exe', 'D:\\p.mjs'), ProtocolError);
  assert.throws(() => registryCommandLine('C:\\node.exe', 'D:\\x" & calc & "\\p.mjs'), ProtocolError);
  assert.throws(() => registryCommandLine('C:\\node.exe', 'D:\\%PATH%\\p.mjs'), ProtocolError);
  assert.throws(() => registryCommandLine('node.exe', 'D:\\p.mjs'), ProtocolError);
  assert.throws(() => registryCommandLine('', 'D:\\p.mjs'), ProtocolError);
});

test('handleEmberUrl routes to the daemon client and notifies (no real toast)', async () => {
  const notes = [];
  const calls = [];
  const client = { ensureDaemon: async () => ({ session: null }), api: async (m, p, b) => { calls.push([m, p, b]); return { adapter: 'jitsi', room: 'r' }; } };
  assert.equal(await handleEmberUrl('ember://join?link=https://localhost:8443/R', { notify: async (a, b) => notes.push([a, b]), client }), 0);
  assert.deepEqual(calls, [['POST', '/join', { link: 'https://localhost:8443/R' }]]);
  assert.equal(await handleEmberUrl('ember://exec', { notify: async (a, b) => notes.push([a, b]), client }), 2);
  assert.match(notes.at(-1)[0], /拒绝/);
  const failing = { ...client, api: async () => { throw Object.assign(new Error('x'), { body: { message: '已经在会议里了' } }); } };
  assert.equal(await handleEmberUrl('ember://leave', { notify: async (a, b) => notes.push([a, b]), client: failing }), 1);
  assert.equal(notes.at(-1)[1], '已经在会议里了');
});
