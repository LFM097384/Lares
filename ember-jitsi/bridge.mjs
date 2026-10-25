// ember-jitsi · 浏览器 bridge:一个无头 Chromium 页面 = 一个 Jitsi 参与者(lib-jitsi-meet,来自目标服务器自己的 /libs)。
// 炉灵 bot 与 e2e 的模拟真人共用此类(真人额外带 --use-file-for-fake-audio-capture)。
// 形状满足 port.mjs 期望的 bridge:join / leave / sendPublic / sendPrivate / on('participant'|'name'|'left'|'audio'|'chat'|'disconnected')。
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { launchChromium } from './deps.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLIENT_JS = () => readFileSync(path.join(HERE, 'page', 'client.js'), 'utf8');
export const PAGE_PATH = '/__ember_jitsi__/client.html';

export function pageHtml() {
  return `<!doctype html><html><head><meta charset="utf-8"><title>ember-jitsi</title>
<script src="/config.js"></script>
<script src="/libs/lib-jitsi-meet.min.js"></script>
</head><body><script>${CLIENT_JS()}</script></body></html>`;
}

/// 规范化服务器地址:https://host[:port],去掉结尾斜杠和路径
export function normalizeUrl(u) {
  const x = new URL(String(u));
  if (!/^https?:$/.test(x.protocol)) throw new Error('JITSI_URL must be http(s)');
  return `${x.protocol}//${x.host}`;
}

export class JitsiBrowserBridge {
  /**
   * @param {object} o
   * @param {string} o.url        Jitsi 服务器(https://localhost:8443)
   * @param {string} o.room
   * @param {string} o.name       显示名
   * @param {boolean} [o.tapAudio]  订阅并抽取远端逐人音频(bot)
   * @param {string} [o.fakeAudioWav]  模拟真人:Chromium 假麦克风播放这个 WAV
   * @param {boolean} [o.insecure]  接受自签证书(缺省:localhost / 127.0.0.1 时 true,或 JITSI_INSECURE=1)
   * @param {object} [o.browser]  共享一个已启动的 Chromium(没有假麦时可复用)
   */
  constructor({ url, room, name, tapAudio = false, fakeAudioWav = null, insecure, browser = null, headless = true, log = () => {}, joinTimeoutMs = 45_000 }) {
    this.url = normalizeUrl(url);
    const host = new URL(this.url).hostname;
    Object.assign(this, { room, name, tapAudio, fakeAudioWav, browser, headless, log, joinTimeoutMs });
    this.insecure = insecure ?? (host === 'localhost' || host === '127.0.0.1' || process.env.JITSI_INSECURE === '1');
    this.handlers = new Map();
    this.ownBrowser = false;
    this.page = null;
    this.ctx = null;
    this.myId = null;
    this.left = false;
    this.stats = { audioFrames: 0, audioBy: new Map() };
  }

  on(ev, fn) { if (!this.handlers.has(ev)) this.handlers.set(ev, []); this.handlers.get(ev).push(fn); return this; }
  _emit(ev, ...a) { for (const fn of this.handlers.get(ev) ?? []) { try { fn(...a); } catch (e) { this.log(`bridge handler ${ev}: ${e.message}`); } } }

  async join() {
    if (!this.browser) {
      // LocalNetworkAccessChecks:page.route 伪造的页面没有「地址空间」,新版 Chromium 会把它到 localhost 服务器的 WS 当作跨网络访问拦掉
      const args = ['--autoplay-policy=no-user-gesture-required', '--use-fake-ui-for-media-stream', '--disable-features=LocalNetworkAccessChecks,BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights'];
      if (this.fakeAudioWav) args.push('--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${this.fakeAudioWav}`);
      this.browser = await launchChromium({ headless: this.headless, args });
      this.ownBrowser = true;
    }
    this.ctx = await this.browser.newContext({ ignoreHTTPSErrors: this.insecure, permissions: ['microphone'] });
    this.page = await this.ctx.newPage();
    this.page.on('crash', () => this._emit('disconnected', 'page_crash'));
    await this.page.route(`${this.url}${PAGE_PATH}`, (r) => r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: pageHtml() }));
    await this.page.exposeFunction('emberEvent', (o) => this._onEvent(o));
    await this.page.exposeFunction('emberAudio', (id, b64) => {
      const buf = Buffer.from(String(b64), 'base64');
      const pcm = new Int16Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
      this.stats.audioFrames += 1;
      this.stats.audioBy.set(id, (this.stats.audioBy.get(id) ?? 0) + 1);
      this._emit('audio', String(id), pcm, 16000);
    });
    await this.page.goto(`${this.url}${PAGE_PATH}`, { waitUntil: 'load', timeout: this.joinTimeoutMs });
    await this.page.waitForFunction(() => Boolean(window.ember && window.JitsiMeetJS), null, { timeout: this.joinTimeoutMs });
    this.myId = await this.page.evaluate((o) => window.ember.start(o), { room: this.room, name: this.name, tapAudio: this.tapAudio, timeoutMs: this.joinTimeoutMs });
    return this.myId;
  }

  _onEvent(o) {
    if (!o || typeof o !== 'object') return;
    switch (o.ev) {
      case 'participant': return this._emit('participant', String(o.id), String(o.name ?? ''), Boolean(o.hidden));
      case 'name': return this._emit('name', String(o.id), String(o.name ?? ''));
      case 'left': return this._emit('left', String(o.id));
      case 'chat': return this._emit('chat', String(o.id), String(o.text ?? ''), Boolean(o.private));
      case 'disconnected': return this.left ? undefined : this._emit('disconnected', String(o.reason ?? 'unknown'));
      case 'track': return this._emit('track', String(o.id));
      case 'warn': return this.log(`page: ${o.where}: ${o.message}`);
      default: return undefined;
    }
  }

  async addMic() { return this.page.evaluate(() => window.ember.addMic()); }
  async sendPublic(text) { if (!this.left) await this.page.evaluate((t) => window.ember.sendPublic(t), String(text)); }
  async sendPrivate(id, text) { if (!this.left) await this.page.evaluate(([i, t]) => window.ember.sendPrivate(i, t), [String(id), String(text)]); }
  async participants() { return this.page.evaluate(() => window.ember.participants()); }

  async leave() {
    if (this.left) return;
    this.left = true;
    try { await this.page?.evaluate(() => window.ember?.leave()); } catch { /* */ }
    try { await this.ctx?.close(); } catch { /* */ }
    if (this.ownBrowser) { try { await this.browser?.close(); } catch { /* */ } }
  }
}
