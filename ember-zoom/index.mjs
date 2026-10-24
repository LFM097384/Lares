#!/usr/bin/env node
// ember-zoom · 炉灵(Ember)在 Zoom 上的进程入口。架构同 ember-lares:Ember 本体(../ember)平台无关,这里只做 Zoom 那一半。
//   一个 HTTP 服务器:/webhook(Zoom 事件)+ /sidebar/(Zoom App 侧边栏)+ WS /hub(侧边栏 = 房间)
//   每条 RTMS 流(meeting.rtms_started)一个 Ember 会话;meeting.rtms_stopped / RTMS stop reason → 该会话散会。
//
// env:
//   ZOOM_CLIENT_ID  ZOOM_CLIENT_SECRET  ZOOM_WEBHOOK_SECRET   (必需;不写进任何文件)
//   PORT(缺省 8790)  HOST(缺省 127.0.0.1;公网经 HTTPS 隧道)
//   LARES_AI_LLM_BASE_URL / LARES_AI_LLM_API_KEY(或 LARES_AI_LLM_KEY)/ LARES_AI_LLM_MODEL   无 key → 确定性 mock 路径
//   EMBER_MEMORY_DIR(缺省 server/data/ember_zoom_memory;每个作用域一个子目录)
//   EMBER_K(放行门槛,缺省自动)  EMBER_ZOOM_ASR = zoom(缺省,用 RTMS 转写)| dashscope(订每人音频,自备 ASR;需 LARES_DASHSCOPE_API_KEY)| mock
//   EMBER_ZOOM_POST_CHAT=1(放行纪要经侧边栏 sendMessageToChat 发到会议聊天;缺省关)  EMBER_ZOOM_LANG(转写 src_language,可选)
//   EMBER_ZOOM_ALLOW_ORIGINS(逗号分隔;缺省只收同源 Origin)
// stdout:一行一个 JSON 事件(listening / session / ready / released / ended / error / exit),只有元数据,不含任何会话文字。
// stdin:{"cmd":"stop"} → 全部散会后退出。SIGINT 同。Windows 上 SIGTERM 是硬杀(TerminateProcess),来不及优雅退出,
//   托管方应先写 stdin stop(同 server/src/anonym_supervisor.js 对 ember-lares 的做法)。退出码:0 正常;2 参数;1 崩溃。
import path from 'node:path';
import readline from 'node:readline';
import { createHash } from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createEmber, createDeepSeekLLM, MockAsr } from '../ember/index.mjs';
import { createZoomServer } from './server.mjs';
import { zoomPort, zoomUserId } from './port.mjs';
import { RtmsClient } from './rtms_client.mjs';
import { splitServerUrls } from './webhook.mjs';
import { WebSocket } from './deps.mjs';

export const EXIT = Object.freeze({ OK: 0, CRASH: 1, BAD_ARGS: 2 });
export class UsageError extends Error {}
const HERE = path.dirname(fileURLToPath(import.meta.url));

/// 同 ember-lares/index.mjs 的 llmFromEnv(复制而非 import:不把 lares-bridge / LiveKit 拉进 Zoom 进程)
export async function llmFromEnv(env = process.env) {
  const key = String(env.LARES_AI_LLM_API_KEY ?? '').trim() || String(env.LARES_AI_LLM_KEY ?? '').trim();
  if (!key) return null;
  return createDeepSeekLLM({
    baseUrl: String(env.LARES_AI_LLM_BASE_URL ?? '').trim() || 'https://api.deepseek.com',
    key, model: String(env.LARES_AI_LLM_MODEL ?? '').trim() || 'deepseek-flash', retries: 2, timeoutMs: 60_000,
  });
}

async function asrFromEnv(kind, env) {
  if (kind === 'zoom' || kind === 'none') return null;
  if (kind === 'mock') return new MockAsr();
  if (kind !== 'dashscope') throw new UsageError(`EMBER_ZOOM_ASR must be zoom|dashscope|mock (got ${kind})`);
  const key = String(env.LARES_DASHSCOPE_API_KEY ?? '').trim();
  if (!key) throw new UsageError('LARES_DASHSCOPE_API_KEY missing (EMBER_ZOOM_ASR=dashscope)');
  const { DashscopeAsr } = await import('../hearthvoice/providers/dashscope.mjs');
  return new DashscopeAsr({ apiKey: key, host: env.LARES_DASHSCOPE_HOST, log: (m) => process.stderr.write(`[ember-zoom asr] ${m}\n`), WebSocket });
}

/// 记忆作用域:同一个 Zoom meeting_id(周期会议不变)= 一个「圈」。可用 EMBER_ZOOM_SCOPE 固定。
export const scopeFor = (payload, env = {}) => String(env.EMBER_ZOOM_SCOPE ?? '').trim()
  || `zoom_${createHash('sha256').update(`${payload.account_id ?? ''}:${payload.meeting_id ?? payload.meeting_uuid ?? ''}`).digest('hex').slice(0, 16)}`;

export function configFromEnv(env = process.env) {
  const need = (k) => { const v = String(env[k] ?? '').trim(); if (!v) throw new UsageError(`${k} missing`); return v; };
  const kEnv = String(env.EMBER_K ?? '').trim();
  const k = kEnv ? Number(kEnv) : null;
  if (k !== null && (!Number.isInteger(k) || k < 1 || k > 20)) throw new UsageError('EMBER_K must be an integer 1..20');
  const port = Number(String(env.PORT ?? '').trim() || 8790);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new UsageError('PORT invalid');
  return {
    clientId: need('ZOOM_CLIENT_ID'), clientSecret: need('ZOOM_CLIENT_SECRET'), webhookSecret: need('ZOOM_WEBHOOK_SECRET'),
    port, host: String(env.HOST ?? '').trim() || '127.0.0.1', k,
    memoryDir: String(env.EMBER_MEMORY_DIR ?? '').trim() || path.join(env.LARES_DATA_DIR || path.join(HERE, '..', 'server', 'data'), 'ember_zoom_memory'),
    asrKind: String(env.EMBER_ZOOM_ASR ?? '').trim() || 'zoom',
    postChat: env.EMBER_ZOOM_POST_CHAT === '1',
    lang: String(env.EMBER_ZOOM_LANG ?? '').trim() || null,
    allowOrigins: String(env.EMBER_ZOOM_ALLOW_ORIGINS ?? '').trim() ? env.EMBER_ZOOM_ALLOW_ORIGINS.split(',').map((s) => s.trim()).filter(Boolean) : null,
  };
}

/**
 * 起服务器。返回 { server, hub, port, sessions: Map<streamId, {ember, port, scopeId}>, stop(code), done: Promise<code> }。
 * 测试可注入 llm / asr / skills / memoryDir(null = 内存)/ rtmsOpts(backoff 等)/ sessionOpts / now。
 */
export async function runEmberZoom(o = {}) {
  const env = o.env ?? process.env;
  const emit = o.emit ?? (() => {});
  const log = o.log ?? ((m) => process.stderr.write(`[ember-zoom] ${m}\n`));
  const cfg = o.config ?? configFromEnv(env);
  const llm = o.llm !== undefined ? o.llm : await llmFromEnv(env);
  const asr = o.asr !== undefined ? o.asr : await asrFromEnv(cfg.asrKind, env);
  const wantAudio = Boolean(asr) && cfg.asrKind !== 'zoom';
  const sessions = new Map();
  let stopping = null;
  let resolveDone;
  const done = new Promise((r) => { resolveDone = r; });

  const endSession = async (streamId, why) => {
    const s = sessions.get(streamId);
    if (!s) return;
    try { await s.ember.stop(why); } catch { /* */ }
    sessions.delete(streamId);
  };

  const startSession = async (payload) => {
    const meetingUuid = String(payload.meeting_uuid ?? '');
    const streamId = String(payload.rtms_stream_id ?? '');
    const serverUrls = splitServerUrls(payload.server_urls);
    if (!meetingUuid || !streamId || !serverUrls.length) { log('rtms_started: missing meeting_uuid / rtms_stream_id / server_urls'); return; }
    if (sessions.has(streamId) || stopping) return; // Zoom 可能重投
    const scopeId = scopeFor(payload, env);
    const inviter = srv.hub.inviterOf(meetingUuid);
    const convenerId = inviter?.participantId ? zoomUserId(inviter.participantId) : null;
    const slot = { ember: null, port: null, scopeId, meetingUuid };
    sessions.set(streamId, slot);
    const port = zoomPort({
      meetingUuid, hub: srv.hub, postReleasedToChat: cfg.postChat, log,
      convenerId: () => slot.ember?.session.convenerId ?? null,
      onHost: (ev) => emit({ ev: 'host', streamId, ...ev }),
      connect: () => new RtmsClient({
        clientId: cfg.clientId, clientSecret: cfg.clientSecret, meetingUuid, streamId, serverUrls, log,
        media: { transcript: !wantAudio, audio: wantAudio },
        transcriptParams: cfg.lang ? { src_language: cfg.lang } : {},
        ...(o.rtmsOpts ?? {}),
      }),
    });
    slot.port = port;
    try {
      slot.ember = await createEmber({
        port, llm, asr, memoryDir: o.memoryDir !== undefined ? (o.memoryDir && path.join(o.memoryDir, scopeId)) : path.join(cfg.memoryDir, scopeId),
        memory: o.memory, skills: o.skills, log, emit: (e) => emit({ ...e, streamId }),
        policy: { k: cfg.k, convenerId, scopeId },
        onEnded: () => { sessions.delete(streamId); },
        sessionOpts: o.sessionOpts ?? {},
      });
      port.on('disconnected', (why) => { log(`rtms stopped (${why}) → 散会`); void endSession(streamId, `rtms:${why}`); });
      await slot.ember.start();
      emit({ ev: 'ready', streamId, scopeId, llm: Boolean(llm), memory: slot.ember.memory.kind, media: wantAudio ? 'audio' : 'transcript' });
    } catch (e) {
      emit({ ev: 'error', where: 'session', streamId, message: String(e?.message ?? e) });
      try { await slot.ember?.stop('start_failed'); } catch { /* */ }
      try { await port.leave(); } catch { /* */ }
      sessions.delete(streamId);
    }
  };

  const onWebhook = async (event, payload) => {
    const streamId = String(payload?.rtms_stream_id ?? '');
    if (event === 'meeting.rtms_started') return startSession(payload);
    if (event === 'meeting.rtms_stopped') { emit({ ev: 'rtms_stopped', streamId, stopReason: payload?.stop_reason ?? null }); return endSession(streamId, `rtms_stopped:${payload?.stop_reason ?? ''}`); }
    if (event === 'meeting.rtms_interrupted') { emit({ ev: 'rtms_interrupted', streamId }); return undefined; } // 客户端自己按退避重连
    return undefined;
  };

  const srv = createZoomServer({ webhookSecret: cfg.webhookSecret, onWebhook, log, allowOrigins: cfg.allowOrigins, ...(o.now ? { now: o.now } : {}) });
  const listenPort = await srv.listen(o.port ?? cfg.port, o.host ?? cfg.host);
  emit({ ev: 'listening', port: listenPort, host: o.host ?? cfg.host });

  const stop = (code = EXIT.OK) => {
    stopping ??= (async () => {
      const hard = setTimeout(() => resolveDone(code), 5000);
      hard.unref?.();
      await Promise.allSettled([...sessions.keys()].map((id) => endSession(id, 'stop')));
      await new Promise((r) => setTimeout(r, 50)); // 让 ended 送出去
      try { await srv.close(); } catch { /* */ }
      clearTimeout(hard);
      resolveDone(code);
    })();
    return stopping.then(() => done);
  };
  return { server: srv.server, hub: srv.hub, port: listenPort, url: `http://${o.host ?? cfg.host}:${listenPort}`, sessions, stop, done, onWebhook };
}

const USAGE = 'usage: ZOOM_CLIENT_ID=… ZOOM_CLIENT_SECRET=… ZOOM_WEBHOOK_SECRET=… [PORT=8790] node ember-zoom/index.mjs';

export async function main(argv = process.argv.slice(2), env = process.env) {
  const out = (ev) => process.stdout.write(`${JSON.stringify(ev)}\n`);
  const fatal = (code, message) => { out({ ev: 'error', message }); out({ ev: 'exit', code }); return code; };
  if (argv.includes('--help') || argv.includes('-h')) { process.stderr.write(`${USAGE}\n`); return EXIT.OK; }
  if (argv.length) { process.stderr.write(`${USAGE}\n`); return fatal(EXIT.BAD_ARGS, `bad_args: unknown argument ${argv[0]}`); }
  let app;
  try {
    const config = configFromEnv(env);
    app = await runEmberZoom({ env, config, emit: out });
  } catch (e) {
    if (e instanceof UsageError) { process.stderr.write(`${USAGE}\n`); return fatal(EXIT.BAD_ARGS, `bad_args: ${e.message}`); }
    return fatal(EXIT.CRASH, `start_failed: ${e.message}`);
  }
  const onSig = () => app.stop(EXIT.OK);
  process.once('SIGINT', onSig);
  process.once('SIGTERM', onSig); // POSIX;Windows 上它是硬杀,见文件头
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => { let m; try { m = JSON.parse(line); } catch { return; } if (m?.cmd === 'stop') app.stop(EXIT.OK); });
  // 与 ember-lares 不同:这是常驻服务,stdin 关闭(如 nohup / 服务管理器)不等于父进程没了,不据此退出
  const code = await app.done;
  rl.close();
  process.stdin.unref?.();
  process.removeListener('SIGINT', onSig);
  process.removeListener('SIGTERM', onSig);
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
