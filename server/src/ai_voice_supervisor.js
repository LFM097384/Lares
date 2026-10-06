// lares.ai-voice 服务端监管:按圈拉起 / 停掉语音助手子进程(契约 server/bots/voice-agent/CONTRACT.md §1/§2/§4)。
//
// 依赖全部注入(圈子状态、插件查询、spawn、时钟),本模块不碰 index.js 的全局表 —— 可单测。
// 密钥只走子进程环境变量,绝不进 argv(argv 在 ps / 任务管理器里人人可见)。

import { spawn as nodeSpawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';

export const AI_VOICE_PLUGIN_ID = 'lares.ai-voice';
export const AI_USER_PREFIX = 'u_ai_';
export const EMPTY_GRACE_MS = 20_000;
export const KILL_AFTER_MS = 5_000;
export const BACKOFF_MIN_MS = 5_000;
export const BACKOFF_MAX_MS = 60_000;
export const RESPAWN_MAX_PER_HOUR = 5;
export const MAX_PROCESSES_DEFAULT = 8; // 全站同时在跑的助手进程上限(LARES_AI_MAX_PROCESSES)
const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;

export const isAiUserId = (uid) => typeof uid === 'string' && uid.startsWith(AI_USER_PREFIX);

/// 下一个本地日 0 点的时间戳。tzOffsetMin 不给就用系统时区(bot 的 caps.mjs 同样默认系统时区)。
export function nextLocalMidnight(t, tzOffsetMin) {
  const off = (tzOffsetMin ?? -new Date(t).getTimezoneOffset()) * 60_000;
  return (Math.floor((t + off) / DAY_MS) + 1) * DAY_MS - off;
}

/// 圈 id 落进文件名:非 [A-Za-z0-9._-] 一律转义,杜绝路径穿越
const fileSafe = (id) => String(id).replace(/[^A-Za-z0-9._-]/g, (c) => `%${c.charCodeAt(0).toString(16).padStart(2, '0')}`);

/**
 * @param {object} d
 *   env, dataDir, botEntry (index.mjs 绝对路径), signalingUrl,
 *   isEnabled(circleId) -> bool, configOf(circleId) -> object, humanCount(circleId) -> int,
 *   circleE2ee(circleId) -> bool, authFor(circleId) -> {secret, v} | null,
 *   memberSecretFor?(circleId) -> string  该圈 u_ai_* 身份密钥(进子进程 env LARES_AI_MEMBER_SECRET)
 *   spawn?, now?, setTimer?(fn, ms)->handle, clearTimer?(handle), log?, tzOffsetMin?, execPath?
 */
export function createAiVoiceSupervisor(d) {
  const env = d.env ?? process.env;
  const spawn = d.spawn ?? nodeSpawn;
  const now = d.now ?? Date.now;
  const setTimer = d.setTimer ?? ((fn, ms) => { const h = setTimeout(fn, ms); h.unref?.(); return h; });
  const clearTimer = d.clearTimer ?? ((h) => clearTimeout(h));
  const log = d.log ?? console;
  const execPath = d.execPath ?? process.execPath;
  const mock = String(env.LARES_AI_PROVIDERS ?? '').trim() === 'mock';
  const hasKey = String(env.LARES_DASHSCOPE_API_KEY ?? '').trim().length > 0;
  // 镜像里可能没有 bots/(server/Dockerfile 只 COPY src/):没有入口就别反复拉起一个必崩的进程
  const entryOk = d.botEntryExists ?? (() => existsSync(d.botEntry));
  // 每圈最多一个(slot 即圈);全站再设总上限:100 个圈都开了也只跑这么多,其余等名额
  const maxProcs = (() => { const raw = String(env.LARES_AI_MAX_PROCESSES ?? '').trim(); const n = raw ? Number(raw) : NaN; return Number.isInteger(n) && n >= 0 ? n : MAX_PROCESSES_DEFAULT; })();
  const runningCount = () => { let n = 0; for (const s of slots.values()) if (s.child) n++; return n; };

  /**
   * circleId -> {
   *   child, startedAt, stopping, killTimer, graceTimer, respawnTimer, respawnAt,
   *   crashes: number[] (hour window), backoff, blockedUntil, lastRefusal, lastExit
   * }
   */
  const slots = new Map();
  let stoppedAll = false;

  const slotOf = (cid) => {
    let s = slots.get(cid);
    if (!s) {
      s = { child: null, crashes: [], backoff: BACKOFF_MIN_MS, blockedUntil: 0, lastRefusal: null, lastExit: null };
      slots.set(cid, s);
    }
    return s;
  };
  const tag = (cid) => `[ai-voice] ${cid}`;

  /// 该不该跑:返回 null = 该跑,否则是拒绝原因
  function refusal(cid) {
    if (stoppedAll) return 'shutdown';
    if (!d.isEnabled(cid)) return 'disabled';
    if ((d.humanCount(cid) ?? 0) < 1) return 'empty';
    if (d.circleE2ee(cid) === true) return 'e2ee';
    if (!hasKey && !mock) return 'no_api_key';
    if (!d.authFor(cid)) return 'no_auth';
    if (!entryOk()) return 'no_bot';
    if (!slots.get(cid)?.child && runningCount() >= maxProcs) return 'capacity';
    return null;
  }

  function childEnv(cid, auth) {
    const out = { ...env };
    // 别把服务端自己的鉴权材料 / LiveKit 密钥漏给子进程:它只需要信令 + DashScope + LARES_AI_LLM_*(对话 LLM,如 DeepSeek)。
    // LARES_AI_LLM_* 原样继承(含 key),同样只走 env,绝不进 argv。
    for (const k of Object.keys(out)) {
      if (k.startsWith('LIVEKIT_') || k === 'LARES_AUTH_TOKEN' || k === 'LARES_CIRCLE_PASSCODE'
        || k === 'LARES_CIRCLE_PASSCODES' || k.startsWith('LARES_APNS_') || k === 'LARES_AI_MEMBER_KEY') delete out[k];
    }
    out.LARES_AI_AUTH_SECRET = String(auth.secret);
    out.LARES_AI_AUTH_V = String(auth.v === 2 ? 2 : 1);
    // u_ai_* 身份凭证(只对本圈有效;服务端 hello 校验,见 index.js aiMemberOk)。同样只走 env
    const ms = d.memberSecretFor?.(cid);
    if (ms) out.LARES_AI_MEMBER_SECRET = String(ms); else delete out.LARES_AI_MEMBER_SECRET;
    out.LARES_AI_CONFIG = slotOf(cid).configJson = JSON.stringify(d.configOf(cid) ?? {});
    out.LARES_AI_USAGE_FILE = path.join(d.dataDir, 'ai_voice_usage', `${fileSafe(cid)}.json`);
    out.LARES_SIGNALING = d.signalingUrl;
    if (mock) out.LARES_AI_PROVIDERS = 'mock';
    return out;
  }

  function start(cid, s) {
    const auth = d.authFor(cid);
    if (!auth) return;
    // argv 只有非敏感项;口令 / verifier / API key 全在 env
    const args = [d.botEntry, '--circle', cid, '--signaling', d.signalingUrl];
    if (mock) args.push('--providers', 'mock');
    let child;
    try {
      child = spawn(execPath, args, { env: childEnv(cid, auth), stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    } catch (e) {
      log.error?.(`${tag(cid)} 启动失败: ${e?.message ?? e}`);
      onExit(cid, s, null, 1, null);
      return;
    }
    s.child = child;
    s.startedAt = now();
    s.stopping = false;
    s.lastRefusal = null;
    log.log?.(`${tag(cid)} 已启动 pid=${child.pid ?? '?'}`);
    lineReader(child.stdout, (line) => onStdout(cid, line));
    lineReader(child.stderr, (line) => log.error?.(`${tag(cid)} ${line}`));
    child.stdin?.on?.('error', () => {}); // 子进程先死时写 stdin 会 EPIPE
    let settled = false;
    const done = (code, signal) => {
      if (settled) return;
      settled = true;
      onExit(cid, s, child, code, signal);
    };
    child.on('exit', done);
    child.on('error', (e) => {
      log.error?.(`${tag(cid)} 子进程错误: ${e?.message ?? e}`);
      done(null, null);
    });
  }

  function onStdout(cid, line) {
    let ev;
    try { ev = JSON.parse(line); } catch { log.log?.(`${tag(cid)} ${line.slice(0, 200)}`); return; }
    if (!ev || typeof ev !== 'object') return;
    switch (ev.ev) {
      case 'turn':
        log.log?.(`${tag(cid)} turn ${ev.trigger ?? '?'} ttfa=${ev.ttfaMs ?? '?'}ms llm1=${ev.llmFirstTokenMs ?? '?'}ms heard=${ev.heardChars ?? 0} reply=${ev.replyChars ?? 0}${ev.interrupted ? ' interrupted' : ''}`);
        break;
      case 'usage': {
        const t = ev.total ?? {};
        log.log?.(`${tag(cid)} usage day=${ev.day ?? '?'} turns=${t.turns ?? '?'} llmIn=${t.llmIn ?? '?'} llmOut=${t.llmOut ?? '?'} tts=${t.ttsChars ?? '?'} asrSec=${t.asrSec ?? '?'}`);
        break;
      }
      case 'cap_reached':
        log.log?.(`${tag(cid)} cap_reached scope=${ev.scope ?? '?'}`);
        if (ev.scope === 'daily') slotOf(cid).blockedUntil = nextLocalMidnight(now(), d.tzOffsetMin);
        break;
      case 'ready':
        log.log?.(`${tag(cid)} ready`);
        break;
      case 'error':
        log.error?.(`${tag(cid)} error ${String(ev.code ?? ev.message ?? '').slice(0, 200)}`);
        break;
      default:
        break;
    }
  }

  function onExit(cid, s, child, code, signal) {
    if (child && s.child !== child) return;
    s.child = null;
    if (s.killTimer) { clearTimer(s.killTimer); s.killTimer = null; }
    const wasStopping = s.stopping;
    s.stopping = false;
    s.lastExit = { code, signal, at: now() };
    log.log?.(`${tag(cid)} 已退出 code=${code} signal=${signal ?? ''}`);
    if (stoppedAll) return;
    wakeWaiting(cid);
    if (code === 4) {
      s.blockedUntil = nextLocalMidnight(now(), d.tzOffsetMin);
      log.log?.(`${tag(cid)} 今日额度用完,明天前不再拉起`);
      // 过了零点再看一眼:房里还有人就重新拉起
      scheduleRetry(cid, s, s.blockedUntil - now() + 1000);
      return;
    }
    if (wasStopping) { reconcile(cid); return; }
    if (code === 0 && !signal) {
      // 没叫它停却正常退出(典型:被圈友踢出房):不立刻拉回来 —— 等房间空过一次 / 插件重新启用
      s.parked = true;
      log.log?.(`${tag(cid)} 自行退出,等房间清空或插件重新启用后再拉起`);
      return;
    }
    // 崩溃 / 鉴权错 code 3 / code 2:走退避重拉,计入每小时上限 —— 否则秒退的子进程会被紧循环重启。
    const t = now();
    if (s.startedAt && t - s.startedAt >= 10 * 60_000) s.backoff = BACKOFF_MIN_MS; // 稳定跑过一阵,退避归零
    s.crashes = s.crashes.filter((x) => t - x < HOUR_MS);
    if (s.crashes.length >= RESPAWN_MAX_PER_HOUR) {
      s.blockedUntil = Math.max(s.blockedUntil, s.crashes[0] + HOUR_MS);
      log.error?.(`${tag(cid)} 一小时内崩溃 ${s.crashes.length} 次,暂停到 ${new Date(s.blockedUntil).toISOString()}`);
      scheduleRetry(cid, s, s.blockedUntil - t);
      return;
    }
    s.crashes.push(t);
    const delay = s.backoff;
    s.backoff = Math.min(BACKOFF_MAX_MS, s.backoff * 2);
    scheduleRetry(cid, s, delay);
  }

  /// 腾出一个全站名额:让因 capacity 排队的圈重新试一次
  function wakeWaiting(except) {
    for (const [id, w] of slots) {
      if (id !== except && !w.child && w.lastRefusal === 'capacity') { reconcile(id); if (runningCount() >= maxProcs) break; }
    }
  }

  function scheduleRetry(cid, s, delay) {
    if (s.respawnTimer) clearTimer(s.respawnTimer);
    s.respawnAt = now() + delay;
    s.respawnTimer = setTimer(() => {
      s.respawnTimer = null;
      s.respawnAt = 0;
      reconcile(cid);
    }, delay);
  }

  function stop(cid, s, why) {
    const child = s.child;
    if (!child || s.stopping) return;
    s.stopping = true;
    log.log?.(`${tag(cid)} 停止(${why})`);
    try { child.stdin?.write?.('{"cmd":"stop"}\n'); } catch { /* ignore */ }
    try { child.kill('SIGTERM'); } catch { /* ignore */ }
    s.killTimer = setTimer(() => {
      s.killTimer = null;
      if (s.child === child) { try { child.kill('SIGKILL'); } catch { /* ignore */ } }
    }, KILL_AFTER_MS);
  }

  /// 按当前状态把该圈调到「该跑就跑,不该跑就停」。随便调,幂等。
  function reconcile(circleId) {
    if (typeof circleId !== 'string' || !circleId) return;
    const s = slotOf(circleId);
    const why = refusal(circleId);
    if (why === 'empty' && s.child && !s.stopping) {
      // 房里没人:宽限 20 s 再停(断线重连 / 换设备不该把助手踢掉)
      if (!s.graceTimer) {
        s.graceTimer = setTimer(() => {
          s.graceTimer = null;
          if (refusal(circleId) === 'empty') stop(circleId, s, 'empty');
          else reconcile(circleId);
        }, EMPTY_GRACE_MS);
      }
      return;
    }
    if (s.graceTimer) { clearTimer(s.graceTimer); s.graceTimer = null; }
    if (why) {
      if (s.child) stop(circleId, s, why);
      else if (why !== 'empty' && why !== 'disabled' && why !== 'shutdown' && s.lastRefusal !== why) {
        // 同一原因只说一次,别每次有人进出房都刷屏
        const msg = why === 'e2ee' ? '圈子开了服务端 E2EE,服务器托管不可用(需带口令独立运行 bot)'
          : why === 'no_api_key' ? '未设 LARES_DASHSCOPE_API_KEY'
            : why === 'no_bot' ? `找不到 bot 入口 ${d.botEntry}`
              : why === 'capacity' ? `全站助手进程已达上限 ${maxProcs}(LARES_AI_MAX_PROCESSES)` : '服务器没有该圈的鉴权材料';
        log.log?.(`${tag(circleId)} 不启动:${msg}`);
      }
      s.lastRefusal = why;
      if (why === 'empty' || why === 'disabled') s.parked = false;
      if (why === 'disabled' || why === 'shutdown') {
        // 插件停用:清掉崩溃计数与重试
        if (s.respawnTimer) { clearTimer(s.respawnTimer); s.respawnTimer = null; s.respawnAt = 0; }
      }
      // e2ee / no_api_key / no_auth 留着 slot,好记住「已经说过一次」
      if ((why === 'empty' || why === 'disabled') && !s.child && !s.respawnTimer && !s.graceTimer) cleanupIfIdle(circleId, s);
      return;
    }
    if (s.child) { onConfig(circleId); return; } // 已在跑:顺手把配置变更推下去(没变则不推)
    if (s.parked) return;
    if (s.respawnTimer) return; // 退避中
    if (s.blockedUntil && now() < s.blockedUntil) {
      scheduleRetry(circleId, s, s.blockedUntil - now() + 1000); // 封禁到期再看
      return;
    }
    s.blockedUntil = 0;
    start(circleId, s);
  }

  /// 没跑也没有挂着的计时器,且没有需要记住的状态(崩溃计数 / 封禁)时回收
  function cleanupIfIdle(cid, s) {
    const t = now();
    if (s.blockedUntil > t) return;
    if (s.crashes.some((x) => t - x < HOUR_MS)) return;
    slots.delete(cid);
  }

  /// 配置变了:正在跑的子进程热更新(不重启)
  function onConfig(circleId) {
    const s = slots.get(circleId);
    if (!s?.child || s.stopping) return false;
    const json = JSON.stringify(d.configOf(circleId) ?? {});
    if (json === s.configJson) return false; // 没变(圈级设置广播很频繁,只在真变了时推)
    s.configJson = json;
    try { s.child.stdin?.write?.(`{"cmd":"config","config":${json}}\n`); return true; } catch { return false; }
  }

  function stopAll() {
    stoppedAll = true;
    for (const [cid, s] of slots) {
      for (const k of ['graceTimer', 'respawnTimer']) if (s[k]) { clearTimer(s[k]); s[k] = null; }
      if (s.child) {
        // 关停路径是同步的(进程马上就退):尽量礼貌地 SIGTERM,孤儿进程收不到 stdin 也会因 stdin 关闭而退出
        try { s.child.stdin?.write?.('{"cmd":"stop"}\n'); s.child.stdin?.end?.(); } catch { /* ignore */ }
        try { s.child.kill('SIGTERM'); } catch { /* ignore */ }
        log.log?.(`${tag(cid)} 停止(shutdown)`);
      }
    }
  }

  function status(circleId) {
    const s = slots.get(circleId);
    if (!s) return { running: false, refusal: refusal(circleId) };
    return {
      running: Boolean(s.child) && !s.stopping,
      stopping: Boolean(s.stopping),
      pid: s.child?.pid ?? null,
      startedAt: s.child ? s.startedAt : null,
      graceUntil: s.graceTimer ? true : false,
      respawnAt: s.respawnAt || null,
      blockedUntil: s.blockedUntil || null,
      crashesLastHour: s.crashes.filter((x) => now() - x < HOUR_MS).length,
      lastExit: s.lastExit,
      refusal: refusal(circleId),
    };
  }

  return { reconcile, onConfig, stopAll, status, _slots: slots };
}

/// 按行切 stream;每行过长截断,防一个坏子进程把日志打爆
function lineReader(stream, onLine) {
  if (!stream?.on) return;
  let buf = '';
  stream.setEncoding?.('utf8');
  stream.on('data', (chunk) => {
    buf += String(chunk);
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).replace(/\r$/, '');
      buf = buf.slice(i + 1);
      if (line.trim()) onLine(line.slice(0, 4000));
    }
    if (buf.length > 64 * 1024) buf = '';
  });
  stream.on('end', () => { if (buf.trim()) onLine(buf.slice(0, 4000)); buf = ''; });
}
