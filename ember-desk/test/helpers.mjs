// 测试共用:临时状态目录、进程内守护进程(无机密、假插件、通知 / 朗读走桩)。
import os from 'node:os';
import path from 'node:path';
import { mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { startDaemon } from '../daemon.mjs';
import { SECRET_KEYS } from '../config.mjs';

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const FAKE_PLUGIN = path.join(HERE, 'fixtures', 'fake-plugin.mjs');
export const DESK = path.join(HERE, '..');

export function tmpDir(t) {
  const d = mkdtempSync(path.join(os.tmpdir(), 'ember-desk-test-'));
  t?.after?.(() => { try { rmSync(d, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }); } catch { /* */ } });
  return d;
}

/// 去掉机密的 env(测试绝不调用真 LLM / DashScope)
export function cleanEnv(extra = {}) {
  const e = { ...process.env };
  for (const k of [...SECRET_KEYS, 'LARES_AI_LLM_API_KEY', 'EMBER_DESK_JITSI_ENTRY', 'EMBER_DESK_JITSI_ARGS']) delete e[k];
  return { ...e, ...extra };
}

export function stubRun(calls = []) {
  return async (exe, script, o) => { calls.push({ exe, script, payload: o?.payload }); return { code: 0, stdout: 'ok' }; };
}

export async function testDaemon(t, { dir = tmpDir(t), fakeMode = 'ok', env = {}, stopTimeoutMs = 3000, ...rest } = {}) {
  const toastCalls = [];
  const ttsCalls = [];
  const d = await startDaemon({
    stateDir: dir,
    env: cleanEnv({ FAKE_MODE: fakeMode, ...env }),
    secrets: {},
    probe: async () => false,
    stopTimeoutMs,
    stdout: () => {},
    overrides: {
      jitsi: { entry: FAKE_PLUGIN, env: { FAKE_MODE: fakeMode, ...env } },
      toast: { run: stubRun(toastCalls), engine: 'winrt' },
      tts: { run: stubRun(ttsCalls) },
      mic: { ffmpegOk: false },
      ...(rest.overrides ?? {}),
    },
    ...rest,
  });
  t?.after?.(async () => { if (!d.already) await d.stop(); });
  return Object.assign(d, { dir, toastCalls, ttsCalls });
}

export async function req(d, method, p, { body, token = d.token, headers = {}, raw } = {}) {
  const r = await fetch(`http://127.0.0.1:${d.port}${p}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined),
  });
  let j = null;
  const txt = await r.text();
  try { j = JSON.parse(txt); } catch { j = txt; }
  return { status: r.status, body: j };
}

export async function waitFor(fn, { timeoutMs = 8000, stepMs = 30 } = {}) {
  const until = Date.now() + timeoutMs;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > until) throw new Error('waitFor timeout');
    await new Promise((r) => setTimeout(r, stepMs));
  }
}
