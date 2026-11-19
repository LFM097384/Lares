#!/usr/bin/env node
// ember-meet · 可达性检查:自动化 Chromium 打开 Teams 网页,报告它是正常渲染还是拦截了自动化。**不登录、不进会、不填任何东西。**
//   node ember-meet/tool/reachability.mjs [--url https://teams.microsoft.com] [--headed] [--profile]
// 输出一行 JSON:{url, finalUrl, title, status, verdict, signals, headless}
import { openBrowser } from '../driver.mjs';
import { DEFAULT_PROFILE } from '../index.mjs';

const argv = process.argv.slice(2);
const url = argv.includes('--url') ? argv[argv.indexOf('--url') + 1] : 'https://teams.microsoft.com';
const headless = !argv.includes('--headed');
const profileDir = argv.includes('--profile') ? DEFAULT_PROFILE : null;

const { page, close } = await openBrowser({ headless, profileDir });
const out = { url, headless };
try {
  const res = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60_000 });
  out.status = res?.status() ?? null;
  await page.waitForTimeout(8000);
  out.finalUrl = page.url().replace(/([?&#]).*$/, '$1…'); // 不打印 query(可能含追踪参数)
  out.title = await page.title();
  const text = (await page.evaluate(() => document.body?.innerText ?? '').catch(() => '')).slice(0, 4000);
  out.signals = {
    signIn: /sign in|登录|login\.microsoftonline/i.test(text + page.url()),
    joinMeeting: /join a meeting|加入会议/i.test(text),
    unsupported: /browser (?:is not|isn't) supported|不支持此浏览器|unsupported browser/i.test(text),
    blocked: /access denied|captcha|unusual traffic|robot|自动化/i.test(text),
    bodyChars: text.length,
  };
  out.verdict = out.signals.blocked || out.signals.unsupported ? 'blocked' : (out.signals.bodyChars > 20 ? 'renders' : 'blank');
} catch (e) {
  out.verdict = 'error';
  out.error = e.message.split('\n')[0];
} finally {
  await close();
}
process.stdout.write(`${JSON.stringify(out)}\n`);
