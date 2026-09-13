// 录音同意广播的端到端验证(需求⑧)。
//
// 这一组测试守的是一条伦理红线:**指示器绝不能说谎**。
// 具体到协议上有三条不变量:
//   1. 发起者必须收到自己的回显 —— 那是客户端放行采集的前提;
//   2. 后进房的人必须立刻知道房间正在被录;
//   3. 录音端崩溃/掉线后,标记必须被撤掉,不能永远亮着。
//
// 用法:node test/rec_consent.mjs

import { spawn } from 'node:child_process';
import { WebSocket } from 'ws';

const PORT = 18940;

let pass = 0;
let fail = 0;
const ok = (n) => { console.log('  ✓', n); pass++; };
const bad = (n, d) => { console.log('  ✗', n, '—', d); fail++; };

function bootServer(env) {
  const cwd = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd, env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'],
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
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

/// 一个带收件箱的客户端;按谓词等待消息,不依赖顺序。
function client(port, { userId, name }) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  const inbox = [];
  const waiters = [];
  ws.on('message', (raw) => {
    let m; try { m = JSON.parse(raw); } catch { return; }
    inbox.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].pred(m)) { waiters[i].resolve(m); waiters.splice(i, 1); }
    }
  });
  const api = {
    ws,
    inbox,
    send: (m) => ws.send(JSON.stringify(m)),
    // 先扫已到达的,再挂等待 —— 避免竞态
    wait(pred, ms = 4000) {
      const hit = inbox.find(pred);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('等待超时')), ms);
        waiters.push({ pred, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
    // 竞态:若 socket 在挂 once('open') 之前就已打开,该监听器永远不会触发。
    // 必须先查 readyState。
    opened() {
      if (ws.readyState === WebSocket.OPEN) return Promise.resolve();
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('连接超时')), 5000);
        ws.once('open', () => { clearTimeout(t); resolve(); });
        ws.once('error', (e) => { clearTimeout(t); reject(e); });
      });
    },
    async helloJoin(circleId) {
      await api.opened();
      api.send({ t: 'hello', userId, deviceId: 'd_' + userId, name, platform: 'test' });
      await api.wait((m) => m.t === 'welcome');
      api.send({ t: 'join', circleId });
      await api.wait((m) => m.t === 'room');
    },
    close: () => { try { ws.close(); } catch {} },
  };
  return api;
}

async function main() {
  console.log('录音同意广播验证\n');
  const child = bootServer({ LARES_PORT: String(PORT), LARES_AUTH_MODE: 'none' });
  if (!(await waitHealth(PORT))) { bad('服务端启动', '超时'); child.kill(); process.exit(1); }

  const a = client(PORT, { userId: 'u_rec', name: '录音者' });
  const b = client(PORT, { userId: 'u_other', name: '旁人' });
  await a.helloJoin('recroom');
  await b.helloJoin('recroom');

  // 1) 发起者必须收到自己的回显
  a.send({ t: 'rec_start', circleId: 'recroom' });
  try {
    const echo = await a.wait((m) => m.t === 'member_rec' && m.userId === 'u_rec' && m.active === true);
    if (typeof echo.since === 'number' && echo.since > 0) {
      ok('发起者收到自己的回显(放行采集的前提),且带 since');
    } else {
      bad('回显缺 since', JSON.stringify(echo));
    }
  } catch (e) { bad('发起者回显', e.message); }

  // 2) 同房其他人也必须收到
  try {
    await b.wait((m) => m.t === 'member_rec' && m.userId === 'u_rec' && m.active === true);
    ok('同房其他人收到录音广播');
  } catch (e) { bad('旁人广播', e.message); }

  // 3) 后进房的人必须从房间快照里立刻看到录音态
  const c = client(PORT, { userId: 'u_late', name: '后来的' });
  await c.opened();
  c.send({ t: 'hello', userId: 'u_late', deviceId: 'd3', name: '后来的', platform: 'test' });
  await c.wait((m) => m.t === 'welcome');
  c.send({ t: 'join', circleId: 'recroom' });
  try {
    const snap = await c.wait((m) => m.t === 'room');
    const rec = snap.members.find((m) => m.userId === 'u_rec');
    if (rec && rec.rec && typeof rec.rec.since === 'number') {
      ok('后进房者从 room 快照即知房间正在被录(伦理红线)');
    } else {
      bad('快照未带录音态', JSON.stringify(snap.members));
    }
  } catch (e) { bad('后进房快照', e.message); }

  // 4) rec_start 幂等:重发不重置 since(重连补发会走到这里)
  const before = a.inbox.filter((m) => m.t === 'member_rec' && m.active).pop().since;
  a.send({ t: 'rec_start', circleId: 'recroom' });
  await new Promise((r) => setTimeout(r, 250));
  const after = a.inbox.filter((m) => m.t === 'member_rec' && m.active).pop().since;
  if (before === after) ok('重发 rec_start 不重置 since(否则「已录 N 分钟」会倒退)');
  else bad('since 被重置', `${before} -> ${after}`);

  // 5) rec_ping 有 ack(用于察觉 TCP 半开)
  a.send({ t: 'rec_ping', circleId: 'recroom' });
  try {
    await a.wait((m) => m.t === 'rec_pong');
    ok('rec_ping 得到 rec_pong(录音端可据此察觉 TCP 半开)');
  } catch (e) { bad('rec_pong', e.message); }

  // 6) 跨圈误报被拒
  a.send({ t: 'rec_start', circleId: 'otherroom' });
  await new Promise((r) => setTimeout(r, 250));
  const crossLeak = b.inbox.some((m) => m.t === 'member_rec' && m.circleId === 'otherroom');
  if (!crossLeak) ok('跨圈 rec_start 被拒(circleId 必须与当前会话一致)');
  else bad('跨圈误报', '其他圈子收到了广播');

  // 7) rec_stop 广播 active:false
  a.send({ t: 'rec_stop', circleId: 'recroom' });
  try {
    await b.wait((m) => m.t === 'member_rec' && m.userId === 'u_rec' && m.active === false);
    ok('rec_stop 广播 active:false');
  } catch (e) { bad('rec_stop 广播', e.message); }

  // 8) rec_stop 幂等
  const cntBefore = b.inbox.filter((m) => m.t === 'member_rec').length;
  a.send({ t: 'rec_stop', circleId: 'recroom' });
  await new Promise((r) => setTimeout(r, 250));
  const cntAfter = b.inbox.filter((m) => m.t === 'member_rec').length;
  if (cntBefore === cntAfter) ok('重复 rec_stop 幂等,不再广播');
  else bad('rec_stop 不幂等', `${cntBefore} -> ${cntAfter}`);

  // 9) 录音者掉线 -> 必须补发 active:false(否则指示器停在旧状态 = 说谎)
  a.send({ t: 'rec_start', circleId: 'recroom' });
  await b.wait((m) => m.t === 'member_rec' && m.userId === 'u_rec' && m.active === true);
  const marker = b.inbox.length;
  a.close();
  try {
    await b.wait(
      (m) => m.t === 'member_rec' && m.userId === 'u_rec' && m.active === false
        && b.inbox.indexOf(m) >= marker,
      4000,
    );
    ok('录音者掉线 -> 自动撤销录音指示(不留幽灵标记)');
  } catch (e) { bad('掉线撤销', e.message); }

  b.close(); c.close();
  child.kill();
  await new Promise((r) => setTimeout(r, 200));

  console.log(`\n通过 ${pass} / 失败 ${fail}`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
