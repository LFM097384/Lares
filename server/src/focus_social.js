// 专注社交 —— 每轮出勤、连续打卡、每周小结。契约见 docs/plans/plugin-focus-contract.md §10。
//
//   出勤:focus 引擎每个专注段到点发 round_end(带每人本轮专注 ms),这里判全勤
//         (本轮离开 ≤ graceSec + 2 s 容差)并广播 focus_round 给房里的人。
//   打卡:本轮全勤 = 这一天「完成了一轮」;按成员本地日(推送订阅上报的时区,否则圈时区,否则 UTC+8 引擎时区)
//         记连续天数。断一天归零。持久化 DATA_DIR/focus_social.json。
//   周报:每周一(圈主时区;没报过 → UTC)把上一周(周一..周日)的专注时长、名次、连续天数、全圈总时长
//         发给每个上周专注过的成员:推送(守免打扰 / 通知等级,免打扰中顺延)+ 进圈时的应用内卡片。
// u_ai_* / bot:* 一概排除。时钟 now() 可注入,tick() 由外部周期调用(测试手动)。

import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { writeFile, rename, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { localParts, keyOfDayIndex, dayIndexOfKey } from './tz.js';

export const GRACE_SLACK_MS = 2000;
const WEEKLY_PUSH_TTL_MS = 2 * 86_400_000; // 免打扰顺延最多两天
const CARD_TTL_DAYS = 7;
const isHuman = (uid) => typeof uid === 'string' && uid && !uid.startsWith('u_ai_') && !uid.startsWith('bot:');
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/// 出勤判定(纯函数)。round = 引擎 round_end 载荷
export function attendance(round, slackMs = GRACE_SLACK_MS) {
  const limit = (round.graceMs ?? 0) + slackMs;
  const members = (round.members ?? [])
    .filter((m) => isHuman(m.userId) && (m.focusMs > 0 || m.inRoom))
    .map((m) => ({ userId: m.userId, name: m.name, awayMs: m.awayMs, full: m.awayMs <= limit }))
    .sort((a, b) => Number(b.full) - Number(a.full) || a.awayMs - b.awayMs || a.userId.localeCompare(b.userId));
  return {
    circleId: round.circleId, round: round.round, rounds: round.rounds, endedAt: round.endedAt, lenMs: round.lenMs,
    total: members.length, full: members.filter((m) => m.full).length, members,
  };
}

/// 打卡推进(纯函数)。s = {last:'YYYY-MM-DD', n, best} | undefined
export function bumpStreak(s, dayKey) {
  const today = dayIndexOfKey(dayKey);
  if (!s || !s.last) return { last: dayKey, n: 1, best: Math.max(1, s?.best ?? 0) };
  const last = dayIndexOfKey(s.last);
  if (today <= last) return s; // 同一天(或时钟倒退)不重复计
  const n = today === last + 1 ? s.n + 1 : 1;
  return { last: dayKey, n, best: Math.max(s.best ?? 0, n) };
}

/// 当前有效连续天数:最后打卡是今天或昨天才算数
export function currentStreak(s, todayKey) {
  if (!s?.last) return 0;
  const gap = dayIndexOfKey(todayKey) - dayIndexOfKey(s.last);
  return gap === 0 || gap === 1 ? s.n : 0;
}

/// 周报(纯函数):days = 引擎日桶;weekStartKey = 上周一
export function weeklySummary(days, names, weekStartKey) {
  const start = dayIndexOfKey(weekStartKey);
  const sums = {};
  for (let i = start; i < start + 7; i++) {
    for (const [uid, ms] of Object.entries(days[keyOfDayIndex(i)] ?? {})) {
      if (!isHuman(uid) || !(ms > 0)) continue;
      sums[uid] = (sums[uid] ?? 0) + ms;
    }
  }
  const rows = Object.entries(sums).map(([userId, ms]) => ({ userId, name: names?.[userId] ?? userId, focusMs: Math.round(ms) }))
    .sort((a, b) => b.focusMs - a.focusMs || a.userId.localeCompare(b.userId));
  rows.forEach((r, i) => { r.rank = i + 1; });
  const circleTotalMs = rows.reduce((a, r) => a + r.focusMs, 0);
  return { week: weekStartKey, rows, circleTotalMs, members: rows.length };
}

/**
 * @param {object} d
 *   now(), dataDir, log
 *   engineTz: {offsetMin}            引擎日桶的时区(LARES_FOCUS_TZ_OFFSET_MIN)
 *   daysOf(cid) → {names, days}      focus 引擎排行榜日桶
 *   circleIds() → string[]           有专注数据的圈(周报扫描)
 *   circleTz(cid) → TzSpec|null      圈主时区(push_triggers 记的)
 *   userTz(uid) → TzSpec|null        成员时区(推送订阅上报的)
 *   deliver(uid, cid, vars) → 'sent'|'deferred'|'skip'   周报推送(push_triggers.deliverToUser)
 *   send(ws,msg), sessionsOfCircle(cid), circleAllowed(session,cid), exists(cid)
 */
export function createFocusSocial(d) {
  const now = d.now ?? Date.now;
  const log = d.log ?? console;
  const file = d.dataDir ? path.join(d.dataDir, 'focus_social.json') : null;
  const engineTz = d.engineTz ?? { offsetMin: 480 };

  // { circles: { [cid]: { streaks:{uid:{last,n,best}}, week?:'YYYY-MM-DD', cards:{uid:card}, pending:{uid:{vars,until}} } } }
  let store = { circles: {} };
  if (file) {
    try {
      const p = JSON.parse(readFileSync(file, 'utf8'));
      if (isObj(p?.circles)) store = { circles: p.circles };
    } catch (e) { if (e?.code !== 'ENOENT') log.error?.('[focus-social] 读取失败,以空表启动:', e?.message ?? e); }
  }
  const rec = (cid) => {
    const r = (store.circles[cid] ??= {});
    if (!isObj(r.streaks)) r.streaks = {};
    if (!isObj(r.cards)) r.cards = {};
    if (!isObj(r.pending)) r.pending = {};
    return r;
  };

  let writing = Promise.resolve();
  function save() {
    if (!file) return;
    const snap = JSON.stringify(store);
    writing = writing.then(async () => {
      await mkdir(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      await writeFile(tmp, snap, { mode: 0o600 });
      await rename(tmp, file);
    }).catch((e) => log.error?.('[focus-social] 写盘失败:', e?.message ?? e));
    return writing;
  }
  function flushSync() {
    if (!file) return;
    try {
      mkdirSync(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.sync.tmp`;
      writeFileSync(tmp, JSON.stringify(store), { mode: 0o600 });
      renameSync(tmp, file);
    } catch (e) { log.error?.('[focus-social] 同步落盘失败:', e?.message ?? e); }
  }

  const tzOfUser = (cid, uid) => d.userTz?.(uid) ?? d.circleTz?.(cid) ?? engineTz;
  const todayOf = (cid, uid, t = now()) => localParts(t, tzOfUser(cid, uid)).dayKey;

  function toSessions(cid, msg) { for (const ws of d.sessionsOfCircle?.(cid) ?? []) d.send(ws, msg); }

  function streaksOf(cid) {
    const out = {};
    const t = now();
    for (const [uid, s] of Object.entries(store.circles[cid]?.streaks ?? {})) {
      if (!isHuman(uid)) continue;
      const n = currentStreak(s, todayOf(cid, uid, t));
      if (n > 0) out[uid] = n;
    }
    return out;
  }
  const streaksMsg = (cid) => ({ t: 'focus_streaks', circleId: cid, streaks: streaksOf(cid) });

  /// 引擎 round_end → 出勤广播 + 打卡
  function onRoundEnd(cid, round) {
    try {
      const a = attendance(round);
      if (a.total === 0) return null;
      toSessions(cid, { t: 'focus_round', ...a });
      const r = rec(cid);
      let changed = false;
      for (const m of a.members) {
        if (!m.full) continue;
        const prev = r.streaks[m.userId];
        const next = bumpStreak(prev, todayOf(cid, m.userId, round.endedAt ?? now()));
        if (next !== prev) { r.streaks[m.userId] = next; changed = true; }
      }
      if (changed) { save(); toSessions(cid, streaksMsg(cid)); }
      return a;
    } catch (e) { log.error?.('[focus-social] round_end 出错:', e); return null; }
  }

  // ── 周报 ──
  /// 该圈此刻是否该出周报;返回上周一的 key 或 null
  function dueWeek(cid, t) {
    const lp = localParts(t, d.circleTz?.(cid) ?? {});
    if (lp.dow !== 1) return null; // 只在本地周一出
    const lastMonday = keyOfDayIndex(lp.dayIndex - 7);
    return store.circles[cid]?.week === lastMonday ? null : lastMonday;
  }

  function runWeekly(cid, weekKey) {
    const r = rec(cid);
    r.week = weekKey;
    const { days, names } = d.daysOf(cid);
    const sum = weeklySummary(days, names, weekKey);
    const t = now();
    for (const row of sum.rows) {
      const card = {
        week: weekKey, focusMs: row.focusMs, rank: row.rank, of: sum.members,
        streak: currentStreak(r.streaks[row.userId], todayOf(cid, row.userId, t)),
        circleTotalMs: sum.circleTotalMs, createdAt: t, seen: false,
      };
      r.cards[row.userId] = card;
      r.pending[row.userId] = { until: t + WEEKLY_PUSH_TTL_MS };
    }
    save();
    flushPending(cid);
    return sum;
  }

  function flushPending(cid) {
    const r = store.circles[cid];
    if (!r?.pending) return;
    const t = now();
    let changed = false;
    for (const [uid, p] of Object.entries(r.pending)) {
      const card = r.cards?.[uid];
      if (!card || t > p.until || card.seen) { delete r.pending[uid]; changed = true; continue; }
      const res = d.deliver?.(uid, cid, card) ?? 'skip';
      if (res !== 'deferred') { delete r.pending[uid]; changed = true; }
    }
    if (changed) save();
  }

  function pruneCards(cid, t) {
    const r = store.circles[cid];
    if (!r?.cards) return;
    const today = localParts(t, {}).dayIndex;
    for (const [uid, c] of Object.entries(r.cards)) {
      if (today - dayIndexOfKey(c.week) > 7 + CARD_TTL_DAYS) delete r.cards[uid];
    }
  }

  /// 周期调用(index.js 每分钟)。返回本次出了周报的圈
  function tick() {
    const t = now();
    const fired = [];
    const ids = new Set([...(d.circleIds?.() ?? []), ...Object.keys(store.circles)]);
    for (const cid of ids) {
      try {
        if (d.exists && !d.exists(cid)) continue;
        const wk = dueWeek(cid, t);
        if (wk) { runWeekly(cid, wk); fired.push(cid); } else flushPending(cid);
        pruneCards(cid, t);
      } catch (e) { log.error?.('[focus-social] 周报出错:', cid, e); }
    }
    return fired;
  }

  function cardFor(cid, uid) {
    const c = store.circles[cid]?.cards?.[uid];
    return c && !c.seen ? c : null;
  }

  // ── 信令 ──
  // focus_social_get {circleId} → focus_streaks + focus_weekly{card|null}
  // focus_weekly_seen {circleId, week} → 卡片标已读(之后不再推这周的周报)
  async function handle(ws, session, msg) {
    const op = msg?.t;
    if (op !== 'focus_social_get' && op !== 'focus_weekly_seen') return false;
    const cid = typeof msg.circleId === 'string' ? msg.circleId : '';
    const fail = (reason) => { d.send(ws, { t: 'focus_error', op, circleId: cid, reason }); return true; };
    if (!session.userId || !session.authed) return fail('say_hello_first');
    if (!cid) return fail('bad_request');
    if (!d.circleAllowed(session, cid)) return fail('forbidden');
    if (op === 'focus_social_get') {
      d.send(ws, streaksMsg(cid));
      d.send(ws, { t: 'focus_weekly', circleId: cid, card: cardFor(cid, session.userId) });
      return true;
    }
    const c = store.circles[cid]?.cards?.[session.userId];
    if (c && (msg.week === undefined || msg.week === c.week)) {
      c.seen = true;
      delete store.circles[cid].pending?.[session.userId];
      save();
    }
    d.send(ws, { t: 'focus_weekly', circleId: cid, card: null });
    return true;
  }

  function dropCircle(cid) {
    if (store.circles[cid]) { delete store.circles[cid]; save(); }
  }

  return {
    onRoundEnd, tick, runWeekly, handle, streaksOf, cardFor, dropCircle, flushSync,
    whenSaved: () => writing, _store: () => store,
  };
}
