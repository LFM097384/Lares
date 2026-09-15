// Lares 炉灵 — presence 信令服务
// 职责:维护「谁在哪个圈子房间」「轻状态」实时广播,并为进房成员签发 LiveKit token。
// MVP:内存态,单进程。后续按设计.md §4.2 演进为 Redis Pub/Sub 集群。

import http from 'node:http';
import crypto from 'node:crypto';
import { mkdir, readdir, readFile, writeFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { AccessToken } from 'livekit-server-sdk';

const PORT = Number(process.env.LARES_PORT ?? 8787);
const LIVEKIT_URL = process.env.LIVEKIT_URL ?? '';
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY ?? '';
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET ?? '';
const RTC_CONFIGURED = Boolean(LIVEKIT_URL && LIVEKIT_API_KEY && LIVEKIT_API_SECRET);

// ── 鉴权配置(公网暴露前的最小防线)──────────────────────────────────────────
// 产品决策:不做账号体系。用「共享密钥」或「圈子口令」的挑战应答证明把门,
// 保护约 20 人的熟人圈 —— 足以挡住扫描器与顺手薅带宽的人,不追求企业级身份。
// LARES_AUTH_MODE: none(默认,本地开发) | token | circle | "token,circle"(任一通过即可)
const AUTH_MODES = new Set(
  String(process.env.LARES_AUTH_MODE ?? 'none').split(',').map((s) => s.trim()).filter(Boolean),
);
if (AUTH_MODES.size === 0) AUTH_MODES.add('none');
const AUTH_TOKEN = process.env.LARES_AUTH_TOKEN ?? '';
const CIRCLE_PASSCODE = process.env.LARES_CIRCLE_PASSCODE ?? '';
// 可选:给特定圈子单独设口令,优先于全站口令。无需圈子注册表即可做到按圈隔离。
let CIRCLE_PASSCODES = {};
const ALLOWED_ORIGIN = process.env.LARES_ALLOWED_ORIGIN ?? '';
// nonce 有效期,默认 60s;可覆盖以便测试快速验证「过期」分支
const NONCE_TTL_MS = Number(process.env.LARES_AUTH_NONCE_TTL_MS ?? 60_000);

// 启动期配置校验:声明了模式却没给密钥 —— 必须「失败关闭」,绝不静默降级成裸奔
function validateAuthConfig() {
  const fatal = (m) => { console.error(`[auth] 致命配置错误:${m}`); process.exit(1); };
  for (const m of AUTH_MODES) {
    if (m !== 'none' && m !== 'token' && m !== 'circle') fatal(`未知的 LARES_AUTH_MODE 取值 "${m}"(可选 none/token/circle)`);
  }
  // none 与其它模式混写语义含糊(到底验不验?),一律拒启动
  if (AUTH_MODES.has('none') && AUTH_MODES.size > 1) fatal('LARES_AUTH_MODE 不能把 none 与其它模式混用');
  if (process.env.LARES_CIRCLE_PASSCODES) {
    try {
      const parsed = JSON.parse(process.env.LARES_CIRCLE_PASSCODES);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('不是 JSON 对象');
      for (const [k, v] of Object.entries(parsed)) {
        if (typeof v !== 'string' || !v) throw new Error(`圈子 "${k}" 的口令为空`);
      }
      CIRCLE_PASSCODES = parsed;
    } catch (e) {
      fatal(`LARES_CIRCLE_PASSCODES 不是合法的 {"circleId":"passcode"} JSON:${e.message}`);
    }
  }
  if (AUTH_MODES.has('token') && !AUTH_TOKEN) fatal('LARES_AUTH_MODE 含 token,但 LARES_AUTH_TOKEN 为空');
  if (AUTH_MODES.has('circle') && !CIRCLE_PASSCODE && Object.keys(CIRCLE_PASSCODES).length === 0) {
    fatal('LARES_AUTH_MODE 含 circle,但 LARES_CIRCLE_PASSCODE 与 LARES_CIRCLE_PASSCODES 均为空');
  }
  if (!Number.isFinite(NONCE_TTL_MS) || NONCE_TTL_MS <= 0) fatal('LARES_AUTH_NONCE_TTL_MS 必须是正数毫秒');
}
validateAuthConfig();

const AUTH_REQUIRED = !AUTH_MODES.has('none');
// 下发给客户端的可用模式,客户端 UI 据此决定弹「口令框」还是「密钥框」
const AUTH_MODE_LIST = AUTH_REQUIRED ? [...AUTH_MODES] : [];

/// 取某圈子适用的口令:按圈覆盖优先,否则回落全站口令
function passcodeFor(circleId) {
  const specific = CIRCLE_PASSCODES[circleId];
  if (typeof specific === 'string' && specific) return specific;
  return CIRCLE_PASSCODE || null;
}

/// 定长比较:先比长度再 timingSafeEqual(长度不等时 timingSafeEqual 会直接抛)
function safeEqualStr(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ba = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function hmacHex(key, msg) {
  return crypto.createHmac('sha256', key).update(msg, 'utf8').digest('hex');
}

// ── nonce 池:一次性 + 60s 过期,防重放 ─────────────────────────────────────
const MAP_CAP = 10_000; // nonce / 限流表容量上限,防止被打爆内存
const nonces = new Map(); // nonce -> issuedAt

function issueNonce() {
  // Map 保持插入序:超容量时淘汰最旧的一条
  while (nonces.size >= MAP_CAP) nonces.delete(nonces.keys().next().value);
  const nonce = crypto.randomBytes(16).toString('hex'); // 32 hex chars
  nonces.set(nonce, Date.now());
  return nonce;
}

/// 消费 nonce:无论成败都删除(单次有效)。返回它是否仍然有效。
function consumeNonce(nonce) {
  const issuedAt = nonces.get(nonce);
  if (issuedAt === undefined) return false;
  nonces.delete(nonce);
  return Date.now() - issuedAt <= NONCE_TTL_MS;
}

function sweepNonces() {
  const now = Date.now();
  for (const [nonce, issuedAt] of nonces) {
    if (now - issuedAt > NONCE_TTL_MS) nonces.delete(nonce);
    else break; // 插入序 = 时间序,遇到第一个未过期的即可停
  }
}

// ── 按 IP 的失败计数与封禁(轻量内存版,单进程够用)─────────────────────────
const RL_WINDOW_MS = 5 * 60_000;
const RL_MAX_FAILS = 10; // 5 分钟内超过 10 次失败即封禁
const RL_BLOCK_MS = 5 * 60_000;
const authFailures = new Map(); // ip -> { count, first, blockedUntil }

function clientIp(req) {
  // 只认 socket 对端地址:X-Forwarded-For 可伪造。反代场景需在入口层收敛可信来源。
  const raw = req?.socket?.remoteAddress ?? 'unknown';
  return raw.startsWith('::ffff:') ? raw.slice(7) : raw; // 归一 IPv4-mapped
}

function isRateLimited(ip) {
  const rec = authFailures.get(ip);
  if (!rec) return false;
  if (rec.blockedUntil && Date.now() < rec.blockedUntil) return true;
  if (rec.blockedUntil) authFailures.delete(ip); // 封禁已到期,放行并清账
  return false;
}

function recordAuthFailure(ip) {
  const now = Date.now();
  let rec = authFailures.get(ip);
  if (!rec || now - rec.first > RL_WINDOW_MS) rec = { count: 0, first: now, blockedUntil: 0 };
  rec.count += 1;
  if (rec.count > RL_MAX_FAILS) rec.blockedUntil = now + RL_BLOCK_MS;
  while (authFailures.size >= MAP_CAP && !authFailures.has(ip)) {
    authFailures.delete(authFailures.keys().next().value); // 淘汰最旧
  }
  authFailures.set(ip, rec);
}

function clearAuthFailures(ip) { authFailures.delete(ip); }

function sweepRateLimits() {
  const now = Date.now();
  for (const [ip, rec] of authFailures) {
    const dead = rec.blockedUntil ? now >= rec.blockedUntil : now - rec.first > RL_WINDOW_MS;
    if (dead) authFailures.delete(ip);
  }
}

// ── 录音过期清理(需求⑧)──────────────────────────────────────────────
// 录音端被杀/断网时不会发 rec_stop。若不清理,房间会**永远显示有人在录** ——
// 指示器一旦说过谎就再没人信。阈值取心跳间隔(15s)的 3 倍,容忍两次丢包。
// 复用已有的 30s heartbeat 扫描,不另起 timer。
const REC_STALE_MS = 45_000;

function sweepStaleRecordings() {
  const now = Date.now();
  for (const [circleId, circle] of circles) {
    for (const member of circle.values()) {
      if (!member.rec) continue;
      if (now - member.rec.seen <= REC_STALE_MS) continue;
      delete member.rec;
      broadcast(circleId, {
        t: 'member_rec',
        circleId,
        userId: member.userId,
        name: member.name,
        active: false,
        since: 0,
      });
    }
  }
}

/// 校验 hello.auth 的挑战应答证明。原文里始终不出现明文密钥。
/// token 模式:proof = HMAC_SHA256(LARES_AUTH_TOKEN, `${nonce}:${userId}`)
/// circle 模式:proof = HMAC_SHA256(passcodeFor(circleId), `${nonce}:${userId}:${circleId}`)
/// 返回 { ok:true, mode, circleId } 或 { ok:false, reason }
function verifyAuth(auth, userId, sessionNonce) {
  if (!auth || typeof auth !== 'object') return { ok: false, reason: 'auth_required' };
  const mode = typeof auth.mode === 'string' ? auth.mode : '';
  // 客户端可回显 nonce 便于自检;一旦回显就必须与本连接下发的那条一致,杜绝跨连接重放
  if (auth.nonce !== undefined && auth.nonce !== sessionNonce) return { ok: false, reason: 'auth_failed' };
  // 未启用的模式一律不接受,避免「声明弱模式绕过强模式」
  if (!AUTH_MODES.has(mode)) return { ok: false, reason: 'auth_failed' };
  if (typeof auth.proof !== 'string' || !auth.proof) return { ok: false, reason: 'auth_failed' };
  // nonce 一次性:验成验败都在此消费掉
  if (!consumeNonce(sessionNonce)) return { ok: false, reason: 'auth_failed' };

  if (mode === 'token') {
    const expect = hmacHex(AUTH_TOKEN, `${sessionNonce}:${userId}`);
    return safeEqualStr(auth.proof.toLowerCase(), expect)
      ? { ok: true, mode: 'token', circleId: null }
      : { ok: false, reason: 'auth_failed' };
  }
  // circle 模式:证明的是「某个具体圈子」的口令,因此该连接只能进那个圈子
  const circleId = typeof auth.circleId === 'string' && auth.circleId ? auth.circleId : '';
  if (!circleId) return { ok: false, reason: 'auth_failed' };
  const pass = passcodeFor(circleId);
  if (!pass) return { ok: false, reason: 'auth_failed' };
  const expect = hmacHex(pass, `${sessionNonce}:${userId}:${circleId}`);
  return safeEqualStr(auth.proof.toLowerCase(), expect)
    ? { ok: true, mode: 'circle', circleId }
    : { ok: false, reason: 'auth_failed' };
}

/// 连接是否有权操作该圈子。circle 模式钉死在证明过的那个圈子;token 模式不限。
function circleAllowed(session, circleId) {
  if (!AUTH_REQUIRED) return true;
  if (session.authMode === 'circle') return session.authCircleId === circleId;
  return true;
}

/// circle 模式下,不带 circleId 的请求默认落到已授权的那个圈子(而非写死的 'home'),
/// 这样客户端少写一个字段也不会莫名撞上 auth_scope。
function defaultCircleFor(session) {
  if (AUTH_REQUIRED && session.authMode === 'circle' && session.authCircleId) return session.authCircleId;
  return 'home';
}

// ── 房间状态 ──────────────────────────────────────────────────────────────
// circleId -> Map<userId, Member>
// Member = { userId, name, status, devices: Map<deviceId, ws> }
const circles = new Map();

// ── 敲门模式(设计.md §3.3):圈子可设「需轻量提示允许」──
// circleId -> { knockRequired: boolean },磁盘持久化
const DATA_DIR = process.env.LARES_DATA_DIR
  ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'data');
const SETTINGS_FILE = path.join(DATA_DIR, 'circle_settings.json');
let circleSettings = {};

// circleId -> Map<userId, {ws, session}>:等待应门的敲门者
const pendingKnocks = new Map();

async function loadSettings() {
  try {
    circleSettings = JSON.parse(await readFile(SETTINGS_FILE, 'utf8'));
  } catch { /* 首次运行 */ }
}

function saveSettings() {
  mkdir(DATA_DIR, { recursive: true })
    .then(() => writeFile(SETTINGS_FILE, JSON.stringify(circleSettings)))
    .catch((e) => console.error('[settings] 保存失败:', e));
}

const VALID_STATUS = new Set(['free', 'busy', 'ears', 'away']);

function getCircle(circleId) {
  if (!circles.has(circleId)) circles.set(circleId, new Map());
  return circles.get(circleId);
}

function memberSnapshot(member) {
  return {
    userId: member.userId,
    name: member.name,
    status: member.status,
    deviceCount: member.devices.size,
    // 位置共享:有则带上(后进房的人也能看到)
    ...(member.loc ? { loc: member.loc } : {}),
    // 录音态:有则带上 —— 后进房的人必须立刻知道房间正在被录(伦理红线)
    ...(member.rec ? { rec: { since: member.rec.since } } : {}),
  };
}

function roomSnapshot(circleId) {
  const members = [...getCircle(circleId).values()].map(memberSnapshot);
  return { t: 'room', circleId, members };
}

function broadcast(circleId, msg, exceptWs = null) {
  const data = JSON.stringify(msg);
  for (const member of getCircle(circleId).values()) {
    for (const ws of member.devices.values()) {
      if (ws !== exceptWs && ws.readyState === ws.OPEN) ws.send(data);
    }
  }
}

// ── 大厅 presence 摘要(未进房也要能看到「X 人在」,设计.md §3.2-1)──
const lobby = new Set(); // 所有已 hello 的连接

// ── 「挂着」(可约)状态 ──────────────────────────────────────────────────
//
// 语义:用户**不进任何房间**,只在大厅里标记「我有空,谁来找我都行」,
// 并对他自己选定的若干圈子可见。第一个来找他的人把两边都拉进
// **那个发起人所在的圈子**;此刻挂着状态立即取消,对其他圈子的人
// 不再显示为可约。
//
// 为什么不做成「同时在多个房间里」:那要拆掉 circleAllowed 的单圈钉死,
// 而那正是修过 5 个越权漏洞的地方。这里改用「一个全局状态 + 广播时按
// 授权范围过滤」,鉴权模型一行不动。
//
// ⚠️ 纯内存、断线即消、不落盘 —— 与 presence 同级别。
// userId -> { circleIds:Set<string>, name, since, ws }
const available = new Map();

/// 挂着状态对某个连接是否可见。
///
/// 两个条件都要满足:
/// 1. 发布者把这个圈子选进了可见范围;
/// 2. 观察者**有权看到**那个圈子(circle 模式下只认自己证明过的那个)。
///
/// 第 2 条是关键 —— 少了它就等于把「某人有空」广播给所有连接,
/// 那是一条新的越权泄露通道。
function availableVisibleTo(session, entry) {
  for (const cid of entry.circleIds) {
    if (circleAllowed(session, cid)) return true;
  }
  return false;
}

/// 这个用户此刻挂着、且对该连接可见的圈子清单。
/// 只回观察者有权看到的那几个,不泄露他挂在别的圈子这件事。
function visibleCirclesOf(session, entry) {
  const out = [];
  for (const cid of entry.circleIds) {
    if (circleAllowed(session, cid)) out.push(cid);
  }
  return out;
}

function availableMsg(userId, entry, session) {
  return {
    t: 'member_available',
    userId,
    name: entry.name,
    since: entry.since,
    circleIds: visibleCirclesOf(session, entry),
  };
}

/// 广播某人的挂着状态变化。[gone] 为真表示取消。
function broadcastAvailable(userId, gone = false) {
  const entry = available.get(userId);
  for (const ws of lobby) {
    const s = ws._laresSession;
    if (!s || ws.readyState !== ws.OPEN) continue;
    // 取消时用**取消前**的可见范围判断,否则对方永远收不到「他不可约了」
    if (gone) {
      const prev = ws._laresSawAvailable?.has(userId);
      if (!prev) continue;
      ws._laresSawAvailable.delete(userId);
      ws.send(JSON.stringify({ t: 'member_unavailable', userId }));
      continue;
    }
    if (!entry || !availableVisibleTo(s, entry)) continue;
    (ws._laresSawAvailable ??= new Set()).add(userId);
    ws.send(JSON.stringify(availableMsg(userId, entry, s)));
  }
}

/// 清掉某人的挂着状态(进房、断线、显式取消都走这里)。
function clearAvailable(userId) {
  if (!available.has(userId)) return;
  available.delete(userId);
  broadcastAvailable(userId, true);
}

function circleSummaryMsg(circleId) {
  const members = [...(circles.get(circleId)?.values() ?? [])];
  return {
    t: 'circle_summary',
    circleId,
    count: members.length,
    names: members.map((m) => m.name),
    knockRequired: circleSettings[circleId]?.knockRequired === true,
  };
}

function broadcastLobbySummary(circleId) {
  const data = JSON.stringify(circleSummaryMsg(circleId));
  for (const ws of lobby) {
    // 修补越权泄露:circle 模式下的连接只证明了一个圈子的口令,
    // 不该从大厅摘要里看到别的圈子「几个人在、都叫什么」。
    if (ws._laresSession && !circleAllowed(ws._laresSession, circleId)) continue;
    if (ws.readyState === ws.OPEN) ws.send(data);
  }
}

async function mintLiveKitToken(circleId, userId, name) {
  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: userId,
    name,
    // token 短寿命,进房即签,降低泄露面
    ttl: '2h',
  });
  // canPublishData:即将上线的「圈内发文字/图片」走 LiveKit data channel。
  // 其余维持房间级最小授权,不放宽。
  at.addGrant({ roomJoin: true, room: circleId, canPublish: true, canSubscribe: true, canPublishData: true });
  return at.toJwt();
}

// ── 连接会话 ──────────────────────────────────────────────────────────────
function handleConnection(ws, req) {
  // 每条连接绑定 (userId, deviceId);一个用户可多端在线
  // authMode/authCircleId:本连接通过了哪种鉴权、被钉死在哪个圈子
  const session = {
    userId: null, deviceId: null, circleId: null,
    authed: !AUTH_REQUIRED, authMode: AUTH_REQUIRED ? null : 'none', authCircleId: null,
  };
  const ip = clientIp(req);
  ws._laresSession = session; // 广播时按会话的授权范围过滤

  // 暴力破解封禁:连 challenge 都不发,直接关断(省得成为噪音放大器)
  if (AUTH_REQUIRED && isRateLimited(ip)) {
    send(ws, { t: 'error', message: 'rate_limited' });
    ws.close(4429, 'rate_limited');
    return;
  }

  // 连接一建立就下发挑战:客户端据此算证明,明文密钥永不上线
  const nonce = issueNonce();
  session.nonce = nonce;
  send(ws, { t: 'challenge', nonce, modes: AUTH_MODE_LIST, authRequired: AUTH_REQUIRED });

  ws.on('message', async (raw) => {
    // 消息体上限 64KB(防内存 DoS;正常协议消息 << 1KB)
    if (raw.length > 64 * 1024) return send(ws, { t: 'error', message: 'too_large' });
    let msg;
    try { msg = JSON.parse(raw); } catch { return send(ws, { t: 'error', message: 'bad_json' }); }

    switch (msg.t) {
      case 'hello': {
        if (typeof msg.userId !== 'string' || !msg.userId) return send(ws, { t: 'error', message: 'userId_required' });
        // 鉴权闸门:先验证再落任何会话状态,失败即断,用 4401 让客户端能区分
        // 「口令错」(该弹输入框)与「网络抖动」(该静默重连)
        if (AUTH_REQUIRED) {
          if (isRateLimited(ip)) {
            send(ws, { t: 'error', message: 'rate_limited' });
            return ws.close(4429, 'rate_limited');
          }
          const r = verifyAuth(msg.auth, msg.userId, session.nonce);
          if (!r.ok) {
            recordAuthFailure(ip);
            send(ws, { t: 'error', message: r.reason });
            return ws.close(4401, r.reason);
          }
          session.authed = true;
          session.authMode = r.mode;
          session.authCircleId = r.circleId;
          clearAuthFailures(ip); // 认证成功即销账,避免家人共用出口 IP 被连坐
        }
        session.userId = msg.userId;
        session.deviceId = typeof msg.deviceId === 'string' && msg.deviceId ? msg.deviceId : crypto.randomUUID();
        session.name = typeof msg.name === 'string' && msg.name ? msg.name.slice(0, 24) : '圈友';
        session.platform = typeof msg.platform === 'string' ? msg.platform : 'unknown';
        send(ws, {
          t: 'welcome', userId: session.userId, deviceId: session.deviceId,
          rtcConfigured: RTC_CONFIGURED, authMode: session.authMode,
        });
        // 加入大厅并立即下发所有非空圈子的在线摘要
        lobby.add(ws);
        // 同样按授权范围过滤:circle 模式只推它自己那个圈子的摘要
        for (const [circleId] of circles) {
          if (circleAllowed(session, circleId)) send(ws, circleSummaryMsg(circleId));
        }
        // 补发当前挂着的人 —— 后连上来的也要知道谁有空,
        // 否则只有「挂起那一刻正好在线」的人看得到。
        for (const [uid, entry] of available) {
          if (uid === session.userId) continue; // 自己不用看自己
          if (!availableVisibleTo(session, entry)) continue;
          (ws._laresSawAvailable ??= new Set()).add(uid);
          send(ws, availableMsg(uid, entry, session));
        }
        break;
      }

      case 'join': {
        if (!session.userId) return send(ws, { t: 'error', message: 'say_hello_first' });
        const circleId = typeof msg.circleId === 'string' && msg.circleId ? msg.circleId : defaultCircleFor(session);
        // circle 模式只证明了某一个圈子的口令,越界进别的圈子必须拒绝
        if (!circleAllowed(session, circleId)) return send(ws, { t: 'error', message: 'auth_scope' });
        // 敲门模式:圈内有人时需里面的人放行;空房直接进(没人可问)
        if (circleSettings[circleId]?.knockRequired && getCircle(circleId).size > 0) {
          if (!pendingKnocks.has(circleId)) pendingKnocks.set(circleId, new Map());
          pendingKnocks.get(circleId).set(session.userId, { ws, session });
          send(ws, { t: 'knock_waiting', circleId });
          broadcast(circleId, { t: 'knock', circleId, userId: session.userId, name: session.name });
          break;
        }
        await joinCircle(ws, session, circleId);
        break;
      }

      case 'available': {
        // 挂起「我有空」。msg.circleIds = 想对哪几个圈子可见。
        if (!session.userId) return send(ws, { t: 'error', message: 'say_hello_first' });
        const raw = Array.isArray(msg.circleIds) ? msg.circleIds : [];
        // 只接受自己有权进的圈子 —— 否则等于借这条消息把自己
        // 广播进一个没有口令的圈子,是越权。
        const ids = new Set(
          raw.filter((c) => typeof c === 'string' && c && circleAllowed(session, c)),
        );
        if (ids.size === 0) return send(ws, { t: 'error', message: 'auth_scope' });
        // 已经在房间里就不该再挂着 —— 两者语义互斥
        if (session.circleId) return send(ws, { t: 'error', message: 'already_in_room' });
        available.set(session.userId, {
          circleIds: ids,
          name: session.name,
          since: Date.now(),
          ws,
        });
        send(ws, { t: 'available_ok', circleIds: [...ids] });
        broadcastAvailable(session.userId);
        break;
      }

      case 'unavailable': {
        if (!session.userId) return;
        // 只能取消自己的
        clearAvailable(session.userId);
        break;
      }

      case 'reach': {
        // 「去找 ta」。把双方都拉进**发起人(被找的那个人)所在的圈子**。
        //
        // 为什么是发起人的圈子而不是新建临时房:临时房不属于任何圈子,
        // 与既有的圈子鉴权、E2EE 密钥派生(由圈口令来)全都对不上。
        if (!session.userId) return;
        const targetId = typeof msg.userId === 'string' ? msg.userId : '';
        const entry = targetId ? available.get(targetId) : null;
        if (!entry) return send(ws, { t: 'reach_failed', reason: 'gone' });
        // 只能找到自己看得见的人
        if (!availableVisibleTo(session, entry)) {
          return send(ws, { t: 'reach_failed', reason: 'gone' });
        }
        // 进哪个圈子:取「双方都有权、且对方挂着」的第一个。
        // 通常就是找的人自己所在的那个圈。
        const circleId = typeof msg.circleId === 'string' && msg.circleId
          ? msg.circleId
          : visibleCirclesOf(session, entry)[0];
        if (!circleId || !entry.circleIds.has(circleId) || !circleAllowed(session, circleId)) {
          return send(ws, { t: 'reach_failed', reason: 'auth_scope' });
        }
        // 先清挂着态再进房:清理会广播 member_unavailable,
        // 让其他圈子的人立刻看到「他不可约了」。
        const targetWs = entry.ws;
        const targetSession = targetWs?._laresSession;
        clearAvailable(targetId);
        // 被找的人先进房,再让发起者进 —— 这样发起者进去时房里已经有人,
        // 拿到的 room 快照是完整的。
        if (targetWs && targetWs.readyState === targetWs.OPEN && targetSession) {
          send(targetWs, { t: 'reached', circleId, by: session.name, byUserId: session.userId });
          await joinCircle(targetWs, targetSession, circleId);
        }
        await joinCircle(ws, session, circleId);
        break;
      }

      case 'knock_allow': {
        // 授权检查:只有圈内成员才能放行(否则敲门形同虚设)
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const approver = circleId ? getCircle(circleId).get(session.userId) : null;
        if (!approver || !approver.devices.has(session.deviceId)) return;
        const pending = pendingKnocks.get(circleId);
        const target = pending?.get(msg.userId);
        if (!target) return;
        pending.delete(msg.userId);
        await joinCircle(target.ws, target.session, circleId);
        break;
      }

      case 'kick': {
        // 踢人:圈内成员可把目标用户请出房间(非封禁,可再进)
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const targetId = typeof msg.userId === 'string' ? msg.userId : '';
        const circle = circleId ? getCircle(circleId) : null;
        const actor = circle?.get(session.userId);
        // 授权:发起者必须是圈内成员;不能踢自己
        if (!actor || !actor.devices.has(session.deviceId) || !targetId || targetId === session.userId) return;
        const target = circle.get(targetId);
        if (!target) return;
        // 先通知目标端,再移出房间
        for (const tws of target.devices.values()) {
          send(tws, { t: 'kicked', circleId, by: actor.name });
        }
        circle.delete(targetId);
        broadcast(circleId, { t: 'member_left', circleId, userId: targetId });
        if (circle.size === 0) circles.delete(circleId);
        broadcastLobbySummary(circleId);
        break;
      }

      case 'loc': {
        // 位置共享(Snapchat 式):仅转发给同房成员,不落盘
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (!member) return;
        const lat = Number(msg.lat), lng = Number(msg.lng);
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) return;
        member.loc = { lat, lng, ts: Date.now() };
        broadcast(session.circleId, {
          t: 'member_loc',
          circleId: session.circleId,
          userId: session.userId,
          name: member.name,
          lat,
          lng,
          ts: member.loc.ts,
        });
        break;
      }

      case 'loc_off': {
        // 关闭共享:广播清除自己的位置
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (member) delete member.loc;
        broadcast(session.circleId, { t: 'member_loc_off', circleId: session.circleId, userId: session.userId });
        break;
      }

      // ── 录音同意广播(需求⑧)──────────────────────────────────────────
      // 设计见 docs/recording-consent-protocol.md。核心不变量:
      // **服务器是录音态的唯一权威**,且客户端必须等到自己的回显才允许采集 ——
      // 「指示器说谎」是本功能最不能出的事故。
      case 'rec_start': {
        if (!session.circleId || !session.userId) return;
        if (msg.circleId !== session.circleId) return; // 防跨圈误报
        const member = getCircle(session.circleId).get(session.userId);
        if (!member) return;
        // 已在录则只续期,不重置 since —— 重连补发 rec_start 会走到这里,
        // 重置会让「已录 N 分钟」倒退。
        if (!member.rec) member.rec = { since: Date.now(), seen: Date.now() };
        else member.rec.seen = Date.now();
        // 回显给发起者自己是**放行采集的前提**,故不能用 exceptWs 把他排除。
        broadcast(session.circleId, {
          t: 'member_rec',
          circleId: session.circleId,
          userId: session.userId,
          name: member.name,
          active: true,
          since: member.rec.since,
        });
        break;
      }

      case 'rec_stop': {
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (!member || !member.rec) return; // 幂等:没在录就当无事发生
        delete member.rec;
        broadcast(session.circleId, {
          t: 'member_rec',
          circleId: session.circleId,
          userId: session.userId,
          name: member.name,
          active: false,
          since: 0,
        });
        break;
      }

      case 'rec_ping': {
        // 活性心跳:录音端每 15s 一发。只更新 seen,不广播(否则平白放大流量)。
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (member?.rec) {
          member.rec.seen = Date.now();
          // ack:让录音端能察觉 TCP 半开(连接已死但本机未察觉)。
          // 没有它,客户端会一边采集、房间那边却早已不知情。
          send(ws, { t: 'rec_pong', now: Date.now() });
        }
        break;
      }

      case 'knock_mode_set': {
        if (typeof msg.circleId !== 'string' || typeof msg.enabled !== 'boolean') return;
        // 修补越权:原实现下「空圈」任何人都能改,且连 hello 都不必说 ——
        // 公网上这等于让陌生人给任意圈子挂上/摘掉敲门锁。至少要求已握手 + 在授权范围内。
        if (!session.userId) return send(ws, { t: 'error', message: 'say_hello_first' });
        if (!circleAllowed(session, msg.circleId)) return send(ws, { t: 'error', message: 'auth_scope' });
        // 授权:圈内成员可改;空圈已鉴权者可预设(创建者场景)
        const circle = getCircle(msg.circleId);
        if (circle.size > 0) {
          const setter = circle.get(session.userId);
          if (!setter || !setter.devices.has(session.deviceId)) return;
        }
        circleSettings[msg.circleId] = { knockRequired: msg.enabled };
        saveSettings();
        broadcastLobbySummary(msg.circleId);
        break;
      }

      case 'leave': {
        leaveCircle(ws, session);
        break;
      }

      case 'token_prefetch': {
        // 预热(P0):App 启动即备好 RTC token,进房时信令与媒体连接并行
        if (!session.userId) return;
        const circleId = typeof msg.circleId === 'string' && msg.circleId ? msg.circleId : defaultCircleFor(session);
        // 预取签的是「真 token」,不设防等于把 join 的鉴权整条绕过去。
        // 越权判断必须排在 RTC_CONFIGURED 之前:否则未配 LiveKit 时这条检查是死代码,
        // 线上一旦配好 LiveKit 就会沉默地变成可利用的绕过口。
        if (!circleAllowed(session, circleId)) return send(ws, { t: 'error', message: 'auth_scope' });
        if (!RTC_CONFIGURED) return;
        try {
          const token = await mintLiveKitToken(circleId, session.userId, session.name);
          send(ws, { t: 'token', circleId, url: LIVEKIT_URL, token, prefetch: true });
        } catch (err) {
          console.error('[token] prefetch failed:', err);
        }
        break;
      }

      case 'profile': {
        // 改名:更新会话与房间成员记录,广播给同房成员与大厅
        if (typeof msg.name !== 'string' || !msg.name.trim()) return;
        const name = msg.name.trim().slice(0, 24);
        session.name = name;
        if (session.circleId && session.userId) {
          const member = getCircle(session.circleId).get(session.userId);
          if (member) {
            member.name = name;
            broadcast(session.circleId, { t: 'member_updated', circleId: session.circleId, member: memberSnapshot(member) });
            broadcastLobbySummary(session.circleId);
          }
        }
        break;
      }

      case 'status': {
        if (!session.circleId || !session.userId) return;
        const status = VALID_STATUS.has(msg.status) ? msg.status : 'free';
        const member = getCircle(session.circleId).get(session.userId);
        if (!member) return;
        member.status = status;
        broadcast(session.circleId, { t: 'member_status', circleId: session.circleId, userId: session.userId, status });
        break;
      }

      case 'ping': {
        send(ws, { t: 'pong', now: Date.now() });
        break;
      }
    }
  });

  ws.on('close', () => {
    lobby.delete(ws);
    leaveCircle(ws, session);
    // 断线即取消挂着 —— 否则会留下一个点了没反应的「可约」幽灵。
    // 只清**这条连接**挂起的那个:同一个人在别的设备上挂着的不该被误清。
    if (session.userId && available.get(session.userId)?.ws === ws) {
      clearAvailable(session.userId);
    }
    // 清理未应门的敲门请求
    for (const pending of pendingKnocks.values()) pending.delete(session.userId);
  });
  ws.on('error', () => {
    lobby.delete(ws);
    leaveCircle(ws, session);
    if (session.userId && available.get(session.userId)?.ws === ws) {
      clearAvailable(session.userId);
    }
  });
}

/// 执行进房(直接进 / 敲门放行后):换圈、登记成员、发房间快照与 RTC token
async function joinCircle(ws, session, circleId) {
  // 进房与「挂着」互斥:人已经在房间里了,对其他圈子就不该再显示可约。
  // 放在这里而不是只放在 reach 分支里 —— 用户自己点进某个圈子时
  // 同样要取消挂着态,否则别人还会看到一个进不去的「可约」标记。
  if (session.userId) clearAvailable(session.userId);
  // 先退出旧圈子(MVP:同时只在一个圈子的房间里)
  if (session.circleId) leaveCircle(ws, session);
  session.circleId = circleId;
  const circle = getCircle(circleId);
  const existing = circle.get(session.userId);
  if (existing) {
    existing.devices.set(session.deviceId, ws);
    existing.name = session.name;
    send(ws, roomSnapshot(circleId));
  } else {
    const member = { userId: session.userId, name: session.name, status: 'free', devices: new Map([[session.deviceId, ws]]) };
    circle.set(session.userId, member);
    broadcast(circleId, { t: 'member_joined', circleId, member: memberSnapshot(member) }, ws);
    send(ws, roomSnapshot(circleId));
    broadcastLobbySummary(circleId);
  }
  // 签发 RTC token
  if (RTC_CONFIGURED) {
    try {
      const token = await mintLiveKitToken(circleId, session.userId, session.name);
      send(ws, { t: 'token', circleId, url: LIVEKIT_URL, token });
    } catch (err) {
      send(ws, { t: 'error', message: 'token_failed' });
      console.error('[token] mint failed:', err);
    }
  } else {
    send(ws, { t: 'error', message: 'rtc_not_configured' });
  }
}

function leaveCircle(ws, session) {
  if (!session.circleId || !session.userId) return;
  const circle = getCircle(session.circleId);
  const member = circle.get(session.userId);
  if (member) {
    member.devices.delete(session.deviceId);
    // 同一用户所有端都离开才算「出房」
    if (member.devices.size === 0) {
      // 录音者直接掉线:先撤录音指示再报离开。
      // 成员对象整个被删时 rec 随之消失,但广播必须补发 ——
      // 否则其他端的指示器会停在旧状态(即「说谎」)。
      if (member.rec) {
        delete member.rec;
        broadcast(session.circleId, {
          t: 'member_rec',
          circleId: session.circleId,
          userId: session.userId,
          name: member.name,
          active: false,
          since: 0,
        });
      }
      circle.delete(session.userId);
      broadcast(session.circleId, { t: 'member_left', circleId: session.circleId, userId: session.userId });
      if (circle.size === 0) circles.delete(session.circleId);
      broadcastLobbySummary(session.circleId);
    }
  }
  session.circleId = null;
}

function send(ws, msg) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
}

// ── 语音便签(设计.md §2.2:圈子里没人时,留一条 15s 语音)──
// MVP:磁盘 JSON 存储(audio 为 base64),听过即删。后续演进:对象存储 + 转码队列。
const NOTES_DIR = path.join(DATA_DIR, 'notes');
const NOTE_MAX_SECONDS = 15;
const NOTE_MAX_BYTES = 2 * 1024 * 1024; // base64 后上限

async function noteDir(circleId) {
  const dir = path.join(NOTES_DIR, encodeURIComponent(circleId));
  await mkdir(dir, { recursive: true });
  return dir;
}

async function listNotes(circleId) {
  try {
    const dir = await noteDir(circleId);
    const files = await readdir(dir);
    const notes = [];
    for (const f of files.filter((f) => f.endsWith('.json'))) {
      try {
        notes.push(JSON.parse(await readFile(path.join(dir, f), 'utf8')));
      } catch { /* 跳过坏文件 */ }
    }
    return notes.sort((a, b) => a.createdAt - b.createdAt);
  } catch {
    return [];
  }
}

async function saveNote(circleId, note) {
  const dir = await noteDir(circleId);
  await writeFile(path.join(dir, `${note.id}.json`), JSON.stringify(note));
}

async function deleteNote(circleId, id) {
  try {
    await unlink(path.join(NOTES_DIR, encodeURIComponent(circleId), `${id}.json`));
  } catch { /* 已不存在 */ }
}

/// HTTP 侧鉴权:REST 是无状态的,挑战应答那套用不上,退回 Bearer。
/// token 模式收 LARES_AUTH_TOKEN;circle 模式收「该 circleId 对应的口令」——
/// 必须按操作的那个圈子校验,否则 home 的口令就能读写 work 的便签。
function httpAuthOk(req, circleId) {
  if (!AUTH_REQUIRED) return true;
  const header = req.headers['authorization'] ?? '';
  if (!header.startsWith('Bearer ')) return false;
  const presented = header.slice(7).trim();
  if (!presented) return false;
  // 逐个模式比对,命中任一即可(组合模式下 token 与口令都收)
  if (AUTH_MODES.has('token') && AUTH_TOKEN && safeEqualStr(presented, AUTH_TOKEN)) return true;
  if (AUTH_MODES.has('circle')) {
    const pass = passcodeFor(circleId);
    if (pass && safeEqualStr(presented, pass)) return true;
  }
  return false;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > NOTE_MAX_BYTES * 2) req.destroy();
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// ── HTTP + WS 服务 ────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const json = (code, obj) => {
    res.writeHead(code, {
      'content-type': 'application/json',
      // 开了鉴权就不再无脑 *:配了 LARES_ALLOWED_ORIGIN 就只回显它
      'access-control-allow-origin': ALLOWED_ORIGIN || '*',
      'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
      // 补 authorization:原来缺这项,浏览器带 Bearer 的预检会直接失败
      'access-control-allow-headers': 'content-type,authorization',
      ...(ALLOWED_ORIGIN ? { vary: 'origin' } : {}),
    });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'OPTIONS') return json(204, {});

  if (url.pathname === '/health') {
    // 开鉴权后不再吐各圈人数:那是给扫描器用的侦察面(谁在、哪个圈活跃)
    if (AUTH_REQUIRED) return json(200, { ok: true, rtcConfigured: RTC_CONFIGURED, authRequired: true });
    const summary = {};
    for (const [circleId, members] of circles) summary[circleId] = members.size;
    return json(200, { ok: true, rtcConfigured: RTC_CONFIGURED, circles: summary });
  }

  // 语音便签 API(开鉴权后需 Authorization: Bearer;REST 无状态,挑战应答不适用)
  if (url.pathname === '/notes' && req.method === 'GET') {
    const circleId = url.searchParams.get('circleId') ?? 'home';
    if (!httpAuthOk(req, circleId)) return json(401, { error: 'auth_required' });
    return json(200, { notes: await listNotes(circleId) });
  }
  if (url.pathname === '/notes' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req));
      const { circleId = 'home', userId, name, audio, mime, durationSec } = body;
      // circleId 在 body 里,只能解析后再校验;凭据必须对得上「这个」圈子,
      // 否则拿 home 的口令就能往 work 圈塞便签并触发圈内广播
      if (!httpAuthOk(req, circleId)) return json(401, { error: 'auth_required' });
      if (!userId || !audio || typeof audio !== 'string') return json(400, { error: 'bad_note' });
      if (audio.length > NOTE_MAX_BYTES) return json(413, { error: 'too_large' });
      if ((durationSec ?? 0) > NOTE_MAX_SECONDS + 1) return json(400, { error: 'too_long' });
      const note = {
        id: crypto.randomUUID(),
        circleId,
        userId,
        name: String(name ?? '圈友').slice(0, 24),
        audio,
        mime: String(mime ?? 'audio/aac'),
        durationSec: Math.min(Number(durationSec) || 0, NOTE_MAX_SECONDS),
        createdAt: Date.now(),
      };
      await saveNote(circleId, note);
      // 通知圈内成员有新便签(在房的人可即时听)
      broadcast(circleId, { t: 'note_added', circleId, noteId: note.id, name: note.name, durationSec: note.durationSec });
      return json(201, { id: note.id });
    } catch {
      return json(400, { error: 'bad_json' });
    }
  }
  if (url.pathname.startsWith('/notes/') && req.method === 'DELETE') {
    const id = url.pathname.slice('/notes/'.length);
    const circleId = url.searchParams.get('circleId') ?? 'home';
    if (!httpAuthOk(req, circleId)) return json(401, { error: 'auth_required' });
    await deleteNote(circleId, id);
    return json(200, { ok: true });
  }

  res.writeHead(404);
  res.end();
});

// WS 挂 / 与 /ws 两条路径(后者供反代按路径分流,见 deploy/)
const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  let pathname = '/';
  try {
    pathname = new URL(req.url, 'http://x').pathname;
  } catch { /* 按默认处理 */ }
  if (pathname === '/' || pathname === '/ws') {
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  } else {
    socket.destroy();
  }
});
wss.on('connection', handleConnection);

// 心跳:30s 无 pong 判定死连接,清理 presence
// 顺带扫过期 nonce 与失效封禁记录 —— 复用这一个 timer,不再另起定时器
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws._laresAlive === false) { ws.terminate(); continue; }
    ws._laresAlive = false;
    ws.ping();
  }
  sweepNonces();
  sweepRateLimits();
  sweepStaleRecordings();
}, 30_000);
wss.on('connection', (ws) => {
  ws._laresAlive = true;
  ws.on('pong', () => { ws._laresAlive = true; });
});
wss.on('close', () => clearInterval(heartbeat));

server.listen(PORT, async () => {
  await loadSettings();
  console.log(`[lares] 信令服务已启动  ws://0.0.0.0:${PORT}`);
  console.log(`[lares] RTC: ${RTC_CONFIGURED ? `LiveKit 已配置 (${LIVEKIT_URL})` : '未配置(仅 presence,设置 LIVEKIT_URL/API_KEY/API_SECRET 启用)'}`);
  if (AUTH_REQUIRED) {
    console.log(`[auth] 鉴权已启用,模式:${AUTH_MODE_LIST.join(',')}`);
    if (AUTH_MODES.has('circle')) {
      const n = Object.keys(CIRCLE_PASSCODES).length;
      console.log(`[auth] 圈子口令:${n > 0 ? `${n} 个按圈覆盖` : '仅全站口令'}${CIRCLE_PASSCODE ? '(含全站兜底)' : ''}`);
    }
    if (!ALLOWED_ORIGIN) console.log('[auth] 提示:未设 LARES_ALLOWED_ORIGIN,CORS 仍为 *');
  } else {
    console.warn('[auth] ⚠ 警告:鉴权已关闭(LARES_AUTH_MODE=none)。任何人都能连接、冒用任意 userId、进任意圈子并拿到 LiveKit token。');
    console.warn('[auth] ⚠ 仅限本机开发使用。公网部署请设置 LARES_AUTH_MODE=token 或 circle。');
  }
});
