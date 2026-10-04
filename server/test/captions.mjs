// 实时字幕 token 代签(cap_token)端到端验证:真实服务端进程 + 本地假 DashScope token 端点。
//
// 与其它测试同一纪律:**不 import 服务端代码**,只看线上收发。
// 覆盖:未握手/未鉴权拒绝、不在房拒绝、E2EE 圈需显式同意、每人限流、
// 未配置 Key(welcome.captions=false + not_configured + 启动日志)、上游报错。
//
// 用法:node test/captions.mjs     (DEBUG=1 显示服务端 stderr)

import { spawn } from 'node:child_process';
import http from 'node:http';
import { createHmac, createHash, randomBytes } from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
import { argon2id } from 'hash-wasm';

const PORT = 18970; // 字幕开启
const PORT_OFF = 18971; // 未配置
const GLOBAL_PASS = 'cap-global-' + randomBytes(4).toString('hex');
const FAKE_KEY = 'sk-test-' + randomBytes(8).toString('hex');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = path.join(HERE, '..');

let pass = 0;
let fail = 0;
function check(cond, name, detail) {
  if (cond) { console.log('  ✓', name); pass++; } else { console.log('  ✗', name, '—', JSON.stringify(detail)); fail++; }
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const hmac = (k, m) => createHmac('sha256', k).update(m, 'utf8').digest('hex');
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const verifierOf = (passcode, circleId) => argon2id({
  password: passcode, salt: `lares-auth-v2:${circleId}`,
  parallelism: 1, iterations: 3, memorySize: 64 * 1024, hashLength: 32, outputType: 'hex',
});
const newCircleId = () => {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  let out = '';
  for (const b of randomBytes(26)) out += alphabet[b & 31];
  return 'c_' + out;
};
const v1Auth = (cid) => (nonce, uid) => ({ mode: 'circle', circleId: cid, nonce, proof: hmac(GLOBAL_PASS, `${nonce}:${uid}:${cid}`) });

// ── 假 DashScope token 端点 ──
function startFakeDashscope() {
  const requests = [];
  let mode = 'ok'; // ok | error
  let n = 0;
  const server = http.createServer((req, res) => {
    requests.push({ method: req.method, url: req.url, auth: req.headers.authorization });
    if (mode === 'error') {
      res.writeHead(500, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ code: 'InternalError', message: `leak ${FAKE_KEY}` }));
    }
    n++;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ token: `st-fake-${n}`, expires_at: Math.floor(Date.now() / 1000) + 300 }));
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port,
    requests,
    setMode: (m) => { mode = m; },
    close: () => new Promise((r) => server.close(r)),
  })));
}

function boot(port, dataDir, extra = {}) {
  const base = { ...process.env };
  for (const k of Object.keys(base)) if (k.startsWith('LARES_') || k.startsWith('LIVEKIT_')) delete base[k];
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...base,
      LARES_PORT: String(port),
      LARES_AUTH_MODE: 'circle',
      LARES_CIRCLE_PASSCODE: GLOBAL_PASS,
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

async function waitHealth(port, ms = 8000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return true; } catch {}
    await wait(100);
  }
  return false;
}

async function stop(child) {
  if (!child || child.exitCode !== null) return;
  const done = new Promise((r) => child.once('exit', r));
  child.kill();
  await done;
}

/// 建连接。auth=null 时**不发 hello**(用来测「没握手就要 token」)。
function connect(port, { userId = 'u_' + randomBytes(3).toString('hex'), auth, hello = true } = {}) {
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
      async capToken(extra = {}) {
        for (let i = inbox.length - 1; i >= 0; i--) if (inbox[i].t === 'cap_token' || inbox[i].t === 'cap_error') inbox.splice(i, 1);
        api.send({ t: 'cap_token', ...extra });
        return api.waitFor((x) => x.t === 'cap_token' || x.t === 'cap_error', 5000);
      },
      close: () => new Promise((res) => {
        if (ws.readyState === ws.CLOSED) return res();
        ws.once('close', () => res());
        try { ws.close(); } catch { res(); }
      }),
    };
    const finish = (v) => { if (!settled) { settled = true; resolve(Object.assign(api, v)); } };
    const timer = setTimeout(() => finish({ kind: 'timeout' }), 6000);
    ws.on('message', async (raw) => {
      let m; try { m = JSON.parse(raw); } catch { return; }
      if (m.t === 'challenge') {
        if (!hello) { clearTimeout(timer); finish({ kind: 'challenge' }); return; }
        const a = await auth(m.nonce, userId);
        ws.send(JSON.stringify({ t: 'hello', userId, deviceId: 'd-' + userId, name: userId, platform: 'windows', auth: a }));
        return;
      }
      const w = waiters.find((x) => x.pred(m));
      if (w) { clearTimeout(w.timer); waiters.splice(waiters.indexOf(w), 1); w.res(m); } else inbox.push(m);
      if (m.t === 'welcome') { clearTimeout(timer); finish({ kind: 'welcome', msg: m }); }
      if (m.t === 'error' && !settled) { clearTimeout(timer); finish({ kind: 'error', msg: m }); }
    });
    ws.on('close', (code) => { clearTimeout(timer); finish({ kind: 'close', code }); });
    ws.on('error', () => { clearTimeout(timer); finish({ kind: 'wserror' }); });
  });
}

async function join(c, circleId) {
  c.send({ t: 'join', circleId });
  return c.waitFor((m) => m.t === 'room' && m.circleId === circleId);
}

async function main() {
  const fake = await startFakeDashscope();
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-cap-'));
  const child = boot(PORT, dataDir, {
    LARES_DASHSCOPE_API_KEY: FAKE_KEY,
    LARES_DASHSCOPE_BASE: `http://127.0.0.1:${fake.port}`,
    LARES_CAP_PER_USER_PER_HOUR: '3',
  });
  const open = [];
  const C = async (opts) => { const c = await connect(PORT, opts); open.push(c); return c; };
  try {
    if (!(await waitHealth(PORT))) throw new Error('服务端启动超时');
    await wait(100);
    console.log('\n[启用]');
    check(/实时字幕已启用/.test(child.out) && !child.out.includes(FAKE_KEY), '启动日志:字幕已启用,且不含 Key', child.out);

    // ── 1. 未握手 ──
    console.log('\n[鉴权闸门]');
    const anon = await C({ hello: false });
    let r = await anon.capToken();
    check(r?.t === 'cap_error' && r.reason === 'say_hello_first', '未 hello 要 token -> cap_error say_hello_first', r);
    check(fake.requests.length === 0, '未握手时上游一次都没被调用', fake.requests.length);

    // ── 2. 已握手但不在房 ──
    const cid = 'capc_' + randomBytes(3).toString('hex');
    const alice = await C({ userId: 'u_alice', auth: v1Auth(cid) });
    check(alice.msg?.captions === true, 'welcome.captions === true', alice.msg);
    r = await alice.capToken();
    check(r?.t === 'cap_error' && r.reason === 'not_in_room', '不在房 -> cap_error not_in_room', r);

    // ── 3. 在房 -> 拿到 token ──
    console.log('\n[签发]');
    await join(alice, cid);
    r = await alice.capToken();
    check(r?.t === 'cap_token' && /^st-fake-/.test(r.token), '在房 -> cap_token 带 st- token', r);
    check(r?.url === 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime' && r?.model === 'qwen3-asr-flash-realtime', '回执带 url / model', r);
    check(typeof r?.expiresAt === 'number' && r.expiresAt > Date.now() && r.expiresAt < Date.now() + 400_000, 'expiresAt 为毫秒且约 5 分钟后', r?.expiresAt);
    const last = fake.requests.at(-1);
    check(last?.method === 'POST' && last?.url === '/api/v1/tokens?expire_in_seconds=300', '上游请求:POST /api/v1/tokens?expire_in_seconds=300', last);
    check(last?.auth === `Bearer ${FAKE_KEY}`, '上游请求带 Bearer 长期 Key', last?.auth?.slice(0, 10));
    check(!JSON.stringify(r).includes(FAKE_KEY), '下发给客户端的回执里没有长期 Key', null);

    // ── 4. 退房后不再签 ──
    alice.send({ t: 'leave' });
    await wait(100);
    r = await alice.capToken();
    check(r?.t === 'cap_error' && r.reason === 'not_in_room', '退房后 -> not_in_room', r);

    // ── 5. 每人限流(测试里设为 3/小时)──
    console.log('\n[限流]');
    const bob = await C({ userId: 'u_bob', auth: v1Auth(cid) });
    await join(bob, cid);
    const got = [];
    for (let i = 0; i < 4; i++) got.push(await bob.capToken());
    check(got.slice(0, 3).every((x) => x?.t === 'cap_token'), '前 3 次签发成功', got.map((x) => x?.t));
    check(got[3]?.t === 'cap_error' && got[3].reason === 'rate_limited', '第 4 次 -> rate_limited', got[3]);
    const carol = await C({ userId: 'u_carol', auth: v1Auth(cid) });
    await join(carol, cid);
    r = await carol.capToken();
    check(r?.t === 'cap_token', '限流按人计:别人不受影响', r);

    // ── 6. 上游报错 ──
    console.log('\n[上游错误]');
    fake.setMode('error');
    const dave = await C({ userId: 'u_dave', auth: v1Auth(cid) });
    await join(dave, cid);
    r = await dave.capToken();
    check(r?.t === 'cap_error' && r.reason === 'upstream_error', '上游 500 -> cap_error upstream_error', r);
    check(!JSON.stringify(r).includes(FAKE_KEY), '错误回执不回显上游响应体', r);
    await wait(100);
    check(!child.out.includes(FAKE_KEY), '服务端日志不含 Key(上游回显了也不打)', null);
    check(child.exitCode === null, '上游出错服务端不崩', child.exitCode);
    fake.setMode('ok');

    // ── 7. E2EE 圈:需显式同意 ──
    console.log('\n[E2EE 同意]');
    const R = newCircleId();
    const PASS1 = 'maple-river-quiet-lamp';
    const ownerKey = randomBytes(32).toString('hex');
    const verifier = await verifierOf(PASS1, R);
    const v2 = (extra = {}) => (nonce, uid) => ({ mode: 'circle', v: 2, circleId: R, nonce, proof: hmac(verifier, `${nonce}:${uid}:${R}`), ...extra });
    const owner = await C({ userId: 'u_owner', auth: v2({ register: { verifier, ownerHash: sha256(ownerKey) } }) });
    check(owner.msg?.circle?.created === true, '注册圈建好', owner.msg?.circle);
    owner.send({ t: 'circle_e2ee_set', circleId: R, enabled: true, ownerKey });
    await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_e2ee_set');
    await join(owner, R);
    r = await owner.capToken();
    check(r?.t === 'cap_error' && r.reason === 'e2ee_opt_in_required', 'E2EE 圈不带 e2eeOptIn -> e2ee_opt_in_required', r);
    r = await owner.capToken({ e2eeOptIn: 'yes' });
    check(r?.t === 'cap_error' && r.reason === 'e2ee_opt_in_required', 'e2eeOptIn 必须是布尔 true', r);
    r = await owner.capToken({ e2eeOptIn: true });
    check(r?.t === 'cap_token', 'E2EE 圈带 e2eeOptIn:true -> 签发', r);
    owner.send({ t: 'circle_e2ee_set', circleId: R, enabled: false, ownerKey });
    await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_e2ee_set');
    r = await owner.capToken();
    check(r?.t === 'cap_token', '圈主关掉 E2EE 后无需同意', r);
  } finally {
    for (const c of open) await c.close();
    await stop(child);
  }

  // ── 8. 未配置 ──
  console.log('\n[未配置]');
  const offDir = mkdtempSync(path.join(tmpdir(), 'lares-cap-off-'));
  const off = boot(PORT_OFF, offDir);
  try {
    if (!(await waitHealth(PORT_OFF))) throw new Error('未配置模式启动超时');
    await wait(100);
    const logs = off.out.match(/captions disabled/g) ?? [];
    check(logs.length === 1, '启动日志恰好一行 captions disabled', off.out);
    const before = fake.requests.length;
    const a = await connect(PORT_OFF, { userId: 'u_off', auth: v1Auth('off') });
    check(a.msg?.captions === false, 'welcome.captions === false', a.msg);
    await join(a, 'off');
    const r = await a.capToken();
    check(r?.t === 'cap_error' && r.reason === 'not_configured', '未配置 -> cap_error not_configured', r);
    check(fake.requests.length === before, '未配置时不调上游', fake.requests.length - before);
    await a.close();
  } finally {
    await stop(off);
    await fake.close();
  }

  console.log(`\n${pass} 通过,${fail} 失败`);
  // Node 24/Windows: process.exit() 遇到正在关闭的句柄会触发 libuv 断言崩溃;改为设退出码,稍后再退
  process.exitCode = fail ? 1 : 0;
  setTimeout(() => process.exit(), 300).unref();
}

main().catch((e) => { console.error(e); process.exit(1); });
