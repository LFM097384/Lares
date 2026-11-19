// 端到端(无浏览器、无网络):FakeDriver → meetPort → createEmber(llm:null 确定性路径)→ 会议聊天。
// 字幕 → port 'transcript' 事件 → 只收已同意的人;聊天命令 → Ember 消息;Ember 输出 → 公开聊天(访客没有私信)。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { checkPort } from '../../ember/port.mjs';
import { meetPort, meetUserId, announceText } from '../port.mjs';
import { runEmberMeet, parseArgs, resolveMeeting, scopeOf, main, UsageError } from '../index.mjs';

class FakeDriver {
  constructor() { this.h = new Map(); this.chats = []; this.joins = 0; this.leaves = 0; }
  on(ev, fn) { if (!this.h.has(ev)) this.h.set(ev, []); this.h.get(ev).push(fn); return this; }
  emit(ev, ...a) { for (const fn of this.h.get(ev) ?? []) fn(...a); }
  async join() { this.joins++; this.emit('state', 'in-meeting'); }
  async leave() { this.leaves++; }
  async sendChat(t) { this.chats.push(String(t)); }
  caption(s, t) { this.emit('caption', s, t); }
  chat(a, t) { this.emit('chat', a, t); }
}
const tick = (ms = 10) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 3000, what = 'condition') {
  const t0 = Date.now();
  for (;;) { const v = await fn(); if (v) return v; if (Date.now() - t0 > ms) throw new Error(`timeout: ${what}`); await tick(15); }
}

const TEAMS = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0';

test('meetPort satisfies the Ember port contract and maps captions to transcript events', async () => {
  const d = new FakeDriver();
  const port = meetPort(d, { announce: false });
  checkPort(port);
  assert.equal(port.transcripts, true);
  const seen = [];
  port.on('joined', (id, name) => seen.push(['joined', id, name]));
  port.on('transcript', (id, text) => seen.push(['transcript', id, text]));
  await port.join();
  d.caption('Alice (Guest)', 'hello there');
  d.caption('炉灵', 'my own words are ignored');
  d.caption('', 'no speaker');
  const id = meetUserId('Alice');
  assert.equal(id, meetUserId('alice (Guest)'), 'id = hash of normalised display name');
  assert.deepEqual(seen, [['joined', id, 'Alice'], ['transcript', id, 'hello there']]);
  assert.equal(port.isHuman(id), true);
  assert.equal(port.isHuman('ember-meet-bot'), false);
  assert.equal(port.nameOf(id), 'Alice');
  await port.leave(); await port.leave();
  assert.equal(d.leaves, 1, 'leave idempotent');
});

test('announcement says chat is public and persistent', () => {
  const a = announceText('Teams 会议');
  assert.match(a, /所有人都看得见/);
  assert.match(a, /聊天记录/);
  assert.match(a, /实时字幕/);
  assert.match(a, /不录音/);
});

async function start(t, { k = 2 } = {}) {
  const memoryDir = mkdtempSync(path.join(os.tmpdir(), 'ember-meet-e2e-'));
  const driver = new FakeDriver();
  const logs = []; const events = [];
  const bot = await runEmberMeet({
    url: TEAMS, driver, llm: null, memoryDir, k, env: {},
    log: (m) => logs.push(String(m)), emit: (e) => events.push(e),
    sessionOpts: { ingestOpts: { batchMs: 20 } },
  });
  t.after(async () => { await bot.stop(0); rmSync(memoryDir, { recursive: true, force: true }); });
  return { bot, driver, logs, events, session: bot.ember.session };
}

const NAMES = /张伟|李秀梅|王强/;

test('e2e: caption gate by chat ack → ask → minutes k-of-n in public chat → convener ends', async (t) => {
  const { bot, driver, events, logs, session } = await start(t);
  assert.equal(driver.joins, 1);
  assert.match(driver.chats[0], /所有人都看得见/);
  assert.ok(events.some((e) => e.ev === 'ready' && e.platform === 'teams' && e.llm === false));
  assert.ok(events.some((e) => e.ev === 'state' && e.state === 'in-meeting'));

  driver.chat('张伟', '@炉灵 同意'); // 第一个 = 召集人
  driver.chat('李秀梅 (Guest)', '@炉灵 同意');
  await until(() => session.acked.size === 2, 3000, 'acks');
  assert.equal(session.convenerId, meetUserId('张伟'));
  await until(() => driver.chats.some((c) => /已同意 2 人/.test(c)), 2000, 'ack count');

  // 王强没同意:字幕被 Ember 丢弃
  driver.caption('王强', '我是王强,我反对这个安排');
  driver.caption('张伟', '我们决定下个月开始读书会');
  driver.caption('李秀梅', '读书会每周三晚上见面,先读三体');
  driver.caption('张伟', '预算控制在五百元以内');
  await until(() => session.counts.utterances >= 3, 3000, 'utterances');
  assert.equal(session.counts.utterances, 3, 'unacked caption dropped');
  await session.ingest.flush();
  for (const e of session.ingest.ledgerView().entries()) assert.doesNotMatch(e.text, NAMES);

  driver.chat('李秀梅', '@炉灵 问 读书会什么时候开始');
  const ans = await until(() => driver.chats.find((c) => c.includes('【炉灵·回答】')), 3000, 'answer');
  assert.match(ans, /读书会/);
  assert.doesNotMatch(ans, NAMES, 'answer does not name the asker or speakers');
  assert.equal(driver.chats.filter((c) => c.includes('【炉灵·回答】')).length, 1, 'answer posted once');

  driver.chat('张伟', '@炉灵 纪要');
  const draftText = await until(() => driver.chats.find((c) => c.includes('纪要草稿 D1')), 3000, 'draft');
  assert.doesNotMatch(draftText, NAMES);
  const [d] = [...session.drafts.values()];
  for (let i = 1; i <= d.items.length; i++) {
    if (d.items[i - 1].roleRisk) {
      assert.ok(!draftText.includes(d.items[i - 1].text), 'roleRisk item text withheld from public chat');
      driver.chat('张伟', `@炉灵 保留 D1 ${i}`);
      await until(() => driver.chats.some((c) => /不能原样保留/.test(c)), 2000, 'keep refused for hidden');
      const h = d.draftHash;
      driver.chat('张伟', `@炉灵 泛化 D1 ${i}`);
      await until(() => d.draftHash !== h, 2000, 'generalised');
    }
  }
  driver.chat('张伟', '@炉灵 批准 D1');
  await until(() => driver.chats.some((c) => /D1 已获 1\/2 人批准,未放行/.test(c)), 2000, '1/2');
  driver.chat('张伟 (Guest)', '@炉灵 批准'); // 同一显示名 = 同一人
  await tick(100);
  assert.equal(session.counts.releases, 0);
  driver.chat('李秀梅', '@炉灵 批准 D1');
  const rel = await until(() => driver.chats.find((c) => c.includes('已放行纪要 D1')), 3000, 'released');
  assert.doesNotMatch(rel, NAMES);
  await until(() => events.some((e) => e.ev === 'host' && e.type === 'released'), 2000, 'host released');

  driver.chat('李秀梅', '@炉灵 记忆');
  await until(() => driver.chats.some((c) => c.includes('本圈记忆') && /M1\./.test(c)), 2000, 'mem list');

  driver.chat('李秀梅', '@炉灵 结束');
  await until(() => driver.chats.some((c) => /只有召集人能散会/.test(c)), 2000, 'not convener');
  driver.chat('张伟', '@炉灵 结束');
  assert.equal(await bot.done, 0);
  assert.ok(driver.chats.some((c) => /散会。放行 1 份纪要/.test(c)));
  assert.equal(driver.leaves, 1);

  // stdout 事件 / 日志卫生:没有名字、没有原话
  const blob = `${logs.join('\n')}\n${JSON.stringify(events)}`;
  assert.doesNotMatch(blob, NAMES);
  assert.doesNotMatch(blob, /读书会|三体|预算/);
  const finals = events.filter((e) => e.ev === 'caption_final');
  assert.ok(finals.length >= 4);
  for (const f of finals) assert.deepEqual(Object.keys(f).sort(), ['acked', 'chars', 'ev', 'speaker']);
});

test('e2e: driver disconnect → crash code; meeting_ended → ok', async (t) => {
  {
    const { bot, driver } = await start(t);
    driver.emit('disconnected', 'page_closed');
    assert.equal(await bot.done, 1);
    assert.equal(driver.leaves, 1);
  }
  {
    const { bot, driver } = await start(t);
    driver.emit('disconnected', 'meeting_ended');
    assert.equal(await bot.done, 0);
  }
});

test('CLI args / meeting resolution', async () => {
  assert.deepEqual(parseArgs(['--url', TEAMS, '--headless', '--k', '3']), { url: TEAMS, headless: true, k: 3 });
  assert.equal(parseArgs(['--no-profile']).profile, null);
  assert.throws(() => parseArgs(['--k', '0']), UsageError);
  assert.throws(() => parseArgs(['--bogus']), UsageError);
  assert.equal(resolveMeeting(TEAMS).adapter.name, 'teams');
  assert.throws(() => resolveMeeting('https://meet.google.com/abc-defg-hij'), /not implemented/);
  assert.throws(() => resolveMeeting('https://example.com/x'), /unsupported/);
  const m = resolveMeeting(TEAMS).meeting;
  assert.equal(scopeOf(m), scopeOf(resolveMeeting(`${TEAMS}?context=other`).meeting), 'scope ignores query noise');
  const out = [];
  assert.equal(await main(['--url', 'https://meet.google.com/abc-defg-hij'], {}, { out: (e) => out.push(e) }), 2);
  assert.match(out[0].message, /not implemented/);
});
