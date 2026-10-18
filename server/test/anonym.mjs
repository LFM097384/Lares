// 隐名之约(anonym)端到端:真服务端进程 + 真核心(server/anonym-agent/core,LLM=off → 确定性 mock)。
// 旁路:假 DashScope token 端点(cap_token)、假 APNs(推送脱敏)、插件 webhook 接收器、机器人 SSE、
// AI 语音助手 supervisor(装了 @livekit/rtc-node 才测)。
//
// 覆盖:start(圈主 / 在房 / 注册圈 / k 校验)→ anon_state 发给全房 → ack(公钥)→ 未 ack 的话不进 →
// ask / draft / review → approve(真 Ed25519,客户端格式:标准 base64 公钥 + 签名、base64url nonce;
// 重放 / 旧 hash / 坏签名拒)→ released → bot API /released + /knowledge → knowledge.released webhook →
// 圈子记忆 list / retract(canRetract、墓碑、anon_mem_retracted 广播)→ end(receipt)→ 内存即焚 →
// 最后一个真人离开自动结束 → 解散圈删知识库文件。
// 会话期强制关闭:转写 append/relay(anonym_active)、机器人 SSE + webhook、AI 语音、推送脱敏;cap_token 照常。
// 日志不含任何原话 / 问题 / 回答。
//
// 用法:node test/anonym.mjs    (DEBUG=1 显示服务端 stderr)

import crypto, { randomBytes } from 'node:crypto';
import http from 'node:http';
import http2 from 'node:http2';
import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v1Auth, v2Auth, ownerReply, wait,
} from './lib/harness.mjs';
import { createAnonymLlm } from '../src/anonym.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const T = makeChecker();
const { check } = T;
const PORT = 18998;
const GLOBAL_PASS = 'anon-global-' + randomBytes(4).toString('hex');
const BASE = `http://127.0.0.1:${PORT}`;
const MIN = 60_000;

let rtcOk = true;
try { await import('@livekit/rtc-node'); } catch { rtcOk = false; }

// 会出现在原话 / 问题里的标记:服务端日志里一个都不许有
const SECRET_WORDS = ['zebraquartz', 'marmalade', 'pelicanfjord', 'tangerinevault', 'obsidianlark'];

// ── 客户端签名(与 docs/plans/chatham/client-canonicalisation.md 一致)──
function newKey() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
  return { privateKey, pubKey: raw.toString('base64') }; // 标准 base64,带 = 填充
}
const canonical = (o) => JSON.stringify(Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]])));
function signApproval(key, { sid, draftId, draftHash }) {
  const nonce = randomBytes(16).toString('base64url'); // 22 字符,无填充
  const msg = canonical({ sid, draftId, draftHash, nonce });
  const sig = crypto.sign(null, Buffer.from(msg, 'utf8'), key.privateKey).toString('base64');
  return { nonce, sig };
}

// ── 假端点 ──
function startFakeDashscope() {
  const requests = [];
  let n = 0;
  const server = http.createServer((req, res) => {
    requests.push({ method: req.method, url: req.url });
    req.resume();
    n++;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ token: `st-fake-${n}`, expires_at: Math.floor(Date.now() / 1000) + 300 }));
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, requests, close: () => new Promise((r) => server.close(r)) })));
}

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

// ── 纯函数:LLM 组装(主 → DashScope 回退;错误不带正文)──
async function unitLlm() {
  console.log('\n[LLM 组装(createAnonymLlm)]');
  check(createAnonymLlm({}) === null, '没有任何 key → null(核心走 mock)');
  check(createAnonymLlm({ LARES_DASHSCOPE_API_KEY: 'k', LARES_ANONYM_LLM: 'off' }) === null, 'LARES_ANONYM_LLM=off → null');
  const calls = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, model: body.model, auth: init.headers.Authorization, thinking: body.thinking, enable_thinking: body.enable_thinking });
    if (url.includes('deepseek')) return new Response('upstream says SECRET-PROMPT-ECHO', { status: 500 });
    return new Response(JSON.stringify({ choices: [{ message: { content: '{"ok":1}' }, finish_reason: 'stop' }], usage: { total_tokens: 3 } }), { status: 200 });
  };
  const llm = createAnonymLlm({
    LARES_AI_LLM_BASE_URL: 'https://api.deepseek.com', LARES_AI_LLM_API_KEY: 'sk-ds', LARES_AI_LLM_MODEL: 'deepseek-flash',
    LARES_DASHSCOPE_API_KEY: 'sk-dash',
  }, { fetchImpl });
  const r = await llm.chat([{ role: 'user', content: 'hi' }], { json: true });
  check(r.text === '{"ok":1}' && calls.length === 2, '主 LLM(DeepSeek)失败 → 回退 DashScope', calls);
  check(calls[0].model === 'deepseek-flash' && calls[0].thinking?.type === 'disabled' && calls[0].auth === 'Bearer sk-ds', '主:LARES_AI_LLM_* 的 model / key,DeepSeek 关思考', calls[0]);
  check(calls[1].model === 'qwen-flash' && calls[1].url.startsWith('https://dashscope.aliyuncs.com/compatible-mode/v1/') && calls[1].auth === 'Bearer sk-dash'
    && calls[1].enable_thinking === false, '回退:DashScope compatible-mode qwen-flash', calls[1]);
  const only = createAnonymLlm({ LARES_AI_LLM_BASE_URL: 'https://api.deepseek.com', LARES_AI_LLM_KEY: 'sk-ds' }, { fetchImpl });
  let e = null;
  try { await only.chat([{ role: 'user', content: 'hi' }]); } catch (x) { e = x; }
  check(e && e.code === 'llm_failed' && !String(e.message).includes('SECRET') && e.message === 'llm_http_500', '无回退时错误只带 code,不带上游正文', e?.message);
  const dash = createAnonymLlm({ LARES_DASHSCOPE_API_KEY: 'sk-dash' }, { fetchImpl });
  calls.length = 0;
  await dash.chat([{ role: 'user', content: 'x' }]);
  check(calls.length === 1 && calls[0].model === 'qwen-flash', '只配 DashScope key → qwen-flash', calls);
}

async function e2e() {
  console.log('\n[端到端:真服务端 + 真核心]');
  const dash = await startFakeDashscope();
  const apns = await startFakeApns();
  const rx = await startReceiver();
  const { privateKey: apnsKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-anonym-'));
  const env = {
    LARES_ANONYM_LLM: 'off', // 核心走确定性 mock(不出网)
    LARES_DASHSCOPE_API_KEY: 'sk-test-' + randomBytes(6).toString('hex'),
    LARES_DASHSCOPE_BASE: `http://127.0.0.1:${dash.port}`,
    LARES_APNS_KEY: apnsKey.export({ type: 'pkcs8', format: 'pem' }),
    LARES_APNS_KEY_ID: 'TESTKEY123', LARES_APNS_TEAM_ID: '7CH28564U7',
    LARES_APNS_HOST_OVERRIDE: `https://127.0.0.1:${apns.port}`, LARES_APNS_INSECURE_TLS: '1',
    LARES_PUBLIC_URL: 'wss://lares.test:8444/ws',
    LARES_PLUGIN_ALLOW_PRIVATE: '1',
    ...(rtcOk ? {
      LIVEKIT_URL: 'ws://127.0.0.1:9', LIVEKIT_API_KEY: 'devkey', LIVEKIT_API_SECRET: 'secret-secret-secret-secret-secret',
      LARES_AI_PROVIDERS: 'mock',
    } : {}),
  };
  const srv = boot(PORT, dataDir, GLOBAL_PASS, env);
  const open = [];
  const isErr = (op) => (m) => m.t === 'anon_error' && m.op === op;
  try {
    check(await waitHealth(PORT), '服务端启动');
    const { cid, verifier, ownerKey, owner: reg } = await registerCircle(PORT, 'anon-pass-' + randomBytes(4).toString('hex'), 'u_owner');
    await reg.close();
    const A = await connect(PORT, { userId: 'u_owner', name: '阿蛮', auth: v2Auth(verifier, cid, { ownerKey }) });
    const B = await connect(PORT, { userId: 'u_bob', name: 'Bobsworth', auth: v2Auth(verifier, cid) });
    const C = await connect(PORT, { userId: 'u_carol', name: 'Carolyne', auth: v2Auth(verifier, cid) });
    const D = await connect(PORT, { userId: 'u_dave', name: 'Davo', auth: v2Auth(verifier, cid) }); // 大厅里,收推送
    open.push(A, B, C, D);
    check([A, B, C, D].every((c) => c.kind === 'welcome'), '四个成员连上');

    // 准备:转写开、装 webhook 插件、建机器人 token、D 登记推送
    let r = await A.req({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_ok', '圈主开转写记录', r);
    const manifest = {
      id: 'com.example.kb', name: 'KB', version: '1.0.0', description: 'kb', author: 'x',
      permissions: ['circle:read', 'members:read', 'knowledge:read'],
      webhook: { url: `http://127.0.0.1:${rx.port}/hook`, events: ['join', 'knowledge.released'] },
    };
    r = await A.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    check(r?.t === 'plugin_installed', '装插件(knowledge:read + knowledge.released webhook)', r);
    const pluginToken = r?.token;
    r = await A.req({ t: 'bot_token_create', circleId: cid, name: 'bot', ownerKey }, (m) => m.t === 'bot_token' || m.t === 'owner_error');
    const botToken = r?.token;
    check(typeof botToken === 'string', '建机器人 token', r);
    const TD = randomBytes(32).toString('hex');
    const nowUtcMin = new Date().getUTCHours() * 60 + new Date().getUTCMinutes();
    r = await D.req({ t: 'push_register', provider: 'apns', token: TD, env: 'sandbox', lang: 'zh',
      circles: [{ circleId: cid, name: '秘密圈', level: 'all' }], prefs: { tzOffsetMin: 0, quiet: { start: (nowUtcMin + 120) % 1440, end: (nowUtcMin + 180) % 1440 } } },
    (m) => m.t === 'push_registered' || m.t === 'push_error');
    check(r?.t === 'push_registered', 'D 登记推送', r);

    // env 圈(全站兜底口令)不可用
    const E = await connect(PORT, { userId: 'u_env', name: 'Env', auth: v1Auth(GLOBAL_PASS, 'c_envtest') });
    open.push(E);
    await join(E, 'c_envtest');
    r = await E.req({ t: 'anon_start', circleId: 'c_envtest', k: 2 }, isErr('anon_start'));
    check(r?.code === 'not_registered', 'env / legacy 圈 anon_start → not_registered', r);
    await E.close();
    // 加密圈不可用
    {
      const z = await registerCircle(PORT, 'anon-e2ee-' + randomBytes(4).toString('hex'), 'u_zed');
      open.push(z.owner);
      r = await z.owner.req({ t: 'circle_e2ee_set', circleId: z.cid, enabled: true, ownerKey: z.ownerKey }, ownerReply('circle_e2ee_set'));
      await join(z.owner, z.cid);
      r = await z.owner.req({ t: 'anon_start', circleId: z.cid, k: 2, ownerKey: z.ownerKey }, isErr('anon_start'));
      check(r?.code === 'e2ee_circle', 'E2EE 圈 anon_start → e2ee_circle', r);
      await z.owner.close();
    }

    let aiId = null;
    if (rtcOk) {
      r = await A.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.ai-voice' }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
      check(r?.t === 'plugin_installed', '装 lares.ai-voice', r);
      aiId = `u_ai_${crypto.createHash('sha256').update(cid).digest('hex').slice(0, 8)}`;
    }

    // 不在房的圈主不能开
    r = await A.req({ t: 'anon_start', circleId: cid, k: 2 }, isErr('anon_start'));
    check(r?.code === 'not_in_room', '圈主不在房 → not_in_room', r);
    await join(A, cid);
    if (rtcOk) {
      const j = await A.waitFor((m) => m.t === 'member_joined' && m.member?.userId === aiId, 15000);
      check(Boolean(j), 'AI 语音助手(会话前)正常进房', j ?? srv.out.slice(-800));
    }
    r = await A.req({ t: 'anon_start', circleId: cid, k: 2 }, isErr('anon_start'));
    check(r?.code === 'too_few', '房里只有 1 个真人(AI 不算)→ too_few', r);
    await join(B, cid);
    await join(C, cid);
    const sse = await openSse(botToken);
    check(sse.res.status === 200, '机器人 SSE 连上', sse.res.status);
    await wait(200);

    r = await B.req({ t: 'anon_start', circleId: cid, k: 2 }, isErr('anon_start'));
    check(r?.code === 'not_owner', '非圈主 anon_start → not_owner', r);
    r = await A.req({ t: 'anon_start', circleId: cid, k: 4 }, isErr('anon_start'));
    check(r?.code === 'bad_k', 'k > 在房真人数 → bad_k', r);
    r = await A.req({ t: 'anon_start', circleId: cid, k: 1 }, isErr('anon_start'));
    check(r?.code === 'bad_k', 'k < 2 → bad_k', r);

    for (const c of [A, B, C]) c.drain(() => true);
    A.send({ t: 'anon_start', circleId: cid, k: 2 });
    const stA = await A.waitFor((m) => m.t === 'anon_state');
    const stC = await C.waitFor((m) => m.t === 'anon_state');
    check(stA?.active === true && stA.k === 2 && stA.convenerId === 'u_owner' && typeof stA.sid === 'string', 'anon_state{active,sid,k,convenerId}', stA);
    check(stC?.active === true && stC.members?.length === 3 && stC.members.every((m) => m.acked === false), '未 ack 的成员也收到 anon_state(可弹同意页),成员 3 人(AI 不算)', stC);
    check(!stC.members.some((m) => m.id === aiId), 'members 不含 AI 助手', stC.members);
    const sid = stA.sid;
    r = await A.req({ t: 'anon_start', circleId: cid, k: 2 }, isErr('anon_start'));
    check(r?.code === 'already_active', '一个圈只能一场 → already_active', r);

    // ── 会话期强制关闭 ──
    console.log('\n[会话期强制关闭]');
    r = await B.req({ t: 'transcript_append', circleId: cid, id: 'x1', text: 'should not archive' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_appended');
    check(r?.t === 'transcript_error' && r.reason === 'anonym_active', 'transcript_append → anonym_active', r);
    r = await B.req({ t: 'transcript_relay', circleId: cid, blob: 'AAAA' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_relayed');
    check(r?.t === 'transcript_error' && r.reason === 'anonym_active', 'transcript_relay → anonym_active', r);
    r = await B.req({ t: 'cap_token' }, (m) => m.t === 'cap_token' || m.t === 'cap_error');
    check(r?.t === 'cap_token' && /^st-fake-/.test(r.token), 'cap_token 照常签发(字幕要用来喂 anon_utt)', r);
    const cap = await fetch(BASE + '/api/v1/captions', { method: 'POST', headers: { authorization: `Bearer ${botToken}`, 'content-type': 'application/json' }, body: JSON.stringify({ text: 'bot line', final: true }) });
    check(cap.status === 409, '机器人字幕 POST /api/v1/captions → 409 anonym_active', cap.status);
    const sseBefore = sse.events.length;
    const hooksBefore = rx.got.length;
    const F = await connect(PORT, { userId: 'u_frank', name: 'Frankel', auth: v2Auth(verifier, cid) });
    open.push(F);
    await join(F, cid); // 会话期间进房:不发 join SSE / webhook
    const stF = await F.waitFor((m) => m.t === 'anon_state');
    check(stF?.active === true && stF.sid === sid, '会话期间进房的人收到当前 anon_state', stF);
    await wait(600);
    check(sse.events.length === sseBefore, '会话期间机器人 SSE 无任何事件', sse.events.slice(sseBefore));
    check(rx.got.length === hooksBefore, '会话期间插件 webhook 无任何事件', rx.got.slice(hooksBefore).map((x) => x.body?.type));
    let t0 = Date.now();
    r = await A.req({ t: 'push_summon', circleId: cid, ownerKey }, (m) => m.t === 'push_summon_ok' || m.t === 'owner_error');
    const ps = await apns.waitFor((q) => q.token === TD && q.at >= t0);
    check(ps?.body?.aps?.alert?.title === 'Lares' && ps?.body?.aps?.alert?.body === '有人在你的圈子里', '推送脱敏:标题 Lares、正文不含人名 / 圈名', ps?.body?.aps ?? r);
    if (rtcOk) {
      const back = await A.waitFor((m) => m.t === 'member_joined' && m.member?.userId === aiId, 8000);
      check(!back, '会话期间 AI 语音助手不在房(停掉且不重拉,> 退避 5 s)', back);
      check(/\[ai-voice\][^\n]*停止\(disabled\)/.test(srv.out), 'anon_start → supervisor 以 disabled 停掉已在跑的子进程', srv.out.split('\n').filter((l) => l.includes('[ai-voice]')).slice(-6));
    }

    // ── ack / utt ──
    console.log('\n[ack / 发言 / 问答]');
    const kA = newKey(), kB = newKey(), kF = newKey();
    r = await B.req({ t: 'anon_utt', circleId: cid, text: 'pelicanfjord early words before consent', ts: Date.now(), final: true }, isErr('anon_utt'), 300);
    check(r === null, '未 ack 的 anon_utt 静默丢弃(不回错)', r);
    r = await A.req({ t: 'anon_ack', circleId: cid, pubKey: 'not-a-key' }, isErr('anon_ack'));
    check(r?.code === 'bad_key', '坏公钥 → bad_key', r);
    for (const c of [A, B, C, F]) c.drain((m) => m.t === 'anon_state');
    A.send({ t: 'anon_ack', circleId: cid, pubKey: kA.pubKey });
    let s = await C.waitFor((m) => m.t === 'anon_state' && m.members?.find((x) => x.id === 'u_owner')?.acked);
    check(Boolean(s), 'ack 后 anon_state 广播(acked=true)', s);
    B.send({ t: 'anon_ack', circleId: cid, pubKey: kB.pubKey });
    F.send({ t: 'anon_ack', circleId: cid, pubKey: kF.pubKey });
    await wait(200);
    r = await C.req({ t: 'anon_ask', circleId: cid, question: 'anything?' }, isErr('anon_ask'));
    check(r?.code === 'not_acked', '未 ack 的人 anon_ask → not_acked', r);
    r = await C.req({ t: 'anon_draft', circleId: cid }, isErr('anon_draft'));
    check(r?.code === 'not_acked', '未 ack 的人 anon_draft → not_acked', r);

    const now = Date.now();
    A.send({ t: 'anon_utt', circleId: cid, text: 'We should move the marmalade launch to Friday because testing is behind.', ts: now, final: true });
    B.send({ t: 'anon_utt', circleId: cid, text: 'The onboarding flow for tangerinevault needs another week of polish.', ts: now + 1, final: true });
    B.send({ t: 'anon_utt', circleId: cid, text: 'interim obsidianlark words', ts: now + 2, final: false });
    r = await A.req({ t: 'anon_utt', circleId: cid, text: 'x'.repeat(2001), ts: now, final: true }, isErr('anon_utt'));
    check(r?.code === 'bad_text', '过长原话 → bad_text', r);
    await wait(150);
    for (const c of [A, B, C, F]) c.drain(() => true);
    A.send({ t: 'anon_ask', circleId: cid, question: 'When is the marmalade launch?' });
    const ansB = await B.waitFor((m) => m.t === 'anon_answer');
    check(ansB?.askerName === '阿蛮' && ansB.question === 'When is the marmalade launch?' && /marmalade/.test(ansB.answer), 'anon_answer 发给已 ack 成员(含提问人名)', ansB);
    check(!/pelicanfjord/.test(ansB?.answer ?? '') && !/obsidianlark/.test(ansB?.answer ?? ''), '未 ack 时说的话 / 非定稿不进 agent', ansB?.answer);
    await wait(150);
    check(!C.inbox.some((m) => m.t === 'anon_answer'), '未 ack 的成员收不到 anon_answer', C.inbox.map((m) => m.t));

    // ── draft / review / approve ──
    console.log('\n[草稿 / 审阅 / 签名放行]');
    A.send({ t: 'anon_draft', circleId: cid });
    const dB = await B.waitFor((m) => m.t === 'anon_draft');
    let draft = dB?.draft;
    check(draft?.draftId && /^[0-9a-f]{64}$/.test(draft.draftHash) && draft.items?.length >= 2 && draft.metrics?.k === 2, 'anon_draft{draft:{draftId,draftHash,items,metrics}}', dB);
    check(!JSON.stringify(draft).includes('阿蛮') && !JSON.stringify(draft).includes('Bobsworth'), '草稿不含说话人名', draft);
    await wait(100);
    check(!C.inbox.some((m) => m.t === 'anon_draft'), '未 ack 的成员收不到草稿', C.inbox.map((m) => m.t));
    const oldHash = draft.draftHash;
    const target = draft.items.find((i) => /tangerinevault/.test(i.text)) ?? draft.items[1];
    for (const c of [A, B]) c.drain(() => true);
    B.send({ t: 'anon_review', circleId: cid, draftId: draft.draftId, itemId: target.id, action: 'generalise' });
    const rv = await A.waitFor((m) => m.t === 'anon_draft');
    draft = rv?.draft;
    check(draft && draft.draftHash !== oldHash && draft.items.find((i) => i.id === target.id)?.flags.includes('generalised'), 'review generalise → 新 draftHash', draft);
    r = await B.req({ t: 'anon_review', circleId: cid, draftId: draft.draftId, itemId: target.id, action: 'nuke' }, isErr('anon_review'));
    check(r?.code === 'bad_request', '未知 action → bad_request', r);

    // 旧 hash 签的 → hash_mismatch
    let sg = signApproval(kA, { sid, draftId: draft.draftId, draftHash: oldHash });
    r = await A.req({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: oldHash, ...sg }, isErr('anon_approve'));
    check(r?.code === 'hash_mismatch', '旧 hash → hash_mismatch', r);
    // 签名对不上(用 B 的私钥冒签 A)→ bad_sig
    sg = signApproval(kB, { sid, draftId: draft.draftId, draftHash: draft.draftHash });
    r = await A.req({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: draft.draftHash, ...sg }, isErr('anon_approve'));
    check(r?.code === 'bad_sig', '别人的私钥签 → bad_sig', r);
    // 未 ack 的人不能签
    r = await C.req({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: draft.draftHash, ...signApproval(newKey(), { sid, draftId: draft.draftId, draftHash: draft.draftHash }) }, isErr('anon_approve'));
    check(r?.code === 'not_acked', '未 ack 的人 anon_approve → not_acked', r);
    for (const c of [A, B, C]) c.drain(() => true);
    const sgA = signApproval(kA, { sid, draftId: draft.draftId, draftHash: draft.draftHash });
    A.send({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: draft.draftHash, ...sgA });
    let ap = await B.waitFor((m) => m.t === 'anon_approvals');
    check(ap?.count === 1 && ap.k === 2 && ap.draftId === draft.draftId, 'anon_approvals{count:1,k:2}', ap);
    r = await A.req({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: draft.draftHash, ...sgA }, isErr('anon_approve'));
    check(r?.code === 'replay', '同一 nonce 重放 → replay', r);
    const hooksPre = rx.got.length;
    B.send({ t: 'anon_approve', circleId: cid, draftId: draft.draftId, draftHash: draft.draftHash, ...signApproval(kB, { sid, draftId: draft.draftId, draftHash: draft.draftHash }) });
    ap = await A.waitFor((m) => m.t === 'anon_approvals' && m.count === 2);
    const relA = await A.waitFor((m) => m.t === 'anon_released');
    check(Boolean(ap) && relA?.draftId === draft.draftId && /marmalade/.test(relA.text), 'k=2 达成 → anon_released{draftId,text}', relA);
    check(!/阿蛮|Bobsworth|Carolyne|Frankel/.test(relA?.text ?? ''), '放行文本不含任何成员名', relA?.text);
    await wait(100);
    check(!C.inbox.some((m) => m.t === 'anon_released' || m.t === 'anon_approvals'), '未 ack 的成员收不到 approvals / released', C.inbox.map((m) => m.t));

    const kh = await rx.waitFor((x) => x.body?.type === 'knowledge.released');
    const kitems = kh?.body?.data?.items ?? [];
    check(kh && kh.body.circleId === cid && kitems.length >= 1 && kitems.every((i) => i.id && i.text && i.kind), 'webhook knowledge.released{items:[{id,text,kind}]}(会话期唯一放行的事件)', kh?.body);
    check(kh && !/阿蛮|Bobsworth|u_owner|u_bob|approverIds|speaker/.test(kh.raw), 'knowledge.released 不含说话人 / 签名人', kh?.raw);
    check(rx.got.slice(hooksPre).every((x) => x.body?.type === 'knowledge.released'), '会话期 webhook 只有 knowledge.released', rx.got.slice(hooksPre).map((x) => x.body?.type));
    check(sse.events.length === sseBefore, '放行也不进机器人 SSE', sse.events.slice(sseBefore));

    // ── bot API ──
    console.log('\n[机器人 API]');
    let g = await getJson(`/bot/v1/circles/${cid}/anonym/released`, botToken);
    check(g.status === 200 && g.body.items?.length === 1 && g.body.items[0].draftId === draft.draftId && g.body.items[0].text === relA.text, 'GET /bot/v1/circles/:id/anonym/released → 放行文本', g);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/released`);
    check(g.status === 401, '无 token → 401', g.status);
    g = await getJson(`/bot/v1/circles/c_someoneelse/anonym/released`, botToken);
    check(g.status === 403, '别的圈 → 403', g);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/knowledge?q=${encodeURIComponent('marmalade launch Friday')}`, pluginToken);
    check(g.status === 200 && g.body.items?.length >= 1 && /marmalade/.test(g.body.items[0].text) && !('approverIds' in g.body.items[0]), 'GET …/anonym/knowledge?q=(插件 token,knowledge:read)→ 去名条目', g);

    // ── 圈子记忆 ──
    console.log('\n[圈子记忆 list / retract]');
    D.drain(() => true);
    r = await D.req({ t: 'anon_mem_list', circleId: cid }, (m) => m.t === 'anon_mem' || m.t === 'anon_error');
    check(r?.t === 'anon_mem' && r.items.length === kitems.length && r.items.every((i) => i.canRetract === false && !('approverIds' in i)), '不在房的普通成员可读;canRetract=false(没签过),无 approverIds', r);
    r = await B.req({ t: 'anon_mem_list', circleId: cid }, (m) => m.t === 'anon_mem' || m.t === 'anon_error');
    check(r?.items?.every((i) => i.canRetract === true), '签过放行的成员 canRetract=true', r);
    r = await A.req({ t: 'anon_mem_list', circleId: cid }, (m) => m.t === 'anon_mem' || m.t === 'anon_error');
    check(r?.items?.every((i) => i.canRetract === true), '圈主 canRetract=true', r);
    const itemId = r.items[0].id;
    r = await D.req({ t: 'anon_mem_retract', circleId: cid, itemId }, isErr('anon_mem_retract'));
    check(r?.code === 'not_approver', '没签过的成员撤回 → not_approver', r);
    r = await D.req({ t: 'anon_mem_retract', circleId: cid, itemId: 'nope' }, isErr('anon_mem_retract'));
    check(r?.code === 'no_such_item', '不存在的条目 → no_such_item', r);
    for (const c of [A, D]) c.drain(() => true);
    B.send({ t: 'anon_mem_retract', circleId: cid, itemId });
    const rtD = await D.waitFor((m) => m.t === 'anon_mem_retracted');
    const rtA = await A.waitFor((m) => m.t === 'anon_mem_retracted');
    check(rtD?.itemId === itemId && rtA?.itemId === itemId, '签名人撤回 → anon_mem_retracted 发给圈内所有在线成员(含大厅)', { rtD, rtA });
    r = await D.req({ t: 'anon_mem_list', circleId: cid }, (m) => m.t === 'anon_mem');
    const tomb = r?.items?.find((i) => i.id === itemId);
    check(tomb?.retracted === true && !('text' in tomb), '列表里变墓碑(无 text)', tomb);
    r = await A.req({ t: 'anon_mem_retract', circleId: cid, itemId }, isErr('anon_mem_retract'));
    check(r?.code === 'already_retracted', '再撤 → already_retracted', r);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/knowledge?q=${encodeURIComponent(tomb ? kitems.find((x) => x.id === itemId)?.text ?? 'x' : 'x')}`, botToken);
    check(g.status === 200 && !g.body.items.some((i) => i.id === itemId), '撤回的条目不再出现在 knowledge', g.body);
    const memFile = path.join(dataDir, 'anonym_memory', `${cid}.json`);
    check(existsSync(memFile), '知识库落盘 anonym_memory/<cid>.json');

    // ── end ──
    console.log('\n[结束 / 即焚]');
    A.send({ t: 'anon_utt', circleId: cid, text: 'zebraquartz is the secret codename nobody released', ts: Date.now(), final: true });
    await wait(100);
    r = await B.req({ t: 'anon_end', circleId: cid }, isErr('anon_end'));
    check(r?.code === 'not_owner', '非圈主 anon_end → not_owner', r);
    for (const c of [A, B, C]) c.drain(() => true);
    A.send({ t: 'anon_end', circleId: cid });
    const endC = await C.waitFor((m) => m.t === 'anon_ended');
    check(endC?.receipt && /^[0-9a-f]{64}$/.test(endC.receipt.sha256) && endC.receipt.counts?.releases === 1 && endC.receipt.counts?.utterances >= 3
      && Object.keys(endC.receipt).sort().join() === 'counts,sha256', 'anon_ended{receipt:{counts,sha256}}', endC);
    const off = await C.waitFor((m) => m.t === 'anon_state' && m.active === false);
    check(Boolean(off), '结束后 anon_state{active:false}', off);
    r = await A.req({ t: 'anon_ask', circleId: cid, question: 'x' }, isErr('anon_ask'));
    check(r?.code === 'no_session', '结束后 anon_ask → no_session', r);
    r = await B.req({ t: 'transcript_append', circleId: cid, id: 'x2', text: 'after the session' }, (m) => m.t === 'transcript_error' || m.t === 'transcript_appended');
    check(r?.t === 'transcript_appended', '结束后转写恢复', r);
    g = await getJson(`/bot/v1/circles/${cid}/anonym/released`, botToken);
    check(g.body?.items?.length === 1, '放行文本在会话结束后仍可读(内存)', g.body);
    if (rtCheck()) {
      const back = await A.waitFor((m) => m.t === 'member_joined' && m.member?.userId === aiId, 15000);
      check(Boolean(back), '结束后 AI 语音助手按原规则回来', back);
    }

    // 第二场:验证上一场的原话已焚;最后一个真人离开 → 自动结束
    r = await A.req({ t: 'anon_start', circleId: cid, k: 2 }, (m) => (m.t === 'anon_state' && m.active) || m.t === 'anon_error');
    check(r?.t === 'anon_state' && r.sid !== sid, '第二场 anon_start(新 sid)', r);
    A.send({ t: 'anon_ack', circleId: cid, pubKey: newKey().pubKey });
    B.send({ t: 'anon_ack', circleId: cid, pubKey: newKey().pubKey });
    await wait(150);
    A.drain(() => true);
    A.send({ t: 'anon_ask', circleId: cid, question: 'What about zebraquartz codename?' });
    const a2 = await A.waitFor((m) => m.t === 'anon_answer');
    check(a2 && !/zebraquartz/.test(a2.answer), '上一场没放行的原话已焚(新会话问不出来)', a2?.answer);
    // 离房即退出本场(客户端离房即焚钥匙):回来不是 acked,且能用新公钥重新 ack
    B.send({ t: 'leave' });
    await wait(150);
    await join(B, cid);
    r = await B.req({ t: 'anon_ask', circleId: cid, question: 'x' }, isErr('anon_ask'));
    check(r?.code === 'not_acked', '离房再回 → 需重新同意(not_acked)', r);
    B.drain(() => true);
    B.send({ t: 'anon_ack', circleId: cid, pubKey: newKey().pubKey });
    const reB = await B.waitFor((m) => (m.t === 'anon_state' && m.members?.find((x) => x.id === 'u_bob')?.acked) || m.t === 'anon_error');
    check(reB?.t === 'anon_state', '离房再回 → 新公钥 ack 成功(不 key_mismatch)', reB);
    const sseMid = sse.events.length;
    for (const c of [A, B, C, F]) c.send({ t: 'leave' });
    await wait(400);
    const A2 = await connect(PORT, { userId: 'u_owner', deviceId: 'd-2', name: '阿蛮', auth: v2Auth(verifier, cid, { ownerKey }) });
    open.push(A2);
    await join(A2, cid);
    r = await A2.req({ t: 'anon_ask', circleId: cid, question: 'x' }, isErr('anon_ask'));
    check(r?.code === 'no_session', '最后一个真人离开 → 会话自动结束', r);
    const jh = await rx.waitFor((x) => x.body?.type === 'join' && x.at > Date.now() - 2000, 3000);
    check(Boolean(jh), '会话结束后 webhook 恢复(join)', rx.got.map((x) => x.body?.type));
    await wait(200);
    check(sse.events.length > sseMid, '会话结束后机器人 SSE 恢复', sse.events.slice(sseMid).map((e) => e.event));

    // 日志不含任何原话 / 问题 / 回答
    const leaked = SECRET_WORDS.filter((w) => srv.out.includes(w));
    check(leaked.length === 0, '服务端日志不含任何原话 / 问题 / 回答', leaked);
    const stored = readFileSync(memFile, 'utf8');
    check(!/阿蛮|Bobsworth|u_owner|u_bob|zebraquartz|pelicanfjord|obsidianlark/.test(stored), '知识库文件不含人名 / user id / 未放行原话', stored.slice(0, 300));

    // 解散圈 → 删知识库
    sse.ctrl.abort();
    A2.send({ t: 'circle_delete', circleId: cid, ownerKey });
    await wait(500);
    check(!existsSync(memFile), 'circle_delete → anonym_memory/<cid>.json 删除');
  } finally {
    for (const c of open) await c.close?.().catch?.(() => {});
    await wait(100);
    await stop(srv);
    await dash.close(); await apns.close(); await rx.close();
    if (T.fail && !process.env.DEBUG) console.log(srv.out.slice(-3000));
  }
  function rtCheck() { return rtcOk; }
}

console.log('隐名之约(anonym)');
await unitLlm();
await e2e();
console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
process.exit(T.fail === 0 ? 0 : 1);
