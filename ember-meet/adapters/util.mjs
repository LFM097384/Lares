// ember-meet · adapter 共用的 Playwright 小工具(不含平台知识)。
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export class AdapterError extends Error {
  constructor(code, message) { super(message); this.name = 'AdapterError'; this.code = code; }
}

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const PROBE_SOURCE = readFileSync(path.join(HERE, '..', 'page', 'probe.js'), 'utf8');

/// 页面里没有探针就注入一次(driver 也用 addInitScript 预装;导航后这里兜底)
export async function ensureProbe(page) {
  const has = await page.evaluate(() => Boolean(window.__emberMeet)).catch(() => false);
  if (!has) await page.evaluate(PROBE_SOURCE).catch(() => {});
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// 一组候选选择器里第一个「可见」的 locator;都不可见 → null。不等待(调用方自己轮询)。
export async function firstVisible(page, selectors) {
  for (const sel of selectors) {
    const loc = page.locator(sel).first();
    try { if (await loc.isVisible()) return loc; } catch { /* 选择器语法在这个引擎里不成立 → 下一个 */ }
  }
  return null;
}

export async function anyVisible(page, selectors) { return Boolean(await firstVisible(page, selectors)); }

/// 轮询直到某组可见,超时返回 null
export async function waitVisible(page, selectors, timeoutMs = 5000, stepMs = 200) {
  const t0 = Date.now();
  for (;;) {
    const l = await firstVisible(page, selectors);
    if (l) return l;
    if (Date.now() - t0 >= timeoutMs) return null;
    await sleep(stepMs);
  }
}

export async function clickFirst(page, selectors, { timeoutMs = 0 } = {}) {
  const l = timeoutMs ? await waitVisible(page, selectors, timeoutMs) : await firstVisible(page, selectors);
  if (!l) return false;
  try { await l.click({ timeout: 3000 }); return true; } catch { return false; }
}

/// 开关的当前状态(probe.switchState):true 开 / false 关 / null 看不出
export async function switchState(loc) {
  try { return await loc.evaluate((el) => window.__emberMeet?.switchState(el) ?? null); } catch { return null; }
}
