// ember-desk · meeting-teams 通道:prepareJoin 拼出 ember-meet 命令行。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseLink } from '../links.mjs';
import meetingTeams from '../channels/meeting-teams.mjs';
import { DEFAULT_CONFIG } from '../config.mjs';
import { MEET_ENTRY } from '../paths.mjs';
import { cleanEnv } from './helpers.mjs';

test('meeting-teams: prepareJoin spawns ember-meet with the meeting link, k and convener; status detail', async () => {
  const env = { ...cleanEnv(), EMBER_DESK_MEET_ARGS: '["--headless"]' };
  const ch = meetingTeams({ config: () => ({ ...DEFAULT_CONFIG, defaultK: 2 }), secrets: {}, env, session: () => null, overrides: { teams: { skipPlaywrightCheck: true } } });
  assert.equal(ch.id, 'meeting-teams');
  assert.equal(ch.kind, 'meeting');
  assert.equal(ch.configured(), true);
  assert.match(ch.status().detail, /Teams/);
  const parsed = await parseLink('https://teams.live.com/meet/9876543210123?p=AbC', { probe: async () => false });
  const spec = ch.prepareJoin(parsed, { k: 3, convenerName: '张伟' });
  assert.equal(spec.command, process.execPath);
  assert.deepEqual(spec.args, [MEET_ENTRY, '--url', 'https://teams.live.com/meet/9876543210123?p=AbC', '--k', '3', '--convener-name', '张伟', '--headless']);
  assert.ok(spec.cwd);
  const spec2 = ch.prepareJoin(parsed, {});
  assert.deepEqual(spec2.args.slice(3, 5), ['--k', '2']);
});

test('meeting-teams: missing entry → not_configured', () => {
  const ch = meetingTeams({ config: () => ({ ...DEFAULT_CONFIG }), secrets: {}, env: cleanEnv(), overrides: { teams: { entry: 'Z:/nope/index.mjs', skipPlaywrightCheck: true } } });
  assert.equal(ch.configured(), false);
  assert.throws(() => ch.prepareJoin({ link: 'https://teams.live.com/meet/1234567' }, {}), (e) => e.code === 'not_configured');
});
