#!/usr/bin/env node
// lares.ai-voice 机器人进程。接口契约见 ./CONTRACT.md(CLI / 环境变量 / stdout JSON / 退出码)。
//
// 进程内使用(测试 harness):
//   import { runVoiceBot } from './index.mjs';
//   const bot = await runVoiceBot({ circleId, signaling, passcode, providers: 'mock', emit: (ev) => … });
//   … await bot.stop();
// 或者只要回合引擎、不进房:createAgent({ config, providers, sink, room })(见 pipeline.mjs VoiceAgent)。

import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';
import readline from 'node:readline';
import { normalizeAiVoiceConfig } from './config.mjs';
import { CostGuard } from './caps.mjs';
import { VoiceAgent } from './pipeline.mjs';
import { createProviders } from './providers/index.mjs';
import { LaresRoom, AuthError, CircleGoneError, E2eeRequiredError, defaultAiUserId } from './room.mjs';

export const EXIT = Object.freeze({ OK: 0, BAD_ARGS: 2, AUTH: 3, DAILY_CAP: 4 });

export class UsageError extends Error {}

export function parseArgs(argv) {
  const o = { providers: undefined, authV2: false, e2ee: false };
  const need = (i) => { if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) throw new UsageError(`missing value for ${argv[i]}`); return argv[i + 1]; };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--circle': o.circleId = need(i); i++; break;
      case '--signaling': o.signaling = need(i); i++; break;
      case '--passcode': o.passcode = need(i); i++; break;
      case '--auth-v2': o.authV2 = true; break;
      case '--e2ee': o.e2ee = true; break;
      case '--config': o.configPath = need(i); i++; break;
      case '--providers': o.providers = need(i); i++; break;
      case '--user-id': o.userId = need(i); i++; break;
      case '--name': o.name = need(i); i++; break;
      case '--help': case '-h': o.help = true; break;
      default: throw new UsageError(`unknown argument ${a}`);
    }
  }
  return o;
}

/// 读配置:--config 文件 > LARES_AI_CONFIG > {};--name 覆盖 config.name。
export function loadConfig({ configPath, name, env = process.env }) {
  let raw = {};
  if (configPath) raw = JSON.parse(readFileSync(configPath, 'utf8'));
  else if (env.LARES_AI_CONFIG) raw = JSON.parse(env.LARES_AI_CONFIG);
  if (name) raw = { ...raw, name };
  const r = normalizeAiVoiceConfig(raw);
  if (!r.ok) throw new UsageError(`bad config: ${r.detail}`);
  return r.config;
}

/**
 * 进房并开始服务。返回 { agent, room, config, stop(), done: Promise<exitCode> }。
 * @param {object} o
 * @param {string} o.circleId
 * @param {string} [o.signaling]
 * @param {string} [o.passcode]
 * @param {boolean} [o.authV2]
 * @param {string} [o.authSecret]  服务端托管:HMAC 密钥(env LARES_AI_AUTH_SECRET)
 * @param {1|2} [o.authV]
 * @param {boolean} [o.e2ee]
 * @param {object} [o.config]       未归一化也行
 * @param {'dashscope'|'mock'|object} [o.providers]  也可直接传 {asr,llm,tts}
 * @param {object} [o.mock]         mock provider 参数
 * @param {string} [o.userId]
 * @param {string} [o.usageFile]
 * @param {(ev:object)=>void} [o.emit]
 * @param {(m:string)=>void} [o.log]
 * @param {boolean} [o.logText]
 * @param {object} [o.env]
 */
export async function runVoiceBot(o) {
  const env = o.env ?? process.env;
  const emit = o.emit ?? (() => {});
  const log = o.log ?? ((m) => process.stderr.write(`[ai-voice] ${m}\n`));
  const nc = normalizeAiVoiceConfig(o.config ?? {});
  if (!nc.ok) throw new UsageError(`bad config: ${nc.detail}`);
  let config = nc.config;
  const providers = typeof o.providers === 'object' && o.providers
    ? o.providers
    : await createProviders(o.providers ?? 'dashscope', { env, mock: o.mock });
  const room = new LaresRoom({
    circleId: o.circleId,
    // u_ai_* 是服务端保留前缀,只有托管进程(带 LARES_AI_MEMBER_SECRET)能用;独立运行退回普通成员 id
    userId: o.userId ?? ((o.memberSecret ?? env.LARES_AI_MEMBER_SECRET) ? defaultAiUserId(o.circleId) : defaultAiUserId(o.circleId).replace(/^u_ai_/, 'u_aibot_')),
    name: config.name,
    signaling: o.signaling ?? env.LARES_SIGNALING ?? 'ws://127.0.0.1:8787/ws',
    authSecret: o.authSecret,
    memberSecret: o.memberSecret ?? env.LARES_AI_MEMBER_SECRET ?? undefined,
    authV: o.authV ?? (o.authV2 ? 2 : 1),
    passcode: o.passcode,
    e2ee: o.e2ee === true,
    log,
  });

  let resolveDone;
  const done = new Promise((r) => { resolveDone = r; });
  let stopping = null;
  const guard = new CostGuard({ usageFile: o.usageFile ?? env.LARES_AI_USAGE_FILE ?? null, config, emit });
  const stop = (code = EXIT.OK) => {
    stopping ??= (async () => {
      const hard = setTimeout(() => resolveDone(code), 2500);
      hard.unref?.();
      try { await agent?.close(); } catch { /* */ }
      try { await room.leave(); } catch { /* */ }
      clearTimeout(hard);
      resolveDone(code);
    })();
    return stopping.then(() => done);
  };

  if (!guard.check().ok && guard.check().reason === 'daily') {
    emit({ ev: 'cap_reached', scope: 'daily', turns: guard.turnsToday() });
    return { agent: null, room, config, stop: async () => EXIT.DAILY_CAP, done: Promise.resolve(EXIT.DAILY_CAP) };
  }

  let agent = null;
  // 处理器先挂(room.join 内部在 connect 之前注册 LiveKit 事件)
  room.on('audio', (id, data, rate, ch) => agent?.onAudioFrame(id, data, rate, ch));
  room.on('chat', (m) => agent?.onChat(m));
  room.on('capctl', (id, m) => agent?.onCaptionControl(id, m));
  room.on('names', (id, n) => agent?.setName(id, n));
  room.on('left', (id) => agent?.participantLeft(id));
  room.on('joined', () => agent?.republishState());
  room.on('disconnected', (why) => {
    if (why === 'circle_deleted') { log('圈子已解散,退出'); stop(EXIT.OK); return; }
    log(`连接断开(${why})`);
    emit({ ev: 'error', where: 'room', message: String(why) });
    stop(1);
  });

  agent = new VoiceAgent({
    config,
    providers,
    sink: { captureFrame: () => {}, clear: () => {}, queuedMs: () => 0 }, // 进房后替换
    room: { publishCaption: (c) => room.publishCaption(c), sendChat: (t) => room.sendChat(t), publishState: (f) => room.publishState(f) },
    selfIdentity: room.userId,
    emit,
    guard,
    log,
    logText: o.logText ?? env.LARES_AI_LOG_TEXT === '1',
    onDailyCap: () => { log('今日回答次数已满,退出'); stop(EXIT.DAILY_CAP); },
  });
  await room.join();
  agent.sink = room.sink();
  agent.republishState(); // 进房前的初始状态发不出去:进房后补发
  emit({ ev: 'ready', userId: room.userId, circleId: o.circleId, providers: providers.kind ?? 'custom', trigger: config.trigger });

  return {
    agent,
    room,
    get config() { return config; },
    setConfig(c) {
      const r = normalizeAiVoiceConfig(c ?? {});
      if (!r.ok) return false;
      const renamed = r.config.name !== config.name;
      config = r.config;
      agent.setConfig(config);
      if (renamed) room.rename(config.name);
      return true;
    },
    stop,
    done,
  };
}

const USAGE = 'usage: node index.mjs --circle <id> [--signaling ws://…/ws] [--passcode p] [--auth-v2] [--e2ee] [--config file.json] [--providers dashscope|mock] [--user-id id] [--name n]';

export async function main(argv = process.argv.slice(2), env = process.env) {
  const out = (ev) => {
    process.stdout.write(`${JSON.stringify(ev)}\n`);
    // 服务端托管时 supervisor 只把 turn 摘要写日志;把完整延迟数字再写一行 stderr(supervisor 原样记日志)。
    // 正文(query/reply)只有 LARES_AI_LOG_TEXT=1 时才在 ev 里。
    if (ev?.ev === 'turn') process.stderr.write(`[ai-voice] turn-metrics ${JSON.stringify(ev)}\n`);
  };
  const fatal = (code, message) => { out({ ev: 'error', message }); out({ ev: 'exit', code }); return code; };
  let args;
  let config;
  try {
    args = parseArgs(argv);
    if (args.help) { process.stderr.write(`${USAGE}\n`); return EXIT.OK; }
    if (!args.circleId) throw new UsageError('--circle is required');
    if (args.e2ee && !args.passcode) throw new UsageError('--e2ee requires --passcode');
    config = loadConfig({ configPath: args.configPath, name: args.name, env });
  } catch (e) {
    process.stderr.write(`${USAGE}\n`);
    return fatal(EXIT.BAD_ARGS, `bad_args: ${e.message}`);
  }
  const providers = args.providers ?? env.LARES_AI_PROVIDERS ?? 'dashscope';
  if (!['dashscope', 'mock'].includes(providers)) return fatal(EXIT.BAD_ARGS, `bad_args: providers ${providers}`);
  const authSecret = args.passcode ? undefined : env.LARES_AI_AUTH_SECRET;
  const authV = args.passcode ? (args.authV2 ? 2 : 1) : (env.LARES_AI_AUTH_V === '1' ? 1 : 2);

  let bot;
  try {
    bot = await runVoiceBot({
      circleId: args.circleId, signaling: args.signaling, passcode: args.passcode, authV2: args.authV2,
      authSecret, authV, e2ee: args.e2ee, config, providers, userId: args.userId, env, emit: out,
    });
  } catch (e) {
    if (e instanceof UsageError || /missing|unknown_providers/.test(e.message)) return fatal(EXIT.BAD_ARGS, e.message);
    if (e instanceof AuthError) return fatal(EXIT.AUTH, e.message);
    if (e instanceof CircleGoneError) return fatal(EXIT.OK, e.message);
    if (e instanceof E2eeRequiredError) return fatal(EXIT.BAD_ARGS, e.message);
    return fatal(1, `start_failed: ${e.message}`);
  }

  const onSig = () => bot.stop(EXIT.OK);
  process.once('SIGTERM', onSig);
  process.once('SIGINT', onSig);
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    let m;
    try { m = JSON.parse(line); } catch { return; }
    if (m?.cmd === 'stop') bot.stop(EXIT.OK);
    else if (m?.cmd === 'config') {
      if (!bot.setConfig?.(m.config)) out({ ev: 'error', message: 'bad_config' });
    }
  });
  rl.on('close', () => bot.stop(EXIT.OK)); // stdin 关 = 父进程没了
  const code = await bot.done;
  rl.close();
  out({ ev: 'exit', code });
  return code;
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().then((code) => {
    // 给 stdout 刷新留一点时间;rtc-node 的原生句柄可能拖住事件循环,所以显式退出
    setTimeout(() => process.exit(code), 50);
  }, (e) => {
    process.stdout.write(`${JSON.stringify({ ev: 'error', message: String(e?.message ?? e) })}\n`);
    setTimeout(() => process.exit(1), 50);
  });
}
