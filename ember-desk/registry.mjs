// ember-desk · 通道注册表。channels/*.mjs 各 export default (ctx) => channel。
// channel 统一接口:{ id, kind:'input'|'output'|'meeting', name, describe(), configured(), start(), stop(), send?(msg), status() }
import path from 'node:path';
import { readdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { HERE } from './paths.mjs';

export const CHANNELS_DIR = path.join(HERE, 'channels');
export const KINDS = Object.freeze(['input', 'output', 'meeting']);
const ID_RE = /^[a-z][a-z0-9-]{0,31}$/;

export class ChannelShapeError extends Error {
  constructor(message) { super(message); this.name = 'ChannelShapeError'; }
}

export function validateChannel(ch, where = 'channel') {
  if (!ch || typeof ch !== 'object') throw new ChannelShapeError(`${where}: factory must return an object`);
  if (typeof ch.id !== 'string' || !ID_RE.test(ch.id)) throw new ChannelShapeError(`${where}: bad id`);
  if (!KINDS.includes(ch.kind)) throw new ChannelShapeError(`${where}: kind must be input|output|meeting`);
  if (typeof ch.name !== 'string' || !ch.name) throw new ChannelShapeError(`${where}: name required`);
  for (const m of ['describe', 'configured', 'start', 'stop', 'status']) {
    if (typeof ch[m] !== 'function') throw new ChannelShapeError(`${where}: ${m}() required`);
  }
  if (ch.send !== undefined && typeof ch.send !== 'function') throw new ChannelShapeError(`${where}: send must be a function`);
  return ch;
}

export class Registry {
  constructor({ ctx, log = () => {}, isEnabled = () => false, onChange = () => {} } = {}) {
    this.ctx = ctx;
    this.log = log;
    this.isEnabled = isEnabled;
    this.onChange = onChange;
    this.map = new Map();
  }

  add(ch, where) {
    validateChannel(ch, where);
    if (this.map.has(ch.id)) throw new ChannelShapeError(`${where ?? ch.id}: duplicate channel id ${ch.id}`);
    this.map.set(ch.id, ch);
    return ch;
  }

  /// 从目录加载所有 *.mjs;factory 可以是 async
  async loadDir(dir = CHANNELS_DIR) {
    const names = readdirSync(dir).filter((f) => f.endsWith('.mjs')).sort();
    for (const f of names) {
      const mod = await import(pathToFileURL(path.join(dir, f)).href);
      if (typeof mod.default !== 'function') throw new ChannelShapeError(`${f}: default export must be a factory function`);
      this.add(await mod.default(this.ctx), f);
    }
    return this;
  }

  get(id) { return this.map.get(id) ?? null; }
  all() { return [...this.map.values()]; }
  byKind(kind) { return this.all().filter((c) => c.kind === kind); }

  statusOf(ch) {
    let s = {};
    try { s = ch.status() ?? {}; } catch (e) { s = { detail: `status error: ${e.message}` }; }
    let configured = false;
    try { configured = Boolean(ch.configured()); } catch { configured = false; }
    return {
      id: ch.id, kind: ch.kind, name: ch.name, configured,
      running: Boolean(s.running), enabled: Boolean(this.isEnabled(ch.id)),
      detail: String(s.detail ?? (configured ? '' : safeDescribe(ch))),
      ...(s.extra ? { extra: s.extra } : {}),
    };
  }

  list() { return this.all().map((c) => this.statusOf(c)); }

  async start(id) {
    const ch = this.get(id);
    if (!ch) throw Object.assign(new Error(`没有这个通道:${id}`), { status: 404 });
    if (!ch.configured()) throw Object.assign(new Error(`通道 ${ch.name} 未配置:${this.statusOf(ch).detail || safeDescribe(ch)}`), { status: 400 });
    await ch.start();
    this.onChange(this.statusOf(ch));
    return this.statusOf(ch);
  }

  async stop(id) {
    const ch = this.get(id);
    if (!ch) throw Object.assign(new Error(`没有这个通道:${id}`), { status: 404 });
    await ch.stop();
    this.onChange(this.statusOf(ch));
    return this.statusOf(ch);
  }

  async stopAll() {
    await Promise.all(this.all().map(async (c) => { try { await c.stop(); } catch (e) { this.log(`channel ${c.id} stop failed: ${e.message}`); } }));
  }

  /// 发给所有正在运行且有 send() 的输出通道;单个失败只记日志
  async broadcast(msg, { only } = {}) {
    const res = {};
    for (const c of this.byKind('output')) {
      if (typeof c.send !== 'function') continue;
      if (only && !only.includes(c.id)) continue;
      let running = false;
      try { running = Boolean(c.status()?.running); } catch { /* */ }
      if (!running) continue;
      try { res[c.id] = (await c.send(msg)) ?? true; } catch (e) { res[c.id] = false; this.log(`broadcast to ${c.id} failed: ${e.message}`); }
    }
    return res;
  }
}

function safeDescribe(ch) { try { return String(ch.describe() ?? ''); } catch { return ''; } }
