// 活动推送触发器 + 专注社交(出勤 / 连续打卡 / 周报)。
//
// 前半:单元测试,直接 import src/push_triggers.js / focus_social.js / focus.js(纯逻辑,假时钟 + 假投递)。
// 后半:端到端 —— 真服务端进程 + 本地假 APNs(HTTP/2 + TLS),两个成员,一人开番茄钟,另一人收到推送
//       (带正确的一键进圈信息),第二次开钟被冷却挡住;圈主「叫大家来」+ 10 分钟限流。
//
// 用法:node test/push_triggers.mjs    (DEBUG=1 显示服务端 stderr)

import http2 from 'node:http2';
import crypto from 'node:crypto';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { wait, makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v2Auth, ownerReply } from './lib/harness.mjs';
import { createPushTriggers, pushText, parseSubPrefs, normalizeCircleCfg, defaultCircleCfg } from '../src/push_triggers.js';
import { createFocusSocial, attendance, bumpStreak, currentStreak, weeklySummary } from '../src/focus_social.js';
import { createFocusEngine } from '../src/focus.js';
import { localParts, inWindow } from '../src/tz.js';

const st = makeChecker();
const check = st.check;
const HERE = path.dirname(fileURLToPath(import.meta.url));
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
// 2026-11-02 是周一。UTC 02:00 = 北京 10:00
const MON = Date.UTC(2026, 10, 2, 2, 0, 0);

// ── 假环境 ──
function world({ purpose = null, e2ee = false, opts = {}, features = null } = {}) {
  const w = { t: MON, subs: {}, room: new Map(), sent: [], purpose, e2ee, features };
  w.now = () => w.t;
  w.pt = createPushTriggers({
    now: w.now,
    subs: () => w.subs,
    roomUsers: (cid) => [...(w.room.get(cid) ?? [])],
    purposeOf: () => w.purpose,
    featureOn: (cid, k) => (w.features ? w.features[k] !== false : true),
    e2ee: () => w.e2ee,
    deliver: (token, entry, cid, content) => w.sent.push({ token, uid: entry.userId, cid, ...content }),
    send: (ws, m) => ws.inbox.push(m),
    broadcast: () => {},
    isOwnerFor: (s) => s.isOwner === true,
    circleAllowed: () => true,
    log: { error: () => {} },
    opts,
  });
  w.sub = (uid, cid, { level = 'all', lang = 'zh', prefs = { tzOffsetMin: 480 }, name = 'Home' } = {}) => {
    const token = `${uid}-tok-${Object.keys(w.subs).length}`;
    w.subs[token] = { userId: uid, deviceId: 'd-' + uid, env: 'sandbox', lang, circles: { [cid]: { name, muted: level === 'off', level } }, prefs: parseSubPrefs(prefs) };
    return token;
  };
  w.enter = (cid, uid, name = uid) => {
    if (!w.room.has(cid)) w.room.set(cid, new Set());
    w.room.get(cid).add(uid);
    w.pt.onJoin(cid, uid, name);
  };
  w.exit = (cid, uid) => { w.room.get(cid)?.delete(uid); w.pt.onLeave(cid, uid); };
  w.take = () => w.sent.splice(0);
  w.adv = (ms) => { w.t += ms; };
  return w;
}

function unitTriggers() {
  console.log('\n[触发器:focus]');
  {
    const w = world();
    w.sub('u_lu', 'c1');
    w.sub('u_owner', 'c1');
    w.enter('c1', 'u_owner', '阿蛮');
    check(w.take().length === 0, '无用途圈:第一个人进房默认不推(arrive 默认关)');
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    const s = w.take();
    check(s.length === 1 && s[0].uid === 'u_lu' && s[0].kind === 'focus' && s[0].body === '阿蛮开始专注了,一起学?', '番茄钟开始 → 推给不在房的成员「阿蛮开始专注了,一起学?」', s);
    check(s[0]?.title === 'Home' && s[0]?.collapseId === 'c1', '标题 = 圈名,collapseId = circleId', s[0]);
    w.adv(10 * MIN);
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    check(w.take().length === 0, '30 分钟冷却内再开钟:不推');
    w.adv(21 * MIN);
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    check(w.take().length === 1, '冷却过后:再推');
  }
  {
    const w = world({ purpose: 'study' });
    w.sub('u_lu', 'c1');
    w.enter('c1', 'u_owner', '阿蛮');
    const s = w.take();
    check(s.length === 1 && s[0].kind === 'focus' && s[0].body === '阿蛮来自习了,一起学?', '学习圈:第一个人进房也推(focus 触发器)', s);
    w.enter('c1', 'u_b', '小B');
    check(w.take().length === 0, '学习圈默认不开 crowd:第 2 人进房不推');
  }

  console.log('\n[触发器:功能开关 focus 关]');
  {
    const w = world({ purpose: 'study', features: { focus: false } });
    w.sub('u_lu', 'c1');
    w.enter('c1', 'u_owner', '阿蛮');
    check(w.take().length === 0, 'focus 功能关:学习圈来人不推「来自习」');
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    check(w.take().length === 0, 'focus 功能关:开番茄钟不推');
    check(w.pt.deliverToUser('u_lu', 'c1', 'weekly', { focusMs: 1, circleTotalMs: 1 }) === 'skip', 'focus 功能关:周报不推');
    w.features = { focus: true };
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    check(w.take().length === 1, 'focus 功能开回来:开钟推送恢复');
  }

  console.log('\n[触发器:crowd(满 N 人)]');
  {
    const w = world({ purpose: 'chat' });
    w.sub('u_lu', 'c1', { lang: 'en' });
    w.enter('c1', 'u_a', 'A');
    w.enter('c1', 'u_ai_helper', 'AI');
    w.enter('c1', 'bot:rec', 'bot');
    w.enter('c1', 'u_b', 'B');
    check(w.take().length === 0, '闲聊圈默认 N=3;2 真人 + AI + bot 不触发(AI 不算人)');
    w.enter('c1', 'u_c', 'C');
    const s = w.take();
    check(s.length === 1 && s[0].kind === 'crowd' && s[0].body === '3 people are already hanging out in the circle', '第 3 个真人进房 → crowd(英文文案)', s);
    w.adv(40 * MIN);
    w.exit('c1', 'u_c');
    w.enter('c1', 'u_c', 'C');
    check(w.take().length === 0, '同一房间会话只推一次(掉回 2 人再回到 3 人不再推)');
    for (const u of ['u_a', 'u_b', 'u_c', 'u_ai_helper', 'bot:rec']) w.exit('c1', u);
    w.adv(40 * MIN);
    for (const u of ['u_a', 'u_b', 'u_c']) w.enter('c1', u, u);
    check(w.take().length === 1, '房间清空后新会话:再次满 3 人 → 推');
    // 圈主改 N=2
    const ws = { inbox: [] };
    for (const u of ['u_a', 'u_b', 'u_c']) w.exit('c1', u);
    w.pt.handle(ws, { userId: 'u_a', authed: true, isOwner: true }, { t: 'push_cfg_set', circleId: 'c1', cfg: { crowdN: 2 } });
    check(ws.inbox[0]?.t === 'owner_ok' && w.pt.cfgOf('c1').crowdN === 2, '圈主 push_cfg_set crowdN=2', ws.inbox);
    w.adv(40 * MIN);
    w.enter('c1', 'u_a', 'A'); w.enter('c1', 'u_b', 'B');
    check(w.take()[0]?.body === '2 people are already hanging out in the circle', 'N=2 生效', null);
  }

  console.log('\n[触发器:arrive / 圈主配置]');
  {
    const w = world();
    const ws = { inbox: [] };
    const owner = { userId: 'u_o', authed: true, isOwner: true };
    w.pt.handle(ws, owner, { t: 'push_cfg_set', circleId: 'c1', cfg: { triggers: { arrive: true, focus: false } } });
    check(ws.inbox.pop()?.t === 'owner_ok', '圈主开 arrive、关 focus', null);
    w.pt.handle(ws, owner, { t: 'push_cfg_set', circleId: 'c1', cfg: { triggers: { nope: true } } });
    check(ws.inbox.pop()?.reason === 'bad_config', '未知触发器 → bad_config', null);
    w.pt.handle(ws, owner, { t: 'push_cfg_set', circleId: 'c1', cfg: { crowdN: 1 } });
    check(ws.inbox.pop()?.reason === 'bad_config', 'crowdN 越界 → bad_config', null);
    w.pt.handle(ws, { userId: 'u_x', authed: true }, { t: 'push_cfg_set', circleId: 'c1', cfg: { crowdN: 4 } });
    check(ws.inbox.pop()?.reason === 'not_owner', '非圈主 → not_owner', null);
    w.pt.handle(ws, { userId: 'u_x', authed: true }, { t: 'push_cfg_get', circleId: 'c1' });
    const v = ws.inbox.pop();
    check(v?.t === 'push_cfg' && v.cfg.triggers.arrive === true && v.cfg.triggers.focus === false && v.custom === true, 'push_cfg_get 返回生效配置', v);
    w.sub('u_lu', 'c1');
    w.enter('c1', 'u_xiaolu', '小鹿');
    const s = w.take();
    check(s.length === 1 && s[0].kind === 'active' && s[0].body === '小鹿来了', '空房来人 → 「小鹿来了」(payload kind=active)', s);
    w.pt.onFocusStart('c1', 'u_xiaolu', '小鹿');
    check(w.take().length === 0, 'focus 被圈主关掉 → 开钟不推');
    w.pt.handle(ws, owner, { t: 'push_cfg_set', circleId: 'c1', cfg: null });
    check(w.pt.cfgOf('c1').custom === false && w.pt.cfgOf('c1').triggers.arrive === false, 'cfg:null → 恢复用途默认', w.pt.cfgOf('c1'));
    const d1 = defaultCircleCfg('study'); const d2 = defaultCircleCfg('chat'); const d3 = defaultCircleCfg(null);
    check(d1.triggers.focus && !d1.triggers.crowd && d2.triggers.crowd && !d2.triggers.focus && d3.triggers.focus && d3.triggers.crowd && !d3.triggers.arrive && d3.crowdN === 3,
      '用途预设:学习→focus,闲聊→crowd,无用途→focus+crowd;arrive 默认关;N=3', { d1, d2, d3 });
    check(!normalizeCircleCfg({ crowdN: 2.5 }, d3).ok && normalizeCircleCfg({ crowdN: 12 }, d3).ok, 'crowdN 必须是 2..12 的整数', null);
  }

  console.log('\n[防打扰:不在房 / 5 分钟内刚在房 / 等级]');
  {
    const w = world();
    w.sub('u_in', 'c1');
    w.sub('u_recent', 'c1');
    w.sub('u_called', 'c1', { level: 'called' });
    w.sub('u_off', 'c1', { level: 'off' });
    w.sub('u_ai_bot', 'c1');
    w.sub('u_ok', 'c1');
    w.enter('c1', 'u_owner', '阿蛮');
    w.enter('c1', 'u_in', 'In');
    w.enter('c1', 'u_recent', 'R');
    w.adv(MIN);
    w.exit('c1', 'u_recent');
    w.adv(3 * MIN);
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    const got = w.take().map((x) => x.uid).sort();
    check(JSON.stringify(got) === JSON.stringify(['u_ok']), '只推 u_ok:在房 / 3 分钟前刚走 / 只要被叫 / 关 / AI 都不推', got);
    // 被叫:summon 推 all + called
    const r = w.pt.summon('c1', 'u_owner', '阿蛮');
    const s2 = w.take();
    check(r.ok && s2.map((x) => x.uid).sort().join() === 'u_called,u_ok' && s2[0].body === '阿蛮 叫你来圈里' && s2[0].kind === 'summon',
      '叫大家来 → 推「全部」与「只要被叫」(不受 30 分钟冷却),不推关 / 在房 / 刚走的', s2);
    const r2 = w.pt.summon('c1', 'u_owner', '阿蛮');
    check(!r2.ok && r2.reason === 'cooldown' && r2.retryAt === w.t + 10 * MIN, '10 分钟内再叫 → cooldown(带 retryAt)', r2);
    w.adv(10 * MIN);
    check(w.pt.summon('c1', 'u_owner', '阿蛮').ok, '10 分钟后可再叫', null);
    check(w.pt.allowsCalled(w.subs[Object.keys(w.subs)[2]], 'c1') && !w.pt.allowsCalled(w.subs[Object.keys(w.subs)[3]], 'c1'), 'reach:called 可推、off 不推', null);
  }

  console.log('\n[免打扰 + 时区]');
  {
    check(inWindow(23 * 60 + 30, 1380, 480) && inWindow(7 * 60, 1380, 480) && !inWindow(8 * 60, 1380, 480) && !inWindow(22 * 60, 1380, 480), 'inWindow 跨午夜', null);
    check(localParts(Date.UTC(2026, 10, 2, 15, 30), { tz: 'Asia/Shanghai' }).minutes === 23 * 60 + 30, 'IANA 时区换算(上海 23:30)', null);
    check(localParts(Date.UTC(2026, 6, 1, 3, 0), { tz: 'America/New_York' }).minutes === 23 * 60, 'IANA 夏令时(纽约 7 月 = UTC-4)', null);
    const w = world();
    w.t = Date.UTC(2026, 10, 2, 15, 30); // 北京 23:30 / 纽约 10:30 / 伦敦 15:30
    w.sub('u_bj', 'c1', { prefs: { tzOffsetMin: 480 } });
    w.sub('u_ny', 'c1', { prefs: { tz: 'America/New_York' } });
    w.sub('u_noq', 'c1', { prefs: { tzOffsetMin: 480, quiet: null } });
    w.sub('u_custom', 'c1', { prefs: { tzOffsetMin: 0, quiet: { start: 15 * 60, end: 16 * 60 } } });
    w.sub('u_legacy', 'c1', { prefs: null });
    w.enter('c1', 'u_owner', '阿蛮');
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    const got = w.take().map((x) => x.uid).sort();
    check(JSON.stringify(got) === JSON.stringify(['u_legacy', 'u_noq', 'u_ny']),
      '北京 23:30 免打扰不推;纽约 10:30 推;关了免打扰推;自定义 15:00–16:00(UTC)不推;没报时区的老客户端不套免打扰', got);
    check(parseSubPrefs({ tzOffsetMin: 480 }).quiet.start === 1380 && parseSubPrefs({ tzOffsetMin: 480 }).quiet.end === 480, '默认免打扰 23:00–08:00', parseSubPrefs({ tzOffsetMin: 480 }));
    check(parseSubPrefs({ tz: 'Not/AZone', tzOffsetMin: 9999 }).tzKnown === false, '非法时区丢弃', null);
    // 免打扰被挡掉的不记冷却:醒来后照常能收
    w.t = Date.UTC(2026, 10, 3, 1, 0); // 北京 09:00,距上一次 9.5 小时
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    check(w.take().some((x) => x.uid === 'u_bj'), '早上 9 点(北京)→ 推给 u_bj', null);
  }

  console.log('\n[每日上限]');
  {
    const w = world({ opts: { cooldownMs: MIN } });
    w.t = Date.UTC(2026, 10, 2, 1, 0); // 北京 09:00
    w.sub('u_lu', 'c1');
    for (let i = 0; i < 10; i++) { w.pt.onFocusStart('c1', 'u_owner', '阿蛮'); w.adv(2 * MIN); }
    check(w.take().length === 8, '每人每天最多 8 条(10 次只推 8)', w.sent.length);
    w.t = Date.UTC(2026, 10, 2, 16, 1); // 北京次日 00:01(免打扰中)
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    check(w.take().length === 0, '次日凌晨在免打扰里', null);
    w.t = Date.UTC(2026, 10, 3, 0, 30); // 北京 08:30,新的一天
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    check(w.take().length === 1, '本地新的一天 → 上限重置', null);
    // 上限跨圈共享
    const w2 = world({ opts: { cooldownMs: MIN, dailyCap: 2 } });
    w2.t = Date.UTC(2026, 10, 2, 1, 0);
    const tk = w2.sub('u_lu', 'c1');
    w2.subs[tk].circles.c2 = { name: 'B', muted: false, level: 'all' };
    w2.pt.onFocusStart('c1', 'u_o', 'O'); w2.pt.onFocusStart('c2', 'u_o', 'O'); w2.pt.onFocusStart('c2', 'u_p', 'P');
    check(w2.take().length === 2, '每日上限是全局的(跨圈累计)', null);
  }

  console.log('\n[E2EE / 文案]');
  {
    const w = world({ e2ee: true });
    w.sub('u_lu', 'c1', { name: '秘密圈' });
    w.pt.onFocusStart('c1', 'u_owner', '阿蛮');
    const s = w.take()[0];
    check(s?.title === 'Lares' && s.body === '有人在你的圈子里' && !JSON.stringify(s).includes('阿蛮') && !JSON.stringify(s).includes('秘密圈'), 'E2EE:不带人名 / 圈名', s);
    check(pushText('summon', 'en', { who: 'Ann' }) === 'Ann is calling you to the circle' && pushText('arrive', 'en', { who: 'Deer' }) === 'Deer is here', '英文文案', null);
    check(pushText('weekly', 'zh', { focusMs: 5.5 * HOUR, rank: 2, streak: 5, circleTotalMs: 20 * HOUR }) === '上周专注 5.5 小时 · 第 2 名 · 🔥5 · 全圈 20 小时', '周报中文文案', pushText('weekly', 'zh', { focusMs: 5.5 * HOUR, rank: 2, streak: 5, circleTotalMs: 20 * HOUR }));
  }
}

// ── 专注社交 ──
function unitSocial() {
  console.log('\n[出勤]');
  {
    const a = attendance({
      circleId: 'c', round: 2, rounds: 4, endedAt: 0, lenMs: 25 * MIN, graceMs: 10_000,
      members: [
        { userId: 'u_a', name: 'A', focusMs: 25 * MIN, awayMs: 0, inRoom: true },
        { userId: 'u_b', name: 'B', focusMs: 25 * MIN - 9000, awayMs: 9000, inRoom: true },
        { userId: 'u_lu', name: '小鹿', focusMs: 23 * MIN, awayMs: 2 * MIN, inRoom: true },
        { userId: 'u_ai_x', name: 'AI', focusMs: 25 * MIN, awayMs: 0, inRoom: true },
        { userId: 'u_gone', name: 'G', focusMs: 0, awayMs: 25 * MIN, inRoom: false },
      ],
    });
    check(a.total === 3 && a.full === 2, '3 人参与(AI、0 专注已走的排除),2 人全勤(离开 ≤ 宽限)', a);
    check(a.members.at(-1).userId === 'u_lu' && a.members.at(-1).full === false && a.members.at(-1).awayMs === 2 * MIN, '小鹿离开 2 分钟:未全勤,排最后', a.members);
  }
  {
    // 引擎实测:4 人一轮,1 人离开 2 分钟
    let t = MON;
    const evs = [];
    const eng = createFocusEngine({
      now: () => t, setTimer: null, out: (cid, ev) => evs.push(ev),
      pluginOf: () => ({ installed: true, enabled: true, config: { focusMin: 25, breakMin: 5, rounds: 2, graceSec: 10, membersCanStart: true } }),
    });
    for (const u of ['u_a', 'u_b', 'u_c', 'u_lu', 'u_ai_v']) eng.join('c', u, 'd-' + u, u === 'u_lu' ? '小鹿' : u);
    eng.start('c', 'u_a');
    t += 5 * MIN; eng.away('c', 'u_lu', 'd-u_lu');
    t += 2 * MIN; eng.back('c', 'u_lu', 'd-u_lu');
    t += 18 * MIN + 1; eng.tick();
    const re = evs.filter((e) => e.type === 'round_end');
    check(re.length === 1 && re[0].round.round === 1 && re[0].round.members.length === 4, '引擎:第 1 轮结束发 round_end(4 个真人,AI 不在内)', re[0]?.round);
    const a = attendance(re[0].round);
    check(a.total === 4 && a.full === 3 && a.members.find((m) => m.userId === 'u_lu').awayMs === 2 * MIN, '引擎实测:3/4 全勤 · 小鹿离开 2 分钟', a);
    // 休息中加入的人第 2 轮算;第 2 轮中途进来的不全勤
    t += 5 * MIN; eng.tick(); // 第 2 轮开始
    t += 10 * MIN; eng.join('c', 'u_late', 'd-late', 'Late');
    t += 15 * MIN + 1; eng.tick();
    const r2 = evs.filter((e) => e.type === 'round_end')[1];
    const a2 = attendance(r2.round);
    check(a2.total === 5 && a2.full === 4 && a2.members.find((m) => m.userId === 'u_late')?.full === false, '第 2 轮:中途进房的 Late 不算全勤', a2);
    eng.start('c', 'u_a');
    t += MIN; eng.stop('c', 'u_a');
    t += 30 * MIN; eng.tick();
    check(evs.filter((e) => e.type === 'round_end').length === 2, '手动停钟:本轮作废,不发 round_end', null);
  }

  console.log('\n[连续打卡]');
  {
    let s = bumpStreak(undefined, '2026-11-02');
    s = bumpStreak(s, '2026-11-02');
    check(s.n === 1, '同一天多轮只算 1 天', s);
    s = bumpStreak(s, '2026-11-03'); s = bumpStreak(s, '2026-11-04');
    check(s.n === 3 && s.best === 3, '连续 3 天', s);
    check(currentStreak(s, '2026-11-05') === 3 && currentStreak(s, '2026-11-06') === 0, '昨天打过卡仍算;断一天归零', null);
    s = bumpStreak(s, '2026-11-06');
    check(s.n === 1 && s.best === 3, '断档后从 1 重新计,best 保留', s);
    s = bumpStreak({ last: '2026-12-31', n: 4, best: 4 }, '2027-01-01');
    check(s.n === 5, '跨年连续', s);
  }
  {
    // 时区:北京用户 UTC 15:59 与 16:01 是两个本地日;UTC 用户是同一天
    const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-social-'));
    let t = Date.UTC(2026, 11, 1, 15, 59);
    const tz = { u_bj: { offsetMin: 480 }, u_utc: { offsetMin: 0 } };
    const sent = [];
    const fs = createFocusSocial({
      now: () => t, dataDir, daysOf: () => ({ names: {}, days: {} }), circleIds: () => [],
      userTz: (u) => tz[u] ?? null, circleTz: () => null, send: (ws, m) => sent.push(m), sessionsOfCircle: () => [{}], circleAllowed: () => true,
    });
    const round = (at) => ({ circleId: 'c', round: 1, rounds: 1, endedAt: at, lenMs: 25 * MIN, graceMs: 0, members: [
      { userId: 'u_bj', name: 'BJ', focusMs: 25 * MIN, awayMs: 0, inRoom: true },
      { userId: 'u_utc', name: 'UTC', focusMs: 25 * MIN, awayMs: 0, inRoom: true },
      { userId: 'u_ai_z', name: 'AI', focusMs: 25 * MIN, awayMs: 0, inRoom: true },
      { userId: 'u_half', name: 'Half', focusMs: 20 * MIN, awayMs: 5 * MIN, inRoom: true },
    ] });
    fs.onRoundEnd('c', round(t));
    t = Date.UTC(2026, 11, 1, 16, 1);
    fs.onRoundEnd('c', round(t));
    const k = fs.streaksOf('c');
    check(k.u_bj === 2 && k.u_utc === 1, '跨本地日:北京 23:59 → 00:01 = 连续 2 天;UTC 用户同一天 = 1', k);
    check(!('u_ai_z' in k) && !('u_half' in k), 'AI 与未全勤者不打卡', k);
    check(sent.some((m) => m.t === 'focus_round' && m.full === 2 && m.total === 3) && sent.some((m) => m.t === 'focus_streaks'), '广播 focus_round + focus_streaks', sent.map((m) => m.t));
    fs.flushSync();
    const disk = JSON.parse(readFileSync(path.join(dataDir, 'focus_social.json'), 'utf8'));
    check(disk.circles.c.streaks.u_bj.n === 2, '打卡持久化到 focus_social.json', disk);
    const fs2 = createFocusSocial({ now: () => t + DAY, dataDir, daysOf: () => ({ names: {}, days: {} }), userTz: (u) => tz[u] ?? null, send: () => {}, circleAllowed: () => true });
    check(fs2.streaksOf('c').u_bj === 2, '重启读回打卡(次日仍显示 🔥2)', fs2.streaksOf('c'));
    t += 3 * DAY;
    check(!('u_bj' in fs.streaksOf('c')), '断档 → 不再显示', fs.streaksOf('c'));
  }

  console.log('\n[周报]');
  {
    const days = {
      '2026-10-26': { u_a: 2 * HOUR, u_b: HOUR, u_ai_q: 9 * HOUR },
      '2026-11-01': { u_a: HOUR, u_c: 30 * MIN },
      '2026-11-02': { u_a: 5 * HOUR }, // 本周一:不算上周
      '2026-10-25': { u_b: 9 * HOUR }, // 上上周日:不算
    };
    const s = weeklySummary(days, { u_a: '阿蛮' }, '2026-10-26');
    check(s.rows.length === 3 && s.rows[0].userId === 'u_a' && s.rows[0].focusMs === 3 * HOUR && s.rows[0].rank === 1 && s.circleTotalMs === 4.5 * HOUR,
      '上周(周一..周日)汇总、排名、全圈总时长;AI 排除', s);

    let t = Date.UTC(2026, 10, 1, 15, 0); // 周日 UTC 15:00 = 北京周日 23:00
    const delivered = [];
    let quiet = new Set();
    const tzs = { u_a: { offsetMin: 480 } };
    const fs = createFocusSocial({
      now: () => t,
      daysOf: () => ({ names: { u_a: '阿蛮', u_b: 'B', u_c: 'C' }, days }),
      circleIds: () => ['c'],
      circleTz: () => ({ offsetMin: 480 }), // 圈主在北京
      userTz: (u) => tzs[u] ?? null,
      deliver: (uid, cid, card) => { if (quiet.has(uid)) return 'deferred'; delivered.push({ uid, card }); return 'sent'; },
      send: () => {}, sessionsOfCircle: () => [], circleAllowed: () => true,
    });
    check(fs.tick().length === 0, '周日不出周报', null);
    t = Date.UTC(2026, 10, 1, 16, 5); // 北京周一 00:05(UTC 还是周日)
    quiet = new Set(['u_b']);
    check(fs.tick().join() === 'c', '圈主时区的周一 00:05 → 出周报(UTC 仍是周日)', null);
    check(delivered.map((d) => d.uid).sort().join() === 'u_a,u_c', '推给上周专注过的人;免打扰中的 B 顺延', delivered);
    const ca = delivered.find((d) => d.uid === 'u_a')?.card;
    check(ca?.focusMs === 3 * HOUR && ca.rank === 1 && ca.of === 3 && ca.circleTotalMs === 4.5 * HOUR && ca.week === '2026-10-26', '周报卡片:时长 / 名次 / 人数 / 全圈', ca);
    check(fs.tick().length === 0, '同一周只出一次', null);
    quiet = new Set();
    t += 8 * HOUR;
    fs.tick();
    check(delivered.some((d) => d.uid === 'u_b'), '免打扰结束后补推 B', delivered.map((d) => d.uid));
    const ws = [];
    fs.handle({}, { userId: 'u_a', authed: true }, { t: 'focus_social_get', circleId: 'c' });
    const fsx = createFocusSocial({ now: () => t, daysOf: () => ({ names: {}, days: {} }), send: (w, m) => ws.push(m), circleAllowed: () => true });
    void fsx;
    // 应用内卡片
    const got = [];
    const fs3 = createFocusSocial({
      now: () => t, daysOf: () => ({ names: {}, days }), circleIds: () => ['c'], circleTz: () => null,
      deliver: () => 'skip', send: (w, m) => got.push(m), sessionsOfCircle: () => [], circleAllowed: () => true,
    });
    fs3.runWeekly('c', '2026-10-26');
    fs3.handle({}, { userId: 'u_c', authed: true }, { t: 'focus_social_get', circleId: 'c' });
    const card = got.find((m) => m.t === 'focus_weekly')?.card;
    check(card?.rank === 3 && card.focusMs === 30 * MIN, '进圈 focus_social_get → focus_weekly 卡片', got);
    fs3.handle({}, { userId: 'u_c', authed: true }, { t: 'focus_weekly_seen', circleId: 'c', week: '2026-10-26' });
    got.length = 0;
    fs3.handle({}, { userId: 'u_c', authed: true }, { t: 'focus_social_get', circleId: 'c' });
    check(got.find((m) => m.t === 'focus_weekly')?.card === null, '标已读后不再显示', got);
    fs3.handle({}, { userId: 'u_ai_q', authed: true }, { t: 'focus_social_get', circleId: 'c' });
    check(got.filter((m) => m.t === 'focus_weekly').at(-1)?.card === null, 'AI 没有周报卡片', null);
    // 没有圈主时区 → UTC 周一
    let t4 = Date.UTC(2026, 10, 1, 23, 0);
    const fs4 = createFocusSocial({ now: () => t4, daysOf: () => ({ names: {}, days }), circleIds: () => ['c'], circleTz: () => null, deliver: () => 'sent', send: () => {}, circleAllowed: () => true });
    check(fs4.tick().length === 0, '无圈主时区:UTC 周日 23:00 不出', null);
    t4 = Date.UTC(2026, 10, 2, 0, 1);
    check(fs4.tick().length === 1, '无圈主时区:UTC 周一 00:01 出', null);
  }
  {
    // 周报推送经 push_triggers.deliverToUser:守免打扰 / 等级 off,不看冷却与在房
    const w = world();
    w.t = Date.UTC(2026, 10, 1, 16, 5); // 北京周一 00:05
    w.sub('u_a', 'c1');
    w.sub('u_off', 'c1', { level: 'off' });
    w.sub('u_utc', 'c1', { prefs: { tzOffsetMin: 0 } });
    check(w.pt.deliverToUser('u_a', 'c1', 'weekly', { focusMs: HOUR, rank: 1, streak: 0, circleTotalMs: HOUR }) === 'deferred', '周报:免打扰中 → deferred', null);
    check(w.pt.deliverToUser('u_off', 'c1', 'weekly', {}) === 'skip', '周报:通知关 → skip', null);
    check(w.pt.deliverToUser('u_utc', 'c1', 'weekly', { focusMs: HOUR, rank: 1, streak: 2, circleTotalMs: HOUR }) === 'sent', '周报:UTC 16:05 → sent', null);
    const s = w.take()[0];
    check(s?.kind === 'weekly' && s.collapseId === 'w-c1' && s.body.includes('🔥2'), '周报 payload kind=weekly,collapse-id 独立(w-<圈>)不覆盖活动推送', s);
    check(w.pt.deliverToUser('u_ai_x', 'c1', 'weekly', {}) === 'skip', 'AI 不收周报', null);
  }
}

// ── 端到端 ──
function startFakeApns() {
  const requests = [];
  const server = http2.createSecureServer({
    cert: readFileSync(path.join(HERE, 'fixtures', 'fake-apns-TEST-ONLY.cert.pem')),
    key: readFileSync(path.join(HERE, 'fixtures', 'fake-apns-TEST-ONLY.key.pem')),
  });
  server.on('stream', (stream, headers) => {
    const chunks = [];
    stream.on('data', (c) => chunks.push(c));
    stream.on('end', () => {
      const p = headers[':path'];
      let body = null;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* null */ }
      requests.push({ at: Date.now(), token: p.startsWith('/3/device/') ? p.slice(10) : '', headers: { ...headers }, body });
      stream.respond({ ':status': 200, 'apns-id': crypto.randomUUID() });
      stream.end();
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port, requests,
    async waitFor(pred, ms = 3000) {
      const end = Date.now() + ms;
      while (Date.now() < end) { const h = requests.find(pred); if (h) return h; await wait(20); }
      return null;
    },
    close: () => new Promise((r) => server.close(r)),
  })));
}

async function e2e() {
  console.log('\n[端到端:真服务端 + 假 APNs]');
  const PORT = 18991;
  const PUBLIC_URL = 'wss://lares.test:8444/ws';
  const fake = await startFakeApns();
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-ptrig-'));
  const srv = boot(PORT, dataDir, 'ptrig-global-pass', {
    LARES_APNS_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    LARES_APNS_KEY_ID: 'TESTKEY123', LARES_APNS_TEAM_ID: '7CH28564U7',
    LARES_APNS_HOST_OVERRIDE: `https://127.0.0.1:${fake.port}`, LARES_APNS_INSECURE_TLS: '1',
    LARES_PUBLIC_URL: PUBLIC_URL,
  });
  const open = [];
  try {
    if (!(await waitHealth(PORT))) throw new Error('服务端启动超时');
    const { cid, verifier, ownerKey, owner } = await registerCircle(PORT, 'oak-lantern-river-mint', 'u_owner');
    open.push(owner);
    owner.close();
    const A = await connect(PORT, { userId: 'u_owner', name: '阿蛮', auth: v2Auth(verifier, cid, { ownerKey }) });
    const B = await connect(PORT, { userId: 'u_lu', name: '小鹿', auth: v2Auth(verifier, cid) });
    open.push(A, B);
    const TB = crypto.randomBytes(32).toString('hex');
    // 白天的 UTC 时区:避免 CI 时钟落在免打扰里
    const nowUtcMin = new Date().getUTCHours() * 60 + new Date().getUTCMinutes();
    const quiet = { start: (nowUtcMin + 120) % 1440, end: (nowUtcMin + 180) % 1440 };
    const r = await B.req({ t: 'push_register', provider: 'apns', token: TB, env: 'sandbox', lang: 'zh',
      circles: [{ circleId: cid, name: '自习室', level: 'all' }], prefs: { tzOffsetMin: 0, quiet } }, (m) => m.t === 'push_registered' || m.t === 'push_error');
    check(r?.t === 'push_registered' && r.circles[0] === cid, 'B 登记推送(level=all, 带时区 + 免打扰)', r);
    await wait(300);
    const subs = JSON.parse(readFileSync(path.join(dataDir, 'push_subscriptions.json'), 'utf8'));
    check(subs[TB]?.circles?.[cid]?.level === 'all' && subs[TB]?.prefs?.offsetMin === 0, '订阅表存了 level 与 prefs', subs[TB]);
    const inst = await A.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.focus' }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    check(inst?.t === 'plugin_installed', '圈主装 lares.focus', inst);
    let cfg = await A.req({ t: 'push_cfg_get', circleId: cid }, (m) => m.t === 'push_cfg');
    check(cfg?.cfg?.triggers?.focus === true && cfg.cfg.crowdN === 3 && cfg.summonReadyAt === 0, 'push_cfg_get:默认 focus 开,N=3', cfg);
    await join(A, cid);
    await wait(150);
    check(fake.requests.length === 0, '圈主进空房:arrive 默认关,不推', fake.requests.length);
    let t0 = Date.now();
    A.send({ t: 'focus_start', circleId: cid, ownerKey });
    const p = await fake.waitFor((q) => q.token === TB && q.at >= t0);
    check(Boolean(p), '圈主开番茄钟 → B 收到推送', fake.requests.length);
    check(p?.body?.aps?.alert?.body === '阿蛮开始专注了,一起学?' && p?.body?.aps?.alert?.title === '自习室', '文案「阿蛮开始专注了,一起学?」/ 标题圈名', p?.body?.aps);
    check(p?.body?.lares?.circleId === cid && p?.body?.lares?.server === PUBLIC_URL && p?.body?.lares?.kind === 'focus'
      && p?.body?.aps?.category === 'LARES_JOIN', '一键进圈 payload:{circleId, server, kind:focus} + category LARES_JOIN', p?.body);
    check(p?.headers?.['apns-collapse-id'] === cid, 'apns-collapse-id = circleId', p?.headers);
    A.send({ t: 'focus_stop', circleId: cid, ownerKey });
    await wait(100);
    t0 = Date.now();
    A.send({ t: 'focus_start', circleId: cid, ownerKey });
    await wait(500);
    check(fake.requests.filter((q) => q.token === TB && q.at >= t0).length === 0, '30 分钟冷却内再开钟:B 不再收到', fake.requests.length);
    // 叫大家来
    t0 = Date.now();
    const s1 = await A.req({ t: 'push_summon', circleId: cid, ownerKey }, (m) => m.t === 'push_summon_ok' || m.t === 'owner_error');
    check(s1?.t === 'push_summon_ok' && s1.sent === 1 && s1.nextAt > Date.now() + 9 * MIN, '叫大家来 → push_summon_ok(sent=1,nextAt≈+10min)', s1);
    const ps = await fake.waitFor((q) => q.token === TB && q.at >= t0);
    check(ps?.body?.aps?.alert?.body === '阿蛮 叫你来圈里' && ps?.body?.lares?.kind === 'summon', 'B 收到「阿蛮 叫你来圈里」(不受活动冷却约束)', ps?.body);
    const s2 = await A.req({ t: 'push_summon', circleId: cid, ownerKey }, (m) => m.t === 'push_summon_ok' || m.t === 'owner_error');
    check(s2?.t === 'owner_error' && s2.reason === 'cooldown' && s2.retryAt > Date.now(), '10 分钟内再叫 → owner_error cooldown + retryAt', s2);
    const s3 = await B.req({ t: 'push_summon', circleId: cid }, (m) => m.t === 'owner_error');
    check(s3?.reason === 'not_owner', '成员不能叫大家来', s3);
    cfg = await B.req({ t: 'push_cfg_get', circleId: cid }, (m) => m.t === 'push_cfg');
    check(cfg?.summonReadyAt > Date.now(), 'push_cfg 带 summonReadyAt(客户端显示冷却)', cfg);
    const soc = await B.req({ t: 'focus_social_get', circleId: cid }, (m) => m.t === 'focus_weekly');
    check(soc && soc.card === null, 'focus_social_get → focus_weekly(无卡片)', soc);
    const bad = await A.req({ t: 'push_cfg_set', circleId: cid, ownerKey, cfg: { triggers: { arrive: 'yes' } } }, (m) => m.t === 'owner_error' || m.t === 'owner_ok');
    check(bad?.reason === 'bad_config', 'push_cfg_set 严格校验', bad);
    const ok = await A.req({ t: 'push_cfg_set', circleId: cid, ownerKey, cfg: { triggers: { arrive: true }, crowdN: 2 } }, ownerReply('push_cfg_set'));
    check(ok?.t === 'owner_ok', 'push_cfg_set 保存', ok);
  } finally {
    for (const c of open) { try { await c.close(); } catch { /* ignore */ } }
    await stop(srv);
    await fake.close();
  }
}

unitTriggers();
unitSocial();
await e2e();
console.log(`\n${st.fail ? '有失败' : '全部通过'}(${st.pass} 通过,${st.fail} 失败)`);
process.exit(st.fail ? 1 : 0);
