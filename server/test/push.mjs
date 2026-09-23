// iOS 推送(APNs)端到端验证:真实服务端进程 + 本地假 APNs(HTTP/2 + TLS)。
//
// 与其它测试同一纪律:**不 import 服务端代码**。假 APNs 只看线上收到的东西:
// 路径、头、JWT(用公钥真验签)、payload。
//
// TLS 证书用 test/fixtures/ 里提交的「测试专用」自签证书 —— Node 不能原生生成 X.509,
// 而 CI / node:22-alpine 里不保证有 openssl。见 test/fixtures/README.md。
//
// 用法:node test/push.mjs     (DEBUG=1 显示服务端 stderr)

import { spawn } from 'node:child_process';
import http2 from 'node:http2';
import crypto, { createHmac, createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
import { argon2id } from 'hash-wasm';

const PORT = 18960; // 推送开启
const PORT_OFF = 18961; // 推送未配置
const GLOBAL_PASS = 'push-global-' + randomBytes(4).toString('hex');
const PUBLIC_URL = 'wss://lares.test:8444/ws';
const KEY_ID = 'TESTKEY123';
const TEAM_ID = '7CH28564U7';
const ACTIVE_WIN = 3000; // 测试用节流窗口(要比第 2~3 节的耗时长,否则「窗口内」断言会误过期)
const REACH_WIN = 1500;
const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = path.join(HERE, '..');

let pass = 0;
let fail = 0;
function check(cond, name, detail) {
  if (cond) { console.log('  ✓', name); pass++; } else { console.log('  ✗', name, '—', JSON.stringify(detail)); fail++; }
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const tok = () => randomBytes(32).toString('hex');

// ── 独立推导(与 circle_registry.mjs 相同)──
const hmac = (k, m) => createHmac('sha256', k).update(m, 'utf8').digest('hex');
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
const newCircleId = () => {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  let out = '';
  for (const b of randomBytes(26)) out += alphabet[b & 31];
  return 'c_' + out;
};
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
// 全站兜底口令 + v1:对任意 circleId 都成立,省掉 Argon2
const v1Auth = (cid) => (nonce, uid) => ({ mode: 'circle', circleId: cid, nonce, proof: hmac(GLOBAL_PASS, `${nonce}:${uid}:${cid}`) });
const v2Auth = (cid, passcode, extra = {}) => async (nonce, uid) => ({
  mode: 'circle', v: 2, circleId: cid, nonce,
  proof: hmac(await verifierOf(passcode, cid), `${nonce}:${uid}:${cid}`),
  ...(typeof extra === 'function' ? await extra() : extra),
});

// ── 假 APNs ──
function startFakeApns() {
  const requests = [];
  const script = new Map(); // token -> { status, reason }
  const server = http2.createSecureServer({
    cert: readFileSync(path.join(HERE, 'fixtures', 'fake-apns-TEST-ONLY.cert.pem')),
    key: readFileSync(path.join(HERE, 'fixtures', 'fake-apns-TEST-ONLY.key.pem')),
  });
  server.on('stream', (stream, headers) => {
    const chunks = [];
    stream.on('data', (c) => chunks.push(c));
    stream.on('end', () => {
      const p = headers[':path'];
      const token = p.startsWith('/3/device/') ? p.slice('/3/device/'.length) : '';
      let body = null;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* 留 null */ }
      requests.push({ at: Date.now(), path: p, method: headers[':method'], token, headers: { ...headers }, body, raw: Buffer.concat(chunks).toString('utf8') });
      const r = script.get(token);
      if (r) {
        stream.respond({ ':status': r.status, 'content-type': 'application/json' });
        stream.end(JSON.stringify({ reason: r.reason }));
      } else {
        stream.respond({ ':status': 200, 'apns-id': crypto.randomUUID() });
        stream.end();
      }
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({
        port: server.address().port,
        requests,
        script,
        forToken: (t) => requests.filter((r) => r.token === t),
        async waitFor(pred, ms = 2000) {
          const end = Date.now() + ms;
          while (Date.now() < end) {
            const hit = requests.find(pred);
            if (hit) return hit;
            await wait(20);
          }
          return null;
        },
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

// ── 服务端进程 ──
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

/// 建连接并完成握手;成功返回带 inbox / waitFor 的客户端
function connect(port, { userId = 'u_' + randomBytes(3).toString('hex'), name = userId, auth } = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    const inbox = [];
    const waiters = [];
    let closeCode = null;
    let settled = false;
    const api = {
      ws, inbox, userId,
      get closeCode() { return closeCode; },
      send: (m) => ws.send(JSON.stringify(m)),
      waitFor(pred, ms = 3000) {
        const idx = inbox.findIndex(pred);
        if (idx >= 0) return Promise.resolve(inbox.splice(idx, 1)[0]);
        return new Promise((res) => {
          const w = { pred, res, timer: setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); res(null); }, ms) };
          waiters.push(w);
        });
      },
      /// 发一条消息并等某类回复(先清掉旧的同类)
      async ask(m, t, ms = 3000) {
        for (let i = inbox.length - 1; i >= 0; i--) if (inbox[i].t === t) inbox.splice(i, 1);
        api.send(m);
        return api.waitFor((x) => x.t === t, ms);
      },
      waitClose(ms = 3000) {
        if (closeCode !== null) return Promise.resolve(closeCode);
        return new Promise((res) => {
          const t = setTimeout(() => res(null), ms);
          ws.once('close', (c) => { clearTimeout(t); res(c); });
        });
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
        const a = await auth(m.nonce, userId);
        ws.send(JSON.stringify({ t: 'hello', userId, deviceId: 'd-' + userId, name, platform: 'ios', ...(a ? { auth: a } : {}) }));
        return;
      }
      const w = waiters.find((x) => x.pred(m));
      if (w) { clearTimeout(w.timer); waiters.splice(waiters.indexOf(w), 1); w.res(m); } else inbox.push(m);
      if (m.t === 'welcome') { clearTimeout(timer); finish({ kind: 'welcome', msg: m }); }
      if (m.t === 'error' && !settled) { clearTimeout(timer); finish({ kind: 'error', msg: m }); }
    });
    ws.on('close', (code) => { closeCode = code; clearTimeout(timer); finish({ kind: 'close', code }); });
    ws.on('error', () => { clearTimeout(timer); finish({ kind: 'wserror' }); });
  });
}

const reg = (token, circles, { env = 'sandbox', lang = 'zh' } = {}) => ({
  t: 'push_register', provider: 'apns', token, env, lang,
  circles: circles.map((c) => (typeof c === 'string' ? { circleId: c, name: `name-${c}`, muted: false } : c)),
});

async function join(c, circleId) {
  c.send({ t: 'join', circleId });
  return c.waitFor((m) => m.t === 'room' && m.circleId === circleId);
}
async function leave(c) {
  c.send({ t: 'leave' });
  await wait(80);
}

/// 等一小段时间,断言这段时间里某 token 没有收到推送
async function noPush(fake, token, since, ms = 400) {
  await wait(ms);
  return fake.requests.filter((r) => r.token === token && r.at >= since).length === 0;
}

function readSubs(dataDir) {
  const f = path.join(dataDir, 'push_subscriptions.json');
  return existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : null;
}
async function waitSubs(dataDir, pred, ms = 2000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { const s = readSubs(dataDir); if (s && pred(s)) return s; } catch { /* 正在 rename */ }
    await wait(30);
  }
  return readSubs(dataDir);
}

function b64urlJson(s) { return JSON.parse(Buffer.from(s, 'base64url').toString('utf8')); }

async function main() {
  console.log('iOS 推送(APNs)\n');
  const fake = await startFakeApns();
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const keyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const apnsEnv = (keyForm = keyPem) => ({
    LARES_APNS_KEY: keyForm,
    LARES_APNS_KEY_ID: KEY_ID,
    LARES_APNS_TEAM_ID: TEAM_ID,
    LARES_APNS_HOST_OVERRIDE: `https://127.0.0.1:${fake.port}`,
    LARES_APNS_INSECURE_TLS: '1',
    LARES_PUBLIC_URL: PUBLIC_URL,
    LARES_PUSH_ACTIVE_THROTTLE_MS: String(ACTIVE_WIN),
    LARES_PUSH_REACH_THROTTLE_MS: String(REACH_WIN),
  });

  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-push-'));
  let child = boot(PORT, dataDir, apnsEnv());
  const open = [];
  const C = async (opts) => { const c = await connect(PORT, opts); open.push(c); return c; };
  try {
    if (!(await waitHealth(PORT))) throw new Error('服务端启动超时');
    await wait(100);
    check(/APNs 已启用/.test(child.out), '启动日志:APNs 已启用', child.out);

    // ── 1. 入参校验 ──
    console.log('\n[校验]');
    {
      // 握手前
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
      const got = await new Promise((res) => {
        ws.on('message', (raw) => {
          const m = JSON.parse(raw);
          if (m.t === 'challenge') ws.send(JSON.stringify(reg(tok(), ['x'])));
          if (m.t === 'push_error') res(m);
        });
        setTimeout(() => res(null), 2000);
      });
      check(got?.reason === 'say_hello_first', '握手前 push_register -> say_hello_first', got);
      ws.close();

      const c = await C({ auth: v1Auth('v1') });
      let r = await c.ask({ ...reg(tok(), ['v1']), provider: 'fcm' }, 'push_error');
      check(r?.reason === 'bad_provider', 'provider≠apns -> bad_provider', r);
      r = await c.ask(reg('abc123', ['v1']), 'push_error');
      check(r?.reason === 'bad_token', '短 token -> bad_token', r);
      r = await c.ask(reg('z'.repeat(64), ['v1']), 'push_error');
      check(r?.reason === 'bad_token', '非 hex token -> bad_token', r);
      r = await c.ask(reg(tok(), ['v1'], { env: 'staging' }), 'push_error');
      check(r?.reason === 'bad_env', 'env 非法 -> bad_env', r);
      r = await c.ask({ t: 'push_mute', circleId: 'v1', muted: true, token: tok() }, 'push_error');
      check(r?.reason === 'not_subscribed', '对未登记 token push_mute -> not_subscribed', r);
      await c.close();
    }

    // ── 2. 基本 active 推送:头、JWT、payload、中文 ──
    console.log('\n[active 推送]');
    const c1 = 'pc1';
    const TB = tok();
    const TA = tok();
    const TC = tok();
    const bob = await C({ userId: 'u_bob', name: 'Bob', auth: v1Auth(c1) });
    // 大写 token:应被接受并以小写存储
    let r = await bob.ask(reg(TB.toUpperCase(), [{ circleId: c1, name: '  家里的圈子' + 'x'.repeat(80), muted: false }], { lang: 'zh' }), 'push_registered');
    check(r && r.circles.length === 1 && r.circles[0] === c1 && r.rejected.length === 0, 'push_registered 回执 circles/rejected', r);
    const alice = await C({ userId: 'u_alice', name: 'Alice', auth: v1Auth(c1) });
    r = await alice.ask(reg(TA, [c1], { lang: 'en' }), 'push_registered');
    const carol = await C({ userId: 'u_carol', name: 'Carol', auth: v1Auth(c1) });
    r = await carol.ask(reg(TC, [{ circleId: c1, name: 'Home' }], { lang: 'en', env: 'production' }), 'push_registered');
    let subs = await waitSubs(dataDir, (s) => s[TB] && s[TA] && s[TC]);
    check(subs?.[TB] && !subs[TB.toUpperCase()], 'token 以小写落盘', Object.keys(subs ?? {}));
    check(subs?.[TB]?.circles?.[c1]?.name === ('家里的圈子' + 'x'.repeat(80)).slice(0, 64), '圈名 trim 后截到 64 字符', subs?.[TB]?.circles?.[c1]);
    const e = subs?.[TB];
    check(e && e.userId === 'u_bob' && e.deviceId === 'd-u_bob' && e.env === 'sandbox' && e.lang === 'zh'
      && e.circles[c1].muted === false && typeof e.updatedAt === 'number', '订阅表条目形状 {userId,deviceId,env,lang,circles,updatedAt}', e);

    // Carol 先断开,让她「不在线」;Bob 在大厅但不在房里
    await carol.close();
    let t0 = Date.now();
    await join(alice, c1);
    const pb = await fake.waitFor((q) => q.token === TB && q.at >= t0);
    const pc = await fake.waitFor((q) => q.token === TC && q.at >= t0);
    check(Boolean(pb), '空圈来人 -> 推给订阅者 Bob', fake.requests.length);
    check(await noPush(fake, TA, t0, 100), '进房者自己的 token 不推(not-self)', fake.forToken(TA).length);
    if (pb) {
      check(pb.method === 'POST' && pb.path === `/3/device/${TB}`, 'POST /3/device/<token>', pb.path);
      const h = pb.headers;
      check(h['apns-push-type'] === 'alert' && h['apns-priority'] === '10', 'apns-push-type=alert, apns-priority=10', h);
      check(h['apns-topic'] === 'com.lfm097384.lares', 'apns-topic 默认 com.lfm097384.lares', h['apns-topic']);
      check(h['apns-collapse-id'] === c1, 'apns-collapse-id = circleId', h['apns-collapse-id']);
      const exp = Number(h['apns-expiration']);
      const nowS = Math.floor(Date.now() / 1000);
      check(exp > nowS + 3500 && exp <= nowS + 3601, 'apns-expiration ≈ now+1h', exp - nowS);
      const auth = String(h.authorization ?? '');
      check(auth.startsWith('bearer '), 'authorization: bearer <jwt>', auth.slice(0, 12));
      const [hh, cc, ss] = auth.slice(7).split('.');
      const jh = b64urlJson(hh);
      const jc = b64urlJson(cc);
      check(jh.alg === 'ES256' && jh.kid === KEY_ID, 'JWT header {alg:ES256, kid}', jh);
      check(jc.iss === TEAM_ID && Math.abs(jc.iat - nowS) < 120, 'JWT claims {iss:TEAM_ID, iat 新鲜}', jc);
      const sigOk = crypto.verify('sha256', Buffer.from(`${hh}.${cc}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(ss, 'base64url'));
      check(sigOk, 'JWT 签名可用公钥验证(ES256 / ieee-p1363)', null);
      const b = pb.body;
      check(b?.aps?.alert?.title === ('家里的圈子' + 'x'.repeat(80)).slice(0, 64) && b?.aps?.alert?.body === 'Alice 在圈里', '中文文案:标题=圈名,正文「Alice 在圈里」', b?.aps?.alert);
      check(b?.aps?.sound === 'default' && b?.aps?.category === 'LARES_JOIN' && b?.aps?.['thread-id'] === c1
        && b?.aps?.['interruption-level'] === 'time-sensitive', 'aps: sound/category/thread-id/interruption-level', b?.aps);
      check(b?.lares?.circleId === c1 && b?.lares?.server === PUBLIC_URL && b?.lares?.kind === 'active', 'lares: {circleId, server, kind:active}', b?.lares);
    }
    if (pc) {
      check(pc.body?.aps?.alert?.title === 'Home' && pc.body?.aps?.alert?.body === 'Alice is in the circle', '英文文案「Alice is in the circle」', pc.body?.aps?.alert);
    }
    const jwts = new Set(fake.requests.map((q) => q.headers.authorization));
    check(jwts.size === 1, 'JWT 被缓存复用(多条推送同一个 provider token)', jwts.size);

    // ── 3. 房里已经有人:再进人不推;在房里的订阅者不推 ──
    console.log('\n[非空房 / 在房里]');
    t0 = Date.now();
    await join(bob, c1); // 房里已有 Alice
    check(await noPush(fake, TA, t0, 300) && await noPush(fake, TB, t0, 0) && await noPush(fake, TC, t0, 0),
      '房间非空时再进人:谁都不推(含在房里的 Alice)', fake.requests.filter((q) => q.at >= t0).length);

    // ── 4. 节流 ──
    console.log('\n[节流]');
    await leave(bob);
    await leave(alice);
    t0 = Date.now();
    await join(alice, c1); // 窗口内第二次「空 → 有人」
    check(await noPush(fake, TB, t0, 400), `${ACTIVE_WIN}ms 窗口内第二次 active 不推`, fake.forToken(TB).length);
    await leave(alice);
    await wait(ACTIVE_WIN + 100);
    t0 = Date.now();
    await join(alice, c1);
    check(Boolean(await fake.waitFor((q) => q.token === TB && q.at >= t0)), '窗口过后再次推送', fake.forToken(TB).length);

    // ── 5. 静音 ──
    console.log('\n[静音]');
    r = await bob.ask({ t: 'push_mute', circleId: c1, muted: true }, 'push_registered');
    check(r?.circles?.includes(c1), 'push_mute(token 缺省用本连接登记的)-> push_registered', r);
    r = await bob.ask({ t: 'push_mute', circleId: 'not-mine', muted: true }, 'push_error');
    check(r?.reason === 'not_subscribed', 'push_mute 未订阅的圈 -> not_subscribed', r);
    subs = await waitSubs(dataDir, (s) => s[TB]?.circles?.[c1]?.muted === true);
    check(subs?.[TB]?.circles?.[c1]?.muted === true, '静音已落盘', subs?.[TB]);
    await leave(alice);
    await wait(ACTIVE_WIN + 100);
    t0 = Date.now();
    await join(alice, c1);
    check(await noPush(fake, TB, t0, 400), '静音后不推', fake.forToken(TB).length);
    // 别人不能改我的静音
    const mallory = await C({ userId: 'u_mallory', auth: v1Auth(c1) });
    r = await mallory.ask({ t: 'push_mute', circleId: c1, muted: false, token: TB }, 'push_error');
    check(r?.reason === 'not_subscribed', '别人的 token 不能 push_mute', r);
    r = await mallory.ask({ t: 'push_unregister', token: TB }, 'push_unregistered');
    await wait(100);
    check(readSubs(dataDir)?.[TB], '别人的 token 不能 push_unregister', null);
    await mallory.close();
    await leave(alice);

    // ── 6. circle 模式越界订阅 + 跨连接累积 + 从清单删除 ──
    console.log('\n[授权 / 累积 / 删除]');
    const c3 = 'pc3';
    const c4 = 'pc4';
    const TE = tok();
    let eve = await C({ userId: 'u_eve', name: 'Eve', auth: v1Auth(c3) });
    r = await eve.ask(reg(TE, [c3, c4]), 'push_registered');
    check(r?.circles?.length === 1 && r.circles[0] === c3 && r.rejected?.length === 1 && r.rejected[0] === c4,
      '只证明了 c3 的连接登记 [c3,c4] -> c4 进 rejected', r);
    await eve.close();
    const frank = await C({ userId: 'u_frank', name: 'Frank', auth: v1Auth(c4) });
    t0 = Date.now();
    await join(frank, c4);
    check(await noPush(fake, TE, t0, 400), '被拒的圈 c4 有动静 -> 不推给 Eve', fake.forToken(TE).length);
    await leave(frank);
    eve = await C({ userId: 'u_eve', name: 'Eve', auth: v1Auth(c4) });
    r = await eve.ask(reg(TE, [c3, c4]), 'push_registered');
    check(r?.circles?.length === 2 && r.circles.includes(c3) && r.circles.includes(c4) && r.rejected.length === 0,
      '同一 token 再凭 c4 登记 -> c3、c4 都在(跨连接累积)', r);
    await eve.close();
    t0 = Date.now();
    await join(frank, c4);
    check(Boolean(await fake.waitFor((q) => q.token === TE && q.at >= t0)), '累积后 c4 有动静 -> 推给 Eve', fake.forToken(TE).length);
    await leave(frank);
    // 已订阅的圈:即使本连接没证明过,也能改名/改静音
    eve = await C({ userId: 'u_eve', name: 'Eve', auth: v1Auth(c4) });
    r = await eve.ask(reg(TE, [{ circleId: c3, name: 'renamed', muted: false }, c4]), 'push_registered');
    subs = await waitSubs(dataDir, (s) => s[TE]?.circles?.[c3]?.name === 'renamed');
    check(r?.circles?.includes(c3) && subs?.[TE]?.circles?.[c3]?.name === 'renamed', '已订阅但本连接未证明的圈:允许改名', subs?.[TE]);
    // 清单里去掉 c3 -> 退订
    r = await eve.ask(reg(TE, [c4]), 'push_registered');
    check(r?.circles?.length === 1 && r.circles[0] === c4, '清单里删掉 c3 -> 退订 c3', r);
    const frank3 = await C({ userId: 'u_frank3', name: 'Frank', auth: v1Auth(c3) });
    t0 = Date.now();
    await join(frank3, c3);
    check(await noPush(fake, TE, t0, 400), '退订后 c3 有动静不推', fake.forToken(TE).length);
    await frank3.close();
    await eve.close();
    // token 换了主人:旧身份攒下的圈子不继承
    const gina = await C({ userId: 'u_gina', auth: v1Auth(c3) });
    r = await gina.ask(reg(TE, [c3, c4]), 'push_registered');
    check(r?.circles?.length === 1 && r.circles[0] === c3 && r.rejected.includes(c4), 'token 换 userId -> 先清空旧圈,不继承 c4', r);
    subs = await waitSubs(dataDir, (s) => s[TE]?.userId === 'u_gina');
    check(subs?.[TE]?.userId === 'u_gina', '换主后条目归新 userId', subs?.[TE]);
    await gina.close();

    // ── 7. reach ──
    console.log('\n[reach]');
    const c5 = 'pc5';
    const TH = tok();
    const hank = await C({ userId: 'u_hank', name: 'Hank', auth: v1Auth(c5) });
    await hank.ask(reg(TH, [{ circleId: c5, name: 'Work' }], { lang: 'en' }), 'push_registered');
    const ok = await hank.ask({ t: 'available', circleIds: [c5] }, 'available_ok');
    check(Boolean(ok), 'Hank 挂着(available)', ok);
    const ivan = await C({ userId: 'u_ivan', name: 'Ivan', auth: v1Auth(c5) });
    t0 = Date.now();
    ivan.send({ t: 'reach', userId: 'u_hank', circleId: c5 });
    const pr = await fake.waitFor((q) => q.token === TH && q.at >= t0);
    check(pr?.body?.lares?.kind === 'reach' && pr?.body?.lares?.circleId === c5, 'reach -> 推给被找者,kind=reach', pr?.body?.lares);
    check(pr?.body?.aps?.alert?.title === 'Work' && pr?.body?.aps?.alert?.body === 'Ivan is calling you', 'reach 文案「Ivan is calling you」', pr?.body?.aps?.alert);
    await wait(300);
    check(fake.requests.filter((q) => q.token === TH && q.at >= t0).length === 1, 'reach 只推一条(被找者进房引发的 active 不推他自己)',
      fake.requests.filter((q) => q.token === TH && q.at >= t0).map((q) => q.body?.lares?.kind));
    // 60s(测试里 1.5s)内同一对再找 -> 不推
    await leave(hank); await leave(ivan);
    await hank.ask({ t: 'available', circleIds: [c5] }, 'available_ok');
    t0 = Date.now();
    ivan.send({ t: 'reach', userId: 'u_hank', circleId: c5 });
    await hank.waitFor((m) => m.t === 'reached');
    check(await noPush(fake, TH, t0, 400), 'reach 节流窗口内第二次不推', fake.forToken(TH).length);
    await hank.close(); await ivan.close();

    // ── 8. 失效 token 清理 ──
    console.log('\n[失效 token 清理]');
    const c6 = 'pc6';
    const T410 = tok();
    const TBAD = tok();
    const TNFT = tok();
    fake.script.set(T410, { status: 410, reason: 'Unregistered' });
    fake.script.set(TBAD, { status: 400, reason: 'BadDeviceToken' });
    fake.script.set(TNFT, { status: 400, reason: 'DeviceTokenNotForTopic' });
    for (const [uid, t] of [['u_k1', T410], ['u_k2', TBAD], ['u_k3', TNFT]]) {
      const k = await C({ userId: uid, auth: v1Auth(c6) });
      await k.ask(reg(t, [c6]), 'push_registered');
      await k.close();
    }
    await waitSubs(dataDir, (s) => s[T410] && s[TBAD] && s[TNFT]);
    const lena = await C({ userId: 'u_lena', name: 'Lena', auth: v1Auth(c6) });
    t0 = Date.now();
    await join(lena, c6);
    await fake.waitFor((q) => q.token === T410 && q.at >= t0);
    await fake.waitFor((q) => q.token === TBAD && q.at >= t0);
    await fake.waitFor((q) => q.token === TNFT && q.at >= t0);
    subs = await waitSubs(dataDir, (s) => !s[T410] && !s[TBAD] && !s[TNFT]);
    check(subs && !subs[T410], '410 -> 订阅从文件删除', Object.keys(subs ?? {}).length);
    check(subs && !subs[TBAD], '400 BadDeviceToken -> 订阅删除', null);
    check(subs && !subs[TNFT], '400 DeviceTokenNotForTopic -> 订阅删除', null);
    await lena.close();

    // ── 9. E2EE:不带任何名字 ──
    console.log('\n[E2EE]');
    const R = newCircleId();
    const PASS1 = 'maple-river-quiet-lamp';
    const ownerKey = randomBytes(32).toString('hex');
    const owner = await C({
      userId: 'u_owner', name: 'Kevin',
      auth: v2Auth(R, PASS1, async () => ({ register: { verifier: await verifierOf(PASS1, R), ownerHash: sha256(ownerKey) } })),
    });
    check(owner.msg?.circle?.created === true, '注册圈建好', owner.msg?.circle);
    owner.send({ t: 'circle_e2ee_set', circleId: R, enabled: true, ownerKey });
    await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_e2ee_set');
    const TJ = tok();
    const TJ2 = tok();
    const jo = await C({ userId: 'u_jo', auth: v2Auth(R, PASS1) });
    await jo.ask(reg(TJ, [{ circleId: R, name: 'Secret Circle' }], { lang: 'en' }), 'push_registered');
    const jz = await C({ userId: 'u_jz', auth: v2Auth(R, PASS1) });
    await jz.ask(reg(TJ2, [{ circleId: R, name: '秘密小圈' }], { lang: 'zh' }), 'push_registered');
    t0 = Date.now();
    await join(owner, R);
    const pe = await fake.waitFor((q) => q.token === TJ && q.at >= t0);
    const pz = await fake.waitFor((q) => q.token === TJ2 && q.at >= t0);
    check(pe?.body?.aps?.alert?.title === 'Lares' && pe?.body?.aps?.alert?.body === 'Someone is in your circle', 'E2EE 英文:Lares / Someone is in your circle', pe?.body?.aps?.alert);
    check(pz?.body?.aps?.alert?.title === 'Lares' && pz?.body?.aps?.alert?.body === '有人在你的圈子里', 'E2EE 中文:Lares / 有人在你的圈子里', pz?.body?.aps?.alert);
    check(pe && !pe.raw.includes('Kevin') && !pe.raw.includes('Secret Circle') && pz && !pz.raw.includes('Kevin') && !pz.raw.includes('秘密小圈'),
      'E2EE payload 里没有人名、没有圈名', pe?.raw);

    // ── 10. 换口令 / 解散 -> 从所有订阅里摘掉 ──
    console.log('\n[换口令 / 解散]');
    owner.send({ t: 'circle_passcode_set', circleId: R, ownerKey, verifier: await verifierOf('cedar-window-brave-otter', R) });
    await owner.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_passcode_set');
    subs = await waitSubs(dataDir, (s) => !s[TJ]?.circles?.[R] && !s[TJ2]?.circles?.[R]);
    check(subs?.[TJ] && !subs[TJ].circles[R] && !subs[TJ2].circles[R], '换口令 -> 所有订阅摘掉该圈(token 条目保留)', subs?.[TJ]);
    const R2 = newCircleId();
    const owner2Key = randomBytes(32).toString('hex');
    const owner2 = await C({
      userId: 'u_owner2',
      auth: v2Auth(R2, PASS1, async () => ({ register: { verifier: await verifierOf(PASS1, R2), ownerHash: sha256(owner2Key) } })),
    });
    const TM = tok();
    const mo = await C({ userId: 'u_mo', auth: v2Auth(R2, PASS1) });
    await mo.ask(reg(TM, [R2]), 'push_registered');
    await waitSubs(dataDir, (s) => s[TM]?.circles?.[R2]);
    owner2.send({ t: 'circle_delete', circleId: R2, ownerKey: owner2Key });
    await owner2.waitFor((m) => m.t === 'owner_ok' && m.op === 'circle_delete');
    subs = await waitSubs(dataDir, (s) => s[TM] && !s[TM].circles[R2]);
    check(subs?.[TM] && !subs[TM].circles[R2], '解散 -> 订阅里摘掉该圈', subs?.[TM]);

    // ── 11. push_unregister ──
    console.log('\n[注销]');
    r = await bob.ask({ t: 'push_unregister', token: TB }, 'push_unregistered');
    subs = await waitSubs(dataDir, (s) => !s[TB]);
    check(r && subs && !subs[TB], 'push_unregister -> push_unregistered,条目删除', r);
    // 重新登记,静音保持给重启测试用
    await bob.ask(reg(TB, [{ circleId: c1, name: 'Home', muted: true }]), 'push_registered');
    await waitSubs(dataDir, (s) => s[TB]?.circles?.[c1]?.muted === true);

    // ── 12. 重启:订阅表持久化;钥匙用 base64 形态 ──
    console.log('\n[重启持久化 + base64 钥匙]');
    for (const c of open) await c.close();
    open.length = 0;
    await stop(child);
    child = boot(PORT, dataDir, apnsEnv(Buffer.from(keyPem).toString('base64')));
    if (!(await waitHealth(PORT))) throw new Error('重启超时');
    await wait(100);
    check(/APNs 已启用/.test(child.out), 'base64 钥匙:APNs 已启用', child.out);
    const alice2 = await C({ userId: 'u_alice', name: 'Alice', auth: v1Auth(c1) });
    t0 = Date.now();
    await join(alice2, c1);
    const pc2 = await fake.waitFor((q) => q.token === TC && q.at >= t0);
    check(Boolean(pc2), '重启后无需重新登记,旧订阅照样推(Carol)', fake.forToken(TC).length);
    if (pc2) {
      const [hh, cc, ss] = String(pc2.headers.authorization).slice(7).split('.');
      check(crypto.verify('sha256', Buffer.from(`${hh}.${cc}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(ss, 'base64url')),
        'base64 钥匙签出的 JWT 可验签', null);
    }
    check(await noPush(fake, TB, t0, 300), '重启后静音状态保持(Bob 不推)', fake.forToken(TB).length);
    await alice2.close();
  } finally {
    for (const c of open) await c.close();
    await stop(child);
  }

  // ── 13. 未配置 APNs:禁用但不崩;坏的订阅文件被挪开 ──
  console.log('\n[未配置 / 坏文件]');
  const offDir = mkdtempSync(path.join(tmpdir(), 'lares-push-off-'));
  writeFileSync(path.join(offDir, 'push_subscriptions.json'), '{"half-written":');
  const off = boot(PORT_OFF, offDir);
  try {
    if (!(await waitHealth(PORT_OFF))) throw new Error('禁用模式启动超时');
    await wait(100);
    check(/push disabled/.test(off.out), '启动日志:APNs 未配置,推送已禁用 (push disabled)', off.out);
    const files = readdirSync(offDir);
    check(files.some((f) => f.startsWith('push_subscriptions.json.corrupt-')), '坏订阅文件被改名为 .corrupt-<ts>', files);
    const before = fake.requests.length;
    const a = await connect(PORT_OFF, { userId: 'u_off_a', auth: v1Auth('off') });
    const b = await connect(PORT_OFF, { userId: 'u_off_b', auth: v1Auth('off') });
    const r = await b.ask(reg(tok(), ['off']), 'push_registered');
    check(r?.circles?.[0] === 'off', '禁用时 push_register 照常回执(订阅仍保存)', r);
    const room = await join(a, 'off');
    await wait(300);
    check(Boolean(room) && fake.requests.length === before && off.exitCode === null, '禁用时进房正常、不发推送、不崩', { room: Boolean(room), n: fake.requests.length - before });
    check(existsSync(path.join(offDir, 'push_subscriptions.json')), '禁用时订阅表照常落盘', readdirSync(offDir));
    await a.close(); await b.close();
  } finally {
    await stop(off);
    await fake.close();
  }

  console.log(`\n${pass} 通过,${fail} 失败`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
