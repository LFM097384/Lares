// 专注学习(lares.focus)验证。契约:docs/plans/plugin-focus-contract.md §6。
//
// 前半:计时引擎单元测试(假时钟,直接 import src/focus.js —— 纯逻辑,无网络)。
// 后半:真实服务端进程集成测试(只看线上收发与磁盘)。
// 用法:node test/focus.mjs     (DEBUG=1 显示服务端 stderr)

import { randomBytes } from 'node:crypto';
import { mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  wait, makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v2Auth, ownerReply,
} from './lib/harness.mjs';
import { createFocusEngine, FOCUS_DEFAULTS, normalizeFocusConfig } from '../src/focus.js';

const PORT = 18987;
const GLOBAL_PASS = 'focus-global-' + randomBytes(4).toString('hex');
const PASSCODE = 'focus-pass-' + randomBytes(4).toString('hex');
const T = makeChecker();
const { check } = T;
const S = 1000;
const MIN = 60 * S;

function fakeEngine({ dataDir = null, config = {}, start = Date.UTC(2026, 8, 15, 4, 0, 0), tz = 480 } = {}) {
  const clock = { t: start };
  const events = [];
  const plugin = { installed: true, enabled: true, config: { ...FOCUS_DEFAULTS, ...config } };
  const e = createFocusEngine({
    dataDir,
    now: () => clock.t,
    tzOffsetMin: tz,
    setTimer: null,
    pluginOf: () => plugin,
    out: (cid, ev) => events.push(ev),
    log: { error: () => {} },
  });
  const notices = () => events.filter((x) => x.type === 'notice').map((x) => x.notice);
  const adv = (ms) => { clock.t += ms; };
  const mem = (cid, uid) => e.status(cid).members.find((m) => m.userId === uid);
  return { e, clock, adv, events, notices, mem, plugin };
}

async function unitTests() {
  const C = 'c_test';

  console.log('\n[配置]');
  check(normalizeFocusConfig({}).config?.focusMin === 25, '缺省补默认');
  check(!normalizeFocusConfig({ focusMin: 181 }).ok && !normalizeFocusConfig({ rounds: 1.5 }).ok, '越界 / 非整数 -> 拒');
  check(!normalizeFocusConfig({ evil: 1 }).ok && !normalizeFocusConfig({ membersCanStart: 'yes' }).ok, '未知字段 / 类型错 -> 拒');
  {
    // 废弃字段 chatInBreak:老客户端 / 老存档还会带,收下即丢(不论取值)
    const legacy = normalizeFocusConfig({ focusMin: 30, chatInBreak: false });
    const legacyOdd = normalizeFocusConfig({ chatInBreak: 'yes' });
    check(legacy.ok && legacy.config.focusMin === 30 && !('chatInBreak' in legacy.config)
      && legacyOdd.ok && !('chatInBreak' in legacyOdd.config), '旧字段 chatInBreak -> 容忍并丢弃');
  }

  console.log('\n[离开 / 回来计时]');
  {
    const { e, adv, mem, notices } = fakeEngine();
    e.join(C, 'u1', 'd1', 'Alice');
    e.start(C, 'owner');
    adv(60 * S);
    check(mem(C, 'u1').focusMs === 60 * S && mem(C, 'u1').state === 'focus', '专注 60 s');
    const t = e.status(C).now;
    e.away(C, 'u1', 'd1', t - 20 * S); // 客户端宽限后才报,since 回溯 20 s
    let m = mem(C, 'u1');
    check(m.state === 'away' && m.focusMs === 40 * S && m.awayMs === 20 * S && m.awaySince === t - 20 * S, 'since 回溯:20 s 从专注改记离开', m);
    check(notices().some((n) => n.kind === 'away' && n.userId === 'u1'), 'away 提示');
    adv(30 * S);
    e.back(C, 'u1', 'd1');
    m = mem(C, 'u1');
    check(m.state === 'focus' && m.awayMs === 50 * S && m.focusMs === 40 * S, '回来:离开共 50 s', m);
    const back = notices().find((n) => n.kind === 'back');
    check(back?.awayMs === 50 * S, 'back 提示带 awayMs', back);
    adv(10 * S);
    check(mem(C, 'u1').focusMs === 50 * S, '回来后继续计专注');
    // since 不早于上次回来
    e.away(C, 'u1', 'd1', e.status(C).now - 60 * S);
    m = mem(C, 'u1');
    check(m.awaySince === e.status(C).now - 10 * S && m.focusMs === 40 * S, 'since 不早于上次回来', m);
    e.back(C, 'u1', 'd1');
    check(e.board(C).all[0]?.ms === 40 * S, '排行榜只计专注(不含离开)', e.board(C).all);
  }

  console.log('\n[since 夹取]');
  {
    const { e, adv, mem } = fakeEngine();
    e.join(C, 'u1', 'd1', 'Alice');
    e.start(C, 'owner');
    adv(15 * MIN);
    const now = e.status(C).now;
    e.away(C, 'u1', 'd1', now - 15 * MIN);
    check(mem(C, 'u1').awaySince === now - 10 * MIN && mem(C, 'u1').awayMs === 10 * MIN, 'since 最多回溯 10 分钟');
    e.back(C, 'u1', 'd1');
    e.away(C, 'u1', 'd1', now + 5 * MIN);
    check(mem(C, 'u1').awaySince === now, '未来的 since 夹到 now');
    e.back(C, 'u1', 'd1');
    e.join(C, 'u2', 'd2', 'Bob');
    adv(5 * S);
    const n2 = e.status(C).now;
    e.away(C, 'u2', 'd2', n2 - 5 * MIN);
    check(mem(C, 'u2').awaySince === n2 - 5 * S, 'since 不早于本次进房');
    e.away(C, 'u1', 'd1', 'garbage');
    check(mem(C, 'u1').awaySince === n2, '非数字 since 当作 now');
  }

  console.log('\n[多设备]');
  {
    const { e, adv, mem, notices } = fakeEngine();
    e.join(C, 'u1', 'phone', 'Alice');
    e.join(C, 'u1', 'pc', 'Alice');
    e.start(C, 'owner');
    adv(10 * S);
    e.away(C, 'u1', 'phone', e.status(C).now);
    adv(10 * S);
    check(mem(C, 'u1').state === 'focus' && mem(C, 'u1').focusMs === 20 * S, '一台设备离开 ≠ 离开');
    e.away(C, 'u1', 'pc', e.status(C).now - 3 * S);
    check(mem(C, 'u1').state === 'away' && mem(C, 'u1').awaySince === e.status(C).now - 3 * S, '所有设备都离开才算离开(since 取最后一台)');
    e.back(C, 'u1', 'phone');
    check(mem(C, 'u1').state === 'focus', '任一设备回来即回来');
    e.away(C, 'u1', 'phone');
    check(mem(C, 'u1').state === 'away', '再次全部离开');
    e.leave(C, 'u1', 'pc');
    check(mem(C, 'u1').state === 'away' && !notices().some((n) => n.kind === 'left_early'), '一台出房:不算出房,剩下的设备仍 away');
    e.leave(C, 'u1', 'phone');
    check(!mem(C, 'u1') && notices().some((n) => n.kind === 'left_early' && n.userId === 'u1'), '最后一台出房(专注期)-> left_early');
    check(!e.away(C, 'u9', 'x'), '不在房的会话报离开被忽略');
  }

  console.log('\n[番茄钟]');
  {
    const { e, adv, mem, notices, events } = fakeEngine({ config: { focusMin: 1, breakMin: 1, rounds: 2 } });
    e.join(C, 'u1', 'd1', 'Alice');
    e.start(C, 'owner');
    let p = e.status(C).pomodoro;
    check(p.phase === 'focus' && p.round === 1 && p.rounds === 2 && p.endsAt === e.status(C).now + MIN && p.startedBy === 'owner', 'start -> focus 第 1 轮', p);
    check(notices().some((n) => n.kind === 'started') && events.some((x) => x.type === 'pomodoro'), 'started 提示 + 写共享状态');
    adv(MIN); e.tick();
    p = e.status(C).pomodoro;
    check(p.phase === 'break' && p.round === 1 && mem(C, 'u1').state === 'break', '到点 -> break', p);
    check(notices().some((n) => n.kind === 'phase' && n.phase === 'break'), 'phase(break)提示');
    e.away(C, 'u1', 'd1');
    const nAway = notices().filter((n) => n.kind === 'away').length;
    adv(30 * S);
    e.back(C, 'u1', 'd1');
    check(mem(C, 'u1').focusMs === MIN && mem(C, 'u1').awayMs === 0, '休息不计时(专注 / 离开都不涨)', mem(C, 'u1'));
    check(nAway === 0 && !notices().some((n) => n.kind === 'back'), '休息中离开 / 回来不广播');
    adv(30 * S); e.tick();
    p = e.status(C).pomodoro;
    check(p.phase === 'focus' && p.round === 2, '休息结束 -> focus 第 2 轮', p);
    adv(MIN); e.tick();
    p = e.status(C).pomodoro;
    check(p.phase === 'idle' && notices().filter((n) => n.kind === 'stopped').length === 1, '最后一轮结束 -> idle + stopped', p);
    check(mem(C, 'u1').focusMs === 2 * MIN, '两轮共专注 2 分钟');
    adv(10 * S);
    check(mem(C, 'u1').focusMs === 2 * MIN && mem(C, 'u1').state === 'idle', '没开番茄钟时不计时(idle)', mem(C, 'u1'));
    e.away(C, 'u1', 'd1'); adv(5 * S); e.back(C, 'u1', 'd1');
    check(mem(C, 'u1').awayMs === 0 && !notices().some((n) => n.kind === 'back'), 'idle 时离开 / 回来不记、不广播');
    // 迟到的 tick:读状态时先推进阶段
    e.start(C, 'owner');
    adv(MIN + MIN + 10 * S); // focus 1 分 + break 1 分 + 进第 2 轮 10 s,中间没 tick
    const m = mem(C, 'u1');
    check(m.focusMs === 2 * MIN + MIN + 10 * S && e.status(C).pomodoro.round === 2, '错过 tick 也不把休息记成专注', m);
    e.stop(C, 'owner');
    check(e.status(C).pomodoro.phase === 'idle' && notices().filter((n) => n.kind === 'stopped').length === 2, 'stop -> idle');
  }

  console.log('\n[圈主停用]');
  {
    const { e, adv, mem, notices, plugin } = fakeEngine();
    e.join(C, 'u1', 'd1', 'Alice');
    e.start(C, 'owner');
    adv(10 * S);
    plugin.enabled = false;
    e.setPlugin(C, { installed: true, enabled: false, config: plugin.config });
    check(notices().some((n) => n.kind === 'ended_by_owner') && e.status(C).enabled === false && e.status(C).pomodoro.phase === 'idle', 'ended_by_owner + 番茄钟清零');
    adv(10 * S);
    check(mem(C, 'u1').focusMs === 10 * S, '停用后不计时');
    e.leave(C, 'u1', 'd1');
    check(!notices().some((n) => n.kind === 'left_early'), '停用后出房不算 left_early');
  }

  console.log('\n[排行榜日界 / 周界]');
  {
    // 2026-09-15 是周二;UTC 15:59:30 = UTC+8 的 23:59:30
    const { e, adv } = fakeEngine({ start: Date.UTC(2026, 8, 15, 15, 59, 30) });
    e.join(C, 'u1', 'd1', 'Alice');
    e.start(C, 'owner');
    adv(60 * S);
    const b = e.board(C);
    check(b.today[0]?.ms === 30 * S && b.week[0]?.ms === 60 * S && b.all[0]?.ms === 60 * S && b.today[0].name === 'Alice', '跨本地午夜:today 30 s / week 60 s / all 60 s', b);
  }
  {
    // 2026-09-20 是周日;跨到周一 → 新的一周
    const { e, adv } = fakeEngine({ start: Date.UTC(2026, 8, 20, 15, 59, 30) });
    e.join(C, 'u1', 'd1', 'Alice');
    e.start(C, 'owner');
    adv(60 * S);
    const b = e.board(C);
    check(b.week[0]?.ms === 30 * S && b.all[0]?.ms === 60 * S, '周一 00:00 换周', b.week);
  }
  {
    // 时区偏移 0:同一时刻不跨日
    const { e, adv } = fakeEngine({ start: Date.UTC(2026, 8, 15, 15, 59, 30), tz: 0 });
    e.join(C, 'u1', 'd1', 'Alice');
    e.start(C, 'owner');
    adv(60 * S);
    check(e.board(C).today[0]?.ms === 60 * S, 'LARES_FOCUS_TZ_OFFSET_MIN=0 时不跨日');
  }
  {
    const { e, adv } = fakeEngine();
    e.join(C, 'u1', 'd1', 'Alice'); e.join(C, 'u2', 'd2', 'Bob');
    e.start(C, 'owner');
    adv(10 * S); e.leave(C, 'u1', 'd1'); adv(10 * S);
    const b = e.board(C);
    check(b.today[0]?.userId === 'u2' && b.today[0].ms === 20 * S && b.today[1]?.ms === 10 * S, '降序', b.today);
  }

  console.log('\n[持久化]');
  {
    const dir = mkdtempSync(path.join(tmpdir(), 'lares-focus-unit-'));
    const start = Date.UTC(2026, 8, 15, 4, 0, 0);
    const a = fakeEngine({ dataDir: dir, start });
    a.e.join(C, 'u1', 'd1', 'Alice');
    a.e.start(C, 'owner');
    a.adv(90 * S);
    await a.e.flushAll();
    check(existsSync(path.join(dir, 'focus', `${C}.json`)), '写到 DATA_DIR/focus/<circleId>.json');
    const b = fakeEngine({ dataDir: dir, start: start + 90 * S });
    const bd = b.e.board(C);
    check(bd.all[0]?.ms === 90 * S && bd.all[0].name === 'Alice' && bd.today[0]?.ms === 90 * S, '新引擎读回排行榜', bd);
    // 60 天外的日子被剪掉,总榜保留
    const c = fakeEngine({ dataDir: dir, start: start + 61 * 86_400_000 });
    c.e.join(C, 'u2', 'd2', 'Bob'); c.e.start(C, 'owner'); c.adv(S);
    await c.e.flushAll();
    const d = fakeEngine({ dataDir: dir, start: start + 61 * 86_400_000 + S });
    const dd = d.e.board(C);
    check(dd.all.length === 2 && dd.today.length === 1 && dd.week.length === 1, '60 天外 days 剪掉,totals 保留', dd);
    d.e.flushSync();
    d.e.deleteCircle(C);
    check(!existsSync(path.join(dir, 'focus', `${C}.json`)), 'deleteCircle 删文件');
  }
}

async function integration() {
  console.log('\n[集成:真实服务端]');
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-focus-'));
  let srv = boot(PORT, dataDir, GLOBAL_PASS, { LARES_FOCUS_FLUSH_MS: '500' });
  const clients = [];
  const BASE = `http://127.0.0.1:${PORT}`;
  const api = (token, p) => fetch(BASE + p, { headers: { authorization: `Bearer ${token}` } });
  try {
    check(await waitHealth(PORT), '服务端启动');
    const { cid, verifier, ownerKey, owner } = await registerCircle(PORT, PASSCODE, 'u_owner');
    clients.push(owner);
    const A = await connect(PORT, { userId: 'u_a', name: 'Alice', auth: v2Auth(verifier, cid) });
    const B = await connect(PORT, { userId: 'u_b', name: 'Bob', auth: v2Auth(verifier, cid) });
    clients.push(A, B);

    const pong = await A.req({ t: 'ping' }, (m) => m.t === 'pong');
    check(typeof pong?.now === 'number' && Math.abs(pong.now - Date.now()) < 5000, 'pong 带服务器时间 now', pong);

    const ferr = (m) => m.t === 'focus_error';
    let r = await A.req({ t: 'focus_away', circleId: cid, since: Date.now() }, ferr);
    check(r?.reason === 'not_in_room', '没进房 focus_away -> not_in_room', r);
    await join(A, cid); await join(B, cid);
    r = await A.req({ t: 'focus_away', circleId: cid }, ferr);
    check(r?.reason === 'disabled', '没装插件 -> disabled', r);

    const inst = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.focus' }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    check(inst?.t === 'plugin_installed', '圈主装 lares.focus', inst);
    const st0 = await A.waitFor((m) => m.t === 'focus_status' && m.enabled === true);
    check(st0?.members?.length === 2 && st0.pomodoro.phase === 'idle' && st0.config.focusMin === 25, '装上后在房成员收到 focus_status', st0);

    owner.send({ t: 'focus_start', circleId: cid, ownerKey });
    check(Boolean(await A.waitFor((m) => m.t === 'focus_notice' && m.kind === 'started')), '圈主(大厅)开番茄钟');
    await wait(1200);
    A.drain(() => true); B.drain(() => true);
    // A 冒充 B 报离开:只记到 A 自己头上
    A.send({ t: 'focus_away', circleId: cid, userId: 'u_b', since: Date.now() - 500 });
    const nA = await B.waitFor((m) => m.t === 'focus_notice' && m.kind === 'away');
    check(nA?.userId === 'u_a' && nA.name === 'Alice', '离开归属会话(冒充 userId 无效)', nA);
    const stA = await B.waitFor((m) => m.t === 'focus_status' && m.members.some((x) => x.userId === 'u_a' && x.state === 'away'));
    const bRow = stA?.members.find((x) => x.userId === 'u_b');
    check(bRow?.state === 'focus' && stA.members.find((x) => x.userId === 'u_a').awayMs >= 400, 'B 仍在专注,A 离开计时', stA?.members);
    await wait(300);
    A.send({ t: 'focus_back', circleId: cid, userId: 'u_b' });
    const back = await B.waitFor((m) => m.t === 'focus_notice' && m.kind === 'back');
    check(back?.userId === 'u_a' && back.awayMs >= 700, 'back 带 awayMs', back);

    r = await A.req({ t: 'focus_start', circleId: cid }, ferr);
    check(r?.reason === 'forbidden', '成员开番茄钟(membersCanStart=false)-> forbidden', r);
    r = await A.req({ t: 'focus_start', circleId: cid, ownerKey: 'nope' }, ferr);
    check(r?.reason === 'forbidden', '假 ownerKey -> forbidden', r);
    await owner.req({ t: 'plugin_config_set', circleId: cid, ownerKey, pluginId: 'lares.focus', config: { membersCanStart: true, focusMin: 1, breakMin: 1, rounds: 2 } }, ownerReply('plugin_config_set'));
    A.drain(() => true); B.drain(() => true);
    A.send({ t: 'focus_start', circleId: cid });
    const started = await B.waitFor((m) => m.t === 'focus_notice' && m.kind === 'started');
    check(started?.userId === 'u_a' && started.round === 1, 'membersCanStart 后成员可开', started);
    const ps = await B.waitFor((m) => m.t === 'plugin_state' && m.pluginId === 'lares.focus');
    check(ps?.state?.pomodoro?.phase === 'focus' && ps.rev >= 1, '番茄钟写入 lares.focus 共享状态', ps);

    owner.drain(() => true);
    owner.send({ t: 'focus_get', circleId: cid });
    const g1 = await owner.waitFor((m) => m.t === 'focus_status');
    const g2 = await owner.waitFor((m) => m.t === 'focus_board');
    check(g1?.pomodoro?.phase === 'focus' && Array.isArray(g2?.today), '圈主(大厅)focus_get -> status + board', g2);

    // REST
    const bt = await owner.req({ t: 'bot_token_create', circleId: cid, ownerKey, name: 'Stats' }, (m) => m.t === 'bot_token' || m.t === 'owner_error');
    let res = await api(bt.token, '/api/v1/focus');
    let body = await res.json();
    check(res.status === 200 && body.installed === true && body.enabled === true && body.pomodoro.phase === 'focus' && body.members.length === 2 && Array.isArray(body.leaderboard?.all), 'GET /api/v1/focus(机器人 token)', body);

    // 圈主停用
    A.drain(() => true);
    await owner.req({ t: 'plugin_set_enabled', circleId: cid, ownerKey, pluginId: 'lares.focus', enabled: false }, ownerReply('plugin_set_enabled'));
    const ended = await A.waitFor((m) => m.t === 'focus_notice' && m.kind === 'ended_by_owner');
    const stOff = await A.waitFor((m) => m.t === 'focus_status' && m.enabled === false);
    check(Boolean(ended) && stOff?.pomodoro?.phase === 'idle', '圈主停用 -> ended_by_owner + focus_status{enabled:false}', stOff);
    res = await api(bt.token, '/api/v1/focus');
    body = await res.json();
    check(body.installed === true && body.enabled === false, 'REST 反映停用');
    await owner.req({ t: 'plugin_set_enabled', circleId: cid, ownerKey, pluginId: 'lares.focus', enabled: true }, ownerReply('plugin_set_enabled'));

    // 专注期出房 → left_early(重新启用后番茄钟是 idle,先开钟)
    owner.send({ t: 'focus_start', circleId: cid, ownerKey });
    await A.waitFor((m) => m.t === 'focus_notice' && m.kind === 'started');
    B.drain(() => true);
    await wait(500);
    A.send({ t: 'leave', circleId: cid });
    const le = await B.waitFor((m) => m.t === 'focus_notice' && m.kind === 'left_early');
    check(le?.userId === 'u_a', '专注期出房 -> left_early', le);

    // 限速
    let limited = false;
    for (let i = 0; i < 40; i++) B.send({ t: 'focus_get', circleId: cid });
    limited = Boolean(await B.waitFor((m) => m.t === 'focus_error' && m.reason === 'rate_limited', 2000));
    check(limited, 'focus_* 每连接限速');

    // 重启后排行榜还在
    B.send({ t: 'leave', circleId: cid });
    await wait(800);
    res = await api(bt.token, '/api/v1/focus');
    const beforeAll = (await res.json()).leaderboard.all;
    await stop(srv);
    srv = boot(PORT, dataDir, GLOBAL_PASS, {});
    check(await waitHealth(PORT), '重启');
    res = await api(bt.token, '/api/v1/focus');
    body = await res.json();
    const afterAll = body.leaderboard?.all ?? [];
    check(afterAll.length === 2 && afterAll.every((x) => x.ms > 0) && JSON.stringify(afterAll) === JSON.stringify(beforeAll), '重启后排行榜持久', { beforeAll, afterAll });

    // 解散删文件
    const owner2 = await connect(PORT, { userId: 'u_owner', auth: v2Auth(verifier, cid, { ownerKey }) });
    clients.push(owner2);
    const file = path.join(dataDir, 'focus', `${encodeURIComponent(cid)}.json`);
    check(existsSync(file), '排行榜文件存在');
    await owner2.req({ t: 'circle_delete', circleId: cid, ownerKey }, ownerReply('circle_delete'));
    await wait(200);
    check(!existsSync(file), '解散删排行榜文件');
  } finally {
    for (const c of clients) await c.close?.().catch?.(() => {});
    await stop(srv);
    if (T.fail && !process.env.DEBUG) console.log(srv.out.slice(-3000));
  }
}

await unitTests();
await integration();
console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
process.exit(T.fail === 0 ? 0 : 1);
