#!/usr/bin/env node
// 隐名之约 v2 · agent 进程(AGENT-V2.md)。显示名「隐名之约 · AI」。
//
// 独立模式:node server/bots/anonym-agent/index.mjs --circle <cid> --passcode <p> [--auth-v2] [--e2ee] [--signaling ws://…/ws] [--k n] [--memory-dir d]
//   E2EE 时独立模式用口令派生媒体密钥(同真人客户端);加 --sealed-key 则改走密封密钥流程。
// 托管模式(server/src/anonym_supervisor.js spawn):node index.mjs --circle <cid> --signaling <url>,env:
//   LARES_ANONYM_HOSTED=1  LARES_ANONYM_USER_ID  LARES_AI_MEMBER_SECRET  LARES_AI_AUTH_SECRET / LARES_AI_AUTH_V
//   LARES_ANONYM_E2EE=1(→ 密封密钥)  LARES_ANONYM_K  LARES_ANONYM_MEMORY_DIR  LARES_DASHSCOPE_API_KEY  LARES_AI_LLM_*
// stdout:一行一个 JSON 事件(ready / session / released / ended / error / exit),不含任何会话文字。
// stdin:{"cmd":"stop"} → 散会退出。退出码:0 = 会话结束;2 参数;3 鉴权;1 崩溃(服务器在邀请有效期内重启)。
import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';
import { AuthError, CircleGoneError, E2eeRequiredError } from '../voice-agent/room.mjs';
import { AnonRoom, anonAgentUserId } from './room.mjs';
import { AnonAgent, AGENT_NAME, wireAgent } from './agent.mjs';
import { openMemory } from './memory_iface.mjs';
import { loadSkills } from './skills.mjs';

export const EXIT = Object.freeze({ OK: 0, CRASH: 1, BAD_ARGS: 2, AUTH: 3 });
export class UsageError extends Error {}

export function parseArgs(argv) {
  const o = { e2ee: false, authV2: false, sealedKey: false };
  const need = (i) => { if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) throw new UsageError(`missing value for ${argv[i]}`); return argv[i + 1]; };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--circle': o.circleId = need(i); i++; break;
      case '--signaling': o.signaling = need(i); i++; break;
      case '--passcode': o.passcode = need(i); i++; break;
      case '--auth-v2': o.authV2 = true; break;
      case '--e2ee': o.e2ee = true; break;
      case '--sealed-key': o.sealedKey = true; break;
      case '--k': o.k = Number(need(i)); i++; break;
      case '--memory-dir': o.memoryDir = need(i); i++; break;
      case '--user-id': o.userId = need(i); i++; break;
      case '--convener': o.convenerId = need(i); i++; break;
      case '--asr': o.asr = need(i); i++; break;
      case '--help': case '-h': o.help = true; break;
      default: throw new UsageError(`unknown argument ${a}`);
    }
  }
  if (o.k !== undefined && (!Number.isInteger(o.k) || o.k < 1 || o.k > 20)) throw new UsageError('--k must be an integer 1..20');
  return o;
}

/// LLM:LARES_AI_LLM_BASE_URL / LARES_AI_LLM_API_KEY(或 LARES_AI_LLM_KEY)/ LARES_AI_LLM_MODEL;无 key → null(确定性 mock 路径)
export async function llmFromEnv(env = process.env) {
  const key = String(env.LARES_AI_LLM_API_KEY ?? '').trim() || String(env.LARES_AI_LLM_KEY ?? '').trim();
  if (!key) return null;
  const { createDeepSeekLLM } = await import('../../anonym-agent/core/gate/llm.mjs');
  return createDeepSeekLLM({
    baseUrl: String(env.LARES_AI_LLM_BASE_URL ?? '').trim() || 'https://api.deepseek.com',
    key, model: String(env.LARES_AI_LLM_MODEL ?? '').trim() || 'deepseek-flash', retries: 2, timeoutMs: 60_000,
  });
}

async function asrFromEnv(kind, env) {
  if (kind === 'none') return null;
  if (kind === 'mock') { const { MockAsr } = await import('../voice-agent/providers/mock.mjs'); return new MockAsr(); }
  const key = String(env.LARES_DASHSCOPE_API_KEY ?? '').trim();
  if (!key) throw new UsageError('LARES_DASHSCOPE_API_KEY missing');
  const { DashscopeAsr } = await import('../voice-agent/providers/dashscope.mjs');
  return new DashscopeAsr({ apiKey: key });
}

/**
 * 进房并开始会话。返回 { agent, room, stop(code), done: Promise<code> }。
 * 测试可注入 o.room(FakeRoom)/ o.asr / o.llm / o.memory / o.skills。
 */
export async function runAnonAgent(o) {
  const env = o.env ?? process.env;
  const emit = o.emit ?? (() => {});
  const log = o.log ?? ((m) => process.stderr.write(`[anonym-agent] ${m}\n`));
  const hosted = o.hosted ?? env.LARES_ANONYM_HOSTED === '1';
  const circleId = o.circleId;
  const e2ee = o.e2ee ?? (hosted ? env.LARES_ANONYM_E2EE === '1' : false);
  const userId = o.userId ?? (hosted ? (env.LARES_ANONYM_USER_ID || anonAgentUserId(circleId)) : anonAgentUserId(circleId).replace(/^u_ai_/, 'u_aibot_'));
  const kEnv = Number(String(env.LARES_ANONYM_K ?? '').trim() || NaN);
  const k = o.k ?? (Number.isInteger(kEnv) && kEnv >= 1 ? kEnv : null);
  const memoryDir = o.memoryDir ?? env.LARES_ANONYM_MEMORY_DIR
    ?? path.join(env.LARES_DATA_DIR || path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..', '..', 'data'), 'anonym_memory', circleId);

  const room = o.room ?? new AnonRoom({
    circleId, userId, name: AGENT_NAME,
    signaling: o.signaling ?? env.LARES_SIGNALING ?? 'ws://127.0.0.1:8787/ws',
    authSecret: o.authSecret, authV: o.authV ?? (o.authV2 ? 2 : 1), passcode: o.passcode,
    memberSecret: hosted ? (env.LARES_AI_MEMBER_SECRET || undefined) : undefined,
    e2ee, sealedKey: o.sealedKey ?? (hosted && e2ee), log,
  });
  let agent = null;
  const llm = o.llm !== undefined ? o.llm : await llmFromEnv(env);
  const asr = o.asr !== undefined ? o.asr : await asrFromEnv(o.asrKind ?? 'dashscope', env);
  const skills = o.skills ?? await loadSkills(undefined, { log });
  const memory = o.memory ?? await openMemory({ dir: memoryDir, circleId, roster: () => agent?.rosterFn() ?? [], log });

  let resolveDone;
  const done = new Promise((r) => { resolveDone = r; });
  let stopping = null;
  const stop = (code = EXIT.OK) => {
    stopping ??= (async () => {
      const hard = setTimeout(() => resolveDone(code), 3000);
      hard.unref?.();
      try { await agent?.end('stop'); } catch { /* */ }
      try { await room.leave(); } catch { /* */ }
      clearTimeout(hard);
      resolveDone(code);
    })();
    return stopping.then(() => done);
  };

  agent = new AnonAgent({
    circleId, selfId: userId, llm, asr, memory, skills, k, convenerId: o.convenerId ?? null, log, emit,
    transport: {
      broadcast: (obj) => room.publishAnon(obj),
      sendTo: (id, obj) => room.publishAnon(obj, id),
      notifyServer: (msg) => room.notifyServer(msg),
    },
    onEnded: () => { setTimeout(() => stop(EXIT.OK), 300).unref?.(); }, // 留时间把 ended 广播出去
    ...(o.agentOpts ?? {}),
  });
  room.on('disconnected', (why) => {
    if (why === 'circle_deleted') { log('圈子已解散,退出'); stop(EXIT.OK); return; }
    log(`连接断开(${why})`);
    emit({ ev: 'error', where: 'room', message: String(why) });
    stop(agent.ended ? EXIT.OK : EXIT.CRASH);
  });
  wireAgent(agent, room);
  await room.join();
  for (const p of room.participants?.() ?? []) agent.participantJoined(p.id, p.name);
  agent.start();
  emit({ ev: 'ready', userId, circleId, e2ee, hosted, llm: Boolean(llm), memory: memory.kind });
  return { agent, room, stop, done };
}

const USAGE = 'usage: node index.mjs --circle <id> [--signaling ws://…/ws] [--passcode p] [--auth-v2] [--e2ee] [--sealed-key] [--k n] [--memory-dir dir] [--asr dashscope|mock|none]';

export async function main(argv = process.argv.slice(2), env = process.env) {
  const out = (ev) => process.stdout.write(`${JSON.stringify(ev)}\n`);
  const fatal = (code, message) => { out({ ev: 'error', message }); out({ ev: 'exit', code }); return code; };
  let args;
  try {
    args = parseArgs(argv);
    if (args.help) { process.stderr.write(`${USAGE}\n`); return EXIT.OK; }
    if (!args.circleId) throw new UsageError('--circle is required');
    const hosted = env.LARES_ANONYM_HOSTED === '1';
    if (!hosted && !args.passcode && !env.LARES_AI_AUTH_SECRET) throw new UsageError('standalone mode needs --passcode');
    if (args.e2ee && !args.passcode && !args.sealedKey && !hosted) throw new UsageError('--e2ee needs --passcode or --sealed-key');
  } catch (e) {
    process.stderr.write(`${USAGE}\n`);
    return fatal(EXIT.BAD_ARGS, `bad_args: ${e.message}`);
  }
  const hosted = env.LARES_ANONYM_HOSTED === '1';
  const authSecret = args.passcode ? undefined : env.LARES_AI_AUTH_SECRET;
  const authV = args.passcode ? (args.authV2 ? 2 : 1) : (env.LARES_AI_AUTH_V === '1' ? 1 : 2);
  let bot;
  try {
    bot = await runAnonAgent({
      circleId: args.circleId, signaling: args.signaling, passcode: args.passcode, authV2: args.authV2, authSecret, authV,
      e2ee: hosted ? undefined : args.e2ee, sealedKey: args.sealedKey || undefined, k: args.k, memoryDir: args.memoryDir,
      userId: args.userId, convenerId: args.convenerId, asrKind: args.asr ?? env.LARES_ANONYM_ASR ?? 'dashscope', env, emit: out,
    });
  } catch (e) {
    if (e instanceof UsageError) return fatal(EXIT.BAD_ARGS, e.message);
    if (e instanceof AuthError) return fatal(EXIT.AUTH, e.message);
    if (e instanceof CircleGoneError) return fatal(EXIT.OK, e.message);
    if (e instanceof E2eeRequiredError) return fatal(EXIT.BAD_ARGS, e.message);
    return fatal(EXIT.CRASH, `start_failed: ${e.message}`);
  }
  const onSig = () => bot.stop(EXIT.OK);
  process.once('SIGTERM', onSig);
  process.once('SIGINT', onSig);
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => { let m; try { m = JSON.parse(line); } catch { return; } if (m?.cmd === 'stop') bot.stop(EXIT.OK); });
  rl.on('close', () => bot.stop(EXIT.OK)); // stdin 关 = 父进程没了
  const code = await bot.done;
  rl.close();
  process.stdin.unref?.();
  out({ ev: 'exit', code });
  try { (await import('../voice-agent/room.mjs')).loadRtcNode().then((rtc) => rtc?.dispose?.()).catch(() => {}); } catch { /* */ }
  return code;
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().then((code) => { process.exitCode = code; }, (e) => {
    process.stdout.write(`${JSON.stringify({ ev: 'error', message: String(e?.message ?? e) })}\n`);
    process.exitCode = EXIT.CRASH;
  });
}
