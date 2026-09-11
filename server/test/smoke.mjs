// 端到端冒烟测试:起服务 -> 两个客户端进房 -> 校验 presence 广播
// 运行:node test/smoke.mjs
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';

const PORT = 18989;
// 隔离数据目录:不受本机持久化的敲门设置/便签影响
const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-test-'));
const server = spawn(process.execPath, ['src/index.js'], {
  env: { ...process.env, LARES_PORT: String(PORT), LARES_DATA_DIR: dataDir },
  stdio: 'inherit',
});

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (name, cond) => {
  console.log(`${cond ? '✓' : '✗'} ${name}`);
  if (!cond) failures++;
};

function client(userId, name) {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
  const inbox = [];
  const waiters = [];
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
  return { ws, inbox, waitFor, send: (m) => ws.send(JSON.stringify(m)) };
}

try {
  await wait(800);

  // /ws 路径也可接入(反代按路径分流用)
  const pathClient = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
  await new Promise((r) => pathClient.on('open', r));
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
  b.send({ t: 'leave' });
  await a.waitFor((m) => m.t === 'member_left' && m.userId === 'u_b');

  // b 离开,c 的大厅摘要应变为 1 人
  const cSummaryAfter = c.waitFor((m) => m.t === 'circle_summary' && m.count === 1);
  b.send({ t: 'leave' });
  await cSummaryAfter;
  check('b 离开后 c 的摘要更新为 1 人', true);

  a.ws.close(); b.ws.close(); a2.ws.close(); c.ws.close();
} catch (e) {
  console.error('✗ 冒烟测试异常:', e.message);
  failures++;
} finally {
  server.kill();
}

console.log(failures === 0 ? '\n全部通过' : `\n${failures} 项失败`);
process.exit(failures === 0 ? 0 : 1);
