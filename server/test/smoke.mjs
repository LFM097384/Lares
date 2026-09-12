// 端到端冒烟测试:起服务 -> 两个客户端进房 -> 校验 presence 广播
// 运行:node test/smoke.mjs
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';

const PORT = 18989;
// 隔离数据目录:不受本机持久化的敲门设置/便签影响
const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-test-'));

// 起服务的统一入口:每组鉴权配置需要独立进程(env 只能在启动时生效),
// 各自占一个端口 + 独立数据目录,互不污染。
const spawned = [];
function spawnServer(port, env = {}) {
  // 显式清掉父进程可能带的鉴权变量,保证每组测试的配置是确定的
  const base = { ...process.env };
  for (const k of ['LARES_AUTH_MODE', 'LARES_AUTH_TOKEN', 'LARES_CIRCLE_PASSCODE',
    'LARES_CIRCLE_PASSCODES', 'LARES_ALLOWED_ORIGIN', 'LARES_AUTH_NONCE_TTL_MS']) delete base[k];
  const proc = spawn(process.execPath, ['src/index.js'], {
    env: {
      ...base,
      LARES_PORT: String(port),
      LARES_DATA_DIR: mkdtempSync(path.join(tmpdir(), 'lares-test-')),
      ...env,
    },
    stdio: 'inherit',
  });
  spawned.push(proc);
  return proc;
}

/// 起服务并等它真正就绪(轮询 /health,比固定 sleep 稳)
async function bootServer(port, env = {}) {
  const proc = spawnServer(port, env);
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/health`);
      if (r.ok) return proc;
    } catch { /* 还没起来 */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`server on :${port} 启动超时`);
}

// ── 挑战应答证明(与服务端 verifyAuth 的输入串格式必须逐字一致)──
const proofToken = (secret, nonce, userId) =>
  crypto.createHmac('sha256', secret).update(`${nonce}:${userId}`).digest('hex');
const proofCircle = (passcode, nonce, userId, circleId) =>
  crypto.createHmac('sha256', passcode).update(`${nonce}:${userId}:${circleId}`).digest('hex');

const server = spawnServer(PORT);

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (name, cond) => {
  console.log(`${cond ? '✓' : '✗'} ${name}`);
  if (!cond) failures++;
};

function client(userId, name, port = PORT) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const inbox = [];
  const waiters = [];
  // 记录关闭码:鉴权失败(4401)与限流(4429)要能和普通掉线区分开
  let closed = null;
  const closeWaiters = [];
  ws.on('close', (code, reason) => {
    closed = { code, reason: String(reason ?? '') };
    for (const r of closeWaiters.splice(0)) r(closed);
  });
  ws.on('error', () => { /* 关闭码由 close 事件给出 */ });
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw);
    inbox.push(msg);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].pred(msg)) {
        waiters[i].resolve(msg);
        waiters.splice(i, 1);
      }
    }
  });
  const waitFor = (pred, ms = 3000) =>
    new Promise((resolve, reject) => {
      const hit = inbox.find(pred);
      if (hit) return resolve(hit);
      waiters.push({ pred, resolve });
      setTimeout(() => reject(new Error('timeout waiting message')), ms);
    });
  const waitClose = (ms = 3000) =>
    new Promise((resolve, reject) => {
      if (closed) return resolve(closed);
      closeWaiters.push(resolve);
      setTimeout(() => reject(new Error('timeout waiting close')), ms);
    });
  return {
    ws, inbox, waitFor, waitClose,
    send: (m) => ws.send(JSON.stringify(m)),
    waitChallenge: () => waitFor((m) => m.t === 'challenge'),
  };
}

/// 完整走一遍「拿挑战 -> 算证明 -> hello」,返回 client 供后续断言
async function authedClient(port, userId, auth) {
  const c = client(userId, userId, port);
  const ch = await c.waitChallenge();
  c.send({ t: 'hello', userId, deviceId: `${userId}_d1`, name: userId, platform: 'test', auth: auth(ch.nonce) });
  return c;
}

try {
  await wait(1500);

  // /ws 路径也可接入(反代按路径分流用)
  const pathClient = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
  await new Promise((r, j) => { pathClient.on('open', r); pathClient.on('error', j); });
  check('/ws 路径可连接', true);
  pathClient.close();

  const a = client('u_a', '阿伟');
  const b = client('u_b', '小敏');
  await wait(300);

  a.send({ t: 'hello', userId: 'u_a', deviceId: 'd_a1', name: '阿伟', platform: 'windows' });
  b.send({ t: 'hello', userId: 'u_b', deviceId: 'd_b1', name: '小敏', platform: 'ios' });
  await a.waitFor((m) => m.t === 'welcome');
  await b.waitFor((m) => m.t === 'welcome');
  check('hello -> welcome', true);

  // a 先进房
  a.send({ t: 'join', circleId: 'home' });
  const roomA = await a.waitFor((m) => m.t === 'room');
  check('a 进房,房间只有自己', roomA.members.length === 1 && roomA.members[0].userId === 'u_a');
  const rtcErr = await a.waitFor((m) => m.t === 'error');
  check('未配置 LiveKit 时返回 rtc_not_configured', rtcErr.message === 'rtc_not_configured');

  // b 进房,a 应收到 member_joined
  b.send({ t: 'join', circleId: 'home' });
  const joined = await a.waitFor((m) => m.t === 'member_joined');
  check('a 收到 b 的 member_joined', joined.member.userId === 'u_b');
  const roomB = await b.waitFor((m) => m.t === 'room');
  check('b 看到房间两人', roomB.members.length === 2);

  // 大厅摘要:只 hello 不进房的 c 也应看到「2 人在」
  const c = client('u_c', '路人');
  await wait(200);
  c.send({ t: 'hello', userId: 'u_c', deviceId: 'd_c1', name: '路人', platform: 'android' });
  const summary = await c.waitFor((m) => m.t === 'circle_summary' && m.circleId === 'home');
  check('未进房的 c 收到大厅摘要(2 人)', summary.count === 2 && summary.names.length === 2);

  // 轻状态广播
  b.send({ t: 'status', status: 'busy' });
  const st = await a.waitFor((m) => m.t === 'member_status');
  check('a 收到 b 的状态变更 busy', st.userId === 'u_b' && st.status === 'busy');

  // 改名广播(b 此时仍在房内)
  b.send({ t: 'profile', name: '小敏同学' });
  const renamed = await a.waitFor((m) => m.t === 'member_updated');
  check('a 收到 b 的改名广播', renamed.member.userId === 'u_b' && renamed.member.name === '小敏同学');

  // b 离开,a 收到 member_left
  b.send({ t: 'leave' });
  const left = await a.waitFor((m) => m.t === 'member_left');
  check('a 收到 b 的 member_left', left.userId === 'u_b');

  // 多端同账号:a 的第二台设备进房,不产生第二个成员
  const a2 = client('u_a', '阿伟');
  await wait(200);
  a2.send({ t: 'hello', userId: 'u_a', deviceId: 'd_a2', name: '阿伟', platform: 'macos' });
  await a2.waitFor((m) => m.t === 'welcome');
  a2.send({ t: 'join', circleId: 'home' });
  const roomA2 = await a2.waitFor((m) => m.t === 'room');
  check('同账号多端聚合为一个成员', roomA2.members.length === 1 && roomA2.members[0].deviceCount === 2);

  // ── 敲门模式 ──
  // 圈主设置 vip 圈需敲门(空房时 a 直接进)
  a.send({ t: 'knock_mode_set', circleId: 'vip', enabled: true });
  const summaryVip = await c.waitFor((m) => m.t === 'circle_summary' && m.circleId === 'vip');
  check('大厅摘要带 knockRequired', summaryVip.knockRequired === true);

  a.send({ t: 'join', circleId: 'vip' });
  await a.waitFor((m) => m.t === 'room' && m.circleId === 'vip');
  check('空房时敲门模式也直接进', true);

  // b 敲 vip 的门:应等待 + a 收到敲门
  b.send({ t: 'join', circleId: 'vip' });
  const waiting = await b.waitFor((m) => m.t === 'knock_waiting');
  check('b 进入敲门等待', waiting.circleId === 'vip');
  const knock = await a.waitFor((m) => m.t === 'knock');
  check('a 收到敲门', knock.userId === 'u_b');

  // 非圈内成员的放行无效(授权检查);c 不在 vip
  c.send({ t: 'knock_allow', circleId: 'vip', userId: 'u_b' });
  await wait(400);
  check('圈外人的放行被拒绝', !b.inbox.some((m) => m.t === 'room' && m.circleId === 'vip'));

  // 圈外人也无权改敲门设置;c 改 vip 应被拒绝(a 在 vip 内)
  const beforeSet = c.inbox.length;
  c.send({ t: 'knock_mode_set', circleId: 'vip', enabled: false });
  await wait(600);
  check(
    '圈外人改敲门设置被拒绝(无新摘要)',
    !c.inbox.slice(beforeSet).some((m) => m.t === 'circle_summary' && m.circleId === 'vip'),
  );

  // a 放行:b 完成进房
  a.send({ t: 'knock_allow', circleId: 'vip', userId: 'u_b' });
  const roomVip = await b.waitFor((m) => m.t === 'room' && m.circleId === 'vip');
  check('放行后 b 进房成功', roomVip.members.length === 2);

  // 清理:离开 vip 圈
  a.send({ t: 'join', circleId: 'home' });
  await a.waitFor((m) => m.t === 'room' && m.circleId === 'home');
  b.send({ t: 'join', circleId: 'home' });
  await b.waitFor((m) => m.t === 'room' && m.circleId === 'home');

  // ── 位置共享 ──
  b.send({ t: 'loc', lat: 39.9042, lng: 116.4074 });
  const loc = await a.waitFor((m) => m.t === 'member_loc');
  check('a 收到 b 的位置', loc.userId === 'u_b' && Math.abs(loc.lat - 39.9042) < 1e-6);

  // ── 踢人 ──
  // 圈外人不能踢人
  const beforeKick = b.inbox.length;
  c.send({ t: 'kick', circleId: 'home', userId: 'u_b' });
  await wait(400);
  check('圈外人踢人被拒绝', !b.inbox.slice(beforeKick).some((m) => m.t === 'kicked'));
  // 圈内 a 踢 b:b 收到 kicked,a 看到 member_left
  a.send({ t: 'kick', circleId: 'home', userId: 'u_b' });
  const kicked = await b.waitFor((m) => m.t === 'kicked');
  check('b 收到被踢通知', kicked.circleId === 'home');
  await a.waitFor((m) => m.t === 'member_left' && m.userId === 'u_b');
  check('a 看到 b 被移出', true);

  b.send({ t: 'leave' });

  // b 离开,c 的大厅摘要应变为 1 人
  const cSummaryAfter = c.waitFor((m) => m.t === 'circle_summary' && m.count === 1);
  b.send({ t: 'leave' });
  await cSummaryAfter;
  check('b 离开后 c 的摘要更新为 1 人', true);

  // none 模式下也应下发 challenge,且标明「不需要鉴权」
  const chNone = a.inbox.find((m) => m.t === 'challenge');
  check('none 模式:仍下发 challenge 且 authRequired=false',
    !!chNone && chNone.authRequired === false && Array.isArray(chNone.modes) && chNone.modes.length === 0);
  check('none 模式:welcome.authMode 为 none',
    a.inbox.some((m) => m.t === 'welcome' && m.authMode === 'none'));

  // none 模式 /health 保留详细信息(本地开发便利)
  const healthNone = await (await fetch(`http://127.0.0.1:${PORT}/health`)).json();
  check('none 模式:/health 仍带 circles 明细', typeof healthNone.circles === 'object');

  a.ws.close(); b.ws.close(); a2.ws.close(); c.ws.close();

  // ══════════════ token 模式 ══════════════
  const TOKEN = 'super-secret-token';
  const P_TOKEN = 18990;
  await bootServer(P_TOKEN, { LARES_AUTH_MODE: 'token', LARES_AUTH_TOKEN: TOKEN });

  const chT = await (async () => {
    const probe = client('probe', 'probe', P_TOKEN);
    const ch = await probe.waitChallenge();
    check('token 模式:challenge 声明 authRequired + modes',
      ch.authRequired === true && ch.modes.includes('token') && /^[0-9a-f]{32}$/.test(ch.nonce));
    probe.ws.close();
    return ch;
  })();

  // 正确证明 -> welcome.authMode = token
  const tOk = await authedClient(P_TOKEN, 'u_t', (nonce) => ({
    mode: 'token', proof: proofToken(TOKEN, nonce, 'u_t'),
  }));
  const welT = await tOk.waitFor((m) => m.t === 'welcome');
  check('token 模式:正确证明通过,welcome.authMode=token', welT.authMode === 'token');
  // token 模式不限圈子
  tOk.send({ t: 'join', circleId: 'anything' });
  const roomAny = await tOk.waitFor((m) => m.t === 'room' && m.circleId === 'anything');
  check('token 模式:可进任意圈子', roomAny.circleId === 'anything');
  tOk.ws.close();

  // 错误证明 -> auth_failed + 4401
  const tBad = await authedClient(P_TOKEN, 'u_bad', (nonce) => ({
    mode: 'token', proof: proofToken('wrong-secret', nonce, 'u_bad'),
  }));
  const errBad = await tBad.waitFor((m) => m.t === 'error');
  const closeBad = await tBad.waitClose();
  check('token 模式:错误证明 -> auth_failed', errBad.message === 'auth_failed');
  check('token 模式:错误证明 -> 关闭码 4401', closeBad.code === 4401);

  // 缺 auth 字段 -> auth_required + 4401
  const tMissing = client('u_noauth', 'u_noauth', P_TOKEN);
  await tMissing.waitChallenge();
  tMissing.send({ t: 'hello', userId: 'u_noauth', deviceId: 'd', name: 'x', platform: 'test' });
  const errMissing = await tMissing.waitFor((m) => m.t === 'error');
  const closeMissing = await tMissing.waitClose();
  check('token 模式:缺 auth -> auth_required', errMissing.message === 'auth_required');
  check('token 模式:缺 auth -> 关闭码 4401', closeMissing.code === 4401);

  // nonce 重放:复用已消费过的 nonce 必须失败
  const replay = client('u_replay', 'u_replay', P_TOKEN);
  await replay.waitChallenge();
  replay.send({ t: 'hello', userId: 'u_replay', deviceId: 'd', name: 'x', platform: 'test',
    auth: { mode: 'token', proof: proofToken(TOKEN, chT.nonce, 'u_replay'), nonce: chT.nonce } });
  const errReplay = await replay.waitFor((m) => m.t === 'error');
  check('nonce 重放:复用已消费的 nonce 被拒', errReplay.message === 'auth_failed');

  // /notes:无 Bearer 401,带正确 Bearer 通过
  const notes401 = await fetch(`http://127.0.0.1:${P_TOKEN}/notes?circleId=home`);
  const notes401Body = await notes401.json();
  check('开鉴权:/notes 无 Bearer 返回 401',
    notes401.status === 401 && notes401Body.error === 'auth_required');
  const notes200 = await fetch(`http://127.0.0.1:${P_TOKEN}/notes?circleId=home`, {
    headers: { authorization: `Bearer ${TOKEN}` },
  });
  check('开鉴权:/notes 带正确 Bearer 通过', notes200.status === 200);
  const notesBadBearer = await fetch(`http://127.0.0.1:${P_TOKEN}/notes?circleId=home`, {
    headers: { authorization: 'Bearer nope' },
  });
  check('开鉴权:/notes 错误 Bearer 返回 401', notesBadBearer.status === 401);

  // POST /notes 也要拦(body 里带 circleId)
  const postNoAuth = await fetch(`http://127.0.0.1:${P_TOKEN}/notes`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ circleId: 'home', userId: 'x', audio: 'AAAA' }),
  });
  check('开鉴权:POST /notes 无 Bearer 返回 401', postNoAuth.status === 401);

  // /health 不再泄露圈子人数
  const healthAuth = await (await fetch(`http://127.0.0.1:${P_TOKEN}/health`)).json();
  check('开鉴权:/health 不泄露圈子人数',
    healthAuth.circles === undefined && healthAuth.authRequired === true && healthAuth.ok === true);

  // CORS 预检应带 authorization
  const preflight = await fetch(`http://127.0.0.1:${P_TOKEN}/notes`, { method: 'OPTIONS' });
  check('开鉴权:CORS allow-headers 含 authorization',
    (preflight.headers.get('access-control-allow-headers') ?? '').includes('authorization'));

  // ══════════════ circle 模式 ══════════════
  const PASS = 'home-passcode';
  const P_CIRCLE = 18991;
  await bootServer(P_CIRCLE, { LARES_AUTH_MODE: 'circle', LARES_CIRCLE_PASSCODE: PASS });

  const cOk = await authedClient(P_CIRCLE, 'u_c1', (nonce) => ({
    mode: 'circle', circleId: 'home', proof: proofCircle(PASS, nonce, 'u_c1', 'home'),
  }));
  const welC = await cOk.waitFor((m) => m.t === 'welcome');
  check('circle 模式:正确口令通过,welcome.authMode=circle', welC.authMode === 'circle');

  cOk.send({ t: 'join', circleId: 'home' });
  const roomHome = await cOk.waitFor((m) => m.t === 'room' && m.circleId === 'home');
  check('circle 模式:可进已授权的圈子', roomHome.circleId === 'home');

  // 越界进别的圈子 -> auth_scope
  // 注意:waitFor 会先扫已有 inbox,所以每条越权断言都必须只看「本次发送之后」新到的消息,
  // 否则会匹配到上一条断言留下的 auth_scope 而假通过(本次开发中确实踩到了)。
  const countScope = () => cOk.inbox.filter((m) => m.t === 'error' && m.message === 'auth_scope').length;
  const expectScope = async (label, payload) => {
    const before = countScope();
    cOk.send(payload);
    for (let i = 0; i < 30 && countScope() <= before; i++) await wait(100);
    check(label, countScope() === before + 1);
  };

  await expectScope('circle 模式:进未授权圈子被拒(auth_scope)', { t: 'join', circleId: 'work' });
  // token_prefetch 同样受限(否则等于绕过 join 的鉴权)
  await expectScope('circle 模式:token_prefetch 越界被拒', { t: 'token_prefetch', circleId: 'work' });
  // knock_mode_set 越界也要拒(修补:原来空圈任何人可改)
  await expectScope('circle 模式:knock_mode_set 越界被拒', { t: 'knock_mode_set', circleId: 'work', enabled: true });
  // 已授权的圈子不该被误伤
  const beforeOk = countScope();
  cOk.send({ t: 'knock_mode_set', circleId: 'home', enabled: false });
  await wait(400);
  check('circle 模式:对已授权圈子的 knock_mode_set 不被误拒', countScope() === beforeOk);

  // 错误口令
  const cBad = await authedClient(P_CIRCLE, 'u_c2', (nonce) => ({
    mode: 'circle', circleId: 'home', proof: proofCircle('wrong', nonce, 'u_c2', 'home'),
  }));
  const cBadErr = await cBad.waitFor((m) => m.t === 'error');
  const cBadClose = await cBad.waitClose();
  check('circle 模式:错误口令 -> auth_failed + 4401',
    cBadErr.message === 'auth_failed' && cBadClose.code === 4401);

  // 大厅摘要不得跨圈泄露:work 圈的人在线,home 圈的连接不该看到
  const workUser = await authedClient(P_CIRCLE, 'u_work', (nonce) => ({
    mode: 'circle', circleId: 'work', proof: proofCircle(PASS, nonce, 'u_work', 'work'),
  }));
  await workUser.waitFor((m) => m.t === 'welcome');
  workUser.send({ t: 'join', circleId: 'work' });
  await workUser.waitFor((m) => m.t === 'room' && m.circleId === 'work');
  await wait(500);
  check('circle 模式:大厅摘要不泄露其它圈子',
    !cOk.inbox.some((m) => m.t === 'circle_summary' && m.circleId === 'work'));
  check('circle 模式:自己圈子的摘要仍可见',
    workUser.inbox.some((m) => m.t === 'circle_summary' && m.circleId === 'work'));
  workUser.ws.close();

  // circle 模式 /notes:口令即 Bearer,且只对自己的圈子有效
  const notesCircleOk = await fetch(`http://127.0.0.1:${P_CIRCLE}/notes?circleId=home`, {
    headers: { authorization: `Bearer ${PASS}` },
  });
  check('circle 模式:/notes 用圈子口令作 Bearer 可通过', notesCircleOk.status === 200);
  cOk.ws.close();

  // ══════════════ 按圈口令覆盖优先级 ══════════════
  const P_OVERRIDE = 18992;
  const HOME_PASS = 'home-only-pass';
  await bootServer(P_OVERRIDE, {
    LARES_AUTH_MODE: 'circle',
    LARES_CIRCLE_PASSCODE: 'site-wide-pass',
    LARES_CIRCLE_PASSCODES: JSON.stringify({ home: HOME_PASS }),
  });

  // home 必须用专属口令
  const ovOk = await authedClient(P_OVERRIDE, 'u_ov', (nonce) => ({
    mode: 'circle', circleId: 'home', proof: proofCircle(HOME_PASS, nonce, 'u_ov', 'home'),
  }));
  const ovWel = await ovOk.waitFor((m) => m.t === 'welcome');
  check('按圈口令:home 用专属口令通过', ovWel.authMode === 'circle');
  ovOk.ws.close();

  // 对 home 用全站口令应失败(专属口令优先)
  const ovBad = await authedClient(P_OVERRIDE, 'u_ov2', (nonce) => ({
    mode: 'circle', circleId: 'home', proof: proofCircle('site-wide-pass', nonce, 'u_ov2', 'home'),
  }));
  const ovBadErr = await ovBad.waitFor((m) => m.t === 'error');
  check('按圈口令:home 用全站口令被拒(专属优先)', ovBadErr.message === 'auth_failed');

  // 没有专属条目的圈子回落到全站口令
  const ovFallback = await authedClient(P_OVERRIDE, 'u_ov3', (nonce) => ({
    mode: 'circle', circleId: 'work', proof: proofCircle('site-wide-pass', nonce, 'u_ov3', 'work'),
  }));
  const ovFbWel = await ovFallback.waitFor((m) => m.t === 'welcome');
  check('按圈口令:未覆盖的圈子回落全站口令', ovFbWel.authMode === 'circle');
  ovFallback.ws.close();

  // ══════════════ nonce 过期 ══════════════
  const P_TTL = 18993;
  await bootServer(P_TTL, {
    LARES_AUTH_MODE: 'token', LARES_AUTH_TOKEN: TOKEN, LARES_AUTH_NONCE_TTL_MS: '300',
  });
  const ttlC = client('u_ttl', 'u_ttl', P_TTL);
  const ttlCh = await ttlC.waitChallenge();
  await wait(700); // 超过 300ms TTL
  ttlC.send({ t: 'hello', userId: 'u_ttl', deviceId: 'd', name: 'x', platform: 'test',
    auth: { mode: 'token', proof: proofToken(TOKEN, ttlCh.nonce, 'u_ttl') } });
  const ttlErr = await ttlC.waitFor((m) => m.t === 'error');
  const ttlClose = await ttlC.waitClose();
  check('nonce 过期:超 TTL 的证明被拒 + 4401',
    ttlErr.message === 'auth_failed' && ttlClose.code === 4401);

  // ══════════════ 限流 ══════════════
  // 独立实例:失败计数会把 127.0.0.1 封 5 分钟,不能污染其它组
  const P_RL = 18994;
  await bootServer(P_RL, { LARES_AUTH_MODE: 'token', LARES_AUTH_TOKEN: TOKEN });
  const rlCodes = [];
  for (let i = 0; i < 13; i++) {
    const rc = client(`u_rl${i}`, 'x', P_RL);
    try {
      await rc.waitChallenge(1500);
      rc.send({ t: 'hello', userId: `u_rl${i}`, deviceId: 'd', name: 'x', platform: 'test',
        auth: { mode: 'token', proof: proofToken('wrong', 'x'.repeat(32), `u_rl${i}`) } });
    } catch { /* 已被封:challenge 都收不到 */ }
    const cl = await rc.waitClose(2000).catch(() => null);
    rlCodes.push(cl ? cl.code : 0);
    if (cl && cl.code === 4429) break;
  }
  // 前 10 次应是 4401(单纯验证失败),越过阈值后才转 4429
  const firstRl = rlCodes.indexOf(4429);
  check('限流:阈值内失败仍返回 4401',
    firstRl > 0 && rlCodes.slice(0, firstRl).every((c) => c === 4401));
  check('限流:连续失败超阈值后返回 4429', firstRl >= 10 && firstRl <= 11);

  // 封禁期间连 challenge 都不给(不做噪音放大器)
  const blocked = client('u_blocked', 'x', P_RL);
  const blockedClose = await blocked.waitClose(2000).catch(() => null);
  check('限流:封禁期内新连接直接 4429 关断', blockedClose?.code === 4429);

  // ══════════════ 未鉴权连接不得改圈子设置 ══════════════
  // 修补前:不说 hello、对空圈直接 knock_mode_set 即可生效
  const P_ANON = 18998;
  await bootServer(P_ANON, { LARES_AUTH_MODE: 'token', LARES_AUTH_TOKEN: TOKEN });
  const anon = client('anon', 'anon', P_ANON);
  await anon.waitChallenge();
  anon.send({ t: 'knock_mode_set', circleId: 'brand_new_circle', enabled: true });
  const anonErr = await anon.waitFor((m) => m.t === 'error', 2000).catch(() => null);
  check('未 hello 的连接改敲门设置被拒', anonErr?.message === 'say_hello_first');
  anon.ws.close();

  // ══════════════ 启动期配置校验 ══════════════
  const exitCode = await new Promise((resolve) => {
    const p = spawnServer(18995, { LARES_AUTH_MODE: 'token' }); // 故意不给 LARES_AUTH_TOKEN
    p.on('exit', resolve);
  });
  check('启动校验:token 模式缺 LARES_AUTH_TOKEN -> 非零退出', exitCode !== 0);

  const exitCode2 = await new Promise((resolve) => {
    const p = spawnServer(18996, { LARES_AUTH_MODE: 'circle' }); // 缺口令
    p.on('exit', resolve);
  });
  check('启动校验:circle 模式缺口令 -> 非零退出', exitCode2 !== 0);

  const exitCode3 = await new Promise((resolve) => {
    const p = spawnServer(18997, { LARES_AUTH_MODE: 'bogus' });
    p.on('exit', resolve);
  });
  check('启动校验:未知模式 -> 非零退出', exitCode3 !== 0);
} catch (e) {
  console.error('✗ 冒烟测试异常:', e.message);
  failures++;
} finally {
  server.kill();
  for (const p of spawned) { try { p.kill(); } catch { /* 已退出 */ } }
}

console.log(failures === 0 ? '\n全部通过' : `\n${failures} 项失败`);
process.exit(failures === 0 ? 0 : 1);
