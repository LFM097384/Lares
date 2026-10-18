// 隐名之约 v2:服务端托管 agent 进程的监管(规格 server/anonym-agent/AGENT-V2.md §1/§3)。
//
// 套路同 ai_voice_supervisor.js:每圈最多一个子进程;依赖全部注入(圈子状态、鉴权材料、spawn、时钟),
// 本模块不碰 index.js 的全局表 —— 可单测。密钥只走子进程 env,绝不进 argv。
//
// 和语音助手的区别:
//   - 不看插件开关,只看「圈主邀请过」(invite / dismiss);
//   - E2EE 圈照样能跑(媒体密钥由圈主经 anon_agent_key 密封交给 agent,服务器只转发密文);
//   - 子进程自行正常退出(code 0)= 会话结束:清掉邀请,不再拉起;
//   - 房里没真人:宽限后停掉并清掉邀请(agent 自己也会在最后一个真人离开时退出)。

import { spawn as nodeSpawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';

export const ANON_USER_PREFIX = 'u_ai_anon_';
export const EMPTY_GRACE_MS = 20_000;
export const KILL_AFTER_MS = 5_000;
export const BACKOFF_MIN_MS = 5_000;
export const BACKOFF_MAX_MS = 60_000;
export const RESPAWN_MAX_PER_HOUR = 5;
export const MAX_PROCESSES_DEFAULT = 8; // LARES_ANONYM_MAX_PROCESSES
const HOUR_MS = 3_600_000;

/// 子进程 env 里一律删掉的服务端主密钥 / 鉴权材料
export function isMasterSecretKey(k) {
  return k.startsWith('LIVEKIT_') || k.startsWith('LARES_APNS_')
    || k === 'LARES_AUTH_TOKEN' || k === 'LARES_CIRCLE_PASSCODE' || k === 'LARES_CIRCLE_PASSCODES'
    || k === 'LARES_AI_MEMBER_KEY' || k === 'LARES_AI_MEMBER_SECRET' || k === 'LARES_AI_AUTH_SECRET';
}

/// 圈 id 落进目录名:只收 [A-Za-z0-9_-],其它一律拒(杜绝路径穿越)
const CID_DIR_RE = /^[A-Za-z0-9_-]{1,64}$/;
export function memoryDirFor(dataDir, cid) {
  if (typeof cid !== 'string' || !CID_DIR_RE.test(cid)) return null;
  return path.join(dataDir, 'anonym_memory', cid);
}

/**
 * @param {object} d
 *   env, dataDir, agentEntry, signalingUrl,
 *   humanCount(cid) -> int, authFor(cid) -> {secret, v} | null, memberSecretFor(cid) -> string,
 *   userIdFor(cid) -> string, circleE2ee(cid) -> bool, rtcConfigured -> bool,
 *   onChange?(cid)  子进程起 / 停 / 邀请清除后回调(index.js 据此重新协调语音助手、广播 anon_agent_state)
 *   spawn?, now?, setTimer?, clearTimer?, log?, execPath?, emptyGraceMs?
 */
export function createAnonymSupervisor(d) {
  const env = d.env ?? process.env;
  const spawn = d.spawn ?? nodeSpawn;
  const now = d.now ?? Date.now;
  const setTimer = d.setTimer ?? ((fn, ms) => { const h = setTimeout(fn, ms); h.unref?.(); return h; });
  const clearTimer = d.clearTimer ?? ((h) => clearTimeout(h));
  const log = d.log ?? console;
  const execPath = d.execPath ?? process.execPath;
  const graceMs = d.emptyGraceMs ?? EMPTY_GRACE_MS;
  const entryOk = d.agentEntryExists ?? (() => existsSync(d.agentEntry));
  const maxProcs = (() => {
    const raw = String(env.LARES_ANONYM_MAX_PROCESSES ?? '').trim();
    const n = raw ? Number(raw) : NaN;
    return Number.isInteger(n) && n >= 0 ? n : MAX_PROCESSES_DEFAULT;
  })();
  const onChange = (cid) => { try { d.onChange?.(cid); } catch (e) { log.error?.(`${tag(cid)} onChange 出错: ${e?.message ?? e}`); } };

  /** cid -> { invited, k, child, stopping, killTimer, graceTimer, respawnTimer, startedAt, crashes[], backoff, lastExit } */
  const slots = new Map();
  let stoppedAll = false;
  const tag = (cid) => `[anonym-agent ${String(cid).slice(0, 8)}]`;
  const runningCount = () => { let n = 0; for (const s of slots.values()) if (s.child) n++; return n; };
  const slotOf = (cid) => {
    let s = slots.get(cid);
    if (!s) { s = { invited: false, k: null, child: null, crashes: [], backoff: BACKOFF_MIN_MS, lastExit: null }; slots.set(cid, s); }
    return s;
  };

  /// 能不能拉起(不看 invited):null = 能,否则是原因
  function refusal(cid) {
    if (stoppedAll) return 'shutdown';
    if (d.rtcConfigured === false) return 'no_rtc';
    if ((d.humanCount(cid) ?? 0) < 1) return 'empty';
    if (!d.authFor(cid)) return 'no_auth';
    if (!entryOk()) return 'no_agent';
    if (!slots.get(cid)?.child && runningCount() >= maxProcs) return 'capacity';
    return null;
  }

  function childEnv(cid, s, auth) {
    const out = { ...env };
    for (const k of Object.keys(out)) if (isMasterSecretKey(k)) delete out[k];
    out.LARES_AI_AUTH_SECRET = String(auth.secret);
    out.LARES_AI_AUTH_V = String(auth.v === 2 ? 2 : 1);
    out.LARES_AI_MEMBER_SECRET = String(d.memberSecretFor(cid)); // 只对本圈 + 隐名身份有效
    out.LARES_ANONYM_USER_ID = d.userIdFor(cid);
    out.LARES_ANONYM_HOSTED = '1';
    out.LARES_ANONYM_E2EE = d.circleE2ee?.(cid) === true ? '1' : '0';
    if (Number.isInteger(s.k)) out.LARES_ANONYM_K = String(s.k); else delete out.LARES_ANONYM_K;
    if (typeof s.convenerId === 'string' && s.convenerId) out.LARES_ANONYM_CONVENER = s.convenerId; else delete out.LARES_ANONYM_CONVENER;
    const dir = memoryDirFor(d.dataDir, cid);
    if (dir) out.LARES_ANONYM_MEMORY_DIR = dir;
    out.LARES_DATA_DIR = d.dataDir;
    out.LARES_SIGNALING = d.signalingUrl;
    return out;
  }

  function start(cid, s) {
    const auth = d.authFor(cid);
    if (!auth) return;
    const args = [d.agentEntry, '--circle', cid, '--signaling', d.signalingUrl]; // 只有非敏感项
    let child;
    try {
      child = spawn(execPath, args, { env: childEnv(cid, s, auth), stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    } catch (e) {
      log.error?.(`${tag(cid)} 启动失败: ${e?.code ?? 'spawn_failed'}`);
      onExit(cid, s, null, 1, null);
      return;
    }
    s.child = child;
    s.startedAt = now();
    s.stopping = false;
    log.log?.(`${tag(cid)} 已启动 pid=${child.pid ?? '?'}`);
    // 子进程输出可能含会话内容:只记行数与 JSON 事件名,绝不原样落日志
    lineReader(child.stdout, (line) => {
      let ev = null;
      try { ev = JSON.parse(line); } catch { /* 非 JSON:丢弃 */ }
      if (ev && typeof ev.ev === 'string') log.log?.(`${tag(cid)} ev=${ev.ev.slice(0, 40)}${typeof ev.code === 'string' ? ` code=${ev.code.slice(0, 60)}` : ''}`);
    });
    lineReader(child.stderr, () => {}); // 同理:stderr 不转写进服务端日志
    child.stdin?.on?.('error', () => {});
    let settled = false;
    const done = (code, signal) => { if (settled) return; settled = true; onExit(cid, s, child, code, signal); };
    child.on('exit', done);
    child.on('error', (e) => { log.error?.(`${tag(cid)} 子进程错误: ${e?.code ?? 'error'}`); done(null, null); });
    onChange(cid);
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
    if (wasStopping || (code === 0 && !signal)) {
      // 叫它停的,或它自己正常结束(会话结束 / 最后一个真人离开):邀请作废,不再拉起
      if (!wasStopping) s.invited = false;
      if (s.invited) reconcile(cid); else { cleanup(cid, s); onChange(cid); }
      return;
    }
    // 崩溃:还在邀请中就退避重拉,计入每小时上限
    const t = now();
    if (s.startedAt && t - s.startedAt >= 10 * 60_000) s.backoff = BACKOFF_MIN_MS;
    s.crashes = s.crashes.filter((x) => t - x < HOUR_MS);
    if (!s.invited || s.crashes.length >= RESPAWN_MAX_PER_HOUR) {
      if (s.invited) log.error?.(`${tag(cid)} 一小时内崩溃 ${s.crashes.length} 次,邀请作废`);
      s.invited = false;
      cleanup(cid, s);
      onChange(cid);
      return;
    }
    s.crashes.push(t);
    const delay = s.backoff;
    s.backoff = Math.min(BACKOFF_MAX_MS, s.backoff * 2);
    if (s.respawnTimer) clearTimer(s.respawnTimer);
    s.respawnTimer = setTimer(() => { s.respawnTimer = null; reconcile(cid); }, delay);
    onChange(cid);
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

  function cleanup(cid, s) {
    for (const k of ['graceTimer', 'respawnTimer']) if (s[k]) { clearTimer(s[k]); s[k] = null; }
    if (!s.child && !s.invited) slots.delete(cid);
  }

  /// 幂等:按「邀请 + 房间状态」把该圈调到该跑就跑、不该跑就停
  function reconcile(cid) {
    if (typeof cid !== 'string' || !cid) return;
    const s = slots.get(cid);
    if (!s) return;
    if (!s.invited) { if (s.child) stop(cid, s, 'dismissed'); else cleanup(cid, s); return; }
    const why = refusal(cid);
    if (why === 'empty') {
      // 房里没真人:宽限后停掉并作废邀请(断线重连 / 换设备不该把 agent 踢掉)
      if (!s.graceTimer) {
        s.graceTimer = setTimer(() => {
          s.graceTimer = null;
          if (refusal(cid) === 'empty') { s.invited = false; if (s.child) stop(cid, s, 'empty'); else { cleanup(cid, s); onChange(cid); } } else reconcile(cid);
        }, graceMs);
      }
      return;
    }
    if (s.graceTimer) { clearTimer(s.graceTimer); s.graceTimer = null; }
    if (why) {
      if (s.child) stop(cid, s, why);
      return;
    }
    if (s.child || s.respawnTimer) return;
    start(cid, s);
  }

  /// 圈主邀请。返回 {ok:true} 或 {ok:false, code}
  function invite(cid, { k = null, convenerId = null } = {}) {
    const why = refusal(cid);
    if (why && why !== 'capacity') return { ok: false, code: why === 'empty' ? 'not_in_room' : 'unavailable', why };
    if (why === 'capacity') return { ok: false, code: 'busy', why };
    const s = slotOf(cid);
    s.invited = true;
    s.k = Number.isInteger(k) ? k : null;
    s.convenerId = typeof convenerId === 'string' && convenerId.length <= 128 ? convenerId : null;
    s.crashes = [];
    s.backoff = BACKOFF_MIN_MS;
    reconcile(cid);
    return { ok: true };
  }

  function dismiss(cid, why = 'dismissed') {
    const s = slots.get(cid);
    if (!s) return false;
    const was = s.invited || Boolean(s.child);
    s.invited = false;
    if (s.child) stop(cid, s, why); else { cleanup(cid, s); }
    onChange(cid);
    return was;
  }

  function stopAll() {
    stoppedAll = true;
    for (const [cid, s] of slots) {
      for (const k of ['graceTimer', 'respawnTimer']) if (s[k]) { clearTimer(s[k]); s[k] = null; }
      if (s.child) {
        try { s.child.stdin?.write?.('{"cmd":"stop"}\n'); s.child.stdin?.end?.(); } catch { /* ignore */ }
        try { s.child.kill('SIGTERM'); } catch { /* ignore */ }
        log.log?.(`${tag(cid)} 停止(shutdown)`);
      }
    }
  }

  const isInvited = (cid) => Boolean(slots.get(cid)?.invited);
  const isRunning = (cid) => Boolean(slots.get(cid)?.child);
  function status(cid) {
    const s = slots.get(cid);
    return { invited: Boolean(s?.invited), running: Boolean(s?.child) && !s?.stopping, pid: s?.child?.pid ?? null, lastExit: s?.lastExit ?? null, refusal: refusal(cid) };
  }

  return { invite, dismiss, reconcile, stopAll, isInvited, isRunning, status, _slots: slots };
}

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
