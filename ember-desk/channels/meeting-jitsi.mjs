// 会议通道 · Jitsi:按需托管 `node ember-jitsi/index.mjs --room R --url U ...` 子进程(由 session.mjs 监管)。
// configured = ember-jitsi 入口存在 + playwright 可解析(同 ember-jitsi/deps.mjs 的查找顺序)。
// 覆盖(测试 / e2e):ctx.overrides.jitsi = { entry, extraArgs, env, skipPlaywrightCheck }
//   或 env EMBER_DESK_JITSI_ENTRY(换入口,同时跳过 playwright 检查)、EMBER_DESK_JITSI_ARGS(JSON 字符串数组,追加参数,如 ["--asr","mock","--memory-dir","D:/tmp/m"])
import path from 'node:path';
import { existsSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { JITSI_ENTRY, REPO } from '../paths.mjs';
import { childEnv } from '../config.mjs';

function playwrightResolvable(env) {
  try { createRequire(path.join(REPO, 'server', 'package.json')).resolve('playwright'); return true; } catch { /* */ }
  try { createRequire(path.join(REPO, 'ember-jitsi', 'package.json')).resolve('playwright'); return true; } catch { /* */ }
  if (env.EMBER_PLAYWRIGHT_DIR && existsSync(path.join(env.EMBER_PLAYWRIGHT_DIR, 'package.json'))) return true;
  const roots = [path.join(env.LOCALAPPDATA || '', 'npm-cache', '_npx'), path.join(env.USERPROFILE || env.HOME || '', '.npm', '_npx')];
  return roots.some((r) => {
    try { return r && existsSync(r) && readdirSync(r).some((d) => existsSync(path.join(r, d, 'node_modules', 'playwright', 'package.json'))); } catch { return false; }
  });
}

function parseExtraArgs(raw) {
  if (!raw) return [];
  try { const a = JSON.parse(raw); return Array.isArray(a) ? a.map(String) : []; } catch { return []; }
}

export default function meetingJitsi(ctx) {
  const env = ctx.env ?? process.env;
  const ov = ctx.overrides?.jitsi ?? {};
  const entry = ov.entry ?? (env.EMBER_DESK_JITSI_ENTRY || JITSI_ENTRY);
  const skipPw = ov.skipPlaywrightCheck ?? Boolean(ov.entry || env.EMBER_DESK_JITSI_ENTRY);
  let pwCache = null;
  const pwOk = () => (skipPw ? true : (pwCache ??= playwrightResolvable(env)));
  const configured = () => existsSync(entry) && pwOk();
  const session = () => ctx.session?.();
  const active = () => session()?.session?.adapter === 'jitsi';

  return {
    id: 'meeting-jitsi',
    kind: 'meeting',
    name: 'Jitsi 会议',
    describe: () => '把炉灵送进 Jitsi Meet 会议(无头 Chromium);会后放行的纪要只在会议聊天里发',
    configured,
    async start() { /* 按需:join 时才拉起子进程 */ },
    async stop() { if (active()) await session().leave(); },
    status() {
      let detail;
      if (!existsSync(entry)) detail = '找不到 ember-jitsi/index.mjs';
      else if (!pwOk()) detail = '找不到 playwright(npx playwright install chromium,或设 EMBER_PLAYWRIGHT_DIR)';
      else if (active()) detail = `会议中:${session().session.room ?? ''}(${session().state})`;
      else detail = '就绪,粘贴 Jitsi 链接即可加入';
      return { running: active(), detail };
    },
    /// session.mjs 调用:返回要拉起的命令
    prepareJoin(parsed, { k, convenerName }) {
      if (!existsSync(entry)) throw Object.assign(new Error('Jitsi 插件(ember-jitsi)不存在'), { status: 400, code: 'not_configured' });
      if (!pwOk()) throw Object.assign(new Error('Jitsi 插件需要 playwright 无头 Chromium:先运行 npx playwright install chromium'), { status: 400, code: 'not_configured' });
      const cfg = ctx.config();
      const secrets = ctx.secrets ?? {};
      let asr = cfg.asr ?? 'dashscope';
      if (asr === 'dashscope' && !secrets.LARES_DASHSCOPE_API_KEY) { asr = 'none'; ctx.log?.('jitsi: no DashScope key → --asr none'); }
      const args = [entry, '--room', parsed.room, '--url', parsed.url, '--asr', asr];
      const kk = k ?? cfg.defaultK;
      if (kk) args.push('--k', String(kk));
      const cn = convenerName ?? cfg.convenerName;
      if (cn) args.push('--convener-name', cn);
      args.push(...(ov.extraArgs ?? []), ...parseExtraArgs(env.EMBER_DESK_JITSI_ARGS));
      // ember-jitsi parseArgs 后写覆盖,所以 extraArgs 里的 --asr / --memory-dir 生效
      return { command: ov.command ?? process.execPath, args, env: childEnv(secrets, env, ov.env ?? {}), cwd: REPO };
    },
  };
}
