// 测试公用件:起服务端进程、原始 WS 客户端、v1/v2 鉴权证明。
// 纪律同其它测试:**不 import 服务端代码**,只看线上收发与磁盘。

import { spawn } from 'node:child_process';
import { createHmac, createHash, randomBytes } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
import { argon2id } from 'hash-wasm';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const SERVER_DIR = path.join(HERE, '..', '..');

export const wait = (ms) => new Promise((r) => setTimeout(r, ms));
export const hmac = (k, m) => createHmac('sha256', k).update(m, 'utf8').digest('hex');
export const sha256 = (s) => createHash('sha256').update(s).digest('hex');
export const verifierOf = (passcode, circleId) => argon2id({
  password: passcode, salt: `lares-auth-v2:${circleId}`,
  parallelism: 1, iterations: 3, memorySize: 64 * 1024, hashLength: 32, outputType: 'hex',
});
export const newCircleId = () => {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  let out = '';
  for (const b of randomBytes(26)) out += alphabet[b & 31];
  return 'c_' + out;
};

export function makeChecker() {
  const st = { pass: 0, fail: 0 };
  st.check = (cond, name, detail) => {
    if (cond) { console.log('  ✓', name); st.pass++; } else { console.log('  ✗', name, '—', JSON.stringify(detail)?.slice(0, 600)); st.fail++; }
  };
  return st;
}

export function boot(port, dataDir, globalPass, extra = {}) {
  const base = { ...process.env };
  for (const k of Object.keys(base)) if (k.startsWith('LARES_') || k.startsWith('LIVEKIT_')) delete base[k];
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...base,
      LARES_PORT: String(port),
      LARES_AUTH_MODE: 'circle',
      LARES_CIRCLE_PASSCODE: globalPass,
      LARES_DATA_DIR: dataDir,
      ...extra,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.out = '';
  child.stdout.on('data', (d) => { child.out += d; });
  child.stderr.on('data', (d) => { child.out += d; if (process.env.DEBUG) process.stderr.write(d); });
  return child;
}

export async function waitHealth(port, ms = 10000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return true; } catch {}
    await wait(100);
  }
  return false;
}

export async function stop(child) {
  if (!child || child.exitCode !== null) return;
  const done = new Promise((r) => child.once('exit', r));
  child.kill();
  await done;
}

/// v1 证明(全站兜底口令圈)
export const v1Auth = (pass, cid) => (nonce, uid) => ({ mode: 'circle', circleId: cid, nonce, proof: hmac(pass, `${nonce}:${uid}:${cid}`) });
/// v2 证明(注册圈);extra 可带 register / ownerKey
export const v2Auth = (verifier, cid, extra = {}) => (nonce, uid) => ({ mode: 'circle', v: 2, circleId: cid, nonce, proof: hmac(verifier, `${nonce}:${uid}:${cid}`), ...extra });

export function connect(port, { userId = 'u_' + randomBytes(3).toString('hex'), deviceId, name, auth } = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    const inbox = [];
    const waiters = [];
    let settled = false;
    const api = {
      ws, inbox, userId,
      send: (m) => ws.send(JSON.stringify(m)),
      waitFor(pred, ms = 3000) {
        const idx = inbox.findIndex(pred);
        if (idx >= 0) return Promise.resolve(inbox.splice(idx, 1)[0]);
        return new Promise((res) => {
          const w = { pred, res, timer: setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); res(null); }, ms) };
          waiters.push(w);
        });
      },
      /// 发一条并等回执
      async req(msg, pred, ms = 3000) {
        api.send(msg);
        return api.waitFor(pred, ms);
      },
      drain(pred) { for (let i = inbox.length - 1; i >= 0; i--) if (pred(inbox[i])) inbox.splice(i, 1); },
      close: () => new Promise((res) => {
        if (ws.readyState === ws.CLOSED) return res();
        ws.once('close', () => res());
        try { ws.close(); } catch { res(); }
      }),
    };
    const finish = (v) => { if (!settled) { settled = true; resolve(Object.assign(api, v)); } };
    const timer = setTimeout(() => finish({ kind: 'timeout' }), 8000);
    ws.on('message', async (raw) => {
      let m; try { m = JSON.parse(raw); } catch { return; }
      if (m.t === 'challenge') {
        const a = await auth(m.nonce, userId);
        ws.send(JSON.stringify({ t: 'hello', userId, deviceId: deviceId ?? 'd-' + userId, name: name ?? userId, platform: 'windows', auth: a }));
        return;
      }
      const w = waiters.find((x) => x.pred(m));
      if (w) { clearTimeout(w.timer); waiters.splice(waiters.indexOf(w), 1); w.res(m); } else inbox.push(m);
      if (m.t === 'welcome') { clearTimeout(timer); finish({ kind: 'welcome', msg: m }); }
      if (m.t === 'error' && !settled) { clearTimeout(timer); finish({ kind: 'error', msg: m }); }
    });
    ws.on('close', (code) => { clearTimeout(timer); api.closedCode = code; finish({ kind: 'close', code }); });
    ws.on('error', () => { clearTimeout(timer); finish({ kind: 'wserror' }); });
  });
}

export async function join(c, circleId) {
  c.send({ t: 'join', circleId });
  return c.waitFor((m) => m.t === 'room' && m.circleId === circleId);
}

/// 注册一个新圈,返回 {cid, verifier, ownerKey, owner(已连上的圈主连接)}
export async function registerCircle(port, passcode, ownerUserId = 'u_owner') {
  const cid = newCircleId();
  const verifier = await verifierOf(passcode, cid);
  const ownerKey = randomBytes(32).toString('hex');
  const owner = await connect(port, { userId: ownerUserId, auth: v2Auth(verifier, cid, { register: { verifier, ownerHash: sha256(ownerKey) } }) });
  if (owner.kind !== 'welcome') throw new Error('注册圈失败: ' + JSON.stringify(owner.msg ?? owner.code));
  return { cid, verifier, ownerKey, owner };
}

export const ownerReply = (op) => (m) => (m.t === 'owner_ok' || m.t === 'owner_error') && m.op === op;
