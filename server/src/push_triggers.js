// 活动推送(把人拉进房间)—— 触发器 + 防打扰。契约见 docs/plans/plugin-focus-contract.md §9。
//
// 触发器(圈主按圈开关;默认值随用途预设):
//   focus   有人开了番茄钟「阿蛮开始专注了,一起学?」;学习圈里第一个人进房也算(「阿蛮来自习了」)
//   crowd   房里真人数首次达到 N(每个房间会话一次)「圈里已经有 3 个人在聊」
//   arrive  空房来了第一个人「小鹿来了」(旧版 'active' 推送,kind 仍叫 active,默认关)
//   summon  圈主在房里点「叫大家来」「X 叫你来圈里」,每圈 10 分钟一次
//   weekly  周报(focus_social.js 调 deliverToUser)
//
// 防打扰(按接收者):
//   - 成员每圈的「通知我」等级:all(全部) / called(只要被叫:summon + reach) / off;
//   - 此刻在房、或 5 分钟内刚在房 → 不推;
//   - 同一人同一圈活动推送冷却 30 分钟(summon 不受冷却约束,它有自己的每圈 10 分钟);
//   - 每人每天(本地日)上限 8 条活动/被叫推送;
//   - 免打扰时段(默认 23:00–08:00,本地时区由客户端上报;没报过时区的老客户端不套免打扰);
//   - apns-collapse-id = circleId:同一个圈的通知互相替换。
// u_ai_* / bot:* 一概不是人:不算人数、不触发、不接收。
//
// 时钟 now() 可注入;投递 deliver() 可注入(测试用假发送器)。冷却 / 计数只在内存里,重启清零(见文档)。

import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { writeFile, rename, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { localParts, normalizeTz, inWindow } from './tz.js';

export const TRIGGERS = Object.freeze(['focus', 'crowd', 'arrive']);
export const LEVELS = Object.freeze(['all', 'called', 'off']);
export const CROWD_N_RANGE = Object.freeze([2, 12]);
export const PUSH_TRIGGER_DEFAULTS = Object.freeze({
  cooldownMs: 30 * 60_000,
  dailyCap: 8,
  recentMs: 5 * 60_000,
  summonMs: 10 * 60_000,
  quietStart: 23 * 60,
  quietEnd: 8 * 60,
  crowdN: 3,
});

export const isHumanId = (uid) => typeof uid === 'string' && uid.length > 0 && !uid.startsWith('u_ai_') && !uid.startsWith('bot:');
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/// 圈的默认触发器配置。purposeId:'study' | 'chat' | 其它 | null
export function defaultCircleCfg(purposeId, { arriveDefault = false } = {}) {
  const base = { focus: true, crowd: true, arrive: arriveDefault === true };
  if (purposeId === 'study') Object.assign(base, { focus: true, crowd: false });
  else if (purposeId === 'chat') Object.assign(base, { focus: false, crowd: true });
  return { triggers: base, crowdN: PUSH_TRIGGER_DEFAULTS.crowdN };
}

/// 严格校验圈主提交的配置(可部分提交,缺的沿用 base)。{ok, cfg} | {ok:false, detail}
export function normalizeCircleCfg(raw, base) {
  if (!isObj(raw)) return { ok: false, detail: 'not_object' };
  const out = { triggers: { ...base.triggers }, crowdN: base.crowdN };
  for (const [k, v] of Object.entries(raw)) {
    if (k === 'triggers') {
      if (!isObj(v)) return { ok: false, detail: 'triggers:not_object' };
      for (const [tk, tv] of Object.entries(v)) {
        if (!TRIGGERS.includes(tk)) return { ok: false, detail: `triggers.${tk}:unknown` };
        if (typeof tv !== 'boolean') return { ok: false, detail: `triggers.${tk}:not_bool` };
        out.triggers[tk] = tv;
      }
    } else if (k === 'crowdN') {
      const [lo, hi] = CROWD_N_RANGE;
      if (!Number.isInteger(v) || v < lo || v > hi) return { ok: false, detail: `crowdN:${lo}..${hi}` };
      out.crowdN = v;
    } else return { ok: false, detail: `${k}:unknown` };
  }
  return { ok: true, cfg: out };
}

/// push_register.circles[] 一项的通知等级。没有 level 的老客户端:muted → off,否则 all
export function parseLevel(c) {
  if (c && LEVELS.includes(c.level)) return c.level;
  return c?.muted === true ? 'off' : 'all';
}

/// push_register.prefs:{ tz?, tzOffsetMin?, quiet: {start,end} | null }
/// 返回 { tz?|offsetMin?, quiet: {start,end}|null, tzKnown }
export function parseSubPrefs(p) {
  if (!isObj(p)) return { tzKnown: false, quiet: null };
  // tzOffsetMin = 客户端字段;offsetMin = 落盘后的规范字段(重启读回)
  const tz = normalizeTz({ tz: p.tz, offsetMin: p.tzOffsetMin ?? p.offsetMin });
  const tzKnown = Object.keys(tz).length > 0;
  let quiet = { start: PUSH_TRIGGER_DEFAULTS.quietStart, end: PUSH_TRIGGER_DEFAULTS.quietEnd };
  if (p.quiet === null || p.quiet === false) quiet = null;
  else if (isObj(p.quiet)) {
    const ok = (x) => Number.isInteger(x) && x >= 0 && x < 1440;
    if (ok(p.quiet.start) && ok(p.quiet.end)) quiet = { start: p.quiet.start, end: p.quiet.end };
  }
  return { ...tz, tzKnown, quiet };
}

const tzSpecOf = (prefs) => (prefs && prefs.tzKnown ? { tz: prefs.tz, offsetMin: prefs.offsetMin } : null);

/// 推送文案。e2ee:人名一个都不放(推送经过 Apple、显示在锁屏上)
export function pushText(kind, lang, v = {}, e2ee = false) {
  const zh = lang === 'zh';
  if (e2ee) {
    if (kind === 'weekly') return zh ? '你的每周专注小结出来了' : 'Your weekly focus summary is ready';
    return zh ? '有人在你的圈子里' : 'Someone is in your circle';
  }
  const who = (typeof v.who === 'string' && v.who.trim()) || (zh ? '有人' : 'Someone');
  switch (kind) {
    case 'focus': return zh ? `${who}开始专注了,一起学?` : `${who} started a focus session — join in?`;
    case 'study': return zh ? `${who}来自习了,一起学?` : `${who} is here to study — join in?`;
    case 'crowd': return zh ? `圈里已经有 ${v.n} 个人在聊` : `${v.n} people are already hanging out in the circle`;
    case 'arrive': return zh ? `${who}来了` : `${who} is here`;
    case 'summon': return zh ? `${who} 叫你来圈里` : `${who} is calling you to the circle`;
    case 'weekly': {
      const h = (ms) => (Math.round((ms / 3_600_000) * 10) / 10).toString();
      if (zh) return `上周专注 ${h(v.focusMs)} 小时${v.rank ? ` · 第 ${v.rank} 名` : ''}${v.streak ? ` · 🔥${v.streak}` : ''} · 全圈 ${h(v.circleTotalMs)} 小时`;
      return `Last week: ${h(v.focusMs)} h focused${v.rank ? ` · #${v.rank}` : ''}${v.streak ? ` · 🔥${v.streak}` : ''} · circle ${h(v.circleTotalMs)} h`;
    }
    default: return zh ? `${who} 在圈里` : `${who} is in the circle`;
  }
}

/**
 * @param {object} d
 *   now()                       可注入时钟
 *   subs()                      推送订阅表 { [token]: { userId, deviceId, env, lang, circles:{[id]:{name,muted,level}}, prefs } }
 *   roomUsers(circleId)         此刻在房的 userId 列表(含 AI,模块自己过滤)
 *   purposeOf(circleId)         当前用途 id 或 null
 *   e2ee(circleId)              是否 E2EE 圈
 *   deliver(token, entry, circleId, content)  content = {kind, title, body, collapseId}
 *   enabled()                   推送是否可用(APNs 配好了);false 时什么都不发
 *   send(ws,msg), broadcast(circleId,msg), isOwnerFor(session,cid,ownerKey), circleAllowed(session,cid), registeredCircle(cid)
 *   dataDir, log, opts(覆盖 PUSH_TRIGGER_DEFAULTS 与 arriveDefault)
 */
export function createPushTriggers(d) {
  const now = d.now ?? Date.now;
  const log = d.log ?? console;
  const o = { ...PUSH_TRIGGER_DEFAULTS, arriveDefault: false, ...(d.opts ?? {}) };
  const enabled = d.enabled ?? (() => true);
  const file = d.dataDir ? path.join(d.dataDir, 'push_triggers.json') : null;

  // 持久:{ circles: { [cid]: { cfg?: {triggers, crowdN}, tz?: TzSpec } } }
  let store = { circles: {} };
  if (file) {
    try {
      const p = JSON.parse(readFileSync(file, 'utf8'));
      if (isObj(p?.circles)) store = { circles: p.circles };
    } catch (e) { if (e?.code !== 'ENOENT') log.error?.('[push-trig] 读取失败,以空表启动:', e?.message ?? e); }
  }
  // 内存:冷却 / 计数 / 房间会话
  const lastSent = new Map(); // `${uid}\0${cid}` -> t(活动推送)
  const daily = new Map(); // uid -> {day, n}
  const lastLeft = new Map(); // `${cid}\0${uid}` -> t
  const crowdFired = new Set(); // cid(本房间会话已推过 crowd)
  const summonAt = new Map(); // cid -> t

  let writing = Promise.resolve();
  function save() {
    if (!file) return;
    const snap = JSON.stringify(store);
    writing = writing.then(async () => {
      await mkdir(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      await writeFile(tmp, snap, { mode: 0o600 });
      await rename(tmp, file);
    }).catch((e) => log.error?.('[push-trig] 写盘失败:', e?.message ?? e));
  }
  function flushSync() {
    if (!file) return;
    try {
      mkdirSync(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.sync.tmp`;
      writeFileSync(tmp, JSON.stringify(store), { mode: 0o600 });
      renameSync(tmp, file);
    } catch (e) { log.error?.('[push-trig] 同步落盘失败:', e?.message ?? e); }
  }

  const rec = (cid) => store.circles[cid];
  function defaultsOf(cid) { return defaultCircleCfg(d.purposeOf?.(cid) ?? null, { arriveDefault: o.arriveDefault }); }
  /// 生效配置:圈主改过 → 存的那份;否则按用途预设
  function cfgOf(cid) {
    const saved = rec(cid)?.cfg;
    const def = defaultsOf(cid);
    if (!isObj(saved)) return { ...def, custom: false };
    return { triggers: { ...def.triggers, ...saved.triggers }, crowdN: saved.crowdN ?? def.crowdN, custom: true };
  }
  function circleTz(cid) { return rec(cid)?.tz ?? null; }

  const humansIn = (cid) => (d.roomUsers(cid) ?? []).filter(isHumanId);
  /// 圈的功能开关(features-purpose-contract §1):focus 关了 → 不发专注 / 自习 / 周报类推送
  const featureOn = (cid, key) => (d.featureOn ? d.featureOn(cid, key) !== false : true);

  function levelOf(entry, cid) {
    const sub = entry?.circles?.[cid];
    if (!sub) return 'off';
    return LEVELS.includes(sub.level) ? sub.level : (sub.muted ? 'off' : 'all');
  }

  function localOf(entry, t) {
    const spec = tzSpecOf(entry.prefs);
    return spec ? localParts(t, spec) : null;
  }
  function quietNow(entry, t) {
    const q = entry.prefs?.quiet;
    const lp = localOf(entry, t);
    if (!q || !lp) return false; // 没报过时区:不知道对方几点,不套免打扰
    return inWindow(lp.minutes, q.start, q.end);
  }
  function dayOf(entries, t) {
    for (const e of entries) { const lp = localOf(e, t); if (lp) return lp.dayKey; }
    return localParts(t, {}).dayKey;
  }

  /// 按人分组的候选接收者:{ uid -> [ [token, entry], ... ] }
  function candidates(cid, excludeUid) {
    const room = new Set(d.roomUsers(cid) ?? []);
    const by = new Map();
    for (const [token, entry] of Object.entries(d.subs())) {
      const uid = entry?.userId;
      if (!isHumanId(uid) || uid === excludeUid) continue;
      if (!entry.circles?.[cid]) continue;
      if (room.has(uid)) continue;
      if (!by.has(uid)) by.set(uid, []);
      by.get(uid).push([token, entry]);
    }
    return by;
  }

  function capLeft(uid, entries, t) {
    const day = dayOf(entries, t);
    const c = daily.get(uid);
    return !c || c.day !== day ? o.dailyCap : o.dailyCap - c.n;
  }
  function countSent(uid, entries, t) {
    const day = dayOf(entries, t);
    const c = daily.get(uid);
    if (!c || c.day !== day) daily.set(uid, { day, n: 1 }); else c.n++;
  }

  /**
   * 对一个圈按规则推一轮。cls:'activity'(要 level=all + 冷却)| 'called'(level∈{all,called},无冷却)
   * 返回实际推到的人数。
   */
  function fanout(cid, causerUid, cls, kind, vars) {
    if (!enabled()) return 0;
    const t = now();
    let n = 0;
    for (const [uid, devs] of candidates(cid, causerUid)) {
      const left = lastLeft.get(`${cid}\0${uid}`);
      if (left !== undefined && t - left < o.recentMs) continue;
      const ck = `${uid}\0${cid}`;
      if (cls === 'activity') {
        const last = lastSent.get(ck);
        if (last !== undefined && t - last < o.cooldownMs) continue;
      }
      if (capLeft(uid, devs.map((x) => x[1]), t) <= 0) continue;
      const ok = devs.filter(([, e]) => {
        const l = levelOf(e, cid);
        if (cls === 'activity' ? l !== 'all' : l === 'off') return false;
        return !quietNow(e, t);
      });
      if (!ok.length) continue;
      for (const [token, entry] of ok) d.deliver(token, entry, cid, contentFor(entry, cid, kind, vars));
      if (cls === 'activity') lastSent.set(ck, t);
      countSent(uid, devs.map((x) => x[1]), t);
      n++;
    }
    return n;
  }

  function contentFor(entry, cid, kind, vars) {
    const e2ee = d.e2ee?.(cid) === true;
    const title = e2ee ? 'Lares' : (entry.circles?.[cid]?.name || 'Lares');
    const payloadKind = kind === 'arrive' ? 'active' : kind === 'study' ? 'focus' : kind;
    return { kind: payloadKind, title, body: pushText(kind, entry.lang, vars, e2ee), collapseId: kind === 'weekly' ? `w-${cid}` : cid };
  }

  // ── 钩子(index.js 调)──
  /// 有人(一台设备首次)进房之后调用 —— 此时他已在 roomUsers 里
  function onJoin(cid, uid, name) {
    try {
      if (!isHumanId(uid)) return;
      const cfg = cfgOf(cid);
      const humans = humansIn(cid).length;
      if (humans === 1) {
        if (cfg.triggers.focus && featureOn(cid, 'focus') && d.purposeOf?.(cid) === 'study') fanout(cid, uid, 'activity', 'study', { who: name });
        else if (cfg.triggers.arrive) fanout(cid, uid, 'activity', 'arrive', { who: name });
      }
      if (cfg.triggers.crowd && humans >= cfg.crowdN && !crowdFired.has(cid)) {
        crowdFired.add(cid);
        fanout(cid, uid, 'activity', 'crowd', { n: humans });
      }
    } catch (e) { log.error?.('[push-trig] onJoin 出错:', e); }
  }

  /// 某人所有设备都出房之后调用
  function onLeave(cid, uid) {
    if (!isHumanId(uid)) return;
    lastLeft.set(`${cid}\0${uid}`, now());
    if (humansIn(cid).length === 0) crowdFired.delete(cid); // 房间会话结束
  }

  /// 番茄钟开始(focus 引擎 notice kind=started)
  function onFocusStart(cid, uid, name) {
    try {
      if (uid && !isHumanId(uid)) return;
      if (!cfgOf(cid).triggers.focus || !featureOn(cid, 'focus')) return;
      fanout(cid, uid ?? null, 'activity', 'focus', { who: name });
    } catch (e) { log.error?.('[push-trig] onFocusStart 出错:', e); }
  }

  /// 圈主「叫大家来」。返回 {ok:true, sent, nextAt} | {ok:false, reason:'cooldown', retryAt}
  function summon(cid, uid, name) {
    const t = now();
    const last = summonAt.get(cid);
    if (last !== undefined && t - last < o.summonMs) return { ok: false, reason: 'cooldown', retryAt: last + o.summonMs };
    summonAt.set(cid, t);
    const sent = fanout(cid, uid, 'called', 'summon', { who: name });
    return { ok: true, sent, nextAt: t + o.summonMs };
  }
  const summonReadyAt = (cid) => { const l = summonAt.get(cid); return l === undefined || now() - l >= o.summonMs ? 0 : l + o.summonMs; };

  /// 「去找 ta」(reach)是否还能推给这台设备:等级不是 off
  const allowsCalled = (entry, cid) => levelOf(entry, cid) !== 'off';

  /**
   * 给某人推一条非活动类通知(周报)。不受冷却 / 在房 / 每日上限约束,但守免打扰与 level=off。
   * @returns {'sent'|'deferred'|'skip'}  deferred = 都在免打扰里,稍后再试
   */
  function deliverToUser(uid, cid, kind, vars) {
    if (!enabled() || !isHumanId(uid)) return 'skip';
    if (kind === 'weekly' && !featureOn(cid, 'focus')) return 'skip';
    const t = now();
    const devs = Object.entries(d.subs()).filter(([, e]) => e?.userId === uid && e.circles?.[cid] && levelOf(e, cid) !== 'off');
    if (!devs.length) return 'skip';
    const ok = devs.filter(([, e]) => !quietNow(e, t));
    if (!ok.length) return 'deferred';
    for (const [token, entry] of ok) d.deliver(token, entry, cid, contentFor(entry, cid, kind, vars));
    return 'sent';
  }

  /// 某人的时区(任一设备报过的);没有则 null
  function userTz(uid) {
    for (const e of Object.values(d.subs())) if (e?.userId === uid && e.prefs?.tzKnown) return tzSpecOf(e.prefs);
    return null;
  }

  /// push_register 之后:圈主的设备报了时区 → 记成该圈的时区(周报按圈主时区排期)
  function onRegister(session, entry) {
    const spec = tzSpecOf(entry?.prefs);
    const cid = session?.authCircleId;
    if (!spec || !cid || !session.isOwner) return;
    const clean = normalizeTz(spec);
    const r = (store.circles[cid] ??= {});
    if (JSON.stringify(r.tz) === JSON.stringify(clean)) return;
    r.tz = clean;
    save();
  }

  function setCfg(cid, cfg) {
    const r = (store.circles[cid] ??= {});
    r.cfg = { triggers: { ...cfg.triggers }, crowdN: cfg.crowdN };
    save();
  }

  function view(cid) {
    const c = cfgOf(cid);
    return {
      t: 'push_cfg', circleId: cid,
      cfg: { triggers: c.triggers, crowdN: c.crowdN }, custom: c.custom,
      defaults: defaultsOf(cid), summonReadyAt: summonReadyAt(cid), now: now(),
      limits: { cooldownMin: Math.round(o.cooldownMs / 60_000), dailyCap: o.dailyCap, summonMin: Math.round(o.summonMs / 60_000) },
    };
  }

  // ── 信令 ──
  // push_cfg_get {circleId} → push_cfg
  // push_cfg_set {circleId, ownerKey, cfg:{triggers?, crowdN?} | null(恢复用途默认)} → owner_ok + 广播 push_cfg
  // push_summon {circleId, ownerKey} → push_summon_ok {circleId, sent, nextAt} | owner_error reason cooldown(retryAt)
  async function handle(ws, session, msg) {
    const op = msg?.t;
    if (op !== 'push_cfg_get' && op !== 'push_cfg_set' && op !== 'push_summon') return false;
    const cid = typeof msg.circleId === 'string' ? msg.circleId : '';
    const ownerFail = (reason, extra = {}) => { d.send(ws, { t: 'owner_error', op, circleId: cid, reason, ...extra }); return true; };
    if (!session.userId || !session.authed) return ownerFail('say_hello_first');
    if (!cid) return ownerFail('bad_request');
    if (op === 'push_cfg_get') {
      if (!d.circleAllowed(session, cid)) return ownerFail('auth_scope');
      d.send(ws, view(cid));
      return true;
    }
    if (d.registeredCircle && !d.registeredCircle(cid)) return ownerFail('not_registered');
    if (!d.isOwnerFor(session, cid, msg.ownerKey)) return ownerFail('not_owner');
    if (op === 'push_cfg_set') {
      if (msg.cfg === null) {
        if (rec(cid)) { delete rec(cid).cfg; save(); }
      } else {
        const r = normalizeCircleCfg(msg.cfg, cfgOf(cid));
        if (!r.ok) return ownerFail('bad_config', { detail: r.detail });
        setCfg(cid, r.cfg);
      }
      d.send(ws, { t: 'owner_ok', op, circleId: cid });
      d.broadcast?.(cid, view(cid));
      return true;
    }
    // push_summon:必须人在房里
    if (session.circleId !== cid) return ownerFail('not_in_room');
    const r = summon(cid, session.userId, session.name);
    if (!r.ok) return ownerFail('cooldown', { retryAt: r.retryAt });
    d.send(ws, { t: 'push_summon_ok', circleId: cid, sent: r.sent, nextAt: r.nextAt });
    d.broadcast?.(cid, view(cid)); // 别的圈主设备也看到冷却
    return true;
  }

  function dropCircle(cid) {
    crowdFired.delete(cid);
    summonAt.delete(cid);
    for (const k of lastSent.keys()) if (k.endsWith(`\0${cid}`)) lastSent.delete(k);
    for (const k of lastLeft.keys()) if (k.startsWith(`${cid}\0`)) lastLeft.delete(k);
    if (store.circles[cid]) { delete store.circles[cid]; save(); }
  }

  /// 周期清理过期的冷却记录
  function sweep() {
    const t = now();
    for (const [k, v] of lastSent) if (t - v >= o.cooldownMs) lastSent.delete(k);
    for (const [k, v] of lastLeft) if (t - v >= o.recentMs) lastLeft.delete(k);
    for (const [k, v] of summonAt) if (t - v >= o.summonMs) summonAt.delete(k);
  }

  return {
    onJoin, onLeave, onFocusStart, summon, summonReadyAt, allowsCalled, deliverToUser, onRegister,
    cfgOf, setCfg, circleTz, userTz, levelOf, handle, dropCircle, sweep, flushSync, view,
    _debug: { lastSent, daily, lastLeft, crowdFired, summonAt },
  };
}
