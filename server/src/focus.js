// 专注学习(lares.focus)—— 计时引擎 + 信令处理(契约 docs/plans/plugin-focus-contract.md §6)。
//
// 引擎是纯逻辑:时钟 now() 与定时器 setTimer/clearTimer 都可注入,测试用假时钟 + 手动 tick() 驱动。
// 计时规则:
//   专注中计时 = 启用 ∧ 在房 ∧ 未离开 ∧ phase≠break;离开计时 = 启用 ∧ 在房 ∧ away ∧ phase≠break。
//   多设备:成员所有在房设备都 away 才算 away。归属只看会话(userId/deviceId),消息里的 userId 不看。
//   focus_away 的 since 夹到 [now−10min, now],且不早于「本次进房 / 上次回来 / 本段可计时开始(启用、休息结束)」——
//   这样 [since, now] 这段一定是按「专注」记过账的,回溯改记成「离开」是精确的。
// 排行榜只累计专注时长(不含离开),按本地日(LARES_FOCUS_TZ_OFFSET_MIN,默认 UTC+8)分桶。

import { mkdirSync, readFileSync, writeFileSync, renameSync, unlinkSync } from 'node:fs';
import { mkdir, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { TokenBuckets } from './ratelimit.js';

export const FOCUS_PLUGIN_ID = 'lares.focus';
export const FOCUS_DEFAULTS = Object.freeze({ focusMin: 25, breakMin: 5, rounds: 4, graceSec: 10, membersCanStart: false, chatInBreak: true });
const RANGES = { focusMin: [1, 180], breakMin: [1, 60], rounds: [1, 12], graceSec: [0, 300] };
export const SINCE_MAX_BACK_MS = 10 * 60_000;
export const KEEP_DAYS = 60;
export const BOARD_MAX = 50;
const DAY_MS = 86_400_000;

/// 严格校验 + 缺省补默认。{ok:true, config} | {ok:false, detail}
export function normalizeFocusConfig(cfg) {
  if (cfg === null || typeof cfg !== 'object' || Array.isArray(cfg)) return { ok: false, detail: 'not_object' };
  const out = { ...FOCUS_DEFAULTS };
  for (const [k, v] of Object.entries(cfg)) {
    if (!Object.prototype.hasOwnProperty.call(FOCUS_DEFAULTS, k)) return { ok: false, detail: `unknown_field:${k}` };
    if (RANGES[k]) {
      const [lo, hi] = RANGES[k];
      if (!Number.isInteger(v) || v < lo || v > hi) return { ok: false, detail: `${k}:${lo}..${hi}` };
    } else if (typeof v !== 'boolean') return { ok: false, detail: `${k}:boolean` };
    out[k] = v;
  }
  return { ok: true, config: out };
}

/// 本地日 key 'YYYY-MM-DD'
export function dayKey(t, tzOffsetMin) {
  const d = new Date(t + tzOffsetMin * 60_000);
  return d.toISOString().slice(0, 10);
}
const localDayIndex = (t, off) => Math.floor((t + off * 60_000) / DAY_MS);
const keyOfIndex = (i) => new Date(i * DAY_MS).toISOString().slice(0, 10);

/**
 * @param {object} o
 * @param {string} [o.dataDir]       有则持久化到 dataDir/focus/<circleId>.json
 * @param {() => number} [o.now]
 * @param {number} [o.tzOffsetMin]
 * @param {(fn:Function, ms:number)=>any} [o.setTimer]  null = 不自动推进(测试手动 tick)
 * @param {(h:any)=>void} [o.clearTimer]
 * @param {(circleId:string) => {installed:boolean, enabled:boolean, config:object, state?:object}} [o.pluginOf]
 * @param {(circleId:string, ev:object) => void} [o.out]  输出:{type:'notice', notice} | {type:'status'} | {type:'pomodoro', pomodoro}
 */
export function createFocusEngine({
  dataDir = null,
  now = Date.now,
  tzOffsetMin = 480,
  setTimer = (fn, ms) => { const h = setTimeout(fn, ms); h.unref?.(); return h; },
  clearTimer = (h) => clearTimeout(h),
  pluginOf = () => ({ installed: false, enabled: false, config: { ...FOCUS_DEFAULTS } }),
  out = () => {},
  log = console,
} = {}) {
  /** @type {Map<string, any>} */
  const circles = new Map();
  const dir = dataDir ? path.join(dataDir, 'focus') : null;
  const fileOf = (circleId) => (dir ? path.join(dir, `${encodeURIComponent(circleId)}.json`) : null);
  const flushing = new Map(); // circleId -> {running, again}

  const idlePomodoro = (rounds) => ({ phase: 'idle', endsAt: null, round: 0, rounds });

  function loadBoard(circleId) {
    const empty = { names: {}, days: {}, totals: {} };
    const f = fileOf(circleId);
    if (!f) return empty;
    try {
      const p = JSON.parse(readFileSync(f, 'utf8'));
      const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
      return { names: obj(p.names), days: obj(p.days), totals: obj(p.totals) };
    } catch (e) {
      if (e?.code !== 'ENOENT') log.error?.('[focus] 读取排行榜失败:', circleId, e?.message ?? e);
      return empty;
    }
  }

  function circle(circleId) {
    let c = circles.get(circleId);
    if (c) return c;
    const p = pluginOf(circleId) ?? { installed: false, enabled: false, config: { ...FOCUS_DEFAULTS } };
    const t = now();
    c = {
      id: circleId,
      enabled: p.enabled === true,
      config: { ...FOCUS_DEFAULTS, ...(p.config ?? {}) },
      members: new Map(),
      pomodoro: idlePomodoro((p.config ?? FOCUS_DEFAULTS).rounds ?? FOCUS_DEFAULTS.rounds),
      floor: t, // 本段「可计时」开始时刻(启用 / 休息结束)
      board: loadBoard(circleId),
      dirty: false,
      timer: null,
    };
    // 重启后恢复番茄钟(存在 lares.focus 的共享状态里)
    const saved = p.state?.pomodoro;
    if (c.enabled && saved && (saved.phase === 'focus' || saved.phase === 'break') && Number.isFinite(saved.endsAt)) {
      c.pomodoro = {
        phase: saved.phase, endsAt: saved.endsAt,
        round: Number.isInteger(saved.round) ? saved.round : 1,
        rounds: Number.isInteger(saved.rounds) ? saved.rounds : c.config.rounds,
        ...(typeof saved.startedBy === 'string' ? { startedBy: saved.startedBy } : {}),
      };
    }
    circles.set(circleId, c);
    schedule(c);
    return c;
  }

  // 只有番茄钟的专注段才计时 / 记离开:没开钟(idle)时房间照常,聊天也开着(2026-10 用户定)
  const counting = (c) => c.enabled && c.pomodoro.phase === 'focus';

  function credit(c, userId, from, to, sign = 1) {
    if (to <= from) return;
    let a = from;
    while (a < to) {
      const idx = localDayIndex(a, tzOffsetMin);
      const end = Math.min(to, (idx + 1) * DAY_MS - tzOffsetMin * 60_000);
      const ms = (end - a) * sign;
      const k = keyOfIndex(idx);
      const day = (c.board.days[k] ??= {});
      day[userId] = Math.max(0, (day[userId] ?? 0) + ms);
      c.board.totals[userId] = Math.max(0, (c.board.totals[userId] ?? 0) + ms);
      a = end;
    }
    c.dirty = true;
  }

  function settle(c, t = now()) {
    for (const [uid, m] of c.members) {
      if (t > m.lastSettle) {
        const d = t - m.lastSettle;
        if (counting(c)) {
          if (m.away) m.awayMs += d;
          else { m.focusMs += d; credit(c, uid, m.lastSettle, t); }
        }
        m.lastSettle = t;
      }
    }
  }

  /// 先把到期的番茄钟阶段推进完,再结算到 t(否则迟到的 tick 会把休息时间记成专注)
  function catchUp(c, t) {
    tickCircle(c, t);
    settle(c, t);
  }

  const memberAwayNow = (m) => m.devices.size > 0 && [...m.devices.values()].every((dv) => dv.away);

  function notice(c, n) { out(c.id, { type: 'notice', notice: { circleId: c.id, ...n } }); }
  function changed(c, force = false) { out(c.id, { type: 'status', force }); }
  function pomodoroChanged(c) { out(c.id, { type: 'pomodoro', pomodoro: { ...c.pomodoro } }); }

  /// 成员 away 态重新计算;since = 变成 away 的时刻(只在变成 away 时用)
  function reevaluate(c, uid, m, t, since = t) {
    const want = memberAwayNow(m);
    if (want && !m.away) {
      const s = Math.max(Math.min(since, t), m.floor, c.floor, t - SINCE_MAX_BACK_MS);
      if (counting(c) && s < t) {
        // 回溯:[s, t] 已按专注记过账,改记离开
        const retro = t - s;
        m.focusMs = Math.max(0, m.focusMs - retro);
        m.awayMs += retro;
        credit(c, uid, s, t, -1);
      }
      m.away = true;
      m.awaySince = s;
      m.awayNotified = counting(c);
      if (m.awayNotified) notice(c, { kind: 'away', userId: uid, name: m.name, awaySince: s });
      changed(c);
    } else if (!want && m.away) {
      const awayMs = t - m.awaySince;
      const notified = m.awayNotified;
      m.away = false;
      m.awaySince = null;
      m.awayNotified = false;
      m.floor = t;
      if (notified) notice(c, { kind: 'back', userId: uid, name: m.name, awayMs });
      changed(c);
    }
  }

  // ── 进出房(index.js 的 join/leave 钩子)──
  function join(circleId, userId, deviceId, name) {
    const c = circle(circleId);
    const t = now();
    catchUp(c, t);
    let m = c.members.get(userId);
    if (!m) {
      m = { name, devices: new Map(), focusMs: 0, awayMs: 0, away: false, awaySince: null, awayNotified: false, floor: t, lastSettle: t };
      c.members.set(userId, m);
    }
    m.name = name ?? m.name;
    if (c.board.names[userId] !== name && name) { c.board.names[userId] = name; c.dirty = true; }
    m.devices.set(deviceId, { away: false, since: null });
    reevaluate(c, userId, m, t);
    changed(c);
  }

  /// 返回 {gone:boolean, leftEarly:boolean}
  function leave(circleId, userId, deviceId) {
    const c = circles.get(circleId);
    const m = c?.members.get(userId);
    if (!m) return { gone: false, leftEarly: false };
    const t = now();
    catchUp(c, t);
    m.devices.delete(deviceId);
    if (m.devices.size > 0) {
      reevaluate(c, userId, m, t);
      changed(c);
      return { gone: false, leftEarly: false };
    }
    c.members.delete(userId);
    const leftEarly = counting(c);
    if (leftEarly) notice(c, { kind: 'left_early', userId, name: m.name });
    changed(c);
    flushSoon(c);
    maybeDrop(c);
    return { gone: true, leftEarly };
  }

  function away(circleId, userId, deviceId, since) {
    const c = circles.get(circleId);
    const m = c?.members.get(userId);
    const dv = m?.devices.get(deviceId);
    if (!dv) return false;
    const t = now();
    catchUp(c, t);
    let s = Number.isFinite(since) ? since : t;
    s = Math.min(t, Math.max(s, t - SINCE_MAX_BACK_MS));
    dv.away = true;
    dv.since = s;
    // 成员级的「变 away 时刻」= 最后一台设备离开的时刻
    const sinces = [...m.devices.values()].map((x) => x.since ?? t);
    reevaluate(c, userId, m, t, Math.max(...sinces));
    return true;
  }

  function back(circleId, userId, deviceId) {
    const c = circles.get(circleId);
    const m = c?.members.get(userId);
    const dv = m?.devices.get(deviceId);
    if (!dv) return false;
    const t = now();
    catchUp(c, t);
    dv.away = false;
    dv.since = null;
    reevaluate(c, userId, m, t);
    return true;
  }

  // ── 番茄钟 ──
  function start(circleId, userId) {
    const c = circle(circleId);
    if (!c.enabled) return false;
    const t = now();
    catchUp(c, t);
    if (c.pomodoro.phase !== 'focus') resumeCounting(c, t);
    c.pomodoro = { phase: 'focus', endsAt: t + c.config.focusMin * 60_000, round: 1, rounds: c.config.rounds, ...(userId ? { startedBy: userId } : {}) };
    notice(c, { kind: 'started', phase: 'focus', round: 1, endsAt: c.pomodoro.endsAt, ...(userId ? { userId } : {}) });
    pomodoroChanged(c);
    changed(c);
    schedule(c);
    flushSoon(c);
    return true;
  }

  function stop(circleId, userId, { silent = false } = {}) {
    const c = circles.get(circleId) ?? circle(circleId);
    const t = now();
    catchUp(c, t);
    const wasRunning = c.pomodoro.phase !== 'idle';
    c.pomodoro = idlePomodoro(c.config.rounds);
    enterBreak(c, t); // 停钟后不再计时:此刻离开着的人回来也不广播
    if (wasRunning) {
      if (!silent) notice(c, { kind: 'stopped', ...(userId ? { userId } : {}) });
      pomodoroChanged(c);
    }
    changed(c);
    schedule(c);
    flushSoon(c);
    return wasRunning;
  }

  /// 休息结束(或停钟)时:重开计时段;休息期间离开的人从这一刻起算离开
  function resumeCounting(c, t) {
    c.floor = t;
    for (const [uid, m] of c.members) {
      m.lastSettle = t;
      if (m.away) {
        m.awaySince = t;
        m.awayNotified = true;
        notice(c, { kind: 'away', userId: uid, name: m.name, awaySince: t });
      }
    }
  }

  function enterBreak(c, t) {
    for (const m of c.members.values()) {
      if (m.away) m.awayNotified = false; // 休息中回来不发 back
    }
  }

  /// 推进到期的阶段。返回是否有变化。
  function tickCircle(c, t = now()) {
    let moved = false;
    while (c.enabled && c.pomodoro.phase !== 'idle' && c.pomodoro.endsAt !== null && c.pomodoro.endsAt <= t) {
      const at = c.pomodoro.endsAt;
      settle(c, at);
      const p = c.pomodoro;
      if (p.phase === 'focus') {
        if (p.round >= p.rounds) {
          c.pomodoro = idlePomodoro(c.config.rounds);
          enterBreak(c, at);
          notice(c, { kind: 'stopped' });
        } else {
          c.pomodoro = { ...p, phase: 'break', endsAt: at + c.config.breakMin * 60_000 };
          enterBreak(c, at);
          notice(c, { kind: 'phase', phase: 'break', round: p.round, endsAt: c.pomodoro.endsAt });
        }
      } else {
        c.pomodoro = { ...p, phase: 'focus', round: p.round + 1, endsAt: at + c.config.focusMin * 60_000 };
        resumeCounting(c, at);
        notice(c, { kind: 'phase', phase: 'focus', round: c.pomodoro.round, endsAt: c.pomodoro.endsAt });
      }
      moved = true;
    }
    if (moved) {
      settle(c, t);
      pomodoroChanged(c);
      changed(c);
      flushSoon(c);
    }
    schedule(c);
    return moved;
  }

  function tick() {
    const t = now();
    for (const c of [...circles.values()]) tickCircle(c, t);
  }

  function schedule(c) {
    if (c.timer) { clearTimer(c.timer); c.timer = null; }
    if (!setTimer || !c.enabled || c.pomodoro.phase === 'idle' || c.pomodoro.endsAt === null) return;
    const ms = Math.max(0, c.pomodoro.endsAt - now()) + 5;
    c.timer = setTimer(() => { c.timer = null; tickCircle(c); }, Math.min(ms, 2 ** 31 - 1));
  }

  // ── 插件状态变化(装/卸/启停/改配置)──
  function setPlugin(circleId, { installed, enabled, config, byOwner = true }) {
    const c = circle(circleId);
    const t = now();
    catchUp(c, t);
    const was = c.enabled;
    const on = installed && enabled === true;
    if (config) {
      c.config = { ...FOCUS_DEFAULTS, ...config };
      if (c.pomodoro.phase !== 'idle') c.pomodoro.rounds = c.config.rounds;
    }
    if (was && !on) {
      // 圈主停用/卸载:结算、番茄钟清零
      const running = c.pomodoro.phase !== 'idle';
      c.pomodoro = idlePomodoro(c.config.rounds);
      c.enabled = false;
      for (const m of c.members.values()) { m.away = memberAwayNow(m); m.awaySince = m.away ? t : null; m.awayNotified = false; }
      if (byOwner) notice(c, { kind: 'ended_by_owner' });
      if (running && installed) pomodoroChanged(c);
    } else if (!was && on) {
      c.enabled = true;
      c.floor = t;
      for (const m of c.members.values()) { m.lastSettle = t; m.floor = t; if (m.away) { m.awaySince = t; m.awayNotified = true; } }
    } else {
      c.enabled = on;
    }
    changed(c, true);
    schedule(c);
    flushSoon(c);
  }

  // ── 读 ──
  function memberRows(c) {
    const rows = [];
    for (const [uid, m] of c.members) {
      rows.push({
        userId: uid,
        name: m.name,
        state: c.pomodoro.phase === 'break' ? 'break' : c.pomodoro.phase === 'idle' ? 'idle' : m.away ? 'away' : 'focus',
        awaySince: m.away ? m.awaySince : null,
        focusMs: Math.round(m.focusMs),
        awayMs: Math.round(m.awayMs),
      });
    }
    return rows;
  }

  function status(circleId) {
    const c = circle(circleId);
    const t = now();
    catchUp(c, t);
    return {
      circleId, now: t, enabled: c.enabled, config: { ...c.config },
      pomodoro: { ...c.pomodoro }, members: memberRows(c),
    };
  }

  function rowsOf(c, sums) {
    return Object.entries(sums)
      .filter(([, ms]) => ms > 0)
      .map(([userId, ms]) => ({ userId, name: c.board.names[userId] ?? c.members.get(userId)?.name ?? userId, ms: Math.round(ms) }))
      .sort((a, b) => b.ms - a.ms || a.userId.localeCompare(b.userId))
      .slice(0, BOARD_MAX);
  }

  function board(circleId) {
    const c = circle(circleId);
    const t = now();
    catchUp(c, t);
    const today = localDayIndex(t, tzOffsetMin);
    const dow = new Date(today * DAY_MS).getUTCDay(); // 0=周日
    const monday = today - ((dow + 6) % 7);
    const week = {};
    for (let i = monday; i <= today; i++) {
      for (const [uid, ms] of Object.entries(c.board.days[keyOfIndex(i)] ?? {})) week[uid] = (week[uid] ?? 0) + ms;
    }
    return {
      circleId,
      today: rowsOf(c, c.board.days[keyOfIndex(today)] ?? {}),
      week: rowsOf(c, week),
      all: rowsOf(c, c.board.totals),
    };
  }

  // ── 持久化 ──
  function prune(c) {
    const cutoff = localDayIndex(now(), tzOffsetMin) - KEEP_DAYS + 1;
    for (const k of Object.keys(c.board.days)) {
      const idx = Math.floor(Date.parse(`${k}T00:00:00Z`) / DAY_MS);
      if (!Number.isFinite(idx) || idx < cutoff) delete c.board.days[k];
    }
  }

  function serialize(c) {
    prune(c);
    return JSON.stringify(c.board);
  }

  async function flushCircle(c) {
    const f = fileOf(c.id);
    if (!f) { c.dirty = false; return; }
    let st = flushing.get(c.id);
    if (st?.running) { st.again = true; return st.promise; }
    st = { running: true, again: false, promise: null };
    flushing.set(c.id, st);
    st.promise = (async () => {
      try {
        do {
          st.again = false;
          if (!c.dirty) break;
          c.dirty = false;
          const data = serialize(c);
          if (c.deleted) break;
          await mkdir(dir, { recursive: true });
          const tmp = `${f}.${process.pid}.tmp`;
          await writeFile(tmp, data, { mode: 0o600 });
          if (c.deleted) break;
          await rename(tmp, f);
        } while (st.again);
      } catch (e) {
        c.dirty = true;
        log.error?.('[focus] 排行榜写盘失败:', c.id, e?.message ?? e);
      } finally {
        st.running = false;
        flushing.delete(c.id);
      }
    })();
    return st.promise;
  }

  function flushSoon(c) { if (c.dirty) flushCircle(c); }

  /// 周期:结算 + 落盘(index.js 每 30 s 调)
  async function flushAll() {
    const t = now();
    await Promise.all([...circles.values()].map((c) => { catchUp(c, t); return flushCircle(c); }));
  }

  /// 关进程:同步结算落盘
  function flushSync() {
    const t = now();
    for (const c of circles.values()) {
      catchUp(c, t);
      const f = fileOf(c.id);
      if (!f || !c.dirty || c.deleted) continue;
      try {
        mkdirSync(dir, { recursive: true });
        const tmp = `${f}.${process.pid}.sync.tmp`;
        writeFileSync(tmp, serialize(c), { mode: 0o600 });
        renameSync(tmp, f);
        c.dirty = false;
      } catch (e) { log.error?.('[focus] 同步落盘失败:', c.id, e?.message ?? e); }
    }
  }

  function maybeDrop(c) {
    if (c.members.size === 0 && c.pomodoro.phase === 'idle' && !c.dirty && !flushing.has(c.id)) {
      if (c.timer) clearTimer(c.timer);
      circles.delete(c.id);
    }
  }

  function deleteCircle(circleId) {
    const c = circles.get(circleId);
    if (c) { c.deleted = true; if (c.timer) clearTimer(c.timer); circles.delete(circleId); }
    const f = fileOf(circleId);
    if (f) { try { unlinkSync(f); } catch { /* 不存在 */ } }
  }

  /// 有人在房且启用的圈(周期推 status 用)
  function activeCircles() {
    return [...circles.values()].filter((c) => c.enabled && c.members.size > 0).map((c) => c.id);
  }

  function inRoom(circleId, userId, deviceId) {
    return Boolean(circles.get(circleId)?.members.get(userId)?.devices.has(deviceId));
  }

  function isEnabled(circleId) { return circle(circleId).enabled; }
  function configOf(circleId) { return { ...circle(circleId).config }; }
  function pomodoroOf(circleId) { return { ...circle(circleId).pomodoro }; }

  function shutdown() {
    for (const c of circles.values()) if (c.timer) { clearTimer(c.timer); c.timer = null; }
  }

  return {
    join, leave, away, back, start, stop, tick, setPlugin, status, board,
    flushAll, flushSync, deleteCircle, activeCircles, inRoom, isEnabled, configOf, pomodoroOf, shutdown,
  };
}

// ── 信令处理 ─────────────────────────────────────────────────────────────
/**
 * @param {object} d
 *   engine (createFocusEngine 的返回;它的 out 回调要接到本模块的 onEngineEvent)
 *   plugins: {focusPlugin(circleId), applyState(circleId, pluginId, patch)}
 *   send(ws,msg), sessionsOfCircle(id), emit(circleId, event, data)(SSE + webhook)
 *   circleAllowed(session,id), isOwnerFor(session, circleId, ownerKey)
 *   defer(fn)  合并「状态变化即推」用,默认 setImmediate
 */
export function createFocusWs(d) {
  const rate = new TokenBuckets({ capacity: 20, perSec: 5 });
  const pendingStatus = new Set();
  const defer = d.defer ?? ((fn) => setImmediate(fn));
  let flushScheduled = false;
  const cidOf = (msg) => (typeof msg.circleId === 'string' ? msg.circleId : '');
  const connKey = (ws) => (ws._laresConnId ??= Math.random().toString(36).slice(2) + Date.now().toString(36));

  function toSessions(circleId, msg) {
    for (const ws of d.sessionsOfCircle(circleId)) d.send(ws, msg);
  }

  function statusMsg(circleId) {
    return { t: 'focus_status', ...d.engine.status(circleId) };
  }
  function boardMsg(circleId) {
    return { t: 'focus_board', ...d.engine.board(circleId) };
  }

  function pushStatus(circleId) {
    toSessions(circleId, statusMsg(circleId));
  }

  /// 引擎输出 → 推送
  function onEngineEvent(circleId, ev) {
    if (ev.type === 'notice') {
      const n = ev.notice;
      toSessions(circleId, { t: 'focus_notice', ...n });
      d.emit(circleId, 'focus', n);
    } else if (ev.type === 'status') {
      // 没装专注插件的圈不推(进出房也会触发引擎),装/卸/启停那一下强制推
      if (!ev.force && !d.plugins.focusPlugin(circleId).installed) return;
      pendingStatus.add(circleId);
      if (!flushScheduled) {
        flushScheduled = true;
        defer(() => {
          flushScheduled = false;
          const ids = [...pendingStatus];
          pendingStatus.clear();
          for (const id of ids) pushStatus(id);
        });
      }
    } else if (ev.type === 'pomodoro') {
      if (d.plugins.focusPlugin(circleId).installed) {
        Promise.resolve(d.plugins.applyState(circleId, FOCUS_PLUGIN_ID, { pomodoro: ev.pomodoro }))
          .catch((e) => console.error('[focus] 写番茄钟状态失败:', e?.message ?? e));
      }
    }
  }

  async function handle(ws, session, msg) {
    if (typeof msg.t !== 'string' || !msg.t.startsWith('focus_')) return false;
    const op = msg.t;
    const circleId = cidOf(msg);
    const fail = (reason) => { d.send(ws, { t: 'focus_error', op, circleId, reason }); return true; };
    if (!['focus_away', 'focus_back', 'focus_start', 'focus_stop', 'focus_get'].includes(op)) return false;
    if (!session.userId || !session.authed) return fail('say_hello_first');
    if (!circleId) return fail('bad_request');
    if (rate.take(connKey(ws)) > 0) return fail('rate_limited');
    switch (op) {
      case 'focus_away':
      case 'focus_back': {
        if (session.circleId !== circleId || !d.engine.inRoom(circleId, session.userId, session.deviceId)) return fail('not_in_room');
        if (!d.engine.isEnabled(circleId)) return fail('disabled');
        if (op === 'focus_away') {
          if (msg.since !== undefined && msg.since !== null && !Number.isFinite(msg.since)) return fail('bad_request');
          // 只认会话身份:msg.userId 一概不看
          d.engine.away(circleId, session.userId, session.deviceId, msg.since ?? undefined);
        } else {
          d.engine.back(circleId, session.userId, session.deviceId);
        }
        return true;
      }
      case 'focus_start':
      case 'focus_stop': {
        if (!d.circleAllowed(session, circleId) && !d.isOwnerFor(session, circleId, msg.ownerKey)) return fail('forbidden');
        if (!d.engine.isEnabled(circleId)) return fail('disabled');
        if (!d.isOwnerFor(session, circleId, msg.ownerKey)) {
          if (d.engine.configOf(circleId).membersCanStart !== true) return fail('forbidden');
          if (session.circleId !== circleId) return fail('not_in_room');
        }
        if (op === 'focus_start') d.engine.start(circleId, session.userId);
        else d.engine.stop(circleId, session.userId);
        return true;
      }
      case 'focus_get': {
        if (!d.circleAllowed(session, circleId)) return fail('forbidden');
        d.send(ws, statusMsg(circleId));
        d.send(ws, boardMsg(circleId));
        return true;
      }
    }
    return false;
  }

  /// 周期(30 s):推一次 status 刷新累计值 + 落盘
  async function periodic() {
    for (const id of d.engine.activeCircles()) pushStatus(id);
    await d.engine.flushAll();
  }

  /// REST GET /api/v1/focus
  function apiSnapshot(circleId) {
    const p = d.plugins.focusPlugin(circleId);
    const s = d.engine.status(circleId);
    const b = d.engine.board(circleId);
    return {
      circleId, installed: p.installed, enabled: s.enabled, config: s.config, now: s.now,
      pomodoro: s.pomodoro, members: s.members,
      leaderboard: { today: b.today, week: b.week, all: b.all },
    };
  }

  function sweep() { rate.sweep(); }

  return { handle, onEngineEvent, periodic, apiSnapshot, sweep, pushStatus };
}
