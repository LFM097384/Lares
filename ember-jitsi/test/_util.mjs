// ember-jitsi 测试小工具:FakeBridge(替代无头 Chromium + lib-jitsi-meet)、until、目录遍历。
import { readdirSync, statSync, existsSync } from 'node:fs';
import path from 'node:path';

export const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
export async function until(fn, ms = 5000, what = 'condition') {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() - t0 > ms) throw new Error(`until: timed out (${what})`);
    await tick(5);
  }
}

export function allFiles(d) {
  const out = [];
  if (!d || !existsSync(d)) return out;
  for (const f of readdirSync(d)) { const p = path.join(d, f); if (statSync(p).isDirectory()) out.push(...allFiles(p)); else out.push(p); }
  return out;
}

/// bridge 形状见 ../port.mjs 顶部。记录所有发出的聊天;fire* 帮手模拟 Jitsi 事件。
export class FakeBridge {
  constructor({ myId = 'bot-endpoint' } = {}) {
    this.myId = myId;
    this.handlers = new Map();
    this.public = []; // [text]
    this.private = []; // [{id, text}]
    this.joins = 0;
    this.leaves = 0;
  }
  on(ev, fn) { if (!this.handlers.has(ev)) this.handlers.set(ev, []); this.handlers.get(ev).push(fn); return this; }
  fire(ev, ...a) { for (const fn of this.handlers.get(ev) ?? []) fn(...a); }
  async join() { this.joins += 1; }
  async leave() { this.leaves += 1; }
  async sendPublic(text) { this.public.push(String(text)); }
  async sendPrivate(id, text) { this.private.push({ id, text: String(text) }); }
  // 事件
  participant(id, name, hidden = false) { this.fire('participant', id, name, hidden); }
  rename(id, name) { this.fire('name', id, name); }
  left(id) { this.fire('left', id); }
  audio(id, pcm, rate = 16000) { this.fire('audio', id, pcm, rate); }
  chat(id, text, isPrivate = false) { this.fire('chat', id, text, isPrivate); }
  disconnect(why = 'test') { this.fire('disconnected', why); }
  // 查询
  privTo(id) { return this.private.filter((m) => m.id === id).map((m) => m.text); }
  envelopesTo(id) { return this.privTo(id).filter((t) => t.startsWith('EMBER1 ')).map((t) => JSON.parse(t.slice(7))); }
  allText() { return [...this.public, ...this.private.map((m) => m.text)].join('\n'); }
}
