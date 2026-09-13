// 鉴权互操作验证:用「客户端视角」独立实现一遍 HMAC,验证与服务端格式一致。
//
// 为什么单独写这个:smoke.mjs 里的断言与服务端共用同一份实现,
// 格式若整体写错(比如分隔符用了 '|' 而非 ':'),两边会一起错、测试照样全绿。
// 这里刻意**不 import 服务端任何代码**,只按协议文档独立推导,
// 再打到真实服务端上。Flutter 客户端将来也必须与这份推导一致。
//
// 用法:node test/auth_interop.mjs

import { spawn } from 'node:child_process';
import { createHmac, randomBytes } from 'node:crypto';
import { WebSocket } from 'ws';

const PORT = 18930;
const TOKEN = 'interop-token-' + randomBytes(6).toString('hex');
const PASSCODE = 'interop-pass-' + randomBytes(6).toString('hex');

let pass = 0;
let fail = 0;
function ok(name) { console.log('  ✓', name); pass++; }
function bad(name, detail) { console.log('  ✗', name, '—', detail); fail++; }

// ── 独立推导的 proof(按协议文档,不看服务端实现)──────────────────────────
function tokenProof(nonce, userId, key) {
  return createHmac('sha256', key).update(`${nonce}:${userId}`).digest('hex');
}
function circleProof(nonce, userId, circleId, passcode) {
  return createHmac('sha256', passcode)
    .update(`${nonce}:${userId}:${circleId}`)
    .digest('hex');
}

function bootServer(env) {
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'),
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', () => {});
  return child;
}

async function waitHealth(port, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/health`);
      if (r.ok) return true;
    } catch { /* 还没起来 */ }
    await new Promise((r) => setTimeout(r, 120));
  }
  return false;
}

/// 连一次,拿 challenge,按给定方式回 hello,返回发生的第一个结果
function attempt(port, buildAuth, { userId = 'u_interop' } = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    let challenge = null;
    const done = (v) => { try { ws.close(); } catch {} resolve(v); };
    const timer = setTimeout(() => done({ kind: 'timeout' }), 6000);

    ws.on('message', (raw) => {
      let m;
      try { m = JSON.parse(raw); } catch { return; }
      if (m.t === 'challenge') {
        challenge = m;
        const auth = buildAuth(m, userId);
        ws.send(JSON.stringify({
          t: 'hello', userId, deviceId: 'd1', name: '互操作', platform: 'test',
          ...(auth ? { auth } : {}),
        }));
        return;
      }
      if (m.t === 'welcome') { clearTimeout(timer); done({ kind: 'welcome', msg: m, challenge }); }
      if (m.t === 'error') { clearTimeout(timer); done({ kind: 'error', msg: m, challenge }); }
    });
    ws.on('close', (code) => { clearTimeout(timer); resolve({ kind: 'close', code, challenge }); });
    ws.on('error', () => { clearTimeout(timer); resolve({ kind: 'wserror', challenge }); });
  });
}

async function main() {
  console.log('鉴权互操作验证(独立实现 HMAC,不复用服务端代码)\n');

  // ── token 模式 ──────────────────────────────────────────────────────────
  let child = bootServer({
    LARES_PORT: String(PORT),
    LARES_AUTH_MODE: 'token',
    LARES_AUTH_TOKEN: TOKEN,
  });
  if (!(await waitHealth(PORT))) { bad('token 模式服务端启动', '超时'); child.kill(); process.exit(1); }

  let r = await attempt(PORT, (c, uid) => ({ mode: 'token', proof: tokenProof(c.nonce, uid, TOKEN) }));
  if (r.kind === 'welcome' && r.msg.authMode === 'token') {
    ok('token 模式:独立推导的 proof 被服务端接受(HMAC 格式一致)');
  } else {
    bad('token 模式 proof 互通', JSON.stringify(r));
  }

  // challenge 结构
  if (r.challenge && /^[0-9a-f]{32}$/.test(r.challenge.nonce ?? '')) {
    ok('challenge.nonce 为 32 位小写十六进制');
  } else {
    bad('challenge.nonce 格式', JSON.stringify(r.challenge));
  }
  if (r.challenge?.authRequired === true && Array.isArray(r.challenge.modes)) {
    ok('challenge 含 authRequired + modes(客户端据此适配 UI)');
  } else {
    bad('challenge 字段', JSON.stringify(r.challenge));
  }

  // 大写十六进制也应被接受(服务端声明会 lowercase 后比较)
  r = await attempt(PORT, (c, uid) => ({
    mode: 'token', proof: tokenProof(c.nonce, uid, TOKEN).toUpperCase(),
  }));
  if (r.kind === 'welcome') ok('proof 大写十六进制同样被接受(大小写不敏感)');
  else bad('大写 proof', JSON.stringify(r));

  // 错误的 key
  r = await attempt(PORT, (c, uid) => ({ mode: 'token', proof: tokenProof(c.nonce, uid, 'wrong') }));
  if (r.kind === 'error' && r.msg.message === 'auth_failed') ok('错误密钥 -> auth_failed');
  else bad('错误密钥', JSON.stringify(r));

  // 分隔符写错(把 ':' 写成 '|')必须失败 —— 证明格式是被真正校验的
  r = await attempt(PORT, (c, uid) => ({
    mode: 'token',
    proof: createHmac('sha256', TOKEN).update(`${c.nonce}|${uid}`).digest('hex'),
  }));
  if (r.kind === 'error' && r.msg.message === 'auth_failed') {
    ok('分隔符写错(| 代替 :)-> auth_failed(格式确实被校验)');
  } else {
    bad('分隔符敏感性', JSON.stringify(r));
  }

  // 不带 auth
  r = await attempt(PORT, () => null);
  if (r.kind === 'error' && r.msg.message === 'auth_required') ok('不带 auth -> auth_required');
  else bad('缺 auth', JSON.stringify(r));

  // nonce 重放:先取一个 nonce,再在新连接上复用它
  const first = await attempt(PORT, (c, uid) => ({ mode: 'token', proof: tokenProof(c.nonce, uid, TOKEN) }));
  const stolen = first.challenge?.nonce;
  r = await attempt(PORT, (_c, uid) => ({ mode: 'token', proof: tokenProof(stolen, uid, TOKEN) }));
  if (r.kind === 'error' && r.msg.message === 'auth_failed') {
    ok('nonce 跨连接重放 -> auth_failed(客户端必须每次重新推导)');
  } else {
    bad('nonce 重放防护', JSON.stringify(r));
  }

  child.kill();
  await new Promise((r) => setTimeout(r, 300));

  // ── circle 模式 ─────────────────────────────────────────────────────────
  const P2 = PORT + 1;
  child = bootServer({
    LARES_PORT: String(P2),
    LARES_AUTH_MODE: 'circle',
    LARES_CIRCLE_PASSCODE: PASSCODE,
  });
  if (!(await waitHealth(P2))) { bad('circle 模式服务端启动', '超时'); child.kill(); process.exit(1); }

  r = await attempt(P2, (c, uid) => ({
    mode: 'circle', circleId: 'home', proof: circleProof(c.nonce, uid, 'home', PASSCODE),
  }));
  if (r.kind === 'welcome' && r.msg.authMode === 'circle') {
    ok('circle 模式:独立推导的 proof 被接受(三段式 HMAC 格式一致)');
  } else {
    bad('circle 模式 proof 互通', JSON.stringify(r));
  }

  // circleId 参与签名 —— 换个 circleId 但沿用原 proof 必须失败
  r = await attempt(P2, (c, uid) => ({
    mode: 'circle', circleId: 'work', proof: circleProof(c.nonce, uid, 'home', PASSCODE),
  }));
  if (r.kind === 'error' && r.msg.message === 'auth_failed') {
    ok('circleId 确实参与签名(换圈沿用旧 proof -> auth_failed)');
  } else {
    bad('circleId 绑定', JSON.stringify(r));
  }

  child.kill();
  await new Promise((r) => setTimeout(r, 200));

  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
