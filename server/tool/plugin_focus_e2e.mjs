// 插件 + 专注学习端到端演示(不需要 LiveKit)。
//
// 起一个真实服务端(LARES_PLUGIN_ALLOW_PRIVATE=1,webhook 可投本机 http)+ 本地 webhook 接收器,
// 注册圈子 → 装 docs/examples/plugin-hello(webhook 改指本机)→ 装 lares.focus →
// 两个成员进房、离开 / 回来 → 校验每条 webhook 的 HMAC → 用插件 token 查 /api/v1/focus。
// 日志打印到终端并写入 tool/plugin_focus_e2e.last.txt。
//
// 用法:cd server; node tool/plugin_focus_e2e.mjs

import http from 'node:http';
import net from 'node:net';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { boot, waitHealth, stop, connect, join, registerCircle, v2Auth, wait } from '../test/lib/harness.mjs';
import { verifySignature } from '../src/plugin_webhooks.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, 'plugin_focus_e2e.last.txt');
const lines = [];
const log = (...a) => { const s = a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' '); lines.push(s); console.log(s); };
let ok = 0; let bad = 0;
const expect = (cond, name, detail) => { if (cond) { ok++; log('  ✓', name); } else { bad++; log('  ✗', name, detail === undefined ? '' : JSON.stringify(detail).slice(0, 400)); } };

const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)); }); });

function receiver() {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      got.push({ headers: req.headers, raw, body: JSON.parse(raw) });
      res.writeHead(200); res.end('ok');
    });
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({ port: server.address().port, got, close: () => new Promise((c) => { server.closeAllConnections?.(); server.close(c); }) })));
}

async function main() {
  const t0 = Date.now();
  log(`# plugin_focus_e2e  ${new Date().toISOString()}`);
  const port = await freePort();
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-pf-e2e-'));
  const rx = await receiver();
  log(`服务端 :${port}  webhook 接收器 :${rx.port}  DATA_DIR ${dataDir}`);
  const srv = boot(port, dataDir, 'e2e-global-' + randomBytes(4).toString('hex'), { LARES_PLUGIN_ALLOW_PRIVATE: '1', LARES_PLUGIN_RETRY_BASE_MS: '100' });
  const clients = [];
  try {
    expect(await waitHealth(port), '服务端启动');
    const passcode = 'e2e-' + randomBytes(4).toString('hex');
    const { cid, verifier, ownerKey, owner } = await registerCircle(port, passcode, 'u_owner');
    clients.push(owner);
    log(`\n[1] 注册圈子 ${cid}`);

    log('\n[2] 安装 docs/examples/plugin-hello(webhook → 本机)');
    const manifest = JSON.parse(readFileSync(path.join(HERE, '..', '..', 'docs', 'examples', 'plugin-hello', 'manifest.json'), 'utf8'));
    manifest.webhook.url = `http://127.0.0.1:${rx.port}/hooks/lares`;
    const inst = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    expect(inst?.t === 'plugin_installed', `plugin_installed ${inst?.plugin?.id}@${inst?.plugin?.version}`, inst);
    const token = inst?.token; const secret = inst?.webhookSecret;
    log(`  token ${token?.slice(0, 10)}…  secret ${secret?.slice(0, 10)}…`);

    log('\n[3] 安装内置 lares.focus');
    const f = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.focus' }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    expect(f?.t === 'plugin_installed' && f.plugin.name === '专注学习', `内置插件 ${f?.plugin?.name}`, f);

    log('\n[4] 两个成员进房,Alice 离开 / 回来');
    const A = await connect(port, { userId: 'u_alice', name: 'Alice', auth: v2Auth(verifier, cid) });
    const B = await connect(port, { userId: 'u_bob', name: 'Bob', auth: v2Auth(verifier, cid) });
    clients.push(A, B);
    await join(A, cid); await join(B, cid);
    const pong = await A.req({ t: 'ping' }, (m) => m.t === 'pong');
    log(`  pong.now 偏差 ${pong.now - Date.now()} ms`);
    await wait(1500);
    A.send({ t: 'focus_away', circleId: cid, since: pong.now + 1000 });
    const away = await B.waitFor((m) => m.t === 'focus_notice' && m.kind === 'away');
    expect(away?.userId === 'u_alice', 'Bob 收到 focus_notice away(Alice)', away);
    await wait(1000);
    A.send({ t: 'focus_back', circleId: cid });
    const back = await B.waitFor((m) => m.t === 'focus_notice' && m.kind === 'back');
    expect(back?.awayMs >= 900, `Bob 收到 back,awayMs=${back?.awayMs}`, back);
    A.send({ t: 'plugin_state_set', circleId: cid, pluginId: manifest.id, patch: { counter: 1 } });
    const ps = await B.waitFor((m) => m.t === 'plugin_state' && m.pluginId === manifest.id);
    expect(ps?.state?.counter === 1, `共享状态 rev=${ps?.rev}`, ps);
    await wait(800);

    log('\n[5] webhook 投递与签名');
    for (const x of rx.got) {
      const v = verifySignature(secret, Number(x.headers['x-lares-timestamp']), x.raw, x.headers['x-lares-signature']);
      log(`  ${v ? 'HMAC✓' : 'HMAC✗'} ${x.body.type.padEnd(12)} ${x.body.id} ${JSON.stringify(x.body.data).slice(0, 80)}`);
      if (!v) bad++;
    }
    const types = rx.got.map((x) => x.body.type);
    expect(types.includes('installed') && types.filter((t) => t === 'join').length === 2 && types.includes('plugin_state'), `收到 installed + 2×join + plugin_state(共 ${types.length} 条)`, types);
    expect(rx.got.find((x) => x.body.type === 'installed')?.body.data.token === token, 'installed 事件携带插件 token');
    expect(!types.includes('focus'), '未订阅 focus 事件 → 不投');

    log('\n[6] 插件 token 查 /api/v1/focus');
    const res = await fetch(`http://127.0.0.1:${port}/api/v1/focus`, { headers: { authorization: `Bearer ${token}` } });
    const body = await res.json();
    expect(res.status === 200 && body.installed && body.enabled, `HTTP ${res.status} installed=${body.installed} enabled=${body.enabled}`, body);
    for (const m of body.members ?? []) log(`  ${m.name.padEnd(6)} state=${m.state} focus=${(m.focusMs / 1000).toFixed(1)}s away=${(m.awayMs / 1000).toFixed(1)}s`);
    const alice = body.members?.find((m) => m.userId === 'u_alice');
    expect(alice?.awayMs >= 900, 'Alice 离开时长已记录', alice);
    log('  排行榜(today):', body.leaderboard?.today?.map((r) => `${r.name} ${(r.ms / 1000).toFixed(1)}s`).join(', '));
    const cr = await (await fetch(`http://127.0.0.1:${port}/api/v1/circle`, { headers: { authorization: `Bearer ${token}` } })).json();
    expect(cr.bot?.name === manifest.name, `插件 token 身份 = "${cr.bot?.name}"`);
  } catch (e) {
    bad++;
    log('异常:', String(e?.stack ?? e));
  } finally {
    for (const c of clients) await c.close().catch(() => {});
    await stop(srv);
    await rx.close();
  }
  log(`\n结果:${bad === 0 ? 'PASS' : 'FAIL'}  ${ok} 通过 ${bad} 失败  用时 ${Date.now() - t0} ms`);
  writeFileSync(OUT, lines.join('\n') + '\n');
  // Windows 上 fetch 的 keep-alive 句柄未关时立刻 process.exit 会触发 libuv 断言;让事件循环自然结束
  process.exitCode = bad === 0 ? 0 : 1;
  setTimeout(() => process.exit(), 200).unref();
}

main();
