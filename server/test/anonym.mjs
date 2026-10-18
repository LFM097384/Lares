// 隐名之约 v2(server/anonym-agent/AGENT-V2.md §1-§3)端到端:真服务端进程 + 假 agent 进程
// (test/fixtures/fake_anonym_agent.mjs,经 LARES_ANONYM_AGENT_ENTRY 注入)+ 假记忆读取
// (test/fixtures/fake_filememory.mjs,经 LARES_ANONYM_FILEMEMORY_MODULE 注入)。
// 旁路:假 APNs(推送脱敏)、插件 webhook 接收器、机器人 SSE、AI 语音助手(装了 @livekit/rtc-node 才测)。
//
// 覆盖:invite 只许圈主 / 注册圈 / 在房 / k 校验 → 子进程 env 不含主密钥、argv 无密钥 →
// agent 以 u_ai_anon_* 身份进房(语音助手的凭证冒充不了)→ hello → 只有圈主收 keyreq → 圈主 key 只交给 agent(原样密文)→
// anon_active 只认 agent 连接 → 强制关闭开 / 关(转写、机器人字幕 409、SSE + webhook 静默、推送脱敏、语音助手停)→
// anon_agent_state 广播 → anon_released_notice → knowledge.released webhook(读记忆文件)→
// 知识检索端点鉴权 → dismiss → 语音助手回来 → E2EE 圈可邀请 → circle_delete 删记忆目录。
// 服务端日志不含公钥 / 密文 / 条目文本。
//
// 用法:node test/anonym.mjs    (DEBUG=1 显示服务端 stderr)

import crypto, { randomBytes } from 'node:crypto';
import http from 'node:http';
import http2 from 'node:http2';
import { mkdtempSync, readFileSync, existsSync, mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v1Auth, v2Auth, ownerReply, wait,
} from './lib/harness.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const T = makeChecker();
const { check } = T;
const PORT = 18998;
const GLOBAL_PASS = 'anon-global-' + randomBytes(4).toString('hex');
const BASE = `http://127.0.0.1:${PORT}`;
const AI_MEMBER_KEY = 'ai-member-key-' + randomBytes(8).toString('hex');
const hmacHex = (k, s) => crypto.createHmac('sha256', k).update(s).digest('hex');
const h8 = (s) => crypto.createHash('sha256').update(s).digest('hex').slice(0, 8);

let rtcOk = true;
try { await import('@livekit/rtc-node'); } catch { rtcOk = false; }

// ── 假端点 ──
function startFakeApns() {
  const requests = [];
  const server = http2.createSecureServer({
    cert: readFileSync(path.join(HERE, 'fixtures', 'fake-apns-TEST-ONLY.cert.pem')),
    key: readFileSync(path.join(HERE, 'fixtures', 'fake-apns-TEST-ONLY.key.pem')),
  });
  server.on('stream', (stream, headers) => {
    const chunks = [];
    stream.on('data', (c) => chunks.push(c));
    stream.on('end', () => {
      const p = headers[':path'];
      let body = null;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* null */ }
      requests.push({ at: Date.now(), token: p.startsWith('/3/device/') ? p.slice(10) : '', body });
      stream.respond({ ':status': 200, 'apns-id': crypto.randomUUID() });
      stream.end();
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port, requests,
    async waitFor(pred, ms = 3000) {
      const end = Date.now() + ms;
      while (Date.now() < end) { const h = requests.find(pred); if (h) return h; await wait(20); }
      return null;
    },
    close: () => new Promise((r) => server.close(r)),
  })));
}

function startReceiver() {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      let body = null; try { body = JSON.parse(raw); } catch { /* */ }
      got.push({ raw, body, at: Date.now() });
      res.writeHead(200); res.end('ok');
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port, got,
    async waitFor(pred, ms = 4000) {
      const end = Date.now() + ms;
      while (Date.now() < end) { const h = got.find(pred); if (h) return h; await wait(20); }
      return null;
    },
    close: () => new Promise((r) => server.close(r)),
  })));
}

async function openSse(token) {
  const ctrl = new AbortController();
  const res = await fetch(BASE + '/api/v1/events', { headers: { authorization: `Bearer ${token}` }, signal: ctrl.signal });
  const sse = { res, raw: '', events: [], ctrl };
  if (!res.ok) return sse;
  (async () => {
    const dec = new TextDecoder();
    let buf = '';
    try {
      for await (const chunk of res.body) {
        const s = dec.decode(chunk, { stream: true });
        sse.raw += s; buf += s;
        let i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const block = buf.slice(0, i); buf = buf.slice(i + 2);
          const ev = {};
          for (const line of block.split('\n')) { const m = /^(event|data): (.*)$/.exec(line); if (m) ev[m[1]] = m[2]; }
          if (ev.event) { try { ev.data = JSON.parse(ev.data); } catch { /* */ } sse.events.push(ev); }
        }
      }
    } catch { /* aborted */ }
  })();
  return sse;
}

const getJson = async (p, token) => {
  const r = await fetch(BASE + p, { headers: token ? { authorization: `Bearer ${token}` } : {} });
  let body = null; try { body = await r.json(); } catch { /* */ }
  return { status: r.status, body };
};

// ── 假 agent 驱动 ──
function agentKit(agentDir) {
  const dirOf = (cid) => path.join(agentDir, cid);
  return {
    cmd(cid, m) { mkdirSync(dirOf(cid), { recursive: true }); appendFileSync(path.join(dirOf(cid), 'cmd.jsonl'), JSON.stringify(m) + '\n'); },
    inbox(cid) {
      try { return readFileSync(path.join(dirOf(cid), 'inbox.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; }
    },
    async waitInbox(cid, pred, ms = 4000) {
      const end = Date.now() + ms;
      while (Date.now() < end) { const h = this.inbox(cid).find(pred); if (h) return h; await wait(30); }
      return null;
    },
    async env(cid, ms = 6000) {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        try { return JSON.parse(readFileSync(path.join(dirOf(cid), 'env.json'), 'utf8')); } catch { await wait(50); }
      }
      return null;
    },
  };
}

async function e2e() {
  console.log('\n[隐名之约 v2:服务器只管元数据]');
  const apns = await startFakeApns();
  const rx = await startReceiver();
  const { privateKey: apnsKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-anonym-'));
  const agentDir = mkdtempSync(path.join(tmpdir(), 'lares-anonym-agent-'));
  const agent = agentKit(agentDir);
  const env = {
    LARES_ANONYM_AGENT_ENTRY: path.join(HERE, 'fixtures', 'fake_anonym_agent.mjs'),
    LARES_ANONYM_FILEMEMORY_MODULE: path.join(HERE, 'fixtures', 'fake_filememory.mjs'),
    FAKE_AGENT_DIR: agentDir,
    LARES_AI_MEMBER_KEY: AI_MEMBER_KEY,
    LARES_AUTH_TOKEN: 'master-token-' + randomBytes(6).toString('hex'),
    LARES_DASHSCOPE_API_KEY: 'sk-test-' + randomBytes(6).toString('hex'),
    LARES_APNS_KEY: apnsKey.export({ type: 'pkcs8', format: 'pem' }),
    LARES_APNS_KEY_ID: 'TESTKEY123', LARES_APNS_TEAM_ID: '7CH28564U7',
    LARES_APNS_HOST_OVERRIDE: `https://127.0.0.1:${apns.port}`, LARES_APNS_INSECURE_TLS: '1',
    LARES_PUBLIC_URL: 'wss://lares.test:8444/ws',
    LARES_PLUGIN_ALLOW_PRIVATE: '1',
    LIVEKIT_URL: 'ws://127.0.0.1:9', LIVEKIT_API_KEY: 'devkey', LIVEKIT_API_SECRET: 'secret-secret-secret-secret-secret',
    LARES_AI_PROVIDERS: 'mock',
  };
  const srv = boot(PORT, dataDir, GLOBAL_PASS, env);
  const open = [];
  const isErr = (op) => (m) => m.t === 'anon_error' && m.op === op;
  const isOk = (op) => (m) => (m.t === 'anon_ok' || m.t === 'anon_error') && m.op === op;
  const PUB = 'cHViLWtleS1mYWtl';
  const SEALED = 'c2VhbGVkLW1lZGlhLWtleS0' + randomBytes(12).toString('hex');
  const ITEM_TEXT = 'marmaladeRelease launches friday';
  try {
    check(await waitHealth(PORT), '服务端启动');
    const { cid, verifier, ownerKey, owner: reg } = await registerCircle(PORT, 'anon-pass-' + randomBytes(4).toString('hex'), 'u_owner');
    await reg.close();
    const anonId = `u_ai_anon_${h8(cid)}`;
    const aiId = `u_ai_${h8(cid)}`;
    const memDir = path.join(dataDir, 'anonym_memory', cid);
    const A = await connect(PORT, { userId: 'u_owner', name: '阿蛮', auth: v2Auth(verifier, cid, { ownerKey }) });
    const B = await connect(PORT, { userId: 'u_bob', name: 'Bobsworth', auth: v2Auth(verifier, cid) });
    const D = await connect(PORT, { userId: 'u_dave', name: 'Davo', auth: v2Auth(verifier, cid) }); // 大厅里,收推送
    open.push(A, B, D);
    check([A, B, D].every((c) => c.kind === 'welcome'), '三个成员连上');

    // 准备:转写开、装插件(一个有 knowledge:read、一个没有)、建机器人 token、D 登记推送
    let r = await A.req({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_ok', '圈主开转写记录', r);
    const manifest = (id, perms) => ({
      id, name: 'KB', version: '1.0.0', description: 'kb', author: 'x', permissions: perms,
      webhook: { url: `http://127.0.0.1:${rx.port}/hook`, events: ['join', 'knowledge.released'] },
    });
    r = await A.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: manifest('com.example.kb', ['circle:read', 'members:read', 'knowledge:read']) }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    check(r?.t === 'plugin_installed', '装插件(knowledge:read + knowledge.released webhook)', r);
    const pluginToken = r?.token;
    r = await A.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: { ...manifest('com.example.nokb', ['circle:read', 'members:read']), webhook: { url: `http://127.0.0.1:${rx.port}/hook2`, events: ['join'] } } }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    const pluginNoKb = r?.token;
    check(typeof pluginNoKb === 'string', '装第二个插件(无 knowledge:read)', r);
    r = await A.req({ t: 'bot_token_create', circleId: cid, name: 'bot', ownerKey }, (m) => m.t === 'bot_token' || m.t === 'owner_error');
    const botToken = r?.token;
    check(typeof botToken === 'string', '建机器人 token', r);
    const TD = randomBytes(32).toString('hex');
    const nowUtcMin = new Date().getUTCHours() * 60 + new Date().getUTCMinutes();
    r = await D.req({ t: 'push_register', provider: 'apns', token: TD, env: 'sandbox', lang: 'zh',
      circles: [{ circleId: cid, name: '秘密圈', level: 'all' }], prefs: { tzOffsetMin: 0, quiet: { start: (nowUtcMin + 120) % 1440, end: (nowUtcMin + 180) % 1440 } } },
    (m) => m.t === 'push_registered' || m.t === 'push_error');
    check(r?.t === 'push_registered', 'D 登记推送', r);

    // ── 邀请的门槛 ──
    console.log('\n[邀请:只许圈主]');
    const E = await connect(PORT, { userId: 'u_env', name: 'Env', auth: v1Auth(GLOBAL_PASS, 'c_envtest') });
    open.push(E);
    await join(E, 'c_envtest');
    r = await E.req({ t: 'anon_agent_invite', circleId: 'c_envtest' }, isErr('anon_agent_invite'));
    check(r?.code === 'not_registered', 'env 圈(未注册)→ not_registered', r);
    await E.close();

    if (rtcOk) {
      r = await A.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.ai-voice' }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
      check(r?.t === 'plugin_installed', '装 lares.ai-voice', r);
    }
    r = await A.req({ t: 'anon_agent_invite', circleId: cid }, isErr('anon_agent_invite'));
    check(r?.code === 'not_in_room', '圈主不在房 → not_in_room', r);
    await join(A, cid);
    await join(B, cid);
    if (rtcOk) {
      const j = await A.waitFor((m) => m.t === 'member_joined' && m.member?.userId === aiId, 15000);
      check(Boolean(j), 'AI 语音助手(邀请前)正常进房', j ?? srv.out.slice(-800));
    }
    const sse = await openSse(botToken);
    check(sse.res.status === 200, '机器人 SSE 连上', sse.res.status);
    r = await B.req({ t: 'anon_agent_invite', circleId: cid }, isErr('anon_agent_invite'));
    check(r?.code === 'not_owner', '非圈主 invite → not_owner', r);
    r = await B.req({ t: 'anon_agent_invite', circleId: cid, ownerKey: randomBytes(32).toString('hex') }, isErr('anon_agent_invite'));
    check(r?.code === 'not_owner', '错的 ownerKey → not_owner', r);
    r = await A.req({ t: 'anon_agent_invite', circleId: cid, k: 1 }, isErr('anon_agent_invite'));
    check(r?.code === 'bad_k', 'k < 2 → bad_k', r);
    r = await A.req({ t: 'anon_agent_dismiss', circleId: cid }, isOk('anon_agent_dismiss'));
    check(r?.t === 'anon_ok', '没邀请过时 dismiss 也幂等 ok', r);
    check(!existsSync(path.join(agentDir, cid, 'env.json')), '门槛没过时没有拉起任何进程');

    for (const c of [A, B]) c.drain(() => true);
    r = await A.req({ t: 'anon_agent_invite', circleId: cid, k: 3 }, isOk('anon_agent_invite'));
    check(r?.t === 'anon_ok', '圈主 invite{k:3} → anon_ok', r);
    r = await A.req({ t: 'anon_agent_invite', circleId: cid }, isErr('anon_agent_invite'));
    check(r?.code === 'already_active', '重复邀请 → already_active', r);

    // ── 子进程 env ──
    console.log('\n[子进程 env:不含主密钥]');
    const ce = await agent.env(cid);
    check(Boolean(ce), 'agent 子进程已启动(LARES_ANONYM_AGENT_ENTRY)', srv.out.slice(-600));
    const cenv = ce?.env ?? {};
    const masterKeys = Object.keys(cenv).filter((k) => k.startsWith('LIVEKIT_') || k.startsWith('LARES_APNS_')
      || ['LARES_AUTH_TOKEN', 'LARES_CIRCLE_PASSCODE', 'LARES_CIRCLE_PASSCODES', 'LARES_AI_MEMBER_KEY'].includes(k));
    check(masterKeys.length === 0, 'env 不含 LIVEKIT_* / LARES_APNS_* / LARES_AUTH_TOKEN / 口令 / LARES_AI_MEMBER_KEY', masterKeys);
    const envValues = JSON.stringify(cenv);
    check(!envValues.includes(env.LARES_AUTH_TOKEN) && !envValues.includes(env.LIVEKIT_API_SECRET) && !envValues.includes(AI_MEMBER_KEY) && !envValues.includes(GLOBAL_PASS),
      'env 值里也找不到主密钥原文');
    check(cenv.LARES_ANONYM_K === '3' && cenv.LARES_ANONYM_USER_ID === anonId && cenv.LARES_ANONYM_E2EE === '0', 'env 带 k=3、u_ai_anon_* 身份、E2EE=0', { k: cenv.LARES_ANONYM_K, u: cenv.LARES_ANONYM_USER_ID });
    check(cenv.LARES_ANONYM_MEMORY_DIR === memDir, 'env 带记忆目录 DATA_DIR/anonym_memory/<cid>', cenv.LARES_ANONYM_MEMORY_DIR);
    check(cenv.LARES_AI_MEMBER_SECRET === hmacHex(AI_MEMBER_KEY, `lares-ai-anon-member:${cid}`)
      && cenv.LARES_AI_MEMBER_SECRET !== hmacHex(AI_MEMBER_KEY, `lares-ai-member:${cid}`), '成员凭证是隐名角色专用派生(≠ 语音助手的)');
    check(cenv.LARES_AI_AUTH_SECRET === verifier && cenv.LARES_AI_AUTH_V === '2', '圈级证明材料 = verifier(v2)');
    check(cenv.LARES_DASHSCOPE_API_KEY === env.LARES_DASHSCOPE_API_KEY, 'ASR 的 DashScope key 照常传下去');
    const argv = ce?.argv ?? [];
    check(argv.join(' ') === `--circle ${cid} --signaling ws://127.0.0.1:${PORT}/ws`, 'argv 只有 --circle / --signaling(无密钥)', argv);

    // ── 进房 + 互斥 + 密钥中继 ──
    console.log('\n[agent 进房、与语音助手互斥、密钥中继]');
    const aj = await A.waitFor((m) => m.t === 'member_joined' && m.member?.userId === anonId, 6000);
    check(Boolean(aj), 'agent 以 u_ai_anon_* 进房', aj ?? srv.out.slice(-800));
    const kr = await A.waitFor((m) => m.t === 'anon_agent_keyreq', 4000);
    check(kr?.circleId === cid && kr.x25519Pub === PUB, '圈主收到 anon_agent_keyreq{x25519Pub}', kr);
    const stB = await B.waitFor((m) => m.t === 'anon_agent_state' && m.present === true);
    check(stB?.circleId === cid && stB.active === false, '成员收到 anon_agent_state{present:true, active:false}', stB);
    await wait(200);
    check(!B.inbox.some((m) => m.t === 'anon_agent_keyreq'), '非圈主收不到 keyreq', B.inbox.map((m) => m.t));
    if (rtcOk) {
      const left = await A.waitFor((m) => m.t === 'member_left' && m.userId === aiId, 8000);
      check(Boolean(left), '邀请 → AI 语音助手离房(互斥)', left ?? A.inbox.map((m) => m.t));
      check(/\[ai-voice\][^\n]*停止\(disabled\)/.test(srv.out), 'supervisor 以 disabled 停掉语音助手', srv.out.split('\n').filter((l) => l.includes('[ai-voice]')).slice(-6));
    }
    r = await B.req({ t: 'anon_agent_key', circleId: cid, sealed: SEALED }, isErr('anon_agent_key'));
    check(r?.code === 'not_owner', '非圈主发 anon_agent_key → not_owner', r);
    r = await A.req({ t: 'anon_agent_key', circleId: cid, sealed: 'not base64 <script>' }, isErr('anon_agent_key'));
    check(r?.code === 'bad_request', '非 base64 / hex 的密文 → bad_request', r);
    r = await A.req({ t: 'anon_agent_key', circleId: cid, sealed: SEALED, x25519Pub: 'b3RoZXIta2V5' }, isErr('anon_agent_key'));
    check(r?.code === 'stale_key', '针对旧公钥封的 → stale_key', r);
    r = await A.req({ t: 'anon_agent_key', circleId: cid, sealed: SEALED, x25519Pub: PUB }, isOk('anon_agent_key'));
    check(r?.t === 'anon_ok', '圈主 anon_agent_key → anon_ok', r);
    const got = await agent.waitInbox(cid, (m) => m.t === 'anon_agent_key');
    check(got?.sealed === SEALED && got.x25519Pub === PUB && got.circleId === cid, 'agent 原样收到密文', got);
    await wait(200);
    check(!B.inbox.some((m) => m.t === 'anon_agent_key') && !A.inbox.some((m) => m.t === 'anon_agent_key'), '密文只交给 agent(成员 / 圈主都收不到回显)');

    // ── anon_active 只认 agent ──
    console.log('\n[anon_active:只认 agent 连接]');
    r = await A.req({ t: 'anon_active', circleId: cid, on: true }, isErr('anon_active'));
    check(r?.code === 'not_allowed', '圈主发 anon_active → not_allowed', r);
    r = await B.req({ t: 'anon_active', circleId: cid, on: true }, isErr('anon_active'));
    check(r?.code === 'not_allowed', '成员发 anon_active → not_allowed', r);
    r = await B.req({ t: 'anon_agent_hello', circleId: cid, x25519Pub: PUB }, isErr('anon_agent_hello'));
    check(r?.code === 'not_allowed', '成员冒充 anon_agent_hello → not_allowed', r);
    r = await B.req({ t: 'anon_released_notice', circleId: cid, itemIds: ['k1'] }, isErr('anon_released_notice'));
    check(r?.code === 'not_allowed', '成员冒充 anon_released_notice → not_allowed', r);
    // 语音助手的成员凭证冒充不了隐名 agent;没凭证也不行
    const voiceSecret = hmacHex(AI_MEMBER_KEY, `lares-ai-member:${cid}`);
    const fake = await connect(PORT, { userId: anonId, name: 'x', auth: v2Auth(verifier, cid),
      helloExtra: (nonce, uid) => ({ aiAuth: { circleId: cid, proof: hmacHex(voiceSecret, `${nonce}:${uid}:${cid}`) } }) });
    check(fake.kind !== 'welcome', '拿语音助手凭证冒充 u_ai_anon_* → 被拒', fake.kind);
    await fake.close?.();
    const fake2 = await connect(PORT, { userId: anonId, name: 'x', auth: v2Auth(verifier, cid) });
    check(fake2.kind !== 'welcome', '不带 aiAuth 用 u_ai_anon_* → 被拒', fake2.kind);
    await fake2.close?.();
    await wait(200);
    r = await getJson('/api/v1/captions', null);
    const capOff = await fetch(BASE + '/api/v1/captions', { method: 'POST', headers: { authorization: `Bearer ${botToken}`, 'content-type': 'application/json' }, body: JSON.stringify({ text: 'bot line', final: true }) });
    check(capOff.status !== 409, '强制关闭前:机器人字幕不是 409', capOff.status);

    // ── 强制关闭:开 ──
    console.log('\n[强制关闭:开]');
    B.drain(() => true);
    agent.cmd(cid, { t: 'anon_active', on: true });
    const aok = await agent.waitInbox(cid, (m) => m.t === 'anon_ok' && m.op === 'anon_active');
    check(aok?.active === true, 'agent anon_active{on:true} → anon_ok', aok);
    const stOn = await B.waitFor((m) => m.t === 'anon_agent_state' && m.active === true);
    check(stOn?.present === true, '成员收到 anon_agent_state{active:true}', stOn);
    r = await B.req({ t: 'transcript_append', circleId: cid, id: 'x1', text: 'should not archive' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_appended');
    check(r?.t === 'transcript_error' && r.reason === 'anonym_active', 'transcript_append → anonym_active', r);
    r = await B.req({ t: 'transcript_relay', circleId: cid, blob: 'AAAA' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_relayed');
    check(r?.t === 'transcript_error' && r.reason === 'anonym_active', 'transcript_relay → anonym_active', r);
    const cap = await fetch(BASE + '/api/v1/captions', { method: 'POST', headers: { authorization: `Bearer ${botToken}`, 'content-type': 'application/json' }, body: JSON.stringify({ text: 'bot line', final: true }) });
    check(cap.status === 409, '机器人字幕 POST /api/v1/captions → 409', cap.status);
    const sseBefore = sse.events.length;
    const hooksBefore = rx.got.length;
    const F = await connect(PORT, { userId: 'u_frank', name: 'Frankel', auth: v2Auth(verifier, cid) });
    open.push(F);
    await join(F, cid); // 会话期间进房:不发 join SSE / webhook
    const stF = await F.waitFor((m) => m.t === 'anon_agent_state');
    check(stF?.present === true && stF.active === true, '后进房的人收到当前 anon_agent_state', stF);
    await wait(600);
    check(sse.events.length === sseBefore, '强制关闭期间机器人 SSE 无任何事件', sse.events.slice(sseBefore));
    check(rx.got.length === hooksBefore, '强制关闭期间插件 webhook 无任何事件', rx.got.slice(hooksBefore).map((x) => x.body?.type));
    const t0 = Date.now();
    r = await A.req({ t: 'push_summon', circleId: cid, ownerKey }, (m) => m.t === 'push_summon_ok' || m.t === 'owner_error');
    const ps = await apns.waitFor((q) => q.token === TD && q.at >= t0);
    check(ps?.body?.aps?.alert?.title === 'Lares' && ps?.body?.aps?.alert?.body === '有人在你的圈子里', '推送脱敏:标题 Lares、正文不含人名 / 圈名', ps?.body?.aps ?? r);
    if (rtcOk) {
      const back = A.inbox.find((m) => m.t === 'member_joined' && m.member?.userId === aiId);
      check(!back, '强制关闭期间语音助手不回来', back);
    }

    // ── 放行通知 → knowledge.released ──
    console.log('\n[放行通知 + 知识检索]');
    mkdirSync(memDir, { recursive: true });
    writeFileSync(path.join(memDir, 'released.json'), JSON.stringify([
      { id: 'k1', text: ITEM_TEXT, kind: 'fact', sid: 's1', releasedAt: 1, speaker: 'u_bob', approverIds: ['u_owner'] },
      { id: 'k2', text: 'older released item', kind: 'fact' },
    ]));
    agent.cmd(cid, { t: 'anon_released_notice', itemIds: ['k1'] });
    const kh = await rx.waitFor((x) => x.body?.type === 'knowledge.released');
    const kitems = kh?.body?.data?.items ?? kh?.body?.items ?? [];
    check(kitems.length === 1 && kitems[0].id === 'k1' && kitems[0].text === ITEM_TEXT, 'webhook knowledge.released 只含通知里的条目', kh?.body);
    check(kh && !/speaker|approverIds|u_bob|u_owner/.test(kh.raw), 'knowledge.released 字段白名单(无说话人 / 签名人)', kh?.raw);
    check(sse.events.length === sseBefore, '放行也不进机器人 SSE', sse.events.slice(sseBefore));
    r = await agent.waitInbox(cid, (m) => m.t === 'anon_error' && m.op === 'anon_released_notice', 300);
    check(!r, 'agent 的放行通知被接受', r);
    agent.cmd(cid, { t: 'anon_released_notice', itemIds: [] });
    r = await agent.waitInbox(cid, (m) => m.t === 'anon_error' && m.op === 'anon_released_notice');
    check(r?.code === 'bad_request', '空 itemIds → bad_request', r);

    let g = await getJson(`/bot/v1/circles/${cid}/anonym/knowledge?q=${encodeURIComponent('marmalade')}`, pluginToken);
    check(g.status === 200 && g.body.items?.length === 1 && g.body.items[0].id === 'k1' && !('speaker' in g.body.items[0]), 'GET …/anonym/knowledge?q=(插件 token,knowledge:read)→ 已放行条目(字段白名单)', g);
    const calls = readFileSync(path.join(memDir, 'calls.log'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    check(calls.some((c) => c.dir === memDir && c.q === 'marmalade'), 'readReleasedKnowledge(dir = anonym_memory/<cid>, q)', calls);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/knowledge?q=x`, botToken);
    check(g.status === 200, '圈主建的机器人 token 可读', g);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/knowledge?q=x`);
    check(g.status === 401, '无 token → 401', g.status);
    g = await getJson(`/bot/v1/circles/c_someoneelse/anonym/knowledge?q=x`, botToken);
    check(g.status === 403 && g.body?.error === 'wrong_circle', '别的圈 → 403 wrong_circle', g);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/knowledge?q=x`, pluginNoKb);
    check(g.status === 403 && g.body?.error === 'permission_required', '插件没声明 knowledge:read → 403', g);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/knowledge?q=x&limit=0`, botToken);
    check(g.status === 400, 'limit 越界 → 400', g.status);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/released`, botToken);
    check(g.status === 404, 'v1 的 /anonym/released 已删 → 404', g.status);

    // ── 强制关闭:关 ──
    console.log('\n[强制关闭:关]');
    agent.cmd(cid, { t: 'anon_active', on: false });
    const stOff = await B.waitFor((m) => m.t === 'anon_agent_state' && m.active === false);
    check(stOff?.present === true, 'anon_agent_state{active:false}(agent 仍在场)', stOff);
    r = await B.req({ t: 'transcript_append', circleId: cid, id: 'x2', text: 'ok now' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_appended');
    check(r && r.reason !== 'anonym_active', '关掉后转写不再被 anonym_active 拦', r);
    const cap2 = await fetch(BASE + '/api/v1/captions', { method: 'POST', headers: { authorization: `Bearer ${botToken}`, 'content-type': 'application/json' }, body: JSON.stringify({ text: 'bot line', final: true }) });
    check(cap2.status !== 409, '关掉后机器人字幕不再 409', cap2.status);
    if (rtcOk) {
      await wait(600);
      check(!A.inbox.some((m) => m.t === 'member_joined' && m.member?.userId === aiId), 'agent 仍在场 → 语音助手仍不回来(互斥)');
    }

    // ── dismiss ──
    console.log('\n[dismiss]');
    r = await B.req({ t: 'anon_agent_dismiss', circleId: cid }, isErr('anon_agent_dismiss'));
    check(r?.code === 'not_owner', '非圈主 dismiss → not_owner', r);
    r = await A.req({ t: 'anon_agent_dismiss', circleId: cid }, isOk('anon_agent_dismiss'));
    check(r?.t === 'anon_ok', '圈主 dismiss → anon_ok', r);
    const gone = await A.waitFor((m) => m.t === 'member_left' && m.userId === anonId, 8000);
    check(Boolean(gone), 'agent 进程停掉、离房', gone ?? srv.out.slice(-600));
    const stGone = await B.waitFor((m) => m.t === 'anon_agent_state' && m.present === false, 4000);
    check(stGone?.active === false, 'anon_agent_state{present:false}', stGone);
    if (rtcOk) {
      const back = await A.waitFor((m) => m.t === 'member_joined' && m.member?.userId === aiId, 15000);
      check(Boolean(back), 'agent 走后 AI 语音助手回来', back ?? srv.out.split('\n').filter((l) => l.includes('[ai-voice]')).slice(-6));
    }
    agent.cmd(cid, { t: 'anon_active', on: true }); // 进程已退,无人执行;保证没有残留连接
    await wait(300);
    r = await B.req({ t: 'transcript_append', circleId: cid, id: 'x3', text: 'still ok' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_appended');
    check(r && r.reason !== 'anonym_active', 'dismiss 后强制关闭保持关', r);

    // ── E2EE 圈可邀请 ──
    console.log('\n[E2EE 圈]');
    {
      const z = await registerCircle(PORT, 'anon-e2ee-' + randomBytes(4).toString('hex'), 'u_zed');
      open.push(z.owner);
      r = await z.owner.req({ t: 'circle_e2ee_set', circleId: z.cid, enabled: true, ownerKey: z.ownerKey }, ownerReply('circle_e2ee_set'));
      check(r?.t === 'owner_ok', '开 E2EE', r);
      await join(z.owner, z.cid);
      r = await z.owner.req({ t: 'anon_agent_invite', circleId: z.cid, ownerKey: z.ownerKey }, isOk('anon_agent_invite'));
      check(r?.t === 'anon_ok', 'E2EE 圈 invite → anon_ok(服务器只中继密文)', r);
      const ze = await agent.env(z.cid);
      check(ze?.env?.LARES_ANONYM_E2EE === '1' && !('LARES_ANONYM_K' in (ze?.env ?? {})), 'E2EE 圈子进程 env:LARES_ANONYM_E2EE=1;未给 k 就不带', ze?.env?.LARES_ANONYM_E2EE);
      const zkr = await z.owner.waitFor((m) => m.t === 'anon_agent_keyreq', 6000);
      check(zkr?.circleId === z.cid, 'E2EE 圈主收到 keyreq', zkr);
      // 别的圈的 agent 不能开本圈的强制关闭
      agent.cmd(z.cid, { t: 'anon_active', circleId: cid, on: true });
      const xr = await agent.waitInbox(z.cid, (m) => m.t === 'anon_error' && m.op === 'anon_active');
      check(Boolean(xr) && ['not_member', 'not_allowed'].includes(xr.code), '别圈的 agent 发本圈 anon_active → 拒', xr);
      r = await B.req({ t: 'transcript_append', circleId: cid, id: 'x4', text: 'still ok' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_appended');
      check(r && r.reason !== 'anonym_active', '本圈强制关闭没被别圈 agent 打开', r);
      await z.owner.req({ t: 'anon_agent_dismiss', circleId: z.cid, ownerKey: z.ownerKey }, isOk('anon_agent_dismiss'));
    }

    // 服务端日志不含公钥 / 密文 / 条目文本
    const leaked = [SEALED, PUB, ITEM_TEXT, 'marmaladeRelease'].filter((w) => srv.out.includes(w));
    check(leaked.length === 0, '服务端日志不含公钥 / 密文 / 条目文本', leaked);

    // ── 解散圈 → 删记忆目录 ──
    console.log('\n[circle_delete]');
    check(existsSync(memDir), '记忆目录存在');
    sse.ctrl.abort();
    r = await A.req({ t: 'circle_delete', circleId: cid, ownerKey }, ownerReply('circle_delete'), 4000);
    await wait(500);
    check(!existsSync(memDir), 'circle_delete → anonym_memory/<cid>/ 整个目录删除', r);
  } finally {
    for (const c of open) await c.close?.().catch?.(() => {});
    await wait(100);
    await stop(srv);
    await apns.close(); await rx.close();
    if (T.fail && !process.env.DEBUG) console.log(srv.out.slice(-3000));
  }
}

console.log('隐名之约 v2(anonym)');
await e2e();
console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
process.exit(T.fail === 0 ? 0 : 1);
