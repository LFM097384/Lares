// 插件系统端到端验证。契约:docs/plans/plugin-focus-contract.md §0-§5,docs/plugin-api.md。
//
// 纯函数(manifest 校验 / merge patch / 签名)直接 import;其余一律起真实服务端进程,只看线上收发与磁盘。
// 用法:node test/plugins.mjs     (DEBUG=1 显示服务端 stderr)

import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  wait, makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v2Auth, ownerReply,
} from './lib/harness.mjs';
import { validateManifest, mergePatch } from '../src/plugins.js';
import { verifySignature, isBlockedIp } from '../src/plugin_webhooks.js';

const PORT = 18985;
const PORT_STRICT = 18986;
const GLOBAL_PASS = 'plg-global-' + randomBytes(4).toString('hex');
const PASSCODE = 'plg-pass-' + randomBytes(4).toString('hex');
const T = makeChecker();
const { check } = T;
const BASE = `http://127.0.0.1:${PORT}`;

const api = (token, p, opts = {}) => fetch(BASE + p, {
  ...opts,
  headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(opts.json ? { 'content-type': 'application/json' } : {}) },
  body: opts.json ? JSON.stringify(opts.json) : opts.body,
});
const jsonOf = async (res) => { try { return await res.json(); } catch { return null; } };

// ── 本地 webhook 接收器 ──
function startReceiver() {
  const got = [];
  const waiters = [];
  let failFirst = 0;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      let body = null; try { body = JSON.parse(raw); } catch { /* */ }
      const rec = { headers: req.headers, raw, body, at: Date.now() };
      if (failFirst > 0) {
        failFirst--;
        rec.status = 500;
        got.push(rec);
        res.writeHead(500); res.end('nope');
        return;
      }
      rec.status = 200;
      got.push(rec);
      res.writeHead(200); res.end('ok');
      for (const w of [...waiters]) if (w.pred(rec)) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(rec); }
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port,
    got,
    failNext(n) { failFirst = n; },
    waitFor(pred, ms = 4000) {
      const hit = got.find((r) => r.status === 200 && pred(r));
      if (hit) return Promise.resolve(hit);
      return new Promise((res) => {
        const w = { pred, res, t: setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); res(null); }, ms) };
        waiters.push(w);
      });
    },
    close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }),
  })));
}

const goodManifest = (over = {}) => ({
  id: 'com.example.hello',
  name: 'Hello',
  version: '1.0.0',
  description: 'demo',
  author: 'Example',
  permissions: ['circle:read', 'members:read', 'state:read', 'state:write'],
  ...over,
});

function unitTests() {
  console.log('\n[manifest 校验(纯函数)]');
  check(validateManifest(goodManifest()).ok, '合法 manifest 通过');
  check(validateManifest(goodManifest({ name: '专注'.repeat(20) })).ok, 'name 40 个汉字通过(按字符计)');
  const bad = (m, opt) => validateManifest(m, opt);
  check(bad(goodManifest({ id: 'Hello' })).reason === 'bad_manifest', 'id 大写 -> bad_manifest');
  check(bad(goodManifest({ id: 'single' })).ok === false, 'id 无点 -> 拒');
  check(bad(goodManifest({ id: 'lares.evil' })).detail === 'id_reserved', 'lares. 前缀保留');
  check(bad(goodManifest({ foo: 1 })).detail === 'unknown_field:foo', '未知顶层字段 -> detail');
  check(!bad(goodManifest({ version: 'v 1' })).ok, 'version 带空格 -> 拒');
  check(!bad(goodManifest({ permissions: ['root'] })).ok, '未知权限 -> 拒');
  check(validateManifest(goodManifest({ permissions: ['state:read', 'state:read'] })).manifest?.permissions.length === 1, '权限去重');
  check(!bad(goodManifest({ webhook: { url: 'https://x.example/h', events: ['chat'] } })).ok, 'webhook 事件缺对应权限 -> 拒');
  check(bad(goodManifest({ webhook: { url: 'https://x.example/h', events: ['join'] } })).ok, 'webhook join + members:read 通过');
  check(!bad(goodManifest({ webhook: { url: 'http://x.example/h', events: [] } })).ok, 'webhook http 默认拒');
  check(bad(goodManifest({ webhook: { url: 'http://x.example/h', events: [] } }), { allowPrivate: true }).ok, 'ALLOW_PRIVATE 时放行 http');
  check(!bad(goodManifest({ entry: { url: 'javascript:alert(1)' } })).ok, 'entry javascript: -> 拒');
  check(!bad(goodManifest({ homepage: 'http://x.example' })).ok, 'homepage 必须 https');
  check(!bad(goodManifest({ description: 'x'.repeat(17000) })).ok, '超 16 KB -> 拒');
  check(!bad(goodManifest({ settingsSchema: { big: 'x'.repeat(9000) } })).ok, 'settingsSchema 超 8 KB -> 拒');
  check(!bad(null).ok && !bad([]).ok, '非对象 -> 拒');

  console.log('\n[merge patch / 签名 / SSRF(纯函数)]');
  const m = mergePatch({ a: 1, b: { c: 2, d: 3 } }, { a: null, b: { c: null, e: 4 }, f: [1] });
  check(JSON.stringify(m) === JSON.stringify({ b: { d: 3, e: 4 }, f: [1] }), 'RFC 7396 合并 + null 删键', m);
  const now = Math.floor(Date.now() / 1000);
  check(verifySignature('whsec_x', now, '{"a":1}', 'v1=' + (await_hmac('whsec_x', `${now}.{"a":1}`))), 'verifySignature 正确签名通过');
  check(!verifySignature('whsec_x', now, '{"a":2}', 'v1=' + await_hmac('whsec_x', `${now}.{"a":1}`)), '篡改 body -> 不通过');
  check(!verifySignature('whsec_x', now - 1000, '{}', 'v1=' + await_hmac('whsec_x', `${now - 1000}.{}`)), '时间戳超 300 s -> 不通过');
  for (const ip of ['127.0.0.1', '10.1.2.3', '172.20.0.1', '192.168.1.1', '100.64.0.1', '169.254.169.254', '0.0.0.0', '::1', '::', 'fe80::1', 'fd00::1', '::ffff:127.0.0.1', '224.0.0.1', '255.255.255.255']) {
    check(isBlockedIp(ip), `SSRF 拦截 ${ip}`);
  }
  check(!isBlockedIp('93.184.216.34') && !isBlockedIp('2606:4700::1111'), '公网地址放行');
}

import { createHmac } from 'node:crypto';
function await_hmac(k, s) { return createHmac('sha256', k).update(s).digest('hex'); }

async function main() {
  unitTests();

  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-plugins-'));
  const rx = await startReceiver();
  const env = { LARES_PLUGIN_ALLOW_PRIVATE: '1', LARES_PLUGIN_RETRY_BASE_MS: '50' };
  let srv = boot(PORT, dataDir, GLOBAL_PASS, env);
  const srvStrict = boot(PORT_STRICT, mkdtempSync(path.join(tmpdir(), 'lares-plugins-strict-')), GLOBAL_PASS, {});
  const clients = [];
  try {
    check(await waitHealth(PORT) && await waitHealth(PORT_STRICT), '两个服务端启动');

    const { cid, verifier, ownerKey, owner } = await registerCircle(PORT, PASSCODE, 'u_owner');
    clients.push(owner);
    const memberA = await connect(PORT, { userId: 'u_a', name: 'Alice', auth: v2Auth(verifier, cid) });
    const memberB = await connect(PORT, { userId: 'u_b', name: 'Bob', auth: v2Auth(verifier, cid) });
    clients.push(memberA, memberB);
    check(memberA.kind === 'welcome' && Array.isArray(memberA.msg.circle?.plugins), 'welcome.circle.plugins 是数组', memberA.msg?.circle);

    console.log('\n[安装门禁]');
    const instReply = (m) => (m.t === 'plugin_installed') || (m.t === 'owner_error' && m.op === 'plugin_install');
    let r = await memberA.req({ t: 'plugin_install', circleId: cid, ownerKey: 'nope', pluginId: 'lares.focus' }, instReply);
    check(r?.t === 'owner_error' && r.reason === 'not_owner', '非圈主安装 -> not_owner', r);
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.nope' }, instReply);
    check(r?.reason === 'unknown_builtin', '未知内置 -> unknown_builtin', r);
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.focus', manifest: goodManifest() }, instReply);
    check(r?.reason === 'bad_request', '同时给 pluginId 与 manifest -> bad_request', r);
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: goodManifest({ bogus: 1 }) }, instReply);
    check(r?.reason === 'bad_manifest' && r.detail === 'unknown_field:bogus', '坏 manifest -> bad_manifest + detail', r);

    memberA.drain(() => true);
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.focus' }, instReply);
    check(r?.t === 'plugin_installed' && r.plugin?.id === 'lares.focus' && r.plugin.builtin === true && r.plugin.enabled === true, '圈主装内置 lares.focus', r);
    check(r?.plugin?.name === '专注学习' && r.plugin.config?.focusMin === 25 && !r.token, '内置:名字 / 默认配置 / 无 token', r?.plugin);
    const bc = await memberA.waitFor((m) => m.t === 'plugins' && m.circleId === cid);
    check(bc?.items?.some((p) => p.id === 'lares.focus'), '成员(大厅)收到 plugins 广播', bc);
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.focus' }, instReply);
    check(r?.reason === 'already_installed', '重复安装 -> already_installed', r);

    r = await memberA.req({ t: 'plugin_list', circleId: cid }, (m) => (m.t === 'plugins' || m.t === 'plugin_error'));
    check(r?.t === 'plugins' && r.items.length === 1 && r.items[0].hasWebhook === false, '成员 plugin_list 可读', r);

    console.log('\n[安装带 webhook 的第三方插件]');
    const hookUrl = `http://127.0.0.1:${rx.port}/hook`;
    const helloManifest = goodManifest({
      entry: { url: 'https://example.com/hello/' },
      permissions: ['circle:read', 'members:read', 'state:read', 'state:write'],
      webhook: { url: hookUrl, events: ['join', 'leave', 'plugin_state'] },
    });
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: helloManifest }, instReply);
    check(r?.t === 'plugin_installed' && /^plg_[A-Za-z0-9_-]{43}$/.test(r.token ?? '') && /^whsec_/.test(r.webhookSecret ?? ''), '回执带 plg_ token 与 whsec_ 密钥(仅此一次)', r);
    check(r?.plugin && !('webhook' in r.plugin) && r.plugin.hasWebhook === true, 'PluginView 不暴露 webhook URL', r?.plugin);
    const helloToken = r?.token;
    const secret = r?.webhookSecret;
    const installed = await rx.waitFor((x) => x.body?.type === 'installed');
    check(installed?.body?.data?.token === helloToken, 'webhook 收到 installed{token}', installed?.body);
    const sigOk = (x) => verifySignature(secret, Number(x.headers['x-lares-timestamp']), x.raw, x.headers['x-lares-signature']);
    check(installed && sigOk(installed), 'installed 事件 HMAC 校验通过');
    check(installed?.headers['x-lares-event'] === 'installed' && installed.headers['x-lares-delivery'] === installed.body.id && /^evt_[0-9a-f]+$/.test(installed.body.id), 'X-Lares-Event / Delivery 头与 body.id 一致', installed?.headers);
    check(installed && !verifySignature('whsec_wrong', Number(installed.headers['x-lares-timestamp']), installed.raw, installed.headers['x-lares-signature']), '错误密钥验签失败');

    console.log('\n[webhook 订阅事件 + 重试]');
    await join(memberA, cid);
    const jEv = await rx.waitFor((x) => x.body?.type === 'join' && x.body.data?.userId === 'u_a');
    check(jEv && sigOk(jEv) && jEv.body.circleId === cid && jEv.body.pluginId === 'com.example.hello', 'join 事件投递且签名正确', jEv?.body);
    rx.failNext(2);
    const before = rx.got.length;
    await join(memberB, cid);
    const jB = await rx.waitFor((x) => x.body?.type === 'join' && x.body.data?.userId === 'u_b', 5000);
    const tries = rx.got.slice(before).filter((x) => x.body?.type === 'join' && x.body.data?.userId === 'u_b');
    check(jB && tries.length === 3 && tries[0].status === 500 && tries[1].status === 500, '500 两次后第三次成功(重试)', tries.map((x) => x.status));
    check(tries.length === 3 && new Set(tries.map((x) => x.body.id)).size === 1, '重试沿用同一 delivery id');

    console.log('\n[共享状态]');
    memberA.drain(() => true); memberB.drain(() => true);
    const stReply = (m) => m.t === 'plugin_state' || m.t === 'plugin_error';
    memberA.send({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.hello', patch: { board: { x: 1, y: 2 }, title: 'hi' } });
    const sA = await memberA.waitFor((m) => m.t === 'plugin_state' && m.pluginId === 'com.example.hello');
    const sB = await memberB.waitFor((m) => m.t === 'plugin_state' && m.pluginId === 'com.example.hello');
    check(sA?.rev === 1 && sA.state.board.y === 2, '发起者收到 plugin_state rev=1', sA);
    check(sB?.rev === 1 && sB.state.title === 'hi', '另一成员收到广播', sB);
    memberA.send({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.hello', patch: { board: { x: null }, title: null } });
    const s2 = await memberB.waitFor((m) => m.t === 'plugin_state' && m.rev === 2);
    check(s2 && JSON.stringify(s2.state) === JSON.stringify({ board: { y: 2 } }), 'null 删键 + rev=2', s2);
    const psEv = await rx.waitFor((x) => x.body?.type === 'plugin_state' && x.body.data?.rev === 2);
    check(psEv && sigOk(psEv), 'plugin_state 事件投递给 webhook');
    r = await memberA.req({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.hello', patch: { big: 'x'.repeat(15000) } }, stReply);
    check(r?.t === 'plugin_state', '15 KB patch 接受', r?.reason);
    for (let i = 0; i < 4; i++) memberA.send({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.hello', patch: { ['big' + i]: 'x'.repeat(15000) } });
    const tooLarge = await memberA.waitFor((m) => m.t === 'plugin_error' && m.reason === 'too_large');
    check(tooLarge?.op === 'plugin_state_set', '合并后超 64 KB -> too_large', tooLarge);
    memberA.drain(() => true);
    r = await memberA.req({ t: 'plugin_state_get', circleId: cid, pluginId: 'com.example.hello' }, stReply);
    const revAfter = r?.rev;
    check(r?.t === 'plugin_state' && Buffer.byteLength(JSON.stringify(r.state)) <= 64 * 1024, 'plugin_state_get 回当前状态(≤64 KB)', r?.rev);
    r = await memberA.req({ t: 'plugin_state_set', circleId: cid, pluginId: 'lares.focus', patch: { a: 1 } }, stReply);
    check(r?.t === 'plugin_error' && r.reason === 'forbidden', '成员写 lares.focus 状态 -> forbidden', r);
    r = await memberA.req({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.nope', patch: { a: 1 } }, stReply);
    check(r?.reason === 'not_installed', '未装插件 -> not_installed', r);
    owner.drain(() => true);
    r = await owner.req({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.hello', patch: { a: 1 } }, stReply);
    check(r?.reason === 'not_in_room', '不在房 -> not_in_room', r);
    r = await memberA.req({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.hello', patch: [1] }, stReply);
    check(r?.reason === 'bad_patch', 'patch 非对象 -> bad_patch', r);

    // 没有 state:write 的插件
    const ro = goodManifest({ id: 'com.example.readonly', permissions: ['state:read'] });
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: ro }, instReply);
    check(r?.t === 'plugin_installed' && !r.token, '无 webhook 的第三方插件不签 token', r);
    r = await memberA.req({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.readonly', patch: { a: 1 } }, stReply);
    check(r?.reason === 'forbidden', '无 state:write -> 成员写 forbidden', r);

    console.log('\n[插件 token 作用域]');
    let res = await api(helloToken, '/api/v1/circle');
    let body = await jsonOf(res);
    check(res.status === 200 && body.id === cid && body.bot?.name === 'Hello' && body.bot.pluginId === 'com.example.hello', '插件 token GET /circle 本圈 200', body);
    res = await api(helloToken, '/api/v1/circle?circleId=c_other');
    check(res.status === 403 && (await jsonOf(res))?.error === 'wrong_circle', '别的圈 -> 403 wrong_circle');
    res = await api(helloToken, '/api/v1/plugins');
    body = await jsonOf(res);
    check(res.status === 200 && body.items.length === 3, 'GET /plugins', body);
    res = await api(helloToken, '/api/v1/plugins/state', { method: 'POST', json: { patch: { fromPlugin: true } } });
    body = await jsonOf(res);
    check(res.status === 200 && body.ok === true && body.rev === revAfter + 1, 'POST /plugins/state -> {ok, rev}', body);
    const pushed = await memberB.waitFor((m) => m.t === 'plugin_state' && m.state?.fromPlugin === true);
    check(Boolean(pushed), 'REST 写状态 -> 成员收到 plugin_state');
    res = await api(helloToken, '/api/v1/plugins/state');
    body = await jsonOf(res);
    check(res.status === 200 && body.pluginId === 'com.example.hello' && body.state.fromPlugin === true, 'GET /plugins/state', body?.rev);
    res = await api(helloToken, '/api/v1/plugins/state', { method: 'POST', json: { patch: 'x' } });
    check(res.status === 400 && (await jsonOf(res))?.error === 'bad_patch', '坏 patch -> 400 bad_patch');

    // 机器人 token:看不见插件 token;不能写插件状态
    owner.drain(() => true);
    r = await owner.req({ t: 'bot_token_create', circleId: cid, ownerKey, name: 'Bot1' }, (m) => m.t === 'bot_token' || (m.t === 'owner_error' && m.op === 'bot_token_create'));
    const botToken = r?.token;
    r = await owner.req({ t: 'bot_token_list', circleId: cid, ownerKey }, (m) => m.t === 'bot_tokens' || m.t === 'owner_error');
    check(r?.t === 'bot_tokens' && r.items.length === 1 && r.items[0].name === 'Bot1', 'bot_token_list 只列机器人 token', r);
    res = await api(botToken, '/api/v1/plugins/state', { method: 'POST', json: { patch: { a: 1 } } });
    check(res.status === 403 && (await jsonOf(res))?.error === 'plugin_token_required', '机器人 token 写插件状态 -> 403 plugin_token_required');
    res = await api(botToken, '/api/v1/plugins');
    check(res.status === 200, '机器人 token 可 GET /plugins');

    console.log('\n[启停 / 配置 / 卸载]');
    r = await memberA.req({ t: 'plugin_set_enabled', circleId: cid, ownerKey: 'x', pluginId: 'com.example.hello', enabled: false }, ownerReply('plugin_set_enabled'));
    check(r?.reason === 'not_owner', '成员停用 -> not_owner', r);
    r = await owner.req({ t: 'plugin_set_enabled', circleId: cid, ownerKey, pluginId: 'com.example.hello', enabled: false }, ownerReply('plugin_set_enabled'));
    check(r?.t === 'owner_ok', '圈主停用 -> owner_ok', r);
    const enEv = await rx.waitFor((x) => x.body?.type === 'enabled' && x.body.data?.enabled === false);
    check(enEv && sigOk(enEv), '停用也投 lifecycle enabled{false}');
    res = await api(helloToken, '/api/v1/circle');
    check(res.status === 403 && (await jsonOf(res))?.error === 'plugin_disabled', '停用后插件 token -> 403 plugin_disabled');
    memberA.drain(() => true);
    r = await memberA.req({ t: 'plugin_state_set', circleId: cid, pluginId: 'com.example.hello', patch: { a: 1 } }, stReply);
    check(r?.reason === 'disabled', '停用后成员写 -> disabled', r);
    const nBefore = rx.got.filter((x) => x.body?.type === 'leave').length;
    await memberB.req({ t: 'leave', circleId: cid }, () => false, 300);
    await wait(300);
    check(rx.got.filter((x) => x.body?.type === 'leave').length === nBefore, '停用的插件不投订阅事件');
    await join(memberB, cid);
    r = await owner.req({ t: 'plugin_set_enabled', circleId: cid, ownerKey, pluginId: 'com.example.hello', enabled: true }, ownerReply('plugin_set_enabled'));
    check(r?.t === 'owner_ok' && (await api(helloToken, '/api/v1/circle')).status === 200, '重新启用 -> token 恢复');
    r = await owner.req({ t: 'plugin_config_set', circleId: cid, ownerKey, pluginId: 'com.example.hello', config: { greeting: 'yo' } }, ownerReply('plugin_config_set'));
    check(r?.t === 'owner_ok', '第三方插件 config_set', r);
    const cfgEv = await rx.waitFor((x) => x.body?.type === 'config');
    check(cfgEv?.body?.data?.config?.greeting === 'yo', 'lifecycle config 事件', cfgEv?.body);
    r = await owner.req({ t: 'plugin_config_set', circleId: cid, ownerKey, pluginId: 'com.example.hello', config: { big: 'x'.repeat(5000) } }, ownerReply('plugin_config_set'));
    check(r?.reason === 'bad_config', 'config 超 4 KB -> bad_config', r);
    r = await owner.req({ t: 'plugin_config_set', circleId: cid, ownerKey, pluginId: 'lares.focus', config: { focusMin: 0 } }, ownerReply('plugin_config_set'));
    check(r?.reason === 'bad_config', '专注 focusMin=0 -> bad_config', r);
    r = await owner.req({ t: 'plugin_config_set', circleId: cid, ownerKey, pluginId: 'lares.focus', config: { focusMin: 50 } }, ownerReply('plugin_config_set'));
    memberA.drain(() => true);
    const lst = await memberA.req({ t: 'plugin_list', circleId: cid }, (m) => m.t === 'plugins');
    const fcfg = lst?.items?.find((p) => p.id === 'lares.focus')?.config;
    check(r?.t === 'owner_ok' && fcfg?.focusMin === 50 && fcfg.breakMin === 5, '专注配置补默认', fcfg);

    console.log('\n[持久化(重启)]');
    await stop(srv);
    const st = statSync(path.join(dataDir, 'plugins.json'));
    check(process.platform === 'win32' || (st.mode & 0o777) === 0o600, 'plugins.json 权限 0600');
    srv = boot(PORT, dataDir, GLOBAL_PASS, env);
    check(await waitHealth(PORT), '重启');
    const m2 = await connect(PORT, { userId: 'u_a', name: 'Alice', auth: v2Auth(verifier, cid) });
    clients.push(m2);
    r = await m2.req({ t: 'plugin_state_get', circleId: cid, pluginId: 'com.example.hello' }, stReply);
    check(r?.state?.fromPlugin === true && r.rev === revAfter + 1, '共享状态与 rev 重启后还在', r?.rev);
    check(m2.msg?.circle?.plugins?.length === 3, 'welcome.circle.plugins 重启后 3 个', m2.msg?.circle?.plugins?.length);
    res = await api(helloToken, '/api/v1/circle');
    check(res.status === 200, '插件 token 重启后仍有效');

    const owner2 = await connect(PORT, { userId: 'u_owner', auth: v2Auth(verifier, cid, { ownerKey }) });
    clients.push(owner2);
    // 再装 7 个凑满 10
    for (let i = 0; i < 7; i++) {
      r = await owner2.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: goodManifest({ id: `com.example.p${i}`, permissions: [] }) }, instReply);
    }
    check(r?.t === 'plugin_installed', '装满 10 个');
    r = await owner2.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: goodManifest({ id: 'com.example.p99', permissions: [] }) }, instReply);
    check(r?.reason === 'too_many', '第 11 个 -> too_many', r);

    r = await owner2.req({ t: 'plugin_uninstall', circleId: cid, ownerKey, pluginId: 'com.example.hello' }, ownerReply('plugin_uninstall'));
    check(r?.t === 'owner_ok', '卸载 -> owner_ok', r);
    const unEv = await rx.waitFor((x) => x.body?.type === 'uninstalled');
    check(unEv && sigOk(unEv), 'lifecycle uninstalled 投递');
    res = await api(helloToken, '/api/v1/circle');
    check(res.status === 401, '卸载后插件 token -> 401');
    r = await owner2.req({ t: 'plugin_uninstall', circleId: cid, ownerKey, pluginId: 'com.example.hello' }, ownerReply('plugin_uninstall'));
    check(r?.reason === 'not_found', '重复卸载 -> not_found', r);

    console.log('\n[解散清理]');
    r = await owner2.req({ t: 'circle_delete', circleId: cid, ownerKey }, ownerReply('circle_delete'));
    await wait(300);
    const stored = JSON.parse(readFileSync(path.join(dataDir, 'plugins.json'), 'utf8'));
    check(r?.t === 'owner_ok' && !stored.circles[cid], '解散后安装记录删除', Object.keys(stored.circles));

    console.log('\n[SSRF(无 ALLOW_PRIVATE)]');
    const reg2 = await registerCircle(PORT_STRICT, PASSCODE, 'u_owner2');
    clients.push(reg2.owner);
    for (const url of ['http://127.0.0.1:9/h', 'https://127.0.0.1:9/h', 'https://localhost:9/h', 'https://10.0.0.1/h', 'https://[::1]/h']) {
      r = await reg2.owner.req({ t: 'plugin_install', circleId: reg2.cid, ownerKey: reg2.ownerKey, manifest: goodManifest({ id: 'com.example.ssrf', webhook: { url, events: ['join'] } }) }, instReply);
      check(r?.t === 'owner_error' && (r.reason === 'ssrf_blocked' || r.reason === 'bad_manifest'), `webhook ${url} -> ${r?.reason}`, r);
    }
    r = await reg2.owner.req({ t: 'plugin_install', circleId: reg2.cid, ownerKey: reg2.ownerKey, manifestUrl: 'https://127.0.0.1:9/manifest.json' }, instReply);
    check(r?.reason === 'ssrf_blocked', 'manifestUrl 指向回环 -> ssrf_blocked', r);
    r = await reg2.owner.req({ t: 'plugin_install', circleId: reg2.cid, ownerKey: reg2.ownerKey, manifestUrl: 'http://example.com/m.json' }, instReply);
    check(r?.t === 'owner_error' && (r.reason === 'ssrf_blocked' || r.reason === 'bad_request'), 'manifestUrl http -> 拒', r);
  } finally {
    for (const c of clients) await c.close?.().catch?.(() => {});
    await stop(srv);
    await stop(srvStrict);
    await rx.close();
  }
  console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
  if (T.fail && !process.env.DEBUG) console.log(srv.out.slice(-3000));
  process.exit(T.fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
