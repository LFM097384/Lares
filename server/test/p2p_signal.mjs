// 点对点连接码的服务器转发测试。
// 运行:node test/p2p_signal.mjs
//
// 服务器在这条路径上只当邮差:不解析、不存储 SDP,只检查「同圈」然后转发。
// 重点验授权 —— 少了那条检查,任何人都能借服务器给任意 userId 发任意内容。
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';

const PORT = 18997;
const spawned = [];

function spawnServer(port, env = {}) {
  const base = { ...process.env };
  for (const k of ['LARES_AUTH_MODE', 'LARES_AUTH_TOKEN', 'LARES_CIRCLE_PASSCODE',
    'LARES_CIRCLE_PASSCODES', 'LARES_ALLOWED_ORIGIN']) delete base[k];
  const proc = spawn(process.execPath, ['src/index.js'], {
    env: {
      ...base,
      LARES_PORT: String(port),
      LARES_DATA_DIR: mkdtempSync(path.join(tmpdir(), 'lares-p2p-')),
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

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (name, cond) => {
  console.log(`${cond ? '✓' : '✗'} ${name}`);
  if (!cond) failures++;
};

function client(userId) {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
  const inbox = [];
  ws.on('error', () => {});
  ws.on('message', (raw) => {
    try { inbox.push(JSON.parse(raw)); } catch { /* 非 JSON */ }
  });
  return {
    ws,
    inbox,
    userId,
    send: (m) => ws.readyState === ws.OPEN && ws.send(JSON.stringify(m)),
    async expect(t, ms = 1200) {
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
}

async function hello(c) {
  await c.open();
  await c.expect('challenge');
  c.send({
    t: 'hello',
    userId: c.userId,
    deviceId: `d_${c.userId}`,
    name: c.userId,
    platform: 'test',
  });
  await c.expect('welcome');
}

async function main() {
  await bootServer(PORT);

  // ── 同圈转发 ──────────────────────────────────────────
  {
    const a = client('u_a');
    const b = client('u_b');
    await hello(a);
    await hello(b);
    a.send({ t: 'join', circleId: 'jia' });
    b.send({ t: 'join', circleId: 'jia' });
    await a.expect('room');
    await b.expect('room');

    b.clear();
    a.send({ t: 'p2p_signal', to: 'u_b', payload: 'LARES-O1:abc123' });
    const got = await b.expect('p2p_signal');
    check('同圈的人收得到连接码', got !== null && got.payload === 'LARES-O1:abc123');
    check('带上是谁发的', got !== null && got.from === 'u_a');
    check('带上圈子 id', got !== null && got.circleId === 'jia');

    // 回程也要能走
    a.clear();
    b.send({ t: 'p2p_signal', to: 'u_a', payload: 'LARES-A1:xyz789' });
    const back = await a.expect('p2p_signal');
    check('应答码能原路回去', back !== null && back.payload === 'LARES-A1:xyz789');

    a.ws.close(); b.ws.close();
    await wait(150);
  }

  // ── 授权:不同圈子不能互发 ────────────────────────────
  {
    const a = client('u_c');
    const b = client('u_d');
    await hello(a);
    await hello(b);
    a.send({ t: 'join', circleId: 'jia' });
    b.send({ t: 'join', circleId: 'yi' });
    await a.expect('room');
    await b.expect('room');

    b.clear();
    a.send({ t: 'p2p_signal', to: 'u_d', payload: 'LARES-O1:sneaky' });
    await wait(400);
    check('⚠️ 不同圈子的人收不到 —— 否则任何人都能借服务器发任意内容',
      !b.has('p2p_signal'));

    a.ws.close(); b.ws.close();
    await wait(150);
  }

  // ── 没进房的人不能发 ─────────────────────────────────
  {
    const a = client('u_e');
    const b = client('u_f');
    await hello(a);
    await hello(b);
    // a 不 join,只 hello
    b.send({ t: 'join', circleId: 'jia' });
    await b.expect('room');

    b.clear();
    a.send({ t: 'p2p_signal', to: 'u_f', payload: 'LARES-O1:x' });
    await wait(400);
    check('没进房的人发不出去', !b.has('p2p_signal'));

    a.ws.close(); b.ws.close();
    await wait(150);
  }

  // ── 体积上限 ─────────────────────────────────────────
  {
    const a = client('u_g');
    const b = client('u_h');
    await hello(a);
    await hello(b);
    a.send({ t: 'join', circleId: 'jia' });
    b.send({ t: 'join', circleId: 'jia' });
    await a.expect('room');
    await b.expect('room');

    a.clear(); b.clear();
    a.send({ t: 'p2p_signal', to: 'u_h', payload: 'x'.repeat(9000) });
    const err = await a.expect('error');
    check('超大载荷被拒 —— 不做免费的任意大小中继',
      err !== null && err.message === 'payload_too_large');
    check('超大载荷不会被转发', !b.has('p2p_signal'));

    a.ws.close(); b.ws.close();
    await wait(150);
  }

  // ── 发给不存在的人 ───────────────────────────────────
  {
    const a = client('u_i');
    await hello(a);
    a.send({ t: 'join', circleId: 'jia' });
    await a.expect('room');
    a.clear();
    a.send({ t: 'p2p_signal', to: 'u_nobody', payload: 'x' });
    await wait(300);
    check('发给不在圈里的人:静默丢弃,不崩', !a.has('error'));
    a.ws.close();
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
