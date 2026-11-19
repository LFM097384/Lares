// 会议通道 · Microsoft Teams:按需托管 `node ember-meet/index.mjs --url <链接> ...` 子进程(由 session.mjs 监管)。
// ember-meet 用 Playwright Chromium 模拟一位访客「炉灵」走 Teams 网页的匿名加入流程(不注册机器人、不要租户授权),
// 文字来自 Teams 实时字幕,命令和输出走会议聊天。
// configured = ember-meet 入口存在 + playwright 可解析(同 ember-jitsi/deps.mjs 的查找顺序)。
// 覆盖(测试 / e2e):ctx.overrides.teams = { entry, extraArgs, env, skipPlaywrightCheck, command }
//   或 env EMBER_DESK_MEET_ENTRY(换入口,同时跳过 playwright 检查)、EMBER_DESK_MEET_ARGS(JSON 字符串数组,追加参数,如 ["--headless"])
import path from 'node:path';
import { existsSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { MEET_ENTRY, REPO } from '../paths.mjs';
import { childEnv } from '../config.mjs';

function playwrightResolvable(env) {
  for (const pkg of ['server', 'ember-jitsi', 'ember-meet']) {
    try { createRequire(path.join(REPO, pkg, 'package.json')).resolve('playwright'); return true; } catch { /* */ }
  }
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

export default function meetingTeams(ctx) {
  const env = ctx.env ?? process.env;
  const ov = ctx.overrides?.teams ?? {};
  const entry = ov.entry ?? (env.EMBER_DESK_MEET_ENTRY || MEET_ENTRY);
  const skipPw = ov.skipPlaywrightCheck ?? Boolean(ov.entry || env.EMBER_DESK_MEET_ENTRY);
  let pwCache = null;
  const pwOk = () => (skipPw ? true : (pwCache ??= playwrightResolvable(env)));
  const configured = () => existsSync(entry) && pwOk();
  const session = () => ctx.session?.();
  const active = () => session()?.session?.adapter === 'teams';

  return {
    id: 'meeting-teams',
    kind: 'meeting',
    name: 'Teams 会议',
    describe: () => '把炉灵以访客身份送进 Microsoft Teams 会议(模拟网页客户端,需组织者从大厅放行、允许实时字幕);纪要只在会议聊天里发',
    configured,
    async start() { /* 按需:join 时才拉起子进程 */ },
    async stop() { if (active()) await session().leave(); },
    status() {
      let detail;
      if (!existsSync(entry)) detail = '找不到 ember-meet/index.mjs';
      else if (!pwOk()) detail = '找不到 playwright(npx playwright install chromium,或设 EMBER_PLAYWRIGHT_DIR)';
      else if (active()) detail = `会议中:${session().session.room ?? ''}(${session().state})`;
      else detail = '就绪,粘贴 Teams 会议链接即可加入';
      return { running: active(), detail };
    },
    /// session.mjs 调用:返回要拉起的命令
    prepareJoin(parsed, { k, convenerName }) {
      if (!existsSync(entry)) throw Object.assign(new Error('Teams 插件(ember-meet)不存在'), { status: 400, code: 'not_configured' });
      if (!pwOk()) throw Object.assign(new Error('Teams 插件需要 playwright Chromium:先运行 npx playwright install chromium'), { status: 400, code: 'not_configured' });
      const cfg = ctx.config();
      const secrets = ctx.secrets ?? {};
      const args = [entry, '--url', parsed.link];
      const kk = k ?? cfg.defaultK;
      if (kk) args.push('--k', String(kk));
      const cn = convenerName ?? cfg.convenerName;
      if (cn) args.push('--convener-name', cn);
      args.push(...(ov.extraArgs ?? []), ...parseExtraArgs(env.EMBER_DESK_MEET_ARGS));
      return { command: ov.command ?? process.execPath, args, env: childEnv(secrets, env, ov.env ?? {}), cwd: REPO };
    },
  };
}
