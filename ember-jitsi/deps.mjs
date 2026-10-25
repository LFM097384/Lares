// ember-jitsi · 外部依赖解析:playwright(无头 Chromium)与 ws(DashScope ASR)。
// 仓库根没有 node_modules:ws 从 server/node_modules 解析(同 lares-bridge/deps.mjs);
// playwright 依次试:裸 import → EMBER_PLAYWRIGHT_DIR(包目录)→ server/node_modules → npx 缓存(%LOCALAPPDATA%\npm-cache\_npx\*\node_modules\playwright)。
import path from 'node:path';
import { existsSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVER_PKG = path.join(HERE, '..', 'server', 'package.json');

export async function importDep(name) {
  let last;
  try { return await import(name); } catch (e) { last = e; }
  try { return await import(pathToFileURL(createRequire(SERVER_PKG).resolve(name)).href); } catch (e) { last = e; }
  throw last;
}

export function playwrightCandidates(env = process.env) {
  const out = [];
  if (env.EMBER_PLAYWRIGHT_DIR) out.push(env.EMBER_PLAYWRIGHT_DIR);
  const npx = path.join(env.LOCALAPPDATA || path.join(env.HOME || '', '.npm'), 'npm-cache', '_npx');
  const npx2 = path.join(env.HOME || env.USERPROFILE || '', '.npm', '_npx');
  for (const root of [npx, npx2]) {
    if (!existsSync(root)) continue;
    for (const d of readdirSync(root)) {
      const p = path.join(root, d, 'node_modules', 'playwright');
      if (existsSync(path.join(p, 'package.json'))) out.push(p);
    }
  }
  return out;
}

let pw = null;
export async function loadPlaywright(env = process.env) {
  if (pw) return pw;
  try { pw = await importDep('playwright'); return pw; } catch { /* */ }
  for (const dir of playwrightCandidates(env)) {
    try { pw = await import(pathToFileURL(path.join(dir, 'index.mjs')).href); return pw; } catch { /* */ }
  }
  throw new Error('ember-jitsi: playwright not found (npx playwright install chromium, or set EMBER_PLAYWRIGHT_DIR)');
}

/// Chromium 可执行文件:EMBER_CHROMIUM_PATH → null(交给 playwright 默认)。
/// 默认版本没下载时(playwright 包比浏览器新),退回 ms-playwright 下已有的最新 headless shell / chromium。
export function chromiumFallbacks(env = process.env) {
  const out = [];
  if (env.EMBER_CHROMIUM_PATH) out.push(env.EMBER_CHROMIUM_PATH);
  const root = env.PLAYWRIGHT_BROWSERS_PATH || path.join(env.LOCALAPPDATA || path.join(env.HOME || '', '.cache'), 'ms-playwright');
  if (!existsSync(root)) return out;
  const dirs = readdirSync(root).filter((d) => /^chromium(_headless_shell)?-\d+$/.test(d)).sort((a, b) => Number(b.split('-').pop()) - Number(a.split('-').pop()) || (a.includes('headless') ? -1 : 1));
  for (const d of dirs) {
    for (const rel of ['chrome-headless-shell-win64/chrome-headless-shell.exe', 'chrome-win64/chrome.exe', 'chrome-headless-shell-linux64/chrome-headless-shell', 'chrome-linux/chrome', 'chrome-linux64/chrome']) {
      const p = path.join(root, d, rel);
      if (existsSync(p)) out.push(p);
    }
  }
  return out;
}

export async function launchChromium(opts = {}, env = process.env) {
  const { chromium } = await loadPlaywright(env);
  if (env.EMBER_CHROMIUM_PATH) return chromium.launch({ ...opts, executablePath: env.EMBER_CHROMIUM_PATH });
  try { return await chromium.launch(opts); } catch (e) {
    if (!/Executable doesn't exist/i.test(String(e?.message))) throw e;
    for (const p of chromiumFallbacks(env)) { try { return await chromium.launch({ ...opts, executablePath: p }); } catch { /* next */ } }
    throw e;
  }
}

export async function loadWs() {
  const m = await importDep('ws');
  return m.WebSocket ?? m.default;
}
