// ember-meet · 通用「模拟真人」网页会议客户端 driver。
// 一个真的 Chromium(本机 Playwright,或 WSL2 里 Xvfb 下的有头 Chromium)打开会议网页,
// 交给平台 adapter(adapters/*.mjs)完成「像人一样」的入会操作,然后定时读字幕和聊天,
// 经 CaptionTracker / ChatTracker 去重后以事件交给 port.mjs。
// 形状见 port.mjs 文件头:join / leave / sendChat / on('caption'|'chat'|'roster'|'state'|'disconnected')。
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { loadPlaywright, chromiumFallbacks } from '../ember-jitsi/deps.mjs';
import { CaptionTracker } from './captions.mjs';
import { ChatTracker } from './chat.mjs';
import { PROBE_SOURCE, sleep } from './adapters/util.mjs';

export const CHROMIUM_ARGS = Object.freeze([
  '--autoplay-policy=no-user-gesture-required',
  '--use-fake-ui-for-media-stream', // 权限弹窗自动同意(我们反正关摄像头和麦克风)
  '--use-fake-device-for-media-stream', // 假摄像头 / 假麦克风:绝不打开本机真实设备(sim speaker 另用 --use-file-for-fake-audio-capture 换成 WAV)
  '--disable-blink-features=AutomationControlled',
  '--no-first-run',
  '--no-default-browser-check',
  '--lang=zh-CN',
]);

const UA_HINT = /HeadlessChrome\//;

/**
 * 打开一个浏览器上下文。profileDir 有值 → 持久化 profile(launchPersistentContext);否则临时上下文。
 * @returns {Promise<{context, page, close:()=>Promise<void>}>}
 */
export async function openBrowser({ headless = false, profileDir = null, args = [], env = process.env, locale = 'zh-CN', log = () => {} } = {}) {
  const { chromium } = await loadPlaywright(env);
  const opts = {
    headless,
    args: [...CHROMIUM_ARGS, ...args],
    locale,
    viewport: { width: 1366, height: 860 },
    permissions: ['microphone', 'camera'],
    ignoreDefaultArgs: ['--enable-automation'],
  };
  const launchers = [null, ...chromiumFallbacks(env)];
  let last;
  for (const exe of env.EMBER_CHROMIUM_PATH ? [env.EMBER_CHROMIUM_PATH] : launchers) {
    const o = exe ? { ...opts, executablePath: exe } : opts;
    try {
      let context;
      let browser = null;
      if (profileDir) {
        mkdirSync(profileDir, { recursive: true });
        context = await chromium.launchPersistentContext(path.resolve(profileDir), o);
      } else {
        const { locale: _l, viewport, permissions, ignoreDefaultArgs: _i, ...launchOpts } = o;
        browser = await chromium.launch({ ...launchOpts, ignoreDefaultArgs: ['--enable-automation'] });
        context = await browser.newContext({ locale, viewport, permissions });
      }
      await context.addInitScript(PROBE_SOURCE);
      // 无头模式的 UA 里有 HeadlessChrome:只提示,不伪装
      const page = context.pages()[0] ?? await context.newPage();
      const ua = await page.evaluate(() => navigator.userAgent).catch(() => '');
      if (UA_HINT.test(ua)) log('driver: headless UA 含 HeadlessChrome(部分平台会据此拦截;遇到拦截改用有头 / WSL 模式)');
      return { context, page, close: async () => { await context.close().catch(() => {}); if (browser) await browser.close().catch(() => {}); } };
    } catch (e) { last = e; }
  }
  throw last ?? new Error('无法启动 Chromium');
}

/**
 * @param {object} o
 * @param {object} o.adapter       adapters/*.mjs
 * @param {string} o.url
 * @param {string} o.displayName
 * @param {object} [o.page]        已打开的 Playwright page(测试 / sim 用);不给就自己 openBrowser
 * @param {object} [o.browser]     openBrowser 的参数
 * @param {number} [o.pollMs]      字幕 / 聊天轮询间隔
 * @param {boolean} [o.captions]   是否开字幕(sim speaker 不开)
 * @param {boolean} [o.chat]       是否开聊天面板
 * @param {object} [o.tracker]     CaptionTracker 参数(stableMs 等)
 * @param {Function} [o.clock]
 */
export function createDriver({ adapter, url, displayName, page = null, browser = {}, log = () => {}, pollMs = 700, captions = true, chat = true, tracker = {}, clock = () => Date.now(), joinOpts = {} }) {
  const handlers = new Map();
  const emit = (ev, ...a) => { for (const fn of handlers.get(ev) ?? []) { try { fn(...a); } catch (e) { log(`driver handler ${ev}: ${e.message}`); } } };
  let session = null; // {page, close}
  let timer = null;
  let polling = false;
  let left = false;
  let joined = false;
  let unknownSince = 0;
  const stats = { polls: 0, captionsPresent: false, chatPresent: false, captionsEnabled: null, chatOpened: null };
  const ct = new CaptionTracker({ ignoreSpeakers: [displayName], ...tracker, onFinal: (u) => emit('caption', u.speaker, u.text) });
  const chatT = new ChatTracker({ selfName: displayName });
  let sendQueue = Promise.resolve();

  async function poll() {
    if (polling || left || !session) return;
    polling = true;
    try {
      const p = session.page;
      stats.polls++;
      const now = clock();
      if (captions) {
        const snap = await adapter.readCaptions(p);
        stats.captionsPresent = snap.present;
        ct.update(snap.items, now);
      }
      if (chat) {
        const c = await adapter.readChat(p);
        stats.chatPresent = c.present;
        if (c.present) for (const m of chatT.update(c.items, now)) emit('chat', m.author, m.text);
      }
      if (stats.polls % 10 === 0) {
        const names = await adapter.participants(p);
        if (names.length) emit('roster', names);
        const st = await adapter.inMeeting(p);
        if (st === 'ended') { emit('state', 'ended'); emit('disconnected', 'meeting_ended'); stop(); return; }
        if (st === 'unknown') { unknownSince ||= now; if (now - unknownSince > 120_000) { emit('disconnected', 'lost_meeting_ui'); stop(); return; } } else unknownSince = 0;
      }
    } catch (e) {
      if (/closed|Target page|has been closed/i.test(e.message)) { emit('disconnected', 'page_closed'); stop(); } else log(`driver poll: ${e.message}`);
    } finally { polling = false; }
  }

  function stop() { if (timer) { clearInterval(timer); timer = null; } }

  const driver = {
    stats,
    get page() { return session?.page ?? null; },
    on(ev, fn) { if (!handlers.has(ev)) handlers.set(ev, []); handlers.get(ev).push(fn); return driver; },
    async join() {
      if (joined) return;
      joined = true;
      session = page ? { page, close: async () => {} } : await openBrowser({ log, ...browser });
      session.page.on('close', () => { if (!left) { emit('disconnected', 'page_closed'); stop(); } });
      await adapter.join(session.page, { url, displayName, log, onState: (s) => emit('state', s), ...joinOpts });
      if (captions) {
        stats.captionsEnabled = await adapter.enableCaptions(session.page, { log });
        emit('state', stats.captionsEnabled ? 'captions-on' : 'captions-unavailable');
      }
      if (chat && adapter.openChat) {
        stats.chatOpened = await adapter.openChat(session.page, { log });
        emit('state', stats.chatOpened ? 'chat-open' : 'chat-unavailable');
        const c = await adapter.readChat(session.page);
        chatT.baseline(c.items); // 进会前的聊天历史不当命令
      }
      timer = setInterval(() => { void poll(); }, pollMs);
      timer.unref?.();
    },
    async sendChat(text) {
      if (left || !session) return;
      const job = sendQueue.then(async () => {
        chatT.noteSent(text, clock());
        await adapter.sendChat(session.page, text);
        await sleep(150);
      });
      sendQueue = job.catch(() => {});
      return job;
    },
    async pollOnce() { await poll(); },
    flushCaptions() { for (const _u of ct.flush(clock())) { /* onFinal 已发 */ } },
    async leave() {
      if (left) return;
      stop();
      if (session && captions) driver.flushCaptions();
      left = true;
      await sendQueue.catch(() => {});
      if (session) {
        await adapter.leave(session.page).catch(() => {});
        await sleep(300);
        await session.close();
      }
    },
    captionStats: () => ({ ...ct.stats }),
  };
  return driver;
}
