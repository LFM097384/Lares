// Local-target helpers for the *_prod_e2e tools (`--local` or env LARES_E2E_TARGET=local).
// The local stack is started by server/tool/local_stack.ps1: livekit-server --dev + node src/index.js
// on 127.0.0.1:<port>, stdout/stderr → .local-server/server.log, data dir .local-server/data.
// Replaces the prod SSH paths: log stream → tail of server.log; data dir → local fs; DashScope key → env / CSV;
// `docker top` → local process list (Win32_Process command lines).
// Secrets stay in memory only (never printed, never written).

import { spawn } from 'node:child_process';
import { existsSync, readFileSync, statSync, openSync, readSync, closeSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '..', '..');
export const LOCAL = process.argv.includes('--local') || String(process.env.LARES_E2E_TARGET ?? '').toLowerCase() === 'local';
export const LOCAL_PORT = Number(process.env.LARES_E2E_PORT ?? 8787);
export const LOCAL_HTTP = `http://127.0.0.1:${LOCAL_PORT}`;
export const LOCAL_WS = `ws://127.0.0.1:${LOCAL_PORT}/ws`;
export const LOCAL_ROOT = process.env.LARES_LOCAL_ROOT ?? path.join(REPO, '.local-server');
export const LOCAL_LOG = path.join(LOCAL_ROOT, 'server.log');
export const LOCAL_DATA = path.join(LOCAL_ROOT, 'data');
const KEY_CSV = process.env.LARES_KEY_CSV ?? 'C:\\Users\\Liu_F\\Downloads\\默认业务空间-apiKey-6421725.csv';

/// DashScope key: env first, else the apiKey row of the CSV. Memory only.
export function localDashscopeKey() {
  if (process.env.LARES_DASHSCOPE_API_KEY) return process.env.LARES_DASHSCOPE_API_KEY.trim();
  if (!existsSync(KEY_CSV)) return '';
  for (const line of readFileSync(KEY_CSV, 'utf8').split(/\r?\n/)) {
    const [k, ...v] = line.split(',');
    if (k?.trim() === 'apiKey') return v.join(',').trim();
  }
  return '';
}

/// Follows server.log from its current end (like `docker logs -f --since now`). onLine(line) per complete line.
export function tailLog(onLine, { file = LOCAL_LOG, intervalMs = 200 } = {}) {
  let pos = existsSync(file) ? statSync(file).size : 0;
  let buf = Buffer.alloc(0);
  const tick = () => {
    if (!existsSync(file)) return;
    const size = statSync(file).size;
    if (size < pos) pos = 0; // truncated / rotated
    if (size === pos) return;
    const fd = openSync(file, 'r');
    try {
      const chunk = Buffer.alloc(size - pos);
      readSync(fd, chunk, 0, chunk.length, pos);
      pos = size;
      buf = Buffer.concat([buf, chunk]);
    } finally { closeSync(fd); }
    let i;
    while ((i = buf.indexOf(10)) >= 0) {
      const l = buf.subarray(0, i).toString('utf8').replace(/\r$/, '');
      buf = buf.subarray(i + 1);
      if (l.trim()) onLine(l);
    }
  };
  const t = setInterval(tick, intervalMs);
  tick();
  return { stop: () => { clearInterval(t); tick(); }, get alive() { return existsSync(file); } };
}

/// server.log bytes written since `fromSize` (for the post-run scan).
export function logSince(fromSize, file = LOCAL_LOG) {
  if (!existsSync(file)) return { ok: false, text: '' };
  const size = statSync(file).size;
  const start = fromSize > size ? 0 : fromSize;
  const fd = openSync(file, 'r');
  try { const b = Buffer.alloc(size - start); readSync(fd, b, 0, b.length, start); return { ok: true, text: b.toString('utf8') }; } finally { closeSync(fd); }
}
export const logSize = (file = LOCAL_LOG) => (existsSync(file) ? statSync(file).size : 0);

/// Like the prod memDir(): {exists, files:[{f, s}]} under DATA_DIR/anonym_memory/<cid>.
export function localMemDir(cid) {
  const d = path.join(LOCAL_DATA, 'anonym_memory', cid);
  if (!existsSync(d)) return { exists: false };
  const files = [];
  const w = (x) => { for (const e of readdirSync(x, { withFileTypes: true })) { const f = path.join(x, e.name); if (e.isDirectory()) w(f); else files.push({ f: path.relative(d, f), s: readFileSync(f, 'utf8') }); } };
  try { w(d); } catch (e) { return { error: String(e.message) }; }
  return { exists: true, files };
}

/// Local analogue of `docker top`: "pid args" lines of node processes (command line only, env is not visible).
export function localProcs() {
  return new Promise((resolve) => {
    const ps = 'Get-CimInstance Win32_Process -Filter "Name=\'node.exe\'" | ForEach-Object { "$($_.ProcessId) $($_.CommandLine)" }';
    const p = spawn('powershell.exe', ['-NoProfile', '-Command', ps], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.on('error', () => resolve({ code: -1, out: '' }));
    p.on('close', (code) => resolve({ code, out }));
  });
}
