#!/usr/bin/env node
// ember-desk · 炉灵桌面守护进程。`node ember-desk/daemon.mjs`
//   单实例:daemon.lock(独占创建 wx,内容 pid);已有活实例(state.json 端口答 /status)→ stdout {ev:'already_running', port},退出码 3。
//   锁陈旧(pid 已死,且端口不答)→ 接管。
//   启动:config.json(缺则写默认)→ token → 机密(env 优先,否则 DPAPI)→ 通道 → HTTP API(127.0.0.1:随机)→ state.json。
//   退出(/quit、SIGINT、SIGBREAK、stdin {"cmd":"stop"};stdin 关闭不退出):会话 stdin stop → 通道 stop → 删 state + lock。
//   日志 daemon.log:只记元数据,不记机密、不记会话 / 笔记内容。
import path from 'node:path';
import readline from 'node:readline';
import { openSync, writeSync, closeSync, readFileSync, unlinkSync, appendFileSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { spawn as nodeSpawn } from 'node:child_process';
import { stateDir as defaultStateDir, files, VERSION, NAME } from './paths.mjs';
import { loadConfig, saveConfig, ensureToken, loadSecrets, ensureDir, writeJsonAtomic, readJson, secretPresence } from './config.mjs';
import { Registry, CHANNELS_DIR } from './registry.mjs';
import { MeetingSessionManager, SessionError } from './session.mjs';
import { createApiServer } from './api.mjs';

export const EXIT_ALREADY = 3;

export function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

/// 端口上的进程是不是一个活的 ember-desk(带 token 问 /status)
export async function probeDaemon(port, token, { timeoutMs = 1500 } = {}) {
  if (!Number.isInteger(port) || port <= 0) return false;
  try {
    const r = await fetch(`http://127.0.0.1:${port}/status`, { headers: { authorization: `Bearer ${token ?? ''}` }, signal: AbortSignal.timeout(timeoutMs) });
    if (r.status === 401) return true; // 有人在答且要 token:当作活实例
    if (!r.ok) return false;
    const j = await r.json();
    return j?.ok === true && j?.name === NAME;
  } catch { return false; }
}

/// 拿锁。返回 {ok:true} 或 {ok:false, port}
export async function acquireLock(dir, token) {
  const f = files(dir);
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const fd = openSync(f.lock, 'wx');
      writeSync(fd, String(process.pid));
      closeSync(fd);
      return { ok: true };
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
    }
    let pid = NaN;
    try { pid = Number.parseInt(readFileSync(f.lock, 'utf8').trim(), 10); } catch { /* */ }
    const st = readJson(f.state, null);
    const port = st?.port;
    const answering = await probeDaemon(port, token);
    if (answering) return { ok: false, port };
    if (pidAlive(pid) && pid !== process.pid) {
      // 进程还活着但端口不答:可能正在启动 —— 等一下再看
      await new Promise((r) => setTimeout(r, 1000));
      if (await probeDaemon(readJson(f.state, null)?.port, token)) return { ok: false, port: readJson(f.state, null)?.port };
      if (pidAlive(pid) && attempt < 2) continue;
    }
    try { unlinkSync(f.lock); } catch { /* */ } // 陈旧锁 → 接管
  }
  throw new Error('cannot acquire daemon.lock');
}

/**
 * 启动守护进程。测试用:startDaemon({ stateDir, env, overrides, port:0, spawn, probe, stopTimeoutMs, stdout })
 * 返回 { port, token, stop(), done: Promise, app } 或 { already:true, port }(此时 exitCode 3)
 */
export async function startDaemon(o = {}) {
  const env = o.env ?? process.env;
  const dir = ensureDir(o.stateDir ?? defaultStateDir(env));
  const f = files(dir);
  const out = o.stdout ?? ((ev) => process.stdout.write(`${JSON.stringify(ev)}\n`));
  const log = (m) => { try { appendFileSync(f.log, `${new Date().toISOString()} [${process.pid}] ${m}\n`); } catch { /* */ } };

  let config = loadConfig(dir);
  const token = ensureToken(dir, { env });
  const lock = await acquireLock(dir, token);
  if (!lock.ok) {
    out({ ev: 'already_running', port: lock.port });
    return { already: true, port: lock.port, exitCode: EXIT_ALREADY };
  }
  log(`start v${VERSION} node ${process.version}`);
  const secrets = o.secrets ?? await loadSecrets(dir, { env, ...(o.decrypt ? { decrypt: o.decrypt } : {}) });
  log(`secrets present: ${Object.entries(secretPresence(secrets)).filter(([, v]) => v).map(([k]) => k).join(',') || 'none'}`);

  const listeners = new Set();
  const publish = (type, data) => { for (const l of listeners) { try { l(type, data); } catch { /* */ } } };
  let registry;
  let sessions;

  /// 一条 feed:写 feed.jsonl(总是)+ SSE + 广播到运行中的输出通道(toast / tts;outputs:false 时不广播)
  const notify = (item, { outputs = true } = {}) => {
    const feed = registry?.get('feed');
    const it = feed ? feed.append(item) : { at: new Date().toISOString(), ...item };
    log(`feed kind=${it.kind}`);
    publish('feed', it);
    if (outputs) registry?.broadcast({ title: it.title, text: it.text, kind: it.kind }, { only: ['toast', 'tts'] }).catch(() => {});
    return it;
  };

  const ctx = {
    config: () => config,
    secrets,
    env,
    stateDir: dir,
    log,
    emit: notify,
    session: () => sessions,
    changed: (ch) => publish('channel', registry.statusOf(ch)),
    overrides: o.overrides ?? {},
  };
  const enabled = (id) => config.enabledChannels.includes(id);
  registry = new Registry({ ctx, log, isEnabled: enabled, onChange: (s) => publish('channel', s) });
  await registry.loadDir(o.channelsDir ?? CHANNELS_DIR);
  sessions = new MeetingSessionManager({
    registry, notify, log, spawn: o.spawn ?? nodeSpawn, jitsiHosts: () => config.jitsiHosts,
    ...(o.probe !== undefined ? { probe: o.probe } : {}), stopTimeoutMs: o.stopTimeoutMs,
    onChange: (info) => { publish('session', info); publish('status', statusObj()); },
  });

  for (const id of config.enabledChannels) {
    const ch = registry.get(id);
    if (!ch || id === 'meeting-lares') continue;
    try { if (ch.configured()) await ch.start(); } catch (e) { log(`channel ${id} autostart failed: ${e.message}`); }
  }
  // 提问通道总在
  try { await registry.get('ask')?.start(); } catch { /* */ }

  const statusObj = () => ({
    ok: true, name: NAME, pid: process.pid, version: VERSION, state: sessions.state,
    session: sessions.info(), lastSession: sessions.info(sessions.lastSession), channels: registry.list(),
  });

  const setEnabled = (id, on) => {
    const set = new Set(config.enabledChannels);
    if (on) set.add(id); else set.delete(id);
    config = { ...config, enabledChannels: [...set] };
    try { saveConfig(dir, config); } catch (e) { log(`save config failed: ${e.message}`); }
  };

  let resolveDone;
  const done = new Promise((r) => { resolveDone = r; });
  let stopping = null;
  let api;

  const app = {
    status: statusObj,
    channels: () => registry.list(),
    async join(body) {
      const k = body.k === undefined || body.k === null || body.k === '' ? undefined : Number(body.k);
      try {
        const info = await sessions.join({ link: body.link, k, convenerName: body.convenerName ?? body.convener_name });
        publish('status', statusObj());
        return info;
      } catch (e) {
        if (e instanceof SessionError) throw Object.assign(new Error(e.message), { status: e.status, error: e.code });
        throw e;
      }
    },
    async leave() { const r = await sessions.leave(); publish('status', statusObj()); return r; },
    async startChannel(id) { if (registry.get(id)?.kind === 'meeting' && id !== 'meeting-zoom') throw Object.assign(new Error('会议通道按链接加入,不能单独启动'), { status: 400 }); await registry.start(id); setEnabled(id, true); return registry.statusOf(registry.get(id)); },
    async stopChannel(id) { await registry.stop(id); setEnabled(id, false); return registry.statusOf(registry.get(id)); },
    async ask(text) {
      const ch = registry.get('ask');
      const r = await ch.ask(text);
      notify({ kind: 'answer', title: '炉灵回答', text: r.answer.slice(0, 2000) });
      return r;
    },
    async speak(text) {
      const t = String(text ?? '').trim();
      if (!t) throw Object.assign(new Error('朗读内容为空'), { status: 400 });
      const r = await registry.get('tts').speak(t.slice(0, 1000));
      return { ok: r.ok, engine: r.engine, ...(r.error ? { error: r.error } : {}) };
    },
    feed: (n) => registry.get('feed').read(n),
    quit: () => stop(),
    subscribe: (fn) => { listeners.add(fn); return () => listeners.delete(fn); },
  };

  api = createApiServer({ token, app, log });
  const port = await api.listen(o.port ?? 0);
  writeJsonAtomic(f.state, { pid: process.pid, port, startedAt: new Date().toISOString(), version: VERSION });
  log(`listening 127.0.0.1:${port}`);
  out({ ev: 'listening', port, pid: process.pid });

  async function stop() {
    stopping ??= (async () => {
      log('stopping');
      try { await sessions.shutdown(); } catch (e) { log(`session shutdown: ${e.message}`); }
      await registry.stopAll();
      try { await api.close(); } catch { /* */ }
      try { if (readJson(f.state, null)?.pid === process.pid) unlinkSync(f.state); } catch { /* */ }
      try { if (Number.parseInt(readFileSync(f.lock, 'utf8'), 10) === process.pid) unlinkSync(f.lock); } catch { /* */ }
      log('stopped');
      out({ ev: 'exit', code: 0 });
      resolveDone(0);
    })();
    return stopping;
  }

  return { port, token, stop, done, app, registry, sessions, stateDir: dir };
}

async function main() {
  const d = await startDaemon();
  if (d.already) { process.exitCode = EXIT_ALREADY; return; }
  const onSig = () => { d.stop(); };
  process.on('SIGINT', onSig);
  process.on('SIGBREAK', onSig);
  if (!process.stdin.isTTY) {
    const rl = readline.createInterface({ input: process.stdin });
    rl.on('line', (l) => { try { if (JSON.parse(l)?.cmd === 'stop') d.stop(); } catch { /* */ } });
    rl.on('error', () => {});
    d.done.then(() => rl.close());
  }
  await d.done;
  process.off('SIGINT', onSig);
  process.off('SIGBREAK', onSig);
  process.stdin.unref?.();
  process.exitCode = 0;
  // 兜底:若有句柄挂住,10 s 后硬退
  setTimeout(() => process.exit(0), 10_000).unref();
}

const isMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  main().catch((e) => {
    try { process.stdout.write(`${JSON.stringify({ ev: 'error', message: String(e?.message ?? e) })}\n`); } catch { /* */ }
    process.exitCode = 1;
  });
}
