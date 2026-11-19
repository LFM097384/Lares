#!/usr/bin/env node
// ember-meet · 炉灵(Ember)以「模拟真人访客」身份进 Teams 等网页会议的进程入口。显示名「炉灵」。
// 不注册机器人、不要平台授权:一个真的 Chromium 打开会议链接,像人一样点「在此浏览器上继续」→ 填名字 → 关音视频 → 加入 → 大厅等放行。
// 文字来源 = 平台实时字幕(带说话人名);房间通道 = 会议聊天。LLM 只用 DeepSeek(LARES_AI_LLM_*)。
//
//   node ember-meet/index.mjs --url <会议链接> [--headless] [--profile dir] [--k n] [--memory-dir d] [--convener-name 张伟] [--name 炉灵]
// env:LARES_AI_LLM_BASE_URL / LARES_AI_LLM_API_KEY(或 LARES_AI_LLM_KEY)/ LARES_AI_LLM_MODEL(无 key → 确定性 mock 路径)
//      EMBER_MEET_PROFILE  EMBER_MEET_HEADLESS=1  EMBER_MEMORY_DIR  EMBER_K  EMBER_SCOPE  EMBER_CONVENER_NAME
//      EMBER_PLAYWRIGHT_DIR  EMBER_CHROMIUM_PATH(找 Playwright / Chromium,同 ember-jitsi)
// stdout:一行一个 JSON 元数据事件(ready / state / host / released / ended / error / exit),绝无会话文字。
// stdin:{"cmd":"stop"} 或 SIGINT → 散会、离会、退出。退出码:0 正常;1 崩溃 / 连接断 / 被拒;2 参数。
import path from 'node:path';
import readline from 'node:readline';
import { createHash } from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createEmber, createDeepSeekLLM, AGENT_NAME } from '../ember/index.mjs';
import { meetPort } from './port.mjs';
import { createDriver } from './driver.mjs';
import { matchMeetingUrl, MeetUrlError } from './urls.mjs';
import { adapterByName } from './adapters/index.mjs';

export const EXIT = Object.freeze({ OK: 0, CRASH: 1, BAD_ARGS: 2 });
export class UsageError extends Error {}
const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '..');
export const DEFAULT_PROFILE = path.join(REPO, '.data', 'ember-meet', 'profile');

export function parseArgs(argv) {
  const o = {};
  const need = (i) => { if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) throw new UsageError(`missing value for ${argv[i]}`); return argv[i + 1]; };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--url': o.url = need(i); i++; break;
      case '--k': o.k = Number(need(i)); i++; break;
      case '--memory-dir': o.memoryDir = need(i); i++; break;
      case '--scope': o.scope = need(i); i++; break;
      case '--convener-name': o.convenerName = need(i); i++; break;
      case '--name': o.name = need(i); i++; break;
      case '--profile': o.profile = need(i); i++; break;
      case '--no-profile': o.profile = null; break;
      case '--headless': o.headless = true; break;
      case '--headed': case '--headful': o.headless = false; break;
      case '--lobby-timeout': o.lobbyTimeoutSec = Number(need(i)); i++; break;
      case '--help': case '-h': o.help = true; break;
      default: throw new UsageError(`unknown argument ${a}`);
    }
  }
  if (o.k !== undefined && (!Number.isInteger(o.k) || o.k < 1 || o.k > 20)) throw new UsageError('--k must be an integer 1..20');
  if (o.lobbyTimeoutSec !== undefined && (!Number.isFinite(o.lobbyTimeoutSec) || o.lobbyTimeoutSec < 10)) throw new UsageError('--lobby-timeout must be >= 10 seconds');
  if (o.name !== undefined && !/^.{1,40}$/u.test(o.name)) throw new UsageError('--name must be 1..40 chars');
  return o;
}

/// 解析链接 → {meeting, adapter};不认识 / 未实现 → UsageError
export function resolveMeeting(url) {
  let m;
  try { m = matchMeetingUrl(url); } catch (e) { throw new UsageError(e instanceof MeetUrlError ? `${e.code}: ${e.message}` : e.message); }
  if (!m) throw new UsageError('unsupported meeting link (Teams: https://teams.microsoft.com/l/meetup-join/… or https://teams.live.com/meet/…)');
  if (!m.implemented) throw new UsageError(`${m.label} adapter not implemented yet`);
  return { meeting: m, adapter: adapterByName(m.platform) };
}

/// 记忆作用域:hash(平台 + 会议键) —— 同一个会议链接 = 同一个「圈」
export function scopeOf(meeting) { return createHash('sha256').update(`${meeting.platform}/${meeting.meetingKey}`).digest('hex').slice(0, 24); }

/// 只认 DeepSeek 兼容端点的 LARES_AI_LLM_*;别的 key 一概不读
export async function llmFromEnv(env = process.env) {
  const key = String(env.LARES_AI_LLM_API_KEY ?? '').trim() || String(env.LARES_AI_LLM_KEY ?? '').trim();
  if (!key) return null;
  return createDeepSeekLLM({
    baseUrl: String(env.LARES_AI_LLM_BASE_URL ?? '').trim() || 'https://api.deepseek.com',
    key, model: String(env.LARES_AI_LLM_MODEL ?? '').trim() || 'deepseek-flash', retries: 2, timeoutMs: 60_000,
  });
}

const truthy = (v) => /^(1|true|yes|on)$/i.test(String(v ?? '').trim());

/**
 * 进会并开始会话。返回 { ember, port, driver, stop(code), done }。测试注入 o.driver / o.llm / o.memory。
 */
export async function runEmberMeet(o) {
  const env = o.env ?? process.env;
  const emit = o.emit ?? (() => {});
  const log = o.log ?? ((m) => process.stderr.write(`[ember-meet] ${m}\n`));
  const { meeting, adapter } = o.meeting ? { meeting: o.meeting, adapter: o.adapter } : resolveMeeting(o.url);
  const kEnv = Number(String(env.EMBER_K ?? '').trim() || NaN);
  const k = o.k ?? (Number.isInteger(kEnv) && kEnv >= 1 ? kEnv : null);
  const scopeId = o.scope ?? env.EMBER_SCOPE ?? scopeOf(meeting);
  const memoryDir = o.memoryDir ?? path.join(env.EMBER_MEMORY_DIR || path.join(REPO, '.data', 'ember-meet', 'memory'), scopeId);
  const name = o.name ?? AGENT_NAME;
  const headless = o.headless ?? truthy(env.EMBER_MEET_HEADLESS);
  const profileDir = o.profile === null ? null : (o.profile ?? env.EMBER_MEET_PROFILE ?? DEFAULT_PROFILE);
  const driver = o.driver ?? createDriver({
    adapter, url: meeting.link, displayName: name, log,
    browser: { headless, profileDir, env },
    joinOpts: o.lobbyTimeoutSec ? { lobbyTimeoutMs: o.lobbyTimeoutSec * 1000 } : {},
  });
  driver.on('state', (s) => emit({ ev: 'state', state: String(s) }));
  const port = meetPort(driver, {
    log, selfName: name, platformLabel: adapter?.label ?? '会议',
    convenerName: o.convenerName ?? env.EMBER_CONVENER_NAME ?? null,
    onHost: (ev) => emit({ ev: 'host', ...ev }),
    meter: (m) => emit(m),
  });
  const llm = o.llm !== undefined ? o.llm : await llmFromEnv(env);

  let resolveDone;
  const done = new Promise((r) => { resolveDone = r; });
  let stopping = null;
  let ember = null;
  const stop = (code = EXIT.OK) => {
    stopping ??= (async () => {
      const hard = setTimeout(() => resolveDone(code), 8000);
      hard.unref?.();
      try { await ember?.session.end('stop'); } catch { /* */ }
      await new Promise((r) => setTimeout(r, 600)); // 让散会回执发到聊天
      try { await port.leave(); } catch { /* */ }
      clearTimeout(hard);
      resolveDone(code);
    })();
    return stopping.then(() => done);
  };

  ember = await createEmber({
    port, llm, asr: null, memoryDir, memory: o.memory, skills: o.skills, log, emit,
    policy: { k, convenerId: null, scopeId },
    onEnded: () => { setTimeout(() => stop(EXIT.OK), 300).unref?.(); },
    sessionOpts: o.sessionOpts ?? {}, autoLeave: false,
  });
  port.on('disconnected', (why) => {
    log(`连接断开(${why})`);
    emit({ ev: 'error', where: 'meet', message: String(why) });
    stop(ember.session.ended || why === 'meeting_ended' ? EXIT.OK : EXIT.CRASH);
  });
  await ember.start();
  emit({ ev: 'ready', platform: meeting.platform, selfId: port.selfId, llm: Boolean(llm), captions: driver.stats?.captionsEnabled ?? null, chat: driver.stats?.chatOpened ?? null, memory: ember.memory.kind, k: k ?? 'auto' });
  return { ember, port, driver, memoryDir, scopeId, stop, done };
}

const USAGE = 'usage: node ember-meet/index.mjs --url <meeting link> [--headless|--headed] [--profile dir|--no-profile] [--k n] [--memory-dir dir] [--convener-name name] [--name 炉灵] [--lobby-timeout sec] [--scope id]';

export async function main(argv = process.argv.slice(2), env = process.env, { stdin = process.stdin, out = (ev) => process.stdout.write(`${JSON.stringify(ev)}\n`), run = runEmberMeet } = {}) {
  const fatal = (code, message) => { out({ ev: 'error', message }); out({ ev: 'exit', code }); return code; };
  let args;
  try {
    args = parseArgs(argv);
    if (args.help) { process.stderr.write(`${USAGE}\n`); return EXIT.OK; }
    if (!args.url) throw new UsageError('--url is required');
    resolveMeeting(args.url);
  } catch (e) {
    process.stderr.write(`${USAGE}\n`);
    return fatal(EXIT.BAD_ARGS, `bad_args: ${e.message}`);
  }
  let bot;
  try {
    bot = await run({ ...args, env, emit: out });
  } catch (e) {
    if (e instanceof UsageError) return fatal(EXIT.BAD_ARGS, e.message);
    return fatal(EXIT.CRASH, `start_failed: ${e.code ? `${e.code}: ` : ''}${e.message}`);
  }
  const onSig = () => bot.stop(EXIT.OK);
  process.once('SIGINT', onSig);
  process.once('SIGTERM', onSig);
  const rl = readline.createInterface({ input: stdin });
  rl.on('line', (line) => { let m; try { m = JSON.parse(line); } catch { return; } if (m?.cmd === 'stop') bot.stop(EXIT.OK); });
  const code = await bot.done;
  rl.close();
  stdin.unref?.();
  process.off('SIGINT', onSig);
  process.off('SIGTERM', onSig);
  out({ ev: 'exit', code });
  return code;
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().then((code) => { process.exitCode = code; setTimeout(() => process.exit(code), 1500).unref(); }, (e) => {
    process.stdout.write(`${JSON.stringify({ ev: 'error', message: String(e?.message ?? e) })}\n`);
    process.exitCode = EXIT.CRASH;
  });
}
