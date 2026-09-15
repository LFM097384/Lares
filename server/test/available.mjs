// 「挂着(可约)」协议测试:多圈可见 + 第一个来找的人把双方拉进同一个圈子。
// 运行:node test/available.mjs
//
// 重点覆盖两类事:
//   1. 语义正确(挂起/被找/自动取消)
//   2. **不越权** —— 这是服务端改动最该防的。挂着状态是一条新的广播通道,
//      如果不按 circleAllowed 过滤,就等于把「某人有空」泄露给无关的圈子。
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';

const PORT_OPEN = 18995; // 不鉴权
const PORT_AUTH = 18996; // circle 鉴权

const spawned = [];
function spawnServer(port, env = {}) {
  const base = { ...process.env };
  for (const k of ['LARES_AUTH_MODE', 'LARES_AUTH_TOKEN', 'LARES_CIRCLE_PASSCODE',
    'LARES_CIRCLE_PASSCODES', 'LARES_ALLOWED_ORIGIN']) delete base[k];
  const proc = spawn(process.execPath, ['src/index.js'], {
    env: {
      ...base,
      LARES_PORT: String(port),
      LARES_DATA_DIR: mkdtempSync(path.join(tmpdir(), 'lares-avail-')),
      ...env,
    },
    stdio: 'inherit',
  });
  spawned.push(proc);
  return proc;
}

async function bootServer(port, env = {}) {
  spawnServer(port, env);
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/health`);
      if (r.ok) return;
    } catch { /* 还没起来 */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`server on :${port} 启动超时`);
}

const proofCircle = (passcode, nonce, userId, circleId) =>
  crypto.createHmac('sha256', passcode).update(`${nonce}:${userId}:${circleId}`).digest('hex');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (name, cond) => {
  console.log(`${cond ? '✓' : '✗'} ${name}`);
  if (!cond) failures++;
};

function client(userId, name, port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const inbox = [];
  ws.on('error', () => { /* 关闭码由 close 给出 */ });
  ws.on('message', (raw) => {
    try { inbox.push(JSON.parse(raw)); } catch { /* 非 JSON 忽略 */ }
  });
  const c = {
    ws,
    inbox,
    userId,
    send: (m) => ws.readyState === ws.OPEN && ws.send(JSON.stringify(m)),
    /// 等某类消息出现(或超时返回 null)
    async expect(t, ms = 1500) {
      const deadline = Date.now() + ms;
      while (Date.now() < deadline) {
        const hit = inbox.find((m) => m.t === t);
        if (hit) return hit;
        await wait(25);
      }
      return null;
    },
    has: (t) => inbox.some((m) => m.t === t),
    clear: () => inbox.splice(0),
    async open() {
      if (ws.readyState === ws.OPEN) return;
      await new Promise((res, rej) => {
        ws.once('open', res);
        ws.once('error', rej);
      });
    },
  };
  return c;
}

/// 完成 hello(按需带 circle 鉴权证明)
async function hello(c, { passcode, circleId } = {}) {
  await c.open();
  if (passcode) {
    const ch = await c.expect('challenge');
    c.send({
      t: 'hello',
      userId: c.userId,
      deviceId: `d_${c.userId}`,
      name: c.userId,
      platform: 'test',
      auth: {
        mode: 'circle',
        nonce: ch.nonce,
        circleId,
        proof: proofCircle(passcode, ch.nonce, c.userId, circleId),
      },
    });
  } else {
    await c.expect('challenge');
    c.send({ t: 'hello', userId: c.userId, deviceId: `d_${c.userId}`, name: c.userId, platform: 'test' });
  }
  await c.expect('welcome');
}

async function main() {
  // ── 组 1:不鉴权服务器,验语义 ──────────────────────────────
  await bootServer(PORT_OPEN);

  {
    const a = client('u_a', 'A', PORT_OPEN);
    const b = client('u_b', 'B', PORT_OPEN);
    await hello(a);
    await hello(b);

    // A 挂在两个圈子
    a.clear(); b.clear();
    a.send({ t: 'available', circleIds: ['jia', 'yi'] });
    const ok = await a.expect('available_ok');
    check('挂起成功并回执', ok !== null && ok.circleIds.length === 2);

    const seen = await b.expect('member_available');
    check('别人能看到「A 可约」', seen !== null && seen.userId === 'u_a');
    check('回报了 A 挂在哪几个圈', seen !== null && seen.circleIds.includes('jia'));

    // B 去找 A
    b.clear(); a.clear();
    b.send({ t: 'reach', userId: 'u_a', circleId: 'jia' });

    const reached = await a.expect('reached');
    check('A 收到「有人来找你了」', reached !== null && reached.circleId === 'jia');
    check('告诉 A 是谁来找的', reached !== null && reached.byUserId === 'u_b');

    // 双方都该进了 jia 圈
    const aRoom = await a.expect('room');
    const bRoom = await b.expect('room');
    check('A 进了房间', aRoom !== null && aRoom.circleId === 'jia');
    check('B 进了同一个房间', bRoom !== null && bRoom.circleId === 'jia');

    // 挂着态必须已取消
    const gone = await b.expect('member_unavailable');
    check('进房后挂着态自动取消', gone !== null && gone.userId === 'u_a');

    // 第三个人 C 也能进(同圈的人不该被拦)
    const c = client('u_c', 'C', PORT_OPEN);
    await hello(c);
    c.clear();
    c.send({ t: 'join', circleId: 'jia' });
    const cRoom = await c.expect('room');
    check('同圈第三人可以进来', cRoom !== null && cRoom.members.length >= 3);

    a.ws.close(); b.ws.close(); c.ws.close();
    await wait(150);
  }

  {
    // 断线要清掉挂着态,否则留下点了没反应的幽灵
    const a = client('u_d', 'D', PORT_OPEN);
    const w = client('u_w', 'W', PORT_OPEN);
    await hello(a);
    await hello(w);
    a.send({ t: 'available', circleIds: ['jia'] });
    await a.expect('available_ok');
    check('观察者看到 D 可约', (await w.expect('member_available')) !== null);

    w.clear();
    a.ws.close();
    const gone = await w.expect('member_unavailable');
    check('断线后挂着态被清掉', gone !== null && gone.userId === 'u_d');
    w.ws.close();
    await wait(150);
  }

  {
    // 已经在房间里就不能再挂着 —— 两者语义互斥
    const a = client('u_e', 'E', PORT_OPEN);
    await hello(a);
    a.send({ t: 'join', circleId: 'jia' });
    await a.expect('room');
    a.clear();
    a.send({ t: 'available', circleIds: ['jia'] });
    const err = await a.expect('error');
    check('在房间里不能挂着', err !== null && err.message === 'already_in_room');
    a.ws.close();
    await wait(150);
  }

  {
    // 找一个已经不在了的人,要明确失败而不是静默
    const b = client('u_f', 'F', PORT_OPEN);
    await hello(b);
    b.clear();
    b.send({ t: 'reach', userId: 'u_nobody' });
    const failed = await b.expect('reach_failed');
    check('找不存在的人会明确报失败', failed !== null && failed.reason === 'gone');
    b.ws.close();
    await wait(150);
  }

  // ── 组 2:circle 鉴权服务器,验不越权 ────────────────────────
  await bootServer(PORT_AUTH, {
    LARES_AUTH_MODE: 'circle',
    LARES_CIRCLE_PASSCODES: JSON.stringify({ jia: 'pass-jia', yi: 'pass-yi' }),
  });

  {
    // X 只有 jia 的口令,Y 只有 yi 的口令
    const x = client('u_x', 'X', PORT_AUTH);
    const y = client('u_y', 'Y', PORT_AUTH);
    await hello(x, { passcode: 'pass-jia', circleId: 'jia' });
    await hello(y, { passcode: 'pass-yi', circleId: 'yi' });

    // X 挂在 jia
    x.clear(); y.clear();
    x.send({ t: 'available', circleIds: ['jia'] });
    await x.expect('available_ok');

    await wait(400);
    check('⚠️ 只有 yi 口令的人看不到 jia 圈的可约状态',
      !y.has('member_available'));

    // X 试图挂进自己没有口令的圈子
    x.clear();
    x.send({ t: 'available', circleIds: ['yi'] });
    const err = await x.expect('error');
    check('⚠️ 不能挂进自己没口令的圈子', err !== null && err.message === 'auth_scope');

    // Y 试图去找 X(看不见就不该找得到)
    y.clear();
    y.send({ t: 'reach', userId: 'u_x' });
    const failed = await y.expect('reach_failed');
    check('⚠️ 看不见的人也找不到', failed !== null);

    x.ws.close(); y.ws.close();
    await wait(150);
  }

  {
    // 后连上来的人要能看到已经挂着的人
    const p = client('u_p', 'P', PORT_AUTH);
    await hello(p, { passcode: 'pass-jia', circleId: 'jia' });
    p.send({ t: 'available', circleIds: ['jia'] });
    await p.expect('available_ok');

    const q = client('u_q', 'Q', PORT_AUTH);
    await hello(q, { passcode: 'pass-jia', circleId: 'jia' });
    const seen = await q.expect('member_available');
    check('后连上来的人也能看到已挂着的人', seen !== null && seen.userId === 'u_p');

    p.ws.close(); q.ws.close();
    await wait(150);
  }

  console.log(failures === 0 ? '\n✓ 全部通过' : `\n✗ ${failures} 项失败`);
  for (const p of spawned) p.kill();
  await wait(200);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  for (const p of spawned) p.kill();
  process.exit(1);
});
