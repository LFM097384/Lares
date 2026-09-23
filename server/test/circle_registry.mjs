// 圈子注册 + 圈主权限 + v2 鉴权的端到端验证(打真实服务端进程)。
//
// 与 auth_interop.mjs 同一纪律:**不 import 服务端代码**,HMAC 按协议独立推导,
// 并硬编码一组与 Dart 端(app/test/auth_crosscheck_test.dart)完全相同的交叉向量 ——
// 两端各自对着同一个常量断言,任何一端算法漂移都会当场红。
//
// 用法:node test/circle_registry.mjs

import { spawn } from 'node:child_process';
import { createHmac, createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { WebSocket } from 'ws';
import { argon2id } from 'hash-wasm';

const PORT = 18950;
const ENV_PASS = 'home-pass-' + randomBytes(4).toString('hex');

let pass = 0;
let fail = 0;
function check(cond, name, detail) {
  if (cond) { console.log('  ✓', name); pass++; } else { console.log('  ✗', name, '—', JSON.stringify(detail)); fail++; }
}

// ── 独立推导 ──
const hmac = (k, m) => createHmac('sha256', k).update(m, 'utf8').digest('hex');
// verifier = hex(Argon2id(口令, salt=UTF-8("lares-auth-v2:"+circleId))),参数与 e2ee_key.dart 的 kArgon2* 一致。
// 独立实现(不 import 服务端),带缓存:每次 ~200ms,测试里同一组口令会反复用到。
const vCache = new Map();
const verifierOf = async (passcode, circleId) => {
  const k = `${circleId}\0${passcode}`;
  if (!vCache.has(k)) {
    vCache.set(k, await argon2id({
      password: passcode, salt: `lares-auth-v2:${circleId}`,
      parallelism: 1, iterations: 3, memorySize: 64 * 1024, hashLength: 32, outputType: 'hex',
    }));
  }
  return vCache.get(k);
};
const proofV1 = (nonce, uid, cid, passcode) => hmac(passcode, `${nonce}:${uid}:${cid}`);
const proofV2 = async (nonce, uid, cid, passcode) => hmac(await verifierOf(passcode, cid), `${nonce}:${uid}:${cid}`);
const newCircleId = () => {
  // c_ + 128 位随机,base32 小写(与客户端同形)
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  const bytes = randomBytes(16);
  let bits = 0, value = 0, out = '';
  for (const b of bytes) {
    value = (value << 8) | b; bits += 8;
    while (bits >= 5) { out += alphabet[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += alphabet[(value << (5 - bits)) & 31];
  return 'c_' + out;
};

// ── 交叉向量(Dart 端硬编码了同样的数)──
async function crossVectors() {
  const nonce = '0123456789abcdef0123456789abcdef';
  const v = await verifierOf('circle-pass', 'home');
  check(v === 'e2a3f817c8709b8ce38d5c605ae5e1b8934da36876d247fd78103b0e560ec683', '交叉向量:verifier(circle-pass, home)', v);
  const p = await proofV2(nonce, 'u_test', 'home', 'circle-pass');
  check(p === 'b446b3479a81e6bd9630b146f283ea16aae130bdc7930e28fd73fdf10c4f6dca', '交叉向量:v2 proof(home)', p);
  const cid = 'c_abcdefghijklmnopqrstuvwxyz';
  const v2 = await verifierOf('correct-horse-battery-staple', cid);
  check(v2 === '39b0bf40119e65e485309fdb411d78b9c0ce8b5b2bef94b171963006c8beffc9', '交叉向量:verifier(注册圈)', v2);
  const p2 = await proofV2(nonce, 'u_test', cid, 'correct-horse-battery-staple');
  check(p2 === 'dd598637d102f5082d253176f31f7bc35aa1a4fc35c24dbbd6d2442a713cd9d7', '交叉向量:v2 proof(注册圈)', p2);
}

function boot(port, dataDir, extra = {}) {
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'),
    env: {
      ...process.env,
      LARES_PORT: String(port),
      LARES_AUTH_MODE: 'circle',
      LARES_CIRCLE_PASSCODES: JSON.stringify({ home: ENV_PASS }),
      LARES_CIRCLE_PASSCODE: '',
      LARES_DATA_DIR: dataDir,
      LIVEKIT_URL: '', LIVEKIT_API_KEY: '', LIVEKIT_API_SECRET: '',
      ...extra,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => { if (process.env.DEBUG) process.stderr.write(d); });
  return child;
}

async function waitHealth(port, ms = 8000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return true; } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

async function stop(child) {
  if (child.exitCode !== null) return;
  const done = new Promise((r) => child.once('exit', r));
  child.kill();
  await done;
}

/// 建一条连接并完成握手。返回 { kind:'welcome'|'error'|'close', ws, msg, code, inbox, waitFor }
/// 成功时连接保持打开,供后续发圈主操作。
function connect(port, { userId = 'u_' + randomBytes(3).toString('hex'), auth, headers } = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers });
    const inbox = [];
    const waiters = [];
    let closeCode = null;
    let settled = false;
    const api = {
      ws, inbox, userId,
      get closeCode() { return closeCode; },
      send: (m) => ws.send(JSON.stringify(m)),
      waitFor(pred, ms = 3000) {
        const hit = inbox.find(pred);
        if (hit) return Promise.resolve(hit);
        return new Promise((res) => {
          const w = { pred, res, timer: setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); res(null); }, ms) };
          waiters.push(w);
        });
      },
      waitClose(ms = 3000) {
        if (closeCode !== null) return Promise.resolve(closeCode);
        return new Promise((res) => {
          const t = setTimeout(() => res(null), ms);
          ws.once('close', (c) => { clearTimeout(t); res(c); });
        });
      },
      close: () => { try { ws.close(); } catch {} },
    };
    // Object.assign 而非展开:展开会把 closeCode 这个 getter 冻成当时的值
    const finish = (v) => { if (!settled) { settled = true; resolve(Object.assign(api, v)); } };
    const timer = setTimeout(() => finish({ kind: 'timeout' }), 6000);
    ws.on('message', async (raw) => {
      let m; try { m = JSON.parse(raw); } catch { return; }
      if (m.t === 'challenge') {
        const a = await auth(m.nonce, userId);
        ws.send(JSON.stringify({ t: 'hello', userId, deviceId: 'd-' + userId, name: userId, platform: 'test', ...(a ? { auth: a } : {}) }));
        return;
      }
      inbox.push(m);
      for (const w of [...waiters]) if (w.pred(m)) { clearTimeout(w.timer); waiters.splice(waiters.indexOf(w), 1); w.res(m); }
      if (m.t === 'welcome') { clearTimeout(timer); finish({ kind: 'welcome', msg: m }); }
      if (m.t === 'error' && !settled) { clearTimeout(timer); finish({ kind: 'error', msg: m }); }
    });
    ws.on('close', (code) => { closeCode = code; clearTimeout(timer); finish({ kind: 'close', code }); });
    ws.on('error', () => { clearTimeout(timer); finish({ kind: 'wserror' }); });
  });
}

const v2Auth = (cid, passcode, extra = {}) => async (nonce, uid) => ({
  mode: 'circle', v: 2, circleId: cid, nonce, proof: await proofV2(nonce, uid, cid, passcode),
  ...(typeof extra === 'function' ? await extra() : extra),
});
const v1Auth = (cid, passcode) => (nonce, uid) => ({
  mode: 'circle', circleId: cid, nonce, proof: proofV1(nonce, uid, cid, passcode),
});
// 圈主钥匙由客户端生成,register 里只报它的 sha256。测试里按 cid 记下明文,模拟客户端的 vault。
const OWNER_KEYS = new Map();
const ownerKeyOf = (cid) => {
  if (!OWNER_KEYS.has(cid)) OWNER_KEYS.set(cid, randomBytes(32).toString('hex'));
  return OWNER_KEYS.get(cid);
};
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const registerAuth = (cid, passcode, key = ownerKeyOf(cid)) => v2Auth(cid, passcode, async () => ({
  register: { verifier: await verifierOf(passcode, cid), ownerHash: sha256(key) },
}));

async function main() {
  console.log('圈子注册 / 圈主权限 / v2 鉴权\n');
  await crossVectors();

  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-circles-'));
  const circlesFile = path.join(dataDir, 'circles.json');
  let child = boot(PORT, dataDir);
  try {
    if (!(await waitHealth(PORT))) throw new Error('服务端启动超时');

    // ── env 圈:v1 / v2 都通 ──
    let r = await connect(PORT, { auth: v1Auth('home', ENV_PASS) });
    check(r.kind === 'welcome', 'env 圈 v1 通过(TestFlight build 36 路径)', r.msg ?? r.code);
    check(r.msg?.circle?.registered === false && r.msg?.circle?.isOwner === false, 'env 圈 welcome.circle.registered=false', r.msg?.circle);
    r.close();
    r = await connect(PORT, { auth: v2Auth('home', ENV_PASS) });
    check(r.kind === 'welcome', 'env 圈 v2 通过', r.msg ?? r.code);
    r.close();
    r = await connect(PORT, { auth: v2Auth('home', 'wrong') });
    check(r.kind === 'error' && r.msg.message === 'auth_failed', 'env 圈 v2 错口令 -> auth_failed', r.msg);
    r = await connect(PORT, { auth: registerAuth('home', 'whatever-long') });
    check(r.kind === 'error' && r.msg.message === 'circle_exists', 'register 撞 env 圈 -> circle_exists', r.msg);

    // ── 未注册 + 不带 register:4401,且什么都不建 ──
    const ghost = newCircleId();
    r = await connect(PORT, { auth: v2Auth(ghost, 'some-passcode') });
    await r.waitClose();
    check(r.msg?.message === 'auth_failed' && r.closeCode === 4401, '未知圈不带 register -> 4401', { msg: r.msg, code: r.closeCode });
    check(!existsSync(circlesFile) || !(ghost in JSON.parse(readFileSync(circlesFile, 'utf8'))), '未知圈没有被隐式创建', null);

    // ── 注册 ──
    const cid = newCircleId();
    const PASS1 = 'maple-river-quiet-lamp';
    const owner = await connect(PORT, { userId: 'u_owner', auth: registerAuth(cid, PASS1) });
    const ownerKey = ownerKeyOf(cid);
    check(owner.kind === 'welcome' && owner.msg.circle?.created === true && owner.msg.circle?.ownerKey === undefined,
      '注册成功:welcome.circle.created,且服务器不下发 ownerKey', owner.msg?.circle);
    check(owner.msg?.circle?.isOwner === true && owner.msg?.circle?.registered === true, '注册者 isOwner=true', owner.msg?.circle);
    const disk = JSON.parse(readFileSync(circlesFile, 'utf8'));
    const rec = disk[cid];
    check(rec && rec.verifier === (await verifierOf(PASS1, cid)) && rec.ownerHash === createHash('sha256').update(ownerKey).digest('hex'),
      '盘上只有 verifier + ownerHash', rec);
    const raw = readFileSync(circlesFile, 'utf8');
    check(!raw.includes(ownerKey) && !raw.includes(PASS1), '盘上找不到明文 ownerKey / 口令', null);

    // 重复注册:circle_exists,记录不变
    r = await connect(PORT, { auth: registerAuth(cid, 'attacker-passcode') });
    await r.waitClose();
    check(r.msg?.message === 'circle_exists' && r.closeCode === 4409, '重复注册 -> circle_exists / 4409', { m: r.msg, c: r.closeCode });
    check(JSON.parse(readFileSync(circlesFile, 'utf8'))[cid].verifier === rec.verifier, '重复注册后记录未被覆盖', null);

    // welcome 丢了 / 4409 之后:客户端手里本就有钥匙,改走普通登录 + ownerKey 即拿回圈主身份
    r = await connect(PORT, { userId: 'u_owner', auth: v2Auth(cid, PASS1, { ownerKey }) });
    check(r.kind === 'welcome' && r.msg.circle?.isOwner === true && r.msg.circle?.created !== true,
      '4409 后带自己生成的 ownerKey 登录 -> isOwner=true(不再有无主圈)', r.msg?.circle);
    r.close();

    // register 缺 ownerHash / 格式不对:register_invalid,什么都不建
    for (const bad of [undefined, 'xyz', 'a'.repeat(63)]) {
      const c2 = newCircleId();
      r = await connect(PORT, {
        auth: v2Auth(c2, PASS1, async () => ({ register: { verifier: await verifierOf(PASS1, c2), ...(bad === undefined ? {} : { ownerHash: bad }) } })),
      });
      await r.waitClose();
      check(r.msg?.message === 'register_invalid' && r.closeCode === 4400 && !(c2 in JSON.parse(readFileSync(circlesFile, 'utf8'))),
        `register ownerHash=${bad} -> register_invalid / 4400,未建圈`, { m: r.msg, c: r.closeCode });
    }

    // 注册圈只收 v2
    r = await connect(PORT, { auth: v1Auth(cid, PASS1) });
    check(r.kind === 'error' && r.msg.message === 'auth_failed', '注册圈 v1 -> 拒绝', r.msg);
    // 第二个人用口令进
    const member = await connect(PORT, { userId: 'u_member', auth: v2Auth(cid, PASS1) });
    check(member.kind === 'welcome' && member.msg.circle?.isOwner === false && !member.msg.circle?.ownerKey,
      '成员 v2 进注册圈,isOwner=false 且拿不到 ownerKey', member.msg?.circle);
    // 带 ownerKey 登录 -> isOwner
    r = await connect(PORT, { userId: 'u_owner', auth: v2Auth(cid, PASS1, { ownerKey }) });
    check(r.kind === 'welcome' && r.msg.circle?.isOwner === true && !r.msg.circle?.ownerKey, '带 ownerKey 登录回显 isOwner=true', r.msg?.circle);
    r.close();
    r = await connect(PORT, { userId: 'u_owner', auth: v2Auth(cid, PASS1, { ownerKey: 'f'.repeat(64) }) });
    check(r.kind === 'welcome' && r.msg.circle?.isOwner === false, '错 ownerKey:照常登录但 isOwner=false', r.msg?.circle);
    r.close();

    // ── 进房 + 非圈主操作全部被拒 ──
    owner.send({ t: 'join', circleId: cid });
    await owner.waitFor((m) => m.t === 'room');
    member.send({ t: 'join', circleId: cid });
    await member.waitFor((m) => m.t === 'room');

    member.send({ t: 'kick', circleId: cid, userId: 'u_owner' });
    let e = await member.waitFor((m) => m.t === 'owner_error' && m.op === 'kick');
    check(e?.reason === 'not_owner', '非圈主 kick -> not_owner', e);
    member.send({ t: 'knock_mode_set', circleId: cid, enabled: true });
    e = await member.waitFor((m) => m.t === 'owner_error' && m.op === 'knock_mode_set');
    check(e?.reason === 'not_owner', '非圈主 knock_mode_set -> not_owner', e);
    member.send({ t: 'circle_e2ee_set', circleId: cid, enabled: true, ownerKey: 'nope' });
    e = await member.waitFor((m) => m.t === 'owner_error' && m.op === 'circle_e2ee_set');
    check(e?.reason === 'not_owner', '非圈主 circle_e2ee_set -> not_owner', e);
    member.send({ t: 'circle_passcode_set', circleId: cid, verifier: await verifierOf('evil-passcode', cid) });
    e = await member.waitFor((m) => m.t === 'owner_error' && m.op === 'circle_passcode_set');
    check(e?.reason === 'not_owner', '非圈主 circle_passcode_set -> not_owner', e);
    member.send({ t: 'circle_delete', circleId: cid });
    e = await member.waitFor((m) => m.t === 'owner_error' && m.op === 'circle_delete');
    check(e?.reason === 'not_owner', '非圈主 circle_delete -> not_owner', e);
    check(JSON.parse(readFileSync(circlesFile, 'utf8'))[cid]?.verifier === rec.verifier, '非圈主操作后记录毫发无损', null);

    // ── 圈主操作 ──
    owner.send({ t: 'knock_mode_set', circleId: cid, enabled: true, ownerKey });
    let ok = await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'knock_mode_set');
    check(Boolean(ok), '圈主 knock_mode_set -> owner_ok', ok);
    owner.send({ t: 'circle_e2ee_set', circleId: cid, enabled: true, ownerKey });
    ok = await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_e2ee_set');
    const pushed = await member.waitFor((m) => m.t === 'circle_settings' && m.circle?.e2ee === true);
    check(Boolean(ok) && pushed?.circle?.knockRequired === true, '圈主 circle_e2ee_set -> owner_ok,且推送给成员', pushed);
    // 新进来的人在 welcome 里就拿到 e2ee(进房前生效)
    r = await connect(PORT, { auth: v2Auth(cid, PASS1) });
    check(r.msg?.circle?.e2ee === true && r.msg?.circle?.knockRequired === true, 'welcome.circle 带 e2ee/knockRequired', r.msg?.circle);
    r.close();

    owner.send({ t: 'kick', circleId: cid, userId: 'u_member', ownerKey });
    const kicked = await member.waitFor((m) => m.t === 'kicked');
    ok = await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'kick');
    check(Boolean(kicked) && Boolean(ok), '圈主 kick -> 对方 kicked + owner_ok', { kicked, ok });

    // 换口令:在线成员被断开,旧口令失效,新口令可用
    const PASS2 = 'cedar-window-brave-otter';
    owner.send({ t: 'circle_passcode_set', circleId: cid, ownerKey, verifier: await verifierOf(PASS2, cid) });
    ok = await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_passcode_set');
    const rekeyed = await member.waitFor((m) => m.t === 'circle_rekeyed');
    const mc = await member.waitClose();
    check(Boolean(ok) && Boolean(rekeyed) && mc === 4401, '换口令:owner_ok,成员收到 circle_rekeyed 并以 4401 断开', { ok, rekeyed, mc });
    check(owner.closeCode === null, '圈主自己的连接不受影响', owner.closeCode);
    r = await connect(PORT, { auth: v2Auth(cid, PASS1) });
    check(r.kind === 'error' && r.msg.message === 'auth_failed', '换口令后旧口令 -> auth_failed', r.msg);
    r = await connect(PORT, { auth: v2Auth(cid, PASS2) });
    check(r.kind === 'welcome', '换口令后新口令可进', r.msg);
    r.close();

    // ── 重启后持久化 ──
    owner.close();
    await stop(child);
    child = boot(PORT, dataDir);
    if (!(await waitHealth(PORT))) throw new Error('重启超时');
    r = await connect(PORT, { auth: v2Auth(cid, PASS2, { ownerKey }) });
    check(r.kind === 'welcome' && r.msg.circle?.isOwner === true && r.msg.circle?.e2ee === true, '重启后:新口令 + ownerKey 仍有效,e2ee 仍在', r.msg?.circle);
    const owner2 = r;
    r = await connect(PORT, { auth: v2Auth(cid, PASS1) });
    check(r.kind === 'error', '重启后旧口令依旧失效', r.msg);

    // ── 解散 ──
    const m2 = await connect(PORT, { userId: 'u_member2', auth: v2Auth(cid, PASS2) });
    owner2.send({ t: 'circle_delete', circleId: cid, ownerKey });
    ok = await owner2.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_delete');
    const del = await m2.waitFor((m) => m.t === 'circle_deleted');
    const dc = await m2.waitClose();
    check(Boolean(ok) && Boolean(del) && dc === 4410, '解散:owner_ok,成员收到 circle_deleted 并以 4410 断开', { ok, del, dc });
    r = await connect(PORT, { auth: v2Auth(cid, PASS2) });
    check(r.kind === 'error' && r.msg.message === 'circle_deleted', '解散后用对的口令 -> circle_deleted', r.msg);
    r = await connect(PORT, { auth: v2Auth(cid, 'wrong-wrong-wrong') });
    check(r.kind === 'error' && r.msg.message === 'auth_failed', '解散后错口令 -> 仍只说 auth_failed(不泄露圈子存在过)', r.msg);
    r = await connect(PORT, { auth: registerAuth(cid, 'reuse-the-id-now') });
    check(r.kind === 'error' && r.msg.message === 'circle_exists', '解散后的 id 不能被重新注册(墓碑)', r.msg);
    const after = JSON.parse(readFileSync(circlesFile, 'utf8'))[cid];
    check(after?.deletedAt && !after.ownerHash, '盘上只剩墓碑(无 ownerHash)', after);
  } finally {
    await stop(child);
  }

  // ── 限流与总量上限(独立实例)──
  const dataDir2 = mkdtempSync(path.join(tmpdir(), 'lares-circles-rl-'));
  const P2 = PORT + 1;
  child = boot(P2, dataDir2, { LARES_CIRCLE_CREATE_PER_HOUR: '2', LARES_MAX_CIRCLES: '3' });
  try {
    if (!(await waitHealth(P2))) throw new Error('限流实例启动超时');
    // 本机对端 + 默认 auto:信 XFF 最右一项。用它模拟反代后面的两个不同用户。
    const ipA = { 'x-forwarded-for': '198.51.100.7' };
    const ipB = { 'x-forwarded-for': '1.2.3.4, 203.0.113.9' }; // 左边的伪造项必须被忽略
    const mk = (headers) => connect(P2, { headers, auth: registerAuth(newCircleId(), 'some-long-passcode') });
    let a1 = await mk(ipA); let a2 = await mk(ipA); let a3 = await mk(ipA);
    check(a1.kind === 'welcome' && a2.kind === 'welcome', '同一 IP 前 2 个注册成功', [a1.msg, a2.msg]);
    await a3.waitClose();
    check(a3.msg?.message === 'create_rate_limited' && a3.closeCode === 4403, '同一 IP 第 3 个 -> create_rate_limited / 4403', { m: a3.msg, c: a3.closeCode });
    // 伪造 XFF 左侧不能绕开:最右一项仍是 198.51.100.7
    const spoof = await mk({ 'x-forwarded-for': '9.9.9.9, 198.51.100.7' });
    check(spoof.msg?.message === 'create_rate_limited', 'XFF 左侧伪造不能绕开限流', spoof.msg);
    const b1 = await mk(ipB);
    check(b1.kind === 'welcome', '另一个 IP 不受连坐', b1.msg);
    const b2 = await mk(ipB);
    await b2.waitClose();
    check(b2.msg?.message === 'circle_cap_reached' && b2.closeCode === 4403, '总量达上限 -> circle_cap_reached', { m: b2.msg, c: b2.closeCode });
    for (const c of [a1, a2, b1]) c.close();
  } finally {
    await stop(child);
  }

  // ── LiveKit 管理 API 不可达:媒体侧驱逐失败,信令侧 kick/换口令照常生效、进程不崩 ──
  const dataDir4 = mkdtempSync(path.join(tmpdir(), 'lares-circles-lk-'));
  child = boot(PORT + 3, dataDir4, {
    LIVEKIT_URL: 'wss://rtc.invalid:8444', LIVEKIT_API_URL: 'http://127.0.0.1:1',
    LIVEKIT_API_KEY: 'k', LIVEKIT_API_SECRET: 's'.repeat(32),
  });
  try {
    if (!(await waitHealth(PORT + 3))) throw new Error('LiveKit 不可达实例启动超时');
    const cid = newCircleId();
    const o = await connect(PORT + 3, { userId: 'u_o', auth: registerAuth(cid, 'lk-down-passcode') });
    const key = ownerKeyOf(cid);
    const m = await connect(PORT + 3, { userId: 'u_m', auth: v2Auth(cid, 'lk-down-passcode') });
    o.send({ t: 'join', circleId: cid }); await o.waitFor((x) => x.t === 'room');
    m.send({ t: 'join', circleId: cid }); await m.waitFor((x) => x.t === 'room');
    o.send({ t: 'kick', circleId: cid, userId: 'u_m', ownerKey: key });
    const k = await m.waitFor((x) => x.t === 'kicked');
    const okk = await o.waitFor((x) => x.t === 'owner_ok' && x.op === 'kick');
    check(Boolean(k) && Boolean(okk), 'LiveKit 不可达时圈主 kick 照常生效', { k, okk });
    o.send({ t: 'circle_passcode_set', circleId: cid, ownerKey: key, verifier: await verifierOf('lk-down-new-pass', cid) });
    const okp = await o.waitFor((x) => x.t === 'owner_ok' && x.op === 'circle_passcode_set');
    await new Promise((r) => setTimeout(r, 1500)); // 给失败的管理 API 调用留时间爆出来
    check(Boolean(okp) && child.exitCode === null && (await waitHealth(PORT + 3, 1000)), 'LiveKit 不可达时换口令成功且进程存活', { okp, exit: child.exitCode });
    o.close(); m.close();
  } finally {
    await stop(child);
  }

  // ── 注册表损坏:拒绝启动(不能用空表覆盖掉所有圈子)──
  const dataDir3 = mkdtempSync(path.join(tmpdir(), 'lares-circles-bad-'));
  const { writeFileSync } = await import('node:fs');
  writeFileSync(path.join(dataDir3, 'circles.json'), '{"c_x": {"verifier": ');
  child = boot(PORT + 2, dataDir3);
  const code = await new Promise((res) => { const t = setTimeout(() => res('alive'), 4000); child.once('exit', (c) => { clearTimeout(t); res(c); }); });
  check(code === 1, 'circles.json 损坏 -> 拒绝启动(exit 1)', code);
  await stop(child);
  check(readFileSync(path.join(dataDir3, 'circles.json'), 'utf8').startsWith('{"c_x"'), '损坏的文件没有被覆盖', null);

  for (const d of [dataDir, dataDir2, dataDir3, dataDir4]) { try { rmSync(d, { recursive: true, force: true }); } catch {} }
  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
