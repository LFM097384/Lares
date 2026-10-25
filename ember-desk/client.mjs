// ember-desk · 客户端共用:读 state / token,api(method, path, body),ensureDaemon()(没在跑就隐藏拉起 node daemon.mjs)。
import { spawn } from 'node:child_process';
import { stateDir as defaultStateDir, files, DAEMON_ENTRY, NAME } from './paths.mjs';
import { readJson, readToken as readTokenFile } from './config.mjs';

export class ApiError extends Error {
  constructor(status, body) { super(body?.message ?? body?.error ?? `HTTP ${status}`); this.status = status; this.body = body; }
}
export class NotRunningError extends Error {
  constructor() { super('炉灵守护进程没有在运行'); this.code = 'not_running'; }
}

export const readState = (dir = defaultStateDir()) => readJson(files(dir).state, null);
export const readToken = (dir = defaultStateDir()) => readTokenFile(dir);

export async function api(method, path, body, { dir = defaultStateDir(), timeoutMs = 60_000 } = {}) {
  const st = readState(dir);
  const token = readToken(dir);
  if (!st?.port || !token) throw new NotRunningError();
  let r;
  try {
    r = await fetch(`http://127.0.0.1:${st.port}${path}`, {
      method,
      headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    if (e?.name === 'TimeoutError') throw e;
    throw new NotRunningError();
  }
  let j = null;
  try { j = await r.json(); } catch { /* */ }
  if (!r.ok) throw new ApiError(r.status, j);
  return j;
}

export async function isRunning({ dir = defaultStateDir() } = {}) {
  try { const s = await api('GET', '/status', undefined, { dir, timeoutMs: 2000 }); return s?.ok === true && s?.name === NAME ? s : null; } catch { return null; }
}

/// 没在跑 → 拉起(detached、隐藏窗口、stdio ignore、unref),轮询 /status 直到就绪
export async function ensureDaemon({ dir = defaultStateDir(), timeoutMs = 15_000, env = process.env, nodePath = process.execPath, entry = DAEMON_ENTRY } = {}) {
  const have = await isRunning({ dir });
  if (have) return have;
  const child = spawn(nodePath, [entry], { detached: true, windowsHide: true, stdio: 'ignore', env: { ...env, EMBER_DESK_HOME: dir } });
  child.on('error', () => {});
  child.unref();
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    await new Promise((r) => setTimeout(r, 200));
    const s = await isRunning({ dir });
    if (s) return s;
  }
  throw new Error('炉灵守护进程启动超时');
}
