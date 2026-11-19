import test from 'node:test';
import assert from 'node:assert/strict';
import { matchMeetingUrl, teamsOf, MeetUrlError, isTeamsHost } from '../urls.mjs';
import { adapterFor, ADAPTERS, checkAdapter, adapterByName } from '../adapters/index.mjs';
import { ChatTracker } from '../chat.mjs';
import { parseCommand } from '../../ember-jitsi/commands.mjs';

const THREAD = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZjA2NzQ5%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d';

test('Teams URL matcher: work/school, short, free, redirect forms', () => {
  const a = matchMeetingUrl(THREAD);
  assert.equal(a.platform, 'teams');
  assert.equal(a.implemented, true);
  assert.equal(a.meetingKey, 'thread:19:meeting_ZjA2NzQ5@thread.v2');
  assert.equal(matchMeetingUrl('https://teams.live.com/meet/9876543210123?p=AbCdEf').meetingKey, 'meet:9876543210123');
  assert.equal(matchMeetingUrl('https://teams.live.com/meet/9876543210123?p=AbCdEf').passcodePresent, true);
  assert.equal(matchMeetingUrl('https://teams.microsoft.com/meet/123456789?p=x').platform, 'teams');
  assert.equal(matchMeetingUrl('https://gov.teams.microsoft.com/l/meetup-join/19%3ameeting_a%40thread.v2/0').platform, 'teams');
  assert.equal(matchMeetingUrl('https://teams.microsoft.com/v2/?meetingjoin=true#/l/meetup-join/19:meeting_q@thread.v2/0').meetingKey, 'thread:19:meeting_q@thread.v2');
  assert.equal(matchMeetingUrl('https://teams.microsoft.com/dl/launcher/launcher.html?url=%2F_%23%2Fl%2Fmeetup-join%2F19%3Ameeting_z%40thread.v2%2F0&type=meetup-join').meetingKey, 'thread:19:meeting_z@thread.v2');
});

test('URL matcher rejects non-meetings and lookalikes', () => {
  assert.equal(matchMeetingUrl('http://teams.microsoft.com/l/meetup-join/x/0'), null, 'https only');
  assert.equal(matchMeetingUrl('https://teams.microsoft.com.evil.example/l/meetup-join/x'), null);
  assert.equal(matchMeetingUrl('https://evilteams.microsoft.com.cn/meet/123456'), null);
  assert.equal(matchMeetingUrl('not a url'), null);
  assert.equal(matchMeetingUrl('https://meet.jit.si/room'), null);
  assert.throws(() => teamsOf('https://teams.microsoft.com/_#/conversations'), (e) => e instanceof MeetUrlError && e.code === 'teams_bad_path');
  assert.equal(isTeamsHost('TEAMS.LIVE.COM'), true);
  assert.equal(isTeamsHost('live.com'), false);
});

test('Google Meet / Tencent are recognised but not implemented; stubs throw', async () => {
  const g = matchMeetingUrl('https://meet.google.com/abc-defg-hij');
  assert.deepEqual([g.platform, g.implemented], ['google-meet', false]);
  const t = matchMeetingUrl('https://meeting.tencent.com/dm/AbCd1234');
  assert.deepEqual([t.platform, t.implemented], ['tencent', false]);
  for (const name of ['google-meet', 'tencent']) {
    const a = adapterByName(name);
    await assert.rejects(a.join({}, {}), /not implemented/);
    await assert.rejects(a.readCaptions({}), /not implemented/);
  }
});

test('adapter registry: every adapter has the full interface; adapterFor routes', () => {
  for (const a of ADAPTERS) checkAdapter(a);
  assert.equal(adapterFor(THREAD).name, 'teams');
  assert.equal(adapterFor('https://meet.google.com/abc-defg-hij').name, 'google-meet');
  assert.equal(adapterFor('https://example.com/'), null);
});

test('ChatTracker: baseline history, own messages, echo, grouped authors', () => {
  const c = new ChatTracker({ selfName: '炉灵' });
  assert.deepEqual(c.update([{ key: '1', author: 'Alice', text: 'old' }], 0), [], 'first read is baseline');
  c.noteSent('【炉灵】hi', 10);
  const out = c.update([
    { key: '1', author: 'Alice', text: 'old' },
    { key: '2', author: 'Bob (Guest)', text: '@炉灵 同意' },
    { key: '3', author: '', text: '【炉灵】hi', mine: false },
    { key: '4', author: '', text: 'x', mine: true },
    { key: '5', author: '炉灵', text: 'from me' },
    { key: '6', author: '', text: 'no author' },
  ], 20);
  assert.deepEqual(out, [{ key: '2', author: 'Bob', text: '@炉灵 同意' }]);
  assert.deepEqual(c.update([{ key: '2', author: 'Bob', text: '@炉灵 同意' }], 30), [], 'seen keys never repeat');
});

test('chat command parsing is the ember-jitsi grammar (reused, not forked)', () => {
  assert.deepEqual(parseCommand('@炉灵 同意'), { cmd: 'ack' });
  assert.equal(parseCommand('@炉灵 问 预算定了吗').cmd, 'ask');
  assert.equal(parseCommand('@炉灵 纪要').cmd, 'minutes');
  assert.equal(parseCommand('@炉灵 批准 D1').draft, 'D1');
  assert.equal(parseCommand('hello everyone'), null);
});
