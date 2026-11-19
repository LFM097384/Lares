// 夹具测试(Playwright 无头 Chromium + test/fixtures/*.html,离线):
// Teams adapter 的入会流程(启动页 → 预加入 → 大厅 → 放行 / 拒绝)、开字幕、读字幕(逐词变长 / 多人 / 重渲染)、
// 聊天读写,以及 driver 把这些串起来交给 port。找不到 Playwright 时整组 skip(不算失败)。
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { launchChromium } from '../../ember-jitsi/deps.mjs';
import { teamsAdapter } from '../adapters/teams.mjs';
import { createDriver } from '../driver.mjs';
import { PROBE_SOURCE } from '../adapters/util.mjs';

const FX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures');
const fx = (name, q = '') => `${pathToFileURL(path.join(FX, name)).href}${q ? `?${q}` : ''}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 5000, what = 'condition') {
  const t0 = Date.now();
  for (;;) { const v = await fn(); if (v) return v; if (Date.now() - t0 > ms) throw new Error(`timeout: ${what}`); await sleep(25); }
}

let browser = null;
let skip = false;
try { browser = await launchChromium({ headless: true }); } catch (e) { skip = `Playwright/Chromium unavailable: ${e.message.split('\n')[0]}`; }
test.after(async () => { await browser?.close(); });

async function newPage(t) {
  const ctx = await browser.newContext({ locale: 'en-US' });
  await ctx.addInitScript(PROBE_SOURCE);
  t.after(() => ctx.close());
  return ctx.newPage();
}

const quiet = { stepMs: 60 };

test('teams join: launcher → name → camera/mic off → join → lobby → admitted', { skip }, async (t) => {
  const page = await newPage(t);
  const states = [];
  const joining = teamsAdapter.join(page, { url: fx('teams-prejoin.html'), displayName: '炉灵', onState: (s) => states.push(s), timeoutMs: 15_000, ...quiet });
  await until(() => states.includes('lobby'), 10_000, 'lobby');
  assert.match(page.url(), /teams-lobby\.html/);
  const q = new URL(page.url()).searchParams;
  assert.equal(q.get('name'), '炉灵', 'display name typed');
  assert.equal(q.get('cam'), 'false', 'camera off');
  assert.equal(q.get('mic'), 'false', 'mic off');
  await page.evaluate(() => window.fx.admit());
  await joining;
  assert.deepEqual(states.filter((s, i, a) => a.indexOf(s) === i), ['opening', 'launcher', 'prejoin', 'joining', 'lobby', 'in-meeting']);
  assert.equal(await teamsAdapter.inMeeting(page), 'in');
});

test('teams join (Chinese UI, media modal, direct admit)', { skip }, async (t) => {
  const page = await newPage(t);
  await teamsAdapter.join(page, { url: fx('teams-prejoin.html', 'lang=zh&mediaModal=1&next=meeting'), displayName: '炉灵', timeoutMs: 15_000, ...quiet });
  const q = new URL(page.url()).searchParams;
  assert.deepEqual([q.get('name'), q.get('cam'), q.get('mic')], ['炉灵', 'false', 'false']);
});

test('teams join: lobby denial and lobby timeout raise AdapterError', { skip }, async (t) => {
  const page = await newPage(t);
  const p = teamsAdapter.join(page, { url: fx('teams-prejoin.html', 'nolauncher=1'), displayName: '炉灵', timeoutMs: 15_000, ...quiet });
  await until(() => /teams-lobby/.test(page.url()), 10_000, 'lobby');
  await sleep(200);
  await page.evaluate(() => window.fx.deny());
  await assert.rejects(p, (e) => e.code === 'denied');

  const page2 = await newPage(t);
  await assert.rejects(teamsAdapter.join(page2, { url: fx('teams-prejoin.html', 'nolauncher=1'), displayName: '炉灵', lobbyTimeoutMs: 400, ...quiet }), (e) => e.code === 'lobby_timeout');
});

test('teams join: meeting not found (live Teams wording) → not_found', { skip }, async (t) => {
  const page = await newPage(t);
  await assert.rejects(teamsAdapter.join(page, { url: fx('teams-prejoin.html', 'nolauncher=1&notFound=1'), displayName: '炉灵', timeoutMs: 10_000, ...quiet }), (e) => e.code === 'not_found');
});

test('teams join: page without a pre-join screen times out clearly', { skip }, async (t) => {
  const page = await newPage(t);
  await assert.rejects(teamsAdapter.join(page, { url: 'data:text/html,<h1>Sign in</h1>', displayName: '炉灵', timeoutMs: 600, ...quiet }), (e) => e.code === 'join_timeout');
});

test('teams captions: enable via More → Language and speech; read partial/final, multiple speakers', { skip }, async (t) => {
  const page = await newPage(t);
  await page.goto(fx('teams-meeting.html'));
  assert.equal((await teamsAdapter.readCaptions(page)).present, false);
  assert.equal(await teamsAdapter.enableCaptions(page, quiet), true);
  assert.equal((await teamsAdapter.readCaptions(page)).present, true);
  const i = await page.evaluate(() => window.fx.caption('Alice (Guest)', 'Hello'));
  await page.evaluate(() => window.fx.caption('Bob', 'Hi'));
  await page.evaluate((idx) => window.fx.setCaption(idx, 'Hello everyone'), i);
  const snap = await teamsAdapter.readCaptions(page);
  assert.deepEqual(snap.items.map((x) => [x.speaker, x.text]), [['Alice (Guest)', 'Hello everyone'], ['Bob', 'Hi']]);
  const again = await teamsAdapter.readCaptions(page);
  assert.equal(again.items[0].key, snap.items[0].key, 'in-place edits keep the same key');
});

test('teams captions disabled by organiser → enableCaptions false', { skip }, async (t) => {
  const page = await newPage(t);
  await page.goto(fx('teams-meeting.html', 'captionsDisabled=1'));
  assert.equal(await teamsAdapter.enableCaptions(page, quiet), false);
});

test('teams chat: open, read with grouped authors, send multi-line, leave picks Leave not End', { skip }, async (t) => {
  const page = await newPage(t);
  await page.goto(fx('teams-meeting.html', 'history=1'));
  assert.equal(await teamsAdapter.openChat(page), true);
  await page.evaluate(() => { window.fx.chat('Carol', 'first'); window.fx.chat('', 'second from Carol'); });
  const c = await teamsAdapter.readChat(page);
  assert.deepEqual(c.items.slice(-2).map((x) => [x.author, x.text]), [['Carol', 'first'], ['Carol', 'second from Carol']]);
  await teamsAdapter.sendChat(page, '【炉灵】line one\nline two');
  assert.deepEqual(await page.evaluate(() => window.fx.sent()), ['【炉灵】line one\nline two']);
  const mine = (await teamsAdapter.readChat(page)).items.at(-1);
  assert.equal(mine.mine, true);
  await teamsAdapter.leave(page);
  const log = await page.evaluate(() => window.__fxLog);
  assert.deepEqual(log, { endedForAll: false, left: true });
  assert.equal(await teamsAdapter.inMeeting(page), 'ended');
});

test('driver over fixtures: join → captions → dedup → caption/chat events → sendChat echo filtered', { skip }, async (t) => {
  const page = await newPage(t);
  const d = createDriver({ adapter: teamsAdapter, url: fx('teams-prejoin.html', 'nolauncher=1&next=meeting&history=1'), displayName: '炉灵', page, pollMs: 60, tracker: { stableMs: 400, supersededMs: 150 }, joinOpts: quiet });
  const caps = []; const chats = []; const states = [];
  d.on('caption', (s, x) => caps.push([s, x])).on('chat', (a, x) => chats.push([a, x])).on('state', (s) => states.push(s));
  await d.join();
  t.after(() => d.leave());
  assert.ok(states.includes('captions-on') && states.includes('chat-open'), states.join(','));
  const a = await page.evaluate(() => window.fx.caption('Alice (Guest)', 'We'));
  await sleep(80);
  await page.evaluate((i) => window.fx.setCaption(i, 'We ship'), a);
  await sleep(80);
  await page.evaluate((i) => window.fx.setCaption(i, 'We ship on Friday.'), a);
  await page.evaluate(() => window.fx.caption('测试用户', '我们下周开会'));
  await page.evaluate((i) => window.fx.rerender(i), a);
  await page.evaluate(() => window.fx.caption('炉灵', 'bot words'));
  await until(() => caps.length >= 2, 4000, 'captions');
  await sleep(600);
  // 每句恰好一次(重渲染后的定稿时机可能让顺序互换)
  assert.deepEqual([...caps].sort(), [['Alice', 'We ship on Friday.'], ['测试用户', '我们下周开会']].sort());
  await page.evaluate(() => window.fx.chat('Dave', '@炉灵 同意'));
  await until(() => chats.length >= 1, 3000, 'chat');
  await d.sendChat('【炉灵】ok');
  await sleep(300);
  assert.deepEqual(chats, [['Dave', '@炉灵 同意']], 'history (@炉灵 帮助) and own echo not re-emitted');
});
