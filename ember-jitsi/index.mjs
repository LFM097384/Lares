#!/usr/bin/env node
// ember-jitsi · 炉灵(Ember)在 Jitsi Meet 上的进程入口。显示名「炉灵」。
// Ember 本体(../ember)与平台无关;这里只做 Jitsi 那一半:无头 Chromium + lib-jitsi-meet 进会(bridge.mjs)、
// 会议聊天 = 房间通道(port.mjs + commands.mjs)、逐人音频 → DashScope 实时 ASR。
//
//   node ember-jitsi/index.mjs --room <name> [--url https://jitsi.example] [--k n] [--memory-dir d] [--asr dashscope|mock|none] [--convener-name 张伟]
// env:JITSI_URL(缺省 https://localhost:8443)  JITSI_INSECURE=1(接受自签证书;localhost 自动)
//      LARES_AI_LLM_BASE_URL / LARES_AI_LLM_API_KEY(或 LARES_AI_LLM_KEY)/ LARES_AI_LLM_MODEL(无 key → 确定性 mock 路径)
//      LARES_DASHSCOPE_API_KEY(--asr dashscope 时必需)  EMBER_MEMORY_DIR  EMBER_K  EMBER_SCOPE
// stdout:一行一个 JSON 元数据事件(ready / host / released / ended / error / exit),绝无会话文字。
// stdin:{"cmd":"stop"} 或 SIGINT → 散会、离会、退出。退出码:0 正常;1 崩溃 / 连接断;2 参数。
import path from 'node:path';
import readline from 'node:readline';
import { createHash } from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createEmber, createDeepSeekLLM, MockAsr, AGENT_NAME } from '../ember/index.mjs';
import { jitsiPort } from './port.mjs';

export const EXIT = Object.freeze({ OK: 0, CRASH: 1, BAD_ARGS: 2 });
export const DEFAULT_URL = 'https://localhost:8443';
export class UsageError extends Error {}
const HERE = path.dirname(fileURLToPath(import.meta.url));

export function parseArgs(argv) {
  const o = {};
  const need = (i) => { if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) throw new UsageError(`missing value for ${argv[i]}`); return argv[i + 1]; };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--room': o.room = need(i); i++; break;
      case '--url': o.url = need(i); i++; break;
      case '--k': o.k = Number(need(i)); i++; break;
      case '--memory-dir': o.memoryDir = need(i); i++; break;
      case '--asr': o.asr = need(i); i++; break;
      case '--scope': o.scope = need(i); i++; break;
      case '--convener-name': o.convenerName = need(i); i++; break;
      case '--headful': o.headful = true; break;
      case '--help': case '-h': o.help = true; break;
      default: throw new UsageError(`unknown argument ${a}`);
    }
  }
  if (o.k !== undefined && (!Number.isInteger(o.k) || o.k < 1 || o.k > 20)) throw new UsageError('--k must be an integer 1..20');
  if (o.room !== undefined && !/^[A-Za-z0-9_.-]{1,64}$/.test(o.room)) throw new UsageError('--room must match [A-Za-z0-9_.-]{1,64}');
  if (o.asr !== undefined && !['dashscope', 'mock', 'none'].includes(o.asr)) throw new UsageError('--asr must be dashscope|mock|none');
  if (o.url !== undefined) { try { const u = new URL(o.url); if (!/^https?:$/.test(u.protocol)) throw new Error(); } catch { throw new UsageError('--url must be an http(s) URL'); } }
  return o;
}

/// 记忆作用域:hash(服务器 host + 房间名) —— 同一个房间名 = 同一个「圈」
export function scopeOf(url, room) { return createHash('sha256').update(`${new URL(url).host}/${String(room).toLowerCase()}`).digest('hex').slice(0, 24); }

export async function llmFromEnv(env = process.env) {
  const key = String(env.LARES_AI_LLM_API_KEY ?? '').trim() || String(env.LARES_AI_LLM_KEY ?? '').trim();
  if (!key) return null;
  return createDeepSeekLLM({
    baseUrl: String(env.LARES_AI_LLM_BASE_URL ?? '').trim() || 'https://api.deepseek.com',
    key, model: String(env.LARES_AI_LLM_MODEL ?? '').trim() || 'deepseek-flash', retries: 2, timeoutMs: 60_000,
  });
}

export async function asrFromEnv(kind, env = process.env, log = () => {}) {
  if (kind === 'none') return null;
  if (kind === 'mock') return new MockAsr();
  const key = String(env.LARES_DASHSCOPE_API_KEY ?? '').trim();
  if (!key) throw new UsageError('LARES_DASHSCOPE_API_KEY missing (--asr dashscope)');
  const { loadWs } = await import('./deps.mjs');
  const { DashscopeAsr } = await import('../hearthvoice/providers/dashscope.mjs');
  return new DashscopeAsr({ apiKey: key, host: env.LARES_DASHSCOPE_HOST, log, WebSocket: await loadWs() });
}

/// 包一层 ASR provider:每句定稿发一个元数据事件 {ev:'asr_final', endpoint, chars} —— 只有长度,绝无文字
export function meteredAsr(asr, emit) {
  if (!asr) return null;
  return {
    warmup: asr.warmup?.bind(asr),
    open(o) {
      return asr.open({ ...o, onFinal: (text) => { try { emit({ ev: 'asr_final', endpoint: o.identity, chars: String(text ?? '').length }); } catch { /* */ } o.onFinal?.(text); } });
    },
  };
}

/**
 * 进会并开始会话。返回 { ember, port, bridge, stop(code), done: Promise<code> }。
 * 测试注入 o.bridge(假 bridge)/ o.asr / o.llm / o.memory。
 */
export async function runEmberJitsi(o) {
  const env = o.env ?? process.env;
  const emit = o.emit ?? (() => {});
  const log = o.log ?? ((m) => process.stderr.write(`[ember-jitsi] ${m}\n`));
  const url = o.url ?? env.JITSI_URL ?? DEFAULT_URL;
  const room = o.room;
  const kEnv = Number(String(env.EMBER_K ?? '').trim() || NaN);
  const k = o.k ?? (Number.isInteger(kEnv) && kEnv >= 1 ? kEnv : null);
  const scopeId = o.scope ?? env.EMBER_SCOPE ?? scopeOf(url, room);
  const memoryDir = o.memoryDir ?? path.join(env.EMBER_MEMORY_DIR || path.join(HERE, '..', 'server', 'data', 'ember_jitsi_memory'), scopeId);
  let bridge = o.bridge;
  if (!bridge) {
    const { JitsiBrowserBridge } = await import('./bridge.mjs');
    bridge = new JitsiBrowserBridge({ url, room, name: AGENT_NAME, tapAudio: true, headless: !o.headful, log });
  }
  const port = jitsiPort(bridge, { log, convenerName: o.convenerName ?? env.EMBER_CONVENER_NAME ?? null, onHost: (ev) => emit({ ev: 'host', ...ev }) });
  const llm = o.llm !== undefined ? o.llm : await llmFromEnv(env);
  const asr = meteredAsr(o.asr !== undefined ? o.asr : await asrFromEnv(o.asrKind ?? 'dashscope', env, (m) => log(`asr: ${m}`)), emit);

  let resolveDone;
  const done = new Promise((r) => { resolveDone = r; });
  let stopping = null;
  let ember = null;
  const stop = (code = EXIT.OK) => {
    stopping ??= (async () => {
      const hard = setTimeout(() => resolveDone(code), 5000);
      hard.unref?.();
      try { await ember?.session.end('stop'); } catch { /* */ }
      await new Promise((r) => setTimeout(r, 300)); // 让 ended 回执发到聊天
      try { await port.leave(); } catch { /* */ }
      clearTimeout(hard);
      resolveDone(code);
    })();
    return stopping.then(() => done);
  };

  ember = await createEmber({
    port, llm, asr, memoryDir, memory: o.memory, skills: o.skills, log, emit,
    policy: { k, convenerId: null, scopeId },
    onEnded: () => { setTimeout(() => stop(EXIT.OK), 300).unref?.(); },
    sessionOpts: o.sessionOpts ?? {}, autoLeave: false,
  });
  port.on('disconnected', (why) => {
    log(`连接断开(${why})`);
    emit({ ev: 'error', where: 'jitsi', message: String(why) });
    stop(ember.session.ended ? EXIT.OK : EXIT.CRASH);
  });
  await ember.start();
  emit({ ev: 'ready', room, selfId: port.selfId, endpoint: bridge.myId ?? null, llm: Boolean(llm), asr: asr ? (o.asrKind ?? 'dashscope') : 'none', memory: ember.memory.kind, k: k ?? 'auto' });
  return { ember, port, bridge, memoryDir, scopeId, stop, done };
}

const USAGE = 'usage: node ember-jitsi/index.mjs --room <name> [--url https://…] [--k n] [--memory-dir dir] [--asr dashscope|mock|none] [--convener-name name] [--scope id] [--headful]';

export async function main(argv = process.argv.slice(2), env = process.env, { stdin = process.stdin, out = (ev) => process.stdout.write(`${JSON.stringify(ev)}\n`), run = runEmberJitsi } = {}) {
  const fatal = (code, message) => { out({ ev: 'error', message }); out({ ev: 'exit', code }); return code; };
  let args;
  try {
    args = parseArgs(argv);
    if (args.help) { process.stderr.write(`${USAGE}\n`); return EXIT.OK; }
    if (!args.room) throw new UsageError('--room is required');
  } catch (e) {
    process.stderr.write(`${USAGE}\n`);
    return fatal(EXIT.BAD_ARGS, `bad_args: ${e.message}`);
  }
  let bot;
  try {
    bot = await run({ room: args.room, url: args.url, k: args.k, memoryDir: args.memoryDir, scope: args.scope, convenerName: args.convenerName, headful: args.headful, asrKind: args.asr ?? env.EMBER_JITSI_ASR ?? 'dashscope', env, emit: out });
  } catch (e) {
    if (e instanceof UsageError) return fatal(EXIT.BAD_ARGS, e.message);
    return fatal(EXIT.CRASH, `start_failed: ${e.message}`);
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
  main().then((code) => { process.exitCode = code; }, (e) => {
    process.stdout.write(`${JSON.stringify({ ev: 'error', message: String(e?.message ?? e) })}\n`);
    process.exitCode = EXIT.CRASH;
  });
}
