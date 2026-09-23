// Lares 炉灵 — presence 信令服务
// 职责:维护「谁在哪个圈子房间」「轻状态」实时广播,并为进房成员签发 LiveKit token。
// MVP:内存态,单进程。后续按设计.md §4.2 演进为 Redis Pub/Sub 集群。

import http from 'node:http';
import crypto from 'node:crypto';
import { mkdir, readdir, readFile, writeFile, unlink, rename } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
// 纯 WASM 的 Argon2(无原生编译):node:22-alpine 镜像里没有 crypto.argon2(那是 Node 24.7+ 才有),
// 而原生 argon2 包在 alpine/musl 上要现编,镜像构建会变脆。
import { argon2id } from 'hash-wasm';
import { createApnsSender, isInvalidTokenResponse } from './apns.js';

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
// ── 圈子注册(客户端自建圈)的防滥用上限 ──
// 注册是「未登录即可写盘」的入口,必须有闸:按 IP 每小时上限 + 全站总量上限。
const CIRCLE_CREATE_PER_HOUR = Number(process.env.LARES_CIRCLE_CREATE_PER_HOUR ?? 5);
const MAX_CIRCLES = Number(process.env.LARES_MAX_CIRCLES ?? 500);
// 反代信任:auto(默认)= 对端是本机/内网地址时才信 X-Forwarded-For 最右一项;
// 1 = 总是信;0 = 从不信。部署在 Caddy 后面时对端恒为 Caddy 的内网地址,
// 不信 XFF 的话所有人共用一个 IP —— 一个人输错十次口令就把全家都封了,
// 注册限流也会变成「全站每小时 5 个」。
const TRUST_PROXY = String(process.env.LARES_TRUST_PROXY ?? 'auto').trim().toLowerCase();

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
  if (!Number.isInteger(CIRCLE_CREATE_PER_HOUR) || CIRCLE_CREATE_PER_HOUR < 0) fatal('LARES_CIRCLE_CREATE_PER_HOUR 必须是非负整数(0 = 关闭注册)');
  if (!Number.isInteger(MAX_CIRCLES) || MAX_CIRCLES < 0) fatal('LARES_MAX_CIRCLES 必须是非负整数');
  if (!['auto', '0', '1', 'true', 'false'].includes(TRUST_PROXY)) fatal('LARES_TRUST_PROXY 只能是 auto / 0 / 1');
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

function normIp(raw) {
  const s = String(raw ?? 'unknown').trim();
  return s.startsWith('::ffff:') ? s.slice(7) : s; // 归一 IPv4-mapped
}

/// 对端是不是「本机 / 内网」:只有这类对端才可能是我们自己的反代(Caddy 在 docker 内网)。
function isPrivatePeer(ip) {
  if (ip === '::1' || ip.startsWith('127.')) return true;
  if (ip.startsWith('10.') || ip.startsWith('192.168.')) return true;
  const m = /^172\.(\d+)\./.exec(ip);
  if (m && Number(m[1]) >= 16 && Number(m[1]) <= 31) return true;
  const lower = ip.toLowerCase();
  return lower.startsWith('fc') || lower.startsWith('fd') || lower.startsWith('fe80:');
}

function clientIp(req) {
  // 默认只认 socket 对端地址:X-Forwarded-For 可被客户端随手伪造。
  // 但部署在 Caddy 后面时对端恒为 Caddy —— 不看 XFF 的话全站共用一个 IP,
  // 失败封禁会连坐所有人、注册限流会变成全站共享。
  // 所以:对端是内网(= 我们自己的反代)时,取 XFF **最右**一项。
  // 最右一项是反代自己追加的真实对端;左边的都可能是客户端伪造的,一律不看。
  const peer = normIp(req?.socket?.remoteAddress);
  const trust = TRUST_PROXY === '1' || TRUST_PROXY === 'true'
    || (TRUST_PROXY === 'auto' && isPrivatePeer(peer));
  const xff = req?.headers?.['x-forwarded-for'];
  if (trust && typeof xff === 'string' && xff) {
    const parts = xff.split(',').map((s) => s.trim()).filter(Boolean);
    const last = parts[parts.length - 1];
    if (last) return normIp(last);
  }
  return peer;
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
async function verifyAuth(auth, userId, sessionNonce) {
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
  if (!circleId || circleId.length > 128) return { ok: false, reason: 'auth_failed' };
  // v1:proof = HMAC(口令, msg)   —— 老客户端(TestFlight build 36)只会这个
  // v2:proof = HMAC(verifier, msg),verifier = Argon2id(口令, "lares-auth-v2:"+circleId)
  const v = auth.v === 2 ? 2 : 1;
  const body = `${sessionNonce}:${userId}:${circleId}`;
  const proof = auth.proof.toLowerCase();
  const register = auth.register && typeof auth.register === 'object' ? auth.register : null;

  // 1) env 圈(home/review 等):v1 / v2 都收 —— v2 的 verifier 从明文现算。
  //    绝不允许用 register 覆盖它。
  if (isEnvCircle(circleId)) {
    if (register) return { ok: false, reason: 'circle_exists' };
    const pass = CIRCLE_PASSCODES[circleId];
    const key = v === 2 ? await verifierFromPasscode(pass, circleId) : pass;
    return safeEqualStr(proof, hmacHex(key, body))
      ? { ok: true, mode: 'circle', circleId, registered: false }
      : { ok: false, reason: 'auth_failed' };
  }

  // 2) 注册圈(含墓碑):只收 v2。服务器手里只有 verifier,算不出 v1 证明 ——
  //    这不是限制而是目标:不持有口令才保住 E2EE。
  if (Object.prototype.hasOwnProperty.call(circleRegistry, circleId)) {
    if (register) return { ok: false, reason: 'circle_exists' };
    const rec = circleRegistry[circleId];
    if (v !== 2 || !safeEqualStr(proof, hmacHex(rec.verifier, body))) return { ok: false, reason: 'auth_failed' };
    // 墓碑:证明对得上才告诉你「解散了」,对不上照常说口令不对 —— 不向外人确认这个圈存在过
    if (rec.deletedAt) return { ok: false, reason: 'circle_deleted' };
    return { ok: true, mode: 'circle', circleId, registered: true };
  }

  // 3) 登记新圈:只有显式带 register 才会创建 —— 永不「撞上一个没见过的 id 就顺手建了」。
  if (register) {
    const verifier = typeof register.verifier === 'string' ? register.verifier.toLowerCase() : '';
    // 圈主钥匙由**客户端**生成并先落进本机安全存储,这里只收它的 sha256。
    // 为什么不再由服务器生成:服务器生成就得靠 welcome 把明文送回去,welcome 一丢
    // (或落盘失败)圈子就永远没有圈主;客户端先存后报,重试时钥匙已在手。
    const ownerHash = typeof register.ownerHash === 'string' ? register.ownerHash.toLowerCase() : '';
    if (v !== 2 || !CIRCLE_ID_RE.test(circleId) || !HEX64_RE.test(verifier) || !HEX64_RE.test(ownerHash)) {
      return { ok: false, reason: 'register_invalid' };
    }
    // 证明必须由它自己声明的 verifier 算出:挡掉瞎填/截断的请求,也保证客户端算法一致
    if (!safeEqualStr(proof, hmacHex(verifier, body))) return { ok: false, reason: 'auth_failed' };
    return { ok: true, mode: 'circle', circleId, registered: true, pendingRegister: { verifier, ownerHash } };
  }

  // 4) 老行为:全站兜底口令(仅开发/自建场景会配),只认 v1/v2 明文派生
  const pass = passcodeFor(circleId);
  if (!pass) return { ok: false, reason: 'auth_failed' };
  // 全站兜底口令对任意 circleId 都成立,每个新 id 都要现算一次 Argon2 ——
  // 只在自建/开发场景会配;失败照常计入 recordAuthFailure,10 次即封 IP。
  const key = v === 2 ? await verifierFromPasscode(pass, circleId) : pass;
  return safeEqualStr(proof, hmacHex(key, body))
    ? { ok: true, mode: 'circle', circleId, registered: false }
    : { ok: false, reason: 'auth_failed' };
}

/// 鉴权失败的 close code。客户端靠它区分「该弹口令框」与「别再连了」。
function closeCodeFor(reason) {
  switch (reason) {
    case 'circle_exists': return 4409;
    case 'circle_deleted': return 4410;
    case 'create_rate_limited':
    case 'circle_cap_reached':
    case 'register_disabled':
    case 'register_failed':
      return 4403;
    case 'register_invalid': return 4400;
    default: return 4401;
  }
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

// ── 圈子注册表(客户端自建圈)─────────────────────────────────────────────
//
// 为什么要有它:env 里的 LARES_CIRCLE_PASSCODES 只能由运维改,客户端「新建圈子」
// 生成的 id 服务器一概不认,于是新圈必然 4401。注册表让圈子由第一个人自助登记。
//
// 为什么只存 verifier 不存口令:E2EE 密钥 = Argon2id(口令, circleId)。
// 服务器手里有明文口令,就等于手里有全圈的媒体密钥 —— 端到端加密形同虚设。
// verifier = Argon2id(口令, "lares-auth-v2:"+circleId) 足以验证 v2 证明,却推不出口令。
// 离线字典攻击仍然可能,但每猜一次要付一次 64 MiB 的 Argon2;
// 所以口令最少 8 位,默认给 4 个 BIP39 词(≈44 位)。
//
// 为什么圈主钥匙只存 sha256:钥匙是 32 字节随机数,sha256 就够了(没有字典可打),
// 磁盘泄露也拿不到可用的钥匙。
//
// 结构:{ [circleId]: { verifier, ownerHash, createdAt } }
//      解散后留墓碑 { verifier, deletedAt }:让离线的圈友下次连上时能听到「圈子已解散」
//      而不是一句莫名其妙的「口令不对」;也防止同一个 id 被别人抢注。
const CIRCLES_FILE = path.join(DATA_DIR, 'circles.json');
let circleRegistry = {};
const CIRCLE_ID_RE = /^c_[a-z0-9]{16,64}$/; // 新客户端:c_ + 128 位随机(base32 小写 26 位)
const HEX64_RE = /^[0-9a-f]{64}$/;

// 启动即开始读盘;hello / /health 都先等它 —— 否则重启后的头几个连接
// 会在注册表还没读进来时被当成「没见过的圈子」拒掉(或被允许重复注册)。
let registryReady = null;
function ensureRegistryLoaded() {
  registryReady ??= loadRegistry();
  return registryReady;
}

async function loadRegistry() {
  try {
    const parsed = JSON.parse(await readFile(CIRCLES_FILE, 'utf8'));
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) circleRegistry = parsed;
  } catch (e) {
    // 文件不存在 = 首次运行;存在却解析失败 = 盘坏了 —— 后者必须大声说,
    // 否则下一次写盘会用空表把所有圈子覆盖掉
    if (e?.code !== 'ENOENT') {
      console.error('[circles] circles.json 读取失败,拒绝启动以免覆盖:', e);
      process.exit(1);
    }
  }
}

// 串行化写盘:两次注册前后脚到达时,后一次的 rename 不能把前一次的内容盖回去。
let registryWriteChain = Promise.resolve();
function saveRegistry() {
  const snapshot = JSON.stringify(circleRegistry);
  const job = registryWriteChain.then(async () => {
    await mkdir(DATA_DIR, { recursive: true });
    // 原子写:先写临时文件再 rename。直接 writeFile 在写到一半时崩溃/断电,
    // 留下的是半截 JSON —— 下次启动整张注册表读不出来,所有自建圈一起消失。
    const tmp = `${CIRCLES_FILE}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
    await writeFile(tmp, snapshot, { mode: 0o600 });
    await rename(tmp, CIRCLES_FILE);
  });
  registryWriteChain = job.catch(() => {}); // 一次失败不拖垮后面的写
  return job;
}

function isEnvCircle(circleId) {
  const specific = CIRCLE_PASSCODES[circleId];
  return typeof specific === 'string' && specific.length > 0;
}

/// 活着的注册圈(墓碑不算)
function registeredCircle(circleId) {
  const rec = Object.prototype.hasOwnProperty.call(circleRegistry, circleId) ? circleRegistry[circleId] : null;
  return rec && !rec.deletedAt ? rec : null;
}

function liveCircleCount() {
  let n = 0;
  for (const rec of Object.values(circleRegistry)) if (!rec.deletedAt) n++;
  return n;
}

function sha256Hex(s) {
  return crypto.createHash('sha256').update(s, 'utf8').digest('hex');
}

/// 圈主钥匙校验:只对注册圈成立;env 圈没有圈主。
function ownerKeyOk(circleId, ownerKey) {
  const rec = registeredCircle(circleId);
  if (!rec || typeof ownerKey !== 'string' || !ownerKey || ownerKey.length > 256) return false;
  return safeEqualStr(sha256Hex(ownerKey), rec.ownerHash);
}

/// v2 的 verifier = hex(Argon2id(口令, salt = UTF-8("lares-auth-v2:"+circleId)))。
///
/// 为什么是 Argon2 而不是一次 HMAC:注册圈的服务器只存 verifier。verifier 若算得飞快,
/// 拿到 circles.json 的人(运维、备份、磁盘泄露)可以每秒上亿次离线猜口令,
/// 猜中口令就等于拿到 E2EE 密钥 —— 「服务器不持有口令」只剩一句空话。
/// 用和 E2EE 相同的代价(64 MiB / t=3 / p=1),每猜一次都得付一次 Argon2。
///
/// 盐前缀 `lares-auth-v2:` 刻意**不同于** E2EE 的盐(sha256("lares-e2ee-v2:"+id) 的前 16 字节):
/// 两者若相同,verifier 本身就是 E2EE 密钥,把它交给服务器比存明文口令还糟。
/// 参数与 app/lib/src/e2ee/e2ee_key.dart 的 kArgon2* 一致,改一个数所有注册圈都要重新登记。
const AUTH_VERIFIER_SALT_PREFIX = 'lares-auth-v2:';
const ARGON2_PARAMS = { parallelism: 1, iterations: 3, memorySize: 64 * 1024, hashLength: 32 };

async function argon2Verifier(passcode, circleId) {
  return argon2id({
    password: passcode, // 字符串 -> UTF-8,与 Dart 端 utf8.encode 对齐
    salt: `${AUTH_VERIFIER_SALT_PREFIX}${circleId}`,
    ...ARGON2_PARAMS,
    outputType: 'hex',
  });
}

// 服务器只在「手里有明文口令」的圈子上才需要现算 verifier:env 圈(home/review)与全站兜底口令。
// 每次握手算一次 = 每次 ~200ms + 64 MiB,所以缓存;env 圈启动时就预热好。
// 计算串行化:并发的 Argon2 每个都要 64 MiB,几十个同时来就是几个 G。
const verifierCache = new Map(); // `${circleId}\0${passcode}` -> hex
const VERIFIER_CACHE_MAX = 1000;
let verifierChain = Promise.resolve();
function verifierFromPasscode(passcode, circleId) {
  const k = `${circleId}\0${passcode}`;
  const hit = verifierCache.get(k);
  if (hit) return Promise.resolve(hit);
  const job = verifierChain.then(async () => {
    const again = verifierCache.get(k);
    if (again) return again;
    const v = await argon2Verifier(passcode, circleId);
    if (verifierCache.size >= VERIFIER_CACHE_MAX) verifierCache.delete(verifierCache.keys().next().value);
    verifierCache.set(k, v);
    return v;
  });
  verifierChain = job.catch(() => {});
  return job;
}
// 启动即预热 env 圈:第一个用新客户端连 home 的人不该多等那 200ms
const envVerifiersReady = Promise.all(
  Object.entries(CIRCLE_PASSCODES).map(([id, pass]) => verifierFromPasscode(pass, id)),
).catch((e) => { console.error('[auth] env 圈 verifier 预热失败:', e); });

// 注册限流:ip -> [成功注册的时间戳]。只数成功的 —— 失败的证明已经由
// recordAuthFailure 计入暴力破解封禁,不重复惩罚。
const CREATE_WINDOW_MS = 60 * 60_000;
const createLog = new Map();

function createAllowed(ip) {
  const now = Date.now();
  const list = (createLog.get(ip) ?? []).filter((t) => now - t < CREATE_WINDOW_MS);
  if (list.length) createLog.set(ip, list); else createLog.delete(ip);
  return list.length < CIRCLE_CREATE_PER_HOUR;
}

function recordCreate(ip) {
  while (createLog.size >= MAP_CAP && !createLog.has(ip)) createLog.delete(createLog.keys().next().value);
  const list = createLog.get(ip) ?? [];
  list.push(Date.now());
  createLog.set(ip, list);
}

function sweepCreateLog() {
  const now = Date.now();
  for (const [ip, list] of createLog) {
    if (!list.some((t) => now - t < CREATE_WINDOW_MS)) createLog.delete(ip);
  }
}

/// 该圈子的圈级设置(推给客户端的那份)。注册圈与 env 圈一视同仁地带出来,
/// 客户端据 registered 决定要不要露圈主控件。
function circleInfo(circleId) {
  const s = circleSettings[circleId] ?? {};
  return {
    id: circleId,
    registered: Boolean(registeredCircle(circleId)),
    knockRequired: s.knockRequired === true,
    // e2ee:null = 圈子没有统一规定(老圈 / env 圈),客户端沿用本机开关;
    // true/false = 圈主定死了,所有人照此进房。
    e2ee: typeof s.e2ee === 'boolean' ? s.e2ee : null,
  };
}

/// 把连接到某圈子的所有会话找出来(被钉在这个圈上的,或此刻在这个圈房间里的)。
function sessionsOfCircle(circleId) {
  const out = [];
  for (const ws of wss.clients) {
    const s = ws._laresSession;
    if (!s) continue;
    if ((s.authMode === 'circle' && s.authCircleId === circleId) || s.circleId === circleId) out.push(ws);
  }
  return out;
}

// ── 媒体侧驱逐(尽力而为)──
// 信令里的 kick 只是「请对方自己退」:对方手里的 LiveKit token 有效期 2 小时,
// 一个不听话(或被改过)的客户端可以继续待在媒体房里听。换口令/解散是真驱逐,
// 必须同时在 LiveKit 那边把人移出去。失败只记日志:信令侧的驱逐照样生效,
// 且 E2EE 圈换口令后旧密钥解不开新媒体。
const LIVEKIT_API_URL = process.env.LIVEKIT_API_URL || LIVEKIT_URL;
let roomService = null;
function roomSvc() {
  if (!RTC_CONFIGURED) return null;
  roomService ??= new RoomServiceClient(LIVEKIT_API_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);
  return roomService;
}

// 调用方一律不 await(fire-and-forget),信令侧的驱逐先完成;
// 所以这里**任何**异常都必须就地吞掉 —— 包括构造客户端时的同步异常,
// 否则就是一个未处理的 rejection,Node 默认会让整个进程退出。
async function evictMedia(circleId, { keep = null, only = null } = {}) {
  try {
    const svc = roomSvc();
    if (!svc) return;
    const parts = await svc.listParticipants(circleId);
    for (const p of parts) {
      if (keep && p.identity === keep) continue;
      if (only && p.identity !== only) continue;
      await svc.removeParticipant(circleId, p.identity).catch(() => {});
    }
  } catch (e) {
    console.error('[livekit] 媒体侧驱逐失败(信令侧已生效):', e?.message ?? e);
  }
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
    // 平台与延迟:多人直连时用来选主机(桌面端优先、延迟低者优先)。
    // 延迟由客户端自己测好报上来 —— 服务器不主动测,
    // 它只是把这个数转给同房的其他人。
    ...(member.platform ? { platform: member.platform } : {}),
    ...(typeof member.latencyMs === 'number'
      ? { latencyMs: member.latencyMs }
      : {}),
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
    // 新增字段,老客户端忽略
    registered: Boolean(registeredCircle(circleId)),
    e2ee: typeof circleSettings[circleId]?.e2ee === 'boolean' ? circleSettings[circleId].e2ee : null,
  };
}

/// 圈级设置变了:推给所有有权看这个圈的连接(不论在不在房里)。
/// 为什么不只靠 circle_summary:摘要只对「有人在」的圈子下发,空圈改设置时没人收得到。
function broadcastCircleSettings(circleId) {
  const data = JSON.stringify({ t: 'circle_settings', circle: circleInfo(circleId) });
  for (const ws of lobby) {
    if (ws._laresSession && !circleAllowed(ws._laresSession, circleId)) continue;
    if (ws.readyState === ws.OPEN) ws.send(data);
  }
}

/// 该连接对这个圈有没有圈主权:握手时带过正确的钥匙,或本条消息带了。
function isOwnerFor(session, circleId, ownerKey) {
  if (!registeredCircle(circleId)) return false;
  if (session.isOwner && session.authCircleId === circleId) return true;
  return ownerKeyOk(circleId, ownerKey);
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

// ── iOS 推送(APNs)──────────────────────────────────────────────────────
//
// 两种事件会推:
//   active —— 一个空圈子来了第一个人(「X 在圈里」)。只在「空 → 有人」那一刻推,
//             房里已经有人时再进人不推:那时想来的人早就被第一条叫过了。
//   reach  —— 有人点了「去找 ta」,推给被找的那个人自己的设备。
//
// 订阅表按设备 token 存:{ [token]: { userId, deviceId, env, lang, circles:{[id]:{name,muted}}, updatedAt } }
// 圈名为什么由客户端上报并存下来:服务器不知道圈子叫什么(圈名只在客户端),
// 而通知标题要显示圈名。E2EE 圈则一个名字都不放(见 pushContent)。
//
// 纪律:推送永远是「顺手做一下」—— 消息处理路径里绝不 await APNs,任何异常就地吞掉。
// 推送失败的代价是少一条通知;把信令卡住或进程崩掉的代价是所有人断线。
const apns = createApnsSender({ env: process.env, log: console });
// 客户端用来连信令的 wss 地址,放进推送里让 App 从通知直接连对服务器(邀请链接由客户端拼,服务端没有可复用的)
const PUBLIC_URL = String(process.env.LARES_PUBLIC_URL ?? '').trim();
const PUSH_FILE = path.join(DATA_DIR, 'push_subscriptions.json');
const PUSH_TOKEN_RE = /^[0-9a-f]{64,200}$/i;
const PUSH_MAX_CIRCLES = 200;
// 订阅表是「握过手就能写盘」的入口:给总量一个顶,防止有人用随机 token 灌满磁盘
const PUSH_MAX_TOKENS = Number(process.env.LARES_PUSH_MAX_TOKENS ?? 5000);
// 节流窗口:active 同一 (圈, 设备) 10 分钟一条 —— 有人进进出出时不能每次都响;
// reach 同一 (被找者, 找人者) 60 秒一条 —— 防连点轰炸。测试用 env 调小。
const PUSH_ACTIVE_THROTTLE_MS = Number(process.env.LARES_PUSH_ACTIVE_THROTTLE_MS ?? 10 * 60_000);
const PUSH_REACH_THROTTLE_MS = Number(process.env.LARES_PUSH_REACH_THROTTLE_MS ?? 60_000);
let pushSubs = {};
const pushActiveSent = new Map(); // `${circleId}\0${token}` -> 上次推送时间
const pushReachSent = new Map(); // `${targetUserId}\0${callerUserId}` -> 上次推送时间

// 与注册表同理:hello 前先把订阅表读进来,否则重启后头几个 push_register
// 会在空表上登记,随后写盘把磁盘上的其它订阅全盖掉。
let pushReady = null;
function ensurePushLoaded() {
  pushReady ??= loadPushSubs();
  return pushReady;
}

async function loadPushSubs() {
  let raw;
  try {
    raw = await readFile(PUSH_FILE, 'utf8');
  } catch (e) {
    if (e?.code !== 'ENOENT') console.error('[push] push_subscriptions.json 读取失败,本次以空表启动:', e);
    return;
  }
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('不是 JSON 对象');
    const clean = {};
    for (const [token, e] of Object.entries(parsed)) {
      if (!PUSH_TOKEN_RE.test(token) || !e || typeof e !== 'object' || typeof e.userId !== 'string') continue;
      clean[token] = {
        userId: e.userId,
        deviceId: typeof e.deviceId === 'string' ? e.deviceId : '',
        env: e.env === 'sandbox' ? 'sandbox' : 'production',
        lang: e.lang === 'zh' ? 'zh' : 'en',
        circles: e.circles && typeof e.circles === 'object' ? e.circles : {},
        updatedAt: Number(e.updatedAt) || 0,
      };
    }
    pushSubs = clean;
  } catch (e) {
    // 与 circles.json 不同,这里**不拒绝启动**:订阅表丢了的代价只是少几条通知,
    // 而且客户端每次 welcome 后都会重新 push_register,几分钟内就自愈。
    // 但也不能默默用空表覆盖 —— 把坏文件挪到一边留作排查,再从空表开始。
    const aside = `${PUSH_FILE}.corrupt-${Date.now()}`;
    console.error(`[push] push_subscriptions.json 解析失败,已改名为 ${path.basename(aside)} 并以空表启动:`, e);
    try { await rename(PUSH_FILE, aside); } catch (e2) { console.error('[push] 坏文件改名失败:', e2); }
  }
}

// 串行化 + 原子写,与 saveRegistry 同一套理由(见那边的注释)
let pushWriteChain = Promise.resolve();
function savePushSubs() {
  const snapshot = JSON.stringify(pushSubs);
  const job = pushWriteChain.then(async () => {
    await mkdir(DATA_DIR, { recursive: true });
    const tmp = `${PUSH_FILE}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
    await writeFile(tmp, snapshot, { mode: 0o600 });
    await rename(tmp, PUSH_FILE);
  });
  pushWriteChain = job.catch(() => {});
  // 调用方都不 await:写盘失败只记日志,内存里的订阅照常生效
  job.catch((e) => console.error('[push] 订阅表写盘失败:', e));
  return job;
}

function isTombstoned(circleId) {
  return Object.prototype.hasOwnProperty.call(circleRegistry, circleId) && Boolean(circleRegistry[circleId]?.deletedAt);
}

/// 从所有订阅里摘掉某个圈子(换口令 / 解散之后)。
/// 换口令:旧订阅是凭旧口令攒下的,新口令没证明过就不该再收这个圈的动静;
/// 客户端拿到新口令重连后会自己再登记回来。
function dropCircleFromPush(circleId) {
  let changed = false;
  for (const entry of Object.values(pushSubs)) {
    if (Object.prototype.hasOwnProperty.call(entry.circles, circleId)) {
      delete entry.circles[circleId];
      changed = true;
    }
  }
  for (const k of pushActiveSent.keys()) if (k.startsWith(`${circleId}\0`)) pushActiveSent.delete(k);
  if (changed) savePushSubs();
}

function sweepPushThrottles() {
  const now = Date.now();
  for (const [k, t] of pushActiveSent) if (now - t >= PUSH_ACTIVE_THROTTLE_MS) pushActiveSent.delete(k);
  for (const [k, t] of pushReachSent) if (now - t >= PUSH_REACH_THROTTLE_MS) pushReachSent.delete(k);
}

function pushRegisteredMsg(entry, rejected = []) {
  return { t: 'push_registered', circles: Object.keys(entry?.circles ?? {}), rejected };
}

/// push_register 的核心。返回要回给客户端的消息。
///
/// 授权论证:circle 模式的连接只证明了**一个**圈子的口令,所以一条连接只能往订阅里
/// **新增**它证明过的那个圈。但同一台设备会在不同时刻、凭不同口令连上不同的圈 ——
/// 订阅是按 token 攒起来的。已经在订阅里的圈子,之前某次连接已经证明过口令,
/// 这次允许改名/改静音(持有 token = 就是那台设备);不在订阅里、这条连接又没证明过的,拒绝。
/// 客户端的列表是它本机的**完整**圈子清单:订阅里有、清单里没有的 = 用户删了,摘掉。
function handlePushRegister(session, msg) {
  if (msg.provider !== 'apns') return { t: 'push_error', reason: 'bad_provider' };
  if (typeof msg.token !== 'string' || !PUSH_TOKEN_RE.test(msg.token)) return { t: 'push_error', reason: 'bad_token' };
  if (msg.env !== 'sandbox' && msg.env !== 'production') return { t: 'push_error', reason: 'bad_env' };
  const token = msg.token.toLowerCase();
  const lang = msg.lang === 'zh' ? 'zh' : 'en';
  const list = Array.isArray(msg.circles) ? msg.circles.slice(0, PUSH_MAX_CIRCLES) : [];

  const existing = pushSubs[token];
  if (!existing && Object.keys(pushSubs).length >= PUSH_MAX_TOKENS) {
    console.error(`[push] 订阅表已满(${PUSH_MAX_TOKENS}),拒绝新 token`);
    return { t: 'push_error', reason: 'capacity' };
  }
  // token 换了主人(同一台设备换了身份):旧身份攒下的圈子不能继承
  const prev = existing && existing.userId === session.userId ? existing.circles : {};
  const next = {};
  const rejected = [];
  for (const c of list) {
    if (!c || typeof c !== 'object') continue;
    const id = c.circleId;
    if (typeof id !== 'string' || !id || id.length > 128) continue;
    if (Object.prototype.hasOwnProperty.call(next, id)) continue;
    const already = Object.prototype.hasOwnProperty.call(prev, id);
    if (isTombstoned(id) || (!already && !circleAllowed(session, id))) {
      if (!rejected.includes(id)) rejected.push(id);
      continue;
    }
    next[id] = {
      name: typeof c.name === 'string' ? c.name.trim().slice(0, 64) : '',
      muted: c.muted === true,
    };
  }
  // 同一台设备(userId + deviceId)的 token 轮换了:删掉旧 token,否则一台手机收两条
  if (session.deviceId) {
    for (const [t, e] of Object.entries(pushSubs)) {
      if (t !== token && e.userId === session.userId && e.deviceId === session.deviceId) delete pushSubs[t];
    }
  }
  const entry = {
    userId: session.userId,
    deviceId: session.deviceId ?? '',
    env: msg.env,
    lang,
    circles: next,
    updatedAt: Date.now(),
  };
  pushSubs[token] = entry;
  session.pushToken = token;
  savePushSubs();
  return pushRegisteredMsg(entry, rejected);
}

/// 推送文案。E2EE 圈:人名、圈名一个都不放 —— 通知内容会经过 Apple 的服务器、
/// 显示在锁屏上;用户选了端到端加密,就不该让「谁在哪个圈」从这条旁路漏出去。
function pushContent(entry, circleId, kind, causerName) {
  const zh = entry.lang === 'zh';
  if (circleSettings[circleId]?.e2ee === true) {
    return { title: 'Lares', body: zh ? '有人在你的圈子里' : 'Someone is in your circle' };
  }
  const title = entry.circles[circleId]?.name || 'Lares';
  const who = (typeof causerName === 'string' && causerName.trim()) || (zh ? '有人' : 'Someone');
  const body = kind === 'reach'
    ? (zh ? `${who} 在叫你` : `${who} is calling you`)
    : (zh ? `${who} 在圈里` : `${who} is in the circle`);
  return { title, body };
}

function sendPush(token, entry, circleId, kind, causerName) {
  const { title, body } = pushContent(entry, circleId, kind, causerName);
  const payload = {
    aps: {
      alert: { title, body },
      sound: 'default',
      category: 'LARES_JOIN',
      'thread-id': circleId,
      // 「有人在圈里」过几分钟就没意义了,值得打断专注模式
      'interruption-level': 'time-sensitive',
    },
    lares: { circleId, ...(PUBLIC_URL ? { server: PUBLIC_URL } : {}), kind },
  };
  const headers = {
    'apns-push-type': 'alert',
    'apns-priority': '10',
    // 同一个圈的通知互相覆盖,锁屏上不堆一串
    'apns-collapse-id': circleId,
    // 一小时后还没送到就别送了:过时的「X 在圈里」只会骗人白跑一趟
    'apns-expiration': String(Math.floor(Date.now() / 1000) + 3600),
  };
  apns.send(token, entry.env, payload, headers).then((r) => {
    if (r.status === 200) return;
    if (isInvalidTokenResponse(r)) {
      // App 卸载了 / token 作废:删订阅,不然每次都白推一次
      if (pushSubs[token] === entry) {
        delete pushSubs[token];
        savePushSubs();
      }
      console.log(`[push] token 失效(${r.status} ${r.reason ?? ''}),已删除订阅`);
      return;
    }
    console.error(`[push] 推送失败:${r.status} ${r.reason ?? ''}`);
  }).catch((e) => console.error('[push] 推送异常:', e));
}

/// 候选接收者:订阅了该圈、没静音、不是触发者本人、此刻不在这个房间里。
function pushRecipients(circleId, causerUserId) {
  const room = circles.get(circleId);
  const out = [];
  for (const [token, entry] of Object.entries(pushSubs)) {
    const sub = entry.circles[circleId];
    if (!sub || sub.muted) continue;
    if (entry.userId === causerUserId) continue;
    if (room?.has(entry.userId)) continue; // 人就在房里,不用叫
    out.push([token, entry]);
  }
  return out;
}

/// 空圈来了第一个人。调用方已经把他放进房间了(所以「在房里」过滤天然排除他自己)。
function pushRoomActive(circleId, session) {
  try {
    if (!apns.enabled) return;
    const now = Date.now();
    for (const [token, entry] of pushRecipients(circleId, session.userId)) {
      const k = `${circleId}\0${token}`;
      const last = pushActiveSent.get(k);
      if (last !== undefined && now - last < PUSH_ACTIVE_THROTTLE_MS) continue;
      pushActiveSent.set(k, now);
      sendPush(token, entry, circleId, 'active', session.name);
    }
  } catch (e) {
    console.error('[push] active 推送出错:', e);
  }
}

/// 「去找 ta」:只推被找者自己的设备。在 joinCircle 之前调用,
/// 此时被找者还不在房里,不需要「在房里」过滤。
function pushReach(circleId, targetUserId, caller) {
  try {
    if (!apns.enabled) return;
    if (targetUserId === caller.userId) return;
    const k = `${targetUserId}\0${caller.userId}`;
    const now = Date.now();
    const last = pushReachSent.get(k);
    if (last !== undefined && now - last < PUSH_REACH_THROTTLE_MS) return;
    let sent = false;
    for (const [token, entry] of Object.entries(pushSubs)) {
      if (entry.userId !== targetUserId) continue;
      const sub = entry.circles[circleId];
      if (!sub || sub.muted) continue;
      sendPush(token, entry, circleId, 'reach', caller.name);
      sent = true;
    }
    if (sent) pushReachSent.set(k, now);
  } catch (e) {
    console.error('[push] reach 推送出错:', e);
  }
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
        // 订阅表先读进来(通常早已就绪,只是重启后头几个连接要等一下)
        await ensurePushLoaded();
        // 鉴权闸门:先验证再落任何会话状态,失败即断,用 4401 让客户端能区分
        // 「口令错」(该弹输入框)与「网络抖动」(该静默重连)
        if (AUTH_REQUIRED) {
          if (isRateLimited(ip)) {
            send(ws, { t: 'error', message: 'rate_limited' });
            return ws.close(4429, 'rate_limited');
          }
          await ensureRegistryLoaded();
          const r = await verifyAuth(msg.auth, msg.userId, session.nonce);
          if (r.ok && r.pendingRegister) {
            // 登记新圈:证明已验过,再过两道闸 —— 按 IP 限流 + 全站总量。
            let reason = null;
            if (CIRCLE_CREATE_PER_HOUR === 0) reason = 'register_disabled';
            else if (liveCircleCount() >= MAX_CIRCLES) reason = 'circle_cap_reached';
            else if (!createAllowed(ip)) reason = 'create_rate_limited';
            if (reason) {
              send(ws, { t: 'error', message: reason });
              return ws.close(closeCodeFor(reason), reason);
            }
            // 同一个 id 两条注册前后脚到达:await 之前再查一次,先到先得,绝不覆盖
            if (Object.prototype.hasOwnProperty.call(circleRegistry, r.circleId) || isEnvCircle(r.circleId)) {
              send(ws, { t: 'error', message: 'circle_exists' });
              return ws.close(4409, 'circle_exists');
            }
            circleRegistry[r.circleId] = {
              verifier: r.pendingRegister.verifier,
              ownerHash: r.pendingRegister.ownerHash,
              createdAt: Date.now(),
            };
            try {
              await saveRegistry();
            } catch (e) {
              // 落不了盘就当没建:否则重启后这个圈凭空消失,而圈主以为建好了
              delete circleRegistry[r.circleId];
              console.error('[circles] 注册写盘失败:', e);
              send(ws, { t: 'error', message: 'register_failed' });
              return ws.close(4403, 'register_failed');
            }
            recordCreate(ip);
            // 服务器从头到尾没见过钥匙明文;登记者就是圈主(register 里带着 ownerHash)
            session.createdCircle = true;
          } else if (!r.ok) {
            // 只有「证明不对」才计入暴力破解:circle_exists / 限流 / 解散 不是在猜口令
            if (r.reason === 'auth_failed' || r.reason === 'auth_required') recordAuthFailure(ip);
            send(ws, { t: 'error', message: r.reason });
            return ws.close(closeCodeFor(r.reason), r.reason);
          }
          session.authed = true;
          session.authMode = r.mode;
          session.authCircleId = r.circleId;
          session.circleRegistered = Boolean(r.registered);
          // 可选:带上圈主钥匙,回显 isOwner。钥匙不对不算鉴权失败 —— 只是「不是圈主」。
          session.isOwner = Boolean(session.createdCircle)
            || (r.registered && ownerKeyOk(r.circleId, msg.auth?.ownerKey));
          clearAuthFailures(ip); // 认证成功即销账,避免家人共用出口 IP 被连坐
        }
        session.userId = msg.userId;
        session.deviceId = typeof msg.deviceId === 'string' && msg.deviceId ? msg.deviceId : crypto.randomUUID();
        session.name = typeof msg.name === 'string' && msg.name ? msg.name.slice(0, 24) : '圈友';
        session.platform = typeof msg.platform === 'string' ? msg.platform : 'unknown';
        // circle 字段是新增的嵌套对象:老客户端(build 36)不认识,原样忽略。
        const welcome = {
          t: 'welcome', userId: session.userId, deviceId: session.deviceId,
          rtcConfigured: RTC_CONFIGURED, authMode: session.authMode,
        };
        if (session.authMode === 'circle' && session.authCircleId) {
          welcome.circle = { ...circleInfo(session.authCircleId), isOwner: Boolean(session.isOwner) };
          // created 只是回执,不再下发 ownerKey(钥匙本来就是客户端自己生成的)
          if (session.createdCircle) {
            welcome.circle.created = true;
            delete session.createdCircle;
          }
        }
        send(ws, welcome);
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

      case 'latency': {
        // 客户端自己测好到服务器的往返,报上来给同房的人。
        // 服务器不主动测 —— 它只是把这个数转出去,供大家各自选主机。
        //
        // 为什么要广播:选主机必须**所有人算出同一个答案**,
        // 那就要求所有人看到同一份输入。
        if (!session.circleId || !session.userId) return;
        const ms = Number(msg.ms);
        // 负数或离谱的大数一律丢弃 —— 别让一个坏数据把选举结果带歪
        if (!Number.isFinite(ms) || ms < 0 || ms > 10000) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (!member) return;
        member.latencyMs = Math.round(ms);
        broadcast(session.circleId, {
          t: 'member_updated',
          circleId: session.circleId,
          member: memberSnapshot(member),
        });
        break;
      }

      case 'p2p_signal': {
        // 点对点直连的信令转发:把连接码原样交给同圈的另一个人。
        //
        // 服务器在这里**只当邮差** —— 它不解析、不存储 SDP,
        // 只检查「你俩确实在同一个圈子里」然后转发。
        // 媒体流随后在两台设备之间直接走,完全不经过这里。
        //
        // 这是「用服务器交换信令」那条路径。另一条是用户自己传连接码
        // (零服务器),两者产出的连接码格式完全一样。
        if (!session.userId || !session.circleId) return;
        const toId = typeof msg.to === 'string' ? msg.to : '';
        const payload = typeof msg.payload === 'string' ? msg.payload : '';
        if (!toId || !payload) return;
        // 体积上限:一份压缩后的连接码实测约 700 字节,给 8KB 余量。
        // 不设上限的话这条消息就成了免费的任意大小中继通道。
        if (payload.length > 8192) {
          return send(ws, { t: 'error', message: 'payload_too_large' });
        }
        // 授权:双方必须在同一个圈子里。少了这条检查,
        // 任何人都能借服务器给任意 userId 发任意内容。
        const circle = getCircle(session.circleId);
        const me = circle.get(session.userId);
        const target = circle.get(toId);
        if (!me || !me.devices.has(session.deviceId) || !target) return;
        for (const tws of target.devices.values()) {
          send(tws, {
            t: 'p2p_signal',
            from: session.userId,
            fromName: session.name,
            circleId: session.circleId,
            payload,
          });
        }
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
        // 推给被找者的设备:App 在后台/锁屏时,光靠 WS 上的 reached 他根本看不到。
        // 放在 joinCircle 之前 —— 进房之后他就「在房里」了。不 await。
        pushReach(circleId, targetId, session);
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
        // 注册圈:只有圈主能踢。env 圈(home/review)没有圈主,维持「圈内谁都能踢」。
        if (registeredCircle(circleId) && !isOwnerFor(session, circleId, msg.ownerKey)) {
          return send(ws, { t: 'owner_error', op: 'kick', circleId, reason: 'not_owner' });
        }
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
        if (registeredCircle(circleId)) {
          // 圈主踢人时媒体侧也清掉,不靠对方客户端自觉退房
          evictMedia(circleId, { only: targetId });
          send(ws, { t: 'owner_ok', op: 'kick', circleId });
        }
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
        // 注册圈的圈主钥匙本身就是凭据:允许从钉在别的圈上的连接改(圈子菜单里操作任意圈)
        const ownerByKey = registeredCircle(msg.circleId) && ownerKeyOk(msg.circleId, msg.ownerKey);
        if (!ownerByKey && !circleAllowed(session, msg.circleId)) return send(ws, { t: 'error', message: 'auth_scope' });
        if (registeredCircle(msg.circleId)) {
          // 注册圈:只有圈主能改,且不要求人在房里(圈主在圈子菜单里就能设)
          if (!isOwnerFor(session, msg.circleId, msg.ownerKey)) {
            return send(ws, { t: 'owner_error', op: 'knock_mode_set', circleId: msg.circleId, reason: 'not_owner' });
          }
        } else {
          // env 圈:圈内成员可改;空圈已鉴权者可预设(创建者场景)
          const circle = getCircle(msg.circleId);
          if (circle.size > 0) {
            const setter = circle.get(session.userId);
            if (!setter || !setter.devices.has(session.deviceId)) return;
          }
        }
        // 合并而不是整个替换:同一条记录里还住着 e2ee
        circleSettings[msg.circleId] = { ...(circleSettings[msg.circleId] ?? {}), knockRequired: msg.enabled };
        saveSettings();
        broadcastLobbySummary(msg.circleId);
        broadcastCircleSettings(msg.circleId);
        if (registeredCircle(msg.circleId)) send(ws, { t: 'owner_ok', op: 'knock_mode_set', circleId: msg.circleId });
        break;
      }

      // ── 圈主操作(仅注册圈)──────────────────────────────────────────
      // 共同纪律:消息里带 ownerKey,服务器 sha256 后定长比较;不认 userId ——
      // userId 是客户端自报的,谁都能冒充。
      case 'circle_passcode_set': {
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const verifier = typeof msg.verifier === 'string' ? msg.verifier.toLowerCase() : '';
        const fail = (reason) => send(ws, { t: 'owner_error', op: 'circle_passcode_set', circleId, reason });
        if (!session.userId) return fail('say_hello_first');
        if (!registeredCircle(circleId)) return fail('not_registered');
        if (!ownerKeyOk(circleId, msg.ownerKey)) return fail('not_owner');
        if (!HEX64_RE.test(verifier)) return fail('bad_verifier');
        const rec = circleRegistry[circleId];
        const prev = rec.verifier;
        rec.verifier = verifier;
        rec.rekeyedAt = Date.now();
        try {
          await saveRegistry();
        } catch (e) {
          rec.verifier = prev; // 没落盘就不算换成:否则重启后旧口令复活
          console.error('[circles] 换口令写盘失败:', e);
          return fail('save_failed');
        }
        send(ws, { t: 'owner_ok', op: 'circle_passcode_set', circleId });
        // 旧口令攒下的推送订阅一并作废:被请走的人不该还收到「X 在圈里」
        dropCircleFromPush(circleId);
        // 这才是真正的「请人离开」:userId 是自报的,踢人挡不住换个 id 再进;
        // 换口令后,没拿到新口令的人重连必然 4401,走既有的「请输入口令」流程。
        // 圈主自己的其他设备也会被断开 —— 它们手里也是旧口令,理应重输。
        for (const other of sessionsOfCircle(circleId)) {
          if (other === ws) continue;
          send(other, { t: 'circle_rekeyed', circleId });
          other.close(4401, 'circle_rekeyed');
        }
        // 媒体侧同步清人:只留圈主自己
        evictMedia(circleId, { keep: session.userId });
        break;
      }

      case 'circle_e2ee_set': {
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const fail = (reason) => send(ws, { t: 'owner_error', op: 'circle_e2ee_set', circleId, reason });
        if (!session.userId) return fail('say_hello_first');
        if (typeof msg.enabled !== 'boolean') return fail('bad_request');
        if (!registeredCircle(circleId)) return fail('not_registered');
        if (!ownerKeyOk(circleId, msg.ownerKey)) return fail('not_owner');
        circleSettings[circleId] = { ...(circleSettings[circleId] ?? {}), e2ee: msg.enabled };
        saveSettings();
        send(ws, { t: 'owner_ok', op: 'circle_e2ee_set', circleId });
        broadcastLobbySummary(circleId);
        broadcastCircleSettings(circleId);
        break;
      }

      case 'circle_delete': {
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const fail = (reason) => send(ws, { t: 'owner_error', op: 'circle_delete', circleId, reason });
        if (!session.userId) return fail('say_hello_first');
        if (!registeredCircle(circleId)) return fail('not_registered');
        if (!ownerKeyOk(circleId, msg.ownerKey)) return fail('not_owner');
        const prev = circleRegistry[circleId];
        // 留墓碑(只剩 verifier + 时间):记录本身的钥匙哈希删掉,圈主权随之作废
        circleRegistry[circleId] = { verifier: prev.verifier, deletedAt: Date.now() };
        try {
          await saveRegistry();
        } catch (e) {
          circleRegistry[circleId] = prev;
          console.error('[circles] 解散写盘失败:', e);
          return fail('save_failed');
        }
        delete circleSettings[circleId];
        saveSettings();
        pendingKnocks.delete(circleId);
        dropCircleFromPush(circleId);
        send(ws, { t: 'owner_ok', op: 'circle_delete', circleId });
        for (const other of sessionsOfCircle(circleId)) {
          send(other, { t: 'circle_deleted', circleId });
          // 包括圈主自己这条:它被钉在一个已不存在的圈上,留着也没法用
          other.close(4410, 'circle_deleted');
        }
        evictMedia(circleId);
        break;
      }

      case 'leave': {
        leaveCircle(ws, session);
        break;
      }

      // ── 推送订阅(iOS)──────────────────────────────────────────────
      // APNs 没配时照样收下订阅:客户端每次 welcome 后都会重新登记,
      // 存着不费事,运维哪天配上钥匙,已有订阅立即生效,不用等所有人重连。
      case 'push_register': {
        if (!session.userId || !session.authed) return send(ws, { t: 'push_error', reason: 'say_hello_first' });
        send(ws, handlePushRegister(session, msg));
        break;
      }

      case 'push_unregister': {
        if (!session.userId || !session.authed) return send(ws, { t: 'push_error', reason: 'say_hello_first' });
        const token = typeof msg.token === 'string' ? msg.token.toLowerCase() : '';
        // 只能注销自己的:否则拿到别人 token 的人能静默掉他的通知
        if (token && pushSubs[token]?.userId === session.userId) {
          delete pushSubs[token];
          savePushSubs();
        }
        if (session.pushToken === token) session.pushToken = null;
        send(ws, { t: 'push_unregistered' });
        break;
      }

      case 'push_mute': {
        if (!session.userId || !session.authed) return send(ws, { t: 'push_error', reason: 'say_hello_first' });
        const token = typeof msg.token === 'string' && msg.token ? msg.token.toLowerCase() : session.pushToken;
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const entry = token ? pushSubs[token] : null;
        // 只能改自己 token 上、已订阅的圈:静音不是新增订阅,但也不能借它探测别人的订阅
        if (!entry || entry.userId !== session.userId || !circleId
          || !Object.prototype.hasOwnProperty.call(entry.circles, circleId)) {
          return send(ws, { t: 'push_error', reason: 'not_subscribed' });
        }
        entry.circles[circleId].muted = msg.muted === true;
        entry.updatedAt = Date.now();
        savePushSubs();
        send(ws, pushRegisteredMsg(entry));
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
    // 平台可能变了(同一个人换设备进来),跟着刷新
    existing.platform = session.platform;
    send(ws, roomSnapshot(circleId));
  } else {
    // 空圈来了第一个人 = 「房间亮了」,要推给不在线的圈友。先记下,等人真进了房再推,
    // 这样「在房里不推」的过滤天然把他自己排除掉。
    const becameActive = circle.size === 0;
    const member = {
      userId: session.userId,
      name: session.name,
      status: 'free',
      // 选主机要用:桌面端优先扛转发(见客户端 host_election.dart)
      platform: session.platform,
      devices: new Map([[session.deviceId, ws]]),
    };
    circle.set(session.userId, member);
    broadcast(circleId, { t: 'member_joined', circleId, member: memberSnapshot(member) }, ws);
    send(ws, roomSnapshot(circleId));
    broadcastLobbySummary(circleId);
    if (becameActive) pushRoomActive(circleId, session);
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
    // 注册圈:服务器没有明文口令,只认 verifier 作 Bearer(与口令一样是静态凭据)
    const rec = registeredCircle(circleId);
    if (rec) return safeEqualStr(presented.toLowerCase(), rec.verifier);
    if (Object.prototype.hasOwnProperty.call(circleRegistry, circleId)) return false; // 墓碑
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
    await ensureRegistryLoaded();
    await envVerifiersReady; // 健康 = 真能验 v2 了(部署探针与测试都靠它)
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
  sweepCreateLog();
  sweepStaleRecordings();
  sweepPushThrottles();
}, 30_000);
wss.on('connection', (ws) => {
  ws._laresAlive = true;
  ws.on('pong', () => { ws._laresAlive = true; });
});
wss.on('close', () => clearInterval(heartbeat));

server.listen(PORT, async () => {
  await loadSettings();
  await ensureRegistryLoaded();
  await ensurePushLoaded();
  console.log(`[lares] 信令服务已启动  ws://0.0.0.0:${PORT}`);
  console.log(`[lares] RTC: ${RTC_CONFIGURED ? `LiveKit 已配置 (${LIVEKIT_URL})` : '未配置(仅 presence,设置 LIVEKIT_URL/API_KEY/API_SECRET 启用)'}`);
  if (apns.enabled) {
    console.log(`[push] APNs 已启用 (topic ${apns.topic}${process.env.LARES_APNS_HOST_OVERRIDE ? `,主机覆盖 ${process.env.LARES_APNS_HOST_OVERRIDE}` : ''}),订阅 ${Object.keys(pushSubs).length} 台设备`);
    if (!PUBLIC_URL) console.log('[push] 提示:未设 LARES_PUBLIC_URL,推送里不带服务器地址');
  } else if (apns.reason === 'not_configured') {
    console.log('[push] APNs 未配置,推送已禁用 (push disabled)');
  } else {
    console.log('[push] APNs 配置有误(见上方错误),推送已禁用 (push disabled)');
  }
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
